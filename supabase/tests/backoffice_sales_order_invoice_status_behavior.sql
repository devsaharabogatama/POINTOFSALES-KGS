-- Rollback-only reconciliation against canonical ledgers. Requires one existing Backoffice SO.
DO $test$
DECLARE v_company uuid;v_order uuid;v_summary jsonb;v_expected text;v_delivered numeric;
  v_remaining numeric;v_draft uuid;v_posted integer;v_fee numeric;v_fee_allocated numeric;
BEGIN
  SELECT document.company_id,document.id INTO v_company,v_order
  FROM public.backoffice_sales_orders document WHERE document.order_no IS NOT NULL
  ORDER BY document.updated_at DESC,document.id LIMIT 1;
  IF v_order IS NULL THEN RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: one canonical Backoffice Sales Order required'; END IF;

  SELECT COALESCE(sum(line.net_delivered_base_qty),0),COALESCE(sum(line.to_invoice_base_qty),0)
  INTO v_delivered,v_remaining FROM public.backoffice_sales_order_lines line
  WHERE line.company_id=v_company AND line.sales_order_id=v_order;
  v_delivered:=v_delivered+COALESCE((SELECT sum(line.accepted_overage_base_qty)
    FROM public.backoffice_sales_delivery_discrepancy_lines line
    WHERE line.company_id=v_company AND line.sales_order_id=v_order
      AND line.requested_resolution='ACCEPT_OVERAGE' AND line.commercial_approval_status='APPROVED'
      AND line.warehouse_resolution_status='RESOLVED'),0);
  v_remaining:=v_remaining+COALESCE((SELECT sum(line.overage_to_invoice_base_qty)
    FROM public.backoffice_sales_delivery_discrepancy_lines line
    WHERE line.company_id=v_company AND line.sales_order_id=v_order
      AND line.requested_resolution='ACCEPT_OVERAGE' AND line.commercial_approval_status='APPROVED'
      AND line.warehouse_resolution_status='RESOLVED'),0);
  SELECT (array_agg(invoice.id ORDER BY invoice.created_at DESC,invoice.id DESC)
      FILTER(WHERE invoice.status='DRAFT'))[1],count(*) FILTER(WHERE invoice.status='POSTED'),
    COALESCE(sum(invoice.delivery_fee_amount) FILTER(WHERE invoice.invoice_type='REGULAR'
      AND invoice.status IN('DRAFT','POSTED')),0)
  INTO v_draft,v_posted,v_fee_allocated FROM public.backoffice_sales_invoices invoice
  WHERE invoice.company_id=v_company AND invoice.sales_order_id=v_order;
  SELECT CASE WHEN v_delivered>0 THEN document.delivery_fee_amount ELSE 0 END
  INTO v_fee FROM public.backoffice_sales_orders document
  WHERE document.company_id=v_company AND document.id=v_order;
  v_remaining:=v_remaining+greatest(0,v_fee-v_fee_allocated);
  v_expected:=CASE WHEN v_draft IS NOT NULL THEN 'DRAFT'
    WHEN v_posted>0 AND v_delivered+v_fee>0 AND v_remaining=0 THEN 'INVOICED'
    WHEN v_posted>0 THEN 'PARTIALLY_INVOICED'
    WHEN v_remaining>0 THEN 'READY' ELSE 'NOT_READY' END;
  v_summary:=private.backoffice_sales_order_invoice_summary(v_company,v_order);
  IF v_summary->>'invoiceStatus'<>v_expected OR (v_summary->>'draftInvoiceId') IS DISTINCT FROM v_draft::text THEN
    RAISE EXCEPTION 'TEST_FAILED: SO Invoice summary drift: %',v_summary;
  END IF;
  RAISE NOTICE 'TEST_PASSED: reconciled SO %, status %, summary %',v_order,v_expected,v_summary;
END
$test$;
