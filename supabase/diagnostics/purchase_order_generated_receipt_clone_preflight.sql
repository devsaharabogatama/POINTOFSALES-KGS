-- SELECT-only preflight for 20260914180000. Run the entire file.
WITH checks AS (
  SELECT 'generated_receipt_dependency_ledger' check_name,
    CASE WHEN count(*)=7 THEN 'PASS' ELSE 'BLOCKER' END status,
    abs(7-count(*))::bigint violation_rows,
    jsonb_build_object('present',count(*),'expected',7) details
  FROM private.kgs_schema_migrations WHERE version IN(
    '20260913120000','20260913130000','20260914100000','20260914140000',
    '20260914150000','20260914160000','20260914170000')
  UNION ALL
  SELECT 'generated_receipt_schema_collision',
    CASE WHEN to_regprocedure('private.sync_purchase_order_receipt_documents(uuid,uuid,uuid,timestamptz)') IS NULL
      AND to_regprocedure('public.save_generated_backoffice_goods_receipt(uuid,bigint,uuid,text,text,jsonb)') IS NULL
      AND to_regprocedure('public.post_generated_backoffice_goods_receipt(uuid,bigint,uuid)') IS NULL
      AND to_regprocedure('private.trg_sync_purchase_order_receipt_documents()') IS NULL
      AND to_regclass('public.purchase_order_active_receipt_warehouse_uidx') IS NULL
      AND NOT EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='public.supplier_order_documents'::regclass
        AND tgname='sync_purchase_order_receipt_documents')
      THEN 'PASS' ELSE 'BLOCKER' END,
    0::bigint,jsonb_build_object('migrationApplied',EXISTS(SELECT 1
      FROM private.kgs_schema_migrations WHERE version='20260914180000'))
  UNION ALL
  SELECT 'generated_receipt_duplicate_draft_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('duplicatePoWarehouseGroups',count(*))
  FROM (SELECT receipt.company_id,receipt.supplier_order_id,receipt.warehouse_id
    FROM public.goods_receipt_documents receipt
    WHERE receipt.source_channel='BACKOFFICE' AND receipt.status='DRAFT'
    GROUP BY receipt.company_id,receipt.supplier_order_id,receipt.warehouse_id
    HAVING count(*)>1) duplicate_group
  UNION ALL
  SELECT 'generated_receipt_revision_anchor',
    CASE WHEN pg_get_functiondef(
      'private.revise_purchase_supplier_order_core(uuid,uuid,bigint,uuid,uuid,date,text,jsonb)'::regprocedure)
      ~ 'receipt.status\s*<>\s*''CANCELED''' THEN 'PASS' ELSE 'BLOCKER' END,
    0::bigint,jsonb_build_object('legacyStartedReceiptBoundary',true)
  UNION ALL
  SELECT 'generated_receipt_active_finance_queue',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('runRows',count(*))
  FROM public.finance_posting_queue_runs WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'generated_receipt_nonterminal_offline',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('submissionRows',count(*))
  FROM public.pos_offline_sale_submissions WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
  UNION ALL
  SELECT 'generated_receipt_development_fixture',
    'SETUP',
    0,
    jsonb_build_object('eligibleAssignedPoLines',count(*),'fixtureRule','Canonical AUTO_PO prepared inside rollback-only purchase_order_generated_receipt_clone_behavior.sql')
  FROM public.supplier_order_lines line
  JOIN public.supplier_order_documents document ON document.company_id=line.company_id
    AND document.id=line.document_id
  JOIN public.warehouses warehouse ON warehouse.company_id=line.company_id
    AND warehouse.id=line.destination_warehouse_id AND warehouse.is_active
    AND warehouse.is_purchase_destination AND warehouse.warehouse_type IS DISTINCT FROM 'TRANSIT'
  WHERE document.order_source='DAILY_REPLENISHMENT' AND document.status='CONFIRMED'
    AND document.supplier_id IS NOT NULL AND line.ordered_base_qty>1
    AND line.estimated_unit_price>0
  UNION ALL
  SELECT 'generated_receipt_open_po_destination_inventory','INFO',0,
    jsonb_build_object('openPoLinesWithoutReceivingWarehouse',count(*))
  FROM public.supplier_order_lines line
  JOIN public.supplier_order_documents document ON document.company_id=line.company_id
    AND document.id=line.document_id
  WHERE document.status IN('CONFIRMED','PARTIALLY_RECEIVED')
    AND line.destination_warehouse_id IS NULL
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;
