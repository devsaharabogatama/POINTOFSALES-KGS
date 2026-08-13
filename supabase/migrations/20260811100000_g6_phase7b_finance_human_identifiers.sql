-- G6 corrective phase 7B: persistent human-readable Finance identifiers.
-- UUID/FK/idempotency identities remain unchanged and server-only.

BEGIN;

DO $migration_guard$
BEGIN
    IF (
        SELECT count(*) FROM private.kgs_schema_migrations
        WHERE version='20260811090000'
    ) <> 1 THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: Phase 7A dependency missing';
    END IF;
    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version='20260811100000'
    ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: Phase 7B already applied';
    END IF;
    IF to_regclass('public.finance_journals') IS NULL
       OR to_regclass('public.finance_posting_queue_runs') IS NULL
       OR to_regclass('public.finance_posting_exceptions') IS NULL
       OR to_regclass('public.finance_reconciliation_documents') IS NULL THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: canonical Finance relations missing';
    END IF;
END
$migration_guard$;

CREATE TABLE private.finance_document_number_counters (
    company_id UUID NOT NULL
        REFERENCES public.companies(id) ON DELETE RESTRICT,
    document_prefix TEXT NOT NULL,
    period_year INTEGER NOT NULL,
    period_month INTEGER NOT NULL,
    last_value BIGINT NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY(company_id,document_prefix,period_year,period_month),
    CONSTRAINT finance_document_counter_prefix_check CHECK (
        document_prefix IN ('JUR','JRB','PST','EXC','REC')
    ),
    CONSTRAINT finance_document_counter_period_check CHECK (
        period_year BETWEEN 2000 AND 9999
        AND period_month BETWEEN 1 AND 12
    ),
    CONSTRAINT finance_document_counter_value_check CHECK(last_value > 0)
);

REVOKE ALL ON private.finance_document_number_counters
FROM PUBLIC,anon,authenticated;
GRANT ALL ON private.finance_document_number_counters TO service_role;

CREATE FUNCTION private.next_finance_display_no(
    p_company_id UUID,p_prefix TEXT,p_document_date DATE
) RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,private,pg_temp
AS $$
DECLARE
    v_year INTEGER;
    v_month INTEGER;
    v_value BIGINT;
BEGIN
    IF p_company_id IS NULL OR p_document_date IS NULL
       OR p_prefix NOT IN ('JUR','JRB','PST','EXC','REC') THEN
        RAISE EXCEPTION 'FINANCE_DISPLAY_NUMBER_INPUT_INVALID';
    END IF;
    v_year:=extract(year FROM p_document_date)::INTEGER;
    v_month:=extract(month FROM p_document_date)::INTEGER;
    INSERT INTO private.finance_document_number_counters AS counter(
        company_id,document_prefix,period_year,period_month,last_value
    ) VALUES(p_company_id,p_prefix,v_year,v_month,1)
    ON CONFLICT(company_id,document_prefix,period_year,period_month)
    DO UPDATE SET
        last_value=counter.last_value+1,
        updated_at=clock_timestamp()
    RETURNING last_value INTO v_value;
    RETURN p_prefix || '/' || v_year::TEXT || '/'
        || lpad(v_month::TEXT,2,'0') || '/'
        || lpad(v_value::TEXT,6,'0');
END;
$$;

ALTER TABLE public.finance_journals ADD COLUMN display_no TEXT;
ALTER TABLE public.finance_posting_queue_runs ADD COLUMN display_no TEXT;
ALTER TABLE public.finance_posting_exceptions ADD COLUMN display_no TEXT;

ALTER TABLE public.finance_journals
    DISABLE TRIGGER g6_guard_finance_journal;
WITH ranked AS (
    SELECT
        journal.id,
        CASE WHEN journal.journal_type='REVERSAL' THEN 'JRB' ELSE 'JUR' END
            AS prefix,
        journal.accounting_date AS document_date,
        row_number() OVER(
            PARTITION BY journal.company_id,
                CASE WHEN journal.journal_type='REVERSAL'
                    THEN 'JRB' ELSE 'JUR' END,
                extract(year FROM journal.accounting_date),
                extract(month FROM journal.accounting_date)
            ORDER BY journal.accounting_date,journal.created_at,journal.id
        ) AS sequence_no
    FROM public.finance_journals journal
)
UPDATE public.finance_journals journal SET display_no=
    ranked.prefix || '/' || extract(year FROM ranked.document_date)::INTEGER
        || '/' || lpad(
            extract(month FROM ranked.document_date)::INTEGER::TEXT,2,'0'
        ) || '/' || lpad(ranked.sequence_no::TEXT,6,'0')
