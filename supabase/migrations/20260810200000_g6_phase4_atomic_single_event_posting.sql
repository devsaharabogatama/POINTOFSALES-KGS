-- KGS POS G6 corrective phase 4: atomic single-event posting engine.
--
-- Initial supported contract is deliberately limited to STOCK_OPENING:
-- Inventory Asset debit equals Opening Balance Clearing credit.
-- Existing Financial Events remain HOLD; historical processing is Phase 5.

BEGIN;

DO $migration_guard$
DECLARE
    v_existing_rule_sets BIGINT;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260810190000'
    ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: G6 phase 3 mapping required';
    END IF;
    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260810200000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260810200000';
    END IF;
    IF to_regprocedure(
        'public.post_financial_event_by_id(uuid,bigint)'
    ) IS NOT NULL
       OR EXISTS (
           SELECT 1
           FROM pg_proc routine
           JOIN pg_namespace namespace
             ON namespace.oid = routine.pronamespace
           WHERE namespace.nspname = 'private'
             AND routine.proname IN (
                 'resolve_financial_event_amount',
                 'resolve_financial_event_account',
                 'post_financial_event_core'
             )
       ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: Phase 4 routine target exists';
    END IF;
    SELECT count(*) INTO v_existing_rule_sets
    FROM public.posting_rule_sets
    WHERE system_key = 'STOCK_OPENING';
    IF v_existing_rule_sets <> 0 THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: STOCK_OPENING rule-set already exists';
    END IF;
END
$migration_guard$;

ALTER TYPE public.event_status ADD VALUE IF NOT EXISTS 'POSTED';

CREATE FUNCTION private.provision_g6_posting_configuration(
    p_company_id UUID,p_actor_id UUID DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_actor UUID := p_actor_id;
    v_category public.transaction_categories%ROWTYPE;
    v_rule_set public.posting_rule_sets%ROWTYPE;
    v_effective_from TIMESTAMPTZ;
    v_unresolved BIGINT;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.companies company
        WHERE company.id = p_company_id AND company.status = 'ACTIVE'
    ) THEN
        RETURN;
    END IF;
    IF v_actor IS NULL OR NOT EXISTS (
        SELECT 1 FROM public.profiles profile WHERE profile.id = v_actor
    ) THEN
        SELECT profile.id INTO v_actor
        FROM public.profiles profile
        JOIN auth.users auth_user ON auth_user.id = profile.id
        WHERE profile.role::TEXT = 'super_admin'
        ORDER BY profile.id
        LIMIT 1;
    END IF;
    IF v_actor IS NULL THEN
        RAISE EXCEPTION 'LINKED_SUPER_ADMIN_REQUIRED';
    END IF;

    -- Future active Companies receive the same explicit account mapping
    -- contract as Companies present during Phase 3.
    WITH required_scope AS (
        SELECT
            category.company_id,
            category.id AS transaction_category_id,
            category.system_key,
            required_function.function_key
        FROM public.transaction_categories category
        JOIN public.system_events system_event
          ON system_event.system_key = category.system_key
        CROSS JOIN LATERAL unnest(
            system_event.required_account_functions
        ) AS required_function(function_key)
        WHERE category.company_id = p_company_id
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
                account.id ORDER BY
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
            scope.system_key,scope.function_key
    ), inserted AS (
        INSERT INTO public.transaction_account_rules(
            company_id,transaction_category_id,system_key,
            account_function_key,account_id,effective_from,effective_to,
            rule_version,status,approved_by,approved_at,created_by,updated_by
        )
        SELECT
            explicit.company_id,explicit.transaction_category_id,
            explicit.system_key,explicit.function_key,explicit.account_id,
            clock_timestamp(),NULL,
            COALESCE((
                SELECT max(existing.rule_version)
                FROM public.transaction_account_rules existing
                WHERE existing.company_id = explicit.company_id
                  AND existing.transaction_category_id =
                      explicit.transaction_category_id
                  AND existing.account_function_key = explicit.function_key
            ),0) + 1,
            'ACTIVE',v_actor,clock_timestamp(),
            v_actor,v_actor
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
                AND existing.system_key = explicit.system_key
                AND existing.account_function_key = explicit.function_key
                AND existing.status = 'ACTIVE'
                AND existing.effective_to IS NULL
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

    SELECT count(*) INTO v_unresolved
    FROM public.transaction_categories category
    JOIN public.system_events system_event
      ON system_event.system_key = category.system_key
    CROSS JOIN LATERAL unnest(
        system_event.required_account_functions
    ) AS required_function(function_key)
    WHERE category.company_id = p_company_id
      AND category.is_active
      AND system_event.is_active
      AND NOT EXISTS (
          SELECT 1 FROM public.transaction_account_rules rule
          WHERE rule.company_id = p_company_id
            AND rule.transaction_category_id = category.id
            AND rule.system_key = category.system_key
            AND rule.account_function_key = required_function.function_key
            AND rule.status = 'ACTIVE'
            AND rule.effective_to IS NULL
      );
    IF v_unresolved <> 0 THEN
        RAISE EXCEPTION
            'REQUIRED_ACCOUNT_MAPPING_UNRESOLVED: % rows',v_unresolved;
    END IF;

    FOR v_category IN
        SELECT category.*
        FROM public.transaction_categories category
        WHERE category.company_id = p_company_id
          AND category.system_key = 'STOCK_OPENING'
          AND category.is_active
        ORDER BY category.is_system_default DESC,category.id
    LOOP
        IF EXISTS (
            SELECT 1 FROM public.posting_rule_sets existing
            WHERE existing.company_id = p_company_id
              AND existing.transaction_category_id = v_category.id
        ) THEN
            CONTINUE;
        END IF;

        SELECT COALESCE(min(event.event_date),clock_timestamp())
        INTO v_effective_from
        FROM public.financial_events event
        WHERE event.company_id = p_company_id
          AND event.transaction_category_id = v_category.id;

        INSERT INTO public.posting_rule_sets(
            company_id,transaction_category_id,system_key,rule_set_version,
            effective_from,status,description,created_by,updated_by
        ) VALUES (
            p_company_id,v_category.id,'STOCK_OPENING',1,
            v_effective_from,'DRAFT',
            'Canonical Stock Opening: Inventory debit and opening clearing credit',
            v_actor,v_actor
        ) RETURNING * INTO v_rule_set;

        INSERT INTO public.posting_rule_lines(
            company_id,rule_set_id,line_no,account_function_key,
            entry_side,amount_expression_key,is_required,created_by
        ) VALUES
            (
                p_company_id,v_rule_set.id,1,'INVENTORY_ASSET','DEBIT',
                'STOCK_OPENING_INVENTORY',TRUE,v_actor
            ),
            (
                p_company_id,v_rule_set.id,2,
                'OPENING_BALANCE_CLEARING','CREDIT',
                'STOCK_OPENING_CLEARING',TRUE,v_actor
            );

        INSERT INTO public.posting_rule_set_audit(
            company_id,rule_set_id,action,actor_id,after_state
        ) VALUES (
            p_company_id,v_rule_set.id,'CREATE',v_actor,
            to_jsonb(v_rule_set) || jsonb_build_object(
                'lines',(
                    SELECT jsonb_agg(to_jsonb(line) ORDER BY line.line_no)
                    FROM public.posting_rule_lines line
                    WHERE line.company_id = p_company_id
                      AND line.rule_set_id = v_rule_set.id
                )
            )
        );

        UPDATE public.posting_rule_sets SET
            status = 'APPROVED',approved_by = v_actor,
            approved_at = clock_timestamp(),updated_by = v_actor
        WHERE company_id = p_company_id AND id = v_rule_set.id
        RETURNING * INTO v_rule_set;

        INSERT INTO public.posting_rule_set_audit(
            company_id,rule_set_id,action,actor_id,after_state
        ) VALUES (
            p_company_id,v_rule_set.id,'APPROVE',v_actor,to_jsonb(v_rule_set)
        );
    END LOOP;
END;
$$;

CREATE FUNCTION private.trg_g6_provision_posting_configuration()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF TG_OP = 'INSERT' AND NEW.status = 'ACTIVE' THEN
        PERFORM private.provision_g6_posting_configuration(NEW.id,auth.uid());
    ELSIF TG_OP = 'UPDATE' AND NEW.status = 'ACTIVE'
          AND OLD.status IS DISTINCT FROM NEW.status THEN
        PERFORM private.provision_g6_posting_configuration(NEW.id,auth.uid());
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER g6_provision_posting_configuration
AFTER INSERT OR UPDATE OF status ON public.companies
FOR EACH ROW EXECUTE FUNCTION private.trg_g6_provision_posting_configuration();

DO $provision_existing_companies$
DECLARE
    v_actor UUID;
    v_company RECORD;
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
    FOR v_company IN
        SELECT company.id FROM public.companies company
        WHERE company.status = 'ACTIVE'
        ORDER BY company.id
    LOOP
        PERFORM private.provision_g6_posting_configuration(
            v_company.id,v_actor
        );
    END LOOP;
END
$provision_existing_companies$;

CREATE FUNCTION private.resolve_financial_event_amount(
    p_event public.financial_events,p_expression_key TEXT
) RETURNS NUMERIC
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_document public.opening_stock_documents%ROWTYPE;
    v_amount NUMERIC(20,4);
    v_json_key TEXT;
BEGIN
    IF p_event.system_event_key <> 'STOCK_OPENING'
       OR p_event.event_type::TEXT <> 'STOCK_OPENING'
       OR p_event.source_table <> 'opening_stock_documents' THEN
        RAISE EXCEPTION 'UNSUPPORTED_FINANCIAL_EVENT_CONTRACT';
    END IF;
    SELECT * INTO v_document
    FROM public.opening_stock_documents document
    WHERE document.company_id = p_event.company_id
      AND document.id = p_event.source_id
      AND document.financial_event_id = p_event.id
      AND document.status = 'POSTED';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'FINANCIAL_EVENT_SOURCE_NOT_FOUND';
    END IF;
    IF p_event.event_date::DATE <> v_document.effective_date THEN
        RAISE EXCEPTION 'FINANCIAL_EVENT_SOURCE_DATE_MISMATCH';
    END IF;
    v_json_key := CASE upper(btrim(p_expression_key))
        WHEN 'STOCK_OPENING_INVENTORY' THEN 'inventoryDebit'
        WHEN 'STOCK_OPENING_CLEARING' THEN 'openingBalanceCredit'
        ELSE NULL
    END;
    IF v_json_key IS NULL
       OR jsonb_typeof(p_event.amounts->v_json_key) <> 'number' THEN
        RAISE EXCEPTION 'AMOUNT_EXPRESSION_NOT_SUPPORTED';
    END IF;
    v_amount := round((p_event.amounts->>v_json_key)::NUMERIC,4);
    IF v_amount <= 0
       OR v_amount <> round(v_document.total_cost,4) THEN
        RAISE EXCEPTION 'FINANCIAL_EVENT_AMOUNT_SOURCE_MISMATCH';
    END IF;
    RETURN v_amount;
END;
$$;

CREATE FUNCTION private.resolve_financial_event_account(
    p_event public.financial_events,p_account_function_key TEXT
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_exact_count BIGINT;
    v_fallback_count BIGINT;
    v_account_id UUID;
    v_account public.chart_of_accounts%ROWTYPE;
    v_function public.account_functions%ROWTYPE;
BEGIN
    SELECT count(*),(
        array_agg(rule.account_id ORDER BY rule.rule_version DESC,rule.id)
    )[1]
    INTO v_exact_count,v_account_id
    FROM public.transaction_account_rules rule
    WHERE rule.company_id = p_event.company_id
      AND rule.transaction_category_id = p_event.transaction_category_id
      AND rule.system_key = p_event.system_event_key
      AND rule.account_function_key = p_account_function_key
      AND rule.status = 'ACTIVE'
      AND rule.effective_from <= p_event.event_date
      AND (
          rule.effective_to IS NULL OR rule.effective_to > p_event.event_date
      );
    IF v_exact_count = 0 THEN
        SELECT count(*),(
            array_agg(
                fallback.account_id
                ORDER BY fallback.fallback_version DESC,fallback.id
            )
        )[1]
        INTO v_fallback_count,v_account_id
        FROM public.company_account_function_fallbacks fallback
        WHERE fallback.company_id = p_event.company_id
          AND fallback.account_function_key = p_account_function_key
          AND fallback.status = 'ACTIVE'
          AND fallback.effective_from <= p_event.event_date
          AND (
              fallback.effective_to IS NULL
              OR fallback.effective_to > p_event.event_date
          );
        IF v_fallback_count <> 1 THEN
            RAISE EXCEPTION 'ACCOUNT_MAPPING_MISSING_OR_AMBIGUOUS';
        END IF;
    ELSIF v_exact_count <> 1 THEN
        RAISE EXCEPTION 'ACCOUNT_MAPPING_MISSING_OR_AMBIGUOUS';
    END IF;

    SELECT * INTO v_function
    FROM public.account_functions function_state
    WHERE function_state.function_key = p_account_function_key
      AND function_state.is_active;
    SELECT * INTO v_account
    FROM public.chart_of_accounts account
    WHERE account.company_id = p_event.company_id
      AND account.id = v_account_id;
    IF v_function.function_key IS NULL OR v_account.id IS NULL
       OR NOT v_account.is_active OR NOT v_account.is_postable
       OR NOT (v_account.account_type = ANY(v_function.compatible_account_types))
    THEN
        RAISE EXCEPTION 'ACCOUNT_MAPPING_INVALID';
    END IF;
    RETURN v_account.id;
END;
$$;

CREATE FUNCTION private.post_financial_event_core(
    p_company_id UUID,p_event_id UUID,p_expected_event_version BIGINT,
    p_actor_id UUID
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_event public.financial_events%ROWTYPE;
    v_rule_set public.posting_rule_sets%ROWTYPE;
    v_rule_set_id UUID;
    v_period public.accounting_periods%ROWTYPE;
    v_document public.opening_stock_documents%ROWTYPE;
    v_journal public.finance_journals%ROWTYPE;
    v_line RECORD;
    v_resolved_line JSONB;
    v_resolved_lines JSONB := '[]'::JSONB;
    v_amount NUMERIC(20,4);
    v_account_id UUID;
    v_debit NUMERIC(20,4) := 0;
    v_credit NUMERIC(20,4) := 0;
    v_rule_count BIGINT;
    v_journal_type TEXT := 'AUTOMATIC';
    v_accounting_date DATE;
    v_now TIMESTAMPTZ := clock_timestamp();
BEGIN
    IF p_actor_id IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    SELECT * INTO v_event
    FROM public.financial_events event
    WHERE event.company_id = p_company_id AND event.id = p_event_id
    FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'FINANCIAL_EVENT_NOT_FOUND'; END IF;
    IF p_expected_event_version IS NULL
       OR p_expected_event_version <> v_event.event_version THEN
        RAISE EXCEPTION 'EVENT_VERSION_CONFLICT';
    END IF;

    IF v_event.status::TEXT = 'POSTED' THEN
        SELECT * INTO v_journal
        FROM public.finance_journals journal
        WHERE journal.company_id = p_company_id
          AND journal.financial_event_id = v_event.id
          AND journal.status = 'POSTED';
        IF NOT FOUND THEN
            RAISE EXCEPTION 'POSTED_EVENT_JOURNAL_MISSING';
        END IF;
        RETURN jsonb_build_object(
            'financialEventId',v_event.id,'journalId',v_journal.id,
            'journalNo',v_journal.journal_no,'status','POSTED',
            'idempotentReplay',TRUE
        );
    END IF;
    IF v_event.status::TEXT <> 'HOLD' THEN
        RAISE EXCEPTION 'FINANCIAL_EVENT_NOT_HOLD';
    END IF;
    IF v_event.system_event_key <> 'STOCK_OPENING'
       OR v_event.event_type::TEXT <> 'STOCK_OPENING'
       OR v_event.source_table <> 'opening_stock_documents' THEN
        RAISE EXCEPTION 'UNSUPPORTED_FINANCIAL_EVENT_CONTRACT';
    END IF;

    SELECT * INTO v_document
    FROM public.opening_stock_documents document
    WHERE document.company_id = p_company_id
      AND document.id = v_event.source_id
      AND document.financial_event_id = v_event.id
      AND document.status = 'POSTED'
    FOR SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION 'FINANCIAL_EVENT_SOURCE_NOT_FOUND'; END IF;

    SELECT count(*),(
        array_agg(rule_set.id ORDER BY rule_set.rule_set_version DESC)
    )[1]
    INTO v_rule_count,v_rule_set_id
    FROM public.posting_rule_sets rule_set
    WHERE rule_set.company_id = p_company_id
      AND rule_set.transaction_category_id = v_event.transaction_category_id
      AND rule_set.system_key = v_event.system_event_key
      AND rule_set.status = 'APPROVED'
      AND rule_set.effective_from <= v_event.event_date
      AND (
          rule_set.effective_to IS NULL
          OR rule_set.effective_to > v_event.event_date
      );
    IF v_rule_count <> 1 THEN
        RAISE EXCEPTION 'POSTING_RULE_MISSING_OR_AMBIGUOUS';
    END IF;
    SELECT * INTO v_rule_set
    FROM public.posting_rule_sets rule_set
    WHERE rule_set.company_id = p_company_id AND rule_set.id = v_rule_set_id;

    SELECT * INTO v_period
    FROM public.accounting_periods period
    WHERE period.company_id = p_company_id
      AND v_event.event_date::DATE BETWEEN period.start_date AND period.end_date
      AND period.status IN ('OPEN','REOPENED')
    ORDER BY period.start_date
    LIMIT 1
    FOR SHARE;
    IF NOT FOUND THEN
        SELECT * INTO v_period
        FROM public.accounting_periods period
        WHERE period.company_id = p_company_id
          AND period.start_date > v_event.event_date::DATE
          AND period.status IN ('OPEN','REOPENED')
        ORDER BY period.start_date
        LIMIT 1
        FOR SHARE;
        IF NOT FOUND THEN RAISE EXCEPTION 'POSTABLE_ACCOUNTING_PERIOD_NOT_FOUND'; END IF;
        v_journal_type := 'PRIOR_PERIOD_ADJUSTMENT';
        v_accounting_date := v_period.start_date;
    ELSE
        v_accounting_date := v_event.event_date::DATE;
    END IF;

    FOR v_line IN
        SELECT line.*
        FROM public.posting_rule_lines line
        WHERE line.company_id = p_company_id
          AND line.rule_set_id = v_rule_set.id
        ORDER BY line.line_no
    LOOP
        v_amount := private.resolve_financial_event_amount(
            v_event,v_line.amount_expression_key
        );
        v_account_id := private.resolve_financial_event_account(
            v_event,v_line.account_function_key
        );
        IF v_line.entry_side = 'DEBIT' THEN
            v_debit := v_debit + v_amount;
        ELSE
            v_credit := v_credit + v_amount;
        END IF;
        v_resolved_line := jsonb_build_object(
            'lineNo',v_line.line_no,'accountId',v_account_id,
            'accountFunctionKey',v_line.account_function_key,
            'entrySide',v_line.entry_side,'amount',v_amount
        );
        v_resolved_lines := v_resolved_lines || jsonb_build_array(v_resolved_line);
    END LOOP;
    IF jsonb_array_length(v_resolved_lines) < 2
       OR v_debit <= 0 OR round(v_debit,4) <> round(v_credit,4) THEN
        RAISE EXCEPTION 'JOURNAL_UNBALANCED';
    END IF;

    INSERT INTO public.finance_journals(
        company_id,journal_no,journal_type,accounting_period_id,
        accounting_date,original_event_date,source_type,source_id,
        source_version,financial_event_id,idempotency_key,system_event_key,
        transaction_category_id,transaction_rule_version,store_id,
        warehouse_id,description,status,created_by
    ) VALUES (
        p_company_id,
        'G6-' || replace(v_event.id::TEXT,'-',''),v_journal_type,v_period.id,
        v_accounting_date,v_event.event_date::DATE,v_event.source_table,
        v_event.source_id,v_event.event_version,v_event.id,
        'G6_EVENT|' || p_company_id::TEXT || '|' || v_event.id::TEXT || '|'
            || v_event.event_version::TEXT,
        v_event.system_event_key,v_event.transaction_category_id,
        v_rule_set.rule_set_version,v_event.store_id,v_document.warehouse_id,
        'Automatic posting: ' || v_event.event_code,'DRAFT',p_actor_id
    ) RETURNING * INTO v_journal;

    FOR v_resolved_line IN
        SELECT value FROM jsonb_array_elements(v_resolved_lines)
    LOOP
        INSERT INTO public.finance_journal_lines(
            company_id,journal_id,line_no,account_id,debit,credit,
            store_id,warehouse_id,description
        ) VALUES (
            p_company_id,v_journal.id,
            (v_resolved_line->>'lineNo')::INTEGER,
            (v_resolved_line->>'accountId')::UUID,
            CASE WHEN v_resolved_line->>'entrySide' = 'DEBIT'
                 THEN (v_resolved_line->>'amount')::NUMERIC ELSE 0 END,
            CASE WHEN v_resolved_line->>'entrySide' = 'CREDIT'
                 THEN (v_resolved_line->>'amount')::NUMERIC ELSE 0 END,
            v_event.store_id,v_document.warehouse_id,
            v_resolved_line->>'accountFunctionKey'
        );
    END LOOP;

    UPDATE public.finance_journals SET
        status = 'POSTED',posted_by = p_actor_id,posted_at = v_now
    WHERE company_id = p_company_id AND id = v_journal.id
    RETURNING * INTO v_journal;

    UPDATE public.financial_events SET
        status = 'POSTED'::public.event_status,
        processed_at = v_now,error_message = NULL,
        transaction_rule_version = v_rule_set.rule_set_version
    WHERE company_id = p_company_id AND id = v_event.id;

    RETURN jsonb_build_object(
        'financialEventId',v_event.id,'journalId',v_journal.id,
        'journalNo',v_journal.journal_no,'status','POSTED',
        'journalType',v_journal.journal_type,
        'accountingDate',v_journal.accounting_date,
        'totalDebit',v_journal.total_debit,
        'totalCredit',v_journal.total_credit,
        'idempotentReplay',FALSE
    );
END;
$$;

CREATE FUNCTION public.post_financial_event_by_id(
    p_event_id UUID,p_expected_event_version BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_actor UUID := auth.uid();
    v_company UUID := public.private_active_company_id();
    v_event public.financial_events%ROWTYPE;
    v_reason TEXT;
    v_error TEXT;
    v_exception_id UUID;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF NOT public.private_user_has_any_company_or_store_role(
        v_company,
        ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE','ACCOUNTING']::TEXT[]
    ) THEN RAISE EXCEPTION 'FINANCE_POSTER_REQUIRED'; END IF;
    SELECT * INTO v_event
    FROM public.financial_events event
    WHERE event.company_id = v_company AND event.id = p_event_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'FINANCIAL_EVENT_NOT_FOUND'; END IF;

    BEGIN
        RETURN private.post_financial_event_core(
            v_company,p_event_id,p_expected_event_version,v_actor
        );
    EXCEPTION WHEN OTHERS THEN
        v_error := SQLERRM;
        v_reason := CASE
            WHEN v_error LIKE '%PERIOD%' THEN 'LOCKED_PERIOD'
            WHEN v_error LIKE '%UNBALANCED%' OR v_error LIKE '%AMOUNT%'
                THEN 'UNBALANCED_JOURNAL'
            WHEN v_error LIKE '%VERSION%' THEN 'RULE_VERSION_CONFLICT'
            WHEN v_error LIKE '%ACCOUNT%INVALID%'
                THEN 'INACTIVE_ACCOUNT'
            WHEN v_error LIKE '%SOURCE%' OR v_error LIKE '%UNSUPPORTED%'
                THEN 'INVALID_DIMENSION'
            ELSE 'MISSING_REQUIRED_FUNCTION'
        END;
        SELECT exception_state.id INTO v_exception_id
        FROM public.finance_posting_exceptions exception_state
        WHERE exception_state.company_id = v_company
          AND exception_state.financial_event_id = v_event.id
          AND exception_state.reason_code = v_reason
          AND exception_state.resolver_level = 'SINGLE_EVENT'
          AND exception_state.status <> 'RESOLVED'
        ORDER BY exception_state.created_at DESC,exception_state.id
        LIMIT 1
        FOR UPDATE;
        IF FOUND THEN
            UPDATE public.finance_posting_exceptions SET
                status = 'POSTING_ERROR',retry_count = retry_count + 1,
                last_error = left(v_error,1000),updated_at = clock_timestamp()
            WHERE company_id = v_company AND id = v_exception_id;
        ELSE
            INSERT INTO public.finance_posting_exceptions(
                company_id,financial_event_id,source_table,source_id,system_key,
                transaction_category_id,reason_code,resolver_level,status,
                retry_count,last_error
            ) VALUES (
                v_company,v_event.id,v_event.source_table,v_event.source_id,
                v_event.system_event_key,v_event.transaction_category_id,
                v_reason,'SINGLE_EVENT','POSTING_ERROR',1,left(v_error,1000)
            ) RETURNING id INTO v_exception_id;
        END IF;
        RETURN jsonb_build_object(
            'financialEventId',v_event.id,'status','HOLD',
            'errorCode',v_error,'postingExceptionId',v_exception_id
        );
    END;
END;
$$;

REVOKE ALL ON FUNCTION
    private.provision_g6_posting_configuration(UUID,UUID),
    private.trg_g6_provision_posting_configuration(),
    private.resolve_financial_event_amount(public.financial_events,TEXT),
    private.resolve_financial_event_account(public.financial_events,TEXT),
    private.post_financial_event_core(UUID,UUID,BIGINT,UUID)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
    private.provision_g6_posting_configuration(UUID,UUID),
    private.trg_g6_provision_posting_configuration(),
    private.resolve_financial_event_amount(public.financial_events,TEXT),
    private.resolve_financial_event_account(public.financial_events,TEXT),
    private.post_financial_event_core(UUID,UUID,BIGINT,UUID)
TO service_role;

REVOKE ALL ON FUNCTION public.post_financial_event_by_id(UUID,BIGINT)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.post_financial_event_by_id(UUID,BIGINT)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES (
    '20260810200000',
    'g6_phase4_atomic_single_event_posting',
    'Atomic exact-idempotent STOCK_OPENING single-event posting with approved expression/account rules, source/period snapshots, balanced canonical journal, and exception capture; existing HOLD queue untouched'
);

COMMIT;
