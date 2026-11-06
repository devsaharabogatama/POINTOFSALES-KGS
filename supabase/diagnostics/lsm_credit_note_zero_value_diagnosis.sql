-- SELECT-only exact diagnosis for LSM Return/Credit Note zero-value defect.
-- No DML, DDL, transaction mutation, or function execution with side effects.

WITH company AS (
  SELECT id,company_code,company_name
  FROM public.companies
  WHERE company_code='LSM'
), exact_docs AS (
  SELECT c.id AS company_id,r.id AS return_id,r.return_no,r.status AS return_status,
    i.id AS invoice_id,i.invoice_no,i.status AS invoice_status,i.grand_total AS invoice_total,
    n.id AS credit_note_id,n.credit_note_no,n.status AS credit_note_status,
    n.charge_total,n.discount_total,n.tax_total,n.delivery_fee_amount,n.grand_total AS credit_note_total
  FROM company c
  LEFT JOIN public.backoffice_sales_returns r
    ON r.company_id=c.id AND r.return_no='RTN-20261021-0000000033'
  LEFT JOIN public.backoffice_sales_invoices i
    ON i.company_id=c.id AND i.invoice_no='INV-20261016-0000000717'
  LEFT JOIN public.backoffice_sales_credit_notes n
    ON n.company_id=c.id AND n.credit_note_no='CN-20261106-0000000025'
)
SELECT 'lsm_credit_note_zero_identity' AS check_name,
  CASE WHEN count(*)=1
    AND count(*) FILTER (WHERE return_id IS NOT NULL AND invoice_id IS NOT NULL
      AND credit_note_id IS NOT NULL)=1 THEN 'PASS' ELSE 'BLOCKER' END AS status,
  count(*) FILTER (WHERE return_id IS NULL OR invoice_id IS NULL OR credit_note_id IS NULL) AS violation_rows,
  jsonb_agg(to_jsonb(exact_docs)) AS details
FROM exact_docs;

WITH company AS (
  SELECT id FROM public.companies WHERE company_code='LSM'
), source_line AS (
  SELECT line.company_id,line.id,line.invoice_id,line.sales_order_line_id,
    line.product_id,line.uom_id,line.quantity_uom,line.quantity_base,
    line.base_qty_per_uom,line.unit_price,line.discount_amount,line.tax_amount,
    line.line_amount,line.source_snapshot,
    private.backoffice_invoice_effective_line_amounts(line.company_id,line.id) AS effective
  FROM public.backoffice_sales_invoice_lines line
  JOIN public.backoffice_sales_invoices invoice
    ON invoice.company_id=line.company_id AND invoice.id=line.invoice_id
  JOIN public.products product
    ON product.company_id=line.company_id AND product.id=line.product_id
  JOIN company c ON c.id=line.company_id
  WHERE invoice.invoice_no='INV-20261016-0000000717'
    AND product.sku='T27BC'
    AND line.line_type='PRODUCT' AND line.source_kind='SALES_ORDER'
)
SELECT 'lsm_credit_note_zero_source_line' AS check_name,
  CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END AS status,
  abs(count(*)-1) AS violation_rows,
  jsonb_build_object('rows',count(*),'lines',COALESCE(jsonb_agg(to_jsonb(source_line)),'[]'::jsonb)) AS details
FROM source_line;

WITH company AS (
  SELECT id FROM public.companies WHERE company_code='LSM'
), note_lines AS (
  SELECT line.id,line.credit_note_id,line.return_id,line.return_receipt_line_id,
    line.sales_order_line_id,line.source_invoice_line_id,line.line_no,
    line.product_id,line.uom_id,line.quantity_uom,line.quantity_base,
    line.base_qty_per_uom,line.unit_price,line.discount_amount,line.tax_amount,
    line.line_amount,line.source_snapshot
  FROM public.backoffice_sales_credit_note_lines line
  JOIN public.backoffice_sales_credit_notes note
    ON note.company_id=line.company_id AND note.id=line.credit_note_id
  JOIN company c ON c.id=line.company_id
  WHERE note.credit_note_no='CN-20261106-0000000025'
)
SELECT 'lsm_credit_note_zero_saved_lines' AS check_name,
  CASE WHEN count(*)>0 THEN 'PASS' ELSE 'ROOT_CAUSE' END AS status,
  CASE WHEN count(*)>0 THEN 0 ELSE 1 END AS violation_rows,
  jsonb_build_object('rows',count(*),'lines',COALESCE(jsonb_agg(to_jsonb(note_lines)),'[]'::jsonb)) AS details
FROM note_lines;

