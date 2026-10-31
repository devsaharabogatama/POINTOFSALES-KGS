-- Authenticated rollback-only behavior for direct Retail POS non-cash
-- verification and atomic payment posting.
BEGIN;

DO $test$
DECLARE
  v_transfer public.sales_payment_verification_requests%rowtype;
  v_clearing public.sales_payment_verification_requests%rowtype;
  v_reviewer uuid;v_other_company uuid;v_result jsonb;v_event uuid;
  v_maker_request uuid;v_maker_key uuid;
  v_blocked boolean;v_sale_event uuid;v_sale_event_status text;
  v_sale_journal_rows bigint;v_payment_journal_rows bigint;
BEGIN
  IF (SELECT count(*) FROM private.kgs_schema_migrations
      WHERE version='20261031100000')<>1 THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: atomic verification migration missing';
  END IF;
  SELECT request.* INTO v_transfer
  FROM public.sales_payment_verification_requests request
  JOIN public.sales_headers sale ON sale.company_id=request.company_id
    AND sale.id=request.sales_id
  WHERE request.status='PENDING' AND request.verification_mode='MANUAL_REVIEW'
    AND request.settlement_route_snapshot='DIRECT_BANK'
    AND sale.sales_origin='POS'
    AND sale.sales_process_mode='RETAIL_CONFIRM_INVOICE'
    AND sale.document_status='POSTED'
    AND sale.order_runtime_status='LEGACY_POSTED'
  ORDER BY request.requested_at,request.id LIMIT 1 FOR UPDATE OF request;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: pending direct Retail bank request required';
  END IF;
  SELECT candidate.actor_id INTO v_reviewer
  FROM (
    SELECT profile.id actor_id,0 actor_rank FROM public.profiles profile
    WHERE profile.role::text='super_admin' AND profile.id<>v_transfer.requested_by
    UNION ALL
    SELECT membership.user_id,1 FROM public.company_memberships membership
    WHERE membership.company_id=v_transfer.company_id
      AND membership.status='ACTIVE'
      AND membership.user_id<>v_transfer.requested_by
  ) candidate
  WHERE (private.acp_resolve_permission(v_transfer.company_id,candidate.actor_id,
    'finance.sales_payment_verification')->'effectiveCapabilities') ? 'APPROVE'
  ORDER BY candidate.actor_rank,candidate.actor_id LIMIT 1;
  IF v_reviewer IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: independent Finance reviewer required';
  END IF;
  v_maker_request:=gen_random_uuid();v_maker_key:=gen_random_uuid();
  INSERT INTO public.sales_payment_verification_requests(
    id,company_id,sales_id,client_payment_key,payment_method_id,amount,
    proof_url,status,payment_method_code_snapshot,payment_method_name_snapshot,
    payment_method_type_snapshot,settlement_route_snapshot,
    settlement_account_function_snapshot,intent_snapshot,requested_by,
    cashier_session_id,store_id,pos_terminal_id,verification_mode)
  SELECT v_maker_request,request.company_id,request.sales_id,v_maker_key,
    request.payment_method_id,request.amount,request.proof_url,'PENDING',
    request.payment_method_code_snapshot,request.payment_method_name_snapshot,
    request.payment_method_type_snapshot,request.settlement_route_snapshot,
    request.settlement_account_function_snapshot,
    request.intent_snapshot||jsonb_build_object(
      'clientPaymentKey',v_maker_key,
      'sourceContract','ROLLBACK_MAKER_CHECKER_FIXTURE'),
    v_reviewer,request.cashier_session_id,request.store_id,
    request.pos_terminal_id,'MANUAL_REVIEW'
  FROM public.sales_payment_verification_requests request
  WHERE request.company_id=v_transfer.company_id AND request.id=v_transfer.id;
  INSERT INTO public.sales_payment_verification_audit(
    company_id,verification_request_id,action,actor_id,idempotency_key,after_state)
  VALUES(v_transfer.company_id,v_maker_request,'CREATE',v_reviewer,v_maker_key,
    jsonb_build_object('status','PENDING',
      'sourceContract','ROLLBACK_MAKER_CHECKER_FIXTURE'));
  SELECT event.id,event.status::text INTO STRICT v_sale_event,v_sale_event_status
  FROM public.financial_events event
  WHERE event.company_id=v_transfer.company_id
    AND event.source_table='sales_headers' AND event.source_id=v_transfer.sales_id
    AND event.system_event_key='SALE_POSTED';
  SELECT count(*) INTO v_sale_journal_rows FROM public.finance_journals journal
  WHERE journal.company_id=v_transfer.company_id
    AND journal.financial_event_id=v_sale_event;

  v_result:=private.capture_direct_retail_non_cash_payment_requests(
    v_transfer.company_id,v_transfer.sales_id,v_transfer.requested_by);
  IF NOT (v_result->>'exactRetry')::boolean
    OR (v_result->>'createdCount')::integer<>0 THEN
    RAISE EXCEPTION 'TEST_FAILED: direct request capture retry duplicated source';
  END IF;

  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub',v_transfer.requested_by,'role','authenticated')::text,true);
  PERFORM set_config('request.jwt.claim.sub',v_transfer.requested_by::text,true);
  PERFORM public.set_active_company_context(v_transfer.company_id,'F4A_TEST');
  v_blocked:=false;
  BEGIN
    PERFORM public.review_sales_payment_verification(v_transfer.id,
      v_transfer.master_version,'VERIFY',NULL,gen_random_uuid());
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='CUSTOM_PERMISSION_DENIED' THEN v_blocked:=true; ELSE RAISE; END IF;
  END;
  IF NOT v_blocked THEN RAISE EXCEPTION
    'TEST_FAILED: unauthorized POS maker reached Finance review'; END IF;

  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub',v_reviewer,'role','authenticated')::text,true);
  PERFORM set_config('request.jwt.claim.sub',v_reviewer::text,true);
  PERFORM public.set_active_company_context(v_transfer.company_id,'F4A_TEST');
  v_blocked:=false;
  BEGIN
    PERFORM public.review_sales_payment_verification(v_maker_request,
      1,'VERIFY',NULL,gen_random_uuid());
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='MAKER_CHECKER_REQUIRED' THEN v_blocked:=true; ELSE RAISE; END IF;
  END;
  IF NOT v_blocked THEN RAISE EXCEPTION
    'TEST_FAILED: authorized maker verified own rollback fixture'; END IF;

  v_blocked:=false;
  BEGIN
    PERFORM public.review_sales_payment_verification(v_transfer.id,
      v_transfer.master_version+1,'VERIFY',NULL,gen_random_uuid());
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='MASTER_VERSION_CONFLICT' THEN v_blocked:=true; ELSE RAISE; END IF;
  END;
  IF NOT v_blocked THEN RAISE EXCEPTION
    'TEST_FAILED: stale request version accepted'; END IF;

  PERFORM set_config('pos.atomic.verify.key',gen_random_uuid()::text,true);
  v_result:=public.review_sales_payment_verification(v_transfer.id,
    v_transfer.master_version,'VERIFY','Rollback-only atomic verification',
    current_setting('pos.atomic.verify.key')::uuid);
  v_event:=(v_result->>'financialEventId')::uuid;
  IF v_result->>'status'<>'VERIFIED'
    OR v_result->'posting'->>'status'<>'POSTED'
    OR v_event IS NULL THEN
    RAISE EXCEPTION 'TEST_FAILED: bank verification did not post atomically: %',v_result;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.sales_payment_verification_requests request
      WHERE request.company_id=v_transfer.company_id AND request.id=v_transfer.id
        AND request.status='VERIFIED' AND request.receipt_timing='POST_DISPATCH'
        AND request.settlement_target='PAYMENT_CLEARING'
        AND request.financial_event_id=v_event)
    OR NOT EXISTS (SELECT 1 FROM public.financial_events event
      WHERE event.company_id=v_transfer.company_id AND event.id=v_event
        AND event.status='POSTED' AND event.system_event_key='SALE_PAYMENT_VERIFIED') THEN
    RAISE EXCEPTION 'TEST_FAILED: verified request/Event state invalid';
  END IF;
  SELECT count(*) INTO v_payment_journal_rows FROM public.finance_journals journal
  WHERE journal.company_id=v_transfer.company_id
    AND journal.financial_event_id=v_event AND journal.status='POSTED';
  IF v_payment_journal_rows<>1 THEN
    RAISE EXCEPTION 'TEST_FAILED: exact payment Journal missing';
  END IF;
  IF (SELECT count(*) FROM public.finance_journal_lines line
      JOIN public.finance_journals journal ON journal.company_id=line.company_id
        AND journal.id=line.journal_id
      WHERE journal.company_id=v_transfer.company_id
        AND journal.financial_event_id=v_event)<>2 THEN
    RAISE EXCEPTION 'TEST_FAILED: payment Journal is not a two-line reclassification';
  END IF;
  IF (SELECT event.status::text FROM public.financial_events event
      WHERE event.company_id=v_transfer.company_id AND event.id=v_sale_event)
      IS DISTINCT FROM v_sale_event_status
    OR (SELECT count(*) FROM public.finance_journals journal
      WHERE journal.company_id=v_transfer.company_id
        AND journal.financial_event_id=v_sale_event)<>v_sale_journal_rows THEN
    RAISE EXCEPTION 'TEST_FAILED: verification mutated Sale Event ownership';
  END IF;

  v_result:=public.review_sales_payment_verification(v_transfer.id,
    v_transfer.master_version,'VERIFY','Rollback-only atomic verification',
    current_setting('pos.atomic.verify.key')::uuid);
  IF NOT (v_result->>'exactRetry')::boolean
    OR v_result->'posting'->>'status'<>'POSTED'
    OR (SELECT count(*) FROM public.finance_journals journal
      WHERE journal.company_id=v_transfer.company_id
        AND journal.financial_event_id=v_event)<>1 THEN
    RAISE EXCEPTION 'TEST_FAILED: exact retry duplicated payment posting';
  END IF;

  SELECT request.* INTO v_clearing
  FROM public.sales_payment_verification_requests request
  JOIN public.sales_headers sale ON sale.company_id=request.company_id
    AND sale.id=request.sales_id
  WHERE request.company_id=v_transfer.company_id
    AND request.id<>v_transfer.id AND request.status='PENDING'
    AND request.verification_mode='MANUAL_REVIEW'
    AND request.settlement_route_snapshot='CLEARING'
    AND sale.sales_origin='POS'
    AND sale.sales_process_mode='RETAIL_CONFIRM_INVOICE'
    AND sale.document_status='POSTED'
    AND sale.order_runtime_status='LEGACY_POSTED'
  ORDER BY request.requested_at,request.id LIMIT 1 FOR UPDATE OF request;
  IF FOUND AND v_clearing.requested_by<>v_reviewer THEN
    v_result:=public.review_sales_payment_verification(v_clearing.id,
      v_clearing.master_version,'VERIFY','Rollback-only no-effect verification',
      gen_random_uuid());
    IF v_result->>'status'<>'VERIFIED'
      OR v_result->'posting'->>'status'<>'CANCELED'
      OR NOT coalesce((v_result->'posting'->>'noFinancialEffect')::boolean,false)
      OR EXISTS (SELECT 1 FROM public.finance_journals journal
        WHERE journal.company_id=v_clearing.company_id
          AND journal.financial_event_id=(v_result->>'financialEventId')::uuid) THEN
      RAISE EXCEPTION 'TEST_FAILED: same-account clearing did not close as no-effect';
    END IF;
  END IF;

  SELECT company.id INTO v_other_company FROM public.companies company
  WHERE company.id<>v_transfer.company_id AND company.status='ACTIVE'
  ORDER BY company.id LIMIT 1;
  IF v_other_company IS NOT NULL
    AND (SELECT role::text FROM public.profiles WHERE id=v_reviewer)='super_admin' THEN
    PERFORM public.set_active_company_context(v_other_company,'F4A_TEST');
    v_blocked:=false;
    BEGIN
      PERFORM public.review_sales_payment_verification(v_transfer.id,
        v_transfer.master_version,'VERIFY',NULL,gen_random_uuid());
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM='PAYMENT_VERIFICATION_NOT_FOUND' THEN v_blocked:=true; ELSE RAISE; END IF;
    END;
    IF NOT v_blocked THEN RAISE EXCEPTION
      'TEST_FAILED: cross-Company request was visible'; END IF;
  END IF;
END
$test$;

ROLLBACK;

SELECT 'pos_retail_non_cash_atomic_verification_behavior' check_name,
  'PASS' status,0 violation_rows,
  jsonb_build_object('tested',jsonb_build_array(
    'installed exact forward migration','direct request capture retry idempotency',
    'unauthorized POS maker denial','authorized maker-checker denial',
    'stale version denial',
    'Finance Verify and Journal posting in one transaction',
    'POST_DISPATCH PAYMENT_CLEARING ownership','two-line Bank reclassification',
    'Sale Event ownership unchanged','exact retry idempotency',
    'same-account Clearing no-financial-effect when fixture exists',
    'cross-Company denial when super-admin fixture exists',
    'all test effects rolled back')) details;
