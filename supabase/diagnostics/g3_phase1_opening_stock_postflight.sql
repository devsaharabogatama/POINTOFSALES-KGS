-- G3 phase 1 postflight: Opening Stock schema/security/runtime contract.
-- SELECT-only. Expected result: every row PASS with violation_rows = 0.

WITH expected_tables(table_name) AS (
    VALUES
        ('opening_stock_documents'),
        ('opening_stock_lines'),
        ('opening_stock_audit')
), expected_routines(routine_name) AS (
    VALUES
        ('save_opening_stock_document'),
        ('post_opening_stock')
), checks AS (
    SELECT
        'migration_ledger'::TEXT AS check_name,
        count(*) FILTER (WHERE m.version IS NULL)::BIGINT AS violation_rows,
        jsonb_build_object('ledger_rows',count(m.version)) AS details
    FROM (VALUES('20260728120000')) expected(version)
    LEFT JOIN private.kgs_schema_migrations m
      ON m.version = expected.version

    UNION ALL

    SELECT
        'required_opening_stock_tables',
        count(*) FILTER (WHERE c.oid IS NULL),
        jsonb_build_object(
            'table_rows',count(c.oid),
            'missing',COALESCE(
                jsonb_agg(e.table_name ORDER BY e.table_name)
                    FILTER (WHERE c.oid IS NULL),
                '[]'::JSONB
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
        'opening_stock_tables_without_rls',
        count(*) FILTER (WHERE c.oid IS NULL OR NOT c.relrowsecurity),
        jsonb_build_object(
            'tables',COALESCE(
                jsonb_agg(e.table_name ORDER BY e.table_name)
                    FILTER (WHERE c.oid IS NULL OR NOT c.relrowsecurity),
                '[]'::JSONB
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
        'opening_stock_tables_without_policy',
        count(*) FILTER (WHERE COALESCE(p.policy_count,0) = 0),
        jsonb_build_object(
            'tables',COALESCE(
                jsonb_agg(e.table_name ORDER BY e.table_name)
                    FILTER (WHERE COALESCE(p.policy_count,0) = 0),
                '[]'::JSONB
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
        'required_opening_stock_routines',
        count(*) FILTER (WHERE p.oid IS NULL),
        jsonb_build_object(
            'routine_rows',count(p.oid),
            'missing',COALESCE(
                jsonb_agg(e.routine_name ORDER BY e.routine_name)
                    FILTER (WHERE p.oid IS NULL),
                '[]'::JSONB
            )
        )
    FROM expected_routines e
    LEFT JOIN pg_namespace n ON n.nspname = 'public'
    LEFT JOIN pg_proc p
      ON p.pronamespace = n.oid
     AND p.proname = e.routine_name

    UNION ALL

    SELECT
        'opening_stock_enum_contract',
        count(*) FILTER (WHERE required.label IS NULL),
        jsonb_build_object(
            'missing',COALESCE(
                jsonb_agg(expected.label ORDER BY expected.label)
                    FILTER (WHERE required.label IS NULL),
                '[]'::JSONB
            )
        )
    FROM (
        VALUES
            ('stock_movement_type','OPENING_BALANCE'),
            ('event_type','STOCK_OPENING'),
            ('event_status','HOLD')
    ) expected(type_name,label)
    LEFT JOIN (
        SELECT t.typname AS type_name,e.enumlabel AS label
        FROM pg_type t
        JOIN pg_enum e ON e.enumtypid = t.oid
    ) required
      ON required.type_name = expected.type_name
     AND required.label = expected.label

    UNION ALL

    SELECT
        'opening_stock_batch_source_column',
        CASE WHEN count(*) = 1 THEN 0 ELSE 1 END,
        jsonb_build_object('column_rows',count(*))
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'product_batches'
      AND column_name = 'opening_stock_line_id'

    UNION ALL

    SELECT
        'opening_stock_source_constraints',
        CASE WHEN count(*) = 4 THEN 0 ELSE 1 END,
        jsonb_build_object('constraint_rows',count(*))
    FROM pg_constraint
    WHERE conname IN (
        'opening_stock_documents_company_posting_key_unique',
        'opening_stock_lines_document_product_unique',
        'fk_product_batches_company_opening_stock_line',
        'product_batches_opening_stock_line_unique'
    )

    UNION ALL

    SELECT
        'opening_stock_movement_source_index',
        CASE WHEN count(*) = 1 THEN 0 ELSE 1 END,
        jsonb_build_object('index_rows',count(*))
    FROM pg_indexes
    WHERE schemaname = 'public'
      AND indexname = 'uq_stock_movements_source_product_warehouse_type'

    UNION ALL

    SELECT
        'browser_opening_stock_direct_write',
        count(*),
        jsonb_build_object(
            'tables',COALESCE(
                jsonb_agg(e.table_name ORDER BY e.table_name),
                '[]'::JSONB
            )
        )
    FROM expected_tables e
    WHERE has_table_privilege(
        'authenticated','public.' || e.table_name,
        'INSERT,UPDATE,DELETE'
    )

    UNION ALL

    SELECT
        'browser_opening_stock_rpc_boundary',
        count(*) FILTER (
            WHERE NOT has_function_privilege(
                'authenticated',p.oid,'EXECUTE'
            )
               OR has_function_privilege('anon',p.oid,'EXECUTE')
        ),
        jsonb_build_object(
            'authenticated_routines',count(*) FILTER (
                WHERE has_function_privilege('authenticated',p.oid,'EXECUTE')
            ),
            'anon_routines',count(*) FILTER (
                WHERE has_function_privilege('anon',p.oid,'EXECUTE')
            )
        )
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN (
          'save_opening_stock_document','post_opening_stock'
      )

    UNION ALL

    SELECT
        'opening_stock_security_definer_search_path',
        count(*) FILTER (
            WHERE NOT p.prosecdef
               OR NOT COALESCE(p.proconfig,ARRAY[]::TEXT[])::TEXT[]
                   @> ARRAY['search_path=public, pg_temp']::TEXT[]
        ),
        jsonb_build_object('routine_rows',count(*))
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE (
            n.nspname = 'public'
            AND p.proname IN (
                'private_opening_stock_prepare_allowed',
                'save_opening_stock_document',
                'post_opening_stock'
            )
          )
       OR (
            n.nspname = 'private'
            AND p.proname = 'resolve_opening_stock_account'
          )

    UNION ALL

    SELECT
        'invalid_opening_stock_document_state',
        count(*),
        jsonb_build_object('row_count',count(*))
    FROM public.opening_stock_documents d
    WHERE d.line_count < 0
       OR d.total_quantity_base < 0
       OR d.total_cost < 0
       OR (
           d.status = 'POSTED'
           AND (
               d.posting_idempotency_key IS NULL
               OR d.financial_event_id IS NULL
               OR d.posted_by IS NULL
               OR d.posted_at IS NULL
           )
       )

    UNION ALL

    SELECT
        'posted_opening_stock_incomplete_runtime',
        count(*),
        jsonb_build_object('document_count',count(*))
    FROM public.opening_stock_documents d
    WHERE d.status = 'POSTED'
      AND (
          NOT EXISTS (
              SELECT 1 FROM public.financial_events fe
              WHERE fe.company_id = d.company_id
                AND fe.id = d.financial_event_id
                AND fe.event_type = 'STOCK_OPENING'::public.event_type
                AND fe.status = 'HOLD'::public.event_status
          )
          OR EXISTS (
              SELECT 1 FROM public.opening_stock_lines l
              WHERE l.company_id = d.company_id
                AND l.document_id = d.id
                AND (
                    NOT EXISTS (
                        SELECT 1 FROM public.stock_movements sm
                        WHERE sm.company_id = l.company_id
                          AND sm.product_id = l.product_id
                          AND sm.warehouse_id = d.warehouse_id
                          AND sm.reference_table =
                              'opening_stock_documents'
                          AND sm.reference_id = d.id
                          AND sm.movement_type =
                              'OPENING_BALANCE'::public.stock_movement_type
                    )
                    OR NOT EXISTS (
                        SELECT 1 FROM public.product_batches pb
                        WHERE pb.company_id = l.company_id
                          AND pb.opening_stock_line_id = l.id
                    )
                )
          )
      )

    UNION ALL

    SELECT
        'opening_stock_balance_reconciliation',
        count(*),
        jsonb_build_object('pair_count',count(*))
    FROM (
        SELECT
            ps.company_id,ps.product_id,ps.warehouse_id
        FROM public.product_stocks ps
        LEFT JOIN (
            SELECT
                company_id,product_id,warehouse_id,
                sum(qty_change) AS movement_qty
            FROM public.stock_movements
            GROUP BY company_id,product_id,warehouse_id
        ) movement
          ON movement.company_id = ps.company_id
         AND movement.product_id = ps.product_id
         AND movement.warehouse_id = ps.warehouse_id
        WHERE ps.stock_qty <> COALESCE(movement.movement_qty,0)
    ) mismatch
)
SELECT
    check_name,
    CASE WHEN violation_rows = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
    violation_rows,
    details
FROM checks
ORDER BY CASE WHEN violation_rows > 0 THEN 1 ELSE 2 END,check_name;
