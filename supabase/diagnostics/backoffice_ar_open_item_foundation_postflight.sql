-- SELECT-only postflight for 20261105100000_backoffice_ar_open_item_foundation.sql.
WITH source_counts AS (
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
    (SELECT count(*) FROM public.backoffice_sales_credit_notes
      WHERE status='POSTED' AND source_kind='BACKOFFICE' AND ar_reduction_amount>0
        AND EXISTS(SELECT 1 FROM public.company_sales_process_settings setting
          WHERE setting.company_id=backoffice_sales_credit_notes.company_id
            AND setting.active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE')) AS credit_notes,
    (SELECT count(*) FROM public.backoffice_sales_invoice_price_corrections
      WHERE status='POSTED' AND ar_adjustment_amount<>0
        AND EXISTS(SELECT 1 FROM public.company_sales_process_settings setting
          WHERE setting.company_id=backoffice_sales_invoice_price_corrections.company_id
            AND setting.active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE')) AS corrections,
    (SELECT count(*) FROM public.customer_receipt_backoffice_invoice_allocations allocation
      JOIN public.customer_receipt_documents receipt ON receipt.company_id=allocation.company_id
        AND receipt.id=allocation.document_id AND receipt.status='POSTED'
      JOIN public.company_sales_process_settings setting ON setting.company_id=receipt.company_id
        AND setting.active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE') AS receipt_allocations
),registry_counts AS (
  SELECT count(*) FILTER(WHERE item_kind='INVOICE') AS invoices,
    count(*) FILTER(WHERE item_kind='RECEIPT') AS receipts,
    count(*) FILTER(WHERE item_kind='CREDIT_NOTE') AS credit_notes,
    count(*) FILTER(WHERE item_kind='PRICE_CORRECTION') AS corrections
  FROM public.ar_open_item_registry
),allocation_shape AS (
  SELECT count(*) FILTER(WHERE source_kind='RECEIPT_ALLOCATION') AS receipt_allocations,
    count(*) AS total_allocations
  FROM public.ar_open_item_allocations
),overallocated AS (
  SELECT count(*) AS rows FROM (
    SELECT item.company_id,item.id
    FROM public.ar_open_item_registry item
    LEFT JOIN public.ar_open_item_allocations allocation
      ON allocation.company_id=item.company_id
      AND (allocation.debit_item_id=item.id OR allocation.credit_item_id=item.id)
    GROUP BY item.company_id,item.id,item.original_amount
    HAVING COALESCE(sum(allocation.allocated_amount),0)>item.original_amount
  ) invalid
),audit_shape AS (
  SELECT (SELECT count(*) FROM public.ar_open_item_registry)
      +(SELECT count(*) FROM public.ar_open_item_operations)
      +(SELECT count(*) FROM public.ar_open_item_allocations) AS expected,
    (SELECT count(*) FROM public.ar_open_item_audit) AS actual
),audit_lineage AS (
  SELECT count(*) AS invalid FROM (
    SELECT audit.id FROM public.ar_open_item_audit audit
    LEFT JOIN public.ar_open_item_registry registry
      ON registry.company_id=audit.company_id AND registry.id=audit.entity_id
    WHERE audit.entity_kind='REGISTRY'
      AND (registry.id IS NULL OR audit.actor_id<>registry.created_by
        OR audit.state_snapshot IS DISTINCT FROM to_jsonb(registry))
    UNION ALL
    SELECT audit.id FROM public.ar_open_item_audit audit
    LEFT JOIN public.ar_open_item_operations operation
      ON operation.company_id=audit.company_id AND operation.id=audit.entity_id
    WHERE audit.entity_kind='OPERATION'
      AND (operation.id IS NULL OR audit.actor_id<>operation.actor_id
        OR audit.state_snapshot IS DISTINCT FROM to_jsonb(operation))
    UNION ALL
    SELECT audit.id FROM public.ar_open_item_audit audit
    LEFT JOIN public.ar_open_item_allocations allocation
      ON allocation.company_id=audit.company_id AND allocation.id=audit.entity_id
    WHERE audit.entity_kind='ALLOCATION'
      AND (allocation.id IS NULL OR audit.actor_id<>allocation.created_by
        OR audit.state_snapshot IS DISTINCT FROM CASE
          WHEN audit.state_snapshot ? 'effective_date' THEN to_jsonb(allocation)
          ELSE to_jsonb(allocation)-'effective_date' END)
  ) invalid_rows
),privilege_shape AS (
  SELECT
    has_function_privilege('authenticated',
      'public.get_finance_ar_open_items(uuid,boolean)'::regprocedure,'EXECUTE') AS rpc_authenticated,
    has_table_privilege('authenticated','public.ar_open_item_registry','SELECT') AS registry_select,
    has_table_privilege('authenticated','public.ar_open_item_operations','SELECT') AS operations_select,
    has_table_privilege('authenticated','public.ar_open_item_allocations','SELECT') AS allocations_select,
    has_table_privilege('authenticated','public.ar_open_item_audit','SELECT') AS audit_select
)
SELECT 'backoffice_ar_open_item_foundation_postflight_migration_ledger' AS check_name,
  CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END AS status,
  abs(1-count(*))::bigint AS violation_rows,
  jsonb_build_object('ledgerRows',count(*)) AS details
FROM private.kgs_schema_migrations WHERE version='20261105100000'
UNION ALL
SELECT 'backoffice_ar_open_item_foundation_postflight_registry_contract',
  CASE WHEN source.invoices=registry.invoices AND source.receipts=registry.receipts
      AND source.credit_notes=registry.credit_notes
      AND source.corrections=registry.corrections THEN 'PASS' ELSE 'FAIL' END,
  abs(source.invoices-registry.invoices)+abs(source.receipts-registry.receipts)
    +abs(source.credit_notes-registry.credit_notes)+abs(source.corrections-registry.corrections),
  jsonb_build_object('source',jsonb_build_object('invoices',source.invoices,
      'receipts',source.receipts,'creditNotes',source.credit_notes,'corrections',source.corrections),
    'registry',jsonb_build_object('invoices',registry.invoices,
      'receipts',registry.receipts,'creditNotes',registry.credit_notes,'corrections',registry.corrections))
FROM source_counts source CROSS JOIN registry_counts registry
UNION ALL
SELECT 'backoffice_ar_open_item_foundation_postflight_allocation_contract',
  CASE WHEN source.receipt_allocations=shape.receipt_allocations
      AND overallocated.rows=0 THEN 'PASS' ELSE 'FAIL' END,
  abs(source.receipt_allocations-shape.receipt_allocations)+overallocated.rows,
  jsonb_build_object('sourceReceiptAllocations',source.receipt_allocations,
    'ledgerReceiptAllocations',shape.receipt_allocations,
    'totalAllocations',shape.total_allocations,'overallocatedItems',overallocated.rows)
FROM source_counts source CROSS JOIN allocation_shape shape CROSS JOIN overallocated
UNION ALL
SELECT 'backoffice_ar_open_item_foundation_postflight_audit_contract',
  CASE WHEN expected=actual AND lineage.invalid=0 THEN 'PASS' ELSE 'FAIL' END,
  abs(expected-actual)+lineage.invalid,
  jsonb_build_object('expected',expected,'actual',actual,
    'invalidActorOrSnapshotLineage',lineage.invalid,
    'actorSource',jsonb_build_object('REGISTRY','created_by',
      'OPERATION','actor_id','ALLOCATION','created_by'))
FROM audit_shape CROSS JOIN audit_lineage lineage
UNION ALL
SELECT 'backoffice_ar_open_item_foundation_postflight_privilege_contract',
  CASE WHEN rpc_authenticated AND NOT registry_select AND NOT operations_select
      AND NOT allocations_select AND NOT audit_select THEN 'PASS' ELSE 'FAIL' END,
  ((NOT rpc_authenticated)::int+registry_select::int+operations_select::int
    +allocations_select::int+audit_select::int)::bigint,
  jsonb_build_object('rpcAuthenticated',rpc_authenticated,
    'directTableSelect',jsonb_build_object('registry',registry_select,
      'operations',operations_select,'allocations',allocations_select,'audit',audit_select))
FROM privilege_shape
UNION ALL
SELECT 'backoffice_ar_open_item_foundation_postflight_business_boundary','INFO',0,
  jsonb_build_object('changed',jsonb_build_array('Backoffice AR open-item read foundation',
      'historical allocation snapshot','append-only audit ledger'),
    'preserved',jsonb_build_array('Posted Journals','Backoffice posting runtime',
      'Return/Refund','POS Retail','Customer Balance','Stock/FIFO','historical documents'),
    'next','Run rollback-only behavior test and authenticated read smoke; Task 3 remains separate');
