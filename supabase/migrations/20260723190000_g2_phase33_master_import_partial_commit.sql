-- KGS POS G2 phase 33: guarded partial commit for four non-stock masters.
-- Dependency: phase 32 business validator 20260723160000.
--
-- Category/UOM/Warehouse/Supplier only. Product, Product-UOM, Brand, Opening
-- Stock, and every inventory mutation remain disabled.

BEGIN;

DO $migration_guard$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260723160000'
    ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: phase 32 business validator required';
    END IF;
    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260723190000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260723190000';
    END IF;
END
$migration_guard$;

ALTER TABLE public.master_import_rows
    ADD COLUMN matched_master_version BIGINT,
    ADD CONSTRAINT master_import_rows_matched_version_positive
        CHECK(matched_master_version IS NULL OR matched_master_version > 0);

-- Preserve optimistic concurrency for any already-validated preview.
UPDATE public.master_import_rows r
SET matched_master_version = x.master_version
FROM public.master_import_jobs j,public.product_categories x
WHERE j.company_id = r.company_id AND j.id = r.job_id
  AND j.import_type = 'PRODUCT_CATEGORY'
  AND x.company_id = r.company_id AND x.id = r.matched_record_id;

UPDATE public.master_import_rows r
SET matched_master_version = x.master_version
FROM public.master_import_jobs j,public.uoms x
WHERE j.company_id = r.company_id AND j.id = r.job_id
  AND j.import_type = 'UOM'
  AND x.company_id = r.company_id AND x.id = r.matched_record_id;

UPDATE public.master_import_rows r
SET matched_master_version = x.master_version
FROM public.master_import_jobs j,public.warehouses x
WHERE j.company_id = r.company_id AND j.id = r.job_id
  AND j.import_type = 'WAREHOUSE'
  AND x.company_id = r.company_id AND x.id = r.matched_record_id;

UPDATE public.master_import_rows r
SET matched_master_version = x.master_version
FROM public.master_import_jobs j,public.suppliers x
WHERE j.company_id = r.company_id AND j.id = r.job_id
  AND j.import_type = 'SUPPLIER'
  AND x.company_id = r.company_id AND x.id = r.matched_record_id;

CREATE FUNCTION private.trg_g2_capture_import_master_version()
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
    END IF;
    NEW.matched_master_version := v_master_version;
    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION private.trg_g2_capture_import_master_version()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.trg_g2_capture_import_master_version()
TO service_role;

