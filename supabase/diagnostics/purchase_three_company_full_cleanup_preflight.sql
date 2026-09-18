-- SUPERSEDED for Supabase SQL Editor output capture by:
-- purchase_three_company_full_cleanup_preflight_consolidated.sql
-- This original multi-result form is retained only as readable query evidence.
--
-- SELECT-only preflight for the user-approved KMS/SMS/LSM procurement cleanup.
--
-- Scope:
--   * every active Purchase Replenishment batch (RO), regardless of mode;
--   * every active Supplier Order (PO), regardless of MANUAL/AUTO origin;
--   * posted receipts must be reversed through canonical Purchase Return before PO cancel;
--   * history, audit, Stock Movement, FIFO and Finance rows are never deleted/reset.
--
-- This file DOES NOT mutate data. Run the complete file in Production SQL Editor
-- and retain every result set before preparing the guarded execution operation.

WITH target_company(company_id,expected_name,short_code) AS (
  VALUES
    ('4eedbf12-3c60-40e0-b2b7-1a48ca62b6f8'::uuid,
      'Khadijah Muda Sejahtera'::text,'KMS'::text),
    ('809abdd9-d05f-4525-9726-1951a0ae1a81'::uuid,
      'Smart Muda Solusi'::text,'SMS'::text),
    ('07bdffb9-8c56-444c-a49b-81ac86745674'::uuid,
      'Latorti Sari Median'::text,'LSM'::text)
), company_scope AS (
  SELECT target.*,company.company_name,company.status,
    company.timezone,
    setting.replenishment_mode,setting.cutoff_local_time,
    setting.default_purchase_receipt_warehouse_id
  FROM target_company target
  LEFT JOIN public.companies company ON company.id=target.company_id
  LEFT JOIN public.company_purchase_replenishment_settings setting
    ON setting.company_id=target.company_id
)
SELECT 'cleanup_company_scope'::text check_name,
  CASE WHEN count(*)=3
      AND count(*) FILTER(WHERE company_name=expected_name AND status='ACTIVE')=3
      AND count(*) FILTER(WHERE replenishment_mode='AUTO_RO')=3
    THEN 'PASS' ELSE 'BLOCKER' END status,
  (3-count(*) FILTER(WHERE company_name=expected_name AND status='ACTIVE'))::bigint
    violation_rows,
  jsonb_build_object(
    'companies',COALESCE(jsonb_agg(jsonb_build_object(
      'companyId',company_id,'code',short_code,'expectedName',expected_name,
      'actualName',company_name,'status',status,'timezone',timezone,
      'replenishmentMode',replenishment_mode,'cutoffLocalTime',cutoff_local_time,
      'defaultReceiptWarehouseId',default_purchase_receipt_warehouse_id)
      ORDER BY short_code),'[]'::jsonb),
    'requiredMode','AUTO_RO',
    'modeRule','Cleanup preserves the configured AUTO_RO flow; it does not switch Company mode') details
FROM company_scope;

WITH target_company(company_id,short_code) AS (
  VALUES
    ('4eedbf12-3c60-40e0-b2b7-1a48ca62b6f8'::uuid,'KMS'::text),
    ('809abdd9-d05f-4525-9726-1951a0ae1a81'::uuid,'SMS'::text),
    ('07bdffb9-8c56-444c-a49b-81ac86745674'::uuid,'LSM'::text)
), active_ro AS (
  SELECT target.short_code,batch.company_id,batch.id,batch.batch_no,
    batch.business_date,batch.mode_snapshot,batch.status,batch.line_count,
    batch.requested_total_base_qty,batch.master_version
  FROM target_company target
  JOIN public.purchase_daily_batches batch ON batch.company_id=target.company_id
  WHERE batch.status<>'CANCELED'
)
SELECT 'active_ro_cleanup_inventory'::text check_name,'INFO'::text status,
  count(*)::bigint violation_rows,
  jsonb_build_object(
    'activeRows',count(*),
    'byCompanyAndStatus',COALESCE((SELECT jsonb_agg(to_jsonb(summary)
      ORDER BY summary.short_code,summary.mode_snapshot,summary.status)
      FROM (SELECT short_code,mode_snapshot,status,count(*) rows,
          sum(line_count) lines,sum(requested_total_base_qty) requested_base_qty
        FROM active_ro GROUP BY short_code,mode_snapshot,status) summary),'[]'::jsonb),
    'documents',COALESCE((SELECT jsonb_agg(to_jsonb(document)
      ORDER BY document.short_code,document.business_date,document.batch_no)
      FROM active_ro document),'[]'::jsonb)) details
