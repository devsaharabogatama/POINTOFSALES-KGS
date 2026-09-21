-- Read-only verification after 20260919120000.
WITH required_columns(name) AS (
  VALUES ('manual_workflow_status'),('manual_approval_required_snapshot'),
    ('external_reference'),('evidence_url'),('submitted_by'),('submitted_at'),
    ('approved_by'),('approved_at')
), column_check AS (
  SELECT array_agg(name ORDER BY name) FILTER(WHERE NOT EXISTS(
    SELECT 1 FROM information_schema.columns column_state
    WHERE column_state.table_schema='public'
      AND column_state.table_name='finance_journals'
      AND column_state.column_name=required_columns.name)) missing
  FROM required_columns
), required_routines(signature) AS (
  VALUES ('public.get_manual_finance_journal_context()'),
    ('public.save_manual_finance_journal_draft(uuid,bigint,uuid,date,text,text,text,jsonb)'),
    ('public.submit_manual_finance_journal(uuid,bigint,uuid)'),
    ('public.approve_manual_finance_journal(uuid,bigint,uuid)'),
    ('public.cancel_manual_finance_journal(uuid,bigint,text,uuid)'),
    ('public.save_manual_journal_approval_policy(bigint,boolean,uuid)'),
    ('private.validate_manual_finance_journal_for_posting(uuid,uuid)')
), routine_check AS (
  SELECT array_agg(signature ORDER BY signature) FILTER(
    WHERE to_regprocedure(signature) IS NULL) missing FROM required_routines
), line_guard AS (
  SELECT regexp_replace(lower(pg_get_functiondef(
    'private.trg_g6_guard_finance_journal_line()'::regprocedure)),'\s+','','g') body
)
SELECT 'manual_journal_migration_ledger' check_name,
  CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
  abs(count(*)-1)::bigint violation_rows,jsonb_build_object('ledgerRows',count(*)) details
FROM private.kgs_schema_migrations WHERE version='20260919120000'
UNION ALL
SELECT 'manual_journal_column_contract',
  CASE WHEN coalesce(cardinality(missing),0)=0 THEN 'PASS' ELSE 'FAIL' END,
  coalesce(cardinality(missing),0)::bigint,
  jsonb_build_object('missing',coalesce(to_jsonb(missing),'[]'::jsonb),'expected',8)
FROM column_check
UNION ALL
SELECT 'manual_journal_routine_contract',
  CASE WHEN coalesce(cardinality(missing),0)=0 THEN 'PASS' ELSE 'FAIL' END,
  coalesce(cardinality(missing),0)::bigint,
  jsonb_build_object('missing',coalesce(to_jsonb(missing),'[]'::jsonb),'expected',7)
FROM routine_check
UNION ALL
SELECT 'manual_journal_guard_compatibility',
  CASE WHEN position('backoffice_customer_refund' IN body)>0
    AND position('manual_posting_account_not_allowed' IN body)>0
    AND position('pending_manual_journal_immutable' IN body)>0
    THEN 'PASS' ELSE 'FAIL' END,
  CASE WHEN position('backoffice_customer_refund' IN body)>0
    AND position('manual_posting_account_not_allowed' IN body)>0
    AND position('pending_manual_journal_immutable' IN body)>0
    THEN 0 ELSE 1 END::bigint,
  jsonb_build_object('customerRefundReversalPreserved',
    position('backoffice_customer_refund' IN body)>0,
    'manualAccountBoundary',position('manual_posting_account_not_allowed' IN body)>0,
    'pendingLineImmutability',position('pending_manual_journal_immutable' IN body)>0)
FROM line_guard
UNION ALL
SELECT 'manual_journal_trigger_contract',
  CASE WHEN count(*)=2 AND count(*) FILTER(WHERE trigger_state.tgenabled='O')=2
    THEN 'PASS' ELSE 'FAIL' END,
  (2-count(*))::bigint,
  jsonb_build_object('triggerRows',count(*),'enabledRows',
    count(*) FILTER(WHERE trigger_state.tgenabled='O'))
FROM pg_trigger trigger_state
JOIN pg_class relation ON relation.oid=trigger_state.tgrelid
JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
WHERE namespace.nspname='public' AND relation.relname='finance_journals'
  AND trigger_state.tgname IN('b_manual_finance_journal_workflow_guard','g6_guard_finance_journal')
UNION ALL
SELECT 'manual_journal_permission_contract',
  CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,abs(count(*)-1)::bigint,
  jsonb_build_object('rows',count(*),'defaultApproval',TRUE)
FROM public.access_permission_catalog permission
WHERE permission.permission_key='finance.manual_journals'
  AND permission.enforcement_status='ENFORCED'
  AND permission.operator_roles@>ARRAY['COMPANY_ADMIN','FINANCE']::text[]
  AND permission.approver_roles@>ARRAY['COMPANY_ADMIN']::text[]
  AND NOT(permission.approver_roles@>ARRAY['FINANCE']::text[])
UNION ALL
SELECT 'manual_journal_default_policy',
  CASE WHEN count(*) FILTER(WHERE NOT manual_journal_approval_required)=0
    THEN 'PASS' ELSE 'FAIL' END,
  count(*) FILTER(WHERE NOT manual_journal_approval_required)::bigint,
  jsonb_build_object('companyPolicies',count(*),'approvalOff',
    count(*) FILTER(WHERE NOT manual_journal_approval_required))
FROM public.finance_company_policies
UNION ALL
SELECT 'manual_journal_legacy_reconciliation',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
  jsonb_build_object('invalidRows',count(*))
FROM public.finance_journals journal
WHERE (journal.journal_type='MANUAL' AND (
    journal.manual_workflow_status IS NULL
    OR journal.manual_approval_required_snapshot IS NULL))
   OR (journal.journal_type<>'MANUAL' AND (
    journal.manual_workflow_status IS NOT NULL
    OR journal.manual_approval_required_snapshot IS NOT NULL))
UNION ALL
SELECT 'manual_journal_finance_balance_reconciliation',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
  jsonb_build_object('invalidPostedManualJournals',count(*))
FROM public.finance_journals journal
WHERE journal.journal_type='MANUAL' AND journal.status='POSTED'
  AND (journal.manual_workflow_status<>'APPROVED'
    OR journal.total_debit<=0 OR journal.total_debit<>journal.total_credit)
UNION ALL
SELECT 'manual_journal_runtime_inventory','INFO',0,
  jsonb_build_object('draft',count(*) FILTER(WHERE manual_workflow_status='DRAFT'),
    'pendingApproval',count(*) FILTER(WHERE manual_workflow_status='PENDING_APPROVAL'),
    'posted',count(*) FILTER(WHERE status='POSTED'),
    'canceled',count(*) FILTER(WHERE status='CANCELED'))
FROM public.finance_journals WHERE journal_type='MANUAL';
