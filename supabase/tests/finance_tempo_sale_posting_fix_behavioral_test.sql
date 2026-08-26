-- Finance TEMPO Sale posting forward-fix behavioral test.
-- SAFETY: posts one existing HOLD TEMPO Event and rolls every write back.
BEGIN;

DO $test$
DECLARE
  v_actor UUID;
  v_event public.financial_events%ROWTYPE;
  v_sale public.sales_headers%ROWTYPE;
  v_result JSONB;
  v_replay JSONB;
  v_journal_id UUID;
  v_receivable_account UUID;
  v_receivable_debit NUMERIC(20,4);
  v_before_count BIGINT;
BEGIN
  SELECT event.* INTO v_event
  FROM public.financial_events event
  JOIN public.sales_headers sale ON sale.company_id=event.company_id
    AND sale.id=event.source_id AND sale.document_status='POSTED'
  WHERE event.status::TEXT='HOLD' AND event.system_event_key='SALE_POSTED'
    AND event.event_type::TEXT='SALE_POSTED' AND event.source_table='sales_headers'
    AND sale.sisa_piutang>0
  ORDER BY event.event_date,event.id LIMIT 1;
  IF v_event.id IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: retryable HOLD TEMPO Sale required';
  END IF;
  SELECT * INTO v_sale FROM public.sales_headers sale
  WHERE sale.company_id=v_event.company_id AND sale.id=v_event.source_id;
  SELECT profile.id INTO v_actor FROM public.profiles profile
  WHERE profile.role::TEXT='super_admin' ORDER BY profile.id LIMIT 1;
  IF v_actor IS NULL THEN
    SELECT membership.user_id INTO v_actor FROM public.company_memberships membership
    WHERE membership.company_id=v_event.company_id AND membership.status='ACTIVE'
      AND membership.role_code IN('COMPANY_OWNER','COMPANY_ADMIN')
    ORDER BY membership.user_id LIMIT 1;
  END IF;
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: Finance posting actor required';
  END IF;
  v_receivable_account:=private.resolve_financial_event_account(
    v_event,'CUSTOMER_RECEIVABLE');
  SELECT count(*) INTO v_before_count FROM public.finance_journals journal
  WHERE journal.company_id=v_event.company_id
    AND journal.financial_event_id=v_event.id;
  IF v_before_count<>0 THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: TEMPO Event already has Journal';
  END IF;

  v_result:=private.post_financial_event_core(
    v_event.company_id,v_event.id,v_event.event_version,v_actor);
  v_replay:=private.post_financial_event_core(
    v_event.company_id,v_event.id,v_event.event_version,v_actor);
  v_journal_id:=(v_result->>'journalId')::UUID;
  SELECT COALESCE(sum(line.debit-line.credit),0) INTO v_receivable_debit
  FROM public.finance_journal_lines line
  WHERE line.company_id=v_event.company_id AND line.journal_id=v_journal_id
    AND line.account_id=v_receivable_account AND line.customer_id=v_sale.customer_id;

  IF v_result->>'status'<>'POSTED'
    OR COALESCE((v_replay->>'idempotentReplay')::BOOLEAN,FALSE) IS NOT TRUE
    OR v_result->>'journalId' IS DISTINCT FROM v_replay->>'journalId'
    OR round(v_receivable_debit,4)<>round(v_sale.sisa_piutang,4)
    OR EXISTS(SELECT 1 FROM public.finance_journals journal
      WHERE journal.company_id=v_event.company_id AND journal.id=v_journal_id
        AND (journal.status<>'POSTED' OR journal.total_debit<=0
          OR journal.total_debit<>journal.total_credit))
    OR (SELECT count(*) FROM public.finance_journals journal
      WHERE journal.company_id=v_event.company_id
        AND journal.financial_event_id=v_event.id)<>1 THEN
    RAISE EXCEPTION 'TEST_FAILED: TEMPO receivable posting or retry invalid';
  END IF;
END
$test$;

ROLLBACK;

SELECT 'finance_tempo_sale_posting_fix_behavioral_test' check_name,
  'PASS' status,0 violation_rows,jsonb_build_object(
    'writesPersisted',FALSE,
    'tested',ARRAY['unpaid or partial TEMPO','CUSTOMER_RECEIVABLE debit',
      'balanced Journal','exact idempotent retry']) details;
