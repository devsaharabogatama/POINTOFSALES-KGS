-- Read-only Task 8 inventory. This file never reclassifies historical rows.
WITH process_scope AS (
  SELECT company.id AS company_id,company.company_code,company.company_name,
    public.private_company_feature_enabled(company.id,'tax_sales_enabled')
      AS tax_sales_enabled
  FROM public.companies company
  JOIN public.company_sales_process_settings setting
    ON setting.company_id=company.id
  WHERE setting.active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE'
), native_liability AS (
  SELECT note.company_id,note.id,note.credit_note_no,note.return_id,
    note.source_invoice_id,note.customer_id,note.grand_total,
    note.refund_liability_amount,
    round(note.refund_liability_amount-COALESCE(refund.net_amount,0),4)
      AS remaining_liability
  FROM public.backoffice_sales_credit_notes note
  JOIN process_scope scope ON scope.company_id=note.company_id
  LEFT JOIN LATERAL (
    SELECT COALESCE(sum(CASE document.document_kind
      WHEN 'REFUND' THEN document.amount WHEN 'REVERSAL' THEN -document.amount
      ELSE 0 END),0) AS net_amount
    FROM public.backoffice_sales_customer_refunds document
    WHERE document.company_id=note.company_id
      AND document.credit_note_id=note.id AND document.status='POSTED'
  ) refund ON true
  WHERE note.source_kind='BACKOFFICE' AND note.status='POSTED'
    AND note.refund_liability_amount>0
), retained_retail_liability AS (
  SELECT note.company_id,count(*) AS rows,
    round(sum(note.refund_liability_amount),4) AS amount
  FROM public.backoffice_sales_credit_notes note
  JOIN process_scope scope ON scope.company_id=note.company_id
  WHERE note.source_kind='RETAINED_RETAIL' AND note.status='POSTED'
    AND note.refund_liability_amount>0
  GROUP BY note.company_id
), return_without_credit AS (
  SELECT document.company_id,document.id,document.return_no,document.status,
    document.source_kind,document.customer_id,document.updated_at
  FROM public.backoffice_sales_returns document
  JOIN process_scope scope ON scope.company_id=document.company_id
  WHERE document.source_kind='BACKOFFICE'
    AND document.status IN('RECEIVED','CREDIT_PENDING','REFUND_PENDING')
    AND NOT EXISTS (
      SELECT 1 FROM public.backoffice_sales_credit_notes note
      WHERE note.company_id=document.company_id AND note.return_id=document.id
        AND note.status IN('DRAFT','POSTED'))
), open_credit AS (
  SELECT item.company_id,item.id,item.source_id,item.customer_id,
    item.original_amount,
    round(item.original_amount-COALESCE(sum(allocation.allocated_amount),0),4)
      AS residual_amount
  FROM public.ar_open_item_registry item
  JOIN process_scope scope ON scope.company_id=item.company_id
  LEFT JOIN public.ar_open_item_allocations allocation
    ON allocation.company_id=item.company_id AND allocation.credit_item_id=item.id
  WHERE item.scope_kind='BACKOFFICE' AND item.item_kind='CREDIT_NOTE'
  GROUP BY item.company_id,item.id,item.source_id,item.customer_id,item.original_amount
), runtime_boundary AS (
  SELECT (SELECT count(*) FROM public.finance_posting_queue_runs
      WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) AS active_finance_queue,
    (SELECT count(*) FROM public.pos_offline_sale_submissions
      WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) AS nonterminal_offline
)
SELECT 'backoffice_ar_legacy_backlog_process_scope' AS check_name,'PASS' AS status,
  0::bigint AS violation_rows,
  jsonb_build_object('companies',COALESCE((SELECT jsonb_agg(jsonb_build_object(
    'code',scope.company_code,'name',scope.company_name,
    'taxSalesEnabled',scope.tax_sales_enabled) ORDER BY scope.company_code)
    FROM process_scope scope),'[]'::jsonb)) AS details
UNION ALL
SELECT 'backoffice_ar_legacy_backlog_native_liability','REVIEW',count(*),
  jsonb_build_object('meaning','Manual row-by-row Finance decision required; no automatic reclassification is authorized',
    'rows',COALESCE(jsonb_agg(jsonb_build_object('company',company.company_code,
      'creditNoteNo',liability.credit_note_no,'creditNoteId',liability.id,
      'returnId',liability.return_id,'sourceInvoiceId',liability.source_invoice_id,
      'customerId',liability.customer_id,'grandTotal',liability.grand_total,
      'originalLiability',liability.refund_liability_amount,
      'remainingLiability',liability.remaining_liability)
      ORDER BY company.company_code,liability.credit_note_no)
      FILTER(WHERE liability.id IS NOT NULL),'[]'::jsonb))
FROM native_liability liability
LEFT JOIN public.companies company ON company.id=liability.company_id
UNION ALL
SELECT 'backoffice_ar_legacy_backlog_retained_retail_exclusion','INFO',0,
  jsonb_build_object('meaning','Retained Retail liability is explicitly excluded from native Backoffice reclassification',
    'rows',COALESCE((SELECT jsonb_agg(jsonb_build_object('company',company.company_code,
      'rows',inventory.rows,'amount',inventory.amount) ORDER BY company.company_code)
      FROM retained_retail_liability inventory JOIN public.companies company
        ON company.id=inventory.company_id),'[]'::jsonb))
UNION ALL
SELECT 'backoffice_ar_legacy_backlog_return_without_credit','REVIEW',count(*),
  jsonb_build_object('meaning','Received native Backoffice Returns without an active Credit Note require operational review',
    'rows',COALESCE(jsonb_agg(jsonb_build_object('company',company.company_code,
      'returnNo',document.return_no,'returnId',document.id,'status',document.status,
      'customerId',document.customer_id,'updatedAt',document.updated_at)
      ORDER BY company.company_code,document.return_no)
      FILTER(WHERE document.id IS NOT NULL),'[]'::jsonb))
FROM return_without_credit document
LEFT JOIN public.companies company ON company.id=document.company_id
UNION ALL
SELECT 'backoffice_ar_legacy_backlog_open_credit_inventory','INFO',0,
  jsonb_build_object('rows',COALESCE((SELECT jsonb_agg(jsonb_build_object(
    'company',company.company_code,'creditNoteId',credit.source_id,
    'customerId',credit.customer_id,'originalAmount',credit.original_amount,
    'residualAmount',credit.residual_amount)
    ORDER BY company.company_code,credit.source_id)
    FROM open_credit credit JOIN public.companies company
      ON company.id=credit.company_id),'[]'::jsonb))
UNION ALL
SELECT 'backoffice_ar_legacy_backlog_runtime_boundary',
  CASE WHEN active_finance_queue=0 AND nonterminal_offline=0 THEN 'PASS' ELSE 'BLOCKER' END,
  active_finance_queue+nonterminal_offline,
  jsonb_build_object('activeFinanceQueue',active_finance_queue,
    'nonterminalOffline',nonterminal_offline)
FROM runtime_boundary
UNION ALL
SELECT 'backoffice_ar_legacy_backlog_business_boundary','INFO',0,
  jsonb_build_object('mutation','NONE','automaticReclassification',false,
    'preserved',jsonb_build_array('Posted Journals','RETAINED_RETAIL','POS Retail',
      'Customer Balance','Stock/FIFO/HPP','historical documents'),
    'next','Any REVIEW row must be approved row-by-row before a separate forward migration');