-- Alphabetical trigger order makes capture run before the phase-32 business
-- validator on the same BEFORE UPDATE event.
CREATE TRIGGER g2_capture_import_master_version
BEFORE UPDATE OF operation,row_status ON public.master_import_rows
FOR EACH ROW EXECUTE FUNCTION private.trg_g2_capture_import_master_version();

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
    v_record_id UUID;
    v_result_version BIGINT;
    v_supplier_before JSONB;
    v_supplier_after JSONB;
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
    IF p_confirm_update_count IS NULL OR p_confirm_update_count < 0 THEN
        RAISE EXCEPTION 'IMPORT_UPDATE_CONFIRMATION_REQUIRED';
    END IF;
    IF p_confirm_update_count <> v_job.updated_rows THEN
        RAISE EXCEPTION 'IMPORT_UPDATE_CONFIRMATION_REQUIRED';
    END IF;

    -- Serialize commits per Company/master type. Manual CRUD races remain safe
    -- through optimistic matched_master_version and unique constraints.
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
            IF v_job.import_type = 'PRODUCT_CATEGORY' THEN
                IF v_row.operation = 'CREATE' THEN
                    INSERT INTO public.product_categories(
                        company_id,category_code,category_name,is_active,
                        created_by,updated_by
                    ) VALUES (
                        v_company,v_row.after_state->>'code',
                        v_row.after_state->>'name',
                        (v_row.after_state->>'isActive')::BOOLEAN,
                        v_actor,v_actor
                    ) RETURNING id,master_version
                    INTO v_record_id,v_result_version;
                ELSE
                    UPDATE public.product_categories SET
                        category_code = v_row.after_state->>'code',
                        category_name = v_row.after_state->>'name',
                        is_active = (v_row.after_state->>'isActive')::BOOLEAN,
                        updated_by = v_actor
                    WHERE company_id = v_company
                      AND id = v_row.matched_record_id
                      AND master_version = v_row.matched_master_version
                    RETURNING id,master_version
                    INTO v_record_id,v_result_version;
                    IF NOT FOUND THEN v_error := 'MASTER_CHANGED_AFTER_VALIDATION'; END IF;
                END IF;

            ELSIF v_job.import_type = 'UOM' THEN
                IF v_row.operation = 'CREATE' THEN
                    INSERT INTO public.uoms(
                        company_id,code,name,uom_type,allow_decimal,
                        decimal_precision,is_active,created_by,updated_by
                    ) VALUES (
                        v_company,v_row.after_state->>'code',
                        v_row.after_state->>'name',
                        v_row.after_state->>'uomType',
                        (v_row.after_state->>'allowDecimal')::BOOLEAN,
                        (v_row.after_state->>'decimalPrecision')::SMALLINT,
                        (v_row.after_state->>'isActive')::BOOLEAN,
                        v_actor,v_actor
                    ) RETURNING id,master_version
                    INTO v_record_id,v_result_version;
                ELSE
                    UPDATE public.uoms SET
                        code = v_row.after_state->>'code',
                        name = v_row.after_state->>'name',
                        uom_type = v_row.after_state->>'uomType',
                        allow_decimal =
                            (v_row.after_state->>'allowDecimal')::BOOLEAN,
                        decimal_precision =
                            (v_row.after_state->>'decimalPrecision')::SMALLINT,
                        is_active = (v_row.after_state->>'isActive')::BOOLEAN,
                        updated_by = v_actor
                    WHERE company_id = v_company
                      AND id = v_row.matched_record_id
                      AND master_version = v_row.matched_master_version
                    RETURNING id,master_version
                    INTO v_record_id,v_result_version;
                    IF NOT FOUND THEN v_error := 'MASTER_CHANGED_AFTER_VALIDATION'; END IF;
                END IF;

            ELSIF v_job.import_type = 'WAREHOUSE' THEN
                IF v_row.operation = 'CREATE' THEN
                    INSERT INTO public.warehouses(
                        company_id,code,name,warehouse_type,store_id,location,
                        is_sale_source,is_purchase_destination,
                        allow_negative_stock,is_active,created_by,updated_by
                    ) VALUES (
                        v_company,v_row.after_state->>'code',
                        v_row.after_state->>'name',
                        v_row.after_state->>'warehouseType',
                        (v_row.after_state->>'storeId')::UUID,
                        NULLIF(v_row.after_state->>'location',''),
                        (v_row.after_state->>'isSaleSource')::BOOLEAN,
                        (v_row.after_state->>'isPurchaseDestination')::BOOLEAN,
                        FALSE,(v_row.after_state->>'isActive')::BOOLEAN,
                        v_actor,v_actor
                    ) RETURNING id,master_version
                    INTO v_record_id,v_result_version;
                ELSE
                    UPDATE public.warehouses SET
                        code = v_row.after_state->>'code',
                        name = v_row.after_state->>'name',
                        warehouse_type = v_row.after_state->>'warehouseType',
                        store_id = (v_row.after_state->>'storeId')::UUID,
                        location = NULLIF(v_row.after_state->>'location',''),
                        is_sale_source =
                            (v_row.after_state->>'isSaleSource')::BOOLEAN,
                        is_purchase_destination =
                            (v_row.after_state->>'isPurchaseDestination')::BOOLEAN,
                        allow_negative_stock = FALSE,
                        is_active = (v_row.after_state->>'isActive')::BOOLEAN,
                        updated_by = v_actor
                    WHERE company_id = v_company
                      AND id = v_row.matched_record_id
                      AND master_version = v_row.matched_master_version
                    RETURNING id,master_version
                    INTO v_record_id,v_result_version;
                    IF NOT FOUND THEN v_error := 'MASTER_CHANGED_AFTER_VALIDATION'; END IF;
                END IF;

            ELSIF v_job.import_type = 'SUPPLIER' THEN
                IF v_row.operation = 'CREATE' THEN
                    INSERT INTO public.suppliers(
                        company_id,supplier_code,supplier_name,contact_name,
                        phone,address,npwp,payment_term,bank_name,
                        bank_account_number,bank_account_holder,is_active,
                        created_by,updated_by
                    ) VALUES (
                        v_company,v_row.after_state->>'code',
                        v_row.after_state->>'name',
                        NULLIF(v_row.after_state->>'contactName',''),
                        NULLIF(v_row.after_state->>'phone',''),
                        NULLIF(v_row.after_state->>'address',''),
                        NULLIF(v_row.after_state->>'npwp',''),
                        NULLIF(v_row.after_state->>'paymentTerm',''),
                        NULLIF(v_row.after_state->>'bankName',''),
                        NULLIF(v_row.after_state->>'bankAccountNumber',''),
                        NULLIF(v_row.after_state->>'bankAccountHolder',''),
                        (v_row.after_state->>'isActive')::BOOLEAN,
                        v_actor,v_actor
                    ) RETURNING id,master_version
                    INTO v_record_id,v_result_version;
                    SELECT to_jsonb(x) INTO v_supplier_after
                    FROM public.suppliers x
                    WHERE x.company_id = v_company AND x.id = v_record_id;
                    INSERT INTO public.supplier_master_audit(
                        company_id,supplier_id,action,actor_id,
                        before_state,after_state
                    ) VALUES (
                        v_company,v_record_id,'CREATE',v_actor,
                        NULL,v_supplier_after
                    );
                ELSE
                    SELECT to_jsonb(x) INTO v_supplier_before
                    FROM public.suppliers x
                    WHERE x.company_id = v_company
                      AND x.id = v_row.matched_record_id
                      AND x.master_version = v_row.matched_master_version
                    FOR UPDATE;
                    IF NOT FOUND THEN
                        v_error := 'MASTER_CHANGED_AFTER_VALIDATION';
                    ELSE
                        UPDATE public.suppliers SET
                            supplier_code = v_row.after_state->>'code',
                            supplier_name = v_row.after_state->>'name',
                            contact_name = NULLIF(
                                v_row.after_state->>'contactName',''
                            ),
                            phone = NULLIF(v_row.after_state->>'phone',''),
                            address = NULLIF(v_row.after_state->>'address',''),
                            npwp = NULLIF(v_row.after_state->>'npwp',''),
                            payment_term = NULLIF(
                                v_row.after_state->>'paymentTerm',''
                            ),
                            bank_name = NULLIF(
                                v_row.after_state->>'bankName',''
                            ),
                            bank_account_number = NULLIF(
                                v_row.after_state->>'bankAccountNumber',''
                            ),
                            bank_account_holder = NULLIF(
                                v_row.after_state->>'bankAccountHolder',''
                            ),
                            is_active =
                                (v_row.after_state->>'isActive')::BOOLEAN,
                            updated_by = v_actor
                        WHERE company_id = v_company
                          AND id = v_row.matched_record_id
                          AND master_version = v_row.matched_master_version
                        RETURNING id,master_version
                        INTO v_record_id,v_result_version;
                        IF NOT FOUND THEN
                            v_error := 'MASTER_CHANGED_AFTER_VALIDATION';
                        ELSE
                            SELECT to_jsonb(x) INTO v_supplier_after
                            FROM public.suppliers x
                            WHERE x.company_id = v_company
                              AND x.id = v_record_id;
                            INSERT INTO public.supplier_master_audit(
                                company_id,supplier_id,action,actor_id,
                                before_state,after_state
                            ) VALUES (
                                v_company,v_record_id,'UPDATE',v_actor,
                                v_supplier_before,v_supplier_after
                            );
                        END IF;
                    END IF;
                END IF;
            ELSE
                v_error := 'UNSUPPORTED_IMPORT_TYPE';
            END IF;

        EXCEPTION
            WHEN unique_violation THEN
                v_error := 'DUPLICATE_MASTER_AT_COMMIT';
            WHEN foreign_key_violation THEN
                v_error := 'INVALID_REFERENCE_AT_COMMIT';
            WHEN check_violation THEN
                v_error := 'MASTER_VALIDATION_CHANGED_AT_COMMIT';
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

REVOKE ALL ON FUNCTION public.commit_master_import_job(UUID,BIGINT,INTEGER)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.commit_master_import_job(UUID,BIGINT,INTEGER)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES (
    '20260723190000',
    'g2_phase33_master_import_partial_commit',
    'Guarded optimistic partial commit for Category/UOM/Warehouse/Supplier with explicit update confirmation, per-row error isolation, audit, and lost-response idempotency; Product and stock remain disabled'
);

COMMIT;

-- Forward-fix note: API/UI, export/error download, Product import, and Opening
-- Stock remain additive later phases. Do not edit this migration after apply.
