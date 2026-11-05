-- SELECT-only Task 1 production inventory for KMS, LSM and SMS.
-- No active-company context, temp object, DDL, DML or function mutation.
-- Output is evidence for design/state classification; REVIEW is not a failure.

WITH
target_codes(company_code) AS (
  VALUES ('KMS'::text),('LSM'::text),('SMS'::text)
),
scope AS (
  SELECT company.id AS company_id,company.company_code,company.company_name,
    company.status
  FROM public.companies company
  JOIN target_codes target ON target.company_code=company.company_code
),
required_versions(version) AS (
  VALUES
    ('20260720090000'::text),
    ('20260722150000'::text),
    ('20260810180000'::text),
    ('20260827100000'::text),
    ('20260827120000'::text),
    ('20260909156000'::text),
    ('20260911160000'::text),
    ('20260911163000'::text),
    ('20260917110000'::text),
    ('20260917120000'::text),
    ('20260917130000'::text),
    ('20260917131000'::text),
    ('20260917150000'::text),
    ('20260918120000'::text),
    ('20260918150000'::text),
    ('20260928110000'::text),
    ('20261006140000'::text)
),
required_relations(object_name) AS (
  VALUES
    ('public.backoffice_sales_returns'::text),
    ('public.backoffice_sales_return_receipts'::text),
    ('public.backoffice_sales_return_receipt_lines'::text),
    ('public.backoffice_sales_invoices'::text),
    ('public.backoffice_sales_credit_notes'::text),
    ('public.backoffice_sales_credit_note_lines'::text),
    ('public.backoffice_sales_customer_refunds'::text),
    ('public.customer_receipt_documents'::text),
    ('public.customer_receipt_backoffice_invoice_allocations'::text),
    ('public.financial_events'::text),
    ('public.finance_journals'::text),
    ('public.finance_journal_lines'::text),
    ('public.transaction_account_rules'::text),
    ('public.company_account_function_fallbacks'::text)
),
required_routines(object_name) AS (
  VALUES
    ('public.post_backoffice_sales_credit_note(uuid,bigint,uuid)'::text),
    ('public.post_backoffice_sales_customer_refund(uuid,bigint,uuid,date,numeric,uuid,text,text,text)'::text),
    ('public.post_customer_receipt_unified(uuid,bigint,uuid)'::text),
    ('public.get_backoffice_sales_invoice_payment_context(uuid)'::text)
),
runtime_definitions AS (
  SELECT routine.object_name,
    to_regprocedure(routine.object_name) AS routine_oid,
    CASE WHEN to_regprocedure(routine.object_name) IS NULL THEN NULL
      ELSE md5(pg_get_functiondef(to_regprocedure(routine.object_name))) END AS definition_md5
  FROM required_routines routine
),
return_inventory AS (
  SELECT scope.company_code,document.source_kind,document.status,count(*) AS rows,
    round(COALESCE(sum(document.total_requested_base_qty),0),6) AS requested_base_qty
  FROM scope
  JOIN public.backoffice_sales_returns document
    ON document.company_id=scope.company_id
  GROUP BY scope.company_code,document.source_kind,document.status
),
received_without_credit AS (
  SELECT scope.company_code,document.id AS return_id,document.return_no,
    document.status,document.customer_id,
    count(DISTINCT receipt.id) AS receipt_rows,
    round(COALESCE(sum(receipt.total_received_base_qty),0),6) AS received_base_qty,
    round(COALESCE(sum(receipt.total_fifo_cost),0),4) AS fifo_cost
  FROM scope
  JOIN public.backoffice_sales_returns document
    ON document.company_id=scope.company_id AND document.source_kind='BACKOFFICE'
  JOIN public.backoffice_sales_return_receipts receipt
    ON receipt.company_id=document.company_id AND receipt.return_id=document.id
  LEFT JOIN public.backoffice_sales_credit_notes note
    ON note.company_id=document.company_id AND note.return_id=document.id
   AND note.source_kind='BACKOFFICE' AND note.status IN('DRAFT','POSTED','REVERSED')
  WHERE note.id IS NULL
  GROUP BY scope.company_code,document.id,document.return_no,document.status,
    document.customer_id
),
credit_inventory AS (
  SELECT scope.company_code,note.source_kind,note.status,count(*) AS rows,
    round(COALESCE(sum(note.grand_total),0),4) AS grand_total,
    round(COALESCE(sum(note.ar_reduction_amount),0),4) AS ar_reduction,
    round(COALESCE(sum(note.refund_liability_amount),0),4) AS refund_liability
  FROM scope
  JOIN public.backoffice_sales_credit_notes note
    ON note.company_id=scope.company_id
  GROUP BY scope.company_code,note.source_kind,note.status
),
refund_totals AS (
  SELECT refund.company_id,refund.credit_note_id,
    round(COALESCE(sum(CASE refund.document_kind
      WHEN 'REFUND' THEN refund.amount
      WHEN 'REVERSAL' THEN -refund.amount ELSE 0 END),0),4) AS net_refunded,
    count(*) FILTER(WHERE refund.document_kind='REFUND') AS refund_rows,
    count(*) FILTER(WHERE refund.document_kind='REVERSAL') AS reversal_rows
  FROM public.backoffice_sales_customer_refunds refund
  JOIN scope ON scope.company_id=refund.company_id
  GROUP BY refund.company_id,refund.credit_note_id
),
legacy_liability AS (
  SELECT scope.company_code,note.id AS credit_note_id,note.credit_note_no,
    note.return_id,note.source_invoice_id,note.customer_id,note.credit_note_date,
    note.refund_liability_amount,
    COALESCE(refund_totals.net_refunded,0) AS net_refunded,
    round(note.refund_liability_amount-COALESCE(refund_totals.net_refunded,0),4)
      AS remaining_liability,
    COALESCE(refund_totals.refund_rows,0) AS refund_rows,
    COALESCE(refund_totals.reversal_rows,0) AS reversal_rows
  FROM scope
  JOIN public.backoffice_sales_credit_notes note
    ON note.company_id=scope.company_id AND note.source_kind='BACKOFFICE'
   AND note.status='POSTED' AND note.refund_liability_amount>0
  LEFT JOIN refund_totals ON refund_totals.company_id=note.company_id
    AND refund_totals.credit_note_id=note.id
),
invoice_context AS (
  SELECT scope.company_code,invoice.id AS invoice_id,invoice.invoice_no,
    invoice.status,invoice.customer_id,invoice.grand_total,
    round(COALESCE((SELECT sum(allocation.allocated_amount)
      FROM public.customer_receipt_backoffice_invoice_allocations allocation
      JOIN public.customer_receipt_documents receipt
        ON receipt.company_id=allocation.company_id
       AND receipt.id=allocation.document_id AND receipt.status='POSTED'
      WHERE allocation.company_id=invoice.company_id
        AND allocation.invoice_id=invoice.id),0),4) AS posted_receipts,
    round(COALESCE((SELECT sum(note.ar_reduction_amount)
      FROM public.backoffice_sales_credit_notes note
      WHERE note.company_id=invoice.company_id
        AND note.source_kind='BACKOFFICE'
        AND note.source_invoice_id=invoice.id AND note.status='POSTED'),0),4)
      AS posted_credit_ar_reduction
  FROM scope
  JOIN public.backoffice_sales_invoices invoice
    ON invoice.company_id=scope.company_id
  WHERE EXISTS(SELECT 1 FROM public.backoffice_sales_credit_notes note
      WHERE note.company_id=invoice.company_id AND note.source_invoice_id=invoice.id)
     OR EXISTS(SELECT 1 FROM public.customer_receipt_backoffice_invoice_allocations allocation
      WHERE allocation.company_id=invoice.company_id AND allocation.invoice_id=invoice.id)
),
journal_gaps AS (
  SELECT scope.company_code,'CREDIT_NOTE'::text AS source_type,note.id AS source_id,
    note.credit_note_no AS document_no
  FROM scope
  JOIN public.backoffice_sales_credit_notes note
    ON note.company_id=scope.company_id AND note.status IN('POSTED','REVERSED')
  LEFT JOIN public.finance_journals journal
    ON journal.company_id=note.company_id
   AND journal.source_type='backoffice_sales_credit_notes'
   AND journal.source_id=note.id AND journal.status='POSTED'
  WHERE journal.id IS NULL
  UNION ALL
  SELECT scope.company_code,'CUSTOMER_REFUND',refund.id,refund.refund_no
  FROM scope
  JOIN public.backoffice_sales_customer_refunds refund
    ON refund.company_id=scope.company_id
  LEFT JOIN public.finance_journals journal
    ON journal.company_id=refund.company_id
   AND journal.source_type='backoffice_sales_customer_refunds'
   AND journal.source_id=refund.id AND journal.status='POSTED'
  WHERE journal.id IS NULL
),
mapping_inventory AS (
  SELECT scope.company_code,'DIRECT'::text AS mapping_source,
    rule.account_function_key,account.account_code,account.account_name,
    rule.status,rule.effective_from,rule.effective_to
  FROM scope
  JOIN public.transaction_account_rules rule ON rule.company_id=scope.company_id
  JOIN public.chart_of_accounts account
    ON account.company_id=rule.company_id AND account.id=rule.account_id
  WHERE rule.account_function_key IN(
    'CUSTOMER_RECEIVABLE','CUSTOMER_REFUND_LIABILITY','SALES_RETURN_DISCOUNT')
  UNION ALL
  SELECT scope.company_code,'FALLBACK',fallback.account_function_key,
    account.account_code,account.account_name,fallback.status,
    fallback.effective_from,fallback.effective_to
  FROM scope
  JOIN public.company_account_function_fallbacks fallback
    ON fallback.company_id=scope.company_id
  JOIN public.chart_of_accounts account
    ON account.company_id=fallback.company_id AND account.id=fallback.account_id
  WHERE fallback.account_function_key IN(
    'CUSTOMER_RECEIVABLE','CUSTOMER_REFUND_LIABILITY','SALES_RETURN_DISCOUNT')
),
finance_queue AS (
  SELECT scope.company_code,event.source_table,event.status,count(*) AS rows
  FROM scope
  JOIN public.financial_events event ON event.company_id=scope.company_id
  WHERE event.source_table IN(
    'backoffice_sales_credit_notes','backoffice_sales_customer_refunds',
    'customer_receipt_documents')
    AND event.status::text<>'POSTED'
  GROUP BY scope.company_code,event.source_table,event.status
),
catalog_candidates AS (
  SELECT namespace.nspname AS schema_name,class.relname AS object_name,
    class.relkind::text AS object_kind
  FROM pg_class class
  JOIN pg_namespace namespace ON namespace.oid=class.relnamespace
  WHERE namespace.nspname IN('public','private')
    AND (class.relname ILIKE '%open_item%'
      OR class.relname ILIKE '%receivable_reconcil%'
      OR class.relname ILIKE '%ar_reconcil%')
)
SELECT 'backoffice_ar_open_item_company_identity' AS check_name,
  CASE WHEN (SELECT count(*) FROM scope)=3
      AND (SELECT count(*) FROM scope WHERE status='ACTIVE')=3
    THEN 'PASS' ELSE 'FAIL' END AS status,
  (3-(SELECT count(*) FROM scope WHERE status='ACTIVE'))::bigint AS violation_rows,
  jsonb_build_object('companies',COALESCE((SELECT jsonb_agg(jsonb_build_object(
    'id',scope.company_id,'code',scope.company_code,'name',scope.company_name,
    'status',scope.status) ORDER BY scope.company_code) FROM scope),'[]'::jsonb)) AS details
