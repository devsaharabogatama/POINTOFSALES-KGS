-- SELECT-only postflight for 20260911162000. Run the entire file.
WITH checks AS (
  SELECT 'migration_ledger'::text check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(1-count(*)) violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260911162000'
  UNION ALL
  SELECT 'required_payment_ui_routines',CASE WHEN count(*)=3 THEN 'PASS' ELSE 'FAIL' END,
    3-count(*),jsonb_build_object('expected',3,'routineRows',count(*))
  FROM pg_proc procedure JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
  WHERE (namespace.nspname,procedure.proname,pg_get_function_identity_arguments(procedure.oid)) IN(
    ('private','trg_backoffice_invoice_payment_operation_guard',''),
    ('public','get_backoffice_sales_invoice_payment_context','p_invoice_id uuid'),
    ('public','register_backoffice_sales_invoice_payment','p_invoice_id uuid, p_operation_id uuid, p_receipt_date date, p_payment_method_id uuid, p_amount numeric, p_reference_no text, p_evidence_url text, p_notes text'))
  UNION ALL
  SELECT 'payment_operation_relation_contract',CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    abs(1-count(*)),jsonb_build_object('relationRows',count(*))
  FROM pg_class relation JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
  WHERE namespace.nspname='public' AND relation.relname='backoffice_sales_invoice_payment_operations'
    AND relation.relrowsecurity
  UNION ALL
  SELECT 'payment_rpc_boundary',CASE WHEN count(*) FILTER(WHERE role.rolname='anon')=0
      AND count(*) FILTER(WHERE role.rolname='authenticated')=2 THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*) FILTER(WHERE role.rolname='anon')=0
      AND count(*) FILTER(WHERE role.rolname='authenticated')=2 THEN 0 ELSE 1 END,
    jsonb_build_object('anonExecute',count(*) FILTER(WHERE role.rolname='anon'),
      'authenticatedExecute',count(*) FILTER(WHERE role.rolname='authenticated'))
  FROM pg_proc procedure JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
  CROSS JOIN pg_roles role
  WHERE namespace.nspname='public'
    AND procedure.proname IN('get_backoffice_sales_invoice_payment_context','register_backoffice_sales_invoice_payment')
    AND has_function_privilege(role.oid,procedure.oid,'EXECUTE') AND role.rolname IN('anon','authenticated')
  UNION ALL
  SELECT 'payment_operation_reconciliation',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*),jsonb_build_object('invalidRows',count(*))
  FROM public.backoffice_sales_invoice_payment_operations operation
  LEFT JOIN public.customer_receipt_documents receipt ON receipt.company_id=operation.company_id
    AND receipt.id=operation.receipt_id
  WHERE operation.response_snapshot IS NOT NULL
    AND (receipt.id IS NULL OR receipt.status<>'POSTED'
      OR operation.response_snapshot->'payment'->>'receiptId'<>operation.receipt_id::text)
  UNION ALL
  SELECT 'invoice_payment_schedule_reconciliation',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*),jsonb_build_object('invalidRows',count(*))
  FROM (SELECT invoice.company_id,invoice.id,invoice.grand_total,
      COALESCE(sum(schedule.allocated_payment_amount),0) scheduled_paid,
      COALESCE((SELECT sum(allocation.allocated_amount)
        FROM public.customer_receipt_backoffice_invoice_allocations allocation
        JOIN public.customer_receipt_documents receipt ON receipt.company_id=allocation.company_id
          AND receipt.id=allocation.document_id AND receipt.status='POSTED'
        WHERE allocation.company_id=invoice.company_id AND allocation.invoice_id=invoice.id),0) receipt_paid
    FROM public.backoffice_sales_invoices invoice
    LEFT JOIN public.backoffice_sales_invoice_receivable_schedules schedule
      ON schedule.company_id=invoice.company_id AND schedule.invoice_id=invoice.id
    WHERE invoice.status='POSTED' GROUP BY invoice.company_id,invoice.id,invoice.grand_total) state
  WHERE round(state.scheduled_paid,4)<>round(state.receipt_paid,4)
    OR state.receipt_paid<0 OR state.receipt_paid>state.grand_total
  UNION ALL
  SELECT 'payment_ui_runtime_inventory','INFO',0,jsonb_build_object(
    'operations',count(*),'completed',count(*) FILTER(WHERE response_snapshot IS NOT NULL))
  FROM public.backoffice_sales_invoice_payment_operations
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;
