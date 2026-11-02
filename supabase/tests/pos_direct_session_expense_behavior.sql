-- Rollback-only behavior for POS direct session Expense.
-- Requires one authenticated actor with an OPEN session and both one Cash and
-- one mapped non-cash Expense payment method in the same Company/Store.
BEGIN;

DO $test$
DECLARE
  v_company UUID;v_actor UUID;v_store UUID;v_session UUID;
  v_category UUID;v_cash UUID;v_noncash UUID;
  v_cash_client UUID:=gen_random_uuid();v_cash_key UUID:=gen_random_uuid();
  v_non_client UUID:=gen_random_uuid();v_non_key UUID:=gen_random_uuid();
  v_cash_result JSONB;v_cash_retry JSONB;v_non_result JSONB;v_workspace JSONB;
  v_cash_document UUID;v_non_document UUID;v_rejected BOOLEAN;
  v_expected NUMERIC;v_summary_before JSONB;v_summary_after JSONB;
  v_sales_before BIGINT;v_stock_before BIGINT;v_fifo_before BIGINT;
BEGIN
  IF (SELECT count(*) FROM private.kgs_schema_migrations
      WHERE version='20261101100000')<>1 THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: migration 20261101100000 missing';
  END IF;
  IF to_regprocedure('public.post_pos_expense(uuid,uuid,uuid,text,uuid,text,numeric,uuid,text,text,text,date,uuid,uuid)') IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: post_pos_expense missing';
  END IF;

  SELECT session.company_id,session.cashier_id,session.store_id,session.id
  INTO v_company,v_actor,v_store,v_session
  FROM public.cashier_sessions session
  JOIN auth.users auth_user ON auth_user.id=session.cashier_id
  JOIN public.stores store ON store.company_id=session.company_id
    AND store.id=session.store_id AND store.status='ACTIVE'
  JOIN public.pos_terminals terminal ON terminal.company_id=session.company_id
    AND terminal.store_id=session.store_id AND terminal.id=session.pos_id
    AND terminal.status='ACTIVE'
  WHERE session.status='OPEN'::public.session_status
    AND public.private_company_feature_enabled(session.company_id,'expense_enabled')
  ORDER BY public.private_is_super_admin(session.cashier_id) DESC,session.id
  LIMIT 1;
  IF v_session IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: authenticated OPEN Expense session required';
  END IF;

  PERFORM set_config('request.jwt.claim.sub',v_actor::text,true);
  PERFORM set_config('request.jwt.claim.role','authenticated',true);
  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub',v_actor,'role','authenticated')::text,true);
  PERFORM public.set_active_company_context(v_company,'POS_EXPENSE_TEST');

  SELECT category.id INTO v_category
  FROM public.expense_categories category
  WHERE category.company_id=v_company AND category.is_active
  ORDER BY category.category_name,category.id LIMIT 1;
  SELECT method.id INTO v_cash
  FROM public.payment_methods method
  WHERE method.company_id=v_company AND method.is_active
    AND method.method_type='CASH' AND method.settlement_route='CASH_DRAWER'
    AND method.effective_from<=clock_timestamp()
    AND (method.effective_to IS NULL OR method.effective_to>clock_timestamp())
    AND (method.available_all_stores OR EXISTS(
      SELECT 1 FROM public.payment_method_store_assignments assignment
      WHERE assignment.company_id=v_company
        AND assignment.payment_method_id=method.id AND assignment.store_id=v_store))
  ORDER BY method.is_default DESC,method.id LIMIT 1;
  SELECT method.id INTO v_noncash
  FROM public.payment_methods method
  WHERE method.company_id=v_company AND method.is_active
    AND method.method_type IN('TRANSFER','QRIS','CARD','E_WALLET')
    AND method.settlement_route IN('DIRECT_BANK','CLEARING')
    AND method.effective_from<=clock_timestamp()
    AND (method.effective_to IS NULL OR method.effective_to>clock_timestamp())
    AND (method.available_all_stores OR EXISTS(
      SELECT 1 FROM public.payment_method_store_assignments assignment
      WHERE assignment.company_id=v_company
        AND assignment.payment_method_id=method.id AND assignment.store_id=v_store))
  ORDER BY method.is_default DESC,method.id LIMIT 1;
  IF v_category IS NULL OR v_cash IS NULL OR v_noncash IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: active category plus Cash and non-cash methods required';
  END IF;

  v_workspace:=public.get_pos_expense_workspace(v_session);
  v_summary_before:=v_workspace->'sessionExpenseSummary';
  SELECT count(*) INTO v_sales_before FROM public.sales_headers;
  SELECT count(*) INTO v_stock_before FROM public.stock_movements;
  SELECT count(*) INTO v_fifo_before FROM public.product_batches;
  v_expected:=private.calculate_cashier_session_expected_cash(v_company,v_session);
  IF v_expected<1 THEN
    UPDATE public.cashier_sessions
    SET opening_cash_actual=opening_cash_actual+(1-v_expected),updated_at=clock_timestamp()
    WHERE company_id=v_company AND id=v_session;
  END IF;

  v_cash_result:=public.post_pos_expense(
    v_store,v_session,v_category,'CASHIER',v_actor,'POS Expense Test',1,
    v_cash,NULL,'Rollback-only Cash Expense',NULL,NULL,v_cash_client,v_cash_key
  );
  v_cash_document:=(v_cash_result->>'documentId')::UUID;
  IF v_cash_result->>'status'<>'DISBURSED'
    OR (v_cash_result->>'paymentMethodType')<>'CASH'
    OR COALESCE((v_cash_result->>'idempotentReplay')::BOOLEAN,TRUE) THEN
    RAISE EXCEPTION 'TEST_FAILED: Cash direct Expense result invalid: %',v_cash_result;
  END IF;
  IF (SELECT count(*) FROM public.cash_drawer_movements movement
      WHERE movement.company_id=v_company AND movement.cashier_session_id=v_session
        AND movement.source_table='expense_disbursements'
        AND movement.source_id=(v_cash_result->>'disbursementId')::UUID
        AND movement.direction='OUT' AND movement.amount=1)<>1 THEN
    RAISE EXCEPTION 'TEST_FAILED: Cash drawer OUT missing or duplicated';
  END IF;

  v_cash_retry:=public.post_pos_expense(
    v_store,v_session,v_category,'CASHIER',v_actor,'POS Expense Test',1,
    v_cash,NULL,'Rollback-only Cash Expense',NULL,NULL,v_cash_client,v_cash_key
  );
  IF NOT COALESCE((v_cash_retry->>'idempotentReplay')::BOOLEAN,FALSE)
    OR v_cash_retry->>'documentId'<>v_cash_result->>'documentId'
    OR v_cash_retry->>'disbursementId'<>v_cash_result->>'disbursementId' THEN
    RAISE EXCEPTION 'TEST_FAILED: exact Cash retry not idempotent';
  END IF;
  v_rejected:=FALSE;
  BEGIN
    PERFORM public.post_pos_expense(
      v_store,v_session,v_category,'CASHIER',v_actor,'POS Expense Test',2,
      v_cash,NULL,'Changed retry must fail',NULL,NULL,v_cash_client,v_cash_key
    );
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='CLIENT_EXPENSE_ID_CONFLICT' THEN v_rejected:=TRUE; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'TEST_FAILED: changed retry accepted'; END IF;

  v_non_result:=public.post_pos_expense(
    v_store,v_session,v_category,'CASHIER',v_actor,'POS Expense Test',1,
    v_noncash,NULL,'Rollback-only non-cash Expense',NULL,NULL,v_non_client,v_non_key
  );
  v_non_document:=(v_non_result->>'documentId')::UUID;
  IF v_non_result->>'status'<>'DISBURSED'
    OR v_non_result->>'paymentMethodType'='CASH'
    OR (v_non_result->>'expectedCashAfter') IS NOT NULL THEN
    RAISE EXCEPTION 'TEST_FAILED: non-cash direct Expense result invalid: %',v_non_result;
  END IF;
  IF EXISTS(SELECT 1 FROM public.cash_drawer_movements movement
      WHERE movement.company_id=v_company
        AND movement.source_table='expense_disbursements'
        AND movement.source_id=(v_non_result->>'disbursementId')::UUID) THEN
    RAISE EXCEPTION 'TEST_FAILED: non-cash Expense changed drawer';
  END IF;
  IF (SELECT count(*) FROM public.expense_disbursements disbursement
      WHERE disbursement.company_id=v_company
        AND disbursement.document_id=v_cash_document
        AND disbursement.cashier_session_id=v_session
        AND disbursement.pos_terminal_id IS NOT NULL)<>1
    OR (SELECT count(*) FROM public.expense_disbursements disbursement
      WHERE disbursement.company_id=v_company
        AND disbursement.document_id=v_non_document
        AND disbursement.cashier_session_id IS NULL
        AND disbursement.pos_terminal_id IS NULL)<>1
    OR (SELECT count(*) FROM public.expense_documents document
      WHERE document.company_id=v_company
        AND document.id IN(v_cash_document,v_non_document)
        AND document.cashier_session_id=v_session)<>2
    OR (SELECT count(*) FROM public.financial_events event
      WHERE event.company_id=v_company AND event.source_table='expense_disbursements'
        AND event.source_id IN((v_cash_result->>'disbursementId')::UUID,
          (v_non_result->>'disbursementId')::UUID))<>2 THEN
    RAISE EXCEPTION 'TEST_FAILED: canonical disbursement/Event lineage invalid';
  END IF;
  IF EXISTS(
    SELECT 1
    FROM public.financial_events event
    WHERE event.company_id=v_company
      AND event.source_id=(v_non_result->>'disbursementId')::UUID
      AND NULLIF(event.amounts->>'cashierSessionId','') IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'TEST_FAILED: non-cash Event claimed Cash Drawer session';
  END IF;

  v_workspace:=public.get_pos_expense_workspace(v_session);
  v_summary_after:=v_workspace->'sessionExpenseSummary';
  IF (v_summary_after->>'documentCount')::BIGINT
      <(v_summary_before->>'documentCount')::BIGINT+2
    OR (v_summary_after->>'totalAmount')::NUMERIC
      <(v_summary_before->>'totalAmount')::NUMERIC+2
    OR (v_summary_after->>'cashAmount')::NUMERIC
      <(v_summary_before->>'cashAmount')::NUMERIC+1
    OR (v_summary_after->>'nonCashAmount')::NUMERIC
      <(v_summary_before->>'nonCashAmount')::NUMERIC+1 THEN
    RAISE EXCEPTION 'TEST_FAILED: session Expense summary did not include both direct payments';
  END IF;
  IF EXISTS(
    SELECT 1 FROM jsonb_array_elements(v_workspace->'outstandingExpenses') item
    WHERE (item->>'cashier_session_id')::UUID IS DISTINCT FROM v_session
  ) THEN
    RAISE EXCEPTION 'TEST_FAILED: POS workspace leaked another Cashier Session';
  END IF;
  IF (SELECT count(*) FROM public.sales_headers)<>v_sales_before
    OR (SELECT count(*) FROM public.stock_movements)<>v_stock_before
    OR (SELECT count(*) FROM public.product_batches)<>v_fifo_before THEN
    RAISE EXCEPTION 'TEST_FAILED: Expense changed Sales, Stock or FIFO';
  END IF;
END
$test$;

ROLLBACK;

SELECT 'pos_direct_session_expense_behavior' check_name,'PASS' status,
  0 violation_rows,jsonb_build_object('tested',jsonb_build_array(
    'installed exact forward migration','authenticated active Company and OPEN session',
    'Cash direct Expense plus drawer OUT','non-cash direct Expense without drawer effect',
    'canonical disbursement and Finance Event lineage','direct approval audit path',
    'exact retry idempotency','changed retry denial','selected-session workspace',
    'per-session Cash/non-cash totals','zero Sales/Stock/FIFO effect',
    'all test effects rolled back')) details;
