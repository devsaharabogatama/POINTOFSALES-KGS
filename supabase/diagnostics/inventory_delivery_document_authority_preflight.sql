-- SELECT-only preflight for Inventory-owned Surat Jalan.
WITH checks AS (
  SELECT 'dependency_chain'::TEXT check_name,
    CASE WHEN count(*)=2 THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('expected',2,'ledger_rows',count(*)) details
  FROM private.kgs_schema_migrations
  WHERE version IN('20260813020000','20260813140000')
  UNION ALL
  SELECT 'canonical_delivery_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('row_count',count(*))
  FROM public.sales_delivery_documents delivery
  LEFT JOIN public.sales_headers sale ON sale.company_id=delivery.company_id
    AND sale.id=delivery.sales_id
  LEFT JOIN public.sales_invoice_snapshots invoice
    ON invoice.company_id=delivery.company_id AND invoice.sales_id=delivery.sales_id
  WHERE sale.id IS NULL OR invoice.id IS NULL OR sale.fulfillment_mode<>'DELIVERY'
  UNION ALL
  SELECT 'permission_split_state','SETUP',jsonb_build_object(
    'delivery_key_exists',EXISTS(SELECT 1 FROM public.access_permission_catalog
      WHERE permission_key='inventory.delivery_documents'),
    'sales_key_exists',EXISTS(SELECT 1 FROM public.access_permission_catalog
      WHERE permission_key='sales.sales_documents'))
  UNION ALL
  SELECT 'runtime_split_state','SETUP',jsonb_build_object('missing',COALESCE(
    jsonb_agg(required.name ORDER BY required.name) FILTER(WHERE routine.oid IS NULL),
    '[]'::JSONB))
  FROM (VALUES('get_inventory_delivery_documents'),
    ('get_inventory_delivery_document'),('record_inventory_delivery_print')) required(name)
  LEFT JOIN pg_proc routine ON routine.pronamespace='public'::regnamespace
    AND routine.proname=required.name
  UNION ALL
  SELECT 'delivery_runtime_inventory','INFO',jsonb_build_object(
    'documents',count(*),'companies',count(DISTINCT company_id),
    'ready',count(*) FILTER(WHERE status='READY'))
  FROM public.sales_delivery_documents
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'SETUP' THEN 2
  WHEN 'PASS' THEN 3 ELSE 4 END,check_name;