UNION ALL
SELECT 'backoffice_ar_open_item_dependency_ledger',
  CASE WHEN NOT EXISTS(SELECT 1 FROM required_versions required
      WHERE NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations ledger
        WHERE ledger.version=required.version)) THEN 'PASS' ELSE 'FAIL' END,
  (SELECT count(*) FROM required_versions required WHERE NOT EXISTS(
    SELECT 1 FROM private.kgs_schema_migrations ledger
    WHERE ledger.version=required.version)),
  jsonb_build_object('required',(SELECT jsonb_agg(version ORDER BY version)
    FROM required_versions),'missing',COALESCE((SELECT jsonb_agg(version ORDER BY version)
    FROM required_versions required WHERE NOT EXISTS(SELECT 1
      FROM private.kgs_schema_migrations ledger
      WHERE ledger.version=required.version)),'[]'::jsonb))
UNION ALL
SELECT 'backoffice_ar_open_item_runtime_objects',
  CASE WHEN NOT EXISTS(SELECT 1 FROM required_relations relation
      WHERE to_regclass(relation.object_name) IS NULL)
    AND NOT EXISTS(SELECT 1 FROM runtime_definitions WHERE routine_oid IS NULL)
    THEN 'PASS' ELSE 'FAIL' END,
  ((SELECT count(*) FROM required_relations relation
      WHERE to_regclass(relation.object_name) IS NULL)
   +(SELECT count(*) FROM runtime_definitions WHERE routine_oid IS NULL))::bigint,
  jsonb_build_object('missingRelations',COALESCE((SELECT jsonb_agg(object_name)
      FROM required_relations relation WHERE to_regclass(relation.object_name) IS NULL),'[]'::jsonb),
    'routines',(SELECT jsonb_agg(jsonb_build_object('signature',object_name,
      'present',routine_oid IS NOT NULL,'definitionMd5',definition_md5)
      ORDER BY object_name) FROM runtime_definitions))
