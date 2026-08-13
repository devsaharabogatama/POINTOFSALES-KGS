-- KGS POS G6 corrective phase 3: versioned approved posting mapping.
-- Posting engine remains closed; Financial Events in HOLD are not mutated.

BEGIN;

DO $migration_guard$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260810185000'
    ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: imported COA ownership fix required';
    END IF;
    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260810190000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260810190000';
    END IF;
    IF to_regclass('public.posting_rule_sets') IS NOT NULL
       OR to_regclass('public.posting_rule_lines') IS NOT NULL
       OR to_regclass('public.posting_rule_set_audit') IS NOT NULL THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: posting mapping relation exists';
    END IF;
END
$migration_guard$;

CREATE TABLE public.posting_rule_sets (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
    transaction_category_id UUID NOT NULL,
    system_key TEXT NOT NULL REFERENCES public.system_events(system_key),
    rule_set_version BIGINT NOT NULL,
    effective_from TIMESTAMPTZ NOT NULL,
    effective_to TIMESTAMPTZ,
    status TEXT NOT NULL DEFAULT 'DRAFT',
    description TEXT,
    master_version BIGINT NOT NULL DEFAULT 1,
    approved_by UUID REFERENCES public.profiles(id),
    approved_at TIMESTAMPTZ,
    created_by UUID NOT NULL REFERENCES public.profiles(id),
    updated_by UUID NOT NULL REFERENCES public.profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT posting_rule_sets_company_id_id_unique UNIQUE(company_id,id),
    CONSTRAINT posting_rule_sets_identity_unique UNIQUE(
        company_id,transaction_category_id,rule_set_version
    ),
    CONSTRAINT posting_rule_sets_version_positive CHECK(rule_set_version > 0),
    CONSTRAINT posting_rule_sets_master_version_positive CHECK(master_version > 0),
    CONSTRAINT posting_rule_sets_period_check CHECK(
        effective_to IS NULL OR effective_to > effective_from
    ),
    CONSTRAINT posting_rule_sets_status_check CHECK(
        status IN ('DRAFT','APPROVED','RETIRED')
    ),
    CONSTRAINT posting_rule_sets_approval_check CHECK(
        (status = 'DRAFT' AND approved_by IS NULL AND approved_at IS NULL)
        OR (status IN ('APPROVED','RETIRED')
            AND approved_by IS NOT NULL AND approved_at IS NOT NULL)
    ),
    CONSTRAINT fk_posting_rule_sets_company_category
        FOREIGN KEY(company_id,transaction_category_id)
        REFERENCES public.transaction_categories(company_id,id)
        ON DELETE RESTRICT
);

CREATE INDEX idx_posting_rule_sets_resolver
    ON public.posting_rule_sets(
        company_id,transaction_category_id,status,effective_from
    );

CREATE TABLE public.posting_rule_lines (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL,
    rule_set_id UUID NOT NULL,
    line_no INTEGER NOT NULL,
    account_function_key TEXT NOT NULL
        REFERENCES public.account_functions(function_key),
    entry_side TEXT NOT NULL,
    amount_expression_key TEXT NOT NULL,
    condition_key TEXT,
    is_required BOOLEAN NOT NULL DEFAULT TRUE,
    created_by UUID NOT NULL REFERENCES public.profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT posting_rule_lines_company_id_id_unique UNIQUE(company_id,id),
    CONSTRAINT posting_rule_lines_line_unique UNIQUE(
        company_id,rule_set_id,line_no
    ),
    CONSTRAINT posting_rule_lines_identity_unique UNIQUE(
        company_id,rule_set_id,account_function_key,
        entry_side,amount_expression_key
    ),
    CONSTRAINT posting_rule_lines_line_positive CHECK(line_no > 0),
    CONSTRAINT posting_rule_lines_side_check CHECK(
        entry_side IN ('DEBIT','CREDIT')
    ),
    CONSTRAINT posting_rule_lines_expression_format CHECK(
        amount_expression_key ~ '^[A-Z][A-Z0-9_:.]{0,99}$'
    ),
    CONSTRAINT posting_rule_lines_condition_format CHECK(
        condition_key IS NULL
        OR condition_key ~ '^[A-Z][A-Z0-9_:.]{0,99}$'
    ),
    CONSTRAINT fk_posting_rule_lines_company_set
        FOREIGN KEY(company_id,rule_set_id)
        REFERENCES public.posting_rule_sets(company_id,id)
        ON DELETE RESTRICT
);

