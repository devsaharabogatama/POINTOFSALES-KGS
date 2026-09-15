-- SELECT-only preflight for 20260912121000.
WITH checks AS (
  SELECT 'shortage_runtime_dependency' check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END status,
    abs(1-count(*)) violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260912120000'
  UNION ALL
  SELECT 'forward_fix_collision',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*),jsonb_build_object('ledgerRows',count(*))
  FROM private.kgs_schema_migrations WHERE version='20260912121000'
  UNION ALL
  SELECT 'canonical_discrepancy_audit_columns',
    CASE WHEN count(*)=7 AND count(*) FILTER(WHERE column_name='reason')=0
      THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN count(*)=7 AND count(*) FILTER(WHERE column_name='reason')=0 THEN 0 ELSE 1 END,
    jsonb_build_object('requiredColumnRows',count(*),
      'reasonColumnRows',count(*) FILTER(WHERE column_name='reason'))
  FROM information_schema.columns
  WHERE table_schema='public' AND table_name='backoffice_sales_discrepancy_audit'
    AND column_name IN('company_id','discrepancy_id','operation_id','action',
      'actor_id','before_state','after_state','reason')
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 0 ELSE 1 END,check_name;
