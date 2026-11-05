-- SELECT-only KMS account-lineage diagnosis for Task 2 AR open-item design.
--
-- Evidence being tested:
--   * KMS changed CUSTOMER_RECEIVABLE routing from system account 1210 to
--     workbook account 1020100 around the 2026-09-29 activation;
--   * finance_journal_lines.account_function_key_snapshot is copied from the
--     COA system_function_key, not from the transaction routing key;
--   * posted Invoice, Receipt, and Credit Note journals may therefore be valid
--     even when that snapshot is NULL.
--
-- This query performs no DDL, DML, context mutation, temp-object creation, or
-- side-effecting function call.

WITH
scope AS (
  SELECT company.id AS company_id,company.company_code
  FROM public.companies company
  WHERE company.company_code='KMS'
),
ar_accounts AS (
  SELECT account.company_id,account.id AS account_id,account.account_code,
    account.account_name,account.system_function_key,account.is_system_account,
    account.is_active,account.is_postable,account.account_type,
    account.normal_balance
  FROM scope
  JOIN public.chart_of_accounts account ON account.company_id=scope.company_id
  WHERE account.account_code IN('1210','1020100')
),
ar_rules AS (
  SELECT 'DIRECT'::text AS route_type,rule.company_id,rule.system_key,
    rule.transaction_category_id,rule.account_function_key,rule.account_id,
    account.account_code,account.account_name,account.system_function_key,
    rule.status,rule.effective_from,rule.effective_to,rule.rule_version AS version
  FROM scope
  JOIN public.transaction_account_rules rule ON rule.company_id=scope.company_id
  JOIN public.chart_of_accounts account ON account.company_id=rule.company_id
    AND account.id=rule.account_id
  WHERE rule.account_function_key='CUSTOMER_RECEIVABLE'
  UNION ALL
  SELECT 'FALLBACK',fallback.company_id,NULL::text,NULL::uuid,
    fallback.account_function_key,fallback.account_id,account.account_code,
    account.account_name,account.system_function_key,fallback.status,
    fallback.effective_from,fallback.effective_to,fallback.fallback_version
  FROM scope
  JOIN public.company_account_function_fallbacks fallback
    ON fallback.company_id=scope.company_id
  JOIN public.chart_of_accounts account ON account.company_id=fallback.company_id
    AND account.id=fallback.account_id
  WHERE fallback.account_function_key='CUSTOMER_RECEIVABLE'
),
invoice_shape AS (
  SELECT invoice.id AS document_id,invoice.invoice_no AS document_no,
    invoice.invoice_date AS document_date,invoice.grand_total AS document_amount,
    invoice.customer_id,event.id AS event_id,event.system_event_key,
    event.transaction_category_id,journal.id AS journal_id,
    count(line.id) FILTER(WHERE line.debit=invoice.grand_total
      AND line.credit=0 AND line.customer_id=invoice.customer_id) AS amount_customer_lines,
    count(line.id) FILTER(WHERE line.account_id=resolved.account_id
      AND line.debit=invoice.grand_total AND line.credit=0
      AND line.customer_id=invoice.customer_id) AS resolved_ar_lines,
    min(line.account_id::text) FILTER(WHERE line.account_id=resolved.account_id
      AND line.debit=invoice.grand_total AND line.credit=0
      AND line.customer_id=invoice.customer_id)::uuid AS resolved_line_account_id,
    min(line.account_code_snapshot) FILTER(WHERE line.account_id=resolved.account_id
      AND line.debit=invoice.grand_total AND line.credit=0
      AND line.customer_id=invoice.customer_id) AS resolved_line_account_code,
    min(line.account_function_key_snapshot) FILTER(WHERE line.account_id=resolved.account_id
      AND line.debit=invoice.grand_total AND line.credit=0
      AND line.customer_id=invoice.customer_id) AS resolved_line_function_snapshot,
    resolved.account_id AS routed_account_id,resolved.route_type,
    resolved.route_rows
  FROM scope
  JOIN public.backoffice_sales_invoices invoice
    ON invoice.company_id=scope.company_id AND invoice.status='POSTED'
  JOIN public.financial_events event ON event.company_id=invoice.company_id
    AND event.id=invoice.financial_event_id
  JOIN public.finance_journals journal ON journal.company_id=invoice.company_id
    AND journal.financial_event_id=event.id AND journal.status='POSTED'
  LEFT JOIN LATERAL (
    SELECT count(*) AS route_rows,
      (array_agg(candidate.account_id
        ORDER BY candidate.version DESC,candidate.account_id))[1] AS account_id,
      (array_agg(candidate.route_type
        ORDER BY candidate.version DESC,candidate.account_id))[1] AS route_type
    FROM (
      SELECT rule.account_id,'DIRECT'::text AS route_type,rule.rule_version AS version
      FROM public.transaction_account_rules rule
      WHERE rule.company_id=event.company_id
        AND rule.transaction_category_id=event.transaction_category_id
        AND rule.system_key=event.system_event_key
        AND rule.account_function_key='CUSTOMER_RECEIVABLE'
        AND rule.status='ACTIVE' AND rule.effective_from<=event.event_date
        AND (rule.effective_to IS NULL OR rule.effective_to>event.event_date)
      UNION ALL
      SELECT fallback.account_id,'FALLBACK',fallback.fallback_version
      FROM public.company_account_function_fallbacks fallback
      WHERE fallback.company_id=event.company_id
        AND fallback.account_function_key='CUSTOMER_RECEIVABLE'
        AND fallback.status='ACTIVE' AND fallback.effective_from<=event.event_date
        AND (fallback.effective_to IS NULL OR fallback.effective_to>event.event_date)
        AND NOT EXISTS(
          SELECT 1 FROM public.transaction_account_rules rule
          WHERE rule.company_id=event.company_id
            AND rule.transaction_category_id=event.transaction_category_id
            AND rule.system_key=event.system_event_key
            AND rule.account_function_key='CUSTOMER_RECEIVABLE'
            AND rule.status='ACTIVE' AND rule.effective_from<=event.event_date
            AND (rule.effective_to IS NULL OR rule.effective_to>event.event_date))
    ) candidate
  ) resolved ON true
  LEFT JOIN public.finance_journal_lines line ON line.company_id=journal.company_id
    AND line.journal_id=journal.id
  GROUP BY invoice.id,invoice.invoice_no,invoice.invoice_date,invoice.grand_total,
    invoice.customer_id,event.id,event.system_event_key,event.transaction_category_id,
    journal.id,resolved.account_id,resolved.route_type,resolved.route_rows
),
receipt_shape AS (
  SELECT receipt.id AS document_id,receipt.receipt_no AS document_no,
    receipt.receipt_date AS document_date,receipt.total_amount AS document_amount,
    receipt.customer_id,receipt.receivable_account_id_snapshot AS routed_account_id,
    journal.id AS journal_id,
    count(line.id) FILTER(WHERE line.account_id=receipt.receivable_account_id_snapshot
      AND line.debit=0 AND line.credit=receipt.total_amount
      AND line.customer_id=receipt.customer_id) AS resolved_ar_lines,
    min(line.account_code_snapshot) FILTER(
      WHERE line.account_id=receipt.receivable_account_id_snapshot
        AND line.debit=0 AND line.credit=receipt.total_amount
        AND line.customer_id=receipt.customer_id) AS resolved_line_account_code,
    min(line.account_function_key_snapshot) FILTER(
      WHERE line.account_id=receipt.receivable_account_id_snapshot
        AND line.debit=0 AND line.credit=receipt.total_amount
        AND line.customer_id=receipt.customer_id) AS resolved_line_function_snapshot
  FROM scope
  JOIN public.customer_receipt_documents receipt
    ON receipt.company_id=scope.company_id AND receipt.status='POSTED'
  JOIN public.finance_journals journal ON journal.company_id=receipt.company_id
    AND journal.financial_event_id=receipt.financial_event_id AND journal.status='POSTED'
  LEFT JOIN public.finance_journal_lines line ON line.company_id=journal.company_id
    AND line.journal_id=journal.id
  WHERE EXISTS(
    SELECT 1 FROM public.customer_receipt_backoffice_invoice_allocations allocation
    WHERE allocation.company_id=receipt.company_id
      AND allocation.document_id=receipt.id)
  GROUP BY receipt.id,receipt.receipt_no,receipt.receipt_date,receipt.total_amount,
    receipt.customer_id,receipt.receivable_account_id_snapshot,journal.id
),
credit_shape AS (
  SELECT note.id AS document_id,note.credit_note_no AS document_no,
    note.credit_note_date AS document_date,note.ar_reduction_amount AS document_amount,
    note.customer_id,event.id AS event_id,journal.id AS journal_id,
    count(line.id) FILTER(WHERE line.credit=note.ar_reduction_amount
      AND line.debit=0 AND line.customer_id=note.customer_id) AS amount_customer_lines,
    min(line.account_code_snapshot) FILTER(WHERE line.credit=note.ar_reduction_amount
      AND line.debit=0 AND line.customer_id=note.customer_id) AS candidate_account_code,
    min(line.account_function_key_snapshot) FILTER(
      WHERE line.credit=note.ar_reduction_amount AND line.debit=0
        AND line.customer_id=note.customer_id) AS candidate_function_snapshot
  FROM scope
  JOIN public.backoffice_sales_credit_notes note
    ON note.company_id=scope.company_id AND note.status='POSTED'
    AND note.ar_reduction_amount>0
  JOIN public.financial_events event ON event.company_id=note.company_id
    AND event.id=note.financial_event_id
  JOIN public.finance_journals journal ON journal.company_id=note.company_id
    AND journal.financial_event_id=event.id AND journal.status='POSTED'
  LEFT JOIN public.finance_journal_lines line ON line.company_id=journal.company_id
    AND line.journal_id=journal.id
  GROUP BY note.id,note.credit_note_no,note.credit_note_date,
    note.ar_reduction_amount,note.customer_id,event.id,journal.id
)
SELECT 'backoffice_ar_kms_account_contract' AS check_name,'INFO' AS status,
  0::bigint AS violation_rows,
  jsonb_build_object('rows',COALESCE((SELECT jsonb_agg(row_to_json(account)
    ORDER BY account.account_code) FROM ar_accounts account),'[]'::jsonb)) AS details
