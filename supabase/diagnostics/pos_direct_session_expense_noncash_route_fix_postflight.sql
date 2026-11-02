-- SELECT-only closing proof for the direct POS Expense non-cash route fix.
WITH state AS (
  SELECT
    pg_get_functiondef(
      'private.post_pos_noncash_expense_core(uuid,bigint,uuid,text,uuid)'::regprocedure
    ) AS core_source,
    pg_get_functiondef(
      'public.get_pos_expense_workspace(uuid)'::regprocedure
    ) AS workspace_source
), checks AS (
  SELECT 10 AS seq,
    'pos_direct_session_expense_noncash_fix_migration_ledger'::text AS check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END AS status,
    CASE WHEN count(*)=1 THEN 0 ELSE 1 END AS violation_rows,
    jsonb_build_object('ledgerRows',count(*)) AS details
  FROM private.kgs_schema_migrations WHERE version='20261101110000'
  UNION ALL
  SELECT 20,'pos_direct_session_expense_noncash_fix_runtime_contract',
    CASE WHEN core_source LIKE '%v_document.cashier_session_id IS DISTINCT FROM p_cashier_session_id%'
           AND core_source LIKE '%' || quote_literal('cashierSessionId') || ',NULL%'
           AND core_source NOT LIKE '%v_session.pos_id,v_document.requested_amount%'
           AND core_source NOT LIKE '%v_method.settlement_route,v_payment_function,v_session.id%'
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN core_source LIKE '%v_document.cashier_session_id IS DISTINCT FROM p_cashier_session_id%'
           AND core_source LIKE '%' || quote_literal('cashierSessionId') || ',NULL%'
           AND core_source NOT LIKE '%v_session.pos_id,v_document.requested_amount%'
           AND core_source NOT LIKE '%v_method.settlement_route,v_payment_function,v_session.id%'
      THEN 0 ELSE 1 END,
    jsonb_build_object('documentOriginRetry',
      core_source LIKE '%v_document.cashier_session_id IS DISTINCT FROM p_cashier_session_id%',
      'eventSessionNull',core_source LIKE '%' || quote_literal('cashierSessionId') || ',NULL%',
      'invalidInsertRemoved',core_source NOT LIKE '%v_session.pos_id,v_document.requested_amount%'
        AND core_source NOT LIKE '%v_method.settlement_route,v_payment_function,v_session.id%')
  FROM state
  UNION ALL
  SELECT 30,'pos_direct_session_expense_noncash_fix_workspace_contract',
    CASE WHEN workspace_source LIKE '%JOIN public.expense_documents document%'
           AND workspace_source LIKE '%document.cashier_session_id=p_cashier_session_id%'
           AND workspace_source NOT LIKE '%disbursement.cashier_session_id=p_cashier_session_id%'
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN workspace_source LIKE '%JOIN public.expense_documents document%'
           AND workspace_source LIKE '%document.cashier_session_id=p_cashier_session_id%'
           AND workspace_source NOT LIKE '%disbursement.cashier_session_id=p_cashier_session_id%'
      THEN 0 ELSE 1 END,
    jsonb_build_object('documentOriginSummary',
      workspace_source LIKE '%document.cashier_session_id=p_cashier_session_id%')
  FROM state
  UNION ALL
  SELECT 40,'pos_direct_session_expense_noncash_fix_business_boundary','INFO',0,
    jsonb_build_object('changed',ARRAY[
      'direct POS non-cash canonical route shape',
      'non-cash exact retry ownership',
      'session Expense summary ownership'],
      'preserved',ARRAY['Cash Drawer','Backoffice Expense','Finance mapping',
        'settlement','return','additional funding','Sales','Stock','FIFO',
        'historical rows','other Companies'])
)
SELECT check_name,status,violation_rows,details
FROM checks ORDER BY seq;

