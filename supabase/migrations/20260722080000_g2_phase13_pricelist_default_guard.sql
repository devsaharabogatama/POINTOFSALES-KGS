-- KGS POS G2 phase 13 forward fix: require exactly one active default Global
-- Pricelist for every active Company.

BEGIN;

DO $guard$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260722070000'
    ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: G2 phase 12 missing';
    END IF;
    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260722080000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260722080000';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM public.companies c
        LEFT JOIN public.pricelists p
          ON p.company_id = c.id
         AND p.scope = 'GLOBAL'
         AND p.is_default
         AND p.is_active
        WHERE c.status = 'ACTIVE'
        GROUP BY c.id
        HAVING count(p.id) <> 1
    ) THEN
        RAISE EXCEPTION
            'G2_PHASE13_STATE_CHANGED: active Company default Global invariant is already invalid';
    END IF;
END
$guard$;

-- Preserve the already-tested phase-12 implementation behind a private entry
-- point. The public wrapper below only adds atomic default handover + audit.
ALTER FUNCTION public.save_pricelist_with_rules(
    UUID,BIGINT,TEXT,TEXT,TEXT,UUID,INTEGER,BOOLEAN,BOOLEAN,UUID[],
    TIMESTAMPTZ,TIMESTAMPTZ,BOOLEAN,TEXT,JSONB
) SET SCHEMA private;
ALTER FUNCTION private.save_pricelist_with_rules(
    UUID,BIGINT,TEXT,TEXT,TEXT,UUID,INTEGER,BOOLEAN,BOOLEAN,UUID[],
    TIMESTAMPTZ,TIMESTAMPTZ,BOOLEAN,TEXT,JSONB
) RENAME TO private_save_pricelist_with_rules_g2_legacy;
REVOKE ALL ON FUNCTION private.private_save_pricelist_with_rules_g2_legacy(
    UUID,BIGINT,TEXT,TEXT,TEXT,UUID,INTEGER,BOOLEAN,BOOLEAN,UUID[],
    TIMESTAMPTZ,TIMESTAMPTZ,BOOLEAN,TEXT,JSONB
) FROM PUBLIC,anon,authenticated;