CREATE INDEX idx_posting_rule_lines_set
    ON public.posting_rule_lines(company_id,rule_set_id,line_no);

CREATE TABLE public.posting_rule_set_audit (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_id UUID NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
    rule_set_id UUID NOT NULL,
    action TEXT NOT NULL,
    actor_id UUID NOT NULL REFERENCES public.profiles(id),
    before_state JSONB,
    after_state JSONB NOT NULL,
    reason TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT posting_rule_set_audit_action_check CHECK(
        action IN ('CREATE','UPDATE','APPROVE','RETIRE')
    ),
    CONSTRAINT fk_posting_rule_set_audit_company_set
        FOREIGN KEY(company_id,rule_set_id)
        REFERENCES public.posting_rule_sets(company_id,id)
        ON DELETE RESTRICT
);

CREATE INDEX idx_posting_rule_set_audit_entity
    ON public.posting_rule_set_audit(company_id,rule_set_id,created_at DESC);

-- Required account mappings prefer one canonical system-owned COA carrying the
-- exact system_function_key. If no system-owned row exists, a sole explicit
-- account is accepted. Compatible account type alone is never sufficient.
DO $provision_required_account_rules$
DECLARE
    v_actor UUID;
    v_unresolved BIGINT;
BEGIN
    SELECT profile.id INTO v_actor
    FROM public.profiles profile
    JOIN auth.users auth_user ON auth_user.id = profile.id
    WHERE profile.role::TEXT = 'super_admin'
    ORDER BY profile.id
    LIMIT 1;
    IF v_actor IS NULL THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: linked Super Admin required';
    END IF;

    WITH required_scope AS (
        SELECT
            category.company_id,
            category.id AS transaction_category_id,
            category.system_key,
            required_function.function_key,
            COALESCE((
                SELECT min(event.event_date)
                FROM public.financial_events event
                WHERE event.company_id = category.company_id
                  AND event.transaction_category_id = category.id
            ),clock_timestamp()) AS effective_from
        FROM public.transaction_categories category
        JOIN public.companies company ON company.id = category.company_id
        JOIN public.system_events system_event
          ON system_event.system_key = category.system_key
        CROSS JOIN LATERAL unnest(
            system_event.required_account_functions
        ) AS required_function(function_key)
        WHERE company.status = 'ACTIVE'
          AND category.is_active
          AND system_event.is_active
    ), explicit_accounts AS (
        SELECT
            scope.*,
            count(account.id) AS explicit_account_count,
            count(account.id) FILTER (
                WHERE account.is_system_account
            ) AS system_account_count,
            (array_agg(
                account.id
                ORDER BY
                    CASE WHEN account.is_system_account THEN 0 ELSE 1 END,
                    account.id
            ) FILTER (WHERE account.id IS NOT NULL))[1] AS account_id
        FROM required_scope scope
        LEFT JOIN public.chart_of_accounts account
          ON account.company_id = scope.company_id
         AND account.system_function_key = scope.function_key
         AND account.is_active
         AND account.is_postable
        GROUP BY
            scope.company_id,scope.transaction_category_id,
            scope.system_key,scope.function_key,scope.effective_from
    ), inserted AS (
        INSERT INTO public.transaction_account_rules(
            company_id,transaction_category_id,system_key,
            account_function_key,account_id,effective_from,effective_to,
            rule_version,status,approved_by,approved_at,created_by,updated_by
        )
        SELECT
            explicit.company_id,explicit.transaction_category_id,
            explicit.system_key,explicit.function_key,explicit.account_id,
            explicit.effective_from,NULL,
            COALESCE((
                SELECT max(existing.rule_version)
                FROM public.transaction_account_rules existing
                WHERE existing.company_id = explicit.company_id
                  AND existing.transaction_category_id =
                      explicit.transaction_category_id
                  AND existing.account_function_key = explicit.function_key
            ),0) + 1,
            'ACTIVE',v_actor,clock_timestamp(),v_actor,v_actor
        FROM explicit_accounts explicit
        WHERE (
                explicit.system_account_count = 1
                OR (
                    explicit.system_account_count = 0
                    AND explicit.explicit_account_count = 1
                )
              )
          AND NOT EXISTS (
              SELECT 1 FROM public.transaction_account_rules existing
              WHERE existing.company_id = explicit.company_id
                AND existing.transaction_category_id =
                    explicit.transaction_category_id
                AND existing.account_function_key = explicit.function_key
                AND existing.status = 'ACTIVE'
                AND existing.effective_from <= explicit.effective_from
                AND (
                    existing.effective_to IS NULL
                    OR existing.effective_to > explicit.effective_from
                )
          )
        RETURNING *
    )
    INSERT INTO public.finance_master_audit(
        company_id,entity_type,entity_id,action,actor_id,after_state
    )
    SELECT
        inserted.company_id,'RULE',inserted.id,'CREATE',v_actor,
        to_jsonb(inserted)
    FROM inserted;

    WITH required_scope AS (
        SELECT
            category.company_id,
            category.id AS transaction_category_id,
            category.system_key,
            required_function.function_key
        FROM public.transaction_categories category
        JOIN public.companies company ON company.id = category.company_id
        JOIN public.system_events system_event
          ON system_event.system_key = category.system_key
        CROSS JOIN LATERAL unnest(
            system_event.required_account_functions
        ) AS required_function(function_key)
        WHERE company.status = 'ACTIVE'
          AND category.is_active
          AND system_event.is_active
    )
    SELECT count(*) INTO v_unresolved
    FROM required_scope scope
    WHERE NOT EXISTS (
        SELECT 1 FROM public.transaction_account_rules rule
        WHERE rule.company_id = scope.company_id
          AND rule.transaction_category_id = scope.transaction_category_id
          AND rule.system_key = scope.system_key
          AND rule.account_function_key = scope.function_key
          AND rule.status = 'ACTIVE'
          AND rule.effective_to IS NULL
    );
    IF v_unresolved <> 0 THEN
        RAISE EXCEPTION
            'PHASE3_REQUIRED_MAPPING_UNRESOLVED: % rows',v_unresolved;
    END IF;
