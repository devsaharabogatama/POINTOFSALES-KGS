-- G6 corrective phase 7A behavior: append-only Finance journal reversal.
-- SAFETY: all fixtures, journals, lines, and audit rows roll back.

BEGIN;

DO $test$
DECLARE
    v_actor UUID;
    v_company CONSTANT UUID := '00000000-0000-0000-0000-000000024001';
    v_company_b CONSTANT UUID := '00000000-0000-0000-0000-000000024002';
    v_account_debit CONSTANT UUID := '00000000-0000-0000-0000-000000024011';
    v_account_credit CONSTANT UUID := '00000000-0000-0000-0000-000000024012';
    v_period UUID;
    v_original CONSTANT UUID := '00000000-0000-0000-0000-000000024021';
    v_non_source CONSTANT UUID := '00000000-0000-0000-0000-000000024022';
    v_result JSONB;
    v_reversal UUID;
    v_original_version BIGINT;
    v_count BIGINT;
    v_rejected BOOLEAN;
BEGIN
    SELECT profile.id INTO v_actor
    FROM public.profiles profile
    JOIN auth.users auth_user ON auth_user.id = profile.id
    WHERE profile.role::text = 'super_admin'
    ORDER BY profile.id LIMIT 1;
    IF v_actor IS NULL THEN
        RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: linked Super Admin required';
    END IF;

    INSERT INTO public.companies(
        id,company_code,company_name,company_slug,status
    ) VALUES
        (v_company,'G6R-A','G6 Reversal A','g6-reversal-a','ACTIVE'),
        (v_company_b,'G6R-B','G6 Reversal B','g6-reversal-b','ACTIVE');

    INSERT INTO public.chart_of_accounts(
        id,company_id,account_code,account_name,account_type,normal_balance,
        is_system_account,is_postable,allow_manual_posting,
        allow_reconciliation,is_active,created_by,updated_by
    ) VALUES
        (v_account_debit,v_company,'G6R-1110','G6R Debit','ASSET','DEBIT',
         FALSE,TRUE,TRUE,FALSE,TRUE,v_actor,v_actor),
        (v_account_credit,v_company,'G6R-3110','G6R Credit','EQUITY','CREDIT',
         FALSE,TRUE,TRUE,FALSE,TRUE,v_actor,v_actor);

    PERFORM set_config(
        'request.jwt.claims',
        jsonb_build_object('sub',v_actor,'role','authenticated')::text,TRUE
    );
    PERFORM public.set_active_company_context(v_company,'G6_PHASE7A_TEST');
    v_result := public.create_accounting_period(2042,1);
    v_period := (v_result->>'accountingPeriodId')::UUID;

    INSERT INTO public.finance_journals(
        id,company_id,journal_no,journal_type,accounting_period_id,
        accounting_date,source_type,source_id,idempotency_key,
        description,created_by
    ) VALUES (
        v_original,v_company,'G6R-JRN-001','MANUAL',v_period,'2042-01-10',
        'G6_PHASE7A_TEST','00000000-0000-0000-0000-000000024031',
        'G6R-ORIGINAL','G6 reversal original',v_actor
    );
    INSERT INTO public.finance_journal_lines(
        company_id,journal_id,line_no,account_id,debit,credit,description
    ) VALUES
        (v_company,v_original,1,v_account_debit,100,0,'Original debit'),
        (v_company,v_original,2,v_account_credit,0,100,'Original credit');
    UPDATE public.finance_journals SET status='POSTED',posted_by=v_actor
    WHERE company_id=v_company AND id=v_original;
    SELECT master_version INTO v_original_version
    FROM public.finance_journals
    WHERE company_id=v_company AND id=v_original;

    v_rejected := FALSE;
    BEGIN
        PERFORM public.reverse_finance_journal(
            v_original,v_original_version,'2042-01-11',NULL,
            '00000000-0000-0000-0000-000000024041'
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM='REVERSAL_REASON_REQUIRED' THEN v_rejected:=TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: reasonless reversal accepted';
    END IF;

    v_result := public.reverse_finance_journal(
        v_original,v_original_version,'2042-01-11','Correction test',
        '00000000-0000-0000-0000-000000024041'
    );
    v_reversal := (v_result->>'journalId')::UUID;
    IF v_result->>'status'<>'POSTED'
       OR (v_result->>'idempotentReplay')::BOOLEAN THEN
        RAISE EXCEPTION 'TEST_FAILED: reversal result invalid: %',v_result;
    END IF;

    SELECT count(*) INTO v_count
    FROM public.finance_journals reversal
    WHERE reversal.company_id=v_company AND reversal.id=v_reversal
      AND reversal.journal_type='REVERSAL'
      AND reversal.reversal_of_journal_id=v_original
      AND reversal.total_debit=100 AND reversal.total_credit=100
      AND reversal.status='POSTED';
    IF v_count<>1 THEN
        RAISE EXCEPTION 'TEST_FAILED: reversal header invalid';
    END IF;
    SELECT count(*) INTO v_count
    FROM public.finance_journal_lines line
    WHERE line.company_id=v_company AND line.journal_id=v_reversal
      AND (
          (line.line_no=1 AND line.debit=0 AND line.credit=100)
          OR (line.line_no=2 AND line.debit=100 AND line.credit=0)
      );
    IF v_count<>2 THEN
        RAISE EXCEPTION 'TEST_FAILED: reversal lines did not swap debit/credit';
    END IF;
    SELECT count(*) INTO v_count
    FROM public.finance_journal_audit audit
    WHERE audit.company_id=v_company
      AND (
          (audit.entity_id=v_original AND audit.action='REVERSE')
          OR (audit.entity_id=v_reversal AND audit.action='POST')
      );
    IF v_count<>2 THEN
        RAISE EXCEPTION 'TEST_FAILED: reversal audit incomplete';
    END IF;

    v_result := public.reverse_finance_journal(
        v_original,v_original_version,'2042-01-11','Correction test',
        '00000000-0000-0000-0000-000000024041'
    );
    IF (v_result->>'journalId')::UUID<>v_reversal
       OR NOT (v_result->>'idempotentReplay')::BOOLEAN THEN
        RAISE EXCEPTION 'TEST_FAILED: exact reversal retry duplicated effect';
    END IF;

    v_rejected := FALSE;
    BEGIN
        PERFORM public.reverse_finance_journal(
            v_original,v_original_version,'2042-01-11','Duplicate attempt',
            '00000000-0000-0000-0000-000000024042'
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM='JOURNAL_ALREADY_REVERSED' THEN v_rejected:=TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: second reversal accepted';
    END IF;

    INSERT INTO public.finance_journals(
        id,company_id,journal_no,journal_type,accounting_period_id,
        accounting_date,source_type,source_id,idempotency_key,
        description,created_by
    ) VALUES (
        v_non_source,v_company,'G6R-JRN-002','PRIOR_PERIOD_ADJUSTMENT',
        v_period,'2042-01-12','G6_PHASE7A_TEST',
        '00000000-0000-0000-0000-000000024032','G6R-NONSOURCE',
        'Source-controlled fixture',v_actor
    );
    INSERT INTO public.finance_journal_lines(
        company_id,journal_id,line_no,account_id,debit,credit
    ) VALUES
        (v_company,v_non_source,1,v_account_debit,50,0),
        (v_company,v_non_source,2,v_account_credit,0,50);
    UPDATE public.finance_journals SET status='POSTED',posted_by=v_actor
    WHERE company_id=v_company AND id=v_non_source;
    v_rejected := FALSE;
    BEGIN
        PERFORM public.reverse_finance_journal(
            v_non_source,2,'2042-01-13','Must use source',
            '00000000-0000-0000-0000-000000024043'
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM='SOURCE_DOCUMENT_REVERSAL_REQUIRED' THEN v_rejected:=TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: source-controlled journal reversed directly';
    END IF;

    PERFORM public.set_active_company_context(v_company_b,'G6_PHASE7A_CROSS');
    v_rejected := FALSE;
    BEGIN
        PERFORM public.reverse_finance_journal(
            v_original,v_original_version,'2042-01-11','Cross tenant',
            '00000000-0000-0000-0000-000000024044'
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM='FINANCE_JOURNAL_NOT_FOUND' THEN v_rejected:=TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: cross-Company reversal accepted';
    END IF;

    IF has_table_privilege(
        'authenticated','public.finance_journals','INSERT,UPDATE,DELETE'
    ) OR has_function_privilege(
        'anon','public.reverse_finance_journal(uuid,bigint,date,text,uuid)',
        'EXECUTE'
    ) OR NOT has_function_privilege(
        'authenticated',
        'public.reverse_finance_journal(uuid,bigint,date,text,uuid)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: reversal privilege boundary invalid';
    END IF;

    RAISE NOTICE
        'TEST PASSED: Finance reversal is append-only, balanced, exact-idempotent, period-aware, source-controlled, audited, and tenant-safe.';
END
$test$;

ROLLBACK;
