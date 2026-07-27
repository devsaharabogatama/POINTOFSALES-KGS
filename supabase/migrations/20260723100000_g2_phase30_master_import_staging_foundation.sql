-- KGS POS G2 phase 30: master Import/Export staging foundation.
-- Requirement: G2 generic import framework; gap B-04.
-- Dependency: phase 28 private Tax resolver through 20260723070000.
--
-- SCOPE:
-- - job/row/event staging and guarded upload/mapping lifecycle;
-- - initial import types are non-stock masters only;
-- - no row validation against business masters and no commit yet;
-- - Product grouped import, Brand, file storage, and Opening Stock are deferred;
-- - legacy Product+initial-stock RPC is quarantined, not reused.

BEGIN;

DO $migration_guard$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260723070000'
    ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: phase 28 Tax resolver is required';
    END IF;
    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260723100000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260723100000';
    END IF;
END
$migration_guard$;

CREATE TABLE public.master_import_jobs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL
        REFERENCES public.companies(id) ON DELETE RESTRICT,
    client_request_id UUID NOT NULL,
    import_type TEXT NOT NULL,
    reference_mode TEXT NOT NULL,
    operation_mode TEXT NOT NULL,
    file_name TEXT NOT NULL,
    file_checksum TEXT NOT NULL,
    delimiter TEXT NOT NULL DEFAULT ',',
    mapping JSONB NOT NULL DEFAULT '{}'::JSONB,
    staging_fingerprint TEXT,
    status TEXT NOT NULL DEFAULT 'UPLOADED',
    total_rows INTEGER NOT NULL DEFAULT 0,
    created_rows INTEGER NOT NULL DEFAULT 0,
    updated_rows INTEGER NOT NULL DEFAULT 0,
    skipped_rows INTEGER NOT NULL DEFAULT 0,
    error_rows INTEGER NOT NULL DEFAULT 0,
    confirmed_update_count INTEGER NOT NULL DEFAULT 0,
    master_version BIGINT NOT NULL DEFAULT 1,
    uploaded_by UUID NOT NULL REFERENCES public.profiles(id),
    uploaded_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    validated_by UUID REFERENCES public.profiles(id),
    validated_at TIMESTAMPTZ,
    committed_by UUID REFERENCES public.profiles(id),
    committed_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT master_import_jobs_company_id_id_unique UNIQUE(company_id,id),
    CONSTRAINT master_import_jobs_company_request_unique
        UNIQUE(company_id,client_request_id),
    CONSTRAINT master_import_jobs_type_check CHECK(import_type IN (
        'PRODUCT_CATEGORY','UOM','WAREHOUSE','SUPPLIER'
    )),
    CONSTRAINT master_import_jobs_reference_mode_check CHECK(
        reference_mode IN ('REFERENCE_BY_ID','REFERENCE_BY_NAME')
    ),
    CONSTRAINT master_import_jobs_operation_mode_check CHECK(
        operation_mode IN ('CREATE_ONLY','UPDATE_ONLY','CREATE_AND_UPDATE')
    ),
    CONSTRAINT master_import_jobs_status_check CHECK(status IN (
        'UPLOADED','MAPPED','VALIDATED','READY','PROCESSING',
        'COMPLETED','COMPLETED_WITH_ERRORS','FAILED','CANCELED'
    )),
    CONSTRAINT master_import_jobs_file_name_not_blank
        CHECK(btrim(file_name) <> ''),
    CONSTRAINT master_import_jobs_checksum_check
        CHECK(file_checksum ~ '^[0-9a-f]{64}$'),
    CONSTRAINT master_import_jobs_delimiter_check
        CHECK(delimiter IN (',',';',E'\t','|')),
    CONSTRAINT master_import_jobs_mapping_object
        CHECK(jsonb_typeof(mapping) = 'object'),
    CONSTRAINT master_import_jobs_staging_fingerprint_check CHECK(
        staging_fingerprint IS NULL
        OR staging_fingerprint ~ '^[0-9a-f]{32}$'
    ),
    CONSTRAINT master_import_jobs_counts_nonnegative CHECK(
        total_rows >= 0 AND created_rows >= 0 AND updated_rows >= 0
        AND skipped_rows >= 0 AND error_rows >= 0
        AND confirmed_update_count >= 0
    ),
    CONSTRAINT master_import_jobs_version_positive CHECK(master_version > 0),
    CONSTRAINT master_import_jobs_validation_pair CHECK(
        (validated_by IS NULL) = (validated_at IS NULL)
    ),
    CONSTRAINT master_import_jobs_commit_pair CHECK(
        (committed_by IS NULL) = (committed_at IS NULL)
    )
);

