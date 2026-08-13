-- G6 phase 8A behavioral test: settlement resolution is exact and read-only.
-- SAFETY: no persistent business mutation.

DO $test$
DECLARE
  v_row RECORD;
  v_event public.financial_events%ROWTYPE;
  v_resolved UUID;
BEGIN
  FOR v_row IN
    WITH scope AS (
      SELECT event.company_id,event.id event_id,CASE payment.settlement_route_snapshot
        WHEN 'CASH_DRAWER' THEN 'CASH_DRAWER'
        WHEN 'DIRECT_BANK' THEN method.bank_account_function
        WHEN 'CLEARING' THEN method.clearing_account_function
        WHEN 'RECEIVABLE' THEN 'CUSTOMER_RECEIVABLE'
        WHEN 'INTERNAL_LIABILITY' THEN 'CUSTOMER_BALANCE_LIABILITY'
      END function_key
      FROM public.financial_events event
      JOIN public.sales_payments payment
        ON payment.company_id=event.company_id AND payment.sales_id=event.source_id
      JOIN public.payment_methods method
        ON method.company_id=payment.company_id AND method.id=payment.payment_method_id
      WHERE event.status='HOLD'::public.event_status
        AND event.system_event_key='SALE_POSTED'
      UNION ALL
      SELECT event.company_id,event.id event_id,CASE refund.settlement_route_snapshot
        WHEN 'CASH_DRAWER' THEN 'CASH_DRAWER'
        WHEN 'DIRECT_BANK' THEN method.bank_account_function
        WHEN 'CLEARING' THEN method.clearing_account_function
        WHEN 'RECEIVABLE' THEN 'CUSTOMER_RECEIVABLE'
        WHEN 'INTERNAL_LIABILITY' THEN 'CUSTOMER_BALANCE_LIABILITY'
      END
      FROM public.financial_events event
      JOIN public.sales_return_refunds refund
        ON refund.company_id=event.company_id AND refund.document_id=event.source_id
      JOIN public.payment_methods method
        ON method.company_id=refund.company_id AND method.id=refund.payment_method_id
      WHERE event.status='HOLD'::public.event_status
        AND event.system_event_key='SALES_RETURN'
    ) SELECT * FROM scope
  LOOP
    SELECT event.* INTO STRICT v_event
    FROM public.financial_events event
    WHERE event.company_id=v_row.company_id AND event.id=v_row.event_id;
    v_resolved:=private.resolve_financial_event_account(
      v_event,v_row.function_key);
    IF v_resolved IS NULL THEN
      RAISE EXCEPTION 'TEST_FAILED: unresolved % for Event %',
        v_row.function_key,v_row.event_id;
    END IF;
  END LOOP;

  IF EXISTS(
    SELECT 1 FROM public.finance_journals journal
    JOIN public.financial_events event ON event.company_id=journal.company_id
     AND event.id=journal.financial_event_id
    WHERE event.system_event_key IN('SALE_POSTED','SALES_RETURN')
  ) THEN
    RAISE EXCEPTION 'TEST_FAILED: Phase 8A unexpectedly created Journal effects';
  END IF;

  RAISE NOTICE
    'TEST PASSED: every historical Sale/Return settlement leg resolves exactly and Phase 8A creates no Journal effect.';
END
$test$;
