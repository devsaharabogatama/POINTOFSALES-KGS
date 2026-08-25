-- POS Terminal price override postflight.
-- SAFETY: SELECT-only.

WITH routine_state AS (
  SELECT count(*)::INTEGER AS routine_rows
  FROM unnest(ARRAY[
    'private.resolve_pos_sale_price_before_terminal_override(uuid,uuid,uuid,uuid,numeric,timestamptz)',
    'private.resolve_pos_sale_price(uuid,uuid,uuid,uuid,numeric,timestamptz)',
    'private.reprice_pos_sale_draft_before_terminal_override(uuid,uuid,uuid,jsonb,timestamptz)',
    'private.reprice_pos_sale_draft(uuid,uuid,uuid,jsonb,timestamptz)',
    'public.save_pos_terminal_ui_settings(uuid,bigint,text[])',
    'public.save_pos_terminal_ui_settings(uuid,bigint,text[],boolean)'
  ]) signature
  WHERE to_regprocedure(signature) IS NOT NULL
), definition_state AS (
  SELECT
    pg_get_functiondef('private.reprice_pos_sale_draft(uuid,uuid,uuid,jsonb,timestamptz)'::regprocedure) AS reprice_definition,
    pg_get_functiondef('private.resolve_pos_sale_price(uuid,uuid,uuid,uuid,numeric,timestamptz)'::regprocedure) AS resolver_definition
), checks AS (
  SELECT 'migration_ledger'::TEXT AS check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END AS status,
    abs(count(*)-1)::BIGINT AS violation_rows,
    jsonb_build_object('ledgerRows',count(*)) AS details
  FROM private.kgs_schema_migrations WHERE version='20260825120000'
  UNION ALL
  SELECT 'required_terminal_price_override_columns',
    CASE WHEN count(*)=9 THEN 'PASS' ELSE 'FAIL' END,
    (9-count(*))::BIGINT,
    jsonb_build_object('columnRows',count(*),'expected',9)
  FROM information_schema.columns
  WHERE table_schema='public' AND (
    (table_name='pos_terminals' AND column_name='allow_price_override') OR
    (table_name='sales_details' AND column_name IN(
      'canonical_resolved_unit_price','price_override_applied',
      'price_override_unit_price','price_override_actor_id',
      'price_override_terminal_id','price_override_session_id',
      'price_override_source','price_override_resolved_at')))
  UNION ALL
  SELECT 'required_terminal_price_override_routines',
    CASE WHEN routine_rows=6 THEN 'PASS' ELSE 'FAIL' END,
    (6-routine_rows)::BIGINT,
    jsonb_build_object('routineRows',routine_rows,'expected',6)
  FROM routine_state
  UNION ALL
  SELECT 'terminal_policy_default_contract',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::BIGINT,
    jsonb_build_object('invalidRows',count(*))
  FROM public.pos_terminals WHERE allow_price_override IS NULL
  UNION ALL
  SELECT 'historical_sale_line_snapshot_backfill',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::BIGINT,
    jsonb_build_object('invalidRows',count(*))
  FROM public.sales_details
  WHERE canonical_resolved_unit_price IS DISTINCT FROM resolved_unit_price
     OR price_override_applied
  UNION ALL
  SELECT 'terminal_override_online_runtime_contract',
    CASE WHEN reprice_definition LIKE '%allow_price_override%'
       AND reprice_definition LIKE '%session.status%'
       AND reprice_definition LIKE '%OPEN%'
       AND reprice_definition LIKE '%session.cashier_id%p_actor_id%'
       AND reprice_definition LIKE '%POS_TERMINAL_PRICE_OVERRIDE_DISABLED%'
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN reprice_definition LIKE '%allow_price_override%'
       AND reprice_definition LIKE '%session.status%'
       AND reprice_definition LIKE '%OPEN%'
       AND reprice_definition LIKE '%session.cashier_id%p_actor_id%'
       AND reprice_definition LIKE '%POS_TERMINAL_PRICE_OVERRIDE_DISABLED%'
      THEN 0 ELSE 1 END,
    jsonb_build_object('routineRows',1)
  FROM definition_state
  UNION ALL
  SELECT 'offline_price_override_boundary',
    CASE WHEN reprice_definition LIKE '%OFFLINE_PRICE_OVERRIDE_NOT_ALLOWED%'
       AND resolver_definition LIKE '%OFFLINE_PRICE_OVERRIDE_NOT_ALLOWED%'
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN reprice_definition LIKE '%OFFLINE_PRICE_OVERRIDE_NOT_ALLOWED%'
       AND resolver_definition LIKE '%OFFLINE_PRICE_OVERRIDE_NOT_ALLOWED%'
      THEN 0 ELSE 1 END,
    jsonb_build_object('routineRows',2)
  FROM definition_state
  UNION ALL
  SELECT 'browser_terminal_policy_write_boundary',
    CASE WHEN NOT has_column_privilege('authenticated','public.pos_terminals',
      'allow_price_override','UPDATE') THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN NOT has_column_privilege('authenticated','public.pos_terminals',
      'allow_price_override','UPDATE') THEN 0 ELSE 1 END,
    jsonb_build_object('directColumnWrite',has_column_privilege(
      'authenticated','public.pos_terminals','allow_price_override','UPDATE'))
  UNION ALL
  SELECT 'terminal_policy_rpc_boundary',
    CASE WHEN has_function_privilege('authenticated',
      'public.save_pos_terminal_ui_settings(uuid,bigint,text[],boolean)','EXECUTE')
      AND NOT has_function_privilege('anon',
      'public.save_pos_terminal_ui_settings(uuid,bigint,text[],boolean)','EXECUTE')
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN has_function_privilege('authenticated',
      'public.save_pos_terminal_ui_settings(uuid,bigint,text[],boolean)','EXECUTE')
      AND NOT has_function_privilege('anon',
      'public.save_pos_terminal_ui_settings(uuid,bigint,text[],boolean)','EXECUTE')
      THEN 0 ELSE 1 END,
    jsonb_build_object(
      'authenticatedExecute',has_function_privilege('authenticated',
        'public.save_pos_terminal_ui_settings(uuid,bigint,text[],boolean)','EXECUTE'),
      'anonExecute',has_function_privilege('anon',
        'public.save_pos_terminal_ui_settings(uuid,bigint,text[],boolean)','EXECUTE'))
  UNION ALL
  SELECT 'price_override_runtime_inventory','INFO',0,jsonb_build_object(
    'enabledTerminals',count(*) FILTER(WHERE allow_price_override),
    'activeTerminals',count(*) FILTER(WHERE status='ACTIVE'),
    'overrideSaleLines',(SELECT count(*) FROM public.sales_details
      WHERE price_override_applied))
  FROM public.pos_terminals
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;
