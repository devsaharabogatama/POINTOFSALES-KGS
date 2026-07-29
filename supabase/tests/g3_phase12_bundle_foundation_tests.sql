-- G3 phase 12 behavioral test: atomic Bundle composition and availability.
-- SAFETY: every fixture, audit row, and Bundle mutation is rolled back.

BEGIN;

DO $test$
DECLARE
    v_actor UUID;
    v_bundle_id UUID;
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
        ('00000000-0000-0000-0000-000000014001',
         'G14A','G14 Company A','g14-company-a','ACTIVE'),
        ('00000000-0000-0000-0000-000000014002',
         'G14B','G14 Company B','g14-company-b','ACTIVE');

    INSERT INTO public.product_categories(
        id,company_id,category_code,category_name
    ) VALUES
        ('00000000-0000-0000-0000-000000014011',
         '00000000-0000-0000-0000-000000014001','BND','Bundle'),
        ('00000000-0000-0000-0000-000000014012',
         '00000000-0000-0000-0000-000000014002','BND','Bundle');

    INSERT INTO public.uoms(id,company_id,code,name) VALUES
        ('00000000-0000-0000-0000-000000014021',
         '00000000-0000-0000-0000-000000014001','KTL','Ketul'),
        ('00000000-0000-0000-0000-000000014022',
         '00000000-0000-0000-0000-000000014001','PCS','Piece'),
        ('00000000-0000-0000-0000-000000014023',
         '00000000-0000-0000-0000-000000014001','PAK','Paket'),
        ('00000000-0000-0000-0000-000000014024',
         '00000000-0000-0000-0000-000000014002','PCS','Piece');

    INSERT INTO public.products(
        id,company_id,sku,name,category,category_id,price,cogs,uom,uom_id,
        weight_reference_uom_id,weight_per_uom_kg,is_active,is_bundle
    ) VALUES
        ('00000000-0000-0000-0000-000000014031',
         '00000000-0000-0000-0000-000000014001','G14-K','Kebab',
         'Bundle','00000000-0000-0000-0000-000000014011',
         100,50,'KTL','00000000-0000-0000-0000-000000014021',
         '00000000-0000-0000-0000-000000014021',2.1,TRUE,FALSE),
        ('00000000-0000-0000-0000-000000014032',
         '00000000-0000-0000-0000-000000014001','G14-D','Drink',
         'Bundle','00000000-0000-0000-0000-000000014011',
         50,20,'PCS','00000000-0000-0000-0000-000000014022',
         '00000000-0000-0000-0000-000000014022',0.5,TRUE,FALSE),
        ('00000000-0000-0000-0000-000000014033',
         '00000000-0000-0000-0000-000000014002','G14-X','Foreign',
         'Bundle','00000000-0000-0000-0000-000000014012',
         10,5,'PCS','00000000-0000-0000-0000-000000014024',
         '00000000-0000-0000-0000-000000014024',1,TRUE,FALSE);

    INSERT INTO public.product_uoms(
        company_id,product_id,uom_id,factor_to_base,
        purchase_allowed,sales_allowed,purchase_price,sale_price
    ) VALUES
        ('00000000-0000-0000-0000-000000014001',
         '00000000-0000-0000-0000-000000014031',
         '00000000-0000-0000-0000-000000014021',1,TRUE,TRUE,50,100),
        ('00000000-0000-0000-0000-000000014001',
         '00000000-0000-0000-0000-000000014032',
         '00000000-0000-0000-0000-000000014022',1,TRUE,TRUE,20,50),
        ('00000000-0000-0000-0000-000000014002',
         '00000000-0000-0000-0000-000000014033',
         '00000000-0000-0000-0000-000000014024',1,TRUE,TRUE,5,10);

    INSERT INTO public.warehouses(
        id,company_id,code,name,warehouse_type,is_sale_source
    ) VALUES (
        '00000000-0000-0000-0000-000000014041',
        '00000000-0000-0000-0000-000000014001',
        'G14W','G14 Warehouse','CENTRAL',TRUE
    );
    INSERT INTO public.product_stocks(
        company_id,product_id,warehouse_id,stock_qty
    ) VALUES
        ('00000000-0000-0000-0000-000000014001',
         '00000000-0000-0000-0000-000000014031',
         '00000000-0000-0000-0000-000000014041',10),
        ('00000000-0000-0000-0000-000000014001',
         '00000000-0000-0000-0000-000000014032',
         '00000000-0000-0000-0000-000000014041',3);

    PERFORM set_config(
        'request.jwt.claims',
        jsonb_build_object('sub',v_actor,'role','authenticated')::TEXT,TRUE
    );
    PERFORM public.set_active_company_context(
        '00000000-0000-0000-0000-000000014001','G3_PHASE12_TEST'
    );

    v_result := public.save_bundle_with_components(
        NULL,NULL,'G14-B','G14 Paket',
        '00000000-0000-0000-0000-000000014011',
        '00000000-0000-0000-0000-000000014023',
        4000,'G14PAK',NULL,TRUE,
        jsonb_build_array(
            jsonb_build_object(
                'productId','00000000-0000-0000-0000-000000014031',
                'uomId','00000000-0000-0000-0000-000000014021',
                'quantity',2
            ),
            jsonb_build_object(
                'productId','00000000-0000-0000-0000-000000014032',
                'uomId','00000000-0000-0000-0000-000000014022',
                'quantity',1
            )
        )
    );
    v_bundle_id := (v_result->>'bundleId')::UUID;

    IF (v_result->>'derivedWeightKg')::NUMERIC <> 4.700 THEN
        RAISE EXCEPTION 'TEST_FAILED: Bundle derived weight invalid';
    END IF;
    SELECT count(*) INTO v_count
    FROM public.products p
    WHERE p.id = v_bundle_id
      AND p.is_bundle
      AND p.price = 4000
      AND p.cogs = 0
      AND p.weight_per_uom_kg = 4.700;
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: canonical Bundle Product invalid';
    END IF;
    SELECT count(*) INTO v_count
    FROM public.product_bundle_items
    WHERE bundle_id = v_bundle_id
      AND qty = component_qty;
    IF v_count <> 2 THEN
        RAISE EXCEPTION 'TEST_FAILED: Bundle composition invalid';
    END IF;
    SELECT count(*) INTO v_count
    FROM public.product_uoms
    WHERE product_id = v_bundle_id
      AND is_active
      AND sales_allowed
      AND NOT purchase_allowed
      AND factor_to_base = 1
      AND sale_price = 4000;
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: Bundle commercial UOM invalid';
    END IF;
    IF (
        public.get_bundle_availability(
            v_bundle_id,'00000000-0000-0000-0000-000000014041'
        )->>'availableQuantity'
    )::BIGINT <> 3 THEN
        RAISE EXCEPTION 'TEST_FAILED: limiting component availability invalid';
    END IF;
    IF EXISTS (
        SELECT 1 FROM public.product_stocks WHERE product_id = v_bundle_id
        UNION ALL
        SELECT 1 FROM public.stock_movements WHERE product_id = v_bundle_id
        UNION ALL
        SELECT 1 FROM public.product_batches WHERE product_id = v_bundle_id
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: Bundle received physical stock';
    END IF;

    v_rejected := FALSE;
    BEGIN
        INSERT INTO public.product_stocks(
            company_id,product_id,warehouse_id,stock_qty
        ) VALUES (
            '00000000-0000-0000-0000-000000014001',
            v_bundle_id,
            '00000000-0000-0000-0000-000000014041',1
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'BUNDLE_PHYSICAL_STOCK_NOT_ALLOWED' THEN
            v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: direct Bundle stock accepted';
    END IF;

    v_result := public.save_bundle_with_components(
        v_bundle_id,1,'G14-B','G14 Paket Updated',
        '00000000-0000-0000-0000-000000014011',
        '00000000-0000-0000-0000-000000014023',
        4500,'G14PAK',NULL,TRUE,
        jsonb_build_array(
            jsonb_build_object(
                'productId','00000000-0000-0000-0000-000000014031',
                'uomId','00000000-0000-0000-0000-000000014021',
                'quantity',1
            ),
            jsonb_build_object(
                'productId','00000000-0000-0000-0000-000000014032',
                'uomId','00000000-0000-0000-0000-000000014022',
                'quantity',1
            )
        )
    );
    IF (v_result->>'masterVersion')::BIGINT <> 2
       OR (v_result->>'derivedWeightKg')::NUMERIC <> 2.600 THEN
        RAISE EXCEPTION 'TEST_FAILED: Bundle update/version invalid';
    END IF;

    SELECT count(*) INTO v_count
    FROM public.product_bundle_master_audit
    WHERE bundle_id = v_bundle_id;
    IF v_count <> 2 THEN
        RAISE EXCEPTION 'TEST_FAILED: Bundle audit missing';
    END IF;
    SELECT count(*) INTO v_count
    FROM public.product_master_audit
    WHERE product_id = v_bundle_id;
    IF v_count <> 2 THEN
        RAISE EXCEPTION 'TEST_FAILED: Product audit missing for Bundle';
    END IF;

    v_rejected := FALSE;
    BEGIN
        PERFORM public.save_bundle_with_components(
            v_bundle_id,1,'G14-B','Stale',
            '00000000-0000-0000-0000-000000014011',
            '00000000-0000-0000-0000-000000014023',
            1,NULL,NULL,TRUE,
            jsonb_build_array(jsonb_build_object(
                'productId','00000000-0000-0000-0000-000000014031',
                'uomId','00000000-0000-0000-0000-000000014021',
                'quantity',1
            ))
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'MASTER_VERSION_CONFLICT' THEN v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: stale Bundle update accepted';
    END IF;

    v_rejected := FALSE;
    BEGIN
        PERFORM public.save_bundle_with_components(
            NULL,NULL,'G14-N','Nested',
            '00000000-0000-0000-0000-000000014011',
            '00000000-0000-0000-0000-000000014023',
            1,NULL,NULL,TRUE,
            jsonb_build_array(jsonb_build_object(
                'productId',v_bundle_id,
                'uomId','00000000-0000-0000-0000-000000014023',
                'quantity',1
            ))
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'NESTED_BUNDLE_NOT_ALLOWED' THEN v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: nested Bundle accepted';
    END IF;

    v_rejected := FALSE;
    BEGIN
        PERFORM public.save_bundle_with_components(
            NULL,NULL,'G14-X','Cross Company',
            '00000000-0000-0000-0000-000000014011',
            '00000000-0000-0000-0000-000000014023',
            1,NULL,NULL,TRUE,
            jsonb_build_array(jsonb_build_object(
                'productId','00000000-0000-0000-0000-000000014033',
                'uomId','00000000-0000-0000-0000-000000014024',
                'quantity',1
            ))
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'ACTIVE_STOCK_COMPONENT_UOM_NOT_FOUND' THEN
            v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: cross-Company component accepted';
    END IF;

    v_rejected := FALSE;
    BEGIN
        UPDATE public.products SET is_bundle = FALSE WHERE id = v_bundle_id;
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'PRODUCT_TYPE_IMMUTABLE' THEN v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: Product type changed';
    END IF;

    IF has_table_privilege(
        'authenticated','public.product_bundle_items','INSERT,UPDATE,DELETE'
    ) OR NOT has_function_privilege(
        'authenticated',
        'public.save_bundle_with_components(uuid,bigint,text,text,uuid,uuid,numeric,text,text,boolean,jsonb)',
        'EXECUTE'
    ) OR has_function_privilege(
        'authenticated',
        'private.resolve_bundle_components(uuid,uuid,numeric)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: Bundle privilege boundary invalid';
    END IF;

    RAISE NOTICE 'TEST PASSED: Bundle save is atomic, tenant-safe, non-nested, versioned, audited, virtual-stock-only, and availability is component-limited.';
END
$test$;

ROLLBACK;
