-- Read-only preflight for Delivery Return status overlay.
WITH required_relation(name) AS (VALUES
  ('sales_delivery_documents'),
  ('backoffice_sales_delivery_orders'),
  ('backoffice_sales_returns'),
  ('backoffice_sales_return_receipts')
), missing_relation AS (
  SELECT required_relation.name
  FROM required_relation
  WHERE to_regclass('public.'||required_relation.name) IS NULL
), required_routine(signature) AS (VALUES
  ('public.private_active_company_id()'),
  ('private.acp_require_permission_capability(uuid,text,text)')
), missing_routine AS (
  SELECT required_routine.signature
  FROM required_routine
  WHERE to_regprocedure(required_routine.signature) IS NULL
), collision AS (
  SELECT to_regprocedure(
    'public.get_inventory_delivery_return_overlays(date,date)') IS NOT NULL AS exists
)
SELECT 'delivery_return_overlay_required_relations' AS check_name,
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END AS status,
  count(*) AS violation_rows,
  jsonb_build_object('missing',COALESCE(jsonb_agg(name),'[]'::jsonb)) AS details
FROM missing_relation
UNION ALL
SELECT 'delivery_return_overlay_required_routines',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*),
  jsonb_build_object('missing',COALESCE(jsonb_agg(signature),'[]'::jsonb))
FROM missing_routine
UNION ALL
SELECT 'delivery_return_overlay_object_collision',
  CASE WHEN bool_or(exists) THEN 'BLOCKER' ELSE 'PASS' END,
  count(*) FILTER(WHERE exists),jsonb_build_object('existing',bool_or(exists))
FROM collision
UNION ALL
SELECT 'delivery_return_overlay_source_shape',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*),
  jsonb_build_object('invalidRows',count(*))
FROM public.backoffice_sales_returns document
WHERE NOT (
  (document.source_kind='BACKOFFICE' AND document.sales_order_id IS NOT NULL
    AND document.retail_sales_id IS NULL)
  OR
  (document.source_kind='RETAINED_RETAIL' AND document.sales_order_id IS NULL
    AND document.retail_sales_id IS NOT NULL)
);

