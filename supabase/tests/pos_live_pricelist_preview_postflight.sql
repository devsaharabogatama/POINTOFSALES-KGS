-- POS live Pricelist preview postflight. SELECT-only.
WITH checks AS (
  SELECT 'migration_ledger'::TEXT AS check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END AS status,
    count(*)::BIGINT AS violation_rows,
    jsonb_build_object('ledgerRows',count(*)) AS details
  FROM private.kgs_schema_migrations
  WHERE version='20260825100000'
  UNION ALL
  SELECT 'required_price_preview_routine',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    abs(1-count(*))::BIGINT,
    jsonb_build_object('routineRows',count(*))
  FROM pg_proc procedure
  JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname='public'
    AND procedure.proname='preview_pos_sale_prices'
    AND pg_get_function_identity_arguments(procedure.oid)=
      'p_cashier_session_id uuid, p_customer_id uuid, p_selected_pricelist_id uuid, p_lines jsonb'
  UNION ALL
  SELECT 'price_preview_rpc_boundary',
    CASE WHEN NOT has_function_privilege(
      'anon','public.preview_pos_sale_prices(uuid,uuid,uuid,jsonb)','EXECUTE'
    ) AND has_function_privilege(
      'authenticated','public.preview_pos_sale_prices(uuid,uuid,uuid,jsonb)','EXECUTE'
    ) THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN NOT has_function_privilege(
      'anon','public.preview_pos_sale_prices(uuid,uuid,uuid,jsonb)','EXECUTE'
    ) AND has_function_privilege(
      'authenticated','public.preview_pos_sale_prices(uuid,uuid,uuid,jsonb)','EXECUTE'
    ) THEN 0 ELSE 1 END,
    jsonb_build_object(
      'anonExecutable',has_function_privilege(
        'anon','public.preview_pos_sale_prices(uuid,uuid,uuid,jsonb)','EXECUTE'),
      'authenticatedExecutable',has_function_privilege(
        'authenticated','public.preview_pos_sale_prices(uuid,uuid,uuid,jsonb)','EXECUTE')
    )
)
SELECT check_name,status,violation_rows,details
FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 ELSE 2 END,check_name;
