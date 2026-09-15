-- SELECT-only verification for 20260911160000.
WITH checks AS (
  SELECT 'migration_ledger'::text check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(count(*)-1)::bigint violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260911160000'

  UNION ALL
  SELECT 'payment_collection_relation_contract',
    CASE WHEN to_regclass('public.customer_receipt_backoffice_invoice_allocations') IS NOT NULL
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN to_regclass('public.customer_receipt_backoffice_invoice_allocations') IS NULL THEN 1 ELSE 0 END,
    jsonb_build_object('relationExists',
      to_regclass('public.customer_receipt_backoffice_invoice_allocations') IS NOT NULL)

  UNION ALL
  SELECT 'payment_collection_routine_contract',
    CASE WHEN count(proc.oid)=6 THEN 'PASS' ELSE 'FAIL' END,
    (6-count(proc.oid))::bigint,
    jsonb_build_object('expected',6,'present',count(proc.oid))
  FROM (VALUES
    ('private.backoffice_invoice_receivable_before_receipts(uuid,uuid,date)'::text),
    ('private.reconcile_backoffice_invoice_receivable_schedule(uuid,uuid)'::text),
    ('private.post_customer_receipt_financial_event_core(uuid,uuid,bigint,uuid)'::text),
    ('public.save_customer_receipt_allocated_draft(uuid,bigint,uuid,date,uuid,text,text,text,numeric,jsonb)'::text),
    ('public.post_customer_receipt_allocated(uuid,bigint,uuid)'::text),
    ('public.post_customer_receipt(uuid,bigint,uuid)'::text)
  ) required(signature)
  LEFT JOIN pg_proc proc ON proc.oid=to_regprocedure(required.signature)

  UNION ALL
  SELECT 'payment_collection_source_typed_fk_contract',
    CASE WHEN count(*)=2 THEN 'PASS' ELSE 'FAIL' END,(2-count(*))::bigint,
    jsonb_build_object('expected',2,'foreignKeys',count(*))
  FROM pg_constraint constraint_row
  WHERE constraint_row.conrelid='public.customer_receipt_backoffice_invoice_allocations'::regclass
    AND constraint_row.contype='f'
    AND constraint_row.conname IN('customer_receipt_bo_alloc_document_fk',
      'customer_receipt_bo_alloc_invoice_fk')

  UNION ALL
  SELECT 'payment_collection_rls_boundary',
    CASE WHEN cls.relrowsecurity AND COALESCE(priv.authenticated_privileges,0)=0
      THEN 'PASS' ELSE 'FAIL' END,
    (CASE WHEN cls.relrowsecurity THEN 0 ELSE 1 END
      +COALESCE(priv.authenticated_privileges,0))::bigint,
    jsonb_build_object('rlsEnabled',cls.relrowsecurity,
      'authenticatedPrivileges',COALESCE(priv.authenticated_privileges,0))
  FROM pg_class cls
  JOIN pg_namespace ns ON ns.oid=cls.relnamespace AND ns.nspname='public'
  LEFT JOIN LATERAL(
    SELECT count(*) authenticated_privileges
    FROM information_schema.role_table_grants grant_row
    WHERE grant_row.table_schema='public'
      AND grant_row.table_name='customer_receipt_backoffice_invoice_allocations'
      AND grant_row.grantee IN('anon','authenticated')
  ) priv ON true
  WHERE cls.relname='customer_receipt_backoffice_invoice_allocations'

  UNION ALL
  SELECT 'payment_collection_public_rpc_boundary',
    CASE WHEN anon_count=0 AND authenticated_count=2 THEN 'PASS' ELSE 'FAIL' END,
    (anon_count+abs(authenticated_count-2))::bigint,
    jsonb_build_object('anonExecute',anon_count,
      'authenticatedExecute',authenticated_count)
  FROM (
    SELECT count(*) FILTER(WHERE role_name='anon' AND has_access) anon_count,
      count(*) FILTER(WHERE role_name='authenticated' AND has_access) authenticated_count
    FROM (VALUES
      ('anon'::text,'public.save_customer_receipt_allocated_draft(uuid,bigint,uuid,date,uuid,text,text,text,numeric,jsonb)'::text),
      ('anon','public.post_customer_receipt_allocated(uuid,bigint,uuid)'),
      ('authenticated','public.save_customer_receipt_allocated_draft(uuid,bigint,uuid,date,uuid,text,text,text,numeric,jsonb)'),
      ('authenticated','public.post_customer_receipt_allocated(uuid,bigint,uuid)')
    ) expected(role_name,signature)
    CROSS JOIN LATERAL(SELECT has_function_privilege(expected.role_name,
      expected.signature,'EXECUTE') has_access) access
  ) boundary

  UNION ALL
  SELECT 'payment_collection_private_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('authenticatedExecutableRows',count(*))
  FROM (VALUES
    ('private.backoffice_invoice_receivable_before_receipts(uuid,uuid,date)'::text),
    ('private.reconcile_backoffice_invoice_receivable_schedule(uuid,uuid)'::text),
    ('private.post_customer_receipt_financial_event_core(uuid,uuid,bigint,uuid)'::text)
  ) routine(signature)
  WHERE has_function_privilege('authenticated',routine.signature,'EXECUTE')

  UNION ALL
  SELECT 'payment_collection_finance_source_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('mismatchReceipts',count(*))
  FROM (
    SELECT receipt.company_id,receipt.id
    FROM public.customer_receipt_documents receipt
    WHERE receipt.unapplied_disposition='NONE'
      AND round(receipt.total_amount,4)<>round(
        COALESCE((SELECT sum(retail.allocated_amount)
          FROM public.customer_receipt_allocations retail
          WHERE retail.company_id=receipt.company_id AND retail.document_id=receipt.id),0)
        +COALESCE((SELECT sum(backoffice.allocated_amount)
          FROM public.customer_receipt_backoffice_invoice_allocations backoffice
          WHERE backoffice.company_id=receipt.company_id AND backoffice.document_id=receipt.id),0),4)
  ) mismatch

  UNION ALL
  SELECT 'payment_collection_schedule_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('invalidInvoices',count(*))
  FROM (
    SELECT invoice.company_id,invoice.id,invoice.grand_total,
      COALESCE((SELECT sum(allocation.allocated_amount)
        FROM public.customer_receipt_backoffice_invoice_allocations allocation
        JOIN public.customer_receipt_documents receipt
          ON receipt.company_id=allocation.company_id AND receipt.id=allocation.document_id
         AND receipt.status='POSTED'
        WHERE allocation.company_id=invoice.company_id AND allocation.invoice_id=invoice.id),0) paid,
      COALESCE(sum(schedule.allocated_payment_amount),0) scheduled_paid,
      COALESCE(sum(schedule.amount_due),0) scheduled_due
    FROM public.backoffice_sales_invoices invoice
    LEFT JOIN public.backoffice_sales_invoice_receivable_schedules schedule
      ON schedule.company_id=invoice.company_id AND schedule.invoice_id=invoice.id
    WHERE invoice.status='POSTED'
    GROUP BY invoice.company_id,invoice.id,invoice.grand_total
  ) state
  WHERE round(state.paid,4)<>round(state.scheduled_paid,4)
    OR (state.grand_total>0 AND round(state.scheduled_due,4)<>round(state.grand_total,4))

  UNION ALL
  SELECT 'payment_collection_runtime_inventory','INFO',0,
    jsonb_build_object(
      'allocationRows',(SELECT count(*) FROM public.customer_receipt_backoffice_invoice_allocations),
      'postedPaymentRows',(SELECT count(*)
        FROM public.customer_receipt_backoffice_invoice_allocations allocation
        JOIN public.customer_receipt_documents receipt
          ON receipt.company_id=allocation.company_id AND receipt.id=allocation.document_id
         AND receipt.status='POSTED'),
      'partiallyPaidInvoices',(SELECT count(DISTINCT invoice_id)
        FROM public.backoffice_sales_invoice_receivable_schedules WHERE status='PARTIALLY_PAID'),
      'fullyPaidInvoices',(SELECT count(*) FROM (
        SELECT invoice_id FROM public.backoffice_sales_invoice_receivable_schedules
        GROUP BY company_id,invoice_id HAVING bool_and(status='PAID')) paid))
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'BLOCKER' THEN 2 WHEN 'PASS' THEN 3 ELSE 4 END,
  check_name;
