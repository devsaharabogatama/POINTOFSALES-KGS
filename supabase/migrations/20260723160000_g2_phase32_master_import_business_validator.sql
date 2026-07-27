-- KGS POS G2 phase 32: business-field dry-run validation for non-stock import.
-- Dependency: phase 31 identity validator 20260723130000.
--
-- Forward-only hook: enriches Phase-31 row preview with the same business
-- constraints used by manual Category/UOM/Warehouse/Supplier CRUD.
-- It never commits a row to a business master.

BEGIN;

DO $migration_guard$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260723130000'
    ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: phase 31 identity validator required';
    END IF;
    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260723160000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260723160000';
    END IF;
END
$migration_guard$;

CREATE FUNCTION private.trg_g2_validate_import_business_fields()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_job public.master_import_jobs%ROWTYPE;
    v_column TEXT;
    v_text TEXT;
    v_error TEXT;
    v_before JSONB;
    v_after JSONB := COALESCE(NEW.after_state,'{}'::JSONB);
    v_uom_type TEXT;
    v_allow_decimal BOOLEAN;
    v_decimal_precision SMALLINT;
    v_warehouse_type TEXT;
    v_store_id UUID;
    v_location TEXT;
    v_is_sale_source BOOLEAN;
    v_is_purchase_destination BOOLEAN;
    v_contact_name TEXT;
    v_phone TEXT;
    v_address TEXT;
    v_npwp TEXT;
    v_payment_term TEXT;
    v_bank_name TEXT;
    v_bank_account_number TEXT;
    v_bank_account_holder TEXT;