CREATE INDEX idx_master_import_jobs_company_created
    ON public.master_import_jobs(company_id,created_at DESC);
CREATE INDEX idx_master_import_jobs_company_status
    ON public.master_import_jobs(company_id,status,updated_at DESC);

CREATE TABLE public.master_import_rows (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_id UUID NOT NULL,
    job_id UUID NOT NULL,
    row_number INTEGER NOT NULL,
    group_key TEXT,
    source_data JSONB NOT NULL,
    source_fingerprint TEXT NOT NULL,
    normalized_data JSONB,
    operation TEXT NOT NULL DEFAULT 'PENDING',
    row_status TEXT NOT NULL DEFAULT 'STAGED',
    matched_record_id UUID,
    warnings JSONB NOT NULL DEFAULT '[]'::JSONB,
    errors JSONB NOT NULL DEFAULT '[]'::JSONB,
    before_state JSONB,
    after_state JSONB,
    committed_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT master_import_rows_job_row_unique UNIQUE(job_id,row_number),
    CONSTRAINT master_import_rows_company_job_fk
        FOREIGN KEY(company_id,job_id)
        REFERENCES public.master_import_jobs(company_id,id) ON DELETE CASCADE,
    CONSTRAINT master_import_rows_number_positive CHECK(row_number > 0),
    CONSTRAINT master_import_rows_group_not_blank
        CHECK(group_key IS NULL OR btrim(group_key) <> ''),
    CONSTRAINT master_import_rows_source_object
        CHECK(jsonb_typeof(source_data) = 'object'),
    CONSTRAINT master_import_rows_fingerprint_check
        CHECK(source_fingerprint ~ '^[0-9a-f]{32}$'),
    CONSTRAINT master_import_rows_normalized_object CHECK(
        normalized_data IS NULL OR jsonb_typeof(normalized_data) = 'object'
    ),
    CONSTRAINT master_import_rows_operation_check CHECK(operation IN (
        'PENDING','CREATE','UPDATE','SKIP','ERROR'
    )),
    CONSTRAINT master_import_rows_status_check CHECK(row_status IN (
        'STAGED','VALIDATED','COMMITTED','ERROR'
    )),
    CONSTRAINT master_import_rows_warnings_array
        CHECK(jsonb_typeof(warnings) = 'array'),
    CONSTRAINT master_import_rows_errors_array
        CHECK(jsonb_typeof(errors) = 'array')
);

CREATE INDEX idx_master_import_rows_company_job
    ON public.master_import_rows(company_id,job_id,row_number);
CREATE INDEX idx_master_import_rows_job_operation
    ON public.master_import_rows(job_id,operation,row_status);

CREATE TABLE public.master_import_job_events (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_id UUID NOT NULL,
    job_id UUID NOT NULL,
    event_type TEXT NOT NULL,
    actor_id UUID NOT NULL REFERENCES public.profiles(id),
    before_state JSONB,
    after_state JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT master_import_job_events_company_job_fk
        FOREIGN KEY(company_id,job_id)
        REFERENCES public.master_import_jobs(company_id,id) ON DELETE CASCADE,
    CONSTRAINT master_import_job_events_type_check CHECK(event_type IN (
        'CREATE','STAGE','VALIDATE','READY','PROCESS','COMPLETE',
        'FAIL','CANCEL'
    )),
    CONSTRAINT master_import_job_events_after_object
        CHECK(jsonb_typeof(after_state) = 'object')
);

CREATE INDEX idx_master_import_job_events_job_created
    ON public.master_import_job_events(company_id,job_id,created_at DESC);

