-- KGS POS G1 phase 5D: Finance tenant topology and read-only browser RLS.
-- Requirement: TEN-001, TEN-002
-- Dependency: 20260721090000_g1_phase5c_transaction_rls.sql
--
-- cash_advances is preserved as a legacy table name. Its canonical replacement
-- is Expense in a later gate. Financial Event, Journal, and Reconciliation are
-- immutable from browser roles and remain worker/workflow-owned.

BEGIN;

DO $migration_guard$
BEGIN
    IF to_regclass('private.kgs_schema_migrations') IS NULL
       OR NOT EXISTS (
           SELECT 1 FROM private.kgs_schema_migrations
           WHERE version = '20260721090000'
       ) THEN
        RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: G1 phase 5C not recorded';
    END IF;

    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260721120000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260721120000';
    END IF;
END
$migration_guard$;

DO $finance_preflight$
DECLARE
    v_violations BIGINT;
BEGIN
    SELECT count(*) INTO v_violations
    FROM (
        SELECT id FROM public.cash_advances
        WHERE company_id IS NULL OR store_id IS NULL
        UNION ALL
        SELECT id FROM public.bank_deposits
        WHERE company_id IS NULL OR store_id IS NULL
        UNION ALL
        SELECT id FROM public.financial_events WHERE company_id IS NULL
        UNION ALL
        SELECT id FROM public.journal_entries WHERE company_id IS NULL
        UNION ALL
        SELECT id FROM public.pos_reconciliations WHERE company_id IS NULL

        UNION ALL

        SELECT c.id
        FROM public.cash_advances c
        JOIN public.cashier_sessions s ON s.id = c.session_id
        WHERE c.company_id IS DISTINCT FROM s.company_id
           OR c.store_id IS DISTINCT FROM s.store_id

        UNION ALL

        SELECT d.id
        FROM public.bank_deposits d
        JOIN public.cashier_sessions s ON s.id = d.session_id
        WHERE d.company_id IS DISTINCT FROM s.company_id
           OR d.store_id IS DISTINCT FROM s.store_id

        UNION ALL

        SELECT e.id
        FROM public.financial_events e
        JOIN public.sales_headers s ON s.id = e.root_sales_id
        WHERE e.company_id IS DISTINCT FROM s.company_id
           OR e.store_id IS DISTINCT FROM s.store_id

        UNION ALL

        SELECT e.id
        FROM public.financial_events e
        JOIN public.stores s ON s.id = e.store_id
        WHERE e.company_id IS DISTINCT FROM s.company_id

        UNION ALL

        SELECT j.id
        FROM public.journal_entries j
        JOIN public.financial_events e ON e.id = j.financial_event_id
        WHERE j.company_id IS DISTINCT FROM e.company_id

        UNION ALL

        SELECT j.id
        FROM public.journal_entries j
        JOIN public.financial_events e ON e.id = j.reversal_of_event_id
        WHERE j.company_id IS DISTINCT FROM e.company_id

        UNION ALL

        SELECT j.id
        FROM public.journal_entries j
        JOIN public.stores s ON s.id = j.store_id
        WHERE j.company_id IS DISTINCT FROM s.company_id

        UNION ALL

        SELECT r.id
        FROM public.pos_reconciliations r
        JOIN public.sales_headers s ON s.id = r.sales_id
        WHERE r.company_id IS DISTINCT FROM s.company_id
    ) violations;

    IF v_violations > 0 THEN
        RAISE EXCEPTION 'G1_PHASE5D_FINANCE_PRECONDITION_FAILED: % violation(s)',v_violations;
    END IF;

    IF EXISTS (
        SELECT 1
        FROM public.journal_entries
        GROUP BY company_id,entry_group_id
        HAVING COALESCE(sum(debit),0) <> COALESCE(sum(kredit),0)
    ) THEN
        RAISE EXCEPTION 'G1_PHASE5D_UNBALANCED_JOURNAL_PRECONDITION_FAILED';
    END IF;
END
$finance_preflight$;

ALTER TABLE public.cash_advances
    ALTER COLUMN company_id SET NOT NULL,
    ALTER COLUMN store_id SET NOT NULL;
