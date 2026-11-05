-- SELECT-only preflight for 20261105100000_backoffice_ar_open_item_foundation.sql.
-- Expected state: NOT_INSTALLED. Run before the migration.
WITH required(version) AS (VALUES
  ('20260810180000'),('20260812140000'),('20260827100000'),
  ('20260909156000'),('20260909162000'),('20260911160000'),('20260917130000'),
  ('20260918150000'),('20260928110000'),('20261006140000')
),dependency AS (
  SELECT array_agg(required.version ORDER BY required.version)
    FILTER(WHERE migration.version IS NULL) AS missing,
    array_agg(required.version ORDER BY required.version)
    FILTER(WHERE migration.version IS NOT NULL) AS installed
  FROM required LEFT JOIN private.kgs_schema_migrations migration
    ON migration.version=required.version
),state AS (
  SELECT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20261105100000') AS ledger,
    to_regclass('public.ar_open_item_registry') IS NOT NULL AS registry,
    to_regclass('public.ar_open_item_operations') IS NOT NULL AS operations,
    to_regclass('public.ar_open_item_allocations') IS NOT NULL AS allocations,
    to_regclass('public.ar_open_item_audit') IS NOT NULL AS audit,
    to_regprocedure('public.get_finance_ar_open_items(uuid,boolean)') IS NOT NULL AS rpc
),invoice_line_shape AS (
  SELECT invoice.id,
    (SELECT count(*) FROM public.finance_journals journal
      JOIN public.finance_journal_lines line ON line.company_id=journal.company_id
        AND line.journal_id=journal.id
      WHERE journal.company_id=invoice.company_id
        AND journal.financial_event_id=invoice.financial_event_id
        AND journal.status='POSTED' AND line.account_id=routed.account_id
        AND line.customer_id=invoice.customer_id AND line.debit=invoice.grand_total
        AND line.credit=0) AS exact_lines
  FROM public.backoffice_sales_invoices invoice
  JOIN public.company_sales_process_settings setting ON setting.company_id=invoice.company_id
    AND setting.active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE'
  JOIN public.financial_events event ON event.company_id=invoice.company_id
    AND event.id=invoice.financial_event_id
  LEFT JOIN LATERAL (
    SELECT candidate.account_id
    FROM (
      SELECT rule.account_id,rule.rule_version AS version
      FROM public.transaction_account_rules rule
      WHERE rule.company_id=event.company_id
        AND rule.transaction_category_id=event.transaction_category_id
        AND rule.system_key=event.system_event_key
        AND rule.account_function_key='CUSTOMER_RECEIVABLE'
        AND rule.status='ACTIVE' AND rule.effective_from<=event.event_date
        AND (rule.effective_to IS NULL OR rule.effective_to>event.event_date)
      UNION ALL
      SELECT fallback.account_id,fallback.fallback_version
      FROM public.company_account_function_fallbacks fallback
      WHERE fallback.company_id=event.company_id
        AND fallback.account_function_key='CUSTOMER_RECEIVABLE'
        AND fallback.status='ACTIVE' AND fallback.effective_from<=event.event_date
        AND (fallback.effective_to IS NULL OR fallback.effective_to>event.event_date)
        AND NOT EXISTS(SELECT 1 FROM public.transaction_account_rules rule
          WHERE rule.company_id=event.company_id
            AND rule.transaction_category_id=event.transaction_category_id
            AND rule.system_key=event.system_event_key
            AND rule.account_function_key='CUSTOMER_RECEIVABLE'
            AND rule.status='ACTIVE' AND rule.effective_from<=event.event_date
            AND (rule.effective_to IS NULL OR rule.effective_to>event.event_date))
    ) candidate ORDER BY candidate.version DESC,candidate.account_id LIMIT 1
  ) routed ON true
  WHERE invoice.status='POSTED' AND invoice.grand_total>0
),receipt_line_shape AS (
  SELECT receipt.id,(SELECT count(*) FROM public.finance_journals journal
    JOIN public.finance_journal_lines line ON line.company_id=journal.company_id
      AND line.journal_id=journal.id
    WHERE journal.company_id=receipt.company_id
      AND journal.financial_event_id=receipt.financial_event_id
      AND journal.status='POSTED'
      AND line.account_id=receipt.receivable_account_id_snapshot
      AND line.customer_id=receipt.customer_id AND line.debit=0
      AND line.credit=receipt.total_amount) AS exact_lines
  FROM public.customer_receipt_documents receipt
  JOIN public.company_sales_process_settings setting ON setting.company_id=receipt.company_id
    AND setting.active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE'
  WHERE receipt.status='POSTED' AND EXISTS(
    SELECT 1 FROM public.customer_receipt_backoffice_invoice_allocations allocation
    WHERE allocation.company_id=receipt.company_id AND allocation.document_id=receipt.id)
),credit_line_shape AS (
  SELECT note.id,(SELECT count(*) FROM public.finance_journals journal
    JOIN public.finance_journal_lines line ON line.company_id=journal.company_id
      AND line.journal_id=journal.id
    WHERE journal.company_id=note.company_id
      AND journal.financial_event_id=note.financial_event_id AND journal.status='POSTED'
      AND line.customer_id=note.customer_id AND line.debit=0
      AND line.credit=note.ar_reduction_amount) AS exact_lines
  FROM public.backoffice_sales_credit_notes note
  JOIN public.company_sales_process_settings setting ON setting.company_id=note.company_id
    AND setting.active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE'
  WHERE note.status='POSTED' AND note.source_kind='BACKOFFICE'
    AND note.ar_reduction_amount>0
),correction_line_shape AS (
  SELECT correction.id,(SELECT count(*) FROM public.finance_journals journal
    JOIN public.finance_journal_lines line ON line.company_id=journal.company_id
      AND line.journal_id=journal.id
    WHERE journal.company_id=correction.company_id
      AND journal.financial_event_id=correction.financial_event_id
      AND journal.status='POSTED' AND line.customer_id=invoice.customer_id
      AND ((correction.ar_adjustment_amount>0
          AND line.debit=correction.ar_adjustment_amount AND line.credit=0)
        OR (correction.ar_adjustment_amount<0
          AND line.credit=-correction.ar_adjustment_amount AND line.debit=0))) AS exact_lines
  FROM public.backoffice_sales_invoice_price_corrections correction
  JOIN public.company_sales_process_settings setting
    ON setting.company_id=correction.company_id
    AND setting.active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE'
  JOIN public.backoffice_sales_invoices invoice ON invoice.company_id=correction.company_id
    AND invoice.id=correction.source_invoice_id
  WHERE correction.status='POSTED' AND correction.ar_adjustment_amount<>0
),source_line_contract AS (
  SELECT (SELECT count(*) FROM invoice_line_shape WHERE exact_lines<>1) AS invalid_invoices,
    (SELECT count(*) FROM receipt_line_shape WHERE exact_lines<>1) AS invalid_receipts,
    (SELECT count(*) FROM credit_line_shape WHERE exact_lines<>1) AS invalid_credit_notes,
    (SELECT count(*) FROM correction_line_shape WHERE exact_lines<>1) AS invalid_corrections
),source_inventory AS (
  SELECT
    (SELECT count(*) FROM public.backoffice_sales_invoices
      WHERE status='POSTED' AND grand_total>0 AND EXISTS(
        SELECT 1 FROM public.company_sales_process_settings setting
        WHERE setting.company_id=backoffice_sales_invoices.company_id
          AND setting.active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE')) AS invoices,
    (SELECT count(DISTINCT receipt.id)
      FROM public.customer_receipt_documents receipt
      JOIN public.company_sales_process_settings setting ON setting.company_id=receipt.company_id
        AND setting.active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE'
      JOIN public.customer_receipt_backoffice_invoice_allocations allocation
        ON allocation.company_id=receipt.company_id AND allocation.document_id=receipt.id
      WHERE receipt.status='POSTED') AS receipts,
    (SELECT count(*) FROM public.customer_receipt_backoffice_invoice_allocations allocation
      JOIN public.customer_receipt_documents receipt ON receipt.company_id=allocation.company_id
        AND receipt.id=allocation.document_id AND receipt.status='POSTED'
      JOIN public.company_sales_process_settings setting ON setting.company_id=receipt.company_id
        AND setting.active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE') AS receipt_allocations,
    (SELECT count(*) FROM public.backoffice_sales_credit_notes
      WHERE status='POSTED' AND source_kind='BACKOFFICE' AND ar_reduction_amount>0
        AND EXISTS(SELECT 1 FROM public.company_sales_process_settings setting
          WHERE setting.company_id=backoffice_sales_credit_notes.company_id
            AND setting.active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE')) AS credit_notes,
    (SELECT count(*) FROM public.backoffice_sales_invoice_price_corrections
      WHERE status='POSTED' AND ar_adjustment_amount<>0
        AND EXISTS(SELECT 1 FROM public.company_sales_process_settings setting
          WHERE setting.company_id=backoffice_sales_invoice_price_corrections.company_id
            AND setting.active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE')) AS price_corrections,
    (SELECT count(*) FROM private.backoffice_invoice_revisions revision
      WHERE (revision.payable_delta<>0
          OR revision.prior_customer_id<>revision.new_customer_id)
        AND EXISTS(SELECT 1 FROM public.company_sales_process_settings setting
          WHERE setting.company_id=revision.company_id
            AND setting.active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE')) AS nonneutral_revisions,
    (SELECT count(*) FROM public.customer_receipt_documents receipt
      JOIN public.company_sales_process_settings setting ON setting.company_id=receipt.company_id
        AND setting.active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE'
      JOIN LATERAL(SELECT COALESCE(sum(allocation.allocated_amount),0) amount
        FROM public.customer_receipt_backoffice_invoice_allocations allocation
        WHERE allocation.company_id=receipt.company_id
          AND allocation.document_id=receipt.id) backoffice ON true
      WHERE receipt.status='POSTED' AND backoffice.amount>receipt.total_amount) AS invalid_slices,
    (SELECT count(*) FROM public.customer_receipt_documents receipt
      JOIN public.company_sales_process_settings setting ON setting.company_id=receipt.company_id
        AND setting.active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE'
      WHERE receipt.status='POSTED'
        AND EXISTS(SELECT 1 FROM public.customer_receipt_allocations retail
          WHERE retail.company_id=receipt.company_id AND retail.document_id=receipt.id)
        AND EXISTS(SELECT 1 FROM public.customer_receipt_backoffice_invoice_allocations backoffice
          WHERE backoffice.company_id=receipt.company_id AND backoffice.document_id=receipt.id)) AS mixed_receipts
),queue_state AS (
  SELECT
    (SELECT count(*) FROM public.finance_posting_queue_runs
      WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) AS active_finance_queue,
    (SELECT count(*) FROM public.pos_offline_sale_submissions
      WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) AS nonterminal_offline
)
SELECT 'backoffice_ar_open_item_foundation_preflight_dependency_ledger' AS check_name,
  CASE WHEN missing IS NULL THEN 'PASS' ELSE 'BLOCKER' END AS status,
  COALESCE(cardinality(missing),0)::bigint AS violation_rows,
  jsonb_build_object('missing',COALESCE(to_jsonb(missing),'[]'::jsonb),
    'installed',COALESCE(to_jsonb(installed),'[]'::jsonb)) AS details
FROM dependency
UNION ALL
SELECT 'backoffice_ar_open_item_foundation_preflight_installation_state',
  CASE WHEN NOT ledger AND NOT registry AND NOT operations AND NOT allocations
      AND NOT audit AND NOT rpc THEN 'PASS' ELSE 'BLOCKER' END,
  (ledger::int+registry::int+operations::int+allocations::int+audit::int+rpc::int)::bigint,
  jsonb_build_object('classification',CASE
    WHEN NOT ledger AND NOT registry AND NOT operations AND NOT allocations
      AND NOT audit AND NOT rpc THEN 'NOT_INSTALLED'
    WHEN ledger AND registry AND operations AND allocations AND audit AND rpc
      THEN 'INSTALLED_CONSISTENT' ELSE 'PARTIAL/INCONSISTENT' END,
    'ledger',ledger,'registry',registry,'operations',operations,
    'allocations',allocations,'audit',audit,'rpc',rpc)
FROM state
UNION ALL
SELECT 'backoffice_ar_open_item_foundation_preflight_source_inventory','INFO',0,
  jsonb_build_object('invoices',invoices,'receipts',receipts,
    'receiptAllocations',receipt_allocations,'nativeCreditNotes',credit_notes,
    'priceCorrections',price_corrections,'mixedReceipts',mixed_receipts)
FROM source_inventory
UNION ALL
SELECT 'backoffice_ar_open_item_foundation_preflight_journal_line_contract',
  CASE WHEN invalid_invoices=0 AND invalid_receipts=0
      AND invalid_credit_notes=0 AND invalid_corrections=0 THEN 'PASS' ELSE 'BLOCKER' END,
  invalid_invoices+invalid_receipts+invalid_credit_notes+invalid_corrections,
  jsonb_build_object('invalidInvoices',invalid_invoices,'invalidReceipts',invalid_receipts,
    'invalidCreditNotes',invalid_credit_notes,'invalidPriceCorrections',invalid_corrections,
    'rule','Every source must resolve to exactly one canonical Posted AR Journal line')
FROM source_line_contract
UNION ALL
SELECT 'backoffice_ar_open_item_foundation_preflight_revision_boundary',
  CASE WHEN nonneutral_revisions=0 THEN 'PASS' ELSE 'BLOCKER' END,
  nonneutral_revisions,jsonb_build_object('nonNeutralRevisions',nonneutral_revisions,
    'meaning','Task 2 does not invent attribution for payable/customer-changing revisions')
FROM source_inventory
UNION ALL
SELECT 'backoffice_ar_open_item_foundation_preflight_receipt_slice_contract',
  CASE WHEN invalid_slices=0 THEN 'PASS' ELSE 'BLOCKER' END,invalid_slices,
  jsonb_build_object('invalidSlices',invalid_slices,'mixedReceipts',mixed_receipts,
    'rule','Backoffice child allocation sum may not exceed the canonical Receipt total')
FROM source_inventory
UNION ALL
SELECT 'backoffice_ar_open_item_foundation_preflight_runtime_boundary',
  CASE WHEN active_finance_queue=0 AND nonterminal_offline=0 THEN 'PASS' ELSE 'BLOCKER' END,
  active_finance_queue+nonterminal_offline,
  jsonb_build_object('activeFinanceQueue',active_finance_queue,
    'nonterminalOffline',nonterminal_offline)
FROM queue_state
UNION ALL
SELECT 'backoffice_ar_open_item_foundation_preflight_business_boundary','INFO',0,
  jsonb_build_object('mutation','NONE','next','Run guarded forward migration only when mandatory rows PASS',
    'included',jsonb_build_array('Backoffice Invoice debit registry','Backoffice Receipt slices',
      'native Backoffice Credit Note AR credit','price-correction AR item',
      'append-only allocation/audit ledger','read-only Finance RPC'),
    'preserved',jsonb_build_array('Posted Journals','Return/Refund posting','POS Retail',
      'Customer Balance','Stock/FIFO','retained-Retail Credit Note','Backoffice posting runtime'));