END
$provision_required_account_rules$;

CREATE FUNCTION private.trg_g6_guard_posting_rule_set()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_system_key TEXT;
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'POSTING_RULE_SET_DELETE_FORBIDDEN';
    END IF;
    SELECT category.system_key INTO v_system_key
    FROM public.transaction_categories category
    WHERE category.company_id = NEW.company_id
      AND category.id = NEW.transaction_category_id;
    IF v_system_key IS NULL OR v_system_key IS DISTINCT FROM NEW.system_key THEN
        RAISE EXCEPTION 'POSTING_RULE_CATEGORY_EVENT_MISMATCH';
    END IF;
    IF TG_OP = 'INSERT' THEN
        IF NEW.status <> 'DRAFT' OR NEW.master_version <> 1 THEN
            RAISE EXCEPTION 'POSTING_RULE_SET_MUST_START_DRAFT';
        END IF;
        RETURN NEW;
    END IF;
    IF OLD.status <> 'DRAFT' THEN
        IF OLD.status = 'APPROVED' AND NEW.status = 'APPROVED' THEN
            IF NEW.company_id IS DISTINCT FROM OLD.company_id
               OR NEW.transaction_category_id IS DISTINCT FROM
                  OLD.transaction_category_id
               OR NEW.system_key IS DISTINCT FROM OLD.system_key
               OR NEW.rule_set_version IS DISTINCT FROM OLD.rule_set_version
               OR NEW.effective_from IS DISTINCT FROM OLD.effective_from
               OR NEW.description IS DISTINCT FROM OLD.description
               OR NEW.approved_by IS DISTINCT FROM OLD.approved_by
               OR NEW.approved_at IS DISTINCT FROM OLD.approved_at
               OR NEW.effective_to IS NULL
               OR NEW.effective_to <= OLD.effective_from THEN
                RAISE EXCEPTION 'APPROVED_POSTING_RULE_IDENTITY_IMMUTABLE';
            END IF;
        ELSIF NEW.status = 'RETIRED' AND OLD.status = 'APPROVED' THEN
            IF NEW.company_id IS DISTINCT FROM OLD.company_id
               OR NEW.transaction_category_id IS DISTINCT FROM
                  OLD.transaction_category_id
               OR NEW.system_key IS DISTINCT FROM OLD.system_key
               OR NEW.rule_set_version IS DISTINCT FROM OLD.rule_set_version
               OR NEW.effective_from IS DISTINCT FROM OLD.effective_from
               OR NEW.approved_by IS DISTINCT FROM OLD.approved_by
               OR NEW.approved_at IS DISTINCT FROM OLD.approved_at THEN
                RAISE EXCEPTION 'APPROVED_POSTING_RULE_IDENTITY_IMMUTABLE';
            END IF;
        ELSE
            RAISE EXCEPTION 'APPROVED_POSTING_RULE_SET_IMMUTABLE';
        END IF;
    END IF;
    NEW.master_version := OLD.master_version + 1;
    NEW.updated_at := clock_timestamp();
    RETURN NEW;
