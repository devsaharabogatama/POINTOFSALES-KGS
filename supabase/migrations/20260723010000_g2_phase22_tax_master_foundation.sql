-- KGS POS G2 phase 22: additive Sales/Purchase Tax master foundation.
-- Tax entitlement, resolver, checkout calculation, Purchase Invoice tax,
-- return/reversal, journal posting, and official reporting remain disabled.

BEGIN;

DO $migration_guard$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260722230000'
    ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: phase 20 COA/fallback is required';
    END IF;
    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260723010000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260723010000';
    END IF;
END
$migration_guard$;

-- -------------------------------------------------------------------------
-- 1. Stable Tax identity and immutable/effective-dated configuration
-- -------------------------------------------------------------------------

CREATE TABLE public.tax_rules (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL
        REFERENCES public.companies(id) ON DELETE RESTRICT,
    tax_code TEXT NOT NULL,
    tax_name TEXT NOT NULL,
    tax_scope TEXT NOT NULL,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    master_version BIGINT NOT NULL DEFAULT 1,
    created_by UUID REFERENCES public.profiles(id),
    updated_by UUID REFERENCES public.profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT tax_rules_company_id_id_unique UNIQUE(company_id,id),
    CONSTRAINT tax_rules_code_not_blank CHECK(btrim(tax_code) <> ''),
    CONSTRAINT tax_rules_name_not_blank CHECK(btrim(tax_name) <> ''),
    CONSTRAINT tax_rules_scope_check CHECK(tax_scope IN ('SALES','PURCHASE')),
    CONSTRAINT tax_rules_version_positive CHECK(master_version > 0)
);

CREATE UNIQUE INDEX uq_tax_rules_company_normalized_code
    ON public.tax_rules(
        company_id,
        upper(regexp_replace(btrim(tax_code),'\s+',' ','g'))
    );
CREATE UNIQUE INDEX uq_tax_rules_company_normalized_name
    ON public.tax_rules(
        company_id,
        lower(regexp_replace(btrim(tax_name),'\s+',' ','g'))
    );
CREATE INDEX idx_tax_rules_company_scope_active
    ON public.tax_rules(company_id,tax_scope,is_active,tax_name);

CREATE TABLE public.tax_rule_versions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL,
    tax_rule_id UUID NOT NULL,
    rate_percent NUMERIC(9,6) NOT NULL,
    calculation_scope TEXT NOT NULL DEFAULT 'PER_DOCUMENT',
    default_price_mode TEXT NOT NULL,
    account_function_key TEXT NOT NULL
        REFERENCES public.account_functions(function_key),
    account_id UUID NOT NULL,
    is_recoverable BOOLEAN,
    effective_from TIMESTAMPTZ NOT NULL,
    effective_to TIMESTAMPTZ,
    rule_version BIGINT NOT NULL,
    status TEXT NOT NULL DEFAULT 'DRAFT',
    approved_by UUID REFERENCES public.profiles(id),
    approved_at TIMESTAMPTZ,
    created_by UUID REFERENCES public.profiles(id),
    updated_by UUID REFERENCES public.profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT tax_rule_versions_company_id_id_unique UNIQUE(company_id,id),
    CONSTRAINT tax_rule_versions_identity_unique
        UNIQUE(company_id,tax_rule_id,rule_version),
    CONSTRAINT tax_rule_versions_rate_check
        CHECK(rate_percent >= 0 AND rate_percent <= 100),
    CONSTRAINT tax_rule_versions_calculation_scope_check
        CHECK(calculation_scope IN ('PER_LINE','PER_DOCUMENT')),
    CONSTRAINT tax_rule_versions_price_mode_check
        CHECK(default_price_mode IN ('INCLUSIVE','EXCLUSIVE')),
    CONSTRAINT tax_rule_versions_period_check
        CHECK(effective_to IS NULL OR effective_to > effective_from),
    CONSTRAINT tax_rule_versions_version_positive CHECK(rule_version > 0),
    CONSTRAINT tax_rule_versions_status_check
        CHECK(status IN ('DRAFT','ACTIVE','INACTIVE')),
    CONSTRAINT tax_rule_versions_approval_check CHECK(
        status <> 'ACTIVE' OR (approved_by IS NOT NULL AND approved_at IS NOT NULL)
    ),
    CONSTRAINT fk_tax_rule_versions_company_rule
        FOREIGN KEY(company_id,tax_rule_id)
        REFERENCES public.tax_rules(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_tax_rule_versions_company_account
        FOREIGN KEY(company_id,account_id)
        REFERENCES public.chart_of_accounts(company_id,id) ON DELETE RESTRICT
);

