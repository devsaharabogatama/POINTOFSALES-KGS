-- SELECT-only postflight for 20260919100000.
WITH checks AS (
  SELECT 'return_net_migration_ledger' check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(count(*)-1)::bigint violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260919100000'
  UNION ALL
  SELECT 'return_net_routine_contract',
    CASE WHEN to_regprocedure('public.get_sales_return_commercial_adjustments()')
      IS NOT NULL THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN to_regprocedure('public.get_sales_return_commercial_adjustments()')
      IS NOT NULL THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('signature',to_regprocedure(
      'public.get_sales_return_commercial_adjustments()')::text)
  UNION ALL
  SELECT 'return_net_permission_contract',
    CASE WHEN has_function_privilege('authenticated',
      'public.get_sales_return_commercial_adjustments()','EXECUTE')
      AND NOT has_function_privilege('anon',
      'public.get_sales_return_commercial_adjustments()','EXECUTE')
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN has_function_privilege('authenticated',
      'public.get_sales_return_commercial_adjustments()','EXECUTE')
      AND NOT has_function_privilege('anon',
      'public.get_sales_return_commercial_adjustments()','EXECUTE')
      THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('authenticated',has_function_privilege('authenticated',
      'public.get_sales_return_commercial_adjustments()','EXECUTE'),
      'anon',has_function_privilege('anon',
      'public.get_sales_return_commercial_adjustments()','EXECUTE'))
  UNION ALL
  SELECT 'return_net_read_only_contract',
    CASE WHEN definition !~* '\m(insert|update|delete|merge)\M'
      AND position('private_request_company_matches' in definition)>0
      AND position('sales.sales_documents' in definition)>0
      AND position('sales.backoffice_orders' in definition)>0
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN definition !~* '\m(insert|update|delete|merge)\M'
      AND position('private_request_company_matches' in definition)>0
      AND position('sales.sales_documents' in definition)>0
      AND position('sales.backoffice_orders' in definition)>0
      THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('readOnly',definition !~* '\m(insert|update|delete|merge)\M',
      'tenantGuard',position('private_request_company_matches' in definition)>0)
  FROM (SELECT pg_get_functiondef(
    'public.get_sales_return_commercial_adjustments()'::regprocedure) definition) runtime
  UNION ALL
  SELECT 'return_net_stock_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('invalidRows',count(*))
  FROM public.backoffice_sales_return_receipt_lines line
  LEFT JOIN public.stock_movements movement
    ON movement.company_id=line.company_id AND movement.id=line.stock_movement_id
  WHERE (line.disposition='RESTOCK' AND (movement.id IS NULL
      OR movement.qty_change<>line.received_base_qty))
     OR (line.disposition='DESTROY' AND line.stock_movement_id IS NOT NULL)
  UNION ALL
  SELECT 'return_net_finance_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('invalidPostedNotes',count(*))
  FROM public.backoffice_sales_credit_notes note
  WHERE note.status='POSTED' AND (note.financial_event_id IS NULL
    OR note.grand_total<>note.ar_reduction_amount+note.refund_liability_amount)
  UNION ALL
  SELECT 'return_net_runtime_inventory','INFO',0::bigint,
    jsonb_build_object(
      'receivedReturnLines',(SELECT count(*) FROM public.backoffice_sales_return_receipt_lines),
      'postedCreditNotes',(SELECT count(*) FROM public.backoffice_sales_credit_notes WHERE status='POSTED'),
      'stockMovements',(SELECT count(*) FROM public.backoffice_sales_return_receipt_lines WHERE stock_movement_id IS NOT NULL))
)
SELECT * FROM checks ORDER BY status,check_name;
