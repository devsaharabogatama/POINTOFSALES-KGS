-- G2 phase 12 behavioral test: guarded and versioned Pricelist writes.
-- SAFETY: all Company, master, rule, and audit fixtures are rolled back.

BEGIN;

DO $test$
DECLARE
    v_actor UUID;
    v_company CONSTANT UUID := '00000000-0000-0000-0000-000000016001';
    v_category CONSTANT UUID := '00000000-0000-0000-0000-000000016011';
    v_uom CONSTANT UUID := '00000000-0000-0000-0000-000000016021';
    v_product CONSTANT UUID := '00000000-0000-0000-0000-000000016031';
    v_product_2 CONSTANT UUID := '00000000-0000-0000-0000-000000016032';
    v_product_uom UUID;
    v_customer UUID;
    v_walk_in UUID;
    v_pricelist UUID;
    v_customer_pricelist UUID;
    v_result JSONB;
    v_count BIGINT;
    v_version BIGINT;
    v_constraint TEXT;
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
    ) VALUES (
        v_company,'G16A','G16 Company A','g16-company-a','ACTIVE'
    );

    SELECT id INTO v_walk_in FROM public.customers
    WHERE company_id = v_company AND is_system_customer;
    IF v_walk_in IS NULL OR NOT EXISTS (
        SELECT 1 FROM public.pricelists
        WHERE company_id = v_company AND scope = 'GLOBAL'
          AND is_default AND is_active AND name = 'Harga Umum'
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: Company defaults were not provisioned';
    END IF;

    INSERT INTO public.product_categories(
        id,company_id,category_code,category_name
    ) VALUES (v_category,v_company,'FOOD','Food');
    INSERT INTO public.uoms(id,company_id,code,name)
    VALUES (v_uom,v_company,'KTL','Ketul');
    INSERT INTO public.products(
        id,company_id,sku,name,category,category_id,price,cogs,uom,uom_id,
        weight_reference_uom_id,weight_per_uom_kg,is_active,is_bundle
    ) VALUES (
        v_product,v_company,'G16-P','G16 Product','Food',v_category,
        100,50,'KTL',v_uom,v_uom,2.1,TRUE,FALSE
    );
    INSERT INTO public.products(
        id,company_id,sku,name,category,category_id,price,cogs,uom,uom_id,
        weight_reference_uom_id,weight_per_uom_kg,is_active,is_bundle
    ) VALUES (
        v_product_2,v_company,'G16-P2','G16 Product 2','Food',v_category,
        100,50,'KTL',v_uom,v_uom,1,TRUE,FALSE
    );
    INSERT INTO public.product_uoms(
        company_id,product_id,uom_id,factor_to_base,purchase_allowed,
        sales_allowed,purchase_price,sale_price
    ) VALUES (v_company,v_product,v_uom,1,TRUE,TRUE,50,100)
    RETURNING id INTO v_product_uom;

    PERFORM set_config(
        'request.jwt.claims',
        jsonb_build_object('sub',v_actor,'role','authenticated')::TEXT,TRUE
    );
    PERFORM public.set_active_company_context(v_company,'G2_PHASE12_TEST');

    v_result := public.save_customer(
        NULL,NULL,NULL,'G16 Customer',(
            SELECT id FROM public.customer_categories
            WHERE company_id = v_company AND is_system_category
        ),NULL,NULL,NULL,'BUSINESS',0,NULL,NULL,TRUE
    );
    v_customer := (v_result->>'customerId')::UUID;

    v_result := public.save_pricelist_with_rules(
        NULL,NULL,'G16-BULK','Harga Grosir','GLOBAL',NULL,10,FALSE,
        TRUE,NULL,NULL,NULL,TRUE,'Global tier test',
        jsonb_build_array(jsonb_build_object(
            'productId',v_product,'productUomId',v_product_uom,
            'minQty',5,'tierQtyBasis','SALES_UOM',
            'pricingMethod','DISCOUNT_AMOUNT','discountAmountPerUnit',10,
            'isActive',TRUE
        ))
    );
    v_pricelist := (v_result->>'pricelistId')::UUID;

    SELECT count(*) INTO v_count
    FROM public.pricelist_rules
    WHERE company_id = v_company AND pricelist_id = v_pricelist
      AND product_id = v_product AND product_uom_id = v_product_uom
      AND min_qty = 5 AND discount_amount_per_unit = 10
      AND rule_version = 1 AND is_active;
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: Global tier rule invalid';
    END IF;

    BEGIN
        INSERT INTO public.pricelist_rules(
            company_id,pricelist_id,product_id,product_uom_id,min_qty,
            pricing_method,fixed_unit_price
        ) VALUES (
            v_company,v_pricelist,v_product_2,v_product_uom,99,
            'FIXED_PRICE',1
        );
        RAISE EXCEPTION 'TEST_FAILED: mismatched Product-UOM rule accepted';
    EXCEPTION WHEN foreign_key_violation THEN
        GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
        IF v_constraint <> 'fk_pricelist_rules_product_uom' THEN
            RAISE EXCEPTION
                'TEST_FAILED: unexpected Product-UOM constraint %',v_constraint;
        END IF;
    END;

    v_result := public.save_pricelist_with_rules(
        NULL,NULL,'G16-CUST','Harga Customer G16','CUSTOMER',v_customer,
        100,TRUE,TRUE,NULL,NULL,NULL,TRUE,NULL,
        jsonb_build_array(jsonb_build_object(
            'productId',v_product,'productUomId',v_product_uom,
            'minQty',1,'tierQtyBasis','SALES_UOM',
            'pricingMethod','FIXED_PRICE','fixedUnitPrice',80,
            'isActive',TRUE
        ))
    );
    v_customer_pricelist := (v_result->>'pricelistId')::UUID;

    v_result := public.save_pricelist_with_rules(
        v_customer_pricelist,1,'G16-CUST','Harga Customer G16 Updated',
        'CUSTOMER',v_customer,100,TRUE,TRUE,NULL,NULL,NULL,TRUE,NULL,
        jsonb_build_array(jsonb_build_object(
            'productId',v_product,'productUomId',v_product_uom,
            'minQty',1,'tierQtyBasis','SALES_UOM',
            'pricingMethod','FIXED_PRICE','fixedUnitPrice',75,
            'isActive',TRUE
        ))
    );
    IF (v_result->>'masterVersion')::BIGINT <> 2 THEN
        RAISE EXCEPTION 'TEST_FAILED: Pricelist master version did not increment';
    END IF;
    SELECT rule_version INTO v_version
    FROM public.pricelist_rules
    WHERE company_id = v_company
      AND pricelist_id = v_customer_pricelist
      AND is_active;
    IF v_version <> 2 THEN
        RAISE EXCEPTION 'TEST_FAILED: Rule version %, expected 2',v_version;
    END IF;
    SELECT count(*) INTO v_count
    FROM public.pricelist_rules
    WHERE company_id = v_company
      AND pricelist_id = v_customer_pricelist;
    IF v_count <> 2 THEN
        RAISE EXCEPTION 'TEST_FAILED: historical rule row was not preserved';
    END IF;

    v_rejected := FALSE;
    BEGIN
        PERFORM public.save_pricelist_with_rules(
            v_customer_pricelist,1,'G16-CUST','Stale Update','CUSTOMER',
            v_customer,100,TRUE,TRUE,NULL,NULL,NULL,TRUE,NULL,'[]'::JSONB
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'MASTER_VERSION_CONFLICT' THEN v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: stale Pricelist update accepted';
    END IF;

    v_rejected := FALSE;
    BEGIN
        PERFORM public.save_pricelist_with_rules(
            NULL,NULL,'G16-TIER-C','Invalid Customer Tier','CUSTOMER',
            v_customer,0,FALSE,TRUE,NULL,NULL,NULL,TRUE,NULL,
            jsonb_build_array(jsonb_build_object(
                'productId',v_product,'productUomId',v_product_uom,
                'minQty',2,'pricingMethod','FIXED_PRICE','fixedUnitPrice',70
            ))
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'CUSTOMER_PRICELIST_TIER_NOT_ALLOWED' THEN
            v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected OR EXISTS (
        SELECT 1 FROM public.pricelists
        WHERE company_id = v_company AND code = 'G16-TIER-C'
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: invalid Customer tier partially persisted';
    END IF;

    v_rejected := FALSE;
    BEGIN
        PERFORM public.save_pricelist_with_rules(
            NULL,NULL,'G16-NOVALUE','Missing Price Value','GLOBAL',NULL,
            0,FALSE,TRUE,NULL,NULL,NULL,TRUE,NULL,
            jsonb_build_array(jsonb_build_object(
                'productId',v_product,'productUomId',v_product_uom,
                'minQty',1,'pricingMethod','FIXED_PRICE'
            ))
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'INVALID_PRICELIST_RULE_VALUE' THEN
            v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected OR EXISTS (
        SELECT 1 FROM public.pricelists
        WHERE company_id = v_company AND code = 'G16-NOVALUE'
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: valueless price rule partially persisted';
    END IF;

    v_rejected := FALSE;
    BEGIN
        PERFORM public.save_pricelist_with_rules(
            NULL,NULL,'G16-WALK','Walk-In Exclusive','CUSTOMER',v_walk_in,
            0,FALSE,TRUE,NULL,NULL,NULL,TRUE,NULL,'[]'::JSONB
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'ACTIVE_REGULAR_CUSTOMER_NOT_FOUND' THEN
            v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: system Walk-In accepted as exclusive scope';
    END IF;

    v_rejected := FALSE;
    BEGIN
        PERFORM public.save_pricelist_with_rules(
            NULL,NULL,'G16-DEFAULT-2','Second Default','GLOBAL',NULL,
            0,TRUE,TRUE,NULL,NULL,NULL,TRUE,NULL,'[]'::JSONB
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'DUPLICATE_OR_DEFAULT_PRICELIST_CONFLICT' THEN
            v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: second active Global default accepted';
    END IF;

    SELECT count(*) INTO v_count FROM public.pricelist_master_audit
    WHERE company_id = v_company
      AND pricelist_id IN (v_pricelist,v_customer_pricelist);
    IF v_count <> 3 THEN
        RAISE EXCEPTION 'TEST_FAILED: expected 3 audit rows, got %',v_count;
    END IF;

    IF has_table_privilege(
        'authenticated','public.pricelists','INSERT,UPDATE,DELETE'
    ) OR has_table_privilege(
        'authenticated','public.pricelist_rules','INSERT,UPDATE,DELETE'
    ) OR NOT has_function_privilege(
        'authenticated',
        'public.save_pricelist_with_rules(uuid,bigint,text,text,text,uuid,integer,boolean,boolean,uuid[],timestamp with time zone,timestamp with time zone,boolean,text,jsonb)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: Pricelist privilege boundary invalid';
    END IF;

    RAISE NOTICE 'TEST PASSED: Global/Customer Pricelist writes are atomic, tenant-safe, versioned, audited, and preserve historical rules.';
END
$test$;

ROLLBACK;
