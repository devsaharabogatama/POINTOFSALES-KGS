-- Read-only preflight for canonical price insert forward-fix.
WITH definition AS (
  SELECT pg_get_functiondef(
    'public.save_backoffice_sales_order_draft_before_pricelist_header(uuid,bigint,uuid,jsonb)'::regprocedure
  ) body
), checks AS (
  SELECT 'commercial_parity_dependency'::text check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260909140000'
  UNION ALL
  SELECT 'active_finance_posting_queue',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('runCount',count(*))
  FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'canonical_insert_gap',
    CASE WHEN body LIKE '%base_qty_per_uom,unit_price,%'
      AND body NOT LIKE '%base_qty_per_uom,unit_price,canonical_unit_price,%'
      THEN 'REPAIR_REQUIRED' ELSE 'BLOCKER' END,
    jsonb_build_object(
      'legacyInsertFound',body LIKE '%base_qty_per_uom,unit_price,%',
      'canonicalInsertAlreadyFound',body LIKE '%base_qty_per_uom,unit_price,canonical_unit_price,%')
  FROM definition
  UNION ALL
  SELECT 'existing_canonical_price_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('nullRows',count(*))
  FROM public.backoffice_sales_order_lines WHERE canonical_unit_price IS NULL
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'REPAIR_REQUIRED' THEN 2 ELSE 3 END,
  check_name;
