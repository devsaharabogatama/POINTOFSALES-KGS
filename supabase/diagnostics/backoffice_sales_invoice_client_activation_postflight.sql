-- SELECT-only verification after 20260911150000.
WITH checks AS (
  SELECT 'migration_ledger' check_name,CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(count(*)-1)::bigint violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260911150000'
  UNION ALL
  SELECT 'required_invoice_client_routines',CASE WHEN count(*)=3 THEN 'PASS' ELSE 'FAIL' END,
    abs(count(*)-3)::bigint,jsonb_build_object('expected',3,'present',count(*))
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE (n.nspname,p.proname) IN(('private','backoffice_sales_invoice_ui_snapshot'),
    ('public','get_backoffice_sales_invoice_workspace'),('public','get_backoffice_sales_invoice_ui'))
  UNION ALL
  SELECT 'invoice_client_rpc_boundary',CASE WHEN count(*)=2 THEN 'PASS' ELSE 'FAIL' END,
    abs(count(*)-2)::bigint,jsonb_build_object('authenticatedExecuteRows',count(*))
  FROM information_schema.routine_privileges WHERE grantee='authenticated' AND specific_schema='public'
    AND routine_name IN('get_backoffice_sales_invoice_workspace','get_backoffice_sales_invoice_ui')
  UNION ALL
  SELECT 'invoice_client_private_boundary',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('browserExecutableRows',count(*))
  FROM information_schema.routine_privileges WHERE grantee IN('anon','authenticated')
    AND specific_schema='private' AND routine_name='backoffice_sales_invoice_ui_snapshot'
  UNION ALL
  SELECT 'explicit_due_date_call_chain',CASE WHEN save_definition~'kgs.backoffice_invoice_due_date'
      AND schedule_definition~'kgs.backoffice_invoice_due_date'
      AND save_definition~'fulfillment_status=''COMPLETED''' THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN save_definition~'kgs.backoffice_invoice_due_date'
      AND schedule_definition~'kgs.backoffice_invoice_due_date'
      AND save_definition~'fulfillment_status=''COMPLETED''' THEN 0 ELSE 1 END,
    jsonb_build_object('dueDatePassedBeforeImmutableAudit',save_definition~'kgs.backoffice_invoice_due_date',
      'completedOrderRequired',save_definition~'fulfillment_status=''COMPLETED''')
  FROM (SELECT pg_get_functiondef('public.save_backoffice_sales_invoice_draft(uuid,bigint,uuid,uuid,jsonb)'::regprocedure) save_definition,
      pg_get_functiondef('private.rebuild_backoffice_sales_invoice_schedules(uuid,uuid,uuid)'::regprocedure) schedule_definition) definition
  UNION ALL
  SELECT 'invoice_schedule_reconciliation',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('invalidInvoices',count(*))
  FROM (SELECT invoice.company_id,invoice.id,invoice.grand_total,
      COALESCE(sum(schedule.amount_due),0) scheduled
    FROM public.backoffice_sales_invoices invoice
    LEFT JOIN public.backoffice_sales_invoice_receivable_schedules schedule
      ON schedule.company_id=invoice.company_id AND schedule.invoice_id=invoice.id
      AND schedule.status<>'CANCELED'
    WHERE invoice.status IN('DRAFT','POSTED') GROUP BY invoice.company_id,invoice.id) state
  WHERE round(state.grand_total,4)<>round(state.scheduled,4)
), inventory AS (
  SELECT 'invoice_client_runtime_inventory' check_name,'INFO' status,0::bigint violation_rows,
    jsonb_build_object('invoiceableCompletedOrders',(SELECT count(DISTINCT document.id)
      FROM public.backoffice_sales_orders document JOIN public.backoffice_sales_order_lines line
        ON line.company_id=document.company_id AND line.sales_order_id=document.id
      WHERE document.status='CONFIRMED' AND document.fulfillment_status='COMPLETED'
        AND line.to_invoice_base_qty>0),'draftInvoices',(SELECT count(*) FROM public.backoffice_sales_invoices WHERE status='DRAFT'),
      'postedInvoices',(SELECT count(*) FROM public.backoffice_sales_invoices WHERE status='POSTED')) details
)
SELECT * FROM (SELECT * FROM checks UNION ALL SELECT * FROM inventory) result
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
