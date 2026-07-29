-- KGS POS G2 phase 42: grouped Product + Product-UOM guarded import.
-- Requirement: MST-005
-- Dependency: phase 40 database import plus UUID forward fix 20260727100000.
--
-- One CSV row represents one Product-UOM. Rows sharing product_key are
-- validated and committed as one atomic Product group.
--
-- BOUNDARIES:
-- - referenced Category, UOM, and Tax Rule must already exist and be active;
-- - Product import never creates stock, Opening Stock, or another master;
-- - Bundle Product remains export-only until the G3 bundle contract;
-- - after transaction history, SKU/Base UOM/UOM structure/factors are locked;
-- - every write delegates to save_product_with_uoms(...), never direct DML.

BEGIN;

DO $migration_guard$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260727100000'
    ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: phase 40 UUID fix is required';
    END IF;
    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260727130000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260727130000';
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
        'PRODUCT'
    ));

-- Keep the public signature and reviewed Phase-40 behavior stable. Replacing
-- the complete body is intentional: pg_get_functiondef formatting is not a
-- stable migration contract across PostgreSQL/Supabase versions.
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
        'PRODUCT'
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

-- Phase-32 validation is for its original simple masters. Product preview is
-- complete below and must not be rewritten by that row trigger.
DO $extend_phase32_dispatch$
DECLARE
    v_oid OID := to_regprocedure(
        'private.trg_g2_validate_import_business_fields()'
    );
    v_definition TEXT;
    v_old TEXT := '''TRANSACTION_CATEGORY'') THEN';
    v_new TEXT := '''TRANSACTION_CATEGORY'',''PRODUCT'') THEN';
BEGIN
    IF v_oid IS NULL THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: phase 32 trigger missing';
    END IF;
    SELECT pg_get_functiondef(v_oid) INTO v_definition;
    IF strpos(v_definition,v_old) = 0 THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: phase 32 trigger contract changed';
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
    END IF;

    NEW.matched_master_version := v_master_version;
    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION private.trg_g2_capture_import_master_version()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.trg_g2_capture_import_master_version()
TO service_role;

CREATE FUNCTION private.g2_phase42_normalized_name(p_value TEXT)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
SET search_path = public, pg_temp
AS $$
    SELECT lower(regexp_replace(btrim(COALESCE(p_value,'')),'\s+',' ','g'))
$$;

