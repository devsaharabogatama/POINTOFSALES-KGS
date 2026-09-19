-- Authenticated rollback-only behavior against one actual posted Credit Note source.
BEGIN;

DO $test$
DECLARE v_actor uuid;v_company uuid;v_source_kind text;v_source_id uuid;v_customer uuid;
  v_today date;v_credit numeric;v_original numeric;v_paid numeric;v_expected numeric;
  v_workspace jsonb;v_row jsonb;v_method uuid;v_failed boolean:=false;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260919110000') THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: 20260919110000 required';
  END IF;
  SELECT profile.id INTO v_actor FROM public.profiles profile
  JOIN auth.users auth_user ON auth_user.id=profile.id
  WHERE profile.role='super_admin'::public.user_role ORDER BY profile.id LIMIT 1;
  SELECT note.company_id,note.source_kind,
    CASE WHEN note.source_kind='BACKOFFICE' THEN note.source_invoice_id
      ELSE note.source_retail_sales_id END,
    note.customer_id,(clock_timestamp() AT TIME ZONE company.timezone)::date
  INTO v_company,v_source_kind,v_source_id,v_customer,v_today
  FROM public.backoffice_sales_credit_notes note
  JOIN public.companies company ON company.id=note.company_id AND company.status='ACTIVE'
  JOIN public.customers customer ON customer.company_id=note.company_id
    AND customer.id=note.customer_id AND customer.is_active
    AND (note.source_kind='BACKOFFICE' OR NOT customer.is_system_customer)
  WHERE note.status='POSTED' AND note.ar_reduction_amount>0
  ORDER BY note.posted_at DESC,note.id LIMIT 1;
  IF v_actor IS NULL OR v_company IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: Super Admin and actual posted Customer Credit Note required';
  END IF;
  PERFORM set_config('request.jwt.claim.sub',v_actor::text,true);
  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub',v_actor,'role','authenticated')::text,true);
  INSERT INTO public.user_active_company_contexts(user_id,company_id)
  VALUES(v_actor,v_company) ON CONFLICT(user_id) DO UPDATE SET
    company_id=excluded.company_id,selected_at=clock_timestamp(),updated_at=clock_timestamp();

  SELECT round(COALESCE(sum(note.ar_reduction_amount),0),4) INTO v_credit
  FROM public.backoffice_sales_credit_notes note
  WHERE note.company_id=v_company AND note.status='POSTED'
    AND note.source_kind=v_source_kind
    AND CASE WHEN v_source_kind='BACKOFFICE' THEN note.source_invoice_id=v_source_id
      ELSE note.source_retail_sales_id=v_source_id END
    AND note.credit_note_date<=v_today;
  IF v_source_kind='BACKOFFICE' THEN
    SELECT invoice.grand_total,COALESCE((SELECT sum(allocation.allocated_amount)
      FROM public.customer_receipt_backoffice_invoice_allocations allocation
      JOIN public.customer_receipt_documents receipt ON receipt.company_id=allocation.company_id
        AND receipt.id=allocation.document_id AND receipt.status='POSTED'
      WHERE allocation.company_id=invoice.company_id AND allocation.invoice_id=invoice.id),0)
    INTO v_original,v_paid FROM public.backoffice_sales_invoices invoice
    WHERE invoice.company_id=v_company AND invoice.id=v_source_id;
  ELSE
    SELECT private.odr6d_dispatched_receivable_before_receipts(sale.company_id,sale.id,v_today),
      COALESCE((SELECT sum(allocation.allocated_amount)
      FROM public.customer_receipt_allocations allocation
      JOIN public.customer_receipt_documents receipt ON receipt.company_id=allocation.company_id
        AND receipt.id=allocation.document_id AND receipt.status='POSTED'
      WHERE allocation.company_id=sale.company_id AND allocation.sales_id=sale.id),0)
    INTO v_original,v_paid FROM public.sales_headers sale
    WHERE sale.company_id=v_company AND sale.id=v_source_id;
  END IF;
  v_expected:=greatest(0,round(v_original-v_credit-v_paid,4));
  v_workspace:=public.get_finance_customer_receipts();
  SELECT item INTO v_row FROM jsonb_array_elements(v_workspace->'openInvoices') item
  WHERE item->>'sourceType'=CASE WHEN v_source_kind='BACKOFFICE'
      THEN 'BACKOFFICE_SALES_INVOICE' ELSE 'RETAIL_SALE' END
    AND (item->>'sourceId')::uuid=v_source_id;
  IF v_expected=0 AND v_row IS NOT NULL THEN
    RAISE EXCEPTION 'TEST_FAILED: fully settled credited Invoice still offered for Customer Receipt';
  ELSIF v_expected>0 AND (v_row IS NULL
    OR round((v_row->>'creditedAmount')::numeric,4)<>v_credit
    OR round((v_row->>'remainingAmount')::numeric,4)<>v_expected) THEN
    RAISE EXCEPTION 'TEST_FAILED: Customer Receipt net outstanding does not match posted Credit Note';
  END IF;

  SELECT method.id INTO v_method FROM public.payment_methods method
  WHERE method.company_id=v_company AND method.is_active
    AND method.settlement_route IN('CASH_DRAWER','DIRECT_BANK')
  ORDER BY method.is_default DESC,method.id LIMIT 1;
  IF v_method IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: active Cash/Bank Payment Method required';
  END IF;
  BEGIN
    PERFORM public.save_customer_receipt_allocated_draft(NULL,NULL,v_customer,v_today,
      v_method,'ROLLBACK-CREDIT-NET',NULL,'Rollback-only over-allocation guard',v_expected+1,
      jsonb_build_array(jsonb_build_object(
        'sourceType',CASE WHEN v_source_kind='BACKOFFICE' THEN 'BACKOFFICE_SALES_INVOICE' ELSE 'RETAIL_SALE' END,
        'sourceId',v_source_id,'clientAllocationKey',gen_random_uuid(),
        'allocatedAmount',v_expected+1)));
  EXCEPTION WHEN OTHERS THEN
    v_failed:=position('CUSTOMER_RECEIPT_OVER_ALLOCATION' IN SQLERRM)>0;
  END;
  IF NOT v_failed THEN
    RAISE EXCEPTION 'TEST_FAILED: Credit Note adjusted over-allocation was accepted';
  END IF;
END
$test$;

SELECT 'customer_receipt_credit_note_outstanding_behavior' check_name,'PASS' status,
  0::bigint violation_rows,jsonb_build_object('tested',ARRAY[
    'actual posted Credit Note reflected in Customer Receipt candidate',
    'fully settled credited Invoice omitted from candidates',
    'server rejects allocation above Credit Note adjusted outstanding',
    'all test context writes rolled back']) details;

ROLLBACK;
