-- Rollback-only behavior for 20260918140000. Run the entire file.
BEGIN;
DO $test$
DECLARE
 v_company uuid:='4eedbf12-3c60-40e0-b2b7-1a48ca62b6f8';
 v_category uuid;v_bca uuid;v_old_bank uuid;v_actor uuid;v_period uuid;v_date date;
 v_journal uuid:=gen_random_uuid();v_event public.financial_events%rowtype;
 v_resolved uuid;v_immutable boolean:=false;v_target record;
BEGIN
 IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
   WHERE version='20260918140000') THEN
  RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: 20260918140000 required'; END IF;
 FOR v_target IN SELECT * FROM (VALUES
  ('4eedbf12-3c60-40e0-b2b7-1a48ca62b6f8'::uuid,'KMS'),
  ('809abdd9-d05f-4525-9726-1951a0ae1a81'::uuid,'SMS'),
  ('07bdffb9-8c56-444c-a49b-81ac86745674'::uuid,'LSM')
 ) target(company_id,label)
 LOOP
  SELECT category.id INTO STRICT v_category FROM public.transaction_categories category
  WHERE category.company_id=v_target.company_id AND category.system_key='SALE_PAYMENT'
   AND category.is_active;
  SELECT account.id INTO STRICT v_bca FROM public.chart_of_accounts account
  WHERE account.company_id=v_target.company_id AND account.account_code='1010100-1'
   AND account.account_name='BANK BCA' AND account.is_active AND account.is_postable;
  v_event.company_id:=v_target.company_id;v_event.transaction_category_id:=v_category;
  v_event.system_event_key:='SALE_PAYMENT';
  v_event.event_date:='2000-01-01 12:00:00+00'::timestamptz;
  v_resolved:=private.resolve_financial_event_account(v_event,'BANK');
  IF v_resolved IS DISTINCT FROM v_bca THEN
   RAISE EXCEPTION 'TEST_FAILED: historical SALE_PAYMENT BANK does not resolve BANK BCA for %',
    v_target.label; END IF;
 END LOOP;

 SELECT category.id INTO STRICT v_category FROM public.transaction_categories category
 WHERE category.company_id=v_company AND category.system_key='SALE_PAYMENT' AND category.is_active;
 SELECT account.id INTO STRICT v_bca FROM public.chart_of_accounts account
 WHERE account.company_id=v_company AND account.account_code='1010100-1'
  AND account.account_name='BANK BCA' AND account.is_active AND account.is_postable;
 SELECT fallback.account_id INTO STRICT v_old_bank
 FROM public.company_account_function_fallbacks fallback
 WHERE fallback.company_id=v_company AND fallback.account_function_key='BANK'
  AND fallback.status='ACTIVE' ORDER BY fallback.effective_from DESC LIMIT 1;
 SELECT rule.approved_by INTO STRICT v_actor FROM public.transaction_account_rules rule
 WHERE rule.company_id=v_company AND rule.transaction_category_id=v_category
  AND rule.account_function_key='BANK' AND rule.account_id=v_bca AND rule.status='ACTIVE'
 ORDER BY rule.effective_from LIMIT 1;
 SELECT period.id,period.start_date INTO STRICT v_period,v_date
 FROM public.accounting_periods period WHERE period.company_id=v_company
  AND period.status IN('OPEN','REOPENED') ORDER BY period.start_date LIMIT 1;

 INSERT INTO public.finance_journals(id,company_id,journal_no,journal_type,
  accounting_period_id,accounting_date,original_event_date,source_type,source_id,
  source_version,idempotency_key,system_event_key,transaction_category_id,
  transaction_rule_version,description,status,created_by)
 VALUES(v_journal,v_company,'TEST-RCB-'||upper(replace(v_journal::text,'-','')),
  'PRIOR_PERIOD_ADJUSTMENT',v_period,v_date,v_date,
  'CUSTOMER_RECEIPT_BANK_RECLASS_TEST',gen_random_uuid(),1,
  'TEST_CUSTOMER_RECEIPT_BANK_RECLASS|'||v_journal,'SALE_PAYMENT',v_category,1,
  'Rollback-only BANK BCA reclassification test','DRAFT',v_actor);
 INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,account_id,
  debit,credit,description) VALUES
  (v_company,v_journal,1,v_bca,1,0,'TEST_DEBIT_BANK_BCA'),
  (v_company,v_journal,2,v_old_bank,0,1,'TEST_CREDIT_OLD_BANK');
 UPDATE public.finance_journals SET status='POSTED',posted_by=v_actor
 WHERE company_id=v_company AND id=v_journal;
 IF NOT EXISTS(SELECT 1 FROM public.finance_journals journal
   WHERE journal.company_id=v_company AND journal.id=v_journal AND journal.status='POSTED'
    AND journal.total_debit=1 AND journal.total_credit=1) THEN
  RAISE EXCEPTION 'TEST_FAILED: balanced reclassification journal not posted'; END IF;
 BEGIN
  UPDATE public.finance_journals SET description='MUTATION MUST FAIL'
  WHERE company_id=v_company AND id=v_journal;
 EXCEPTION WHEN OTHERS THEN
  v_immutable:=position('POSTED_JOURNAL_IMMUTABLE' IN SQLERRM)>0;
 END;
 IF NOT v_immutable THEN RAISE EXCEPTION 'TEST_FAILED: posted correction journal mutable'; END IF;
END $test$;
ROLLBACK;
SELECT 'customer_receipt_bank_bca_reclassification_behavior' check_name,'PASS' status,
 0::bigint violation_rows,jsonb_build_object('tested',ARRAY[
  'historical SALE_PAYMENT BANK resolves BANK BCA','balanced append-only reclassification',
  'posted correction immutable','all fixture writes rolled back']) details;
