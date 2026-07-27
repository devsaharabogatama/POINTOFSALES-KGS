-- G2 phase 30 behavioral test: idempotent guarded import staging.
-- SAFETY: every Company, job, row, and event fixture rolls back.

BEGIN;

DO $test$
DECLARE
    v_actor UUID;
    v_company_a UUID := '00000000-0000-0000-0000-000000030001';
    v_company_b UUID := '00000000-0000-0000-0000-000000030002';
    v_request UUID := '00000000-0000-0000-0000-000000030011';
    v_job UUID;
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
        (v_company_a,'G30A','G30 Company A','g30-company-a','ACTIVE'),
        (v_company_b,'G30B','G30 Company B','g30-company-b','ACTIVE');

    PERFORM set_config(
        'request.jwt.claims',
        jsonb_build_object('sub',v_actor,'role','authenticated')::TEXT,TRUE
    );
    PERFORM public.set_active_company_context(v_company_a,'G2_PHASE30_TEST');

    v_result := public.create_master_import_job(
        v_request,'UOM','REFERENCE_BY_NAME','CREATE_AND_UPDATE',
        'uom.csv',repeat('a',64),','
    );
    v_job := (v_result->>'jobId')::UUID;
    IF v_result->>'action' <> 'CREATE'
       OR (v_result->>'masterVersion')::BIGINT <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: import job create result invalid';
    END IF;

    v_result := public.create_master_import_job(
        v_request,'UOM','REFERENCE_BY_NAME','CREATE_AND_UPDATE',
        'uom.csv',repeat('a',64),','
    );
    IF v_result->>'action' <> 'EXISTING'
       OR (v_result->>'jobId')::UUID <> v_job THEN
        RAISE EXCEPTION 'TEST_FAILED: import job retry was not idempotent';
    END IF;

    v_rejected := FALSE;
    BEGIN
        PERFORM public.create_master_import_job(
            v_request,'SUPPLIER','REFERENCE_BY_NAME','CREATE_AND_UPDATE',
            'supplier.csv',repeat('b',64),','
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'IMPORT_IDEMPOTENCY_CONFLICT' THEN v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: changed idempotent request accepted';
    END IF;

    v_result := public.stage_master_import_rows(
        v_job,1,
        '{"code":"kode","name":"nama"}'::JSONB,
        '[
            {"rowNumber":2,"sourceData":{"kode":"PCS","nama":"Piece"}},
            {"rowNumber":3,"sourceData":{"kode":"BOX","nama":"Box"}}
        ]'::JSONB
    );
    IF (v_result->>'masterVersion')::BIGINT <> 2
       OR (v_result->>'rowCount')::INTEGER <> 2 THEN
        RAISE EXCEPTION 'TEST_FAILED: staged import result invalid';
    END IF;

    -- Lost-response retry with the old version and identical payload is safe.
    v_result := public.stage_master_import_rows(
        v_job,1,
        '{"code":"kode","name":"nama"}'::JSONB,
        '[
            {"rowNumber":2,"sourceData":{"kode":"PCS","nama":"Piece"}},
            {"rowNumber":3,"sourceData":{"kode":"BOX","nama":"Box"}}
        ]'::JSONB
    );
    IF v_result->>'action' <> 'EXISTING'
       OR (v_result->>'masterVersion')::BIGINT <> 2 THEN
        RAISE EXCEPTION 'TEST_FAILED: staging retry was not idempotent';
    END IF;

    v_rejected := FALSE;
    BEGIN
        PERFORM public.stage_master_import_rows(
            v_job,2,'{}'::JSONB,
            '[
                {"rowNumber":4,"sourceData":{"code":"A"}},
                {"rowNumber":4,"sourceData":{"code":"B"}}
            ]'::JSONB
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'DUPLICATE_IMPORT_ROW_NUMBER' THEN v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: duplicate staged row accepted';
    END IF;
    SELECT count(*) INTO v_count FROM public.master_import_rows
    WHERE company_id = v_company_a AND job_id = v_job;
    IF v_count <> 2 THEN
        RAISE EXCEPTION 'TEST_FAILED: rejected staging replaced valid rows';
    END IF;

    v_rejected := FALSE;
    BEGIN
        PERFORM public.stage_master_import_rows(
            v_job,1,'{}'::JSONB,
            '[{"rowNumber":9,"sourceData":{"code":"STALE"}}]'::JSONB
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'MASTER_VERSION_CONFLICT' THEN v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: stale different staging accepted';
    END IF;

    SELECT count(*) INTO v_count FROM public.master_import_job_events
    WHERE company_id = v_company_a AND job_id = v_job;
    IF v_count <> 2 THEN
        RAISE EXCEPTION 'TEST_FAILED: expected CREATE and STAGE events';
    END IF;

    PERFORM public.set_active_company_context(v_company_b,'G2_PHASE30_TEST');
    v_rejected := FALSE;
    BEGIN
        PERFORM public.stage_master_import_rows(
            v_job,2,'{}'::JSONB,
            '[{"rowNumber":2,"sourceData":{"code":"CROSS"}}]'::JSONB
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'IMPORT_JOB_NOT_FOUND' THEN v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: cross-Company job staged';
    END IF;

    IF has_table_privilege(
        'authenticated','public.master_import_jobs','INSERT,UPDATE,DELETE'
    ) OR has_table_privilege(
        'authenticated','public.master_import_rows','INSERT,UPDATE,DELETE'
    ) OR NOT has_function_privilege(
        'authenticated',
        'public.create_master_import_job(uuid,text,text,text,text,text,text)',
        'EXECUTE'
    ) OR has_function_privilege(
        'service_role',
        'public.import_products_for_company(uuid,jsonb)','EXECUTE'
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: import privilege boundary invalid';
    END IF;

    RAISE NOTICE 'TEST PASSED: non-stock import staging is tenant-safe, idempotent, versioned, audited, and legacy Product+stock import is quarantined.';
END
$test$;

ROLLBACK;
