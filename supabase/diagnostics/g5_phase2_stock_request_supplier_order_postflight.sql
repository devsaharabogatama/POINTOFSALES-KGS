-- G5 phase 2 postflight: Stock Request + Supplier Order foundation.
-- SAFETY: SELECT-only and aggregate metadata only.
-- This revision uses information_schema/pg_catalog only. It contains no
-- direct query, regclass conversion, or privilege helper for public tables.

WITH required_tables(table_name) AS (
    VALUES
        ('stock_request_documents'),
        ('stock_request_lines'),
        ('supplier_order_documents'),
        ('supplier_order_lines'),
        ('supplier_order_request_allocations'),
        ('stock_request_audit'),
        ('supplier_order_audit')
), required_routines(routine_name) AS (
    VALUES
        ('save_stock_request'),
        ('submit_stock_request'),
        ('close_stock_request'),
        ('cancel_stock_request'),
        ('save_supplier_order'),
        ('confirm_supplier_order'),
        ('cancel_supplier_order')
), required_triggers(table_name,trigger_name) AS (
    VALUES
        ('stock_request_documents','g5_guard_stock_request_history'),
        ('stock_request_lines','g5_guard_stock_request_lines'),
        ('supplier_order_documents','g5_guard_supplier_order_history'),
        ('supplier_order_lines','g5_guard_supplier_order_lines'),
        ('supplier_order_request_allocations','g5_guard_supplier_order_allocations')
), table_state AS (
    SELECT required.table_name,
        relation.oid AS relation_oid,
        COALESCE(relation.relrowsecurity,FALSE) AS rls_enabled
    FROM required_tables required
    LEFT JOIN pg_catalog.pg_namespace namespace
      ON namespace.nspname='public'
    LEFT JOIN pg_catalog.pg_class relation
      ON relation.relnamespace=namespace.oid
     AND relation.relname=required.table_name
     AND relation.relkind IN('r','p')
), routine_state AS (
    SELECT required.routine_name,
        count(DISTINCT procedure.oid) AS routine_rows,
        count(DISTINCT procedure.oid) FILTER (
            WHERE lower(procedure.prosrc) ~
                '(insert into[[:space:]]+(public[.])?(stock_movements|product_batches|financial_events|journal_entries)|update[[:space:]]+(public[.])?product_stocks)'
        ) AS final_effect_rows
    FROM required_routines required
    LEFT JOIN pg_catalog.pg_namespace namespace
      ON namespace.nspname='public'
    LEFT JOIN pg_catalog.pg_proc procedure
      ON procedure.pronamespace=namespace.oid
     AND procedure.proname=required.routine_name
    GROUP BY required.routine_name
), trigger_state AS (
    SELECT required.table_name,required.trigger_name,
        count(trigger_row.event_object_table) AS trigger_rows
    FROM required_triggers required
    LEFT JOIN information_schema.triggers trigger_row
      ON trigger_row.trigger_schema='public'
     AND trigger_row.event_object_schema='public'
     AND trigger_row.event_object_table=required.table_name
     AND trigger_row.trigger_name=required.trigger_name
    GROUP BY required.table_name,required.trigger_name
), direct_write_grants AS (
    SELECT grant_row.table_name,count(*) AS grant_rows
    FROM information_schema.role_table_grants grant_row
    JOIN required_tables required ON required.table_name=grant_row.table_name
    WHERE grant_row.table_schema='public'
      AND grant_row.grantee IN('authenticated','anon','PUBLIC')
      AND grant_row.privilege_type IN('INSERT','UPDATE','DELETE','TRUNCATE')
    GROUP BY grant_row.table_name
), rpc_execute_grants AS (
    SELECT grant_row.routine_name,count(*) AS grant_rows
    FROM information_schema.routine_privileges grant_row
    JOIN required_routines required
      ON required.routine_name=grant_row.routine_name
    WHERE grant_row.specific_schema='public'
      AND grant_row.grantee='authenticated'
      AND grant_row.privilege_type='EXECUTE'
    GROUP BY grant_row.routine_name
), checks AS (
    SELECT 'migration_ledger'::TEXT AS check_name,
        CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END AS status,
        CASE WHEN count(*)=1 THEN 0 ELSE 1 END AS violation_rows,
        jsonb_build_object('ledger_rows',count(*)) AS details
    FROM private.kgs_schema_migrations migration_row
    WHERE migration_row.version='20260806010000'

    UNION ALL
    SELECT 'required_purchase_tables',
        CASE WHEN count(*) FILTER(WHERE relation_oid IS NULL)=0
             THEN 'PASS' ELSE 'FAIL' END,
        count(*) FILTER(WHERE relation_oid IS NULL),
        jsonb_build_object('expected',count(*),'missing',COALESCE(
            jsonb_agg(table_name ORDER BY table_name)
                FILTER(WHERE relation_oid IS NULL),'[]'::JSONB))
    FROM table_state

    UNION ALL
    SELECT 'required_purchase_routines',
        CASE WHEN count(*) FILTER(WHERE routine_rows=0)=0
             THEN 'PASS' ELSE 'FAIL' END,
        count(*) FILTER(WHERE routine_rows=0),
        jsonb_build_object('expected',count(*),'missing',COALESCE(
            jsonb_agg(routine_name ORDER BY routine_name)
                FILTER(WHERE routine_rows=0),'[]'::JSONB))
    FROM routine_state

    UNION ALL
    SELECT 'required_purchase_guard_triggers',
        CASE WHEN count(*) FILTER(WHERE trigger_rows=0)=0
             THEN 'PASS' ELSE 'FAIL' END,
        count(*) FILTER(WHERE trigger_rows=0),
        jsonb_build_object('expected',count(*),'missing',COALESCE(
            jsonb_agg(trigger_name ORDER BY trigger_name)
                FILTER(WHERE trigger_rows=0),'[]'::JSONB))
    FROM trigger_state

    UNION ALL
    SELECT 'purchase_table_rls',
        CASE WHEN count(*) FILTER(WHERE NOT rls_enabled)=0
             THEN 'PASS' ELSE 'FAIL' END,
        count(*) FILTER(WHERE NOT rls_enabled),
        jsonb_build_object('expected',count(*))
    FROM table_state

    UNION ALL
    SELECT 'browser_direct_purchase_write_boundary',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('direct_write_tables',COALESCE(
            jsonb_agg(table_name ORDER BY table_name),'[]'::JSONB))
    FROM direct_write_grants

    UNION ALL
    SELECT 'browser_purchase_rpc_boundary',
        CASE WHEN count(*) FILTER(WHERE COALESCE(grant_row.grant_rows,0)=0)=0
             THEN 'PASS' ELSE 'FAIL' END,
        count(*) FILTER(WHERE COALESCE(grant_row.grant_rows,0)=0),
        jsonb_build_object('expected',count(*),'missing_grants',COALESCE(
            jsonb_agg(required.routine_name ORDER BY required.routine_name)
                FILTER(WHERE COALESCE(grant_row.grant_rows,0)=0),'[]'::JSONB))
    FROM required_routines required
    LEFT JOIN rpc_execute_grants grant_row
      ON grant_row.routine_name=required.routine_name

    UNION ALL
    SELECT 'purchase_routine_zero_final_effect_contract',
        CASE WHEN COALESCE(sum(final_effect_rows),0)=0
             THEN 'PASS' ELSE 'FAIL' END,
        COALESCE(sum(final_effect_rows),0),
        jsonb_build_object('violating_routines',COALESCE(
            jsonb_agg(routine_name ORDER BY routine_name)
                FILTER(WHERE final_effect_rows>0),'[]'::JSONB))
    FROM routine_state

    UNION ALL
    SELECT 'legacy_purchase_confirmation_browser_boundary',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('authenticated_execute_grants',count(*))
    FROM information_schema.routine_privileges grant_row
    WHERE grant_row.specific_schema='public'
      AND grant_row.routine_name='confirm_purchase_order'
      AND grant_row.grantee IN('authenticated','anon','PUBLIC')
      AND grant_row.privilege_type='EXECUTE'

    UNION ALL
    SELECT 'purchase_schema_inventory','INFO',0,
        jsonb_build_object(
            'required_tables_present',count(*) FILTER(
                WHERE relation_oid IS NOT NULL),
            'required_tables_expected',count(*)
        )
    FROM table_state
)
SELECT check_name,status,violation_rows,details
FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,
    check_name;
