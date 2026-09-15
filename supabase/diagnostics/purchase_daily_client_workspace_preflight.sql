-- SELECT-only preflight for Purchase Step 6/6C client workspace.
WITH checks AS (
  SELECT 'client_workspace_dependency_ledger' check_name,
    CASE WHEN count(*)=10 THEN 'PASS' ELSE 'BLOCKER' END status,
    10-count(*) violation_rows,
    jsonb_build_object('expected',10,'present',count(*)) details
  FROM private.kgs_schema_migrations
  WHERE version IN('20260913100000','20260913110000','20260913120000',
    '20260913130000','20260914100000','20260914110000','20260914112000',
    '20260914130000','20260914140000','20260914141000')
  UNION ALL
  SELECT 'client_workspace_base_routine','PASS',0,
    jsonb_build_object('baseRoutineExists',
      to_regprocedure('public.get_purchase_daily_auto_ro_workspace()') IS NOT NULL)
  WHERE to_regprocedure('public.get_purchase_daily_auto_ro_workspace()') IS NOT NULL
  UNION ALL
  SELECT 'client_workspace_base_routine','BLOCKER',1,
    jsonb_build_object('baseRoutineExists',false)
  WHERE to_regprocedure('public.get_purchase_daily_auto_ro_workspace()') IS NULL
  UNION ALL
  SELECT 'client_workspace_routine_collision',
    CASE WHEN to_regprocedure('public.get_purchase_daily_replenishment_client_workspace()') IS NULL
      THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN to_regprocedure('public.get_purchase_daily_replenishment_client_workspace()') IS NULL
      THEN 0 ELSE 1 END,
    jsonb_build_object('existing',
      to_regprocedure('public.get_purchase_daily_replenishment_client_workspace()') IS NOT NULL)
)
SELECT check_name,status,violation_rows,details FROM checks ORDER BY check_name;
