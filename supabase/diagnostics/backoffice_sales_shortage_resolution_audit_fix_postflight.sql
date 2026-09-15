-- SELECT-only postflight for 20260912121000.
WITH definition AS (
  SELECT pg_get_functiondef(
    'private.resolve_backoffice_sales_shortage_core(uuid,bigint,uuid,date,text)'::regprocedure) body
), checks AS (
  SELECT 'migration_ledger' check_name,CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(1-count(*)) violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260912121000'
  UNION ALL
  SELECT 'canonical_audit_insert_definition',
    CASE WHEN body LIKE '%operation_id,action,actor_id,before_state,after_state)%'
      AND body NOT LIKE '%operation_id,action,actor_id,reason,before_state,after_state)%'
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN body LIKE '%operation_id,action,actor_id,before_state,after_state)%'
      AND body NOT LIKE '%operation_id,action,actor_id,reason,before_state,after_state)%'
      THEN 0 ELSE 1 END,
    jsonb_build_object('canonicalInsert',body LIKE '%operation_id,action,actor_id,before_state,after_state)%',
      'invalidReasonInsert',body LIKE '%operation_id,action,actor_id,reason,before_state,after_state)%')
  FROM definition
  UNION ALL
  SELECT 'note_retained_in_operation_request',
    CASE WHEN body LIKE '%requestedBackorderDate%' AND body LIKE '%request_payload%'
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN body LIKE '%requestedBackorderDate%' AND body LIKE '%request_payload%'
      THEN 0 ELSE 1 END,
    jsonb_build_object('requestPayloadRetained',
      body LIKE '%requestedBackorderDate%' AND body LIKE '%request_payload%')
  FROM definition
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 0 ELSE 1 END,check_name;
