-- KGS POS G2 phase 44: guarded Product-Supplier fixed CSV import.
-- Requirement: MST-005
-- Dependency: grouped Product Import and its COMPLETE-event forward fix.
--
-- One row represents one Product-Supplier relation. Product, Supplier, and
-- purchase UOM are existing active tenant masters. The importer never creates
-- those references, never changes stock, and never writes last purchase price.

BEGIN;

DO $migration_guard$
BEGIN
    IF (
        SELECT count(DISTINCT version)
        FROM private.kgs_schema_migrations
        WHERE version IN ('20260727130000','20260727140000')
    ) <> 2 THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: phase 42 and its forward fix are required';
    END IF;
    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260727160000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260727160000';
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
        'CUSTOMER_CATEGORY','CHART_OF_ACCOUNT','TRANSACTION_CATEGORY',
        'PRODUCT','PRODUCT_SUPPLIER'
    ));

-- Keep the public signature and all reviewed Phase-42 behavior stable.
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
        'CUSTOMER_CATEGORY','CHART_OF_ACCOUNT','TRANSACTION_CATEGORY',
        'PRODUCT','PRODUCT_SUPPLIER'
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
END
$$;

REVOKE ALL ON FUNCTION public.create_master_import_job(
    UUID,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT
) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.create_master_import_job(
    UUID,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT
) TO authenticated,service_role;

-- Phase-32 only enriches simple-master rows. The complete Product-Supplier
-- preview is produced below and must pass through that trigger unchanged.
DO $extend_phase32_dispatch$
DECLARE
    v_oid OID := to_regprocedure(
        'private.trg_g2_validate_import_business_fields()'
    );
    v_definition TEXT;
    v_old TEXT := '''TRANSACTION_CATEGORY'',''PRODUCT'') THEN';
    v_new TEXT :=
        '''TRANSACTION_CATEGORY'',''PRODUCT'',''PRODUCT_SUPPLIER'') THEN';
BEGIN
    IF v_oid IS NULL THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: phase 32 trigger missing';
    END IF;
    SELECT pg_get_functiondef(v_oid) INTO v_definition;
    IF strpos(v_definition,v_old) = 0 THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: phase 32 dispatch changed';
    END IF;
    IF (
        length(v_definition) - length(replace(v_definition,v_old,''))
    ) / length(v_old) <> 1 THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: phase 32 dispatch ambiguous';
    END IF;
    EXECUTE replace(v_definition,v_old,v_new);
END
$extend_phase32_dispatch$;

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
    ELSIF v_import_type = 'PRODUCT' THEN
        SELECT x.master_version INTO v_master_version
        FROM public.products x
        WHERE x.company_id = NEW.company_id AND x.id = NEW.matched_record_id;
    ELSIF v_import_type = 'PRODUCT_SUPPLIER' THEN
        SELECT x.master_version INTO v_master_version
        FROM public.product_suppliers x
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

