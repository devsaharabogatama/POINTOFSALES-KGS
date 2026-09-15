-- Backoffice Quotation/Sales Order isolated foundation preflight. READ ONLY.
WITH required_relations(object_name) AS (
  VALUES
    ('public.companies'),
    ('public.stores'),
    ('public.warehouses'),
    ('public.customers'),
    ('public.products'),
    ('public.uoms'),
    ('public.pricelists')
),
required_unique_keys(table_name, columns) AS (
  VALUES
    ('companies', ARRAY['id']::text[]),
    ('stores', ARRAY['company_id','id']::text[]),
    ('warehouses', ARRAY['company_id','id']::text[]),
    ('customers', ARRAY['company_id','id']::text[]),
    ('products', ARRAY['company_id','id']::text[]),
    ('uoms', ARRAY['company_id','id']::text[]),
    ('pricelists', ARRAY['company_id','id']::text[])
),
actual_unique_keys AS (
  SELECT
    relation.relname AS table_name,
    array_agg(attribute.attname ORDER BY key_column.ordinality)::text[] AS columns
  FROM pg_constraint constraint_row
  JOIN pg_class relation ON relation.oid = constraint_row.conrelid
  JOIN pg_namespace relation_schema ON relation_schema.oid = relation.relnamespace
  CROSS JOIN LATERAL unnest(constraint_row.conkey)
    WITH ORDINALITY AS key_column(attnum, ordinality)
  JOIN pg_attribute attribute
    ON attribute.attrelid = relation.oid
   AND attribute.attnum = key_column.attnum
  WHERE relation_schema.nspname = 'public'
    AND constraint_row.contype IN ('p','u')
  GROUP BY relation.relname, constraint_row.oid
),
results AS (
  SELECT
    'phase_dependency'::text AS check_name,
    CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'BLOCKER' END::text AS status,
    abs(count(*) - 1)::bigint AS violation_rows,
    jsonb_build_object('requiredVersion','20260908100000','ledgerRows',count(*)) AS details
  FROM private.kgs_schema_migrations
  WHERE version = '20260908100000'

  UNION ALL

  SELECT
    'required_master_relations',
    CASE WHEN bool_and(to_regclass(object_name) IS NOT NULL) THEN 'PASS' ELSE 'BLOCKER' END,
    count(*) FILTER (WHERE to_regclass(object_name) IS NULL)::bigint,
    jsonb_build_object(
      'missing', coalesce(
        jsonb_agg(object_name) FILTER (WHERE to_regclass(object_name) IS NULL),
        '[]'::jsonb
      )
    )
  FROM required_relations

  UNION ALL

  SELECT
    'required_tenant_unique_keys',
    CASE WHEN count(*) FILTER (WHERE actual.table_name IS NULL) = 0
      THEN 'PASS' ELSE 'BLOCKER' END,
    count(*) FILTER (WHERE actual.table_name IS NULL)::bigint,
    jsonb_build_object(
      'missing', coalesce(
        jsonb_agg(required.table_name || '(' || array_to_string(required.columns,',') || ')')
          FILTER (WHERE actual.table_name IS NULL),
        '[]'::jsonb
      )
    )
  FROM required_unique_keys required
  LEFT JOIN actual_unique_keys actual
    ON actual.table_name = required.table_name
   AND actual.columns = required.columns

  UNION ALL

  SELECT
    'backoffice_order_schema_collision',
    CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,
    jsonb_build_object('existing',coalesce(jsonb_agg(object_name),'[]'::jsonb))
  FROM (VALUES
    ('public.backoffice_sales_orders'),
    ('public.backoffice_sales_order_lines'),
    ('public.backoffice_sales_order_operations'),
    ('public.backoffice_sales_order_audit')
  ) expected(object_name)
  WHERE to_regclass(object_name) IS NOT NULL

  UNION ALL

  SELECT
    'backoffice_feature_default_off',
    CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,
    jsonb_build_object('enabledCompanies',count(*))
  FROM public.company_features
  WHERE feature_code = 'backoffice_delivered_qty_sales_enabled'
    AND is_enabled

  UNION ALL

  SELECT
    'sales_permission_dependency',
    CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'BLOCKER' END,
    abs(count(*) - 1)::bigint,
    jsonb_build_object(
      'permissionKey','sales.sales_documents',
      'rows',count(*),
      'definition',coalesce(jsonb_agg(jsonb_build_object(
        'viewRoles',view_roles,
        'operatorRoles',operator_roles,
        'supportedCapabilities',supported_capabilities,
        'enforcementStatus',enforcement_status
      )),'[]'::jsonb)
    )
  FROM public.access_permission_catalog
  WHERE permission_key = 'sales.sales_documents'

  UNION ALL

  SELECT
    'active_finance_posting_queue',
    CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,
    jsonb_build_object('runCount',count(*))
  FROM public.finance_posting_queue_runs
  WHERE status IN ('PREVIEWED','APPROVED','PROCESSING')

  UNION ALL

  SELECT
    'nonterminal_offline_submission',
    CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,
    jsonb_build_object('submissionCount',count(*))
  FROM public.pos_offline_sale_submissions
  WHERE status IN ('QUEUED','SYNCING','NEEDS_CONFIRMATION')
)
SELECT check_name,status,violation_rows,details
FROM results
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,
  check_name;
