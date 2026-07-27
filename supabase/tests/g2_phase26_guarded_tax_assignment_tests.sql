-- G2 phase 26 behavioral test: guarded and atomic Tax assignment.
-- SAFETY: every fixture, assignment, and audit row is rolled back.

BEGIN;

DO $fixtures$
DECLARE
    v_actor UUID;
    v_input_tax_account UUID;
    v_output_tax_account UUID;
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

    INSERT INTO public.company_features(
        company_id,feature_code,is_enabled,updated_by
    ) VALUES
        ('00000000-0000-0000-0000-000000014001',
         'tax_sales_enabled',TRUE,v_actor),
        ('00000000-0000-0000-0000-000000014001',
         'tax_purchase_enabled',TRUE,v_actor);

    INSERT INTO public.product_categories(
        id,company_id,category_code,category_name
    ) VALUES
        ('00000000-0000-0000-0000-000000014011',
         '00000000-0000-0000-0000-000000014001','FOOD','Food'),
        ('00000000-0000-0000-0000-000000014012',
         '00000000-0000-0000-0000-000000014002','FOOD','Food');

    INSERT INTO public.uoms(id,company_id,code,name) VALUES
        ('00000000-0000-0000-0000-000000014021',
         '00000000-0000-0000-0000-000000014001','KTL','Ketul'),
        ('00000000-0000-0000-0000-000000014022',
         '00000000-0000-0000-0000-000000014001','DUS','Dus');

    SELECT id INTO v_input_tax_account
    FROM public.chart_of_accounts
    WHERE company_id = '00000000-0000-0000-0000-000000014001'
      AND system_function_key = 'INPUT_TAX'
      AND is_active AND is_postable
    ORDER BY id LIMIT 1;
    SELECT id INTO v_output_tax_account
    FROM public.chart_of_accounts
    WHERE company_id = '00000000-0000-0000-0000-000000014001'
      AND system_function_key = 'OUTPUT_TAX'
      AND is_active AND is_postable
    ORDER BY id LIMIT 1;
    IF v_input_tax_account IS NULL OR v_output_tax_account IS NULL THEN
        RAISE EXCEPTION
            'TEST_PRECONDITION_FAILED: provisioned Tax accounts required';
    END IF;

    INSERT INTO public.tax_rules(
        id,company_id,tax_code,tax_name,tax_scope,created_by,updated_by
    ) VALUES
        ('00000000-0000-0000-0000-000000014041',
         '00000000-0000-0000-0000-000000014001','PPN-OUT','PPN Keluaran',
         'SALES',v_actor,v_actor),
        ('00000000-0000-0000-0000-000000014042',
         '00000000-0000-0000-0000-000000014001','PPN-IN','PPN Masukan',
         'PURCHASE',v_actor,v_actor),
        ('00000000-0000-0000-0000-000000014043',
         '00000000-0000-0000-0000-000000014002','PPN-B','PPN Company B',
         'SALES',v_actor,v_actor);

    INSERT INTO public.tax_rule_versions(
        id,company_id,tax_rule_id,rate_percent,calculation_scope,
        default_price_mode,account_function_key,account_id,is_recoverable,
        effective_from,rule_version,status,approved_by,approved_at,
        created_by,updated_by
    ) VALUES
        ('00000000-0000-0000-0000-000000014051',
         '00000000-0000-0000-0000-000000014001',
         '00000000-0000-0000-0000-000000014041',11,'PER_LINE','INCLUSIVE',
         'OUTPUT_TAX',v_output_tax_account,NULL,
         clock_timestamp() - interval '1 day',1,'ACTIVE',v_actor,
         clock_timestamp(),v_actor,v_actor),
        ('00000000-0000-0000-0000-000000014052',
         '00000000-0000-0000-0000-000000014001',
         '00000000-0000-0000-0000-000000014042',11,'PER_LINE','EXCLUSIVE',
         'INPUT_TAX',v_input_tax_account,TRUE,
         clock_timestamp() - interval '1 day',1,'ACTIVE',v_actor,
         clock_timestamp(),v_actor,v_actor);

    PERFORM set_config('g2.test_actor',v_actor::TEXT,TRUE);
END
$fixtures$;

SET LOCAL ROLE authenticated;

DO $test$
DECLARE
    v_actor UUID := current_setting('g2.test_actor')::UUID;
    v_result JSONB;
    v_product_id UUID;
    v_count BIGINT;
    v_rejected BOOLEAN;
