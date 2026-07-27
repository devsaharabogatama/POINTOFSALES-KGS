-- G2 phase 33 behavioral test: guarded partial non-stock import commit.
-- SAFETY: every master write, audit row, job, and event rolls back.

BEGIN;

DO $test$
DECLARE
    v_actor UUID;
    v_company_a UUID := '00000000-0000-0000-0000-000000033001';
    v_company_b UUID := '00000000-0000-0000-0000-000000033002';
    v_store_a UUID := '00000000-0000-0000-0000-000000033011';
    v_piece UUID := '00000000-0000-0000-0000-000000033021';
    v_supplier UUID := '00000000-0000-0000-0000-000000033022';
    v_job UUID;
    v_result JSONB;
    v_count BIGINT;
    v_rejected BOOLEAN;
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
        (v_company_a,'G33A','G33 Company A','g33-company-a','ACTIVE'),
        (v_company_b,'G33B','G33 Company B','g33-company-b','ACTIVE');
    INSERT INTO public.stores(id,company_id,store_code,store_name,status)
    VALUES (v_store_a,v_company_a,'A1','G33 Store A','ACTIVE');
    INSERT INTO public.uoms(
        id,company_id,code,name,uom_type,allow_decimal,decimal_precision
    ) VALUES (v_piece,v_company_a,'PCS','Piece','UNIT',FALSE,0);
    INSERT INTO public.suppliers(
        id,company_id,supplier_code,supplier_name,phone,created_by,updated_by
    ) VALUES (
        v_supplier,v_company_a,'SUP-A','Supplier A','0800',v_actor,v_actor
    );

    PERFORM set_config(
        'request.jwt.claims',
        jsonb_build_object('sub',v_actor,'role','authenticated')::TEXT,TRUE
    );
    PERFORM public.set_active_company_context(v_company_a,'G2_PHASE33_TEST');

    -- Category: one commit-time duplicate and one validation error do not
    -- prevent the other valid row from committing.
    v_result := public.create_master_import_job(
        '00000000-0000-0000-0000-000000033101',
        'PRODUCT_CATEGORY','REFERENCE_BY_NAME','CREATE_AND_UPDATE',
        'category-commit.csv',repeat('a',64),','
    );
    v_job := (v_result->>'jobId')::UUID;
    PERFORM public.stage_master_import_rows(
        v_job,1,'{"code":"code","name":"name"}'::JSONB,
        jsonb_build_array(
            jsonb_build_object('rowNumber',2,'sourceData',jsonb_build_object(
                'code','CAT-A','name','Category A'
            )),
            jsonb_build_object('rowNumber',3,'sourceData',jsonb_build_object(
                'code','CAT-B','name','Category B'
            )),
            jsonb_build_object('rowNumber',4,'sourceData',jsonb_build_object(
                'code',repeat('X',51),'name','Invalid Category'
            ))
        )
    );
    v_result := public.validate_master_import_job(v_job,2);
    IF (v_result->>'createCount')::INTEGER <> 2
       OR (v_result->>'errorCount')::INTEGER <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: Category preview invalid';
    END IF;
    INSERT INTO public.product_categories(
        company_id,category_code,category_name,created_by,updated_by
    ) VALUES (v_company_a,'CAT-B','Competing Category',v_actor,v_actor);

    v_result := public.commit_master_import_job(v_job,3,0);
    IF v_result->>'status' <> 'COMPLETED_WITH_ERRORS'
       OR (v_result->>'createCount')::INTEGER <> 1
       OR (v_result->>'errorCount')::INTEGER <> 2 THEN
        RAISE EXCEPTION 'TEST_FAILED: Category partial commit invalid: %',v_result;
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM public.product_categories
        WHERE company_id = v_company_a AND category_code = 'CAT-A'
    ) THEN RAISE EXCEPTION 'TEST_FAILED: valid Category was not committed'; END IF;
    SELECT count(*) INTO v_count FROM public.master_import_rows
    WHERE job_id = v_job
      AND errors @> '[{"code":"DUPLICATE_MASTER_AT_COMMIT"}]';
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: commit-time duplicate not isolated';
    END IF;
    v_result := public.commit_master_import_job(v_job,3,0);
    IF v_result->>'action' <> 'EXISTING'
       OR (v_result->>'createCount')::INTEGER <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: commit retry was not idempotent';
    END IF;

    -- UOM update requires exact explicit confirmation before any write.
    v_result := public.create_master_import_job(
        '00000000-0000-0000-0000-000000033102',
        'UOM','REFERENCE_BY_NAME','CREATE_AND_UPDATE',
        'uom-commit.csv',repeat('b',64),','
    );
    v_job := (v_result->>'jobId')::UUID;
    PERFORM public.stage_master_import_rows(
        v_job,1,
        '{"code":"code","name":"name","uomType":"type","allowDecimal":"decimal","decimalPrecision":"precision"}'::JSONB,
        '[
            {"rowNumber":2,"sourceData":{"code":"PCS","name":"Piece","type":"UNIT","decimal":"true","precision":"2"}},
            {"rowNumber":3,"sourceData":{"code":"KG","name":"Kilogram","type":"WEIGHT","decimal":"true","precision":"3"}}
        ]'::JSONB
    );
    PERFORM public.validate_master_import_job(v_job,2);
    v_rejected := FALSE;
    BEGIN
        PERFORM public.commit_master_import_job(v_job,3,0);
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'IMPORT_UPDATE_CONFIRMATION_REQUIRED' THEN
            v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected OR EXISTS (
        SELECT 1 FROM public.uoms WHERE company_id = v_company_a AND code = 'KG'
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: unconfirmed update wrote master data';
    END IF;
    v_result := public.commit_master_import_job(v_job,3,1);
    IF v_result->>'status' <> 'COMPLETED'
       OR (v_result->>'createCount')::INTEGER <> 1
       OR (v_result->>'updateCount')::INTEGER <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: confirmed UOM commit invalid';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM public.uoms
        WHERE id = v_piece AND allow_decimal AND decimal_precision = 2
    ) OR NOT EXISTS (
        SELECT 1 FROM public.uoms
        WHERE company_id = v_company_a AND code = 'KG'
    ) THEN RAISE EXCEPTION 'TEST_FAILED: UOM commit values invalid'; END IF;

    -- Warehouse cross-Company job access is denied before own-Company commit.
    v_result := public.create_master_import_job(
        '00000000-0000-0000-0000-000000033103',
        'WAREHOUSE','REFERENCE_BY_NAME','CREATE_AND_UPDATE',
        'warehouse-commit.csv',repeat('c',64),','
    );
    v_job := (v_result->>'jobId')::UUID;
    PERFORM public.stage_master_import_rows(
        v_job,1,
        '{"code":"code","name":"name","warehouseType":"type","storeId":"store"}'::JSONB,
        jsonb_build_array(jsonb_build_object(
            'rowNumber',2,'sourceData',jsonb_build_object(
                'code','STA','name','Store Warehouse','type','STORE',
                'store',v_store_a
            )
        ))
    );
    PERFORM public.validate_master_import_job(v_job,2);
    PERFORM public.set_active_company_context(v_company_b,'G2_PHASE33_TEST');
    v_rejected := FALSE;
    BEGIN
        PERFORM public.commit_master_import_job(v_job,3,0);
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'IMPORT_JOB_NOT_FOUND' THEN v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: cross-Company job commit accepted';
    END IF;
    PERFORM public.set_active_company_context(v_company_a,'G2_PHASE33_TEST');
    PERFORM public.commit_master_import_job(v_job,3,0);
    IF NOT EXISTS (
        SELECT 1 FROM public.warehouses
        WHERE company_id = v_company_a AND code = 'STA'
          AND store_id = v_store_a AND location IS NULL
    ) THEN RAISE EXCEPTION 'TEST_FAILED: Warehouse commit invalid'; END IF;

    -- Supplier changed after preview is reported as a row error, not overwritten.
    v_result := public.create_master_import_job(
        '00000000-0000-0000-0000-000000033104',
        'SUPPLIER','REFERENCE_BY_NAME','CREATE_AND_UPDATE',
        'supplier-commit.csv',repeat('d',64),','
    );
    v_job := (v_result->>'jobId')::UUID;
    PERFORM public.stage_master_import_rows(
        v_job,1,
        '{"code":"code","name":"name","phone":"phone"}'::JSONB,
        '[
            {"rowNumber":2,"sourceData":{"code":"SUP-A","name":"Supplier A","phone":"0811"}},
            {"rowNumber":3,"sourceData":{"code":"SUP-B","name":"Supplier B","phone":"0822"}}
        ]'::JSONB
    );
    PERFORM public.validate_master_import_job(v_job,2);
    UPDATE public.suppliers SET phone = 'MANUAL',updated_by = v_actor
    WHERE id = v_supplier;
    v_result := public.commit_master_import_job(v_job,3,1);
    IF v_result->>'status' <> 'COMPLETED_WITH_ERRORS'
       OR (v_result->>'createCount')::INTEGER <> 1
       OR (v_result->>'errorCount')::INTEGER <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: stale Supplier preview not rejected';
    END IF;
    IF (SELECT phone FROM public.suppliers WHERE id = v_supplier) <> 'MANUAL' THEN
        RAISE EXCEPTION 'TEST_FAILED: stale import overwrote Supplier';
    END IF;
    SELECT count(*) INTO v_count FROM public.master_import_rows
    WHERE job_id = v_job
      AND errors @> '[{"code":"MASTER_CHANGED_AFTER_VALIDATION"}]';
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: stale Supplier error evidence missing';
    END IF;
    SELECT count(*) INTO v_count
    FROM public.supplier_master_audit a
    JOIN public.suppliers s ON s.id = a.supplier_id
    WHERE a.company_id = v_company_a
      AND s.supplier_code = 'SUP-B' AND a.action = 'CREATE';
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: committed Supplier audit missing';
    END IF;

    IF has_function_privilege(
        'anon','public.commit_master_import_job(uuid,bigint,integer)','EXECUTE'
    ) OR NOT has_function_privilege(
        'authenticated',
        'public.commit_master_import_job(uuid,bigint,integer)','EXECUTE'
    ) OR EXISTS (
        SELECT 1 FROM public.stock_movements
        WHERE reference_table = 'master_import_jobs'
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: commit privilege/stock boundary invalid';
    END IF;

    RAISE NOTICE 'TEST PASSED: non-stock import commit is confirmation-guarded, tenant-safe, partial-success, optimistic, audited, and idempotent without Product or stock mutation.';
END
$test$;

ROLLBACK;
