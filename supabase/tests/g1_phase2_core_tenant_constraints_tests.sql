-- G1 phase 2 behavioral test: forged cross-company references must fail.
-- SAFETY: all fixtures and attempted mutations are inside one transaction and
-- always rolled back.

BEGIN;

DO $test$
DECLARE
    v_actor UUID;
    v_constraint TEXT;
BEGIN
    SELECT p.id INTO v_actor
    FROM public.profiles p
    JOIN auth.users u ON u.id = p.id
    WHERE p.role = 'super_admin'::user_role
    ORDER BY p.id
    LIMIT 1;

    IF v_actor IS NULL THEN
        RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: linked Super Admin is required';
    END IF;

    INSERT INTO public.companies (
        id, company_code, company_name, company_slug, status
    ) VALUES
        ('00000000-0000-0000-0000-000000001001', 'G1C1', 'G1 Company 1', 'g1-company-1', 'ACTIVE'),
        ('00000000-0000-0000-0000-000000001002', 'G1C2', 'G1 Company 2', 'g1-company-2', 'ACTIVE');

    INSERT INTO public.stores (
        id, company_id, store_code, store_name, status
    ) VALUES
        ('00000000-0000-0000-0000-000000001011', '00000000-0000-0000-0000-000000001001', 'S1', 'G1 Store 1', 'ACTIVE'),
        ('00000000-0000-0000-0000-000000001012', '00000000-0000-0000-0000-000000001002', 'S2', 'G1 Store 2', 'ACTIVE');

    INSERT INTO public.warehouses (
        id, company_id, code, name, is_active
    ) VALUES
        ('00000000-0000-0000-0000-000000001021', '00000000-0000-0000-0000-000000001001', 'W1', 'G1 Warehouse 1', TRUE),
        ('00000000-0000-0000-0000-000000001022', '00000000-0000-0000-0000-000000001002', 'W2', 'G1 Warehouse 2', TRUE);

    INSERT INTO public.uoms (
        id, company_id, code, name
    ) VALUES
        ('00000000-0000-0000-0000-000000001031', '00000000-0000-0000-0000-000000001001', 'U1', 'G1 UOM 1'),
        ('00000000-0000-0000-0000-000000001032', '00000000-0000-0000-0000-000000001002', 'U2', 'G1 UOM 2');

    INSERT INTO public.products (
        id, company_id, sku, name, category, price, cogs, uom, uom_id,
        weight_per_uom_kg, is_active, is_bundle
    ) VALUES
        ('00000000-0000-0000-0000-000000001041', '00000000-0000-0000-0000-000000001001', 'G1P1', 'G1 Product 1', 'TEST', 100, 50, 'U1', '00000000-0000-0000-0000-000000001031', 1, TRUE, TRUE),
        ('00000000-0000-0000-0000-000000001042', '00000000-0000-0000-0000-000000001002', 'G1P2', 'G1 Product 2', 'TEST', 100, 50, 'U2', '00000000-0000-0000-0000-000000001032', 1, TRUE, FALSE);

    -- POS Company 1 cannot reference Store Company 2.
    BEGIN
        INSERT INTO public.pos_terminals (
            id, company_id, store_id, pos_code, pos_name, status
        ) VALUES (
            '00000000-0000-0000-0000-000000001051',
            '00000000-0000-0000-0000-000000001001',
            '00000000-0000-0000-0000-000000001012',
            'P1', 'Forged POS', 'ACTIVE'
        );
        RAISE EXCEPTION 'TEST_FAILED: forged POS store was accepted';
    EXCEPTION WHEN foreign_key_violation THEN
        GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
        IF v_constraint <> 'fk_pos_terminals_company_store' THEN
            RAISE EXCEPTION 'TEST_FAILED: unexpected POS constraint %', v_constraint;
        END IF;
    END;

    -- Store membership Company 1 cannot reference Store Company 2.
    BEGIN
        INSERT INTO public.store_memberships (
            company_id, store_id, user_id, role_code, status
        ) VALUES (
            '00000000-0000-0000-0000-000000001001',
            '00000000-0000-0000-0000-000000001012',
            v_actor,
            'CASHIER',
            'ACTIVE'
        );
        RAISE EXCEPTION 'TEST_FAILED: forged Store membership was accepted';
    EXCEPTION WHEN foreign_key_violation THEN
        GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
        IF v_constraint <> 'fk_store_memberships_company_store' THEN
            RAISE EXCEPTION 'TEST_FAILED: unexpected membership constraint %', v_constraint;
        END IF;
    END;

    -- Product Company 1 cannot reference UOM Company 2.
    BEGIN
        INSERT INTO public.products (
            id, company_id, sku, name, price, cogs, uom, uom_id,
            weight_per_uom_kg, is_active, is_bundle
        ) VALUES (
            '00000000-0000-0000-0000-000000001043',
            '00000000-0000-0000-0000-000000001001',
            'G1PX', 'Forged Product', 100, 50, 'U2',
            '00000000-0000-0000-0000-000000001032', 1, TRUE, FALSE
        );
        RAISE EXCEPTION 'TEST_FAILED: forged Product UOM was accepted';
    EXCEPTION WHEN foreign_key_violation THEN
        GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
        IF v_constraint <> 'fk_products_company_uom' THEN
            RAISE EXCEPTION 'TEST_FAILED: unexpected Product constraint %', v_constraint;
        END IF;
    END;

    -- Bundle Company 1 cannot contain Product Company 2.
    BEGIN
        INSERT INTO public.product_bundle_items (
            company_id, bundle_id, item_id, qty
        ) VALUES (
            '00000000-0000-0000-0000-000000001001',
            '00000000-0000-0000-0000-000000001041',
            '00000000-0000-0000-0000-000000001042',
            1
        );
        RAISE EXCEPTION 'TEST_FAILED: forged Bundle item was accepted';
    EXCEPTION WHEN foreign_key_violation THEN
        GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
        IF v_constraint <> 'fk_bundle_items_company_item' THEN
            RAISE EXCEPTION 'TEST_FAILED: unexpected Bundle constraint %', v_constraint;
        END IF;
    END;

    -- Stock Company 1 cannot use Warehouse Company 2.
    BEGIN
        INSERT INTO public.product_stocks (
            company_id, product_id, warehouse_id, stock_qty
        ) VALUES (
            '00000000-0000-0000-0000-000000001001',
            '00000000-0000-0000-0000-000000001041',
            '00000000-0000-0000-0000-000000001022',
            1
        );
        RAISE EXCEPTION 'TEST_FAILED: forged Product stock was accepted';
    EXCEPTION WHEN foreign_key_violation THEN
        GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
        IF v_constraint <> 'fk_product_stocks_company_warehouse' THEN
            RAISE EXCEPTION 'TEST_FAILED: unexpected Stock constraint %', v_constraint;
        END IF;
    END;

    -- Conversion Company 1 cannot use target UOM Company 2.
    BEGIN
        INSERT INTO public.product_uom_conversions (
            company_id, product_id, from_uom_id, to_uom_id, conversion_factor
        ) VALUES (
            '00000000-0000-0000-0000-000000001001',
            '00000000-0000-0000-0000-000000001041',
            '00000000-0000-0000-0000-000000001031',
            '00000000-0000-0000-0000-000000001032',
            12
        );
        RAISE EXCEPTION 'TEST_FAILED: forged UOM conversion was accepted';
    EXCEPTION WHEN foreign_key_violation THEN
        GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
        IF v_constraint <> 'fk_uom_conversions_company_to' THEN
            RAISE EXCEPTION 'TEST_FAILED: unexpected conversion constraint %', v_constraint;
        END IF;
    END;

    -- Batch Company 1 cannot use Warehouse Company 2.
    BEGIN
        INSERT INTO public.product_batches (
            company_id, product_id, warehouse_id,
            qty_purchased, qty_remaining, cogs_unit
        ) VALUES (
            '00000000-0000-0000-0000-000000001001',
            '00000000-0000-0000-0000-000000001041',
            '00000000-0000-0000-0000-000000001022',
            1, 1, 50
        );
        RAISE EXCEPTION 'TEST_FAILED: forged Product batch was accepted';
    EXCEPTION WHEN foreign_key_violation THEN
        GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
        IF v_constraint <> 'fk_product_batches_company_warehouse' THEN
            RAISE EXCEPTION 'TEST_FAILED: unexpected Batch constraint %', v_constraint;
        END IF;
    END;

    RAISE NOTICE 'TEST PASSED: core cross-company references were rejected by composite foreign keys.';
END
$test$;

ROLLBACK;
