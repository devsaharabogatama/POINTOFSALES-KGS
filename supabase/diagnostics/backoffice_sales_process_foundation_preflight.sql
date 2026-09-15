-- Backoffice Sales process identity foundation preflight (read only).
WITH results AS (
  SELECT 'active_finance_posting_queue'::text check_name,
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END::text status,
    count(*)::bigint violation_rows,jsonb_build_object('runCount',count(*)) details
  FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'nonterminal_offline_submission',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('submissionCount',count(*))
  FROM public.pos_offline_sale_submissions
  WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
  UNION ALL
  SELECT 'foundation_dependency',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END,abs(1-count(*))::bigint,
    jsonb_build_object('requiredVersion','20260907100000','ledgerRows',count(*))
  FROM private.kgs_schema_migrations WHERE version='20260907100000'
  UNION ALL
  SELECT 'process_identity_schema_collision',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('existingColumns',coalesce(jsonb_agg(column_name),'[]'::jsonb))
  FROM information_schema.columns
  WHERE table_schema='public' AND table_name='sales_headers'
    AND column_name IN('sales_origin','sales_process_mode')
  UNION ALL
  SELECT 'process_feature_catalog_collision',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('featureCode','backoffice_delivered_qty_sales_enabled','rows',count(*))
  FROM public.platform_features
  WHERE feature_code='backoffice_delivered_qty_sales_enabled'
  UNION ALL
  SELECT 'sales_document_permission_dependency',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END,abs(1-count(*))::bigint,
    jsonb_build_object('permissionKey','sales.sales_documents','rows',count(*))
  FROM public.access_permission_catalog WHERE permission_key='sales.sales_documents'
  UNION ALL
  SELECT 'existing_sales_inventory','INFO',0,jsonb_build_object(
    'sales',(SELECT count(*) FROM public.sales_headers),
    'invoiceSnapshots',(SELECT count(*) FROM public.sales_invoice_snapshots),
    'deliveryDocuments',(SELECT count(*) FROM public.sales_delivery_documents),
    'reservations',(SELECT count(*) FROM public.sales_stock_reservations))
)
SELECT check_name,status,violation_rows,details FROM results
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