FROM active_ro;

WITH corrected_target AS (
  -- Only the three explicitly approved Company UUIDs are in scope.
  SELECT * FROM (VALUES
    ('4eedbf12-3c60-40e0-b2b7-1a48ca62b6f8'::uuid,'KMS'::text),
    ('809abdd9-d05f-4525-9726-1951a0ae1a81'::uuid,'SMS'::text),
    ('07bdffb9-8c56-444c-a49b-81ac86745674'::uuid,'LSM'::text)
  ) approved(company_id,short_code)
), active_po AS (
  SELECT target.short_code,document.*
  FROM corrected_target target
  JOIN public.supplier_order_documents document
    ON document.company_id=target.company_id
  WHERE document.status IN('DRAFT','CONFIRMED','PARTIALLY_RECEIVED','RECEIVED')
), received AS (
  SELECT order_line.company_id,order_line.document_id,
    sum(receipt_line.accepted_good_base_qty+receipt_line.damaged_base_qty)
      received_base_qty,
    count(DISTINCT receipt.id) receipt_count
  FROM active_po document
  JOIN public.supplier_order_lines order_line
    ON order_line.company_id=document.company_id
   AND order_line.document_id=document.id
  JOIN public.goods_receipt_lines receipt_line
    ON receipt_line.company_id=order_line.company_id
   AND receipt_line.supplier_order_line_id=order_line.id
  JOIN public.goods_receipt_documents receipt
    ON receipt.company_id=receipt_line.company_id
   AND receipt.id=receipt_line.document_id AND receipt.status='POSTED'
  GROUP BY order_line.company_id,order_line.document_id
), returned AS (
  SELECT document.company_id,document.supplier_order_id document_id,
    sum(line.return_base_qty) returned_base_qty,
    count(DISTINCT document.id) return_count
  FROM public.purchase_return_documents document
  JOIN public.purchase_return_lines line
    ON line.company_id=document.company_id AND line.document_id=document.id
  WHERE document.status='POSTED'
    AND document.company_id IN(SELECT company_id FROM corrected_target)
  GROUP BY document.company_id,document.supplier_order_id
), bill AS (
  SELECT order_line.company_id,order_line.document_id,
    count(DISTINCT invoice.id) FILTER(WHERE invoice.status<>'CANCELED') bill_count,
    count(DISTINCT invoice.id) FILTER(WHERE invoice.status='VALIDATED') validated_bill_count,
    count(DISTINCT payment.id) FILTER(WHERE payment.status<>'CANCELED') payment_count
  FROM active_po document
  JOIN public.supplier_order_lines order_line
    ON order_line.company_id=document.company_id
   AND order_line.document_id=document.id
  JOIN public.supplier_invoice_allocations invoice_allocation
    ON invoice_allocation.company_id=order_line.company_id
   AND invoice_allocation.supplier_order_line_id=order_line.id
  JOIN public.supplier_invoice_documents invoice
    ON invoice.company_id=invoice_allocation.company_id
   AND invoice.id=invoice_allocation.document_id
  LEFT JOIN public.supplier_payment_allocations payment_allocation
    ON payment_allocation.company_id=invoice.company_id
   AND payment_allocation.invoice_id=invoice.id
  LEFT JOIN public.supplier_payment_documents payment
    ON payment.company_id=payment_allocation.company_id
   AND payment.id=payment_allocation.document_id
  GROUP BY order_line.company_id,order_line.document_id
), inventory AS (
  SELECT document.short_code,document.company_id,document.id,document.order_no,
    document.order_source,document.status,document.order_date,
    document.purchase_daily_batch_id,document.master_version,
    COALESCE(received.received_base_qty,0) received_base_qty,
    COALESCE(returned.returned_base_qty,0) returned_base_qty,
    COALESCE(received.received_base_qty,0)-COALESCE(returned.returned_base_qty,0)
      net_received_base_qty,
    COALESCE(received.receipt_count,0) receipt_count,
    COALESCE(returned.return_count,0) return_count,
    COALESCE(bill.bill_count,0) bill_count,
    COALESCE(bill.validated_bill_count,0) validated_bill_count,
    COALESCE(bill.payment_count,0) payment_count
  FROM active_po document
  LEFT JOIN received
    ON received.company_id=document.company_id AND received.document_id=document.id
  LEFT JOIN returned
    ON returned.company_id=document.company_id AND returned.document_id=document.id
  LEFT JOIN bill
    ON bill.company_id=document.company_id AND bill.document_id=document.id
)
SELECT 'active_po_cleanup_inventory'::text check_name,'INFO'::text status,
  count(*)::bigint violation_rows,
  jsonb_build_object(
    'activeRows',count(*),
    'manualRows',count(*) FILTER(WHERE order_source='MANUAL'),
    'dailyRows',count(*) FILTER(WHERE order_source='DAILY_REPLENISHMENT'),
    'requiresPhysicalReturn',count(*) FILTER(WHERE net_received_base_qty<>0),
    'withActiveBill',count(*) FILTER(WHERE bill_count>0),
    'withPayment',count(*) FILTER(WHERE payment_count>0),
    'documents',COALESCE(jsonb_agg(to_jsonb(inventory)
      ORDER BY short_code,order_date,order_no),'[]'::jsonb)) details
