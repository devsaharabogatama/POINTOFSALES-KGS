-- SELECT-only root-cause diagnosis for Task 2 AR open-item lineage.
-- This does not replace or weaken the FAIL assertions in
-- backoffice_ar_open_item_journal_line_inventory.sql. It determines whether
-- documents rejected by direct source_type/source_id matching are linked by
-- financial_event_id, genuinely lack a posted journal, or use another lineage.
-- No active-company context, temp object, DDL, DML, or side-effecting function
-- is present.

WITH
target_codes(company_code) AS (
  VALUES ('KMS'::text),('LSM'::text),('SMS'::text)
),
scope AS (
  SELECT company.id AS company_id,company.company_code
  FROM public.companies company
  JOIN target_codes target ON target.company_code=company.company_code
),
posted_ar_lines AS (
  SELECT journal.company_id,journal.id AS journal_id,journal.financial_event_id,
    journal.source_type,journal.source_id,journal.accounting_date,
    line.id AS line_id,line.account_id,line.customer_id,line.debit,line.credit
  FROM scope
  JOIN public.finance_journals journal
    ON journal.company_id=scope.company_id AND journal.status='POSTED'
  JOIN public.finance_journal_lines line
    ON line.company_id=journal.company_id AND line.journal_id=journal.id
  WHERE line.account_function_key_snapshot='CUSTOMER_RECEIVABLE'
),
posted_event_journals AS (
  SELECT journal.company_id,journal.financial_event_id,count(*) AS journal_rows,
    min(journal.source_type) AS source_type,
    min(journal.source_id::text)::uuid AS source_id
  FROM scope
  JOIN public.finance_journals journal
    ON journal.company_id=scope.company_id AND journal.status='POSTED'
   AND journal.financial_event_id IS NOT NULL
  GROUP BY journal.company_id,journal.financial_event_id
),
event_ar AS (
  SELECT line.company_id,line.financial_event_id,count(*) AS line_rows,
    round(sum(line.debit),4) AS debit,round(sum(line.credit),4) AS credit,
    min(line.account_id::text)::uuid AS account_id,
    min(line.customer_id::text)::uuid AS customer_id
  FROM posted_ar_lines line
  WHERE line.financial_event_id IS NOT NULL
  GROUP BY line.company_id,line.financial_event_id
),
invoice_direct_ar AS (
  SELECT line.company_id,line.source_id,count(*) AS line_rows,
    round(sum(line.debit),4) AS debit
  FROM posted_ar_lines line
  WHERE line.source_type='backoffice_sales_invoices'
  GROUP BY line.company_id,line.source_id
),
receipt_direct_ar AS (
  SELECT line.company_id,line.source_id,count(*) AS line_rows,
    round(sum(line.credit),4) AS credit
  FROM posted_ar_lines line
  WHERE line.source_type='customer_receipt_documents'
  GROUP BY line.company_id,line.source_id
),
invoice_lineage AS (
  SELECT scope.company_code,invoice.company_id,invoice.id AS document_id,
    invoice.invoice_no AS document_no,invoice.invoice_date AS document_date,
    invoice.customer_id,invoice.grand_total AS document_amount,
    invoice.financial_event_id,event.status::text AS event_status,
    event.source_table AS event_source_table,event.source_id AS event_source_id,
    COALESCE(direct.line_rows,0) AS direct_ar_rows,
    COALESCE(direct.debit,0) AS direct_ar_debit,
    COALESCE(linked.line_rows,0) AS event_ar_rows,
    COALESCE(linked.debit,0) AS event_ar_debit,
    linked.account_id AS event_account_id,
    linked.customer_id AS event_customer_id,
    event_journal.source_type AS event_journal_source_type,
    event_journal.source_id AS event_journal_source_id,
    COALESCE(event_journal.journal_rows,0) AS event_journal_rows
  FROM scope
  JOIN public.backoffice_sales_invoices invoice
    ON invoice.company_id=scope.company_id AND invoice.status='POSTED'
  LEFT JOIN public.financial_events event
    ON event.company_id=invoice.company_id AND event.id=invoice.financial_event_id
  LEFT JOIN invoice_direct_ar direct ON direct.company_id=invoice.company_id
    AND direct.source_id=invoice.id
  LEFT JOIN event_ar linked ON linked.company_id=invoice.company_id
    AND linked.financial_event_id=invoice.financial_event_id
  LEFT JOIN posted_event_journals event_journal
    ON event_journal.company_id=invoice.company_id
   AND event_journal.financial_event_id=invoice.financial_event_id
),
invoice_classified AS (
  SELECT lineage.*,
    CASE
      WHEN financial_event_id IS NULL THEN 'DOCUMENT_EVENT_NULL'
      WHEN event_status IS NULL THEN 'EVENT_ROW_MISSING'
      WHEN event_source_table IS DISTINCT FROM 'backoffice_sales_invoices'
        OR event_source_id IS DISTINCT FROM document_id THEN 'EVENT_SOURCE_MISMATCH'
      WHEN event_status<>'POSTED' THEN 'EVENT_NOT_POSTED'
      WHEN event_journal_rows=0 THEN 'POSTED_EVENT_JOURNAL_MISSING'
      WHEN event_ar_rows=0 THEN 'EVENT_JOURNAL_AR_LINE_MISSING'
      WHEN event_ar_rows<>1 OR event_ar_debit<>document_amount
        OR event_customer_id IS DISTINCT FROM customer_id
        THEN 'EVENT_LINKED_AR_SHAPE_MISMATCH'
      WHEN direct_ar_rows=1 AND direct_ar_debit=document_amount
        THEN 'DIRECT_AND_EVENT_LINK_MATCH'
      ELSE 'EVENT_LINK_MATCH_DIRECT_SOURCE_MISMATCH'
    END AS classification
  FROM invoice_lineage lineage
),
backoffice_receipt_amounts AS (
  SELECT allocation.company_id,allocation.document_id,
    round(sum(allocation.allocated_amount),4) AS backoffice_amount
  FROM public.customer_receipt_backoffice_invoice_allocations allocation
  JOIN scope ON scope.company_id=allocation.company_id
  GROUP BY allocation.company_id,allocation.document_id
),
retail_receipt_amounts AS (
  SELECT allocation.company_id,allocation.document_id,
    round(sum(allocation.allocated_amount),4) AS retail_amount
  FROM public.customer_receipt_allocations allocation
  JOIN scope ON scope.company_id=allocation.company_id
  GROUP BY allocation.company_id,allocation.document_id
),
receipt_lineage AS (
  SELECT scope.company_code,receipt.company_id,receipt.id AS document_id,
    receipt.receipt_no AS document_no,receipt.receipt_date AS document_date,
    receipt.customer_id,receipt.total_amount AS document_amount,
    receipt.financial_event_id,event.status::text AS event_status,
    event.source_table AS event_source_table,event.source_id AS event_source_id,
    backoffice.backoffice_amount,COALESCE(retail.retail_amount,0) AS retail_amount,
    COALESCE(direct.line_rows,0) AS direct_ar_rows,
    COALESCE(direct.credit,0) AS direct_ar_credit,
    COALESCE(linked.line_rows,0) AS event_ar_rows,
    COALESCE(linked.credit,0) AS event_ar_credit,
    linked.account_id AS event_account_id,
    linked.customer_id AS event_customer_id,
    event_journal.source_type AS event_journal_source_type,
    event_journal.source_id AS event_journal_source_id,
    COALESCE(event_journal.journal_rows,0) AS event_journal_rows
  FROM scope
  JOIN public.customer_receipt_documents receipt
    ON receipt.company_id=scope.company_id AND receipt.status='POSTED'
  JOIN backoffice_receipt_amounts backoffice
    ON backoffice.company_id=receipt.company_id
   AND backoffice.document_id=receipt.id
  LEFT JOIN retail_receipt_amounts retail
    ON retail.company_id=receipt.company_id AND retail.document_id=receipt.id
  LEFT JOIN public.financial_events event
    ON event.company_id=receipt.company_id AND event.id=receipt.financial_event_id
  LEFT JOIN receipt_direct_ar direct ON direct.company_id=receipt.company_id
    AND direct.source_id=receipt.id
  LEFT JOIN event_ar linked ON linked.company_id=receipt.company_id
    AND linked.financial_event_id=receipt.financial_event_id
  LEFT JOIN posted_event_journals event_journal
    ON event_journal.company_id=receipt.company_id
   AND event_journal.financial_event_id=receipt.financial_event_id
),
receipt_classified AS (
  SELECT lineage.*,
    CASE
      WHEN financial_event_id IS NULL THEN 'DOCUMENT_EVENT_NULL'
      WHEN event_status IS NULL THEN 'EVENT_ROW_MISSING'
      WHEN event_source_table IS DISTINCT FROM 'customer_receipt_documents'
        OR event_source_id IS DISTINCT FROM document_id THEN 'EVENT_SOURCE_MISMATCH'
      WHEN event_status<>'POSTED' THEN 'EVENT_NOT_POSTED'
      WHEN event_journal_rows=0 THEN 'POSTED_EVENT_JOURNAL_MISSING'
      WHEN event_ar_rows=0 THEN 'EVENT_JOURNAL_AR_LINE_MISSING'
      WHEN event_ar_rows<>1 OR event_ar_credit<>document_amount
        OR event_customer_id IS DISTINCT FROM customer_id
        THEN 'EVENT_LINKED_AR_SHAPE_MISMATCH'
      WHEN direct_ar_rows=1 AND direct_ar_credit=document_amount
        THEN 'DIRECT_AND_EVENT_LINK_MATCH'
      ELSE 'EVENT_LINK_MATCH_DIRECT_SOURCE_MISMATCH'
    END AS classification
  FROM receipt_lineage lineage
),
pair_diagnosis AS (
  SELECT scope.company_code,allocation.id AS allocation_id,
    invoice.document_no AS invoice_no,receipt.document_no AS receipt_no,
    allocation.allocated_amount,
    invoice.classification AS invoice_classification,
    receipt.classification AS receipt_classification,
    invoice.event_account_id AS invoice_account_id,
    receipt.event_account_id AS receipt_account_id,
    invoice.event_customer_id AS invoice_customer_id,
    receipt.event_customer_id AS receipt_customer_id,
    CASE
      WHEN invoice.event_ar_rows<>1 THEN 'INVOICE_AR_LINE_UNRESOLVED'
      WHEN receipt.event_ar_rows<>1 THEN 'RECEIPT_AR_LINE_UNRESOLVED'
      WHEN invoice.event_customer_id IS DISTINCT FROM receipt.event_customer_id
        THEN 'CUSTOMER_MISMATCH'
      WHEN invoice.event_account_id IS DISTINCT FROM receipt.event_account_id
        THEN 'AR_ACCOUNT_MISMATCH'
      ELSE 'PAIR_MATCH'
    END AS classification
  FROM public.customer_receipt_backoffice_invoice_allocations allocation
  JOIN scope ON scope.company_id=allocation.company_id
  JOIN invoice_classified invoice ON invoice.company_id=allocation.company_id
    AND invoice.document_id=allocation.invoice_id
  JOIN receipt_classified receipt ON receipt.company_id=allocation.company_id
    AND receipt.document_id=allocation.document_id
  JOIN public.customer_receipt_documents document
    ON document.company_id=allocation.company_id
   AND document.id=allocation.document_id AND document.status='POSTED'
),
credit_note_lineage AS (
  SELECT scope.company_code,note.source_kind,count(*) AS document_rows,
    round(sum(note.ar_reduction_amount),4) AS ar_reduction,
    round(sum(note.refund_liability_amount),4) AS refund_liability,
    count(*) FILTER(WHERE note.financial_event_id IS NULL) AS event_null_rows,
    count(*) FILTER(WHERE event.id IS NULL) AS event_missing_rows,
    count(*) FILTER(WHERE COALESCE(event_journal.journal_rows,0)=0)
      AS journal_missing_rows,
    count(*) FILTER(WHERE COALESCE(line.line_rows,0)=0
      AND note.ar_reduction_amount>0)
      AS ar_line_missing_rows
  FROM scope
  JOIN public.backoffice_sales_credit_notes note
    ON note.company_id=scope.company_id AND note.status='POSTED'
  LEFT JOIN public.financial_events event
    ON event.company_id=note.company_id AND event.id=note.financial_event_id
  LEFT JOIN posted_event_journals event_journal
    ON event_journal.company_id=note.company_id
   AND event_journal.financial_event_id=note.financial_event_id
  LEFT JOIN event_ar line ON line.company_id=note.company_id
    AND line.financial_event_id=note.financial_event_id
  GROUP BY scope.company_code,note.source_kind
)
SELECT 'backoffice_ar_lineage_invoice_classification' AS check_name,
  'INFO' AS status,0::bigint AS violation_rows,
  jsonb_build_object(
    'rows',COALESCE((SELECT jsonb_agg(row_to_json(summary) ORDER BY
      summary.company_code,summary.classification)
      FROM (SELECT company_code,classification,count(*) AS rows,
        round(sum(document_amount),4) AS amount,min(document_date) AS min_date,
        max(document_date) AS max_date
        FROM invoice_classified GROUP BY company_code,classification) summary),'[]'::jsonb),
    'nonDirectSamples',COALESCE((SELECT jsonb_agg(row_to_json(sample) ORDER BY
      sample.company_code,sample.document_no)
      FROM (SELECT company_code,document_no,document_date,document_amount,
        classification,event_status,event_source_table,event_source_id,
        event_journal_rows,event_ar_rows,event_ar_debit,event_journal_source_type,
        event_journal_source_id
        FROM invoice_classified
        WHERE classification<>'DIRECT_AND_EVENT_LINK_MATCH'
        ORDER BY company_code,document_no LIMIT 50) sample),'[]'::jsonb))