CREATE FUNCTION private.g2_phase44_import_error(
    p_code TEXT,
    p_message TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE sql
IMMUTABLE
SET search_path = public, pg_temp
AS $$
    SELECT jsonb_build_array(
        jsonb_strip_nulls(jsonb_build_object(
            'code',p_code,
            'message',NULLIF(p_message,'')
        ))
    )
$$;

REVOKE ALL ON FUNCTION private.g2_phase44_import_error(TEXT,TEXT)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.g2_phase44_import_error(TEXT,TEXT)
TO service_role;

-- Preserve the complete Phase-42 public dispatcher for all existing types.
ALTER FUNCTION public.validate_master_import_job(UUID,BIGINT)
    RENAME TO validate_master_import_job_phase42;
ALTER FUNCTION public.validate_master_import_job_phase42(UUID,BIGINT)
    SET SCHEMA private;

REVOKE ALL ON FUNCTION
    private.validate_master_import_job_phase42(UUID,BIGINT)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
    private.validate_master_import_job_phase42(UUID,BIGINT)
TO service_role;

CREATE FUNCTION private.validate_master_import_product_supplier_job(
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
    v_source JSONB;
    v_column TEXT;
    v_product_sku TEXT;
    v_supplier_name TEXT;
    v_uom_name TEXT;
    v_supplier_product_code TEXT;
    v_internal_text TEXT;
    v_internal_id UUID;
    v_product_id UUID;
    v_supplier_id UUID;
    v_purchase_uom_id UUID;
    v_existing_id UUID;
    v_existing public.product_suppliers%ROWTYPE;
    v_reference_price NUMERIC;
    v_is_preferred BOOLEAN;
    v_is_active BOOLEAN;
    v_match_count BIGINT;
    v_errors JSONB;
    v_before JSONB;
    v_after JSONB;
    v_operation TEXT;
    v_created INTEGER;
    v_updated INTEGER;
    v_skipped INTEGER;
    v_error_rows INTEGER;
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
    IF v_job.import_type <> 'PRODUCT_SUPPLIER' THEN
        RAISE EXCEPTION 'INVALID_PRODUCT_SUPPLIER_IMPORT_JOB';
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

    FOREACH v_column IN ARRAY ARRAY[
        'productSku','supplierName','purchaseUomName',
        'supplierProductCode','referencePurchasePrice',
        'isPreferredSupplier','isActive'
    ] LOOP
        IF NULLIF(btrim(v_job.mapping->>v_column),'') IS NULL THEN
            RAISE EXCEPTION
                'IMPORT_PRODUCT_SUPPLIER_MAPPING_REQUIRED: %',v_column;
        END IF;
    END LOOP;
    IF v_job.reference_mode = 'REFERENCE_BY_ID'
       AND NULLIF(btrim(v_job.mapping->>'internalId'),'') IS NULL THEN
        RAISE EXCEPTION 'IMPORT_INTERNAL_ID_MAPPING_REQUIRED';
    END IF;

    UPDATE public.master_import_rows SET
        normalized_data = NULL,operation = 'PENDING',row_status = 'STAGED',
        matched_record_id = NULL,matched_master_version = NULL,
        warnings = '[]'::JSONB,errors = '[]'::JSONB,
        before_state = NULL,after_state = NULL,committed_at = NULL,
        updated_at = clock_timestamp()
    WHERE company_id = v_company AND job_id = p_job_id;

    FOR v_row IN
        SELECT * FROM public.master_import_rows r
        WHERE r.company_id = v_company AND r.job_id = p_job_id
        ORDER BY r.row_number
        FOR UPDATE
    LOOP
        v_source := v_row.source_data;
        v_errors := '[]'::JSONB;
        v_product_id := NULL;
        v_supplier_id := NULL;
        v_purchase_uom_id := NULL;
        v_internal_id := NULL;
        v_internal_text := NULL;
        v_existing_id := NULL;
        v_before := NULL;
        v_after := NULL;

        v_product_sku := upper(regexp_replace(btrim(COALESCE(
            v_source->>(v_job.mapping->>'productSku'),''
        )),'\s+',' ','g'));
        v_supplier_name := regexp_replace(btrim(COALESCE(
            v_source->>(v_job.mapping->>'supplierName'),''
        )),'\s+',' ','g');
        v_uom_name := regexp_replace(btrim(COALESCE(
            v_source->>(v_job.mapping->>'purchaseUomName'),''
        )),'\s+',' ','g');
        v_supplier_product_code := NULLIF(regexp_replace(btrim(COALESCE(
            v_source->>(v_job.mapping->>'supplierProductCode'),''
        )),'\s+',' ','g'),'');

        IF v_product_sku = '' OR char_length(v_product_sku) > 100 THEN
            v_errors := v_errors ||
                private.g2_phase44_import_error('INVALID_PRODUCT_SKU');
        END IF;
        IF v_supplier_name = '' OR char_length(v_supplier_name) > 200 THEN
            v_errors := v_errors ||
                private.g2_phase44_import_error('INVALID_SUPPLIER_NAME');
        END IF;
        IF v_uom_name = '' OR char_length(v_uom_name) > 200 THEN
            v_errors := v_errors ||
                private.g2_phase44_import_error('INVALID_PURCHASE_UOM_NAME');
        END IF;
        IF v_supplier_product_code IS NOT NULL
           AND char_length(v_supplier_product_code) > 200 THEN
            v_errors := v_errors ||
                private.g2_phase44_import_error(
                    'SUPPLIER_PRODUCT_CODE_TOO_LONG'
                );
        END IF;

        BEGIN
            v_reference_price := NULLIF(btrim(COALESCE(
                v_source->>(v_job.mapping->>'referencePurchasePrice'),''
            )),'')::NUMERIC;
            v_is_preferred := private.g2_phase40_import_boolean(
                v_source->>(v_job.mapping->>'isPreferredSupplier'),FALSE
            );
            v_is_active := private.g2_phase40_import_boolean(
                v_source->>(v_job.mapping->>'isActive'),TRUE
            );
        EXCEPTION WHEN OTHERS THEN
            v_errors := v_errors ||
                private.g2_phase44_import_error(
                    'INVALID_PRODUCT_SUPPLIER_VALUE',SQLERRM
                );
            v_reference_price := NULL;
            v_is_preferred := FALSE;
            v_is_active := TRUE;
        END;
        IF v_reference_price IS NOT NULL AND v_reference_price < 0 THEN
            v_errors := v_errors ||
                private.g2_phase44_import_error(
                    'REFERENCE_PURCHASE_PRICE_NEGATIVE'
                );
        END IF;
        IF v_is_preferred AND NOT v_is_active THEN
            v_errors := v_errors ||
                private.g2_phase44_import_error(
                    'PREFERRED_SUPPLIER_MUST_BE_ACTIVE'
                );
        END IF;

        SELECT count(*),min(p.id::TEXT)::UUID
        INTO v_match_count,v_product_id
        FROM public.products p
        WHERE p.company_id = v_company
          AND p.is_active
          AND NOT p.is_bundle
          AND upper(regexp_replace(btrim(p.sku),'\s+',' ','g')) =
              v_product_sku;
        IF v_match_count = 0 THEN
            v_errors := v_errors ||
                private.g2_phase44_import_error(
                    'ACTIVE_STOCK_PRODUCT_NOT_FOUND'
                );
        ELSIF v_match_count > 1 THEN
            v_errors := v_errors ||
                private.g2_phase44_import_error(
                    'AMBIGUOUS_PRODUCT_REFERENCE'
                );
            v_product_id := NULL;
        END IF;

        SELECT count(*),min(s.id::TEXT)::UUID
        INTO v_match_count,v_supplier_id
        FROM public.suppliers s
        WHERE s.company_id = v_company
          AND s.is_active
          AND lower(regexp_replace(
              btrim(s.supplier_name),'\s+',' ','g'
          )) = lower(v_supplier_name);
        IF v_match_count = 0 THEN
            v_errors := v_errors ||
                private.g2_phase44_import_error(
                    'ACTIVE_SUPPLIER_NOT_FOUND'
                );
        ELSIF v_match_count > 1 THEN
            v_errors := v_errors ||
                private.g2_phase44_import_error(
                    'AMBIGUOUS_SUPPLIER_REFERENCE'
                );
            v_supplier_id := NULL;
        END IF;

        IF v_product_id IS NOT NULL THEN
            SELECT count(*),min(pu.uom_id::TEXT)::UUID
            INTO v_match_count,v_purchase_uom_id
            FROM public.product_uoms pu
            JOIN public.uoms u
              ON u.company_id = pu.company_id AND u.id = pu.uom_id
            WHERE pu.company_id = v_company
              AND pu.product_id = v_product_id
              AND pu.is_active
              AND pu.purchase_allowed
              AND u.is_active
              AND lower(regexp_replace(
                  btrim(u.name),'\s+',' ','g'
              )) = lower(v_uom_name);
            IF v_match_count = 0 THEN
                v_errors := v_errors ||
                    private.g2_phase44_import_error(
                        'ACTIVE_PURCHASE_PRODUCT_UOM_NOT_FOUND'
                    );
            ELSIF v_match_count > 1 THEN
                v_errors := v_errors ||
                    private.g2_phase44_import_error(
                        'AMBIGUOUS_PURCHASE_UOM_REFERENCE'
                    );
                v_purchase_uom_id := NULL;
            END IF;
        END IF;

        IF v_job.reference_mode = 'REFERENCE_BY_ID' THEN
            v_internal_text := NULLIF(btrim(COALESCE(
                v_source->>(v_job.mapping->>'internalId'),''
            )),'');
            IF v_internal_text IS NOT NULL THEN
                BEGIN
                    v_internal_id := v_internal_text::UUID;
                    SELECT ps.id INTO v_existing_id
                    FROM public.product_suppliers ps
                    WHERE ps.company_id = v_company
                      AND ps.id = v_internal_id;
                    IF NOT FOUND THEN
                        v_errors := v_errors ||
                            private.g2_phase44_import_error(
                                'PRODUCT_SUPPLIER_ID_NOT_FOUND'
                            );
                    END IF;
                EXCEPTION WHEN invalid_text_representation THEN
                    v_errors := v_errors ||
                        private.g2_phase44_import_error(
                            'INVALID_INTERNAL_ID'
                        );
                END;
            END IF;
        END IF;

        IF v_existing_id IS NULL
           AND v_product_id IS NOT NULL
           AND v_supplier_id IS NOT NULL THEN
            SELECT ps.id INTO v_existing_id
            FROM public.product_suppliers ps
            WHERE ps.company_id = v_company
              AND ps.product_id = v_product_id
              AND ps.supplier_id = v_supplier_id;
        END IF;
        IF v_job.reference_mode = 'REFERENCE_BY_ID'
           AND v_internal_text IS NULL
           AND v_existing_id IS NOT NULL THEN
            v_errors := v_errors ||
                private.g2_phase44_import_error(
                    'IMPORT_INTERNAL_ID_REQUIRED_FOR_UPDATE'
                );
        END IF;

        IF jsonb_array_length(v_errors) = 0 THEN
            IF v_existing_id IS NULL THEN
                v_operation := 'CREATE';
                IF v_job.operation_mode = 'UPDATE_ONLY' THEN
                    v_errors := v_errors ||
                        private.g2_phase44_import_error(
                            'IMPORT_UPDATE_TARGET_NOT_FOUND'
                        );
                END IF;
            ELSE
                v_operation := 'UPDATE';
                IF v_job.operation_mode = 'CREATE_ONLY' THEN
                    v_errors := v_errors ||
                        private.g2_phase44_import_error(
                            'IMPORT_CREATE_ONLY_MATCHED_EXISTING'
                        );
                END IF;
            END IF;
        ELSE
            v_operation := 'ERROR';
        END IF;

        v_after := jsonb_strip_nulls(jsonb_build_object(
            'productId',v_product_id,
            'supplierId',v_supplier_id,
            'purchaseUomId',v_purchase_uom_id,
            'supplierProductCode',v_supplier_product_code,
            'referencePurchasePrice',v_reference_price,
            'isPreferredSupplier',v_is_preferred,
            'isActive',v_is_active
        ));

        IF v_existing_id IS NOT NULL THEN
            SELECT * INTO v_existing
            FROM public.product_suppliers ps
            WHERE ps.company_id = v_company AND ps.id = v_existing_id;
            IF v_job.reference_mode = 'REFERENCE_BY_ID'
               AND v_internal_text IS NOT NULL
               AND (
                   v_existing.product_id IS DISTINCT FROM v_product_id
                   OR v_existing.supplier_id IS DISTINCT FROM v_supplier_id
               ) THEN
                v_errors := v_errors ||
                    private.g2_phase44_import_error(
                        'PRODUCT_SUPPLIER_IDENTITY_MISMATCH'
                    );
            END IF;
            v_before := jsonb_strip_nulls(jsonb_build_object(
                'productSupplierId',v_existing.id,
                'masterVersion',v_existing.master_version,
                'productId',v_existing.product_id,
                'supplierId',v_existing.supplier_id,
                'purchaseUomId',v_existing.purchase_uom_id,
                'supplierProductCode',v_existing.supplier_product_code,
                'referencePurchasePrice',v_existing.reference_purchase_price,
                'isPreferredSupplier',v_existing.is_preferred_supplier,
                'isActive',v_existing.is_active
            ));
            IF (v_before - 'productSupplierId' - 'masterVersion') = v_after
               AND jsonb_array_length(v_errors) = 0 THEN
                v_operation := 'SKIP';
            END IF;
        END IF;

        UPDATE public.master_import_rows SET
            group_key = COALESCE(
                v_product_id::TEXT || ':' || v_supplier_id::TEXT,
                'ROW:' || v_row.row_number
            ),
            normalized_data = jsonb_strip_nulls(jsonb_build_object(
                'productSku',v_product_sku,
                'supplierName',v_supplier_name,
                'purchaseUomName',v_uom_name,
                'productId',v_product_id,
                'supplierId',v_supplier_id,
                'purchaseUomId',v_purchase_uom_id
            )),
            operation = CASE
                WHEN jsonb_array_length(v_errors) > 0 THEN 'ERROR'
                ELSE v_operation
            END,
            row_status = CASE
                WHEN jsonb_array_length(v_errors) > 0 THEN 'ERROR'
                ELSE 'VALIDATED'
            END,
            matched_record_id = CASE
                WHEN jsonb_array_length(v_errors) > 0 THEN NULL
                ELSE v_existing_id
            END,
            warnings = CASE
                WHEN v_operation = 'UPDATE'
                     AND jsonb_array_length(v_errors) = 0
                THEN jsonb_build_array(jsonb_build_object(
                    'code','IMPORT_WILL_UPDATE_EXISTING'
                ))
                ELSE '[]'::JSONB
            END,
            errors = v_errors,
            before_state = CASE
                WHEN jsonb_array_length(v_errors) > 0 THEN NULL
                ELSE v_before
            END,
            after_state = CASE
                WHEN jsonb_array_length(v_errors) > 0 THEN NULL
                ELSE v_after
            END,
            updated_at = clock_timestamp()
        WHERE company_id = v_company AND job_id = p_job_id
          AND id = v_row.id;
    END LOOP;

    -- One relation identity may occur only once in a file.
    UPDATE public.master_import_rows target SET
        operation = 'ERROR',row_status = 'ERROR',
        errors = target.errors ||
            private.g2_phase44_import_error(
                'DUPLICATE_PRODUCT_SUPPLIER_IN_FILE'
            ),
        matched_record_id = NULL,matched_master_version = NULL,
        before_state = NULL,after_state = NULL,
        updated_at = clock_timestamp()
    WHERE target.company_id = v_company AND target.job_id = p_job_id
      AND target.group_key IN (
          SELECT r.group_key
          FROM public.master_import_rows r
          WHERE r.company_id = v_company AND r.job_id = p_job_id
            AND r.row_status = 'VALIDATED'
          GROUP BY r.group_key
          HAVING count(*) > 1
      );

    -- Validate the final preferred state, including existing relations omitted
    -- from this file. This permits an explicit old=false/new=true switch.
    WITH candidate_products AS (
        SELECT DISTINCT (r.after_state->>'productId')::UUID AS product_id
        FROM public.master_import_rows r
        WHERE r.company_id = v_company AND r.job_id = p_job_id
          AND r.row_status = 'VALIDATED'
    ), bad_products AS (
        SELECT cp.product_id
        FROM candidate_products cp
        WHERE (
            SELECT count(*)
            FROM public.product_suppliers ps
            WHERE ps.company_id = v_company
              AND ps.product_id = cp.product_id
              AND ps.is_active AND ps.is_preferred_supplier
              AND NOT EXISTS (
                  SELECT 1 FROM public.master_import_rows r
                  WHERE r.company_id = v_company AND r.job_id = p_job_id
                    AND r.row_status = 'VALIDATED'
                    AND (
                        r.matched_record_id = ps.id
                        OR (
                            (r.after_state->>'productId')::UUID =
                                ps.product_id
                            AND (r.after_state->>'supplierId')::UUID =
                                ps.supplier_id
                        )
                    )
              )
        ) + (
            SELECT count(*)
            FROM public.master_import_rows r
            WHERE r.company_id = v_company AND r.job_id = p_job_id
              AND r.row_status = 'VALIDATED'
              AND (r.after_state->>'productId')::UUID = cp.product_id
              AND (r.after_state->>'isActive')::BOOLEAN
              AND (r.after_state->>'isPreferredSupplier')::BOOLEAN
        ) > 1
    )
    UPDATE public.master_import_rows target SET
        operation = 'ERROR',row_status = 'ERROR',
        errors = target.errors ||
            private.g2_phase44_import_error(
                'MULTIPLE_ACTIVE_PREFERRED_SUPPLIER'
            ),
        matched_record_id = NULL,matched_master_version = NULL,
        before_state = NULL,after_state = NULL,
        updated_at = clock_timestamp()
    WHERE target.company_id = v_company AND target.job_id = p_job_id
      AND target.row_status = 'VALIDATED'
      AND (target.after_state->>'productId')::UUID IN (
          SELECT product_id FROM bad_products
      );

    SELECT
        count(*) FILTER (WHERE operation = 'CREATE'),
        count(*) FILTER (WHERE operation = 'UPDATE'),
        count(*) FILTER (WHERE operation = 'SKIP'),
        count(*) FILTER (WHERE operation = 'ERROR')
    INTO v_created,v_updated,v_skipped,v_error_rows
    FROM public.master_import_rows
    WHERE company_id = v_company AND job_id = p_job_id;

    UPDATE public.master_import_jobs SET
        status = 'VALIDATED',
        created_rows = COALESCE(v_created,0),
        updated_rows = COALESCE(v_updated,0),
        skipped_rows = COALESCE(v_skipped,0),
        error_rows = COALESCE(v_error_rows,0),
        confirmed_update_count = 0,
        validated_by = v_actor,validated_at = clock_timestamp(),
        master_version = master_version + 1,
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
            'createCount',COALESCE(v_created,0),
            'updateCount',COALESCE(v_updated,0),
            'skipCount',COALESCE(v_skipped,0),
            'errorCount',COALESCE(v_error_rows,0)
        )
    );
    RETURN jsonb_build_object(
        'jobId',p_job_id,'masterVersion',v_new_version,
        'status','VALIDATED',
        'createCount',COALESCE(v_created,0),
        'updateCount',COALESCE(v_updated,0),
        'skipCount',COALESCE(v_skipped,0),
        'errorCount',COALESCE(v_error_rows,0),
        'action','VALIDATE'
    );
