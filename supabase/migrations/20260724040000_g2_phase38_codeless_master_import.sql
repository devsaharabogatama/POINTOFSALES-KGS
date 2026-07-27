-- KGS POS G2 phase 38: code-less CSV compatibility for simple master import.
-- Requirement: MST-005
-- Dependency: automatic hidden technical codes through 20260724010000.
--
-- FORWARD-ONLY COMPATIBILITY:
-- - existing CSV files that explicitly map code keep the phase-31 behavior;
-- - new CSV files may omit code for Category/UOM/Warehouse/Supplier;
-- - missing codes are allocated server-side inside the validation transaction;
-- - the generated code is staged once and reused by the existing guarded
--   partial commit, so preview and commit refer to one stable identity;
-- - no Product, stock, Opening Stock, or transaction import is enabled here.

BEGIN;

DO $migration_guard$
BEGIN
    IF to_regclass('private.kgs_schema_migrations') IS NULL
       OR NOT EXISTS (
           SELECT 1 FROM private.kgs_schema_migrations
           WHERE version='20260724010000'
       ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: automatic code foundation is incomplete';
    END IF;
    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version='20260724040000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260724040000';
    END IF;
END
$migration_guard$;

-- Preserve the already-applied validator byte-for-byte as a private legacy
-- implementation. The public signature becomes a compatibility wrapper.
ALTER FUNCTION public.validate_master_import_job(UUID,BIGINT)
    RENAME TO validate_master_import_job_phase31;
ALTER FUNCTION public.validate_master_import_job_phase31(UUID,BIGINT)
    SET SCHEMA private;

REVOKE ALL ON FUNCTION
    private.validate_master_import_job_phase31(UUID,BIGINT)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
    private.validate_master_import_job_phase31(UUID,BIGINT)
TO service_role;

-- Phase 32 inherited the legacy Warehouse convention of 1-5 letters. Phase 36
-- deliberately introduced WH-000001 technical identities. Extend only that
-- canonical validation predicate; retain legacy letters for old CSV files.
DO $warehouse_code_forward_fix$
DECLARE
    v_oid OID := to_regprocedure(
        'private.trg_g2_validate_import_business_fields()'
    );
    v_definition TEXT;
    v_old_predicate TEXT :=
        '(v_after->>''code'') !~ ''^[A-Z]{1,5}$''';
    v_new_predicate TEXT :=
        '(v_after->>''code'') !~ ''^[A-Z]{1,5}$'' AND '
        || '(v_after->>''code'') !~ ''^WH-[0-9]{6,18}$''';
BEGIN
    IF v_oid IS NULL THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: phase 32 business validator missing';
    END IF;
    SELECT pg_get_functiondef(v_oid) INTO v_definition;
    IF strpos(v_definition,v_old_predicate)=0 THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: Warehouse code predicate changed';
    END IF;
    EXECUTE replace(v_definition,v_old_predicate,v_new_predicate);
END
$warehouse_code_forward_fix$;

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
    v_name_column TEXT;
    v_internal_id_column TEXT;
    v_name TEXT;
    v_internal_id_text TEXT;
    v_internal_id UUID;
    v_existing_code TEXT;
    v_entity_type TEXT;
    v_generated_code TEXT;
    v_next_version BIGINT;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF NOT public.private_user_has_any_company_or_store_role(
        v_company,ARRAY['COMPANY_OWNER','COMPANY_ADMIN']::TEXT[]
    ) THEN RAISE EXCEPTION 'MASTER_IMPORT_ADMIN_REQUIRED'; END IF;

    SELECT * INTO v_job
    FROM public.master_import_jobs
    WHERE company_id=v_company AND id=p_job_id
    FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'IMPORT_JOB_NOT_FOUND'; END IF;

    -- A code-less first validation advances the job once for stable code
    -- preparation and once in the phase-31 validator. Translate an exact
    -- lost-response retry back to the legacy validator's one-step contract.
    IF v_job.status='VALIDATED'
       AND v_job.mapping->>'code'='__system_code'
       AND p_master_version+2=v_job.master_version THEN
        RETURN private.validate_master_import_job_phase31(
            p_job_id,v_job.master_version-1
        );
    END IF;

    -- Lost-response retries and legacy mappings retain the exact prior
    -- lifecycle/version behavior.
    IF NULLIF(btrim(v_job.mapping->>'code'),'') IS NOT NULL
       OR v_job.status<>'MAPPED' THEN
        RETURN private.validate_master_import_job_phase31(
            p_job_id,p_master_version
        );
    END IF;
    IF p_master_version IS NULL
       OR p_master_version<>v_job.master_version THEN
        RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
    END IF;

    v_name_column := NULLIF(btrim(v_job.mapping->>'name'),'');
    v_internal_id_column := NULLIF(
        btrim(v_job.mapping->>'internalId'),''
    );
    IF v_name_column IS NULL THEN
        RAISE EXCEPTION 'IMPORT_NAME_MAPPING_REQUIRED';
    END IF;
    IF v_job.reference_mode='REFERENCE_BY_ID'
       AND v_internal_id_column IS NULL THEN
        RAISE EXCEPTION 'IMPORT_INTERNAL_ID_MAPPING_REQUIRED';
    END IF;

    v_entity_type := CASE v_job.import_type
        WHEN 'PRODUCT_CATEGORY' THEN 'PRODUCT_CATEGORY'
        WHEN 'UOM' THEN 'UOM'
        WHEN 'WAREHOUSE' THEN 'WAREHOUSE'
        WHEN 'SUPPLIER' THEN 'SUPPLIER'
    END;
    IF v_entity_type IS NULL THEN
        RAISE EXCEPTION 'UNSUPPORTED_IMPORT_TYPE';
    END IF;

    FOR v_row IN
        SELECT r.id,r.source_data
        FROM public.master_import_rows r
        WHERE r.company_id=v_company AND r.job_id=p_job_id
        ORDER BY r.row_number
        FOR UPDATE
    LOOP
        v_existing_code := NULL;
        v_internal_id := NULL;
        v_name := lower(regexp_replace(
            btrim(COALESCE(v_row.source_data->>v_name_column,'')),
            '\s+',' ','g'
        ));
        v_internal_id_text := CASE
            WHEN v_internal_id_column IS NULL THEN NULL
            ELSE NULLIF(btrim(
                v_row.source_data->>v_internal_id_column
            ),'')
        END;
        IF v_internal_id_text IS NOT NULL
           AND v_internal_id_text ~*
               '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        THEN
            v_internal_id := v_internal_id_text::UUID;
        END IF;

        IF v_job.import_type='PRODUCT_CATEGORY' THEN
            IF v_job.reference_mode='REFERENCE_BY_ID' THEN
                SELECT x.category_code INTO v_existing_code
                FROM public.product_categories x
                WHERE x.company_id=v_company AND x.id=v_internal_id;
            ELSE
                SELECT min(x.category_code) INTO v_existing_code
                FROM public.product_categories x
                WHERE x.company_id=v_company
                  AND lower(regexp_replace(
                      btrim(x.category_name),'\s+',' ','g'
                  ))=v_name
                HAVING count(*)=1;
            END IF;
        ELSIF v_job.import_type='UOM' THEN
            IF v_job.reference_mode='REFERENCE_BY_ID' THEN
                SELECT x.code INTO v_existing_code
                FROM public.uoms x
                WHERE x.company_id=v_company AND x.id=v_internal_id;
            ELSE
                SELECT min(x.code) INTO v_existing_code
                FROM public.uoms x
                WHERE x.company_id=v_company
                  AND lower(regexp_replace(
                      btrim(x.name),'\s+',' ','g'
                  ))=v_name
                HAVING count(*)=1;
            END IF;
        ELSIF v_job.import_type='WAREHOUSE' THEN
            IF v_job.reference_mode='REFERENCE_BY_ID' THEN
                SELECT x.code INTO v_existing_code
                FROM public.warehouses x
                WHERE x.company_id=v_company AND x.id=v_internal_id;
            ELSE
                SELECT min(x.code) INTO v_existing_code
                FROM public.warehouses x
                WHERE x.company_id=v_company
                  AND lower(regexp_replace(
                      btrim(x.name),'\s+',' ','g'
                  ))=v_name
                HAVING count(*)=1;
            END IF;
        ELSE
            IF v_job.reference_mode='REFERENCE_BY_ID' THEN
                SELECT x.supplier_code INTO v_existing_code
                FROM public.suppliers x
                WHERE x.company_id=v_company AND x.id=v_internal_id;
            ELSE
                SELECT min(x.supplier_code) INTO v_existing_code
                FROM public.suppliers x
                WHERE x.company_id=v_company
                  AND lower(regexp_replace(
                      btrim(x.supplier_name),'\s+',' ','g'
                  ))=v_name
                HAVING count(*)=1;
            END IF;
        END IF;

        v_generated_code := COALESCE(
            v_existing_code,
            private.allocate_master_code(v_company,v_entity_type)
        );
        UPDATE public.master_import_rows
        SET source_data=source_data || jsonb_build_object(
                '__system_code',v_generated_code
            ),
            updated_at=clock_timestamp()
        WHERE id=v_row.id;
    END LOOP;

    UPDATE public.master_import_jobs
    SET mapping=jsonb_set(
            mapping,'{code}',to_jsonb('__system_code'::TEXT),TRUE
        ),
        master_version=master_version+1,
        updated_at=clock_timestamp()
    WHERE company_id=v_company AND id=p_job_id
    RETURNING master_version INTO v_next_version;

    RETURN private.validate_master_import_job_phase31(
        p_job_id,v_next_version
    );
END;
$$;

REVOKE ALL ON FUNCTION public.validate_master_import_job(UUID,BIGINT)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.validate_master_import_job(UUID,BIGINT)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES (
    '20260724040000',
    'g2_phase38_codeless_master_import',
    'Server-side stable technical-code preparation for code-less Category/UOM/Warehouse/Supplier CSV; WH generated-code validation forward-fix; legacy code-mapped CSV and guarded commit remain compatible'
);

COMMIT;

-- Forward-fix note: the full master catalog and atomic Product/Pricelist/
-- Payment Method groups remain later additive gates. Do not edit applied SQL.
