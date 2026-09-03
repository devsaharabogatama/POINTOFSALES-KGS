-- Stock Opname negative-stock compatibility postflight.
-- SAFETY: SELECT-only.

WITH checks(check_name,status,violation_rows,details) AS (
  SELECT 'migration_ledger',CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1 THEN 0 ELSE 1 END,
    jsonb_build_object('ledgerRows',count(*))
  FROM private.kgs_schema_migrations WHERE version='20260902110000'
  UNION ALL
  SELECT 'signed_system_snapshot_constraint',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1 THEN 0 ELSE 1 END,
    jsonb_build_object('constraintRows',count(*))
  FROM pg_constraint
  WHERE conrelid='public.stock_opname_details'::regclass
    AND conname='stock_opname_details_physical_qty_nonnegative'
    AND pg_get_constraintdef(oid) ILIKE '%physical_qty%>=%0%'
    AND pg_get_constraintdef(oid) NOT ILIKE '%system_qty%'
    AND pg_get_constraintdef(oid) NOT ILIKE '%expected_qty%'
  UNION ALL
  SELECT 'legacy_unsigned_constraint_removed',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('constraintRows',count(*))
  FROM pg_constraint
  WHERE conrelid='public.stock_opname_details'::regclass
    AND conname='stock_opname_details_quantity_nonnegative'
  UNION ALL
  SELECT 'physical_quantity_nonnegative',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('rowCount',count(*))
  FROM public.stock_opname_details WHERE physical_qty<0
  UNION ALL
  SELECT 'stock_opname_signed_snapshot_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('rowCount',count(*))
  FROM public.stock_opname_details
  WHERE line_status IN('COUNTED','RECOUNT_REQUIRED','POSTED') AND (
    expected_qty_at_count IS NULL OR variance_at_count IS DISTINCT FROM
      physical_qty-expected_qty_at_count
    OR difference IS DISTINCT FROM variance_at_count)
  UNION ALL
  SELECT 'negative_stock_runtime_inventory','INFO',0,jsonb_build_object(
    'negativeStockPairs',count(*),'minimumStock',min(stock_qty))
  FROM public.product_stocks WHERE stock_qty<0
)
SELECT * FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