ALTER TABLE public.bank_deposits
    ALTER COLUMN company_id SET NOT NULL,
    ALTER COLUMN store_id SET NOT NULL;
ALTER TABLE public.financial_events ALTER COLUMN company_id SET NOT NULL;
ALTER TABLE public.journal_entries ALTER COLUMN company_id SET NOT NULL;
ALTER TABLE public.pos_reconciliations ALTER COLUMN company_id SET NOT NULL;

-- Composite parent identities.
ALTER TABLE public.cashier_sessions
    ADD CONSTRAINT uq_cashier_sessions_company_store_id
    UNIQUE(company_id,store_id,id);
ALTER TABLE public.financial_events
    ADD CONSTRAINT uq_financial_events_company_id_id
    UNIQUE(company_id,id);
ALTER TABLE public.sales_headers
    ADD CONSTRAINT uq_sales_headers_company_store_id
    UNIQUE(company_id,store_id,id);

-- Tenant-safe source topology. Existing single-ID FKs remain for compatibility.
ALTER TABLE public.cash_advances
    ADD CONSTRAINT fk_cash_advances_company_store_session
    FOREIGN KEY(company_id,store_id,session_id)
    REFERENCES public.cashier_sessions(company_id,store_id,id)
    NOT VALID;
ALTER TABLE public.bank_deposits
    ADD CONSTRAINT fk_bank_deposits_company_store_session
    FOREIGN KEY(company_id,store_id,session_id)
    REFERENCES public.cashier_sessions(company_id,store_id,id)
    NOT VALID;
ALTER TABLE public.financial_events
    ADD CONSTRAINT fk_financial_events_company_store_root_sales
    FOREIGN KEY(company_id,store_id,root_sales_id)
    REFERENCES public.sales_headers(company_id,store_id,id)
    ON DELETE SET NULL (root_sales_id)
    NOT VALID,
    ADD CONSTRAINT fk_financial_events_company_store
    FOREIGN KEY(company_id,store_id)
    REFERENCES public.stores(company_id,id)
    NOT VALID;
ALTER TABLE public.journal_entries
    ADD CONSTRAINT fk_journal_entries_company_event
    FOREIGN KEY(company_id,financial_event_id)
    REFERENCES public.financial_events(company_id,id)
    ON DELETE CASCADE
    NOT VALID,
    ADD CONSTRAINT fk_journal_entries_company_reversal_event
    FOREIGN KEY(company_id,reversal_of_event_id)
    REFERENCES public.financial_events(company_id,id)
    ON DELETE SET NULL (reversal_of_event_id)
    NOT VALID,
    ADD CONSTRAINT fk_journal_entries_company_store
    FOREIGN KEY(company_id,store_id)
    REFERENCES public.stores(company_id,id)
    NOT VALID;
ALTER TABLE public.pos_reconciliations
    ADD CONSTRAINT fk_pos_reconciliations_company_sales
    FOREIGN KEY(company_id,sales_id)
    REFERENCES public.sales_headers(company_id,id)
    ON DELETE CASCADE
    NOT VALID;

DO $validate_constraints$
DECLARE
    r RECORD;
BEGIN
    FOR r IN
        SELECT * FROM (VALUES
            ('cash_advances','fk_cash_advances_company_store_session'),
            ('bank_deposits','fk_bank_deposits_company_store_session'),
            ('financial_events','fk_financial_events_company_store_root_sales'),
            ('financial_events','fk_financial_events_company_store'),
            ('journal_entries','fk_journal_entries_company_event'),
            ('journal_entries','fk_journal_entries_company_reversal_event'),
            ('journal_entries','fk_journal_entries_company_store'),
            ('pos_reconciliations','fk_pos_reconciliations_company_sales')
        ) v(table_name,constraint_name)
    LOOP
        EXECUTE format(
            'ALTER TABLE public.%I VALIDATE CONSTRAINT %I',
            r.table_name,r.constraint_name
        );
    END LOOP;
END
$validate_constraints$;

CREATE INDEX idx_cash_advances_company_store_session_fk
    ON public.cash_advances(company_id,store_id,session_id);
CREATE INDEX idx_bank_deposits_company_store_session_fk
    ON public.bank_deposits(company_id,store_id,session_id);
