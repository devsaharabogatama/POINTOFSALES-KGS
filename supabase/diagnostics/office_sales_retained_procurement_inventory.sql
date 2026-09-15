-- Read-only impact inventory for the confirmed Production cutover defect.
-- Run the ENTIRE file in Production SQL Editor; export the complete result.
-- No cancellation, reservation release, demand/RO/PO mutation, or mode switch.
-- Includes all nonterminal Retail sources, not only the nine reported sources.
-- INFO is factual inventory, NOT migration/behavioral readiness PASS.
WITH sources AS (
  SELECT sale.*, company.company_name, setting.active_mode
  FROM public.sales_headers sale
  JOIN public.companies company ON company.id=sale.company_id
  JOIN public.company_sales_process_settings setting ON setting.company_id=sale.company_id
  WHERE sale.sales_process_mode='RETAIL_CONFIRM_INVOICE'
    AND sale.document_status='DRAFT'
    AND sale.order_runtime_status IN
      ('DRAFT_INPUT','SCHEDULED','CONFIRMED','RESERVED','PARTIALLY_DISPATCHED','DISPATCHED')
), inventory AS (
  SELECT source.company_id, source.company_name, source.id source_sales_id,
    COALESCE(source.draft_no,source.invoice_no) source_document_no,
    'INFO'::text status,
    jsonb_build_object(
      'activeMode',source.active_mode,
      'runtimeStatus',source.order_runtime_status,
      'sourceMasterVersion',source.master_version,
      'sessionId',source.session_id,
      'sessionStatus',(SELECT session.status FROM public.cashier_sessions session
        WHERE session.company_id=source.company_id AND session.id=source.session_id),
      'warehouseId',source.sales_warehouse_id,
      'reservation',COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'id',reservation.id,'status',reservation.status,
        'dispatchedBaseQty',reservation.total_dispatched_base_qty))
        FROM public.sales_stock_reservations reservation
        WHERE reservation.company_id=source.company_id AND reservation.sales_id=source.id),'[]'::jsonb),
      'hasDispatchEffect',EXISTS(SELECT 1 FROM public.sales_dispatch_financial_effects effect
        WHERE effect.company_id=source.company_id AND effect.sales_id=source.id),
      'hasPayment',EXISTS(SELECT 1 FROM public.sales_payments payment
        WHERE payment.company_id=source.company_id AND payment.sales_id=source.id
          AND NOT payment.is_reversal),
      'hasPendingOrVerifiedPayment',EXISTS(SELECT 1 FROM public.sales_payment_verification_requests request
        WHERE request.company_id=source.company_id AND request.sales_id=source.id
          AND request.status IN('PENDING','VERIFIED')),
      'hasInvoiceSnapshot',EXISTS(SELECT 1 FROM public.sales_invoice_snapshots invoice
        WHERE invoice.company_id=source.company_id AND invoice.sales_id=source.id),
      'hasPendingRevision',EXISTS(SELECT 1 FROM public.sales_order_revisions revision
        WHERE revision.company_id=source.company_id
          AND (revision.source_sales_id=source.id OR revision.replacement_sales_id=source.id)
          AND revision.status='PENDING'),
      'procurementLines',COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'demandLineId',line.id,'demandId',line.demand_id,'status',line.status,
        'reservationLineId',line.reservation_line_id,
        'demandBaseQty',line.demand_base_qty,'releasedBaseQty',line.released_base_qty,
        'requestLineId',line.stock_request_line_id,
        'requestDocumentId',demand.stock_request_document_id,
        'requestStatus',(SELECT request.status FROM public.stock_request_documents request
          WHERE request.company_id=source.company_id AND request.id=demand.stock_request_document_id),
        'supplierOrders',COALESCE((SELECT jsonb_agg(jsonb_build_object(
          'allocationId',allocation.id,'allocatedBaseQty',allocation.allocated_base_qty,
          'orderId',purchase.id,'orderStatus',purchase.status,'orderLineId',order_line.id,
          'receipts',COALESCE((SELECT jsonb_agg(jsonb_build_object(
            'id',receipt.id,'status',receipt.status,'receivedBaseQty',receipt_line.received_base_qty))
            FROM public.goods_receipt_lines receipt_line
            JOIN public.goods_receipt_documents receipt ON receipt.company_id=receipt_line.company_id
              AND receipt.id=receipt_line.document_id
            WHERE receipt_line.company_id=source.company_id
              AND receipt_line.supplier_order_line_id=order_line.id),'[]'::jsonb)))
          FROM public.supplier_order_request_allocations allocation
          JOIN public.supplier_order_lines order_line ON order_line.company_id=allocation.company_id
            AND order_line.id=allocation.supplier_order_line_id
          JOIN public.supplier_order_documents purchase ON purchase.company_id=order_line.company_id
            AND purchase.id=order_line.document_id
          WHERE allocation.company_id=source.company_id
            AND allocation.stock_request_line_id=line.stock_request_line_id),'[]'::jsonb))
        ORDER BY line.id)
        FROM public.sales_order_procurement_demand_lines line
        JOIN public.sales_order_procurement_demands demand ON demand.company_id=line.company_id
          AND demand.id=line.demand_id
        WHERE line.company_id=source.company_id AND line.sales_id=source.id),'[]'::jsonb),
      'cutoverItems',COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'planId',plan.id,'planStatus',plan.status,'itemId',item.id,
        'decision',item.decision,'itemStatus',item.item_status,'blockerCodes',item.blocker_codes,
        'targetId',item.target_document_id,'targetNo',item.target_document_no)
        ORDER BY plan.created_at,item.id)
        FROM public.sales_process_cutover_items item
        JOIN public.sales_process_cutover_plans plan ON plan.company_id=item.company_id
          AND plan.id=item.cutover_plan_id
        WHERE item.company_id=source.company_id AND item.source_document_id=source.id
          AND item.source_document_type='RETAIL_SALE'),'[]'::jsonb)
    ) details
  FROM sources source
)
SELECT * FROM inventory ORDER BY company_id,source_document_no,source_sales_id;
