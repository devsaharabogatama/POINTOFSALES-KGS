-- SELECT only. Foundation is additive and never enables conversion.
WITH dependencies(signature) AS (VALUES
  ('private.convert_retail_sale_to_backoffice_order(uuid,uuid,uuid,uuid)'),
  ('private.refresh_sales_order_procurement_demand(uuid,uuid,uuid,uuid,text)'),
  ('private.acp_require_permission_capability(uuid,text,text)')
), checks AS (
  SELECT 'lineage_dependency_ledger'::text check_name,
    CASE WHEN count(*)=2 THEN 'PASS' ELSE 'BLOCKER' END status,
    2-count(*) violation_rows,jsonb_build_object('present',count(*),'expected',2) details
  FROM private.kgs_schema_migrations WHERE version IN('20260828190000','20260911130000')
  UNION ALL
  SELECT 'lineage_dependency_routines',CASE WHEN count(*) FILTER(WHERE to_regprocedure(signature) IS NULL)=0
    THEN 'PASS' ELSE 'BLOCKER' END,count(*) FILTER(WHERE to_regprocedure(signature) IS NULL),
    jsonb_build_object('missing',COALESCE(jsonb_agg(signature) FILTER(WHERE to_regprocedure(signature) IS NULL),'[]'))
  FROM dependencies
  UNION ALL
  SELECT 'lineage_installation_state',CASE WHEN EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260915140000') THEN 'INFO'
    WHEN to_regclass('public.sales_cutover_procurement_links') IS NULL THEN 'SETUP' ELSE 'BLOCKER' END,
    CASE WHEN to_regclass('public.sales_cutover_procurement_links') IS NOT NULL AND NOT EXISTS(
      SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260915140000') THEN 1 ELSE 0 END,
    jsonb_build_object('migrationApplied',EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260915140000'),'writes',false,'conversionEnabledByThisMigration',false)
)
SELECT * FROM checks ORDER BY check_name;
