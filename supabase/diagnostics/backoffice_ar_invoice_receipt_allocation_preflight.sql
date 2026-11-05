-- SELECT-only Fase A inventory for Backoffice AR Task 3.
-- This file does not install, alter, insert, update, delete, or deploy anything.
WITH required(version) AS (VALUES
  ('20260909161000'),('20260911160000'),('20260911163000'),
  ('20261006140000'),('20261105100000')
), dependency AS (
  SELECT array_agg(required.version ORDER BY required.version)
      FILTER(WHERE migration.version IS NULL) AS missing,
    array_agg(required.version ORDER BY required.version)
      FILTER(WHERE migration.version IS NOT NULL) AS installed
  FROM required
  LEFT JOIN private.kgs_schema_migrations migration
    ON migration.version=required.version
), state AS (
  SELECT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20261105100000') AS foundation_ledger,
    EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20261105110000') AS task3_ledger,
    to_regclass('public.ar_open_item_registry') IS NOT NULL AS registry,
    to_regclass('public.ar_open_item_operations') IS NOT NULL AS operations,
    to_regclass('public.ar_open_item_allocations') IS NOT NULL AS allocations,
    to_regclass('public.ar_open_item_audit') IS NOT NULL AS audit,
    to_regprocedure('public.get_finance_ar_open_items(uuid,boolean)') IS NOT NULL AS read_rpc
), runtime AS (
  SELECT
    to_regprocedure('public.post_backoffice_sales_invoice(uuid,bigint,uuid)') AS invoice_post,
    to_regprocedure('public.save_customer_receipt_allocated_draft(uuid,bigint,uuid,date,uuid,text,text,text,numeric,jsonb)') AS receipt_save,
    to_regprocedure('public.post_customer_receipt_allocated(uuid,bigint,uuid)') AS receipt_post,
    to_regprocedure('public.post_customer_receipt_unified(uuid,bigint,uuid)') AS receipt_unified,
    to_regprocedure('private.trg_ar_open_item_validate_allocation()') AS allocation_guard,
    to_regprocedure('public.get_finance_ar_open_items(uuid,boolean)') AS read_rpc
), runtime_definition AS (
  SELECT md5(pg_get_functiondef(invoice_post)) AS invoice_post_md5,
    md5(pg_get_functiondef(receipt_save)) AS receipt_save_md5,
    md5(pg_get_functiondef(receipt_post)) AS receipt_post_md5,
    md5(pg_get_functiondef(receipt_unified)) AS receipt_unified_md5,
    md5(pg_get_functiondef(allocation_guard)) AS allocation_guard_md5,
    md5(pg_get_functiondef(read_rpc)) AS read_rpc_md5,
    pg_get_functiondef(receipt_save) ILIKE '%p_received_amount%'
      AND pg_get_functiondef(receipt_save) ILIKE '%CUSTOMER_RECEIPT_AMOUNT_MISMATCH%'
      AS receipt_save_amount_guard,
    pg_get_functiondef(receipt_post) ILIKE '%FOR UPDATE%'
      AND pg_get_functiondef(receipt_post) ILIKE '%CUSTOMER_RECEIPT_OUTSTANDING_CHANGED%'
      AS receipt_post_concurrency_guard,
    pg_get_functiondef(receipt_unified) ILIKE '%post_customer_receipt_allocated%'
      AND pg_get_functiondef(receipt_unified) ILIKE '%post_customer_receipt_with_disposition%'
      AS unified_partition,
    pg_get_functiondef(allocation_guard) ILIKE '%BACKFILL_RECEIPT%'
      AND pg_get_functiondef(allocation_guard) NOT ILIKE '%POST_RECEIPT%'
      AS backfill_only_allocation_guard
  FROM runtime
), foundation_constraints AS (
  SELECT
    (SELECT pg_get_constraintdef(constraint_row.oid)
      FROM pg_constraint constraint_row
      WHERE constraint_row.conrelid='public.ar_open_item_operations'::regclass
        AND constraint_row.conname='ar_open_item_operations_shape') AS operation_shape,
    (SELECT pg_get_constraintdef(constraint_row.oid)
      FROM pg_constraint constraint_row
      WHERE constraint_row.conrelid='public.ar_open_item_allocations'::regclass
        AND constraint_row.conname='ar_open_item_allocations_shape') AS allocation_shape,
    (SELECT pg_get_constraintdef(constraint_row.oid)
      FROM pg_constraint constraint_row
      WHERE constraint_row.conrelid='public.customer_receipt_documents'::regclass
        AND constraint_row.conname='customer_receipt_amount_disposition_check')
      AS receipt_amount_shape
), invoice_source AS (
  SELECT invoice.company_id,invoice.id,invoice.invoice_no,invoice.customer_id,
    invoice.grand_total,invoice.financial_event_id,
    EXISTS(SELECT 1 FROM public.ar_open_item_registry item
      WHERE item.company_id=invoice.company_id AND item.scope_kind='BACKOFFICE'
        AND item.item_kind='INVOICE' AND item.source_id=invoice.id) AS registered,
    (SELECT count(*) FROM public.finance_journals journal
      JOIN public.finance_journal_lines line ON line.company_id=journal.company_id
        AND line.journal_id=journal.id
      WHERE journal.company_id=invoice.company_id
        AND journal.financial_event_id=invoice.financial_event_id
        AND journal.status='POSTED' AND line.customer_id=invoice.customer_id
        AND line.debit=invoice.grand_total AND line.credit=0) AS candidate_ar_lines
  FROM public.backoffice_sales_invoices invoice
  JOIN public.company_sales_process_settings setting
    ON setting.company_id=invoice.company_id
    AND setting.active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE'
  WHERE invoice.status='POSTED' AND invoice.grand_total>0
), receipt_source AS (
  SELECT receipt.company_id,receipt.id,receipt.receipt_no,receipt.customer_id,
    receipt.total_amount,receipt.received_amount,receipt.unapplied_amount,
    receipt.unapplied_disposition,receipt.financial_event_id,
    COALESCE(backoffice.amount,0)::numeric(24,4) AS backoffice_slice,
    COALESCE(retail.amount,0)::numeric(24,4) AS retail_slice,
    EXISTS(SELECT 1 FROM public.ar_open_item_registry item
      WHERE item.company_id=receipt.company_id AND item.scope_kind='BACKOFFICE'
        AND item.item_kind='RECEIPT' AND item.source_id=receipt.id) AS registered,
    (SELECT count(*) FROM public.finance_journals journal
      JOIN public.finance_journal_lines line ON line.company_id=journal.company_id
        AND line.journal_id=journal.id
      WHERE journal.company_id=receipt.company_id
        AND journal.financial_event_id=receipt.financial_event_id
        AND journal.status='POSTED'
        AND line.account_id=receipt.receivable_account_id_snapshot
        AND line.customer_id=receipt.customer_id AND line.debit=0
        AND line.credit=receipt.total_amount) AS exact_ar_lines
  FROM public.customer_receipt_documents receipt
  JOIN public.company_sales_process_settings setting
    ON setting.company_id=receipt.company_id
    AND setting.active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE'
  LEFT JOIN LATERAL(SELECT sum(allocation.allocated_amount) amount
    FROM public.customer_receipt_backoffice_invoice_allocations allocation
    WHERE allocation.company_id=receipt.company_id
      AND allocation.document_id=receipt.id) backoffice ON true
  LEFT JOIN LATERAL(SELECT sum(allocation.allocated_amount) amount
    FROM public.customer_receipt_allocations allocation
    WHERE allocation.company_id=receipt.company_id
      AND allocation.document_id=receipt.id) retail ON true
  WHERE receipt.status='POSTED' AND COALESCE(backoffice.amount,0)>0
), draft_receipt AS (
  SELECT receipt.company_id,receipt.id,receipt.receipt_no,receipt.customer_id,
    receipt.total_amount,receipt.received_amount,receipt.unapplied_amount,
    receipt.unapplied_disposition,
    COALESCE(backoffice.amount,0)::numeric(24,4) AS backoffice_slice,
    COALESCE(retail.amount,0)::numeric(24,4) AS retail_slice
  FROM public.customer_receipt_documents receipt
  JOIN public.company_sales_process_settings setting
    ON setting.company_id=receipt.company_id
    AND setting.active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE'
  LEFT JOIN LATERAL(SELECT sum(allocation.allocated_amount) amount
    FROM public.customer_receipt_backoffice_invoice_allocations allocation
    WHERE allocation.company_id=receipt.company_id
      AND allocation.document_id=receipt.id) backoffice ON true
  LEFT JOIN LATERAL(SELECT sum(allocation.allocated_amount) amount
    FROM public.customer_receipt_allocations allocation
    WHERE allocation.company_id=receipt.company_id
      AND allocation.document_id=receipt.id) retail ON true
  WHERE receipt.status='DRAFT'
), cutover_delta AS (
  SELECT
    (SELECT count(*) FROM invoice_source) AS posted_invoices,
    (SELECT count(*) FROM invoice_source WHERE NOT registered) AS missing_invoice_items,
    (SELECT count(*) FROM invoice_source
      WHERE NOT registered AND candidate_ar_lines<>1) AS invalid_missing_invoice_lines,
    (SELECT count(*) FROM receipt_source) AS posted_backoffice_receipts,
    (SELECT count(*) FROM receipt_source WHERE NOT registered) AS missing_receipt_items,
    (SELECT count(*) FROM receipt_source
      WHERE NOT registered AND exact_ar_lines<>1) AS invalid_missing_receipt_lines,
    (SELECT count(*) FROM receipt_source
      WHERE backoffice_slice+retail_slice<>total_amount) AS invalid_posted_slice_totals,
    (SELECT count(*) FROM receipt_source
      WHERE backoffice_slice>0 AND retail_slice>0) AS mixed_posted_receipts
), draft_inventory AS (
  SELECT count(*) AS drafts,
    count(*) FILTER(WHERE unapplied_disposition='NONE') AS allocated_mode,
    count(*) FILTER(WHERE unapplied_disposition='CUSTOMER_BALANCE') AS balance_mode,
    count(*) FILTER(WHERE backoffice_slice>0) AS with_backoffice,
    count(*) FILTER(WHERE retail_slice>0 AND backoffice_slice>0) AS mixed,
    count(*) FILTER(WHERE unapplied_disposition='NONE'
      AND received_amount<>backoffice_slice+retail_slice) AS invalid_amount_shape,
    count(*) FILTER(WHERE unapplied_disposition='NONE'
      AND received_amount>backoffice_slice+retail_slice) AS residual_candidates
  FROM draft_receipt
), privilege_state AS (
  SELECT has_function_privilege('authenticated',
      'public.get_finance_ar_open_items(uuid,boolean)','EXECUTE') AS rpc_execute,
    has_table_privilege('authenticated','public.ar_open_item_registry','SELECT')
      AS registry_select,
    has_table_privilege('authenticated','public.ar_open_item_operations','SELECT')
      AS operations_select,
    has_table_privilege('authenticated','public.ar_open_item_allocations','SELECT')
      AS allocations_select,
    has_table_privilege('authenticated','public.ar_open_item_audit','SELECT')
      AS audit_select
), queue_state AS (
  SELECT
    (SELECT count(*) FROM public.finance_posting_queue_runs
      WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) AS active_finance_queue,
    (SELECT count(*) FROM public.pos_offline_sale_submissions
      WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) AS nonterminal_offline
)
SELECT 'backoffice_ar_invoice_receipt_runtime_preflight_dependency_ledger' AS check_name,
  CASE WHEN missing IS NULL THEN 'PASS' ELSE 'BLOCKER' END AS status,
  COALESCE(cardinality(missing),0)::bigint AS violation_rows,
  jsonb_build_object('missing',COALESCE(to_jsonb(missing),'[]'::jsonb),
    'installed',COALESCE(to_jsonb(installed),'[]'::jsonb)) AS details