CREATE FUNCTION public.save_pricelist_with_rules(
    p_pricelist_id UUID,p_master_version BIGINT,p_code TEXT,p_name TEXT,
    p_scope TEXT,p_customer_id UUID,p_priority INTEGER,p_is_default BOOLEAN,
    p_applies_all_stores BOOLEAN,p_store_ids UUID[],p_valid_from TIMESTAMPTZ,
    p_valid_until TIMESTAMPTZ,p_is_active BOOLEAN,p_notes TEXT,p_rules JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_actor UUID := auth.uid();
    v_company UUID := public.private_active_company_id();
    v_old RECORD;
    v_after JSONB;
BEGIN
    -- The private implementation repeats complete authorization/validation.
    -- These checks protect the preliminary default handover itself.
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF NOT public.private_user_has_any_company_or_store_role(
        v_company,
        ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER']::TEXT[]
    ) THEN
        RAISE EXCEPTION 'PRICELIST_MANAGER_REQUIRED';
    END IF;

    IF COALESCE(p_is_default,FALSE) AND COALESCE(p_is_active,TRUE) THEN
        FOR v_old IN
            SELECT p.id,to_jsonb(p) AS before_state
            FROM public.pricelists p
            WHERE p.company_id = v_company
              AND p.id IS DISTINCT FROM p_pricelist_id
              AND p.scope = upper(COALESCE(p_scope,''))
              AND p.customer_id IS NOT DISTINCT FROM CASE
                    WHEN upper(COALESCE(p_scope,''))='CUSTOMER'
                    THEN p_customer_id ELSE NULL
                  END
              AND p.is_default
              AND p.is_active
            FOR UPDATE
        LOOP
            UPDATE public.pricelists
            SET is_default=FALSE,updated_by=v_actor
            WHERE company_id=v_company AND id=v_old.id;
            SELECT to_jsonb(p) INTO v_after
            FROM public.pricelists p
            WHERE p.company_id=v_company AND p.id=v_old.id;
            INSERT INTO public.pricelist_master_audit(
                company_id,pricelist_id,action,actor_id,before_state,after_state
            ) VALUES (
                v_company,v_old.id,'UPDATE',v_actor,v_old.before_state,v_after
            );
        END LOOP;
    END IF;

    RETURN private.private_save_pricelist_with_rules_g2_legacy(
        p_pricelist_id,p_master_version,p_code,p_name,p_scope,p_customer_id,
        p_priority,p_is_default,p_applies_all_stores,p_store_ids,p_valid_from,
        p_valid_until,p_is_active,p_notes,p_rules
    );
END;
$$;

REVOKE ALL ON FUNCTION public.save_pricelist_with_rules(
    UUID,BIGINT,TEXT,TEXT,TEXT,UUID,INTEGER,BOOLEAN,BOOLEAN,UUID[],
    TIMESTAMPTZ,TIMESTAMPTZ,BOOLEAN,TEXT,JSONB
) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.save_pricelist_with_rules(
    UUID,BIGINT,TEXT,TEXT,TEXT,UUID,INTEGER,BOOLEAN,BOOLEAN,UUID[],
    TIMESTAMPTZ,TIMESTAMPTZ,BOOLEAN,TEXT,JSONB
) TO authenticated,service_role;

CREATE FUNCTION private.trg_g2_require_default_global_pricelist()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_company_id UUID;
BEGIN
    FOR v_company_id IN
        SELECT DISTINCT affected.company_id
        FROM (
            SELECT CASE WHEN TG_OP <> 'INSERT' THEN OLD.company_id END AS company_id
            UNION ALL
            SELECT CASE WHEN TG_OP <> 'DELETE' THEN NEW.company_id END
        ) affected
        WHERE affected.company_id IS NOT NULL
    LOOP
        IF EXISTS (
            SELECT 1 FROM public.companies c
            WHERE c.id = v_company_id AND c.status = 'ACTIVE'
        ) AND (
            SELECT count(*)
            FROM public.pricelists p
            WHERE p.company_id = v_company_id
              AND p.scope = 'GLOBAL'
              AND p.is_default
              AND p.is_active
        ) <> 1 THEN
            RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRES_ONE_DEFAULT_GLOBAL_PRICELIST';
        END IF;
    END LOOP;
    RETURN NULL;
END;
$$;

CREATE FUNCTION private.trg_g2_guard_company_activation_pricelist()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF NEW.status = 'ACTIVE' AND (
        SELECT count(*)
        FROM public.pricelists p
        WHERE p.company_id = NEW.id
          AND p.scope = 'GLOBAL'
          AND p.is_default
          AND p.is_active
    ) <> 1 THEN
        RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRES_ONE_DEFAULT_GLOBAL_PRICELIST';
    END IF;
    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION private.trg_g2_require_default_global_pricelist()
FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION private.trg_g2_guard_company_activation_pricelist()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.trg_g2_require_default_global_pricelist(),
    private.trg_g2_guard_company_activation_pricelist()
TO service_role;

CREATE CONSTRAINT TRIGGER g2_require_default_global_pricelist
AFTER INSERT OR UPDATE OR DELETE ON public.pricelists
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION private.trg_g2_require_default_global_pricelist();

CREATE TRIGGER g2_guard_company_activation_pricelist
AFTER UPDATE OF status ON public.companies
FOR EACH ROW
WHEN (NEW.status = 'ACTIVE')
EXECUTE FUNCTION private.trg_g2_guard_company_activation_pricelist();

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES(
    '20260722080000',
    'g2_phase13_pricelist_default_guard',
    'Forward guard requiring exactly one active default Global Pricelist per active Company'
);

NOTIFY pgrst,'reload schema';
COMMIT;