UNION ALL
SELECT 'backoffice_ar_kms_route_history','INFO',0,
  jsonb_build_object('rows',COALESCE((SELECT jsonb_agg(row_to_json(route)
    ORDER BY route.effective_from,route.route_type,route.system_key)
    FROM ar_rules route),'[]'::jsonb))
UNION ALL
SELECT 'backoffice_ar_kms_invoice_line_shape','INFO',0,
  jsonb_build_object(
    'summary',COALESCE((SELECT jsonb_agg(row_to_json(summary)
      ORDER BY summary.document_date,summary.account_code)
      FROM (SELECT document_date,resolved_line_account_code AS account_code,
        resolved_line_function_snapshot AS function_snapshot,route_type,
        count(*) AS documents,round(sum(document_amount),4) AS amount,
        count(*) FILTER(WHERE route_rows<>1) AS ambiguous_route,
        count(*) FILTER(WHERE resolved_ar_lines<>1) AS invalid_line_shape
        FROM invoice_shape GROUP BY document_date,resolved_line_account_code,
          resolved_line_function_snapshot,route_type) summary),'[]'::jsonb),
    'invalidSamples',COALESCE((SELECT jsonb_agg(row_to_json(sample)
      ORDER BY sample.document_no) FROM (SELECT * FROM invoice_shape
        WHERE route_rows<>1 OR resolved_ar_lines<>1 OR amount_customer_lines<>1
        ORDER BY document_no LIMIT 50) sample),'[]'::jsonb))
