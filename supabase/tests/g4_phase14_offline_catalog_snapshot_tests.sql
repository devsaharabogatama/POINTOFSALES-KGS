-- G4 phase 14 behavior: guarded snapshot on an existing open Session.
-- SAFETY: feature/policy fixtures and all audit effects are rolled back.

BEGIN;

DO $test$
DECLARE
    v_actor UUID;
    v_company UUID;
    v_session UUID;
    v_store UUID;
    v_terminal UUID;
    v_result JSONB;
BEGIN
    SELECT
        cs.cashier_id,cs.company_id,cs.id,cs.store_id,cs.pos_id
    INTO v_actor,v_company,v_session,v_store,v_terminal
    FROM public.cashier_sessions cs
    JOIN auth.users au ON au.id = cs.cashier_id
    WHERE cs.status = 'OPEN'::public.session_status
    ORDER BY cs.opened_at DESC
    LIMIT 1;
    IF v_session IS NULL THEN
        RAISE EXCEPTION
            'TEST_PRECONDITION_FAILED: one linked open Session required';
    END IF;

    INSERT INTO public.company_features(
        company_id,feature_code,is_enabled,config
    ) VALUES (
        v_company,'offline_pos_enabled',TRUE,'{}'::JSONB
    )
    ON CONFLICT (company_id,feature_code)
    DO UPDATE SET is_enabled = TRUE;

    IF NOT EXISTS (
        SELECT 1 FROM public.company_features cf
        WHERE cf.company_id = v_company
          AND cf.feature_code = 'offline_pos_enabled'
          AND cf.is_enabled
    ) THEN
        RAISE EXCEPTION
            'TEST_PRECONDITION_FAILED: rollback-safe Offline feature fixture failed';
    END IF;

    INSERT INTO public.pos_offline_allowance_policies(
        company_id,scope_type,store_id,terminal_id,is_enabled
    ) VALUES (
        v_company,'TERMINAL',v_store,v_terminal,TRUE
    )
    ON CONFLICT (company_id,terminal_id)
        WHERE scope_type = 'TERMINAL'
    DO UPDATE SET is_enabled = TRUE;

    PERFORM set_config(
        'request.jwt.claims',
        jsonb_build_object('sub',v_actor,'role','authenticated')::TEXT,
        TRUE
    );
    PERFORM public.set_active_company_context(
        v_company,'G4_PHASE14_TEST'
    );

    v_result := public.get_pos_offline_catalog_snapshot(v_session);
    IF (v_result->>'companyId')::UUID <> v_company
       OR (v_result->>'cashierSessionId')::UUID <> v_session
       OR (v_result->>'catalogVersion')::BIGINT <= 0
       OR jsonb_typeof(v_result->'productUoms') <> 'array'
       OR jsonb_array_length(v_result->'productUoms') = 0
       OR jsonb_typeof(v_result->'customers') <> 'array'
       OR jsonb_array_length(v_result->'customers') = 0
       OR jsonb_typeof(v_result->'paymentMethods') <> 'array'
       OR jsonb_array_length(v_result->'paymentMethods') = 0
       OR jsonb_typeof(v_result->'pricelists') <> 'array'
       OR jsonb_typeof(v_result->'pricelistRules') <> 'array'
       OR jsonb_typeof(v_result->'allowances') <> 'array' THEN
        RAISE EXCEPTION 'TEST_FAILED: Offline snapshot shape invalid';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM jsonb_array_elements(v_result->'productUoms') row(value)
        WHERE row.value->'tax' IS NULL
           OR row.value->>'productUomId' IS NULL
           OR row.value->>'baseUnitPrice' IS NULL
           OR row.value->>'factorToBase' IS NULL
    ) THEN
        RAISE EXCEPTION
            'TEST_FAILED: Product price/Tax snapshot incomplete';
    END IF;
    IF has_function_privilege(
        'anon','public.get_pos_offline_catalog_snapshot(uuid)','EXECUTE'
    ) OR NOT has_function_privilege(
        'authenticated',
        'public.get_pos_offline_catalog_snapshot(uuid)','EXECUTE'
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: snapshot RPC privilege invalid';
    END IF;

    RAISE NOTICE
        'TEST PASSED: Offline catalog snapshot is Session-scoped, authoritative, and browser-guarded.';
END
$test$;

ROLLBACK;