UNION ALL
SELECT 'backoffice_ar_open_item_existing_foundation_inventory','INFO',0,
  jsonb_build_object('candidateObjects',COALESCE((SELECT jsonb_agg(
    jsonb_build_object('schema',schema_name,'name',object_name,'kind',object_kind)
    ORDER BY schema_name,object_name) FROM catalog_candidates),'[]'::jsonb),
    'interpretation','Catalog inventory only; final Task 2 identifiers are not yet selected')
UNION ALL
SELECT 'backoffice_ar_open_item_return_inventory','INFO',0,
  jsonb_build_object('rows',COALESCE((SELECT jsonb_agg(jsonb_build_object(
    'company',company_code,'sourceKind',source_kind,'status',status,'rows',rows,
    'requestedBaseQty',requested_base_qty) ORDER BY company_code,source_kind,status)
    FROM return_inventory),'[]'::jsonb))
UNION ALL
SELECT 'backoffice_ar_open_item_received_without_credit','REVIEW',
  (SELECT count(*) FROM received_without_credit),
  jsonb_build_object('rows',COALESCE((SELECT jsonb_agg(jsonb_build_object(
    'company',company_code,'returnId',return_id,'returnNo',return_no,
    'status',status,'customerId',customer_id,'receiptRows',receipt_rows,
    'receivedBaseQty',received_base_qty,'fifoCost',fifo_cost)
    ORDER BY company_code,return_no) FROM received_without_credit),'[]'::jsonb),
    'meaning','Physical Backoffice Return receipt exists but no Draft/Posted/Reversed Credit Note exists')
