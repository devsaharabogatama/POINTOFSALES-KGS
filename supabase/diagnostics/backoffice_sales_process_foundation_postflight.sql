-- Backoffice Sales process identity foundation postflight (read only).
WITH results AS (
  SELECT 'migration_ledger'::text check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END::text status,
    abs(1-count(*))::bigint violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260908100000'
  UNION ALL
  SELECT 'required_process_identity_columns',
    CASE WHEN count(*)=2 THEN 'PASS' ELSE 'BLOCKER' END,abs(2-count(*))::bigint,
    jsonb_build_object('expected',2,'columnRows',count(*))
  FROM information_schema.columns WHERE table_schema='public' AND table_name='sales_headers'
    AND column_name IN('sales_origin','sales_process_mode') AND is_nullable='NO'
  UNION ALL
  SELECT 'process_identity_constraint_contract',
    CASE WHEN count(*)=3 THEN 'PASS' ELSE 'BLOCKER' END,abs(3-count(*))::bigint,
    jsonb_build_object('expected',3,'constraintRows',count(*))
  FROM pg_constraint WHERE conrelid='public.sales_headers'::regclass
    AND conname IN('sales_headers_origin_check','sales_headers_process_mode_check',
      'sales_headers_origin_process_pair_check')
  UNION ALL
  SELECT 'process_identity_trigger_contract',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END,abs(1-count(*))::bigint,
    jsonb_build_object('triggerRows',count(*))
  FROM pg_trigger WHERE tgrelid='public.sales_headers'::regclass
    AND tgname='sales_headers_process_identity_guard' AND tgenabled<>'D'
  UNION ALL
  SELECT 'backoffice_sales_feature_catalog',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END,abs(1-count(*))::bigint,
    jsonb_build_object('catalogRows',count(*))
  FROM public.platform_features
  WHERE feature_code='backoffice_delivered_qty_sales_enabled' AND is_active
  UNION ALL
  SELECT 'backoffice_sales_feature_default_off',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('enabledCompanies',count(*))
  FROM public.company_features
  WHERE feature_code='backoffice_delivered_qty_sales_enabled' AND is_enabled
  UNION ALL
  SELECT 'existing_sales_pos_identity_backfill',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('invalidRows',count(*))
  FROM public.sales_headers
  WHERE sales_origin<>'POS' OR sales_process_mode<>'RETAIL_CONFIRM_INVOICE'
  UNION ALL
  SELECT 'retail_document_cardinality_preserved',
    CASE WHEN count(*)=2 THEN 'PASS' ELSE 'BLOCKER' END,abs(2-count(*))::bigint,
    jsonb_build_object('expected',2,'constraintRows',count(*))
  FROM pg_constraint
  WHERE (conrelid,conname) IN(
    ('public.sales_invoice_snapshots'::regclass,'sales_invoice_snapshots_company_sale_unique'),
    ('public.sales_delivery_documents'::regclass,'sales_delivery_documents_company_sale_unique'))
  UNION ALL
  SELECT 'private_process_guard_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('authenticatedExecutableRows',count(*))
  FROM information_schema.routine_privileges
  WHERE grantee='authenticated' AND routine_schema='private'
    AND routine_name='trg_guard_sales_process_identity' AND privilege_type='EXECUTE'
  UNION ALL
  SELECT 'process_identity_runtime_inventory','INFO',0,jsonb_build_object(
    'posSales',(SELECT count(*) FROM public.sales_headers WHERE sales_origin='POS'),
    'backofficeSales',(SELECT count(*) FROM public.sales_headers WHERE sales_origin='BACKOFFICE_SALES'),
    'enabledCompanies',(SELECT count(*) FROM public.company_features
      WHERE feature_code='backoffice_delivered_qty_sales_enabled' AND is_enabled))
)
SELECT check_name,status,violation_rows,details FROM results
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
