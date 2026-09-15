-- SELECT-only verification for 20260914111000.
WITH definition AS (
  SELECT pg_get_functiondef(to_regprocedure(
    'private.generate_purchase_daily_auto_po_core(uuid,date,uuid,uuid,timestamptz)')) body
), checks AS (
  SELECT 'migration_ledger' check_name,CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(1-count(*)) violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260914111000'
  UNION ALL
  SELECT 'auto_po_destination_filter_absent',
    CASE WHEN position('AND line.destination_warehouse_id IS NOT NULL' in body)=0
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN position('AND line.destination_warehouse_id IS NOT NULL' in body)=0
      THEN 0 ELSE 1 END,
    jsonb_build_object('destinationFilterAbsent',
      position('AND line.destination_warehouse_id IS NOT NULL' in body)=0)
  FROM definition
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 0 WHEN 'BLOCKER' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,
  check_name;
