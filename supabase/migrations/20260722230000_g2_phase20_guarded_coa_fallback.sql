-- KGS POS G2 phase 20: guarded COA and explicit Company fallback mutation.
-- Finance resolver, worker, accounting period, and journal posting remain off.

BEGIN;

DO $migration_guard$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260722210000'
    ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: phase 19 trigger fix is required';
    END IF;
    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260722230000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260722230000';
    END IF;
END
$migration_guard$;

CREATE FUNCTION private.trg_g2_guard_chart_of_account_structure()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_parent_type TEXT;
    v_parent_postable BOOLEAN;
    v_parent_active BOOLEAN;
    v_parent_depth INTEGER;
    v_cycle BOOLEAN;
    v_compatible_types TEXT[];
BEGIN
    IF TG_OP = 'UPDATE' THEN
        IF OLD.is_system_account IS DISTINCT FROM NEW.is_system_account THEN
            RAISE EXCEPTION 'SYSTEM_ACCOUNT_FLAG_LOCKED';
        END IF;
        IF (NOT NEW.is_active OR NOT NEW.is_postable)
           AND EXISTS (
               SELECT 1 FROM public.transaction_account_rules r
               WHERE r.company_id = OLD.company_id
                 AND r.account_id = OLD.id
                 AND r.status = 'ACTIVE'
                 AND (r.effective_to IS NULL
                      OR r.effective_to > clock_timestamp())
           ) THEN
            RAISE EXCEPTION 'ACCOUNT_IN_USE_BY_ACTIVE_RULE';
        END IF;
        IF (NOT NEW.is_active OR NOT NEW.is_postable)
           AND EXISTS (
               SELECT 1 FROM public.company_account_function_fallbacks f
               WHERE f.company_id = OLD.company_id
                 AND f.account_id = OLD.id
                 AND f.status = 'ACTIVE'
                 AND (f.effective_to IS NULL
                      OR f.effective_to > clock_timestamp())
           ) THEN
            RAISE EXCEPTION 'ACCOUNT_IN_USE_BY_ACTIVE_FALLBACK';
        END IF;
        IF NOT NEW.is_active AND EXISTS (
            SELECT 1 FROM public.chart_of_accounts child
            WHERE child.company_id = OLD.company_id
              AND child.parent_account_id = OLD.id
              AND child.is_active
        ) THEN
            RAISE EXCEPTION 'ACTIVE_CHILD_ACCOUNT_EXISTS';
        END IF;
    END IF;

    IF NEW.parent_account_id IS NOT NULL THEN
        IF NEW.parent_account_id = NEW.id THEN
            RAISE EXCEPTION 'COA_HIERARCHY_CYCLE';
        END IF;
        SELECT parent.account_type,parent.is_postable,parent.is_active
        INTO v_parent_type,v_parent_postable,v_parent_active
        FROM public.chart_of_accounts parent
        WHERE parent.company_id = NEW.company_id
          AND parent.id = NEW.parent_account_id;
        IF v_parent_type IS NULL THEN
            RAISE EXCEPTION 'PARENT_ACCOUNT_NOT_FOUND';
        END IF;
        IF v_parent_postable THEN
            RAISE EXCEPTION 'PARENT_ACCOUNT_MUST_BE_NONPOSTABLE';
        END IF;
        IF NOT v_parent_active THEN
            RAISE EXCEPTION 'ACTIVE_PARENT_ACCOUNT_REQUIRED';
        END IF;
        IF v_parent_type IS DISTINCT FROM NEW.account_type THEN
            RAISE EXCEPTION 'PARENT_ACCOUNT_TYPE_MISMATCH';
        END IF;

        WITH RECURSIVE ancestors AS (
            SELECT
                parent.id,parent.parent_account_id,1 AS depth,
                ARRAY[parent.id]::UUID[] AS path,
                parent.id = NEW.id AS cycle
            FROM public.chart_of_accounts parent
            WHERE parent.company_id = NEW.company_id
              AND parent.id = NEW.parent_account_id

            UNION ALL

            SELECT
                parent.id,parent.parent_account_id,ancestors.depth + 1,
                ancestors.path || parent.id,
                parent.id = ANY(ancestors.path) OR parent.id = NEW.id
            FROM ancestors
            JOIN public.chart_of_accounts parent
              ON parent.company_id = NEW.company_id
             AND parent.id = ancestors.parent_account_id
            WHERE NOT ancestors.cycle AND ancestors.depth < 4
        )
        SELECT COALESCE(max(depth),0),COALESCE(bool_or(cycle),FALSE)
        INTO v_parent_depth,v_cycle
        FROM ancestors;

        IF v_cycle THEN RAISE EXCEPTION 'COA_HIERARCHY_CYCLE'; END IF;
        IF v_parent_depth >= 3 THEN
            RAISE EXCEPTION 'COA_HIERARCHY_MAX_DEPTH_EXCEEDED';
        END IF;
    END IF;

    IF NEW.is_postable AND EXISTS (
        SELECT 1 FROM public.chart_of_accounts child
        WHERE child.company_id = NEW.company_id
          AND child.parent_account_id = NEW.id
    ) THEN
        RAISE EXCEPTION 'PARENT_ACCOUNT_CANNOT_BE_POSTABLE';
    END IF;
    IF EXISTS (
        SELECT 1 FROM public.chart_of_accounts child
        WHERE child.company_id = NEW.company_id
          AND child.parent_account_id = NEW.id
          AND child.account_type IS DISTINCT FROM NEW.account_type
    ) THEN
        RAISE EXCEPTION 'CHILD_ACCOUNT_TYPE_MISMATCH';
    END IF;

    IF NEW.system_function_key IS NOT NULL THEN
        SELECT af.compatible_account_types INTO v_compatible_types
        FROM public.account_functions af
        WHERE af.function_key = NEW.system_function_key
          AND af.is_active;
        IF v_compatible_types IS NULL THEN
            RAISE EXCEPTION 'ACTIVE_ACCOUNT_FUNCTION_NOT_FOUND';
        END IF;
        IF NOT (NEW.account_type = ANY(v_compatible_types)) THEN
            RAISE EXCEPTION 'INCOMPATIBLE_ACCOUNT_TYPE';
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION private.trg_g2_guard_chart_of_account_structure()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.trg_g2_guard_chart_of_account_structure()
TO service_role;

