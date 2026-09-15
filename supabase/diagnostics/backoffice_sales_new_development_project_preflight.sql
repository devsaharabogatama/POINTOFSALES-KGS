-- New isolated Development project baseline audit. READ ONLY.
WITH required_relations(object_name) AS (
  VALUES
    ('public.companies'),
    ('public.profiles'),
    ('public.sales_headers'),
    ('public.sales_invoice_snapshots'),
    ('public.sales_delivery_documents'),
    ('public.finance_posting_queue_runs'),
    ('public.pos_offline_sale_submissions')
),
relation_state AS (
  SELECT object_name, to_regclass(object_name) IS NOT NULL AS present
  FROM required_relations
),
results AS (
  SELECT
    'development_project_identity'::text AS check_name,
    CASE
      WHEN current_database() = 'postgres' THEN 'PASS'
      ELSE 'REVIEW'
    END::text AS status,
    0::bigint AS violation_rows,
    jsonb_build_object(
      'database', current_database(),
      'serverVersion', current_setting('server_version')
    ) AS details

  UNION ALL

  SELECT
    'application_relation_baseline',
    CASE WHEN count(*) FILTER (WHERE present) = 0 THEN 'PASS' ELSE 'REVIEW' END,
    count(*) FILTER (WHERE present)::bigint,
    jsonb_build_object(
      'expectedFreshProject', true,
      'present', coalesce(
        jsonb_agg(object_name ORDER BY object_name) FILTER (WHERE present),
        '[]'::jsonb
      ),
      'missingCount', count(*) FILTER (WHERE NOT present)
    )
  FROM relation_state

  UNION ALL

  SELECT
    'supabase_migration_ledger',
    CASE
      WHEN to_regclass('supabase_migrations.schema_migrations') IS NULL
        THEN 'PASS'
      ELSE 'REVIEW'
    END,
    CASE
      WHEN to_regclass('supabase_migrations.schema_migrations') IS NULL
        THEN 0
      ELSE 1
    END::bigint,
    jsonb_build_object(
      'expectedFreshProject', true,
      'ledgerRelationExists',
        to_regclass('supabase_migrations.schema_migrations') IS NOT NULL
    )
)
SELECT check_name, status, violation_rows, details
FROM results
ORDER BY check_name;
