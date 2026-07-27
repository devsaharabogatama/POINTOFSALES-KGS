-- G2 phase 38 behavioral test: code-less simple master CSV validation/commit.
-- SAFETY: every fixture, allocation, import job, event, and master rolls back.

BEGIN;

DO $test$
DECLARE
    v_actor UUID;
    v_company UUID := '00000000-0000-0000-0000-000000038001';
    v_job UUID;
    v_result JSONB;
    v_code TEXT;
    v_version BIGINT;
BEGIN
    SELECT p.id INTO v_actor
    FROM public.profiles p
    JOIN auth.users u ON u.id=p.id
    WHERE p.role='super_admin'::user_role
    ORDER BY p.id LIMIT 1;
    IF v_actor IS NULL THEN
        RAISE EXCEPTION
            'TEST_PRECONDITION_FAILED: linked Super Admin required';
    END IF;

    INSERT INTO public.companies(
        id,company_code,company_name,company_slug,status
    ) VALUES (
        v_company,'G38A','G38 Company A','g38-company-a','ACTIVE'
    );
    INSERT INTO public.uoms(
        company_id,code,name,uom_type,allow_decimal,decimal_precision,
        created_by,updated_by
    ) VALUES (
        v_company,'LEGACY-PCS','G38 Piece','UNIT',FALSE,0,v_actor,v_actor
    );

    PERFORM set_config(
        'request.jwt.claims',
        jsonb_build_object('sub',v_actor,'role','authenticated')::TEXT,TRUE
    );
    PERFORM public.set_active_company_context(
        v_company,'G2_PHASE38_TEST'
    );

    -- New template: no code column or mapping. Validation allocates a stable
    -- server code and commit persists exactly that previewed identity.
    v_result := public.create_master_import_job(
        '00000000-0000-0000-0000-000000038101',
        'PRODUCT_CATEGORY','REFERENCE_BY_NAME','CREATE_AND_UPDATE',
        'category-codeless.csv',repeat('a',64),','
    );
    v_job := (v_result->>'jobId')::UUID;
    PERFORM public.stage_master_import_rows(
        v_job,1,'{"name":"name","isActive":"active"}'::JSONB,
        '[{"rowNumber":2,"sourceData":{"name":"G38 Food","active":"true"}}]'::JSONB
    );
    v_result := public.validate_master_import_job(v_job,2);
    v_version := (v_result->>'masterVersion')::BIGINT;
    IF v_version<>4 OR (v_result->>'createCount')::INTEGER<>1 THEN
        RAISE EXCEPTION
            'TEST_FAILED: code-less preview lifecycle invalid: %',v_result;
    END IF;
    v_result := public.validate_master_import_job(v_job,2);
    IF v_result->>'action'<>'EXISTING'
       OR (v_result->>'masterVersion')::BIGINT<>4 THEN
        RAISE EXCEPTION
            'TEST_FAILED: code-less validation retry not idempotent: %',
            v_result;
    END IF;
    SELECT after_state->>'code' INTO v_code
    FROM public.master_import_rows
    WHERE job_id=v_job AND row_number=2;
    IF v_code!~'^CAT-[0-9]{6}$' THEN
        RAISE EXCEPTION
            'TEST_FAILED: preview code was not server-generated: %',v_code;
    END IF;
    PERFORM public.commit_master_import_job(v_job,v_version,0);
    IF NOT EXISTS (
        SELECT 1 FROM public.product_categories
        WHERE company_id=v_company
          AND category_name='G38 Food'
          AND category_code=v_code
    ) THEN
        RAISE EXCEPTION
            'TEST_FAILED: committed Category identity differs from preview';
    END IF;

    -- Updating by name without a code reuses the immutable legacy identity.
    v_result := public.create_master_import_job(
        '00000000-0000-0000-0000-000000038102',
        'UOM','REFERENCE_BY_NAME','CREATE_AND_UPDATE',
        'uom-codeless.csv',repeat('b',64),','
    );
    v_job := (v_result->>'jobId')::UUID;
    PERFORM public.stage_master_import_rows(
        v_job,1,
        '{"name":"name","uomType":"type","allowDecimal":"decimal","decimalPrecision":"precision"}'::JSONB,
        '[{"rowNumber":2,"sourceData":{"name":"G38 Piece","type":"UNIT","decimal":"true","precision":"2"}}]'::JSONB
    );
    v_result := public.validate_master_import_job(v_job,2);
    v_version := (v_result->>'masterVersion')::BIGINT;
    IF (v_result->>'updateCount')::INTEGER<>1 THEN
        RAISE EXCEPTION
            'TEST_FAILED: code-less existing UOM was not matched';
    END IF;
    SELECT after_state->>'code' INTO v_code
    FROM public.master_import_rows
    WHERE job_id=v_job AND row_number=2;
    IF v_code<>'LEGACY-PCS' THEN
        RAISE EXCEPTION
            'TEST_FAILED: existing immutable code not reused: %',v_code;
    END IF;
    PERFORM public.commit_master_import_job(v_job,v_version,1);
    IF NOT EXISTS (
        SELECT 1 FROM public.uoms
        WHERE company_id=v_company AND code='LEGACY-PCS'
          AND name='G38 Piece' AND allow_decimal
          AND decimal_precision=2
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: code-less UOM update invalid';
    END IF;

    -- Generated Warehouse prefixes are accepted alongside legacy letter codes.
    v_result := public.create_master_import_job(
        '00000000-0000-0000-0000-000000038104',
        'WAREHOUSE','REFERENCE_BY_NAME','CREATE_AND_UPDATE',
        'warehouse-codeless.csv',repeat('d',64),','
    );
    v_job := (v_result->>'jobId')::UUID;
    PERFORM public.stage_master_import_rows(
        v_job,1,'{"name":"name","warehouseType":"type"}'::JSONB,
        '[{"rowNumber":2,"sourceData":{"name":"G38 Central","type":"CENTRAL"}}]'::JSONB
    );
    v_result := public.validate_master_import_job(v_job,2);
    v_version := (v_result->>'masterVersion')::BIGINT;
    IF (v_result->>'createCount')::INTEGER<>1
       OR (v_result->>'errorCount')::INTEGER<>0 THEN
        RAISE EXCEPTION
            'TEST_FAILED: generated Warehouse code rejected: %',v_result;
    END IF;
    PERFORM public.commit_master_import_job(v_job,v_version,0);
    IF NOT EXISTS (
        SELECT 1 FROM public.warehouses
        WHERE company_id=v_company AND name='G38 Central'
          AND code~'^WH-[0-9]{6}$'
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: code-less Warehouse commit invalid';
    END IF;

    -- Applied/old templates with an explicit code keep the old version path.
    v_result := public.create_master_import_job(
        '00000000-0000-0000-0000-000000038103',
        'SUPPLIER','REFERENCE_BY_NAME','CREATE_AND_UPDATE',
        'supplier-legacy.csv',repeat('c',64),','
    );
    v_job := (v_result->>'jobId')::UUID;
    PERFORM public.stage_master_import_rows(
        v_job,1,'{"code":"code","name":"name"}'::JSONB,
        '[{"rowNumber":2,"sourceData":{"code":"OLD-SUP","name":"G38 Supplier"}}]'::JSONB
    );
    v_result := public.validate_master_import_job(v_job,2);
    IF (v_result->>'masterVersion')::BIGINT<>3 THEN
        RAISE EXCEPTION
            'TEST_FAILED: legacy template version compatibility changed';
    END IF;
    PERFORM public.commit_master_import_job(v_job,3,0);
    IF NOT EXISTS (
        SELECT 1 FROM public.suppliers
        WHERE company_id=v_company
          AND supplier_code='OLD-SUP'
          AND supplier_name='G38 Supplier'
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: legacy code template no longer commits';
    END IF;

    IF has_function_privilege(
        'anon',
        'public.validate_master_import_job(uuid,bigint)','EXECUTE'
    ) OR has_function_privilege(
        'authenticated',
        'private.validate_master_import_job_phase31(uuid,bigint)','EXECUTE'
    ) OR NOT has_function_privilege(
        'authenticated',
        'public.validate_master_import_job(uuid,bigint)','EXECUTE'
    ) THEN
        RAISE EXCEPTION
            'TEST_FAILED: validator privilege boundary invalid';
    END IF;

    RAISE NOTICE
        'TEST PASSED: code-less templates allocate stable server codes, reuse immutable existing identities, and preserve legacy CSV compatibility.';
END
$test$;

ROLLBACK;
