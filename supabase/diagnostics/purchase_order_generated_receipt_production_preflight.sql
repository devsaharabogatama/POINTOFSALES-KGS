-- Production SELECT-only preflight AFTER checkpoint G. No test fixture required.
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
  SELECT 'generated_receipt_open_po_destination_inventory','INFO',0,
    jsonb_build_object('openPoLinesWithoutReceivingWarehouse',count(*))
  FROM public.supplier_order_lines line
  JOIN public.supplier_order_documents document ON document.company_id=line.company_id
    AND document.id=line.document_id
  WHERE document.status IN('CONFIRMED','PARTIALLY_RECEIVED')
    AND line.destination_warehouse_id IS NULL
  UNION ALL
  SELECT 'generated_receipt_exact_missing_pairs','INFO',0,
    jsonb_build_object('pairs',COALESCE(jsonb_agg(to_jsonb(candidate)
      ORDER BY candidate.company_id,candidate.supplier_order_id,candidate.warehouse_id),'[]'::jsonb))
  FROM (SELECT document.company_id,document.id supplier_order_id,line.destination_warehouse_id warehouse_id
    FROM public.supplier_order_documents document
    JOIN public.supplier_order_lines line ON line.company_id=document.company_id AND line.document_id=document.id
    JOIN public.warehouses warehouse ON warehouse.company_id=line.company_id
      AND warehouse.id=line.destination_warehouse_id AND warehouse.is_active
      AND warehouse.is_purchase_destination AND warehouse.warehouse_type IS DISTINCT FROM 'TRANSIT'
    WHERE document.status IN('CONFIRMED','PARTIALLY_RECEIVED')
      AND COALESCE(document.confirmed_by,document.ordered_by) IS NOT NULL
      AND line.ordered_base_qty>COALESCE((SELECT sum(receipt_line.received_base_qty)
        FROM public.goods_receipt_lines receipt_line JOIN public.goods_receipt_documents posted
          ON posted.company_id=receipt_line.company_id AND posted.id=receipt_line.document_id AND posted.status='POSTED'
        WHERE receipt_line.company_id=line.company_id AND receipt_line.supplier_order_line_id=line.id),0)
      AND NOT EXISTS(SELECT 1 FROM public.goods_receipt_documents receipt
        WHERE receipt.company_id=document.company_id AND receipt.supplier_order_id=document.id
          AND receipt.warehouse_id=line.destination_warehouse_id
          AND receipt.source_channel='BACKOFFICE' AND receipt.status='DRAFT')
    GROUP BY document.company_id,document.id,line.destination_warehouse_id) candidate
  UNION ALL
  SELECT 'generated_receipt_existing_draft_baseline','INFO',0,
    jsonb_build_object('drafts',COALESCE(jsonb_agg(jsonb_build_object(
      'id',receipt.id,'companyId',receipt.company_id,'supplierOrderId',receipt.supplier_order_id,
      'warehouseId',receipt.warehouse_id,'lineCount',receipt.line_count,'masterVersion',receipt.master_version,
      'hasLines',EXISTS(SELECT 1 FROM public.goods_receipt_lines line
        WHERE line.company_id=receipt.company_id AND line.document_id=receipt.id))
      ORDER BY receipt.company_id,receipt.id),'[]'::jsonb),
      'rule','Only untouched empty placeholders may sync metadata/cancel; preserve started/posted Receipt')
  FROM public.goods_receipt_documents receipt
  WHERE receipt.source_channel='BACKOFFICE' AND receipt.status='DRAFT'

)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;