FROM inventory;

WITH target_company(company_id,short_code) AS (
  VALUES
    ('4eedbf12-3c60-40e0-b2b7-1a48ca62b6f8'::uuid,'KMS'::text),
    ('809abdd9-d05f-4525-9726-1951a0ae1a81'::uuid,'SMS'::text),
    ('07bdffb9-8c56-444c-a49b-81ac86745674'::uuid,'LSM'::text)
), active_po AS (
  SELECT target.short_code,document.id,document.company_id,document.order_no
  FROM target_company target
  JOIN public.supplier_order_documents document
    ON document.company_id=target.company_id
  WHERE document.status IN('DRAFT','CONFIRMED','PARTIALLY_RECEIVED','RECEIVED')
), prior_return AS (
  SELECT line.company_id,line.source_condition_allocation_id,
    sum(line.return_base_qty) returned_base_qty
  FROM public.purchase_return_lines line
  JOIN public.purchase_return_documents document
    ON document.company_id=line.company_id AND document.id=line.document_id
   AND document.status='POSTED'
  WHERE line.company_id IN(SELECT company_id FROM target_company)
  GROUP BY line.company_id,line.source_condition_allocation_id
), return_source AS (
  SELECT document.short_code,document.order_no,receipt.receipt_no,
    allocation.id source_allocation_id,allocation.condition_type,
    allocation.quantity_base-COALESCE(prior.returned_base_qty,0) required_return_base_qty,
    allocation.product_batch_id,COALESCE(batch.qty_remaining,0) fifo_available_base_qty,
    CASE WHEN allocation.product_batch_id IS NULL
        OR batch.id IS NULL
        OR batch.qty_remaining < allocation.quantity_base-COALESCE(prior.returned_base_qty,0)
      THEN true ELSE false END blocked
  FROM active_po document
  JOIN public.supplier_order_lines order_line
    ON order_line.company_id=document.company_id AND order_line.document_id=document.id
  JOIN public.goods_receipt_lines receipt_line
    ON receipt_line.company_id=order_line.company_id
   AND receipt_line.supplier_order_line_id=order_line.id
  JOIN public.goods_receipt_documents receipt
    ON receipt.company_id=receipt_line.company_id
   AND receipt.id=receipt_line.document_id AND receipt.status='POSTED'
  JOIN public.goods_receipt_condition_allocations allocation
    ON allocation.company_id=receipt_line.company_id
   AND allocation.receipt_line_id=receipt_line.id
   AND allocation.condition_type IN('GOOD','DAMAGED')
  LEFT JOIN prior_return prior
    ON prior.company_id=allocation.company_id
   AND prior.source_condition_allocation_id=allocation.id
  LEFT JOIN public.product_batches batch
    ON batch.company_id=allocation.company_id AND batch.id=allocation.product_batch_id
  WHERE allocation.quantity_base-COALESCE(prior.returned_base_qty,0)>0
)
SELECT 'purchase_return_fifo_availability'::text check_name,
  CASE WHEN count(*) FILTER(WHERE blocked)=0 THEN 'PASS' ELSE 'BLOCKER' END status,
  count(*) FILTER(WHERE blocked)::bigint violation_rows,
  jsonb_build_object(
    'requiredAllocationRows',count(*),
    'blockedRows',count(*) FILTER(WHERE blocked),
    'blocked',COALESCE(jsonb_agg(to_jsonb(return_source)
      ORDER BY short_code,order_no,receipt_no)
      FILTER(WHERE blocked),'[]'::jsonb)) details
