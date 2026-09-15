-- Read-only postflight for canonical price insert forward-fix.
WITH definition AS (
  SELECT pg_get_functiondef(
    'public.save_backoffice_sales_order_draft_before_pricelist_header(uuid,bigint,uuid,jsonb)'::regprocedure
  ) body
), checks AS (
  SELECT 'migration_ledger'::text check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    CASE WHEN count(*)=1 THEN 0 ELSE 1 END::bigint violation_rows,
    jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260909141000'
  UNION ALL
  SELECT 'canonical_insert_definition_contract',
    CASE WHEN body LIKE '%base_qty_per_uom,unit_price,canonical_unit_price,%'
      AND body LIKE '%canonicalResolvedUnitPrice%' THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN body LIKE '%base_qty_per_uom,unit_price,canonical_unit_price,%'
      AND body LIKE '%canonicalResolvedUnitPrice%' THEN 0 ELSE 1 END::bigint,
    jsonb_build_object(
      'canonicalColumnInserted',body LIKE '%base_qty_per_uom,unit_price,canonical_unit_price,%',
      'canonicalResolverValueUsed',body LIKE '%canonicalResolvedUnitPrice%')
  FROM definition
  UNION ALL
  SELECT 'canonical_price_not_null_contract',
    CASE WHEN column_name IS NOT NULL AND is_nullable='NO' AND column_default IS NULL
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN column_name IS NOT NULL AND is_nullable='NO' AND column_default IS NULL
      THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('isNullable',is_nullable,'columnDefault',column_default)
  FROM (SELECT column_name,is_nullable,column_default
    FROM information_schema.columns
    WHERE table_schema='public' AND table_name='backoffice_sales_order_lines'
      AND column_name='canonical_unit_price') column_state
  UNION ALL
  SELECT 'canonical_price_row_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('nullRows',count(*))
  FROM public.backoffice_sales_order_lines WHERE canonical_unit_price IS NULL
  UNION ALL
  SELECT 'active_finance_posting_queue',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('runCount',count(*))
  FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
