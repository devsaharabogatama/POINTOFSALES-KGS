-- G2 phase 1 behavioral test: tenant master, version, and UOM history guard.
-- SAFETY: every fixture and mutation is rolled back.

BEGIN;

DO $test$
DECLARE
    v_super_admin UUID;
    v_version BIGINT;
    v_constraint TEXT;
    v_rejected BOOLEAN;
BEGIN
    SELECT p.id INTO v_super_admin
    FROM public.profiles p
    JOIN auth.users u ON u.id = p.id
    WHERE p.role = 'super_admin'::user_role
    ORDER BY p.id LIMIT 1;

    IF v_super_admin IS NULL THEN
        RAISE EXCEPTION
            'TEST_PRECONDITION_FAILED: linked Super Admin is required';
    END IF;

    INSERT INTO public.companies(
        id,company_code,company_name,company_slug,status
    ) VALUES
        ('00000000-0000-0000-0000-000000011001',
         'G11A','G11 Company A','g11-company-a','ACTIVE'),
        ('00000000-0000-0000-0000-000000011002',
         'G11B','G11 Company B','g11-company-b','ACTIVE');

    INSERT INTO public.product_categories(
        id,company_id,category_code,category_name
    ) VALUES
        ('00000000-0000-0000-0000-000000011011',
         '00000000-0000-0000-0000-000000011001','FOOD','Food'),
        ('00000000-0000-0000-0000-000000011012',
         '00000000-0000-0000-0000-000000011002','FOOD','Food');

    v_rejected := FALSE;
    BEGIN
        INSERT INTO public.product_categories(
            company_id,category_code,category_name
        ) VALUES (
            '00000000-0000-0000-0000-000000011001','FOOD-2','  fOoD  '
        );
    EXCEPTION WHEN unique_violation THEN
        v_rejected := TRUE;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION
            'TEST_FAILED: normalized duplicate Category name was accepted';
    END IF;

    INSERT INTO public.uoms(
        id,company_id,code,name,uom_type,allow_decimal,decimal_precision
    ) VALUES
        ('00000000-0000-0000-0000-000000011021',
         '00000000-0000-0000-0000-000000011001',
         'PCS','Piece','UNIT',FALSE,0),
        ('00000000-0000-0000-0000-000000011022',
         '00000000-0000-0000-0000-000000011001',
         'BOX','Box','PACKAGING',FALSE,0),
        ('00000000-0000-0000-0000-000000011023',
         '00000000-0000-0000-0000-000000011002',
         'PCS','Piece','UNIT',FALSE,0);

    INSERT INTO public.warehouses(
        id,company_id,code,name,warehouse_type
    ) VALUES (
        '00000000-0000-0000-0000-000000011031',
        '00000000-0000-0000-0000-000000011001',
        'WHA','G11 Warehouse A','CENTRAL'
    );

    INSERT INTO public.products(
        id,company_id,sku,name,category,category_id,
        price,cogs,uom,uom_id,weight_reference_uom_id,
        weight_per_uom_kg,is_active,is_bundle
    ) VALUES
        ('00000000-0000-0000-0000-000000011041',
         '00000000-0000-0000-0000-000000011001',
         'G11PA','G11 Product A','Food',
         '00000000-0000-0000-0000-000000011011',
         100,50,'PCS','00000000-0000-0000-0000-000000011021',
         '00000000-0000-0000-0000-000000011022',1,TRUE,FALSE),
        ('00000000-0000-0000-0000-000000011042',
         '00000000-0000-0000-0000-000000011002',
         'G11PB','G11 Product B','Food',
         '00000000-0000-0000-0000-000000011012',
         100,50,'PCS','00000000-0000-0000-0000-000000011023',
         '00000000-0000-0000-0000-000000011023',1,TRUE,FALSE);

    INSERT INTO public.product_uoms(
        id,company_id,product_id,uom_id,factor_to_base,
        purchase_allowed,sales_allowed,purchase_price,sale_price
    ) VALUES
        ('00000000-0000-0000-0000-000000011051',
         '00000000-0000-0000-0000-000000011001',
         '00000000-0000-0000-0000-000000011041',
         '00000000-0000-0000-0000-000000011021',1,
         TRUE,TRUE,50,100),
        ('00000000-0000-0000-0000-000000011052',
         '00000000-0000-0000-0000-000000011001',
         '00000000-0000-0000-0000-000000011041',
         '00000000-0000-0000-0000-000000011022',12,
         TRUE,TRUE,550,1100);

    UPDATE public.product_uoms
    SET factor_to_base = 10
    WHERE id = '00000000-0000-0000-0000-000000011052';

    SELECT conversion_version INTO v_version
    FROM public.product_uoms
    WHERE id = '00000000-0000-0000-0000-000000011052';
    IF v_version <> 2 THEN
        RAISE EXCEPTION
            'TEST_FAILED: conversion version %, expected 2',v_version;
    END IF;

    v_rejected := FALSE;
    BEGIN
        INSERT INTO public.product_uoms(
            company_id,product_id,uom_id,factor_to_base,
            purchase_allowed,sales_allowed,purchase_price,sale_price
        ) VALUES (
            '00000000-0000-0000-0000-000000011001',
            '00000000-0000-0000-0000-000000011042',
            '00000000-0000-0000-0000-000000011022',1,
            TRUE,TRUE,1,1
        );
    EXCEPTION WHEN foreign_key_violation THEN
        GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
        IF v_constraint <> 'fk_product_uoms_company_product' THEN
            RAISE EXCEPTION
                'TEST_FAILED: unexpected cross-Company constraint %',v_constraint;
        END IF;
        v_rejected := TRUE;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION
            'TEST_FAILED: cross-Company Product UOM was accepted';
    END IF;

    v_rejected := FALSE;
    BEGIN
        UPDATE public.product_uoms
        SET factor_to_base = 2
        WHERE id = '00000000-0000-0000-0000-000000011051';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'BASE_UOM_FACTOR_MUST_EQUAL_ONE' THEN
            v_rejected := TRUE;
        ELSE
            RAISE;
        END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION
            'TEST_FAILED: base Product UOM accepted factor other than one';
    END IF;

    INSERT INTO public.stock_movements(
        product_id,warehouse_id,qty_change,movement_type,
        reference_table,reference_id,company_id
    ) VALUES (
        '00000000-0000-0000-0000-000000011041',
        '00000000-0000-0000-0000-000000011031',1,
        'PURCHASE'::stock_movement_type,'G2_PHASE1_TEST',
        '00000000-0000-0000-0000-000000011061',
        '00000000-0000-0000-0000-000000011001'
    );

    v_rejected := FALSE;
    BEGIN
        UPDATE public.product_uoms
        SET factor_to_base = 12
        WHERE id = '00000000-0000-0000-0000-000000011052';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'PRODUCT_UOM_CONVERSION_LOCKED_BY_MOVEMENT' THEN
            v_rejected := TRUE;
        ELSE
            RAISE;
        END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION
            'TEST_FAILED: historical conversion factor was changed';
    END IF;

    v_rejected := FALSE;
    BEGIN
        UPDATE public.products
        SET uom_id = '00000000-0000-0000-0000-000000011022'
        WHERE id = '00000000-0000-0000-0000-000000011041';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'PRODUCT_BASE_UOM_LOCKED_BY_MOVEMENT' THEN
            v_rejected := TRUE;
        ELSE
            RAISE;
        END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION
            'TEST_FAILED: Product base UOM changed after movement';
    END IF;

    PERFORM set_config(
        'request.jwt.claims',
        jsonb_build_object(
            'sub',v_super_admin,'role','authenticated'
        )::text,
        TRUE
    );