CREATE INDEX idx_financial_events_company_root_sales_fk
    ON public.financial_events(company_id,root_sales_id)
    WHERE root_sales_id IS NOT NULL;
CREATE INDEX idx_financial_events_company_store_fk
    ON public.financial_events(company_id,store_id)
    WHERE store_id IS NOT NULL;
CREATE INDEX idx_journal_entries_company_event_fk
    ON public.journal_entries(company_id,financial_event_id)
    WHERE financial_event_id IS NOT NULL;
CREATE INDEX idx_journal_entries_company_reversal_event_fk
    ON public.journal_entries(company_id,reversal_of_event_id)
    WHERE reversal_of_event_id IS NOT NULL;
CREATE INDEX idx_journal_entries_company_store_fk
    ON public.journal_entries(company_id,store_id)
    WHERE store_id IS NOT NULL;

CREATE OR REPLACE FUNCTION public.private_finance_company_visible(
    p_company_id UUID
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT public.private_request_company_matches(p_company_id)
       AND public.private_user_has_any_company_role(
           p_company_id,
           ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE','ACCOUNTING']::TEXT[]
       );
$$;

DO $drop_finance_policies$
DECLARE
    r RECORD;
BEGIN
    FOR r IN
        SELECT tablename,policyname
        FROM pg_policies
        WHERE schemaname = 'public'
          AND tablename = ANY(ARRAY[
              'cash_advances','bank_deposits','financial_events',
              'journal_entries','pos_reconciliations'
          ])
    LOOP
        EXECUTE format('DROP POLICY %I ON public.%I',r.policyname,r.tablename);
    END LOOP;
END
$drop_finance_policies$;

ALTER TABLE public.cash_advances ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bank_deposits ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.financial_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.journal_entries ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pos_reconciliations ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Legacy expenses readable by creator or authorized reviewers"
ON public.cash_advances FOR SELECT TO authenticated
USING (
    public.private_request_company_matches(company_id)
    AND (
        created_by = auth.uid()
        OR public.private_finance_company_visible(company_id)
        OR public.private_user_has_any_store_role(
            store_id,ARRAY['STORE_MANAGER']::TEXT[]
        )
    )
);

CREATE POLICY "Bank deposits readable by creator or authorized reviewers"
ON public.bank_deposits FOR SELECT TO authenticated
USING (
    public.private_request_company_matches(company_id)
    AND (
        created_by = auth.uid()
        OR public.private_finance_company_visible(company_id)
        OR public.private_user_has_any_store_role(
            store_id,ARRAY['STORE_MANAGER']::TEXT[]
        )
    )
);

CREATE POLICY "Financial events readable by Finance roles"
ON public.financial_events FOR SELECT TO authenticated
USING (public.private_finance_company_visible(company_id));

CREATE POLICY "Journal entries readable by Finance roles"
ON public.journal_entries FOR SELECT TO authenticated
USING (public.private_finance_company_visible(company_id));

CREATE POLICY "POS reconciliations readable by Finance roles"
ON public.pos_reconciliations FOR SELECT TO authenticated
USING (public.private_finance_company_visible(company_id));

-- No browser mutation for Finance source/ledger tables in G1.
REVOKE ALL ON public.cash_advances, public.bank_deposits,
    public.financial_events, public.journal_entries,
    public.pos_reconciliations
FROM PUBLIC, anon, authenticated;

GRANT SELECT ON public.cash_advances, public.bank_deposits,
    public.financial_events, public.journal_entries,
    public.pos_reconciliations
TO authenticated;

GRANT ALL ON public.cash_advances, public.bank_deposits,
    public.financial_events, public.journal_entries,
    public.pos_reconciliations
TO service_role;

REVOKE ALL ON FUNCTION public.private_finance_company_visible(UUID)
FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.private_finance_company_visible(UUID)
TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.process_financial_events_queue()
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.process_financial_events_queue()
TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES (
    '20260721120000',
    'g1_phase5d_finance_rls',
    'TEN-001/TEN-002 Finance tenant topology, scoped reads, immutable browser ledger, service-role worker boundary'
);

NOTIFY pgrst, 'reload schema';

COMMIT;
