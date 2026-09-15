-- SELECT-only verification for 20260914112000.
WITH constraint_fact AS (
  SELECT pg_get_constraintdef(oid) definition
  FROM pg_constraint
  WHERE conrelid='public.supplier_order_lines'::regclass
    AND conname='supplier_order_line_warehouse_pair_check'
), checks AS (
  SELECT 'migration_ledger' check_name,CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(1-count(*)) violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260914112000'
  UNION ALL
  SELECT 'supplier_order_unset_destination_constraint',
    CASE WHEN count(*)=1
      AND bool_and(position('OR (source_warehouse_id IS NOT NULL)' in definition)>0)
      AND bool_and(position('destination_warehouse_id IS NOT NULL' in definition)=0)
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1
      AND bool_and(position('OR (source_warehouse_id IS NOT NULL)' in definition)>0)
      AND bool_and(position('destination_warehouse_id IS NOT NULL' in definition)=0)
      THEN 0 ELSE 1 END,
    jsonb_build_object('constraintRows',count(*),'definition',max(definition))
  FROM constraint_fact
  UNION ALL
  SELECT 'supplier_order_unset_destination_unique_index',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,abs(1-count(*)),
    jsonb_build_object('indexRows',count(*))
  FROM pg_indexes WHERE schemaname='public'
    AND indexname='supplier_order_lines_unset_destination_unique'
    AND indexdef LIKE '%UNIQUE%'
    AND indexdef LIKE '%destination_warehouse_id IS NULL%'
  UNION ALL
  SELECT 'supplier_order_existing_row_contract',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('invalidRows',count(*))
  FROM public.supplier_order_lines
  WHERE source_warehouse_id IS NULL AND destination_warehouse_id IS NOT NULL
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 0 WHEN 'BLOCKER' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,
  check_name;
