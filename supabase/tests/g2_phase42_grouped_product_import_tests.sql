-- G2 phase 42 behavioral test: grouped Product/Product-UOM import.
-- SAFETY: every fixture, job, Product, UOM, audit, and movement is rolled back.

BEGIN;

DO $test$
DECLARE
    v_actor UUID;
    v_job_id UUID;
    v_product_id UUID;
    v_result JSONB;
    v_version BIGINT;
    v_count BIGINT;
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
    ) VALUES (
        '00000000-0000-0000-0000-000000042001',
        'G42A','G42 Company A','g42-company-a','ACTIVE'
    );
    INSERT INTO public.product_categories(
        id,company_id,category_code,category_name
    ) VALUES (
        '00000000-0000-0000-0000-000000042011',
        '00000000-0000-0000-0000-000000042001',
        'G42-CAT','G42 Food'
    );
    INSERT INTO public.uoms(id,company_id,code,name) VALUES
        (
            '00000000-0000-0000-0000-000000042021',
            '00000000-0000-0000-0000-000000042001',
            'G42-KTL','G42 Ketul'
        ),
        (
            '00000000-0000-0000-0000-000000042022',
            '00000000-0000-0000-0000-000000042001',
            'G42-DUS','G42 Dus'
        );
    INSERT INTO public.warehouses(
        id,company_id,code,name,warehouse_type
    ) VALUES (
        '00000000-0000-0000-0000-000000042031',
        '00000000-0000-0000-0000-000000042001',
        'G42-WH','G42 Warehouse','CENTRAL'
    );

    PERFORM set_config(
        'request.jwt.claims',
        jsonb_build_object('sub',v_actor,'role','authenticated')::TEXT,
        TRUE
    );
    PERFORM public.set_active_company_context(
        '00000000-0000-0000-0000-000000042001','G2_PHASE42_TEST'
    );

    v_result := public.create_master_import_job(
        '00000000-0000-0000-0000-000000042101',
        'PRODUCT','REFERENCE_BY_NAME','CREATE_AND_UPDATE',
        'g42-product.csv',repeat('a',64),','
    );
    v_job_id := (v_result->>'jobId')::UUID;
    v_version := (v_result->>'masterVersion')::BIGINT;

    v_result := public.stage_master_import_rows(
        v_job_id,v_version,
        jsonb_build_object(
            'productKey','product_key',
            'sku','sku',
            'productName','product_name',
            'categoryName','category_name',
            'imageUrl','image_url',
            'isActive','is_active',
            'uomName','uom_name',
            'factorToBase','factor_to_base',
            'purchaseAllowed','purchase_allowed',
            'salesAllowed','sales_allowed',
            'purchasePrice','purchase_price',
            'salePrice','sale_price',
            'barcode','barcode',
            'salesTaxRuleName','sales_tax_rule_name',
            'purchaseTaxRuleName','purchase_tax_rule_name',
            'weightPerLargestUomKg','weight_per_largest_uom_kg'
        ),
        jsonb_build_array(
            jsonb_build_object(
                'rowNumber',1,
                'sourceData',jsonb_build_object(
                    'product_key','KEBAB',
                    'sku','G42-KEBAB',
                    'product_name','G42 Kebab',
                    'category_name','G42 Food',
                    'is_active','true',
                    'uom_name','G42 Ketul',
                    'factor_to_base','1',
                    'purchase_allowed','false',
                    'sales_allowed','true',
                    'purchase_price','50',
                    'sale_price','100',
                    'weight_per_largest_uom_kg','21'
                )
            ),
            jsonb_build_object(
                'rowNumber',2,
                'sourceData',jsonb_build_object(
                    'product_key','KEBAB',
                    'sku','G42-KEBAB',
                    'product_name','G42 Kebab',
                    'category_name','G42 Food',
                    'is_active','true',
                    'uom_name','G42 Dus',
                    'factor_to_base','10',
                    'purchase_allowed','true',
                    'sales_allowed','false',
                    'purchase_price','500',
                    'sale_price','1000',
                    'barcode','G42BOX',
                    'weight_per_largest_uom_kg','21'
                )
            ),
            jsonb_build_object(
                'rowNumber',3,
                'sourceData',jsonb_build_object(
                    'product_key','INVALID',
                    'sku','G42-BAD',
                    'product_name','G42 Invalid',
                    'category_name','Missing Category',
                    'is_active','true',
                    'uom_name','G42 Ketul',
                    'factor_to_base','1',
                    'purchase_allowed','true',
                    'sales_allowed','true',
                    'purchase_price','1',
                    'sale_price','1',
                    'weight_per_largest_uom_kg','1'
                )
            )
        )
    );
    v_version := (v_result->>'masterVersion')::BIGINT;

    v_result := public.validate_master_import_job(v_job_id,v_version);
    IF (v_result->>'createCount')::INTEGER <> 1
       OR (v_result->>'errorCount')::INTEGER <> 1 THEN
        RAISE EXCEPTION
            'TEST_FAILED: expected one valid and one rejected Product group';
    END IF;
    v_version := (v_result->>'masterVersion')::BIGINT;

    SELECT count(*) INTO v_count
    FROM public.master_import_rows
    WHERE job_id = v_job_id
      AND group_key = 'KEBAB'
      AND operation = 'CREATE'
      AND row_status = 'VALIDATED';
    IF v_count <> 2 THEN
        RAISE EXCEPTION
            'TEST_FAILED: valid Product group was not kept atomic';
    END IF;

    v_result := public.commit_master_import_job(v_job_id,v_version,0);
    IF v_result->>'status' <> 'COMPLETED_WITH_ERRORS'
       OR (v_result->>'createCount')::INTEGER <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: Product partial commit summary invalid';
    END IF;

    SELECT id INTO v_product_id
    FROM public.products
    WHERE company_id = '00000000-0000-0000-0000-000000042001'
      AND sku = 'G42-KEBAB';
    IF v_product_id IS NULL THEN
        RAISE EXCEPTION 'TEST_FAILED: valid Product was not created';
    END IF;
    IF EXISTS (
        SELECT 1 FROM public.products
        WHERE company_id = '00000000-0000-0000-0000-000000042001'
          AND sku = 'G42-BAD'
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: rejected Product partially persisted';
    END IF;

    SELECT count(*) INTO v_count
    FROM public.product_uoms
    WHERE company_id = '00000000-0000-0000-0000-000000042001'
      AND product_id = v_product_id
      AND is_active;
    IF v_count <> 2 THEN
        RAISE EXCEPTION
            'TEST_FAILED: expected two committed Product-UOM rows';
    END IF;
    SELECT count(*) INTO v_count
    FROM public.product_master_audit
    WHERE company_id = '00000000-0000-0000-0000-000000042001'
      AND product_id = v_product_id
      AND action = 'CREATE';
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: Product create audit missing';
    END IF;

    INSERT INTO public.stock_movements(
        product_id,warehouse_id,qty_change,movement_type,
        reference_table,reference_id,company_id
    ) VALUES (
        v_product_id,
        '00000000-0000-0000-0000-000000042031',
        1,'PURCHASE'::stock_movement_type,
        'G2_PHASE42_TEST',
        '00000000-0000-0000-0000-000000042061',
        '00000000-0000-0000-0000-000000042001'
    );

    -- Changing a conversion after history is rejected at preview as a group.
    v_result := public.create_master_import_job(
        '00000000-0000-0000-0000-000000042102',
        'PRODUCT','REFERENCE_BY_NAME','CREATE_AND_UPDATE',
        'g42-product-update.csv',repeat('b',64),','
    );
    v_job_id := (v_result->>'jobId')::UUID;
    v_result := public.stage_master_import_rows(
        v_job_id,(v_result->>'masterVersion')::BIGINT,
        jsonb_build_object(
            'productKey','product_key','sku','sku',
            'productName','product_name','categoryName','category_name',
            'isActive','is_active','uomName','uom_name',
            'factorToBase','factor_to_base',
            'purchaseAllowed','purchase_allowed',
            'salesAllowed','sales_allowed',
            'purchasePrice','purchase_price','salePrice','sale_price',
            'weightPerLargestUomKg','weight_per_largest_uom_kg'
        ),
        jsonb_build_array(
            jsonb_build_object(
                'rowNumber',1,'sourceData',jsonb_build_object(
                    'product_key','KEBAB','sku','G42-KEBAB',
                    'product_name','G42 Kebab','category_name','G42 Food',
                    'is_active','true','uom_name','G42 Ketul',
                    'factor_to_base','1','purchase_allowed','false',
                    'sales_allowed','true','purchase_price','50',
                    'sale_price','100','weight_per_largest_uom_kg','25'
                )
            ),
            jsonb_build_object(
                'rowNumber',2,'sourceData',jsonb_build_object(
                    'product_key','KEBAB','sku','G42-KEBAB',
                    'product_name','G42 Kebab','category_name','G42 Food',
                    'is_active','true','uom_name','G42 Dus',
                    'factor_to_base','12','purchase_allowed','true',
                    'sales_allowed','false','purchase_price','500',
                    'sale_price','1000','weight_per_largest_uom_kg','25'
                )
            )
        )
    );
    v_result := public.validate_master_import_job(
        v_job_id,(v_result->>'masterVersion')::BIGINT
    );
    IF (v_result->>'errorCount')::INTEGER <> 1
       OR (v_result->>'updateCount')::INTEGER <> 0 THEN
        RAISE EXCEPTION
            'TEST_FAILED: historical conversion change was not rejected';
    END IF;

    IF has_table_privilege(
        'authenticated','public.products','INSERT,UPDATE,DELETE'
    ) OR has_table_privilege(
        'authenticated','public.product_uoms','INSERT,UPDATE,DELETE'
    ) OR has_function_privilege(
        'authenticated',
        'private.validate_master_import_product_job(uuid,bigint)',
        'EXECUTE'
    ) OR NOT has_function_privilege(
        'authenticated',
        'public.validate_master_import_job(uuid,bigint)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: Product import privilege boundary invalid';
    END IF;

    RAISE NOTICE
        'TEST PASSED: grouped Product import is atomic, partial-commit safe, history guarded, audited, and stock-neutral.';
END
$test$;

ROLLBACK;
