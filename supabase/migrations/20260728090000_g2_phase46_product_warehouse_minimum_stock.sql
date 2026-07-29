-- KGS POS G2 phase 46: Product-Warehouse minimum-stock configuration/import.
-- Requirement: INV minimum-stock notice configuration and fixed CSV import.
-- Dependency: G2 phase 44 Product-Supplier import.
--
-- This migration is stock-neutral. It never changes product_stocks,
-- stock_movements, Opening Stock, Stock Request, or Supplier Order.

BEGIN;

DO $migration_guard$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260727160000'
    ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: phase 44 is required';
    END IF;
    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260728090000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260728090000';
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

CREATE TABLE public.product_warehouse_stock_settings (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL,
    product_id UUID NOT NULL,
    warehouse_id UUID NOT NULL,
    minimum_stock_base_qty NUMERIC(24,6),
    low_stock_alert_enabled BOOLEAN NOT NULL DEFAULT FALSE,
    master_version BIGINT NOT NULL DEFAULT 1,
    created_by UUID NOT NULL REFERENCES public.profiles(id),
    updated_by UUID NOT NULL REFERENCES public.profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT product_warehouse_stock_settings_company_id_id_unique
        UNIQUE(company_id,id),
    CONSTRAINT product_warehouse_stock_settings_pair_unique
        UNIQUE(company_id,product_id,warehouse_id),
    CONSTRAINT fk_product_warehouse_stock_settings_product
        FOREIGN KEY(company_id,product_id)
        REFERENCES public.products(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_product_warehouse_stock_settings_warehouse
        FOREIGN KEY(company_id,warehouse_id)
        REFERENCES public.warehouses(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT product_warehouse_stock_settings_minimum_nonnegative CHECK(
        minimum_stock_base_qty IS NULL OR minimum_stock_base_qty >= 0
    ),
    CONSTRAINT product_warehouse_stock_settings_alert_threshold CHECK(
        NOT low_stock_alert_enabled OR minimum_stock_base_qty IS NOT NULL
    ),
    CONSTRAINT product_warehouse_stock_settings_version_positive CHECK(
        master_version > 0
    )
);

CREATE INDEX idx_product_warehouse_stock_settings_company_warehouse_alert
    ON public.product_warehouse_stock_settings(
        company_id,warehouse_id,low_stock_alert_enabled
    );
CREATE INDEX idx_product_warehouse_stock_settings_company_product
    ON public.product_warehouse_stock_settings(company_id,product_id);

CREATE TABLE public.product_warehouse_stock_setting_audit (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_id UUID NOT NULL,
    setting_id UUID NOT NULL,
    action TEXT NOT NULL CHECK(action IN ('CREATE','UPDATE')),
    actor_id UUID NOT NULL REFERENCES public.profiles(id),
    before_state JSONB,
    after_state JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT fk_product_warehouse_stock_setting_audit_setting
        FOREIGN KEY(company_id,setting_id)
        REFERENCES public.product_warehouse_stock_settings(company_id,id)
        ON DELETE RESTRICT
);

CREATE INDEX idx_product_warehouse_stock_setting_audit_setting_created
    ON public.product_warehouse_stock_setting_audit(
        company_id,setting_id,created_at DESC
    );

CREATE TRIGGER g2_touch_product_warehouse_stock_settings
BEFORE INSERT OR UPDATE ON public.product_warehouse_stock_settings
FOR EACH ROW EXECUTE FUNCTION private.trg_g2_touch_master();

CREATE FUNCTION public.save_product_warehouse_stock_setting(
    p_setting_id UUID,
    p_master_version BIGINT,
    p_product_id UUID,
    p_warehouse_id UUID,
    p_minimum_stock_base_qty NUMERIC,
    p_low_stock_alert_enabled BOOLEAN
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_actor UUID := auth.uid();
    v_company UUID := public.private_active_company_id();
    v_setting_id UUID;
    v_result_version BIGINT;
    v_existing public.product_warehouse_stock_settings%ROWTYPE;
    v_before JSONB;
    v_after JSONB;
    v_allow_decimal BOOLEAN;
    v_decimal_precision INTEGER;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF NOT public.private_user_has_any_company_or_store_role(
        v_company,
        ARRAY[
            'COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','WAREHOUSE_ADMIN'
        ]::TEXT[]
    ) THEN
        RAISE EXCEPTION 'INVENTORY_CONFIGURATION_MANAGER_REQUIRED';
    END IF;
    IF p_minimum_stock_base_qty IS NOT NULL
       AND p_minimum_stock_base_qty < 0 THEN
        RAISE EXCEPTION 'MINIMUM_STOCK_NEGATIVE';
    END IF;
    IF p_minimum_stock_base_qty >= 1000000000000000000::NUMERIC THEN
        RAISE EXCEPTION 'MINIMUM_STOCK_TOO_LARGE';
    END IF;
    IF COALESCE(p_low_stock_alert_enabled,FALSE)
       AND p_minimum_stock_base_qty IS NULL THEN
        RAISE EXCEPTION 'MINIMUM_STOCK_REQUIRED_WHEN_ALERT_ENABLED';
    END IF;
    SELECT u.allow_decimal,u.decimal_precision
    INTO v_allow_decimal,v_decimal_precision
        FROM public.products p
        JOIN public.product_uoms pu
          ON pu.company_id = p.company_id
         AND pu.product_id = p.id
         AND pu.uom_id = p.uom_id
         AND pu.factor_to_base = 1
         AND pu.is_active
        JOIN public.uoms u
          ON u.company_id = pu.company_id
         AND u.id = pu.uom_id
         AND u.is_active
        WHERE p.company_id = v_company
          AND p.id = p_product_id
          AND p.is_active
          AND NOT p.is_bundle;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ACTIVE_STOCK_PRODUCT_WITH_BASE_UOM_NOT_FOUND';
    END IF;
    IF p_minimum_stock_base_qty IS NOT NULL
       AND NOT v_allow_decimal
       AND p_minimum_stock_base_qty <> trunc(p_minimum_stock_base_qty) THEN
        RAISE EXCEPTION 'MINIMUM_STOCK_BASE_UOM_REQUIRES_INTEGER';
    END IF;
    IF p_minimum_stock_base_qty IS NOT NULL
       AND v_allow_decimal
       AND p_minimum_stock_base_qty <>
           round(p_minimum_stock_base_qty,v_decimal_precision) THEN
        RAISE EXCEPTION 'MINIMUM_STOCK_BASE_UOM_PRECISION_EXCEEDED';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM public.warehouses w
        WHERE w.company_id = v_company
          AND w.id = p_warehouse_id
          AND w.is_active
    ) THEN
        RAISE EXCEPTION 'ACTIVE_WAREHOUSE_NOT_FOUND';
    END IF;

    PERFORM pg_advisory_xact_lock(hashtextextended(
        v_company::TEXT || ':MINIMUM_STOCK:' ||
        p_product_id::TEXT || ':' || p_warehouse_id::TEXT,0
    ));

    IF p_setting_id IS NULL THEN
        IF p_master_version IS NOT NULL THEN
            RAISE EXCEPTION 'MASTER_VERSION_NOT_ALLOWED_ON_CREATE';
        END IF;
        INSERT INTO public.product_warehouse_stock_settings(
            company_id,product_id,warehouse_id,minimum_stock_base_qty,
            low_stock_alert_enabled,created_by,updated_by
        ) VALUES (
            v_company,p_product_id,p_warehouse_id,p_minimum_stock_base_qty,
            COALESCE(p_low_stock_alert_enabled,FALSE),v_actor,v_actor
        )
        RETURNING id,master_version
        INTO v_setting_id,v_result_version;

        SELECT to_jsonb(s) INTO v_after
        FROM public.product_warehouse_stock_settings s
        WHERE s.company_id = v_company AND s.id = v_setting_id;
        INSERT INTO public.product_warehouse_stock_setting_audit(
            company_id,setting_id,action,actor_id,before_state,after_state
        ) VALUES (
            v_company,v_setting_id,'CREATE',v_actor,NULL,v_after
        );
    ELSE
        SELECT * INTO v_existing
        FROM public.product_warehouse_stock_settings s
        WHERE s.company_id = v_company AND s.id = p_setting_id
        FOR UPDATE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'PRODUCT_WAREHOUSE_STOCK_SETTING_NOT_FOUND';
        END IF;
        IF p_master_version IS NULL
           OR p_master_version <> v_existing.master_version THEN
            RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
        END IF;
        IF v_existing.product_id IS DISTINCT FROM p_product_id
           OR v_existing.warehouse_id IS DISTINCT FROM p_warehouse_id THEN
            RAISE EXCEPTION 'PRODUCT_WAREHOUSE_SETTING_IDENTITY_IMMUTABLE';
        END IF;
        v_before := to_jsonb(v_existing);

        UPDATE public.product_warehouse_stock_settings SET
            minimum_stock_base_qty = p_minimum_stock_base_qty,
            low_stock_alert_enabled = COALESCE(
                p_low_stock_alert_enabled,FALSE
            ),
            updated_by = v_actor
        WHERE company_id = v_company AND id = p_setting_id
        RETURNING id,master_version
        INTO v_setting_id,v_result_version;

        SELECT to_jsonb(s) INTO v_after
        FROM public.product_warehouse_stock_settings s
        WHERE s.company_id = v_company AND s.id = v_setting_id;
        INSERT INTO public.product_warehouse_stock_setting_audit(
            company_id,setting_id,action,actor_id,before_state,after_state
        ) VALUES (
            v_company,v_setting_id,'UPDATE',v_actor,v_before,v_after
        );
    END IF;

    RETURN jsonb_build_object(
        'settingId',v_setting_id,
        'masterVersion',v_result_version
    );
EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'PRODUCT_WAREHOUSE_STOCK_SETTING_ALREADY_EXISTS';
END;
$$;

ALTER TABLE public.product_warehouse_stock_settings
    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.product_warehouse_stock_setting_audit
    ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Inventory managers read minimum stock settings"
ON public.product_warehouse_stock_settings FOR SELECT TO authenticated
USING (
    public.private_request_company_matches(company_id)
    AND public.private_user_has_any_company_or_store_role(
        company_id,
        ARRAY[
            'COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER',
            'WAREHOUSE_ADMIN'
        ]::TEXT[]
    )
);

CREATE POLICY "Inventory managers read minimum stock audit"
ON public.product_warehouse_stock_setting_audit FOR SELECT TO authenticated
USING (
    public.private_request_company_matches(company_id)
    AND public.private_user_has_any_company_or_store_role(
        company_id,
        ARRAY[
            'COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','WAREHOUSE_ADMIN'
        ]::TEXT[]
    )
);

REVOKE ALL ON public.product_warehouse_stock_settings,
    public.product_warehouse_stock_setting_audit
FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.product_warehouse_stock_settings
TO authenticated;
GRANT SELECT ON public.product_warehouse_stock_setting_audit
TO authenticated;
GRANT ALL ON public.product_warehouse_stock_settings,
    public.product_warehouse_stock_setting_audit
TO service_role;

REVOKE ALL ON FUNCTION public.save_product_warehouse_stock_setting(
    UUID,BIGINT,UUID,UUID,NUMERIC,BOOLEAN
) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.save_product_warehouse_stock_setting(
    UUID,BIGINT,UUID,UUID,NUMERIC,BOOLEAN
) TO authenticated,service_role;

-- Extend the fixed import job type while preserving every reviewed signature.
ALTER TABLE public.master_import_jobs
    DROP CONSTRAINT master_import_jobs_type_check,
    ADD CONSTRAINT master_import_jobs_type_check CHECK(import_type IN (
        'PRODUCT_CATEGORY','UOM','WAREHOUSE','SUPPLIER',
        'CUSTOMER_CATEGORY','CHART_OF_ACCOUNT','TRANSACTION_CATEGORY',
        'PRODUCT','PRODUCT_SUPPLIER','PRODUCT_WAREHOUSE_MINIMUM_STOCK'
    ));

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
        'PRODUCT','PRODUCT_SUPPLIER','PRODUCT_WAREHOUSE_MINIMUM_STOCK'
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

-- Prevent the Phase-32 simple-master trigger from interpreting this fixed
-- operational configuration as a code/name master.
DO $extend_phase32_dispatch$
DECLARE
    v_oid OID := to_regprocedure(
        'private.trg_g2_validate_import_business_fields()'
    );
    v_definition TEXT;
    v_old TEXT :=
        '''TRANSACTION_CATEGORY'',''PRODUCT'',''PRODUCT_SUPPLIER'') THEN';
    v_new TEXT :=
        '''TRANSACTION_CATEGORY'',''PRODUCT'',''PRODUCT_SUPPLIER'',' ||
        '''PRODUCT_WAREHOUSE_MINIMUM_STOCK'') THEN';
BEGIN
    IF v_oid IS NULL THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: phase 32 trigger missing';
    END IF;
    SELECT pg_get_functiondef(v_oid) INTO v_definition;
    IF strpos(v_definition,v_old) = 0 THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: import dispatch changed';
    END IF;
    IF (
        length(v_definition) - length(replace(v_definition,v_old,''))
    ) / length(v_old) <> 1 THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: import dispatch ambiguous';
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
        SELECT x.master_version INTO v_master_version FROM public.uoms x
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
        SELECT x.master_version INTO v_master_version FROM public.products x
        WHERE x.company_id = NEW.company_id AND x.id = NEW.matched_record_id;
    ELSIF v_import_type = 'PRODUCT_SUPPLIER' THEN
        SELECT x.master_version INTO v_master_version
        FROM public.product_suppliers x
        WHERE x.company_id = NEW.company_id AND x.id = NEW.matched_record_id;
    ELSIF v_import_type = 'PRODUCT_WAREHOUSE_MINIMUM_STOCK' THEN
        SELECT x.master_version INTO v_master_version
        FROM public.product_warehouse_stock_settings x
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

CREATE FUNCTION private.g2_phase46_import_error(
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
            'code',p_code,'message',NULLIF(p_message,'')
        ))
    )
$$;

REVOKE ALL ON FUNCTION private.g2_phase46_import_error(TEXT,TEXT)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.g2_phase46_import_error(TEXT,TEXT)
TO service_role;

ALTER FUNCTION public.validate_master_import_job(UUID,BIGINT)
    RENAME TO validate_master_import_job_phase44;
ALTER FUNCTION public.validate_master_import_job_phase44(UUID,BIGINT)
    SET SCHEMA private;

REVOKE ALL ON FUNCTION
    private.validate_master_import_job_phase44(UUID,BIGINT)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
    private.validate_master_import_job_phase44(UUID,BIGINT)
TO service_role;

CREATE FUNCTION private.validate_master_import_minimum_stock_job(
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
    v_existing public.product_warehouse_stock_settings%ROWTYPE;
    v_source JSONB;
    v_column TEXT;
    v_product_sku TEXT;
    v_warehouse_name TEXT;
    v_internal_text TEXT;
    v_internal_id UUID;
    v_product_id UUID;
    v_warehouse_id UUID;
    v_existing_id UUID;
    v_minimum_qty NUMERIC;
    v_alert_enabled BOOLEAN;
    v_allow_decimal BOOLEAN;
    v_decimal_precision INTEGER;
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
    IF v_job.import_type <> 'PRODUCT_WAREHOUSE_MINIMUM_STOCK' THEN
        RAISE EXCEPTION 'INVALID_MINIMUM_STOCK_IMPORT_JOB';
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
        'productSku','warehouseName','minimumStockBaseQty',
        'lowStockAlertEnabled'
    ] LOOP
        IF NULLIF(btrim(v_job.mapping->>v_column),'') IS NULL THEN
            RAISE EXCEPTION
                'IMPORT_MINIMUM_STOCK_MAPPING_REQUIRED: %',v_column;
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
        v_warehouse_id := NULL;
        v_internal_id := NULL;
        v_internal_text := NULL;
        v_existing_id := NULL;
        v_before := NULL;
        v_after := NULL;
        v_operation := 'ERROR';

        v_product_sku := upper(regexp_replace(btrim(COALESCE(
            v_source->>(v_job.mapping->>'productSku'),''
        )),'\s+',' ','g'));
        v_warehouse_name := regexp_replace(btrim(COALESCE(
            v_source->>(v_job.mapping->>'warehouseName'),''
        )),'\s+',' ','g');

        IF v_product_sku = '' OR char_length(v_product_sku) > 100 THEN
            v_errors := v_errors ||
                private.g2_phase46_import_error('INVALID_PRODUCT_SKU');
        END IF;
        IF v_warehouse_name = ''
           OR char_length(v_warehouse_name) > 200 THEN
            v_errors := v_errors ||
                private.g2_phase46_import_error('INVALID_WAREHOUSE_NAME');
        END IF;

        BEGIN
            v_minimum_qty := NULLIF(btrim(COALESCE(
                v_source->>(v_job.mapping->>'minimumStockBaseQty'),''
            )),'')::NUMERIC;
            v_alert_enabled := private.g2_phase40_import_boolean(
                v_source->>(v_job.mapping->>'lowStockAlertEnabled'),FALSE
            );
        EXCEPTION WHEN OTHERS THEN
            v_errors := v_errors ||
                private.g2_phase46_import_error(
                    'INVALID_MINIMUM_STOCK_VALUE',SQLERRM
                );
            v_minimum_qty := NULL;
            v_alert_enabled := FALSE;
        END;
        IF v_minimum_qty IS NOT NULL AND v_minimum_qty < 0 THEN
            v_errors := v_errors ||
                private.g2_phase46_import_error('MINIMUM_STOCK_NEGATIVE');
        END IF;
        IF v_minimum_qty >= 1000000000000000000::NUMERIC THEN
            v_errors := v_errors ||
                private.g2_phase46_import_error('MINIMUM_STOCK_TOO_LARGE');
        END IF;
        IF v_alert_enabled AND v_minimum_qty IS NULL THEN
            v_errors := v_errors ||
                private.g2_phase46_import_error(
                    'MINIMUM_STOCK_REQUIRED_WHEN_ALERT_ENABLED'
                );
        END IF;

        SELECT count(*),min(p.id::TEXT)::UUID
        INTO v_match_count,v_product_id
        FROM public.products p
        WHERE p.company_id = v_company
          AND p.is_active
          AND NOT p.is_bundle
          AND upper(regexp_replace(btrim(p.sku),'\s+',' ','g')) =
              v_product_sku
          AND EXISTS (
              SELECT 1
              FROM public.product_uoms pu
              JOIN public.uoms u
                ON u.company_id = pu.company_id
               AND u.id = pu.uom_id
               AND u.is_active
              WHERE pu.company_id = p.company_id
                AND pu.product_id = p.id
                AND pu.uom_id = p.uom_id
                AND pu.factor_to_base = 1
                AND pu.is_active
          );
        IF v_match_count = 0 THEN
            v_errors := v_errors ||
                private.g2_phase46_import_error(
                    'ACTIVE_STOCK_PRODUCT_WITH_BASE_UOM_NOT_FOUND'
                );
        ELSIF v_match_count > 1 THEN
            v_errors := v_errors ||
                private.g2_phase46_import_error(
                    'AMBIGUOUS_PRODUCT_REFERENCE'
                );
            v_product_id := NULL;
        END IF;
        IF v_product_id IS NOT NULL THEN
            SELECT u.allow_decimal,u.decimal_precision
            INTO v_allow_decimal,v_decimal_precision
            FROM public.products p
            JOIN public.uoms u
              ON u.company_id = p.company_id
             AND u.id = p.uom_id
            WHERE p.company_id = v_company
              AND p.id = v_product_id;
            IF v_minimum_qty IS NOT NULL
               AND NOT v_allow_decimal
               AND v_minimum_qty <> trunc(v_minimum_qty) THEN
                v_errors := v_errors ||
                    private.g2_phase46_import_error(
                        'MINIMUM_STOCK_BASE_UOM_REQUIRES_INTEGER'
                    );
            END IF;
            IF v_minimum_qty IS NOT NULL
               AND v_allow_decimal
               AND v_minimum_qty <>
                   round(v_minimum_qty,v_decimal_precision) THEN
                v_errors := v_errors ||
                    private.g2_phase46_import_error(
                        'MINIMUM_STOCK_BASE_UOM_PRECISION_EXCEEDED'
                    );
            END IF;
        END IF;

        SELECT count(*),min(w.id::TEXT)::UUID
        INTO v_match_count,v_warehouse_id
        FROM public.warehouses w
        WHERE w.company_id = v_company
          AND w.is_active
          AND lower(regexp_replace(btrim(w.name),'\s+',' ','g')) =
              lower(v_warehouse_name);
        IF v_match_count = 0 THEN
            v_errors := v_errors ||
                private.g2_phase46_import_error(
                    'ACTIVE_WAREHOUSE_NOT_FOUND'
                );
        ELSIF v_match_count > 1 THEN
            v_errors := v_errors ||
                private.g2_phase46_import_error(
                    'AMBIGUOUS_WAREHOUSE_REFERENCE'
                );
            v_warehouse_id := NULL;
        END IF;

        IF v_job.reference_mode = 'REFERENCE_BY_ID' THEN
            v_internal_text := NULLIF(btrim(COALESCE(
                v_source->>(v_job.mapping->>'internalId'),''
            )),'');
            IF v_internal_text IS NOT NULL THEN
                BEGIN
                    v_internal_id := v_internal_text::UUID;
                    SELECT s.id INTO v_existing_id
                    FROM public.product_warehouse_stock_settings s
                    WHERE s.company_id = v_company
                      AND s.id = v_internal_id;
                    IF NOT FOUND THEN
                        v_errors := v_errors ||
                            private.g2_phase46_import_error(
                                'MINIMUM_STOCK_SETTING_ID_NOT_FOUND'
                            );
                    END IF;
                EXCEPTION WHEN invalid_text_representation THEN
                    v_errors := v_errors ||
                        private.g2_phase46_import_error(
                            'INVALID_INTERNAL_ID'
                        );
                END;
            END IF;
        END IF;

        IF v_existing_id IS NULL
           AND v_product_id IS NOT NULL
           AND v_warehouse_id IS NOT NULL THEN
            SELECT s.id INTO v_existing_id
            FROM public.product_warehouse_stock_settings s
            WHERE s.company_id = v_company
              AND s.product_id = v_product_id
              AND s.warehouse_id = v_warehouse_id;
        END IF;
        IF v_job.reference_mode = 'REFERENCE_BY_ID'
           AND v_internal_text IS NULL
           AND v_existing_id IS NOT NULL THEN
            v_errors := v_errors ||
                private.g2_phase46_import_error(
                    'IMPORT_INTERNAL_ID_REQUIRED_FOR_UPDATE'
                );
        END IF;

        IF jsonb_array_length(v_errors) = 0 THEN
            IF v_existing_id IS NULL THEN
                v_operation := 'CREATE';
                IF v_job.operation_mode = 'UPDATE_ONLY' THEN
                    v_errors := v_errors ||
                        private.g2_phase46_import_error(
                            'IMPORT_UPDATE_TARGET_NOT_FOUND'
                        );
                END IF;
            ELSE
                v_operation := 'UPDATE';
                IF v_job.operation_mode = 'CREATE_ONLY' THEN
                    v_errors := v_errors ||
                        private.g2_phase46_import_error(
                            'IMPORT_CREATE_ONLY_MATCHED_EXISTING'
                        );
                END IF;
            END IF;
        END IF;

        v_after := jsonb_build_object(
            'productId',v_product_id,
            'warehouseId',v_warehouse_id,
            'minimumStockBaseQty',v_minimum_qty,
            'lowStockAlertEnabled',v_alert_enabled
        );

        IF v_existing_id IS NOT NULL THEN
            SELECT * INTO v_existing
            FROM public.product_warehouse_stock_settings s
            WHERE s.company_id = v_company AND s.id = v_existing_id;
            IF v_job.reference_mode = 'REFERENCE_BY_ID'
               AND v_internal_text IS NOT NULL
               AND (
                   v_existing.product_id IS DISTINCT FROM v_product_id
                   OR v_existing.warehouse_id IS DISTINCT FROM v_warehouse_id
               ) THEN
                v_errors := v_errors ||
                    private.g2_phase46_import_error(
                        'MINIMUM_STOCK_SETTING_IDENTITY_MISMATCH'
                    );
            END IF;
            v_before := jsonb_build_object(
                'settingId',v_existing.id,
                'masterVersion',v_existing.master_version,
                'productId',v_existing.product_id,
                'warehouseId',v_existing.warehouse_id,
                'minimumStockBaseQty',
                    v_existing.minimum_stock_base_qty,
                'lowStockAlertEnabled',
                    v_existing.low_stock_alert_enabled
            );
            IF (v_before - 'settingId' - 'masterVersion') = v_after
               AND jsonb_array_length(v_errors) = 0 THEN
                v_operation := 'SKIP';
            END IF;
        END IF;

        UPDATE public.master_import_rows SET
            group_key = COALESCE(
                v_product_id::TEXT || ':' || v_warehouse_id::TEXT,
                'ROW:' || v_row.row_number
            ),
            normalized_data = jsonb_build_object(
                'productSku',v_product_sku,
                'warehouseName',v_warehouse_name,
                'productId',v_product_id,
                'warehouseId',v_warehouse_id
            ),
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

    -- A Product-Warehouse pair may occur only once in one file.
    UPDATE public.master_import_rows r SET
        operation = 'ERROR',row_status = 'ERROR',
        matched_record_id = NULL,matched_master_version = NULL,
        errors = errors || private.g2_phase46_import_error(
            'DUPLICATE_PRODUCT_WAREHOUSE_IN_FILE'
        ),
        before_state = NULL,after_state = NULL,
        updated_at = clock_timestamp()
    WHERE r.company_id = v_company
      AND r.job_id = p_job_id
      AND r.group_key IN (
          SELECT group_key
          FROM public.master_import_rows
          WHERE company_id = v_company
            AND job_id = p_job_id
            AND group_key NOT LIKE 'ROW:%'
          GROUP BY group_key
          HAVING count(*) > 1
      );

    SELECT
        count(*) FILTER (
            WHERE operation = 'CREATE' AND row_status = 'VALIDATED'
        ),
        count(*) FILTER (
            WHERE operation = 'UPDATE' AND row_status = 'VALIDATED'
        ),
        count(*) FILTER (
            WHERE operation = 'SKIP' AND row_status = 'VALIDATED'
        ),
        count(*) FILTER (WHERE row_status = 'ERROR')
    INTO v_created,v_updated,v_skipped,v_error_rows
    FROM public.master_import_rows
    WHERE company_id = v_company AND job_id = p_job_id;

    UPDATE public.master_import_jobs SET
        status = 'VALIDATED',
        created_rows = COALESCE(v_created,0),
        updated_rows = COALESCE(v_updated,0),
        skipped_rows = COALESCE(v_skipped,0),
        error_rows = COALESCE(v_error_rows,0),
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
    private.validate_master_import_minimum_stock_job(UUID,BIGINT)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
    private.validate_master_import_minimum_stock_job(UUID,BIGINT)
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
    IF v_import_type = 'PRODUCT_WAREHOUSE_MINIMUM_STOCK' THEN
        RETURN private.validate_master_import_minimum_stock_job(
            p_job_id,p_master_version
        );
    END IF;
    RETURN private.validate_master_import_job_phase44(
        p_job_id,p_master_version
    );
END;
$$;

REVOKE ALL ON FUNCTION public.validate_master_import_job(UUID,BIGINT)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.validate_master_import_job(UUID,BIGINT)
TO authenticated,service_role;

ALTER FUNCTION public.commit_master_import_job(UUID,BIGINT,INTEGER)
    RENAME TO commit_master_import_job_phase44;
ALTER FUNCTION public.commit_master_import_job_phase44(UUID,BIGINT,INTEGER)
    SET SCHEMA private;

REVOKE ALL ON FUNCTION
    private.commit_master_import_job_phase44(UUID,BIGINT,INTEGER)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
    private.commit_master_import_job_phase44(UUID,BIGINT,INTEGER)
TO service_role;

CREATE FUNCTION private.commit_master_import_minimum_stock_job(
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
    IF v_job.import_type <> 'PRODUCT_WAREHOUSE_MINIMUM_STOCK' THEN
        RAISE EXCEPTION 'INVALID_MINIMUM_STOCK_IMPORT_JOB';
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
        v_company::TEXT ||
        ':MASTER_IMPORT_COMMIT:PRODUCT_WAREHOUSE_MINIMUM_STOCK',0
    ));

    FOR v_row IN
        SELECT * FROM public.master_import_rows r
        WHERE r.company_id = v_company AND r.job_id = p_job_id
          AND r.operation IN ('CREATE','UPDATE','SKIP')
          AND r.row_status = 'VALIDATED'
        ORDER BY r.row_number
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
                SELECT 1
                FROM public.product_warehouse_stock_settings s
                WHERE s.company_id = v_company
                  AND s.id = v_row.matched_record_id
                  AND s.master_version = v_row.matched_master_version
            ) THEN
                RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
            END IF;

            v_result := public.save_product_warehouse_stock_setting(
                CASE WHEN v_row.operation = 'CREATE'
                    THEN NULL ELSE v_row.matched_record_id END,
                CASE WHEN v_row.operation = 'CREATE'
                    THEN NULL ELSE v_row.matched_master_version END,
                (v_after->>'productId')::UUID,
                (v_after->>'warehouseId')::UUID,
                NULLIF(v_after->>'minimumStockBaseQty','')::NUMERIC,
                (v_after->>'lowStockAlertEnabled')::BOOLEAN
            );
            v_record_id := (v_result->>'settingId')::UUID;
            v_result_version := (v_result->>'masterVersion')::BIGINT;

            UPDATE public.master_import_rows SET
                row_status = 'COMMITTED',
                matched_record_id = v_record_id,
                matched_master_version = v_result_version,
                after_state = after_state || jsonb_build_object(
                    'settingId',v_record_id,
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
                errors = errors || private.g2_phase46_import_error(
                    'MINIMUM_STOCK_COMMIT_FAILED',v_error
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
    private.commit_master_import_minimum_stock_job(UUID,BIGINT,INTEGER)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
    private.commit_master_import_minimum_stock_job(UUID,BIGINT,INTEGER)
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
    IF v_import_type = 'PRODUCT_WAREHOUSE_MINIMUM_STOCK' THEN
        RETURN private.commit_master_import_minimum_stock_job(
            p_job_id,p_master_version,p_confirm_update_count
        );
    END IF;
    RETURN private.commit_master_import_job_phase44(
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
    '20260728090000',
    'g2_phase46_product_warehouse_minimum_stock',
    'Tenant-scoped Product-Warehouse minimum-stock settings with guarded optimistic audit and fixed CSV import; no stock, request, or order mutation'
);

COMMIT;
