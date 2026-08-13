-- G6 corrective phase 7A: guarded append-only Finance journal reversal.
-- Automatic operational journals remain source-document controlled.

BEGIN;

DO $migration_guard$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260810230000'
    ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: G6 Phase 6C dependency missing';
    END IF;
    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260811090000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260811090000';
    END IF;
    IF to_regclass('public.finance_journals') IS NULL
       OR to_regclass('public.finance_journal_lines') IS NULL
       OR to_regclass('public.finance_journal_audit') IS NULL
       OR to_regclass('public.chart_of_accounts') IS NULL
       OR to_regclass('public.accounting_periods') IS NULL
       OR to_regprocedure(
           'private.trg_g6_guard_finance_journal_line()'
       ) IS NULL
       OR to_regprocedure(
           'public.reverse_finance_journal(uuid,bigint,date,text,uuid)'
       ) IS NOT NULL THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: Phase 7A live contract changed';
    END IF;
    IF (
        SELECT count(*)
        FROM pg_trigger trigger_state
        JOIN pg_class relation ON relation.oid = trigger_state.tgrelid
        JOIN pg_namespace namespace ON namespace.oid = relation.relnamespace
        WHERE namespace.nspname = 'public'
          AND relation.relname = 'finance_journal_lines'
          AND trigger_state.tgname = 'g6_guard_finance_journal_line'
          AND NOT trigger_state.tgisinternal
    ) <> 1 THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: journal line guard changed';
    END IF;
END
$migration_guard$;

CREATE OR REPLACE FUNCTION private.trg_g6_guard_finance_journal_line()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_company UUID;
    v_journal UUID;
    v_status TEXT;
    v_journal_type TEXT;
    v_reversal_of UUID;
    v_account public.chart_of_accounts%ROWTYPE;
    v_original_line public.finance_journal_lines%ROWTYPE;
BEGIN
    IF TG_OP = 'DELETE' THEN
        v_company := OLD.company_id;
        v_journal := OLD.journal_id;
    ELSE
        v_company := NEW.company_id;
        v_journal := NEW.journal_id;
    END IF;
    IF TG_OP = 'UPDATE'
       AND (
           NEW.id IS DISTINCT FROM OLD.id
           OR NEW.company_id IS DISTINCT FROM OLD.company_id
           OR NEW.journal_id IS DISTINCT FROM OLD.journal_id
       ) THEN
        RAISE EXCEPTION 'FINANCE_JOURNAL_LINE_IDENTITY_IMMUTABLE';
    END IF;

    SELECT journal.status,journal.journal_type,journal.reversal_of_journal_id
    INTO v_status,v_journal_type,v_reversal_of
    FROM public.finance_journals journal
    WHERE journal.company_id = v_company AND journal.id = v_journal
    FOR UPDATE;
    IF v_status IS NULL THEN RAISE EXCEPTION 'FINANCE_JOURNAL_NOT_FOUND'; END IF;
    IF v_status <> 'DRAFT' THEN RAISE EXCEPTION 'POSTED_JOURNAL_IMMUTABLE'; END IF;
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;

    IF v_journal_type = 'REVERSAL' THEN
        SELECT original_line.* INTO v_original_line
        FROM public.finance_journal_lines original_line
        JOIN public.finance_journals original_journal
          ON original_journal.company_id = original_line.company_id
         AND original_journal.id = original_line.journal_id
        WHERE original_line.company_id = NEW.company_id
          AND original_line.journal_id = v_reversal_of
          AND original_line.line_no = NEW.line_no
          AND original_line.account_id = NEW.account_id
          AND original_journal.status = 'POSTED'
          AND original_journal.journal_type IN (
              'MANUAL','OPENING_BALANCE'
          );
        IF NOT FOUND THEN
            RAISE EXCEPTION 'REVERSAL_LINE_SOURCE_MISMATCH';
        END IF;
        NEW.account_code_snapshot := v_original_line.account_code_snapshot;
        NEW.account_name_snapshot := v_original_line.account_name_snapshot;
        NEW.account_function_key_snapshot :=
            v_original_line.account_function_key_snapshot;
        NEW.normal_balance_snapshot := v_original_line.normal_balance_snapshot;
        NEW.debit := v_original_line.credit;
        NEW.credit := v_original_line.debit;
        NEW.store_id := v_original_line.store_id;
        NEW.warehouse_id := v_original_line.warehouse_id;
        NEW.customer_id := v_original_line.customer_id;
        NEW.supplier_id := v_original_line.supplier_id;
        RETURN NEW;
    END IF;

    SELECT * INTO v_account
    FROM public.chart_of_accounts account
    WHERE account.company_id = NEW.company_id
      AND account.id = NEW.account_id;
    IF NOT FOUND OR NOT v_account.is_active OR NOT v_account.is_postable THEN
        RAISE EXCEPTION 'ACTIVE_POSTABLE_ACCOUNT_REQUIRED';
    END IF;
    NEW.account_code_snapshot := v_account.account_code;
    NEW.account_name_snapshot := v_account.account_name;
    NEW.account_function_key_snapshot := v_account.system_function_key;
    NEW.normal_balance_snapshot := v_account.normal_balance;
    RETURN NEW;
