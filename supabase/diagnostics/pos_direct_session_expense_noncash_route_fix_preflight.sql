-- SELECT-only classifier for the immutable direct POS Expense non-cash fix.
WITH state AS (
  SELECT
    (SELECT count(*) FROM private.kgs_schema_migrations
      WHERE version='20261101100000') AS dependency_rows,
    (SELECT count(*) FROM private.kgs_schema_migrations
      WHERE version='20261101110000') AS fix_rows,
    pg_get_functiondef(
      'private.post_pos_noncash_expense_core(uuid,bigint,uuid,text,uuid)'::regprocedure
    ) AS core_source,
    pg_get_functiondef(
      'public.get_pos_expense_workspace(uuid)'::regprocedure
    ) AS workspace_source
), checks AS (
  SELECT 10 AS seq,
    'pos_direct_session_expense_noncash_fix_dependency'::text AS check_name,
    CASE WHEN dependency_rows=1 THEN 'PASS' ELSE 'BLOCKER' END AS status,
    CASE WHEN dependency_rows=1 THEN 0 ELSE 1 END AS violation_rows,
    jsonb_build_object('required','20261101100000','rows',dependency_rows) AS details
  FROM state
  UNION ALL
  SELECT 20,'pos_direct_session_expense_noncash_fix_installation_state',
    CASE WHEN fix_rows=0 THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN fix_rows=0 THEN 0 ELSE 1 END,
    jsonb_build_object('state',CASE WHEN fix_rows=0 THEN 'NOT_INSTALLED'
      ELSE 'INSTALLED' END,'ledgerRows',fix_rows)
  FROM state
  UNION ALL
  SELECT 30,'pos_direct_session_expense_noncash_fix_exact_root_cause',
    CASE WHEN core_source LIKE '%v_session.pos_id,v_document.requested_amount%'
           AND core_source LIKE '%v_method.settlement_route,v_payment_function,v_session.id%'
           AND workspace_source LIKE '%disbursement.cashier_session_id=p_cashier_session_id%'
      THEN 'ROOT_CAUSE' ELSE 'BLOCKER' END,
    CASE WHEN core_source LIKE '%v_session.pos_id,v_document.requested_amount%'
           AND core_source LIKE '%v_method.settlement_route,v_payment_function,v_session.id%'
           AND workspace_source LIKE '%disbursement.cashier_session_id=p_cashier_session_id%'
      THEN 0 ELSE 1 END,
    jsonb_build_object(
      'invalidNonCashSessionInsert',core_source LIKE '%v_session.pos_id,v_document.requested_amount%',
      'invalidNonCashTerminalInsert',core_source LIKE '%v_method.settlement_route,v_payment_function,v_session.id%',
      'invalidSummaryOwnership',workspace_source LIKE '%disbursement.cashier_session_id=p_cashier_session_id%')
  FROM state
  UNION ALL
  SELECT 40,'pos_direct_session_expense_noncash_fix_persisted_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*),
    jsonb_build_object('invalidPersistedRows',count(*),
      'meaning','The route constraint should have rejected every invalid non-cash row')
  FROM public.expense_disbursements disbursement
  WHERE disbursement.payment_method_type_snapshot<>'CASH'
    AND (disbursement.cashier_session_id IS NOT NULL
      OR disbursement.pos_terminal_id IS NOT NULL)
  UNION ALL
  SELECT 50,'pos_direct_session_expense_noncash_fix_runtime_boundary',
    CASE WHEN finance_rows=0 AND offline_rows=0 THEN 'PASS' ELSE 'BLOCKER' END,
    finance_rows+offline_rows,
    jsonb_build_object('activeFinanceQueue',finance_rows,
      'nonterminalOffline',offline_rows)
  FROM (
    SELECT
      (SELECT count(*) FROM public.finance_posting_queue_runs
        WHERE status IN('DRAFT','PROCESSING')) AS finance_rows,
      (SELECT count(*) FROM public.pos_offline_sale_submissions
        WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) AS offline_rows
  ) boundary
)
SELECT check_name,status,violation_rows,details
FROM checks ORDER BY seq;