FROM return_source;

WITH target_company(company_id,short_code) AS (
  VALUES
    ('4eedbf12-3c60-40e0-b2b7-1a48ca62b6f8'::uuid,'KMS'::text),
    ('809abdd9-d05f-4525-9726-1951a0ae1a81'::uuid,'SMS'::text),
    ('07bdffb9-8c56-444c-a49b-81ac86745674'::uuid,'LSM'::text)
), active_order_allocation AS (
  SELECT allocation.company_id,allocation.stock_request_line_id,
    sum(allocation.allocated_base_qty) allocated_base_qty
  FROM public.supplier_order_request_allocations allocation
  JOIN public.supplier_order_lines order_line
    ON order_line.company_id=allocation.company_id
   AND order_line.id=allocation.supplier_order_line_id
  JOIN public.supplier_order_documents order_document
    ON order_document.company_id=order_line.company_id
   AND order_document.id=order_line.document_id
  WHERE allocation.company_id IN(SELECT company_id FROM target_company)
    AND order_document.status IN('DRAFT','CONFIRMED','PARTIALLY_RECEIVED')
  GROUP BY allocation.company_id,allocation.stock_request_line_id
), active_request AS (
  SELECT target.short_code,document.company_id,document.id,document.request_no,
    document.status,document.master_version,
    count(line.id) line_count,
    COALESCE(sum(GREATEST(
      line.requested_base_qty-COALESCE(allocation.allocated_base_qty,0),0)),0)
      open_base_qty,
    count(demand.id) sales_linked_lines
  FROM target_company target
  JOIN public.stock_request_documents document ON document.company_id=target.company_id
  LEFT JOIN public.stock_request_lines line
    ON line.company_id=document.company_id AND line.document_id=document.id
   AND line.is_active
  LEFT JOIN active_order_allocation allocation
    ON allocation.company_id=line.company_id AND allocation.stock_request_line_id=line.id
  LEFT JOIN public.sales_order_procurement_demand_lines demand
    ON demand.company_id=line.company_id AND demand.stock_request_line_id=line.id
  WHERE document.status IN('DRAFT','SUBMITTED','ORDERED','PARTIALLY_RECEIVED')
  GROUP BY target.short_code,document.company_id,document.id,document.request_no,
    document.status,document.master_version
)
SELECT 'active_stock_request_coverage'::text check_name,
  CASE WHEN COALESCE(sum(open_base_qty),0)=0 THEN 'PASS' ELSE 'BLOCKER' END status,
  count(*) FILTER(WHERE open_base_qty>0)::bigint violation_rows,
  jsonb_build_object(
    'rule','Active Stock Request coverage also reduces automatic PO quantity',
    'openBaseQty',COALESCE(sum(open_base_qty),0),
    'salesLinkedDocuments',count(*) FILTER(WHERE sales_linked_lines>0),
    'documents',COALESCE(jsonb_agg(to_jsonb(active_request)
      ORDER BY short_code,request_no),'[]'::jsonb)) details