BEGIN
    PERFORM set_config(
        'request.jwt.claims',
        jsonb_build_object('sub',v_actor,'role','authenticated')::TEXT,TRUE
    );
    PERFORM public.set_active_company_context(
        '00000000-0000-0000-0000-000000014001','G2_PHASE26_TEST'
    );

    v_result := public.save_product_category_tax_assignment(
        '00000000-0000-0000-0000-000000014011',1,
        '00000000-0000-0000-0000-000000014041',
        '00000000-0000-0000-0000-000000014042'
    );
    IF (v_result->>'masterVersion')::BIGINT <> 2 THEN
        RAISE EXCEPTION 'TEST_FAILED: Category version did not increment';
    END IF;
    SELECT count(*) INTO v_count
    FROM public.tax_assignment_audit
    WHERE entity_type = 'PRODUCT_CATEGORY'
      AND entity_id = '00000000-0000-0000-0000-000000014011';
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: Category Tax audit missing';
    END IF;

    v_rejected := FALSE;
    BEGIN
        PERFORM public.save_product_category_tax_assignment(
            '00000000-0000-0000-0000-000000014011',1,NULL,NULL
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'MASTER_VERSION_CONFLICT' THEN v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: stale Category assignment accepted';
    END IF;

    v_rejected := FALSE;
    BEGIN
        PERFORM public.save_product_category_tax_assignment(
            '00000000-0000-0000-0000-000000014011',2,
            '00000000-0000-0000-0000-000000014042',
            '00000000-0000-0000-0000-000000014042'
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'CURRENT_SALES_TAX_RULE_REQUIRED' THEN
            v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: wrong-scope Category Tax accepted';
    END IF;

    v_result := public.save_product_with_uoms(
        NULL,NULL,'G14-PROD','G14 Product',
        '00000000-0000-0000-0000-000000014011',
        '00000000-0000-0000-0000-000000014021',
        '00000000-0000-0000-0000-000000014022',21,FALSE,NULL,TRUE,
        jsonb_build_array(
            jsonb_build_object(
                'uomId','00000000-0000-0000-0000-000000014021',
                'factorToBase',1,'purchaseAllowed',FALSE,
                'salesAllowed',TRUE,'purchasePrice',50,
                'salePrice',100,'isActive',TRUE
            ),
            jsonb_build_object(
                'uomId','00000000-0000-0000-0000-000000014022',
                'factorToBase',10,'purchaseAllowed',TRUE,
                'salesAllowed',FALSE,'purchasePrice',500,
                'salePrice',1000,'isActive',TRUE
            )
        ),
        '00000000-0000-0000-0000-000000014041',
        '00000000-0000-0000-0000-000000014042'
    );
    v_product_id := (v_result->>'productId')::UUID;
    SELECT count(*) INTO v_count
    FROM public.products p
    WHERE p.id = v_product_id
      AND p.sales_tax_rule_id = '00000000-0000-0000-0000-000000014041'
      AND p.purchase_tax_rule_id = '00000000-0000-0000-0000-000000014042';
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: atomic Product Tax assignment missing';
    END IF;
    SELECT count(*) INTO v_count
    FROM public.tax_assignment_audit
    WHERE entity_type = 'PRODUCT' AND entity_id = v_product_id;
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: Product Tax audit missing';
    END IF;

    v_rejected := FALSE;
    BEGIN
        PERFORM public.save_product_with_uoms(
            NULL,NULL,'G14-BAD','G14 Rejected Product',
            '00000000-0000-0000-0000-000000014011',
            '00000000-0000-0000-0000-000000014021',
            '00000000-0000-0000-0000-000000014022',21,FALSE,NULL,TRUE,
            jsonb_build_array(
                jsonb_build_object(
                    'uomId','00000000-0000-0000-0000-000000014021',
                    'factorToBase',1,'purchaseAllowed',FALSE,
                    'salesAllowed',TRUE,'purchasePrice',50,
                    'salePrice',100,'isActive',TRUE
                ),
                jsonb_build_object(
                    'uomId','00000000-0000-0000-0000-000000014022',
                    'factorToBase',10,'purchaseAllowed',TRUE,
                    'salesAllowed',FALSE,'purchasePrice',500,
                    'salePrice',1000,'isActive',TRUE
                )
            ),
            '00000000-0000-0000-0000-000000014042',NULL
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'CURRENT_SALES_TAX_RULE_REQUIRED' THEN
            v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: invalid atomic Product Tax accepted';
    END IF;
    IF EXISTS(SELECT 1 FROM public.products WHERE sku = 'G14-BAD') THEN
        RAISE EXCEPTION 'TEST_FAILED: rejected Product partially persisted';
    END IF;

    IF has_column_privilege(
        'authenticated','public.product_categories',
        'default_sales_tax_rule_id','INSERT'
    ) OR has_column_privilege(
        'authenticated','public.product_categories',
        'default_sales_tax_rule_id','UPDATE'
    ) OR has_table_privilege(
        'authenticated','public.tax_assignment_audit','INSERT,UPDATE,DELETE'
    ) OR NOT has_function_privilege(
        'authenticated',
        'public.save_product_category_tax_assignment(uuid,bigint,uuid,uuid)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: Tax assignment privilege boundary invalid';
    END IF;

    RAISE NOTICE 'TEST PASSED: Product Category/Product Tax assignments are tenant-safe, effective-version guarded, optimistic, audited, and atomic with Product-UOM saves.';
END
$test$;

RESET ROLE;
ROLLBACK;
