-- Backoffice Quotation/Sales Order runtime postflight. READ ONLY.
WITH required_routines(signature) AS (
  VALUES
    ('public.get_backoffice_sales_order_workspace()'),
    ('public.get_backoffice_sales_orders(text,text,integer)'),
    ('public.get_backoffice_sales_order(uuid)'),
    ('public.save_backoffice_sales_order_draft(uuid,bigint,uuid,jsonb)'),
    ('public.send_backoffice_sales_quotation(uuid,bigint,uuid)'),
    ('public.confirm_backoffice_sales_order(uuid,bigint,uuid)'),
    ('public.cancel_backoffice_sales_order(uuid,bigint,uuid,text)')
), results AS (
  SELECT 'migration_ledger'::text check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END::text status,
    abs(count(*)-1)::bigint violation_rows,
    jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260908120000'
  UNION ALL
  SELECT 'required_backoffice_order_routines',
    CASE WHEN count(*)=7 THEN 'PASS' ELSE 'BLOCKER' END,
    abs(7-count(*))::bigint,jsonb_build_object('expected',7,'routineRows',count(*))
  FROM required_routines WHERE to_regprocedure(signature) IS NOT NULL
  UNION ALL
  SELECT 'backoffice_order_permission_enforced',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END,
    abs(count(*)-1)::bigint,jsonb_build_object('rows',count(*),
      'statuses',COALESCE(jsonb_agg(enforcement_status),'[]'::jsonb))
  FROM public.access_permission_catalog
  WHERE permission_key='sales.backoffice_orders' AND enforcement_status='ENFORCED'
    AND required_any_features=ARRAY['backoffice_delivered_qty_sales_enabled']::text[]
  UNION ALL
  SELECT 'backoffice_sales_feature_remains_off',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('enabledCompanies',count(*))
  FROM public.company_features WHERE feature_code='backoffice_delivered_qty_sales_enabled'
    AND is_enabled
  UNION ALL
  SELECT 'public_order_runtime_security_contract',
    CASE WHEN count(*)=7 THEN 'PASS' ELSE 'BLOCKER' END,
    abs(7-count(*))::bigint,jsonb_build_object('expected',7,'routineRows',count(*))
  FROM required_routines required
  JOIN pg_proc routine ON routine.oid=to_regprocedure(required.signature)
  WHERE routine.prosecdef AND routine.provolatile IN('s','v')
    AND routine.proconfig @> ARRAY['search_path=public, pg_temp']::text[]
  UNION ALL
  SELECT 'public_order_runtime_rpc_boundary',
    CASE WHEN anon_rows=0 AND authenticated_rows=7 THEN 'PASS' ELSE 'BLOCKER' END,
    (anon_rows+abs(7-authenticated_rows))::bigint,
    jsonb_build_object('anonExecute',anon_rows,'authenticatedExecute',authenticated_rows)
  FROM (SELECT
    count(*) FILTER(WHERE has_function_privilege('anon',signature,'EXECUTE')) anon_rows,
    count(*) FILTER(WHERE has_function_privilege('authenticated',signature,'EXECUTE')) authenticated_rows
    FROM required_routines) privilege_state
  UNION ALL
  SELECT 'private_order_runtime_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('authenticatedExecutableRows',count(*))
  FROM (VALUES
    ('private.backoffice_sales_order_snapshot(uuid,uuid)'),
    ('private.backoffice_operation_retry(uuid,uuid,text,text)'),
    ('private.transition_backoffice_sales_order(uuid,bigint,uuid,text,text)')
  ) private_routine(signature)
  WHERE has_function_privilege('authenticated',signature,'EXECUTE')
  UNION ALL
  SELECT 'order_runtime_forbidden_effect_definition',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('routineRows',count(*))
  FROM (SELECT signature FROM required_routines UNION ALL
    SELECT 'private.transition_backoffice_sales_order(uuid,bigint,uuid,text,text)') required
  WHERE lower(pg_get_functiondef(to_regprocedure(required.signature))) ~
    '(insert into|update|delete from)[[:space:]]+public\.(sales_headers|sales_stock_reservations|sales_delivery_documents|sales_invoice_snapshots|stock_movements|financial_events|finance_journals|sales_payment_verification_requests)'
  UNION ALL
  SELECT 'backoffice_order_runtime_inventory','INFO',0::bigint,
    jsonb_build_object('orders',(SELECT count(*) FROM public.backoffice_sales_orders),
      'lines',(SELECT count(*) FROM public.backoffice_sales_order_lines),
      'operations',(SELECT count(*) FROM public.backoffice_sales_order_operations),
      'auditRows',(SELECT count(*) FROM public.backoffice_sales_order_audit),
      'reservations',(SELECT count(*) FROM public.sales_stock_reservations),
      'deliveryDocuments',(SELECT count(*) FROM public.sales_delivery_documents),
      'invoiceSnapshots',(SELECT count(*) FROM public.sales_invoice_snapshots),
      'stockMovements',(SELECT count(*) FROM public.stock_movements),
      'financeEvents',(SELECT count(*) FROM public.financial_events))
)
SELECT check_name,status,violation_rows,details FROM results
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
