-- G6 corrective phase 2 behavioral test.
-- SAFETY: all Company/period/account/journal/audit fixtures are rolled back.

BEGIN;

DO $test$
DECLARE
    v_actor UUID;
    v_period UUID;
    v_journal UUID := '00000000-0000-0000-0000-000000094041';
    v_result JSONB;
    v_count BIGINT;
    v_rejected BOOLEAN;
BEGIN
    SELECT profile.id INTO v_actor
    FROM public.profiles profile
    JOIN auth.users auth_user ON auth_user.id = profile.id
    WHERE profile.role = 'super_admin'::user_role
    ORDER BY profile.id LIMIT 1;
    IF v_actor IS NULL THEN
        RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: linked Super Admin required';
    END IF;

    INSERT INTO public.companies(
        id,company_code,company_name,company_slug,status
    ) VALUES
        ('00000000-0000-0000-0000-000000094001',
         'G94A','G94 Company A','g94-company-a','ACTIVE'),
        ('00000000-0000-0000-0000-000000094002',
         'G94B','G94 Company B','g94-company-b','ACTIVE');

    INSERT INTO public.chart_of_accounts(
        id,company_id,account_code,account_name,account_type,normal_balance,
        is_system_account,is_postable,allow_manual_posting,
        allow_reconciliation,is_active,created_by,updated_by
    ) VALUES
        ('00000000-0000-0000-0000-000000094011',
         '00000000-0000-0000-0000-000000094001',
         'G94-1110','G94 Debit','ASSET','DEBIT',FALSE,TRUE,TRUE,FALSE,TRUE,
         v_actor,v_actor),
        ('00000000-0000-0000-0000-000000094012',
         '00000000-0000-0000-0000-000000094001',
         'G94-3110','G94 Credit','EQUITY','CREDIT',FALSE,TRUE,TRUE,FALSE,TRUE,
         v_actor,v_actor),
        ('00000000-0000-0000-0000-000000094013',
         '00000000-0000-0000-0000-000000094002',
         'G94B-1110','G94 Cross','ASSET','DEBIT',FALSE,TRUE,TRUE,FALSE,TRUE,
         v_actor,v_actor);

    PERFORM set_config(
        'request.jwt.claims',
        jsonb_build_object('sub',v_actor,'role','authenticated')::TEXT,TRUE
    );
    PERFORM public.set_active_company_context(
        '00000000-0000-0000-0000-000000094001','G6_PHASE2_TEST'
    );

    v_result := public.create_accounting_period(2032,1);
    v_period := (v_result->>'accountingPeriodId')::UUID;
    IF (v_result->>'masterVersion')::BIGINT <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: period create version invalid';
    END IF;

    v_result := public.lock_accounting_period(v_period,1);
    IF v_result->>'status' <> 'LOCKED'
       OR (v_result->>'masterVersion')::BIGINT <> 2 THEN
        RAISE EXCEPTION 'TEST_FAILED: period lock invalid';
    END IF;

    v_rejected := FALSE;
    BEGIN
        PERFORM public.reopen_accounting_period(v_period,2,NULL);
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'REOPEN_REASON_REQUIRED' THEN v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: reasonless reopen accepted';
    END IF;

    v_result := public.reopen_accounting_period(
        v_period,2,'G6 behavioral reopen'
    );
    IF v_result->>'status' <> 'REOPENED'
       OR (v_result->>'masterVersion')::BIGINT <> 3 THEN
        RAISE EXCEPTION 'TEST_FAILED: period reopen invalid';
    END IF;

    INSERT INTO public.finance_journals(
        id,company_id,journal_no,journal_type,accounting_period_id,
        accounting_date,source_type,source_id,idempotency_key,
        description,created_by
    ) VALUES (
        v_journal,'00000000-0000-0000-0000-000000094001',
        'G94-JRN-001','MANUAL',v_period,'2032-01-15',
        'G6_PHASE2_TEST','00000000-0000-0000-0000-000000094051',
        'G94-JOURNAL-IDEMPOTENCY','G6 Phase 2 balanced journal',v_actor
    );

    INSERT INTO public.finance_journal_lines(
        company_id,journal_id,line_no,account_id,
        account_code_snapshot,account_name_snapshot,normal_balance_snapshot,
        debit,credit
    ) VALUES
        ('00000000-0000-0000-0000-000000094001',v_journal,1,
         '00000000-0000-0000-0000-000000094011','placeholder',
         'placeholder','DEBIT',100,0),
        ('00000000-0000-0000-0000-000000094001',v_journal,2,
         '00000000-0000-0000-0000-000000094012','placeholder',
         'placeholder','CREDIT',0,90);

    v_rejected := FALSE;
    BEGIN
        UPDATE public.finance_journals SET
            status = 'POSTED',posted_by = v_actor
        WHERE id = v_journal;
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'JOURNAL_UNBALANCED' THEN v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: unbalanced journal posted';
    END IF;

    UPDATE public.finance_journal_lines SET credit = 100
    WHERE company_id = '00000000-0000-0000-0000-000000094001'
      AND journal_id = v_journal AND line_no = 2;

    v_rejected := FALSE;
    BEGIN
        INSERT INTO public.finance_journal_lines(
            company_id,journal_id,line_no,account_id,
            account_code_snapshot,account_name_snapshot,
            normal_balance_snapshot,debit,credit
        ) VALUES (
            '00000000-0000-0000-0000-000000094001',v_journal,3,
            '00000000-0000-0000-0000-000000094013',
            'placeholder','placeholder','DEBIT',1,0
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'ACTIVE_POSTABLE_ACCOUNT_REQUIRED' THEN
            v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: cross-Company account accepted';
    END IF;

    UPDATE public.finance_journals SET
        status = 'POSTED',posted_by = v_actor
    WHERE id = v_journal;

    SELECT count(*) INTO v_count FROM public.finance_journals
    WHERE id = v_journal AND status = 'POSTED'
      AND total_debit = 100 AND total_credit = 100
      AND master_version = 2;
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: balanced posted journal invalid';
    END IF;

    v_rejected := FALSE;
    BEGIN
        UPDATE public.finance_journal_lines SET description = 'mutated'
        WHERE company_id = '00000000-0000-0000-0000-000000094001'
          AND journal_id = v_journal AND line_no = 1;
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'POSTED_JOURNAL_IMMUTABLE' THEN v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: posted journal line mutated';
    END IF;

    SELECT count(*) INTO v_count FROM public.finance_journal_audit
    WHERE company_id = '00000000-0000-0000-0000-000000094001'
      AND (
          (entity_type = 'ACCOUNTING_PERIOD' AND entity_id = v_period)
          OR (entity_type = 'JOURNAL' AND entity_id = v_journal)
      );
    IF v_count <> 4 THEN
        RAISE EXCEPTION 'TEST_FAILED: expected 4 audit rows, got %',v_count;
    END IF;

    IF has_table_privilege(
        'authenticated','public.finance_journals','INSERT,UPDATE,DELETE'
    ) OR has_table_privilege(
        'authenticated','public.finance_journal_lines','INSERT,UPDATE,DELETE'
    ) OR NOT has_function_privilege(
        'authenticated','public.create_accounting_period(integer,integer)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: Finance privilege boundary invalid';
    END IF;

    RAISE NOTICE
        'TEST PASSED: period lifecycle and additive canonical journal are tenant-safe, balanced, versioned, audited, and immutable.';
END
$test$;

ROLLBACK;
