-- G6 corrective phase 4 postflight: atomic STOCK_OPENING event posting.
-- SAFETY: SELECT-only; aggregate metadata/configuration only.

WITH required_routines(schema_name,routine_name) AS (
    VALUES
        ('private','provision_g6_posting_configuration'),
        ('private','resolve_financial_event_amount'),
        ('private','resolve_financial_event_account'),
        ('private','post_financial_event_core'),
        ('public','post_financial_event_by_id')
), active_stock_opening_categories AS (
    SELECT category.company_id,category.id AS transaction_category_id
    FROM public.transaction_categories category
    JOIN public.companies company ON company.id = category.company_id
    WHERE company.status = 'ACTIVE'
      AND category.is_active
      AND category.system_key = 'STOCK_OPENING'
), approved_rule_state AS (
    SELECT
        category.company_id,category.transaction_category_id,
        count(rule_set.id) AS rule_set_count
    FROM active_stock_opening_categories category
    LEFT JOIN public.posting_rule_sets rule_set
      ON rule_set.company_id = category.company_id
     AND rule_set.transaction_category_id = category.transaction_category_id
     AND rule_set.system_key = 'STOCK_OPENING'
     AND rule_set.status = 'APPROVED'
     AND rule_set.effective_to IS NULL
    GROUP BY category.company_id,category.transaction_category_id
), checks AS (
    SELECT
        'migration_ledger'::TEXT AS check_name,
        CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'FAIL' END AS status,
        count(*) FILTER (WHERE version IS NULL) AS violation_rows,
        jsonb_build_object('ledger_rows',count(*)) AS details
    FROM private.kgs_schema_migrations
    WHERE version = '20260810200000'

    UNION ALL

    SELECT
        'required_single_event_routines',
        CASE WHEN count(routine.oid) = count(*) THEN 'PASS' ELSE 'FAIL' END,
        count(*) FILTER (WHERE routine.oid IS NULL),
        jsonb_build_object(
            'expected',count(*),
            'missing',COALESCE(
                jsonb_agg(
                    expected.schema_name || '.' || expected.routine_name
                    ORDER BY expected.schema_name,expected.routine_name
                ) FILTER (WHERE routine.oid IS NULL),'[]'::JSONB
            )
        )
    FROM required_routines expected
    LEFT JOIN pg_namespace namespace
      ON namespace.nspname = expected.schema_name
    LEFT JOIN pg_proc routine
      ON routine.pronamespace = namespace.oid
     AND routine.proname = expected.routine_name

    UNION ALL

    SELECT
        'financial_event_posted_enum',
        CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN count(*) = 1 THEN 0 ELSE 1 END,
        jsonb_build_object('enum_rows',count(*))
    FROM pg_enum enum_state
    JOIN pg_type type_state ON type_state.oid = enum_state.enumtypid
    JOIN pg_namespace namespace ON namespace.oid = type_state.typnamespace
    WHERE namespace.nspname = 'public'
      AND type_state.typname = 'event_status'
      AND enum_state.enumlabel = 'POSTED'

    UNION ALL

    SELECT
        'active_company_stock_opening_rule_coverage',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),
        jsonb_build_object(
            'invalid_category_rows',count(*),
            'companies_affected',count(DISTINCT company_id)
        )
    FROM approved_rule_state
    WHERE rule_set_count <> 1

    UNION ALL

    SELECT
        'stock_opening_rule_line_contract',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),
        jsonb_build_object('invalid_rule_sets',count(*))
    FROM public.posting_rule_sets rule_set
    WHERE rule_set.system_key = 'STOCK_OPENING'
      AND rule_set.status = 'APPROVED'
      AND (
          (SELECT count(*) FROM public.posting_rule_lines line
           WHERE line.company_id = rule_set.company_id
             AND line.rule_set_id = rule_set.id) <> 2
          OR NOT EXISTS (
              SELECT 1 FROM public.posting_rule_lines line
              WHERE line.company_id = rule_set.company_id
                AND line.rule_set_id = rule_set.id
                AND line.line_no = 1
                AND line.account_function_key = 'INVENTORY_ASSET'
                AND line.entry_side = 'DEBIT'
                AND line.amount_expression_key =
                    'STOCK_OPENING_INVENTORY'
          )
          OR NOT EXISTS (
              SELECT 1 FROM public.posting_rule_lines line
              WHERE line.company_id = rule_set.company_id
                AND line.rule_set_id = rule_set.id
                AND line.line_no = 2
                AND line.account_function_key =
                    'OPENING_BALANCE_CLEARING'
                AND line.entry_side = 'CREDIT'
                AND line.amount_expression_key =
                    'STOCK_OPENING_CLEARING'
          )
      )

    UNION ALL

    SELECT
        'stock_opening_account_mapping_coverage',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),
        jsonb_build_object('missing_or_ambiguous_rows',count(*))
    FROM (
        SELECT
            category.company_id,category.transaction_category_id,
            required_function.function_key,count(rule.id) AS rule_count
        FROM active_stock_opening_categories category
        CROSS JOIN (
            VALUES ('INVENTORY_ASSET'),('OPENING_BALANCE_CLEARING')
        ) required_function(function_key)
        LEFT JOIN public.transaction_account_rules rule
          ON rule.company_id = category.company_id
         AND rule.transaction_category_id = category.transaction_category_id
         AND rule.system_key = 'STOCK_OPENING'
         AND rule.account_function_key = required_function.function_key
         AND rule.status = 'ACTIVE'
         AND rule.effective_to IS NULL
        GROUP BY
            category.company_id,category.transaction_category_id,
            required_function.function_key
        HAVING count(rule.id) <> 1
    ) invalid_mapping

    UNION ALL

    SELECT
        'company_posting_configuration_trigger',
        CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN count(*) = 1 THEN 0 ELSE 1 END,
        jsonb_build_object('trigger_rows',count(*))
    FROM pg_trigger trigger_state
    JOIN pg_class relation ON relation.oid = trigger_state.tgrelid
    JOIN pg_namespace namespace ON namespace.oid = relation.relnamespace
    WHERE namespace.nspname = 'public'
      AND relation.relname = 'companies'
      AND trigger_state.tgname = 'g6_provision_posting_configuration'
      AND NOT trigger_state.tgisinternal
      AND trigger_state.tgenabled <> 'D'

    UNION ALL

    SELECT
        'browser_single_event_rpc_boundary',
        CASE WHEN
            NOT has_function_privilege(
                'anon','public.post_financial_event_by_id(uuid,bigint)',
                'EXECUTE'
            )
            AND has_function_privilege(
                'authenticated',
                'public.post_financial_event_by_id(uuid,bigint)','EXECUTE'
            )
            THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN
            NOT has_function_privilege(
                'anon','public.post_financial_event_by_id(uuid,bigint)',
                'EXECUTE'
            )
            AND has_function_privilege(
                'authenticated',
                'public.post_financial_event_by_id(uuid,bigint)','EXECUTE'
            )
            THEN 0 ELSE 1 END,
        jsonb_build_object(
            'anon_execute',has_function_privilege(
                'anon','public.post_financial_event_by_id(uuid,bigint)',
                'EXECUTE'
            ),
            'authenticated_execute',has_function_privilege(
                'authenticated',
                'public.post_financial_event_by_id(uuid,bigint)','EXECUTE'
            )
        )

    UNION ALL

    SELECT
        'private_single_event_routine_boundary',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),
        jsonb_build_object('browser_executable_rows',count(*))
    FROM pg_proc routine
    JOIN pg_namespace namespace ON namespace.oid = routine.pronamespace
    WHERE namespace.nspname = 'private'
      AND routine.proname IN (
          'provision_g6_posting_configuration',
          'resolve_financial_event_amount',
          'resolve_financial_event_account','post_financial_event_core'
      )
      AND (
          has_function_privilege('anon',routine.oid,'EXECUTE')
          OR has_function_privilege('authenticated',routine.oid,'EXECUTE')
      )

    UNION ALL

    SELECT
        'existing_hold_event_no_early_posting',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),
        jsonb_build_object('event_count',count(DISTINCT event.id))
    FROM public.financial_events event
    JOIN public.finance_journals journal
      ON journal.company_id = event.company_id
     AND journal.financial_event_id = event.id
    WHERE event.status::TEXT = 'HOLD'

    UNION ALL

    SELECT
        'phase4_runtime_inventory',
        'INFO',0,
        jsonb_build_object(
            'hold_events',(
                SELECT count(*) FROM public.financial_events
                WHERE status::TEXT = 'HOLD'
            ),
            'posted_events',(
                SELECT count(*) FROM public.financial_events
                WHERE status::TEXT = 'POSTED'
            ),
            'canonical_journals',(
                SELECT count(*) FROM public.finance_journals
            ),
            'stock_opening_rule_sets',(
                SELECT count(*) FROM public.posting_rule_sets
                WHERE system_key = 'STOCK_OPENING' AND status = 'APPROVED'
            )
        )
)
SELECT check_name,status,violation_rows,details
FROM checks
ORDER BY
    CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,
    check_name;