FROM ranked WHERE ranked.id=journal.id;
ALTER TABLE public.finance_journals
    ENABLE TRIGGER g6_guard_finance_journal;

ALTER TABLE public.finance_posting_queue_runs
    DISABLE TRIGGER g6_touch_posting_queue_run;
WITH ranked AS (
    SELECT
        run.id,run.created_at::DATE AS document_date,
        row_number() OVER(
            PARTITION BY run.company_id,
                extract(year FROM run.created_at),
                extract(month FROM run.created_at)
            ORDER BY run.created_at,run.id
        ) AS sequence_no
    FROM public.finance_posting_queue_runs run
)
UPDATE public.finance_posting_queue_runs run SET display_no=
    'PST/' || extract(year FROM ranked.document_date)::INTEGER
        || '/' || lpad(
            extract(month FROM ranked.document_date)::INTEGER::TEXT,2,'0'
        ) || '/' || lpad(ranked.sequence_no::TEXT,6,'0')
FROM ranked WHERE ranked.id=run.id;
ALTER TABLE public.finance_posting_queue_runs
    ENABLE TRIGGER g6_touch_posting_queue_run;

WITH ranked AS (
    SELECT
        exception.id,exception.created_at::DATE AS document_date,
        row_number() OVER(
            PARTITION BY exception.company_id,
                extract(year FROM exception.created_at),
                extract(month FROM exception.created_at)
            ORDER BY exception.created_at,exception.id
        ) AS sequence_no
    FROM public.finance_posting_exceptions exception
)
UPDATE public.finance_posting_exceptions exception SET display_no=
    'EXC/' || extract(year FROM ranked.document_date)::INTEGER
        || '/' || lpad(
            extract(month FROM ranked.document_date)::INTEGER::TEXT,2,'0'
        ) || '/' || lpad(ranked.sequence_no::TEXT,6,'0')
FROM ranked WHERE ranked.id=exception.id;

ALTER TABLE public.finance_reconciliation_documents
    DISABLE TRIGGER g6_guard_reconciliation_document;
ALTER TABLE public.finance_reconciliation_documents
    DISABLE TRIGGER g6_audit_reconciliation_document;
WITH ranked AS (
    SELECT
        document.id,document.as_of_date AS document_date,
        row_number() OVER(
            PARTITION BY document.company_id,
                extract(year FROM document.as_of_date),
                extract(month FROM document.as_of_date)
            ORDER BY document.as_of_date,document.created_at,document.id
        ) AS sequence_no
    FROM public.finance_reconciliation_documents document
)
UPDATE public.finance_reconciliation_documents document
SET reconciliation_no=
    'REC/' || extract(year FROM ranked.document_date)::INTEGER
        || '/' || lpad(
            extract(month FROM ranked.document_date)::INTEGER::TEXT,2,'0'
        ) || '/' || lpad(ranked.sequence_no::TEXT,6,'0')
FROM ranked WHERE ranked.id=document.id;
ALTER TABLE public.finance_reconciliation_documents
    ENABLE TRIGGER g6_guard_reconciliation_document;
ALTER TABLE public.finance_reconciliation_documents
    ENABLE TRIGGER g6_audit_reconciliation_document;

INSERT INTO private.finance_document_number_counters(
    company_id,document_prefix,period_year,period_month,last_value
)
SELECT
    source.company_id,source.prefix,source.period_year,source.period_month,
    max(source.sequence_no)
FROM (
    SELECT
        journal.company_id,
        split_part(journal.display_no,'/',1) AS prefix,
        split_part(journal.display_no,'/',2)::INTEGER AS period_year,
        split_part(journal.display_no,'/',3)::INTEGER AS period_month,
        split_part(journal.display_no,'/',4)::BIGINT AS sequence_no
    FROM public.finance_journals journal
    UNION ALL
    SELECT
        run.company_id,split_part(run.display_no,'/',1),
        split_part(run.display_no,'/',2)::INTEGER,
        split_part(run.display_no,'/',3)::INTEGER,
        split_part(run.display_no,'/',4)::BIGINT
    FROM public.finance_posting_queue_runs run
    UNION ALL
    SELECT
        exception.company_id,split_part(exception.display_no,'/',1),
        split_part(exception.display_no,'/',2)::INTEGER,
        split_part(exception.display_no,'/',3)::INTEGER,
        split_part(exception.display_no,'/',4)::BIGINT
    FROM public.finance_posting_exceptions exception
    UNION ALL
    SELECT
        document.company_id,split_part(document.reconciliation_no,'/',1),
        split_part(document.reconciliation_no,'/',2)::INTEGER,
        split_part(document.reconciliation_no,'/',3)::INTEGER,
        split_part(document.reconciliation_no,'/',4)::BIGINT
    FROM public.finance_reconciliation_documents document
) source
GROUP BY source.company_id,source.prefix,source.period_year,source.period_month;

