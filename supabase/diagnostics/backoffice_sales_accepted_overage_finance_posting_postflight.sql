-- SELECT-only postflight for Step 5/6.1. Run the entire file.
WITH post_routine AS (
  SELECT p.oid,p.prosecdef,p.proconfig,pg_get_functiondef(p.oid) definition
  FROM pg_proc p WHERE p.oid=to_regprocedure(
    'private.post_backoffice_accepted_overage_financial_event_core(uuid,uuid,bigint,uuid)')
), dispatcher AS (
  SELECT pg_get_functiondef(to_regprocedure(
    'private.post_financial_event_core(uuid,uuid,bigint,uuid)')) definition
), supported AS (
  SELECT pg_get_functiondef(to_regprocedure(
    'private.f4b_financial_event_supported(public.financial_events)')) definition
), checks AS (
  SELECT 's5_1_migration_ledger' check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(count(*)-1)::bigint violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260912134000'
  UNION ALL SELECT 's5_1_required_routines',
    CASE WHEN count(*)=5 THEN 'PASS' ELSE 'FAIL' END,
    abs(count(*)-5)::bigint,jsonb_build_object('routineRows',count(*),'expected',5)
  FROM (VALUES
    (to_regprocedure('private.post_backoffice_accepted_overage_financial_event_core(uuid,uuid,bigint,uuid)')),
    (to_regprocedure('private.post_financial_event_core(uuid,uuid,bigint,uuid)')),
    (to_regprocedure('private.post_financial_event_core_pre_backoffice_accepted_overage(uuid,uuid,bigint,uuid)')),
    (to_regprocedure('private.f4b_financial_event_supported(public.financial_events)')),
    (to_regprocedure('private.f4b_financial_event_supported_pre_backoffice_accepted_overage(public.financial_events)'))
  ) required(oid) WHERE oid IS NOT NULL
  UNION ALL SELECT 's5_1_private_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('browserExecutableRows',count(*))
  FROM pg_proc proc JOIN pg_namespace ns ON ns.oid=proc.pronamespace
  WHERE ns.nspname='private' AND proc.proname IN(
    'post_backoffice_accepted_overage_financial_event_core',
    'post_financial_event_core_pre_backoffice_accepted_overage',
    'f4b_financial_event_supported_pre_backoffice_accepted_overage')
    AND (has_function_privilege('anon',proc.oid,'EXECUTE')
      OR has_function_privilege('authenticated',proc.oid,'EXECUTE'))
  UNION ALL SELECT 's5_1_posting_runtime_contract',
    CASE WHEN count(*)=1 AND bool_and(prosecdef
      AND proconfig @> ARRAY['search_path=public, pg_temp']) THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1 AND bool_and(prosecdef
      AND proconfig @> ARRAY['search_path=public, pg_temp']) THEN 0 ELSE 1 END,
    jsonb_build_object('routineRows',count(*),'securityDefiner',coalesce(bool_and(prosecdef),false),
      'config',min(proconfig::text)) FROM post_routine
  UNION ALL SELECT 's5_1_dispatcher_chain',
    CASE WHEN position('BACKOFFICE_ACCEPTED_OVERAGE_COGS' in definition)>0
      AND position('post_backoffice_accepted_overage_financial_event_core' in definition)>0
      AND position('post_financial_event_core_pre_backoffice_accepted_overage' in definition)>0
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN position('BACKOFFICE_ACCEPTED_OVERAGE_COGS' in definition)>0
      AND position('post_backoffice_accepted_overage_financial_event_core' in definition)>0
      AND position('post_financial_event_core_pre_backoffice_accepted_overage' in definition)>0
      THEN 0 ELSE 1 END,jsonb_build_object('dispatcherRows',1) FROM dispatcher
  UNION ALL SELECT 's5_1_queue_support_chain',
    CASE WHEN position('BACKOFFICE_ACCEPTED_OVERAGE_COGS' in definition)>0
      AND position('f4b_financial_event_supported_pre_backoffice_accepted_overage' in definition)>0
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN position('BACKOFFICE_ACCEPTED_OVERAGE_COGS' in definition)>0
      AND position('f4b_financial_event_supported_pre_backoffice_accepted_overage' in definition)>0
      THEN 0 ELSE 1 END,jsonb_build_object('supportedRows',1) FROM supported
  UNION ALL SELECT 's5_1_hold_queue_coverage',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('unsupportedHoldEvents',count(*))
  FROM public.financial_events event
  WHERE event.system_event_key='BACKOFFICE_ACCEPTED_OVERAGE_COGS' AND event.status='HOLD'
    AND NOT private.f4b_financial_event_supported(event)
  UNION ALL SELECT 's5_1_posted_journal_coverage',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('invalidRows',count(*))
  FROM public.financial_events event
  LEFT JOIN public.finance_journals journal ON journal.company_id=event.company_id
    AND journal.financial_event_id=event.id AND journal.status='POSTED'
  WHERE event.system_event_key='BACKOFFICE_ACCEPTED_OVERAGE_COGS'
    AND event.status='POSTED' AND journal.id IS NULL
  UNION ALL SELECT 's5_1_posted_journal_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('invalidRows',count(*))
  FROM (
    SELECT effect.id
    FROM public.backoffice_sales_discrepancy_stock_effects effect
    JOIN public.financial_events event ON event.company_id=effect.company_id
      AND event.id=effect.financial_event_id
      AND event.system_event_key='BACKOFFICE_ACCEPTED_OVERAGE_COGS'
      AND event.status='POSTED'
    JOIN public.finance_journals journal ON journal.company_id=event.company_id
      AND journal.financial_event_id=event.id AND journal.status='POSTED'
    LEFT JOIN public.finance_journal_lines line ON line.company_id=journal.company_id
      AND line.journal_id=journal.id
    WHERE effect.effect_type='OVERAGE_ACCEPTED_SALE'
    GROUP BY effect.id,effect.total_cost,effect.source_warehouse_id,
      journal.source_type,journal.source_id,journal.warehouse_id,
      journal.total_debit,journal.total_credit
    HAVING journal.source_type<>'backoffice_sales_discrepancy_stock_effects'
      OR journal.source_id<>effect.id
      OR journal.warehouse_id<>effect.source_warehouse_id
      OR round(journal.total_debit,4)<>round(effect.total_cost,4)
      OR round(journal.total_credit,4)<>round(effect.total_cost,4)
      OR count(line.id)<>2
      OR count(*) FILTER(WHERE line.description='COGS - Kelebihan barang diterima'
        AND round(line.debit,4)=round(effect.total_cost,4))<>1
      OR count(*) FILTER(WHERE line.description='INVENTORY_ASSET - Kelebihan barang diterima'
        AND round(line.credit,4)=round(effect.total_cost,4))<>1
  ) invalid
  UNION ALL SELECT 's5_1_runtime_inventory','INFO',0,
    jsonb_build_object('holdEvents',(SELECT count(*) FROM public.financial_events
      WHERE system_event_key='BACKOFFICE_ACCEPTED_OVERAGE_COGS' AND status='HOLD'),
      'postedEvents',(SELECT count(*) FROM public.financial_events
      WHERE system_event_key='BACKOFFICE_ACCEPTED_OVERAGE_COGS' AND status='POSTED'),
      'journals',(SELECT count(*) FROM public.finance_journals
      WHERE system_event_key='BACKOFFICE_ACCEPTED_OVERAGE_COGS'))
)
SELECT check_name,status,violation_rows,details FROM checks ORDER BY
  CASE status WHEN 'BLOCKER' THEN 0 WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