CREATE FUNCTION public.create_master_import_job(
    p_client_request_id UUID,
    p_import_type TEXT,
    p_reference_mode TEXT,
    p_operation_mode TEXT,
    p_file_name TEXT,
    p_file_checksum TEXT,
    p_delimiter TEXT DEFAULT ','
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_actor UUID := auth.uid();
    v_company UUID := public.private_active_company_id();
    v_import_type TEXT := upper(btrim(COALESCE(p_import_type,'')));
    v_reference_mode TEXT := upper(btrim(COALESCE(p_reference_mode,'')));
    v_operation_mode TEXT := upper(btrim(COALESCE(p_operation_mode,'')));
    v_file_name TEXT := btrim(COALESCE(p_file_name,''));
    v_checksum TEXT := lower(btrim(COALESCE(p_file_checksum,'')));
    v_delimiter TEXT := COALESCE(p_delimiter,',');
    v_existing public.master_import_jobs%ROWTYPE;
    v_job_id UUID;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF NOT public.private_user_has_any_company_or_store_role(
        v_company,ARRAY['COMPANY_OWNER','COMPANY_ADMIN']::TEXT[]
    ) THEN RAISE EXCEPTION 'MASTER_IMPORT_ADMIN_REQUIRED'; END IF;
    IF p_client_request_id IS NULL THEN
        RAISE EXCEPTION 'IMPORT_CLIENT_REQUEST_ID_REQUIRED';
    END IF;
    IF v_import_type NOT IN (
        'PRODUCT_CATEGORY','UOM','WAREHOUSE','SUPPLIER'
    ) THEN RAISE EXCEPTION 'UNSUPPORTED_IMPORT_TYPE'; END IF;
    IF v_reference_mode NOT IN (
        'REFERENCE_BY_ID','REFERENCE_BY_NAME'
    ) THEN RAISE EXCEPTION 'INVALID_IMPORT_REFERENCE_MODE'; END IF;
    IF v_operation_mode NOT IN (
        'CREATE_ONLY','UPDATE_ONLY','CREATE_AND_UPDATE'
    ) THEN RAISE EXCEPTION 'INVALID_IMPORT_OPERATION_MODE'; END IF;
    IF v_file_name = '' THEN RAISE EXCEPTION 'IMPORT_FILE_NAME_REQUIRED'; END IF;
    IF v_checksum !~ '^[0-9a-f]{64}$' THEN
        RAISE EXCEPTION 'INVALID_IMPORT_FILE_CHECKSUM';
    END IF;
    IF v_delimiter NOT IN (',',';',E'\t','|') THEN
        RAISE EXCEPTION 'INVALID_IMPORT_DELIMITER';
    END IF;

    PERFORM pg_advisory_xact_lock(
        hashtextextended(v_company::TEXT || ':' || p_client_request_id::TEXT,0)
    );
    SELECT * INTO v_existing
    FROM public.master_import_jobs
    WHERE company_id = v_company
      AND client_request_id = p_client_request_id;
    IF FOUND THEN
        IF v_existing.import_type <> v_import_type
           OR v_existing.reference_mode <> v_reference_mode
           OR v_existing.operation_mode <> v_operation_mode
           OR v_existing.file_name <> v_file_name
           OR v_existing.file_checksum <> v_checksum
           OR v_existing.delimiter <> v_delimiter THEN
            RAISE EXCEPTION 'IMPORT_IDEMPOTENCY_CONFLICT';
        END IF;
        RETURN jsonb_build_object(
            'jobId',v_existing.id,
            'masterVersion',v_existing.master_version,
            'status',v_existing.status,
            'action','EXISTING'
        );
    END IF;

    INSERT INTO public.master_import_jobs(
        company_id,client_request_id,import_type,reference_mode,
        operation_mode,file_name,file_checksum,delimiter,uploaded_by
    ) VALUES (
        v_company,p_client_request_id,v_import_type,v_reference_mode,
        v_operation_mode,v_file_name,v_checksum,v_delimiter,v_actor
    ) RETURNING id INTO v_job_id;

    INSERT INTO public.master_import_job_events(
        company_id,job_id,event_type,actor_id,after_state
    ) VALUES (
        v_company,v_job_id,'CREATE',v_actor,
        jsonb_build_object(
            'status','UPLOADED','importType',v_import_type,
            'referenceMode',v_reference_mode,
            'operationMode',v_operation_mode,'masterVersion',1
        )
    );
    RETURN jsonb_build_object(
        'jobId',v_job_id,'masterVersion',1,
        'status','UPLOADED','action','CREATE'
    );
END;
$$;

CREATE FUNCTION public.stage_master_import_rows(
    p_job_id UUID,
    p_master_version BIGINT,
    p_mapping JSONB,
    p_rows JSONB
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
    v_row JSONB;
    v_row_number INTEGER;
    v_row_numbers INTEGER[] := ARRAY[]::INTEGER[];
    v_group_key TEXT;
    v_source JSONB;
    v_new_version BIGINT;
    v_staging_fingerprint TEXT;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF NOT public.private_user_has_any_company_or_store_role(
        v_company,ARRAY['COMPANY_OWNER','COMPANY_ADMIN']::TEXT[]
    ) THEN RAISE EXCEPTION 'MASTER_IMPORT_ADMIN_REQUIRED'; END IF;
    IF jsonb_typeof(p_mapping) IS DISTINCT FROM 'object' THEN
        RAISE EXCEPTION 'IMPORT_MAPPING_OBJECT_REQUIRED';
    END IF;
    IF jsonb_typeof(p_rows) IS DISTINCT FROM 'array'
       OR jsonb_array_length(p_rows) = 0 THEN
        RAISE EXCEPTION 'IMPORT_ROWS_REQUIRED';
    END IF;
    IF jsonb_array_length(p_rows) > 5000 THEN
        RAISE EXCEPTION 'IMPORT_ROW_LIMIT_EXCEEDED';
    END IF;
    v_staging_fingerprint := md5(p_mapping::TEXT || ':' || p_rows::TEXT);

    SELECT * INTO v_job
    FROM public.master_import_jobs
    WHERE company_id = v_company AND id = p_job_id
    FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'IMPORT_JOB_NOT_FOUND'; END IF;
    IF p_master_version IS NOT NULL
       AND p_master_version + 1 = v_job.master_version
       AND v_job.status = 'MAPPED'
       AND v_job.staging_fingerprint = v_staging_fingerprint THEN
        RETURN jsonb_build_object(
            'jobId',p_job_id,'masterVersion',v_job.master_version,
            'status','MAPPED','rowCount',v_job.total_rows,'action','EXISTING'
        );
    END IF;
    IF p_master_version IS NULL OR p_master_version <> v_job.master_version THEN
        RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
    END IF;
    IF v_job.status NOT IN ('UPLOADED','MAPPED') THEN
        RAISE EXCEPTION 'IMPORT_JOB_NOT_STAGEABLE';
    END IF;

    -- Validate the entire staging payload before replacing existing rows.
    FOR v_row IN SELECT value FROM jsonb_array_elements(p_rows) LOOP
        IF jsonb_typeof(v_row) IS DISTINCT FROM 'object' THEN
            RAISE EXCEPTION 'INVALID_IMPORT_ROW';
        END IF;
        IF COALESCE(v_row->>'rowNumber','') !~ '^[1-9][0-9]*$' THEN
            RAISE EXCEPTION 'INVALID_IMPORT_ROW_NUMBER';
        END IF;
        v_row_number := (v_row->>'rowNumber')::INTEGER;
        IF v_row_number = ANY(v_row_numbers) THEN
            RAISE EXCEPTION 'DUPLICATE_IMPORT_ROW_NUMBER';
        END IF;
        IF jsonb_typeof(v_row->'sourceData') IS DISTINCT FROM 'object' THEN
            RAISE EXCEPTION 'IMPORT_SOURCE_DATA_OBJECT_REQUIRED';
        END IF;
        v_row_numbers := array_append(v_row_numbers,v_row_number);
    END LOOP;

    DELETE FROM public.master_import_rows
    WHERE company_id = v_company AND job_id = p_job_id;
    FOR v_row IN SELECT value FROM jsonb_array_elements(p_rows) LOOP
        v_row_number := (v_row->>'rowNumber')::INTEGER;
        v_group_key := NULLIF(btrim(v_row->>'groupKey'),'');
        v_source := v_row->'sourceData';
        INSERT INTO public.master_import_rows(
            company_id,job_id,row_number,group_key,
            source_data,source_fingerprint
        ) VALUES (
            v_company,p_job_id,v_row_number,v_group_key,
            v_source,md5(v_source::TEXT)
        );
    END LOOP;

    UPDATE public.master_import_jobs
    SET mapping = p_mapping,
        staging_fingerprint = v_staging_fingerprint,
        status = 'MAPPED',
        total_rows = jsonb_array_length(p_rows),
        created_rows = 0,updated_rows = 0,skipped_rows = 0,error_rows = 0,
        confirmed_update_count = 0,
        validated_by = NULL,validated_at = NULL,
        committed_by = NULL,committed_at = NULL,
        master_version = master_version + 1,
        updated_at = clock_timestamp()
    WHERE company_id = v_company AND id = p_job_id
    RETURNING master_version INTO v_new_version;

    INSERT INTO public.master_import_job_events(
        company_id,job_id,event_type,actor_id,before_state,after_state
    ) VALUES (
        v_company,p_job_id,'STAGE',v_actor,
        jsonb_build_object(
            'status',v_job.status,'rowCount',v_job.total_rows,
            'masterVersion',v_job.master_version
        ),
        jsonb_build_object(
            'status','MAPPED','rowCount',jsonb_array_length(p_rows),
            'masterVersion',v_new_version
        )
    );
    RETURN jsonb_build_object(
        'jobId',p_job_id,'masterVersion',v_new_version,
        'status','MAPPED','rowCount',jsonb_array_length(p_rows)
    );
END;
$$;

ALTER TABLE public.master_import_jobs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.master_import_rows ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.master_import_job_events ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Master import jobs readable by Company administrators"
ON public.master_import_jobs FOR SELECT TO authenticated
USING(
    public.private_request_company_matches(company_id)
    AND public.private_user_has_any_company_or_store_role(
        company_id,ARRAY['COMPANY_OWNER','COMPANY_ADMIN']::TEXT[]
    )
);
CREATE POLICY "Master import rows readable by Company administrators"
ON public.master_import_rows FOR SELECT TO authenticated
USING(
    public.private_request_company_matches(company_id)
    AND public.private_user_has_any_company_or_store_role(
        company_id,ARRAY['COMPANY_OWNER','COMPANY_ADMIN']::TEXT[]
    )
);
CREATE POLICY "Master import events readable by Company administrators"
ON public.master_import_job_events FOR SELECT TO authenticated
USING(
    public.private_request_company_matches(company_id)
    AND public.private_user_has_any_company_or_store_role(
        company_id,ARRAY['COMPANY_OWNER','COMPANY_ADMIN']::TEXT[]
    )
);

REVOKE ALL ON public.master_import_jobs,public.master_import_rows,
    public.master_import_job_events FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.master_import_jobs,public.master_import_rows,
    public.master_import_job_events TO authenticated;
GRANT ALL ON public.master_import_jobs,public.master_import_rows,
    public.master_import_job_events TO service_role;
GRANT USAGE,SELECT ON SEQUENCE public.master_import_rows_id_seq,
    public.master_import_job_events_id_seq TO service_role;

REVOKE ALL ON FUNCTION public.create_master_import_job(
    UUID,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT
) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.stage_master_import_rows(
    UUID,BIGINT,JSONB,JSONB
) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.create_master_import_job(
    UUID,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT
) TO authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.stage_master_import_rows(
    UUID,BIGINT,JSONB,JSONB
) TO authenticated,service_role;

-- Quarantine the incompatible all-in-one legacy import. Objects remain for
-- catalog compatibility, but no API role can execute them.
REVOKE ALL ON FUNCTION public.import_products_for_company(UUID,JSONB)
FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.private_import_products_for_company_g1_legacy(
    UUID,JSONB
) FROM PUBLIC,anon,authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES (
    '20260723100000',
    'g2_phase30_master_import_staging_foundation',
    'Tenant-scoped idempotent non-stock import job/row/event staging; guarded upload/mapping RPC; legacy Product+stock import quarantined; validation/commit deferred'
);

COMMIT;

-- Forward-fix note: do not edit after apply. Validation/commit lifecycle,
-- Product grouped import, storage, and export use later additive migrations.
