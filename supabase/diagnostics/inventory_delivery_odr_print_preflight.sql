-- Inventory Surat Jalan read/print compatibility preflight.
-- SAFETY: SELECT-only. No operational data is changed.
WITH checks AS (
  SELECT 'migration_dependency'::TEXT check_name,
    CASE WHEN count(*)=3 THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('expected',3,'ledgerRows',count(*),
      'requiredVersions',ARRAY['20260813150000','20260827153000','20260828130000']) details
  FROM private.kgs_schema_migrations
  WHERE version=ANY(ARRAY['20260813150000','20260827153000','20260828130000'])
  UNION ALL
  SELECT 'required_inventory_delivery_routines',
    CASE WHEN count(*)=3 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('expected',3,'routineRows',count(*))
  FROM unnest(ARRAY[
    'public.get_inventory_delivery_documents(date,date)',
    'public.get_inventory_delivery_document(uuid)',
    'public.record_inventory_delivery_print(uuid)'
  ]) signature
  WHERE to_regprocedure(signature) IS NOT NULL
  UNION ALL
  SELECT 'inventory_delivery_permission_state',
    CASE WHEN count(*)=1 AND bool_and(enforcement_status='ENFORCED')
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('rows',count(*),'statuses',COALESCE(jsonb_agg(enforcement_status),'[]'::JSONB))
  FROM public.access_permission_catalog
  WHERE permission_key='inventory.delivery_documents'
  UNION ALL
  SELECT 'odr_delivery_print_read_scope',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BACKFILL' END,
    jsonb_build_object('affectedDocuments',count(*),'companyCodes',
      COALESCE(jsonb_agg(DISTINCT company.company_code),'[]'::JSONB))
  FROM public.sales_delivery_documents delivery
  JOIN public.sales_headers sale ON sale.company_id=delivery.company_id
    AND sale.id=delivery.sales_id
  JOIN public.companies company ON company.id=delivery.company_id
  WHERE delivery.reservation_id IS NOT NULL
    AND sale.document_status='DRAFT'
    AND sale.order_runtime_status IN('CONFIRMED','RESERVED')
  UNION ALL
  SELECT 'inventory_delivery_runtime_inventory','INFO',jsonb_build_object(
    'allDocuments',count(*),
    'linkedDocuments',count(*) FILTER(WHERE reservation_id IS NOT NULL),
    'linkedReady',count(*) FILTER(WHERE reservation_id IS NOT NULL AND status='READY'))
  FROM public.sales_delivery_documents
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'BACKFILL' THEN 2
  WHEN 'PASS' THEN 3 ELSE 4 END,check_name;
