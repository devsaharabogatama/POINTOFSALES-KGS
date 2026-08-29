-- POS scheduled order behavior/definition verification.
-- SAFETY: SELECT-only; operational behavior remains guarded by public RPC.
WITH routine AS (
  SELECT namespace.nspname schema_name,procedure.proname,
    pg_get_functiondef(procedure.oid) definition
  FROM pg_proc procedure JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
  WHERE (namespace.nspname,procedure.proname) IN(
    ('public','save_pos_sale_draft_with_pricelist'),
    ('public','list_pos_sale_drafts'),('public','post_pos_sale'))
), checks AS (
  SELECT 'future_order_post_guard'::TEXT check_name,
    CASE WHEN definition LIKE '%SCHEDULED_ORDER_NOT_ACTIVE%' THEN 'PASS' ELSE 'FAIL' END status,
    jsonb_build_object('routineRows',1) details FROM routine WHERE proname='post_pos_sale'
  UNION ALL
  SELECT 'company_date_derived_activation',
    CASE WHEN definition LIKE '%planned_order_date>v_today%'
      AND definition LIKE '%operationalStatus%' THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('routineRows',1) FROM routine WHERE proname='list_pos_sale_drafts'
  UNION ALL
  SELECT 'scheduled_tempo_only_guard',
    CASE WHEN definition LIKE '%SCHEDULED_ORDER_TEMPO_REQUIRED%'
      AND definition LIKE '%validate_pos_scheduled_order_dates%' THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('routineRows',1) FROM routine
    WHERE proname='save_pos_sale_draft_with_pricelist'
  UNION ALL
  SELECT 'manual_post_only_contract',
    CASE WHEN NOT EXISTS(SELECT 1 FROM pg_trigger trigger
      JOIN pg_class relation ON relation.oid=trigger.tgrelid
      JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
      WHERE namespace.nspname='public' AND relation.relname='sales_headers'
        AND NOT trigger.tgisinternal AND pg_get_triggerdef(trigger.oid)
          LIKE '%post_pos_sale%') THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('automaticPostTrigger',false)
)
SELECT check_name,status,details FROM checks ORDER BY check_name;
