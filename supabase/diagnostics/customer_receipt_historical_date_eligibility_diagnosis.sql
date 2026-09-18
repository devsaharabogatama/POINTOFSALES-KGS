-- SELECT-only diagnosis for Finance > Customer Receipt historical allocation.
-- Target reported by the user on 2026-09-18:
--   invoice     : INV-20260829-0000000144
--   receipt date: 2026-08-31
--
-- This script does not write, lock, or change Production data.

WITH parameters AS (
  SELECT
    'INV-20260829-0000000144'::text AS invoice_no,
    DATE '2026-08-31' AS attempted_receipt_date
),
target_sale AS (
  SELECT
    company.id AS company_id,
    company.company_name,
    sale.id AS sales_id,
    snapshot.invoice_no,
    sale.customer_id,
    customer.code AS customer_code,
    customer.name AS customer_name,
    sale.is_tempo,
    sale.document_status::text AS document_status,
    sale.transaction_date,
    sale.due_date,
    parameters.attempted_receipt_date
  FROM parameters
  JOIN public.sales_invoice_snapshots snapshot
    ON snapshot.invoice_no=parameters.invoice_no
  JOIN public.sales_headers sale
    ON sale.company_id=snapshot.company_id
   AND sale.id=snapshot.sales_id
  JOIN public.companies company
    ON company.id=sale.company_id
  JOIN public.customers customer
    ON customer.company_id=sale.company_id
   AND customer.id=sale.customer_id
),
dispatch_summary AS (
  SELECT
    target.company_id,
    target.sales_id,
    min(effect.effective_date) AS first_effective_date,
    max(effect.effective_date) AS last_effective_date,
    count(effect.id)::bigint AS effect_rows,
    COALESCE(sum(effect.receivable_amount)
      FILTER (WHERE effect.effective_date<=target.attempted_receipt_date),0) AS receivable_at_attempt,
    COALESCE(sum(effect.receivable_amount),0) AS receivable_current,
    COALESCE(jsonb_agg(jsonb_build_object(
      'effectId',effect.id,
      'effectiveDate',effect.effective_date,
      'receivableAmount',effect.receivable_amount,
      'createdAt',effect.created_at
    ) ORDER BY effect.effective_date,effect.created_at)
      FILTER (WHERE effect.id IS NOT NULL),'[]'::jsonb) AS effects
  FROM target_sale target
  LEFT JOIN public.sales_dispatch_financial_effects effect
    ON effect.company_id=target.company_id
   AND effect.sales_id=target.sales_id
  GROUP BY target.company_id,target.sales_id,target.attempted_receipt_date
),
posted_receipts AS (
  SELECT
    target.company_id,
    target.sales_id,
    COALESCE(sum(allocation.allocated_amount)
      FILTER (WHERE receipt.id IS NOT NULL),0) AS posted_allocation_total,
    COALESCE(jsonb_agg(jsonb_build_object(
      'receiptNo',receipt.receipt_no,
      'receiptDate',receipt.receipt_date,
      'allocatedAmount',allocation.allocated_amount
    ) ORDER BY receipt.receipt_date,receipt.receipt_no)
      FILTER (WHERE receipt.id IS NOT NULL),'[]'::jsonb) AS receipts
  FROM target_sale target
  LEFT JOIN public.customer_receipt_allocations allocation
    ON allocation.company_id=target.company_id
   AND allocation.sales_id=target.sales_id
  LEFT JOIN public.customer_receipt_documents receipt
    ON receipt.company_id=allocation.company_id
   AND receipt.id=allocation.document_id
   AND receipt.status='POSTED'
  GROUP BY target.company_id,target.sales_id
)
SELECT
  'customer_receipt_historical_date_eligibility'::text AS check_name,
  CASE
    WHEN target.is_tempo IS NOT TRUE THEN 'BLOCKED_NOT_TEMPO'
    WHEN target.document_status='POSTED' THEN 'ELIGIBLE_LEGACY_POSTED'
    WHEN dispatch.first_effective_date IS NULL THEN 'BLOCKED_NO_DISPATCH_RECEIVABLE'
    WHEN dispatch.first_effective_date>target.attempted_receipt_date
      THEN 'BLOCKED_RECEIVABLE_NOT_YET_EFFECTIVE'
    WHEN dispatch.receivable_at_attempt-receipt.posted_allocation_total<=0
      THEN 'BLOCKED_NO_OUTSTANDING_AT_DATE'
    ELSE 'ELIGIBLE_AT_ATTEMPTED_DATE'
  END AS status,
  jsonb_build_object(
    'companyId',target.company_id,
    'companyName',target.company_name,
    'salesId',target.sales_id,
    'invoiceNo',target.invoice_no,
    'customerId',target.customer_id,
    'customerCode',target.customer_code,
    'customerName',target.customer_name,
    'isTempo',target.is_tempo,
    'documentStatus',target.document_status,
    'transactionDate',target.transaction_date,
    'dueDate',target.due_date,
    'attemptedReceiptDate',target.attempted_receipt_date,
    'firstDispatchEffectiveDate',dispatch.first_effective_date,
    'lastDispatchEffectiveDate',dispatch.last_effective_date,
    'dispatchEffectRows',dispatch.effect_rows,
    'receivableAtAttempt',dispatch.receivable_at_attempt,
    'receivableCurrent',dispatch.receivable_current,
    'postedAllocationTotal',receipt.posted_allocation_total,
    'outstandingAtAttempt',GREATEST(
      CASE WHEN target.document_status='POSTED'
        THEN private.odr6d_dispatched_receivable_before_receipts(
          target.company_id,target.sales_id,target.attempted_receipt_date)
        ELSE dispatch.receivable_at_attempt
      END-receipt.posted_allocation_total,0),
    'saveEligibilityRule',jsonb_build_object(
      'legacyPostedBypassesDispatchDate',target.document_status='POSTED',
      'hasDispatchEffectiveByAttempt',EXISTS(
        SELECT 1
        FROM public.sales_dispatch_financial_effects effect
        WHERE effect.company_id=target.company_id
          AND effect.sales_id=target.sales_id
          AND effect.effective_date<=target.attempted_receipt_date
      )
    ),
    'dispatchEffects',dispatch.effects,
    'postedReceipts',receipt.receipts
  ) AS details
FROM target_sale target
JOIN dispatch_summary dispatch
  ON dispatch.company_id=target.company_id
 AND dispatch.sales_id=target.sales_id
JOIN posted_receipts receipt
  ON receipt.company_id=target.company_id
 AND receipt.sales_id=target.sales_id;
