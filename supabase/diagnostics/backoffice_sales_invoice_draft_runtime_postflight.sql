-- Read-only verification after gate 20260909157000.
WITH checks AS (
  SELECT 'migration_ledger'::text check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(count(*)-1)::bigint violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260909157000'
  UNION ALL
  SELECT 'required_draft_invoice_runtime_routines',CASE WHEN count(*)=8 THEN 'PASS' ELSE 'FAIL' END,
    abs(count(*)-8)::bigint,jsonb_build_object('expected',8,'routineRows',count(*))
  FROM (VALUES
    (to_regprocedure('private.backoffice_sales_invoice_snapshot(uuid,uuid)')),
    (to_regprocedure('private.backoffice_sales_invoice_operation_retry(uuid,uuid,text,text)')),
    (to_regprocedure('private.backoffice_sales_invoice_due_date(date,text,integer,integer)')),
    (to_regprocedure('private.rebuild_backoffice_sales_invoice_schedules(uuid,uuid,uuid)')),
    (to_regprocedure('private.save_backoffice_sales_invoice_draft_core(uuid,bigint,uuid,uuid,jsonb)')),
    (to_regprocedure('public.save_backoffice_sales_invoice_draft(uuid,bigint,uuid,uuid,jsonb)')),
    (to_regprocedure('public.cancel_backoffice_sales_invoice_draft(uuid,bigint,uuid,text)')),
    (to_regprocedure('public.get_backoffice_sales_invoice(uuid)'))
  ) routine(oid) WHERE oid IS NOT NULL
  UNION ALL
  SELECT 'draft_invoice_operation_relation',CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    abs(count(*)-1)::bigint,jsonb_build_object('relationRows',count(*))
  FROM information_schema.tables WHERE table_schema='public'
    AND table_name='backoffice_sales_invoice_operations'
  UNION ALL
  SELECT 'dp_tax_split_columns',CASE WHEN count(*)=2 THEN 'PASS' ELSE 'FAIL' END,
    abs(count(*)-2)::bigint,jsonb_build_object('columnRows',count(*))
  FROM information_schema.columns WHERE table_schema='public'
    AND table_name='backoffice_sales_down_payment_applications'
    AND column_name IN('applied_basis_amount','applied_tax_amount')
  UNION ALL
  SELECT 'draft_invoice_runtime_security_contract',
    CASE WHEN count(*)=3 AND bool_and(prosecdef) AND bool_and(provolatile IN('s','v'))
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=3 AND bool_and(prosecdef) AND bool_and(provolatile IN('s','v'))
      THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('routineRows',count(*),'securityDefiner',bool_and(prosecdef))
  FROM pg_proc function JOIN pg_namespace namespace ON namespace.oid=function.pronamespace
  WHERE namespace.nspname='public' AND function.oid IN(
    to_regprocedure('public.save_backoffice_sales_invoice_draft(uuid,bigint,uuid,uuid,jsonb)'),
    to_regprocedure('public.cancel_backoffice_sales_invoice_draft(uuid,bigint,uuid,text)'),
    to_regprocedure('public.get_backoffice_sales_invoice(uuid)'))
  UNION ALL
  SELECT 'draft_invoice_runtime_rpc_boundary',
    CASE WHEN anon_count=0 AND authenticated_count=3 THEN 'PASS' ELSE 'FAIL' END,
    (anon_count+abs(authenticated_count-3))::bigint,
    jsonb_build_object('anonExecute',anon_count,'authenticatedExecute',authenticated_count)
  FROM (SELECT
    count(*) FILTER(WHERE grantee='anon') anon_count,
    count(*) FILTER(WHERE grantee='authenticated') authenticated_count
    FROM information_schema.routine_privileges
    WHERE specific_schema='public' AND privilege_type='EXECUTE'
      AND routine_name IN('save_backoffice_sales_invoice_draft',
        'cancel_backoffice_sales_invoice_draft','get_backoffice_sales_invoice')) privilege
  UNION ALL
  SELECT 'private_draft_invoice_runtime_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('browserExecutableRows',count(*))
  FROM information_schema.routine_privileges
  WHERE specific_schema='private' AND grantee IN('anon','authenticated')
    AND routine_name IN('backoffice_sales_invoice_snapshot',
      'backoffice_sales_invoice_operation_retry','backoffice_sales_invoice_due_date',
      'rebuild_backoffice_sales_invoice_schedules','save_backoffice_sales_invoice_draft_core')
  UNION ALL
  SELECT 'draft_quantity_hold_reconciliation',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('invalidRows',count(*))
  FROM (SELECT line.company_id,line.id
    FROM public.backoffice_sales_order_lines line
    LEFT JOIN (SELECT company_id,sales_order_line_id,sum(allocated_base_qty) quantity
      FROM public.backoffice_sales_invoice_quantity_allocations WHERE status='HELD'
      GROUP BY company_id,sales_order_line_id) held
      ON held.company_id=line.company_id AND held.sales_order_line_id=line.id
    WHERE line.draft_invoice_allocated_base_qty<>COALESCE(held.quantity,0)) mismatch
  UNION ALL
  SELECT 'draft_schedule_total_reconciliation',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('invalidRows',count(*))
  FROM (SELECT invoice.id
    FROM public.backoffice_sales_invoices invoice
    LEFT JOIN public.backoffice_sales_invoice_receivable_schedules schedule
      ON schedule.company_id=invoice.company_id AND schedule.invoice_id=invoice.id
      AND schedule.status='DRAFT'
    WHERE invoice.status='DRAFT'
    GROUP BY invoice.id,invoice.grand_total
    HAVING COALESCE(sum(schedule.amount_due),0)<>invoice.grand_total) mismatch
  UNION ALL
  SELECT 'draft_runtime_no_finance_effect',
    CASE WHEN event_count=0 AND journal_count=0 THEN 'PASS' ELSE 'FAIL' END,
    (event_count+journal_count)::bigint,
    jsonb_build_object('invoiceEvents',event_count,'invoiceJournals',journal_count)
  FROM (SELECT
    (SELECT count(*) FROM public.financial_events
      WHERE source_table='backoffice_sales_invoices') event_count,
    (SELECT count(*) FROM public.finance_journals
      WHERE source_type='backoffice_sales_invoices') journal_count) tally
), inventory AS (
  SELECT 'draft_invoice_runtime_inventory'::text check_name,'INFO'::text status,
    0::bigint violation_rows,jsonb_build_object(
      'draftInvoices',(SELECT count(*) FROM public.backoffice_sales_invoices WHERE status='DRAFT'),
      'canceledInvoices',(SELECT count(*) FROM public.backoffice_sales_invoices WHERE status='CANCELED'),
      'heldQuantityAllocations',(SELECT count(*) FROM public.backoffice_sales_invoice_quantity_allocations WHERE status='HELD'),
      'draftSchedules',(SELECT count(*) FROM public.backoffice_sales_invoice_receivable_schedules WHERE status='DRAFT')) details
)
SELECT * FROM (SELECT * FROM checks UNION ALL SELECT * FROM inventory) output
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;

