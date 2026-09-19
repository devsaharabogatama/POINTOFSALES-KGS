-- SELECT-only preflight for 20260919110000.
WITH definitions AS (
  SELECT pg_get_functiondef(to_regprocedure('public.get_finance_customer_receipts()')) workspace,
    pg_get_functiondef(to_regprocedure(
      'public.save_customer_receipt_allocated_draft(uuid,bigint,uuid,date,uuid,text,text,text,numeric,jsonb)')) save_draft,
    pg_get_functiondef(to_regprocedure(
      'public.post_customer_receipt_allocated(uuid,bigint,uuid)')) post_receipt
),credited_sources AS (
  SELECT note.company_id,note.source_kind,
    CASE WHEN note.source_kind='BACKOFFICE' THEN note.source_invoice_id
      ELSE note.source_retail_sales_id END source_id,
    sum(note.ar_reduction_amount) credited_amount
  FROM public.backoffice_sales_credit_notes note
  WHERE note.status='POSTED'
  GROUP BY note.company_id,note.source_kind,
    CASE WHEN note.source_kind='BACKOFFICE' THEN note.source_invoice_id
      ELSE note.source_retail_sales_id END
)
SELECT * FROM (
  SELECT 'customer_receipt_credit_dependency_ledger' check_name,
    CASE WHEN count(*)=3 THEN 'PASS' ELSE 'BLOCKER' END status,
    abs(count(*)-3)::bigint violation_rows,
    jsonb_build_object('installed',array_agg(version ORDER BY version),'expected',3) details
  FROM private.kgs_schema_migrations
  WHERE version IN('20260917131000','20260918150000','20260919100000')
  UNION ALL
  SELECT 'customer_receipt_credit_active_finance_queue',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('runRows',count(*))
  FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'customer_receipt_credit_nonterminal_offline',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('submissionRows',count(*))
  FROM public.pos_offline_sale_submissions
  WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
  UNION ALL
  SELECT 'customer_receipt_credit_runtime_anchor',
    CASE WHEN position('''remainingAmount'',row_data.original_receivable-row_data.allocated_amount' IN workspace)>0
      AND position('v_invoice.grand_total-v_paid' IN save_draft)>0
      AND position('private.odr6d_dispatched_receivable_before_receipts(' IN save_draft)>0
      AND position('customer_receipt_retail_receivable_before_receipts' IN post_receipt)=0
      THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN position('''remainingAmount'',row_data.original_receivable-row_data.allocated_amount' IN workspace)>0
      AND position('v_invoice.grand_total-v_paid' IN save_draft)>0
      AND position('private.odr6d_dispatched_receivable_before_receipts(' IN save_draft)>0
      AND position('customer_receipt_retail_receivable_before_receipts' IN post_receipt)=0
      THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('workspaceStillGross',position(
      '''remainingAmount'',row_data.original_receivable-row_data.allocated_amount' IN workspace)>0,
      'saveStillGross',position('v_invoice.grand_total-v_paid' IN save_draft)>0)
  FROM definitions
  UNION ALL
  SELECT 'customer_receipt_credit_draft_review','INFO',count(*)::bigint,
    jsonb_build_object('draftAllocationsOnCreditedSources',count(*),
      'action','Existing Draft remains editable; Post will recheck net outstanding')
  FROM (
    SELECT allocation.document_id FROM public.customer_receipt_backoffice_invoice_allocations allocation
    JOIN public.customer_receipt_documents receipt ON receipt.company_id=allocation.company_id
      AND receipt.id=allocation.document_id AND receipt.status='DRAFT'
    JOIN credited_sources credit ON credit.company_id=allocation.company_id
      AND credit.source_kind='BACKOFFICE' AND credit.source_id=allocation.invoice_id
    UNION ALL
    SELECT allocation.document_id FROM public.customer_receipt_allocations allocation
    JOIN public.customer_receipt_documents receipt ON receipt.company_id=allocation.company_id
      AND receipt.id=allocation.document_id AND receipt.status='DRAFT'
    JOIN credited_sources credit ON credit.company_id=allocation.company_id
      AND credit.source_kind='RETAINED_RETAIL' AND credit.source_id=allocation.sales_id
  ) draft
  UNION ALL
  SELECT 'customer_receipt_credit_runtime_inventory','INFO',count(*)::bigint,
    jsonb_build_object('creditedSources',count(*),'arReductionTotal',COALESCE(sum(credited_amount),0),
      'backofficeSources',count(*) FILTER(WHERE source_kind='BACKOFFICE'),
      'retainedRetailSources',count(*) FILTER(WHERE source_kind='RETAINED_RETAIL'))
  FROM credited_sources
) result ORDER BY status,check_name;
