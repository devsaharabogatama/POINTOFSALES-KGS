WITH checks AS (
  SELECT 'migration_ledger'::text check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    CASE WHEN count(*)=1 THEN 0 ELSE 1 END::bigint violation_rows,
    jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260909144000'
  UNION ALL
  SELECT 'atomic_commercial_reset_definition',
    CASE WHEN body LIKE '%subtotal=0,discount_total=0,global_discount=0,tax_total=0,grand_total_before_rounding=0%'
      AND body LIKE '%rounding_direction=''NONE'',rounding_increment=100,rounding_adjustment=0,grand_total=0%'
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN body LIKE '%subtotal=0,discount_total=0,global_discount=0,tax_total=0,grand_total_before_rounding=0%'
      AND body LIKE '%rounding_direction=''NONE'',rounding_increment=100,rounding_adjustment=0,grand_total=0%'
      THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('routineRows',1)
  FROM (SELECT pg_get_functiondef(
    'public.save_backoffice_sales_order_draft_before_pricelist_header(uuid,bigint,uuid,jsonb)'::regprocedure) body) definition
  UNION ALL
  SELECT 'backoffice_sales_amount_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('invalidRows',count(*))
  FROM public.backoffice_sales_orders document
  WHERE document.subtotal<0 OR document.discount_total<0
    OR document.global_discount<0 OR document.discount_total>document.subtotal
    OR document.tax_total<0 OR document.rounding_increment<=0
    OR document.grand_total_before_rounding<>document.subtotal-document.discount_total
    OR document.rounding_adjustment<>document.grand_total-document.grand_total_before_rounding
  UNION ALL
  SELECT 'active_finance_posting_queue',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('runCount',count(*))
  FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
