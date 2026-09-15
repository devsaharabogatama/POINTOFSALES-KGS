-- SELECT-only. Run entire file in Production SQL Editor.
-- Target is the exact PO/GR shown by user; no auth/context/data mutation.
WITH target AS (
 SELECT receipt.*,document.order_no,document.status po_status
 FROM public.goods_receipt_documents receipt
 JOIN public.supplier_order_documents document
 ON document.company_id=receipt.company_id AND document.id=receipt.supplier_order_id
 WHERE receipt.receipt_no='GR-20260914-0000000034'
 AND document.order_no='PO-20260910-0000000058'
), source_lines AS (
 SELECT target.receipt_no,target.order_no,target.company_id,target.po_status,
 target.status receipt_status,target.warehouse_id receipt_warehouse_id,
 target.line_count stored_draft_line_count,line.id source_line_id,
 line.product_name_snapshot,line.destination_warehouse_id,line.ordered_base_qty,
 greatest(line.ordered_base_qty-COALESCE((SELECT sum(received.received_base_qty)
 FROM public.goods_receipt_lines received JOIN public.goods_receipt_documents posted
 ON posted.company_id=received.company_id AND posted.id=received.document_id
 WHERE received.company_id=line.company_id AND received.supplier_order_line_id=line.id
 AND posted.status='POSTED'),0),0) remaining_base_qty,
 (SELECT count(*) FROM public.goods_receipt_lines saved
 WHERE saved.company_id=target.company_id AND saved.document_id=target.id
 AND saved.supplier_order_line_id=line.id) saved_draft_lines
 FROM target LEFT JOIN public.supplier_order_lines line
 ON line.company_id=target.company_id AND line.document_id=target.supplier_order_id
), checks AS (
 SELECT 'exact_receipt_source' check_name,
 CASE WHEN EXISTS(SELECT 1 FROM target) THEN 'INFO' ELSE 'MISSING' END status,
 jsonb_build_object('matchingReceipts',(SELECT count(*) FROM target),
 'lines',COALESCE((SELECT jsonb_agg(to_jsonb(source_lines)||jsonb_build_object(
 'warehouseMatches',destination_warehouse_id=receipt_warehouse_id,
 'currentUiWouldShow',COALESCE(destination_warehouse_id=receipt_warehouse_id
 AND remaining_base_qty>0,false))) FROM source_lines),'[]'::jsonb)) details
 UNION ALL SELECT 'production_receipt_reader','INFO',jsonb_build_object(
 'readerExists',to_regprocedure('public.get_backoffice_goods_receipt_workspace()') IS NOT NULL,
 'generatedWorkspaceV2',position('goodsReceiptWorkspaceVersion' IN
 pg_get_functiondef(to_regprocedure('public.get_backoffice_goods_receipt_workspace()')))>0,
 'projectsLineDestination',position('line.destination_warehouse_id' IN
 pg_get_functiondef(to_regprocedure('public.get_backoffice_goods_receipt_workspace()')))>0,
 'generatedWorkflowInstalled',EXISTS(SELECT 1 FROM private.kgs_schema_migrations
 WHERE version='20260914180000'))
)
SELECT check_name,status,details FROM checks ORDER BY check_name;