FROM active_request;

WITH target_company(company_id,short_code) AS (
  VALUES
    ('4eedbf12-3c60-40e0-b2b7-1a48ca62b6f8'::uuid,'KMS'::text),
    ('809abdd9-d05f-4525-9726-1951a0ae1a81'::uuid,'SMS'::text),
    ('07bdffb9-8c56-444c-a49b-81ac86745674'::uuid,'LSM'::text)
), today_run AS (
  SELECT target.short_code,run.company_id,run.business_date,run.mode_snapshot,
    run.status,run.attempt_count,run.operation_id,run.error_code,
    run.last_attempted_at
  FROM target_company target
  JOIN public.companies company ON company.id=target.company_id
  LEFT JOIN public.purchase_daily_scheduler_runs run
    ON run.company_id=target.company_id
   AND run.business_date=(clock_timestamp() AT TIME ZONE company.timezone)::date
)
SELECT 'today_scheduler_reuse_boundary'::text check_name,
  CASE WHEN count(*) FILTER(WHERE status IN('GENERATED','NO_DEMAND'))=0
    THEN 'PASS' ELSE 'BLOCKER' END status,
  count(*) FILTER(WHERE status IN('GENERATED','NO_DEMAND'))::bigint violation_rows,
  jsonb_build_object(
    'rule','A GENERATED/NO_DEMAND run is reused and will not generate a replacement batch',
    'runs',COALESCE(jsonb_agg(to_jsonb(today_run) ORDER BY short_code),'[]'::jsonb)) details
FROM today_run;

WITH target_company(company_id,short_code) AS (
  VALUES
    ('4eedbf12-3c60-40e0-b2b7-1a48ca62b6f8'::uuid,'KMS'::text),
    ('809abdd9-d05f-4525-9726-1951a0ae1a81'::uuid,'SMS'::text),
    ('07bdffb9-8c56-444c-a49b-81ac86745674'::uuid,'LSM'::text)
), negative_stock AS (
  SELECT target.short_code,stock.company_id,stock.product_id,product.sku,
    product.name product_name,stock.warehouse_id,warehouse.name warehouse_name,
    stock.stock_qty on_hand_base_qty,-stock.stock_qty raw_replenishment_base_qty
  FROM target_company target
  JOIN public.product_stocks stock ON stock.company_id=target.company_id
  JOIN public.products product
    ON product.company_id=stock.company_id AND product.id=stock.product_id
  JOIN public.warehouses warehouse
    ON warehouse.company_id=stock.company_id AND warehouse.id=stock.warehouse_id
  WHERE stock.stock_qty<0 AND product.is_active AND warehouse.is_active
)
SELECT 'negative_on_hand_raw_target'::text check_name,'INFO'::text status,
  count(*)::bigint violation_rows,
  jsonb_build_object(
    'negativeStockRows',count(*),
    'rawReplenishmentBaseQty',COALESCE(sum(raw_replenishment_base_qty),0),
    'byCompany',COALESCE((SELECT jsonb_agg(to_jsonb(summary) ORDER BY short_code)
      FROM (SELECT short_code,count(*) negative_rows,
          sum(raw_replenishment_base_qty) raw_replenishment_base_qty
        FROM negative_stock GROUP BY short_code) summary),'[]'::jsonb),
    'rows',COALESCE(jsonb_agg(to_jsonb(negative_stock)
      ORDER BY short_code,product_name,warehouse_name),'[]'::jsonb)) details
FROM negative_stock;