CREATE FUNCTION private.g2_phase42_product_import_error(
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

REVOKE ALL ON FUNCTION private.g2_phase42_normalized_name(TEXT)
FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION private.g2_phase42_product_import_error(TEXT,TEXT)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.g2_phase42_normalized_name(TEXT),
    private.g2_phase42_product_import_error(TEXT,TEXT)
TO service_role;

-- Preserve the complete Phase-40 implementation for every existing type.
ALTER FUNCTION public.validate_master_import_job(UUID,BIGINT)
    RENAME TO validate_master_import_job_phase40;
ALTER FUNCTION public.validate_master_import_job_phase40(UUID,BIGINT)
    SET SCHEMA private;

REVOKE ALL ON FUNCTION
    private.validate_master_import_job_phase40(UUID,BIGINT)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
    private.validate_master_import_job_phase40(UUID,BIGINT)
TO service_role;

CREATE FUNCTION private.validate_master_import_product_job(
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
    v_group RECORD;
    v_source JSONB;
    v_normalized JSONB;
    v_errors JSONB;
    v_column TEXT;
    v_product_key TEXT;
    v_sku TEXT;
    v_name TEXT;
    v_category_name TEXT;
    v_uom_name TEXT;
    v_image_url TEXT;
    v_sales_tax_name TEXT;
    v_purchase_tax_name TEXT;
    v_barcode TEXT;
    v_internal_text TEXT;
    v_internal_id UUID;
    v_category_id UUID;
    v_uom_id UUID;
    v_sales_tax_id UUID;
    v_purchase_tax_id UUID;
    v_factor NUMERIC;
    v_purchase_price NUMERIC;
    v_sale_price NUMERIC;
    v_weight NUMERIC;
    v_purchase_allowed BOOLEAN;
    v_sales_allowed BOOLEAN;
    v_is_active BOOLEAN;
    v_match_count BIGINT;
    v_existing public.products%ROWTYPE;
    v_existing_id UUID;
    v_first JSONB;
    v_uoms JSONB;
    v_before JSONB;
    v_after JSONB;
    v_existing_uoms JSONB;
    v_base_uom_id UUID;
    v_weight_uom_id UUID;
    v_operation TEXT;
    v_has_history BOOLEAN;
    v_group_error TEXT;
    v_created INTEGER;
    v_updated INTEGER;
    v_skipped INTEGER;
    v_error_groups INTEGER;
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
    IF v_job.import_type <> 'PRODUCT' THEN
        RAISE EXCEPTION 'INVALID_PRODUCT_IMPORT_JOB';
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
        'productKey','sku','productName','categoryName','uomName',
        'factorToBase','purchaseAllowed','salesAllowed','purchasePrice',
        'salePrice','weightPerLargestUomKg'
    ] LOOP
        IF NULLIF(btrim(v_job.mapping->>v_column),'') IS NULL THEN
            RAISE EXCEPTION 'IMPORT_PRODUCT_MAPPING_REQUIRED: %',v_column;
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

    -- Parse and resolve every row first. Group rules are evaluated afterward.
    FOR v_row IN
        SELECT * FROM public.master_import_rows r
        WHERE r.company_id = v_company AND r.job_id = p_job_id
        ORDER BY r.row_number
        FOR UPDATE
    LOOP
        v_source := v_row.source_data;
        v_errors := '[]'::JSONB;
        v_category_id := NULL;
        v_uom_id := NULL;
        v_sales_tax_id := NULL;
        v_purchase_tax_id := NULL;
        v_internal_id := NULL;

        v_product_key := btrim(COALESCE(
            v_source->>(v_job.mapping->>'productKey'),''
        ));
        v_sku := upper(regexp_replace(btrim(COALESCE(
            v_source->>(v_job.mapping->>'sku'),''
        )),'\s+',' ','g'));
        v_name := regexp_replace(btrim(COALESCE(
            v_source->>(v_job.mapping->>'productName'),''
        )),'\s+',' ','g');
        v_category_name := regexp_replace(btrim(COALESCE(
            v_source->>(v_job.mapping->>'categoryName'),''
        )),'\s+',' ','g');
        v_uom_name := regexp_replace(btrim(COALESCE(
            v_source->>(v_job.mapping->>'uomName'),''
        )),'\s+',' ','g');
        v_image_url := NULLIF(btrim(COALESCE(
            v_source->>(v_job.mapping->>'imageUrl'),''
        )),'');
        v_sales_tax_name := NULLIF(regexp_replace(btrim(COALESCE(
            v_source->>(v_job.mapping->>'salesTaxRuleName'),''
        )),'\s+',' ','g'),'');
        v_purchase_tax_name := NULLIF(regexp_replace(btrim(COALESCE(
            v_source->>(v_job.mapping->>'purchaseTaxRuleName'),''
        )),'\s+',' ','g'),'');
        v_barcode := NULLIF(regexp_replace(btrim(COALESCE(
            v_source->>(v_job.mapping->>'barcode'),''
        )),'\s+','','g'),'');

        IF v_product_key = '' OR char_length(v_product_key) > 120 THEN
            v_errors := v_errors ||
                private.g2_phase42_product_import_error(
                    'INVALID_PRODUCT_KEY'
                );
        END IF;
        IF v_sku = '' OR char_length(v_sku) > 100 THEN
            v_errors := v_errors ||
                private.g2_phase42_product_import_error(
                    'INVALID_PRODUCT_SKU'
                );
        END IF;
        IF v_name = '' OR char_length(v_name) > 200 THEN
            v_errors := v_errors ||
                private.g2_phase42_product_import_error(
                    'INVALID_PRODUCT_NAME'
                );
        END IF;
        IF v_category_name = '' THEN
            v_errors := v_errors ||
                private.g2_phase42_product_import_error(
                    'PRODUCT_CATEGORY_NAME_REQUIRED'
                );
        END IF;
        IF v_uom_name = '' THEN
            v_errors := v_errors ||
                private.g2_phase42_product_import_error('UOM_NAME_REQUIRED');
        END IF;
        IF v_image_url IS NOT NULL AND v_image_url !~* '^https://' THEN
            v_errors := v_errors ||
                private.g2_phase42_product_import_error(
                    'PRODUCT_IMAGE_HTTPS_REQUIRED'
                );
        END IF;

        BEGIN
            v_factor := NULLIF(btrim(COALESCE(
                v_source->>(v_job.mapping->>'factorToBase'),''
            )),'')::NUMERIC;
            v_purchase_price := NULLIF(btrim(COALESCE(
                v_source->>(v_job.mapping->>'purchasePrice'),''
            )),'')::NUMERIC;
            v_sale_price := NULLIF(btrim(COALESCE(
                v_source->>(v_job.mapping->>'salePrice'),''
            )),'')::NUMERIC;
            v_weight := NULLIF(btrim(COALESCE(
                v_source->>(v_job.mapping->>'weightPerLargestUomKg'),''
            )),'')::NUMERIC;
            v_purchase_allowed := private.g2_phase40_import_boolean(
                v_source->>(v_job.mapping->>'purchaseAllowed'),FALSE
            );
            v_sales_allowed := private.g2_phase40_import_boolean(
                v_source->>(v_job.mapping->>'salesAllowed'),FALSE
            );
            v_is_active := private.g2_phase40_import_boolean(
                v_source->>(v_job.mapping->>'isActive'),TRUE
            );
        EXCEPTION WHEN OTHERS THEN
            v_errors := v_errors ||
                private.g2_phase42_product_import_error(
                    'INVALID_PRODUCT_UOM_VALUE'
                );
            v_factor := NULL;
            v_purchase_price := NULL;
            v_sale_price := NULL;
            v_weight := NULL;
            v_purchase_allowed := FALSE;
            v_sales_allowed := FALSE;
            v_is_active := TRUE;
        END;

        IF v_factor IS NULL OR v_factor < 1 THEN
            v_errors := v_errors ||
                private.g2_phase42_product_import_error(
                    'PRODUCT_UOM_FACTOR_BELOW_BASE'
                );
        END IF;
        IF v_weight IS NULL OR v_weight <= 0 THEN
            v_errors := v_errors ||
                private.g2_phase42_product_import_error(
                    'POSITIVE_REFERENCE_WEIGHT_REQUIRED'
                );
        END IF;
        IF v_purchase_price IS NOT NULL AND v_purchase_price < 0
           OR v_sale_price IS NOT NULL AND v_sale_price < 0 THEN
            v_errors := v_errors ||
                private.g2_phase42_product_import_error(
                    'PRODUCT_UOM_PRICE_NEGATIVE'
                );
        END IF;
        IF v_purchase_allowed AND v_purchase_price IS NULL THEN
            v_errors := v_errors ||
                private.g2_phase42_product_import_error(
                    'PURCHASE_PRICE_REQUIRED'
                );
        END IF;
        IF v_sales_allowed AND v_sale_price IS NULL THEN
            v_errors := v_errors ||
                private.g2_phase42_product_import_error(
                    'SALE_PRICE_REQUIRED'
                );
        END IF;

        IF v_category_name <> '' THEN
            SELECT count(*),min(pc.id::TEXT)::UUID
            INTO v_match_count,v_category_id
            FROM public.product_categories pc
            WHERE pc.company_id = v_company
              AND pc.is_active
              AND private.g2_phase42_normalized_name(pc.category_name) =
                  private.g2_phase42_normalized_name(v_category_name);
            IF v_match_count <> 1 THEN
                v_errors := v_errors ||
                    private.g2_phase42_product_import_error(
                        'ACTIVE_PRODUCT_CATEGORY_NOT_FOUND'
                    );
                v_category_id := NULL;
            END IF;
        END IF;

        IF v_uom_name <> '' THEN
            SELECT count(*),min(u.id::TEXT)::UUID
            INTO v_match_count,v_uom_id
            FROM public.uoms u
            WHERE u.company_id = v_company
              AND u.is_active
              AND private.g2_phase42_normalized_name(u.name) =
                  private.g2_phase42_normalized_name(v_uom_name);
            IF v_match_count <> 1 THEN
                v_errors := v_errors ||
                    private.g2_phase42_product_import_error(
                        'ACTIVE_PRODUCT_UOM_NOT_FOUND'
                    );
                v_uom_id := NULL;
            END IF;
        END IF;

        IF v_sales_tax_name IS NOT NULL THEN
            SELECT count(*),min(tr.id::TEXT)::UUID
            INTO v_match_count,v_sales_tax_id
            FROM public.tax_rules tr
            WHERE tr.company_id = v_company
              AND tr.tax_scope = 'SALES'
              AND tr.is_active
              AND private.g2_phase42_normalized_name(tr.tax_name) =
                  private.g2_phase42_normalized_name(v_sales_tax_name)
              AND EXISTS (
                  SELECT 1 FROM public.tax_rule_versions tv
                  WHERE tv.company_id = tr.company_id
                    AND tv.tax_rule_id = tr.id
                    AND tv.status = 'ACTIVE'
                    AND tv.effective_from <= clock_timestamp()
                    AND (
                        tv.effective_to IS NULL
                        OR tv.effective_to > clock_timestamp()
                    )
              );
            IF v_match_count <> 1 THEN
                v_errors := v_errors ||
                    private.g2_phase42_product_import_error(
                        'ACTIVE_SALES_TAX_RULE_NOT_FOUND'
                    );
                v_sales_tax_id := NULL;
            END IF;
        END IF;

        IF v_purchase_tax_name IS NOT NULL THEN
            SELECT count(*),min(tr.id::TEXT)::UUID
            INTO v_match_count,v_purchase_tax_id
            FROM public.tax_rules tr
            WHERE tr.company_id = v_company
              AND tr.tax_scope = 'PURCHASE'
              AND tr.is_active
              AND private.g2_phase42_normalized_name(tr.tax_name) =
                  private.g2_phase42_normalized_name(v_purchase_tax_name)
              AND EXISTS (
                  SELECT 1 FROM public.tax_rule_versions tv
                  WHERE tv.company_id = tr.company_id
                    AND tv.tax_rule_id = tr.id
                    AND tv.status = 'ACTIVE'
                    AND tv.effective_from <= clock_timestamp()
                    AND (
                        tv.effective_to IS NULL
                        OR tv.effective_to > clock_timestamp()
                    )
              );
            IF v_match_count <> 1 THEN
                v_errors := v_errors ||
                    private.g2_phase42_product_import_error(
                        'ACTIVE_PURCHASE_TAX_RULE_NOT_FOUND'
                    );
                v_purchase_tax_id := NULL;
            END IF;
        END IF;

        IF v_job.reference_mode = 'REFERENCE_BY_ID' THEN
            v_internal_text := btrim(COALESCE(
                v_source->>(v_job.mapping->>'internalId'),''
            ));
            BEGIN
                v_internal_id := v_internal_text::UUID;
            EXCEPTION WHEN OTHERS THEN
                v_errors := v_errors ||
                    private.g2_phase42_product_import_error(
                        'INVALID_IMPORT_INTERNAL_ID'
                    );
            END;
        END IF;

        v_normalized := jsonb_strip_nulls(jsonb_build_object(
            'productKey',v_product_key,
            'normalizedProductKey',
                private.g2_phase42_normalized_name(v_product_key),
            'sku',v_sku,'productName',v_name,
            'normalizedProductName',
                private.g2_phase42_normalized_name(v_name),
            'categoryName',v_category_name,'categoryId',v_category_id,
            'imageUrl',v_image_url,'isActive',v_is_active,
            'uomName',v_uom_name,'uomId',v_uom_id,
            'factorToBase',v_factor,
            'purchaseAllowed',v_purchase_allowed,
            'salesAllowed',v_sales_allowed,
            'purchasePrice',v_purchase_price,'salePrice',v_sale_price,
            'barcode',v_barcode,
            'salesTaxRuleName',v_sales_tax_name,
            'salesTaxRuleId',v_sales_tax_id,
            'purchaseTaxRuleName',v_purchase_tax_name,
            'purchaseTaxRuleId',v_purchase_tax_id,
            'weightPerLargestUomKg',v_weight,
            'internalId',v_internal_id
        ));

        UPDATE public.master_import_rows SET
            group_key = NULLIF(v_product_key,''),
            normalized_data = v_normalized,
            operation = CASE
                WHEN jsonb_array_length(v_errors) > 0 THEN 'ERROR'
                ELSE 'PENDING'
            END,
            row_status = CASE
                WHEN jsonb_array_length(v_errors) > 0 THEN 'ERROR'
                ELSE 'STAGED'
            END,
            errors = v_errors,
            updated_at = clock_timestamp()
        WHERE id = v_row.id;
    END LOOP;

    -- A Product group is valid only as a complete, internally consistent set.
    FOR v_group IN
        SELECT
            r.group_key,
            min(r.row_number) AS first_row,
            count(*) AS row_count,
            count(*) FILTER (WHERE r.operation = 'ERROR') AS invalid_rows,
            count(DISTINCT r.normalized_data->>'sku') AS sku_count,
            count(DISTINCT r.normalized_data->>'productName') AS name_count,
            count(DISTINCT r.normalized_data->>'categoryId') AS category_count,
            count(DISTINCT COALESCE(
                r.normalized_data->>'imageUrl','<NULL>'
            )) AS image_count,
            count(DISTINCT r.normalized_data->>'isActive') AS active_count,
            count(DISTINCT COALESCE(
                r.normalized_data->>'salesTaxRuleId','<NULL>'
            )) AS sales_tax_count,
            count(DISTINCT COALESCE(
                r.normalized_data->>'purchaseTaxRuleId','<NULL>'
            )) AS purchase_tax_count,
            count(DISTINCT
                r.normalized_data->>'weightPerLargestUomKg'
            ) AS weight_count,
            count(DISTINCT COALESCE(
                r.normalized_data->>'internalId','<NULL>'
            )) AS internal_id_count,
            count(DISTINCT r.normalized_data->>'uomId') AS distinct_uoms,
            count(*) FILTER (
                WHERE (r.normalized_data->>'factorToBase')::NUMERIC = 1
            ) AS base_rows,
            count(*) FILTER (
                WHERE COALESCE(
                    (r.normalized_data->>'salesAllowed')::BOOLEAN,FALSE
                )
            ) AS sales_rows,
            count(*) FILTER (
                WHERE COALESCE(
                    (r.normalized_data->>'purchaseAllowed')::BOOLEAN,FALSE
                )
            ) AS purchase_rows
        FROM public.master_import_rows r
        WHERE r.company_id = v_company AND r.job_id = p_job_id
        GROUP BY r.group_key
        ORDER BY min(r.row_number)
    LOOP
        v_group_error := NULL;
        v_operation := NULL;
        v_before := NULL;
        v_after := NULL;
        v_existing_uoms := NULL;
        v_existing_id := NULL;
        IF v_group.group_key IS NULL THEN
            v_group_error := 'INVALID_PRODUCT_KEY';
        ELSIF v_group.invalid_rows > 0 THEN
            v_group_error := 'PRODUCT_GROUP_HAS_INVALID_ROW';
        ELSIF v_group.row_count > 20 THEN
            v_group_error := 'PRODUCT_UOM_ROW_LIMIT_EXCEEDED';
        ELSIF v_group.sku_count <> 1
           OR v_group.name_count <> 1
           OR v_group.category_count <> 1
           OR v_group.image_count <> 1
           OR v_group.active_count <> 1
           OR v_group.sales_tax_count <> 1
           OR v_group.purchase_tax_count <> 1
           OR v_group.weight_count <> 1
           OR (
               v_job.reference_mode = 'REFERENCE_BY_ID'
               AND v_group.internal_id_count <> 1
           ) THEN
            v_group_error := 'INCONSISTENT_PRODUCT_GROUP_HEADER';
        ELSIF v_group.distinct_uoms <> v_group.row_count THEN
            v_group_error := 'DUPLICATE_PRODUCT_UOM';
        ELSIF v_group.base_rows <> 1 THEN
            v_group_error := 'EXACTLY_ONE_BASE_UOM_REQUIRED';
        ELSIF v_group.sales_rows = 0 THEN
            v_group_error := 'ACTIVE_SALES_UOM_REQUIRED';
        ELSIF v_group.purchase_rows = 0 THEN
            v_group_error := 'ACTIVE_PURCHASE_UOM_REQUIRED';
        END IF;

        IF v_group_error IS NULL AND EXISTS (
            SELECT 1
            FROM public.master_import_rows r
            WHERE r.company_id = v_company AND r.job_id = p_job_id
              AND r.group_key = v_group.group_key
              AND NULLIF(r.normalized_data->>'barcode','') IS NOT NULL
            GROUP BY upper(r.normalized_data->>'barcode')
            HAVING count(*) > 1
        ) THEN
            v_group_error := 'DUPLICATE_PRODUCT_BARCODE';
        END IF;

        IF v_group_error IS NULL THEN
            SELECT r.normalized_data INTO v_first
            FROM public.master_import_rows r
            WHERE r.company_id = v_company AND r.job_id = p_job_id
              AND r.group_key = v_group.group_key
            ORDER BY r.row_number LIMIT 1;

            SELECT
                jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                    'uomId',r.normalized_data->>'uomId',
                    'factorToBase',
                        (r.normalized_data->>'factorToBase')::NUMERIC,
                    'purchaseAllowed',
                        (r.normalized_data->>'purchaseAllowed')::BOOLEAN,
                    'salesAllowed',
                        (r.normalized_data->>'salesAllowed')::BOOLEAN,
                    'purchasePrice',
                        NULLIF(r.normalized_data->>'purchasePrice','')::NUMERIC,
                    'salePrice',
                        NULLIF(r.normalized_data->>'salePrice','')::NUMERIC,
                    'barcode',NULLIF(r.normalized_data->>'barcode',''),
                    'isActive',TRUE
                )) ORDER BY
                    (r.normalized_data->>'factorToBase')::NUMERIC,
                    r.normalized_data->>'uomId'
                ),
                (
                    min(r.normalized_data->>'uomId') FILTER (
                        WHERE
                            (r.normalized_data->>'factorToBase')::NUMERIC = 1
                    )
                )::UUID
            INTO v_uoms,v_base_uom_id
            FROM public.master_import_rows r
            WHERE r.company_id = v_company AND r.job_id = p_job_id
              AND r.group_key = v_group.group_key;

            SELECT (r.normalized_data->>'uomId')::UUID
            INTO v_weight_uom_id
            FROM public.master_import_rows r
            WHERE r.company_id = v_company AND r.job_id = p_job_id
              AND r.group_key = v_group.group_key
            ORDER BY
                (r.normalized_data->>'factorToBase')::NUMERIC DESC,
                r.row_number
            LIMIT 1;

            IF (
                SELECT count(*) FROM public.master_import_rows r
                WHERE r.company_id = v_company AND r.job_id = p_job_id
                  AND r.group_key = v_group.group_key
                  AND (r.normalized_data->>'factorToBase')::NUMERIC = (
                      SELECT max(
                          (x.normalized_data->>'factorToBase')::NUMERIC
                      )
                      FROM public.master_import_rows x
                      WHERE x.company_id = v_company
                        AND x.job_id = p_job_id
                        AND x.group_key = v_group.group_key
                  )
            ) <> 1 THEN
                v_group_error := 'LARGEST_PRODUCT_UOM_FACTOR_NOT_UNIQUE';
            END IF;
        END IF;

        IF v_group_error IS NULL THEN
            v_existing_id := NULL;
            IF v_job.reference_mode = 'REFERENCE_BY_ID' THEN
                v_existing_id := NULLIF(v_first->>'internalId','')::UUID;
                SELECT count(*) INTO v_match_count
                FROM public.products p
                WHERE p.company_id = v_company AND p.id = v_existing_id;
            ELSE
                SELECT count(*),min(p.id::TEXT)::UUID
                INTO v_match_count,v_existing_id
                FROM public.products p
                WHERE p.company_id = v_company
                  AND private.g2_phase42_normalized_name(p.name) =
                      v_first->>'normalizedProductName';
            END IF;

            IF v_match_count > 1 THEN
                v_group_error := 'AMBIGUOUS_PRODUCT_MATCH';
            ELSIF v_match_count = 0 THEN
                v_existing_id := NULL;
                IF v_job.operation_mode = 'UPDATE_ONLY' THEN
                    v_group_error := 'IMPORT_UPDATE_TARGET_NOT_FOUND';
                ELSIF EXISTS (
                    SELECT 1 FROM public.products p
                    WHERE p.company_id = v_company
                      AND upper(regexp_replace(
                          btrim(p.sku),'\s+',' ','g'
                      )) = v_first->>'sku'
                ) THEN
                    v_group_error := 'DUPLICATE_PRODUCT_SKU';
                ELSE
                    v_operation := 'CREATE';
                END IF;
            ELSE
                SELECT * INTO v_existing
                FROM public.products p
                WHERE p.company_id = v_company AND p.id = v_existing_id;
                IF v_existing.is_bundle THEN
                    v_group_error := 'BUNDLE_PRODUCT_IMPORT_NOT_SUPPORTED';
                ELSIF v_job.operation_mode = 'CREATE_ONLY' THEN
                    v_group_error := 'IMPORT_CREATE_ONLY_MATCHED_EXISTING';
                ELSIF EXISTS (
                    SELECT 1 FROM public.products p
                    WHERE p.company_id = v_company
                      AND p.id <> v_existing_id
                      AND upper(regexp_replace(
                          btrim(p.sku),'\s+',' ','g'
                      )) = v_first->>'sku'
                ) THEN
                    v_group_error := 'DUPLICATE_PRODUCT_SKU';
                ELSE
                    v_operation := 'UPDATE';
                END IF;
            END IF;
        END IF;

        IF v_group_error IS NULL THEN
            v_after := jsonb_strip_nulls(jsonb_build_object(
                'productId',v_existing_id,
                'masterVersion',CASE
                    WHEN v_existing_id IS NULL THEN NULL
                    ELSE v_existing.master_version
                END,
                'sku',v_first->>'sku',
                'name',v_first->>'productName',
                'categoryId',v_first->>'categoryId',
                'baseUomId',v_base_uom_id,
                'weightReferenceUomId',v_weight_uom_id,
                'weightPerReferenceUomKg',
                    (v_first->>'weightPerLargestUomKg')::NUMERIC,
                'isBundle',FALSE,
                'imageUrl',NULLIF(v_first->>'imageUrl',''),
                'isActive',(v_first->>'isActive')::BOOLEAN,
                'salesTaxRuleId',NULLIF(v_first->>'salesTaxRuleId',''),
                'purchaseTaxRuleId',
                    NULLIF(v_first->>'purchaseTaxRuleId',''),
                'uoms',v_uoms
            ));

            IF v_existing_id IS NOT NULL THEN
                SELECT COALESCE(jsonb_agg(
                    jsonb_strip_nulls(jsonb_build_object(
                        'uomId',pu.uom_id,
                        'factorToBase',pu.factor_to_base,
                        'purchaseAllowed',pu.purchase_allowed,
                        'salesAllowed',pu.sales_allowed,
                        'purchasePrice',pu.purchase_price,
                        'salePrice',pu.sale_price,
                        'barcode',pu.barcode,
                        'isActive',pu.is_active
                    )) ORDER BY pu.factor_to_base,pu.uom_id
                ) FILTER (WHERE pu.is_active),'[]'::JSONB)
                INTO v_existing_uoms
                FROM public.product_uoms pu
                WHERE pu.company_id = v_company
                  AND pu.product_id = v_existing_id;

                v_before := jsonb_strip_nulls(jsonb_build_object(
                    'productId',v_existing.id,
                    'masterVersion',v_existing.master_version,
                    'sku',v_existing.sku,'name',v_existing.name,
                    'categoryId',v_existing.category_id,
                    'baseUomId',v_existing.uom_id,
                    'weightReferenceUomId',
                        v_existing.weight_reference_uom_id,
                    'weightPerReferenceUomKg',
                        v_existing.weight_per_uom_kg,
                    'isBundle',v_existing.is_bundle,
                    'imageUrl',v_existing.image_url,
                    'isActive',v_existing.is_active,
                    'salesTaxRuleId',v_existing.sales_tax_rule_id,
                    'purchaseTaxRuleId',v_existing.purchase_tax_rule_id,
                    'uoms',v_existing_uoms
                ));

                SELECT EXISTS (
                    SELECT 1 FROM public.stock_movements sm
                    WHERE sm.company_id = v_company
                      AND sm.product_id = v_existing_id
                    UNION ALL
                    SELECT 1 FROM public.sales_details sd
                    WHERE sd.company_id = v_company
                      AND sd.product_id = v_existing_id
                    UNION ALL
                    SELECT 1 FROM public.purchases_details pd
                    WHERE pd.company_id = v_company
                      AND pd.product_id = v_existing_id
                ) INTO v_has_history;

                IF v_has_history AND (
                    upper(btrim(v_existing.sku)) <> v_first->>'sku'
                    OR v_existing.uom_id IS DISTINCT FROM v_base_uom_id
                    OR (
                        SELECT COALESCE(jsonb_agg(jsonb_build_object(
                            'uomId',pu.uom_id,
                            'factorToBase',pu.factor_to_base
                        ) ORDER BY pu.uom_id),'[]'::JSONB)
                        FROM public.product_uoms pu
                        WHERE pu.company_id = v_company
                          AND pu.product_id = v_existing_id
                          AND pu.is_active
                    ) IS DISTINCT FROM (
                        SELECT COALESCE(jsonb_agg(jsonb_build_object(
                            'uomId',(x->>'uomId')::UUID,
                            'factorToBase',(x->>'factorToBase')::NUMERIC
                        ) ORDER BY x->>'uomId'),'[]'::JSONB)
                        FROM jsonb_array_elements(v_uoms) x
                    )
                ) THEN
                    v_group_error :=
                        'PRODUCT_STRUCTURE_LOCKED_BY_TRANSACTION_HISTORY';
                ELSIF (v_before - 'masterVersion') =
                      (v_after - 'masterVersion') THEN
                    v_operation := 'SKIP';
                END IF;
            END IF;
        END IF;

        IF v_group_error IS NOT NULL THEN
            UPDATE public.master_import_rows SET
                operation = 'ERROR',row_status = 'ERROR',
                errors = errors ||
                    private.g2_phase42_product_import_error(v_group_error),
                matched_record_id = NULL,matched_master_version = NULL,
                before_state = NULL,after_state = NULL,
                updated_at = clock_timestamp()
            WHERE company_id = v_company AND job_id = p_job_id
              AND group_key IS NOT DISTINCT FROM v_group.group_key;
        ELSE
            UPDATE public.master_import_rows SET
                operation = v_operation,row_status = 'VALIDATED',
                matched_record_id = v_existing_id,
                before_state = v_before,after_state = v_after,
                updated_at = clock_timestamp()
            WHERE company_id = v_company AND job_id = p_job_id
              AND group_key = v_group.group_key;
        END IF;
    END LOOP;

    -- A Product identity may only occur in one Product group in the same file.
    UPDATE public.master_import_rows target SET
        operation = 'ERROR',row_status = 'ERROR',
        errors = target.errors ||
            private.g2_phase42_product_import_error(
                'DUPLICATE_PRODUCT_GROUP_IDENTITY'
            ),
        matched_record_id = NULL,matched_master_version = NULL,
        before_state = NULL,after_state = NULL,
        updated_at = clock_timestamp()
    WHERE target.company_id = v_company AND target.job_id = p_job_id
      AND (
          target.normalized_data->>'sku' IN (
              SELECT r.normalized_data->>'sku'
              FROM public.master_import_rows r
              WHERE r.company_id = v_company AND r.job_id = p_job_id
                AND r.operation <> 'ERROR'
              GROUP BY r.normalized_data->>'sku'
              HAVING count(DISTINCT r.group_key) > 1
          )
          OR target.normalized_data->>'normalizedProductName' IN (
              SELECT r.normalized_data->>'normalizedProductName'
              FROM public.master_import_rows r
              WHERE r.company_id = v_company AND r.job_id = p_job_id
                AND r.operation <> 'ERROR'
              GROUP BY r.normalized_data->>'normalizedProductName'
              HAVING count(DISTINCT r.group_key) > 1
          )
      );

    SELECT
        count(DISTINCT group_key) FILTER (WHERE operation = 'CREATE'),
        count(DISTINCT group_key) FILTER (WHERE operation = 'UPDATE'),
        count(DISTINCT group_key) FILTER (WHERE operation = 'SKIP'),
        count(DISTINCT COALESCE(group_key,'<ROW:' || row_number || '>'))
            FILTER (WHERE operation = 'ERROR')
    INTO v_created,v_updated,v_skipped,v_error_groups
    FROM public.master_import_rows
    WHERE company_id = v_company AND job_id = p_job_id;

    UPDATE public.master_import_jobs SET
        status = 'VALIDATED',
        created_rows = COALESCE(v_created,0),
        updated_rows = COALESCE(v_updated,0),
        skipped_rows = COALESCE(v_skipped,0),
        error_rows = COALESCE(v_error_groups,0),
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
            'errorCount',COALESCE(v_error_groups,0)
        )
    );
    RETURN jsonb_build_object(
        'jobId',p_job_id,'masterVersion',v_new_version,
        'status','VALIDATED',
        'createCount',COALESCE(v_created,0),
        'updateCount',COALESCE(v_updated,0),
        'skipCount',COALESCE(v_skipped,0),
        'errorCount',COALESCE(v_error_groups,0),
        'action','VALIDATE'
    );