END;
$$;

CREATE FUNCTION public.reverse_finance_journal(
    p_journal_id UUID,
    p_expected_master_version BIGINT,
    p_accounting_date DATE,
    p_reason TEXT,
    p_idempotency_key UUID
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, private, pg_temp
AS $$
DECLARE
    v_actor UUID := auth.uid();
    v_company UUID := public.private_active_company_id();
    v_original public.finance_journals%ROWTYPE;
    v_existing public.finance_journals%ROWTYPE;
    v_period public.accounting_periods%ROWTYPE;
    v_reversal public.finance_journals%ROWTYPE;
    v_reversal_id UUID := gen_random_uuid();
    v_idempotency TEXT;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF NOT public.private_user_has_any_company_or_store_role(
        v_company,
        ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE']::TEXT[]
    ) THEN
        RAISE EXCEPTION 'FINANCE_JOURNAL_REVERSAL_ROLE_REQUIRED';
    END IF;
    IF p_journal_id IS NULL OR p_expected_master_version IS NULL
       OR p_accounting_date IS NULL OR p_idempotency_key IS NULL THEN
        RAISE EXCEPTION 'REVERSAL_INPUT_REQUIRED';
    END IF;
    IF btrim(COALESCE(p_reason,'')) = '' THEN
        RAISE EXCEPTION 'REVERSAL_REASON_REQUIRED';
    END IF;
    v_idempotency := 'G6_REVERSAL|' || p_idempotency_key::TEXT;

    SELECT * INTO v_original
    FROM public.finance_journals journal
    WHERE journal.company_id = v_company AND journal.id = p_journal_id
    FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'FINANCE_JOURNAL_NOT_FOUND'; END IF;

    SELECT * INTO v_existing
    FROM public.finance_journals journal
    WHERE journal.company_id = v_company
      AND journal.reversal_of_journal_id = v_original.id;
    IF FOUND THEN
        IF v_existing.idempotency_key = v_idempotency
           AND v_existing.status = 'POSTED' THEN
            RETURN jsonb_build_object(
                'journalId',v_existing.id,
                'journalNo',v_existing.journal_no,
                'status',v_existing.status,
                'masterVersion',v_existing.master_version,
                'reversalOfJournalId',v_original.id,
                'idempotentReplay',TRUE
            );
        END IF;
        RAISE EXCEPTION 'JOURNAL_ALREADY_REVERSED';
    END IF;

    IF EXISTS (
        SELECT 1 FROM public.finance_journals journal
        WHERE journal.company_id = v_company
          AND journal.idempotency_key = v_idempotency
    ) THEN
        RAISE EXCEPTION 'REVERSAL_IDEMPOTENCY_CONFLICT';
    END IF;
    IF p_expected_master_version <> v_original.master_version THEN
        RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
    END IF;
    IF v_original.status <> 'POSTED' THEN
        RAISE EXCEPTION 'POSTED_FINANCE_JOURNAL_REQUIRED';
    END IF;
    IF v_original.journal_type NOT IN ('MANUAL','OPENING_BALANCE') THEN
        RAISE EXCEPTION 'SOURCE_DOCUMENT_REVERSAL_REQUIRED';
    END IF;

    SELECT * INTO v_period
    FROM public.accounting_periods period
    WHERE period.company_id = v_company
      AND p_accounting_date BETWEEN period.start_date AND period.end_date
      AND period.status IN ('OPEN','REOPENED')
    ORDER BY period.start_date DESC,period.id
    LIMIT 1
    FOR SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION 'OPEN_ACCOUNTING_PERIOD_REQUIRED'; END IF;

    INSERT INTO public.finance_journals(
        id,company_id,journal_no,journal_type,accounting_period_id,
        accounting_date,original_event_date,source_type,source_id,
        source_version,idempotency_key,system_event_key,
        transaction_category_id,transaction_rule_version,store_id,
        warehouse_id,currency_code,description,reversal_of_journal_id,
        created_by
    ) VALUES (
        v_reversal_id,v_company,
        'REV-' || upper(replace(p_idempotency_key::TEXT,'-','')),
        'REVERSAL',v_period.id,p_accounting_date,
        COALESCE(v_original.original_event_date,v_original.accounting_date),
        'FINANCE_JOURNAL_REVERSAL',v_original.id,v_original.master_version,
        v_idempotency,v_original.system_event_key,
        v_original.transaction_category_id,
        v_original.transaction_rule_version,v_original.store_id,
        v_original.warehouse_id,v_original.currency_code,
        'Reversal ' || v_original.journal_no || ': ' || btrim(p_reason),
        v_original.id,v_actor
    ) RETURNING * INTO v_reversal;

    INSERT INTO public.finance_journal_lines(
        company_id,journal_id,line_no,account_id,
        account_code_snapshot,account_name_snapshot,
        account_function_key_snapshot,normal_balance_snapshot,
        debit,credit,store_id,warehouse_id,customer_id,supplier_id,description
    )
    SELECT
        v_company,v_reversal.id,line.line_no,line.account_id,
        line.account_code_snapshot,line.account_name_snapshot,
        line.account_function_key_snapshot,line.normal_balance_snapshot,
        line.credit,line.debit,line.store_id,line.warehouse_id,
        line.customer_id,line.supplier_id,
        COALESCE(line.description,'') || ' [REVERSAL]'
    FROM public.finance_journal_lines line
    WHERE line.company_id = v_company AND line.journal_id = v_original.id
    ORDER BY line.line_no;

    UPDATE public.finance_journals SET
        status = 'POSTED',posted_by = v_actor
    WHERE company_id = v_company AND id = v_reversal.id
    RETURNING * INTO v_reversal;

    INSERT INTO public.finance_journal_audit(
        company_id,entity_type,entity_id,action,actor_id,
        before_state,after_state,reason
    ) VALUES (
        v_company,'JOURNAL',v_original.id,'REVERSE',v_actor,
        to_jsonb(v_original),
        jsonb_build_object(
            'reversalJournalId',v_reversal.id,
            'reversalJournalNo',v_reversal.journal_no,
            'accountingDate',v_reversal.accounting_date,
            'masterVersion',v_reversal.master_version
        ),
        btrim(p_reason)
    );

    RETURN jsonb_build_object(
        'journalId',v_reversal.id,
        'journalNo',v_reversal.journal_no,
        'status',v_reversal.status,
        'masterVersion',v_reversal.master_version,
        'reversalOfJournalId',v_original.id,
        'idempotentReplay',FALSE
    );
END;
$$;

REVOKE ALL ON FUNCTION
    public.reverse_finance_journal(UUID,BIGINT,DATE,TEXT,UUID)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION
    public.reverse_finance_journal(UUID,BIGINT,DATE,TEXT,UUID)
TO authenticated,service_role;

REVOKE ALL ON FUNCTION private.trg_g6_guard_finance_journal_line()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.trg_g6_guard_finance_journal_line()
TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES (
    '20260811090000',
    'g6_phase7_append_only_journal_reversal',
    'Guarded tenant/role/period-aware append-only reversal for manual Finance and opening-balance journals; automatic operational journals remain source-controlled.'
);

COMMIT;