WITH company AS (
  SELECT id FROM public.companies WHERE company_code='LSM'
), exact AS (
  SELECT allocation.id,allocation.allocation_type,allocation.allocated_base_qty,
    allocation.invoice_id,allocation.invoice_line_id,allocation.credit_note_id,
    allocation.invoice_line_snapshot,allocation.operation_id,allocation.created_at
  FROM public.backoffice_sales_return_invoice_allocations allocation
  JOIN public.backoffice_sales_returns r
    ON r.company_id=allocation.company_id AND r.id=allocation.return_id
  JOIN company c ON c.id=allocation.company_id
  WHERE r.return_no='RTN-20261021-0000000033'
)
SELECT 'lsm_credit_note_zero_allocation_lineage' AS check_name,
  CASE WHEN count(*)>0 THEN 'PASS' ELSE 'BLOCKER' END AS status,
  CASE WHEN count(*)>0 THEN 0 ELSE 1 END AS violation_rows,
  jsonb_build_object('rows',count(*),'allocations',COALESCE(jsonb_agg(to_jsonb(exact)),'[]'::jsonb)) AS details
FROM exact;

SELECT 'lsm_credit_note_zero_runtime_definitions' AS check_name,
  CASE WHEN to_regprocedure('private.allocate_backoffice_sales_return_invoices_before_retained(uuid,bigint,uuid,jsonb)') IS NOT NULL
    AND to_regprocedure('private.backoffice_invoice_effective_line_amounts(uuid,uuid)') IS NOT NULL
    AND to_regprocedure('private.recalculate_backoffice_sales_credit_note(uuid,uuid,uuid)') IS NOT NULL
    THEN 'PASS' ELSE 'BLOCKER' END AS status,
  (to_regprocedure('private.allocate_backoffice_sales_return_invoices_before_retained(uuid,bigint,uuid,jsonb)') IS NULL)::int
    +(to_regprocedure('private.backoffice_invoice_effective_line_amounts(uuid,uuid)') IS NULL)::int
    +(to_regprocedure('private.recalculate_backoffice_sales_credit_note(uuid,uuid,uuid)') IS NULL)::int AS violation_rows,
  jsonb_build_object(
    'allocatorMd5',CASE WHEN to_regprocedure('private.allocate_backoffice_sales_return_invoices_before_retained(uuid,bigint,uuid,jsonb)') IS NOT NULL
      THEN md5(pg_get_functiondef('private.allocate_backoffice_sales_return_invoices_before_retained(uuid,bigint,uuid,jsonb)'::regprocedure)) END,
    'effectiveLineMd5',CASE WHEN to_regprocedure('private.backoffice_invoice_effective_line_amounts(uuid,uuid)') IS NOT NULL
      THEN md5(pg_get_functiondef('private.backoffice_invoice_effective_line_amounts(uuid,uuid)'::regprocedure)) END,
    'recalculateMd5',CASE WHEN to_regprocedure('private.recalculate_backoffice_sales_credit_note(uuid,uuid,uuid)') IS NOT NULL
      THEN md5(pg_get_functiondef('private.recalculate_backoffice_sales_credit_note(uuid,uuid,uuid)'::regprocedure)) END,
    'allocatorDefinition',CASE WHEN to_regprocedure('private.allocate_backoffice_sales_return_invoices_before_retained(uuid,bigint,uuid,jsonb)') IS NOT NULL
      THEN pg_get_functiondef('private.allocate_backoffice_sales_return_invoices_before_retained(uuid,bigint,uuid,jsonb)'::regprocedure) END,
    'effectiveLineDefinition',CASE WHEN to_regprocedure('private.backoffice_invoice_effective_line_amounts(uuid,uuid)') IS NOT NULL
      THEN pg_get_functiondef('private.backoffice_invoice_effective_line_amounts(uuid,uuid)'::regprocedure) END,
    'recalculateDefinition',CASE WHEN to_regprocedure('private.recalculate_backoffice_sales_credit_note(uuid,uuid,uuid)') IS NOT NULL
      THEN pg_get_functiondef('private.recalculate_backoffice_sales_credit_note(uuid,uuid,uuid)'::regprocedure) END
  ) AS details;

WITH company AS (
  SELECT id FROM public.companies WHERE company_code='LSM'
), effects AS (
  SELECT
    (SELECT count(*) FROM public.financial_events event
      JOIN public.backoffice_sales_credit_notes note
        ON note.company_id=event.company_id AND note.financial_event_id=event.id
      WHERE event.company_id=company.id AND note.credit_note_no='CN-20261106-0000000025') AS event_rows,
    (SELECT count(*) FROM public.finance_journals journal
      JOIN public.financial_events event
        ON event.company_id=journal.company_id AND event.id=journal.financial_event_id
      JOIN public.backoffice_sales_credit_notes note
        ON note.company_id=event.company_id AND note.financial_event_id=event.id
      WHERE journal.company_id=company.id AND note.credit_note_no='CN-20261106-0000000025') AS journal_rows
  FROM company
)
SELECT 'lsm_credit_note_zero_finance_boundary' AS check_name,
  CASE WHEN event_rows=0 AND journal_rows=0 THEN 'PASS' ELSE 'BLOCKER' END AS status,
  event_rows+journal_rows AS violation_rows,
  to_jsonb(effects) AS details
FROM effects;