CREATE TRIGGER g2_guard_chart_of_account_structure
BEFORE INSERT OR UPDATE ON public.chart_of_accounts
FOR EACH ROW EXECUTE FUNCTION private.trg_g2_guard_chart_of_account_structure();

CREATE OR REPLACE FUNCTION private.trg_g2_guard_finance_master_history()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF TG_TABLE_NAME = 'transaction_categories' THEN
        IF NEW.system_key IS DISTINCT FROM OLD.system_key
           AND (
               EXISTS (
                   SELECT 1 FROM public.transaction_account_rules r
                   WHERE r.company_id = OLD.company_id
                     AND r.transaction_category_id = OLD.id
               ) OR EXISTS (
                   SELECT 1 FROM public.financial_events e
                   WHERE e.company_id = OLD.company_id
                     AND e.transaction_category_id = OLD.id
               )
           ) THEN
            RAISE EXCEPTION 'CATEGORY_SYSTEM_EVENT_LOCKED_BY_HISTORY';
        END IF;
    ELSIF TG_TABLE_NAME = 'chart_of_accounts' THEN
        IF NEW.account_type IS DISTINCT FROM OLD.account_type
           AND EXISTS (
               SELECT 1 FROM public.journal_entries je
               WHERE je.company_id = OLD.company_id
                 AND je.account_id = OLD.id
           ) THEN
            RAISE EXCEPTION 'ACCOUNT_TYPE_LOCKED_BY_HISTORY';
        END IF;
        IF NEW.system_function_key IS DISTINCT FROM OLD.system_function_key
           AND EXISTS (
               SELECT 1 FROM public.journal_entries je
               WHERE je.company_id = OLD.company_id
                 AND je.account_id = OLD.id
           ) THEN
            RAISE EXCEPTION 'ACCOUNT_FUNCTION_LOCKED_BY_HISTORY';
        END IF;
    ELSE
        RAISE EXCEPTION
            'UNSUPPORTED_FINANCE_MASTER_HISTORY_TABLE: %',TG_TABLE_NAME;
    END IF;
    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION private.trg_g2_guard_finance_master_history()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.trg_g2_guard_finance_master_history()
