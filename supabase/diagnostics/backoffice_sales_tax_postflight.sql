WITH checks(check_name,status,violation_rows,details) AS (
  SELECT 'migration_ledger',CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    abs(count(*)-1),jsonb_build_object('ledgerRows',count(*))
  FROM private.kgs_schema_migrations WHERE version='20260909110000'
  UNION ALL
  SELECT 'required_tax_snapshot_columns',CASE WHEN count(*)=12 THEN 'PASS' ELSE 'FAIL' END,
    abs(count(*)-12),jsonb_build_object('expected',12,'columnRows',count(*))
  FROM information_schema.columns WHERE table_schema='public'
    AND table_name='backoffice_sales_order_lines' AND column_name IN(
      'tax_rule_id','tax_rule_version','tax_code_snapshot','tax_name_snapshot',
      'tax_rate_percent_snapshot','tax_price_mode_snapshot','tax_calculation_scope_snapshot',
      'tax_base','tax_rounding','tax_account_id','tax_account_code_snapshot','tax_account_name_snapshot')
  UNION ALL
  SELECT 'required_tax_runtime_triggers',CASE WHEN count(*)=2 THEN 'PASS' ELSE 'FAIL' END,
    abs(count(*)-2),jsonb_build_object('expected',2,'triggerRows',count(*))
  FROM pg_trigger WHERE tgname IN('backoffice_sales_line_total','backoffice_sales_order_tax')
    AND NOT tgisinternal
  UNION ALL
  SELECT 'private_tax_runtime_boundary',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*),jsonb_build_object('browserExecutableRows',count(*))
  FROM information_schema.routine_privileges WHERE specific_schema='private'
    AND routine_name IN('apply_backoffice_sales_order_tax','trg_backoffice_sales_order_tax','trg_backoffice_sales_line_total')
    AND grantee IN('anon','authenticated') AND privilege_type='EXECUTE'
  UNION ALL
  SELECT 'backoffice_tax_runtime_inventory','INFO',0,jsonb_build_object(
    'orders',(SELECT count(*) FROM public.backoffice_sales_orders),
    'taxedLines',(SELECT count(*) FROM public.backoffice_sales_order_lines WHERE tax_rule_id IS NOT NULL),
    'reservations',(SELECT count(*) FROM public.sales_stock_reservations),
    'deliveries',(SELECT count(*) FROM public.sales_delivery_documents),
    'invoices',(SELECT count(*) FROM public.sales_invoice_snapshots),
    'financialEvents',(SELECT count(*) FROM public.financial_events))
)
SELECT * FROM checks ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
