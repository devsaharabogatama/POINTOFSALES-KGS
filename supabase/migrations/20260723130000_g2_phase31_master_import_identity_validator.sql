-- KGS POS G2 phase 31: dry-run identity/lifecycle validator for non-stock import.
-- Dependency: import staging foundation 20260723100000.
--
-- Validates common identity fields only: internalId, code, name, isActive.
-- Type-specific operational fields and commit remain disabled.

BEGIN;

DO $migration_guard$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260723100000'
    ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: phase 30 import staging is required';
    END IF;
    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260723130000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260723130000';
    END IF;
END
$migration_guard$;

CREATE FUNCTION public.validate_master_import_job(
    p_job_id UUID,
    p_master_version BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_actor UUID := auth.uid();
    v_company UUID := public.private_active_company_id();
    v_job public.master_import_jobs%ROWTYPE;
    v_row RECORD;
    v_internal_id_column TEXT;
    v_code_column TEXT;
    v_name_column TEXT;
    v_active_column TEXT;
    v_internal_id_text TEXT;
    v_internal_id UUID;
    v_code TEXT;
    v_name TEXT;
    v_normalized_code TEXT;
    v_normalized_name TEXT;
    v_active_text TEXT;
    v_is_active BOOLEAN;
    v_match_count BIGINT;
    v_existing JSONB;
    v_existing_id UUID;
    v_operation TEXT;
    v_changed BOOLEAN;
    v_error_code TEXT;
    v_created INTEGER;
    v_updated INTEGER;
    v_skipped INTEGER;
    v_errors INTEGER;
    v_new_version BIGINT;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF NOT public.private_user_has_any_company_or_store_role(
        v_company,ARRAY['COMPANY_OWNER','COMPANY_ADMIN']::TEXT[]
    ) THEN RAISE EXCEPTION 'MASTER_IMPORT_ADMIN_REQUIRED'; END IF;

    SELECT * INTO v_job
    FROM public.master_import_jobs
    WHERE company_id = v_company AND id = p_job_id
    FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'IMPORT_JOB_NOT_FOUND'; END IF;
    IF p_master_version IS NOT NULL
       AND p_master_version + 1 = v_job.master_version
       AND v_job.status = 'VALIDATED' THEN
        RETURN jsonb_build_object(
            'jobId',v_job.id,'masterVersion',v_job.master_version,
            'status',v_job.status,'createCount',v_job.created_rows,
            'updateCount',v_job.updated_rows,'skipCount',v_job.skipped_rows,
            'errorCount',v_job.error_rows,'action','EXISTING'
        );
    END IF;
    IF p_master_version IS NULL OR p_master_version <> v_job.master_version THEN
        RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
    END IF;
    IF v_job.status <> 'MAPPED' THEN
        RAISE EXCEPTION 'IMPORT_JOB_NOT_VALIDATABLE';
    END IF;
    IF v_job.total_rows = 0 OR NOT EXISTS (
        SELECT 1 FROM public.master_import_rows r
        WHERE r.company_id = v_company AND r.job_id = p_job_id
    ) THEN RAISE EXCEPTION 'IMPORT_ROWS_REQUIRED'; END IF;

    v_internal_id_column := NULLIF(btrim(v_job.mapping->>'internalId'),'');
    v_code_column := NULLIF(btrim(v_job.mapping->>'code'),'');
    v_name_column := NULLIF(btrim(v_job.mapping->>'name'),'');
    v_active_column := NULLIF(btrim(v_job.mapping->>'isActive'),'');
    IF v_code_column IS NULL OR v_name_column IS NULL THEN
        RAISE EXCEPTION 'IMPORT_CODE_NAME_MAPPING_REQUIRED';
    END IF;
    IF v_job.reference_mode = 'REFERENCE_BY_ID'
       AND v_internal_id_column IS NULL THEN
        RAISE EXCEPTION 'IMPORT_INTERNAL_ID_MAPPING_REQUIRED';
    END IF;

    UPDATE public.master_import_rows
    SET normalized_data = NULL,operation = 'PENDING',row_status = 'STAGED',
        matched_record_id = NULL,warnings = '[]'::JSONB,errors = '[]'::JSONB,
        before_state = NULL,after_state = NULL,updated_at = clock_timestamp()
    WHERE company_id = v_company AND job_id = p_job_id;

    FOR v_row IN
        SELECT * FROM public.master_import_rows
        WHERE company_id = v_company AND job_id = p_job_id
        ORDER BY row_number
    LOOP
        v_error_code := NULL;
        v_existing := NULL;
        v_existing_id := NULL;
        v_match_count := 0;
        v_internal_id := NULL;
        v_operation := NULL;
        v_changed := FALSE;
        v_is_active := TRUE;
        v_internal_id_text := CASE WHEN v_internal_id_column IS NULL THEN NULL
            ELSE NULLIF(btrim(v_row.source_data->>v_internal_id_column),'') END;
        v_code := regexp_replace(
            btrim(COALESCE(v_row.source_data->>v_code_column,'')),'\s+',' ','g'
        );
        v_name := regexp_replace(
            btrim(COALESCE(v_row.source_data->>v_name_column,'')),'\s+',' ','g'
        );
        v_normalized_code := upper(v_code);
        v_normalized_name := lower(v_name);
        v_active_text := CASE WHEN v_active_column IS NULL THEN NULL
            ELSE NULLIF(lower(btrim(v_row.source_data->>v_active_column)),'') END;
        IF v_active_text IS NULL THEN
            v_is_active := TRUE;
        ELSIF v_active_text IN ('true','t','1','yes','y','ya','aktif','active') THEN
            v_is_active := TRUE;
        ELSIF v_active_text IN ('false','f','0','no','n','tidak','nonaktif','inactive') THEN
            v_is_active := FALSE;
        ELSE
            v_error_code := 'INVALID_BOOLEAN_IS_ACTIVE';
        END IF;
        IF v_code = '' THEN v_error_code := COALESCE(v_error_code,'CODE_REQUIRED'); END IF;
        IF v_name = '' THEN v_error_code := COALESCE(v_error_code,'NAME_REQUIRED'); END IF;
        IF v_internal_id_text IS NOT NULL THEN
            IF v_internal_id_text !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
                v_error_code := COALESCE(v_error_code,'INVALID_INTERNAL_ID');
            ELSE
                v_internal_id := v_internal_id_text::UUID;
            END IF;
        END IF;

        IF v_error_code IS NULL THEN
            IF v_job.import_type = 'PRODUCT_CATEGORY' THEN
                IF v_job.reference_mode = 'REFERENCE_BY_ID' THEN
                    SELECT count(*) INTO v_match_count
                    FROM public.product_categories x
                    WHERE x.company_id = v_company AND x.id = v_internal_id;
                    IF v_match_count = 1 THEN
                        SELECT jsonb_build_object(
                            'id',x.id,'code',x.category_code,
                            'name',x.category_name,'isActive',x.is_active
                        ) INTO v_existing
                        FROM public.product_categories x
                        WHERE x.company_id = v_company AND x.id = v_internal_id;
                    END IF;
                ELSE
                    SELECT count(*) INTO v_match_count
                    FROM public.product_categories x
                    WHERE x.company_id = v_company
                      AND lower(regexp_replace(btrim(x.category_name),'\s+',' ','g'))
                          = v_normalized_name;
                    IF v_match_count = 1 THEN
                        SELECT jsonb_build_object(
                            'id',x.id,'code',x.category_code,
                            'name',x.category_name,'isActive',x.is_active
                        ) INTO v_existing
                        FROM public.product_categories x
                        WHERE x.company_id = v_company
                          AND lower(regexp_replace(btrim(x.category_name),'\s+',' ','g'))
                              = v_normalized_name;
                    END IF;
                END IF;
            ELSIF v_job.import_type = 'UOM' THEN
                IF v_job.reference_mode = 'REFERENCE_BY_ID' THEN
                    SELECT count(*) INTO v_match_count FROM public.uoms x
                    WHERE x.company_id = v_company AND x.id = v_internal_id;
                    IF v_match_count = 1 THEN
                        SELECT jsonb_build_object(
                            'id',x.id,'code',x.code,'name',x.name,
                            'isActive',x.is_active
                        ) INTO v_existing FROM public.uoms x
                        WHERE x.company_id = v_company AND x.id = v_internal_id;
                    END IF;
                ELSE
                    SELECT count(*) INTO v_match_count FROM public.uoms x
                    WHERE x.company_id = v_company
                      AND lower(regexp_replace(btrim(x.name),'\s+',' ','g'))
                          = v_normalized_name;
                    IF v_match_count = 1 THEN
                        SELECT jsonb_build_object(
                            'id',x.id,'code',x.code,'name',x.name,
                            'isActive',x.is_active
                        ) INTO v_existing FROM public.uoms x
                        WHERE x.company_id = v_company
                          AND lower(regexp_replace(btrim(x.name),'\s+',' ','g'))
                              = v_normalized_name;
                    END IF;
                END IF;
            ELSIF v_job.import_type = 'WAREHOUSE' THEN
                IF v_job.reference_mode = 'REFERENCE_BY_ID' THEN
                    SELECT count(*) INTO v_match_count FROM public.warehouses x
                    WHERE x.company_id = v_company AND x.id = v_internal_id;
                    IF v_match_count = 1 THEN
                        SELECT jsonb_build_object(
                            'id',x.id,'code',x.code,'name',x.name,
                            'isActive',x.is_active
                        ) INTO v_existing FROM public.warehouses x
                        WHERE x.company_id = v_company AND x.id = v_internal_id;
                    END IF;
                ELSE
                    SELECT count(*) INTO v_match_count FROM public.warehouses x
                    WHERE x.company_id = v_company
                      AND lower(regexp_replace(btrim(x.name),'\s+',' ','g'))
                          = v_normalized_name;
                    IF v_match_count = 1 THEN
                        SELECT jsonb_build_object(
                            'id',x.id,'code',x.code,'name',x.name,
                            'isActive',x.is_active
                        ) INTO v_existing FROM public.warehouses x
                        WHERE x.company_id = v_company
                          AND lower(regexp_replace(btrim(x.name),'\s+',' ','g'))
                              = v_normalized_name;
                    END IF;
                END IF;
            ELSIF v_job.import_type = 'SUPPLIER' THEN
                IF v_job.reference_mode = 'REFERENCE_BY_ID' THEN
                    SELECT count(*) INTO v_match_count FROM public.suppliers x
                    WHERE x.company_id = v_company AND x.id = v_internal_id;
                    IF v_match_count = 1 THEN
                        SELECT jsonb_build_object(
                            'id',x.id,'code',x.supplier_code,
                            'name',x.supplier_name,'isActive',x.is_active
                        ) INTO v_existing FROM public.suppliers x
                        WHERE x.company_id = v_company AND x.id = v_internal_id;
                    END IF;
                ELSE
                    SELECT count(*) INTO v_match_count FROM public.suppliers x
                    WHERE x.company_id = v_company
                      AND lower(regexp_replace(btrim(x.supplier_name),'\s+',' ','g'))
                          = v_normalized_name;
                    IF v_match_count = 1 THEN
                        SELECT jsonb_build_object(
                            'id',x.id,'code',x.supplier_code,
                            'name',x.supplier_name,'isActive',x.is_active
                        ) INTO v_existing FROM public.suppliers x
                        WHERE x.company_id = v_company
                          AND lower(regexp_replace(btrim(x.supplier_name),'\s+',' ','g'))
                              = v_normalized_name;
                    END IF;
                END IF;
            ELSE
                v_error_code := 'UNSUPPORTED_IMPORT_TYPE';
            END IF;
        END IF;

        IF v_error_code IS NULL AND v_match_count > 1 THEN
            v_error_code := 'AMBIGUOUS_REFERENCE';
        END IF;
        IF v_existing IS NOT NULL THEN
            v_existing_id := (v_existing->>'id')::UUID;
            -- In name-reference mode the normalized name is the matching key,
            -- not a rename channel. Preserve the canonical stored spelling.
            IF v_job.reference_mode = 'REFERENCE_BY_NAME' THEN
                v_name := v_existing->>'name';
                v_normalized_name := lower(regexp_replace(
                    btrim(v_name),'\s+',' ','g'
                ));
            END IF;
        END IF;
        IF v_error_code IS NULL
           AND v_job.reference_mode = 'REFERENCE_BY_ID'
           AND v_internal_id IS NOT NULL AND v_existing IS NULL THEN
            v_error_code := 'ID_NOT_FOUND_IN_ACTIVE_COMPANY';
        END IF;

        -- Identity conflicts are checked against a different matched record.
        IF v_error_code IS NULL THEN
            IF v_job.import_type = 'PRODUCT_CATEGORY' AND EXISTS (
                SELECT 1 FROM public.product_categories x
                WHERE x.company_id = v_company
                  AND x.id IS DISTINCT FROM v_existing_id
                  AND (
                    upper(regexp_replace(btrim(x.category_code),'\s+',' ','g'))
                        = v_normalized_code
                    OR lower(regexp_replace(btrim(x.category_name),'\s+',' ','g'))
                        = v_normalized_name
                  )
            ) THEN v_error_code := 'CODE_OR_NAME_ALREADY_USED';
            ELSIF v_job.import_type = 'UOM' AND EXISTS (
                SELECT 1 FROM public.uoms x
                WHERE x.company_id = v_company
                  AND x.id IS DISTINCT FROM v_existing_id
                  AND (
                    upper(regexp_replace(btrim(x.code),'\s+',' ','g'))
                        = v_normalized_code
                    OR lower(regexp_replace(btrim(x.name),'\s+',' ','g'))
                        = v_normalized_name
                  )
            ) THEN v_error_code := 'CODE_OR_NAME_ALREADY_USED';
            ELSIF v_job.import_type = 'WAREHOUSE' AND EXISTS (
                SELECT 1 FROM public.warehouses x
                WHERE x.company_id = v_company
                  AND x.id IS DISTINCT FROM v_existing_id
                  AND (
                    upper(regexp_replace(btrim(x.code),'\s+',' ','g'))
                        = v_normalized_code
                    OR lower(regexp_replace(btrim(x.name),'\s+',' ','g'))
                        = v_normalized_name
                  )
            ) THEN v_error_code := 'CODE_OR_NAME_ALREADY_USED';
            ELSIF v_job.import_type = 'SUPPLIER' AND EXISTS (
                SELECT 1 FROM public.suppliers x
                WHERE x.company_id = v_company
                  AND x.id IS DISTINCT FROM v_existing_id
                  AND (
                    upper(regexp_replace(btrim(x.supplier_code),'\s+',' ','g'))
                        = v_normalized_code
                    OR lower(regexp_replace(btrim(x.supplier_name),'\s+',' ','g'))
                        = v_normalized_name
                  )
            ) THEN v_error_code := 'CODE_OR_NAME_ALREADY_USED';
            END IF;
        END IF;

        IF v_error_code IS NULL THEN
            IF v_existing IS NULL THEN
                IF v_job.operation_mode = 'UPDATE_ONLY' THEN
                    v_error_code := 'RECORD_NOT_FOUND_FOR_UPDATE';
                ELSE
                    v_operation := 'CREATE';
                END IF;
            ELSE
                IF v_job.operation_mode = 'CREATE_ONLY' THEN
                    v_error_code := 'RECORD_ALREADY_EXISTS';
                ELSE
                    v_changed := upper(v_existing->>'code') <> v_normalized_code
                        OR regexp_replace(btrim(v_existing->>'name'),'\s+',' ','g')
                            <> v_name
                        OR (v_existing->>'isActive')::BOOLEAN IS DISTINCT FROM v_is_active;
                    v_operation := CASE WHEN v_changed THEN 'UPDATE' ELSE 'SKIP' END;
                END IF;
            END IF;
        END IF;

        IF v_error_code IS NOT NULL THEN
            UPDATE public.master_import_rows SET
                normalized_data = jsonb_build_object(
                    'internalId',v_internal_id,'code',v_code,'name',v_name,
                    'isActive',v_is_active
                ),operation = 'ERROR',row_status = 'ERROR',
                matched_record_id = v_existing_id,
                errors = jsonb_build_array(jsonb_build_object('code',v_error_code)),
                before_state = v_existing,after_state = NULL,
                updated_at = clock_timestamp()
            WHERE id = v_row.id;
        ELSE
            UPDATE public.master_import_rows SET
                normalized_data = jsonb_build_object(
                    'internalId',v_internal_id,'code',v_code,'name',v_name,
                    'isActive',v_is_active
                ),operation = v_operation,row_status = 'VALIDATED',
                matched_record_id = v_existing_id,
                warnings = CASE WHEN v_operation = 'UPDATE'
                    THEN jsonb_build_array(jsonb_build_object(
                        'code','UPDATE_EXISTING_CONFIRMATION_REQUIRED'
                    )) ELSE '[]'::JSONB END,
                errors = '[]'::JSONB,before_state = v_existing,
                after_state = jsonb_build_object(
                    'id',v_existing_id,'code',v_code,'name',v_name,
                    'isActive',v_is_active
                ),updated_at = clock_timestamp()
            WHERE id = v_row.id;
        END IF;
    END LOOP;

    -- Duplicate identities in one file invalidate every involved row.
    UPDATE public.master_import_rows target SET
        operation = 'ERROR',row_status = 'ERROR',
        errors = target.errors || jsonb_build_array(jsonb_build_object(
            'code','DUPLICATE_CODE_OR_NAME_IN_FILE'
        )),after_state = NULL,updated_at = clock_timestamp()
    WHERE target.company_id = v_company AND target.job_id = p_job_id
      AND (
        (
            SELECT count(*)
            FROM public.master_import_rows candidate
            WHERE candidate.company_id = v_company
              AND candidate.job_id = p_job_id
              AND upper(candidate.normalized_data->>'code') =
                  upper(target.normalized_data->>'code')
        ) > 1
        OR (
            SELECT count(*)
            FROM public.master_import_rows candidate
            WHERE candidate.company_id = v_company
              AND candidate.job_id = p_job_id
              AND lower(candidate.normalized_data->>'name') =
                  lower(target.normalized_data->>'name')
        ) > 1
      );

    SELECT
        count(*) FILTER(WHERE operation = 'CREATE'),
        count(*) FILTER(WHERE operation = 'UPDATE'),
        count(*) FILTER(WHERE operation = 'SKIP'),
        count(*) FILTER(WHERE operation = 'ERROR')
    INTO v_created,v_updated,v_skipped,v_errors
    FROM public.master_import_rows
    WHERE company_id = v_company AND job_id = p_job_id;

    UPDATE public.master_import_jobs SET
        status = 'VALIDATED',created_rows = v_created,updated_rows = v_updated,
        skipped_rows = v_skipped,error_rows = v_errors,
        confirmed_update_count = 0,validated_by = v_actor,
        validated_at = clock_timestamp(),master_version = master_version + 1,
        updated_at = clock_timestamp()
    WHERE company_id = v_company AND id = p_job_id
    RETURNING master_version INTO v_new_version;

    INSERT INTO public.master_import_job_events(
        company_id,job_id,event_type,actor_id,before_state,after_state
    ) VALUES (
        v_company,p_job_id,'VALIDATE',v_actor,
        jsonb_build_object(
            'status',v_job.status,'masterVersion',v_job.master_version
        ),
        jsonb_build_object(
            'status','VALIDATED','masterVersion',v_new_version,
            'createCount',v_created,'updateCount',v_updated,
            'skipCount',v_skipped,'errorCount',v_errors
        )
    );
    RETURN jsonb_build_object(
        'jobId',p_job_id,'masterVersion',v_new_version,'status','VALIDATED',
        'createCount',v_created,'updateCount',v_updated,
        'skipCount',v_skipped,'errorCount',v_errors,'action','VALIDATE'
    );
END;
$$;

REVOKE ALL ON FUNCTION public.validate_master_import_job(UUID,BIGINT)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.validate_master_import_job(UUID,BIGINT)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES (
    '20260723130000',
    'g2_phase31_master_import_identity_validator',
    'Dry-run common identity/lifecycle validator for Category/UOM/Warehouse/Supplier with tenant-safe ID/name matching, preview operations, file duplicate errors, update warnings, and no commit'
);

COMMIT;

-- Forward-fix note: type-specific field validators and commit are additive
-- later phases. Do not edit this migration after apply.
