-- SELECT-only postflight for Backoffice Sales Return Step 5/5 UI read models.
WITH required(signature) AS (VALUES
  ('public.get_backoffice_sales_return_receipt_workspace()'),
  ('public.get_backoffice_sales_return_links(uuid)'),
  ('public.get_backoffice_sales_return_activity(uuid)')),
checks AS (
  SELECT 'return_ui_migration_ledger'::text check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(1-count(*))::bigint violation_rows,
    jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260918100000'
  UNION ALL
  SELECT 'return_ui_required_routines',
    CASE WHEN count(*)=3 THEN 'PASS' ELSE 'FAIL' END,
    abs(3-count(*))::bigint,
    jsonb_build_object('present',count(*),'expected',3,
      'missing',COALESCE(jsonb_agg(required.signature) FILTER(WHERE to_regprocedure(required.signature) IS NULL),'[]'::jsonb))
  FROM required
  UNION ALL
  SELECT 'return_ui_security_contract',
    CASE WHEN count(*) FILTER(WHERE routine.prosecdef AND routine.provolatile='s')=3 THEN 'PASS' ELSE 'FAIL' END,
    (3-count(*) FILTER(WHERE routine.prosecdef AND routine.provolatile='s'))::bigint,
    jsonb_build_object('securityDefinerStable',count(*) FILTER(WHERE routine.prosecdef AND routine.provolatile='s'),'expected',3)
  FROM required
  LEFT JOIN pg_proc routine ON routine.oid=to_regprocedure(required.signature)
  UNION ALL
  SELECT 'return_ui_rpc_boundary',
    CASE WHEN count(*) FILTER(WHERE has_function_privilege('anon',to_regprocedure(required.signature),'EXECUTE'))=0
      AND count(*) FILTER(WHERE has_function_privilege('authenticated',to_regprocedure(required.signature),'EXECUTE'))=3
      THEN 'PASS' ELSE 'FAIL' END,
    (count(*) FILTER(WHERE has_function_privilege('anon',to_regprocedure(required.signature),'EXECUTE'))
      + abs(3-count(*) FILTER(WHERE has_function_privilege('authenticated',to_regprocedure(required.signature),'EXECUTE'))))::bigint,
    jsonb_build_object('anonExecute',count(*) FILTER(WHERE has_function_privilege('anon',to_regprocedure(required.signature),'EXECUTE')),
      'authenticatedExecute',count(*) FILTER(WHERE has_function_privilege('authenticated',to_regprocedure(required.signature),'EXECUTE')))
  FROM required
  UNION ALL
  SELECT 'return_ui_definition_contract',
    CASE WHEN
      position('inventory.customer_return_receipts' in lower(pg_get_functiondef(to_regprocedure('public.get_backoffice_sales_return_receipt_workspace()'))))>0
      AND position('sales.backoffice_orders' in lower(pg_get_functiondef(to_regprocedure('public.get_backoffice_sales_return_links(uuid)'))))>0
      AND position('sales.backoffice_returns' in lower(pg_get_functiondef(to_regprocedure('public.get_backoffice_sales_return_activity(uuid)'))))>0
      AND position('financial_events' in lower(pg_get_functiondef(to_regprocedure('public.get_backoffice_sales_return_receipt_workspace()'))))=0
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN
      position('inventory.customer_return_receipts' in lower(pg_get_functiondef(to_regprocedure('public.get_backoffice_sales_return_receipt_workspace()'))))>0
      AND position('sales.backoffice_orders' in lower(pg_get_functiondef(to_regprocedure('public.get_backoffice_sales_return_links(uuid)'))))>0
      AND position('sales.backoffice_returns' in lower(pg_get_functiondef(to_regprocedure('public.get_backoffice_sales_return_activity(uuid)'))))>0
      AND position('financial_events' in lower(pg_get_functiondef(to_regprocedure('public.get_backoffice_sales_return_receipt_workspace()'))))=0
      THEN 0 ELSE 1 END,
    jsonb_build_object('inventoryAuthority',true,'salesLinkAuthority',true,'activityAuthority',true,'readOnly',true)
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;
