-- G2 phase 31 behavioral test: deterministic dry-run import validation.
-- SAFETY: every fixture, job, validation result, and event rolls back.

BEGIN;

DO $test$
DECLARE
    v_actor UUID;
    v_company_a UUID := '00000000-0000-0000-0000-000000031001';
    v_company_b UUID := '00000000-0000-0000-0000-000000031002';
    v_piece UUID := '00000000-0000-0000-0000-000000031011';
    v_kilogram UUID := '00000000-0000-0000-0000-000000031012';
    v_foreign_uom UUID := '00000000-0000-0000-0000-000000031013';
    v_job UUID;
    v_duplicate_job UUID;
    v_id_job UUID;
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
        (v_company_a,'G31A','G31 Company A','g31-company-a','ACTIVE'),
        (v_company_b,'G31B','G31 Company B','g31-company-b','ACTIVE');

    INSERT INTO public.uoms(id,company_id,code,name,is_active) VALUES
        (v_piece,v_company_a,'PCS','Piece',TRUE),
        (v_kilogram,v_company_a,'KG','Kilogram',TRUE),
        (v_foreign_uom,v_company_b,'BOX','Foreign Box',TRUE);

    PERFORM set_config(
        'request.jwt.claims',
        jsonb_build_object('sub',v_actor,'role','authenticated')::TEXT,TRUE
    );
    PERFORM public.set_active_company_context(v_company_a,'G2_PHASE31_TEST');

    v_result := public.create_master_import_job(
        '00000000-0000-0000-0000-000000031101',
        'UOM','REFERENCE_BY_NAME','CREATE_AND_UPDATE',
        'uom-validation.csv',repeat('a',64),','
    );
    v_job := (v_result->>'jobId')::UUID;
    PERFORM public.stage_master_import_rows(
        v_job,1,
        '{"code":"kode","name":"nama","isActive":"aktif"}'::JSONB,
        '[
            {"rowNumber":2,"sourceData":{"kode":"PCE","nama":"piece","aktif":"ya"}},
            {"rowNumber":3,"sourceData":{"kode":"KG","nama":"Kilogram","aktif":"true"}},
            {"rowNumber":4,"sourceData":{"kode":"DUS","nama":"Dus","aktif":"aktif"}},
            {"rowNumber":5,"sourceData":{"kode":"","nama":"Invalid","aktif":"true"}}
        ]'::JSONB
    );
    v_result := public.validate_master_import_job(v_job,2);
    IF (v_result->>'masterVersion')::BIGINT <> 3
       OR (v_result->>'createCount')::INTEGER <> 1
       OR (v_result->>'updateCount')::INTEGER <> 1
       OR (v_result->>'skipCount')::INTEGER <> 1
       OR (v_result->>'errorCount')::INTEGER <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: dry-run operation summary invalid: %',v_result;
    END IF;

    SELECT count(*) INTO v_count
    FROM public.master_import_rows r
    WHERE r.job_id = v_job
      AND r.operation = 'UPDATE'
      AND r.matched_record_id = v_piece
      AND r.before_state->>'code' = 'PCS'
      AND r.after_state->>'code' = 'PCE'
      AND r.after_state->>'name' = 'Piece'
      AND r.warnings @> '[{"code":"UPDATE_EXISTING_CONFIRMATION_REQUIRED"}]';
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: update diff/warning or name preservation invalid';
    END IF;

    IF EXISTS (SELECT 1 FROM public.uoms WHERE company_id = v_company_a AND code = 'DUS')
       OR EXISTS (SELECT 1 FROM public.uoms WHERE id = v_piece AND code <> 'PCS') THEN
        RAISE EXCEPTION 'TEST_FAILED: dry-run mutated UOM master';
    END IF;

    -- Lost-response retry returns the already persisted preview.
    v_result := public.validate_master_import_job(v_job,2);
    IF v_result->>'action' <> 'EXISTING'
       OR (v_result->>'masterVersion')::BIGINT <> 3 THEN
        RAISE EXCEPTION 'TEST_FAILED: validation retry was not idempotent';
    END IF;

    -- Same code with different names and same name with different codes are
    -- both file-level identity collisions; all involved rows must be errors.
    v_result := public.create_master_import_job(
        '00000000-0000-0000-0000-000000031102',
        'UOM','REFERENCE_BY_NAME','CREATE_AND_UPDATE',
        'uom-duplicates.csv',repeat('b',64),','
    );
    v_duplicate_job := (v_result->>'jobId')::UUID;
    PERFORM public.stage_master_import_rows(
        v_duplicate_job,1,'{"code":"code","name":"name"}'::JSONB,
        '[
            {"rowNumber":2,"sourceData":{"code":"PACK","name":"Pack A"}},
            {"rowNumber":3,"sourceData":{"code":"PACK","name":"Pack B"}},
            {"rowNumber":4,"sourceData":{"code":"PA","name":"Shared Pack"}},
            {"rowNumber":5,"sourceData":{"code":"PB","name":"Shared Pack"}}
        ]'::JSONB
    );
    v_result := public.validate_master_import_job(v_duplicate_job,2);
    IF (v_result->>'errorCount')::INTEGER <> 4 THEN
        RAISE EXCEPTION 'TEST_FAILED: duplicate code/name rows not all rejected';
    END IF;
    SELECT count(*) INTO v_count FROM public.master_import_rows
    WHERE job_id = v_duplicate_job
      AND errors @> '[{"code":"DUPLICATE_CODE_OR_NAME_IN_FILE"}]';
    IF v_count <> 4 THEN
        RAISE EXCEPTION 'TEST_FAILED: duplicate-file error evidence missing';
    END IF;

    -- A syntactically valid ID from another Company is never a match.
    v_result := public.create_master_import_job(
        '00000000-0000-0000-0000-000000031103',
        'UOM','REFERENCE_BY_ID','UPDATE_ONLY',
        'uom-id.csv',repeat('c',64),','
    );
    v_id_job := (v_result->>'jobId')::UUID;
    PERFORM public.stage_master_import_rows(
        v_id_job,1,
        '{"internalId":"id","code":"code","name":"name"}'::JSONB,
        jsonb_build_array(jsonb_build_object(
            'rowNumber',2,
            'sourceData',jsonb_build_object(
                'id',v_foreign_uom,'code','BOX','name','Foreign Box'
            )
        ))
    );
    v_result := public.validate_master_import_job(v_id_job,2);
    IF (v_result->>'errorCount')::INTEGER <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: foreign ID was not rejected';
    END IF;
    SELECT count(*) INTO v_count FROM public.master_import_rows
    WHERE job_id = v_id_job
      AND errors @> '[{"code":"ID_NOT_FOUND_IN_ACTIVE_COMPANY"}]';
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: foreign ID error code invalid';
    END IF;

    PERFORM public.set_active_company_context(v_company_b,'G2_PHASE31_TEST');
    v_rejected := FALSE;
    BEGIN
        PERFORM public.validate_master_import_job(v_job,3);
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'IMPORT_JOB_NOT_FOUND' THEN v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: cross-Company validation accessed job';
    END IF;

    IF has_table_privilege(
        'authenticated','public.master_import_rows','INSERT,UPDATE,DELETE'
    ) OR NOT has_function_privilege(
        'authenticated','public.validate_master_import_job(uuid,bigint)','EXECUTE'
    ) OR has_function_privilege(
        'anon','public.validate_master_import_job(uuid,bigint)','EXECUTE'
    ) OR to_regprocedure('public.commit_master_import_job(uuid,bigint,integer)')
        IS NOT NULL THEN
        RAISE EXCEPTION 'TEST_FAILED: validation privilege/cutover boundary invalid';
    END IF;

    RAISE NOTICE 'TEST PASSED: dry-run import validation is tenant-safe, deterministic, idempotent, partial-error tolerant, duplicate-aware, and does not mutate master data.';
END
$test$;

ROLLBACK;