END
$test$;

SET LOCAL ROLE authenticated;

DO $rls_test$
DECLARE
    v_count BIGINT;
    v_version BIGINT;
BEGIN
    PERFORM public.set_active_company_context(
        '00000000-0000-0000-0000-000000011001','G2_PHASE1_TEST'
    );

    SELECT count(*) INTO v_count FROM public.product_categories;
    IF v_count <> 1 THEN
        RAISE EXCEPTION
            'TEST_FAILED: Super Admin saw % Categories, expected 1',v_count;
    END IF;

    SELECT count(*) INTO v_count FROM public.product_uoms;
    IF v_count <> 2 THEN
        RAISE EXCEPTION
            'TEST_FAILED: Super Admin saw % Product UOM rows, expected 2',v_count;
    END IF;

    UPDATE public.product_categories
    SET category_name = 'Food Updated'
    WHERE id = '00000000-0000-0000-0000-000000011011';

    SELECT master_version INTO v_version
    FROM public.product_categories
    WHERE id = '00000000-0000-0000-0000-000000011011';
    IF v_version <> 2 THEN
        RAISE EXCEPTION
            'TEST_FAILED: master version %, expected 2',v_version;
    END IF;

    IF has_table_privilege(
        'authenticated','public.product_categories','DELETE'
    ) OR has_table_privilege(
        'anon','public.product_categories','SELECT'
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: unsafe new-master privilege exists';
    END IF;

    RAISE NOTICE
        'TEST PASSED: G2 master foundation is tenant-scoped, versioned, and protects historical UOM conversion.';
END
$rls_test$;

RESET ROLE;
ROLLBACK;