CREATE INDEX idx_tax_rule_versions_resolver
    ON public.tax_rule_versions(
        company_id,tax_rule_id,status,effective_from,effective_to
    );

CREATE TABLE public.tax_master_audit (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_id UUID NOT NULL
        REFERENCES public.companies(id) ON DELETE RESTRICT,
    entity_type TEXT NOT NULL,
    entity_id UUID NOT NULL,
    action TEXT NOT NULL,
    actor_id UUID NOT NULL REFERENCES public.profiles(id),
    before_state JSONB,
    after_state JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT tax_master_audit_entity_check
        CHECK(entity_type IN ('TAX_RULE','TAX_RULE_VERSION')),
    CONSTRAINT tax_master_audit_action_check
        CHECK(action IN ('CREATE','UPDATE','CLOSE'))
);

CREATE INDEX idx_tax_master_audit_entity_created
    ON public.tax_master_audit(company_id,entity_type,entity_id,created_at DESC);

-- -------------------------------------------------------------------------
-- 2. Nullable resolver assignments and transaction snapshots
-- -------------------------------------------------------------------------

ALTER TABLE public.product_categories
    ADD COLUMN default_sales_tax_rule_id UUID,
    ADD COLUMN default_purchase_tax_rule_id UUID,
    ADD CONSTRAINT fk_product_categories_company_sales_tax_rule
        FOREIGN KEY(company_id,default_sales_tax_rule_id)
        REFERENCES public.tax_rules(company_id,id) ON DELETE RESTRICT,
    ADD CONSTRAINT fk_product_categories_company_purchase_tax_rule
        FOREIGN KEY(company_id,default_purchase_tax_rule_id)
        REFERENCES public.tax_rules(company_id,id) ON DELETE RESTRICT;

ALTER TABLE public.products
    ADD COLUMN sales_tax_rule_id UUID,
    ADD COLUMN purchase_tax_rule_id UUID,
    ADD CONSTRAINT fk_products_company_sales_tax_rule
        FOREIGN KEY(company_id,sales_tax_rule_id)
        REFERENCES public.tax_rules(company_id,id) ON DELETE RESTRICT,
    ADD CONSTRAINT fk_products_company_purchase_tax_rule
        FOREIGN KEY(company_id,purchase_tax_rule_id)
        REFERENCES public.tax_rules(company_id,id) ON DELETE RESTRICT;

CREATE INDEX idx_product_categories_company_sales_tax_rule
    ON public.product_categories(company_id,default_sales_tax_rule_id)
    WHERE default_sales_tax_rule_id IS NOT NULL;
CREATE INDEX idx_product_categories_company_purchase_tax_rule
    ON public.product_categories(company_id,default_purchase_tax_rule_id)
    WHERE default_purchase_tax_rule_id IS NOT NULL;
CREATE INDEX idx_products_company_sales_tax_rule
    ON public.products(company_id,sales_tax_rule_id)
    WHERE sales_tax_rule_id IS NOT NULL;
CREATE INDEX idx_products_company_purchase_tax_rule
    ON public.products(company_id,purchase_tax_rule_id)
    WHERE purchase_tax_rule_id IS NOT NULL;

