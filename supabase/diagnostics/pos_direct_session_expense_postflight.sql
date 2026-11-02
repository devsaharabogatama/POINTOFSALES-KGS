-- SELECT-only postflight for migration 20261101100000. No mutation.
WITH runtime AS (
  SELECT
    pg_get_functiondef('public.post_pos_expense(uuid,uuid,uuid,text,uuid,text,numeric,uuid,text,text,text,date,uuid,uuid)'::regprocedure) AS post_source,
    pg_get_functiondef('public.get_pos_expense_workspace(uuid)'::regprocedure) AS workspace_source
), checks AS (
  SELECT 10 AS seq,'pos_direct_session_expense_postflight_migration_ledger'::text check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(count(*)-1)::bigint violation_rows,
    jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20261101100000'
  UNION ALL
  SELECT 20,'pos_direct_session_expense_postflight_runtime_contract',
    CASE WHEN post_source LIKE '%acp6a_save_expense_draft_core%'
      AND post_source LIKE '%acp6a_disburse_expense_core%'
      AND post_source LIKE '%post_pos_noncash_expense_core%'
      AND post_source LIKE '%AUTO_APPROVE%'
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN post_source LIKE '%acp6a_save_expense_draft_core%'
      AND post_source LIKE '%acp6a_disburse_expense_core%'
      AND post_source LIKE '%post_pos_noncash_expense_core%'
      AND post_source LIKE '%AUTO_APPROVE%' THEN 0 ELSE 1 END,
    jsonb_build_object('atomicDraft',post_source LIKE '%acp6a_save_expense_draft_core%',
      'canonicalCash',post_source LIKE '%acp6a_disburse_expense_core%',
      'sessionNonCash',post_source LIKE '%post_pos_noncash_expense_core%',
      'directApprovalAudit',post_source LIKE '%AUTO_APPROVE%')
  FROM runtime
  UNION ALL
  SELECT 30,'pos_direct_session_expense_postflight_workspace_contract',
    CASE WHEN workspace_source LIKE '%sessionExpenseSummary%'
      AND workspace_source LIKE '%document.cashier_session_id=p_cashier_session_id%'
      AND workspace_source LIKE '%disbursement.cashier_session_id=p_cashier_session_id%'
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN workspace_source LIKE '%sessionExpenseSummary%'
      AND workspace_source LIKE '%document.cashier_session_id=p_cashier_session_id%'
      AND workspace_source LIKE '%disbursement.cashier_session_id=p_cashier_session_id%'
      THEN 0 ELSE 1 END,
    jsonb_build_object('sessionSummary',workspace_source LIKE '%sessionExpenseSummary%',
      'documentScope',workspace_source LIKE '%document.cashier_session_id=p_cashier_session_id%',
      'disbursementScope',workspace_source LIKE '%disbursement.cashier_session_id=p_cashier_session_id%')
  FROM runtime
  UNION ALL
  SELECT 40,'pos_direct_session_expense_postflight_business_boundary','INFO',0,
    jsonb_build_object('changed',jsonb_build_array(
      'initial POS Expense is paid atomically','selected-session POS history',
      'per-session Expense summary'),
      'preserved',jsonb_build_array('Backoffice Expense approval','legacy approved Expense payment',
      'settlement','return','additional funding','Sales','Stock','FIFO','other Companies'),
      'next','Run rollback-only behavior, deploy client, then authenticated POS smoke')
)
SELECT check_name,status,violation_rows,details
FROM checks ORDER BY seq;
