-- Authenticated rollback-only behavior test for posted Invoice price correction.
-- Uses one eligible existing Posted Invoice, writes two opposite corrections,
-- asserts their effects, and rolls the entire transaction back.
BEGIN;
DO $test$
DECLARE v_actor uuid;v_company uuid;v_invoice public.backoffice_sales_invoices%rowtype;
  v_context jsonb;v_payload jsonb;v_reverse_payload jsonb;v_result jsonb;v_reverse jsonb;v_retry jsonb;
  v_operation uuid:=gen_random_uuid();v_first_line uuid;v_original_price numeric(24,4);
  v_invoice_before jsonb;v_lines_before jsonb;v_event_before bigint;v_journal_before bigint;
  v_stock_before bigint;v_delta numeric(24,4);v_journal public.finance_journals%rowtype;
  v_blocked boolean:=false;v_correction_id uuid;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260928110000') THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: migration 20260928110000 missing';
  END IF;
  SELECT profile.id INTO v_actor FROM public.profiles profile
  JOIN auth.users auth_user ON auth_user.id=profile.id
  WHERE profile.role='super_admin'::public.user_role ORDER BY profile.id LIMIT 1;
  IF v_actor IS NULL THEN RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: linked Super Admin required'; END IF;

  SELECT invoice.* INTO v_invoice FROM public.backoffice_sales_invoices invoice
  WHERE invoice.company_id IN('4eedbf12-3c60-40e0-b2b7-1a48ca62b6f8'::uuid,
      '07bdffb9-8c56-444c-a49b-81ac86745674'::uuid,'809abdd9-d05f-4525-9726-1951a0ae1a81'::uuid)
    AND invoice.status='POSTED' AND invoice.invoice_type='REGULAR'
    AND EXISTS(SELECT 1 FROM public.backoffice_sales_invoice_lines line
      WHERE line.company_id=invoice.company_id AND line.invoice_id=invoice.id
        AND line.line_type='PRODUCT' AND line.source_kind='SALES_ORDER')
    AND EXISTS(SELECT 1 FROM public.backoffice_sales_invoice_receivable_schedules schedule
      WHERE schedule.company_id=invoice.company_id AND schedule.invoice_id=invoice.id)
    AND NOT EXISTS(SELECT 1 FROM public.backoffice_sales_credit_notes note
      WHERE note.company_id=invoice.company_id AND note.source_invoice_id=invoice.id
        AND note.status IN('DRAFT','POSTED'))
    AND NOT EXISTS(SELECT 1 FROM public.backoffice_sales_invoice_price_corrections correction
      WHERE correction.company_id=invoice.company_id AND correction.source_invoice_id=invoice.id)
  ORDER BY invoice.posted_at DESC,invoice.id LIMIT 1 FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: eligible KMS/LSM/SMS Posted Regular Invoice without Return Credit Note required';
  END IF;
  v_company:=v_invoice.company_id;
  PERFORM set_config('request.jwt.claim.sub',v_actor::text,true);
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',v_actor,'role','authenticated')::text,true);
  INSERT INTO public.user_active_company_contexts(user_id,company_id) VALUES(v_actor,v_company)
  ON CONFLICT(user_id) DO UPDATE SET company_id=excluded.company_id,
    selected_at=clock_timestamp(),updated_at=clock_timestamp();

  SELECT to_jsonb(invoice) INTO v_invoice_before FROM public.backoffice_sales_invoices invoice
  WHERE invoice.company_id=v_company AND invoice.id=v_invoice.id;
  SELECT jsonb_agg(to_jsonb(line) ORDER BY line.line_no,line.id) INTO v_lines_before
  FROM public.backoffice_sales_invoice_lines line
  WHERE line.company_id=v_company AND line.invoice_id=v_invoice.id;
  SELECT count(*) INTO v_event_before FROM public.financial_events;
  SELECT count(*) INTO v_journal_before FROM public.finance_journals;
  SELECT count(*) INTO v_stock_before FROM public.stock_movements;

  v_context:=public.get_backoffice_sales_invoice_price_correction_context(v_invoice.id);
  IF (v_context->>'priceRevision')::bigint<>0 OR NOT (v_context->>'canCorrect')::boolean THEN
    RAISE EXCEPTION 'TEST_FAILED: initial correction context invalid';
  END IF;
  SELECT line.id,private.backoffice_invoice_effective_entered_unit_price(v_company,line.id)
  INTO v_first_line,v_original_price FROM public.backoffice_sales_invoice_lines line
  WHERE line.company_id=v_company AND line.invoice_id=v_invoice.id
    AND line.line_type='PRODUCT' AND line.source_kind='SALES_ORDER'
  ORDER BY line.line_no,line.id LIMIT 1;
  SELECT jsonb_agg(jsonb_build_object('invoiceLineId',line.id,'newUnitPrice',
      private.backoffice_invoice_effective_entered_unit_price(v_company,line.id)
        +CASE WHEN line.id=v_first_line THEN 100 ELSE 0 END) ORDER BY line.line_no,line.id)
  INTO v_payload FROM public.backoffice_sales_invoice_lines line
  WHERE line.company_id=v_company AND line.invoice_id=v_invoice.id
    AND line.line_type='PRODUCT' AND line.source_kind='SALES_ORDER';

  v_result:=public.post_backoffice_sales_invoice_price_correction(v_invoice.id,
    v_invoice.master_version,0,v_operation,v_payload);
  v_delta:=(v_result->>'totalDelta')::numeric;
  v_correction_id:=(v_result->>'correctionId')::uuid;
  IF v_delta<=0 OR v_result->>'kind'<>'DEBIT_NOTE'
    OR (v_result->'priceCorrectionContext'->>'priceRevision')::bigint<>1
    OR private.backoffice_invoice_effective_entered_unit_price(v_company,v_first_line)<>v_original_price+100 THEN
    RAISE EXCEPTION 'TEST_FAILED: Debit Note correction or effective price invalid';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.backoffice_sales_invoice_price_corrections correction
      WHERE correction.company_id=v_company AND correction.id=v_correction_id
        AND correction.total_delta=correction.ar_adjustment_amount-correction.refund_liability_amount
        AND correction.ar_adjustment_amount>=0 AND correction.refund_liability_amount<=0) THEN
    RAISE EXCEPTION 'TEST_FAILED: Debit Note AR/refund settlement split invalid';
  END IF;
  SELECT * INTO v_journal FROM public.finance_journals journal
  WHERE journal.company_id=v_company AND journal.journal_no=v_result->>'journalNo';
  IF v_journal.status<>'POSTED' OR round(v_journal.total_debit,4)<>round(v_journal.total_credit,4)
    OR round(v_journal.total_debit,4)<>round(v_delta,4) THEN
    RAISE EXCEPTION 'TEST_FAILED: Debit Note Journal invalid';
  END IF;
  IF (public.get_backoffice_sales_invoice_payment_context(v_invoice.id)->'summary'->>'effectiveInvoiceAmount')::numeric
      <>v_invoice.grand_total+v_delta THEN
    RAISE EXCEPTION 'TEST_FAILED: payment context did not use effective Invoice total';
  END IF;

  v_retry:=public.post_backoffice_sales_invoice_price_correction(v_invoice.id,
    v_invoice.master_version,0,v_operation,v_payload);
  IF COALESCE((v_retry->>'exactRetry')::boolean,false) IS NOT TRUE
    OR (SELECT count(*) FROM public.backoffice_sales_invoice_price_corrections correction
      WHERE correction.company_id=v_company AND correction.id=v_correction_id)<>1 THEN
    RAISE EXCEPTION 'TEST_FAILED: exact retry duplicated correction';
  END IF;
  BEGIN
    PERFORM public.post_backoffice_sales_invoice_price_correction(v_invoice.id,
      v_invoice.master_version,0,gen_random_uuid(),v_payload);
  EXCEPTION WHEN OTHERS THEN v_blocked:=SQLERRM LIKE '%INVOICE_PRICE_REVISION_CONFLICT%'; END;
  IF NOT v_blocked THEN RAISE EXCEPTION 'TEST_FAILED: stale price revision was not rejected'; END IF;

  SELECT jsonb_agg(jsonb_build_object('invoiceLineId',line.id,'newUnitPrice',
      CASE WHEN line.id=v_first_line THEN v_original_price
        ELSE private.backoffice_invoice_effective_entered_unit_price(v_company,line.id) END)
      ORDER BY line.line_no,line.id)
  INTO v_reverse_payload FROM public.backoffice_sales_invoice_lines line
  WHERE line.company_id=v_company AND line.invoice_id=v_invoice.id
    AND line.line_type='PRODUCT' AND line.source_kind='SALES_ORDER';
  v_reverse:=public.post_backoffice_sales_invoice_price_correction(v_invoice.id,
    v_invoice.master_version,1,gen_random_uuid(),v_reverse_payload);
  IF v_reverse->>'kind'<>'CREDIT_NOTE' OR (v_reverse->>'totalDelta')::numeric<>-v_delta
    OR (v_reverse->'priceCorrectionContext'->>'priceRevision')::bigint<>2
    OR (v_reverse->>'effectiveTotal')::numeric<>v_invoice.grand_total THEN
    RAISE EXCEPTION 'TEST_FAILED: reverse price correction did not restore effective total';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.backoffice_sales_invoice_price_corrections correction
      WHERE correction.company_id=v_company AND correction.id=(v_reverse->>'correctionId')::uuid
        AND correction.total_delta=correction.ar_adjustment_amount-correction.refund_liability_amount
        AND correction.ar_adjustment_amount<=0 AND correction.refund_liability_amount>=0) THEN
    RAISE EXCEPTION 'TEST_FAILED: Credit Note AR/refund settlement split invalid';
  END IF;

  v_blocked:=false;
  BEGIN
    UPDATE public.backoffice_sales_invoice_price_corrections SET total_delta=total_delta
    WHERE company_id=v_company AND id=v_correction_id;
  EXCEPTION WHEN OTHERS THEN v_blocked:=SQLERRM LIKE '%POSTED_INVOICE_PRICE_CORRECTION_IMMUTABLE%'; END;
  IF NOT v_blocked THEN RAISE EXCEPTION 'TEST_FAILED: posted correction history is mutable'; END IF;
  IF (SELECT to_jsonb(invoice) FROM public.backoffice_sales_invoices invoice
      WHERE invoice.company_id=v_company AND invoice.id=v_invoice.id) IS DISTINCT FROM v_invoice_before
    OR (SELECT jsonb_agg(to_jsonb(line) ORDER BY line.line_no,line.id)
      FROM public.backoffice_sales_invoice_lines line
      WHERE line.company_id=v_company AND line.invoice_id=v_invoice.id) IS DISTINCT FROM v_lines_before THEN
    RAISE EXCEPTION 'TEST_FAILED: original Invoice or lines were mutated';
  END IF;
  IF (SELECT count(*) FROM public.stock_movements)<>v_stock_before
    OR (SELECT count(*) FROM public.financial_events)<>v_event_before+2
    OR (SELECT count(*) FROM public.finance_journals)<>v_journal_before+2 THEN
    RAISE EXCEPTION 'TEST_FAILED: Stock mutation or Finance effect count invalid';
  END IF;
END
$test$;
ROLLBACK;

SELECT 'backoffice_posted_invoice_price_correction_behavior' check_name,'PASS' status,
  0::bigint violation_rows,jsonb_build_object('tested',ARRAY[
    'authenticated existing Posted Invoice correction','server timestamped Debit Note',
    'balanced delta Journal','signed AR/refund settlement split','effective payment context','exact retry',
    'stale price revision rejection','Credit Note restores original effective total',
    'posted correction immutability','original Invoice and lines immutable',
    'no Stock movement','all transactional writes rolled back']) details;