ALTER TABLE public.sales_details
    ADD COLUMN tax_rule_id UUID,
    ADD COLUMN tax_rule_version BIGINT,
    ADD COLUMN tax_code_snapshot TEXT,
    ADD COLUMN tax_name_snapshot TEXT,
    ADD COLUMN tax_scope_snapshot TEXT,
    ADD COLUMN tax_rate_percent_snapshot NUMERIC(9,6),
    ADD COLUMN tax_price_mode_snapshot TEXT,
    ADD COLUMN tax_calculation_scope_snapshot TEXT,
    ADD COLUMN tax_base NUMERIC(20,4),
    ADD COLUMN tax_amount NUMERIC(20,4),
    ADD COLUMN tax_rounding NUMERIC(20,4),
    ADD COLUMN tax_account_id UUID,
    ADD COLUMN tax_account_code_snapshot TEXT,
    ADD COLUMN tax_account_name_snapshot TEXT,
    ADD CONSTRAINT fk_sales_details_company_tax_rule
        FOREIGN KEY(company_id,tax_rule_id)
        REFERENCES public.tax_rules(company_id,id) ON DELETE RESTRICT,
    ADD CONSTRAINT fk_sales_details_company_tax_account
        FOREIGN KEY(company_id,tax_account_id)
        REFERENCES public.chart_of_accounts(company_id,id) ON DELETE RESTRICT,
    ADD CONSTRAINT sales_details_tax_scope_snapshot_check
        CHECK(tax_scope_snapshot IS NULL OR tax_scope_snapshot = 'SALES'),
    ADD CONSTRAINT sales_details_tax_rate_snapshot_check
        CHECK(tax_rate_percent_snapshot IS NULL OR (
            tax_rate_percent_snapshot >= 0 AND tax_rate_percent_snapshot <= 100
        )),
    ADD CONSTRAINT sales_details_tax_price_mode_snapshot_check
        CHECK(tax_price_mode_snapshot IS NULL OR tax_price_mode_snapshot = 'INCLUSIVE'),
    ADD CONSTRAINT sales_details_tax_calculation_scope_snapshot_check CHECK(
        tax_calculation_scope_snapshot IS NULL
        OR tax_calculation_scope_snapshot IN ('PER_LINE','PER_DOCUMENT')
    );

ALTER TABLE public.purchases_details
    ADD COLUMN tax_rule_id UUID,
    ADD COLUMN tax_rule_version BIGINT,
    ADD COLUMN tax_code_snapshot TEXT,
    ADD COLUMN tax_name_snapshot TEXT,
    ADD COLUMN tax_scope_snapshot TEXT,
    ADD COLUMN tax_rate_percent_snapshot NUMERIC(9,6),
    ADD COLUMN tax_price_mode_snapshot TEXT,
    ADD COLUMN tax_calculation_scope_snapshot TEXT,
    ADD COLUMN tax_is_recoverable_snapshot BOOLEAN,
    ADD COLUMN tax_base NUMERIC(20,4),
    ADD COLUMN tax_amount NUMERIC(20,4),
    ADD COLUMN tax_rounding NUMERIC(20,4),
    ADD COLUMN tax_account_id UUID,
    ADD COLUMN tax_account_code_snapshot TEXT,
    ADD COLUMN tax_account_name_snapshot TEXT,
    ADD CONSTRAINT fk_purchase_details_company_tax_rule
        FOREIGN KEY(company_id,tax_rule_id)
        REFERENCES public.tax_rules(company_id,id) ON DELETE RESTRICT,
    ADD CONSTRAINT fk_purchase_details_company_tax_account
        FOREIGN KEY(company_id,tax_account_id)
        REFERENCES public.chart_of_accounts(company_id,id) ON DELETE RESTRICT,
    ADD CONSTRAINT purchase_details_tax_scope_snapshot_check
        CHECK(tax_scope_snapshot IS NULL OR tax_scope_snapshot = 'PURCHASE'),
    ADD CONSTRAINT purchase_details_tax_rate_snapshot_check
        CHECK(tax_rate_percent_snapshot IS NULL OR (
            tax_rate_percent_snapshot >= 0 AND tax_rate_percent_snapshot <= 100
        )),
    ADD CONSTRAINT purchase_details_tax_price_mode_snapshot_check CHECK(
        tax_price_mode_snapshot IS NULL
        OR tax_price_mode_snapshot IN ('INCLUSIVE','EXCLUSIVE')
    ),
    ADD CONSTRAINT purchase_details_tax_calculation_scope_snapshot_check CHECK(
        tax_calculation_scope_snapshot IS NULL
        OR tax_calculation_scope_snapshot IN ('PER_LINE','PER_DOCUMENT')
    );

