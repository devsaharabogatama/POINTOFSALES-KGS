-- KGS POS G2 phase 36: automatic hidden technical codes.
-- Requirement: MST-005
-- Dependency: canonical master/import chain through 20260723190000.
--
-- FORWARD-ONLY COMPATIBILITY:
-- - UUID remains the canonical identity;
-- - every existing business/technical code is preserved byte-for-byte;
-- - explicit-code RPC signatures remain for applied import compatibility;
-- - new overloads omit the code and allocate it server-side;
-- - new direct-table rows allocate only when the code is NULL/blank;
-- - technical codes become immutable after insert.

BEGIN;

DO $migration_guard$
BEGIN
    IF to_regclass('private.kgs_schema_migrations') IS NULL
       OR NOT EXISTS (
           SELECT 1 FROM private.kgs_schema_migrations
           WHERE version='20260723190000'
       ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: phase 33 import chain is incomplete';
    END IF;
    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version='20260724010000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260724010000';
    END IF;
END
$migration_guard$;

CREATE TABLE private.master_code_counters (
    company_id UUID NOT NULL
        REFERENCES public.companies(id) ON DELETE CASCADE,
    entity_type TEXT NOT NULL,
    last_value BIGINT NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY(company_id,entity_type),
    CONSTRAINT master_code_counters_entity_check CHECK (
        entity_type IN (
            'PRODUCT_CATEGORY','UOM','WAREHOUSE','SUPPLIER',
            'CUSTOMER_CATEGORY','PRICELIST','PAYMENT_METHOD',
            'TRANSACTION_CATEGORY'
        )
    ),
    CONSTRAINT master_code_counters_value_positive CHECK (last_value > 0)
);

REVOKE ALL ON private.master_code_counters FROM PUBLIC,anon,authenticated;
GRANT ALL ON private.master_code_counters TO service_role;

-- Seed only prefixes that already follow the new format. Legacy codes stay
-- untouched and do not consume/rename a number unless they already occupy it.
WITH target_codes(company_id,entity_type,prefix,technical_code) AS (
    SELECT company_id,'PRODUCT_CATEGORY','CAT',category_code
    FROM public.product_categories
    UNION ALL
    SELECT company_id,'UOM','UOM',code FROM public.uoms
    UNION ALL
    SELECT company_id,'WAREHOUSE','WH',code FROM public.warehouses
    UNION ALL
    SELECT company_id,'SUPPLIER','SUP',supplier_code FROM public.suppliers
    UNION ALL
    SELECT company_id,'CUSTOMER_CATEGORY','CC',category_code
    FROM public.customer_categories
    UNION ALL
    SELECT company_id,'PRICELIST','PL',code FROM public.pricelists
    UNION ALL
    SELECT company_id,'PAYMENT_METHOD','PAY',payment_method_code
    FROM public.payment_methods
    UNION ALL
    SELECT company_id,'TRANSACTION_CATEGORY','TC',category_code
    FROM public.transaction_categories
), generated_codes AS (
    SELECT
        company_id,entity_type,
        split_part(technical_code,'-',2)::BIGINT AS allocated_value
    FROM target_codes
    WHERE upper(technical_code) ~ ('^'||prefix||'-[0-9]{6,18}$')
)
INSERT INTO private.master_code_counters(company_id,entity_type,last_value)
SELECT company_id,entity_type,max(allocated_value)
FROM generated_codes
GROUP BY company_id,entity_type;

CREATE FUNCTION private.allocate_master_code(
    p_company_id UUID,
    p_entity_type TEXT
)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_entity TEXT := upper(btrim(COALESCE(p_entity_type,'')));
    v_prefix TEXT;
    v_value BIGINT;
BEGIN
    IF p_company_id IS NULL THEN
        RAISE EXCEPTION 'MASTER_CODE_COMPANY_REQUIRED';
    END IF;
    v_prefix := CASE v_entity
        WHEN 'PRODUCT_CATEGORY' THEN 'CAT'
        WHEN 'UOM' THEN 'UOM'
        WHEN 'WAREHOUSE' THEN 'WH'
        WHEN 'SUPPLIER' THEN 'SUP'
        WHEN 'CUSTOMER_CATEGORY' THEN 'CC'
        WHEN 'PRICELIST' THEN 'PL'
        WHEN 'PAYMENT_METHOD' THEN 'PAY'
        WHEN 'TRANSACTION_CATEGORY' THEN 'TC'
    END;
    IF v_prefix IS NULL THEN
        RAISE EXCEPTION 'UNSUPPORTED_MASTER_CODE_ENTITY';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM public.companies c WHERE c.id=p_company_id
    ) THEN
        RAISE EXCEPTION 'MASTER_CODE_COMPANY_NOT_FOUND';
    END IF;

    INSERT INTO private.master_code_counters AS counter(
        company_id,entity_type,last_value,updated_at
    ) VALUES (
        p_company_id,v_entity,1,clock_timestamp()
    )
    ON CONFLICT(company_id,entity_type) DO UPDATE SET
        last_value=counter.last_value+1,
        updated_at=clock_timestamp()
    RETURNING last_value INTO v_value;

    RETURN v_prefix||'-'||lpad(v_value::TEXT,6,'0');
