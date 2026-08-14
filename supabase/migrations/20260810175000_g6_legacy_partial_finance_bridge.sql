-- Fresh-install bridge for two audited partial Finance relations that existed
-- before the canonical migration ledger. On established databases both
-- relations already exist, so every statement below is intentionally a no-op.

BEGIN;

CREATE TABLE IF NOT EXISTS public.accounting_periods (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL
        REFERENCES public.companies(id) ON DELETE RESTRICT,
    period_year INTEGER NOT NULL,
    period_month INTEGER NOT NULL,
    start_date DATE NOT NULL,
    end_date DATE NOT NULL,
    status TEXT NOT NULL DEFAULT 'OPEN',
    closed_by UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
    closed_at TIMESTAMPTZ,
    reopened_by UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
    reopened_at TIMESTAMPTZ,
    reopen_reason TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT accounting_periods_company_month_unique
        UNIQUE(company_id,period_year,period_month),
    CONSTRAINT accounting_periods_year_check
        CHECK(period_year BETWEEN 2000 AND 9999),
    CONSTRAINT accounting_periods_month_check
        CHECK(period_month BETWEEN 1 AND 12),
    CONSTRAINT accounting_periods_date_order_check
        CHECK(end_date >= start_date),
    CONSTRAINT accounting_periods_legacy_status_check
        CHECK(status IN ('OPEN','LOCKED','REOPENED'))
);

-- This is the rejected legacy detail relation. G6 Phase 2 deliberately keeps
-- it separate from finance_journal_lines and requires it to be empty.
CREATE TABLE IF NOT EXISTS public.journal_lines (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL
        REFERENCES public.companies(id) ON DELETE RESTRICT,
    journal_entry_id UUID NOT NULL
        REFERENCES public.journal_entries(id) ON DELETE RESTRICT,
    line_no INTEGER NOT NULL,
    account_id UUID NOT NULL
        REFERENCES public.chart_of_accounts(id) ON DELETE RESTRICT,
    account_code_snapshot TEXT NOT NULL,
    account_name_snapshot TEXT NOT NULL,
    debit NUMERIC(20,4) NOT NULL DEFAULT 0,
    credit NUMERIC(20,4) NOT NULL DEFAULT 0,
    description TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT journal_lines_journal_line_unique
        UNIQUE(journal_entry_id,line_no),
    CONSTRAINT journal_lines_line_no_positive CHECK(line_no > 0),
    CONSTRAINT journal_lines_account_code_not_blank
        CHECK(btrim(account_code_snapshot) <> ''),
    CONSTRAINT journal_lines_account_name_not_blank
        CHECK(btrim(account_name_snapshot) <> ''),
    CONSTRAINT journal_lines_amount_nonnegative
        CHECK(debit >= 0 AND credit >= 0),
    CONSTRAINT journal_lines_one_sided_amount
        CHECK((debit > 0 AND credit = 0) OR (credit > 0 AND debit = 0))
);

ALTER TABLE public.accounting_periods ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.journal_lines ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.accounting_periods,public.journal_lines
FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.accounting_periods,public.journal_lines TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES (
    '20260810175000',
    'g6_legacy_partial_finance_bridge',
    'Fresh-install-only bridge for pre-ledger accounting_periods and rejected journal_lines; established databases remain unchanged'
)
ON CONFLICT(version) DO NOTHING;

COMMIT;
