-- Backoffice delivered-quantity Sales: Phase 0 compatibility preflight.
-- READ ONLY. Expected SETUP/REVIEW rows describe work still required.

WITH
constraint_state AS (
  SELECT con.conrelid,con.conname,pg_get_constraintdef(con.oid) definition
  FROM pg_constraint con
  WHERE con.conrelid IN (
    'public.sales_headers'::regclass,
    'public.sales_invoice_snapshots'::regclass,
    'public.sales_delivery_documents'::regclass,
    'public.sales_stock_reservations'::regclass)
),
column_state AS (
  SELECT table_name,column_name,is_nullable
  FROM information_schema.columns
  WHERE table_schema='public' AND table_name IN(
    'sales_headers','sales_invoice_snapshots',
    'sales_delivery_documents','sales_stock_reservations')
),
routine_state AS (
  SELECT n.nspname schema_name,p.proname,
    pg_get_function_identity_arguments(p.oid) identity_arguments,
    pg_get_functiondef(p.oid) definition
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE (n.nspname,p.proname) IN(
    ('private','ensure_confirmed_order_documents'),
    ('public','confirm_pos_sales_order'),
    ('public','dispatch_sales_delivery'),
    ('public','confirm_sales_delivery_received'),
    ('public','get_inventory_stock_overview'))
),
results AS (
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
  SELECT 'backoffice_sales_feature_default_off',
    CASE
      WHEN count(*) FILTER(WHERE f.feature_code='backoffice_delivered_qty_sales_enabled')=0 THEN 'SETUP'
      WHEN count(*) FILTER(WHERE f.feature_code='backoffice_delivered_qty_sales_enabled' AND cf.is_enabled)=0 THEN 'PASS'
      ELSE 'BLOCKER' END,
    count(*) FILTER(WHERE f.feature_code='backoffice_delivered_qty_sales_enabled' AND cf.is_enabled)::bigint,
    jsonb_build_object(
      'catalogRows',count(*) FILTER(WHERE f.feature_code='backoffice_delivered_qty_sales_enabled'),
      'enabledCompanies',count(*) FILTER(WHERE f.feature_code='backoffice_delivered_qty_sales_enabled' AND cf.is_enabled),
      'requiredDefault','OFF')
  FROM public.platform_features f
  LEFT JOIN public.company_features cf ON cf.feature_code=f.feature_code

  UNION ALL
  SELECT 'sales_document_permission_dependency',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END,abs(1-count(*))::bigint,
    jsonb_build_object('permissionKey','sales.sales_documents','rows',count(*))
  FROM public.access_permission_catalog WHERE permission_key='sales.sales_documents'

  UNION ALL
  SELECT 'sales_header_backoffice_source_boundary',
    CASE WHEN EXISTS(SELECT 1 FROM column_state WHERE table_name='sales_headers'
      AND column_name='session_id' AND is_nullable='NO')
      OR NOT EXISTS(SELECT 1 FROM constraint_state
        WHERE conrelid='public.sales_headers'::regclass AND definition ILIKE '%BACKOFFICE_SALES%')
      THEN 'SETUP' ELSE 'PASS' END,0,
    jsonb_build_object(
      'cashierSessionRequired',EXISTS(SELECT 1 FROM column_state WHERE table_name='sales_headers'
        AND column_name='session_id' AND is_nullable='NO'),
      'sourceConstraintSupportsBackoffice',EXISTS(SELECT 1 FROM constraint_state
        WHERE conrelid='public.sales_headers'::regclass AND definition ILIKE '%BACKOFFICE_SALES%'),
      'rule','Backoffice Sales must not fabricate a Cashier Session')

  UNION ALL
  SELECT 'invoice_multiple_per_sales_boundary',
    CASE WHEN EXISTS(SELECT 1 FROM constraint_state
      WHERE conrelid='public.sales_invoice_snapshots'::regclass
        AND definition ILIKE '%UNIQUE%company_id%sales_id%') THEN 'SETUP' ELSE 'PASS' END,0,
    jsonb_build_object('singleInvoiceConstraintPresent',EXISTS(SELECT 1 FROM constraint_state
      WHERE conrelid='public.sales_invoice_snapshots'::regclass
        AND definition ILIKE '%UNIQUE%company_id%sales_id%'),
      'requiredCardinality','one Sales Order to zero or many Invoices')

  UNION ALL
  SELECT 'delivery_before_invoice_boundary',
    CASE WHEN EXISTS(SELECT 1 FROM column_state WHERE table_name='sales_delivery_documents'
      AND column_name='invoice_snapshot_id' AND is_nullable='NO') THEN 'SETUP' ELSE 'PASS' END,0,
    jsonb_build_object('invoiceSnapshotRequired',EXISTS(SELECT 1 FROM column_state
      WHERE table_name='sales_delivery_documents' AND column_name='invoice_snapshot_id'
        AND is_nullable='NO'),
      'requiredOrder','Sales Order -> Delivery Order -> Customer Received -> Invoice')

  UNION ALL
  SELECT 'delivery_multiple_per_sales_boundary',
    CASE WHEN EXISTS(SELECT 1 FROM constraint_state
      WHERE conrelid='public.sales_delivery_documents'::regclass
        AND definition ILIKE '%UNIQUE%company_id%sales_id%') THEN 'SETUP' ELSE 'PASS' END,0,
    jsonb_build_object('singleDeliveryConstraintPresent',EXISTS(SELECT 1 FROM constraint_state
      WHERE conrelid='public.sales_delivery_documents'::regclass
        AND definition ILIKE '%UNIQUE%company_id%sales_id%'),
      'requiredCardinality','one Sales Order to one or many Delivery Orders')

  UNION ALL
  SELECT 'retail_confirm_document_creation_boundary',
    CASE WHEN count(*) FILTER(WHERE schema_name='private'
      AND proname='ensure_confirmed_order_documents'
      AND definition ILIKE '%sales_invoice_snapshots%'
      AND definition ILIKE '%sales_delivery_documents%')=1 THEN 'PASS' ELSE 'BLOCKER' END,0,
    jsonb_build_object('documentComposerRows',count(*) FILTER(WHERE schema_name='private'
      AND proname='ensure_confirmed_order_documents'),
      'createsInvoiceAndDelivery',count(*) FILTER(WHERE schema_name='private'
      AND proname='ensure_confirmed_order_documents'
      AND definition ILIKE '%sales_invoice_snapshots%'
      AND definition ILIKE '%sales_delivery_documents%'),
      'compatibilityRule','POS retail composer must remain unchanged')
  FROM routine_state

  UNION ALL
  SELECT 'canonical_pos_confirm_boundary',CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END,
    abs(1-count(*))::bigint,jsonb_build_object('routineRows',count(*),'expectedArguments',4)
  FROM routine_state WHERE schema_name='public' AND proname='confirm_pos_sales_order'
    AND identity_arguments='p_sales_id uuid, p_master_version bigint, p_idempotency_key uuid, p_notes text'

  UNION ALL
  SELECT 'delivery_runtime_dependency',CASE WHEN count(*)=2 THEN 'PASS' ELSE 'BLOCKER' END,
    abs(2-count(*))::bigint,jsonb_build_object('routineRows',count(*),'expected',2)
  FROM routine_state WHERE schema_name='public'
    AND proname IN('dispatch_sales_delivery','confirm_sales_delivery_received')

  UNION ALL
  SELECT 'reservation_cardinality_contract',
    CASE WHEN EXISTS(SELECT 1 FROM constraint_state
      WHERE conrelid='public.sales_stock_reservations'::regclass
        AND definition ILIKE '%UNIQUE%company_id%sales_id%') THEN 'REVIEW' ELSE 'PASS' END,0,
    jsonb_build_object('oneReservationHeaderPerSales',EXISTS(SELECT 1 FROM constraint_state
      WHERE conrelid='public.sales_stock_reservations'::regclass
        AND definition ILIKE '%UNIQUE%company_id%sales_id%'),
      'decision','Keep only if multiple DO allocations remain line-level and reconcilable')

  UNION ALL
  SELECT 'stock_overview_read_model_dependency',CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END,
    abs(1-count(*))::bigint,jsonb_build_object('routineRows',count(*))
  FROM routine_state WHERE schema_name='public' AND proname='get_inventory_stock_overview'
    AND identity_arguments=''

  UNION ALL
  SELECT 'phase0_runtime_inventory','INFO',0,jsonb_build_object(
    'sales',(SELECT count(*) FROM public.sales_headers),
    'invoiceSnapshots',(SELECT count(*) FROM public.sales_invoice_snapshots),
    'deliveryDocuments',(SELECT count(*) FROM public.sales_delivery_documents),
    'reservations',(SELECT count(*) FROM public.sales_stock_reservations),
    'featureEnabledCompanies',(SELECT count(*) FROM public.company_features
      WHERE feature_code='backoffice_delivered_qty_sales_enabled' AND is_enabled))
)
SELECT check_name,status,violation_rows,details FROM results
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'SETUP' THEN 2
  WHEN 'REVIEW' THEN 3 WHEN 'PASS' THEN 4 ELSE 5 END,check_name;