END;
$$;

CREATE FUNCTION private.trg_g6_guard_posting_rule_line()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_company UUID;
    v_rule_set UUID;
    v_status TEXT;
    v_system_key TEXT;
BEGIN
    IF TG_OP = 'DELETE' THEN
        v_company := OLD.company_id;
        v_rule_set := OLD.rule_set_id;
    ELSE
        v_company := NEW.company_id;
        v_rule_set := NEW.rule_set_id;
    END IF;
    SELECT rule_set.status,rule_set.system_key
    INTO v_status,v_system_key
    FROM public.posting_rule_sets rule_set
    WHERE rule_set.company_id = v_company AND rule_set.id = v_rule_set
    FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'POSTING_RULE_SET_NOT_FOUND'; END IF;
    IF v_status <> 'DRAFT' THEN
        RAISE EXCEPTION 'APPROVED_POSTING_RULE_LINES_IMMUTABLE';
    END IF;
    IF TG_OP <> 'DELETE' AND NOT EXISTS (
        SELECT 1 FROM public.system_events system_event
        WHERE system_event.system_key = v_system_key
          AND NEW.account_function_key = ANY(
              system_event.required_account_functions
              || system_event.conditional_account_functions
              || system_event.optional_account_functions
          )
    ) THEN
        RAISE EXCEPTION 'FUNCTION_NOT_ALLOWED_FOR_SYSTEM_EVENT';
    END IF;
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION private.trg_g6_guard_posting_rule_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    RAISE EXCEPTION 'POSTING_RULE_AUDIT_IMMUTABLE';
END;
$$;

CREATE TRIGGER g6_guard_posting_rule_set
BEFORE INSERT OR UPDATE OR DELETE ON public.posting_rule_sets
FOR EACH ROW EXECUTE FUNCTION private.trg_g6_guard_posting_rule_set();
CREATE TRIGGER g6_guard_posting_rule_line
BEFORE INSERT OR UPDATE OR DELETE ON public.posting_rule_lines
FOR EACH ROW EXECUTE FUNCTION private.trg_g6_guard_posting_rule_line();
CREATE TRIGGER g6_guard_posting_rule_audit
BEFORE UPDATE OR DELETE ON public.posting_rule_set_audit
FOR EACH ROW EXECUTE FUNCTION private.trg_g6_guard_posting_rule_audit();