END;
$$;

REVOKE ALL ON FUNCTION
    private.validate_master_import_product_supplier_job(UUID,BIGINT)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
    private.validate_master_import_product_supplier_job(UUID,BIGINT)
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
    v_company UUID := public.private_active_company_id();
    v_import_type TEXT;
BEGIN
    SELECT j.import_type INTO v_import_type
    FROM public.master_import_jobs j
    WHERE j.company_id = v_company AND j.id = p_job_id;
    IF v_import_type = 'PRODUCT_SUPPLIER' THEN
        RETURN private.validate_master_import_product_supplier_job(
            p_job_id,p_master_version
        );
    END IF;
    RETURN private.validate_master_import_job_phase42(
        p_job_id,p_master_version
    );
END;
$$;

REVOKE ALL ON FUNCTION public.validate_master_import_job(UUID,BIGINT)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.validate_master_import_job(UUID,BIGINT)
TO authenticated,service_role;

-- Preserve the complete Phase-42 public commit dispatcher.
ALTER FUNCTION public.commit_master_import_job(UUID,BIGINT,INTEGER)
    RENAME TO commit_master_import_job_phase42;
ALTER FUNCTION public.commit_master_import_job_phase42(UUID,BIGINT,INTEGER)
    SET SCHEMA private;

REVOKE ALL ON FUNCTION
    private.commit_master_import_job_phase42(UUID,BIGINT,INTEGER)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
    private.commit_master_import_job_phase42(UUID,BIGINT,INTEGER)