END;
$$;

CREATE FUNCTION private.resolve_or_allocate_master_code(
    p_entity_type TEXT,
    p_entity_id UUID,
    p_not_found_error TEXT
)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_company UUID := public.private_active_company_id();
    v_entity TEXT := upper(btrim(COALESCE(p_entity_type,'')));
    v_code TEXT;
BEGIN
    IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF p_entity_id IS NULL THEN
        RETURN private.allocate_master_code(v_company,v_entity);
    END IF;

    CASE v_entity
        WHEN 'SUPPLIER' THEN
            SELECT supplier_code INTO v_code FROM public.suppliers
            WHERE company_id=v_company AND id=p_entity_id;
        WHEN 'CUSTOMER_CATEGORY' THEN
            SELECT category_code INTO v_code FROM public.customer_categories
            WHERE company_id=v_company AND id=p_entity_id;
        WHEN 'PRICELIST' THEN
            SELECT code INTO v_code FROM public.pricelists
            WHERE company_id=v_company AND id=p_entity_id;
        WHEN 'PAYMENT_METHOD' THEN
            SELECT payment_method_code INTO v_code FROM public.payment_methods
            WHERE company_id=v_company AND id=p_entity_id;
        WHEN 'TRANSACTION_CATEGORY' THEN
            SELECT category_code INTO v_code
            FROM public.transaction_categories
            WHERE company_id=v_company AND id=p_entity_id;
        ELSE
            RAISE EXCEPTION 'UNSUPPORTED_MASTER_CODE_ENTITY';
    END CASE;

    IF v_code IS NULL THEN
        RAISE EXCEPTION USING MESSAGE=COALESCE(
            NULLIF(btrim(p_not_found_error),''),
            'MASTER_NOT_FOUND'
        );
    END IF;
    RETURN v_code;
END;
$$;

