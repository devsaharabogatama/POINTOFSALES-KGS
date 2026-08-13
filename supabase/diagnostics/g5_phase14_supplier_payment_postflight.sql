-- G5 Phase 14 Postflight: Supplier Payment / AP Settlement foundation diagnostic.
-- SAFETY: SELECT-only; strictly read-only; no DDL or DML mutations.

WITH expected_tables(table_name) AS (
    VALUES ('supplier_payment_documents'),('supplier_payment_allocations'),
           ('supplier_payment_audit')
), expected_rpcs(rpc_name) AS (
    VALUES ('save_supplier_payment_draft'),('validate_supplier_payment'),
           ('cancel_supplier_payment')
), checks AS (
    SELECT 'g5_supplier_payment_migration_registered'::TEXT AS check_name,
           CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'FAIL' END AS status,
           jsonb_build_object('registered', count(*) = 1) AS details
    FROM private.kgs_schema_migrations
    WHERE version = '20260807150000'
    UNION ALL
    SELECT 'canonical_supplier_payment_tables',
           CASE WHEN count(*) FILTER(WHERE relation.oid IS NOT NULL) = 3
                THEN 'PASS' ELSE 'FAIL' END,
           jsonb_build_object(
               'expected', 3,
               'found', count(*) FILTER(WHERE relation.oid IS NOT NULL),
               'missing', COALESCE(jsonb_agg(expected.table_name ORDER BY expected.table_name)
                   FILTER(WHERE relation.oid IS NULL), '[]'::JSONB)
           )
    FROM expected_tables expected
    LEFT JOIN pg_catalog.pg_namespace namespace ON namespace.nspname = 'public'
    LEFT JOIN pg_catalog.pg_class relation
      ON relation.relnamespace = namespace.oid
     AND relation.relname = expected.table_name
     AND relation.relkind IN ('r','p')
    UNION ALL
    SELECT 'supplier_payment_rls_enabled',
           CASE WHEN count(*) FILTER(WHERE relation.relrowsecurity) = 3
                THEN 'PASS' ELSE 'FAIL' END,
           jsonb_build_object(
               'expected', 3,
               'rls_active', count(*) FILTER(WHERE relation.relrowsecurity)
           )
    FROM expected_tables expected
    JOIN pg_catalog.pg_namespace namespace ON namespace.nspname = 'public'
    JOIN pg_catalog.pg_class relation
      ON relation.relnamespace = namespace.oid
     AND relation.relname = expected.table_name
    UNION ALL
    SELECT 'supplier_payment_rpcs',
           CASE WHEN count(*) FILTER(WHERE proc.oid IS NOT NULL) = 3
                THEN 'PASS' ELSE 'FAIL' END,
           jsonb_build_object(
               'expected', 3,
               'found', count(*) FILTER(WHERE proc.oid IS NOT NULL),
               'missing', COALESCE(jsonb_agg(expected.rpc_name ORDER BY expected.rpc_name)
                   FILTER(WHERE proc.oid IS NULL), '[]'::JSONB)
           )
    FROM expected_rpcs expected
    LEFT JOIN pg_catalog.pg_namespace namespace ON namespace.nspname = 'public'
    LEFT JOIN pg_catalog.pg_proc proc
      ON proc.pronamespace = namespace.oid
     AND proc.proname = expected.rpc_name
    UNION ALL
    SELECT 'supplier_payment_direct_write_boundary',
           CASE WHEN has_table_privilege('authenticated','public.supplier_payment_documents','INSERT') = FALSE
                 AND has_table_privilege('authenticated','public.supplier_payment_documents','UPDATE') = FALSE
                 AND has_table_privilege('authenticated','public.supplier_payment_allocations','INSERT') = FALSE
                THEN 'PASS' ELSE 'FAIL' END,
           jsonb_build_object(
               'doc_insert', has_table_privilege('authenticated','public.supplier_payment_documents','INSERT'),
               'doc_update', has_table_privilege('authenticated','public.supplier_payment_documents','UPDATE'),
               'alloc_insert', has_table_privilege('authenticated','public.supplier_payment_allocations','INSERT')
           )
)
SELECT check_name, status, details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END, check_name;