UNION ALL
SELECT 'backoffice_ar_lineage_receipt_classification','INFO',0,
  jsonb_build_object(
    'rows',COALESCE((SELECT jsonb_agg(row_to_json(summary) ORDER BY
      summary.company_code,summary.classification)
      FROM (SELECT company_code,classification,count(*) AS rows,
        round(sum(document_amount),4) AS amount,min(document_date) AS min_date,
        max(document_date) AS max_date
        FROM receipt_classified GROUP BY company_code,classification) summary),'[]'::jsonb),
    'nonDirectSamples',COALESCE((SELECT jsonb_agg(row_to_json(sample) ORDER BY
      sample.company_code,sample.document_no)
      FROM (SELECT company_code,document_no,document_date,document_amount,
        classification,event_status,event_source_table,event_source_id,
        event_journal_rows,event_ar_rows,event_ar_credit,event_journal_source_type,
        event_journal_source_id
        FROM receipt_classified
        WHERE classification<>'DIRECT_AND_EVENT_LINK_MATCH'
        ORDER BY company_code,document_no LIMIT 50) sample),'[]'::jsonb))
UNION ALL
SELECT 'backoffice_ar_lineage_mixed_receipt_partition','INFO',0,
  jsonb_build_object('rows',COALESCE((SELECT jsonb_agg(row_to_json(mixed)
    ORDER BY mixed.company_code,mixed.document_no)
    FROM (SELECT company_code,document_no,document_amount,backoffice_amount,
      retail_amount,round(document_amount-backoffice_amount-retail_amount,4)
        AS unallocated_amount,event_ar_credit,classification
      FROM receipt_classified WHERE backoffice_amount>0 AND retail_amount>0) mixed),
    '[]'::jsonb))