TO service_role;

CREATE FUNCTION public.save_chart_of_account(
    p_account_id UUID,
    p_master_version BIGINT,
    p_account_code TEXT,
    p_account_name TEXT,
    p_account_type TEXT,
    p_normal_balance TEXT,
    p_parent_account_id UUID,
    p_system_function_key TEXT,
    p_is_postable BOOLEAN,
    p_allow_manual_posting BOOLEAN,
    p_allow_reconciliation BOOLEAN,
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
    v_id UUID;
    v_version BIGINT;
    v_before JSONB;
    v_after JSONB;
    v_type TEXT := upper(btrim(COALESCE(p_account_type,'')));
    v_balance TEXT := upper(btrim(COALESCE(p_normal_balance,'')));
    v_function TEXT := NULLIF(upper(btrim(COALESCE(
        p_system_function_key,''
    ))),'');
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF NOT public.private_user_has_any_company_or_store_role(
        v_company,
        ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE','ACCOUNTING']::TEXT[]
    ) THEN RAISE EXCEPTION 'FINANCE_MASTER_MANAGER_REQUIRED'; END IF;
    -- Serialize structural edits per Company so two concurrent parent changes
    -- cannot both pass hierarchy validation and create a cycle.
    PERFORM pg_advisory_xact_lock(
        hashtextextended('G2_COA|' || v_company::TEXT,0)
    );
    IF btrim(COALESCE(p_account_code,'')) = ''
       OR btrim(COALESCE(p_account_name,'')) = '' THEN
        RAISE EXCEPTION 'INVALID_ACCOUNT_IDENTITY';
    END IF;
    IF v_type NOT IN (
        'ASSET','LIABILITY','EQUITY','REVENUE','COGS','EXPENSE',
        'OTHER_INCOME','OTHER_EXPENSE'
    ) THEN RAISE EXCEPTION 'INVALID_ACCOUNT_TYPE'; END IF;
    IF v_balance NOT IN ('DEBIT','CREDIT') THEN
        RAISE EXCEPTION 'INVALID_NORMAL_BALANCE';
    END IF;
    IF COALESCE(p_allow_manual_posting,FALSE)
       AND NOT COALESCE(p_is_postable,TRUE) THEN
        RAISE EXCEPTION 'MANUAL_POSTING_REQUIRES_POSTABLE_ACCOUNT';
    END IF;

    IF p_account_id IS NULL THEN
        INSERT INTO public.chart_of_accounts(
            company_id,account_code,account_name,account_type,normal_balance,
            parent_account_id,system_function_key,is_system_account,
            is_postable,allow_manual_posting,allow_reconciliation,is_active,
            created_by,updated_by
        ) VALUES (
            v_company,btrim(p_account_code),btrim(p_account_name),
            v_type,v_balance,p_parent_account_id,v_function,FALSE,
            COALESCE(p_is_postable,TRUE),
            COALESCE(p_allow_manual_posting,FALSE),
            COALESCE(p_allow_reconciliation,FALSE),
            COALESCE(p_is_active,TRUE),v_actor,v_actor
        ) RETURNING id,master_version INTO v_id,v_version;
    ELSE
        SELECT to_jsonb(coa),coa.master_version INTO v_before,v_version
        FROM public.chart_of_accounts coa
        WHERE coa.company_id = v_company AND coa.id = p_account_id
        FOR UPDATE;
        IF NOT FOUND THEN RAISE EXCEPTION 'CHART_OF_ACCOUNT_NOT_FOUND'; END IF;
        IF p_master_version IS NULL OR p_master_version <> v_version THEN
            RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
        END IF;
        UPDATE public.chart_of_accounts SET
            account_code = btrim(p_account_code),
            account_name = btrim(p_account_name),
            account_type = v_type,
            normal_balance = v_balance,
            parent_account_id = p_parent_account_id,
            system_function_key = v_function,
            is_postable = COALESCE(p_is_postable,TRUE),
            allow_manual_posting = COALESCE(p_allow_manual_posting,FALSE),
            allow_reconciliation = COALESCE(p_allow_reconciliation,FALSE),
            is_active = COALESCE(p_is_active,TRUE),
            updated_by = v_actor
        WHERE company_id = v_company AND id = p_account_id
        RETURNING id,master_version INTO v_id,v_version;
    END IF;

    SELECT to_jsonb(coa) INTO v_after
    FROM public.chart_of_accounts coa
    WHERE coa.company_id = v_company AND coa.id = v_id;
    INSERT INTO public.finance_master_audit(
        company_id,entity_type,entity_id,action,actor_id,before_state,after_state
    ) VALUES (
        v_company,'ACCOUNT',v_id,
        CASE WHEN p_account_id IS NULL THEN 'CREATE' ELSE 'UPDATE' END,
        v_actor,v_before,v_after
    );
    RETURN jsonb_build_object('accountId',v_id,'masterVersion',v_version);
EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'DUPLICATE_CHART_OF_ACCOUNT';
END;
$$;

CREATE FUNCTION public.save_company_account_function_fallback(
    p_fallback_id UUID,
    p_account_function_key TEXT,
    p_account_id UUID,
    p_effective_from TIMESTAMPTZ,
    p_effective_to TIMESTAMPTZ,
    p_status TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_actor UUID := auth.uid();
    v_company UUID := public.private_active_company_id();
    v_function TEXT := upper(btrim(COALESCE(p_account_function_key,'')));
    v_status TEXT := upper(btrim(COALESCE(p_status,'')));
    v_id UUID;
    v_version BIGINT;
    v_old_status TEXT;
    v_old_function TEXT;
    v_before JSONB;
    v_after JSONB;
    v_previous RECORD;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF NOT public.private_user_has_any_company_or_store_role(
        v_company,
        ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE','ACCOUNTING']::TEXT[]
    ) THEN RAISE EXCEPTION 'FINANCE_MASTER_MANAGER_REQUIRED'; END IF;
    -- Version allocation and active-period replacement are one serialized
    -- mutation per Company + function.
    PERFORM pg_advisory_xact_lock(hashtextextended(
        'G2_FALLBACK|' || v_company::TEXT || '|' || v_function,0
    ));
    IF NOT EXISTS (
        SELECT 1 FROM public.account_functions af
        WHERE af.function_key = v_function AND af.is_active
    ) THEN RAISE EXCEPTION 'ACTIVE_ACCOUNT_FUNCTION_NOT_FOUND'; END IF;
    IF p_effective_from IS NULL THEN RAISE EXCEPTION 'EFFECTIVE_FROM_REQUIRED'; END IF;
    IF p_effective_to IS NOT NULL AND p_effective_to <= p_effective_from THEN
        RAISE EXCEPTION 'INVALID_EFFECTIVE_PERIOD';
    END IF;
    IF v_status NOT IN ('DRAFT','ACTIVE') THEN
        RAISE EXCEPTION 'INVALID_FALLBACK_STATUS';
    END IF;

    IF p_fallback_id IS NULL THEN
        IF v_status = 'ACTIVE' THEN
            FOR v_previous IN
                SELECT f.id,f.effective_from,to_jsonb(f) AS before_state
                FROM public.company_account_function_fallbacks f
                WHERE f.company_id = v_company
                  AND f.account_function_key = v_function
                  AND f.status = 'ACTIVE'
                  AND (f.effective_to IS NULL
                       OR f.effective_to > p_effective_from)
                FOR UPDATE
            LOOP
                IF v_previous.effective_from >= p_effective_from THEN
                    RAISE EXCEPTION 'FALLBACK_VERSION_CONFLICT';
                END IF;
                UPDATE public.company_account_function_fallbacks
                SET effective_to = p_effective_from,updated_by = v_actor
                WHERE company_id = v_company AND id = v_previous.id;
                SELECT to_jsonb(f) INTO v_after
                FROM public.company_account_function_fallbacks f
                WHERE f.company_id = v_company AND f.id = v_previous.id;
                INSERT INTO public.finance_master_audit(
                    company_id,entity_type,entity_id,action,actor_id,
                    before_state,after_state
                ) VALUES (
                    v_company,'FALLBACK',v_previous.id,'UPDATE',v_actor,
                    v_previous.before_state,v_after
                );
            END LOOP;
        END IF;

        SELECT COALESCE(max(fallback_version),0) + 1 INTO v_version
        FROM public.company_account_function_fallbacks
        WHERE company_id = v_company
          AND account_function_key = v_function;

        INSERT INTO public.company_account_function_fallbacks(
            company_id,account_function_key,account_id,effective_from,
            effective_to,fallback_version,status,approved_by,approved_at,
            created_by,updated_by
        ) VALUES (
            v_company,v_function,p_account_id,p_effective_from,p_effective_to,
            v_version,v_status,
            CASE WHEN v_status = 'ACTIVE' THEN v_actor END,
            CASE WHEN v_status = 'ACTIVE' THEN clock_timestamp() END,
            v_actor,v_actor
        ) RETURNING id INTO v_id;
    ELSE
        SELECT to_jsonb(f),f.fallback_version,f.status,f.account_function_key
        INTO v_before,v_version,v_old_status,v_old_function
        FROM public.company_account_function_fallbacks f
        WHERE f.company_id = v_company AND f.id = p_fallback_id
        FOR UPDATE;
        IF NOT FOUND THEN RAISE EXCEPTION 'COMPANY_FALLBACK_NOT_FOUND'; END IF;
        IF v_old_status <> 'DRAFT' THEN
            RAISE EXCEPTION 'ACTIVE_COMPANY_FALLBACK_IMMUTABLE';
        END IF;
        IF v_function IS DISTINCT FROM v_old_function THEN
            RAISE EXCEPTION 'FALLBACK_FUNCTION_LOCKED';
        END IF;
        UPDATE public.company_account_function_fallbacks SET
            account_function_key = v_function,
            account_id = p_account_id,effective_from = p_effective_from,
            effective_to = p_effective_to,status = v_status,
            approved_by = CASE WHEN v_status = 'ACTIVE' THEN v_actor END,
            approved_at = CASE WHEN v_status = 'ACTIVE'
                               THEN clock_timestamp() END,
            updated_by = v_actor
        WHERE company_id = v_company AND id = p_fallback_id
        RETURNING id INTO v_id;
    END IF;

    SELECT to_jsonb(f) INTO v_after
    FROM public.company_account_function_fallbacks f
    WHERE f.company_id = v_company AND f.id = v_id;
    INSERT INTO public.finance_master_audit(
        company_id,entity_type,entity_id,action,actor_id,before_state,after_state
    ) VALUES (
        v_company,'FALLBACK',v_id,
        CASE WHEN p_fallback_id IS NULL THEN 'CREATE' ELSE 'UPDATE' END,
        v_actor,v_before,v_after
    );
    RETURN jsonb_build_object('fallbackId',v_id,'fallbackVersion',v_version);
END;
$$;

REVOKE ALL ON FUNCTION public.save_chart_of_account(
    UUID,BIGINT,TEXT,TEXT,TEXT,TEXT,UUID,TEXT,BOOLEAN,BOOLEAN,BOOLEAN,BOOLEAN
) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.save_chart_of_account(
    UUID,BIGINT,TEXT,TEXT,TEXT,TEXT,UUID,TEXT,BOOLEAN,BOOLEAN,BOOLEAN,BOOLEAN
) TO authenticated,service_role;

REVOKE ALL ON FUNCTION public.save_company_account_function_fallback(
    UUID,TEXT,UUID,TIMESTAMPTZ,TIMESTAMPTZ,TEXT
) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.save_company_account_function_fallback(
    UUID,TEXT,UUID,TIMESTAMPTZ,TIMESTAMPTZ,TEXT
) TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES (
    '20260722230000',
    'g2_phase20_guarded_coa_fallback',
    'Guarded audited COA add/edit/lifecycle and versioned explicit Company account-function fallback; Finance resolver and posting remain disabled'
);

COMMIT;