-- -------------------------------------------------------------------------
-- 3. Server-side scope/history/assignment guards
-- -------------------------------------------------------------------------

CREATE FUNCTION private.trg_g2_guard_tax_rule_header()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF NEW.tax_scope IS DISTINCT FROM OLD.tax_scope
       AND EXISTS (
           SELECT 1 FROM public.tax_rule_versions v
           WHERE v.company_id = OLD.company_id AND v.tax_rule_id = OLD.id
       ) THEN
        RAISE EXCEPTION 'TAX_SCOPE_LOCKED_BY_VERSION_HISTORY';
    END IF;
    IF NOT NEW.is_active AND OLD.is_active AND (
        EXISTS (
            SELECT 1 FROM public.product_categories pc
            WHERE pc.company_id = OLD.company_id
              AND pc.is_active
              AND (pc.default_sales_tax_rule_id = OLD.id
                   OR pc.default_purchase_tax_rule_id = OLD.id)
        ) OR EXISTS (
            SELECT 1 FROM public.products p
            WHERE p.company_id = OLD.company_id
              AND p.is_active
              AND (p.sales_tax_rule_id = OLD.id
                   OR p.purchase_tax_rule_id = OLD.id)
        )
    ) THEN
        RAISE EXCEPTION 'TAX_RULE_IN_USE_BY_ACTIVE_MASTER';
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION private.trg_g2_guard_tax_rule_version()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_scope TEXT;
    v_rule_active BOOLEAN;
    v_expected_function TEXT;
    v_account_type TEXT;
    v_compatible_types TEXT[];
BEGIN
    SELECT r.tax_scope,r.is_active INTO v_scope,v_rule_active
    FROM public.tax_rules r
    WHERE r.company_id = NEW.company_id AND r.id = NEW.tax_rule_id;
    IF v_scope IS NULL THEN RAISE EXCEPTION 'TAX_RULE_NOT_FOUND'; END IF;
    IF NOT v_rule_active AND NEW.status = 'ACTIVE' THEN
        RAISE EXCEPTION 'ACTIVE_TAX_RULE_REQUIRED';
    END IF;

    v_expected_function := CASE v_scope
        WHEN 'SALES' THEN 'OUTPUT_TAX'
        ELSE 'INPUT_TAX'
    END;
    IF NEW.account_function_key IS DISTINCT FROM v_expected_function THEN
        RAISE EXCEPTION 'TAX_ACCOUNT_FUNCTION_SCOPE_MISMATCH';
    END IF;

    SELECT coa.account_type,af.compatible_account_types
    INTO v_account_type,v_compatible_types
    FROM public.chart_of_accounts coa
    JOIN public.account_functions af
      ON af.function_key = NEW.account_function_key AND af.is_active
    WHERE coa.company_id = NEW.company_id
      AND coa.id = NEW.account_id
      AND coa.is_active
      AND coa.is_postable;
    IF v_account_type IS NULL THEN
        RAISE EXCEPTION 'ACTIVE_POSTABLE_TAX_ACCOUNT_REQUIRED';
    END IF;
    IF NOT (v_account_type = ANY(v_compatible_types)) THEN
        RAISE EXCEPTION 'INCOMPATIBLE_TAX_ACCOUNT_TYPE';
    END IF;

    IF v_scope = 'SALES' THEN
        IF NEW.default_price_mode <> 'INCLUSIVE' THEN
            RAISE EXCEPTION 'SALES_TAX_MUST_BE_INCLUSIVE';
        END IF;
        IF NEW.is_recoverable IS NOT NULL THEN
            RAISE EXCEPTION 'SALES_TAX_RECOVERABLE_NOT_APPLICABLE';
        END IF;
    ELSIF NEW.is_recoverable IS NULL THEN
        RAISE EXCEPTION 'PURCHASE_TAX_RECOVERABLE_REQUIRED';
    END IF;

    IF TG_OP = 'UPDATE' AND OLD.status = 'ACTIVE' AND (
        NEW.tax_rule_id IS DISTINCT FROM OLD.tax_rule_id
        OR NEW.rate_percent IS DISTINCT FROM OLD.rate_percent
        OR NEW.calculation_scope IS DISTINCT FROM OLD.calculation_scope
        OR NEW.default_price_mode IS DISTINCT FROM OLD.default_price_mode
        OR NEW.account_function_key IS DISTINCT FROM OLD.account_function_key
        OR NEW.account_id IS DISTINCT FROM OLD.account_id
        OR NEW.is_recoverable IS DISTINCT FROM OLD.is_recoverable
        OR NEW.effective_from IS DISTINCT FROM OLD.effective_from
        OR NEW.rule_version IS DISTINCT FROM OLD.rule_version
        OR NEW.status IS DISTINCT FROM OLD.status
    ) THEN
        RAISE EXCEPTION 'ACTIVE_TAX_RULE_VERSION_IMMUTABLE';
    END IF;

    IF NEW.status = 'ACTIVE' AND EXISTS (
        SELECT 1 FROM public.tax_rule_versions existing
        WHERE existing.company_id = NEW.company_id
          AND existing.tax_rule_id = NEW.tax_rule_id
          AND existing.status = 'ACTIVE'
          AND existing.id IS DISTINCT FROM NEW.id
          AND tstzrange(existing.effective_from,existing.effective_to,'[)')
              && tstzrange(NEW.effective_from,NEW.effective_to,'[)')
    ) THEN
        RAISE EXCEPTION 'TAX_RULE_VERSION_PERIOD_OVERLAP';
    END IF;
    NEW.updated_at := clock_timestamp();
    RETURN NEW;
