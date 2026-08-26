-- F4B Finance posting policy closure postflight.
-- SAFETY: SELECT-only.
WITH supported_events AS (
  SELECT event.* FROM public.financial_events event
  WHERE private.f4b_financial_event_supported(event)
),checks AS (
  SELECT 'migration_ledger' check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(count(*)-1) violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260827140000'
  UNION ALL
  SELECT 'required_posting_policy_routines',
    CASE WHEN count(*)=7 THEN 'PASS' ELSE 'FAIL' END,7-count(*),
    jsonb_build_object('expected',7,'routineRows',count(*))
  FROM (VALUES
    (to_regprocedure('public.save_finance_posting_policy(bigint,text)')),
    (to_regprocedure('public.process_automatic_financial_events(integer)')),
    (to_regprocedure('public.preview_financial_event_posting_queue(integer)')),
    (to_regprocedure('public.approve_financial_event_posting_queue(uuid,bigint)')),
    (to_regprocedure('public.process_financial_event_posting_queue(uuid,bigint)')),
    (to_regprocedure('private.f4b_financial_event_supported(public.financial_events)')),
    (to_regprocedure('private.f4b_record_posting_exception(uuid,uuid,text,text)'))
  ) routine(oid) WHERE oid IS NOT NULL
  UNION ALL
  SELECT 'automatic_posting_deferred_trigger',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,abs(count(*)-1),
    jsonb_build_object('triggerRows',count(*))
  FROM pg_trigger trigger_state
  JOIN pg_class relation ON relation.oid=trigger_state.tgrelid
  JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
  WHERE namespace.nspname='public' AND relation.relname='financial_events'
    AND trigger_state.tgname='financial_event_automatic_posting'
    AND NOT trigger_state.tgisinternal
    AND trigger_state.tgenabled<>'D'
    AND (trigger_state.tgtype&4)=4
    AND trigger_state.tgdeferrable AND trigger_state.tginitdeferred
  UNION ALL
  SELECT 'posting_policy_contract',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('invalidRows',count(*))
  FROM public.finance_company_policies policy
  WHERE policy.posting_mode NOT IN('CONTROLLED','AUTOMATIC')
    OR policy.master_version<1
  UNION ALL
  SELECT 'browser_finance_posting_write_boundary',
    CASE WHEN bool_or(writable) THEN 'FAIL' ELSE 'PASS' END,
    count(*) FILTER(WHERE writable),
    jsonb_build_object('writableRelations',COALESCE(jsonb_agg(relation_name)
      FILTER(WHERE writable),'[]'::JSONB))
  FROM (VALUES
    ('finance_company_policies',has_table_privilege('authenticated',
      'public.finance_company_policies','INSERT,UPDATE,DELETE')),
    ('finance_company_policy_audit',has_table_privilege('authenticated',
      'public.finance_company_policy_audit','INSERT,UPDATE,DELETE')),
    ('financial_events',has_table_privilege('authenticated',
      'public.financial_events','INSERT,UPDATE,DELETE')),
    ('finance_journals',has_table_privilege('authenticated',
      'public.finance_journals','INSERT,UPDATE,DELETE')),
    ('finance_journal_lines',has_table_privilege('authenticated',
      'public.finance_journal_lines','INSERT,UPDATE,DELETE')),
    ('finance_posting_exceptions',has_table_privilege('authenticated',
      'public.finance_posting_exceptions','INSERT,UPDATE,DELETE'))
  ) boundary(relation_name,writable)
  UNION ALL
  SELECT 'private_posting_helper_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('authenticatedExecutableRows',count(*))
  FROM (VALUES
    ('private.f4b_financial_event_supported(public.financial_events)'::TEXT),
    ('private.f4b_record_posting_exception(uuid,uuid,text,text)'::TEXT),
    ('private.trg_f4b_automatic_financial_event()'::TEXT)
  ) expected(signature)
  WHERE has_function_privilege('authenticated',signature,'EXECUTE')
  UNION ALL
  SELECT 'duplicate_financial_event_journal',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('duplicateGroups',count(*))
  FROM (SELECT journal.company_id,journal.financial_event_id
    FROM public.finance_journals journal
    WHERE journal.financial_event_id IS NOT NULL
    GROUP BY journal.company_id,journal.financial_event_id HAVING count(*)>1
  ) duplicate
  UNION ALL
  SELECT 'posted_event_journal_coverage',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('eventCount',count(*))
  FROM public.financial_events event
  WHERE event.status::TEXT='POSTED' AND NOT EXISTS(
    SELECT 1 FROM public.finance_journals journal
    WHERE journal.company_id=event.company_id
      AND journal.financial_event_id=event.id AND journal.status='POSTED')
  UNION ALL
  SELECT 'posted_journal_balance',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('journalCount',count(*))
  FROM public.finance_journals journal WHERE journal.status='POSTED'
    AND (journal.total_debit<>journal.total_credit OR journal.total_debit<0)
  UNION ALL
  SELECT 'canceled_event_without_journal',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('eventCount',count(*))
  FROM public.financial_events event WHERE event.status::TEXT='CANCELED'
    AND EXISTS(SELECT 1 FROM public.finance_journals journal
      WHERE journal.company_id=event.company_id
        AND journal.financial_event_id=event.id)
  UNION ALL
  SELECT 'supported_hold_backfill_scope',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BACKFILL' END,0,
    jsonb_build_object('eventCount',count(*),'companies',count(DISTINCT company_id))
  FROM supported_events
  UNION ALL
  SELECT 'posting_policy_runtime_inventory','INFO',0,jsonb_build_object(
    'controlledCompanies',(SELECT count(*) FROM public.finance_company_policies
      WHERE posting_mode='CONTROLLED'),
    'automaticCompanies',(SELECT count(*) FROM public.finance_company_policies
      WHERE posting_mode='AUTOMATIC'),
    'supportedHoldEvents',(SELECT count(*) FROM supported_events),
    'openExceptions',(SELECT count(*) FROM public.finance_posting_exceptions
      WHERE status<>'RESOLVED'),
    'postedEvents',(SELECT count(*) FROM public.financial_events
      WHERE status::TEXT='POSTED'),
    'canceledEvents',(SELECT count(*) FROM public.financial_events
      WHERE status::TEXT='CANCELED'),
    'postedJournals',(SELECT count(*) FROM public.finance_journals
      WHERE status='POSTED'))
)
SELECT check_name,status,violation_rows,details FROM checks ORDER BY
  CASE status WHEN 'FAIL' THEN 1 WHEN 'BACKFILL' THEN 2
    WHEN 'PASS' THEN 3 ELSE 4 END,check_name;
