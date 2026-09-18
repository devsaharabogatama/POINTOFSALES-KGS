-- Authenticated rollback-only behavior for retained Retail financial correction.
-- Uses a real received retained Return, creates any missing payment only inside
-- this transaction, and rolls every allocation/Credit Note/Refund write back.
BEGIN;

DO $test$
DECLARE
  v_actor uuid;v_company uuid;v_return uuid;v_sale uuid;v_customer uuid;v_store uuid;
  v_version bigint;v_today date;v_method uuid;v_proof_mode text;v_outstanding numeric(24,4);
  v_payment_amount numeric(24,4);v_payment jsonb;v_allocations jsonb;v_allocate jsonb;
  v_retry jsonb;v_note uuid;
  v_note_version bigint;v_note_total numeric(24,4);v_refund_liability numeric(24,4);
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
  SELECT profile.id INTO STRICT v_actor FROM public.profiles profile
  JOIN auth.users auth_user ON auth_user.id=profile.id
  WHERE profile.role='super_admin'::public.user_role ORDER BY profile.id LIMIT 1;

  SELECT document.company_id,document.id,document.retail_sales_id,sale.customer_id,
    sale.store_id,document.master_version,
    (clock_timestamp() AT TIME ZONE company.timezone)::date
  INTO STRICT v_company,v_return,v_sale,v_customer,v_store,v_version,v_today
  FROM public.backoffice_sales_returns document
  JOIN public.sales_headers sale ON sale.company_id=document.company_id
    AND sale.id=document.retail_sales_id AND sale.document_status<>'CANCELED'
  JOIN public.companies company ON company.id=document.company_id AND company.status='ACTIVE'
  JOIN public.customers customer ON customer.company_id=sale.company_id
    AND customer.id=sale.customer_id AND NOT customer.is_system_customer
  WHERE document.source_kind='RETAINED_RETAIL'
    AND document.status IN('RECEIVED','CREDIT_PENDING')
    AND document.total_received_base_qty>0
    AND EXISTS(SELECT 1 FROM public.backoffice_sales_return_receipt_lines receipt_line
      WHERE receipt_line.company_id=document.company_id AND receipt_line.return_id=document.id
        AND receipt_line.received_base_qty>COALESCE((SELECT sum(allocation.allocated_base_qty)
          FROM public.backoffice_sales_return_invoice_allocations allocation
          WHERE allocation.company_id=receipt_line.company_id
            AND allocation.return_receipt_line_id=receipt_line.id),0))
    AND NOT EXISTS(SELECT 1 FROM public.backoffice_sales_credit_notes note
      WHERE note.company_id=document.company_id AND note.return_id=document.id)
    AND EXISTS(SELECT 1 FROM public.accounting_periods period
      WHERE period.company_id=document.company_id
        AND (clock_timestamp() AT TIME ZONE company.timezone)::date
          BETWEEN period.start_date AND period.end_date
        AND period.status IN('OPEN','REOPENED'))
  ORDER BY document.created_at DESC,document.id LIMIT 1;

  PERFORM set_config('request.jwt.claim.sub',v_actor::text,true);
  INSERT INTO public.user_active_company_contexts(user_id,company_id)
  VALUES(v_actor,v_company) ON CONFLICT(user_id) DO UPDATE
  SET company_id=excluded.company_id,selected_at=clock_timestamp(),updated_at=clock_timestamp();

  SELECT method.id,method.proof_mode INTO STRICT v_method,v_proof_mode
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
  ORDER BY method.is_default DESC,method.id LIMIT 1;

  SELECT greatest(0,round(sale.sisa_piutang-COALESCE((SELECT sum(allocation.allocated_amount)
      FROM public.customer_receipt_allocations allocation
      JOIN public.customer_receipt_documents receipt ON receipt.company_id=allocation.company_id
        AND receipt.id=allocation.document_id AND receipt.status='POSTED'
      WHERE allocation.company_id=sale.company_id AND allocation.sales_id=sale.id),0),4))
  INTO STRICT v_outstanding FROM public.sales_headers sale
  WHERE sale.company_id=v_company AND sale.id=v_sale;
  SELECT jsonb_agg(jsonb_build_object(
      'returnReceiptLineId',receipt_line.id,'allocationType','RETAIL_POSTED_INVOICE',
      'retailSalesId',v_sale,'retailSalesDetailId',return_line.retail_sales_detail_id,
      'quantityUom',round((receipt_line.received_base_qty-COALESCE((SELECT sum(allocation.allocated_base_qty)
        FROM public.backoffice_sales_return_invoice_allocations allocation
        WHERE allocation.company_id=receipt_line.company_id
          AND allocation.return_receipt_line_id=receipt_line.id),0))/receipt_line.base_qty_per_uom,6))
    ORDER BY receipt_line.created_at,receipt_line.id)
  INTO STRICT v_allocations
  FROM public.backoffice_sales_return_receipt_lines receipt_line
  JOIN public.backoffice_sales_return_lines return_line
    ON return_line.company_id=receipt_line.company_id AND return_line.id=receipt_line.return_line_id
  WHERE receipt_line.company_id=v_company AND receipt_line.return_id=v_return
    AND receipt_line.received_base_qty>COALESCE((SELECT sum(allocation.allocated_base_qty)
      FROM public.backoffice_sales_return_invoice_allocations allocation
      WHERE allocation.company_id=receipt_line.company_id
        AND allocation.return_receipt_line_id=receipt_line.id),0);

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

  SELECT note.id,note.master_version,note.grand_total INTO STRICT
    v_note,v_note_version,v_note_total
  FROM public.backoffice_sales_credit_notes note
  WHERE note.company_id=v_company AND note.return_id=v_return
    AND note.source_kind='RETAINED_RETAIL' AND note.status='DRAFT';

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

  SELECT to_jsonb(sale) INTO STRICT v_source_header FROM public.sales_headers sale
    WHERE sale.company_id=v_company AND sale.id=v_sale;
  SELECT to_jsonb(invoice) INTO STRICT v_source_invoice FROM public.sales_invoice_snapshots invoice
    WHERE invoice.company_id=v_company AND invoice.sales_id=v_sale;
  SELECT jsonb_agg(to_jsonb(detail) ORDER BY detail.id) INTO STRICT v_source_lines
    FROM public.sales_details detail WHERE detail.company_id=v_company AND detail.sales_id=v_sale;
  SELECT count(*) INTO v_native_returns FROM public.sales_return_documents
    WHERE company_id=v_company AND source_sales_id=v_sale;
  SELECT count(*) INTO v_stock_movements FROM public.stock_movements WHERE company_id=v_company;

  v_post:=public.post_backoffice_sales_credit_note(v_note,v_note_version,v_post_operation);
  v_retry:=public.post_backoffice_sales_credit_note(v_note,v_note_version,v_post_operation);
  IF COALESCE((v_retry->>'exactRetry')::boolean,false) IS NOT TRUE THEN
    RAISE EXCEPTION 'TEST_FAILED: retained Credit Note exact retry invalid';
  END IF;
  SELECT master_version,refund_liability_amount INTO STRICT v_note_version,v_refund_liability
  FROM public.backoffice_sales_credit_notes WHERE company_id=v_company AND id=v_note;
  IF v_refund_liability<=0 OR
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
  SELECT master_version INTO STRICT v_refund_version
  FROM public.backoffice_sales_customer_refunds WHERE company_id=v_company AND id=v_refund_id;
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
    'received retained Retail Return allocation to exact Retail Invoice',
    'Credit Note balanced Journal and AR-first split','Refund and Refund reversal source lineage',
    'exact retry','stale version rejection','Retail Sale/Invoice/lines immutable',
    'native Retail Return and Stock unchanged','all fixture writes rolled back']) details;