FROM dependency
UNION ALL
SELECT 'backoffice_ar_invoice_receipt_runtime_preflight_installation_state',
  CASE WHEN foundation_ledger AND registry AND operations AND allocations
      AND audit AND read_rpc AND NOT task3_ledger THEN 'PASS' ELSE 'BLOCKER' END,
  CASE WHEN foundation_ledger AND registry AND operations AND allocations
      AND audit AND read_rpc AND NOT task3_ledger THEN 0 ELSE 1 END,
  jsonb_build_object('classification',CASE
    WHEN foundation_ledger AND registry AND operations AND allocations
      AND audit AND read_rpc AND NOT task3_ledger THEN 'FOUNDATION_INSTALLED_TASK3_NOT_INSTALLED'
    WHEN task3_ledger THEN 'TASK3_ALREADY_INSTALLED'
    ELSE 'PARTIAL/INCONSISTENT' END,'foundationLedger',foundation_ledger,
    'task3Ledger',task3_ledger,'registry',registry,'operations',operations,
    'allocations',allocations,'audit',audit,'readRpc',read_rpc)
FROM state
UNION ALL
SELECT 'backoffice_ar_invoice_receipt_runtime_preflight_active_anchors',
  CASE WHEN invoice_post IS NOT NULL AND receipt_save IS NOT NULL
      AND receipt_post IS NOT NULL AND receipt_unified IS NOT NULL
      AND allocation_guard IS NOT NULL AND read_rpc IS NOT NULL
      AND receipt_save_amount_guard AND receipt_post_concurrency_guard
      AND unified_partition AND backfill_only_allocation_guard
    THEN 'PASS' ELSE 'BLOCKER' END,
  CASE WHEN invoice_post IS NOT NULL AND receipt_save IS NOT NULL
      AND receipt_post IS NOT NULL AND receipt_unified IS NOT NULL
      AND allocation_guard IS NOT NULL AND read_rpc IS NOT NULL
      AND receipt_save_amount_guard AND receipt_post_concurrency_guard
      AND unified_partition AND backfill_only_allocation_guard
    THEN 0 ELSE 1 END,
  jsonb_build_object('invoicePostMd5',invoice_post_md5,
    'receiptSaveMd5',receipt_save_md5,'receiptPostMd5',receipt_post_md5,
    'receiptUnifiedMd5',receipt_unified_md5,
    'allocationGuardMd5',allocation_guard_md5,'readRpcMd5',read_rpc_md5,
    'receiptSaveAmountGuard',receipt_save_amount_guard,
    'receiptPostConcurrencyGuard',receipt_post_concurrency_guard,
    'unifiedPartition',unified_partition,
    'backfillOnlyAllocationGuard',backfill_only_allocation_guard)