UNION ALL
SELECT 'backoffice_ar_kms_receipt_line_shape','INFO',0,
  jsonb_build_object(
    'summary',COALESCE((SELECT jsonb_agg(row_to_json(summary)
      ORDER BY summary.document_date,summary.account_code)
      FROM (SELECT document_date,resolved_line_account_code AS account_code,
        resolved_line_function_snapshot AS function_snapshot,count(*) AS documents,
        round(sum(document_amount),4) AS amount,
        count(*) FILTER(WHERE resolved_ar_lines<>1) AS invalid_line_shape
        FROM receipt_shape GROUP BY document_date,resolved_line_account_code,
          resolved_line_function_snapshot) summary),'[]'::jsonb),
    'invalidSamples',COALESCE((SELECT jsonb_agg(row_to_json(sample)
      ORDER BY sample.document_no) FROM (SELECT * FROM receipt_shape
        WHERE resolved_ar_lines<>1 ORDER BY document_no LIMIT 50) sample),'[]'::jsonb))
UNION ALL
SELECT 'backoffice_ar_kms_credit_note_line_shape','INFO',0,
  jsonb_build_object('rows',COALESCE((SELECT jsonb_agg(row_to_json(shape)
    ORDER BY shape.document_no) FROM credit_shape shape),'[]'::jsonb))
UNION ALL
SELECT 'backoffice_ar_kms_account_lineage_boundary','INFO',0,
  jsonb_build_object(
    'mutation','NONE',
    'expected','Posted document account lineage is unique even when COA function snapshot is NULL',
    'next','Use exact proven line identity for Task 2 schema design; do not mutate journals',
    'preserved',jsonb_build_array('Invoice','Receipt','Credit Note','Journal',
      'mapping history','Retail allocation','Backoffice allocation','all Companies'));
