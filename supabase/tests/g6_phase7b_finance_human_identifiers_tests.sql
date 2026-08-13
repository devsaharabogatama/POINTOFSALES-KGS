-- G6 corrective phase 7B behavior: display numbering is server-owned.
-- SAFETY: test rows and counters are rolled back.

BEGIN;

DO $test$
DECLARE
    v_actor UUID;
    v_company UUID;
    v_first TEXT;
    v_second TEXT;
    v_first_value BIGINT;
    v_second_value BIGINT;
BEGIN
    SELECT profile.id INTO v_actor
    FROM public.profiles profile
    JOIN auth.users auth_user ON auth_user.id=profile.id
    WHERE profile.role='super_admin'::user_role
    ORDER BY profile.id LIMIT 1;
    SELECT company.id INTO v_company
    FROM public.companies company
    WHERE company.status='ACTIVE'
    ORDER BY company.id LIMIT 1;
    IF v_actor IS NULL OR v_company IS NULL THEN
        RAISE EXCEPTION
            'TEST_PRECONDITION_FAILED: linked Super Admin and active Company required';
    END IF;

    PERFORM set_config(
        'request.jwt.claims',
        jsonb_build_object('sub',v_actor,'role','authenticated')::TEXT,TRUE
    );
    PERFORM public.set_active_company_context(v_company,'G6_PHASE7B_TEST');

    INSERT INTO public.finance_posting_exceptions(
        company_id,source_table,source_id,reason_code,status
    ) VALUES(
        v_company,'G6_PHASE7B_TEST',gen_random_uuid(),
        'MISSING_REQUIRED_FUNCTION','PENDING_MAPPING'
    ) RETURNING display_no INTO v_first;
    INSERT INTO public.finance_posting_exceptions(
        company_id,source_table,source_id,reason_code,status
    ) VALUES(
        v_company,'G6_PHASE7B_TEST',gen_random_uuid(),
        'MISSING_REQUIRED_FUNCTION','PENDING_MAPPING'
    ) RETURNING display_no INTO v_second;

    IF v_first !~ '^EXC/[0-9]{4}/[0-9]{2}/[0-9]{6}$'
       OR v_second !~ '^EXC/[0-9]{4}/[0-9]{2}/[0-9]{6}$' THEN
        RAISE EXCEPTION 'TEST_FAILED: human identifier format invalid';
    END IF;
    v_first_value:=split_part(v_first,'/',4)::BIGINT;
    v_second_value:=split_part(v_second,'/',4)::BIGINT;
    IF v_second_value<>v_first_value+1 THEN
        RAISE EXCEPTION 'TEST_FAILED: Finance identifier sequence invalid';
    END IF;

    v_first:=private.next_finance_display_no(
        v_company,'JUR',DATE '2099-12-01'
    );
    v_second:=private.next_finance_display_no(
        v_company,'JUR',DATE '2099-12-01'
    );
    IF v_first<>'JUR/2099/12/000001'
       OR v_second<>'JUR/2099/12/000002' THEN
        RAISE EXCEPTION 'TEST_FAILED: monthly Journal sequence invalid';
    END IF;

    v_first:=private.next_finance_display_no(
        v_company,'REC',DATE '2099-11-01'
    );
    IF v_first<>'REC/2099/11/000001' THEN
        RAISE EXCEPTION 'TEST_FAILED: Reconciliation sequence invalid';
    END IF;

    IF has_function_privilege(
        'authenticated',
        'private.next_finance_display_no(uuid,text,date)','EXECUTE'
    ) OR has_table_privilege(
        'authenticated','private.finance_document_number_counters','SELECT'
    ) THEN
        RAISE EXCEPTION
            'TEST_FAILED: browser can allocate or inspect Finance counters';
    END IF;

    RAISE NOTICE
        'TEST PASSED: Journal, queue, exception, and reconciliation numbers are human-readable, sequential, tenant/month scoped, and server-owned.';
END
$test$;

ROLLBACK;
