-- SELECT-only postflight for Backoffice Sales Return Step 3/5.
WITH checks AS (
  SELECT 'step3_migration_ledger' check_name,
    CASE WHEN count(*)=2 THEN 'PASS' ELSE 'BLOCKER' END status,
    2-count(*) violation_rows,jsonb_build_object('expected',2,'present',count(*)) details
  FROM private.kgs_schema_migrations
  WHERE version IN('20260917130000','20260917131000')
  UNION ALL
  SELECT 'step3_required_relations',CASE WHEN count(*)=5 THEN 'PASS' ELSE 'BLOCKER' END,
    5-count(*),jsonb_build_object('expected',5,'present',count(*),'missing',
      to_jsonb(ARRAY(SELECT required.name FROM (VALUES
        ('backoffice_sales_credit_notes'),('backoffice_sales_credit_note_lines'),
        ('backoffice_sales_return_invoice_allocations'),
        ('backoffice_sales_credit_note_operations'),('backoffice_sales_credit_note_audit')) required(name)
        WHERE to_regclass('public.'||required.name) IS NULL)))
  FROM (VALUES('backoffice_sales_credit_notes'),('backoffice_sales_credit_note_lines'),
    ('backoffice_sales_return_invoice_allocations'),
    ('backoffice_sales_credit_note_operations'),('backoffice_sales_credit_note_audit')) required(name)
  WHERE to_regclass('public.'||required.name) IS NOT NULL
  UNION ALL
  SELECT 'step3_required_routines',CASE WHEN count(*)=5 THEN 'PASS' ELSE 'BLOCKER' END,
    5-count(*),jsonb_build_object('expected',5,'present',count(*))
  FROM (VALUES
    ('public.allocate_backoffice_sales_return_invoices(uuid,bigint,uuid,jsonb)'),
    ('public.update_backoffice_sales_credit_note_draft(uuid,bigint,uuid,date,numeric,text)'),
    ('public.post_backoffice_sales_credit_note(uuid,bigint,uuid)'),
    ('public.get_backoffice_sales_credit_note(uuid)'),
    ('public.get_backoffice_sales_return_invoice_reconciliation(uuid)')) required(signature)
  WHERE to_regprocedure(required.signature) IS NOT NULL
  UNION ALL
  SELECT 'step3_quantity_ledger_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('invalidRows',count(*))
  FROM public.backoffice_sales_order_lines line
  WHERE line.returned_before_invoice_base_qty<0 OR line.returned_after_invoice_base_qty<0
    OR line.returned_before_invoice_base_qty+line.returned_after_invoice_base_qty>line.accepted_base_qty
    OR line.returned_after_invoice_base_qty>line.invoiced_base_qty
    OR line.draft_invoice_allocated_base_qty+line.invoiced_base_qty
      >line.accepted_base_qty-line.returned_before_invoice_base_qty
  UNION ALL
  SELECT 'step3_receipt_allocation_cap',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*),jsonb_build_object('overAllocatedReceiptLines',count(*))
  FROM (SELECT receipt_line.id
    FROM public.backoffice_sales_return_receipt_lines receipt_line
    LEFT JOIN public.backoffice_sales_return_invoice_allocations allocation
      ON allocation.company_id=receipt_line.company_id
      AND allocation.return_receipt_line_id=receipt_line.id
    GROUP BY receipt_line.id,receipt_line.received_base_qty
    HAVING COALESCE(sum(allocation.allocated_base_qty),0)>receipt_line.received_base_qty) invalid
  UNION ALL
  SELECT 'step3_credit_note_amount_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('invalidNotes',count(*))
  FROM public.backoffice_sales_credit_notes note
  WHERE note.charge_total<>COALESCE((SELECT round(sum(line.line_amount+line.discount_amount),4)
      FROM public.backoffice_sales_credit_note_lines line
      WHERE line.company_id=note.company_id AND line.credit_note_id=note.id),0)
    OR note.discount_total<>COALESCE((SELECT round(sum(line.discount_amount),4)
      FROM public.backoffice_sales_credit_note_lines line
      WHERE line.company_id=note.company_id AND line.credit_note_id=note.id),0)
    OR note.tax_total<>COALESCE((SELECT round(sum(line.tax_amount),4)
      FROM public.backoffice_sales_credit_note_lines line
      WHERE line.company_id=note.company_id AND line.credit_note_id=note.id),0)
  UNION ALL
  SELECT 'step3_posted_finance_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('invalidPostedNotes',count(*))
  FROM public.backoffice_sales_credit_notes note
  LEFT JOIN public.financial_events event ON event.company_id=note.company_id
    AND event.id=note.financial_event_id AND event.status='POSTED'
  LEFT JOIN public.finance_journals journal ON journal.company_id=note.company_id
    AND journal.financial_event_id=event.id AND journal.status='POSTED'
  WHERE note.status='POSTED' AND (event.id IS NULL OR journal.id IS NULL
    OR journal.total_debit<>note.grand_total OR journal.total_credit<>note.grand_total)
  UNION ALL
  SELECT 'step3_settlement_schedule_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('invalidPostedInvoices',count(*))
  FROM (SELECT invoice.company_id,invoice.id
    FROM public.backoffice_sales_invoices invoice
    LEFT JOIN public.backoffice_sales_invoice_receivable_schedules schedule
      ON schedule.company_id=invoice.company_id AND schedule.invoice_id=invoice.id
    WHERE invoice.status='POSTED'
    GROUP BY invoice.company_id,invoice.id,invoice.grand_total
    HAVING round(COALESCE(sum(schedule.amount_due),0),4)<>round(invoice.grand_total,4)
      OR round(COALESCE(sum(schedule.allocated_payment_amount),0),4)<>
        round(COALESCE((SELECT sum(allocation.allocated_amount)
          FROM public.customer_receipt_backoffice_invoice_allocations allocation
          JOIN public.customer_receipt_documents receipt
            ON receipt.company_id=allocation.company_id AND receipt.id=allocation.document_id
           AND receipt.status='POSTED'
          WHERE allocation.company_id=invoice.company_id
            AND allocation.invoice_id=invoice.id),0),4)
      OR round(COALESCE(sum(schedule.credited_amount),0),4)<>
        round(COALESCE((SELECT sum(note.ar_reduction_amount)
          FROM public.backoffice_sales_credit_notes note
          WHERE note.company_id=invoice.company_id AND note.source_invoice_id=invoice.id
            AND note.status='POSTED'),0),4)) invalid
  UNION ALL
  SELECT 'step3_allocation_audit_coverage',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('operationsWithoutAudit',count(*))
  FROM public.backoffice_sales_credit_note_operations operation
  WHERE operation.operation_type='ALLOCATE_RETURN'
    AND NOT EXISTS(SELECT 1 FROM public.backoffice_sales_credit_note_audit audit
      WHERE audit.company_id=operation.company_id
        AND audit.operation_id=operation.operation_id
        AND audit.action='ALLOCATE_RETURN')
  UNION ALL
  SELECT 'step3_credit_note_event_contract',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN count(*)=1 THEN 0 ELSE 1 END,
    jsonb_build_object('validEventRows',count(*),'requiredConditionalFunctions',
      ARRAY['SALES_RETURN_DISCOUNT','OUTPUT_TAX','CUSTOMER_REFUND_LIABILITY',
        'DELIVERY_FEE_REVENUE'])
  FROM public.system_events event
  WHERE event.system_key='CUSTOMER_CREDIT_NOTE'
    AND event.is_active
    AND event.required_account_functions@>ARRAY['CUSTOMER_RECEIVABLE']::text[]
    AND event.conditional_account_functions@>ARRAY['SALES_RETURN_DISCOUNT','OUTPUT_TAX',
      'CUSTOMER_REFUND_LIABILITY','DELIVERY_FEE_REVENUE']::text[]
  UNION ALL
  SELECT 'step3_private_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*),
    jsonb_build_object('authenticatedExecutableRows',count(*))
  FROM information_schema.routine_privileges privilege
  WHERE privilege.specific_schema='private' AND privilege.grantee='authenticated'
    AND privilege.routine_name IN('backoffice_sales_credit_note_snapshot',
      'backoffice_sales_credit_note_operation_retry',
      'recalculate_backoffice_sales_credit_note',
      'reconcile_backoffice_invoice_receivable_schedule',
      'backoffice_invoice_receivable_before_receipts')
  UNION ALL
  SELECT 'step3_credit_note_optimistic_version_contract',
    CASE WHEN position('master_version=master_version+1' IN
      pg_get_functiondef(to_regprocedure(
        'public.allocate_backoffice_sales_return_invoices(uuid,bigint,uuid,jsonb)')))>0
      THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN position('master_version=master_version+1' IN
      pg_get_functiondef(to_regprocedure(
        'public.allocate_backoffice_sales_return_invoices(uuid,bigint,uuid,jsonb)')))>0
      THEN 0 ELSE 1 END,
    jsonb_build_object('existingDraftCreditNoteVersionAdvances',
      position('master_version=master_version+1' IN
        pg_get_functiondef(to_regprocedure(
          'public.allocate_backoffice_sales_return_invoices(uuid,bigint,uuid,jsonb)')))>0)
  UNION ALL
  SELECT 'step3_ar_reader_contract',
    CASE WHEN position('backoffice_sales_credit_notes' IN
      pg_get_functiondef(to_regprocedure('public.get_finance_ar_aging(date,uuid,uuid)')))>0
      AND position('creditNoteAmount' IN
      pg_get_functiondef(to_regprocedure('public.get_backoffice_sales_invoice_payment_context(uuid)')))>0
      AND position('backoffice_sales_credit_notes' IN
      pg_get_functiondef(to_regprocedure('public.get_finance_customer_statement(uuid,date,date,uuid)')))>0
      THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN position('backoffice_sales_credit_notes' IN
      pg_get_functiondef(to_regprocedure('public.get_finance_ar_aging(date,uuid,uuid)')))>0
      AND position('creditNoteAmount' IN
      pg_get_functiondef(to_regprocedure('public.get_backoffice_sales_invoice_payment_context(uuid)')))>0
      AND position('backoffice_sales_credit_notes' IN
      pg_get_functiondef(to_regprocedure('public.get_finance_customer_statement(uuid,date,date,uuid)')))>0
      THEN 0 ELSE 1 END,
    jsonb_build_object('agingCreditAware',position('backoffice_sales_credit_notes' IN
      pg_get_functiondef(to_regprocedure('public.get_finance_ar_aging(date,uuid,uuid)')))>0,
      'invoicePaymentContextCreditAware',position('creditNoteAmount' IN
      pg_get_functiondef(to_regprocedure('public.get_backoffice_sales_invoice_payment_context(uuid)')))>0,
      'customerStatementCreditAware',position('backoffice_sales_credit_notes' IN
      pg_get_functiondef(to_regprocedure('public.get_finance_customer_statement(uuid,date,date,uuid)')))>0)
  UNION ALL
  SELECT 'step3_runtime_inventory','INFO',0,jsonb_build_object(
    'allocations',(SELECT count(*) FROM public.backoffice_sales_return_invoice_allocations),
    'draftNotes',(SELECT count(*) FROM public.backoffice_sales_credit_notes WHERE status='DRAFT'),
    'postedNotes',(SELECT count(*) FROM public.backoffice_sales_credit_notes WHERE status='POSTED'),
    'refundPending',(SELECT count(*) FROM public.backoffice_sales_returns WHERE status='REFUND_PENDING'))
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 0 WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
