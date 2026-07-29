-- G2 phase 14 behavioral test: Payment Method guarded master writes.
-- SAFETY: every fixture, Payment Method, assignment, audit, and payment rolls back.

BEGIN;

DO $test$
DECLARE
    v_actor UUID;
    v_cash UUID;
    v_qris UUID;
    v_result JSONB;
    v_count BIGINT;
    v_rejected BOOLEAN;
BEGIN
    SELECT p.id INTO v_actor
    FROM public.profiles p
    JOIN auth.users u ON u.id = p.id
    WHERE p.role = 'super_admin'::user_role
    ORDER BY p.id LIMIT 1;
    IF v_actor IS NULL THEN
        RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: linked Super Admin required';
    END IF;

    INSERT INTO public.companies(
        id,company_code,company_name,company_slug,status
    ) VALUES
        ('00000000-0000-0000-0000-000000014001',
         'G14A','G14 Company A','g14-company-a','ACTIVE'),
        ('00000000-0000-0000-0000-000000014002',
         'G14B','G14 Company B','g14-company-b','ACTIVE');
    INSERT INTO public.stores(id,company_id,store_code,store_name,status) VALUES
        ('00000000-0000-0000-0000-000000014011',
         '00000000-0000-0000-0000-000000014001','A1','G14 Store A','ACTIVE'),
        ('00000000-0000-0000-0000-000000014012',
         '00000000-0000-0000-0000-000000014002','B1','G14 Store B','ACTIVE');
    INSERT INTO public.pos_terminals(
        id,company_id,store_id,pos_code,pos_name,status
    ) VALUES (
        '00000000-0000-0000-0000-000000014021',
        '00000000-0000-0000-0000-000000014001',
        '00000000-0000-0000-0000-000000014011','PA','G14 POS A','ACTIVE'
    );

    SELECT id INTO v_cash FROM public.payment_methods
    WHERE company_id = '00000000-0000-0000-0000-000000014001'
      AND payment_method_code = 'CASH'
      AND is_default AND is_active;
    IF v_cash IS NULL THEN
        RAISE EXCEPTION 'TEST_FAILED: default Cash was not provisioned';
    END IF;

    PERFORM set_config(
        'request.jwt.claims',
        jsonb_build_object('sub',v_actor,'role','authenticated')::TEXT,TRUE
    );
    PERFORM public.set_active_company_context(
        '00000000-0000-0000-0000-000000014001','G2_PHASE14_TEST'
    );

    v_result := public.save_payment_method(
        NULL,NULL,'QRIS-STORE','QRIS Store','QRIS','CLEARING',TRUE,FALSE,
        ARRAY['00000000-0000-0000-0000-000000014011'::UUID],
        'REQUIRED',TRUE,'CUSTOMER','PERCENT',0.7,NULL,
        'PAYMENT_CLEARING',NULL,clock_timestamp(),NULL,TRUE
    );
    v_qris := (v_result->>'paymentMethodId')::UUID;

    SELECT count(*) INTO v_count FROM public.payment_methods pm
    WHERE pm.company_id = '00000000-0000-0000-0000-000000014001'
      AND pm.id = v_qris
      AND pm.is_default
      AND pm.fee_enabled
      AND pm.fee_bearer = 'CUSTOMER'
      AND pm.fee_type = 'PERCENT'
      AND pm.fee_percent = 0.7;
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: QRIS master configuration invalid';
    END IF;
    SELECT count(*) INTO v_count
    FROM public.payment_method_store_assignments
    WHERE company_id = '00000000-0000-0000-0000-000000014001'
      AND payment_method_id = v_qris
      AND store_id = '00000000-0000-0000-0000-000000014011';
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: Store assignment missing';
    END IF;
    IF EXISTS (
        SELECT 1 FROM public.payment_methods
        WHERE id = v_cash AND is_default
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: old default Cash remained default';
    END IF;

    v_result := public.save_payment_method(
        v_qris,1,'QRIS-STORE','QRIS Store Updated','QRIS','CLEARING',TRUE,FALSE,
        ARRAY['00000000-0000-0000-0000-000000014011'::UUID],
        'REQUIRED',TRUE,'COMPANY','PERCENT_PLUS_FIXED',0.5,100,
        'PAYMENT_CLEARING',NULL,clock_timestamp(),NULL,TRUE
    );
    IF (v_result->>'masterVersion')::BIGINT <> 2 THEN
        RAISE EXCEPTION 'TEST_FAILED: master version did not increment';
    END IF;

    v_rejected := FALSE;
    BEGIN
        PERFORM public.save_payment_method(
            v_qris,1,'QRIS-STORE','Stale QRIS','QRIS','CLEARING',TRUE,FALSE,
            ARRAY['00000000-0000-0000-0000-000000014011'::UUID],
            'REQUIRED',FALSE,NULL,NULL,NULL,NULL,
            'PAYMENT_CLEARING',NULL,clock_timestamp(),NULL,TRUE
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'MASTER_VERSION_CONFLICT' THEN v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: stale Payment Method update accepted';
    END IF;

    v_rejected := FALSE;
    BEGIN
        PERFORM public.save_payment_method(
            NULL,NULL,'CROSS','Cross Store','TRANSFER','DIRECT_BANK',
            FALSE,FALSE,
            ARRAY['00000000-0000-0000-0000-000000014012'::UUID],
            'OPTIONAL',FALSE,NULL,NULL,NULL,NULL,NULL,'BANK_RECEIPT',
            clock_timestamp(),NULL,TRUE
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'ACTIVE_STORE_NOT_FOUND' THEN v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: cross-Company Store accepted';
    END IF;
    IF EXISTS (
        SELECT 1 FROM public.payment_methods
        WHERE company_id = '00000000-0000-0000-0000-000000014001'
          AND payment_method_code = 'CROSS'
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: rejected master partially persisted';
    END IF;

    v_rejected := FALSE;
    BEGIN
        PERFORM public.save_payment_method(
            NULL,NULL,'BAL','Balance Bypass','CUSTOMER_BALANCE',
            'INTERNAL_LIABILITY',FALSE,TRUE,ARRAY[]::UUID[],
            'OPTIONAL',FALSE,NULL,NULL,NULL,NULL,NULL,NULL,
            clock_timestamp(),NULL,TRUE
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'INTERNAL_PAYMENT_METHOD_REQUIRES_MODULE_WORKFLOW' THEN
            v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: internal tender bypass accepted';
    END IF;

    v_rejected := FALSE;
    BEGIN
        PERFORM public.save_payment_method(
            NULL,NULL,'BAD-FEE','Bad Fee','QRIS','CLEARING',FALSE,TRUE,
            ARRAY[]::UUID[],'OPTIONAL',TRUE,'CUSTOMER','PERCENT',101,NULL,
            'PAYMENT_CLEARING',NULL,clock_timestamp(),NULL,TRUE
        );
    EXCEPTION WHEN check_violation THEN
        v_rejected := TRUE;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: invalid fee configuration accepted';
    END IF;

    v_rejected := FALSE;
    BEGIN
        UPDATE public.payment_methods
        SET is_default = FALSE
        WHERE company_id = '00000000-0000-0000-0000-000000014001'
          AND id = v_qris;
        SET CONSTRAINTS g2_require_default_payment_method IMMEDIATE;
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM =
            'ACTIVE_COMPANY_REQUIRES_ONE_DEFAULT_PAYMENT_METHOD' THEN
            v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: last active default was removed';
    END IF;

    INSERT INTO public.cashier_sessions(
        id,session_code,cashier_id,company_id,store_id,pos_id,status
    ) VALUES (
        '00000000-0000-0000-0000-000000014031','G14-SA',v_actor,
        '00000000-0000-0000-0000-000000014001',
        '00000000-0000-0000-0000-000000014011',
        '00000000-0000-0000-0000-000000014021',
        'CLOSED'::session_status
    );
    INSERT INTO public.sales_headers(
        id,invoice_no,session_id,company_id,store_id,pos_id,created_by
    ) VALUES (
        '00000000-0000-0000-0000-000000014041','G14-INV-A',
        '00000000-0000-0000-0000-000000014031',
        '00000000-0000-0000-0000-000000014001',
        '00000000-0000-0000-0000-000000014011',
        '00000000-0000-0000-0000-000000014021',v_actor
    );
    INSERT INTO public.sales_payments(
        company_id,sales_id,session_id,payment_no,payment_method,amount,
        payment_method_id,payment_method_code_snapshot,
        payment_method_name_snapshot,payment_method_type_snapshot,
        settlement_route_snapshot
    ) VALUES (
        '00000000-0000-0000-0000-000000014001',
        '00000000-0000-0000-0000-000000014041',
        '00000000-0000-0000-0000-000000014031','G14-PAY-A',
        'QRIS'::payment_method,1000,v_qris,'QRIS-STORE',
        'QRIS Store Updated','QRIS','CLEARING'
    );

    v_rejected := FALSE;
    BEGIN
        PERFORM public.save_payment_method(
            v_qris,2,'QRIS-RENAMED','Forbidden Code Change','QRIS','CLEARING',
            TRUE,FALSE,
            ARRAY['00000000-0000-0000-0000-000000014011'::UUID],
            'REQUIRED',TRUE,'COMPANY','PERCENT_PLUS_FIXED',0.5,100,
            'PAYMENT_CLEARING',NULL,clock_timestamp(),NULL,TRUE
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'PAYMENT_METHOD_CODE_LOCKED_BY_HISTORY' THEN
            v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: historical Payment Method code changed';
    END IF;

    SELECT count(*) INTO v_count
    FROM public.payment_method_master_audit
    WHERE payment_method_id = v_qris;
    IF v_count <> 2 THEN
        RAISE EXCEPTION 'TEST_FAILED: expected two QRIS audit rows, got %',v_count;
    END IF;

    IF has_table_privilege(
        'authenticated','public.payment_methods','INSERT,UPDATE,DELETE'
    ) OR has_table_privilege(
        'authenticated',
        'public.payment_method_store_assignments','INSERT,UPDATE,DELETE'
    ) OR NOT has_function_privilege(
        'authenticated',
        'public.save_payment_method(uuid,bigint,text,text,text,text,boolean,boolean,uuid[],text,boolean,text,text,numeric,numeric,text,text,timestamp with time zone,timestamp with time zone,boolean)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: Payment Method privilege boundary invalid';
    END IF;

    RAISE NOTICE 'TEST PASSED: Payment Method master is tenant-safe, Store-scoped, fee-valid, versioned, default-guarded, history-safe, and audited.';
END
$test$;

ROLLBACK;
