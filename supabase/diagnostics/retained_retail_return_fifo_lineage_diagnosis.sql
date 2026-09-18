-- SELECT-only diagnosis for retained Retail sources whose canonical
-- sale_fifo_allocations are absent. Run the entire file. No writes.
WITH
retained AS (
  SELECT sale.company_id,sale.id sales_id,sale.invoice_no,sale.created_at
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
      SELECT 1
      FROM public.sales_process_cutover_items item
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
source_lines AS (
  SELECT retained.company_id,retained.sales_id,detail.id sales_detail_id,
    detail.product_id,detail.qty,detail.quantity_base,
    detail.fifo_cost_total,
    (SELECT count(*) FROM public.sale_stock_requirements requirement
      WHERE requirement.company_id=detail.company_id
        AND requirement.sales_detail_id=detail.id) requirement_rows,
    COALESCE((SELECT sum(requirement.quantity_base)
      FROM public.sale_stock_requirements requirement
      WHERE requirement.company_id=detail.company_id
        AND requirement.sales_detail_id=detail.id),0) requirement_base_qty,
    (SELECT count(*) FROM public.sale_fifo_allocations allocation
      WHERE allocation.company_id=detail.company_id
        AND allocation.sales_detail_id=detail.id) allocation_rows,
    COALESCE((SELECT sum(allocation.quantity_base)
      FROM public.sale_fifo_allocations allocation
      WHERE allocation.company_id=detail.company_id
        AND allocation.sales_detail_id=detail.id),0) allocation_base_qty,
    COALESCE((SELECT sum(allocation.fifo_cost_total)
      FROM public.sale_fifo_allocations allocation
      WHERE allocation.company_id=detail.company_id
        AND allocation.sales_detail_id=detail.id),0) allocation_cost
  FROM retained
  JOIN public.sales_details detail
    ON detail.company_id=retained.company_id AND detail.sales_id=retained.sales_id
),
source_events AS (
  SELECT retained.company_id,retained.sales_id,
    count(event.id) event_rows,
    count(event.id) FILTER(WHERE event.system_event_key='SALE_POSTED') sale_event_rows,
    COALESCE(sum(CASE WHEN event.amounts ? 'fifoCostTotal'
      THEN (event.amounts->>'fifoCostTotal')::numeric ELSE 0 END),0) event_fifo_cost
  FROM retained
  LEFT JOIN public.financial_events event
    ON event.company_id=retained.company_id AND event.root_sales_id=retained.sales_id
  GROUP BY retained.company_id,retained.sales_id
),
movement_refs AS (
  SELECT movement.reference_table,count(*) rows
  FROM public.stock_movements movement
  JOIN retained ON retained.company_id=movement.company_id
    AND movement.reference_id=retained.sales_id
  GROUP BY movement.reference_table
),
checks AS (
  SELECT 'retained_fifo_line_cost_shape' check_name,'INFO' status,
    jsonb_build_object(
      'lines',count(*),
      'positiveDetailFifoCost',count(*) FILTER(WHERE fifo_cost_total>0),
      'zeroDetailFifoCost',count(*) FILTER(WHERE fifo_cost_total=0),
      'positiveRequirementRows',count(*) FILTER(WHERE requirement_rows>0),
      'zeroRequirementRows',count(*) FILTER(WHERE requirement_rows=0),
      'positiveAllocationRows',count(*) FILTER(WHERE allocation_rows>0),
      'zeroAllocationRows',count(*) FILTER(WHERE allocation_rows=0),
      'detailFifoCostTotal',COALESCE(sum(fifo_cost_total),0),
      'allocationFifoCostTotal',COALESCE(sum(allocation_cost),0)) details
  FROM source_lines
  UNION ALL
  SELECT 'retained_fifo_requirement_reconciliation','INFO',
    jsonb_build_object(
      'linesWithRequirementQtyMismatch',count(*) FILTER(WHERE requirement_rows>0
        AND round(requirement_base_qty,6)<>round(quantity_base,6)),
      'requirementsWithoutAllocations',count(*) FILTER(WHERE requirement_rows>0
        AND allocation_rows=0),
      'allocationsBelowRequirement',count(*) FILTER(WHERE requirement_rows>0
        AND round(allocation_base_qty,6)<round(requirement_base_qty,6)))
  FROM source_lines
  UNION ALL
  SELECT 'retained_fifo_finance_event_shape','INFO',
    jsonb_build_object(
      'sales',count(*),
      'salesWithEvents',count(*) FILTER(WHERE event_rows>0),
      'salesWithPostedSaleEvent',count(*) FILTER(WHERE sale_event_rows>0),
      'salesWithPositiveEventFifoCost',count(*) FILTER(WHERE event_fifo_cost>0),
      'eventFifoCostTotal',COALESCE(sum(event_fifo_cost),0))
  FROM source_events
  UNION ALL
  SELECT 'retained_fifo_direct_movement_reference','INFO',
    jsonb_build_object('references',COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'referenceTable',reference_table,'rows',rows) ORDER BY reference_table)
      FROM movement_refs),'[]'::jsonb))
  UNION ALL
  SELECT 'retained_fifo_company_inventory','INFO',
    jsonb_build_object('companies',COALESCE(jsonb_agg(jsonb_build_object(
      'companyId',company.id,'companyName',company.company_name,'sales',inventory.sales,
      'lines',inventory.lines,'firstCreatedAt',inventory.first_created_at,
      'lastCreatedAt',inventory.last_created_at) ORDER BY company.company_name),'[]'::jsonb))
  FROM (
    SELECT retained.company_id,count(DISTINCT retained.sales_id) sales,
      count(source_lines.sales_detail_id) lines,min(retained.created_at) first_created_at,
      max(retained.created_at) last_created_at
    FROM retained JOIN source_lines ON source_lines.company_id=retained.company_id
      AND source_lines.sales_id=retained.sales_id
    GROUP BY retained.company_id
  ) inventory
  JOIN public.companies company ON company.id=inventory.company_id
)
SELECT check_name,status,details FROM checks ORDER BY check_name;
