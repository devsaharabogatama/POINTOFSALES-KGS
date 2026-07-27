-- G2 phase 32 behavioral test: business-field dry-run validation.
-- SAFETY: every master fixture, job, preview, and event rolls back.

BEGIN;

DO $test$
DECLARE
    v_actor UUID;
    v_company_a UUID := '00000000-0000-0000-0000-000000032001';
    v_company_b UUID := '00000000-0000-0000-0000-000000032002';
    v_store_a UUID := '00000000-0000-0000-0000-000000032011';
    v_store_b UUID := '00000000-0000-0000-0000-000000032012';
    v_uom UUID := '00000000-0000-0000-0000-000000032021';
    v_warehouse UUID := '00000000-0000-0000-0000-000000032022';
    v_supplier UUID := '00000000-0000-0000-0000-000000032023';
    v_job UUID;
    v_result JSONB;
    v_count BIGINT;
BEGIN
    SELECT p.id INTO v_actor
    FROM public.profiles p
    JOIN auth.users u ON u.id = p.id
    WHERE p.role = 'super_admin'::user_role
    ORDER BY p.id LIMIT 1;
    IF v_actor IS NULL THEN
        RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: linked Super Admin required';
    END IF;

    INSERT INTO public.companies(
        id,company_code,company_name,company_slug,status
    ) VALUES
        (v_company_a,'G32A','G32 Company A','g32-company-a','ACTIVE'),
        (v_company_b,'G32B','G32 Company B','g32-company-b','ACTIVE');
    INSERT INTO public.stores(id,company_id,store_code,store_name,status) VALUES
        (v_store_a,v_company_a,'A1','G32 Store A','ACTIVE'),
        (v_store_b,v_company_b,'B1','G32 Store B','ACTIVE');
    INSERT INTO public.uoms(
        id,company_id,code,name,uom_type,allow_decimal,decimal_precision
    ) VALUES (v_uom,v_company_a,'PCS','Piece','UNIT',FALSE,0);
    INSERT INTO public.warehouses(
        id,company_id,code,name,warehouse_type,is_purchase_destination
    ) VALUES (v_warehouse,v_company_a,'WHA','Warehouse A','CENTRAL',FALSE);
    INSERT INTO public.suppliers(
        id,company_id,supplier_code,supplier_name,phone,created_by,updated_by
    ) VALUES (
        v_supplier,v_company_a,'SUP-A','Supplier A','0800',v_actor,v_actor
    );

    PERFORM set_config(
        'request.jwt.claims',
        jsonb_build_object('sub',v_actor,'role','authenticated')::TEXT,TRUE
    );
    PERFORM public.set_active_company_context(v_company_a,'G2_PHASE32_TEST');

    -- UOM: business-only change becomes UPDATE; invalid precision is row error.
    v_result := public.create_master_import_job(
        '00000000-0000-0000-0000-000000032101',
        'UOM','REFERENCE_BY_NAME','CREATE_AND_UPDATE',
        'uom-business.csv',repeat('a',64),','
    );
    v_job := (v_result->>'jobId')::UUID;
    PERFORM public.stage_master_import_rows(
        v_job,1,
        '{"code":"code","name":"name","uomType":"type","allowDecimal":"decimal","decimalPrecision":"precision"}'::JSONB,
        '[
            {"rowNumber":2,"sourceData":{"code":"PCS","name":"Piece","type":"UNIT","decimal":"true","precision":"2"}},
            {"rowNumber":3,"sourceData":{"code":"KG","name":"Kilogram","type":"WEIGHT","decimal":"true","precision":"3"}},
            {"rowNumber":4,"sourceData":{"code":"CASE","name":"Case","type":"PACKAGING","decimal":"false","precision":"2"}}
        ]'::JSONB
    );
    v_result := public.validate_master_import_job(v_job,2);
    IF (v_result->>'createCount')::INTEGER <> 1
       OR (v_result->>'updateCount')::INTEGER <> 1
       OR (v_result->>'errorCount')::INTEGER <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: UOM business summary invalid: %',v_result;
    END IF;
    SELECT count(*) INTO v_count FROM public.master_import_rows
    WHERE job_id = v_job AND matched_record_id = v_uom
      AND operation = 'UPDATE'
      AND before_state->>'allowDecimal' = 'false'
      AND after_state->>'allowDecimal' = 'true'
      AND after_state->>'decimalPrecision' = '2'
      AND warnings @> '[{"code":"UPDATE_EXISTING_CONFIRMATION_REQUIRED"}]';
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: UOM business diff/warning invalid';
    END IF;
    SELECT count(*) INTO v_count FROM public.master_import_rows
    WHERE job_id = v_job
      AND errors @> '[{"code":"INTEGER_UOM_PRECISION_MUST_BE_ZERO"}]';
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: invalid UOM precision not isolated';
    END IF;

    -- Warehouse: location is optional, STORE needs an active same-Company Store.
    v_result := public.create_master_import_job(
        '00000000-0000-0000-0000-000000032102',
        'WAREHOUSE','REFERENCE_BY_NAME','CREATE_AND_UPDATE',
        'warehouse-business.csv',repeat('b',64),','
    );
    v_job := (v_result->>'jobId')::UUID;
    PERFORM public.stage_master_import_rows(
        v_job,1,
        '{"code":"code","name":"name","warehouseType":"type","storeId":"store","location":"location","isPurchaseDestination":"purchase"}'::JSONB,
        jsonb_build_array(
            jsonb_build_object('rowNumber',2,'sourceData',jsonb_build_object(
                'code','WHA','name','Warehouse A','type','CENTRAL',
                'store','','location','','purchase','true'
            )),
            jsonb_build_object('rowNumber',3,'sourceData',jsonb_build_object(
                'code','STA','name','Store Warehouse','type','STORE',
                'store',v_store_a,'location','','purchase','true'
            )),
            jsonb_build_object('rowNumber',4,'sourceData',jsonb_build_object(
                'code','STB','name','Foreign Store Warehouse','type','STORE',
                'store',v_store_b,'location','','purchase','true'
            ))
        )
    );
    v_result := public.validate_master_import_job(v_job,2);
    IF (v_result->>'createCount')::INTEGER <> 1
       OR (v_result->>'updateCount')::INTEGER <> 1
       OR (v_result->>'errorCount')::INTEGER <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: Warehouse business summary invalid: %',v_result;
    END IF;
    SELECT count(*) INTO v_count FROM public.master_import_rows
    WHERE job_id = v_job
      AND errors @> '[{"code":"ACTIVE_STORE_NOT_FOUND"}]';
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: foreign Store reference accepted';
    END IF;
    SELECT count(*) INTO v_count FROM public.master_import_rows
    WHERE job_id = v_job AND row_number = 3
      AND after_state->>'storeId' = v_store_a::TEXT
      AND after_state->'location' = 'null'::JSONB;
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: valid Store Warehouse preview invalid';
    END IF;

    -- Supplier optional fields participate in diff and enforce form limits.
    v_result := public.create_master_import_job(
        '00000000-0000-0000-0000-000000032103',
        'SUPPLIER','REFERENCE_BY_NAME','CREATE_AND_UPDATE',
        'supplier-business.csv',repeat('c',64),','
    );
    v_job := (v_result->>'jobId')::UUID;
    PERFORM public.stage_master_import_rows(
        v_job,1,
        '{"code":"code","name":"name","phone":"phone","bankName":"bank"}'::JSONB,
        jsonb_build_array(
            jsonb_build_object('rowNumber',2,'sourceData',jsonb_build_object(
                'code','SUP-A','name','Supplier A','phone','0811','bank','Bank A'
            )),
            jsonb_build_object('rowNumber',3,'sourceData',jsonb_build_object(
                'code','SUP-B','name','Supplier B','phone','0822','bank','Bank B'
            )),
            jsonb_build_object('rowNumber',4,'sourceData',jsonb_build_object(
                'code','SUP-C','name','Supplier C','phone',repeat('9',101),
                'bank','Bank C'
            ))
        )
    );
    v_result := public.validate_master_import_job(v_job,2);
    IF (v_result->>'createCount')::INTEGER <> 1
       OR (v_result->>'updateCount')::INTEGER <> 1
       OR (v_result->>'errorCount')::INTEGER <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: Supplier business summary invalid: %',v_result;
    END IF;
    SELECT count(*) INTO v_count FROM public.master_import_rows
    WHERE job_id = v_job
      AND errors @> '[{"code":"SUPPLIER_PHONE_TOO_LONG"}]';
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: Supplier length validation invalid';
    END IF;

    -- Category common identity receives the same manual-form length limits.
    v_result := public.create_master_import_job(
        '00000000-0000-0000-0000-000000032104',
        'PRODUCT_CATEGORY','REFERENCE_BY_NAME','CREATE_AND_UPDATE',
        'category-business.csv',repeat('d',64),','
    );
    v_job := (v_result->>'jobId')::UUID;
    PERFORM public.stage_master_import_rows(
        v_job,1,'{"code":"code","name":"name"}'::JSONB,
        jsonb_build_array(
            jsonb_build_object('rowNumber',2,'sourceData',jsonb_build_object(
                'code','FOOD','name','Food'
            )),
            jsonb_build_object('rowNumber',3,'sourceData',jsonb_build_object(
                'code',repeat('X',51),'name','Too Long Code'
            ))
        )
    );
    v_result := public.validate_master_import_job(v_job,2);
    IF (v_result->>'createCount')::INTEGER <> 1
       OR (v_result->>'errorCount')::INTEGER <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: Category business summary invalid: %',v_result;
    END IF;
    SELECT count(*) INTO v_count FROM public.master_import_rows
    WHERE job_id = v_job
      AND errors @> '[{"code":"CATEGORY_CODE_TOO_LONG"}]';
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: Category length validation invalid';
    END IF;

    -- All phases above are preview-only.
    IF EXISTS (SELECT 1 FROM public.uoms WHERE company_id = v_company_a AND code = 'KG')
       OR EXISTS (SELECT 1 FROM public.warehouses WHERE company_id = v_company_a AND code = 'STA')
       OR EXISTS (SELECT 1 FROM public.suppliers WHERE company_id = v_company_a AND supplier_code = 'SUP-B')
       OR EXISTS (SELECT 1 FROM public.product_categories WHERE company_id = v_company_a AND category_code = 'FOOD')
       OR EXISTS (SELECT 1 FROM public.uoms WHERE id = v_uom AND allow_decimal)
       OR EXISTS (SELECT 1 FROM public.warehouses WHERE id = v_warehouse AND is_purchase_destination)
       OR EXISTS (SELECT 1 FROM public.suppliers WHERE id = v_supplier AND phone <> '0800') THEN
        RAISE EXCEPTION 'TEST_FAILED: business dry-run mutated master data';
    END IF;

    RAISE NOTICE 'TEST PASSED: four-master import business validation matches manual CRUD limits, isolates row errors, rejects cross-Company Store references, preserves optional Warehouse location, and remains dry-run only.';
END
$test$;

ROLLBACK;
