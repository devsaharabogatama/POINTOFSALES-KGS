-- SELECT only; use only AFTER 20260915140000. Zero links are NOT behavioral PASS.
WITH expected(signature) AS (VALUES
  ('private.trg_guard_sales_cutover_procurement_link()'),
  ('private.link_sales_cutover_procurement(uuid,uuid,uuid,uuid,uuid)'),
  ('public.get_backoffice_sales_order_procurement_links(uuid)')
), checks AS (
  SELECT 'lineage_migration_ledger'::text check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,1-count(*) violation_rows,
    jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260915140000'
  UNION ALL
  SELECT 'lineage_required_routines',CASE WHEN count(*) FILTER(WHERE to_regprocedure(signature) IS NULL)=0
    THEN 'PASS' ELSE 'FAIL' END,count(*) FILTER(WHERE to_regprocedure(signature) IS NULL),
    jsonb_build_object('missing',COALESCE(jsonb_agg(signature) FILTER(WHERE to_regprocedure(signature) IS NULL),'[]'))
  FROM expected
  UNION ALL
  SELECT 'lineage_private_boundary',CASE WHEN has_function_privilege('authenticated',
    'private.link_sales_cutover_procurement(uuid,uuid,uuid,uuid,uuid)','EXECUTE')
    OR has_function_privilege('anon','public.get_backoffice_sales_order_procurement_links(uuid)','EXECUTE')
    THEN 'FAIL' ELSE 'PASS' END,
    CASE WHEN has_function_privilege('authenticated','private.link_sales_cutover_procurement(uuid,uuid,uuid,uuid,uuid)','EXECUTE')
      OR has_function_privilege('anon','public.get_backoffice_sales_order_procurement_links(uuid)','EXECUTE') THEN 1 ELSE 0 END,
    jsonb_build_object('authenticatedRead',has_function_privilege('authenticated',
      'public.get_backoffice_sales_order_procurement_links(uuid)','EXECUTE'))
  UNION ALL
  SELECT 'lineage_table_boundary',CASE WHEN relation.relrowsecurity
    AND NOT has_table_privilege('authenticated',relation.oid,'SELECT,INSERT,UPDATE,DELETE')
    THEN 'PASS' ELSE 'FAIL' END,CASE WHEN relation.relrowsecurity
    AND NOT has_table_privilege('authenticated',relation.oid,'SELECT,INSERT,UPDATE,DELETE') THEN 0 ELSE 1 END,
    jsonb_build_object('rls',relation.relrowsecurity,'clientDirectAccess',has_table_privilege(
      'authenticated',relation.oid,'SELECT,INSERT,UPDATE,DELETE'))
  FROM pg_class relation WHERE relation.oid='public.sales_cutover_procurement_links'::regclass
  UNION ALL
  SELECT 'lineage_scope_integrity',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('invalidLinks',count(*))
  FROM public.sales_cutover_procurement_links link
  JOIN public.sales_order_procurement_demand_lines line ON line.company_id=link.company_id AND line.id=link.source_demand_line_id
  JOIN public.backoffice_sales_orders target ON target.company_id=link.company_id AND target.id=link.target_sales_order_id
  JOIN public.backoffice_sales_order_operations operation ON operation.company_id=link.company_id
    AND operation.operation_id=link.operation_id
  WHERE line.sales_id<>link.source_sales_id
    OR operation.sales_order_id<>target.id OR operation.actor_id<>link.actor_id
  UNION ALL
  SELECT 'lineage_runtime_inventory','INFO',0,jsonb_build_object('links',count(*),
    'targetOrders',count(DISTINCT target_sales_order_id),'behaviorEvidence',false)
  FROM public.sales_cutover_procurement_links
)
SELECT * FROM checks ORDER BY check_name;
