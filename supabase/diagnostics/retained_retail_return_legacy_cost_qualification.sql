-- SELECT-only qualification for the approved LEGACY_AGGREGATE_COST policy.
-- Proves how each retained Retail line cost can be assigned to its Stock
-- Requirement without guessing. Run the entire file; it performs no writes.
WITH
retained AS (
  SELECT sale.company_id,sale.id sales_id,sale.sales_warehouse_id
  FROM public.sales_headers sale
  JOIN public.company_sales_process_settings setting
    ON setting.company_id=sale.company_id
   AND setting.active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE'
  WHERE sale.sales_process_mode='RETAIL_CONFIRM_INVOICE'
    AND sale.document_status<>'CANCELED'
    AND (sale.document_status='POSTED'
      OR sale.order_runtime_status='DELIVERED'
      OR EXISTS(SELECT 1 FROM public.sales_delivery_documents delivery
        WHERE delivery.company_id=sale.company_id AND delivery.sales_id=sale.id
          AND delivery.status='DELIVERED'))
    AND NOT EXISTS(
      SELECT 1 FROM public.sales_process_cutover_items item
      JOIN public.sales_process_cutover_audit audit
        ON audit.company_id=item.company_id AND audit.cutover_item_id=item.id
      WHERE item.company_id=sale.company_id
        AND item.source_document_id=sale.id
        AND item.source_document_type='RETAIL_SALE'
        AND audit.action='APPLY_ITEM'
        AND audit.after_state->'converterResult'->>'targetDocumentType'=
          'BACKOFFICE_SALES_ORDER'
        AND nullif(audit.after_state->'converterResult'->>'targetDocumentId','')
          IS NOT NULL)
),
line_shape AS (
  SELECT detail.company_id,detail.sales_id,detail.id sales_detail_id,
    detail.fifo_cost_total detail_cost,detail.quantity_base detail_base_qty,
    count(requirement.id) requirement_rows,
    count(requirement.id) FILTER(WHERE bundle.id IS NOT NULL) bundle_cost_rows,
    COALESCE(sum(CASE
      WHEN bundle.id IS NOT NULL THEN bundle.fifo_cost_total
      WHEN requirement_count.rows=1 THEN detail.fifo_cost_total
      ELSE NULL END),0) assigned_cost,
    count(requirement.id) FILTER(WHERE
      bundle.id IS NULL AND requirement_count.rows<>1) unassignable_rows
  FROM retained
  JOIN public.sales_details detail ON detail.company_id=retained.company_id
    AND detail.sales_id=retained.sales_id
  JOIN LATERAL(SELECT count(*) rows FROM public.sale_stock_requirements candidate
    WHERE candidate.company_id=detail.company_id
      AND candidate.sales_detail_id=detail.id) requirement_count ON true
  LEFT JOIN public.sale_stock_requirements requirement
    ON requirement.company_id=detail.company_id
   AND requirement.sales_detail_id=detail.id
  LEFT JOIN public.bundle_sale_allocations bundle
    ON bundle.company_id=requirement.company_id
   AND bundle.stock_requirement_id=requirement.id
  GROUP BY detail.company_id,detail.sales_id,detail.id,detail.fifo_cost_total,
    detail.quantity_base,requirement_count.rows
),
requirement_group AS (
  SELECT requirement.company_id,requirement.sales_id,
    retained.sales_warehouse_id,requirement.stock_product_id,
    sum(requirement.quantity_base) requirement_base_qty
  FROM retained
  JOIN public.sale_stock_requirements requirement
    ON requirement.company_id=retained.company_id
   AND requirement.sales_id=retained.sales_id
  GROUP BY requirement.company_id,requirement.sales_id,
    retained.sales_warehouse_id,requirement.stock_product_id
),
movement_group AS (
  SELECT movement.company_id,movement.reference_id sales_id,
    movement.warehouse_id,movement.product_id,
    -sum(movement.qty_change) movement_base_qty,count(*) movement_rows
  FROM public.stock_movements movement
  JOIN retained ON retained.company_id=movement.company_id
    AND retained.sales_id=movement.reference_id
  WHERE movement.reference_table='sales_headers'
    AND movement.movement_type='SALE' AND movement.movement_status='POSTED'
    AND movement.qty_change<0
  GROUP BY movement.company_id,movement.reference_id,
    movement.warehouse_id,movement.product_id
),
movement_reconciliation AS (
  SELECT requirement.*,
    COALESCE(movement.movement_base_qty,0) movement_base_qty,
    COALESCE(movement.movement_rows,0) movement_rows
  FROM requirement_group requirement
  LEFT JOIN movement_group movement
    ON movement.company_id=requirement.company_id
   AND movement.sales_id=requirement.sales_id
   AND movement.warehouse_id=requirement.sales_warehouse_id
   AND movement.product_id=requirement.stock_product_id
),
checks AS (
  SELECT 'legacy_cost_assignment_contract' check_name,
    CASE WHEN count(*) FILTER(WHERE requirement_rows=0 OR unassignable_rows>0
      OR round(assigned_cost,4)<>round(detail_cost,4))=0
      THEN 'PASS' ELSE 'BLOCKER' END status,
    count(*) FILTER(WHERE requirement_rows=0 OR unassignable_rows>0
      OR round(assigned_cost,4)<>round(detail_cost,4))::bigint violation_rows,
    jsonb_build_object('lines',count(*),
      'singleRequirementLines',count(*) FILTER(WHERE requirement_rows=1),
      'multiRequirementLines',count(*) FILTER(WHERE requirement_rows>1),
      'zeroCostLines',count(*) FILTER(WHERE detail_cost=0),
      'unassignableLines',count(*) FILTER(WHERE unassignable_rows>0),
      'costMismatchLines',count(*) FILTER(WHERE
        round(assigned_cost,4)<>round(detail_cost,4)),
      'detailCostTotal',COALESCE(sum(detail_cost),0),
      'assignedCostTotal',COALESCE(sum(assigned_cost),0),
      'policy','LEGACY_AGGREGATE_COST') details
  FROM line_shape
  UNION ALL
  SELECT 'legacy_stock_movement_reconciliation',
    CASE WHEN count(*) FILTER(WHERE movement_rows<>1 OR
      round(movement_base_qty,6)<>round(requirement_base_qty,6))=0
      THEN 'PASS' ELSE 'BLOCKER' END,
    count(*) FILTER(WHERE movement_rows<>1 OR
      round(movement_base_qty,6)<>round(requirement_base_qty,6))::bigint,
    jsonb_build_object('requirementGroups',count(*),
      'missingOrDuplicateMovementGroups',count(*) FILTER(WHERE movement_rows<>1),
      'quantityMismatchGroups',count(*) FILTER(WHERE
        round(movement_base_qty,6)<>round(requirement_base_qty,6)),
      'requiredBaseQty',COALESCE(sum(requirement_base_qty),0),
      'movementBaseQty',COALESCE(sum(movement_base_qty),0))
  FROM movement_reconciliation
  UNION ALL
  SELECT 'legacy_cost_zero_line_inventory','INFO',0,
    jsonb_build_object('lines',COALESCE(jsonb_agg(jsonb_build_object(
      'companyId',line.company_id,'salesId',line.sales_id,
      'salesDetailId',line.sales_detail_id,'baseQty',line.detail_base_qty,
      'requirementRows',line.requirement_rows) ORDER BY line.company_id,
      line.sales_id,line.sales_detail_id) FILTER(WHERE line.detail_cost=0),'[]'::jsonb),
      'approvedHandling','Preserve zero historical cost and mark LEGACY_AGGREGATE_COST')
  FROM line_shape line
)
SELECT check_name,status,violation_rows,details
FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,
  check_name;
