-- G2 phase 44 behavioral test: guarded Product-Supplier fixed import.
-- SAFETY: every fixture, import job, relation, and audit row is rolled back.

BEGIN;

DO $test$
DECLARE
    v_actor UUID;
    v_job_id UUID;
    v_result JSONB;
    v_version BIGINT;
    v_count BIGINT;
    v_movement_before BIGINT;
    v_relation_id UUID;
BEGIN
    SELECT p.id INTO v_actor
    FROM public.profiles p
    JOIN auth.users u ON u.id = p.id
    WHERE p.role = 'super_admin'::user_role
    ORDER BY p.id LIMIT 1;
    IF v_actor IS NULL THEN
        RAISE EXCEPTION
            'TEST_PRECONDITION_FAILED: linked Super Admin required';
    END IF;

    INSERT INTO public.companies(
        id,company_code,company_name,company_slug,status
    ) VALUES
        (
            '00000000-0000-0000-0000-000000044001',
            'G44A','G44 Company A','g44-company-a','ACTIVE'
        ),
        (
            '00000000-0000-0000-0000-000000044002',
            'G44B','G44 Company B','g44-company-b','ACTIVE'
        );
    INSERT INTO public.product_categories(
        id,company_id,category_code,category_name
    ) VALUES (
        '00000000-0000-0000-0000-000000044011',
        '00000000-0000-0000-0000-000000044001',
        'G44-CAT','G44 Food'
    );
    INSERT INTO public.uoms(id,company_id,code,name) VALUES
        (
            '00000000-0000-0000-0000-000000044021',
            '00000000-0000-0000-0000-000000044001',
            'G44-KTL','G44 Ketul'
        ),
        (
            '00000000-0000-0000-0000-000000044022',
            '00000000-0000-0000-0000-000000044001',
            'G44-DUS','G44 Dus'
        );
    INSERT INTO public.products(
        id,company_id,sku,name,category,category_id,price,cogs,uom,uom_id,
        weight_reference_uom_id,weight_per_uom_kg,is_active,is_bundle
    ) VALUES (
        '00000000-0000-0000-0000-000000044031',
        '00000000-0000-0000-0000-000000044001',
        'G44-KEBAB','G44 Kebab','G44 Food',
        '00000000-0000-0000-0000-000000044011',
        100,50,'G44-KTL',
        '00000000-0000-0000-0000-000000044021',
        '00000000-0000-0000-0000-000000044022',
        21,TRUE,FALSE
    );
    INSERT INTO public.product_uoms(
        company_id,product_id,uom_id,factor_to_base,purchase_allowed,
        sales_allowed,purchase_price,sale_price
    ) VALUES
        (
            '00000000-0000-0000-0000-000000044001',
            '00000000-0000-0000-0000-000000044031',
            '00000000-0000-0000-0000-000000044021',
            1,FALSE,TRUE,50,100
        ),
        (
            '00000000-0000-0000-0000-000000044001',
            '00000000-0000-0000-0000-000000044031',
            '00000000-0000-0000-0000-000000044022',
            10,TRUE,FALSE,500,1000
        );
    INSERT INTO public.suppliers(
        id,company_id,supplier_code,supplier_name
    ) VALUES
        (
            '00000000-0000-0000-0000-000000044041',
            '00000000-0000-0000-0000-000000044001',
            'G44-S1','G44 Supplier Lama'
        ),
        (
            '00000000-0000-0000-0000-000000044042',
            '00000000-0000-0000-0000-000000044001',
            'G44-S2','G44 Supplier Baru'
        ),
        (
            '00000000-0000-0000-0000-000000044043',
            '00000000-0000-0000-0000-000000044002',
            'G44-SX','G44 Supplier Asing'
        );
    INSERT INTO public.product_suppliers(
        id,company_id,product_id,supplier_id,purchase_uom_id,
        supplier_product_code,reference_purchase_price,
        is_preferred_supplier,is_active
    ) VALUES (
        '00000000-0000-0000-0000-000000044051',
        '00000000-0000-0000-0000-000000044001',
        '00000000-0000-0000-0000-000000044031',
        '00000000-0000-0000-0000-000000044041',
        '00000000-0000-0000-0000-000000044022',
        'OLD-KEBAB',500,TRUE,TRUE
    );

    SELECT count(*) INTO v_movement_before
    FROM public.stock_movements
    WHERE company_id = '00000000-0000-0000-0000-000000044001';

    PERFORM set_config(
        'request.jwt.claims',
        jsonb_build_object('sub',v_actor,'role','authenticated')::TEXT,
        TRUE
    );
    PERFORM public.set_active_company_context(
        '00000000-0000-0000-0000-000000044001','G2_PHASE44_TEST'
    );

    v_result := public.create_master_import_job(
        '00000000-0000-0000-0000-000000044101',
        'PRODUCT_SUPPLIER','REFERENCE_BY_NAME','CREATE_AND_UPDATE',
        'g44-product-supplier.csv',repeat('c',64),','
    );
    v_job_id := (v_result->>'jobId')::UUID;
    v_version := (v_result->>'masterVersion')::BIGINT;

    v_result := public.stage_master_import_rows(
        v_job_id,v_version,
        jsonb_build_object(
            'productSku','product_sku',
            'supplierName','supplier_name',
            'purchaseUomName','purchase_uom_name',
            'supplierProductCode','supplier_product_code',
            'referencePurchasePrice','reference_purchase_price',
            'isPreferredSupplier','is_preferred_supplier',
            'isActive','is_active'
        ),
        jsonb_build_array(
            jsonb_build_object(
                'rowNumber',1,
                'sourceData',jsonb_build_object(
                    'product_sku','G44-KEBAB',
                    'supplier_name','G44 Supplier Lama',
                    'purchase_uom_name','G44 Dus',
                    'supplier_product_code','OLD-KEBAB-UPDATED',
                    'reference_purchase_price','510',
                    'is_preferred_supplier','false',
                    'is_active','true'
                )
            ),
            jsonb_build_object(
                'rowNumber',2,
                'sourceData',jsonb_build_object(
                    'product_sku','G44-KEBAB',
                    'supplier_name','G44 Supplier Baru',
                    'purchase_uom_name','G44 Dus',
                    'supplier_product_code','NEW-KEBAB',
                    'reference_purchase_price','490',
                    'is_preferred_supplier','true',
                    'is_active','true'
                )
            ),
            jsonb_build_object(
                'rowNumber',3,
                'sourceData',jsonb_build_object(
                    'product_sku','G44-KEBAB',
                    'supplier_name','G44 Supplier Asing',
                    'purchase_uom_name','G44 Dus',
                    'supplier_product_code','FOREIGN',
                    'reference_purchase_price','1',
                    'is_preferred_supplier','false',
                    'is_active','true'
                )
            )
        )
    );
    v_version := (v_result->>'masterVersion')::BIGINT;

    v_result := public.validate_master_import_job(v_job_id,v_version);
    IF (v_result->>'createCount')::INTEGER <> 1
       OR (v_result->>'updateCount')::INTEGER <> 1
       OR (v_result->>'errorCount')::INTEGER <> 1 THEN
        RAISE EXCEPTION
            'TEST_FAILED: Product-Supplier preview summary invalid: %',
            v_result;
    END IF;
    v_version := (v_result->>'masterVersion')::BIGINT;

    SELECT count(*) INTO v_count
    FROM public.master_import_rows
    WHERE company_id = '00000000-0000-0000-0000-000000044001'
      AND job_id = v_job_id
      AND row_number = 3
      AND operation = 'ERROR'
      AND errors @> '[{"code":"ACTIVE_SUPPLIER_NOT_FOUND"}]'::JSONB;
    IF v_count <> 1 THEN
        RAISE EXCEPTION
            'TEST_FAILED: cross-Company Supplier was not rejected';
    END IF;

    v_result := public.commit_master_import_job(v_job_id,v_version,1);
    IF v_result->>'status' <> 'COMPLETED_WITH_ERRORS'
       OR (v_result->>'createCount')::INTEGER <> 1
       OR (v_result->>'updateCount')::INTEGER <> 1 THEN
        RAISE EXCEPTION
            'TEST_FAILED: Product-Supplier commit summary invalid: %',
            v_result;
    END IF;

    SELECT id INTO v_relation_id
    FROM public.product_suppliers
    WHERE company_id = '00000000-0000-0000-0000-000000044001'
      AND product_id = '00000000-0000-0000-0000-000000044031'
      AND supplier_id = '00000000-0000-0000-0000-000000044042'
      AND purchase_uom_id = '00000000-0000-0000-0000-000000044022'
      AND supplier_product_code = 'NEW-KEBAB'
      AND reference_purchase_price = 490
      AND is_preferred_supplier
      AND is_active;
    IF v_relation_id IS NULL THEN
        RAISE EXCEPTION
            'TEST_FAILED: new preferred Product-Supplier was not created';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM public.product_suppliers
        WHERE company_id = '00000000-0000-0000-0000-000000044001'
          AND id = '00000000-0000-0000-0000-000000044051'
          AND supplier_product_code = 'OLD-KEBAB-UPDATED'
          AND reference_purchase_price = 510
          AND NOT is_preferred_supplier
          AND is_active
    ) THEN
        RAISE EXCEPTION
            'TEST_FAILED: old preferred relation was not updated first';
    END IF;

    SELECT count(*) INTO v_count
    FROM public.product_supplier_audit
    WHERE company_id = '00000000-0000-0000-0000-000000044001'
      AND product_supplier_id IN (
          '00000000-0000-0000-0000-000000044051',v_relation_id
      );
    IF v_count <> 2 THEN
        RAISE EXCEPTION
            'TEST_FAILED: Product-Supplier create/update audit missing';
    END IF;

    SELECT count(*) INTO v_count
    FROM public.stock_movements
    WHERE company_id = '00000000-0000-0000-0000-000000044001';
    IF v_count <> v_movement_before THEN
        RAISE EXCEPTION
            'TEST_FAILED: Product-Supplier import changed stock movement';
    END IF;

    -- Terminal retry is idempotent and returns the same outcome.
    v_result := public.commit_master_import_job(v_job_id,v_version,1);
    IF v_result->>'action' <> 'EXISTING' THEN
        RAISE EXCEPTION 'TEST_FAILED: terminal commit retry was not idempotent';
    END IF;

    IF has_table_privilege(
        'authenticated','public.product_suppliers','INSERT,UPDATE,DELETE'
    ) OR has_function_privilege(
        'authenticated',
        'private.validate_master_import_product_supplier_job(uuid,bigint)',
        'EXECUTE'
    ) OR has_function_privilege(
        'authenticated',
        'private.commit_master_import_product_supplier_job(uuid,bigint,integer)',
        'EXECUTE'
    ) OR NOT has_function_privilege(
        'authenticated',
        'public.validate_master_import_job(uuid,bigint)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION
            'TEST_FAILED: Product-Supplier import privilege boundary invalid';
    END IF;

    RAISE NOTICE
        'TEST PASSED: Product-Supplier import is tenant-safe, previewed, preferred-switch safe, partially committed, audited, idempotent, and stock-neutral.';
END
$test$;

ROLLBACK;
