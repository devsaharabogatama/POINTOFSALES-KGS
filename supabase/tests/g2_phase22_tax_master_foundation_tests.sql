-- G2 phase 22 behavioral test: guarded Sales/Purchase Tax master.
-- SAFETY: every feature, Company, Tax, assignment, and audit fixture rolls back.

BEGIN;

DO $test$
DECLARE
    v_actor UUID;
    v_company_a UUID := '00000000-0000-0000-0000-000000022001';
    v_company_b UUID := '00000000-0000-0000-0000-000000022002';
    v_category UUID := '00000000-0000-0000-0000-000000022011';
    v_output_account UUID;
    v_input_account UUID;
    v_foreign_output_account UUID;
    v_sales_rule UUID;
    v_purchase_rule UUID;
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
        (v_company_a,'G22A','G22 Company A','g22-company-a','ACTIVE'),
        (v_company_b,'G22B','G22 Company B','g22-company-b','ACTIVE');

    SELECT id INTO v_output_account FROM public.chart_of_accounts
    WHERE company_id = v_company_a AND system_function_key = 'OUTPUT_TAX';
    SELECT id INTO v_input_account FROM public.chart_of_accounts
    WHERE company_id = v_company_a AND system_function_key = 'INPUT_TAX';
    SELECT id INTO v_foreign_output_account FROM public.chart_of_accounts
    WHERE company_id = v_company_b AND system_function_key = 'OUTPUT_TAX';

    INSERT INTO public.product_categories(
        id,company_id,category_code,category_name
    ) VALUES (v_category,v_company_a,'G22','G22 Category');

    PERFORM set_config(
        'request.jwt.claims',
        jsonb_build_object('sub',v_actor,'role','authenticated')::TEXT,TRUE
    );
    PERFORM public.set_active_company_context(v_company_a,'G2_PHASE22_TEST');
    PERFORM public.set_company_feature(
        v_company_a,'tax_sales_enabled',TRUE,'{}'::JSONB
    );
    PERFORM public.set_company_feature(
        v_company_a,'tax_purchase_enabled',TRUE,'{}'::JSONB
    );

    v_result := public.save_tax_rule(
        NULL,NULL,'PPN-S','PPN Penjualan','SALES',11,'PER_DOCUMENT',
        'INCLUSIVE',v_output_account,NULL,
        '2026-01-01 00:00:00+00',NULL,'ACTIVE',TRUE
    );
    v_sales_rule := (v_result->>'taxRuleId')::UUID;
    IF (v_result->>'ruleVersion')::BIGINT <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: first Sales Tax version invalid';
    END IF;

    v_result := public.save_tax_rule(
        v_sales_rule,1,'PPN-S','PPN Penjualan','SALES',12,'PER_DOCUMENT',
        'INCLUSIVE',v_output_account,NULL,
        '2027-01-01 00:00:00+00',NULL,'ACTIVE',TRUE
    );
    IF (v_result->>'ruleVersion')::BIGINT <> 2
       OR (v_result->>'masterVersion')::BIGINT <> 2 THEN
        RAISE EXCEPTION 'TEST_FAILED: second Sales Tax version invalid';
    END IF;
    SELECT count(*) INTO v_count FROM public.tax_rule_versions
    WHERE company_id = v_company_a AND tax_rule_id = v_sales_rule
      AND rule_version = 1
      AND effective_to = '2027-01-01 00:00:00+00'::TIMESTAMPTZ;
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: prior Sales Tax period not closed';
    END IF;

    v_result := public.save_tax_rule(
        NULL,NULL,'PPN-P','PPN Pembelian','PURCHASE',11,'PER_DOCUMENT',
        'EXCLUSIVE',v_input_account,TRUE,
        '2026-01-01 00:00:00+00',NULL,'ACTIVE',TRUE
    );
    v_purchase_rule := (v_result->>'taxRuleId')::UUID;

    v_rejected := FALSE;
    BEGIN
        PERFORM public.save_tax_rule(
            v_sales_rule,2,'PPN-S','PPN Penjualan','SALES',13,'PER_DOCUMENT',
            'EXCLUSIVE',v_output_account,NULL,
            '2028-01-01 00:00:00+00',NULL,'ACTIVE',TRUE
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'SALES_TAX_MUST_BE_INCLUSIVE' THEN v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: exclusive Sales Tax accepted';
    END IF;

    v_rejected := FALSE;
    BEGIN
        PERFORM public.save_tax_rule(
            v_sales_rule,2,'PPN-S','PPN Penjualan','SALES',13,'PER_DOCUMENT',
            'INCLUSIVE',v_foreign_output_account,NULL,
            '2028-01-01 00:00:00+00',NULL,'ACTIVE',TRUE
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'ACTIVE_POSTABLE_TAX_ACCOUNT_REQUIRED' THEN
            v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: cross-Company Tax account accepted';
    END IF;

    v_rejected := FALSE;
    BEGIN
        UPDATE public.product_categories
        SET default_sales_tax_rule_id = v_purchase_rule
        WHERE company_id = v_company_a AND id = v_category;
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'ACTIVE_SALES_TAX_RULE_REQUIRED' THEN
            v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: Purchase Tax assigned as Sales Tax';
    END IF;

    PERFORM public.set_active_company_context(v_company_b,'G2_PHASE22_TEST');
    v_rejected := FALSE;
    BEGIN
        PERFORM public.save_tax_rule(
            NULL,NULL,'NO-FEATURE','Disabled Tax','SALES',11,'PER_DOCUMENT',
            'INCLUSIVE',v_foreign_output_account,NULL,
            '2026-01-01 00:00:00+00',NULL,'ACTIVE',TRUE
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'TAX_FEATURE_DISABLED' THEN v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: Tax Rule created while feature disabled';
    END IF;

    SELECT count(*) INTO v_count FROM public.tax_master_audit
    WHERE company_id = v_company_a;
    IF v_count < 6 THEN
        RAISE EXCEPTION 'TEST_FAILED: Tax audit history incomplete';
    END IF;

    IF has_table_privilege(
        'authenticated','public.tax_rules','INSERT,UPDATE,DELETE'
    ) OR has_table_privilege(
        'authenticated','public.tax_rule_versions','INSERT,UPDATE,DELETE'
    ) OR NOT has_function_privilege(
        'authenticated',
        'public.save_tax_rule(uuid,bigint,text,text,text,numeric,text,text,uuid,boolean,timestamp with time zone,timestamp with time zone,text,boolean)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: Tax master privilege boundary invalid';
    END IF;

    RAISE NOTICE 'TEST PASSED: Tax master is entitlement-gated, tenant-safe, effective-dated, scope-safe, versioned, and audited; calculation/posting remains disabled.';
END
$test$;

ROLLBACK;