CREATE FUNCTION public.save_posting_rule_set(
    p_rule_set_id UUID,
    p_master_version BIGINT,
    p_transaction_category_id UUID,
    p_effective_from TIMESTAMPTZ,
    p_effective_to TIMESTAMPTZ,
    p_description TEXT,
    p_lines JSONB
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_actor UUID := auth.uid();
    v_company UUID := public.private_active_company_id();
    v_category public.transaction_categories%ROWTYPE;
    v_set public.posting_rule_sets%ROWTYPE;
    v_before JSONB;
    v_line JSONB;
    v_line_no INTEGER;
    v_function TEXT;
    v_side TEXT;
    v_expression TEXT;
    v_condition TEXT;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF NOT public.private_user_has_any_company_or_store_role(
        v_company,
        ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE','ACCOUNTING']::TEXT[]
    ) THEN RAISE EXCEPTION 'FINANCE_MAPPING_MANAGER_REQUIRED'; END IF;
    IF p_effective_from IS NULL THEN RAISE EXCEPTION 'EFFECTIVE_FROM_REQUIRED'; END IF;
    IF p_effective_to IS NOT NULL AND p_effective_to <= p_effective_from THEN
        RAISE EXCEPTION 'INVALID_EFFECTIVE_PERIOD';
    END IF;
    IF jsonb_typeof(p_lines) <> 'array'
       OR jsonb_array_length(p_lines) < 2
       OR jsonb_array_length(p_lines) > 100 THEN
        RAISE EXCEPTION 'POSTING_RULE_LINES_INVALID';
    END IF;

    SELECT * INTO v_category
    FROM public.transaction_categories category
    WHERE category.company_id = v_company
      AND category.id = p_transaction_category_id
      AND category.is_active;
    IF NOT FOUND THEN RAISE EXCEPTION 'ACTIVE_TRANSACTION_CATEGORY_NOT_FOUND'; END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended(
        'G6_POSTING_RULE|' || v_company::TEXT || '|'
        || p_transaction_category_id::TEXT,0
    ));

    IF p_rule_set_id IS NULL THEN
        INSERT INTO public.posting_rule_sets(
            company_id,transaction_category_id,system_key,rule_set_version,
            effective_from,effective_to,status,description,created_by,updated_by
        ) VALUES (
            v_company,p_transaction_category_id,v_category.system_key,
            COALESCE((SELECT max(existing.rule_set_version)
                      FROM public.posting_rule_sets existing
                      WHERE existing.company_id = v_company
                        AND existing.transaction_category_id =
                            p_transaction_category_id),0) + 1,
            p_effective_from,p_effective_to,'DRAFT',
            NULLIF(btrim(COALESCE(p_description,'')),''),v_actor,v_actor
        ) RETURNING * INTO v_set;
    ELSE
        SELECT * INTO v_set FROM public.posting_rule_sets rule_set
        WHERE rule_set.company_id = v_company AND rule_set.id = p_rule_set_id
        FOR UPDATE;
        IF NOT FOUND THEN RAISE EXCEPTION 'POSTING_RULE_SET_NOT_FOUND'; END IF;
        IF v_set.status <> 'DRAFT' THEN
            RAISE EXCEPTION 'APPROVED_POSTING_RULE_SET_IMMUTABLE';
        END IF;
        IF p_master_version IS NULL OR p_master_version <> v_set.master_version THEN
            RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
        END IF;
        IF v_set.transaction_category_id IS DISTINCT FROM p_transaction_category_id
        THEN RAISE EXCEPTION 'POSTING_RULE_CATEGORY_IMMUTABLE'; END IF;
        v_before := to_jsonb(v_set) || jsonb_build_object(
            'lines',(SELECT COALESCE(jsonb_agg(to_jsonb(line)
                         ORDER BY line.line_no),'[]'::JSONB)
                     FROM public.posting_rule_lines line
                     WHERE line.company_id = v_company
                       AND line.rule_set_id = v_set.id)
        );
        DELETE FROM public.posting_rule_lines line
        WHERE line.company_id = v_company AND line.rule_set_id = v_set.id;
        UPDATE public.posting_rule_sets SET
            effective_from = p_effective_from,
            effective_to = p_effective_to,
            description = NULLIF(btrim(COALESCE(p_description,'')),''),
            updated_by = v_actor
        WHERE company_id = v_company AND id = v_set.id
        RETURNING * INTO v_set;
    END IF;

    FOR v_line IN SELECT value FROM jsonb_array_elements(p_lines)
    LOOP
        v_line_no := NULLIF(v_line->>'lineNo','')::INTEGER;
        v_function := upper(btrim(COALESCE(v_line->>'accountFunctionKey','')));
        v_side := upper(btrim(COALESCE(v_line->>'entrySide','')));
        v_expression := upper(btrim(COALESCE(v_line->>'amountExpressionKey','')));
        v_condition := NULLIF(upper(btrim(COALESCE(v_line->>'conditionKey',''))),'');
        IF v_line_no IS NULL OR v_line_no <= 0
           OR v_side NOT IN ('DEBIT','CREDIT')
           OR v_expression !~ '^[A-Z][A-Z0-9_:.]{0,99}$'
           OR (v_condition IS NOT NULL
               AND v_condition !~ '^[A-Z][A-Z0-9_:.]{0,99}$') THEN
            RAISE EXCEPTION 'POSTING_RULE_LINE_INVALID';
        END IF;
        INSERT INTO public.posting_rule_lines(
            company_id,rule_set_id,line_no,account_function_key,
            entry_side,amount_expression_key,condition_key,is_required,created_by
        ) VALUES (
            v_company,v_set.id,v_line_no,v_function,v_side,v_expression,
            v_condition,COALESCE((v_line->>'isRequired')::BOOLEAN,TRUE),v_actor
        );
    END LOOP;

    SELECT * INTO v_set FROM public.posting_rule_sets rule_set
    WHERE rule_set.company_id = v_company AND rule_set.id = v_set.id;
    INSERT INTO public.posting_rule_set_audit(
        company_id,rule_set_id,action,actor_id,before_state,after_state
    ) VALUES (
        v_company,v_set.id,
        CASE WHEN p_rule_set_id IS NULL THEN 'CREATE' ELSE 'UPDATE' END,
        v_actor,v_before,
        to_jsonb(v_set) || jsonb_build_object(
            'lines',(SELECT jsonb_agg(to_jsonb(line) ORDER BY line.line_no)
                     FROM public.posting_rule_lines line
                     WHERE line.company_id = v_company
                       AND line.rule_set_id = v_set.id)
        )
    );
    RETURN jsonb_build_object(
        'postingRuleSetId',v_set.id,
        'ruleSetVersion',v_set.rule_set_version,
        'masterVersion',v_set.master_version,
        'status',v_set.status
    );
EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'DUPLICATE_POSTING_RULE_LINE';
END;
$$;

CREATE FUNCTION public.approve_posting_rule_set(
    p_rule_set_id UUID,p_master_version BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_actor UUID := auth.uid();
    v_company UUID := public.private_active_company_id();
    v_set public.posting_rule_sets%ROWTYPE;
    v_before JSONB;
    v_unresolved BIGINT;
    v_previous RECORD;
    v_previous_after public.posting_rule_sets%ROWTYPE;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF NOT public.private_user_has_any_company_or_store_role(
        v_company,ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE']::TEXT[]
    ) THEN RAISE EXCEPTION 'FINANCE_MAPPING_APPROVER_REQUIRED'; END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended(
        'G6_POSTING_RULE|' || v_company::TEXT || '|' || p_rule_set_id::TEXT,0
    ));
    SELECT * INTO v_set FROM public.posting_rule_sets rule_set
    WHERE rule_set.company_id = v_company AND rule_set.id = p_rule_set_id
    FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'POSTING_RULE_SET_NOT_FOUND'; END IF;
    IF v_set.status <> 'DRAFT' THEN RAISE EXCEPTION 'POSTING_RULE_SET_NOT_DRAFT'; END IF;
    IF p_master_version IS NULL OR p_master_version <> v_set.master_version THEN
        RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM public.posting_rule_lines line
        WHERE line.company_id = v_company AND line.rule_set_id = v_set.id
          AND line.entry_side = 'DEBIT'
    ) OR NOT EXISTS (
        SELECT 1 FROM public.posting_rule_lines line
        WHERE line.company_id = v_company AND line.rule_set_id = v_set.id
          AND line.entry_side = 'CREDIT'
    ) THEN RAISE EXCEPTION 'POSTING_RULE_BOTH_SIDES_REQUIRED'; END IF;
    IF EXISTS (
        SELECT 1
        FROM public.system_events system_event
        CROSS JOIN LATERAL unnest(
            system_event.required_account_functions
        ) AS required_function(function_key)
        WHERE system_event.system_key = v_set.system_key
          AND NOT EXISTS (
              SELECT 1 FROM public.posting_rule_lines line
              WHERE line.company_id = v_company
                AND line.rule_set_id = v_set.id
                AND line.account_function_key = required_function.function_key
          )
    ) THEN RAISE EXCEPTION 'POSTING_RULE_REQUIRED_FUNCTION_MISSING'; END IF;

    SELECT count(*) INTO v_unresolved
    FROM public.posting_rule_lines line
    CROSS JOIN LATERAL (
        SELECT count(*) AS exact_count
        FROM public.transaction_account_rules rule
        WHERE rule.company_id = v_company
          AND rule.transaction_category_id = v_set.transaction_category_id
          AND rule.system_key = v_set.system_key
          AND rule.account_function_key = line.account_function_key
          AND rule.status = 'ACTIVE'
          AND rule.effective_from <= v_set.effective_from
          AND (rule.effective_to IS NULL
               OR rule.effective_to > v_set.effective_from)
    ) exact_resolution
    CROSS JOIN LATERAL (
        SELECT count(*) AS fallback_count
        FROM public.company_account_function_fallbacks fallback
        WHERE fallback.company_id = v_company
          AND fallback.account_function_key = line.account_function_key
          AND fallback.status = 'ACTIVE'
          AND fallback.effective_from <= v_set.effective_from
          AND (fallback.effective_to IS NULL
               OR fallback.effective_to > v_set.effective_from)
    ) fallback_resolution
    WHERE line.company_id = v_company AND line.rule_set_id = v_set.id
      AND NOT (
          exact_resolution.exact_count = 1
          OR (
              exact_resolution.exact_count = 0
              AND fallback_resolution.fallback_count = 1
          )
      );
    IF v_unresolved <> 0 THEN
        RAISE EXCEPTION 'POSTING_RULE_ACCOUNT_RESOLUTION_INCOMPLETE';
    END IF;

    FOR v_previous IN
        SELECT previous.* FROM public.posting_rule_sets previous
        WHERE previous.company_id = v_company
          AND previous.transaction_category_id = v_set.transaction_category_id
          AND previous.status = 'APPROVED'
          AND (previous.effective_to IS NULL
               OR previous.effective_to > v_set.effective_from)
        FOR UPDATE
    LOOP
        IF v_previous.effective_from >= v_set.effective_from THEN
            RAISE EXCEPTION 'POSTING_RULE_VERSION_CONFLICT';
        END IF;
        UPDATE public.posting_rule_sets SET
            effective_to = v_set.effective_from,updated_by = v_actor
        WHERE company_id = v_company AND id = v_previous.id
        RETURNING * INTO v_previous_after;
        INSERT INTO public.posting_rule_set_audit(
            company_id,rule_set_id,action,actor_id,before_state,after_state
        ) VALUES (
            v_company,v_previous.id,'UPDATE',v_actor,
            to_jsonb(v_previous),to_jsonb(v_previous_after)
        );
    END LOOP;

    v_before := to_jsonb(v_set);
    UPDATE public.posting_rule_sets SET
        status = 'APPROVED',approved_by = v_actor,
        approved_at = clock_timestamp(),updated_by = v_actor
    WHERE company_id = v_company AND id = v_set.id
    RETURNING * INTO v_set;
    INSERT INTO public.posting_rule_set_audit(
        company_id,rule_set_id,action,actor_id,before_state,after_state
    ) VALUES (
        v_company,v_set.id,'APPROVE',v_actor,v_before,to_jsonb(v_set)
    );
    RETURN jsonb_build_object(
        'postingRuleSetId',v_set.id,'status',v_set.status,
        'masterVersion',v_set.master_version
    );
