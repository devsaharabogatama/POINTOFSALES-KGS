-- F4B policy/queue behavioral test.
-- SAFETY: every write is rolled back.
BEGIN;

DO $test$
DECLARE
  v_actor UUID;
  v_company UUID;
  v_policy JSONB;
  v_changed JSONB;
  v_controlled JSONB;
  v_preview JSONB;
  v_error TEXT;
BEGIN
  SELECT membership.user_id,membership.company_id
  INTO v_actor,v_company
  FROM public.company_memberships membership
  JOIN public.companies company ON company.id=membership.company_id
    AND company.status='ACTIVE'
  WHERE membership.status='ACTIVE'
    AND membership.role_code IN('COMPANY_OWNER','COMPANY_ADMIN')
    AND EXISTS(SELECT 1 FROM public.financial_events event
      WHERE event.company_id=membership.company_id
        AND private.f4b_financial_event_supported(event))
    AND NOT EXISTS(SELECT 1 FROM public.user_company_permission_overrides override_state
      WHERE override_state.company_id=membership.company_id
        AND override_state.user_id=membership.user_id
        AND override_state.permission_key='finance.journals_reports')
  ORDER BY membership.company_id,membership.user_id LIMIT 1;
  IF v_actor IS NULL THEN
    SELECT profile.id,event.company_id INTO v_actor,v_company
    FROM public.profiles profile
    CROSS JOIN LATERAL(
      SELECT financial_event.company_id
      FROM public.financial_events financial_event
      JOIN public.companies company ON company.id=financial_event.company_id
        AND company.status='ACTIVE'
      WHERE private.f4b_financial_event_supported(financial_event)
      ORDER BY financial_event.company_id,financial_event.event_date,
        financial_event.id LIMIT 1
    ) event
    WHERE profile.role='super_admin'::public.user_role
    ORDER BY profile.id LIMIT 1;
  END IF;
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: Finance policy actor and supported HOLD event required';
  END IF;

  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub',v_actor,'role','authenticated')::TEXT,TRUE);
  EXECUTE 'SET LOCAL ROLE authenticated';
  PERFORM public.set_active_company_context(v_company,'BACKOFFICE_SELECTOR');

  v_policy:=public.get_finance_company_policy();
  IF v_policy->>'postingMode'<>'CONTROLLED' THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: controlled policy required';
  END IF;
  v_changed:=public.save_finance_posting_policy(
    (v_policy->>'masterVersion')::BIGINT,'AUTOMATIC');
  IF v_changed->>'postingMode'<>'AUTOMATIC'
     OR (v_changed->>'masterVersion')::BIGINT
       <=(v_policy->>'masterVersion')::BIGINT THEN
    RAISE EXCEPTION 'TEST_FAILED: automatic policy transition invalid';
  END IF;
  IF (public.save_finance_posting_policy(
      (v_changed->>'masterVersion')::BIGINT,'AUTOMATIC')
      ->>'idempotentReplay')::BOOLEAN IS DISTINCT FROM TRUE THEN
    RAISE EXCEPTION 'TEST_FAILED: policy exact retry is not idempotent';
  END IF;
  v_controlled:=public.save_finance_posting_policy(
    (v_changed->>'masterVersion')::BIGINT,'CONTROLLED');
  IF v_controlled->>'postingMode'<>'CONTROLLED' THEN
    RAISE EXCEPTION 'TEST_FAILED: controlled policy transition invalid';
  END IF;
  BEGIN
    PERFORM public.process_automatic_financial_events(1);
    RAISE EXCEPTION 'TEST_FAILED: automatic processor accepted controlled policy';
  EXCEPTION WHEN OTHERS THEN
    v_error:=SQLERRM;
    IF v_error NOT LIKE '%FINANCE_AUTOMATIC_POSTING_DISABLED%' THEN
      RAISE;
    END IF;
  END;
  v_preview:=public.preview_financial_event_posting_queue(1);
  IF v_preview->>'scopeSystemKey'<>'ALL_SUPPORTED'
     OR (v_preview->>'eventCount')::INTEGER<>1 THEN
    RAISE EXCEPTION 'TEST_FAILED: canonical controlled preview invalid';
  END IF;
END
$test$;

ROLLBACK;

SELECT 'finance_posting_policy_closure_behavioral_test' check_name,
  'PASS' status,jsonb_build_object(
    'writesPersisted',FALSE,
    'tested',ARRAY[
      'Owner/Admin policy transition','exact retry','controlled guard',
      'all-supported queue preview']) details;
