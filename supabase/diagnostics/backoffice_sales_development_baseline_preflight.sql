-- Development-only baseline audit. READ ONLY.
WITH
required_relations(name,object_name) AS (VALUES
  ('sales_stock_reservations','public.sales_stock_reservations'),
  ('sales_stock_reservation_lines','public.sales_stock_reservation_lines'),
  ('sales_dispatch_allocations','public.sales_dispatch_allocations'),
  ('sales_dispatch_financial_effects','public.sales_dispatch_financial_effects'),
  ('sales_payment_verification_requests','public.sales_payment_verification_requests'),
  ('sales_order_procurement_demands','public.sales_order_procurement_demands')
),
required_routines(name,object_name) AS (VALUES
  ('confirm_pos_sales_order','public.confirm_pos_sales_order(uuid,bigint,uuid,text)'),
  ('cancel_pos_sales_order','public.cancel_pos_sales_order(uuid,bigint,uuid,text)'),
  ('dispatch_sales_delivery','public.dispatch_sales_delivery(uuid,bigint,uuid,jsonb,text)'),
  ('confirm_sales_delivery_received','public.confirm_sales_delivery_received(uuid,bigint,text,text)'),
  ('get_inventory_stock_overview','public.get_inventory_stock_overview()')
),
relation_state AS (
  SELECT name,to_regclass(object_name) IS NOT NULL present FROM required_relations
),
routine_state AS (
  SELECT name,to_regprocedure(object_name) IS NOT NULL present FROM required_routines
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
  SELECT 'required_current_relations',
    CASE WHEN bool_and(present) THEN 'PASS' ELSE 'SETUP' END,
    count(*) FILTER(WHERE NOT present)::bigint,
    jsonb_build_object('missing',coalesce(jsonb_agg(name) FILTER(WHERE NOT present),'[]'::jsonb),
      'expected',count(*))
  FROM relation_state
  UNION ALL
  SELECT 'required_current_routines',
    CASE WHEN bool_and(present) THEN 'PASS' ELSE 'SETUP' END,
    count(*) FILTER(WHERE NOT present)::bigint,
    jsonb_build_object('missing',coalesce(jsonb_agg(name) FILTER(WHERE NOT present),'[]'::jsonb),
      'expected',count(*))
  FROM routine_state
  UNION ALL
  SELECT 'backoffice_feature_absent',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'REVIEW' END,count(*)::bigint,
    jsonb_build_object('catalogRows',count(*),'requiredBeforeFeatureWork',0)
  FROM public.platform_features
  WHERE feature_code='backoffice_delivered_qty_sales_enabled'
  UNION ALL
  SELECT 'migration_ledger_inventory','INFO',0,jsonb_build_object(
    'supabaseLedgerRows',(SELECT count(*) FROM supabase_migrations.schema_migrations),
    'supabaseLatest',(SELECT max(version) FROM supabase_migrations.schema_migrations),
    'applicationLedgerRows',(SELECT count(*) FROM private.kgs_schema_migrations),
    'applicationLatest',(SELECT max(version) FROM private.kgs_schema_migrations))
  UNION ALL
  SELECT 'development_fixture_inventory','INFO',0,jsonb_build_object(
    'companies',(SELECT count(*) FROM public.companies),
    'profiles',(SELECT count(*) FROM public.profiles),
    'sales',(SELECT count(*) FROM public.sales_headers),
    'invoiceSnapshots',(SELECT count(*) FROM public.sales_invoice_snapshots),
    'deliveryDocuments',(SELECT count(*) FROM public.sales_delivery_documents))
)
SELECT check_name,status,violation_rows,details FROM results
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'SETUP' THEN 2
  WHEN 'REVIEW' THEN 3 WHEN 'PASS' THEN 4 ELSE 5 END,check_name;