TO service_role;

CREATE FUNCTION private.commit_master_import_product_supplier_job(
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
    v_after JSONB;
    v_result JSONB;
    v_record_id UUID;
    v_result_version BIGINT;
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
    IF v_job.import_type <> 'PRODUCT_SUPPLIER' THEN
        RAISE EXCEPTION 'INVALID_PRODUCT_SUPPLIER_IMPORT_JOB';
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
        v_company::TEXT || ':MASTER_IMPORT_COMMIT:PRODUCT_SUPPLIER',0
    ));

    -- Preferred-off rows are committed first so an explicit preferred switch
    -- does not transiently violate the one-active-preferred unique index.
    FOR v_row IN
        SELECT * FROM public.master_import_rows r
        WHERE r.company_id = v_company AND r.job_id = p_job_id
          AND r.operation IN ('CREATE','UPDATE','SKIP')
          AND r.row_status = 'VALIDATED'
        ORDER BY
            CASE
                WHEN COALESCE(
                    (r.after_state->>'isPreferredSupplier')::BOOLEAN,FALSE
                ) THEN 2 ELSE 1
            END,
            r.row_number
        FOR UPDATE
    LOOP
        IF v_row.operation = 'SKIP' THEN
            UPDATE public.master_import_rows SET
                row_status = 'COMMITTED',committed_at = clock_timestamp(),
                updated_at = clock_timestamp()
            WHERE company_id = v_company AND job_id = p_job_id
              AND id = v_row.id;
            CONTINUE;
        END IF;

        BEGIN
            v_after := v_row.after_state;
            IF v_row.operation = 'UPDATE' AND NOT EXISTS (
                SELECT 1 FROM public.product_suppliers ps
                WHERE ps.company_id = v_company
                  AND ps.id = v_row.matched_record_id
                  AND ps.master_version = v_row.matched_master_version
            ) THEN
                RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
            END IF;

            v_result := public.save_product_supplier(
                CASE WHEN v_row.operation = 'CREATE'
                    THEN NULL ELSE v_row.matched_record_id END,
                CASE WHEN v_row.operation = 'CREATE'
                    THEN NULL ELSE v_row.matched_master_version END,
                (v_after->>'productId')::UUID,
                (v_after->>'supplierId')::UUID,
                (v_after->>'purchaseUomId')::UUID,
                NULLIF(v_after->>'supplierProductCode',''),
                NULLIF(v_after->>'referencePurchasePrice','')::NUMERIC,
                (v_after->>'isPreferredSupplier')::BOOLEAN,
                (v_after->>'isActive')::BOOLEAN
            );
            v_record_id := (v_result->>'productSupplierId')::UUID;
            v_result_version := (v_result->>'masterVersion')::BIGINT;

            UPDATE public.master_import_rows SET
                row_status = 'COMMITTED',
                matched_record_id = v_record_id,
                matched_master_version = v_result_version,
                after_state = after_state || jsonb_build_object(
                    'productSupplierId',v_record_id,
                    'masterVersion',v_result_version
                ),
                committed_at = clock_timestamp(),
                updated_at = clock_timestamp()
            WHERE company_id = v_company AND job_id = p_job_id
              AND id = v_row.id;
        EXCEPTION WHEN OTHERS THEN
            v_error := SQLERRM;
            UPDATE public.master_import_rows SET
                operation = 'ERROR',row_status = 'ERROR',
                errors = errors || private.g2_phase44_import_error(
                    'PRODUCT_SUPPLIER_COMMIT_FAILED',v_error
                ),
                committed_at = NULL,updated_at = clock_timestamp()
            WHERE company_id = v_company AND job_id = p_job_id
              AND id = v_row.id;
        END;
    END LOOP;

    SELECT
        count(*) FILTER (
            WHERE operation = 'CREATE' AND row_status = 'COMMITTED'
        ),
        count(*) FILTER (
            WHERE operation = 'UPDATE' AND row_status = 'COMMITTED'
        ),
        count(*) FILTER (
            WHERE operation = 'SKIP' AND row_status = 'COMMITTED'
        ),
        count(*) FILTER (WHERE row_status = 'ERROR')
    INTO v_created,v_updated,v_skipped,v_errors
    FROM public.master_import_rows
    WHERE company_id = v_company AND job_id = p_job_id;

    v_status := CASE
        WHEN COALESCE(v_errors,0) > 0 THEN 'COMPLETED_WITH_ERRORS'
        ELSE 'COMPLETED'
    END;

    UPDATE public.master_import_jobs SET
        status = v_status,
        created_rows = COALESCE(v_created,0),
        updated_rows = COALESCE(v_updated,0),
        skipped_rows = COALESCE(v_skipped,0),
        error_rows = COALESCE(v_errors,0),
        confirmed_update_count = p_confirm_update_count,
        committed_by = v_actor,committed_at = clock_timestamp(),
        master_version = master_version + 1,
        updated_at = clock_timestamp()
    WHERE company_id = v_company AND id = p_job_id
    RETURNING master_version INTO v_new_version;

    INSERT INTO public.master_import_job_events(
        company_id,job_id,event_type,actor_id,before_state,after_state
    ) VALUES (
        v_company,p_job_id,'COMPLETE',v_actor,
        jsonb_build_object(
            'status',v_job.status,'masterVersion',v_job.master_version
        ),
        jsonb_build_object(
            'status',v_status,'masterVersion',v_new_version,
            'createCount',COALESCE(v_created,0),
            'updateCount',COALESCE(v_updated,0),
            'skipCount',COALESCE(v_skipped,0),
            'errorCount',COALESCE(v_errors,0)
        )
    );
    RETURN jsonb_build_object(
        'jobId',p_job_id,'masterVersion',v_new_version,'status',v_status,
        'createCount',COALESCE(v_created,0),
        'updateCount',COALESCE(v_updated,0),
        'skipCount',COALESCE(v_skipped,0),
        'errorCount',COALESCE(v_errors,0),'action','COMMIT'
    );
END;
$$;

REVOKE ALL ON FUNCTION
    private.commit_master_import_product_supplier_job(UUID,BIGINT,INTEGER)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
    private.commit_master_import_product_supplier_job(UUID,BIGINT,INTEGER)
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
    v_company UUID := public.private_active_company_id();
    v_import_type TEXT;
BEGIN
    SELECT j.import_type INTO v_import_type
    FROM public.master_import_jobs j
    WHERE j.company_id = v_company AND j.id = p_job_id;
    IF v_import_type = 'PRODUCT_SUPPLIER' THEN
        RETURN private.commit_master_import_product_supplier_job(
            p_job_id,p_master_version,p_confirm_update_count
        );
    END IF;
    RETURN private.commit_master_import_job_phase42(
        p_job_id,p_master_version,p_confirm_update_count
    );
END;
$$;

REVOKE ALL ON FUNCTION
    public.commit_master_import_job(UUID,BIGINT,INTEGER)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION
    public.commit_master_import_job(UUID,BIGINT,INTEGER)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES (
    '20260727160000',
    'g2_phase44_product_supplier_import',
    'MST-005 guarded Product-Supplier fixed import with active reference resolution, preferred uniqueness, optimistic partial commit, and no stock mutation'
);

COMMIT;