UNION ALL
SELECT 'backoffice_ar_open_item_credit_note_inventory','INFO',0,
  jsonb_build_object('rows',COALESCE((SELECT jsonb_agg(jsonb_build_object(
    'company',company_code,'sourceKind',source_kind,'status',status,'rows',rows,
    'grandTotal',grand_total,'arReduction',ar_reduction,
    'refundLiability',refund_liability) ORDER BY company_code,source_kind,status)
    FROM credit_inventory),'[]'::jsonb))
UNION ALL
SELECT 'backoffice_ar_open_item_legacy_liability_inventory','REVIEW',
  (SELECT count(*) FROM legacy_liability WHERE remaining_liability>0),
  jsonb_build_object('remainingRows',COALESCE((SELECT jsonb_agg(jsonb_build_object(
    'company',company_code,'creditNoteId',credit_note_id,'creditNoteNo',credit_note_no,
    'returnId',return_id,'sourceInvoiceId',source_invoice_id,'customerId',customer_id,
    'creditNoteDate',credit_note_date,'liability',refund_liability_amount,
    'netRefunded',net_refunded,'remaining',remaining_liability,
    'refundRows',refund_rows,'reversalRows',reversal_rows)
    ORDER BY company_code,credit_note_no) FROM legacy_liability
    WHERE remaining_liability>0),'[]'::jsonb),
    'invalidNegativeRows',(SELECT count(*) FROM legacy_liability WHERE remaining_liability<0),
    'fullySettledRows',(SELECT count(*) FROM legacy_liability WHERE remaining_liability=0))
