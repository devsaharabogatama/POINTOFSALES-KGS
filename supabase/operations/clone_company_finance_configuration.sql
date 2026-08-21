-- Controlled Company Finance configuration clone.
--
-- Copies configuration only:
--   * chart_of_accounts, including hierarchy
--   * transaction_categories
--   * current ACTIVE transaction_account_rules
--   * current ACTIVE company_account_function_fallbacks
--   * current APPROVED posting_rule_sets and posting_rule_lines
--
-- Never copies operational balances, Journal, Financial Event, Stock, Customer,
-- Supplier, Product, user access, Company identity, feature entitlement, or
-- Store/Warehouse/Terminal policy.
--
-- HOW TO USE
-- 1. Fill the five values in kgs_finance_clone_config below.
-- 2. Keep execute_clone = FALSE and run the whole file for PREVIEW.
-- 3. Review every row in the final result.
-- 4. Change execute_clone = TRUE and confirmation exactly to:
--      CLONE_FINANCE_CONFIGURATION
-- 5. Run the whole file once more. The DO block is one atomic transaction.

DROP TABLE IF EXISTS pg_temp.kgs_finance_clone_config;
CREATE TEMP TABLE kgs_finance_clone_config (
    source_company_id UUID,
    source_company_name TEXT,
    target_company_id UUID,
    target_company_name TEXT,
    actor_id UUID,
    execute_clone BOOLEAN NOT NULL,
    confirmation TEXT
);

INSERT INTO kgs_finance_clone_config(
    source_company_id,source_company_name,target_company_id,target_company_name,
    actor_id,execute_clone,confirmation
) VALUES (
    NULL,             -- UUID Company sumber: KGS
    'KGS',            -- nama Company sumber persis seperti di database
    NULL,             -- UUID Company tujuan: KMS
    'KMS',            -- nama Company tujuan persis seperti di database
    NULL,             -- optional; NULL = linked Super Admin pertama
    FALSE,            -- FALSE = PREVIEW, TRUE = APPLY
    NULL              -- APPLY wajib: CLONE_FINANCE_CONFIGURATION
);

DROP TABLE IF EXISTS pg_temp.kgs_finance_clone_result;
CREATE TEMP TABLE kgs_finance_clone_result (
    check_name TEXT NOT NULL,
    status TEXT NOT NULL,
    details JSONB NOT NULL
);

DROP TABLE IF EXISTS pg_temp.kgs_finance_clone_account_map;
CREATE TEMP TABLE kgs_finance_clone_account_map (
    source_id UUID PRIMARY KEY,
    target_id UUID NOT NULL UNIQUE,
    match_mode TEXT NOT NULL CHECK(match_mode IN ('CODE','SYSTEM_FUNCTION','NEW'))
);

DROP TABLE IF EXISTS pg_temp.kgs_finance_clone_category_map;
CREATE TEMP TABLE kgs_finance_clone_category_map (
    source_id UUID PRIMARY KEY,
    target_id UUID NOT NULL UNIQUE
);

DROP TABLE IF EXISTS pg_temp.kgs_finance_clone_rule_set_map;
CREATE TEMP TABLE kgs_finance_clone_rule_set_map (
    source_id UUID PRIMARY KEY,
    target_id UUID NOT NULL UNIQUE
);

DO $operation$
DECLARE
    v_config pg_temp.kgs_finance_clone_config%ROWTYPE;
    v_source public.companies%ROWTYPE;
    v_target public.companies%ROWTYPE;
    v_actor UUID;
    v_now TIMESTAMPTZ := clock_timestamp();
    v_row RECORD;
    v_target_id UUID;
    v_target_before JSONB;
    v_target_after JSONB;
    v_target_rule_set UUID;
    v_target_rule_version BIGINT;
    v_count BIGINT;
    v_match_mode TEXT;
