-- G4 phase 30 postflight: Expense request/approval foundation.
-- SELECT-only verification.

WITH required_tables(table_name) AS (
    VALUES ('expense_categories'),('expense_approval_policies'),
        ('expense_documents'),('expense_disbursements'),('expense_settlements'),
        ('expense_returns'),('cash_in_documents'),('cash_drawer_movements'),
        ('expense_audit')
), required_routines(routine_name) AS (
    VALUES ('save_expense_category'),('save_expense_approval_policy'),
        ('save_expense_draft'),('submit_expense_request'),
        ('review_expense_request'),('cancel_expense_request'),
        ('resolve_expense_approval_required'),('trg_expense_history_immutable'),
        ('provision_expense_request_defaults'),
        ('trg_provision_expense_request_defaults')
), immutable_tables(table_name) AS (
    VALUES ('expense_disbursements'),('expense_settlements'),
        ('expense_returns'),('cash_in_documents'),
        ('cash_drawer_movements'),('expense_audit')
), checks AS (
    SELECT 'migration_ledger'::text check_name,
        CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
        count(*) FILTER (WHERE version IS NULL)::bigint violation_rows,
        jsonb_build_object('ledger_rows',count(*)) details
    FROM private.kgs_schema_migrations
    WHERE version='20260803040000'

    UNION ALL
    SELECT 'required_expense_tables',
        CASE WHEN count(*) FILTER (WHERE c.oid IS NULL)=0 THEN 'PASS' ELSE 'FAIL' END,
        count(*) FILTER (WHERE c.oid IS NULL),
        jsonb_build_object('expected',count(*),'missing',COALESCE(
            jsonb_agg(t.table_name ORDER BY t.table_name)
                FILTER (WHERE c.oid IS NULL),'[]'::jsonb))
    FROM required_tables t
    LEFT JOIN pg_class c ON c.oid=to_regclass('public.'||t.table_name)

    UNION ALL
    SELECT 'required_expense_routines',
        CASE WHEN count(DISTINCT p.proname) FILTER (WHERE n.oid IS NOT NULL)
                  =count(DISTINCT r.routine_name)
             THEN 'PASS' ELSE 'FAIL' END,
        count(DISTINCT r.routine_name)-count(DISTINCT p.proname)
            FILTER (WHERE n.oid IS NOT NULL),
        jsonb_build_object('expected',count(DISTINCT r.routine_name),
            'routine_names_found',count(DISTINCT p.proname)
                FILTER (WHERE n.oid IS NOT NULL))
    FROM required_routines r
    LEFT JOIN pg_proc p ON p.proname=r.routine_name
    LEFT JOIN pg_namespace n ON n.oid=p.pronamespace
      AND n.nspname IN ('public','private')

    UNION ALL
    SELECT 'expense_feature_catalog',
        CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
        abs(count(*)-1),jsonb_build_object('catalog_rows',count(*))
    FROM public.platform_features WHERE feature_code='expense_enabled' AND is_active

    UNION ALL
    SELECT 'expense_entitlement_default_closed',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),jsonb_build_object('enabled_companies',count(*))
    FROM public.company_features
    WHERE feature_code='expense_enabled' AND is_enabled

    UNION ALL
    SELECT 'active_company_default_policy_coverage',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),jsonb_build_object('company_count',count(*))
    FROM public.companies c
    WHERE c.status='ACTIVE' AND NOT EXISTS(
        SELECT 1 FROM public.expense_approval_policies p
        WHERE p.company_id=c.id AND p.store_id IS NULL
          AND p.approval_required AND p.is_active)

    UNION ALL
    SELECT 'active_company_default_category_coverage',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),jsonb_build_object('company_count',count(*))
    FROM public.companies c
    WHERE c.status='ACTIVE' AND NOT EXISTS(
        SELECT 1 FROM public.expense_categories ec
        WHERE ec.company_id=c.id AND ec.is_system_default AND ec.is_active)

    UNION ALL
    SELECT 'default_expense_category_reference',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),jsonb_build_object('row_count',count(*))
    FROM public.expense_categories ec
    JOIN public.transaction_categories tc
      ON tc.company_id=ec.company_id AND tc.id=ec.transaction_category_id
    LEFT JOIN public.chart_of_accounts coa
      ON coa.company_id=ec.company_id AND coa.id=ec.expense_account_id
    WHERE ec.is_system_default AND (
        tc.system_key<>'EXPENSE_SETTLEMENT' OR NOT tc.is_active
        OR (ec.expense_account_id IS NOT NULL AND (
            coa.id IS NULL OR NOT coa.is_active OR NOT coa.is_postable
            OR coa.account_type NOT IN ('EXPENSE','OTHER_EXPENSE'))))

    UNION ALL
    SELECT 'expense_history_immutable_triggers',
        CASE WHEN count(DISTINCT t.table_name)=count(DISTINCT i.table_name)
             THEN 'PASS' ELSE 'FAIL' END,
        count(DISTINCT i.table_name)-count(DISTINCT t.table_name),
        jsonb_build_object('expected',count(DISTINCT i.table_name),
            'triggered_tables',count(DISTINCT t.table_name))
    FROM immutable_tables i
    LEFT JOIN (
        SELECT c.relname table_name
        FROM pg_trigger tr JOIN pg_class c ON c.oid=tr.tgrelid
        JOIN pg_namespace n ON n.oid=c.relnamespace
        WHERE n.nspname='public' AND NOT tr.tgisinternal
          AND tr.tgenabled<>'D'
          AND pg_get_triggerdef(tr.oid) ILIKE '%trg_expense_history_immutable%'
    ) t ON t.table_name=i.table_name

    UNION ALL
    SELECT 'legacy_cash_advance_trigger_retired',
        CASE WHEN count(*) FILTER (WHERE tr.tgenabled<>'D')=0
             THEN 'PASS' ELSE 'FAIL' END,
        count(*) FILTER (WHERE tr.tgenabled<>'D'),
        jsonb_build_object('trigger_rows',count(*),
            'enabled_trigger_rows',count(*) FILTER (WHERE tr.tgenabled<>'D'))
    FROM pg_trigger tr JOIN pg_class c ON c.oid=tr.tgrelid
    JOIN pg_namespace n ON n.oid=c.relnamespace
    JOIN pg_proc p ON p.oid=tr.tgfoid
    JOIN pg_namespace pn ON pn.oid=p.pronamespace
    WHERE n.nspname='public' AND c.relname='cash_advances'
      AND NOT tr.tgisinternal AND pn.nspname='public'
      AND p.proname='trg_cash_advances_to_financial_events'

    UNION ALL
    SELECT 'future_company_expense_default_trigger',
        CASE WHEN count(*)=2 THEN 'PASS' ELSE 'FAIL' END,
        abs(count(*)-2),jsonb_build_object('trigger_rows',count(*))
    FROM pg_trigger tr
    JOIN pg_class c ON c.oid=tr.tgrelid
    JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE n.nspname='public' AND c.relname='companies'
      AND NOT tr.tgisinternal AND tr.tgenabled<>'D'
      AND tr.tgname IN (
          'g4_provision_expense_request_defaults',
          'g4_provision_expense_request_defaults_on_activation'
      )

    UNION ALL
    SELECT 'browser_expense_write_boundary',
        CASE WHEN bool_or(has_table_privilege(
            'authenticated','public.'||t.table_name,'INSERT,UPDATE,DELETE'))
             THEN 'FAIL' ELSE 'PASS' END,
        count(*) FILTER (WHERE has_table_privilege(
            'authenticated','public.'||t.table_name,'INSERT,UPDATE,DELETE')),
        jsonb_build_object('table_rows',count(*),'direct_write',bool_or(
            has_table_privilege('authenticated','public.'||t.table_name,
                'INSERT,UPDATE,DELETE')))
    FROM required_tables t

    UNION ALL
    SELECT 'browser_expense_rpc_boundary',
        CASE WHEN
            has_function_privilege('authenticated',
                'public.save_expense_draft(uuid,bigint,uuid,uuid,uuid,text,uuid,text,numeric,uuid,text,text,text,date,uuid)','EXECUTE')
            AND has_function_privilege('authenticated',
                'public.submit_expense_request(uuid,bigint)','EXECUTE')
            AND has_function_privilege('authenticated',
                'public.review_expense_request(uuid,bigint,boolean,text)','EXECUTE')
            AND NOT has_function_privilege('anon',
                'public.save_expense_draft(uuid,bigint,uuid,uuid,uuid,text,uuid,text,numeric,uuid,text,text,text,date,uuid)','EXECUTE')
            THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN has_function_privilege('authenticated',
                'public.save_expense_draft(uuid,bigint,uuid,uuid,uuid,text,uuid,text,numeric,uuid,text,text,text,date,uuid)','EXECUTE')
             AND NOT has_function_privilege('anon',
                'public.save_expense_draft(uuid,bigint,uuid,uuid,uuid,text,uuid,text,numeric,uuid,text,text,text,date,uuid)','EXECUTE')
             THEN 0 ELSE 1 END,
        jsonb_build_object('guarded_request_rpcs',4)

    UNION ALL
    SELECT 'expense_cash_runtime_remains_closed',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),jsonb_build_object('event_rows',count(*))
    FROM (
        SELECT id FROM public.expense_disbursements UNION ALL
        SELECT id FROM public.expense_settlements UNION ALL
        SELECT id FROM public.expense_returns UNION ALL
        SELECT id FROM public.cash_in_documents UNION ALL
        SELECT id FROM public.cash_drawer_movements
    ) runtime_rows
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
