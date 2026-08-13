-- G6 corrective phase 2: tenant-safe Accounting Period and canonical Journal
-- foundation. Additive only: legacy journal_entries and rejected journal_lines
-- are not repurposed, migrated, deleted, or written.

BEGIN;

DO $migration_guard$
DECLARE
    v_invalid_periods BIGINT;
    v_rejected_lines BIGINT;
BEGIN
    IF to_regclass('private.kgs_schema_migrations') IS NULL
       OR NOT EXISTS (
           SELECT 1 FROM private.kgs_schema_migrations
           WHERE version = '20260810170000'
       ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: G6 corrective phase 1 incomplete';
    END IF;
    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260810180000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260810180000';
    END IF;
    IF to_regclass('public.accounting_periods') IS NULL
       OR to_regclass('public.journal_lines') IS NULL THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: audited partial Finance objects changed';
    END IF;
    IF to_regclass('public.finance_journals') IS NOT NULL
       OR to_regclass('public.finance_journal_lines') IS NOT NULL
       OR to_regclass('public.finance_journal_audit') IS NOT NULL THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: canonical Finance target already exists';
    END IF;
    IF to_regprocedure(
           'public.create_accounting_period(integer,integer)'
       ) IS NOT NULL
       OR to_regprocedure(
           'public.lock_accounting_period(uuid,bigint)'
       ) IS NOT NULL
       OR to_regprocedure(
           'public.reopen_accounting_period(uuid,bigint,text)'
       ) IS NOT NULL THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: canonical period RPC target exists';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM information_schema.columns column_state
        WHERE column_state.table_schema = 'public'
          AND column_state.table_name = 'accounting_periods'
          AND column_state.column_name = 'status'
          AND column_state.data_type NOT IN ('text','character varying')
    ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: accounting period status is not text-compatible';
    END IF;

    SELECT count(*) INTO v_invalid_periods
    FROM public.accounting_periods period
    WHERE period.company_id IS NULL
       OR period.period_year NOT BETWEEN 2000 AND 9999
       OR period.period_month NOT BETWEEN 1 AND 12
       OR period.start_date <> make_date(
           period.period_year,period.period_month,1
       )
       OR period.end_date <> (
           make_date(period.period_year,period.period_month,1)
           + INTERVAL '1 month' - INTERVAL '1 day'
       )::DATE
       OR period.status::TEXT NOT IN ('OPEN','LOCKED','REOPENED');
    IF v_invalid_periods <> 0 THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: % accounting periods violate canonical contract',
            v_invalid_periods;
    END IF;

    SELECT count(*) INTO v_rejected_lines FROM public.journal_lines;
    IF v_rejected_lines <> 0 THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: rejected journal_lines contains % rows',
            v_rejected_lines;
    END IF;
END
$migration_guard$;

-- Adopt the valid monthly period rows without renaming their live date fields.
ALTER TABLE public.accounting_periods
    ADD COLUMN master_version BIGINT NOT NULL DEFAULT 1,
    ADD COLUMN created_by UUID REFERENCES public.profiles(id),
    ADD COLUMN updated_by UUID REFERENCES public.profiles(id),
    ADD CONSTRAINT accounting_periods_master_version_positive
        CHECK(master_version > 0),
    ADD CONSTRAINT accounting_periods_canonical_month_check CHECK (
        period_year BETWEEN 2000 AND 9999
        AND period_month BETWEEN 1 AND 12
        AND start_date = make_date(period_year,period_month,1)
        AND end_date = (
            make_date(period_year,period_month,1)
            + INTERVAL '1 month' - INTERVAL '1 day'
        )::DATE
    );

DO $period_constraint_adoption$
DECLARE
    v_constraint RECORD;
BEGIN
    FOR v_constraint IN
        SELECT constraint_state.conname
        FROM pg_constraint constraint_state
        JOIN pg_class relation ON relation.oid = constraint_state.conrelid
        JOIN pg_namespace namespace ON namespace.oid = relation.relnamespace
        WHERE namespace.nspname = 'public'
          AND relation.relname = 'accounting_periods'
          AND constraint_state.contype = 'c'
          AND pg_get_constraintdef(constraint_state.oid) ILIKE '%status%'
    LOOP
        EXECUTE format(
            'ALTER TABLE public.accounting_periods DROP CONSTRAINT %I',
            v_constraint.conname
        );
    END LOOP;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint constraint_state
        JOIN pg_class relation ON relation.oid = constraint_state.conrelid
        JOIN pg_namespace namespace ON namespace.oid = relation.relnamespace
        WHERE namespace.nspname = 'public'
          AND relation.relname = 'accounting_periods'
          AND constraint_state.conname =
              'accounting_periods_company_id_id_unique'
    ) THEN
        ALTER TABLE public.accounting_periods
            ADD CONSTRAINT accounting_periods_company_id_id_unique
            UNIQUE(company_id,id);
    END IF;
