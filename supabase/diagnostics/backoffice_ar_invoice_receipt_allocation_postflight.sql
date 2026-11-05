-- SELECT-only postflight for Backoffice AR Task 3.
WITH ledger AS (
  SELECT count(*)::bigint AS rows FROM private.kgs_schema_migrations
  WHERE version='20261105110000'
),runtime AS (
  SELECT
    to_regprocedure('public.save_customer_receipt_open_credit_draft(uuid,bigint,uuid,date,uuid,text,text,text,numeric,jsonb)') save_rpc,
    to_regprocedure('public.post_customer_receipt_allocated(uuid,bigint,uuid)') allocated_rpc,
    to_regprocedure('public.post_customer_receipt_unified(uuid,bigint,uuid)') unified_rpc,
    to_regprocedure('public.post_backoffice_sales_invoice(uuid,bigint,uuid)') invoice_rpc,
    to_regprocedure('private.ar3_register_backoffice_invoice_open_item(uuid,uuid,uuid)') invoice_register,
    to_regprocedure('private.ar3_register_backoffice_receipt_open_item(uuid,uuid,uuid)') receipt_register,
    to_regprocedure('public.register_backoffice_sales_invoice_payment(uuid,uuid,date,uuid,numeric,text,text,text)') invoice_payment_rpc
),source_counts AS (
  SELECT
    (SELECT count(*) FROM public.backoffice_sales_invoices invoice
      JOIN public.company_sales_process_settings setting
        ON setting.company_id=invoice.company_id
       AND setting.active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE'
      WHERE invoice.status='POSTED' AND invoice.grand_total>0)::bigint invoices,
    (SELECT count(DISTINCT (receipt.company_id,receipt.id))
      FROM public.customer_receipt_documents receipt
      JOIN public.company_sales_process_settings setting
        ON setting.company_id=receipt.company_id
       AND setting.active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE'
      JOIN public.customer_receipt_backoffice_invoice_allocations allocation
        ON allocation.company_id=receipt.company_id AND allocation.document_id=receipt.id
      WHERE receipt.status='POSTED')::bigint receipts,
    (SELECT count(*) FROM public.customer_receipt_backoffice_invoice_allocations allocation
      JOIN public.customer_receipt_documents receipt
        ON receipt.company_id=allocation.company_id AND receipt.id=allocation.document_id
       AND receipt.status='POSTED')::bigint allocations
),registry_counts AS (
  SELECT
    count(*) FILTER(WHERE item_kind='INVOICE')::bigint invoices,
    count(*) FILTER(WHERE item_kind='RECEIPT')::bigint receipts
  FROM public.ar_open_item_registry WHERE scope_kind='BACKOFFICE'
),allocation_count AS (
  SELECT count(*)::bigint rows FROM public.ar_open_item_allocations allocation
  WHERE allocation.source_kind='RECEIPT_ALLOCATION'
),invalid AS (
  SELECT
    (SELECT count(*) FROM public.backoffice_sales_invoices invoice
      JOIN public.company_sales_process_settings setting
        ON setting.company_id=invoice.company_id
       AND setting.active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE'
      LEFT JOIN public.ar_open_item_registry item
        ON item.company_id=invoice.company_id AND item.scope_kind='BACKOFFICE'
       AND item.item_kind='INVOICE' AND item.source_id=invoice.id
      WHERE invoice.status='POSTED' AND invoice.grand_total>0
        AND (item.id IS NULL OR item.customer_id<>invoice.customer_id
          OR item.direction<>'DEBIT' OR item.original_amount<>invoice.grand_total))::bigint invoices,
    (SELECT count(*) FROM public.customer_receipt_backoffice_invoice_allocations source
      JOIN public.customer_receipt_documents receipt
        ON receipt.company_id=source.company_id AND receipt.id=source.document_id
       AND receipt.status='POSTED'
      LEFT JOIN public.ar_open_item_allocations target
        ON target.company_id=source.company_id
       AND target.source_kind='RECEIPT_ALLOCATION' AND target.source_id=source.id
      WHERE target.id IS NULL OR target.allocated_amount<>source.allocated_amount)::bigint allocations,
    (SELECT count(*) FROM public.ar_open_item_registry item
      LEFT JOIN LATERAL(SELECT COALESCE(sum(allocation.allocated_amount),0) used
        FROM public.ar_open_item_allocations allocation
        WHERE allocation.company_id=item.company_id
          AND (allocation.debit_item_id=item.id OR allocation.credit_item_id=item.id)) totals ON true
      WHERE totals.used>item.original_amount)::bigint overallocated
)
SELECT check_name,status,violation_rows,details FROM (
  SELECT 1 AS seq,'backoffice_ar_invoice_receipt_runtime_postflight_migration_ledger' check_name,
    CASE WHEN ledger.rows=1 THEN 'PASS' ELSE 'FAIL' END status,
    CASE WHEN ledger.rows=1 THEN 0 ELSE 1 END::bigint violation_rows,
    jsonb_build_object('ledgerRows',ledger.rows) details FROM ledger
  UNION ALL
  SELECT 2,'backoffice_ar_invoice_receipt_runtime_postflight_runtime_contract',
    CASE WHEN save_rpc IS NOT NULL AND allocated_rpc IS NOT NULL AND unified_rpc IS NOT NULL
      AND invoice_rpc IS NOT NULL AND invoice_register IS NOT NULL
      AND receipt_register IS NOT NULL AND invoice_payment_rpc IS NOT NULL
      AND position('public.post_customer_receipt_allocated' in pg_get_functiondef(invoice_payment_rpc))>0
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN save_rpc IS NOT NULL AND allocated_rpc IS NOT NULL AND unified_rpc IS NOT NULL
      AND invoice_rpc IS NOT NULL AND invoice_register IS NOT NULL
      AND receipt_register IS NOT NULL AND invoice_payment_rpc IS NOT NULL
      AND position('public.post_customer_receipt_allocated' in pg_get_functiondef(invoice_payment_rpc))>0
      THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('saveOpenCredit',save_rpc IS NOT NULL,
      'invoiceWrapper',invoice_rpc IS NOT NULL,'allocatedWrapper',allocated_rpc IS NOT NULL,
      'unifiedWrapper',unified_rpc IS NOT NULL,'invoiceRegistration',invoice_register IS NOT NULL,
      'receiptRegistration',receipt_register IS NOT NULL,
      'invoicePaymentRebound',invoice_payment_rpc IS NOT NULL
        AND position('public.post_customer_receipt_allocated' in pg_get_functiondef(invoice_payment_rpc))>0)
  FROM runtime
  UNION ALL
  SELECT 3,'backoffice_ar_invoice_receipt_runtime_postflight_registry_contract',
    CASE WHEN invalid.invoices=0 AND source_counts.invoices=registry_counts.invoices
      AND source_counts.receipts=registry_counts.receipts THEN 'PASS' ELSE 'FAIL' END,
    invalid.invoices+abs(source_counts.invoices-registry_counts.invoices)
      +abs(source_counts.receipts-registry_counts.receipts),
    jsonb_build_object('sourceInvoices',source_counts.invoices,
      'registryInvoices',registry_counts.invoices,'sourceReceipts',source_counts.receipts,
      'registryReceipts',registry_counts.receipts,'invalidInvoices',invalid.invoices)
  FROM source_counts,registry_counts,invalid
  UNION ALL
  SELECT 4,'backoffice_ar_invoice_receipt_runtime_postflight_allocation_contract',
    CASE WHEN invalid.allocations=0 AND invalid.overallocated=0
      AND source_counts.allocations=allocation_count.rows THEN 'PASS' ELSE 'FAIL' END,
    invalid.allocations+invalid.overallocated
      +abs(source_counts.allocations-allocation_count.rows),
    jsonb_build_object('sourceAllocations',source_counts.allocations,
      'openItemAllocations',allocation_count.rows,'missingOrMismatched',invalid.allocations,
      'overallocatedItems',invalid.overallocated)
  FROM source_counts,allocation_count,invalid
  UNION ALL
  SELECT 5,'backoffice_ar_invoice_receipt_runtime_postflight_privilege_contract',
    CASE WHEN has_function_privilege('authenticated',
        'public.save_customer_receipt_open_credit_draft(uuid,bigint,uuid,date,uuid,text,text,text,numeric,jsonb)','EXECUTE')
      AND has_function_privilege('authenticated',
        'public.post_customer_receipt_unified(uuid,bigint,uuid)','EXECUTE')
      AND NOT has_table_privilege('authenticated','public.ar_open_item_registry','SELECT')
      AND NOT has_table_privilege('authenticated','public.ar_open_item_allocations','SELECT')
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN has_function_privilege('authenticated',
        'public.save_customer_receipt_open_credit_draft(uuid,bigint,uuid,date,uuid,text,text,text,numeric,jsonb)','EXECUTE')
      AND has_function_privilege('authenticated',
        'public.post_customer_receipt_unified(uuid,bigint,uuid)','EXECUTE')
      AND NOT has_table_privilege('authenticated','public.ar_open_item_registry','SELECT')
      AND NOT has_table_privilege('authenticated','public.ar_open_item_allocations','SELECT')
      THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('saveRpcAuthenticated',has_function_privilege('authenticated',
        'public.save_customer_receipt_open_credit_draft(uuid,bigint,uuid,date,uuid,text,text,text,numeric,jsonb)','EXECUTE'),
      'postRpcAuthenticated',has_function_privilege('authenticated',
        'public.post_customer_receipt_unified(uuid,bigint,uuid)','EXECUTE'),
      'registryDirectSelect',has_table_privilege('authenticated','public.ar_open_item_registry','SELECT'),
      'allocationsDirectSelect',has_table_privilege('authenticated','public.ar_open_item_allocations','SELECT'))
  UNION ALL
  SELECT 6,'backoffice_ar_invoice_receipt_runtime_postflight_business_boundary','INFO',0,
    jsonb_build_object('changed',ARRAY['future Backoffice Invoice registration',
      'future Backoffice Receipt registration','manual partial/full allocation',
      'customer-scoped residual Receipt open credit'],
      'preserved',ARRAY['single Cash/Bank-to-AR Journal','POS Retail and mixed Receipt',
      'Customer Balance advance','Backoffice Return/Credit Note','Stock/Reservation/FIFO/HPP',
      'historical Posted documents and Journals'],
      'next','Run rollback-only behavior, then deploy client and authenticated smoke')
) checks ORDER BY seq;