BEGIN
    SELECT * INTO STRICT v_config FROM pg_temp.kgs_finance_clone_config;

    IF v_config.source_company_id IS NULL OR v_config.target_company_id IS NULL THEN
        RAISE EXCEPTION
            'CONFIG_REQUIRED: fill source_company_id and target_company_id';
    END IF;
    IF v_config.source_company_id = v_config.target_company_id THEN
        RAISE EXCEPTION 'SOURCE_AND_TARGET_COMPANY_MUST_DIFFER';
    END IF;

    SELECT * INTO v_source
    FROM public.companies company
    WHERE company.id = v_config.source_company_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'SOURCE_COMPANY_NOT_FOUND'; END IF;

    SELECT * INTO v_target
    FROM public.companies company
    WHERE company.id = v_config.target_company_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'TARGET_COMPANY_NOT_FOUND'; END IF;

    IF btrim(v_source.company_name) IS DISTINCT FROM
       btrim(v_config.source_company_name) THEN
        RAISE EXCEPTION 'SOURCE_COMPANY_NAME_MISMATCH: database=%',
            v_source.company_name;
    END IF;
    IF btrim(v_target.company_name) IS DISTINCT FROM
       btrim(v_config.target_company_name) THEN
        RAISE EXCEPTION 'TARGET_COMPANY_NAME_MISMATCH: database=%',
            v_target.company_name;
    END IF;
    IF v_target.status <> 'ACTIVE' THEN
        RAISE EXCEPTION 'TARGET_COMPANY_MUST_BE_ACTIVE';
    END IF;

    v_actor := v_config.actor_id;
    IF v_actor IS NULL THEN
        SELECT profile.id INTO v_actor
        FROM public.profiles profile
        WHERE public.private_is_super_admin(profile.id)
        ORDER BY profile.id
        LIMIT 1;
    END IF;
    IF v_actor IS NULL OR NOT EXISTS (
        SELECT 1 FROM public.profiles profile WHERE profile.id = v_actor
    ) THEN
        RAISE EXCEPTION 'VALID_AUDIT_ACTOR_REQUIRED';
    END IF;
    IF NOT public.private_is_super_admin(v_actor) AND NOT (
        EXISTS (
            SELECT 1 FROM public.company_memberships membership
            WHERE membership.company_id = v_source.id
              AND membership.user_id = v_actor
              AND membership.status = 'ACTIVE'
              AND membership.role_code IN ('COMPANY_OWNER','COMPANY_ADMIN')
        ) AND EXISTS (
            SELECT 1 FROM public.company_memberships membership
            WHERE membership.company_id = v_target.id
              AND membership.user_id = v_actor
              AND membership.status = 'ACTIVE'
              AND membership.role_code IN ('COMPANY_OWNER','COMPANY_ADMIN')
        )
    ) THEN
        RAISE EXCEPTION 'CLONE_ACTOR_MUST_CONTROL_BOTH_COMPANIES';
    END IF;

    PERFORM pg_advisory_xact_lock(hashtextextended(
        'CLONE_FINANCE_CONFIG|' || v_source.id::TEXT,0
    ));
    PERFORM pg_advisory_xact_lock(hashtextextended(
        'CLONE_FINANCE_CONFIG|' || v_target.id::TEXT,0
    ));

    SELECT
        (SELECT count(*) FROM public.financial_events event
         WHERE event.company_id = v_target.id)
      + (SELECT count(*) FROM public.finance_journals journal
         WHERE journal.company_id = v_target.id)
      + (SELECT count(*) FROM public.journal_entries legacy
         WHERE legacy.company_id = v_target.id)
    INTO v_count;
    INSERT INTO pg_temp.kgs_finance_clone_result VALUES (
        'target_financial_history',
        CASE WHEN v_count = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'rowCount',v_count,
            'financialEvents',(SELECT count(*) FROM public.financial_events
                               WHERE company_id = v_target.id),
            'canonicalJournals',(SELECT count(*) FROM public.finance_journals
                                WHERE company_id = v_target.id),
            'legacyJournalRows',(SELECT count(*) FROM public.journal_entries
                                WHERE company_id = v_target.id)
        )
    );
    IF v_count <> 0 AND v_config.execute_clone THEN
        RAISE EXCEPTION
            'TARGET_FINANCIAL_HISTORY_NOT_EMPTY: % rows; clone refused',v_count;
    END IF;

    SELECT
        (SELECT count(*) FROM public.transaction_account_rules rule
         WHERE rule.company_id = v_target.id)
      + (SELECT count(*) FROM public.company_account_function_fallbacks fallback
         WHERE fallback.company_id = v_target.id)
      + (SELECT count(*) FROM public.posting_rule_sets rule_set
         WHERE rule_set.company_id = v_target.id)
    INTO v_count;
    INSERT INTO pg_temp.kgs_finance_clone_result VALUES (
        'target_mapping_state',
        CASE WHEN v_count = 0 THEN 'PASS' ELSE 'REPLACE' END,
        jsonb_build_object(
            'existingMappingRows',v_count,
            'transactionRules',(
                SELECT count(*) FROM public.transaction_account_rules
                WHERE company_id = v_target.id),
            'accountFunctionFallbacks',(
                SELECT count(*) FROM public.company_account_function_fallbacks
                WHERE company_id = v_target.id),
            'postingRuleSets',(
                SELECT count(*) FROM public.posting_rule_sets
                WHERE company_id = v_target.id)
        )
    );

    SELECT count(*) INTO v_count
    FROM public.chart_of_accounts source_account
    JOIN public.chart_of_accounts target_account
      ON target_account.company_id = v_target.id
     AND lower(regexp_replace(btrim(target_account.account_name),'\s+',' ','g')) =
         lower(regexp_replace(btrim(source_account.account_name),'\s+',' ','g'))
     AND upper(regexp_replace(btrim(target_account.account_code),'\s+',' ','g')) <>
         upper(regexp_replace(btrim(source_account.account_code),'\s+',' ','g'))
    WHERE source_account.company_id = v_source.id;
    INSERT INTO pg_temp.kgs_finance_clone_result VALUES (
        'target_coa_name_conflict',
        CASE WHEN v_count = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('conflictRows',v_count)
    );
    IF v_count <> 0 AND v_config.execute_clone THEN
        RAISE EXCEPTION 'TARGET_COA_NAME_CONFLICT: % rows',v_count;
    END IF;

    SELECT count(*) INTO v_count
    FROM public.transaction_categories source_category
    JOIN public.transaction_categories target_category
      ON target_category.company_id = v_target.id
     AND lower(regexp_replace(btrim(target_category.category_name),'\s+',' ','g')) =
         lower(regexp_replace(btrim(source_category.category_name),'\s+',' ','g'))
     AND upper(regexp_replace(btrim(target_category.category_code),'\s+',' ','g')) <>
         upper(regexp_replace(btrim(source_category.category_code),'\s+',' ','g'))
    WHERE source_category.company_id = v_source.id;
    INSERT INTO pg_temp.kgs_finance_clone_result VALUES (
        'target_transaction_category_name_conflict',
        CASE WHEN v_count = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('conflictRows',v_count)
    );
    IF v_count <> 0 AND v_config.execute_clone THEN
        RAISE EXCEPTION 'TARGET_TRANSACTION_CATEGORY_NAME_CONFLICT: % rows',v_count;
    END IF;

    SELECT count(*) INTO v_count
    FROM public.chart_of_accounts source_account
    JOIN public.chart_of_accounts target_account
      ON target_account.company_id = v_target.id
     AND target_account.system_function_key = source_account.system_function_key
     AND target_account.is_system_account
     AND upper(regexp_replace(btrim(target_account.account_code),'\s+',' ','g')) <>
         upper(regexp_replace(btrim(source_account.account_code),'\s+',' ','g'))
    WHERE source_account.company_id = v_source.id
      AND source_account.is_system_account
      AND source_account.system_function_key IS NOT NULL;
    INSERT INTO pg_temp.kgs_finance_clone_result VALUES (
        'target_system_function_conflict',
        CASE WHEN v_count = 0 THEN 'PASS' ELSE 'REMAP' END,
        jsonb_build_object(
            'conflictRows',v_count,
            'resolution','Preserve target system account identity and remap by function'
        )
    );

    WITH candidate_map AS (
        SELECT
            source_account.id AS source_id,
            CASE
                WHEN source_account.is_system_account
                 AND source_account.system_function_key IS NOT NULL
                    THEN COALESCE(system_match.id,code_match.id)
                ELSE code_match.id
            END AS target_id
        FROM public.chart_of_accounts source_account
        LEFT JOIN LATERAL (
            SELECT target_account.id
            FROM public.chart_of_accounts target_account
            WHERE target_account.company_id = v_target.id
              AND upper(regexp_replace(
                    btrim(target_account.account_code),'\s+',' ','g')) =
                  upper(regexp_replace(
                    btrim(source_account.account_code),'\s+',' ','g'))
            LIMIT 1
        ) code_match ON TRUE
        LEFT JOIN LATERAL (
            SELECT target_account.id
            FROM public.chart_of_accounts target_account
            WHERE target_account.company_id = v_target.id
              AND target_account.is_system_account
              AND target_account.system_function_key =
                  source_account.system_function_key
            LIMIT 1
        ) system_match ON TRUE
        WHERE source_account.company_id = v_source.id
    ), collisions AS (
        SELECT target_id
        FROM candidate_map
        WHERE target_id IS NOT NULL
        GROUP BY target_id
        HAVING count(*) > 1
    )
    SELECT count(*) INTO v_count FROM collisions;
    INSERT INTO pg_temp.kgs_finance_clone_result VALUES (
        'target_coa_mapping_collision',
        CASE WHEN v_count = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('collisionTargets',v_count)
    );
    IF v_count <> 0 AND v_config.execute_clone THEN
        RAISE EXCEPTION 'TARGET_COA_MAPPING_COLLISION: % targets',v_count;
    END IF;

    INSERT INTO pg_temp.kgs_finance_clone_result
    SELECT 'source_configuration_inventory','INFO',jsonb_build_object(
        'accounts',(SELECT count(*) FROM public.chart_of_accounts
                    WHERE company_id = v_source.id),
        'categories',(SELECT count(*) FROM public.transaction_categories
                      WHERE company_id = v_source.id),
        'activeTransactionRules',(
            SELECT count(*) FROM public.transaction_account_rules
            WHERE company_id = v_source.id AND status = 'ACTIVE'
              AND effective_from <= v_now
              AND (effective_to IS NULL OR effective_to > v_now)),
        'activeFallbacks',(
            SELECT count(*) FROM public.company_account_function_fallbacks
            WHERE company_id = v_source.id AND status = 'ACTIVE'
              AND effective_from <= v_now
              AND (effective_to IS NULL OR effective_to > v_now)),
        'approvedPostingRuleSets',(
            SELECT count(*) FROM public.posting_rule_sets
            WHERE company_id = v_source.id AND status = 'APPROVED'
              AND effective_from <= v_now
              AND (effective_to IS NULL OR effective_to > v_now))
    );

    IF NOT v_config.execute_clone THEN
        INSERT INTO pg_temp.kgs_finance_clone_result VALUES (
            'operation_mode','PREVIEW',jsonb_build_object(
                'sourceCompany',v_source.company_name,
                'targetCompany',v_target.company_name,
                'actorId',v_actor,
                'writesExecuted',FALSE
            )
        );
        RETURN;
    END IF;
    IF v_config.confirmation IS DISTINCT FROM 'CLONE_FINANCE_CONFIGURATION' THEN
        RAISE EXCEPTION
            'CONFIRMATION_REQUIRED: CLONE_FINANCE_CONFIGURATION';
    END IF;

    -- A new Company can already contain provisioned baseline mappings. Because
    -- target Finance history was proven empty above, close only the effective
    -- baseline versions before cloning KGS as newer audited versions.
    FOR v_row IN
        SELECT rule.* FROM public.transaction_account_rules rule
        WHERE rule.company_id = v_target.id AND rule.status = 'ACTIVE'
        FOR UPDATE
    LOOP
        v_target_before := to_jsonb(v_row);
        UPDATE public.transaction_account_rules SET
            status = 'INACTIVE',
            effective_to = CASE
                WHEN v_row.effective_to IS NULL THEN
                    greatest(v_now,v_row.effective_from + interval '1 microsecond')
                ELSE v_row.effective_to
            END,
            updated_by = v_actor
        WHERE company_id = v_target.id AND id = v_row.id;
        SELECT to_jsonb(rule) INTO v_target_after
        FROM public.transaction_account_rules rule WHERE rule.id = v_row.id;
        INSERT INTO public.finance_master_audit(
            company_id,entity_type,entity_id,action,actor_id,
            before_state,after_state
        ) VALUES (
            v_target.id,'RULE',v_row.id,'UPDATE',v_actor,
            v_target_before,v_target_after
        );
    END LOOP;

    FOR v_row IN
        SELECT fallback.*
        FROM public.company_account_function_fallbacks fallback
        WHERE fallback.company_id = v_target.id AND fallback.status = 'ACTIVE'
        FOR UPDATE
    LOOP
        v_target_before := to_jsonb(v_row);
        UPDATE public.company_account_function_fallbacks SET
            status = 'INACTIVE',
            effective_to = CASE
                WHEN v_row.effective_to IS NULL THEN
                    greatest(v_now,v_row.effective_from + interval '1 microsecond')
                ELSE v_row.effective_to
            END,
            updated_by = v_actor
        WHERE company_id = v_target.id AND id = v_row.id;
        SELECT to_jsonb(fallback) INTO v_target_after
        FROM public.company_account_function_fallbacks fallback
        WHERE fallback.id = v_row.id;
        INSERT INTO public.finance_master_audit(
            company_id,entity_type,entity_id,action,actor_id,
            before_state,after_state
        ) VALUES (
            v_target.id,'FALLBACK',v_row.id,'UPDATE',v_actor,
            v_target_before,v_target_after
        );
    END LOOP;

    FOR v_row IN
        SELECT rule_set.* FROM public.posting_rule_sets rule_set
        WHERE rule_set.company_id = v_target.id
          AND rule_set.status = 'APPROVED'
          AND (rule_set.effective_to IS NULL OR rule_set.effective_to > v_now)
        FOR UPDATE
    LOOP
        v_target_before := to_jsonb(v_row);
        UPDATE public.posting_rule_sets SET
            status = 'RETIRED',
            effective_to = greatest(
                v_now,v_row.effective_from + interval '1 microsecond'
            ),
            updated_by = v_actor
        WHERE company_id = v_target.id AND id = v_row.id;
        SELECT to_jsonb(rule_set) INTO v_target_after
        FROM public.posting_rule_sets rule_set WHERE rule_set.id = v_row.id;
        INSERT INTO public.posting_rule_set_audit(
            company_id,rule_set_id,action,actor_id,before_state,after_state,reason
        ) VALUES (
            v_target.id,v_row.id,'UPDATE',v_actor,
            v_target_before,v_target_after,
            'Replaced by controlled Finance configuration clone from ' ||
                v_source.company_name
        );
    END LOOP;

    -- Accounts are matched by normalized account code. New UUIDs are generated
    -- for KMS; source UUIDs never cross the tenant boundary.
    FOR v_row IN
        SELECT account.*
        FROM public.chart_of_accounts account
        WHERE account.company_id = v_source.id
        ORDER BY account.created_at,account.id
    LOOP
        v_target_id := NULL;
        v_match_mode := NULL;
        IF v_row.is_system_account
           AND v_row.system_function_key IS NOT NULL THEN
            SELECT target_account.id,to_jsonb(target_account)
            INTO v_target_id,v_target_before
            FROM public.chart_of_accounts target_account
            WHERE target_account.company_id = v_target.id
              AND target_account.is_system_account
              AND target_account.system_function_key =
                  v_row.system_function_key;
            IF v_target_id IS NOT NULL THEN v_match_mode := 'SYSTEM_FUNCTION'; END IF;
        END IF;

        IF v_target_id IS NULL THEN
            SELECT target_account.id,to_jsonb(target_account)
            INTO v_target_id,v_target_before
            FROM public.chart_of_accounts target_account
            WHERE target_account.company_id = v_target.id
              AND upper(regexp_replace(
                    btrim(target_account.account_code),'\s+',' ','g')) =
                  upper(regexp_replace(
                    btrim(v_row.account_code),'\s+',' ','g'));
            IF v_target_id IS NOT NULL THEN v_match_mode := 'CODE'; END IF;
        END IF;

        IF v_target_id IS NULL THEN
            INSERT INTO public.chart_of_accounts(
                company_id,account_code,account_name,account_type,normal_balance,
                parent_account_id,system_function_key,is_system_account,
                is_postable,allow_manual_posting,allow_reconciliation,is_active,
                created_by,updated_by
            ) VALUES (
                v_target.id,v_row.account_code,v_row.account_name,
                v_row.account_type,v_row.normal_balance,NULL,
                v_row.system_function_key,v_row.is_system_account,
                v_row.is_postable,v_row.allow_manual_posting,
                v_row.allow_reconciliation,v_row.is_active,v_actor,v_actor
            ) RETURNING id INTO v_target_id;
            v_match_mode := 'NEW';
            SELECT to_jsonb(account) INTO v_target_after
            FROM public.chart_of_accounts account
            WHERE account.id = v_target_id;
            INSERT INTO public.finance_master_audit(
                company_id,entity_type,entity_id,action,actor_id,after_state
            ) VALUES (
                v_target.id,'ACCOUNT',v_target_id,'CREATE',v_actor,v_target_after
            );
        ELSE
            UPDATE public.chart_of_accounts SET
                account_name = v_row.account_name,
                account_type = v_row.account_type,
                normal_balance = v_row.normal_balance,
                system_function_key = v_row.system_function_key,
                is_postable = v_row.is_postable,
                allow_manual_posting = v_row.allow_manual_posting,
                allow_reconciliation = v_row.allow_reconciliation,
                is_active = v_row.is_active,
                updated_by = v_actor
            WHERE company_id = v_target.id AND id = v_target_id;
            SELECT to_jsonb(account) INTO v_target_after
            FROM public.chart_of_accounts account
            WHERE account.id = v_target_id;
            IF v_target_after IS DISTINCT FROM v_target_before THEN
                INSERT INTO public.finance_master_audit(
                    company_id,entity_type,entity_id,action,actor_id,
                    before_state,after_state
                ) VALUES (
                    v_target.id,'ACCOUNT',v_target_id,'UPDATE',v_actor,
                    v_target_before,v_target_after
                );
            END IF;
        END IF;
        INSERT INTO pg_temp.kgs_finance_clone_account_map(
            source_id,target_id,match_mode
        ) VALUES(v_row.id,v_target_id,v_match_mode);
    END LOOP;

    -- Apply hierarchy only after every target account exists.
    FOR v_row IN
        SELECT account.id,account.parent_account_id
        FROM public.chart_of_accounts account
        WHERE account.company_id = v_source.id
    LOOP
        SELECT account_map.target_id,parent_map.target_id
        INTO v_target_id,v_target_rule_set
        FROM pg_temp.kgs_finance_clone_account_map account_map
        LEFT JOIN pg_temp.kgs_finance_clone_account_map parent_map
          ON parent_map.source_id = v_row.parent_account_id
        WHERE account_map.source_id = v_row.id;
        SELECT to_jsonb(target_account) INTO v_target_before
        FROM public.chart_of_accounts target_account
        WHERE target_account.company_id = v_target.id
          AND target_account.id = v_target_id;
        IF (v_target_before->>'parent_account_id')::UUID
           IS DISTINCT FROM v_target_rule_set THEN
            UPDATE public.chart_of_accounts SET
                parent_account_id = v_target_rule_set,
                updated_by = v_actor
            WHERE company_id = v_target.id AND id = v_target_id;
            SELECT to_jsonb(target_account) INTO v_target_after
            FROM public.chart_of_accounts target_account
            WHERE target_account.company_id = v_target.id
              AND target_account.id = v_target_id;
            INSERT INTO public.finance_master_audit(
                company_id,entity_type,entity_id,action,actor_id,
                before_state,after_state
            ) VALUES (
                v_target.id,'ACCOUNT',v_target_id,'UPDATE',v_actor,
                v_target_before,v_target_after
            );
        END IF;
    END LOOP;

    FOR v_row IN
        SELECT category.*
        FROM public.transaction_categories category
        WHERE category.company_id = v_source.id
        ORDER BY category.created_at,category.id
    LOOP
        v_target_id := NULL;
        v_target_before := NULL;
        SELECT target_category.id,to_jsonb(target_category)
        INTO v_target_id,v_target_before
        FROM public.transaction_categories target_category
        WHERE target_category.company_id = v_target.id
          AND upper(regexp_replace(btrim(target_category.category_code),'\s+',' ','g')) =
              upper(regexp_replace(btrim(v_row.category_code),'\s+',' ','g'));

        IF v_target_id IS NULL THEN
            INSERT INTO public.transaction_categories(
                company_id,category_code,category_name,system_key,description,
                is_active,created_by,updated_by
            ) VALUES (
                v_target.id,v_row.category_code,v_row.category_name,
                v_row.system_key,v_row.description,v_row.is_active,v_actor,v_actor
            ) RETURNING id INTO v_target_id;
            SELECT to_jsonb(category) INTO v_target_after
            FROM public.transaction_categories category
            WHERE category.id = v_target_id;
            INSERT INTO public.finance_master_audit(
                company_id,entity_type,entity_id,action,actor_id,after_state
            ) VALUES (
                v_target.id,'CATEGORY',v_target_id,'CREATE',v_actor,v_target_after
            );
        ELSE
            UPDATE public.transaction_categories SET
                category_name = v_row.category_name,
                system_key = v_row.system_key,
                description = v_row.description,
                is_active = v_row.is_active,
                updated_by = v_actor
            WHERE company_id = v_target.id AND id = v_target_id;
            SELECT to_jsonb(category) INTO v_target_after
            FROM public.transaction_categories category
            WHERE category.id = v_target_id;
            IF v_target_after IS DISTINCT FROM v_target_before THEN
                INSERT INTO public.finance_master_audit(
                    company_id,entity_type,entity_id,action,actor_id,
                    before_state,after_state
                ) VALUES (
                    v_target.id,'CATEGORY',v_target_id,'UPDATE',v_actor,
                    v_target_before,v_target_after
                );
            END IF;
        END IF;
        INSERT INTO pg_temp.kgs_finance_clone_category_map(source_id,target_id)
        VALUES(v_row.id,v_target_id);
    END LOOP;

    FOR v_row IN
        SELECT rule.*,category_map.target_id AS target_category_id,
               account_map.target_id AS target_account_id
        FROM public.transaction_account_rules rule
        JOIN pg_temp.kgs_finance_clone_category_map category_map
          ON category_map.source_id = rule.transaction_category_id
        JOIN pg_temp.kgs_finance_clone_account_map account_map
          ON account_map.source_id = rule.account_id
        WHERE rule.company_id = v_source.id
          AND rule.status = 'ACTIVE'
          AND rule.effective_from <= v_now
          AND (rule.effective_to IS NULL OR rule.effective_to > v_now)
        ORDER BY rule.transaction_category_id,rule.account_function_key
    LOOP
        SELECT COALESCE(max(existing.rule_version),0) + 1
        INTO v_target_rule_version
        FROM public.transaction_account_rules existing
        WHERE existing.company_id = v_target.id
          AND existing.transaction_category_id = v_row.target_category_id
          AND existing.account_function_key = v_row.account_function_key;
        INSERT INTO public.transaction_account_rules(
            company_id,transaction_category_id,system_key,
            account_function_key,account_id,effective_from,effective_to,
            rule_version,status,approved_by,approved_at,created_by,updated_by
        ) VALUES (
            v_target.id,v_row.target_category_id,v_row.system_key,
            v_row.account_function_key,v_row.target_account_id,v_now,NULL,
            v_target_rule_version,'ACTIVE',v_actor,v_now,v_actor,v_actor
        ) RETURNING id INTO v_target_id;
        SELECT to_jsonb(rule) INTO v_target_after
        FROM public.transaction_account_rules rule WHERE rule.id = v_target_id;
        INSERT INTO public.finance_master_audit(
            company_id,entity_type,entity_id,action,actor_id,after_state
        ) VALUES (
            v_target.id,'RULE',v_target_id,'CREATE',v_actor,v_target_after
        );
    END LOOP;

    FOR v_row IN
        SELECT fallback.*,account_map.target_id AS target_account_id
        FROM public.company_account_function_fallbacks fallback
        JOIN pg_temp.kgs_finance_clone_account_map account_map
          ON account_map.source_id = fallback.account_id
        WHERE fallback.company_id = v_source.id
          AND fallback.status = 'ACTIVE'
          AND fallback.effective_from <= v_now
          AND (fallback.effective_to IS NULL OR fallback.effective_to > v_now)
        ORDER BY fallback.account_function_key
    LOOP
        SELECT COALESCE(max(existing.fallback_version),0) + 1
        INTO v_target_rule_version
        FROM public.company_account_function_fallbacks existing
        WHERE existing.company_id = v_target.id
          AND existing.account_function_key = v_row.account_function_key;
        INSERT INTO public.company_account_function_fallbacks(
            company_id,account_function_key,account_id,effective_from,
            effective_to,fallback_version,status,approved_by,approved_at,
            created_by,updated_by
        ) VALUES (
            v_target.id,v_row.account_function_key,v_row.target_account_id,
            v_now,NULL,v_target_rule_version,'ACTIVE',v_actor,v_now,v_actor,v_actor
        ) RETURNING id INTO v_target_id;
        SELECT to_jsonb(fallback) INTO v_target_after
        FROM public.company_account_function_fallbacks fallback
        WHERE fallback.id = v_target_id;
        INSERT INTO public.finance_master_audit(
            company_id,entity_type,entity_id,action,actor_id,after_state
        ) VALUES (
            v_target.id,'FALLBACK',v_target_id,'CREATE',v_actor,v_target_after
        );
    END LOOP;

    FOR v_row IN
        SELECT rule_set.*,category_map.target_id AS target_category_id
        FROM public.posting_rule_sets rule_set
        JOIN pg_temp.kgs_finance_clone_category_map category_map
          ON category_map.source_id = rule_set.transaction_category_id
        WHERE rule_set.company_id = v_source.id
          AND rule_set.status = 'APPROVED'
          AND rule_set.effective_from <= v_now
          AND (rule_set.effective_to IS NULL OR rule_set.effective_to > v_now)
        ORDER BY rule_set.transaction_category_id,rule_set.rule_set_version
    LOOP
        SELECT COALESCE(max(existing.rule_set_version),0) + 1
        INTO v_target_rule_version
        FROM public.posting_rule_sets existing
        WHERE existing.company_id = v_target.id
          AND existing.transaction_category_id = v_row.target_category_id;

        INSERT INTO public.posting_rule_sets(
            company_id,transaction_category_id,system_key,rule_set_version,
            effective_from,effective_to,status,description,master_version,
            created_by,updated_by
        ) VALUES (
            v_target.id,v_row.target_category_id,v_row.system_key,
            v_target_rule_version,v_now,NULL,'DRAFT',
            'Cloned from ' || v_source.company_name || ': ' ||
                COALESCE(v_row.description,''),
            1,v_actor,v_actor
        ) RETURNING id INTO v_target_rule_set;

        INSERT INTO public.posting_rule_lines(
            company_id,rule_set_id,line_no,account_function_key,entry_side,
            amount_expression_key,condition_key,is_required,created_by
        )
        SELECT
            v_target.id,v_target_rule_set,line.line_no,
            line.account_function_key,line.entry_side,
            line.amount_expression_key,line.condition_key,line.is_required,v_actor
        FROM public.posting_rule_lines line
        WHERE line.company_id = v_source.id
          AND line.rule_set_id = v_row.id
        ORDER BY line.line_no;

        SELECT to_jsonb(rule_set) || jsonb_build_object(
            'lines',(SELECT jsonb_agg(to_jsonb(line) ORDER BY line.line_no)
                     FROM public.posting_rule_lines line
                     WHERE line.company_id = v_target.id
                       AND line.rule_set_id = v_target_rule_set)
        ) INTO v_target_after
        FROM public.posting_rule_sets rule_set
        WHERE rule_set.id = v_target_rule_set;
        INSERT INTO public.posting_rule_set_audit(
            company_id,rule_set_id,action,actor_id,after_state,reason
        ) VALUES (
            v_target.id,v_target_rule_set,'CREATE',v_actor,v_target_after,
            'Controlled Finance configuration clone from ' || v_source.company_name
        );

        SELECT to_jsonb(rule_set) INTO v_target_before
        FROM public.posting_rule_sets rule_set
        WHERE rule_set.id = v_target_rule_set;
        UPDATE public.posting_rule_sets SET
            status = 'APPROVED',approved_by = v_actor,approved_at = v_now,
            updated_by = v_actor
        WHERE company_id = v_target.id AND id = v_target_rule_set;
        SELECT to_jsonb(rule_set) INTO v_target_after
        FROM public.posting_rule_sets rule_set
        WHERE rule_set.id = v_target_rule_set;
        INSERT INTO public.posting_rule_set_audit(
            company_id,rule_set_id,action,actor_id,before_state,after_state,reason
        ) VALUES (
            v_target.id,v_target_rule_set,'APPROVE',v_actor,
            v_target_before,v_target_after,
            'Controlled Finance configuration clone from ' || v_source.company_name
        );
        INSERT INTO pg_temp.kgs_finance_clone_rule_set_map(source_id,target_id)
        VALUES(v_row.id,v_target_rule_set);
    END LOOP;

    SELECT count(*) INTO v_count
    FROM public.chart_of_accounts source_account
    JOIN pg_temp.kgs_finance_clone_account_map account_map
      ON account_map.source_id = source_account.id
    JOIN public.chart_of_accounts target_account
      ON target_account.company_id = v_target.id
     AND target_account.id = account_map.target_id
    LEFT JOIN pg_temp.kgs_finance_clone_account_map parent_map
      ON parent_map.source_id = source_account.parent_account_id
    WHERE source_account.company_id = v_source.id
      AND (
          (account_map.match_mode <> 'SYSTEM_FUNCTION'
           AND target_account.account_code IS DISTINCT FROM
               source_account.account_code)
          OR target_account.account_name IS DISTINCT FROM source_account.account_name
          OR target_account.account_type IS DISTINCT FROM source_account.account_type
          OR target_account.normal_balance IS DISTINCT FROM source_account.normal_balance
          OR target_account.parent_account_id IS DISTINCT FROM parent_map.target_id
          OR target_account.system_function_key IS DISTINCT FROM
             source_account.system_function_key
          OR target_account.is_postable IS DISTINCT FROM source_account.is_postable
          OR target_account.allow_manual_posting IS DISTINCT FROM
             source_account.allow_manual_posting
          OR target_account.allow_reconciliation IS DISTINCT FROM
             source_account.allow_reconciliation
          OR target_account.is_active IS DISTINCT FROM source_account.is_active
      );
    IF v_count <> 0 THEN
        RAISE EXCEPTION 'CLONED_COA_VERIFICATION_FAILED: % rows',v_count;
    END IF;

    SELECT count(*) INTO v_count
    FROM public.transaction_categories source_category
    JOIN pg_temp.kgs_finance_clone_category_map category_map
      ON category_map.source_id = source_category.id
    JOIN public.transaction_categories target_category
      ON target_category.company_id = v_target.id
     AND target_category.id = category_map.target_id
    WHERE source_category.company_id = v_source.id
      AND (
          target_category.category_code IS DISTINCT FROM
             source_category.category_code
          OR target_category.category_name IS DISTINCT FROM
             source_category.category_name
          OR target_category.system_key IS DISTINCT FROM source_category.system_key
          OR target_category.description IS DISTINCT FROM source_category.description
          OR target_category.is_active IS DISTINCT FROM source_category.is_active
      );
    IF v_count <> 0 THEN
        RAISE EXCEPTION 'CLONED_CATEGORY_VERIFICATION_FAILED: % rows',v_count;
    END IF;

    SELECT
        (SELECT count(*) FROM public.transaction_account_rules
         WHERE company_id = v_source.id AND status = 'ACTIVE'
           AND effective_from <= v_now
           AND (effective_to IS NULL OR effective_to > v_now))
      - (SELECT count(*) FROM public.transaction_account_rules
         WHERE company_id = v_target.id AND status = 'ACTIVE'
           AND effective_from <= v_now
           AND (effective_to IS NULL OR effective_to > v_now))
    INTO v_count;
    IF v_count <> 0 THEN
        RAISE EXCEPTION 'CLONED_TRANSACTION_RULE_COUNT_MISMATCH: %',v_count;
    END IF;

    SELECT count(*) INTO v_count
    FROM public.transaction_account_rules source_rule
    JOIN pg_temp.kgs_finance_clone_category_map category_map
      ON category_map.source_id = source_rule.transaction_category_id
    JOIN pg_temp.kgs_finance_clone_account_map account_map
      ON account_map.source_id = source_rule.account_id
    WHERE source_rule.company_id = v_source.id
      AND source_rule.status = 'ACTIVE'
      AND source_rule.effective_from <= v_now
      AND (source_rule.effective_to IS NULL OR source_rule.effective_to > v_now)
      AND NOT EXISTS (
          SELECT 1 FROM public.transaction_account_rules target_rule
          WHERE target_rule.company_id = v_target.id
            AND target_rule.transaction_category_id = category_map.target_id
            AND target_rule.system_key = source_rule.system_key
            AND target_rule.account_function_key =
                source_rule.account_function_key
            AND target_rule.account_id = account_map.target_id
            AND target_rule.status = 'ACTIVE'
            AND target_rule.effective_from <= v_now
            AND (target_rule.effective_to IS NULL
                 OR target_rule.effective_to > v_now)
      );
    IF v_count <> 0 THEN
        RAISE EXCEPTION 'CLONED_TRANSACTION_RULE_MAPPING_MISMATCH: % rows',v_count;
    END IF;

    SELECT
        (SELECT count(*) FROM public.company_account_function_fallbacks
         WHERE company_id = v_source.id AND status = 'ACTIVE'
           AND effective_from <= v_now
           AND (effective_to IS NULL OR effective_to > v_now))
      - (SELECT count(*) FROM public.company_account_function_fallbacks
         WHERE company_id = v_target.id AND status = 'ACTIVE'
           AND effective_from <= v_now
           AND (effective_to IS NULL OR effective_to > v_now))
    INTO v_count;
    IF v_count <> 0 THEN
        RAISE EXCEPTION 'CLONED_FALLBACK_COUNT_MISMATCH: %',v_count;
    END IF;

    SELECT count(*) INTO v_count
    FROM public.company_account_function_fallbacks source_fallback
    JOIN pg_temp.kgs_finance_clone_account_map account_map
      ON account_map.source_id = source_fallback.account_id
    WHERE source_fallback.company_id = v_source.id
      AND source_fallback.status = 'ACTIVE'
      AND source_fallback.effective_from <= v_now
      AND (source_fallback.effective_to IS NULL
           OR source_fallback.effective_to > v_now)
      AND NOT EXISTS (
          SELECT 1
          FROM public.company_account_function_fallbacks target_fallback
          WHERE target_fallback.company_id = v_target.id
            AND target_fallback.account_function_key =
                source_fallback.account_function_key
            AND target_fallback.account_id = account_map.target_id
            AND target_fallback.status = 'ACTIVE'
            AND target_fallback.effective_from <= v_now
            AND (target_fallback.effective_to IS NULL
                 OR target_fallback.effective_to > v_now)
      );
    IF v_count <> 0 THEN
        RAISE EXCEPTION 'CLONED_FALLBACK_MAPPING_MISMATCH: % rows',v_count;
    END IF;

    SELECT count(*) INTO v_count
    FROM public.posting_rule_sets source_set
    LEFT JOIN pg_temp.kgs_finance_clone_rule_set_map set_map
      ON set_map.source_id = source_set.id
    WHERE source_set.company_id = v_source.id
      AND source_set.status = 'APPROVED'
      AND source_set.effective_from <= v_now
      AND (source_set.effective_to IS NULL OR source_set.effective_to > v_now)
      AND set_map.target_id IS NULL;
    IF v_count <> 0 THEN
        RAISE EXCEPTION 'CLONED_POSTING_RULE_SET_MISSING: % rows',v_count;
    END IF;

    SELECT count(*) INTO v_count
    FROM public.posting_rule_lines source_line
    JOIN pg_temp.kgs_finance_clone_rule_set_map set_map
      ON set_map.source_id = source_line.rule_set_id
    WHERE source_line.company_id = v_source.id
      AND NOT EXISTS (
          SELECT 1 FROM public.posting_rule_lines target_line
          WHERE target_line.company_id = v_target.id
            AND target_line.rule_set_id = set_map.target_id
            AND target_line.line_no = source_line.line_no
            AND target_line.account_function_key =
                source_line.account_function_key
            AND target_line.entry_side = source_line.entry_side
            AND target_line.amount_expression_key =
                source_line.amount_expression_key
            AND target_line.condition_key IS NOT DISTINCT FROM
                source_line.condition_key
            AND target_line.is_required = source_line.is_required
      );
    IF v_count <> 0 THEN
        RAISE EXCEPTION 'CLONED_POSTING_RULE_LINE_MISMATCH: % rows',v_count;
    END IF;

    INSERT INTO pg_temp.kgs_finance_clone_result VALUES (
        'applied_configuration_verification','PASS',jsonb_build_object(
            'coaAndHierarchyExact',TRUE,
            'transactionCategoriesExact',TRUE,
            'activeMappingCountsMatch',TRUE,
            'atomic',TRUE
        )
    );

    INSERT INTO pg_temp.kgs_finance_clone_result VALUES (
        'operation_mode','APPLIED',jsonb_build_object(
            'sourceCompany',v_source.company_name,
            'targetCompany',v_target.company_name,
            'actorId',v_actor,
            'accountsMapped',(
                SELECT count(*) FROM pg_temp.kgs_finance_clone_account_map),
            'categoriesMapped',(
                SELECT count(*) FROM pg_temp.kgs_finance_clone_category_map),
            'postingRuleSetsCloned',(
                SELECT count(*) FROM pg_temp.kgs_finance_clone_rule_set_map)
        )
    );
END
$operation$;

SELECT check_name,status,details
FROM pg_temp.kgs_finance_clone_result
ORDER BY CASE status
    WHEN 'BLOCKER' THEN 1
    WHEN 'PASS' THEN 2
    WHEN 'PREVIEW' THEN 3
    WHEN 'APPLIED' THEN 4
    ELSE 5
END,check_name;