END
$period_constraint_adoption$;

ALTER TABLE public.accounting_periods
    ALTER COLUMN status SET DEFAULT 'OPEN',
    ALTER COLUMN status SET NOT NULL,
    ADD CONSTRAINT accounting_periods_canonical_status_check CHECK (
        status IN ('OPEN','LOCKED','REOPENED')
    ),
    ADD CONSTRAINT accounting_periods_canonical_lifecycle_check CHECK (
        status = 'OPEN'
        OR (
            status = 'LOCKED'
            AND closed_by IS NOT NULL AND closed_at IS NOT NULL
        )
        OR (
            status = 'REOPENED'
            AND closed_by IS NOT NULL AND closed_at IS NOT NULL
            AND reopened_by IS NOT NULL AND reopened_at IS NOT NULL
            AND btrim(COALESCE(reopen_reason,'')) <> ''
        )
    );

CREATE TABLE public.finance_journals (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL
        REFERENCES public.companies(id) ON DELETE RESTRICT,
    journal_no TEXT NOT NULL,
    journal_type TEXT NOT NULL,
    accounting_period_id UUID NOT NULL,
    accounting_date DATE NOT NULL,
    original_event_date DATE,
    source_type TEXT NOT NULL,
    source_id UUID NOT NULL,
    source_version BIGINT,
    financial_event_id UUID,
    idempotency_key TEXT NOT NULL,
    system_event_key TEXT REFERENCES public.system_events(system_key),
    transaction_category_id UUID,
    transaction_rule_version BIGINT,
    store_id UUID,
    warehouse_id UUID,
    currency_code TEXT NOT NULL DEFAULT 'IDR',
    description TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'DRAFT',
    total_debit NUMERIC(20,4) NOT NULL DEFAULT 0,
    total_credit NUMERIC(20,4) NOT NULL DEFAULT 0,
    reversal_of_journal_id UUID,
    master_version BIGINT NOT NULL DEFAULT 1,
    created_by UUID REFERENCES public.profiles(id),
    posted_by UUID REFERENCES public.profiles(id),
    canceled_by UUID REFERENCES public.profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    posted_at TIMESTAMPTZ,
    canceled_at TIMESTAMPTZ,
    cancel_reason TEXT,
    CONSTRAINT finance_journals_company_id_id_unique UNIQUE(company_id,id),
    CONSTRAINT finance_journals_company_no_unique
        UNIQUE(company_id,journal_no),
    CONSTRAINT finance_journals_company_idempotency_unique
        UNIQUE(company_id,idempotency_key),
    CONSTRAINT finance_journals_type_check CHECK (
        journal_type IN (
            'AUTOMATIC','MANUAL','OPENING_BALANCE','REVERSAL',
            'PRIOR_PERIOD_ADJUSTMENT'
        )
    ),
    CONSTRAINT finance_journals_status_check CHECK (
        status IN ('DRAFT','POSTED','CANCELED')
    ),
    CONSTRAINT finance_journals_identity_not_blank CHECK (
        btrim(journal_no) <> '' AND btrim(source_type) <> ''
        AND btrim(idempotency_key) <> '' AND btrim(description) <> ''
    ),
    CONSTRAINT finance_journals_currency_check CHECK(currency_code = 'IDR'),
    CONSTRAINT finance_journals_amount_nonnegative CHECK (
        total_debit >= 0 AND total_credit >= 0
    ),
    CONSTRAINT finance_journals_posted_balance_check CHECK (
        status <> 'POSTED'
        OR (total_debit > 0 AND total_debit = total_credit)
    ),
    CONSTRAINT finance_journals_master_version_positive
        CHECK(master_version > 0),
    CONSTRAINT finance_journals_source_version_positive CHECK (
        source_version IS NULL OR source_version > 0
    ),
    CONSTRAINT finance_journals_rule_version_positive CHECK (
        transaction_rule_version IS NULL OR transaction_rule_version > 0
    ),
    CONSTRAINT finance_journals_posted_snapshot_check CHECK (
        status <> 'POSTED'
        OR (posted_by IS NOT NULL AND posted_at IS NOT NULL)
    ),
    CONSTRAINT finance_journals_canceled_snapshot_check CHECK (
        status <> 'CANCELED'
        OR (
            canceled_by IS NOT NULL AND canceled_at IS NOT NULL
            AND btrim(COALESCE(cancel_reason,'')) <> ''
        )
    ),
    CONSTRAINT finance_journals_automatic_source_check CHECK (
        journal_type <> 'AUTOMATIC'
        OR (
            financial_event_id IS NOT NULL
            AND system_event_key IS NOT NULL
            AND transaction_category_id IS NOT NULL
            AND transaction_rule_version IS NOT NULL
        )
    ),
    CONSTRAINT finance_journals_reversal_source_check CHECK (
        journal_type <> 'REVERSAL' OR reversal_of_journal_id IS NOT NULL
    ),
    CONSTRAINT finance_journals_not_self_reversal CHECK (
        reversal_of_journal_id IS NULL OR reversal_of_journal_id <> id
    ),
    CONSTRAINT fk_finance_journals_company_period
        FOREIGN KEY(company_id,accounting_period_id)
        REFERENCES public.accounting_periods(company_id,id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_finance_journals_company_event
        FOREIGN KEY(company_id,financial_event_id)
        REFERENCES public.financial_events(company_id,id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_finance_journals_company_category
        FOREIGN KEY(company_id,transaction_category_id)
        REFERENCES public.transaction_categories(company_id,id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_finance_journals_company_store
        FOREIGN KEY(company_id,store_id)
        REFERENCES public.stores(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_finance_journals_company_warehouse
        FOREIGN KEY(company_id,warehouse_id)
        REFERENCES public.warehouses(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_finance_journals_company_reversal
        FOREIGN KEY(company_id,reversal_of_journal_id)
        REFERENCES public.finance_journals(company_id,id) ON DELETE RESTRICT
);

CREATE UNIQUE INDEX uq_finance_journals_company_event
    ON public.finance_journals(company_id,financial_event_id)
    WHERE financial_event_id IS NOT NULL;
CREATE UNIQUE INDEX uq_finance_journals_company_reversal
    ON public.finance_journals(company_id,reversal_of_journal_id)
    WHERE reversal_of_journal_id IS NOT NULL;
CREATE INDEX idx_finance_journals_company_period_status
    ON public.finance_journals(company_id,accounting_period_id,status);
CREATE INDEX idx_finance_journals_company_date
    ON public.finance_journals(company_id,accounting_date,id);

CREATE TABLE public.finance_journal_lines (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL,
    journal_id UUID NOT NULL,
    line_no INTEGER NOT NULL,
    account_id UUID NOT NULL,
    account_code_snapshot TEXT NOT NULL,
    account_name_snapshot TEXT NOT NULL,
    account_function_key_snapshot TEXT,
    normal_balance_snapshot TEXT NOT NULL,
    debit NUMERIC(20,4) NOT NULL DEFAULT 0,
    credit NUMERIC(20,4) NOT NULL DEFAULT 0,
    store_id UUID,
    warehouse_id UUID,
    customer_id UUID,
    supplier_id UUID,
    description TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT finance_journal_lines_company_id_id_unique
        UNIQUE(company_id,id),
    CONSTRAINT finance_journal_lines_company_line_unique
        UNIQUE(company_id,journal_id,line_no),
    CONSTRAINT finance_journal_lines_line_positive CHECK(line_no > 0),
    CONSTRAINT finance_journal_lines_account_snapshot_check CHECK (
        btrim(account_code_snapshot) <> ''
        AND btrim(account_name_snapshot) <> ''
        AND normal_balance_snapshot IN ('DEBIT','CREDIT')
    ),
    CONSTRAINT finance_journal_lines_one_sided_amount_check CHECK (
        (debit > 0 AND credit = 0) OR (credit > 0 AND debit = 0)
    ),
    CONSTRAINT fk_finance_journal_lines_company_journal
        FOREIGN KEY(company_id,journal_id)
        REFERENCES public.finance_journals(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_finance_journal_lines_company_account
        FOREIGN KEY(company_id,account_id)
        REFERENCES public.chart_of_accounts(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_finance_journal_lines_company_store
        FOREIGN KEY(company_id,store_id)
        REFERENCES public.stores(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_finance_journal_lines_company_warehouse
        FOREIGN KEY(company_id,warehouse_id)
        REFERENCES public.warehouses(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_finance_journal_lines_company_customer
        FOREIGN KEY(company_id,customer_id)
        REFERENCES public.customers(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_finance_journal_lines_company_supplier
        FOREIGN KEY(company_id,supplier_id)
        REFERENCES public.suppliers(company_id,id) ON DELETE RESTRICT
);

CREATE INDEX idx_finance_journal_lines_company_journal
    ON public.finance_journal_lines(company_id,journal_id,line_no);
CREATE INDEX idx_finance_journal_lines_company_account
    ON public.finance_journal_lines(company_id,account_id);

CREATE TABLE public.finance_journal_audit (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_id UUID NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
    entity_type TEXT NOT NULL,
    entity_id UUID NOT NULL,
    action TEXT NOT NULL,
    actor_id UUID NOT NULL REFERENCES public.profiles(id),
    before_state JSONB,
    after_state JSONB NOT NULL,
    reason TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT finance_journal_audit_entity_check CHECK (
        entity_type IN ('ACCOUNTING_PERIOD','JOURNAL')
    ),
    CONSTRAINT finance_journal_audit_action_check CHECK (
        action IN ('CREATE','LOCK','REOPEN','POST','CANCEL','REVERSE')
    )
);

CREATE INDEX idx_finance_journal_audit_entity
    ON public.finance_journal_audit(
        company_id,entity_type,entity_id,created_at DESC
    );

CREATE FUNCTION private.trg_g6_touch_accounting_period()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        NEW.master_version := 1;
        NEW.created_at := COALESCE(NEW.created_at,clock_timestamp());
        NEW.updated_at := COALESCE(NEW.updated_at,NEW.created_at);
        IF auth.uid() IS NOT NULL THEN
            NEW.created_by := COALESCE(NEW.created_by,auth.uid());
            NEW.updated_by := COALESCE(NEW.updated_by,auth.uid());
        END IF;
    ELSE
        IF NEW.company_id IS DISTINCT FROM OLD.company_id
           OR NEW.id IS DISTINCT FROM OLD.id
           OR NEW.period_year IS DISTINCT FROM OLD.period_year
           OR NEW.period_month IS DISTINCT FROM OLD.period_month
           OR NEW.start_date IS DISTINCT FROM OLD.start_date
           OR NEW.end_date IS DISTINCT FROM OLD.end_date THEN
            RAISE EXCEPTION 'ACCOUNTING_PERIOD_IDENTITY_IMMUTABLE';
        END IF;
        NEW.master_version := OLD.master_version + 1;
        NEW.updated_at := clock_timestamp();
        IF auth.uid() IS NOT NULL THEN NEW.updated_by := auth.uid(); END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION private.trg_g6_guard_accounting_period_delete()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    RAISE EXCEPTION 'ACCOUNTING_PERIOD_DELETE_FORBIDDEN';
END;
$$;

CREATE FUNCTION private.trg_g6_guard_finance_journal()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_period public.accounting_periods%ROWTYPE;
    v_line_count BIGINT;
    v_debit NUMERIC(20,4);
    v_credit NUMERIC(20,4);
    v_actor UUID;
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'FINANCE_JOURNAL_DELETE_FORBIDDEN';
    END IF;

    IF TG_OP = 'INSERT' THEN
        IF NEW.status <> 'DRAFT' THEN
            RAISE EXCEPTION 'FINANCE_JOURNAL_MUST_START_DRAFT';
        END IF;
        NEW.master_version := 1;
        NEW.created_at := COALESCE(NEW.created_at,clock_timestamp());
        NEW.updated_at := COALESCE(NEW.updated_at,NEW.created_at);
        RETURN NEW;
    END IF;

    IF OLD.status <> 'DRAFT' THEN
        RAISE EXCEPTION 'POSTED_JOURNAL_IMMUTABLE';
    END IF;
    IF NEW.company_id IS DISTINCT FROM OLD.company_id
       OR NEW.id IS DISTINCT FROM OLD.id
       OR NEW.journal_no IS DISTINCT FROM OLD.journal_no
       OR NEW.idempotency_key IS DISTINCT FROM OLD.idempotency_key
       OR NEW.financial_event_id IS DISTINCT FROM OLD.financial_event_id
       OR NEW.reversal_of_journal_id IS DISTINCT FROM OLD.reversal_of_journal_id
    THEN
        RAISE EXCEPTION 'FINANCE_JOURNAL_IDENTITY_IMMUTABLE';
    END IF;

    NEW.master_version := OLD.master_version + 1;
    NEW.updated_at := clock_timestamp();

    IF NEW.status = 'POSTED' THEN
        SELECT * INTO v_period
        FROM public.accounting_periods period
        WHERE period.company_id = NEW.company_id
          AND period.id = NEW.accounting_period_id
        FOR SHARE;
        IF NOT FOUND THEN RAISE EXCEPTION 'ACCOUNTING_PERIOD_NOT_FOUND'; END IF;
        IF v_period.status NOT IN ('OPEN','REOPENED') THEN
            RAISE EXCEPTION 'ACCOUNTING_PERIOD_LOCKED';
        END IF;
        IF NEW.accounting_date < v_period.start_date
           OR NEW.accounting_date > v_period.end_date THEN
            RAISE EXCEPTION 'ACCOUNTING_DATE_OUTSIDE_PERIOD';
        END IF;

        -- Re-resolve every account snapshot at the posting boundary and fail
        -- if a Draft account became inactive/non-postable in the meantime.
        UPDATE public.finance_journal_lines line SET
            account_id = line.account_id
        WHERE line.company_id = NEW.company_id
          AND line.journal_id = NEW.id;

        SELECT count(*),COALESCE(sum(line.debit),0),
               COALESCE(sum(line.credit),0)
        INTO v_line_count,v_debit,v_credit
        FROM public.finance_journal_lines line
        WHERE line.company_id = NEW.company_id
          AND line.journal_id = NEW.id;
        IF v_line_count < 2 THEN
            RAISE EXCEPTION 'JOURNAL_MINIMUM_TWO_LINES_REQUIRED';
        END IF;
        IF v_debit <= 0 OR round(v_debit,4) <> round(v_credit,4) THEN
            RAISE EXCEPTION 'JOURNAL_UNBALANCED';
        END IF;
        IF NEW.posted_by IS NULL THEN RAISE EXCEPTION 'POSTED_BY_REQUIRED'; END IF;

        NEW.total_debit := v_debit;
        NEW.total_credit := v_credit;
        NEW.posted_at := COALESCE(NEW.posted_at,clock_timestamp());
        v_actor := NEW.posted_by;
        INSERT INTO public.finance_journal_audit(
            company_id,entity_type,entity_id,action,actor_id,
            before_state,after_state
        ) VALUES (
            NEW.company_id,'JOURNAL',NEW.id,'POST',v_actor,
            to_jsonb(OLD),to_jsonb(NEW)
        );
    ELSIF NEW.status = 'CANCELED' THEN
        IF NEW.canceled_by IS NULL
           OR btrim(COALESCE(NEW.cancel_reason,'')) = '' THEN
            RAISE EXCEPTION 'JOURNAL_CANCEL_SNAPSHOT_REQUIRED';
        END IF;
        NEW.canceled_at := COALESCE(NEW.canceled_at,clock_timestamp());
        v_actor := NEW.canceled_by;
        INSERT INTO public.finance_journal_audit(
            company_id,entity_type,entity_id,action,actor_id,
            before_state,after_state,reason
        ) VALUES (
            NEW.company_id,'JOURNAL',NEW.id,'CANCEL',v_actor,
            to_jsonb(OLD),to_jsonb(NEW),btrim(NEW.cancel_reason)
        );
    ELSIF NEW.status <> 'DRAFT' THEN
        RAISE EXCEPTION 'INVALID_FINANCE_JOURNAL_STATUS_TRANSITION';
    END IF;

    RETURN NEW;
END;
$$;

CREATE FUNCTION private.trg_g6_guard_finance_journal_line()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_company UUID;
    v_journal UUID;
    v_status TEXT;
    v_account public.chart_of_accounts%ROWTYPE;
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
    SELECT journal.status INTO v_status
    FROM public.finance_journals journal
    WHERE journal.company_id = v_company AND journal.id = v_journal
    FOR UPDATE;
    IF v_status IS NULL THEN RAISE EXCEPTION 'FINANCE_JOURNAL_NOT_FOUND'; END IF;
    IF v_status <> 'DRAFT' THEN RAISE EXCEPTION 'POSTED_JOURNAL_IMMUTABLE'; END IF;
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;

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

CREATE FUNCTION private.trg_g6_guard_finance_journal_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    RAISE EXCEPTION 'FINANCE_JOURNAL_AUDIT_IMMUTABLE';
END;
$$;

CREATE TRIGGER g6_touch_accounting_period
BEFORE INSERT OR UPDATE ON public.accounting_periods
FOR EACH ROW EXECUTE FUNCTION private.trg_g6_touch_accounting_period();
CREATE TRIGGER g6_guard_accounting_period_delete
BEFORE DELETE ON public.accounting_periods
FOR EACH ROW EXECUTE FUNCTION private.trg_g6_guard_accounting_period_delete();
CREATE TRIGGER g6_guard_finance_journal
BEFORE INSERT OR UPDATE OR DELETE ON public.finance_journals
FOR EACH ROW EXECUTE FUNCTION private.trg_g6_guard_finance_journal();
CREATE TRIGGER g6_guard_finance_journal_line
BEFORE INSERT OR UPDATE OR DELETE ON public.finance_journal_lines
FOR EACH ROW EXECUTE FUNCTION private.trg_g6_guard_finance_journal_line();
CREATE TRIGGER g6_guard_finance_journal_audit
BEFORE UPDATE OR DELETE ON public.finance_journal_audit
FOR EACH ROW EXECUTE FUNCTION private.trg_g6_guard_finance_journal_audit();

CREATE FUNCTION public.create_accounting_period(
    p_period_year INTEGER,p_period_month INTEGER
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_actor UUID := auth.uid();
    v_company UUID := public.private_active_company_id();
    v_period public.accounting_periods%ROWTYPE;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF NOT public.private_user_has_any_company_or_store_role(
        v_company,
        ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE','ACCOUNTING']::TEXT[]
    ) THEN RAISE EXCEPTION 'FINANCE_PERIOD_MANAGER_REQUIRED'; END IF;
    IF p_period_year NOT BETWEEN 2000 AND 9999
       OR p_period_month NOT BETWEEN 1 AND 12 THEN
        RAISE EXCEPTION 'INVALID_ACCOUNTING_PERIOD';
    END IF;

    PERFORM pg_advisory_xact_lock(
        hashtextextended('G6_PERIOD|' || v_company::TEXT,0)
    );
    INSERT INTO public.accounting_periods(
        company_id,period_year,period_month,start_date,end_date,status,
        created_by,updated_by
    ) VALUES (
        v_company,p_period_year,p_period_month,
        make_date(p_period_year,p_period_month,1),
        (make_date(p_period_year,p_period_month,1)
         + INTERVAL '1 month' - INTERVAL '1 day')::DATE,
        'OPEN',v_actor,v_actor
    ) RETURNING * INTO v_period;

    INSERT INTO public.finance_journal_audit(
        company_id,entity_type,entity_id,action,actor_id,after_state
    ) VALUES (
        v_company,'ACCOUNTING_PERIOD',v_period.id,'CREATE',v_actor,
        to_jsonb(v_period)
    );
    RETURN jsonb_build_object(
        'accountingPeriodId',v_period.id,
        'masterVersion',v_period.master_version,
        'status',v_period.status
    );
EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'ACCOUNTING_PERIOD_ALREADY_EXISTS';
END;
$$;

CREATE FUNCTION public.lock_accounting_period(
    p_period_id UUID,p_master_version BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_actor UUID := auth.uid();
    v_company UUID := public.private_active_company_id();
    v_period public.accounting_periods%ROWTYPE;
    v_before JSONB;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF NOT public.private_user_has_any_company_or_store_role(
        v_company,
        ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE']::TEXT[]
    ) THEN RAISE EXCEPTION 'FINANCE_PERIOD_LOCKER_REQUIRED'; END IF;

    SELECT * INTO v_period FROM public.accounting_periods period
    WHERE period.company_id = v_company AND period.id = p_period_id
    FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'ACCOUNTING_PERIOD_NOT_FOUND'; END IF;
    IF p_master_version IS NULL OR p_master_version <> v_period.master_version
    THEN RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
    IF v_period.status NOT IN ('OPEN','REOPENED') THEN
        RAISE EXCEPTION 'ACCOUNTING_PERIOD_NOT_OPEN';
    END IF;
    IF EXISTS (
        SELECT 1 FROM public.finance_journals journal
        WHERE journal.company_id = v_company
          AND journal.accounting_period_id = v_period.id
          AND journal.status = 'DRAFT'
    ) THEN RAISE EXCEPTION 'ACCOUNTING_PERIOD_HAS_DRAFT_JOURNAL'; END IF;
    IF EXISTS (
        SELECT 1 FROM public.financial_events event
        WHERE event.company_id = v_company
          AND event.event_date::DATE BETWEEN v_period.start_date AND v_period.end_date
          AND event.status::TEXT <> 'POSTED'
    ) THEN RAISE EXCEPTION 'ACCOUNTING_PERIOD_HAS_UNPOSTED_EVENT'; END IF;

    v_before := to_jsonb(v_period);
    UPDATE public.accounting_periods SET
        status = 'LOCKED',closed_by = v_actor,closed_at = clock_timestamp(),
        updated_by = v_actor
    WHERE company_id = v_company AND id = v_period.id
    RETURNING * INTO v_period;
    INSERT INTO public.finance_journal_audit(
        company_id,entity_type,entity_id,action,actor_id,
        before_state,after_state
    ) VALUES (
        v_company,'ACCOUNTING_PERIOD',v_period.id,'LOCK',v_actor,
        v_before,to_jsonb(v_period)
    );
    RETURN jsonb_build_object(
        'accountingPeriodId',v_period.id,
        'masterVersion',v_period.master_version,
        'status',v_period.status
    );
END;
$$;

CREATE FUNCTION public.reopen_accounting_period(
    p_period_id UUID,p_master_version BIGINT,p_reason TEXT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_actor UUID := auth.uid();
    v_company UUID := public.private_active_company_id();
    v_period public.accounting_periods%ROWTYPE;
    v_before JSONB;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF NOT public.private_user_has_any_company_or_store_role(
        v_company,ARRAY['COMPANY_OWNER','COMPANY_ADMIN']::TEXT[]
    ) THEN RAISE EXCEPTION 'ACCOUNTING_PERIOD_REOPEN_APPROVER_REQUIRED'; END IF;
    IF btrim(COALESCE(p_reason,'')) = '' THEN
        RAISE EXCEPTION 'REOPEN_REASON_REQUIRED';
    END IF;

    SELECT * INTO v_period FROM public.accounting_periods period
    WHERE period.company_id = v_company AND period.id = p_period_id
    FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'ACCOUNTING_PERIOD_NOT_FOUND'; END IF;
    IF p_master_version IS NULL OR p_master_version <> v_period.master_version
    THEN RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
    IF v_period.status <> 'LOCKED' THEN
        RAISE EXCEPTION 'ACCOUNTING_PERIOD_NOT_LOCKED';
    END IF;

    v_before := to_jsonb(v_period);
    UPDATE public.accounting_periods SET
        status = 'REOPENED',reopened_by = v_actor,
        reopened_at = clock_timestamp(),reopen_reason = btrim(p_reason),
        updated_by = v_actor
    WHERE company_id = v_company AND id = v_period.id
    RETURNING * INTO v_period;
    INSERT INTO public.finance_journal_audit(
        company_id,entity_type,entity_id,action,actor_id,
        before_state,after_state,reason
    ) VALUES (
        v_company,'ACCOUNTING_PERIOD',v_period.id,'REOPEN',v_actor,
        v_before,to_jsonb(v_period),btrim(p_reason)
    );
    RETURN jsonb_build_object(
        'accountingPeriodId',v_period.id,
        'masterVersion',v_period.master_version,
        'status',v_period.status
    );
END;
$$;

-- Replace the unknown partial period policy with the canonical Finance read.
DO $period_policy_reset$
DECLARE
    v_policy RECORD;
BEGIN
    FOR v_policy IN
        SELECT policyname FROM pg_policies
        WHERE schemaname = 'public' AND tablename = 'accounting_periods'
    LOOP
        EXECUTE format(
            'DROP POLICY %I ON public.accounting_periods',v_policy.policyname
        );
    END LOOP;
END
$period_policy_reset$;

ALTER TABLE public.accounting_periods ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.finance_journals ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.finance_journal_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.finance_journal_audit ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Accounting periods readable by Finance roles"
ON public.accounting_periods FOR SELECT TO authenticated
USING(public.private_finance_company_visible(company_id));
CREATE POLICY "Canonical journals readable by Finance roles"
ON public.finance_journals FOR SELECT TO authenticated
USING(public.private_finance_company_visible(company_id));
CREATE POLICY "Canonical journal lines readable by Finance roles"
ON public.finance_journal_lines FOR SELECT TO authenticated
USING(public.private_finance_company_visible(company_id));
CREATE POLICY "Canonical journal audit readable by Finance roles"
ON public.finance_journal_audit FOR SELECT TO authenticated
USING(public.private_finance_company_visible(company_id));

REVOKE ALL ON public.accounting_periods,public.journal_lines,
    public.finance_journals,public.finance_journal_lines,
    public.finance_journal_audit
FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.accounting_periods,public.finance_journals,
    public.finance_journal_lines,public.finance_journal_audit
TO authenticated;
GRANT ALL ON public.accounting_periods,public.journal_lines,
    public.finance_journals,public.finance_journal_lines,
    public.finance_journal_audit
TO service_role;
GRANT USAGE,SELECT ON SEQUENCE public.finance_journal_audit_id_seq
TO service_role;

REVOKE ALL ON FUNCTION
    private.trg_g6_touch_accounting_period(),
    private.trg_g6_guard_accounting_period_delete(),
    private.trg_g6_guard_finance_journal(),
    private.trg_g6_guard_finance_journal_line(),
    private.trg_g6_guard_finance_journal_audit()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
    private.trg_g6_touch_accounting_period(),
    private.trg_g6_guard_accounting_period_delete(),
    private.trg_g6_guard_finance_journal(),
    private.trg_g6_guard_finance_journal_line(),
    private.trg_g6_guard_finance_journal_audit()
TO service_role;

REVOKE ALL ON FUNCTION
    public.create_accounting_period(INTEGER,INTEGER),
    public.lock_accounting_period(UUID,BIGINT),
    public.reopen_accounting_period(UUID,BIGINT,TEXT)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION
    public.create_accounting_period(INTEGER,INTEGER),
    public.lock_accounting_period(UUID,BIGINT),
    public.reopen_accounting_period(UUID,BIGINT,TEXT)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES (
    '20260810180000',
    'g6_phase2_tenant_safe_journal_foundation',
    'Adopts valid monthly periods and creates additive canonical journal header/line/audit with tenant FKs, browser write closure, immutable posted history, balance/period guards, and guarded period lifecycle; no event posting or legacy journal mutation'
);

COMMIT;
