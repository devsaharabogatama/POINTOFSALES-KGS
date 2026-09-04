-- Sales Invoice revision activity and human-readable linkage preflight.
-- SAFETY: SELECT-only.
WITH checks AS (
  SELECT 'revision_dependency'::TEXT check_name,
    CASE WHEN count(*)=3 THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('expected',3,'ledgerRows',count(*),'requiredVersions',
      ARRAY['20260903100000','20260903110000','20260903120000']) details
  FROM private.kgs_schema_migrations
  WHERE version IN('20260903100000','20260903110000','20260903120000')
  UNION ALL
  SELECT 'revision_activity_schema','PASS',jsonb_build_object(
    'revisionRows',(SELECT count(*) FROM public.sales_order_revisions),
    'revisionAuditRows',(SELECT count(*) FROM public.sales_order_revision_audit),
    'invoiceRows',(SELECT count(*) FROM public.sales_invoice_snapshots))
  UNION ALL
  SELECT 'sales_document_activity_runtime',
    CASE WHEN to_regprocedure('public.get_sales_document_activity()') IS NULL
      THEN 'SETUP' ELSE 'PASS' END,
    jsonb_build_object('routineExists',
      to_regprocedure('public.get_sales_document_activity()') IS NOT NULL)
  UNION ALL
  SELECT 'revision_link_actor_runtime',
    CASE WHEN position('startedByName' IN COALESCE(pg_get_functiondef(
      to_regprocedure('public.get_sales_order_revision_links()')),''))>0
      THEN 'PASS' ELSE 'SETUP' END,
    jsonb_build_object('actorNamesExposed',position('startedByName' IN COALESCE(
      pg_get_functiondef(to_regprocedure(
        'public.get_sales_order_revision_links()')),''))>0)
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'SETUP' THEN 2 ELSE 3 END,
  check_name;