END;
$$;

CREATE FUNCTION private.trg_g2_guard_tax_assignment()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_sales_tax_rule_id UUID;
    v_purchase_tax_rule_id UUID;
BEGIN
    IF TG_TABLE_NAME = 'product_categories' THEN
        v_sales_tax_rule_id := NEW.default_sales_tax_rule_id;
        v_purchase_tax_rule_id := NEW.default_purchase_tax_rule_id;
    ELSIF TG_TABLE_NAME = 'products' THEN
        v_sales_tax_rule_id := NEW.sales_tax_rule_id;
        v_purchase_tax_rule_id := NEW.purchase_tax_rule_id;
    ELSE
        RAISE EXCEPTION 'UNSUPPORTED_TAX_ASSIGNMENT_TABLE: %',TG_TABLE_NAME;
    END IF;

    IF v_sales_tax_rule_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.tax_rules r
        WHERE r.company_id = NEW.company_id
          AND r.id = v_sales_tax_rule_id
          AND r.tax_scope = 'SALES'
          AND r.is_active
    ) THEN RAISE EXCEPTION 'ACTIVE_SALES_TAX_RULE_REQUIRED'; END IF;

    IF v_purchase_tax_rule_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.tax_rules r
        WHERE r.company_id = NEW.company_id
          AND r.id = v_purchase_tax_rule_id
          AND r.tax_scope = 'PURCHASE'
          AND r.is_active
    ) THEN RAISE EXCEPTION 'ACTIVE_PURCHASE_TAX_RULE_REQUIRED'; END IF;
    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION private.trg_g2_guard_tax_rule_header()
FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION private.trg_g2_guard_tax_rule_version()
FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION private.trg_g2_guard_tax_assignment()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.trg_g2_guard_tax_rule_header(),
    private.trg_g2_guard_tax_rule_version(),
    private.trg_g2_guard_tax_assignment()
TO service_role;