UNION ALL
SELECT 'backoffice_ar_lineage_pair_classification','INFO',0,
  jsonb_build_object(
    'rows',COALESCE((SELECT jsonb_agg(row_to_json(summary) ORDER BY
      summary.company_code,summary.classification)
      FROM (SELECT company_code,classification,count(*) AS rows,
        round(sum(allocated_amount),4) AS amount
        FROM pair_diagnosis GROUP BY company_code,classification) summary),'[]'::jsonb),
    'invalidSamples',COALESCE((SELECT jsonb_agg(row_to_json(sample) ORDER BY
      sample.company_code,sample.receipt_no,sample.invoice_no)
      FROM (SELECT company_code,invoice_no,receipt_no,allocated_amount,
        classification,invoice_classification,receipt_classification,
        invoice_account_id,receipt_account_id,invoice_customer_id,
        receipt_customer_id FROM pair_diagnosis
        WHERE classification<>'PAIR_MATCH'
        ORDER BY company_code,receipt_no,invoice_no LIMIT 50) sample),'[]'::jsonb))
UNION ALL
SELECT 'backoffice_ar_lineage_credit_note_partition','INFO',0,
  jsonb_build_object('rows',COALESCE((SELECT jsonb_agg(row_to_json(lineage)
    ORDER BY lineage.company_code,lineage.source_kind)
    FROM credit_note_lineage lineage),'[]'::jsonb))
UNION ALL
SELECT 'backoffice_ar_lineage_business_boundary','INFO',0,
  jsonb_build_object(
    'mutation','NONE',
    'interpretation','Direct source mismatch is not equivalent to missing Finance lineage',
    'next','Classify event-linked and genuinely missing rows before Task 2 schema design',
    'preserved',jsonb_build_array('existing FAIL evidence','Invoice','Receipt',
      'Credit Note','Retail allocation','Backoffice allocation','Finance Journal',
      'historical rows','all Companies'));
