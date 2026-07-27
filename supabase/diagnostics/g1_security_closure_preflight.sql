-- G1 security-closure live audit.
-- SELECT-only. Expected result: 15 PASS rows with violation_rows = 0,
-- except migration_ledger which passes when all 9 canonical versions exist.

WITH expected_tables(table_name) AS (
    VALUES
        ('profiles'), ('companies'), ('stores'), ('pos_terminals'),
        ('company_memberships'), ('store_memberships'), ('warehouses'),
        ('products'), ('product_bundle_items'), ('product_stocks'),
        ('customers'), ('cashier_sessions'), ('sales_headers'),
        ('sales_details'), ('sales_payments'), ('purchases_headers'),
        ('purchases_details'), ('cash_advances'), ('bank_deposits'),
        ('financial_events'), ('journal_entries'), ('pos_reconciliations'),
        ('uoms'), ('product_uom_conversions'), ('product_batches'),
        ('sales_fifo_allocations'), ('stock_opnames'),
        ('stock_opname_details'), ('stock_adjustments'), ('stock_movements'),
        ('platform_features'), ('company_features'),
        ('company_feature_audit'), ('user_active_company_contexts'),
        ('user_active_company_context_audit')
), tenant_tables(table_name) AS (
    VALUES
        ('stores'), ('pos_terminals'), ('company_memberships'),
        ('store_memberships'), ('warehouses'), ('products'),
        ('product_bundle_items'), ('product_stocks'), ('customers'),
        ('cashier_sessions'), ('sales_headers'), ('sales_details'),
        ('sales_payments'), ('purchases_headers'), ('purchases_details'),
        ('cash_advances'), ('bank_deposits'), ('financial_events'),
        ('journal_entries'), ('pos_reconciliations'), ('uoms'),
        ('product_uom_conversions'), ('product_batches'),
        ('sales_fifo_allocations'), ('stock_opnames'),
        ('stock_opname_details'), ('stock_adjustments'), ('stock_movements'),
        ('company_features'), ('company_feature_audit'),
        ('user_active_company_contexts')
), expected_versions(version) AS (
    VALUES
        ('20260720090000'), ('20260720120000'), ('20260720150000'),
        ('20260720180000'), ('20260720210000'), ('20260720230000'),
        ('20260721090000'), ('20260721120000'), ('20260721150000')
), unsafe_functions(function_name) AS (
    VALUES
        ('handle_new_user'),
        ('trg_company_features_touch'),
        ('trg_company_features_audit'),
        ('trg_cash_advances_to_financial_events'),
        ('trg_bank_deposits_to_financial_events'),
        ('process_financial_events_queue'),
        ('transfer_product_stock'),
        ('private_import_products_for_company_g1_legacy'),
        ('private_create_sales_transaction_g1_legacy')
), checks AS (
    SELECT
        'canonical_tables_missing'::text AS check_name,
        count(*) FILTER (WHERE c.oid IS NULL)::bigint AS violation_rows,
        jsonb_build_object(
            'expected',count(*),
            'missing',COALESCE(
                jsonb_agg(e.table_name ORDER BY e.table_name)
                    FILTER (WHERE c.oid IS NULL),
                '[]'::jsonb
            )
        ) AS details
    FROM expected_tables e
    LEFT JOIN pg_namespace n ON n.nspname = 'public'
    LEFT JOIN pg_class c
      ON c.relnamespace = n.oid
     AND c.relname = e.table_name
     AND c.relkind IN ('r','p')

    UNION ALL

    SELECT
        'canonical_tables_without_rls',
        count(*) FILTER (
            WHERE c.oid IS NULL OR NOT c.relrowsecurity
        ),
        jsonb_build_object(
            'tables',COALESCE(
                jsonb_agg(e.table_name ORDER BY e.table_name)
                    FILTER (WHERE c.oid IS NULL OR NOT c.relrowsecurity),
                '[]'::jsonb
            )
        )
    FROM expected_tables e
    LEFT JOIN pg_namespace n ON n.nspname = 'public'
    LEFT JOIN pg_class c
      ON c.relnamespace = n.oid
     AND c.relname = e.table_name
     AND c.relkind IN ('r','p')

    UNION ALL

    SELECT
        'canonical_tables_without_policy',
        count(*) FILTER (WHERE COALESCE(p.policy_count,0) = 0),
        jsonb_build_object(
            'tables',COALESCE(
                jsonb_agg(e.table_name ORDER BY e.table_name)
                    FILTER (WHERE COALESCE(p.policy_count,0) = 0),
                '[]'::jsonb
            )
        )
    FROM expected_tables e
    LEFT JOIN (
        SELECT tablename,count(*) AS policy_count
        FROM pg_policies
        WHERE schemaname = 'public'
        GROUP BY tablename
    ) p ON p.tablename = e.table_name

    UNION ALL

    SELECT
        'tenant_company_id_nullable_or_missing',
        count(*) FILTER (
            WHERE c.column_name IS NULL OR c.is_nullable <> 'NO'
        ),
        jsonb_build_object(
            'columns',COALESCE(
                jsonb_agg(
                    jsonb_build_object(
                        'table',e.table_name,
                        'is_nullable',c.is_nullable
                    ) ORDER BY e.table_name
                ) FILTER (
                    WHERE c.column_name IS NULL OR c.is_nullable <> 'NO'
                ),
                '[]'::jsonb
            )
        )
    FROM tenant_tables e
    LEFT JOIN information_schema.columns c
      ON c.table_schema = 'public'
     AND c.table_name = e.table_name
     AND c.column_name = 'company_id'

    UNION ALL

    SELECT
        'anon_public_table_privileges',
        count(*),
        jsonb_build_object(
            'tables',COALESCE(
                jsonb_agg(e.table_name ORDER BY e.table_name),
                '[]'::jsonb
            )
        )
    FROM expected_tables e
    WHERE has_table_privilege(
        'anon','public.' || e.table_name,
        'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER'
    )

    UNION ALL

    SELECT
        'anon_public_routine_execute',
        count(*),
        jsonb_build_object(
            'routines',COALESCE(
                jsonb_agg(
                    format('%I(%s)',p.proname,pg_get_function_identity_arguments(p.oid))
                    ORDER BY p.proname
                ),
                '[]'::jsonb
            )
        )
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND has_function_privilege('anon',p.oid,'EXECUTE')

    UNION ALL

    SELECT
        'authenticated_dangerous_table_privileges',
        count(*),
        jsonb_build_object(
            'tables',COALESCE(
                jsonb_agg(e.table_name ORDER BY e.table_name),
                '[]'::jsonb
            )
        )
    FROM expected_tables e
    WHERE has_table_privilege(
        'authenticated','public.' || e.table_name,
        'TRUNCATE,REFERENCES,TRIGGER'
    )

    UNION ALL

    SELECT
        'authenticated_unsafe_rpc_execute',
        count(*),
        jsonb_build_object(
            'routines',COALESCE(
                jsonb_agg(
                    format('%I(%s)',p.proname,pg_get_function_identity_arguments(p.oid))
                    ORDER BY p.proname
                ),
                '[]'::jsonb
            )
        )
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    JOIN unsafe_functions u ON u.function_name = p.proname
    WHERE n.nspname = 'public'
      AND has_function_privilege('authenticated',p.oid,'EXECUTE')

    UNION ALL

    SELECT
        'security_definer_without_fixed_search_path',
        count(*),
        jsonb_build_object(
            'routines',COALESCE(
                jsonb_agg(
                    format('%I(%s)',p.proname,pg_get_function_identity_arguments(p.oid))
                    ORDER BY p.proname
                ),
                '[]'::jsonb
            )
        )
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.prosecdef
      AND NOT COALESCE(p.proconfig,ARRAY[]::text[])::text[]
              @> ARRAY['search_path=public, pg_temp']::text[]

    UNION ALL

    SELECT
        'active_context_without_membership',
        count(*),
        jsonb_build_object('row_count',count(*))
    FROM public.user_active_company_contexts c
    JOIN public.profiles p ON p.id = c.user_id
    WHERE p.role <> 'super_admin'::user_role
      AND NOT EXISTS (
          SELECT 1
          FROM public.company_memberships m
          WHERE m.user_id = c.user_id
            AND m.company_id = c.company_id
            AND m.status = 'ACTIVE'
      )

    UNION ALL

    SELECT
        'active_context_inactive_company',
        count(*),
        jsonb_build_object('row_count',count(*))
    FROM public.user_active_company_contexts c
    JOIN public.companies co ON co.id = c.company_id
    WHERE co.status <> 'ACTIVE'

    UNION ALL

    SELECT
        'unvalidated_canonical_tenant_fk',
        count(*),
        jsonb_build_object(
            'constraints',COALESCE(
                jsonb_agg(con.conname ORDER BY con.conname),
                '[]'::jsonb
            )
        )
    FROM pg_constraint con
    JOIN pg_class rel ON rel.oid = con.conrelid
    JOIN pg_namespace n ON n.oid = rel.relnamespace
    WHERE n.nspname = 'public'
      AND con.contype = 'f'
      AND con.conname LIKE 'fk\_%company\_%' ESCAPE '\'
      AND NOT con.convalidated

    UNION ALL

    SELECT
        'negative_product_stock',
        count(*),
        jsonb_build_object('row_count',count(*))
    FROM public.product_stocks
    WHERE stock_qty < 0

    UNION ALL

    SELECT
        'unbalanced_journal_groups',
        count(*),
        jsonb_build_object('group_count',count(*))
    FROM (
        SELECT company_id,entry_group_id
        FROM public.journal_entries
        GROUP BY company_id,entry_group_id
        HAVING COALESCE(sum(debit),0) <> COALESCE(sum(kredit),0)
    ) unbalanced

    UNION ALL

    SELECT
        'migration_ledger',
        count(*) FILTER (WHERE applied.version IS NULL),
        jsonb_build_object(
            'expected',count(*),
            'missing',COALESCE(
                jsonb_agg(e.version ORDER BY e.version)
                    FILTER (WHERE applied.version IS NULL),
                '[]'::jsonb
            )
        )
    FROM expected_versions e
    LEFT JOIN private.kgs_schema_migrations applied
      ON applied.version = e.version
)
SELECT
    check_name,
    CASE WHEN violation_rows = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
    violation_rows,
    details
FROM checks
ORDER BY CASE WHEN violation_rows > 0 THEN 1 ELSE 2 END,check_name;
