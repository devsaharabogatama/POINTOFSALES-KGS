-- Read-only production preflight for Manual Finance Journal rollout.
WITH required_relations(name) AS (
  VALUES ('finance_journals'),('finance_journal_lines'),('finance_journal_audit'),
         ('finance_company_policies'),('accounting_periods'),('chart_of_accounts'),
         ('access_permission_catalog'),('finance_posting_queue_runs')
), relation_check AS (
  SELECT array_agg(name ORDER BY name) FILTER (
    WHERE to_regclass('public.'||name) IS NULL
  ) AS missing FROM required_relations
), required_routines(signature) AS (
  VALUES ('private.acp_require_permission_capability(uuid,text,text)'),
         ('private.acp_resolve_permission(uuid,uuid,text)'),
         ('private.ensure_company_accounting_periods(uuid,date,uuid)'),
         ('private.trg_g6_guard_finance_journal()'),
         ('private.trg_g6_guard_finance_journal_line()'),
         ('public.private_active_company_id()')
), routine_check AS (
  SELECT array_agg(signature ORDER BY signature) FILTER (
    WHERE to_regprocedure(signature) IS NULL
  ) AS missing FROM required_routines
)
SELECT 'manual_journal_required_relations' check_name,
  CASE WHEN coalesce(cardinality(missing),0)=0 THEN 'PASS' ELSE 'BLOCKER' END status,
  coalesce(cardinality(missing),0)::bigint violation_rows,
  jsonb_build_object('missing',coalesce(to_jsonb(missing),'[]'::jsonb)) details
FROM relation_check
UNION ALL
SELECT 'manual_journal_required_routines',
  CASE WHEN coalesce(cardinality(missing),0)=0 THEN 'PASS' ELSE 'BLOCKER' END,
  coalesce(cardinality(missing),0)::bigint,
  jsonb_build_object('missing',coalesce(to_jsonb(missing),'[]'::jsonb))
FROM routine_check
UNION ALL
SELECT 'manual_journal_dependency_ledger',
  CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END,
  abs(count(*)-1)::bigint,jsonb_build_object('required','20260919110000','rows',count(*))
FROM private.kgs_schema_migrations WHERE version='20260919110000'
UNION ALL
SELECT 'manual_journal_object_collision',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
  jsonb_build_object('existing',coalesce(jsonb_agg(name),'[]'::jsonb))
FROM (
  SELECT 'finance_journals.manual_workflow_status' name WHERE EXISTS(
    SELECT 1 FROM information_schema.columns WHERE table_schema='public'
      AND table_name='finance_journals' AND column_name='manual_workflow_status')
  UNION ALL SELECT 'finance.manual_journals' WHERE EXISTS(
    SELECT 1 FROM public.access_permission_catalog
    WHERE permission_key='finance.manual_journals')
  UNION ALL SELECT 'public.get_manual_finance_journal_context()' WHERE
    to_regprocedure('public.get_manual_finance_journal_context()') IS NOT NULL
) collision
UNION ALL
SELECT 'manual_journal_active_finance_queue',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
  jsonb_build_object('runRows',count(*))
FROM public.finance_posting_queue_runs
WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
UNION ALL
SELECT 'manual_journal_existing_inventory','INFO',0,
  jsonb_build_object(
    'manualJournals',count(*) FILTER(WHERE journal_type='MANUAL'),
    'manualDrafts',count(*) FILTER(WHERE journal_type='MANUAL' AND status='DRAFT'),
    'manualPosted',count(*) FILTER(WHERE journal_type='MANUAL' AND status='POSTED'),
    'manualCanceled',count(*) FILTER(WHERE journal_type='MANUAL' AND status='CANCELED'))
FROM public.finance_journals
UNION ALL
SELECT 'manual_posting_account_inventory','INFO',0,
  jsonb_build_object('eligibleAccounts',count(*) FILTER(
    WHERE is_active AND is_postable AND allow_manual_posting),
    'companiesWithoutEligibleAccounts',(
      SELECT count(*) FROM public.companies company
      WHERE company.status='ACTIVE' AND NOT EXISTS(
        SELECT 1 FROM public.chart_of_accounts account
        WHERE account.company_id=company.id AND account.is_active
          AND account.is_postable AND account.allow_manual_posting)))
FROM public.chart_of_accounts
UNION ALL
SELECT 'manual_journal_migration_ledger',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
  jsonb_build_object('existingRows',count(*))
FROM private.kgs_schema_migrations
WHERE version='20260919120000';
