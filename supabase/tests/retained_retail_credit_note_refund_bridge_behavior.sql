-- Authenticated rollback-only behavior for retained Retail financial correction.
-- Builds its own retained Return and receipt from an eligible delivered Retail
-- source, then rolls every Return/receipt/allocation/Credit Note/Refund write back.
BEGIN;

DO $test$
DECLARE
  v_actor uuid;v_company uuid;v_return uuid;v_sale uuid;v_customer uuid;v_store uuid;
  v_detail uuid;v_return_line uuid;v_warehouse uuid;v_qty numeric(24,6);
  v_version bigint;v_today date;v_method uuid;v_proof_mode text;v_outstanding numeric(24,4);
  v_saved jsonb;v_submitted jsonb;v_approved jsonb;v_receipt jsonb;
  v_payment_amount numeric(24,4);v_payment jsonb;v_allocations jsonb;v_allocate jsonb;
  v_retry jsonb;v_note uuid;
  v_note_version bigint;v_note_total numeric(24,4);v_ar_reduction numeric(24,4);
  v_refund_liability numeric(24,4);
  v_post jsonb;v_refund jsonb;v_reversal jsonb;v_refund_id uuid;v_refund_version bigint;
  v_allocate_operation uuid:=gen_random_uuid();v_post_operation uuid:=gen_random_uuid();
  v_refund_operation uuid:=gen_random_uuid();v_reversal_operation uuid:=gen_random_uuid();
  v_stale_rejected boolean:=false;v_source_header jsonb;v_source_invoice jsonb;
  v_source_lines jsonb;v_native_returns bigint;v_stock_movements bigint;v_aging jsonb;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260918150000') THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: retained Retail Credit Note bridge required';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260919131000') THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: retained Retail AR-first split fix required';
  END IF;
  SELECT profile.id INTO v_actor FROM public.profiles profile
  JOIN auth.users auth_user ON auth_user.id=profile.id
  WHERE profile.role='super_admin'::public.user_role ORDER BY profile.id LIMIT 1;
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: authenticated super_admin fixture unavailable';
  END IF;

  -- Do not depend on a previously received-but-unallocated Return. That pool is
  -- consumed by normal use and made this test fail with P0002 on every rerun.
  -- Select only the immutable delivered Retail source; the test creates all
  -- mutable prerequisites below and the outer transaction rolls them back.
  SELECT sale.company_id,sale.id,sale.customer_id,sale.store_id,detail.id,
    candidate.quantity_uom,candidate.outstanding,
    (clock_timestamp() AT TIME ZONE company.timezone)::date
  INTO v_company,v_sale,v_customer,v_store,v_detail,v_qty,v_outstanding,v_today
  FROM public.sales_headers sale
  JOIN public.company_sales_process_settings setting ON setting.company_id=sale.company_id
    AND setting.active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE'
  JOIN public.sales_details detail ON detail.company_id=sale.company_id AND detail.sales_id=sale.id
  JOIN public.uoms uom ON uom.company_id=detail.company_id AND uom.id=detail.sale_uom_id
  JOIN public.companies company ON company.id=sale.company_id AND company.status='ACTIVE'
  JOIN public.customers customer ON customer.company_id=sale.company_id
    AND customer.id=sale.customer_id AND NOT customer.is_system_customer
  JOIN LATERAL(SELECT detail.quantity_base
      -COALESCE((SELECT sum(line.quantity_base) FROM public.sales_return_lines line
        JOIN public.sales_return_documents document ON document.company_id=line.company_id
          AND document.id=line.document_id
        WHERE line.company_id=detail.company_id AND line.source_sales_detail_id=detail.id
          AND document.status='POSTED'),0)
      -COALESCE((SELECT sum(line.requested_base_qty)
        FROM public.backoffice_sales_return_lines line
        JOIN public.backoffice_sales_returns document ON document.company_id=line.company_id
          AND document.id=line.return_id
        WHERE line.company_id=detail.company_id AND line.retail_sales_detail_id=detail.id
          AND document.status NOT IN('DRAFT','CANCELED')),0) base_qty) available ON true
  JOIN LATERAL(SELECT greatest(0,round(
      private.odr6d_dispatched_receivable_before_receipts(
        sale.company_id,sale.id,(clock_timestamp() AT TIME ZONE company.timezone)::date)
      -COALESCE((SELECT sum(allocation.allocated_amount)
        FROM public.customer_receipt_allocations allocation
        JOIN public.customer_receipt_documents receipt
          ON receipt.company_id=allocation.company_id AND receipt.id=allocation.document_id
          AND receipt.status='POSTED'
        WHERE allocation.company_id=sale.company_id AND allocation.sales_id=sale.id),0)
      -COALESCE((SELECT sum(note.ar_reduction_amount)
        FROM public.backoffice_sales_credit_notes note
        WHERE note.company_id=sale.company_id AND note.source_kind='RETAINED_RETAIL'
          AND note.source_retail_sales_id=sale.id AND note.status='POSTED'),0),4)) outstanding
    ) receivable ON true
  JOIN LATERAL(SELECT receivable.outstanding,
      CASE WHEN uom.allow_decimal THEN
        round(least(available.base_qty/detail.uom_factor_to_base_snapshot,
          receivable.outstanding*1.5/nullif(
            (detail.line_total+detail.allocated_document_rounding)/detail.qty,0)),6)
      ELSE floor(least(available.base_qty/detail.uom_factor_to_base_snapshot,
          receivable.outstanding*1.5/nullif(
            (detail.line_total+detail.allocated_document_rounding)/detail.qty,0))) END quantity_uom
    ) candidate ON candidate.quantity_uom>0
  WHERE sale.sales_process_mode='RETAIL_CONFIRM_INVOICE'
    AND sale.document_status<>'CANCELED' AND sale.is_tempo
    AND (sale.document_status='POSTED' OR sale.order_runtime_status='DELIVERED'
      OR EXISTS(SELECT 1 FROM public.sales_delivery_documents delivery
        WHERE delivery.company_id=sale.company_id AND delivery.sales_id=sale.id
          AND delivery.status='DELIVERED'))
    AND available.base_qty>0 AND receivable.outstanding>0
    AND detail.qty>0 AND detail.line_total+detail.allocated_document_rounding>0
    AND (SELECT count(*) FROM public.sale_stock_requirements requirement
      WHERE requirement.company_id=detail.company_id
        AND requirement.sales_detail_id=detail.id)=1
    AND EXISTS(SELECT 1 FROM public.sale_stock_requirements requirement
      WHERE requirement.company_id=detail.company_id
        AND requirement.sales_detail_id=detail.id
        AND requirement.commercial_product_id=detail.product_id
        AND requirement.stock_product_id=detail.product_id)
    AND NOT EXISTS(SELECT 1 FROM public.sales_process_cutover_items item
      JOIN public.sales_process_cutover_audit audit ON audit.company_id=item.company_id
        AND audit.cutover_item_id=item.id
      WHERE item.company_id=sale.company_id AND item.source_document_id=sale.id
        AND item.source_document_type='RETAIL_SALE' AND audit.action='APPLY_ITEM'
        AND audit.after_state->'converterResult'->>'targetDocumentType'='BACKOFFICE_SALES_ORDER'
        AND nullif(audit.after_state->'converterResult'->>'targetDocumentId','') IS NOT NULL)
    AND EXISTS(SELECT 1 FROM public.accounting_periods period
      WHERE period.company_id=sale.company_id
        AND (clock_timestamp() AT TIME ZONE company.timezone)::date
          BETWEEN period.start_date AND period.end_date
        AND period.status IN('OPEN','REOPENED'))
  ORDER BY sale.created_at DESC,detail.id LIMIT 1;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: no eligible delivered tempo Retail line with positive returnable quantity and receivable';
  END IF;

  PERFORM set_config('request.jwt.claim.sub',v_actor::text,true);
  INSERT INTO public.user_active_company_contexts(user_id,company_id)
  VALUES(v_actor,v_company) ON CONFLICT(user_id) DO UPDATE
  SET company_id=excluded.company_id,selected_at=clock_timestamp(),updated_at=clock_timestamp();

  SELECT warehouse.id INTO v_warehouse FROM public.warehouses warehouse
  WHERE warehouse.company_id=v_company AND warehouse.is_active
  ORDER BY warehouse.is_purchase_destination DESC,warehouse.id LIMIT 1;
  IF v_warehouse IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: selected Company has no active Warehouse';
  END IF;

  v_saved:=public.save_retained_retail_backoffice_return_draft(
    NULL,NULL,gen_random_uuid(),v_sale,jsonb_build_object(
      'reason','Retained Credit/Refund rollback-only test',
      'notes','All generated Return prerequisites are rolled back',
      'lines',jsonb_build_array(jsonb_build_object(
        'retailSalesDetailId',v_detail,'quantityUom',v_qty))));
  v_return:=(v_saved->'data'->>'id')::uuid;
  SELECT line.id INTO v_return_line FROM public.backoffice_sales_return_lines line
  WHERE line.company_id=v_company AND line.return_id=v_return;
  IF v_return_line IS NULL THEN
    RAISE EXCEPTION 'TEST_FAILED: generated retained Return line missing';
  END IF;
  v_submitted:=public.submit_backoffice_sales_return(v_return,
    (v_saved->'data'->>'masterVersion')::bigint,gen_random_uuid());
  v_approved:=public.approve_backoffice_sales_return(v_return,
    (v_submitted->'data'->>'masterVersion')::bigint,gen_random_uuid());
  v_receipt:=public.post_backoffice_sales_return_receipt(v_return,
    (v_approved->'data'->>'masterVersion')::bigint,gen_random_uuid(),v_today,
    jsonb_build_array(jsonb_build_object('returnLineId',v_return_line,
      'quantityUom',v_qty,'warehouseId',v_warehouse,'disposition','DESTROY',
      'notes','Rollback-only financial bridge fixture')),NULL);
  SELECT document.master_version INTO v_version
  FROM public.backoffice_sales_returns document
  WHERE document.company_id=v_company AND document.id=v_return;
  IF v_version IS NULL OR v_receipt->'data'->>'status'<>'RECEIVED' THEN
    RAISE EXCEPTION 'TEST_FAILED: generated retained Return receipt invalid';
  END IF;

  SELECT method.id,method.proof_mode INTO v_method,v_proof_mode
  FROM public.payment_methods method
  WHERE method.company_id=v_company AND method.is_active
    AND method.settlement_route IN('CASH_DRAWER','DIRECT_BANK')
    AND method.effective_from<=((v_today::text||' 23:59:59')::timestamp
      AT TIME ZONE (SELECT timezone FROM public.companies WHERE id=v_company))
    AND (method.effective_to IS NULL OR method.effective_to>=((v_today::text||' 00:00:00')::timestamp
      AT TIME ZONE (SELECT timezone FROM public.companies WHERE id=v_company)))
    AND (method.available_all_stores OR EXISTS(SELECT 1
      FROM public.payment_method_store_assignments assignment
      WHERE assignment.company_id=v_company AND assignment.payment_method_id=method.id
        AND assignment.store_id=v_store))
  ORDER BY CASE WHEN method.settlement_route='DIRECT_BANK' THEN 0 ELSE 1 END,
    method.is_default DESC,method.id LIMIT 1;
  IF v_method IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: active Customer Receipt/Refund payment method unavailable for selected Company and Store';
  END IF;

  SELECT greatest(0,round(private.odr6d_dispatched_receivable_before_receipts(
      sale.company_id,sale.id,v_today)-COALESCE((SELECT sum(allocation.allocated_amount)
      FROM public.customer_receipt_allocations allocation
      JOIN public.customer_receipt_documents receipt ON receipt.company_id=allocation.company_id
        AND receipt.id=allocation.document_id AND receipt.status='POSTED'
      WHERE allocation.company_id=sale.company_id AND allocation.sales_id=sale.id),0)
      -COALESCE((SELECT sum(note.ar_reduction_amount)
        FROM public.backoffice_sales_credit_notes note
        WHERE note.company_id=sale.company_id AND note.source_kind='RETAINED_RETAIL'
          AND note.source_retail_sales_id=sale.id AND note.status='POSTED'),0),4))
  INTO v_outstanding FROM public.sales_headers sale
  WHERE sale.company_id=v_company AND sale.id=v_sale;
  SELECT jsonb_agg(jsonb_build_object(
      'returnReceiptLineId',receipt_line.id,'allocationType','RETAIL_POSTED_INVOICE',
      'retailSalesId',v_sale,'retailSalesDetailId',return_line.retail_sales_detail_id,
      'quantityUom',round((receipt_line.received_base_qty-COALESCE((SELECT sum(allocation.allocated_base_qty)
        FROM public.backoffice_sales_return_invoice_allocations allocation
        WHERE allocation.company_id=receipt_line.company_id
          AND allocation.return_receipt_line_id=receipt_line.id),0))/receipt_line.base_qty_per_uom,6))
    ORDER BY receipt_line.created_at,receipt_line.id)
  INTO v_allocations
  FROM public.backoffice_sales_return_receipt_lines receipt_line
  JOIN public.backoffice_sales_return_lines return_line
    ON return_line.company_id=receipt_line.company_id AND return_line.id=receipt_line.return_line_id
  WHERE receipt_line.company_id=v_company AND receipt_line.return_id=v_return
    AND receipt_line.received_base_qty>COALESCE((SELECT sum(allocation.allocated_base_qty)
      FROM public.backoffice_sales_return_invoice_allocations allocation
      WHERE allocation.company_id=receipt_line.company_id
        AND allocation.return_receipt_line_id=receipt_line.id),0);
  IF v_allocations IS NULL OR jsonb_array_length(v_allocations)=0 THEN
    RAISE EXCEPTION 'TEST_FAILED: generated retained receipt has no allocatable lines';
  END IF;

  v_allocate:=public.allocate_backoffice_sales_return_invoices(
    v_return,v_version,v_allocate_operation,v_allocations);
  v_retry:=public.allocate_backoffice_sales_return_invoices(
    v_return,v_version,v_allocate_operation,v_allocations);
  IF COALESCE((v_retry->>'exactRetry')::boolean,false) IS NOT TRUE THEN
    RAISE EXCEPTION 'TEST_FAILED: retained allocation exact retry invalid';
  END IF;
  BEGIN
    PERFORM public.allocate_backoffice_sales_return_invoices(
      v_return,v_version,gen_random_uuid(),v_allocations);
  EXCEPTION WHEN OTHERS THEN
    v_stale_rejected:=position('MASTER_VERSION_CONFLICT' IN SQLERRM)>0;
  END;
  IF NOT v_stale_rejected THEN
    RAISE EXCEPTION 'TEST_FAILED: retained allocation stale version accepted';
  END IF;

  SELECT note.id,note.master_version,note.grand_total INTO
    v_note,v_note_version,v_note_total
  FROM public.backoffice_sales_credit_notes note
  WHERE note.company_id=v_company AND note.return_id=v_return
    AND note.source_kind='RETAINED_RETAIL' AND note.status='DRAFT';
  IF v_note IS NULL OR v_note_total<=0 THEN
    RAISE EXCEPTION 'TEST_FAILED: retained allocation did not create a positive Draft Credit Note';
  END IF;
  IF v_outstanding<v_note_total/2 THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: generated Credit Note cannot produce the required partial AR/refund split';
  END IF;

  -- Leave exactly half of the Credit Note value outstanding whenever the
  -- source still has a larger receivable. This exercises both AR reduction
  -- and Refund liability in one rollback-only transaction.
  v_payment_amount:=greatest(0,round(v_outstanding-v_note_total/2,4));
  IF v_payment_amount>0 THEN
    IF NOT (SELECT is_tempo FROM public.sales_headers
      WHERE company_id=v_company AND id=v_sale) THEN
      RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: selected retained Retail source has unpaid non-tempo balance';
    END IF;
    v_payment:=public.save_customer_receipt_allocated_draft(NULL,NULL,v_customer,v_today,
      v_method,'RETAINED-RETURN-ROLLBACK',
      CASE WHEN v_proof_mode='REQUIRED' THEN 'https://example.invalid/rollback-only-proof' ELSE NULL END,
      'Rollback-only payment to exercise Refund bridge',v_payment_amount,
      jsonb_build_array(jsonb_build_object('sourceType','RETAIL_SALE','sourceId',v_sale,
        'clientAllocationKey',gen_random_uuid(),'allocatedAmount',v_payment_amount)));
    PERFORM public.post_customer_receipt_unified((v_payment->>'documentId')::uuid,
      (v_payment->>'masterVersion')::bigint,gen_random_uuid());
  END IF;

  SELECT to_jsonb(sale) INTO v_source_header FROM public.sales_headers sale
    WHERE sale.company_id=v_company AND sale.id=v_sale;
  SELECT to_jsonb(invoice) INTO v_source_invoice FROM public.sales_invoice_snapshots invoice
    WHERE invoice.company_id=v_company AND invoice.sales_id=v_sale;
  SELECT jsonb_agg(to_jsonb(detail) ORDER BY detail.id) INTO v_source_lines
    FROM public.sales_details detail WHERE detail.company_id=v_company AND detail.sales_id=v_sale;
  IF v_source_header IS NULL OR v_source_invoice IS NULL OR v_source_lines IS NULL THEN
    RAISE EXCEPTION 'TEST_FAILED: retained Retail source snapshot incomplete';
  END IF;
  SELECT count(*) INTO v_native_returns FROM public.sales_return_documents
    WHERE company_id=v_company AND source_sales_id=v_sale;
  SELECT count(*) INTO v_stock_movements FROM public.stock_movements WHERE company_id=v_company;

  v_post:=public.post_backoffice_sales_credit_note(v_note,v_note_version,v_post_operation);
  v_retry:=public.post_backoffice_sales_credit_note(v_note,v_note_version,v_post_operation);
  IF COALESCE((v_retry->>'exactRetry')::boolean,false) IS NOT TRUE THEN
    RAISE EXCEPTION 'TEST_FAILED: retained Credit Note exact retry invalid';
  END IF;
  SELECT master_version,ar_reduction_amount,refund_liability_amount
  INTO v_note_version,v_ar_reduction,v_refund_liability
  FROM public.backoffice_sales_credit_notes WHERE company_id=v_company AND id=v_note;
  IF v_note_version IS NULL THEN
    RAISE EXCEPTION 'TEST_FAILED: posted retained Credit Note missing';
  END IF;
  IF v_ar_reduction<=0 OR v_refund_liability<=0 OR
    (SELECT ar_reduction_amount+refund_liability_amount
      FROM public.backoffice_sales_credit_notes
      WHERE company_id=v_company AND id=v_note)<>v_note_total OR
    NOT EXISTS(SELECT 1 FROM public.finance_journals journal
      WHERE journal.company_id=v_company AND journal.source_type='backoffice_sales_credit_notes'
        AND journal.source_id=v_note AND journal.status='POSTED'
        AND journal.total_debit=v_note_total AND journal.total_credit=v_note_total) THEN
    RAISE EXCEPTION 'TEST_FAILED: retained Credit Note AR/refund split or Journal invalid';
  END IF;

  v_refund:=public.post_backoffice_sales_customer_refund(v_note,v_note_version,
    v_refund_operation,v_today,v_refund_liability,v_method,'RETAINED-REFUND-ROLLBACK',
    CASE WHEN v_proof_mode='REQUIRED' THEN 'https://example.invalid/rollback-only-proof' ELSE NULL END,
    'Rollback-only retained Retail Refund');
  v_retry:=public.post_backoffice_sales_customer_refund(v_note,v_note_version,
    v_refund_operation,v_today,v_refund_liability,v_method,'RETAINED-REFUND-ROLLBACK',
    CASE WHEN v_proof_mode='REQUIRED' THEN 'https://example.invalid/rollback-only-proof' ELSE NULL END,
    'Rollback-only retained Retail Refund');
  IF COALESCE((v_retry->>'exactRetry')::boolean,false) IS NOT TRUE THEN
    RAISE EXCEPTION 'TEST_FAILED: retained Refund exact retry invalid';
  END IF;
  v_refund_id:=(v_refund->'data'->>'id')::uuid;
  SELECT master_version INTO v_refund_version
  FROM public.backoffice_sales_customer_refunds WHERE company_id=v_company AND id=v_refund_id;
  IF v_refund_version IS NULL THEN
    RAISE EXCEPTION 'TEST_FAILED: posted retained Refund missing';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.backoffice_sales_customer_refunds refund
      WHERE refund.company_id=v_company AND refund.id=v_refund_id
        AND refund.source_kind='RETAINED_RETAIL' AND refund.source_invoice_id IS NULL
        AND refund.source_retail_sales_id=v_sale) THEN
    RAISE EXCEPTION 'TEST_FAILED: retained Refund source identity invalid';
  END IF;
  v_reversal:=public.reverse_backoffice_sales_customer_refund(v_refund_id,v_refund_version,
    v_reversal_operation,v_today,'Rollback-only reversal verification');
  IF NOT EXISTS(SELECT 1 FROM public.backoffice_sales_customer_refunds reversal
      WHERE reversal.company_id=v_company AND reversal.id=(v_reversal->'data'->>'id')::uuid
        AND reversal.source_kind='RETAINED_RETAIL' AND reversal.source_invoice_id IS NULL
        AND reversal.source_retail_sales_id=v_sale) THEN
    RAISE EXCEPTION 'TEST_FAILED: retained Refund reversal source identity invalid';
  END IF;

  v_aging:=public.get_finance_ar_aging(v_today,v_customer,v_store);
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(v_aging->'invoices') item
    WHERE item->>'sourceProcess'='RETAIL_SALE' AND item->>'sourceId'=v_sale::text
      AND (item->>'outstanding')::numeric>0) THEN
    RAISE EXCEPTION 'TEST_FAILED: retained Credit Note not reflected in Retail AR Aging';
  END IF;
  IF (SELECT to_jsonb(sale) FROM public.sales_headers sale
      WHERE sale.company_id=v_company AND sale.id=v_sale)<>v_source_header
    OR (SELECT to_jsonb(invoice) FROM public.sales_invoice_snapshots invoice
      WHERE invoice.company_id=v_company AND invoice.sales_id=v_sale)<>v_source_invoice
    OR (SELECT jsonb_agg(to_jsonb(detail) ORDER BY detail.id) FROM public.sales_details detail
      WHERE detail.company_id=v_company AND detail.sales_id=v_sale)<>v_source_lines
    OR (SELECT count(*) FROM public.sales_return_documents
      WHERE company_id=v_company AND source_sales_id=v_sale)<>v_native_returns
    OR (SELECT count(*) FROM public.stock_movements WHERE company_id=v_company)<>v_stock_movements THEN
    RAISE EXCEPTION 'TEST_FAILED: financial correction mutated Retail source, native Return, or Stock';
  END IF;
END
$test$;

ROLLBACK;

SELECT 'retained_retail_credit_note_refund_bridge_behavior' check_name,'PASS' status,
  0::bigint violation_rows,jsonb_build_object('tested',ARRAY[
    'self-created retained Retail Return and receipt fixture',
    'received retained Retail Return allocation to exact Retail Invoice',
    'Credit Note balanced Journal and AR-first split','Refund and Refund reversal source lineage',
    'exact retry','stale version rejection','Retail Sale/Invoice/lines immutable',
    'native Retail Return and Stock unchanged','all fixture writes rolled back']) details;
