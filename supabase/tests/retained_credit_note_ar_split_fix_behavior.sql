-- Authenticated rollback-only proof that the exact Invoice now exposes net AR.
BEGIN;
DO $test$
DECLARE v_actor uuid;v_company uuid;v_sale uuid;v_payload jsonb;v_row jsonb;
  v_original numeric;v_credit numeric;v_paid numeric;v_expected numeric;
BEGIN
  SELECT profile.id INTO v_actor FROM public.profiles profile
  JOIN auth.users actor ON actor.id=profile.id
  WHERE profile.role='super_admin'::public.user_role ORDER BY profile.id LIMIT 1;
  SELECT note.company_id,note.source_retail_sales_id INTO v_company,v_sale
  FROM public.backoffice_sales_credit_notes note
  JOIN public.sales_invoice_snapshots invoice ON invoice.company_id=note.company_id
    AND invoice.sales_id=note.source_retail_sales_id
  WHERE note.credit_note_no='CN-20260919-0000000012'
    AND invoice.invoice_no='INV-20260904-0000000236'
    AND note.status='POSTED' AND note.ar_reduction_amount=78400
    AND note.refund_liability_amount=0;
  IF v_actor IS NULL OR v_company IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: corrected exact Credit Note/Invoice required';
  END IF;
  IF private.backoffice_sales_credit_note_refunded_amount(v_company,
      (SELECT note.id FROM public.backoffice_sales_credit_notes note
       WHERE note.company_id=v_company
         AND note.credit_note_no='CN-20260919-0000000012'))<>0 THEN
    RAISE EXCEPTION 'TEST_FAILED: erroneous Refund was not fully reversed';
  END IF;
  PERFORM set_config('request.jwt.claim.sub',v_actor::text,true);
  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub',v_actor,'role','authenticated')::text,true);
  INSERT INTO public.user_active_company_contexts(user_id,company_id)
  VALUES(v_actor,v_company) ON CONFLICT(user_id) DO UPDATE SET
    company_id=excluded.company_id,selected_at=clock_timestamp(),updated_at=clock_timestamp();
  v_payload:=public.get_finance_customer_receipts();
  SELECT item INTO v_row FROM jsonb_array_elements(v_payload->'openInvoices') item
  WHERE item->>'sourceType'='RETAIL_SALE' AND (item->>'sourceId')::uuid=v_sale;
  SELECT private.odr6d_dispatched_receivable_before_receipts(
      sale.company_id,sale.id,(clock_timestamp() AT TIME ZONE company.timezone)::date),
    COALESCE((SELECT sum(note.ar_reduction_amount)
      FROM public.backoffice_sales_credit_notes note
      WHERE note.company_id=sale.company_id AND note.source_kind='RETAINED_RETAIL'
        AND note.source_retail_sales_id=sale.id AND note.status='POSTED'),0),
    COALESCE((SELECT sum(allocation.allocated_amount)
      FROM public.customer_receipt_allocations allocation
      JOIN public.customer_receipt_documents receipt ON receipt.company_id=allocation.company_id
        AND receipt.id=allocation.document_id AND receipt.status='POSTED'
      WHERE allocation.company_id=sale.company_id AND allocation.sales_id=sale.id),0)
  INTO v_original,v_credit,v_paid
  FROM public.sales_headers sale JOIN public.companies company ON company.id=sale.company_id
  WHERE sale.company_id=v_company AND sale.id=v_sale;
  v_expected:=greatest(0,v_original-v_credit-v_paid);
  IF v_expected>0 AND (v_row IS NULL
    OR (v_row->>'creditedAmount')::numeric<>v_credit
    OR (v_row->>'remainingAmount')::numeric<>v_expected) THEN
    RAISE EXCEPTION 'TEST_FAILED: Customer Receipt still exposes pre-return amount';
  END IF;
  IF v_expected=0 AND v_row IS NOT NULL THEN
    RAISE EXCEPTION 'TEST_FAILED: fully credited Invoice still offered';
  END IF;
END
$test$;
SELECT 'retained_credit_note_ar_split_fix_behavior' check_name,'PASS' status,
  0::bigint violation_rows,jsonb_build_object('tested',ARRAY[
    'erroneous Refund append-only reversal','exact retained Retail Credit Note reclassified',
    'Customer Receipt reads posted AR reduction',
    'remaining amount equals dispatch receivable minus Credit Note minus receipts',
    'authenticated Company scope','context write rolled back']) details;
ROLLBACK;