CREATE FUNCTION private.trg_g6_assign_finance_display_no()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,private,pg_temp
AS $$
DECLARE
    v_prefix TEXT;
    v_date DATE;
BEGIN
    IF TG_TABLE_NAME='finance_journals' THEN
        v_prefix:=CASE WHEN NEW.journal_type='REVERSAL'
            THEN 'JRB' ELSE 'JUR' END;
        v_date:=NEW.accounting_date;
    ELSIF TG_TABLE_NAME='finance_posting_queue_runs' THEN
        v_prefix:='PST';
        v_date:=COALESCE(NEW.created_at,clock_timestamp())::DATE;
    ELSIF TG_TABLE_NAME='finance_posting_exceptions' THEN
        v_prefix:='EXC';
        v_date:=COALESCE(NEW.created_at,clock_timestamp())::DATE;
    ELSIF TG_TABLE_NAME='finance_reconciliation_documents' THEN
        v_prefix:='REC';
        v_date:=NEW.as_of_date;
    ELSE
        RAISE EXCEPTION 'FINANCE_DISPLAY_NUMBER_TARGET_INVALID';
    END IF;
    IF TG_TABLE_NAME='finance_reconciliation_documents' THEN
        NEW.reconciliation_no:=private.next_finance_display_no(
            NEW.company_id,v_prefix,v_date
        );
    ELSE
        NEW.display_no:=private.next_finance_display_no(
            NEW.company_id,v_prefix,v_date
        );
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER a_g6_assign_finance_journal_display_no
BEFORE INSERT ON public.finance_journals
FOR EACH ROW EXECUTE FUNCTION private.trg_g6_assign_finance_display_no();
CREATE TRIGGER a_g6_assign_finance_queue_display_no
BEFORE INSERT ON public.finance_posting_queue_runs
FOR EACH ROW EXECUTE FUNCTION private.trg_g6_assign_finance_display_no();
CREATE TRIGGER a_g6_assign_finance_exception_display_no
BEFORE INSERT ON public.finance_posting_exceptions
FOR EACH ROW EXECUTE FUNCTION private.trg_g6_assign_finance_display_no();
CREATE TRIGGER a_g6_assign_finance_reconciliation_no
BEFORE INSERT ON public.finance_reconciliation_documents
FOR EACH ROW EXECUTE FUNCTION private.trg_g6_assign_finance_display_no();

ALTER TABLE public.finance_journals
    ALTER COLUMN display_no SET NOT NULL,
    ADD CONSTRAINT finance_journals_display_no_check CHECK(
        display_no ~ '^(JUR|JRB)/[0-9]{4}/[0-9]{2}/[0-9]{6}$'
    ),
    ADD CONSTRAINT finance_journals_company_display_no_unique
        UNIQUE(company_id,display_no);
ALTER TABLE public.finance_posting_queue_runs
    ALTER COLUMN display_no SET NOT NULL,
    ADD CONSTRAINT finance_queue_display_no_check CHECK(
        display_no ~ '^PST/[0-9]{4}/[0-9]{2}/[0-9]{6}$'
    ),
    ADD CONSTRAINT finance_queue_company_display_no_unique
        UNIQUE(company_id,display_no);
ALTER TABLE public.finance_posting_exceptions
    ALTER COLUMN display_no SET NOT NULL,
    ADD CONSTRAINT finance_exception_display_no_check CHECK(
        display_no ~ '^EXC/[0-9]{4}/[0-9]{2}/[0-9]{6}$'
    ),
    ADD CONSTRAINT finance_exception_company_display_no_unique
        UNIQUE(company_id,display_no);
ALTER TABLE public.finance_reconciliation_documents
    ADD CONSTRAINT finance_reconciliation_no_format_check CHECK(
        reconciliation_no ~ '^REC/[0-9]{4}/[0-9]{2}/[0-9]{6}$'
    );

REVOKE ALL ON FUNCTION private.next_finance_display_no(UUID,TEXT,DATE),
    private.trg_g6_assign_finance_display_no()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.next_finance_display_no(UUID,TEXT,DATE),
    private.trg_g6_assign_finance_display_no()
TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES(
    '20260811100000','g6_phase7b_finance_human_identifiers',
    'Persistent tenant/month-scoped JUR/JRB/PST/EXC/REC display numbers; UUID and immutable canonical identity remain unchanged.'
);

COMMIT;
