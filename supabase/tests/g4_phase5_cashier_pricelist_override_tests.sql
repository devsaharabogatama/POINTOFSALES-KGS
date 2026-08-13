-- G4 phase 5 behavior: AUTO, eligible Global override, and cross-Customer deny.
-- SAFETY: all fixtures are rolled back.

BEGIN;

INSERT INTO public.companies(
    id,company_code,company_name,company_slug,status
) VALUES (
    '00000000-0000-0000-0000-000000054001',
    'G54A','G54 Company A','g54-company-a','ACTIVE'
);

INSERT INTO public.stores(id,company_id,store_code,store_name,status)
VALUES (
    '00000000-0000-0000-0000-000000054011',
    '00000000-0000-0000-0000-000000054001',
    'A1','G54 Store A','ACTIVE'
);

INSERT INTO public.product_categories(
    id,company_id,category_code,category_name
) VALUES (
    '00000000-0000-0000-0000-000000054021',
    '00000000-0000-0000-0000-000000054001',
    'TEST','Test Product'
);

INSERT INTO public.uoms(
    id,company_id,code,name,uom_type,allow_decimal,decimal_precision
) VALUES (
    '00000000-0000-0000-0000-000000054031',
    '00000000-0000-0000-0000-000000054001',
    'PCS','Piece','UNIT',FALSE,0
);

INSERT INTO public.products(
    id,company_id,sku,name,category,category_id,price,cogs,uom,uom_id,
    weight_reference_uom_id,weight_per_uom_kg,is_active,is_bundle
) VALUES (
    '00000000-0000-0000-0000-000000054041',
    '00000000-0000-0000-0000-000000054001',
    'G54-PROD','G54 Product','Test Product',
    '00000000-0000-0000-0000-000000054021',
    100,50,'PCS',
    '00000000-0000-0000-0000-000000054031',
    '00000000-0000-0000-0000-000000054031',
    1,TRUE,FALSE
);

INSERT INTO public.product_uoms(
    id,company_id,product_id,uom_id,factor_to_base,
    purchase_allowed,sales_allowed,purchase_price,sale_price,is_active
) VALUES (
    '00000000-0000-0000-0000-000000054051',
    '00000000-0000-0000-0000-000000054001',
    '00000000-0000-0000-0000-000000054041',
    '00000000-0000-0000-0000-000000054031',
    1,TRUE,TRUE,50,100,TRUE
);

INSERT INTO public.customer_categories(
    id,company_id,category_code,category_name,is_system_category
) VALUES (
    '00000000-0000-0000-0000-000000054061',
    '00000000-0000-0000-0000-000000054001',
    'REG','Regular',FALSE
);

-- Company provisioning already creates one default Global Pricelist. Demote
-- that rollback-only fixture before installing the deterministic resolver row.
UPDATE public.pricelists SET is_default=FALSE
WHERE company_id='00000000-0000-0000-0000-000000054001'
  AND scope='GLOBAL' AND is_default AND is_active;

INSERT INTO public.pricelists(
    id,company_id,code,name,scope,priority,is_default,
    applies_all_stores,is_active
) VALUES
    (
        '00000000-0000-0000-0000-000000054071',
        '00000000-0000-0000-0000-000000054001',
        'G54-GLOBAL','Global G54','GLOBAL',10,TRUE,TRUE,TRUE
    ),
    (
        '00000000-0000-0000-0000-000000054072',
        '00000000-0000-0000-0000-000000054001',
        'CUST-A','Customer A G54','CUSTOMER',20,FALSE,TRUE,TRUE
    ),
    (
        '00000000-0000-0000-0000-000000054073',
        '00000000-0000-0000-0000-000000054001',
        'CUST-B','Customer B G54','CUSTOMER',20,FALSE,TRUE,TRUE
    );

