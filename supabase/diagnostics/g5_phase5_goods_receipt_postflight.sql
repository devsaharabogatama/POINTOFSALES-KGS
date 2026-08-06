-- G5 phase 5 postflight: canonical Goods Receipt foundation + trigger fix.
-- SAFETY: SELECT-only; aggregate metadata and invariant counts only.

WITH checks(check_name,status,violation_rows,details) AS (
    SELECT
        'migration_ledger',
        CASE WHEN count(m.version)=2 THEN 'PASS' ELSE 'FAIL' END,
        2-count(m.version),
        jsonb_build_object(
            'expected',2,
            'ledger_rows',count(m.version),
            'missing',COALESCE(
                jsonb_agg(v.version ORDER BY v.version)
                    FILTER (WHERE m.version IS NULL),
                '[]'::jsonb
            )
        )
    FROM (VALUES ('20260806040000'),('20260806050000')) AS v(version)
    LEFT JOIN private.kgs_schema_migrations AS m
      ON m.version=v.version

    UNION ALL

    SELECT
        'required_goods_receipt_tables',
        CASE WHEN count(c.oid)=5 THEN 'PASS' ELSE 'FAIL' END,
        5-count(c.oid),
        jsonb_build_object(
            'expected',5,
            'table_rows',count(c.oid),
            'missing',COALESCE(
                jsonb_agg(v.table_name ORDER BY v.table_name)
                    FILTER (WHERE c.oid IS NULL),
                '[]'::jsonb
            )
        )
    FROM (
        VALUES
            ('goods_receipt_documents'),
            ('goods_receipt_lines'),
            ('goods_receipt_condition_allocations'),
            ('goods_receipt_ap_provisionals'),
            ('goods_receipt_audit')
    ) AS v(table_name)
    LEFT JOIN pg_catalog.pg_namespace AS n
      ON n.nspname='public'
    LEFT JOIN pg_catalog.pg_class AS c
      ON c.relnamespace=n.oid
     AND c.relname=v.table_name
     AND c.relkind IN ('r','p')

    UNION ALL

    SELECT
        'required_goods_receipt_routines',
        CASE WHEN count(p.oid)=3 THEN 'PASS' ELSE 'FAIL' END,
        3-count(p.oid),
        jsonb_build_object(
            'expected',3,
            'routine_rows',count(p.oid),
            'missing',COALESCE(
                jsonb_agg(v.routine_name ORDER BY v.routine_name)
                    FILTER (WHERE p.oid IS NULL),
                '[]'::jsonb
            )
        )
    FROM (
        VALUES
            ('save_goods_receipt'),
            ('post_goods_receipt'),
            ('cancel_goods_receipt')
    ) AS v(routine_name)
    LEFT JOIN pg_catalog.pg_namespace AS n
      ON n.nspname='public'
    LEFT JOIN pg_catalog.pg_proc AS p
      ON p.pronamespace=n.oid
     AND p.proname=v.routine_name

    UNION ALL

    SELECT
        'goods_receipt_history_trigger_fix',
        CASE WHEN count(p.oid)=1
                  AND bool_and(p.prosrc LIKE '%ELSIF TG_TABLE_NAME=%')
             THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN count(p.oid)=1
                  AND bool_and(p.prosrc LIKE '%ELSIF TG_TABLE_NAME=%')
             THEN 0 ELSE 1 END,
        jsonb_build_object('routine_rows',count(p.oid))
    FROM pg_catalog.pg_proc AS p
    JOIN pg_catalog.pg_namespace AS n
      ON n.oid=p.pronamespace
    WHERE n.nspname='private'
      AND p.proname='trg_g5_goods_receipt_history_guard'

    UNION ALL

    SELECT
        'goods_receipt_table_rls',
        CASE WHEN count(*) FILTER (WHERE NOT c.relrowsecurity)=0
             THEN 'PASS' ELSE 'FAIL' END,
        count(*) FILTER (WHERE NOT c.relrowsecurity),
        jsonb_build_object('table_rows',count(*))
    FROM pg_catalog.pg_class AS c
    JOIN pg_catalog.pg_namespace AS n
      ON n.oid=c.relnamespace
    WHERE n.nspname='public'
      AND c.relname IN (
          'goods_receipt_documents','goods_receipt_lines',
          'goods_receipt_condition_allocations',
          'goods_receipt_ap_provisionals','goods_receipt_audit'
      )

    UNION ALL

    SELECT
        'browser_direct_goods_receipt_write_boundary',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),
        jsonb_build_object(
            'direct_write_tables',COALESCE(
                jsonb_agg(DISTINCT g.table_name ORDER BY g.table_name),
                '[]'::jsonb
            )
        )
    FROM information_schema.role_table_grants AS g
    WHERE g.table_schema='public'
      AND g.table_name IN (
          'goods_receipt_documents','goods_receipt_lines',
          'goods_receipt_condition_allocations',
          'goods_receipt_ap_provisionals','goods_receipt_audit'
      )
      AND g.grantee IN ('authenticated','anon','PUBLIC')
      AND g.privilege_type IN ('INSERT','UPDATE','DELETE','TRUNCATE')

    UNION ALL

    SELECT
        'browser_goods_receipt_rpc_boundary',
        CASE WHEN count(DISTINCT g.routine_name)=3 THEN 'PASS' ELSE 'FAIL' END,
        3-count(DISTINCT g.routine_name),
        jsonb_build_object(
            'expected',3,
            'authenticated_execute_rows',count(DISTINCT g.routine_name)
        )
    FROM information_schema.routine_privileges AS g
    WHERE g.specific_schema='public'
      AND g.routine_name IN (
          'save_goods_receipt','post_goods_receipt','cancel_goods_receipt'
      )
      AND g.grantee='authenticated'
      AND g.privilege_type='EXECUTE'

    UNION ALL

    SELECT
        'posted_receipt_stock_movement_coverage',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),
        jsonb_build_object('allocation_count',count(*))
    FROM public.goods_receipt_condition_allocations AS a
    JOIN public.goods_receipt_lines AS l
      ON l.company_id=a.company_id
     AND l.id=a.receipt_line_id
    JOIN public.goods_receipt_documents AS d
      ON d.company_id=l.company_id
     AND d.id=l.document_id
     AND d.status='POSTED'
    WHERE a.condition_type IN ('GOOD','DAMAGED')
      AND NOT EXISTS (
          SELECT 1
          FROM public.stock_movements AS sm
          WHERE sm.company_id=a.company_id
            AND sm.source_line_id=a.id
            AND sm.movement_type='PURCHASE'
      )

    UNION ALL

    SELECT
        'posted_receipt_fifo_coverage',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),
        jsonb_build_object('allocation_count',count(*))
    FROM public.goods_receipt_condition_allocations AS a
    JOIN public.goods_receipt_lines AS l
      ON l.company_id=a.company_id
     AND l.id=a.receipt_line_id
    JOIN public.goods_receipt_documents AS d
      ON d.company_id=l.company_id
     AND d.id=l.document_id
     AND d.status='POSTED'
    WHERE a.condition_type IN ('GOOD','DAMAGED')
      AND (
          a.product_batch_id IS NULL
          OR NOT EXISTS (
              SELECT 1
              FROM public.product_batches AS b
              WHERE b.company_id=a.company_id
                AND b.id=a.product_batch_id
                AND b.goods_receipt_condition_allocation_id=a.id
          )
      )

    UNION ALL

    SELECT
        'posted_receipt_finance_hold_coverage',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),
        jsonb_build_object('receipt_count',count(*))
    FROM public.goods_receipt_documents AS d
    LEFT JOIN public.financial_events AS f
      ON f.company_id=d.company_id
     AND f.id=d.financial_event_id
    WHERE d.status='POSTED'
      AND (
          f.id IS NULL
          OR f.status<>'HOLD'
          OR f.system_event_key<>'GOODS_RECEIPT'
      )

    UNION ALL

    SELECT
        'posted_receipt_ap_reconciliation',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),
        jsonb_build_object('receipt_count',count(*))
    FROM (
        SELECT d.id
        FROM public.goods_receipt_documents AS d
        LEFT JOIN public.goods_receipt_ap_provisionals AS ap
          ON ap.company_id=d.company_id
         AND ap.receipt_id=d.id
        WHERE d.status='POSTED'
        GROUP BY d.id,d.provisional_ap_total
        HAVING COALESCE(sum(ap.amount),0)<>d.provisional_ap_total
    ) AS mismatch

    UNION ALL

    SELECT
        'goods_receipt_runtime_inventory',
        'INFO',
        0::bigint,
        jsonb_build_object(
            'documents',(SELECT count(*) FROM public.goods_receipt_documents),
            'posted',(SELECT count(*) FROM public.goods_receipt_documents
                      WHERE status='POSTED'),
            'receipt_lines',(SELECT count(*) FROM public.goods_receipt_lines),
            'condition_allocations',(
                SELECT count(*)
                FROM public.goods_receipt_condition_allocations
            ),
            'open_ap_provisionals',(
                SELECT count(*)
                FROM public.goods_receipt_ap_provisionals
                WHERE status='OPEN'
            )
        )
)
SELECT check_name,status,violation_rows,details
FROM checks
ORDER BY
    CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,
    check_name;
