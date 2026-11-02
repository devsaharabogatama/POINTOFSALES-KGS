-- SELECT-only preflight for POS direct session Expense. No mutation.
WITH dependency AS (
  SELECT count(DISTINCT version) AS installed_rows,
    coalesce(jsonb_agg(version ORDER BY version),'[]'::jsonb) AS installed
  FROM private.kgs_schema_migrations
  WHERE version IN(
    '20260803040000','20260803070000','20260803100000',
    '20260804100000','20260813060000'
  )
), installation AS (
  SELECT
    (SELECT count(*) FROM private.kgs_schema_migrations
      WHERE version='20261101100000') AS ledger_rows,
    (to_regprocedure('public.post_pos_expense(uuid,uuid,uuid,text,uuid,text,numeric,uuid,text,text,text,date,uuid,uuid)') IS NOT NULL)::int AS public_rows,
    (to_regprocedure('private.post_pos_noncash_expense_core(uuid,bigint,uuid,text,uuid)') IS NOT NULL)::int AS private_rows
), runtime AS (
  SELECT
    (to_regprocedure('private.acp6a_save_expense_draft_core(uuid,bigint,uuid,uuid,uuid,text,uuid,text,numeric,uuid,text,text,text,date,uuid)') IS NOT NULL)::int AS save_core,
    (to_regprocedure('private.acp6a_disburse_expense_core(uuid,bigint,uuid,text,uuid)') IS NOT NULL)::int AS cash_core,
    (to_regprocedure('public.get_pos_expense_workspace(uuid)') IS NOT NULL)::int AS workspace
), checks AS (
  SELECT 10 AS seq,'pos_direct_session_expense_preflight_dependency_ledger'::text check_name,
    CASE WHEN installed_rows=5 THEN 'PASS' ELSE 'BLOCKER' END status,
    abs(installed_rows-5)::bigint violation_rows,
    jsonb_build_object('expected',5,'installedRows',installed_rows,'installed',installed) details
  FROM dependency
  UNION ALL
  SELECT 20,'pos_direct_session_expense_preflight_installation_state',
    CASE
      WHEN ledger_rows=0 AND public_rows=0 AND private_rows=0 THEN 'PASS'
      WHEN ledger_rows=1 AND public_rows=1 AND private_rows=1 THEN 'INFO'
      ELSE 'BLOCKER'
    END,
    CASE
      WHEN (ledger_rows=0 AND public_rows=0 AND private_rows=0)
        OR (ledger_rows=1 AND public_rows=1 AND private_rows=1) THEN 0 ELSE 1
    END,
    jsonb_build_object('state',CASE
      WHEN ledger_rows=0 AND public_rows=0 AND private_rows=0 THEN 'NOT_INSTALLED'
      WHEN ledger_rows=1 AND public_rows=1 AND private_rows=1 THEN 'INSTALLED_CONSISTENT'
      ELSE 'PARTIAL_INCONSISTENT' END,
      'ledgerRows',ledger_rows,'publicRpcRows',public_rows,'privateCoreRows',private_rows)
  FROM installation
  UNION ALL
  SELECT 30,'pos_direct_session_expense_preflight_runtime_anchors',
    CASE WHEN save_core+cash_core+workspace=3 THEN 'PASS' ELSE 'BLOCKER' END,
    (3-(save_core+cash_core+workspace))::bigint,
    jsonb_build_object('saveDraftCore',save_core=1,'cashDisbursementCore',cash_core=1,
      'posWorkspace',workspace=1)
  FROM runtime
  UNION ALL
  SELECT 40,'pos_direct_session_expense_preflight_existing_partition','INFO',0,
    jsonb_build_object(
      'documents',count(*),
      'sessionLinked',count(*) FILTER (WHERE document.cashier_session_id IS NOT NULL),
      'approvedCash',count(*) FILTER (WHERE document.status='APPROVED'
        AND document.requested_payment_method_type_snapshot='CASH'),
      'outstanding',count(*) FILTER (WHERE document.status IN('DISBURSED','PARTIALLY_SETTLED')
        AND document.outstanding_amount>0),
      'meaning','Existing rows remain immutable; the new POS read model only scopes by their recorded origin session')
  FROM public.expense_documents document
  UNION ALL
  SELECT 50,'pos_direct_session_expense_preflight_runtime_boundary',
    CASE WHEN finance_rows=0 AND offline_rows=0 THEN 'PASS' ELSE 'BLOCKER' END,
    (finance_rows+offline_rows)::bigint,
    jsonb_build_object('activeFinanceQueue',finance_rows,'nonterminalOffline',offline_rows)
  FROM (SELECT
    (SELECT count(*) FROM public.finance_posting_queue_runs
      WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) AS finance_rows,
    (SELECT count(*) FROM public.pos_offline_sale_submissions
      WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) AS offline_rows
  ) boundary
)
SELECT check_name,status,violation_rows,details
FROM checks ORDER BY seq;
