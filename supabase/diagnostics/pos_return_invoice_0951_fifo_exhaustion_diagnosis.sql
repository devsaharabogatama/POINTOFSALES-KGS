-- SELECT-only diagnosis for INV-20261101-0000000951.
-- Proves whether the Return failure comes from negative-stock lineage,
-- absent/incomplete positive FIFO, or FIFO already consumed by prior Returns.
WITH sale_scope AS (
  SELECT sale.company_id,sale.id sales_id,sale.invoice_no,
    sale.document_status,sale.sales_origin,sale.sales_process_mode,
    sale.sales_warehouse_id
  FROM public.sales_headers sale
  WHERE sale.invoice_no='INV-20261101-0000000951'
), detail_scope AS (
  SELECT sale.*,detail.id sales_detail_id,detail.product_id,
    detail.product_name_snapshot,detail.qty sold_quantity,
    private.odr6d_returnable_sales_detail_quantity(
      detail.company_id,detail.id) returnable_quantity
  FROM sale_scope sale
  JOIN public.sales_details detail
    ON detail.company_id=sale.company_id AND detail.sales_id=sale.sales_id
), posted_returns AS (
  SELECT line.company_id,line.source_sales_detail_id,
    COALESCE(sum(line.quantity_uom),0) posted_return_quantity
  FROM public.sales_return_lines line
  JOIN public.sales_return_documents document
    ON document.company_id=line.company_id AND document.id=line.document_id
   AND document.status='POSTED'
  JOIN detail_scope detail ON detail.company_id=line.company_id
    AND detail.sales_detail_id=line.source_sales_detail_id
  GROUP BY line.company_id,line.source_sales_detail_id
), requirement_scope AS (
  SELECT detail.*,requirement.id requirement_id,
    requirement.stock_product_id,requirement.quantity_base required_base,
    greatest(detail.returnable_quantity-
      COALESCE(posted.posted_return_quantity,0),0) visible_remaining_quantity
  FROM detail_scope detail
  JOIN public.sale_stock_requirements requirement
    ON requirement.company_id=detail.company_id
   AND requirement.sales_id=detail.sales_id
   AND requirement.sales_detail_id=detail.sales_detail_id
  LEFT JOIN posted_returns posted ON posted.company_id=detail.company_id
    AND posted.source_sales_detail_id=detail.sales_detail_id
), fifo_capacity AS (
  SELECT requirement.company_id,requirement.requirement_id,
    COALESCE(sum(allocation.quantity_base),0) positive_fifo_allocated_base,
    COALESCE(sum(allocation.quantity_base-COALESCE((
      SELECT sum(restoration.quantity_base)
      FROM public.sales_return_fifo_restorations restoration
      WHERE restoration.company_id=allocation.company_id
        AND restoration.source_sale_fifo_allocation_id=allocation.id
    ),0)),0) positive_fifo_remaining_base
  FROM requirement_scope requirement
  LEFT JOIN public.sale_fifo_allocations allocation
    ON allocation.company_id=requirement.company_id
   AND allocation.stock_requirement_id=requirement.requirement_id
  GROUP BY requirement.company_id,requirement.requirement_id
), negative_capacity AS (
  SELECT requirement.company_id,requirement.requirement_id,
    COALESCE(sum(negative.shortage_base_qty),0) negative_shortage_base,
    COALESCE(sum(negative.replenished_base_qty),0) negative_replenished_base
  FROM requirement_scope requirement
  LEFT JOIN public.negative_stock_sale_allocations negative
    ON negative.company_id=requirement.company_id
   AND negative.stock_requirement_id=requirement.requirement_id
  GROUP BY requirement.company_id,requirement.requirement_id
), diagnosis AS (
  SELECT requirement.*,
    round(requirement.required_base*requirement.visible_remaining_quantity/
      NULLIF(requirement.returnable_quantity,0),6) visible_return_required_base,
    fifo.positive_fifo_allocated_base,fifo.positive_fifo_remaining_base,
    negative.negative_shortage_base,negative.negative_replenished_base,
    CASE
      WHEN fifo.positive_fifo_remaining_base+0.000001 >=
        round(requirement.required_base*requirement.visible_remaining_quantity/
          NULLIF(requirement.returnable_quantity,0),6)
        THEN 'POSITIVE_FIFO_CAPACITY_AVAILABLE'
      WHEN negative.negative_shortage_base>0
        THEN 'NEGATIVE_STOCK_SOURCE_NOT_RESTORED_BY_CURRENT_RETURN_CORE'
      WHEN fifo.positive_fifo_allocated_base=0
        THEN 'SOURCE_HAS_NO_POSITIVE_FIFO_ALLOCATION'
      ELSE 'SOURCE_POSITIVE_FIFO_ALREADY_PARTLY_OR_FULLY_RESTORED'
    END classification
  FROM requirement_scope requirement
  JOIN fifo_capacity fifo ON fifo.company_id=requirement.company_id
    AND fifo.requirement_id=requirement.requirement_id
  JOIN negative_capacity negative ON negative.company_id=requirement.company_id
    AND negative.requirement_id=requirement.requirement_id
)
SELECT 'pos_return_invoice_0951_identity' check_name,
  CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
  abs(count(*)-1) violation_rows,
  jsonb_build_object('rows',count(*),'sales',COALESCE(jsonb_agg(
    jsonb_build_object('companyId',sale.company_id,'salesId',sale.sales_id,
      'invoiceNo',sale.invoice_no,'documentStatus',sale.document_status,
      'salesOrigin',sale.sales_origin,'salesProcessMode',sale.sales_process_mode)
  ),'[]'::jsonb)) details
FROM sale_scope sale
UNION ALL
SELECT 'pos_return_invoice_0951_fifo_lineage',
  CASE WHEN count(*)>0 THEN 'INFO' ELSE 'FAIL' END,
  CASE WHEN count(*)>0 THEN 0 ELSE 1 END,
  jsonb_build_object('rows',count(*),'requirements',COALESCE(jsonb_agg(
    jsonb_build_object(
      'salesDetailId',diagnosis.sales_detail_id,
      'productId',diagnosis.product_id,
      'productName',diagnosis.product_name_snapshot,
      'soldQuantity',diagnosis.sold_quantity,
      'returnableQuantity',diagnosis.returnable_quantity,
      'visibleRemainingQuantity',diagnosis.visible_remaining_quantity,
      'requiredBase',diagnosis.required_base,
      'visibleReturnRequiredBase',diagnosis.visible_return_required_base,
      'positiveFifoAllocatedBase',diagnosis.positive_fifo_allocated_base,
      'positiveFifoRemainingBase',diagnosis.positive_fifo_remaining_base,
      'negativeShortageBase',diagnosis.negative_shortage_base,
      'negativeReplenishedBase',diagnosis.negative_replenished_base,
      'classification',diagnosis.classification
    ) ORDER BY diagnosis.sales_detail_id,diagnosis.requirement_id
  ),'[]'::jsonb))
FROM diagnosis
UNION ALL
SELECT 'pos_return_invoice_0951_runtime_interpretation','INFO',0,
  jsonb_build_object(
    'listBehavior','UI remaining quantity uses sold/dispatch quantity minus Posted Return quantity',
    'postBehavior','physical Return restores only remaining sale_fifo_allocations',
    'error','SOURCE_SALE_FIFO_RESTORATION_EXHAUSTED',
    'mutation','NONE'
  );
