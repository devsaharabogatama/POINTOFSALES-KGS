-- G2 phase 4 behavioral test: Product + Product-UOM is one atomic group.
-- SAFETY: all fixtures, RPC writes, audit rows, and movement are rolled back.

BEGIN;

DO $test$
DECLARE
    v_actor UUID;
    v_product_id UUID;
    v_result JSONB;
    v_version BIGINT;
    v_count BIGINT;
    v_rejected BOOLEAN;
BEGIN
    SELECT p.id INTO v_actor
    FROM public.profiles p
    JOIN auth.users u ON u.id = p.id
    WHERE p.role = 'super_admin'::user_role
    ORDER BY p.id LIMIT 1;

    IF v_actor IS NULL THEN
        RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: linked Super Admin is required';
    END IF;

    INSERT INTO public.companies(
        id,company_code,company_name,company_slug,status
    ) VALUES
        ('00000000-0000-0000-0000-000000012001',
         'G12A','G12 Company A','g12-company-a','ACTIVE'),
        ('00000000-0000-0000-0000-000000012002',
         'G12B','G12 Company B','g12-company-b','ACTIVE');

    INSERT INTO public.product_categories(
        id,company_id,category_code,category_name
    ) VALUES
        ('00000000-0000-0000-0000-000000012011',
         '00000000-0000-0000-0000-000000012001','FOOD','Food'),
        ('00000000-0000-0000-0000-000000012012',
         '00000000-0000-0000-0000-000000012002','FOOD','Food');

    INSERT INTO public.uoms(
        id,company_id,code,name,uom_type,allow_decimal,decimal_precision
    ) VALUES
        ('00000000-0000-0000-0000-000000012021',
         '00000000-0000-0000-0000-000000012001',
         'PCS','Piece','UNIT',FALSE,0),
        ('00000000-0000-0000-0000-000000012022',
         '00000000-0000-0000-0000-000000012001',
         'BOX','Box','PACKAGING',FALSE,0),
        ('00000000-0000-0000-0000-000000012023',
         '00000000-0000-0000-0000-000000012002',
         'PCS','Piece','UNIT',FALSE,0);

    INSERT INTO public.warehouses(
        id,company_id,code,name,warehouse_type
    ) VALUES (
        '00000000-0000-0000-0000-000000012031',
        '00000000-0000-0000-0000-000000012001',
        'WHA','G12 Warehouse A','CENTRAL'
    );

    PERFORM set_config(
        'request.jwt.claims',
        jsonb_build_object('sub',v_actor,'role','authenticated')::TEXT,
        TRUE
    );
    PERFORM public.set_active_company_context(
        '00000000-0000-0000-0000-000000012001','G2_PHASE4_TEST'
    );

    v_result := public.save_product_with_uoms(
        NULL,NULL,'G12-PROD','G12 Product',
        '00000000-0000-0000-0000-000000012011',
        '00000000-0000-0000-0000-000000012021',
        '00000000-0000-0000-0000-000000012022',
        6,FALSE,NULL,TRUE,
        jsonb_build_array(
            jsonb_build_object(
                'uomId','00000000-0000-0000-0000-000000012021',
                'factorToBase',1,
                'purchaseAllowed',TRUE,'salesAllowed',TRUE,
                'purchasePrice',50,'salePrice',100,'isActive',TRUE
            ),
            jsonb_build_object(
                'uomId','00000000-0000-0000-0000-000000012022',
                'factorToBase',12,
                'purchaseAllowed',TRUE,'salesAllowed',TRUE,
                'purchasePrice',550,'salePrice',1100,
                'barcode','G12BOX','isActive',TRUE
            )
        )
    );
    v_product_id := (v_result->>'productId')::UUID;

    SELECT count(*) INTO v_count
    FROM public.products p
    WHERE p.id = v_product_id
      AND p.company_id = '00000000-0000-0000-0000-000000012001'
      AND p.category_id = '00000000-0000-0000-0000-000000012011'
      AND p.uom_id = '00000000-0000-0000-0000-000000012021'
      AND p.weight_reference_uom_id =
          '00000000-0000-0000-0000-000000012022'
      AND p.category = 'Food'
      AND p.uom = 'PCS'
      AND p.price = 100
      AND p.cogs = 50;
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: canonical/legacy Product row invalid';
    END IF;

    SELECT count(*) INTO v_count
    FROM public.product_uoms pu
    WHERE pu.company_id = '00000000-0000-0000-0000-000000012001'
      AND pu.product_id = v_product_id;
    IF v_count <> 2 THEN
        RAISE EXCEPTION 'TEST_FAILED: expected two Product-UOM rows, got %',v_count;
    END IF;

    SELECT count(*) INTO v_count
    FROM public.product_master_audit a
    WHERE a.product_id = v_product_id AND a.action = 'CREATE';
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: create audit missing';
    END IF;

    v_result := public.save_product_with_uoms(
        v_product_id,1,'G12-PROD','G12 Product Updated',
        '00000000-0000-0000-0000-000000012011',
        '00000000-0000-0000-0000-000000012021',
        '00000000-0000-0000-0000-000000012022',
        5,FALSE,'https://example.invalid/product.jpg',TRUE,
        jsonb_build_array(
            jsonb_build_object(
                'uomId','00000000-0000-0000-0000-000000012021',
                'factorToBase',1,
                'purchaseAllowed',TRUE,'salesAllowed',TRUE,
                'purchasePrice',55,'salePrice',105,'isActive',TRUE
            ),
            jsonb_build_object(
                'uomId','00000000-0000-0000-0000-000000012022',
                'factorToBase',10,
                'purchaseAllowed',TRUE,'salesAllowed',TRUE,
                'purchasePrice',500,'salePrice',1000,
                'barcode','G12BOX','isActive',TRUE
            )
        )
    );

    IF (v_result->>'masterVersion')::BIGINT <> 2 THEN
        RAISE EXCEPTION 'TEST_FAILED: Product master version did not increment';
    END IF;
    SELECT conversion_version INTO v_version
    FROM public.product_uoms
    WHERE product_id = v_product_id
      AND uom_id = '00000000-0000-0000-0000-000000012022';
    IF v_version <> 2 THEN
        RAISE EXCEPTION 'TEST_FAILED: conversion version %, expected 2',v_version;
    END IF;

    v_rejected := FALSE;
    BEGIN
        PERFORM public.save_product_with_uoms(
            v_product_id,1,'G12-PROD','Stale Update',
            '00000000-0000-0000-0000-000000012011',
            '00000000-0000-0000-0000-000000012021',
            '00000000-0000-0000-0000-000000012022',
            5,FALSE,NULL,TRUE,
            jsonb_build_array(
                jsonb_build_object(
                    'uomId','00000000-0000-0000-0000-000000012021',
                    'factorToBase',1,'purchaseAllowed',TRUE,
                    'salesAllowed',TRUE,'purchasePrice',55,
                    'salePrice',105,'isActive',TRUE
                ),
                jsonb_build_object(
                    'uomId','00000000-0000-0000-0000-000000012022',
                    'factorToBase',10,'purchaseAllowed',TRUE,
                    'salesAllowed',TRUE,'purchasePrice',500,
                    'salePrice',1000,'isActive',TRUE
                )
            )
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'MASTER_VERSION_CONFLICT' THEN
            v_rejected := TRUE;
        ELSE
            RAISE;
        END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: stale Product update accepted';
    END IF;

    v_rejected := FALSE;
    BEGIN
        PERFORM public.save_product_with_uoms(
            NULL,NULL,'G12-CROSS','Cross Product',
            '00000000-0000-0000-0000-000000012012',
            '00000000-0000-0000-0000-000000012021',
            '00000000-0000-0000-0000-000000012021',
            1,FALSE,NULL,TRUE,
            jsonb_build_array(jsonb_build_object(
                'uomId','00000000-0000-0000-0000-000000012021',
                'factorToBase',1,'purchaseAllowed',TRUE,
                'salesAllowed',TRUE,'purchasePrice',1,
                'salePrice',1,'isActive',TRUE
            ))
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'ACTIVE_PRODUCT_CATEGORY_NOT_FOUND' THEN
            v_rejected := TRUE;
        ELSE
            RAISE;
        END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: cross-Company Category accepted';
    END IF;
    IF EXISTS (SELECT 1 FROM public.products WHERE sku = 'G12-CROSS') THEN
        RAISE EXCEPTION 'TEST_FAILED: rejected Product partially persisted';
    END IF;

    INSERT INTO public.stock_movements(
        product_id,warehouse_id,qty_change,movement_type,
        reference_table,reference_id,company_id
    ) VALUES (
        v_product_id,'00000000-0000-0000-0000-000000012031',1,
        'PURCHASE'::stock_movement_type,'G2_PHASE4_TEST',
        '00000000-0000-0000-0000-000000012061',
        '00000000-0000-0000-0000-000000012001'
    );

    v_rejected := FALSE;
    BEGIN
        PERFORM public.save_product_with_uoms(
            v_product_id,2,'G12-PROD','Forbidden Conversion Update',
            '00000000-0000-0000-0000-000000012011',
            '00000000-0000-0000-0000-000000012021',
            '00000000-0000-0000-0000-000000012022',
            5,FALSE,NULL,TRUE,
            jsonb_build_array(
                jsonb_build_object(
                    'uomId','00000000-0000-0000-0000-000000012021',
                    'factorToBase',1,'purchaseAllowed',TRUE,
                    'salesAllowed',TRUE,'purchasePrice',55,
                    'salePrice',105,'isActive',TRUE
                ),
                jsonb_build_object(
                    'uomId','00000000-0000-0000-0000-000000012022',
                    'factorToBase',12,'purchaseAllowed',TRUE,
                    'salesAllowed',TRUE,'purchasePrice',500,
                    'salePrice',1000,'isActive',TRUE
                )
            )
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'PRODUCT_UOM_CONVERSION_LOCKED_BY_MOVEMENT' THEN
            v_rejected := TRUE;
        ELSE
            RAISE;
        END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: historical conversion changed';
    END IF;

    SELECT master_version INTO v_version
    FROM public.products WHERE id = v_product_id;
    IF v_version <> 2 THEN
        RAISE EXCEPTION 'TEST_FAILED: rejected update partially changed Product';
    END IF;
    SELECT count(*) INTO v_count
    FROM public.product_master_audit WHERE product_id = v_product_id;
    IF v_count <> 2 THEN
        RAISE EXCEPTION 'TEST_FAILED: rejected update wrote audit';
    END IF;

    IF has_table_privilege(
        'authenticated','public.products','INSERT,UPDATE,DELETE'
    ) OR has_table_privilege(
        'authenticated','public.product_uoms','INSERT,UPDATE,DELETE'
    ) OR has_function_privilege(
        'authenticated','public.import_products_for_company(uuid,jsonb)','EXECUTE'
    ) OR NOT has_function_privilege(
        'authenticated',
        'public.save_product_with_uoms(uuid,bigint,text,text,uuid,uuid,uuid,numeric,boolean,text,boolean,jsonb)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: Product write privilege boundary invalid';
    END IF;

    RAISE NOTICE 'TEST PASSED: Product and Product-UOM create/update is atomic, tenant-safe, versioned, and audited.';
END
$test$;

ROLLBACK;