FROM runtime CROSS JOIN runtime_definition
UNION ALL
SELECT 'backoffice_ar_invoice_receipt_runtime_preflight_constraint_contract','INFO',0,
  jsonb_build_object('operationShape',operation_shape,
    'allocationShape',allocation_shape,'receiptAmountShape',receipt_amount_shape)
FROM foundation_constraints
UNION ALL
SELECT 'backoffice_ar_invoice_receipt_runtime_preflight_cutover_delta',
  CASE WHEN invalid_missing_invoice_lines=0 AND invalid_missing_receipt_lines=0
      AND invalid_posted_slice_totals=0 THEN 'PASS' ELSE 'BLOCKER' END,
  invalid_missing_invoice_lines+invalid_missing_receipt_lines+invalid_posted_slice_totals,
  jsonb_build_object('postedInvoices',posted_invoices,
    'missingInvoiceItems',missing_invoice_items,
    'invalidMissingInvoiceLines',invalid_missing_invoice_lines,
    'postedBackofficeReceipts',posted_backoffice_receipts,
    'missingReceiptItems',missing_receipt_items,
    'invalidMissingReceiptLines',invalid_missing_receipt_lines,
    'invalidPostedSliceTotals',invalid_posted_slice_totals,
    'mixedPostedReceipts',mixed_posted_receipts)
