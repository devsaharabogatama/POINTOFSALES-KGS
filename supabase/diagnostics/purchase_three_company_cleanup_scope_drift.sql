-- SELECT-only diagnosis for CLEANUP_SCOPE_DRIFT in the guarded KMS/SMS/LSM
-- Purchase cleanup. This file does not mutate any document, Stock, or Finance.

WITH target_company(company_id,company_name,short_code) AS (
  VALUES
    ('4eedbf12-3c60-40e0-b2b7-1a48ca62b6f8'::uuid,
      'Khadijah Muda Sejahtera'::text,'KMS'::text),
    ('809abdd9-d05f-4525-9726-1951a0ae1a81'::uuid,
      'Smart Muda Solusi'::text,'SMS'::text),
    ('07bdffb9-8c56-444c-a49b-81ac86745674'::uuid,
      'Latorti Sari Median'::text,'LSM'::text)
), active_request AS (
  SELECT target.short_code,document.*
  FROM target_company target
  JOIN public.stock_request_documents document
    ON document.company_id=target.company_id
  WHERE document.status IN('DRAFT','SUBMITTED','ORDERED','PARTIALLY_RECEIVED')
), line_inventory AS (
  SELECT request.company_id,request.id document_id,
    count(line.id) FILTER(WHERE line.is_active) active_line_count,
    COALESCE(sum(line.requested_base_qty) FILTER(WHERE line.is_active),0)
      requested_base_qty,
    count(DISTINCT demand.id) FILTER(WHERE line.is_active) sales_linked_lines
  FROM active_request request
  LEFT JOIN public.stock_request_lines line
    ON line.company_id=request.company_id AND line.document_id=request.id
  LEFT JOIN public.sales_order_procurement_demand_lines demand
    ON demand.company_id=line.company_id AND demand.stock_request_line_id=line.id
  GROUP BY request.company_id,request.id
), order_inventory AS (
  SELECT request.company_id,request.id document_id,
    COALESCE(sum(allocation.allocated_base_qty),0) allocated_base_qty,
    count(DISTINCT order_document.id) FILTER(
      WHERE order_document.status IN('DRAFT','CONFIRMED','PARTIALLY_RECEIVED'))
      active_supplier_orders,
    count(DISTINCT order_document.id) FILTER(
      WHERE order_document.status='RECEIVED') received_supplier_orders,
    COALESCE(sum(
      CASE WHEN receipt.status='POSTED'
        THEN receipt_line.accepted_good_base_qty+receipt_line.damaged_base_qty
        ELSE 0 END),0) posted_receipt_base_qty
  FROM active_request request
  JOIN public.stock_request_lines request_line
    ON request_line.company_id=request.company_id
   AND request_line.document_id=request.id
  LEFT JOIN public.supplier_order_request_allocations allocation
    ON allocation.company_id=request_line.company_id
   AND allocation.stock_request_line_id=request_line.id
  LEFT JOIN public.supplier_order_lines order_line
    ON order_line.company_id=allocation.company_id
   AND order_line.id=allocation.supplier_order_line_id
  LEFT JOIN public.supplier_order_documents order_document
    ON order_document.company_id=order_line.company_id
   AND order_document.id=order_line.document_id
  LEFT JOIN public.goods_receipt_lines receipt_line
    ON receipt_line.company_id=order_line.company_id
   AND receipt_line.supplier_order_line_id=order_line.id
  LEFT JOIN public.goods_receipt_documents receipt
    ON receipt.company_id=receipt_line.company_id
   AND receipt.id=receipt_line.document_id
  GROUP BY request.company_id,request.id
), inventory AS (
  SELECT request.short_code,request.company_id,request.id,request.request_no,
    request.status,request.master_version,request.requested_at,
    request.created_at,request.updated_at,
    COALESCE(line.active_line_count,0) active_line_count,
    COALESCE(line.requested_base_qty,0) requested_base_qty,
    COALESCE(line.sales_linked_lines,0) sales_linked_lines,
    COALESCE(ordering.allocated_base_qty,0) allocated_base_qty,
    COALESCE(ordering.active_supplier_orders,0) active_supplier_orders,
    COALESCE(ordering.received_supplier_orders,0) received_supplier_orders,
    COALESCE(ordering.posted_receipt_base_qty,0) posted_receipt_base_qty
  FROM active_request request
  LEFT JOIN line_inventory line
    ON line.company_id=request.company_id AND line.document_id=request.id
  LEFT JOIN order_inventory ordering
    ON ordering.company_id=request.company_id AND ordering.document_id=request.id
), recent AS (
  SELECT * FROM inventory
  ORDER BY GREATEST(updated_at,created_at,requested_at) DESC,id
  LIMIT 15
), result AS (
  SELECT 10 sort_order,'active_stock_request_scope' check_name,'INFO' status,
    jsonb_build_object(
      'rows',count(*),
      'digest',md5(COALESCE(string_agg(
        id::text||'|'||status||'|'||master_version::text||'|'||request_no,
        ',' ORDER BY id),'')),
      'expectedPriorRows',94,
      'expectedPriorDigest','eae2c51c9dac1a7e0f052c09b056cdcd',
      'currentErrorDigest','a29857add5540f988baa5807e863c2a2') details
  FROM inventory

  UNION ALL
  SELECT 20,'recent_active_stock_requests','INFO',jsonb_build_object(
    'rule','Identify the new or recently changed request before repinning cleanup',
    'documents',COALESCE(jsonb_agg(to_jsonb(recent)
      ORDER BY GREATEST(updated_at,created_at,requested_at) DESC,id),'[]'::jsonb))
  FROM recent

  UNION ALL
  SELECT 30,'active_request_safety_boundary',
    CASE WHEN count(*) FILTER(WHERE status IN('DRAFT','PARTIALLY_RECEIVED')
        OR active_supplier_orders>0 OR posted_receipt_base_qty>0)>0
      THEN 'BLOCKER' ELSE 'PASS' END,
    jsonb_build_object(
      'draftOrPartial',count(*) FILTER(WHERE status IN('DRAFT','PARTIALLY_RECEIVED')),
      'withActiveSupplierOrder',count(*) FILTER(WHERE active_supplier_orders>0),
      'withPostedReceipt',count(*) FILTER(WHERE posted_receipt_base_qty>0),
      'submittedOrOrdered',count(*) FILTER(WHERE status IN('SUBMITTED','ORDERED')),
      'salesLinkedDocuments',count(*) FILTER(WHERE sales_linked_lines>0))
  FROM inventory
)
SELECT check_name,status,details
FROM result
ORDER BY sort_order;