INSERT INTO public.customers(
    id,company_id,code,name,customer_category_id,default_pricelist_id
) VALUES
    (
        '00000000-0000-0000-0000-000000054081',
        '00000000-0000-0000-0000-000000054001',
        'CUST-A','Customer A',
        '00000000-0000-0000-0000-000000054061',
        '00000000-0000-0000-0000-000000054072'
    ),
    (
        '00000000-0000-0000-0000-000000054082',
        '00000000-0000-0000-0000-000000054001',
        'CUST-B','Customer B',
        '00000000-0000-0000-0000-000000054061',
        '00000000-0000-0000-0000-000000054073'
    );

INSERT INTO public.pricelist_rules(
    company_id,pricelist_id,product_id,product_uom_id,min_qty,
    tier_qty_basis,pricing_method,fixed_unit_price,is_active
) VALUES
    (
        '00000000-0000-0000-0000-000000054001',
        '00000000-0000-0000-0000-000000054071',
        '00000000-0000-0000-0000-000000054041',
        '00000000-0000-0000-0000-000000054051',
        1,'SALES_UOM','FIXED_PRICE',90,TRUE
    ),
    (
        '00000000-0000-0000-0000-000000054001',
        '00000000-0000-0000-0000-000000054072',
        '00000000-0000-0000-0000-000000054041',
        '00000000-0000-0000-0000-000000054051',
        1,'SALES_UOM','FIXED_PRICE',80,TRUE
    ),
    (
        '00000000-0000-0000-0000-000000054001',
        '00000000-0000-0000-0000-000000054073',
        '00000000-0000-0000-0000-000000054041',
        '00000000-0000-0000-0000-000000054051',
        1,'SALES_UOM','FIXED_PRICE',70,TRUE
    );

DO $test$
DECLARE
    v_result JSONB;
    v_rejected BOOLEAN := FALSE;
BEGIN
    PERFORM set_config('kgs.selected_pricelist_id','',TRUE);
    v_result := private.resolve_pos_sale_price(
        '00000000-0000-0000-0000-000000054001',
        '00000000-0000-0000-0000-000000054011',
        '00000000-0000-0000-0000-000000054081',
        '00000000-0000-0000-0000-000000054051',
        1,clock_timestamp()
    );
    IF (v_result->>'resolvedUnitPrice')::NUMERIC <> 80
       OR v_result->>'pricingSelectionSource' <> 'AUTO' THEN
        RAISE EXCEPTION 'TEST_FAILED: Customer AUTO resolver invalid: %',
            v_result;
    END IF;

    PERFORM set_config(
        'kgs.selected_pricelist_id',
        '00000000-0000-0000-0000-000000054071',TRUE
    );
    v_result := private.resolve_pos_sale_price(
        '00000000-0000-0000-0000-000000054001',
        '00000000-0000-0000-0000-000000054011',
        '00000000-0000-0000-0000-000000054081',
        '00000000-0000-0000-0000-000000054051',
        1,clock_timestamp()
    );
    IF (v_result->>'resolvedUnitPrice')::NUMERIC <> 90
       OR v_result->>'pricingSelectionSource' <> 'CASHIER_OVERRIDE' THEN
        RAISE EXCEPTION 'TEST_FAILED: Global override invalid: %',v_result;
    END IF;

    PERFORM set_config(
        'kgs.selected_pricelist_id',
        '00000000-0000-0000-0000-000000054073',TRUE
    );
    BEGIN
        PERFORM private.resolve_pos_sale_price(
            '00000000-0000-0000-0000-000000054001',
            '00000000-0000-0000-0000-000000054011',
            '00000000-0000-0000-0000-000000054081',
            '00000000-0000-0000-0000-000000054051',
            1,clock_timestamp()
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'PRICELIST_NOT_ELIGIBLE' THEN
            v_rejected := TRUE;
        ELSE
            RAISE;
        END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION
            'TEST_FAILED: another Customer Pricelist was accepted';
    END IF;

    RAISE NOTICE
        'TEST PASSED: AUTO and eligible override resolve server-side; cross-Customer Pricelist is denied.';
END
$test$;

ROLLBACK;
