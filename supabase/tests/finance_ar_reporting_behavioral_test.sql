-- F4A authenticated AR report behavior against existing final data.
-- Only active-Company context is touched and the transaction is rolled back.
BEGIN;
DO $setup$
DECLARE v_actor UUID;v_company UUID;v_customer UUID;
BEGIN
  WITH target_sales AS (
    SELECT sale.company_id,sale.customer_id
    FROM public.sales_headers sale
    JOIN public.companies company ON company.id=sale.company_id AND company.status='ACTIVE'
    WHERE sale.document_status='POSTED' AND sale.is_tempo
    ORDER BY sale.transaction_date,sale.id LIMIT 1
  ),candidates AS (
    SELECT profile.id actor_id,target.company_id,target.customer_id,0 actor_rank
    FROM target_sales target
    CROSS JOIN LATERAL(SELECT profile.id FROM public.profiles profile
      WHERE profile.role::TEXT='super_admin' ORDER BY profile.id LIMIT 1) profile
    UNION ALL
    SELECT membership.user_id,target.company_id,target.customer_id,1
    FROM target_sales target JOIN public.company_memberships membership
      ON membership.company_id=target.company_id AND membership.status='ACTIVE'
      AND membership.role_code IN('COMPANY_OWNER','COMPANY_ADMIN','FINANCE','ACCOUNTING')
  )
  SELECT candidate.actor_id,candidate.company_id,candidate.customer_id
    INTO v_actor,v_company,v_customer
  FROM candidates candidate
  WHERE (private.acp_resolve_permission(candidate.company_id,candidate.actor_id,
      'finance.customer_receipts')->'effectiveCapabilities') ?& ARRAY['VIEW','EXPORT']
  ORDER BY candidate.actor_rank,candidate.actor_id
  LIMIT 1;
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: AR report actor and TEMPO invoice required';
  END IF;
  PERFORM set_config('f4a.actor',v_actor::TEXT,TRUE);
  PERFORM set_config('f4a.company',v_company::TEXT,TRUE);
  PERFORM set_config('f4a.customer',v_customer::TEXT,TRUE);
  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub',v_actor,'role','authenticated')::TEXT,TRUE);
  PERFORM public.set_active_company_context(v_company,'F4A_TEST');
END
$setup$;

DO $test$
DECLARE v_aging JSONB;v_statement JSONB;v_export JSONB;v_rejected BOOLEAN:=FALSE;v_today DATE;
  v_customer UUID:=current_setting('f4a.customer')::UUID;
BEGIN
  v_aging:=public.get_finance_ar_aging(NULL,v_customer,NULL);
  v_today:=(v_aging->>'asOf')::DATE;
  IF v_aging->>'companyId'<>current_setting('f4a.company')
    OR jsonb_typeof(v_aging->'invoices')<>'array'
    OR jsonb_typeof(v_aging->'buckets')<>'array'
    OR jsonb_array_length(v_aging->'buckets')<>6 THEN
    RAISE EXCEPTION 'TEST_FAILED: AR aging response invalid: %',v_aging;
  END IF;
  v_statement:=public.get_finance_customer_statement(
    v_customer,v_today-365,v_today,NULL);
  IF v_statement->'customer'->>'id'<>v_customer::TEXT
    OR jsonb_typeof(v_statement->'rows')<>'array'
    OR (v_statement->>'endingBalance')::NUMERIC<0 THEN
    RAISE EXCEPTION 'TEST_FAILED: Customer statement response invalid: %',v_statement;
  END IF;
  v_export:=public.export_finance_ar_report(
    'AGING',v_customer,v_today-365,v_today,NULL);
  IF v_export->>'companyId'<>current_setting('f4a.company') THEN
    RAISE EXCEPTION 'TEST_FAILED: AR export response invalid';
  END IF;
  BEGIN
    PERFORM public.get_finance_ar_aging(v_today+1,v_customer,NULL);
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='AR_AS_OF_DATE_FUTURE' THEN v_rejected:=TRUE; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'TEST_FAILED: future as-of accepted'; END IF;
  RAISE NOTICE 'TEST PASSED: F4A AR aging, Customer statement, export and date guard are tenant-scoped and read-only.';
END
$test$;
ROLLBACK;