BEGIN
    -- Reset and duplicate-file updates also touch operation/status. Only enrich
    -- the first successful Phase-31 validation result.
    IF NEW.row_status <> 'VALIDATED' OR NEW.operation = 'ERROR' THEN
        RETURN NEW;
    END IF;

    SELECT * INTO v_job
    FROM public.master_import_jobs j
    WHERE j.company_id = NEW.company_id AND j.id = NEW.job_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'IMPORT_JOB_NOT_FOUND';
    END IF;

    -- Manual CRUD stores every business code in uppercase. Preview and future
    -- commit must expose the same canonical value, not raw file casing.
    v_after := v_after || jsonb_build_object(
        'code',upper(v_after->>'code')
    );

    IF v_job.import_type = 'PRODUCT_CATEGORY' THEN
        IF char_length(v_after->>'code') > 50 THEN
            v_error := 'CATEGORY_CODE_TOO_LONG';
        ELSIF char_length(v_after->>'name') > 150 THEN
            v_error := 'CATEGORY_NAME_TOO_LONG';
        END IF;

        IF NEW.matched_record_id IS NOT NULL THEN
            SELECT jsonb_build_object(
                'id',x.id,'code',x.category_code,'name',x.category_name,
                'isActive',x.is_active
            ) INTO v_before
            FROM public.product_categories x
            WHERE x.company_id = NEW.company_id
              AND x.id = NEW.matched_record_id;
        END IF;

    ELSIF v_job.import_type = 'UOM' THEN
        IF char_length(v_after->>'code') > 30 THEN
            v_error := 'UOM_CODE_TOO_LONG';
        ELSIF char_length(v_after->>'name') > 100 THEN
            v_error := 'UOM_NAME_TOO_LONG';
        END IF;

        IF NEW.matched_record_id IS NOT NULL THEN
            SELECT
                jsonb_build_object(
                    'id',x.id,'code',x.code,'name',x.name,
                    'isActive',x.is_active,'uomType',x.uom_type,
                    'allowDecimal',x.allow_decimal,
                    'decimalPrecision',x.decimal_precision
                ),x.uom_type,x.allow_decimal,x.decimal_precision
            INTO v_before,v_uom_type,v_allow_decimal,v_decimal_precision
            FROM public.uoms x
            WHERE x.company_id = NEW.company_id
              AND x.id = NEW.matched_record_id;
        ELSE
            v_allow_decimal := FALSE;
            v_decimal_precision := 0;
        END IF;

        v_column := NULLIF(btrim(v_job.mapping->>'uomType'),'');
        IF v_column IS NULL THEN
            v_error := COALESCE(v_error,'UOM_TYPE_MAPPING_REQUIRED');
        ELSE
            v_uom_type := upper(btrim(COALESCE(NEW.source_data->>v_column,'')));
            IF v_uom_type NOT IN (
                'UNIT','PACKAGING','WEIGHT','VOLUME','LENGTH','OTHER'
            ) THEN
                v_error := COALESCE(v_error,'UOM_TYPE_INVALID');
            END IF;
        END IF;

        v_column := NULLIF(btrim(v_job.mapping->>'allowDecimal'),'');
        IF v_column IS NOT NULL THEN
            v_text := NULLIF(lower(btrim(NEW.source_data->>v_column)),'');
            IF v_text IS NULL THEN
                NULL;
            ELSIF v_text IN ('true','t','1','yes','y','ya','aktif','active') THEN
                v_allow_decimal := TRUE;
            ELSIF v_text IN ('false','f','0','no','n','tidak','nonaktif','inactive') THEN
                v_allow_decimal := FALSE;
            ELSE
                v_error := COALESCE(v_error,'ALLOW_DECIMAL_INVALID');
            END IF;
        END IF;

        v_column := NULLIF(btrim(v_job.mapping->>'decimalPrecision'),'');
        IF v_column IS NOT NULL THEN
            v_text := NULLIF(btrim(NEW.source_data->>v_column),'');
            IF v_text IS NOT NULL THEN
                IF v_text !~ '^[0-9]+$' OR char_length(v_text) > 2 THEN
                    v_error := COALESCE(v_error,'DECIMAL_PRECISION_INVALID');
                ELSE
                    v_decimal_precision := v_text::SMALLINT;
                END IF;
            END IF;
        ELSIF NEW.matched_record_id IS NULL AND v_allow_decimal THEN
            v_decimal_precision := 3;
        END IF;

        IF NOT v_allow_decimal THEN
            IF COALESCE(v_decimal_precision,0) <> 0 THEN
                v_error := COALESCE(
                    v_error,'INTEGER_UOM_PRECISION_MUST_BE_ZERO'
                );
            END IF;
            v_decimal_precision := 0;
        ELSIF v_decimal_precision NOT BETWEEN 1 AND 6 THEN
            v_error := COALESCE(v_error,'DECIMAL_PRECISION_INVALID');
        END IF;

        v_after := v_after || jsonb_build_object(
            'uomType',v_uom_type,
            'allowDecimal',v_allow_decimal,
            'decimalPrecision',v_decimal_precision
        );

    ELSIF v_job.import_type = 'WAREHOUSE' THEN
        IF (v_after->>'code') !~ '^[A-Z]{1,5}$' THEN
            v_error := 'WAREHOUSE_CODE_INVALID';
        ELSIF char_length(v_after->>'name') > 150 THEN
            v_error := 'WAREHOUSE_NAME_TOO_LONG';
        END IF;

        IF NEW.matched_record_id IS NOT NULL THEN
            SELECT
                jsonb_build_object(
                    'id',x.id,'code',x.code,'name',x.name,
                    'isActive',x.is_active,'warehouseType',x.warehouse_type,
                    'storeId',x.store_id,'location',x.location,
                    'isSaleSource',x.is_sale_source,
                    'isPurchaseDestination',x.is_purchase_destination,
                    'allowNegativeStock',x.allow_negative_stock
                ),x.warehouse_type,x.store_id,x.location,x.is_sale_source,
                x.is_purchase_destination
            INTO v_before,v_warehouse_type,v_store_id,v_location,
                v_is_sale_source,v_is_purchase_destination
            FROM public.warehouses x
            WHERE x.company_id = NEW.company_id
              AND x.id = NEW.matched_record_id;
        ELSE
            v_is_sale_source := FALSE;
            v_is_purchase_destination := FALSE;
        END IF;

        v_column := NULLIF(btrim(v_job.mapping->>'warehouseType'),'');
        IF v_column IS NULL THEN
            v_error := COALESCE(v_error,'WAREHOUSE_TYPE_MAPPING_REQUIRED');
        ELSE
            v_warehouse_type := upper(btrim(
                COALESCE(NEW.source_data->>v_column,'')
            ));
            IF v_warehouse_type NOT IN (
                'CENTRAL','STORE','DAMAGED','TRANSIT'
            ) THEN
                v_error := COALESCE(v_error,'WAREHOUSE_TYPE_INVALID');
            END IF;
        END IF;

        v_column := NULLIF(btrim(v_job.mapping->>'storeId'),'');
        IF v_column IS NOT NULL THEN
            v_text := NULLIF(btrim(NEW.source_data->>v_column),'');
            IF v_text IS NULL THEN
                v_store_id := NULL;
            ELSIF v_text !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
                v_error := COALESCE(v_error,'STORE_ID_INVALID');
            ELSE
                v_store_id := v_text::UUID;
            END IF;
        END IF;

        IF v_store_id IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM public.stores s
            WHERE s.company_id = NEW.company_id
              AND s.id = v_store_id AND s.status = 'ACTIVE'
        ) THEN
            v_error := COALESCE(v_error,'ACTIVE_STORE_NOT_FOUND');
        END IF;
        IF v_warehouse_type = 'STORE' AND v_store_id IS NULL THEN
            v_error := COALESCE(v_error,'STORE_WAREHOUSE_REQUIRES_STORE');
        END IF;

        v_column := NULLIF(btrim(v_job.mapping->>'location'),'');
        IF v_column IS NOT NULL THEN
            v_location := NULLIF(regexp_replace(
                btrim(NEW.source_data->>v_column),'\s+',' ','g'
            ),'');
        END IF;
        IF char_length(v_location) > 500 THEN
            v_error := COALESCE(v_error,'WAREHOUSE_LOCATION_TOO_LONG');
        END IF;

        v_column := NULLIF(btrim(v_job.mapping->>'isSaleSource'),'');
        IF v_column IS NOT NULL THEN
            v_text := NULLIF(lower(btrim(NEW.source_data->>v_column)),'');
            IF v_text IS NULL THEN NULL;
            ELSIF v_text IN ('true','t','1','yes','y','ya','aktif','active') THEN
                v_is_sale_source := TRUE;
            ELSIF v_text IN ('false','f','0','no','n','tidak','nonaktif','inactive') THEN
                v_is_sale_source := FALSE;
            ELSE
                v_error := COALESCE(v_error,'IS_SALE_SOURCE_INVALID');
            END IF;
        END IF;

        v_column := NULLIF(btrim(v_job.mapping->>'isPurchaseDestination'),'');
        IF v_column IS NOT NULL THEN
            v_text := NULLIF(lower(btrim(NEW.source_data->>v_column)),'');
            IF v_text IS NULL THEN NULL;
            ELSIF v_text IN ('true','t','1','yes','y','ya','aktif','active') THEN
                v_is_purchase_destination := TRUE;
            ELSIF v_text IN ('false','f','0','no','n','tidak','nonaktif','inactive') THEN
                v_is_purchase_destination := FALSE;
            ELSE
                v_error := COALESCE(
                    v_error,'IS_PURCHASE_DESTINATION_INVALID'
                );
            END IF;
        END IF;

        v_after := v_after || jsonb_build_object(
            'warehouseType',v_warehouse_type,'storeId',v_store_id,
            'location',v_location,'isSaleSource',v_is_sale_source,
            'isPurchaseDestination',v_is_purchase_destination,
            'allowNegativeStock',FALSE
        );

    ELSIF v_job.import_type = 'SUPPLIER' THEN
        IF char_length(v_after->>'code') > 100 THEN
            v_error := 'SUPPLIER_CODE_TOO_LONG';
        ELSIF char_length(v_after->>'name') > 200 THEN
            v_error := 'SUPPLIER_NAME_TOO_LONG';
        END IF;

        IF NEW.matched_record_id IS NOT NULL THEN
            SELECT
                jsonb_build_object(
                    'id',x.id,'code',x.supplier_code,'name',x.supplier_name,
                    'isActive',x.is_active,'contactName',x.contact_name,
                    'phone',x.phone,'address',x.address,'npwp',x.npwp,
                    'paymentTerm',x.payment_term,'bankName',x.bank_name,
                    'bankAccountNumber',x.bank_account_number,
                    'bankAccountHolder',x.bank_account_holder
                ),x.contact_name,x.phone,x.address,x.npwp,x.payment_term,
                x.bank_name,x.bank_account_number,x.bank_account_holder
            INTO v_before,v_contact_name,v_phone,v_address,v_npwp,
                v_payment_term,v_bank_name,v_bank_account_number,
                v_bank_account_holder
            FROM public.suppliers x
            WHERE x.company_id = NEW.company_id
              AND x.id = NEW.matched_record_id;
        END IF;

        v_column := NULLIF(btrim(v_job.mapping->>'contactName'),'');
        IF v_column IS NOT NULL THEN
            v_contact_name := NULLIF(regexp_replace(
                btrim(NEW.source_data->>v_column),'\s+',' ','g'
            ),'');
        END IF;
        v_column := NULLIF(btrim(v_job.mapping->>'phone'),'');
        IF v_column IS NOT NULL THEN
            v_phone := NULLIF(regexp_replace(
                btrim(NEW.source_data->>v_column),'\s+',' ','g'
            ),'');
        END IF;
        v_column := NULLIF(btrim(v_job.mapping->>'address'),'');
        IF v_column IS NOT NULL THEN
            v_address := NULLIF(regexp_replace(
                btrim(NEW.source_data->>v_column),'\s+',' ','g'
            ),'');
        END IF;
        v_column := NULLIF(btrim(v_job.mapping->>'npwp'),'');
        IF v_column IS NOT NULL THEN
            v_npwp := NULLIF(regexp_replace(
                btrim(NEW.source_data->>v_column),'\s+',' ','g'
            ),'');
        END IF;
        v_column := NULLIF(btrim(v_job.mapping->>'paymentTerm'),'');
        IF v_column IS NOT NULL THEN
            v_payment_term := NULLIF(regexp_replace(
                btrim(NEW.source_data->>v_column),'\s+',' ','g'
            ),'');
        END IF;
        v_column := NULLIF(btrim(v_job.mapping->>'bankName'),'');
        IF v_column IS NOT NULL THEN
            v_bank_name := NULLIF(regexp_replace(
                btrim(NEW.source_data->>v_column),'\s+',' ','g'
            ),'');
        END IF;
        v_column := NULLIF(btrim(v_job.mapping->>'bankAccountNumber'),'');
        IF v_column IS NOT NULL THEN
            v_bank_account_number := NULLIF(regexp_replace(
                btrim(NEW.source_data->>v_column),'\s+',' ','g'
            ),'');
        END IF;
        v_column := NULLIF(btrim(v_job.mapping->>'bankAccountHolder'),'');
        IF v_column IS NOT NULL THEN
            v_bank_account_holder := NULLIF(regexp_replace(
                btrim(NEW.source_data->>v_column),'\s+',' ','g'
            ),'');
        END IF;

        IF char_length(v_contact_name) > 200 THEN
            v_error := COALESCE(v_error,'SUPPLIER_CONTACT_NAME_TOO_LONG');
        ELSIF char_length(v_phone) > 100 THEN
            v_error := COALESCE(v_error,'SUPPLIER_PHONE_TOO_LONG');
        ELSIF char_length(v_address) > 1000 THEN
            v_error := COALESCE(v_error,'SUPPLIER_ADDRESS_TOO_LONG');
        ELSIF char_length(v_npwp) > 100 THEN
            v_error := COALESCE(v_error,'SUPPLIER_NPWP_TOO_LONG');
        ELSIF char_length(v_payment_term) > 200 THEN
            v_error := COALESCE(v_error,'SUPPLIER_PAYMENT_TERM_TOO_LONG');
        ELSIF char_length(v_bank_name) > 200 THEN
            v_error := COALESCE(v_error,'SUPPLIER_BANK_NAME_TOO_LONG');
        ELSIF char_length(v_bank_account_number) > 100 THEN
            v_error := COALESCE(v_error,'SUPPLIER_BANK_ACCOUNT_TOO_LONG');
        ELSIF char_length(v_bank_account_holder) > 200 THEN
            v_error := COALESCE(v_error,'SUPPLIER_BANK_HOLDER_TOO_LONG');
        END IF;

        v_after := v_after || jsonb_build_object(
            'contactName',v_contact_name,'phone',v_phone,'address',v_address,
            'npwp',v_npwp,'paymentTerm',v_payment_term,'bankName',v_bank_name,
            'bankAccountNumber',v_bank_account_number,
            'bankAccountHolder',v_bank_account_holder
        );
    END IF;

    IF v_error IS NOT NULL THEN
        NEW.operation := 'ERROR';
        NEW.row_status := 'ERROR';
        NEW.errors := NEW.errors || jsonb_build_array(
            jsonb_build_object('code',v_error)
        );
        NEW.before_state := v_before;
        NEW.after_state := NULL;
        RETURN NEW;
    END IF;

    NEW.before_state := v_before;
    NEW.after_state := v_after;
    NEW.normalized_data := COALESCE(NEW.normalized_data,'{}'::JSONB)
        || (v_after - 'id');

    IF NEW.matched_record_id IS NOT NULL
       AND NEW.operation = 'SKIP'
       AND v_before IS DISTINCT FROM v_after THEN
        NEW.operation := 'UPDATE';
        NEW.warnings := NEW.warnings || jsonb_build_array(
            jsonb_build_object('code','UPDATE_EXISTING_CONFIRMATION_REQUIRED')
        );
    END IF;
    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION private.trg_g2_validate_import_business_fields()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.trg_g2_validate_import_business_fields()
TO service_role;

CREATE TRIGGER g2_validate_import_business_fields
BEFORE UPDATE OF operation,row_status ON public.master_import_rows
FOR EACH ROW EXECUTE FUNCTION private.trg_g2_validate_import_business_fields();

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES (
    '20260723160000',
    'g2_phase32_master_import_business_validator',
    'Dry-run Category/UOM/Warehouse/Supplier field validation aligned with manual CRUD; enriches preview only and does not commit master data'
);

COMMIT;

-- Forward-fix note: commit RPC remains a later additive phase. Do not edit
-- this migration after apply.