CREATE TRIGGER g2_guard_tax_rule_header
BEFORE UPDATE ON public.tax_rules
FOR EACH ROW EXECUTE FUNCTION private.trg_g2_guard_tax_rule_header();
CREATE TRIGGER g2_touch_tax_rules
BEFORE INSERT OR UPDATE ON public.tax_rules
FOR EACH ROW EXECUTE FUNCTION private.trg_g2_touch_master();
CREATE TRIGGER g2_guard_tax_rule_versions
BEFORE INSERT OR UPDATE ON public.tax_rule_versions
FOR EACH ROW EXECUTE FUNCTION private.trg_g2_guard_tax_rule_version();
CREATE TRIGGER g2_guard_product_category_tax_assignment
BEFORE INSERT OR UPDATE ON public.product_categories
FOR EACH ROW EXECUTE FUNCTION private.trg_g2_guard_tax_assignment();
CREATE TRIGGER g2_guard_product_tax_assignment
BEFORE INSERT OR UPDATE ON public.products
FOR EACH ROW EXECUTE FUNCTION private.trg_g2_guard_tax_assignment();

-- -------------------------------------------------------------------------
-- 4. Atomic guarded Tax identity + new configuration version
-- -------------------------------------------------------------------------

CREATE FUNCTION public.save_tax_rule(
    p_tax_rule_id UUID,
    p_master_version BIGINT,
    p_tax_code TEXT,
    p_tax_name TEXT,
    p_tax_scope TEXT,
    p_rate_percent NUMERIC,
    p_calculation_scope TEXT,
    p_default_price_mode TEXT,
    p_account_id UUID,
    p_is_recoverable BOOLEAN,
    p_effective_from TIMESTAMPTZ,
    p_effective_to TIMESTAMPTZ,
    p_status TEXT,
    p_is_active BOOLEAN
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_actor UUID := auth.uid();
    v_company UUID := public.private_active_company_id();
    v_scope TEXT := upper(btrim(COALESCE(p_tax_scope,'')));
    v_calculation_scope TEXT := upper(btrim(COALESCE(p_calculation_scope,'')));
    v_price_mode TEXT := upper(btrim(COALESCE(p_default_price_mode,'')));
    v_status TEXT := upper(btrim(COALESCE(p_status,'')));
    v_feature_code TEXT;
    v_function_key TEXT;
    v_id UUID;
    v_version BIGINT;
    v_master_version BIGINT;
    v_before JSONB;
    v_after JSONB;
    v_old_scope TEXT;
    v_previous RECORD;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF NOT public.private_user_has_any_company_or_store_role(
        v_company,
        ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE','ACCOUNTING']::TEXT[]
    ) THEN RAISE EXCEPTION 'TAX_MASTER_MANAGER_REQUIRED'; END IF;
    IF v_scope NOT IN ('SALES','PURCHASE') THEN
        RAISE EXCEPTION 'INVALID_TAX_SCOPE';
    END IF;
    v_feature_code := CASE v_scope
        WHEN 'SALES' THEN 'tax_sales_enabled'
        ELSE 'tax_purchase_enabled'
    END;
    IF NOT public.private_company_feature_enabled(v_company,v_feature_code) THEN
        RAISE EXCEPTION 'TAX_FEATURE_DISABLED';
    END IF;
    IF btrim(COALESCE(p_tax_code,'')) = ''
       OR btrim(COALESCE(p_tax_name,'')) = '' THEN
        RAISE EXCEPTION 'INVALID_TAX_IDENTITY';
    END IF;
    IF p_rate_percent IS NULL OR p_rate_percent < 0 OR p_rate_percent > 100 THEN
        RAISE EXCEPTION 'INVALID_TAX_RATE';
    END IF;
    IF v_calculation_scope NOT IN ('PER_LINE','PER_DOCUMENT') THEN
        RAISE EXCEPTION 'INVALID_TAX_CALCULATION_SCOPE';
    END IF;
    IF v_price_mode NOT IN ('INCLUSIVE','EXCLUSIVE') THEN
        RAISE EXCEPTION 'INVALID_TAX_PRICE_MODE';
    END IF;
    IF v_status NOT IN ('DRAFT','ACTIVE') THEN
        RAISE EXCEPTION 'INVALID_TAX_RULE_STATUS';
    END IF;
    IF v_status = 'ACTIVE' AND NOT COALESCE(p_is_active,TRUE) THEN
        RAISE EXCEPTION 'TAX_ACTIVE_VERSION_REQUIRES_ACTIVE_RULE';
    END IF;
    IF p_effective_from IS NULL THEN RAISE EXCEPTION 'EFFECTIVE_FROM_REQUIRED'; END IF;
    IF p_effective_to IS NOT NULL AND p_effective_to <= p_effective_from THEN
        RAISE EXCEPTION 'INVALID_EFFECTIVE_PERIOD';
    END IF;
    v_function_key := CASE v_scope
        WHEN 'SALES' THEN 'OUTPUT_TAX'
        ELSE 'INPUT_TAX'
    END;

    PERFORM pg_advisory_xact_lock(hashtextextended(
        'G2_TAX|' || v_company::TEXT || '|'
        || upper(btrim(COALESCE(p_tax_code,''))),0
    ));

    IF p_tax_rule_id IS NULL THEN
        INSERT INTO public.tax_rules(
            company_id,tax_code,tax_name,tax_scope,is_active,
            created_by,updated_by
        ) VALUES (
            v_company,upper(btrim(p_tax_code)),btrim(p_tax_name),v_scope,
            COALESCE(p_is_active,TRUE),v_actor,v_actor
        ) RETURNING id,master_version INTO v_id,v_master_version;
        SELECT to_jsonb(r) INTO v_after FROM public.tax_rules r
        WHERE r.company_id = v_company AND r.id = v_id;
        INSERT INTO public.tax_master_audit(
            company_id,entity_type,entity_id,action,actor_id,after_state
        ) VALUES (v_company,'TAX_RULE',v_id,'CREATE',v_actor,v_after);
    ELSE
        SELECT to_jsonb(r),r.master_version,r.tax_scope
        INTO v_before,v_master_version,v_old_scope
        FROM public.tax_rules r
        WHERE r.company_id = v_company AND r.id = p_tax_rule_id
        FOR UPDATE;
        IF NOT FOUND THEN RAISE EXCEPTION 'TAX_RULE_NOT_FOUND'; END IF;
        IF p_master_version IS NULL OR p_master_version <> v_master_version THEN
            RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
        END IF;
        IF v_scope IS DISTINCT FROM v_old_scope THEN
            RAISE EXCEPTION 'TAX_SCOPE_LOCKED_BY_VERSION_HISTORY';
        END IF;
        UPDATE public.tax_rules SET
            tax_code = upper(btrim(p_tax_code)),tax_name = btrim(p_tax_name),
            is_active = COALESCE(p_is_active,TRUE),updated_by = v_actor
        WHERE company_id = v_company AND id = p_tax_rule_id
        RETURNING id,master_version INTO v_id,v_master_version;
        SELECT to_jsonb(r) INTO v_after FROM public.tax_rules r
        WHERE r.company_id = v_company AND r.id = v_id;
        INSERT INTO public.tax_master_audit(
            company_id,entity_type,entity_id,action,actor_id,
            before_state,after_state
        ) VALUES (
            v_company,'TAX_RULE',v_id,'UPDATE',v_actor,v_before,v_after
        );
    END IF;

    IF v_status = 'ACTIVE' THEN
        FOR v_previous IN
            SELECT v.id,v.effective_from,to_jsonb(v) AS before_state
            FROM public.tax_rule_versions v
            WHERE v.company_id = v_company
              AND v.tax_rule_id = v_id
              AND v.status = 'ACTIVE'
              AND (v.effective_to IS NULL OR v.effective_to > p_effective_from)
            FOR UPDATE
        LOOP
            IF v_previous.effective_from >= p_effective_from THEN
                RAISE EXCEPTION 'TAX_RULE_VERSION_CONFLICT';
            END IF;
            UPDATE public.tax_rule_versions
            SET effective_to = p_effective_from,updated_by = v_actor
            WHERE company_id = v_company AND id = v_previous.id;
            SELECT to_jsonb(v) INTO v_after FROM public.tax_rule_versions v
            WHERE v.company_id = v_company AND v.id = v_previous.id;
            INSERT INTO public.tax_master_audit(
                company_id,entity_type,entity_id,action,actor_id,
                before_state,after_state
            ) VALUES (
                v_company,'TAX_RULE_VERSION',v_previous.id,'CLOSE',v_actor,
                v_previous.before_state,v_after
            );
        END LOOP;
    END IF;

    SELECT COALESCE(max(rule_version),0) + 1 INTO v_version
    FROM public.tax_rule_versions
    WHERE company_id = v_company AND tax_rule_id = v_id;

    INSERT INTO public.tax_rule_versions(
        company_id,tax_rule_id,rate_percent,calculation_scope,
        default_price_mode,account_function_key,account_id,is_recoverable,
        effective_from,effective_to,rule_version,status,
        approved_by,approved_at,created_by,updated_by
    ) VALUES (
        v_company,v_id,p_rate_percent,v_calculation_scope,v_price_mode,
        v_function_key,p_account_id,p_is_recoverable,p_effective_from,
        p_effective_to,v_version,v_status,
        CASE WHEN v_status = 'ACTIVE' THEN v_actor END,
        CASE WHEN v_status = 'ACTIVE' THEN clock_timestamp() END,
        v_actor,v_actor
    ) RETURNING id INTO v_id;

    SELECT to_jsonb(v) INTO v_after FROM public.tax_rule_versions v
    WHERE v.company_id = v_company AND v.id = v_id;
    INSERT INTO public.tax_master_audit(
        company_id,entity_type,entity_id,action,actor_id,after_state
    ) VALUES (
        v_company,'TAX_RULE_VERSION',v_id,'CREATE',v_actor,v_after
    );
    RETURN jsonb_build_object(
        'taxRuleId',(v_after->>'tax_rule_id')::UUID,
        'masterVersion',v_master_version,
        'taxRuleVersionId',v_id,
        'ruleVersion',v_version
    );
EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'DUPLICATE_TAX_RULE';
END;
$$;

REVOKE ALL ON FUNCTION public.save_tax_rule(
    UUID,BIGINT,TEXT,TEXT,TEXT,NUMERIC,TEXT,TEXT,UUID,BOOLEAN,
    TIMESTAMPTZ,TIMESTAMPTZ,TEXT,BOOLEAN
) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.save_tax_rule(
    UUID,BIGINT,TEXT,TEXT,TEXT,NUMERIC,TEXT,TEXT,UUID,BOOLEAN,
    TIMESTAMPTZ,TIMESTAMPTZ,TEXT,BOOLEAN
) TO authenticated,service_role;

-- -------------------------------------------------------------------------
-- 5. Read-only browser surface and exact write boundary
-- -------------------------------------------------------------------------

ALTER TABLE public.tax_rules ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tax_rule_versions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tax_master_audit ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Tax Rules readable in active Company"
ON public.tax_rules FOR SELECT TO authenticated
USING(
    public.private_request_company_matches(company_id)
    AND public.private_user_has_company_access(company_id)
);
CREATE POLICY "Tax Rule Versions readable in active Company"
ON public.tax_rule_versions FOR SELECT TO authenticated
USING(
    public.private_request_company_matches(company_id)
    AND public.private_user_has_company_access(company_id)
);
CREATE POLICY "Finance roles read Tax Master Audit"
ON public.tax_master_audit FOR SELECT TO authenticated
USING(public.private_finance_company_visible(company_id));

REVOKE ALL ON public.tax_rules,public.tax_rule_versions,public.tax_master_audit
FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.tax_rules,public.tax_rule_versions TO authenticated;
GRANT SELECT ON public.tax_master_audit TO authenticated;
GRANT ALL ON public.tax_rules,public.tax_rule_versions,public.tax_master_audit
TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES (
    '20260723010000',
    'g2_phase22_tax_master_foundation',
    'Additive effective-dated Sales/Purchase Tax master, guarded RPC/RLS/audit, nullable Product/Category assignments and transaction snapshots; resolver/posting disabled'
);

COMMIT;
