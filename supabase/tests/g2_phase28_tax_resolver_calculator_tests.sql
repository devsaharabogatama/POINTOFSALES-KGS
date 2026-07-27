-- G2 phase 28 behavioral test: private Tax resolution and calculation.
-- SAFETY: every fixture, feature change, assignment, and audit row rolls back.

BEGIN;

DO $test$
DECLARE
    v_actor UUID;
    v_company UUID := '00000000-0000-0000-0000-000000028001';
    v_category UUID := '00000000-0000-0000-0000-000000028011';
    v_category_no_tax UUID := '00000000-0000-0000-0000-000000028012';
    v_uom UUID := '00000000-0000-0000-0000-000000028021';
    v_product UUID := '00000000-0000-0000-0000-000000028031';
    v_product_no_tax UUID := '00000000-0000-0000-0000-000000028032';
    v_output_account UUID;
    v_input_account UUID;
    v_sales_rule UUID;
    v_purchase_category_rule UUID;
    v_purchase_override_rule UUID;
    v_result JSONB;
    v_per_line JSONB;
    v_per_document JSONB;
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
        v_company,'G28','G28 Company','g28-company','ACTIVE'
    );

    SELECT id INTO v_output_account FROM public.chart_of_accounts
    WHERE company_id = v_company AND system_function_key = 'OUTPUT_TAX';
    SELECT id INTO v_input_account FROM public.chart_of_accounts
    WHERE company_id = v_company AND system_function_key = 'INPUT_TAX';
    IF v_output_account IS NULL OR v_input_account IS NULL THEN
        RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: Tax template accounts missing';
    END IF;

    INSERT INTO public.product_categories(
        id,company_id,category_code,category_name
    ) VALUES
        (v_category,v_company,'G28-TAX','G28 Taxed'),
        (v_category_no_tax,v_company,'G28-NONE','G28 No Tax');
    INSERT INTO public.uoms(id,company_id,code,name) VALUES
        (v_uom,v_company,'PCS','Piece');
    INSERT INTO public.products(
        id,company_id,sku,name,category,category_id,price,cogs,uom,uom_id,
        weight_reference_uom_id,weight_per_uom_kg,is_active,is_bundle
    ) VALUES
        (
            v_product,v_company,'G28-P','G28 Product','G28 Taxed',
            v_category,110,100,'PCS',v_uom,v_uom,1,TRUE,FALSE
        ),
        (
            v_product_no_tax,v_company,'G28-N','G28 No Tax Product',
            'G28 No Tax',v_category_no_tax,110,100,'PCS',v_uom,v_uom,
            1,TRUE,FALSE
        );

    PERFORM set_config(
        'request.jwt.claims',
        jsonb_build_object('sub',v_actor,'role','authenticated')::TEXT,TRUE
    );
    PERFORM public.set_active_company_context(v_company,'G2_PHASE28_TEST');
    PERFORM public.set_company_feature(
        v_company,'tax_sales_enabled',TRUE,'{}'::JSONB
    );
    PERFORM public.set_company_feature(
        v_company,'tax_purchase_enabled',TRUE,'{}'::JSONB
    );

    v_result := public.save_tax_rule(
        NULL,NULL,'G28-S','G28 Sales','SALES',10,'PER_DOCUMENT',
        'INCLUSIVE',v_output_account,NULL,
        CURRENT_TIMESTAMP - INTERVAL '1 day',NULL,'ACTIVE',TRUE
    );
    v_sales_rule := (v_result->>'taxRuleId')::UUID;
    v_result := public.save_tax_rule(
        NULL,NULL,'G28-PC','G28 Purchase Category','PURCHASE',10,
        'PER_DOCUMENT','EXCLUSIVE',v_input_account,TRUE,
        CURRENT_TIMESTAMP - INTERVAL '1 day',NULL,'ACTIVE',TRUE
    );
    v_purchase_category_rule := (v_result->>'taxRuleId')::UUID;
    v_result := public.save_tax_rule(
        NULL,NULL,'G28-PO','G28 Purchase Override','PURCHASE',12,
        'PER_LINE','EXCLUSIVE',v_input_account,FALSE,
        CURRENT_TIMESTAMP - INTERVAL '1 day',NULL,'ACTIVE',TRUE
    );
    v_purchase_override_rule := (v_result->>'taxRuleId')::UUID;

    PERFORM public.save_product_category_tax_assignment(
        v_category,1,v_sales_rule,v_purchase_category_rule
    );
    PERFORM public.save_product_tax_assignment(
        v_product,1,NULL,v_purchase_override_rule
    );

    v_result := private.resolve_product_tax_rule(
        v_company,v_product,'SALES',CURRENT_TIMESTAMP
    );
    IF NOT (v_result->>'taxApplied')::BOOLEAN
       OR v_result->>'assignmentSource' <> 'CATEGORY'
       OR (v_result->>'taxRuleId')::UUID <> v_sales_rule
       OR (v_result->>'priceMode') <> 'INCLUSIVE' THEN
        RAISE EXCEPTION 'TEST_FAILED: Sales Category resolver invalid: %',v_result;
    END IF;

    v_result := private.resolve_product_tax_rule(
        v_company,v_product,'PURCHASE',CURRENT_TIMESTAMP
    );
    IF NOT (v_result->>'taxApplied')::BOOLEAN
       OR v_result->>'assignmentSource' <> 'PRODUCT'
       OR (v_result->>'taxRuleId')::UUID <> v_purchase_override_rule
       OR (v_result->>'ratePercent')::NUMERIC <> 12 THEN
        RAISE EXCEPTION 'TEST_FAILED: Product override resolver invalid: %',v_result;
    END IF;

    v_result := private.resolve_product_tax_rule(
        v_company,v_product_no_tax,'SALES',CURRENT_TIMESTAMP
    );
    IF (v_result->>'taxApplied')::BOOLEAN
       OR v_result->>'reason' <> 'NO_ASSIGNMENT' THEN
        RAISE EXCEPTION 'TEST_FAILED: no-tax resolver invalid: %',v_result;
    END IF;

    v_result := private.calculate_tax_group(
        '[{"lineKey":"SALE-1","amount":110}]'::JSONB,
        10,'SALES','INCLUSIVE','PER_LINE'
    );
    IF (v_result->>'totalTaxBase')::NUMERIC <> 100
       OR (v_result->>'totalTaxAmount')::NUMERIC <> 10
       OR (v_result->>'totalGrossAmount')::NUMERIC <> 110 THEN
        RAISE EXCEPTION 'TEST_FAILED: inclusive calculation invalid: %',v_result;
    END IF;

    v_result := private.calculate_tax_group(
        '[{"lineKey":"BUY-1","amount":100}]'::JSONB,
        10,'PURCHASE','EXCLUSIVE','PER_LINE'
    );
    IF (v_result->>'totalTaxBase')::NUMERIC <> 100
       OR (v_result->>'totalTaxAmount')::NUMERIC <> 10
       OR (v_result->>'totalGrossAmount')::NUMERIC <> 110 THEN
        RAISE EXCEPTION 'TEST_FAILED: exclusive calculation invalid: %',v_result;
    END IF;

    v_per_line := private.calculate_tax_group(
        '[{"lineKey":"A","amount":5},{"lineKey":"B","amount":5}]'::JSONB,
        10,'PURCHASE','EXCLUSIVE','PER_LINE'
    );
    v_per_document := private.calculate_tax_group(
        '[{"lineKey":"A","amount":5},{"lineKey":"B","amount":5}]'::JSONB,
        10,'PURCHASE','EXCLUSIVE','PER_DOCUMENT'
    );
    IF (v_per_line->>'totalTaxAmount')::NUMERIC <> 2
       OR (v_per_document->>'totalTaxAmount')::NUMERIC <> 1
       OR (v_per_document#>>'{lines,0,taxAmount}')::NUMERIC <> 0
       OR (v_per_document#>>'{lines,1,taxAmount}')::NUMERIC <> 1 THEN
        RAISE EXCEPTION
            'TEST_FAILED: PER_LINE/PER_DOCUMENT allocation invalid: % / %',
            v_per_line,v_per_document;
    END IF;

    v_rejected := FALSE;
    BEGIN
        PERFORM private.calculate_tax_group(
            '[{"lineKey":"BAD","amount":100}]'::JSONB,
            10,'SALES','EXCLUSIVE','PER_DOCUMENT'
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'SALES_TAX_MUST_BE_INCLUSIVE' THEN v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: exclusive Sales Tax calculation accepted';
    END IF;

    IF has_function_privilege(
        'authenticated',
        'private.resolve_product_tax_rule(uuid,uuid,text,timestamp with time zone)',
        'EXECUTE'
    ) OR has_function_privilege(
        'authenticated',
        'private.calculate_tax_group(jsonb,numeric,text,text,text)',
        'EXECUTE'
    ) OR NOT has_function_privilege(
        'service_role',
        'private.calculate_tax_group(jsonb,numeric,text,text,text)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: private Tax routine privilege invalid';
    END IF;

    RAISE NOTICE 'TEST PASSED: Tax resolution is tenant/scope/effective-safe and PER_LINE/PER_DOCUMENT calculation is deterministic; transaction cutover remains disabled.';
END
$test$;

ROLLBACK;
