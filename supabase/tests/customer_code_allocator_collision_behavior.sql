-- Rollback-only behavior for migration 20261102170000.
-- Exercises stale counters through Backoffice and POS writers; all effects roll back.

BEGIN;

DO $test$
DECLARE
  v_actor uuid;
  v_company_a uuid;
  v_company_b uuid;
  v_category_a uuid;
  v_category_b uuid;
  v_result jsonb;
  v_customer uuid;
  v_a_max bigint;
  v_a_explicit_suffix bigint;
  v_a_explicit_code text;
  v_a_expected_code text;
  v_b_max bigint;
  v_b_expected_code text;
  v_before_next bigint;
  v_after_next bigint;
  v_pos_actor uuid;
  v_pos_company uuid;
  v_pos_session uuid;
  v_pos_max bigint;
  v_pos_code_suffix bigint;
  v_no_session_company uuid;
  v_rejected boolean:=false;
  v_suffix text:=substr(replace(gen_random_uuid()::text,'-',''),1,10);
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations migration
    WHERE migration.version='20261102170000') THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: migration 20261102170000 required';
  END IF;

  SELECT profile.id INTO v_actor
  FROM public.profiles profile
  JOIN auth.users auth_user ON auth_user.id=profile.id
  WHERE profile.role='super_admin'::public.user_role
  ORDER BY profile.id LIMIT 1;
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: linked Super Admin required';
  END IF;

  -- Use existing configured Companies. Creating a synthetic active Company
  -- correctly invokes mandatory G6 Finance provisioning and is outside this test.
  SELECT company.id,category.id INTO v_company_a,v_category_a
  FROM public.companies company
  JOIN LATERAL (
    SELECT candidate.id FROM public.customer_categories candidate
    WHERE candidate.company_id=company.id AND candidate.is_active
    ORDER BY candidate.is_system_category DESC,candidate.id LIMIT 1
  ) category ON TRUE
  WHERE company.status='ACTIVE'
    AND EXISTS(SELECT 1 FROM public.customers customer
      WHERE customer.company_id=company.id
        AND upper(btrim(customer.code)) ~ '^CUST-[0-9]{1,18}$')
  ORDER BY company.company_code,company.id LIMIT 1;
  SELECT company.id,category.id INTO v_company_b,v_category_b
  FROM public.companies company
  JOIN LATERAL (
    SELECT candidate.id FROM public.customer_categories candidate
    WHERE candidate.company_id=company.id AND candidate.is_active
    ORDER BY candidate.is_system_category DESC,candidate.id LIMIT 1
  ) category ON TRUE
  WHERE company.status='ACTIVE' AND company.id<>v_company_a
    AND EXISTS(SELECT 1 FROM public.customers customer
      WHERE customer.company_id=company.id
        AND upper(btrim(customer.code)) ~ '^CUST-[0-9]{1,18}$')
  ORDER BY company.company_code,company.id LIMIT 1;
  IF v_company_a IS NULL OR v_company_b IS NULL THEN
    RAISE EXCEPTION
      'TEST_PRECONDITION_FAILED: two configured active Companies with canonical Customers required';
  END IF;

  PERFORM set_config('request.jwt.claims',
    jsonb_build_object('sub',v_actor,'role','authenticated')::text,true);
  PERFORM public.set_active_company_context(v_company_a,'G2_PHASE8_TEST');

  SELECT max((substring(upper(btrim(customer.code))
    FROM '^CUST-([0-9]{1,18})$'))::bigint)
  INTO v_a_max FROM public.customers customer
  WHERE customer.company_id=v_company_a
    AND upper(btrim(customer.code)) ~ '^CUST-[0-9]{1,18}$';
  v_a_explicit_suffix:=v_a_max+1000;
  v_a_explicit_code:='CUST-'||CASE WHEN v_a_explicit_suffix<1000000
    THEN lpad(v_a_explicit_suffix::text,6,'0') ELSE v_a_explicit_suffix::text END;
  v_a_expected_code:='CUST-'||CASE WHEN v_a_explicit_suffix+1<1000000
    THEN lpad((v_a_explicit_suffix+1)::text,6,'0') ELSE (v_a_explicit_suffix+1)::text END;

  -- Explicit code remains exact and advances the floor through the trigger.
  v_result:=public.save_customer(NULL,NULL,v_a_explicit_code,
    'Allocator Explicit A '||v_suffix,v_category_a,NULL,NULL,NULL,
    'INDIVIDUAL',0,NULL,NULL,true);
  IF v_result->>'customerCode'<>v_a_explicit_code THEN
    RAISE EXCEPTION 'TEST_FAILED: explicit Customer code changed';
  END IF;

  v_rejected:=false;
  BEGIN
    PERFORM public.save_customer(NULL,NULL,v_a_explicit_code,
      'Allocator Duplicate Code A '||v_suffix,v_category_a,NULL,NULL,NULL,
      'INDIVIDUAL',0,NULL,NULL,true);
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='DUPLICATE_CUSTOMER' THEN v_rejected:=true; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'TEST_FAILED: duplicate explicit Customer code accepted';
  END IF;

  -- Reproduce the production defect: occupied code while stored counter is stale.
  UPDATE private.customer_code_sequences sequence SET next_value=1
  WHERE sequence.company_id=v_company_a;
  v_result:=public.save_customer(NULL,NULL,NULL,
    'Allocator Generated A '||v_suffix,v_category_a,NULL,NULL,NULL,
    'INDIVIDUAL',0,NULL,NULL,true);
  v_customer:=(v_result->>'customerId')::uuid;
  IF v_result->>'customerCode'<>v_a_expected_code
     OR NOT EXISTS(SELECT 1 FROM public.customers customer
       WHERE customer.company_id=v_company_a AND customer.id=v_customer
         AND customer.code=v_a_expected_code) THEN
    RAISE EXCEPTION 'TEST_FAILED: stale Backoffice counter was not skipped';
  END IF;

  SELECT sequence.next_value INTO v_before_next
  FROM private.customer_code_sequences sequence WHERE sequence.company_id=v_company_a;
  v_rejected:=false;
  BEGIN
    PERFORM public.save_customer(NULL,NULL,NULL,
      ' Allocator   Generated A '||v_suffix,v_category_a,NULL,NULL,NULL,
      'INDIVIDUAL',0,NULL,NULL,true);
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='DUPLICATE_CUSTOMER' THEN v_rejected:=true; ELSE RAISE; END IF;
  END;
  SELECT sequence.next_value INTO v_after_next
  FROM private.customer_code_sequences sequence WHERE sequence.company_id=v_company_a;
  IF NOT v_rejected OR v_after_next<>v_before_next THEN
    RAISE EXCEPTION 'TEST_FAILED: duplicate-name failure changed counter';
  END IF;

  -- A second Company owns the same canonical numbers independently.
  PERFORM public.set_active_company_context(v_company_b,'G2_PHASE8_TEST');
  SELECT max((substring(upper(btrim(customer.code))
    FROM '^CUST-([0-9]{1,18})$'))::bigint)
  INTO v_b_max FROM public.customers customer
  WHERE customer.company_id=v_company_b
    AND upper(btrim(customer.code)) ~ '^CUST-[0-9]{1,18}$';
  v_b_expected_code:='CUST-'||CASE WHEN v_b_max+1<1000000
    THEN lpad((v_b_max+1)::text,6,'0') ELSE (v_b_max+1)::text END;
  UPDATE private.customer_code_sequences sequence SET next_value=1
  WHERE sequence.company_id=v_company_b;
  v_result:=public.save_customer(NULL,NULL,NULL,
    'Allocator Generated B '||v_suffix,v_category_b,NULL,NULL,NULL,
    'INDIVIDUAL',0,NULL,NULL,true);
  IF v_result->>'customerCode'<>v_b_expected_code THEN
    RAISE EXCEPTION 'TEST_FAILED: Company-independent allocation invalid';
  END IF;

  -- POS path uses an authenticated OPEN session and the same allocator.
  SELECT session.cashier_id,session.company_id,session.id
  INTO v_pos_actor,v_pos_company,v_pos_session
  FROM public.cashier_sessions session
  JOIN auth.users auth_user ON auth_user.id=session.cashier_id
  WHERE session.status='OPEN'::public.session_status
  ORDER BY session.opened_at DESC LIMIT 1;
  IF v_pos_session IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: linked OPEN Cashier Session required';
  END IF;
  PERFORM set_config('request.jwt.claims',
    jsonb_build_object('sub',v_pos_actor,'role','authenticated')::text,true);
  PERFORM public.set_active_company_context(v_pos_company,'G4_PHASE18_TEST');
  SELECT COALESCE(max((substring(upper(btrim(customer.code))
    FROM '^CUST-([0-9]{1,18})$'))::bigint),0)
  INTO v_pos_max FROM public.customers customer
  WHERE customer.company_id=v_pos_company
    AND upper(btrim(customer.code)) ~ '^CUST-[0-9]{1,18}$';
  INSERT INTO private.customer_code_sequences(company_id,next_value)
  VALUES(v_pos_company,1)
  ON CONFLICT(company_id) DO UPDATE SET next_value=1;
  v_result:=public.quick_create_pos_customer(
    'Allocator POS '||v_suffix,NULL,NULL,NULL,'INDIVIDUAL');
  v_pos_code_suffix:=(substring(v_result->>'customerCode' FROM '^CUST-([0-9]{1,18})$'))::bigint;
  IF v_pos_code_suffix IS NULL OR v_pos_code_suffix<=v_pos_max THEN
    RAISE EXCEPTION 'TEST_FAILED: stale POS counter was not skipped';
  END IF;

  -- Quick-create remains unavailable without an OPEN session.
  SELECT company.id INTO v_no_session_company
  FROM public.companies company
  WHERE company.status='ACTIVE'
    AND EXISTS(SELECT 1 FROM public.customer_categories category
      WHERE category.company_id=company.id AND category.is_active)
    AND NOT EXISTS(SELECT 1 FROM public.cashier_sessions session
      WHERE session.company_id=company.id AND session.cashier_id=v_actor
        AND session.status='OPEN'::public.session_status)
  ORDER BY company.company_code,company.id LIMIT 1;
  IF v_no_session_company IS NULL THEN
    RAISE EXCEPTION
      'TEST_PRECONDITION_FAILED: active Company without Super Admin OPEN session required';
  END IF;
  PERFORM set_config('request.jwt.claims',
    jsonb_build_object('sub',v_actor,'role','authenticated')::text,true);
  PERFORM public.set_active_company_context(v_no_session_company,'G4_PHASE18_TEST');
  v_rejected:=false;
  BEGIN
    PERFORM public.quick_create_pos_customer(
      'Allocator No Session '||v_suffix,NULL,NULL,NULL,'INDIVIDUAL');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='OPEN_CASHIER_SESSION_REQUIRED' THEN v_rejected:=true; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'TEST_FAILED: POS open-session guard changed';
  END IF;

  RAISE NOTICE 'TEST PASSED: Customer allocator skips stale collisions for Backoffice and POS, preserves explicit codes, tenant isolation, rollback-on-failure, and the POS session guard.';
END
$test$;

ROLLBACK;
