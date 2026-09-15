-- SELECT-only postflight for 20260914180000. Run the entire file.
WITH checks AS (
  SELECT 'generated_receipt_migration_ledger' check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(1-count(*))::bigint violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260914180000'
  UNION ALL
  SELECT 'generated_receipt_required_routines',
    CASE WHEN count(*)=6 THEN 'PASS' ELSE 'FAIL' END,abs(6-count(*))::bigint,
    jsonb_build_object('present',count(*),'expected',6)
  FROM pg_proc procedure JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
  WHERE (namespace.nspname,procedure.proname) IN(
    ('private','sync_purchase_order_receipt_documents'),
    ('private','trg_sync_purchase_order_receipt_documents'),
    ('public','save_generated_backoffice_goods_receipt'),
    ('public','post_generated_backoffice_goods_receipt'),
    ('public','get_backoffice_goods_receipt_workspace'),
    ('private','revise_purchase_supplier_order_core'))
  UNION ALL
  SELECT 'generated_receipt_trigger_contract',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,abs(1-count(*))::bigint,
    jsonb_build_object('triggerRows',count(*))
  FROM pg_trigger trigger WHERE trigger.tgrelid='public.supplier_order_documents'::regclass
    AND trigger.tgname='sync_purchase_order_receipt_documents' AND NOT trigger.tgisinternal
  UNION ALL
  SELECT 'generated_receipt_unique_draft_contract',
    CASE WHEN to_regclass('public.purchase_order_active_receipt_warehouse_uidx') IS NOT NULL
      THEN 'PASS' ELSE 'FAIL' END,0::bigint,jsonb_build_object('indexPresent',
        to_regclass('public.purchase_order_active_receipt_warehouse_uidx') IS NOT NULL)
  UNION ALL
  SELECT 'generated_receipt_revision_boundary',
    CASE WHEN pg_get_functiondef(
      'private.revise_purchase_supplier_order_core(uuid,uuid,bigint,uuid,uuid,date,text,jsonb)'::regprocedure)
      ~ 'receipt.line_count>0' THEN 'PASS' ELSE 'FAIL' END,0::bigint,
    jsonb_build_object('emptyGeneratedDraftBlocksEdit',false)
  UNION ALL
  SELECT 'generated_receipt_open_po_coverage',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('missingReceiptDocuments',count(*))
  FROM (SELECT document.company_id,document.id,line.destination_warehouse_id
    FROM public.supplier_order_documents document
    JOIN public.supplier_order_lines line ON line.company_id=document.company_id
      AND line.document_id=document.id
    JOIN public.warehouses warehouse ON warehouse.company_id=line.company_id
      AND warehouse.id=line.destination_warehouse_id AND warehouse.is_active
      AND warehouse.is_purchase_destination AND warehouse.warehouse_type IS DISTINCT FROM 'TRANSIT'
    WHERE document.status IN('CONFIRMED','PARTIALLY_RECEIVED')
      AND line.ordered_base_qty>COALESCE((SELECT sum(receipt_line.received_base_qty)
        FROM public.goods_receipt_lines receipt_line
        JOIN public.goods_receipt_documents receipt ON receipt.company_id=receipt_line.company_id
          AND receipt.id=receipt_line.document_id AND receipt.status='POSTED'
        WHERE receipt_line.company_id=line.company_id
          AND receipt_line.supplier_order_line_id=line.id),0)
      AND NOT EXISTS(SELECT 1 FROM public.goods_receipt_documents receipt
        WHERE receipt.company_id=document.company_id AND receipt.supplier_order_id=document.id
          AND receipt.warehouse_id=line.destination_warehouse_id
          AND receipt.source_channel='BACKOFFICE' AND receipt.status='DRAFT')
    GROUP BY document.company_id,document.id,line.destination_warehouse_id) missing
  UNION ALL
  SELECT 'generated_receipt_duplicate_draft_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('duplicatePoWarehouseGroups',count(*))
  FROM (SELECT company_id,supplier_order_id,warehouse_id
    FROM public.goods_receipt_documents WHERE source_channel='BACKOFFICE' AND status='DRAFT'
    GROUP BY company_id,supplier_order_id,warehouse_id HAVING count(*)>1) duplicate_group
  UNION ALL
  SELECT 'generated_receipt_runtime_inventory','INFO',0,
    jsonb_build_object('generatedDrafts',count(*),'purchaseOrders',count(DISTINCT supplier_order_id))
  FROM public.goods_receipt_documents WHERE source_channel='BACKOFFICE' AND status='DRAFT'
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;
