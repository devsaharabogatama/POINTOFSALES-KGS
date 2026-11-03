-- Authenticated rollback-only behavior for Retail POS Session Return summary.
-- This test performs reads plus rolled-back active-context changes only.
BEGIN;

DO $test$
DECLARE
  v_company uuid;v_actor uuid;v_session uuid;v_payload jsonb;v_retry jsonb;
  v_expected_refund_rows bigint;v_expected_refund_amount numeric;
  v_expected_line_rows bigint;v_expected_physical_quantity numeric;
  v_actual_refund_rows bigint;v_actual_refund_amount numeric;
  v_actual_line_rows bigint;v_actual_physical_quantity numeric;
  v_other_company uuid;v_other_actor uuid;v_other_session uuid;
  v_before_events bigint;v_before_movements bigint;v_before_journals bigint;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations ledger
      WHERE ledger.version='20261102150000') THEN
    RAISE EXCEPTION
      'TEST_PRECONDITION_FAILED: Retail Session Return summary migration missing';
  END IF;

  SELECT document.company_id,document.executing_session_id,session.cashier_id
  INTO v_company,v_session,v_actor
  FROM public.sales_return_documents document
  JOIN public.sales_headers source_sale
    ON source_sale.company_id=document.company_id
   AND source_sale.id=document.source_sales_id
  JOIN public.company_sales_process_settings setting
    ON setting.company_id=document.company_id
   AND setting.active_mode='RETAIL_CONFIRM_INVOICE'
  JOIN public.cashier_sessions session
    ON session.company_id=document.company_id
   AND session.id=document.executing_session_id
  JOIN auth.users auth_user ON auth_user.id=session.cashier_id
  WHERE document.status='POSTED'
    AND source_sale.sales_origin='POS'
    AND source_sale.sales_process_mode='RETAIL_CONFIRM_INVOICE'
  ORDER BY document.posted_at DESC NULLS LAST,document.id
  LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION
    'TEST_PRECONDITION_FAILED: Posted Retail POS Return with authenticated executing cashier required';
  END IF;

  SELECT count(refund.id),COALESCE(sum(refund.amount),0)
  INTO v_expected_refund_rows,v_expected_refund_amount
  FROM public.sales_return_refunds refund
  JOIN public.sales_return_documents document
    ON document.company_id=refund.company_id
   AND document.id=refund.document_id AND document.status='POSTED'
  JOIN public.sales_headers source_sale
    ON source_sale.company_id=document.company_id
   AND source_sale.id=document.source_sales_id
  WHERE refund.company_id=v_company
    AND document.executing_session_id=v_session
    AND source_sale.sales_origin='POS'
    AND source_sale.sales_process_mode='RETAIL_CONFIRM_INVOICE';

  SELECT count(line.id),COALESCE(sum(line.quantity_uom)
    FILTER(WHERE line.return_condition IN('SALEABLE','DAMAGED')),0)
  INTO v_expected_line_rows,v_expected_physical_quantity
  FROM public.sales_return_lines line
  JOIN public.sales_return_documents document
    ON document.company_id=line.company_id
   AND document.id=line.document_id AND document.status='POSTED'
  JOIN public.sales_headers source_sale
    ON source_sale.company_id=document.company_id
   AND source_sale.id=document.source_sales_id
  WHERE line.company_id=v_company
    AND document.executing_session_id=v_session
    AND source_sale.sales_origin='POS'
    AND source_sale.sales_process_mode='RETAIL_CONFIRM_INVOICE';

  SELECT count(*) INTO v_before_events FROM public.financial_events;
  SELECT count(*) INTO v_before_movements FROM public.stock_movements;
  SELECT count(*) INTO v_before_journals FROM public.finance_journals;

  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub',v_actor,'role','authenticated')::text,true);
  PERFORM set_config('request.jwt.claim.sub',v_actor::text,true);
  PERFORM public.set_active_company_context(v_company,'POS_SESSION_SUMMARY_TEST');

  v_payload:=public.get_pos_cashier_session_return_adjustments(v_session);
  v_retry:=public.get_pos_cashier_session_return_adjustments(v_session);
  SELECT count(*),COALESCE(sum((entry.value->>'amount')::numeric),0)
  INTO v_actual_refund_rows,v_actual_refund_amount
  FROM jsonb_array_elements(v_payload->'refunds') entry;
  SELECT count(*),COALESCE(sum((entry.value->>'quantity')::numeric)
    FILTER(WHERE entry.value->>'returnCondition' IN('SALEABLE','DAMAGED')),0)
  INTO v_actual_line_rows,v_actual_physical_quantity
  FROM jsonb_array_elements(v_payload->'lines') entry;

  IF v_payload->>'processMode'<>'RETAIL_CONFIRM_INVOICE'
    OR (v_payload->>'companyId')::uuid<>v_company
    OR (v_payload->>'cashierSessionId')::uuid<>v_session
    OR v_actual_refund_rows<>v_expected_refund_rows
    OR v_actual_refund_amount<>v_expected_refund_amount
    OR v_actual_line_rows<>v_expected_line_rows
    OR v_actual_physical_quantity<>v_expected_physical_quantity
    OR v_retry IS DISTINCT FROM v_payload THEN
    RAISE EXCEPTION 'TEST_FAILED: Retail own-session adjustment mismatch';
  END IF;

  SELECT session.company_id,session.id INTO v_other_company,v_other_session
  FROM public.cashier_sessions session
  JOIN public.company_sales_process_settings setting
    ON setting.company_id=session.company_id
   AND setting.active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE'
  WHERE session.company_id<>v_company
  ORDER BY session.opened_at DESC,session.id LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION
    'TEST_PRECONDITION_FAILED: Backoffice Company Session required'; END IF;

  BEGIN
    PERFORM public.get_pos_cashier_session_return_adjustments(v_other_session);
    RAISE EXCEPTION 'TEST_FAILED: cross-Company Session read was allowed';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%CASHIER_SESSION_NOT_OWNED%' THEN RAISE; END IF;
  END;

  SELECT session.cashier_id INTO v_other_actor
  FROM public.cashier_sessions session
  JOIN auth.users auth_user ON auth_user.id=session.cashier_id
  WHERE session.company_id=v_other_company AND session.id=v_other_session;
  IF v_other_actor IS NULL THEN RAISE EXCEPTION
    'TEST_PRECONDITION_FAILED: Backoffice Session authenticated cashier required';
  END IF;
  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub',v_other_actor,'role','authenticated')::text,true);
  PERFORM set_config('request.jwt.claim.sub',v_other_actor::text,true);
  PERFORM public.set_active_company_context(
    v_other_company,'POS_SESSION_SUMMARY_TEST');
  v_payload:=public.get_pos_cashier_session_return_adjustments(v_other_session);
  IF COALESCE((v_payload->>'applicable')::boolean,true)
    OR jsonb_array_length(v_payload->'refunds')<>0
    OR jsonb_array_length(v_payload->'lines')<>0
    OR v_payload->>'processMode'<>'BACKOFFICE_DELIVERED_QTY_INVOICE' THEN
    RAISE EXCEPTION 'TEST_FAILED: Backoffice process entered Retail summary';
  END IF;

  IF (SELECT count(*) FROM public.financial_events)<>v_before_events
    OR (SELECT count(*) FROM public.stock_movements)<>v_before_movements
    OR (SELECT count(*) FROM public.finance_journals)<>v_before_journals THEN
    RAISE EXCEPTION 'TEST_FAILED: read model changed business effects';
  END IF;

  RAISE NOTICE 'pos_retail_session_net_return_summary_behavior PASS: %',
    jsonb_build_object('tested',jsonb_build_array(
      'installed exact forward migration','authenticated own Retail Session',
      'actual Posted refund rows and amount','all Return lines',
      'physical SALEABLE/DAMAGED quantity','exact repeated read',
      'cross-Company denial','Backoffice process denial',
      'zero Finance/Stock/Journal effect','all context effects rolled back'));
END
$test$;

ROLLBACK;
