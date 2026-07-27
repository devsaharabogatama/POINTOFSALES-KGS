-- KGS POS G2 phase 40: remaining simple master Import/Export database gate.
-- Requirement: MST-005
-- Dependency: code-less simple import through 20260724040000.
--
-- Adds Customer Category, Chart of Account, and Transaction Category to the
-- generic staging/preview/partial-commit framework.
--
-- BOUNDARIES:
-- - system Customer Category, system COA, and required Transaction Category
--   rows are export-only and rejected by generic import;
-- - COA account_code remains a user-facing business identity;
-- - Customer/Transaction Category technical codes remain server allocated;
-- - commit delegates to guarded master RPCs and never mutates stock, journal,
--   transaction, Product, Pricelist, Payment Method, or Opening Stock.

BEGIN;

DO $migration_guard$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260724040000'
    ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: phase 38 import gate is required';
    END IF;
    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260727090000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260727090000';
    END IF;
    IF EXISTS (
        SELECT 1 FROM public.master_import_jobs
        WHERE status NOT IN (
            'COMPLETED','COMPLETED_WITH_ERRORS','FAILED','CANCELED'
        )
    ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: nonterminal import job exists';
    END IF;
END
$migration_guard$;

ALTER TABLE public.master_import_jobs
    DROP CONSTRAINT master_import_jobs_type_check,
    ADD CONSTRAINT master_import_jobs_type_check CHECK(import_type IN (
        'PRODUCT_CATEGORY','UOM','WAREHOUSE','SUPPLIER',
        'CUSTOMER_CATEGORY','CHART_OF_ACCOUNT','TRANSACTION_CATEGORY'
    ));

-- Keep the public job contract stable while extending only the whitelist.
CREATE OR REPLACE FUNCTION public.create_master_import_job(
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
        'PRODUCT_CATEGORY','UOM','WAREHOUSE','SUPPLIER',
        'CUSTOMER_CATEGORY','CHART_OF_ACCOUNT','TRANSACTION_CATEGORY'
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

REVOKE ALL ON FUNCTION public.create_master_import_job(
    UUID,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT
) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.create_master_import_job(
    UUID,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT
) TO authenticated,service_role;

-- The Phase-32 trigger only enriches the original four import types. Prevent
-- it from rewriting the complete Phase-40 preview produced below.
DO $phase32_trigger_dispatch$
DECLARE
    v_oid OID := to_regprocedure(
        'private.trg_g2_validate_import_business_fields()'
    );
    v_definition TEXT;
    v_marker TEXT :=
        '    -- Manual CRUD stores every business code in uppercase.';
    v_dispatch TEXT :=
        '    IF v_job.import_type IN (' ||
        '''CUSTOMER_CATEGORY'',''CHART_OF_ACCOUNT'',' ||
        '''TRANSACTION_CATEGORY'') THEN' || E'\n' ||
        '        RETURN NEW;' || E'\n' ||
        '    END IF;' || E'\n\n';
BEGIN
    IF v_oid IS NULL THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: phase 32 trigger missing';
    END IF;
    SELECT pg_get_functiondef(v_oid) INTO v_definition;
    IF strpos(v_definition,v_marker) = 0 THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: phase 32 trigger contract changed';
    END IF;
    EXECUTE replace(v_definition,v_marker,v_dispatch || v_marker);
END
$phase32_trigger_dispatch$;

-- Extend optimistic preview capture to the three new master types.
CREATE OR REPLACE FUNCTION private.trg_g2_capture_import_master_version()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_import_type TEXT;
    v_master_version BIGINT;
BEGIN
    IF NEW.row_status = 'STAGED' THEN
        NEW.matched_master_version := NULL;
        RETURN NEW;
    END IF;
    IF NEW.row_status <> 'VALIDATED' OR NEW.matched_record_id IS NULL THEN
        RETURN NEW;
    END IF;

    SELECT j.import_type INTO v_import_type
    FROM public.master_import_jobs j
    WHERE j.company_id = NEW.company_id AND j.id = NEW.job_id;

    IF v_import_type = 'PRODUCT_CATEGORY' THEN
        SELECT x.master_version INTO v_master_version
        FROM public.product_categories x
        WHERE x.company_id = NEW.company_id AND x.id = NEW.matched_record_id;
    ELSIF v_import_type = 'UOM' THEN
        SELECT x.master_version INTO v_master_version
        FROM public.uoms x
        WHERE x.company_id = NEW.company_id AND x.id = NEW.matched_record_id;
    ELSIF v_import_type = 'WAREHOUSE' THEN
        SELECT x.master_version INTO v_master_version
        FROM public.warehouses x
        WHERE x.company_id = NEW.company_id AND x.id = NEW.matched_record_id;
    ELSIF v_import_type = 'SUPPLIER' THEN
        SELECT x.master_version INTO v_master_version
        FROM public.suppliers x
        WHERE x.company_id = NEW.company_id AND x.id = NEW.matched_record_id;
    ELSIF v_import_type = 'CUSTOMER_CATEGORY' THEN
        SELECT x.master_version INTO v_master_version
        FROM public.customer_categories x
        WHERE x.company_id = NEW.company_id AND x.id = NEW.matched_record_id;
    ELSIF v_import_type = 'CHART_OF_ACCOUNT' THEN
        SELECT x.master_version INTO v_master_version
        FROM public.chart_of_accounts x
        WHERE x.company_id = NEW.company_id AND x.id = NEW.matched_record_id;
    ELSIF v_import_type = 'TRANSACTION_CATEGORY' THEN
        SELECT x.master_version INTO v_master_version
        FROM public.transaction_categories x
        WHERE x.company_id = NEW.company_id AND x.id = NEW.matched_record_id;
    END IF;
    NEW.matched_master_version := v_master_version;
    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION private.trg_g2_capture_import_master_version()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.trg_g2_capture_import_master_version()
TO service_role;

CREATE FUNCTION private.g2_phase40_import_boolean(
    p_value TEXT,
    p_default BOOLEAN
)
RETURNS BOOLEAN
LANGUAGE plpgsql
IMMUTABLE
SET search_path = public, pg_temp
AS $$
DECLARE
    v_value TEXT := NULLIF(lower(btrim(p_value)),'');
BEGIN
    IF v_value IS NULL THEN RETURN p_default; END IF;
    IF v_value IN ('true','t','1','yes','y','ya','aktif','active') THEN
        RETURN TRUE;
    END IF;
    IF v_value IN (
        'false','f','0','no','n','tidak','nonaktif','inactive'
    ) THEN
        RETURN FALSE;
    END IF;
    RAISE EXCEPTION 'INVALID_IMPORT_BOOLEAN';
END;
$$;

REVOKE ALL ON FUNCTION private.g2_phase40_import_boolean(TEXT,BOOLEAN)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.g2_phase40_import_boolean(TEXT,BOOLEAN)
TO service_role;

-- Preserve Phase-38 behavior for the original four types.
ALTER FUNCTION public.validate_master_import_job(UUID,BIGINT)
    RENAME TO validate_master_import_job_phase38;
ALTER FUNCTION public.validate_master_import_job_phase38(UUID,BIGINT)
    SET SCHEMA private;

REVOKE ALL ON FUNCTION
    private.validate_master_import_job_phase38(UUID,BIGINT)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
    private.validate_master_import_job_phase38(UUID,BIGINT)
TO service_role;

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
    v_row public.master_import_rows%ROWTYPE;
    v_existing JSONB;
    v_existing_id UUID;
    v_match_count BIGINT;
    v_internal_id UUID;
    v_internal_text TEXT;
    v_column TEXT;
    v_text TEXT;
    v_name TEXT;
    v_normalized_name TEXT;
    v_code TEXT;
    v_normalized_code TEXT;
    v_is_active BOOLEAN;
    v_account_type TEXT;
    v_normal_balance TEXT;
    v_parent_code TEXT;
    v_parent_id UUID;
    v_function_key TEXT;
    v_is_postable BOOLEAN;
    v_allow_manual BOOLEAN;
    v_allow_reconciliation BOOLEAN;
    v_system_key TEXT;
    v_description TEXT;
    v_operation TEXT;
    v_error TEXT;
    v_changed BOOLEAN;
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

    IF v_job.import_type NOT IN (
        'CUSTOMER_CATEGORY','CHART_OF_ACCOUNT','TRANSACTION_CATEGORY'
    ) THEN
        RETURN private.validate_master_import_job_phase38(
            p_job_id,p_master_version
        );
    END IF;

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

    IF NULLIF(btrim(v_job.mapping->>'name'),'') IS NULL THEN
        RAISE EXCEPTION 'IMPORT_NAME_MAPPING_REQUIRED';
    END IF;
    IF v_job.reference_mode = 'REFERENCE_BY_ID'
       AND NULLIF(btrim(v_job.mapping->>'internalId'),'') IS NULL THEN
        RAISE EXCEPTION 'IMPORT_INTERNAL_ID_MAPPING_REQUIRED';
    END IF;
    IF v_job.import_type = 'CHART_OF_ACCOUNT' AND (
        NULLIF(btrim(v_job.mapping->>'code'),'') IS NULL
        OR NULLIF(btrim(v_job.mapping->>'accountType'),'') IS NULL
        OR NULLIF(btrim(v_job.mapping->>'normalBalance'),'') IS NULL
    ) THEN RAISE EXCEPTION 'IMPORT_COA_MAPPING_REQUIRED'; END IF;
    IF v_job.import_type = 'TRANSACTION_CATEGORY'
       AND NULLIF(btrim(v_job.mapping->>'systemKey'),'') IS NULL THEN
        RAISE EXCEPTION 'IMPORT_SYSTEM_KEY_MAPPING_REQUIRED';
    END IF;

    UPDATE public.master_import_rows
    SET normalized_data = NULL,operation = 'PENDING',row_status = 'STAGED',
        matched_record_id = NULL,matched_master_version = NULL,
        warnings = '[]'::JSONB,errors = '[]'::JSONB,
        before_state = NULL,after_state = NULL,
        updated_at = clock_timestamp()
    WHERE company_id = v_company AND job_id = p_job_id;

    FOR v_row IN
        SELECT * FROM public.master_import_rows
        WHERE company_id = v_company AND job_id = p_job_id
        ORDER BY row_number
        FOR UPDATE
    LOOP
        v_existing := NULL;
        v_existing_id := NULL;
        v_match_count := 0;
        v_internal_id := NULL;
        v_operation := NULL;
        v_error := NULL;
        v_changed := FALSE;
        v_parent_id := NULL;
        v_parent_code := NULL;
        v_function_key := NULL;
        v_description := NULL;
        v_is_active := TRUE;
        v_account_type := NULL;
        v_normal_balance := NULL;
        v_is_postable := TRUE;
        v_allow_manual := FALSE;
        v_allow_reconciliation := FALSE;
        v_system_key := NULL;

        v_column := NULLIF(btrim(v_job.mapping->>'internalId'),'');
        v_internal_text := CASE WHEN v_column IS NULL THEN NULL
            ELSE NULLIF(btrim(v_row.source_data->>v_column),'') END;
        IF v_internal_text IS NOT NULL THEN
            IF v_internal_text !~*
                '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
            THEN
                v_error := 'INVALID_INTERNAL_ID';
            ELSE
                v_internal_id := v_internal_text::UUID;
            END IF;
        END IF;

        v_column := btrim(v_job.mapping->>'name');
        v_name := regexp_replace(
            btrim(COALESCE(v_row.source_data->>v_column,'')),'\s+',' ','g'
        );
        v_normalized_name := lower(v_name);
        IF v_name = '' THEN v_error := COALESCE(v_error,'NAME_REQUIRED'); END IF;

        IF v_job.import_type = 'CHART_OF_ACCOUNT' THEN
            v_column := btrim(v_job.mapping->>'code');
            v_code := upper(regexp_replace(
                btrim(COALESCE(v_row.source_data->>v_column,'')),
                '\s+',' ','g'
            ));
            v_normalized_code := v_code;
            IF v_code = '' THEN
                v_error := COALESCE(v_error,'ACCOUNT_CODE_REQUIRED');
            END IF;
        ELSE
            v_code := NULL;
            v_normalized_code := NULL;
        END IF;

        IF v_error IS NULL THEN
            IF v_job.import_type = 'CUSTOMER_CATEGORY' THEN
                IF v_job.reference_mode = 'REFERENCE_BY_ID' THEN
                    SELECT count(*),min(x.id::TEXT)::UUID
                    INTO v_match_count,v_existing_id
                    FROM public.customer_categories x
                    WHERE x.company_id = v_company AND x.id = v_internal_id;
                ELSE
                    SELECT count(*),min(x.id::TEXT)::UUID
                    INTO v_match_count,v_existing_id
                    FROM public.customer_categories x
                    WHERE x.company_id = v_company
                      AND lower(regexp_replace(
                          btrim(x.category_name),'\s+',' ','g'
                      )) = v_normalized_name;
                END IF;
                IF v_match_count = 1 THEN
                    SELECT jsonb_build_object(
                        'id',x.id,'code',x.category_code,
                        'name',x.category_name,'isActive',x.is_active,
                        'isSystem',x.is_system_category
                    ) INTO v_existing
                    FROM public.customer_categories x
                    WHERE x.company_id = v_company AND x.id = v_existing_id;
                END IF;
            ELSIF v_job.import_type = 'CHART_OF_ACCOUNT' THEN
                IF v_job.reference_mode = 'REFERENCE_BY_ID' THEN
                    SELECT count(*),min(x.id::TEXT)::UUID
                    INTO v_match_count,v_existing_id
                    FROM public.chart_of_accounts x
                    WHERE x.company_id = v_company AND x.id = v_internal_id;
                ELSE
                    SELECT count(*),min(x.id::TEXT)::UUID
                    INTO v_match_count,v_existing_id
                    FROM public.chart_of_accounts x
                    WHERE x.company_id = v_company
                      AND upper(regexp_replace(
                          btrim(x.account_code),'\s+',' ','g'
                      )) = v_normalized_code;
                END IF;
                IF v_match_count = 1 THEN
                    SELECT jsonb_build_object(
                        'id',x.id,'code',x.account_code,'name',x.account_name,
                        'accountType',x.account_type,
                        'normalBalance',x.normal_balance,
                        'parentAccountId',x.parent_account_id,
                        'parentAccountCode',parent.account_code,
                        'systemFunctionKey',x.system_function_key,
                        'isPostable',x.is_postable,
                        'allowManualPosting',x.allow_manual_posting,
                        'allowReconciliation',x.allow_reconciliation,
                        'isActive',x.is_active,
                        'isSystem',x.is_system_account
                    ) INTO v_existing
                    FROM public.chart_of_accounts x
                    LEFT JOIN public.chart_of_accounts parent
                      ON parent.company_id = x.company_id
                     AND parent.id = x.parent_account_id
                    WHERE x.company_id = v_company AND x.id = v_existing_id;
                END IF;
            ELSE
                IF v_job.reference_mode = 'REFERENCE_BY_ID' THEN
                    SELECT count(*),min(x.id::TEXT)::UUID
                    INTO v_match_count,v_existing_id
                    FROM public.transaction_categories x
                    WHERE x.company_id = v_company AND x.id = v_internal_id;
                ELSE
                    SELECT count(*),min(x.id::TEXT)::UUID
                    INTO v_match_count,v_existing_id
                    FROM public.transaction_categories x
                    WHERE x.company_id = v_company
                      AND lower(regexp_replace(
                          btrim(x.category_name),'\s+',' ','g'
                      )) = v_normalized_name;
                END IF;
                IF v_match_count = 1 THEN
                    SELECT jsonb_build_object(
                        'id',x.id,'code',x.category_code,
                        'name',x.category_name,'systemKey',x.system_key,
                        'description',x.description,'isActive',x.is_active,
                        'isSystem',x.is_system_default
                    ) INTO v_existing
                    FROM public.transaction_categories x
                    WHERE x.company_id = v_company AND x.id = v_existing_id;
                END IF;
            END IF;
        END IF;

        IF v_error IS NULL AND v_match_count > 1 THEN
            v_error := 'AMBIGUOUS_REFERENCE';
        END IF;
        IF v_error IS NULL
           AND v_job.reference_mode = 'REFERENCE_BY_ID'
           AND v_internal_id IS NOT NULL AND v_existing IS NULL THEN
            v_error := 'ID_NOT_FOUND_IN_ACTIVE_COMPANY';
        END IF;
        IF v_error IS NULL AND v_existing IS NOT NULL
           AND (v_existing->>'isSystem')::BOOLEAN THEN
            v_error := 'SYSTEM_MASTER_IMPORT_FORBIDDEN';
        END IF;

        IF v_error IS NULL THEN
            v_is_active := CASE WHEN v_existing IS NULL THEN TRUE
                ELSE (v_existing->>'isActive')::BOOLEAN END;
            v_column := NULLIF(btrim(v_job.mapping->>'isActive'),'');
            IF v_column IS NOT NULL THEN
                BEGIN
                    v_is_active := private.g2_phase40_import_boolean(
                        v_row.source_data->>v_column,v_is_active
                    );
                EXCEPTION WHEN OTHERS THEN
                    v_error := 'INVALID_BOOLEAN_IS_ACTIVE';
                END;
            END IF;
        END IF;

        IF v_error IS NULL AND v_job.import_type = 'CUSTOMER_CATEGORY' THEN
            IF char_length(v_name) > 200 THEN
                v_error := 'CUSTOMER_CATEGORY_NAME_TOO_LONG';
            ELSIF EXISTS (
                SELECT 1 FROM public.customer_categories x
                WHERE x.company_id = v_company
                  AND x.id IS DISTINCT FROM v_existing_id
                  AND lower(regexp_replace(
                      btrim(x.category_name),'\s+',' ','g'
                  )) = v_normalized_name
            ) THEN
                v_error := 'NAME_ALREADY_USED';
            END IF;

        ELSIF v_error IS NULL
          AND v_job.import_type = 'TRANSACTION_CATEGORY' THEN
            v_column := btrim(v_job.mapping->>'systemKey');
            v_system_key := upper(btrim(COALESCE(
                v_row.source_data->>v_column,''
            )));
            v_column := NULLIF(btrim(v_job.mapping->>'description'),'');
            v_description := CASE WHEN v_column IS NULL THEN
                CASE WHEN v_existing IS NULL THEN NULL
                     ELSE NULLIF(v_existing->>'description','') END
                ELSE NULLIF(btrim(v_row.source_data->>v_column),'')
            END;
            IF NOT EXISTS (
                SELECT 1 FROM public.system_events event
                WHERE event.system_key = v_system_key AND event.is_active
            ) THEN
                v_error := 'ACTIVE_SYSTEM_EVENT_NOT_FOUND';
            ELSIF EXISTS (
                SELECT 1 FROM public.transaction_categories x
                WHERE x.company_id = v_company
                  AND x.id IS DISTINCT FROM v_existing_id
                  AND lower(regexp_replace(
                      btrim(x.category_name),'\s+',' ','g'
                  )) = v_normalized_name
            ) THEN
                v_error := 'NAME_ALREADY_USED';
            END IF;

        ELSIF v_error IS NULL AND v_job.import_type = 'CHART_OF_ACCOUNT' THEN
            v_column := btrim(v_job.mapping->>'accountType');
            v_account_type := upper(btrim(COALESCE(
                v_row.source_data->>v_column,''
            )));
            v_column := btrim(v_job.mapping->>'normalBalance');
            v_normal_balance := upper(btrim(COALESCE(
                v_row.source_data->>v_column,''
            )));
            IF v_account_type NOT IN (
                'ASSET','LIABILITY','EQUITY','REVENUE','COGS','EXPENSE',
                'OTHER_INCOME','OTHER_EXPENSE'
            ) THEN
                v_error := 'INVALID_ACCOUNT_TYPE';
            ELSIF v_normal_balance NOT IN ('DEBIT','CREDIT') THEN
                v_error := 'INVALID_NORMAL_BALANCE';
            END IF;

            v_column := NULLIF(btrim(v_job.mapping->>'parentAccountCode'),'');
            IF v_column IS NOT NULL THEN
                v_parent_code := NULLIF(upper(regexp_replace(
                    btrim(v_row.source_data->>v_column),'\s+',' ','g'
                )),'');
            ELSIF v_existing IS NOT NULL THEN
                v_parent_code := NULLIF(
                    v_existing->>'parentAccountCode',''
                );
            END IF;
            IF v_parent_code = v_normalized_code THEN
                v_error := COALESCE(v_error,'COA_HIERARCHY_CYCLE');
            ELSIF v_parent_code IS NOT NULL THEN
                SELECT min(x.id) INTO v_parent_id
                FROM public.chart_of_accounts x
                WHERE x.company_id = v_company
                  AND upper(regexp_replace(
                      btrim(x.account_code),'\s+',' ','g'
                  )) = v_parent_code;
                IF v_parent_id IS NULL AND NOT EXISTS (
                    SELECT 1 FROM public.master_import_rows prior
                    WHERE prior.company_id = v_company
                      AND prior.job_id = p_job_id
                      AND prior.row_number < v_row.row_number
                      AND prior.row_status = 'VALIDATED'
                      AND prior.operation = 'CREATE'
                      AND upper(prior.after_state->>'code') = v_parent_code
                ) THEN
                    v_error := COALESCE(
                        v_error,'PARENT_ACCOUNT_NOT_FOUND_OR_NOT_PRIOR'
                    );
                END IF;
            END IF;

            v_column := NULLIF(
                btrim(v_job.mapping->>'systemFunctionKey'),''
            );
            v_function_key := CASE WHEN v_column IS NULL THEN
                CASE WHEN v_existing IS NULL THEN NULL
                     ELSE NULLIF(v_existing->>'systemFunctionKey','') END
                ELSE NULLIF(upper(btrim(
                    v_row.source_data->>v_column
                )),'')
            END;
            IF v_function_key IS NOT NULL AND NOT EXISTS (
                SELECT 1 FROM public.account_functions af
                WHERE af.function_key = v_function_key
                  AND af.is_active
                  AND v_account_type = ANY(af.compatible_account_types)
            ) THEN
                v_error := COALESCE(
                    v_error,'INCOMPATIBLE_OR_INACTIVE_ACCOUNT_FUNCTION'
                );
            END IF;

            v_is_postable := CASE WHEN v_existing IS NULL THEN TRUE
                ELSE (v_existing->>'isPostable')::BOOLEAN END;
            v_allow_manual := CASE WHEN v_existing IS NULL THEN FALSE
                ELSE (v_existing->>'allowManualPosting')::BOOLEAN END;
            v_allow_reconciliation := CASE
                WHEN v_existing IS NULL THEN FALSE
                ELSE (v_existing->>'allowReconciliation')::BOOLEAN END;

            FOREACH v_text IN ARRAY ARRAY[
                'isPostable','allowManualPosting','allowReconciliation'
            ] LOOP
                v_column := NULLIF(btrim(v_job.mapping->>v_text),'');
                IF v_column IS NOT NULL THEN
                    BEGIN
                        IF v_text = 'isPostable' THEN
                            v_is_postable :=
                                private.g2_phase40_import_boolean(
                                    v_row.source_data->>v_column,
                                    v_is_postable
                                );
                        ELSIF v_text = 'allowManualPosting' THEN
                            v_allow_manual :=
                                private.g2_phase40_import_boolean(
                                    v_row.source_data->>v_column,
                                    v_allow_manual
                                );
                        ELSE
                            v_allow_reconciliation :=
                                private.g2_phase40_import_boolean(
                                    v_row.source_data->>v_column,
                                    v_allow_reconciliation
                                );
                        END IF;
                    EXCEPTION WHEN OTHERS THEN
                        v_error := COALESCE(
                            v_error,'INVALID_BOOLEAN_' || upper(v_text)
                        );
                    END;
                END IF;
            END LOOP;
            IF v_allow_manual AND NOT v_is_postable THEN
                v_error := COALESCE(
                    v_error,'MANUAL_POSTING_REQUIRES_POSTABLE_ACCOUNT'
                );
            END IF;
            IF EXISTS (
                SELECT 1 FROM public.chart_of_accounts x
                WHERE x.company_id = v_company
                  AND x.id IS DISTINCT FROM v_existing_id
                  AND (
                      upper(regexp_replace(
                          btrim(x.account_code),'\s+',' ','g'
                      )) = v_normalized_code
                      OR lower(regexp_replace(
                          btrim(x.account_name),'\s+',' ','g'
                      )) = v_normalized_name
                  )
            ) THEN
                v_error := COALESCE(v_error,'CODE_OR_NAME_ALREADY_USED');
            END IF;
        END IF;

        IF v_error IS NULL THEN
            IF v_existing IS NULL THEN
                IF v_job.operation_mode = 'UPDATE_ONLY' THEN
                    v_error := 'RECORD_NOT_FOUND_FOR_UPDATE';
                ELSE
                    v_operation := 'CREATE';
                END IF;
            ELSIF v_job.operation_mode = 'CREATE_ONLY' THEN
                v_error := 'RECORD_ALREADY_EXISTS';
            END IF;
        END IF;

        IF v_job.import_type = 'CUSTOMER_CATEGORY' THEN
            v_changed := v_existing IS NOT NULL AND (
                v_existing->>'name' IS DISTINCT FROM v_name
                OR (v_existing->>'isActive')::BOOLEAN
                    IS DISTINCT FROM v_is_active
            );
        ELSIF v_job.import_type = 'TRANSACTION_CATEGORY' THEN
            v_changed := v_existing IS NOT NULL AND (
                v_existing->>'name' IS DISTINCT FROM v_name
                OR v_existing->>'systemKey' IS DISTINCT FROM v_system_key
                OR NULLIF(v_existing->>'description','')
                    IS DISTINCT FROM v_description
                OR (v_existing->>'isActive')::BOOLEAN
                    IS DISTINCT FROM v_is_active
            );
        ELSE
            v_changed := v_existing IS NOT NULL AND (
                upper(v_existing->>'code') IS DISTINCT FROM v_code
                OR v_existing->>'name' IS DISTINCT FROM v_name
                OR v_existing->>'accountType' IS DISTINCT FROM v_account_type
                OR v_existing->>'normalBalance'
                    IS DISTINCT FROM v_normal_balance
                OR NULLIF(upper(v_existing->>'parentAccountCode'),'')
                    IS DISTINCT FROM v_parent_code
                OR NULLIF(v_existing->>'systemFunctionKey','')
                    IS DISTINCT FROM v_function_key
                OR (v_existing->>'isPostable')::BOOLEAN
                    IS DISTINCT FROM v_is_postable
                OR (v_existing->>'allowManualPosting')::BOOLEAN
                    IS DISTINCT FROM v_allow_manual
                OR (v_existing->>'allowReconciliation')::BOOLEAN
                    IS DISTINCT FROM v_allow_reconciliation
                OR (v_existing->>'isActive')::BOOLEAN
                    IS DISTINCT FROM v_is_active
            );
        END IF;
        IF v_error IS NULL AND v_existing IS NOT NULL THEN
            v_operation := CASE WHEN v_changed THEN 'UPDATE' ELSE 'SKIP' END;
        END IF;

        IF v_job.import_type = 'CUSTOMER_CATEGORY' THEN
            v_row.after_state := jsonb_build_object(
                'id',v_existing_id,'name',v_name,'isActive',v_is_active
            );
        ELSIF v_job.import_type = 'TRANSACTION_CATEGORY' THEN
            v_row.after_state := jsonb_build_object(
                'id',v_existing_id,'name',v_name,'systemKey',v_system_key,
                'description',v_description,'isActive',v_is_active
            );
        ELSE
            v_row.after_state := jsonb_build_object(
                'id',v_existing_id,'code',v_code,'name',v_name,
                'accountType',v_account_type,'normalBalance',v_normal_balance,
                'parentAccountCode',v_parent_code,
                'systemFunctionKey',v_function_key,
                'isPostable',v_is_postable,
                'allowManualPosting',v_allow_manual,
                'allowReconciliation',v_allow_reconciliation,
                'isActive',v_is_active
            );
        END IF;

        IF v_error IS NOT NULL THEN
            UPDATE public.master_import_rows SET
                normalized_data = COALESCE(v_row.after_state,'{}'::JSONB),
                operation = 'ERROR',row_status = 'ERROR',
                matched_record_id = v_existing_id,
                errors = jsonb_build_array(jsonb_build_object('code',v_error)),
                before_state = v_existing,after_state = NULL,
                updated_at = clock_timestamp()
            WHERE id = v_row.id;
        ELSE
            UPDATE public.master_import_rows SET
                normalized_data = v_row.after_state - 'id',
                operation = v_operation,row_status = 'VALIDATED',
                matched_record_id = v_existing_id,
                warnings = CASE WHEN v_operation = 'UPDATE'
                    THEN jsonb_build_array(jsonb_build_object(
                        'code','UPDATE_EXISTING_CONFIRMATION_REQUIRED'
                    )) ELSE '[]'::JSONB END,
                errors = '[]'::JSONB,before_state = v_existing,
                after_state = v_row.after_state,
                updated_at = clock_timestamp()
            WHERE id = v_row.id;
        END IF;
    END LOOP;

    -- Duplicate user-facing identities invalidate every involved file row.
    UPDATE public.master_import_rows target SET
        operation = 'ERROR',row_status = 'ERROR',
        errors = target.errors || jsonb_build_array(jsonb_build_object(
            'code','DUPLICATE_IDENTITY_IN_FILE'
        )),after_state = NULL,updated_at = clock_timestamp()
    WHERE target.company_id = v_company AND target.job_id = p_job_id
      AND (
          (
              v_job.import_type = 'CHART_OF_ACCOUNT'
              AND (
                  SELECT count(*) FROM public.master_import_rows candidate
                  WHERE candidate.company_id = v_company
                    AND candidate.job_id = p_job_id
                    AND upper(candidate.normalized_data->>'code') =
                        upper(target.normalized_data->>'code')
              ) > 1
          )
          OR (
              SELECT count(*) FROM public.master_import_rows candidate
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

-- Preserve Phase-33 behavior for the original four types.
ALTER FUNCTION public.commit_master_import_job(UUID,BIGINT,INTEGER)
    RENAME TO commit_master_import_job_phase33;
ALTER FUNCTION public.commit_master_import_job_phase33(UUID,BIGINT,INTEGER)
    SET SCHEMA private;

REVOKE ALL ON FUNCTION
    private.commit_master_import_job_phase33(UUID,BIGINT,INTEGER)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
    private.commit_master_import_job_phase33(UUID,BIGINT,INTEGER)
TO service_role;

CREATE FUNCTION public.commit_master_import_job(
    p_job_id UUID,
    p_master_version BIGINT,
    p_confirm_update_count INTEGER
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
    v_row public.master_import_rows%ROWTYPE;
    v_result JSONB;
    v_record_id UUID;
    v_result_version BIGINT;
    v_parent_id UUID;
    v_error TEXT;
    v_created INTEGER;
    v_updated INTEGER;
    v_skipped INTEGER;
    v_errors INTEGER;
    v_status TEXT;
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

    IF v_job.import_type NOT IN (
        'CUSTOMER_CATEGORY','CHART_OF_ACCOUNT','TRANSACTION_CATEGORY'
    ) THEN
        RETURN private.commit_master_import_job_phase33(
            p_job_id,p_master_version,p_confirm_update_count
        );
    END IF;

    IF p_master_version IS NOT NULL
       AND p_master_version + 1 = v_job.master_version
       AND v_job.status IN ('COMPLETED','COMPLETED_WITH_ERRORS') THEN
        IF p_confirm_update_count IS DISTINCT FROM
           v_job.confirmed_update_count THEN
            RAISE EXCEPTION 'IMPORT_IDEMPOTENCY_CONFLICT';
        END IF;
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
    IF v_job.status <> 'VALIDATED' THEN
        RAISE EXCEPTION 'IMPORT_JOB_NOT_COMMITTABLE';
    END IF;
    IF p_confirm_update_count IS NULL
       OR p_confirm_update_count <> v_job.updated_rows THEN
        RAISE EXCEPTION 'IMPORT_UPDATE_CONFIRMATION_REQUIRED';
    END IF;

    PERFORM pg_advisory_xact_lock(hashtextextended(
        v_company::TEXT || ':MASTER_IMPORT_COMMIT:' || v_job.import_type,0
    ));

    FOR v_row IN
        SELECT * FROM public.master_import_rows r
        WHERE r.company_id = v_company AND r.job_id = p_job_id
          AND r.operation IN ('CREATE','UPDATE','SKIP')
          AND r.row_status = 'VALIDATED'
        ORDER BY r.row_number
        FOR UPDATE
    LOOP
        v_error := NULL;
        v_record_id := v_row.matched_record_id;
        v_result_version := v_row.matched_master_version;

        IF v_row.operation = 'SKIP' THEN
            UPDATE public.master_import_rows SET
                row_status = 'COMMITTED',committed_at = clock_timestamp(),
                updated_at = clock_timestamp()
            WHERE id = v_row.id;
            CONTINUE;
        END IF;

        BEGIN
            IF v_row.operation = 'UPDATE' AND (
                (v_job.import_type = 'CUSTOMER_CATEGORY' AND EXISTS (
                    SELECT 1 FROM public.customer_categories x
                    WHERE x.company_id = v_company
                      AND x.id = v_row.matched_record_id
                      AND x.is_system_category
                ))
                OR (v_job.import_type = 'CHART_OF_ACCOUNT' AND EXISTS (
                    SELECT 1 FROM public.chart_of_accounts x
                    WHERE x.company_id = v_company
                      AND x.id = v_row.matched_record_id
                      AND x.is_system_account
                ))
                OR (v_job.import_type = 'TRANSACTION_CATEGORY' AND EXISTS (
                    SELECT 1 FROM public.transaction_categories x
                    WHERE x.company_id = v_company
                      AND x.id = v_row.matched_record_id
                      AND x.is_system_default
                ))
            ) THEN
                RAISE EXCEPTION 'SYSTEM_MASTER_IMPORT_FORBIDDEN';
            END IF;

            IF v_job.import_type = 'CUSTOMER_CATEGORY' THEN
                v_result := public.save_customer_category(
                    CASE WHEN v_row.operation = 'CREATE'
                        THEN NULL ELSE v_row.matched_record_id END,
                    CASE WHEN v_row.operation = 'CREATE'
                        THEN NULL ELSE v_row.matched_master_version END,
                    v_row.after_state->>'name',
                    (v_row.after_state->>'isActive')::BOOLEAN
                );
                v_record_id := (v_result->>'customerCategoryId')::UUID;

            ELSIF v_job.import_type = 'TRANSACTION_CATEGORY' THEN
                v_result := public.save_transaction_category(
                    CASE WHEN v_row.operation = 'CREATE'
                        THEN NULL ELSE v_row.matched_record_id END,
                    CASE WHEN v_row.operation = 'CREATE'
                        THEN NULL ELSE v_row.matched_master_version END,
                    v_row.after_state->>'name',
                    v_row.after_state->>'systemKey',
                    NULLIF(v_row.after_state->>'description',''),
                    (v_row.after_state->>'isActive')::BOOLEAN
                );
                v_record_id := (v_result->>'categoryId')::UUID;

            ELSE
                v_parent_id := NULL;
                IF NULLIF(
                    v_row.after_state->>'parentAccountCode',''
                ) IS NOT NULL THEN
                    SELECT x.id INTO v_parent_id
                    FROM public.chart_of_accounts x
                    WHERE x.company_id = v_company
                      AND upper(regexp_replace(
                          btrim(x.account_code),'\s+',' ','g'
                      )) = upper(v_row.after_state->>'parentAccountCode');
                    IF v_parent_id IS NULL THEN
                        RAISE EXCEPTION 'PARENT_ACCOUNT_NOT_FOUND_AT_COMMIT';
                    END IF;
                END IF;
                v_result := public.save_chart_of_account(
                    CASE WHEN v_row.operation = 'CREATE'
                        THEN NULL ELSE v_row.matched_record_id END,
                    CASE WHEN v_row.operation = 'CREATE'
                        THEN NULL ELSE v_row.matched_master_version END,
                    v_row.after_state->>'code',
                    v_row.after_state->>'name',
                    v_row.after_state->>'accountType',
                    v_row.after_state->>'normalBalance',
                    v_parent_id,
                    NULLIF(v_row.after_state->>'systemFunctionKey',''),
                    (v_row.after_state->>'isPostable')::BOOLEAN,
                    (v_row.after_state->>'allowManualPosting')::BOOLEAN,
                    (v_row.after_state->>'allowReconciliation')::BOOLEAN,
                    (v_row.after_state->>'isActive')::BOOLEAN
                );
                v_record_id := (v_result->>'accountId')::UUID;
            END IF;
            v_result_version := (v_result->>'masterVersion')::BIGINT;
        EXCEPTION WHEN OTHERS THEN
            v_error := CASE SQLERRM
                WHEN 'MASTER_VERSION_CONFLICT'
                    THEN 'MASTER_CHANGED_AFTER_VALIDATION'
                WHEN 'SYSTEM_CUSTOMER_CATEGORY_IMMUTABLE'
                    THEN 'SYSTEM_MASTER_IMPORT_FORBIDDEN'
                WHEN 'REQUIRED_TRANSACTION_CATEGORY_CANNOT_BE_DISABLED'
                    THEN 'SYSTEM_MASTER_IMPORT_FORBIDDEN'
                WHEN 'REQUIRED_TRANSACTION_CATEGORY_SYSTEM_EVENT_LOCKED'
                    THEN 'SYSTEM_MASTER_IMPORT_FORBIDDEN'
                ELSE CASE
                    WHEN SQLERRM ~ '^[A-Z][A-Z0-9_]+$' THEN SQLERRM
                    ELSE 'MASTER_COMMIT_FAILED'
                END
            END;
        END;

        IF v_error IS NOT NULL THEN
            UPDATE public.master_import_rows SET
                operation = 'ERROR',row_status = 'ERROR',
                errors = errors || jsonb_build_array(
                    jsonb_build_object('code',v_error)
                ),after_state = NULL,updated_at = clock_timestamp()
            WHERE id = v_row.id;
        ELSE
            UPDATE public.master_import_rows SET
                matched_record_id = v_record_id,
                matched_master_version = v_result_version,
                row_status = 'COMMITTED',committed_at = clock_timestamp(),
                after_state = after_state || jsonb_build_object(
                    'id',v_record_id,'masterVersion',v_result_version
                ),updated_at = clock_timestamp()
            WHERE id = v_row.id;
        END IF;
    END LOOP;

    SELECT
        count(*) FILTER(
            WHERE operation = 'CREATE' AND row_status = 'COMMITTED'
        ),
        count(*) FILTER(
            WHERE operation = 'UPDATE' AND row_status = 'COMMITTED'
        ),
        count(*) FILTER(
            WHERE operation = 'SKIP' AND row_status = 'COMMITTED'
        ),
        count(*) FILTER(WHERE row_status = 'ERROR')
    INTO v_created,v_updated,v_skipped,v_errors
    FROM public.master_import_rows
    WHERE company_id = v_company AND job_id = p_job_id;

    v_status := CASE WHEN v_errors > 0
        THEN 'COMPLETED_WITH_ERRORS' ELSE 'COMPLETED' END;

    UPDATE public.master_import_jobs SET
        status = v_status,created_rows = v_created,updated_rows = v_updated,
        skipped_rows = v_skipped,error_rows = v_errors,
        confirmed_update_count = p_confirm_update_count,
        committed_by = v_actor,committed_at = clock_timestamp(),
        master_version = master_version + 1,updated_at = clock_timestamp()
    WHERE company_id = v_company AND id = p_job_id
    RETURNING master_version INTO v_new_version;

    INSERT INTO public.master_import_job_events(
        company_id,job_id,event_type,actor_id,before_state,after_state
    ) VALUES (
        v_company,p_job_id,'COMPLETE',v_actor,
        jsonb_build_object(
            'status',v_job.status,'masterVersion',v_job.master_version,
            'previewUpdateCount',v_job.updated_rows
        ),
        jsonb_build_object(
            'status',v_status,'masterVersion',v_new_version,
            'createCount',v_created,'updateCount',v_updated,
            'skipCount',v_skipped,'errorCount',v_errors,
            'confirmedUpdateCount',p_confirm_update_count
        )
    );

    RETURN jsonb_build_object(
        'jobId',p_job_id,'masterVersion',v_new_version,'status',v_status,
        'createCount',v_created,'updateCount',v_updated,
        'skipCount',v_skipped,'errorCount',v_errors,'action','COMMIT'
    );
END;
$$;

REVOKE ALL ON FUNCTION public.commit_master_import_job(
    UUID,BIGINT,INTEGER
) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.commit_master_import_job(
    UUID,BIGINT,INTEGER
) TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES (
    '20260727090000',
    'g2_phase40_remaining_simple_master_import',
    'Additive guarded staging validation and partial commit for Customer Category, COA, and Transaction Category; system rows export-only; COA business code retained; original four import types remain compatible'
);

COMMIT;

-- Rollback/forward-fix note:
-- - a failed migration rolls back atomically;
-- - after apply, use a forward fix and never edit this migration;
-- - UI exposure remains a later gate after postflight/behavioral tests pass.
