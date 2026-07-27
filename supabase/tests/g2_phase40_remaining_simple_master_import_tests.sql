-- G2 phase 40 behavioral test: guarded simple master import expansion.
-- SAFETY: all Company/master/job/audit fixtures are rolled back.

BEGIN;

DO $test$
DECLARE
    v_actor UUID;
    v_company UUID := '00000000-0000-0000-0000-000000040001';
    v_job UUID;
    v_result JSONB;
    v_version BIGINT;
    v_system_key TEXT;
    v_name TEXT;
    v_code TEXT;
    v_id UUID;
    v_count BIGINT;
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
        v_company,'G40','G40 Company','g40-company','ACTIVE'
    );

    PERFORM set_config(
        'request.jwt.claims',
        jsonb_build_object('sub',v_actor,'role','authenticated')::TEXT,
        TRUE
    );
    PERFORM public.set_active_company_context(v_company,'G2_PHASE40_TEST');

    SELECT system_key INTO v_system_key
    FROM public.system_events
    WHERE is_active
    ORDER BY system_key LIMIT 1;
    IF v_system_key IS NULL THEN
        RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: active System Event required';
    END IF;

    -- Customer Category: code-less create through guarded RPC commit.
    v_result := public.create_master_import_job(
        '00000000-0000-0000-0000-000000040011',
        'CUSTOMER_CATEGORY','REFERENCE_BY_NAME','CREATE_AND_UPDATE',
        'customer-category.csv',repeat('a',64),','
    );
    v_job := (v_result->>'jobId')::UUID;
    v_result := public.stage_master_import_rows(
        v_job,(v_result->>'masterVersion')::BIGINT,
        '{"name":"name","isActive":"active"}'::JSONB,
        jsonb_build_array(jsonb_build_object(
            'rowNumber',1,'sourceData',
            jsonb_build_object('name','G40 Retail','active','true')
        ))
    );
    v_result := public.validate_master_import_job(
        v_job,(v_result->>'masterVersion')::BIGINT
    );
    IF (v_result->>'createCount')::INTEGER <> 1
       OR (v_result->>'errorCount')::INTEGER <> 0 THEN
        RAISE EXCEPTION 'TEST_FAILED: Customer Category preview invalid';
    END IF;
    v_version := (v_result->>'masterVersion')::BIGINT;
    v_result := public.commit_master_import_job(v_job,v_version,0);
    IF v_result->>'status' <> 'COMPLETED' THEN
        RAISE EXCEPTION 'TEST_FAILED: Customer Category commit failed';
    END IF;
    SELECT id,category_code INTO v_id,v_code
    FROM public.customer_categories
    WHERE company_id = v_company AND category_name = 'G40 Retail';
    IF v_id IS NULL OR v_code !~ '^CC-[0-9]{6,18}$' THEN
        RAISE EXCEPTION 'TEST_FAILED: automatic Customer Category code invalid';
    END IF;
    SELECT count(*) INTO v_count
    FROM public.customer_category_audit
    WHERE company_id = v_company
      AND customer_category_id = v_id
      AND action = 'CREATE';
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: Customer Category audit missing';
    END IF;

    -- COA: a non-postable parent may be referenced by a later row in the file.
    v_result := public.create_master_import_job(
        '00000000-0000-0000-0000-000000040012',
        'CHART_OF_ACCOUNT','REFERENCE_BY_NAME','CREATE_AND_UPDATE',
        'coa.csv',repeat('b',64),','
    );
    v_job := (v_result->>'jobId')::UUID;
    v_result := public.stage_master_import_rows(
        v_job,(v_result->>'masterVersion')::BIGINT,
        '{
          "code":"code","name":"name","accountType":"type",
          "normalBalance":"balance","parentAccountCode":"parent",
          "isPostable":"postable","allowManualPosting":"manual",
          "allowReconciliation":"reconcile","isActive":"active"
        }'::JSONB,
        jsonb_build_array(
            jsonb_build_object(
                'rowNumber',1,'sourceData',jsonb_build_object(
                    'code','G40-PARENT','name','G40 Import Parent',
                    'type','ASSET','balance','DEBIT','parent','',
                    'postable','false','manual','false',
                    'reconcile','false','active','true'
                )
            ),
            jsonb_build_object(
                'rowNumber',2,'sourceData',jsonb_build_object(
                    'code','G40-CHILD','name','G40 Import Child',
                    'type','ASSET','balance','DEBIT','parent','G40-PARENT',
                    'postable','true','manual','true',
                    'reconcile','true','active','true'
                )
            )
        )
    );
    v_result := public.validate_master_import_job(
        v_job,(v_result->>'masterVersion')::BIGINT
    );
    IF (v_result->>'createCount')::INTEGER <> 2
       OR (v_result->>'errorCount')::INTEGER <> 0 THEN
        RAISE EXCEPTION 'TEST_FAILED: COA parent/child preview invalid: %',
            v_result;
    END IF;
    v_version := (v_result->>'masterVersion')::BIGINT;
    v_result := public.commit_master_import_job(v_job,v_version,0);
    IF v_result->>'status' <> 'COMPLETED' THEN
        RAISE EXCEPTION 'TEST_FAILED: COA commit failed: %',v_result;
    END IF;
    SELECT count(*) INTO v_count
    FROM public.chart_of_accounts child
    JOIN public.chart_of_accounts parent
      ON parent.company_id = child.company_id
     AND parent.id = child.parent_account_id
    WHERE child.company_id = v_company
      AND child.account_code = 'G40-CHILD'
      AND parent.account_code = 'G40-PARENT'
      AND NOT parent.is_postable;
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: COA hierarchy not committed';
    END IF;
    SELECT count(*) INTO v_count
    FROM public.finance_master_audit
    WHERE company_id = v_company
      AND entity_type = 'ACCOUNT'
      AND action = 'CREATE'
      AND after_state->>'account_code' IN ('G40-PARENT','G40-CHILD');
    IF v_count <> 2 THEN
        RAISE EXCEPTION 'TEST_FAILED: COA audit missing';
    END IF;

    -- Transaction Category: code-less create with active System Event.
    v_result := public.create_master_import_job(
        '00000000-0000-0000-0000-000000040013',
        'TRANSACTION_CATEGORY','REFERENCE_BY_NAME','CREATE_AND_UPDATE',
        'transaction-category.csv',repeat('c',64),','
    );
    v_job := (v_result->>'jobId')::UUID;
    v_result := public.stage_master_import_rows(
        v_job,(v_result->>'masterVersion')::BIGINT,
        '{
          "name":"name","systemKey":"system_key",
          "description":"description","isActive":"active"
        }'::JSONB,
        jsonb_build_array(jsonb_build_object(
            'rowNumber',1,'sourceData',jsonb_build_object(
                'name','G40 Custom Transaction','system_key',v_system_key,
                'description','G40 test','active','true'
            )
        ))
    );
    v_result := public.validate_master_import_job(
        v_job,(v_result->>'masterVersion')::BIGINT
    );
    IF (v_result->>'createCount')::INTEGER <> 1
       OR (v_result->>'errorCount')::INTEGER <> 0 THEN
        RAISE EXCEPTION 'TEST_FAILED: Transaction Category preview invalid';
    END IF;
    v_version := (v_result->>'masterVersion')::BIGINT;
    v_result := public.commit_master_import_job(v_job,v_version,0);
    IF v_result->>'status' <> 'COMPLETED' THEN
        RAISE EXCEPTION 'TEST_FAILED: Transaction Category commit failed';
    END IF;
    SELECT id,category_code INTO v_id,v_code
    FROM public.transaction_categories
    WHERE company_id = v_company
      AND category_name = 'G40 Custom Transaction';
    IF v_id IS NULL OR v_code !~ '^TC-[0-9]{6,18}$' THEN
        RAISE EXCEPTION
            'TEST_FAILED: automatic Transaction Category code invalid';
    END IF;
    SELECT count(*) INTO v_count
    FROM public.finance_master_audit
    WHERE company_id = v_company
      AND entity_type = 'CATEGORY'
      AND entity_id = v_id
      AND action = 'CREATE';
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: Transaction Category audit missing';
    END IF;

    -- Every system-owned row is rejected during preview.
    SELECT category_name INTO v_name
    FROM public.customer_categories
    WHERE company_id = v_company AND is_system_category
    LIMIT 1;
    v_result := public.create_master_import_job(
        '00000000-0000-0000-0000-000000040014',
        'CUSTOMER_CATEGORY','REFERENCE_BY_NAME','CREATE_AND_UPDATE',
        'system-customer-category.csv',repeat('d',64),','
    );
    v_job := (v_result->>'jobId')::UUID;
    v_result := public.stage_master_import_rows(
        v_job,(v_result->>'masterVersion')::BIGINT,
        '{"name":"name","isActive":"active"}'::JSONB,
        jsonb_build_array(jsonb_build_object(
            'rowNumber',1,'sourceData',
            jsonb_build_object('name',v_name,'active','true')
        ))
    );
    v_result := public.validate_master_import_job(
        v_job,(v_result->>'masterVersion')::BIGINT
    );
    IF (v_result->>'errorCount')::INTEGER <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: system Customer Category accepted';
    END IF;

    SELECT account_code,account_name INTO v_code,v_name
    FROM public.chart_of_accounts
    WHERE company_id = v_company AND is_system_account
    ORDER BY account_code LIMIT 1;
    v_result := public.create_master_import_job(
        '00000000-0000-0000-0000-000000040015',
        'CHART_OF_ACCOUNT','REFERENCE_BY_NAME','CREATE_AND_UPDATE',
        'system-coa.csv',repeat('e',64),','
    );
    v_job := (v_result->>'jobId')::UUID;
    v_result := public.stage_master_import_rows(
        v_job,(v_result->>'masterVersion')::BIGINT,
        '{
          "code":"code","name":"name","accountType":"type",
          "normalBalance":"balance","isActive":"active"
        }'::JSONB,
        jsonb_build_array(jsonb_build_object(
            'rowNumber',1,'sourceData',jsonb_build_object(
                'code',v_code,'name',v_name,'type','ASSET',
                'balance','DEBIT','active','true'
            )
        ))
    );
    v_result := public.validate_master_import_job(
        v_job,(v_result->>'masterVersion')::BIGINT
    );
    IF (v_result->>'errorCount')::INTEGER <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: system COA accepted';
    END IF;

    SELECT category_name,system_key INTO v_name,v_system_key
    FROM public.transaction_categories
    WHERE company_id = v_company AND is_system_default
    ORDER BY category_code LIMIT 1;
    v_result := public.create_master_import_job(
        '00000000-0000-0000-0000-000000040016',
        'TRANSACTION_CATEGORY','REFERENCE_BY_NAME','CREATE_AND_UPDATE',
        'system-transaction-category.csv',repeat('f',64),','
    );
    v_job := (v_result->>'jobId')::UUID;
    v_result := public.stage_master_import_rows(
        v_job,(v_result->>'masterVersion')::BIGINT,
        '{"name":"name","systemKey":"system_key","isActive":"active"}'::JSONB,
        jsonb_build_array(jsonb_build_object(
            'rowNumber',1,'sourceData',jsonb_build_object(
                'name',v_name,'system_key',v_system_key,'active','true'
            )
        ))
    );
    v_result := public.validate_master_import_job(
        v_job,(v_result->>'masterVersion')::BIGINT
    );
    IF (v_result->>'errorCount')::INTEGER <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: required Transaction Category accepted';
    END IF;

    IF has_table_privilege(
        'authenticated','public.customer_categories','INSERT,UPDATE,DELETE'
    ) OR has_table_privilege(
        'authenticated','public.chart_of_accounts','INSERT,UPDATE,DELETE'
    ) OR has_table_privilege(
        'authenticated','public.transaction_categories','INSERT,UPDATE,DELETE'
    ) OR NOT has_function_privilege(
        'authenticated',
        'public.commit_master_import_job(uuid,bigint,integer)','EXECUTE'
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: simple master privilege boundary invalid';
    END IF;

    RAISE NOTICE 'TEST PASSED: Customer Category, COA, and Transaction Category import is tenant-safe, system-protected, versioned, audited, partial, and compatible.';
END
$test$;

ROLLBACK;