FROM cutover_delta
UNION ALL
SELECT 'backoffice_ar_invoice_receipt_runtime_preflight_draft_inventory',
  CASE WHEN invalid_amount_shape=0 AND residual_candidates=0 THEN 'PASS' ELSE 'BLOCKER' END,
  invalid_amount_shape+residual_candidates,
  jsonb_build_object('drafts',drafts,'allocatedMode',allocated_mode,
    'customerBalanceMode',balance_mode,'withBackoffice',with_backoffice,
    'mixed',mixed,'invalidAmountShape',invalid_amount_shape,
    'residualCandidates',residual_candidates,
    'meaning','Existing Drafts must retain their current immutable amount semantics')
FROM draft_inventory
UNION ALL
SELECT 'backoffice_ar_invoice_receipt_runtime_preflight_privilege_boundary',
  CASE WHEN rpc_execute AND NOT registry_select AND NOT operations_select
      AND NOT allocations_select AND NOT audit_select THEN 'PASS' ELSE 'BLOCKER' END,
  CASE WHEN rpc_execute AND NOT registry_select AND NOT operations_select
      AND NOT allocations_select AND NOT audit_select THEN 0 ELSE 1 END,
  jsonb_build_object('rpcExecute',rpc_execute,'registryDirectSelect',registry_select,
    'operationsDirectSelect',operations_select,
    'allocationsDirectSelect',allocations_select,'auditDirectSelect',audit_select)
FROM privilege_state
UNION ALL
SELECT 'backoffice_ar_invoice_receipt_runtime_preflight_runtime_boundary',
  CASE WHEN active_finance_queue=0 AND nonterminal_offline=0
    THEN 'PASS' ELSE 'BLOCKER' END,
  active_finance_queue+nonterminal_offline,
  jsonb_build_object('activeFinanceQueue',active_finance_queue,
    'nonterminalOffline',nonterminal_offline)
FROM queue_state
UNION ALL
SELECT 'backoffice_ar_invoice_receipt_runtime_preflight_business_boundary','INFO',0,
  jsonb_build_object('mutation','NONE',
    'planned',jsonb_build_array('future Backoffice Invoice registration',
      'future Backoffice Receipt credit registration','manual partial/full allocation',
      'customer-scoped residual open credit','minimal authenticated read-only panel'),
    'preserved',jsonb_build_array('one canonical Cash/Bank-to-AR Journal',
      'legacy allocation compatibility','explicit Customer Balance advance',
      'POS Retail','Backoffice Return/Credit Note','Stock/Reservation/FIFO/HPP',
      'historical Posted documents and Journals'));