END;
$$;

REVOKE ALL ON FUNCTION
    private.validate_master_import_product_job(UUID,BIGINT)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
    private.validate_master_import_product_job(UUID,BIGINT)
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
    IF v_import_type = 'PRODUCT' THEN
        RETURN private.validate_master_import_product_job(
            p_job_id,p_master_version
        );
    END IF;
    RETURN private.validate_master_import_job_phase40(
        p_job_id,p_master_version
    );
END;
$$;

REVOKE ALL ON FUNCTION public.validate_master_import_job(UUID,BIGINT)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.validate_master_import_job(UUID,BIGINT)
TO authenticated,service_role;

-- Preserve Phase-40 commit for every existing import type.
ALTER FUNCTION public.commit_master_import_job(UUID,BIGINT,INTEGER)
    RENAME TO commit_master_import_job_phase40;
ALTER FUNCTION public.commit_master_import_job_phase40(UUID,BIGINT,INTEGER)
    SET SCHEMA private;

REVOKE ALL ON FUNCTION
    private.commit_master_import_job_phase40(UUID,BIGINT,INTEGER)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
    private.commit_master_import_job_phase40(UUID,BIGINT,INTEGER)
TO service_role;

CREATE FUNCTION private.commit_master_import_product_job(
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
    v_group RECORD;
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
    IF v_job.import_type <> 'PRODUCT' THEN
        RAISE EXCEPTION 'INVALID_PRODUCT_IMPORT_JOB';
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
        v_company::TEXT || ':MASTER_IMPORT_COMMIT:PRODUCT',0
    ));

    FOR v_group IN
        SELECT
            r.group_key,min(r.row_number) AS first_row,
            min(r.operation) AS operation,
            min(r.matched_record_id::TEXT)::UUID AS matched_record_id,
            min(r.matched_master_version) AS matched_master_version
        FROM public.master_import_rows r
        WHERE r.company_id = v_company AND r.job_id = p_job_id
          AND r.operation IN ('CREATE','UPDATE','SKIP')
          AND r.row_status = 'VALIDATED'
        GROUP BY r.group_key
        ORDER BY min(r.row_number)
    LOOP
        IF v_group.operation = 'SKIP' THEN
            UPDATE public.master_import_rows SET
                row_status = 'COMMITTED',committed_at = clock_timestamp(),
                updated_at = clock_timestamp()
            WHERE company_id = v_company AND job_id = p_job_id
              AND group_key = v_group.group_key;
            CONTINUE;
        END IF;

        BEGIN
            SELECT r.after_state INTO v_after
            FROM public.master_import_rows r
            WHERE r.company_id = v_company AND r.job_id = p_job_id
              AND r.group_key = v_group.group_key
            ORDER BY r.row_number LIMIT 1;

            IF v_group.operation = 'UPDATE' AND NOT EXISTS (
                SELECT 1 FROM public.products p
                WHERE p.company_id = v_company
                  AND p.id = v_group.matched_record_id
                  AND p.master_version = v_group.matched_master_version
            ) THEN
                RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
            END IF;

            v_result := public.save_product_with_uoms(
                CASE WHEN v_group.operation = 'CREATE'
                    THEN NULL ELSE v_group.matched_record_id END,
                CASE WHEN v_group.operation = 'CREATE'
                    THEN NULL ELSE v_group.matched_master_version END,
                v_after->>'sku',
                v_after->>'name',
                (v_after->>'categoryId')::UUID,
                (v_after->>'baseUomId')::UUID,
                (v_after->>'weightReferenceUomId')::UUID,
                (v_after->>'weightPerReferenceUomKg')::NUMERIC,
                FALSE,
                NULLIF(v_after->>'imageUrl',''),
                (v_after->>'isActive')::BOOLEAN,
                v_after->'uoms',
                NULLIF(v_after->>'salesTaxRuleId','')::UUID,
                NULLIF(v_after->>'purchaseTaxRuleId','')::UUID
            );
            v_record_id := (v_result->>'productId')::UUID;
            v_result_version := (v_result->>'masterVersion')::BIGINT;

            UPDATE public.master_import_rows SET
                row_status = 'COMMITTED',
                matched_record_id = v_record_id,
                matched_master_version = v_result_version,
                after_state = after_state || jsonb_build_object(
                    'productId',v_record_id,
                    'masterVersion',v_result_version
                ),
                committed_at = clock_timestamp(),
                updated_at = clock_timestamp()
            WHERE company_id = v_company AND job_id = p_job_id
              AND group_key = v_group.group_key;
        EXCEPTION WHEN OTHERS THEN
            v_error := SQLERRM;
            UPDATE public.master_import_rows SET
                operation = 'ERROR',row_status = 'ERROR',
                errors = errors ||
                    private.g2_phase42_product_import_error(
                        'PRODUCT_GROUP_COMMIT_FAILED',v_error
                    ),
                committed_at = NULL,updated_at = clock_timestamp()
            WHERE company_id = v_company AND job_id = p_job_id
              AND group_key = v_group.group_key;
        END;
    END LOOP;

    SELECT
        count(DISTINCT group_key) FILTER (
            WHERE operation = 'CREATE' AND row_status = 'COMMITTED'
        ),
        count(DISTINCT group_key) FILTER (
            WHERE operation = 'UPDATE' AND row_status = 'COMMITTED'
        ),
        count(DISTINCT group_key) FILTER (
            WHERE operation = 'SKIP' AND row_status = 'COMMITTED'
        ),
        count(DISTINCT COALESCE(group_key,'<ROW:' || row_number || '>'))
            FILTER (WHERE row_status = 'ERROR')
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
        v_company,p_job_id,'COMMIT',v_actor,
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
    private.commit_master_import_product_job(UUID,BIGINT,INTEGER)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
    private.commit_master_import_product_job(UUID,BIGINT,INTEGER)
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
    IF v_import_type = 'PRODUCT' THEN
        RETURN private.commit_master_import_product_job(
            p_job_id,p_master_version,p_confirm_update_count
        );
    END IF;
    RETURN private.commit_master_import_job_phase40(
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
    '20260727130000',
    'g2_phase42_grouped_product_import',
    'MST-005 grouped Product/Product-UOM preview and partial commit through guarded atomic Product RPC; no stock mutation'
);

COMMIT;
