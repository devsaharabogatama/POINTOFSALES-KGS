-- G2 phase 46 behavioral test: guarded Product-Warehouse minimum stock/import.
-- SAFETY: every fixture, setting, audit, and import job is rolled back.

BEGIN;

DO $test$
DECLARE
    v_actor UUID;
    v_job_id UUID;
    v_setting_id UUID;
    v_result JSONB;
    v_version BIGINT;
    v_count BIGINT;
    v_balance_before BIGINT;
    v_movement_before BIGINT;
    v_rejected BOOLEAN;
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
            '00000000-0000-0000-0000-000000046001',
            'G46A','G46 Company A','g46-company-a','ACTIVE'
        ),
        (
            '00000000-0000-0000-0000-000000046002',
            'G46B','G46 Company B','g46-company-b','ACTIVE'
        );
    INSERT INTO public.product_categories(
        id,company_id,category_code,category_name
    ) VALUES (
        '00000000-0000-0000-0000-000000046011',
        '00000000-0000-0000-0000-000000046001',
        'G46-CAT','G46 Food'
    );
    INSERT INTO public.uoms(id,company_id,code,name) VALUES (
        '00000000-0000-0000-0000-000000046021',
        '00000000-0000-0000-0000-000000046001',
        'G46-KTL','G46 Ketul'
    );
    INSERT INTO public.products(
        id,company_id,sku,name,category,category_id,price,cogs,uom,uom_id,
        weight_reference_uom_id,weight_per_uom_kg,is_active,is_bundle
    ) VALUES (
        '00000000-0000-0000-0000-000000046031',
        '00000000-0000-0000-0000-000000046001',
        'G46-KEBAB','G46 Kebab','G46 Food',
        '00000000-0000-0000-0000-000000046011',
        100,50,'G46-KTL',
        '00000000-0000-0000-0000-000000046021',
        '00000000-0000-0000-0000-000000046021',
        2.1,TRUE,FALSE
    );
    INSERT INTO public.product_uoms(
        company_id,product_id,uom_id,factor_to_base,purchase_allowed,
        sales_allowed,purchase_price,sale_price
    ) VALUES (
        '00000000-0000-0000-0000-000000046001',
        '00000000-0000-0000-0000-000000046031',
        '00000000-0000-0000-0000-000000046021',
        1,TRUE,TRUE,50,100
    );
    INSERT INTO public.warehouses(
        id,company_id,code,name,warehouse_type
    ) VALUES
        (
            '00000000-0000-0000-0000-000000046041',
            '00000000-0000-0000-0000-000000046001',
            'GFA','G46 Gudang Utama','CENTRAL'
        ),
        (
            '00000000-0000-0000-0000-000000046042',
            '00000000-0000-0000-0000-000000046001',
            'GFB','G46 Gudang Cabang','CENTRAL'
        ),
        (
            '00000000-0000-0000-0000-000000046043',
            '00000000-0000-0000-0000-000000046002',
            'GFX','G46 Gudang Asing','CENTRAL'
        );

    SELECT count(*) INTO v_balance_before
    FROM public.product_stocks
    WHERE company_id = '00000000-0000-0000-0000-000000046001';
    SELECT count(*) INTO v_movement_before
    FROM public.stock_movements
    WHERE company_id = '00000000-0000-0000-0000-000000046001';

    PERFORM set_config(
        'request.jwt.claims',
        jsonb_build_object('sub',v_actor,'role','authenticated')::TEXT,
        TRUE
    );
    PERFORM public.set_active_company_context(
        '00000000-0000-0000-0000-000000046001','G2_PHASE46_TEST'
    );

    v_result := public.save_product_warehouse_stock_setting(
        NULL,NULL,
        '00000000-0000-0000-0000-000000046031',
        '00000000-0000-0000-0000-000000046041',
        5,TRUE
    );
    v_setting_id := (v_result->>'settingId')::UUID;
    v_version := (v_result->>'masterVersion')::BIGINT;
    IF v_version <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: create version invalid';
    END IF;

    v_rejected := FALSE;
    BEGIN
        PERFORM public.save_product_warehouse_stock_setting(
            v_setting_id,0,
            '00000000-0000-0000-0000-000000046031',
            '00000000-0000-0000-0000-000000046041',
            6,TRUE
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'MASTER_VERSION_CONFLICT' THEN v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: stale setting update accepted';
    END IF;

    v_rejected := FALSE;
    BEGIN
        PERFORM public.save_product_warehouse_stock_setting(
            NULL,NULL,
            '00000000-0000-0000-0000-000000046031',
            '00000000-0000-0000-0000-000000046043',
            1,TRUE
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'ACTIVE_WAREHOUSE_NOT_FOUND' THEN v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: cross-Company Warehouse accepted';
    END IF;

    v_rejected := FALSE;
    BEGIN
        PERFORM public.save_product_warehouse_stock_setting(
            v_setting_id,1,
            '00000000-0000-0000-0000-000000046031',
            '00000000-0000-0000-0000-000000046041',
            NULL,TRUE
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'MINIMUM_STOCK_REQUIRED_WHEN_ALERT_ENABLED' THEN
            v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: alert without threshold accepted';
    END IF;

    v_rejected := FALSE;
    BEGIN
        PERFORM public.save_product_warehouse_stock_setting(
            v_setting_id,1,
            '00000000-0000-0000-0000-000000046031',
            '00000000-0000-0000-0000-000000046041',
            2.5,TRUE
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'MINIMUM_STOCK_BASE_UOM_REQUIRES_INTEGER' THEN
            v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION
            'TEST_FAILED: fractional threshold accepted for integer Base UOM';
    END IF;

    v_result := public.create_master_import_job(
        '00000000-0000-0000-0000-000000046101',
        'PRODUCT_WAREHOUSE_MINIMUM_STOCK',
        'REFERENCE_BY_NAME','CREATE_AND_UPDATE',
        'g46-minimum-stock.csv',repeat('d',64),','
    );
    v_job_id := (v_result->>'jobId')::UUID;
    v_version := (v_result->>'masterVersion')::BIGINT;

    v_result := public.stage_master_import_rows(
        v_job_id,v_version,
        jsonb_build_object(
            'productSku','product_sku',
            'warehouseName','warehouse_name',
            'minimumStockBaseQty','minimum_stock_base_qty',
            'lowStockAlertEnabled','low_stock_alert_enabled'
        ),
        jsonb_build_array(
            jsonb_build_object(
                'rowNumber',1,
                'sourceData',jsonb_build_object(
                    'product_sku','G46-KEBAB',
                    'warehouse_name','G46 Gudang Utama',
                    'minimum_stock_base_qty','8',
                    'low_stock_alert_enabled','true'
                )
            ),
            jsonb_build_object(
                'rowNumber',2,
                'sourceData',jsonb_build_object(
                    'product_sku','G46-KEBAB',
                    'warehouse_name','G46 Gudang Cabang',
                    'minimum_stock_base_qty','3',
                    'low_stock_alert_enabled','true'
                )
            ),
            jsonb_build_object(
                'rowNumber',3,
                'sourceData',jsonb_build_object(
                    'product_sku','G46-KEBAB',
                    'warehouse_name','G46 Gudang Asing',
                    'minimum_stock_base_qty','1',
                    'low_stock_alert_enabled','true'
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
            'TEST_FAILED: minimum-stock preview invalid: %',v_result;
    END IF;
    v_version := (v_result->>'masterVersion')::BIGINT;

    SELECT count(*) INTO v_count
    FROM public.master_import_rows
    WHERE company_id = '00000000-0000-0000-0000-000000046001'
      AND job_id = v_job_id
      AND row_number = 3
      AND operation = 'ERROR'
      AND errors @> '[{"code":"ACTIVE_WAREHOUSE_NOT_FOUND"}]'::JSONB;
    IF v_count <> 1 THEN
        RAISE EXCEPTION
            'TEST_FAILED: foreign Warehouse import was not rejected';
    END IF;

    v_result := public.commit_master_import_job(v_job_id,v_version,1);
    IF v_result->>'status' <> 'COMPLETED_WITH_ERRORS'
       OR (v_result->>'createCount')::INTEGER <> 1
       OR (v_result->>'updateCount')::INTEGER <> 1 THEN
        RAISE EXCEPTION
            'TEST_FAILED: minimum-stock commit invalid: %',v_result;
    END IF;

    SELECT count(*) INTO v_count
    FROM public.product_warehouse_stock_settings
    WHERE company_id = '00000000-0000-0000-0000-000000046001'
      AND product_id = '00000000-0000-0000-0000-000000046031'
      AND low_stock_alert_enabled
      AND (
          (
              warehouse_id = '00000000-0000-0000-0000-000000046041'
              AND minimum_stock_base_qty = 8
          )
          OR (
              warehouse_id = '00000000-0000-0000-0000-000000046042'
              AND minimum_stock_base_qty = 3
          )
      );
    IF v_count <> 2 THEN
        RAISE EXCEPTION
            'TEST_FAILED: expected two configured Warehouse settings';
    END IF;

    SELECT count(*) INTO v_count
    FROM public.product_warehouse_stock_setting_audit
    WHERE company_id = '00000000-0000-0000-0000-000000046001';
    IF v_count <> 3 THEN
        RAISE EXCEPTION
            'TEST_FAILED: create/update setting audit missing';
    END IF;

    SELECT count(*) INTO v_count
    FROM public.product_stocks
    WHERE company_id = '00000000-0000-0000-0000-000000046001';
    IF v_count <> v_balance_before THEN
        RAISE EXCEPTION
            'TEST_FAILED: minimum stock created/changed stock balance';
    END IF;
    SELECT count(*) INTO v_count
    FROM public.stock_movements
    WHERE company_id = '00000000-0000-0000-0000-000000046001';
    IF v_count <> v_movement_before THEN
        RAISE EXCEPTION
            'TEST_FAILED: minimum stock created stock movement';
    END IF;

    v_result := public.commit_master_import_job(v_job_id,v_version,1);
    IF v_result->>'action' <> 'EXISTING' THEN
        RAISE EXCEPTION 'TEST_FAILED: terminal retry was not idempotent';
    END IF;

    IF has_table_privilege(
        'authenticated',
        'public.product_warehouse_stock_settings',
        'INSERT,UPDATE,DELETE'
    ) OR has_function_privilege(
        'authenticated',
        'private.validate_master_import_minimum_stock_job(uuid,bigint)',
        'EXECUTE'
    ) OR has_function_privilege(
        'authenticated',
        'private.commit_master_import_minimum_stock_job(uuid,bigint,integer)',
        'EXECUTE'
    ) OR NOT has_function_privilege(
        'authenticated',
        'public.save_product_warehouse_stock_setting(uuid,bigint,uuid,uuid,numeric,boolean)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION
            'TEST_FAILED: minimum-stock privilege boundary invalid';
    END IF;

    RAISE NOTICE
        'TEST PASSED: Product-Warehouse minimum stock is tenant-safe, versioned, audited, importable, idempotent, and stock/request neutral.';
END
$test$;

ROLLBACK;
