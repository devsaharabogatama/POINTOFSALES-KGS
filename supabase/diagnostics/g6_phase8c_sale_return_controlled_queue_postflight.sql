-- G6 phase 8C postflight. SAFETY: SELECT-only.
WITH checks(check_name,status,violation_rows,details) AS (
 SELECT 'migration_ledger',CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
  abs(1-count(*)),jsonb_build_object('ledgerRows',count(*))
 FROM private.kgs_schema_migrations WHERE version='20260814130000'
 UNION ALL SELECT 'controlled_queue_routine',CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
  abs(1-count(*)),jsonb_build_object('routineRows',count(*))
 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
 WHERE n.nspname='public' AND p.proname='preview_sale_return_posting_queue'
 UNION ALL SELECT 'controlled_queue_rpc_boundary',
  CASE WHEN count(*) FILTER(WHERE has_function_privilege('anon',p.oid,'EXECUTE'))=0
    AND count(*) FILTER(WHERE has_function_privilege('authenticated',p.oid,'EXECUTE'))=1
    THEN 'PASS' ELSE 'FAIL' END,
  count(*) FILTER(WHERE has_function_privilege('anon',p.oid,'EXECUTE')),
  jsonb_build_object('anonRows',count(*) FILTER(WHERE has_function_privilege('anon',p.oid,'EXECUTE')),
    'authenticatedRows',count(*) FILTER(WHERE has_function_privilege('authenticated',p.oid,'EXECUTE')))
 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
 WHERE n.nspname='public' AND p.proname='preview_sale_return_posting_queue'
 UNION ALL SELECT 'active_finance_queue',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
  count(*),jsonb_build_object('runCount',count(*))
 FROM public.finance_posting_queue_runs WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
 UNION ALL SELECT 'historical_sale_return_final_effect_closed',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
  jsonb_build_object('journalRows',count(*))
 FROM public.finance_journals journal JOIN public.financial_events event
  ON event.company_id=journal.company_id AND event.id=journal.financial_event_id
 WHERE event.system_event_key IN('SALE_POSTED','SALES_RETURN')
 UNION ALL SELECT 'sale_return_controlled_scope','INFO',0,jsonb_build_object(
  'holdEvents',(SELECT count(*) FROM public.financial_events
    WHERE status='HOLD'::public.event_status
      AND system_event_key IN('SALE_POSTED','SALES_RETURN')),
  'companies',(SELECT count(DISTINCT company_id) FROM public.financial_events
    WHERE status='HOLD'::public.event_status
      AND system_event_key IN('SALE_POSTED','SALES_RETURN')))
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