CREATE FUNCTION private.reserve_master_code(
    p_company_id UUID,
    p_entity_type TEXT,
    p_technical_code TEXT
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_entity TEXT := upper(btrim(COALESCE(p_entity_type,'')));
    v_prefix TEXT;
    v_value BIGINT;
BEGIN
    v_prefix := CASE v_entity
        WHEN 'PRODUCT_CATEGORY' THEN 'CAT'
        WHEN 'UOM' THEN 'UOM'
        WHEN 'WAREHOUSE' THEN 'WH'
        WHEN 'SUPPLIER' THEN 'SUP'
        WHEN 'CUSTOMER_CATEGORY' THEN 'CC'
        WHEN 'PRICELIST' THEN 'PL'
        WHEN 'PAYMENT_METHOD' THEN 'PAY'
        WHEN 'TRANSACTION_CATEGORY' THEN 'TC'
    END;
    IF v_prefix IS NULL THEN
        RAISE EXCEPTION 'UNSUPPORTED_MASTER_CODE_ENTITY';
    END IF;
    IF upper(btrim(COALESCE(p_technical_code,'')))
       !~ ('^'||v_prefix||'-[0-9]{6,18}$') THEN
        RETURN;
    END IF;

    v_value := split_part(upper(btrim(p_technical_code)),'-',2)::BIGINT;
    IF v_value<=0 THEN RETURN; END IF;
    INSERT INTO private.master_code_counters AS counter(
        company_id,entity_type,last_value,updated_at
    ) VALUES (
        p_company_id,v_entity,v_value,clock_timestamp()
    )
    ON CONFLICT(company_id,entity_type) DO UPDATE SET
        last_value=greatest(counter.last_value,EXCLUDED.last_value),
        updated_at=clock_timestamp();
END;
$$;

CREATE FUNCTION private.trg_g2_automatic_master_code()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_entity TEXT;
    v_column TEXT;
    v_old_code TEXT;
    v_new_code TEXT;
BEGIN
    SELECT entity_type,column_name INTO v_entity,v_column
    FROM (
        VALUES
            ('product_categories','PRODUCT_CATEGORY','category_code'),
            ('uoms','UOM','code'),
            ('warehouses','WAREHOUSE','code'),
            ('suppliers','SUPPLIER','supplier_code'),
            ('customer_categories','CUSTOMER_CATEGORY','category_code'),
            ('pricelists','PRICELIST','code'),
            ('payment_methods','PAYMENT_METHOD','payment_method_code'),
            ('transaction_categories','TRANSACTION_CATEGORY','category_code')
    ) mapping(table_name,entity_type,column_name)
    WHERE table_name=TG_TABLE_NAME;

    IF v_entity IS NULL THEN RAISE EXCEPTION 'UNSUPPORTED_MASTER_CODE_TABLE'; END IF;

    v_new_code := to_jsonb(NEW)->>v_column;
    IF TG_OP='INSERT' THEN
        IF btrim(COALESCE(v_new_code,''))='' THEN
            v_new_code := private.allocate_master_code(NEW.company_id,v_entity);
            NEW := jsonb_populate_record(
                NEW,jsonb_build_object(v_column,v_new_code)
            );
        ELSE
            -- Applied import compatibility can still provide an explicit code.
            -- Reserve matching new-format suffixes so a later automatic create
            -- never attempts the same identity.
            PERFORM private.reserve_master_code(
                NEW.company_id,v_entity,v_new_code
            );
        END IF;
        RETURN NEW;
    END IF;

    v_old_code := to_jsonb(OLD)->>v_column;
    IF upper(regexp_replace(btrim(COALESCE(v_new_code,'')),'\s+',' ','g'))
       IS DISTINCT FROM
       upper(regexp_replace(btrim(COALESCE(v_old_code,'')),'\s+',' ','g')) THEN
        RAISE EXCEPTION 'SYSTEM_CODE_IMMUTABLE';
    END IF;

    -- Preserve the original bytes even if an old client submits cosmetic
    -- whitespace/case normalization for the same identity.
    NEW := jsonb_populate_record(
        NEW,jsonb_build_object(v_column,v_old_code)
    );
    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION private.allocate_master_code(UUID,TEXT),
    private.resolve_or_allocate_master_code(TEXT,UUID,TEXT),
    private.reserve_master_code(UUID,TEXT,TEXT),
    private.trg_g2_automatic_master_code()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.allocate_master_code(UUID,TEXT),
    private.resolve_or_allocate_master_code(TEXT,UUID,TEXT),
    private.reserve_master_code(UUID,TEXT,TEXT),
    private.trg_g2_automatic_master_code()
TO service_role;

CREATE TRIGGER g2_automatic_product_category_code
BEFORE INSERT OR UPDATE OF category_code ON public.product_categories
FOR EACH ROW EXECUTE FUNCTION private.trg_g2_automatic_master_code();
CREATE TRIGGER g2_automatic_uom_code
BEFORE INSERT OR UPDATE OF code ON public.uoms
FOR EACH ROW EXECUTE FUNCTION private.trg_g2_automatic_master_code();
CREATE TRIGGER g2_automatic_warehouse_code
BEFORE INSERT OR UPDATE OF code ON public.warehouses
FOR EACH ROW EXECUTE FUNCTION private.trg_g2_automatic_master_code();
CREATE TRIGGER g2_automatic_supplier_code
BEFORE INSERT OR UPDATE OF supplier_code ON public.suppliers
FOR EACH ROW EXECUTE FUNCTION private.trg_g2_automatic_master_code();
CREATE TRIGGER g2_automatic_customer_category_code
BEFORE INSERT OR UPDATE OF category_code ON public.customer_categories
FOR EACH ROW EXECUTE FUNCTION private.trg_g2_automatic_master_code();
CREATE TRIGGER g2_automatic_pricelist_code
BEFORE INSERT OR UPDATE OF code ON public.pricelists
FOR EACH ROW EXECUTE FUNCTION private.trg_g2_automatic_master_code();
CREATE TRIGGER g2_automatic_payment_method_code
BEFORE INSERT OR UPDATE OF payment_method_code ON public.payment_methods
FOR EACH ROW EXECUTE FUNCTION private.trg_g2_automatic_master_code();
CREATE TRIGGER g2_automatic_transaction_category_code
BEFORE INSERT OR UPDATE OF category_code ON public.transaction_categories
FOR EACH ROW EXECUTE FUNCTION private.trg_g2_automatic_master_code();

-- Guarded compatibility overloads. Existing explicit-code signatures remain
-- available to the already-applied import engine until its Phase-35 cutover.

CREATE FUNCTION public.save_supplier(
    p_supplier_id UUID,p_master_version BIGINT,p_supplier_name TEXT,
    p_contact_name TEXT,p_phone TEXT,p_address TEXT,p_npwp TEXT,
    p_payment_term TEXT,p_bank_name TEXT,p_bank_account_number TEXT,
    p_bank_account_holder TEXT,p_is_active BOOLEAN
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    RETURN public.save_supplier(
        p_supplier_id,p_master_version,
        private.resolve_or_allocate_master_code(
            'SUPPLIER',p_supplier_id,'SUPPLIER_NOT_FOUND'
        ),
        p_supplier_name,p_contact_name,p_phone,p_address,p_npwp,p_payment_term,
        p_bank_name,p_bank_account_number,p_bank_account_holder,p_is_active
    );
END;
$$;

CREATE FUNCTION public.save_customer_category(
    p_customer_category_id UUID,p_master_version BIGINT,
    p_category_name TEXT,p_is_active BOOLEAN
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    RETURN public.save_customer_category(
        p_customer_category_id,p_master_version,
        private.resolve_or_allocate_master_code(
            'CUSTOMER_CATEGORY',p_customer_category_id,
            'CUSTOMER_CATEGORY_NOT_FOUND'
        ),
        p_category_name,p_is_active
    );
END;
$$;

CREATE FUNCTION public.save_reusable_pricelist_with_rules(
    p_pricelist_id UUID,p_master_version BIGINT,p_name TEXT,p_scope TEXT,
    p_priority INTEGER,p_is_default BOOLEAN,p_applies_all_stores BOOLEAN,
    p_store_ids UUID[],p_valid_from TIMESTAMPTZ,p_valid_until TIMESTAMPTZ,
    p_is_active BOOLEAN,p_notes TEXT,p_rules JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    RETURN public.save_reusable_pricelist_with_rules(
        p_pricelist_id,p_master_version,
        private.resolve_or_allocate_master_code(
            'PRICELIST',p_pricelist_id,'PRICELIST_NOT_FOUND'
        ),
        p_name,p_scope,p_priority,p_is_default,p_applies_all_stores,p_store_ids,
        p_valid_from,p_valid_until,p_is_active,p_notes,p_rules
    );
END;
$$;

CREATE FUNCTION public.save_payment_method(
    p_payment_method_id UUID,p_master_version BIGINT,
    p_payment_method_name TEXT,p_method_type TEXT,p_settlement_route TEXT,
    p_is_default BOOLEAN,p_available_all_stores BOOLEAN,p_store_ids UUID[],
    p_proof_mode TEXT,p_fee_enabled BOOLEAN,p_fee_bearer TEXT,p_fee_type TEXT,
    p_fee_percent NUMERIC,p_fee_fixed_amount NUMERIC,
    p_clearing_account_function TEXT,p_bank_account_function TEXT,
    p_effective_from TIMESTAMPTZ,p_effective_to TIMESTAMPTZ,
    p_is_active BOOLEAN
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    RETURN public.save_payment_method(
        p_payment_method_id,p_master_version,
        private.resolve_or_allocate_master_code(
            'PAYMENT_METHOD',p_payment_method_id,'PAYMENT_METHOD_NOT_FOUND'
        ),
        p_payment_method_name,p_method_type,p_settlement_route,p_is_default,
        p_available_all_stores,p_store_ids,p_proof_mode,p_fee_enabled,
        p_fee_bearer,p_fee_type,p_fee_percent,p_fee_fixed_amount,
        p_clearing_account_function,p_bank_account_function,p_effective_from,
        p_effective_to,p_is_active
    );
END;
$$;

CREATE FUNCTION public.save_transaction_category(
    p_category_id UUID,p_master_version BIGINT,p_category_name TEXT,
    p_system_key TEXT,p_description TEXT,p_is_active BOOLEAN
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    RETURN public.save_transaction_category(
        p_category_id,p_master_version,
        private.resolve_or_allocate_master_code(
            'TRANSACTION_CATEGORY',p_category_id,
            'TRANSACTION_CATEGORY_NOT_FOUND'
        ),
        p_category_name,p_system_key,p_description,p_is_active
    );
END;
$$;

REVOKE ALL ON FUNCTION public.save_supplier(
    UUID,BIGINT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,BOOLEAN
), public.save_customer_category(UUID,BIGINT,TEXT,BOOLEAN),
public.save_reusable_pricelist_with_rules(
    UUID,BIGINT,TEXT,TEXT,INTEGER,BOOLEAN,BOOLEAN,UUID[],
    TIMESTAMPTZ,TIMESTAMPTZ,BOOLEAN,TEXT,JSONB
), public.save_payment_method(
    UUID,BIGINT,TEXT,TEXT,TEXT,BOOLEAN,BOOLEAN,UUID[],TEXT,BOOLEAN,TEXT,TEXT,
    NUMERIC,NUMERIC,TEXT,TEXT,TIMESTAMPTZ,TIMESTAMPTZ,BOOLEAN
), public.save_transaction_category(
    UUID,BIGINT,TEXT,TEXT,TEXT,BOOLEAN
) FROM PUBLIC,anon;

GRANT EXECUTE ON FUNCTION public.save_supplier(
    UUID,BIGINT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,BOOLEAN
), public.save_customer_category(UUID,BIGINT,TEXT,BOOLEAN),
public.save_reusable_pricelist_with_rules(
    UUID,BIGINT,TEXT,TEXT,INTEGER,BOOLEAN,BOOLEAN,UUID[],
    TIMESTAMPTZ,TIMESTAMPTZ,BOOLEAN,TEXT,JSONB
), public.save_payment_method(
    UUID,BIGINT,TEXT,TEXT,TEXT,BOOLEAN,BOOLEAN,UUID[],TEXT,BOOLEAN,TEXT,TEXT,
    NUMERIC,NUMERIC,TEXT,TEXT,TIMESTAMPTZ,TIMESTAMPTZ,BOOLEAN
), public.save_transaction_category(
    UUID,BIGINT,TEXT,TEXT,TEXT,BOOLEAN
) TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES (
    '20260724010000',
    'g2_phase36_automatic_master_codes',
    'UUID stays canonical; automatic immutable hidden codes for 8 masters, existing codes preserved, compatibility overloads retained'
);

COMMIT;