UNION ALL
SELECT 'backoffice_ar_open_item_invoice_receipt_credit_inventory','INFO',0,
  jsonb_build_object('rows',COALESCE((SELECT jsonb_agg(jsonb_build_object(
    'company',company_code,'invoiceId',invoice_id,'invoiceNo',invoice_no,
    'status',status,'customerId',customer_id,'grandTotal',grand_total,
    'postedReceipts',posted_receipts,'postedCreditArReduction',posted_credit_ar_reduction)
    ORDER BY company_code,invoice_no) FROM invoice_context),'[]'::jsonb))
UNION ALL
SELECT 'backoffice_ar_open_item_posted_journal_lineage',
  CASE WHEN NOT EXISTS(SELECT 1 FROM journal_gaps) THEN 'PASS' ELSE 'FAIL' END,
  (SELECT count(*) FROM journal_gaps),
  jsonb_build_object('missing',COALESCE((SELECT jsonb_agg(jsonb_build_object(
    'company',company_code,'sourceType',source_type,'sourceId',source_id,
    'documentNo',document_no) ORDER BY company_code,source_type,document_no)
    FROM journal_gaps),'[]'::jsonb))
UNION ALL
SELECT 'backoffice_ar_open_item_mapping_inventory','INFO',0,
  jsonb_build_object('rows',COALESCE((SELECT jsonb_agg(jsonb_build_object(
    'company',company_code,'source',mapping_source,'function',account_function_key,
    'accountCode',account_code,'accountName',account_name,'status',status,
    'effectiveFrom',effective_from,'effectiveTo',effective_to)
    ORDER BY company_code,account_function_key,mapping_source,effective_from)
    FROM mapping_inventory),'[]'::jsonb))
UNION ALL
SELECT 'backoffice_ar_open_item_customer_balance_boundary','INFO',0,
  jsonb_build_object('customers',COALESCE((SELECT jsonb_agg(jsonb_build_object(
    'company',scope.company_code,'customerId',customer.id,'customerCode',customer.code,
    'customerName',customer.name,'currentBalance',customer.current_balance)
    ORDER BY scope.company_code,customer.code)
    FROM scope JOIN public.customers customer ON customer.company_id=scope.company_id
    WHERE EXISTS(SELECT 1 FROM public.backoffice_sales_credit_notes note
      WHERE note.company_id=customer.company_id AND note.customer_id=customer.id)
      AND customer.current_balance<>0),'[]'::jsonb),
    'meaning','Inventory only; Credit Note must not be inferred as Customer Balance')
UNION ALL
SELECT 'backoffice_ar_open_item_accounting_period_inventory','INFO',0,
  jsonb_build_object('rows',COALESCE((SELECT jsonb_agg(jsonb_build_object(
    'company',scope.company_code,'status',period.status,'start',period.start_date,
    'end',period.end_date) ORDER BY scope.company_code,period.start_date)
    FROM scope JOIN public.accounting_periods period ON period.company_id=scope.company_id
    WHERE period.status IN('OPEN','REOPENED')),'[]'::jsonb))
UNION ALL
SELECT 'backoffice_ar_open_item_finance_queue',
  CASE WHEN NOT EXISTS(SELECT 1 FROM finance_queue) THEN 'PASS' ELSE 'REVIEW' END,
  (SELECT COALESCE(sum(rows),0)::bigint FROM finance_queue),
  jsonb_build_object('rows',COALESCE((SELECT jsonb_agg(jsonb_build_object(
    'company',company_code,'sourceTable',source_table,'status',status,'rows',rows)
    ORDER BY company_code,source_table,status) FROM finance_queue),'[]'::jsonb))
UNION ALL
SELECT 'backoffice_ar_open_item_business_boundary','INFO',0,
  jsonb_build_object('scope',jsonb_build_array('KMS','LSM','SMS'),
    'mutation','NONE','included',jsonb_build_array(
      'Backoffice Return receipt','Backoffice Invoice','Backoffice Credit Note',
      'Backoffice Customer Receipt allocation','Backoffice Customer Refund',
      'Finance Event/Journal lineage','legacy unpaid Refund Liability'),
    'preserved',jsonb_build_array('POS Retail','Cashier Session','Sales dispatch',
      'Stock/FIFO mutation','posted Journal immutability','other Companies'),
    'next','Classify production state and resolve only evidence-backed holes before Task 2');

