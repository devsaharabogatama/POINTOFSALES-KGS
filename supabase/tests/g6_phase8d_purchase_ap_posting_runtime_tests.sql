-- G6 phase 8D behavioral: post all 9 historical Purchase/AP events and rollback.

BEGIN;
DO $test$
DECLARE
  v_actor UUID; v_event public.financial_events%ROWTYPE;
  v_result JSONB; v_replay JSONB; v_journal UUID;
  v_expected_supplier UUID;
  v_before_count BIGINT; v_after_count BIGINT;
  v_receipt_count INTEGER:=0; v_invoice_count INTEGER:=0; v_payment_count INTEGER:=0;
  v_zero_effect_count INTEGER:=0;
BEGIN
  SELECT profile.id INTO v_actor FROM public.profiles profile
  WHERE profile.role::TEXT='super_admin' ORDER BY profile.id LIMIT 1;
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: Super Admin profile required'; END IF;

  FOR v_event IN SELECT event.* FROM public.financial_events event
    WHERE event.status='HOLD'::public.event_status
      AND event.system_event_key IN(
        'GOODS_RECEIPT','SUPPLIER_INVOICE','SUPPLIER_PAYMENT')
    ORDER BY CASE event.system_event_key WHEN 'GOODS_RECEIPT' THEN 1
      WHEN 'SUPPLIER_INVOICE' THEN 2 ELSE 3 END,event.event_date,event.id
  LOOP
    IF v_event.system_event_key='GOODS_RECEIPT' THEN
      SELECT order_document.supplier_id INTO v_expected_supplier
      FROM public.goods_receipt_documents receipt
      JOIN public.supplier_order_documents order_document
        ON order_document.company_id=receipt.company_id
       AND order_document.id=receipt.supplier_order_id
      WHERE receipt.company_id=v_event.company_id AND receipt.id=v_event.source_id;
    ELSE
      v_expected_supplier:=(v_event.amounts->>'supplierId')::UUID;
    END IF;
    SELECT count(*) INTO v_before_count FROM public.finance_journals
    WHERE company_id=v_event.company_id AND financial_event_id=v_event.id;
    v_result:=private.post_financial_event_core(
      v_event.company_id,v_event.id,v_event.event_version,v_actor);
    v_replay:=private.post_financial_event_core(
      v_event.company_id,v_event.id,v_event.event_version,v_actor);
    IF v_result->>'status'='CANCELED' AND
       v_result->>'reason'='NO_FINANCIAL_EFFECT' THEN
      SELECT count(*) INTO v_after_count FROM public.finance_journals
      WHERE company_id=v_event.company_id AND financial_event_id=v_event.id;
      IF v_event.system_event_key<>'GOODS_RECEIPT'
        OR v_before_count<>0 OR v_after_count<>0
        OR COALESCE((v_replay->>'idempotentReplay')::BOOLEAN,FALSE) IS NOT TRUE
        OR v_replay->>'status'<>'CANCELED'
        OR EXISTS(SELECT 1 FROM public.financial_events closed_event
          WHERE closed_event.company_id=v_event.company_id
            AND closed_event.id=v_event.id
            AND (closed_event.status::TEXT<>'CANCELED'
              OR closed_event.error_message<>'NO_FINANCIAL_EFFECT')) THEN
        RAISE EXCEPTION 'TEST_FAILED: zero-effect Receipt closure invalid for %',
          v_event.id;
      END IF;
      v_receipt_count:=v_receipt_count+1;
      v_zero_effect_count:=v_zero_effect_count+1;
      CONTINUE;
    END IF;
    v_journal:=(v_result->>'journalId')::UUID;
    SELECT count(*) INTO v_after_count FROM public.finance_journals
    WHERE company_id=v_event.company_id AND financial_event_id=v_event.id;
    IF v_before_count<>0 OR v_after_count<>1 OR v_result->>'status'<>'POSTED'
      OR COALESCE((v_replay->>'idempotentReplay')::BOOLEAN,FALSE) IS NOT TRUE
      OR v_result->>'journalId' IS DISTINCT FROM v_replay->>'journalId' THEN
      RAISE EXCEPTION 'TEST_FAILED: posting identity or replay invalid for %',v_event.id;
    END IF;
    IF EXISTS(SELECT 1 FROM public.finance_journals journal
      WHERE journal.company_id=v_event.company_id AND journal.id=v_journal
        AND (journal.status<>'POSTED' OR journal.total_debit<=0
          OR journal.total_debit<>journal.total_credit)) THEN
      RAISE EXCEPTION 'TEST_FAILED: unbalanced Journal for %',v_event.id;
    END IF;
    IF NOT EXISTS(SELECT 1 FROM public.finance_journal_lines line
      WHERE line.company_id=v_event.company_id AND line.journal_id=v_journal
        AND line.supplier_id=v_expected_supplier) THEN
      RAISE EXCEPTION 'TEST_FAILED: Supplier dimension missing for %',v_event.id;
    END IF;

    IF v_event.system_event_key='GOODS_RECEIPT' THEN
      v_receipt_count:=v_receipt_count+1;
      IF (SELECT count(*) FROM public.finance_journal_lines line
          WHERE line.company_id=v_event.company_id AND line.journal_id=v_journal)<>2
        OR NOT EXISTS(SELECT 1 FROM public.finance_journal_lines line
          WHERE line.company_id=v_event.company_id AND line.journal_id=v_journal
            AND line.account_id=(v_event.amounts->>'inventoryAccountId')::UUID
            AND line.debit=round((v_event.amounts->>'inventoryDebit')::NUMERIC,4))
        OR NOT EXISTS(SELECT 1 FROM public.finance_journal_lines line
          WHERE line.company_id=v_event.company_id AND line.journal_id=v_journal
            AND line.account_id=(v_event.amounts->>'supplierApAccountId')::UUID
            AND line.credit=round((v_event.amounts->>'supplierApProvisionalCredit')::NUMERIC,4))
      THEN RAISE EXCEPTION 'TEST_FAILED: Goods Receipt journal invalid'; END IF;

    ELSIF v_event.system_event_key='SUPPLIER_INVOICE' THEN
      v_invoice_count:=v_invoice_count+1;
      IF NOT EXISTS(SELECT 1 FROM public.finance_journal_lines line
          WHERE line.company_id=v_event.company_id AND line.journal_id=v_journal
            AND line.account_id=(v_event.amounts->>'apFinalAccountId')::UUID
            AND line.credit=round((v_event.amounts->>'apFinalCredit')::NUMERIC,4))
      THEN RAISE EXCEPTION 'TEST_FAILED: Supplier Invoice AP Final invalid'; END IF;

    ELSE
      v_payment_count:=v_payment_count+1;
      IF (SELECT count(*) FROM public.finance_journal_lines line
          WHERE line.company_id=v_event.company_id AND line.journal_id=v_journal)<>2
        OR NOT EXISTS(SELECT 1 FROM public.finance_journal_lines line
          WHERE line.company_id=v_event.company_id AND line.journal_id=v_journal
            AND line.account_id=(v_event.amounts->>'apFinalDebitAccount')::UUID
            AND line.debit=round((v_event.amounts->>'totalAmount')::NUMERIC,4))
        OR NOT EXISTS(SELECT 1 FROM public.finance_journal_lines line
          WHERE line.company_id=v_event.company_id AND line.journal_id=v_journal
            AND line.account_id=(v_event.amounts->>'cashOrBankCreditAccount')::UUID
            AND line.credit=round((v_event.amounts->>'totalAmount')::NUMERIC,4))
      THEN RAISE EXCEPTION 'TEST_FAILED: Supplier Payment journal invalid'; END IF;
    END IF;
  END LOOP;

  IF v_receipt_count<>4 OR v_invoice_count<>3 OR v_payment_count<>2 THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: expected 4/3/2 events, got %/%/%',
      v_receipt_count,v_invoice_count,v_payment_count;
  END IF;
  RAISE NOTICE 'TEST PASSED: 4 Goods Receipt (% no-financial-effect), 3 Supplier Invoice and 2 Supplier Payment events close/post atomically, balance, retain Supplier dimensions, replay idempotently, and will roll back.',v_zero_effect_count;
END
$test$;
ROLLBACK;