END;
$$;

ALTER TABLE public.posting_rule_sets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.posting_rule_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.posting_rule_set_audit ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Finance roles read Posting Rule Sets"
ON public.posting_rule_sets FOR SELECT TO authenticated
USING(public.private_finance_company_visible(company_id));
CREATE POLICY "Finance roles read Posting Rule Lines"
ON public.posting_rule_lines FOR SELECT TO authenticated
USING(public.private_finance_company_visible(company_id));
CREATE POLICY "Finance roles read Posting Rule Audit"
ON public.posting_rule_set_audit FOR SELECT TO authenticated
USING(public.private_finance_company_visible(company_id));

REVOKE ALL ON public.posting_rule_sets,public.posting_rule_lines,
    public.posting_rule_set_audit
FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.posting_rule_sets,public.posting_rule_lines,
    public.posting_rule_set_audit TO authenticated;
GRANT ALL ON public.posting_rule_sets,public.posting_rule_lines,
    public.posting_rule_set_audit TO service_role;
GRANT USAGE,SELECT ON SEQUENCE public.posting_rule_set_audit_id_seq
TO service_role;

REVOKE ALL ON FUNCTION
    private.trg_g6_guard_posting_rule_set(),
    private.trg_g6_guard_posting_rule_line(),
    private.trg_g6_guard_posting_rule_audit()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
    private.trg_g6_guard_posting_rule_set(),
    private.trg_g6_guard_posting_rule_line(),
    private.trg_g6_guard_posting_rule_audit()
TO service_role;

REVOKE ALL ON FUNCTION
    public.save_posting_rule_set(
        UUID,BIGINT,UUID,TIMESTAMPTZ,TIMESTAMPTZ,TEXT,JSONB
    ),
    public.approve_posting_rule_set(UUID,BIGINT)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION
    public.save_posting_rule_set(
        UUID,BIGINT,UUID,TIMESTAMPTZ,TIMESTAMPTZ,TEXT,JSONB
    ),
    public.approve_posting_rule_set(UUID,BIGINT)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES (
    '20260810190000',
    'g6_phase3_versioned_posting_mapping',
    'Explicit unique system-function account provisioning plus guarded versioned/effective/approved posting rule-set header-line-audit; no Financial Event processing or journal posting'
);

COMMIT;
