-- POS Stock Opname online UI preflight.
-- SAFETY: SELECT-only. This file does not mutate database state.

WITH checks(check_name,status,details) AS (
  SELECT 'stock_opname_runtime_dependency',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('requiredVersion','20260812190000','ledgerRows',count(*))
  FROM private.kgs_schema_migrations WHERE version='20260812190000'
  UNION ALL
  SELECT 'terminal_ui_runtime_dependency',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('requiredVersion','20260825120000','ledgerRows',count(*))
  FROM private.kgs_schema_migrations WHERE version='20260825120000'
  UNION ALL
  SELECT 'canonical_stock_opname_runtime',
    CASE WHEN count(*)=6 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('expected',6,'routineRows',count(*))
  FROM unnest(ARRAY[
    'public.save_stock_opname_session(uuid,bigint,uuid,text,uuid,jsonb,text)',
    'public.start_stock_opname(uuid,bigint)',
    'public.get_stock_opname_blind_session(uuid)',
    'public.record_stock_opname_count(uuid,bigint,uuid,numeric,text)',
    'public.complete_stock_opname(uuid,bigint)',
    'public.cancel_stock_opname(uuid,bigint)'
  ]) signature
  WHERE to_regprocedure(signature) IS NOT NULL
  UNION ALL
  SELECT 'pos_stock_opname_workspace_state',
    CASE WHEN to_regprocedure('public.get_pos_stock_opname_workspace()') IS NULL
      THEN 'SETUP' ELSE 'BLOCKER' END,
    jsonb_build_object('rpcExists',
      to_regprocedure('public.get_pos_stock_opname_workspace()') IS NOT NULL)
  UNION ALL
  SELECT 'active_finance_posting_queue',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('runCount',count(*))
  FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'stock_opname_runtime_inventory','INFO',jsonb_build_object(
    'drafts',count(*) FILTER(WHERE status='DRAFT'),
    'counting',count(*) FILTER(WHERE status='COUNTING'),
    'completed',count(*) FILTER(WHERE status='COMPLETED'),
    'posted',count(*) FILTER(WHERE status='POSTED'),
    'canceled',count(*) FILTER(WHERE status='CANCELED'))
  FROM public.stock_opnames
)
SELECT * FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'SETUP' THEN 2
  WHEN 'PASS' THEN 3 ELSE 4 END,check_name;
