-- G6 corrective phase 6C: POSTED statements, pending analysis, reconciliation.
-- Remaining Financial Events stay HOLD. No journal, adjustment, or queue run.

BEGIN;

DO $guard$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version='20260810220000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: G6 phase 6A required';
    END IF;
    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version='20260810230000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260810230000';
    END IF;
    IF to_regclass('public.finance_reconciliation_documents') IS NOT NULL
       OR to_regclass('public.finance_reconciliation_allocations') IS NOT NULL
       OR to_regclass('public.finance_reconciliation_audit') IS NOT NULL
       OR to_regprocedure('public.get_finance_income_statement(date,date,uuid,uuid)') IS NOT NULL
       OR to_regprocedure('public.get_finance_balance_sheet(date,uuid,uuid)') IS NOT NULL
       OR to_regprocedure('public.get_finance_pending_analysis(date,date,integer,integer)') IS NOT NULL
       OR to_regprocedure('public.get_finance_reconciliation_summary(date)') IS NOT NULL
    THEN
        RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Phase 6C target exists';
    END IF;
END
$guard$;

ALTER TABLE public.finance_report_versions
    ADD CONSTRAINT finance_report_versions_company_definition_id_unique
    UNIQUE(company_id,report_definition_id,id);

CREATE TABLE public.finance_reconciliation_documents (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
    reconciliation_no TEXT NOT NULL,
    reconciliation_type TEXT NOT NULL,
    as_of_date DATE NOT NULL,
    report_definition_id UUID NOT NULL,
    report_version_id UUID NOT NULL,
    account_id UUID,
    status TEXT NOT NULL DEFAULT 'DRAFT',
    subledger_balance NUMERIC(24,4) NOT NULL,
    ledger_balance NUMERIC(24,4) NOT NULL,
    difference NUMERIC(24,4) NOT NULL,
    filter_snapshot JSONB NOT NULL DEFAULT '{}'::JSONB,
    notes TEXT,
    master_version BIGINT NOT NULL DEFAULT 1,
    created_by UUID NOT NULL REFERENCES public.profiles(id),
    finalized_by UUID REFERENCES public.profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    finalized_at TIMESTAMPTZ,
    CONSTRAINT finance_reconciliation_documents_company_id_id_unique
        UNIQUE(company_id,id),
    CONSTRAINT finance_reconciliation_documents_company_no_unique
        UNIQUE(company_id,reconciliation_no),
    CONSTRAINT finance_reconciliation_documents_identity_check CHECK(
        btrim(reconciliation_no)<>''
    ),
    CONSTRAINT finance_reconciliation_documents_type_check CHECK(
        reconciliation_type IN(
            'STOCK_FIFO_GL','SUPPLIER_AP_GL','CUSTOMER_BALANCE_GL','CASH_BANK_GL'
        )
    ),
    CONSTRAINT finance_reconciliation_documents_status_check CHECK(
        status IN('DRAFT','FINALIZED')
    ),
    CONSTRAINT finance_reconciliation_documents_difference_check CHECK(
        difference=round(subledger_balance-ledger_balance,4)
    ),
    CONSTRAINT finance_reconciliation_documents_filter_check CHECK(
        jsonb_typeof(filter_snapshot)='object'
    ),
    CONSTRAINT finance_reconciliation_documents_version_check CHECK(
        master_version>0
    ),
    CONSTRAINT finance_reconciliation_documents_final_check CHECK(
        status<>'FINALIZED'
        OR (finalized_by IS NOT NULL AND finalized_at IS NOT NULL)
    ),
    CONSTRAINT fk_finance_reconciliation_definition
        FOREIGN KEY(company_id,report_definition_id)
        REFERENCES public.finance_report_definitions(company_id,id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_finance_reconciliation_version
        FOREIGN KEY(company_id,report_definition_id,report_version_id)
        REFERENCES public.finance_report_versions(
            company_id,report_definition_id,id
        )
        ON DELETE RESTRICT,
    CONSTRAINT fk_finance_reconciliation_account
        FOREIGN KEY(company_id,account_id)
        REFERENCES public.chart_of_accounts(company_id,id)
        ON DELETE RESTRICT
);

CREATE TABLE public.finance_reconciliation_allocations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL,
    reconciliation_document_id UUID NOT NULL,
    line_no INTEGER NOT NULL,
    source_type TEXT NOT NULL,
    source_id UUID NOT NULL,
    journal_line_id UUID,
    allocation_status TEXT NOT NULL,
    subledger_amount NUMERIC(24,4) NOT NULL,
    ledger_amount NUMERIC(24,4) NOT NULL,
    difference NUMERIC(24,4) NOT NULL,
    notes TEXT,
    created_by UUID NOT NULL REFERENCES public.profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT finance_reconciliation_allocations_company_id_id_unique
        UNIQUE(company_id,id),
    CONSTRAINT finance_reconciliation_allocations_line_unique
        UNIQUE(company_id,reconciliation_document_id,line_no),
    CONSTRAINT finance_reconciliation_allocations_line_positive CHECK(line_no>0),
    CONSTRAINT finance_reconciliation_allocations_source_check CHECK(
        btrim(source_type)<>''
    ),
    CONSTRAINT finance_reconciliation_allocations_status_check CHECK(
        allocation_status IN('MATCHED','PARTIAL','UNMATCHED','EXCEPTION')
    ),
    CONSTRAINT finance_reconciliation_allocations_difference_check CHECK(
        difference=round(subledger_amount-ledger_amount,4)
    ),
    CONSTRAINT fk_finance_reconciliation_allocation_document
        FOREIGN KEY(company_id,reconciliation_document_id)
        REFERENCES public.finance_reconciliation_documents(company_id,id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_finance_reconciliation_allocation_journal_line
        FOREIGN KEY(company_id,journal_line_id)
        REFERENCES public.finance_journal_lines(company_id,id)
        ON DELETE RESTRICT
);

CREATE TABLE public.finance_reconciliation_audit (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_id UUID NOT NULL,
    reconciliation_document_id UUID NOT NULL,
    action TEXT NOT NULL CHECK(action IN(
        'DOCUMENT_CREATE','DOCUMENT_FINALIZE','ALLOCATION_CREATE'
    )),
    actor_id UUID NOT NULL REFERENCES public.profiles(id),
    before_state JSONB,
    after_state JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT fk_finance_reconciliation_audit_document
        FOREIGN KEY(company_id,reconciliation_document_id)
        REFERENCES public.finance_reconciliation_documents(company_id,id)
        ON DELETE RESTRICT
);

CREATE INDEX idx_finance_reconciliation_documents_company_as_of
    ON public.finance_reconciliation_documents(
        company_id,reconciliation_type,as_of_date,status
    );
CREATE INDEX idx_finance_reconciliation_allocations_document
    ON public.finance_reconciliation_allocations(
        company_id,reconciliation_document_id,line_no
    );
CREATE INDEX idx_finance_reconciliation_audit_document
    ON public.finance_reconciliation_audit(
        company_id,reconciliation_document_id,created_at,id
    );

CREATE FUNCTION private.trg_g6_guard_reconciliation_document()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
BEGIN
    IF TG_OP='DELETE' THEN
        RAISE EXCEPTION 'FINANCE_RECONCILIATION_DELETE_FORBIDDEN';
    END IF;
    IF OLD.status<>'DRAFT' THEN
        RAISE EXCEPTION 'FINAL_RECONCILIATION_IMMUTABLE';
    END IF;
    IF NEW.id IS DISTINCT FROM OLD.id
       OR NEW.company_id IS DISTINCT FROM OLD.company_id
       OR NEW.reconciliation_no IS DISTINCT FROM OLD.reconciliation_no
       OR NEW.reconciliation_type IS DISTINCT FROM OLD.reconciliation_type
       OR NEW.as_of_date IS DISTINCT FROM OLD.as_of_date
       OR NEW.report_definition_id IS DISTINCT FROM OLD.report_definition_id
       OR NEW.report_version_id IS DISTINCT FROM OLD.report_version_id
       OR NEW.account_id IS DISTINCT FROM OLD.account_id
    THEN
        RAISE EXCEPTION 'FINANCE_RECONCILIATION_IDENTITY_IMMUTABLE';
    END IF;
    NEW.master_version:=OLD.master_version+1;
    IF NEW.status='FINALIZED' THEN
        NEW.finalized_at:=COALESCE(NEW.finalized_at,clock_timestamp());
    ELSIF NEW.status<>'DRAFT' THEN
        RAISE EXCEPTION 'INVALID_RECONCILIATION_TRANSITION';
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION private.trg_g6_guard_reconciliation_allocation()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_status TEXT;
BEGIN
    IF TG_OP='DELETE' THEN
        RAISE EXCEPTION 'FINANCE_RECONCILIATION_ALLOCATION_DELETE_FORBIDDEN';
    END IF;
    IF TG_OP='UPDATE' THEN
        RAISE EXCEPTION 'FINANCE_RECONCILIATION_ALLOCATION_IMMUTABLE';
    END IF;
    SELECT document.status INTO v_status
    FROM public.finance_reconciliation_documents document
    WHERE document.company_id=NEW.company_id
      AND document.id=NEW.reconciliation_document_id
    FOR SHARE;
    IF v_status IS NULL THEN RAISE EXCEPTION 'RECONCILIATION_DOCUMENT_NOT_FOUND'; END IF;
    IF v_status<>'DRAFT' THEN RAISE EXCEPTION 'FINAL_RECONCILIATION_IMMUTABLE'; END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION private.trg_g6_audit_reconciliation_document()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_action TEXT; v_actor UUID;
BEGIN
    IF TG_OP='INSERT' THEN
        v_action:='DOCUMENT_CREATE';
        v_actor:=NEW.created_by;
    ELSIF NEW.status='FINALIZED' AND OLD.status<>'FINALIZED' THEN
        v_action:='DOCUMENT_FINALIZE';
        v_actor:=NEW.finalized_by;
    ELSE
        RETURN NEW;
    END IF;
    INSERT INTO public.finance_reconciliation_audit(
        company_id,reconciliation_document_id,action,actor_id,
        before_state,after_state
    ) VALUES(
        NEW.company_id,NEW.id,v_action,v_actor,
        CASE WHEN TG_OP='UPDATE' THEN to_jsonb(OLD) ELSE NULL END,to_jsonb(NEW)
    );
    RETURN NEW;
END;
$$;

CREATE FUNCTION private.trg_g6_audit_reconciliation_allocation()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
BEGIN
    INSERT INTO public.finance_reconciliation_audit(
        company_id,reconciliation_document_id,action,actor_id,after_state
    ) VALUES(
        NEW.company_id,NEW.reconciliation_document_id,
        'ALLOCATION_CREATE',NEW.created_by,to_jsonb(NEW)
    );
    RETURN NEW;
END;
$$;

CREATE FUNCTION private.trg_g6_guard_reconciliation_audit()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
BEGIN
    RAISE EXCEPTION 'FINANCE_RECONCILIATION_AUDIT_IMMUTABLE';
END;
$$;

CREATE TRIGGER g6_guard_reconciliation_document
BEFORE UPDATE OR DELETE ON public.finance_reconciliation_documents
FOR EACH ROW EXECUTE FUNCTION private.trg_g6_guard_reconciliation_document();
CREATE TRIGGER g6_guard_reconciliation_allocation
BEFORE INSERT OR UPDATE OR DELETE ON public.finance_reconciliation_allocations
FOR EACH ROW EXECUTE FUNCTION private.trg_g6_guard_reconciliation_allocation();
CREATE TRIGGER g6_audit_reconciliation_document
AFTER INSERT OR UPDATE ON public.finance_reconciliation_documents
FOR EACH ROW EXECUTE FUNCTION private.trg_g6_audit_reconciliation_document();
CREATE TRIGGER g6_audit_reconciliation_allocation
AFTER INSERT ON public.finance_reconciliation_allocations
FOR EACH ROW EXECUTE FUNCTION private.trg_g6_audit_reconciliation_allocation();
CREATE TRIGGER g6_guard_reconciliation_audit
BEFORE UPDATE OR DELETE ON public.finance_reconciliation_audit
FOR EACH ROW EXECUTE FUNCTION private.trg_g6_guard_reconciliation_audit();

CREATE OR REPLACE FUNCTION private.provision_g6_posted_reports(
    p_company UUID,p_actor UUID DEFAULT NULL
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
    v_actor UUID:=p_actor;
    v_code TEXT;
    v_name TEXT;
    v_formula TEXT;
    v_definition UUID;
    v_version UUID;
    v_version_no BIGINT;
BEGIN
    IF NOT EXISTS(
        SELECT 1 FROM public.companies WHERE id=p_company AND status='ACTIVE'
    ) THEN RETURN; END IF;
    IF v_actor IS NULL OR NOT EXISTS(
        SELECT 1 FROM public.profiles WHERE id=v_actor
    ) THEN
        SELECT profile.id INTO v_actor
        FROM public.profiles profile
        JOIN auth.users auth_user ON auth_user.id=profile.id
        WHERE profile.role::TEXT='super_admin'
        ORDER BY profile.id LIMIT 1;
    END IF;
    IF v_actor IS NULL THEN RAISE EXCEPTION 'LINKED_SUPER_ADMIN_REQUIRED'; END IF;

    FOR v_code,v_name,v_formula IN SELECT * FROM(VALUES
        ('TRIAL_BALANCE','Neraca Saldo','POSTED_ACCOUNT_BALANCE_V1'),
        ('GENERAL_LEDGER','Buku Besar','POSTED_ACCOUNT_LEDGER_V1'),
        ('INCOME_STATEMENT','Laba Rugi','POSTED_INCOME_STATEMENT_V1'),
        ('BALANCE_SHEET','Neraca','POSTED_BALANCE_SHEET_V1'),
        ('PENDING_ANALYSIS','Analisis Transaksi Belum Diposting','NON_POSTED_EVENT_AGING_V1'),
        ('RECONCILIATION_SUMMARY','Ringkasan Rekonsiliasi','CURRENT_SUBLEDGER_GL_V1')
    ) seed(code,name,formula)
    LOOP
        INSERT INTO public.finance_report_definitions(
            company_id,report_code,report_name,created_by,updated_by
        ) VALUES(p_company,v_code,v_name,v_actor,v_actor)
        ON CONFLICT(company_id,report_code) DO UPDATE SET
            is_active=TRUE,updated_by=v_actor,updated_at=clock_timestamp()
        RETURNING id INTO v_definition;

        SELECT version.id INTO v_version
        FROM public.finance_report_versions version
        WHERE version.company_id=p_company
          AND version.report_definition_id=v_definition
          AND version.status='ACTIVE' AND version.effective_to IS NULL;
        IF v_version IS NULL THEN
            SELECT COALESCE(max(version.version_no),0)+1 INTO v_version_no
            FROM public.finance_report_versions version
            WHERE version.company_id=p_company
              AND version.report_definition_id=v_definition;
            INSERT INTO public.finance_report_versions(
                company_id,report_definition_id,version_no,status,formula_key,
                effective_from,created_by,approved_by,approved_at
            ) VALUES(
                p_company,v_definition,v_version_no,'ACTIVE',v_formula,
                DATE '2000-01-01',v_actor,v_actor,clock_timestamp()
            ) RETURNING id INTO v_version;
            INSERT INTO public.finance_report_audit(
                company_id,report_definition_id,action,actor_id,after_state
            ) VALUES(
                p_company,v_definition,'PROVISION',v_actor,
                jsonb_build_object(
                    'reportCode',v_code,'version',v_version_no,
                    'formulaKey',v_formula
                )
            );
        END IF;

        IF v_code='INCOME_STATEMENT' THEN
            INSERT INTO public.finance_report_lines(
                company_id,report_version_id,line_no,line_key,line_label,
                account_types,balance_multiplier
            ) VALUES
                (p_company,v_version,10,'NET_REVENUE','Pendapatan Bersih',ARRAY['REVENUE'],1),
                (p_company,v_version,20,'COGS','Harga Pokok Penjualan',ARRAY['COGS'],1),
                (p_company,v_version,30,'OPERATING_EXPENSE','Beban Operasional',ARRAY['EXPENSE'],1),
                (p_company,v_version,40,'OTHER_INCOME','Pendapatan Lain',ARRAY['OTHER_INCOME'],1),
                (p_company,v_version,50,'OTHER_EXPENSE','Beban Lain',ARRAY['OTHER_EXPENSE'],1)
            ON CONFLICT(company_id,report_version_id,line_key) DO NOTHING;
        ELSIF v_code='BALANCE_SHEET' THEN
            INSERT INTO public.finance_report_lines(
                company_id,report_version_id,line_no,line_key,line_label,
                account_types,balance_multiplier
            ) VALUES
                (p_company,v_version,10,'ASSETS','Aset',ARRAY['ASSET'],1),
                (p_company,v_version,20,'LIABILITIES','Liabilitas',ARRAY['LIABILITY'],1),
                (p_company,v_version,30,'EQUITY','Ekuitas',ARRAY['EQUITY'],1),
                (p_company,v_version,40,'CURRENT_RESULT','Laba/Rugi Berjalan',
                    ARRAY['REVENUE','COGS','EXPENSE','OTHER_INCOME','OTHER_EXPENSE'],1)
            ON CONFLICT(company_id,report_version_id,line_key) DO NOTHING;
        ELSIF v_code='PENDING_ANALYSIS' THEN
            INSERT INTO public.finance_report_lines(
                company_id,report_version_id,line_no,line_key,line_label
            ) VALUES(
                p_company,v_version,10,'NON_POSTED_EXPOSURE',
                'Belum Masuk Laporan Keuangan'
            ) ON CONFLICT(company_id,report_version_id,line_key) DO NOTHING;
        ELSIF v_code='RECONCILIATION_SUMMARY' THEN
            INSERT INTO public.finance_report_lines(
                company_id,report_version_id,line_no,line_key,line_label
            ) VALUES
                (p_company,v_version,10,'STOCK_FIFO_GL','FIFO vs Persediaan GL'),
                (p_company,v_version,20,'SUPPLIER_AP_GL','Hutang Supplier vs GL'),
                (p_company,v_version,30,'CUSTOMER_BALANCE_GL','Saldo Customer vs GL'),
                (p_company,v_version,40,'CASH_BANK_GL','Kas/Bank vs GL')
            ON CONFLICT(company_id,report_version_id,line_key) DO NOTHING;
        END IF;
    END LOOP;
END;
$$;

DO $provision$
DECLARE v_company UUID; v_actor UUID;
BEGIN
    SELECT profile.id INTO v_actor
    FROM public.profiles profile
    JOIN auth.users auth_user ON auth_user.id=profile.id
    WHERE profile.role::TEXT='super_admin'
    ORDER BY profile.id LIMIT 1;
    IF v_actor IS NULL THEN RAISE EXCEPTION 'LINKED_SUPER_ADMIN_REQUIRED'; END IF;
    FOR v_company IN
        SELECT id FROM public.companies WHERE status='ACTIVE' ORDER BY id
    LOOP
        PERFORM private.provision_g6_posted_reports(v_company,v_actor);
    END LOOP;
END
$provision$;

CREATE FUNCTION public.get_finance_income_statement(
    p_date_from DATE,p_as_of DATE,
    p_store_id UUID DEFAULT NULL,p_warehouse_id UUID DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id(); v_timezone TEXT; v_version BIGINT;
BEGIN
    IF auth.uid() IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF NOT private.g6_report_role_allowed(v_company) THEN
        RAISE EXCEPTION 'FINANCE_REPORT_ROLE_REQUIRED';
    END IF;
    IF p_date_from IS NULL OR p_as_of IS NULL OR p_date_from>p_as_of THEN
        RAISE EXCEPTION 'REPORT_DATE_RANGE_INVALID';
    END IF;
    IF p_store_id IS NOT NULL AND NOT EXISTS(
        SELECT 1 FROM public.stores WHERE company_id=v_company AND id=p_store_id
    ) THEN RAISE EXCEPTION 'REPORT_STORE_NOT_FOUND'; END IF;
    IF p_warehouse_id IS NOT NULL AND NOT EXISTS(
        SELECT 1 FROM public.warehouses WHERE company_id=v_company AND id=p_warehouse_id
    ) THEN RAISE EXCEPTION 'REPORT_WAREHOUSE_NOT_FOUND'; END IF;
    SELECT company.timezone INTO v_timezone
    FROM public.companies company
    WHERE company.id=v_company AND company.status='ACTIVE';
    SELECT version.version_no INTO v_version
    FROM public.finance_report_definitions definition
    JOIN public.finance_report_versions version
      ON version.company_id=definition.company_id
     AND version.report_definition_id=definition.id
    WHERE definition.company_id=v_company
      AND definition.report_code='INCOME_STATEMENT' AND definition.is_active
      AND version.status='ACTIVE' AND version.effective_from<=p_as_of
      AND (version.effective_to IS NULL OR version.effective_to>p_as_of);
    IF v_version IS NULL THEN RAISE EXCEPTION 'ACTIVE_REPORT_VERSION_NOT_FOUND'; END IF;

    RETURN (WITH account_result AS(
        SELECT account.id,account.account_code,account.account_name,account.account_type,
            COALESCE(sum(CASE
                WHEN account.account_type IN('REVENUE','OTHER_INCOME')
                    THEN line.credit-line.debit
                ELSE line.debit-line.credit END),0)::NUMERIC(24,4) amount,
            COALESCE(sum(CASE WHEN journal.journal_type='PRIOR_PERIOD_ADJUSTMENT'
                THEN CASE WHEN account.account_type IN('REVENUE','OTHER_INCOME')
                    THEN line.credit-line.debit ELSE line.debit-line.credit END
                ELSE 0 END),0)::NUMERIC(24,4) prior_period_amount
        FROM public.chart_of_accounts account
        JOIN public.finance_journal_lines line
          ON line.company_id=account.company_id AND line.account_id=account.id
        JOIN public.finance_journals journal
          ON journal.company_id=line.company_id AND journal.id=line.journal_id
         AND journal.status='POSTED'
        WHERE account.company_id=v_company
          AND account.account_type IN(
              'REVENUE','COGS','EXPENSE','OTHER_INCOME','OTHER_EXPENSE'
          )
          AND journal.accounting_date BETWEEN p_date_from AND p_as_of
          AND (p_store_id IS NULL OR line.store_id=p_store_id)
          AND (p_warehouse_id IS NULL OR line.warehouse_id=p_warehouse_id)
        GROUP BY account.id,account.account_code,account.account_name,account.account_type
    ), totals AS(
        SELECT
            COALESCE(sum(amount) FILTER(WHERE account_type='REVENUE'),0) revenue,
            COALESCE(sum(amount) FILTER(WHERE account_type='COGS'),0) cogs,
            COALESCE(sum(amount) FILTER(WHERE account_type='EXPENSE'),0) operating_expense,
            COALESCE(sum(amount) FILTER(WHERE account_type='OTHER_INCOME'),0) other_income,
            COALESCE(sum(amount) FILTER(WHERE account_type='OTHER_EXPENSE'),0) other_expense,
            COALESCE(sum(prior_period_amount),0) prior_period_amount
        FROM account_result
    ) SELECT jsonb_build_object(
        'companyId',v_company,'timezone',v_timezone,
        'dateFrom',p_date_from,'asOf',p_as_of,'reportVersion',v_version,
        'postedOnly',TRUE,
        'netRevenue',revenue,'cogs',cogs,'grossProfit',revenue-cogs,
        'operatingExpense',operating_expense,'otherIncome',other_income,
        'otherExpense',other_expense,
        'profitBeforeTax',revenue-cogs-operating_expense+other_income-other_expense,
        'priorPeriodAdjustment',prior_period_amount,
        'rows',COALESCE((SELECT jsonb_agg(jsonb_build_object(
            'accountId',id,'accountCode',account_code,'accountName',account_name,
            'accountType',account_type,'amount',amount,
            'priorPeriodAdjustment',prior_period_amount
        ) ORDER BY account_code) FROM account_result),'[]'::JSONB)
    ) FROM totals);
END;
$$;

CREATE FUNCTION public.get_finance_balance_sheet(
    p_as_of DATE,p_store_id UUID DEFAULT NULL,p_warehouse_id UUID DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id(); v_timezone TEXT; v_version BIGINT;
BEGIN
    IF auth.uid() IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF NOT private.g6_report_role_allowed(v_company) THEN
        RAISE EXCEPTION 'FINANCE_REPORT_ROLE_REQUIRED';
    END IF;
    IF p_as_of IS NULL THEN RAISE EXCEPTION 'REPORT_DATE_RANGE_INVALID'; END IF;
    IF p_store_id IS NOT NULL AND NOT EXISTS(
        SELECT 1 FROM public.stores WHERE company_id=v_company AND id=p_store_id
    ) THEN RAISE EXCEPTION 'REPORT_STORE_NOT_FOUND'; END IF;
    IF p_warehouse_id IS NOT NULL AND NOT EXISTS(
        SELECT 1 FROM public.warehouses WHERE company_id=v_company AND id=p_warehouse_id
    ) THEN RAISE EXCEPTION 'REPORT_WAREHOUSE_NOT_FOUND'; END IF;
    SELECT company.timezone INTO v_timezone FROM public.companies company
    WHERE company.id=v_company AND company.status='ACTIVE';
    SELECT version.version_no INTO v_version
    FROM public.finance_report_definitions definition
    JOIN public.finance_report_versions version
      ON version.company_id=definition.company_id
     AND version.report_definition_id=definition.id
    WHERE definition.company_id=v_company
      AND definition.report_code='BALANCE_SHEET' AND definition.is_active
      AND version.status='ACTIVE' AND version.effective_from<=p_as_of
      AND (version.effective_to IS NULL OR version.effective_to>p_as_of);
    IF v_version IS NULL THEN RAISE EXCEPTION 'ACTIVE_REPORT_VERSION_NOT_FOUND'; END IF;

    RETURN (WITH account_result AS(
        SELECT account.id,account.account_code,account.account_name,account.account_type,
            COALESCE(sum(CASE
                WHEN account.account_type IN(
                    'LIABILITY','EQUITY','REVENUE','OTHER_INCOME'
                ) THEN line.credit-line.debit
                ELSE line.debit-line.credit END),0)::NUMERIC(24,4) amount
        FROM public.chart_of_accounts account
        JOIN public.finance_journal_lines line
          ON line.company_id=account.company_id AND line.account_id=account.id
        JOIN public.finance_journals journal
          ON journal.company_id=line.company_id AND journal.id=line.journal_id
         AND journal.status='POSTED' AND journal.accounting_date<=p_as_of
        WHERE account.company_id=v_company
          AND (p_store_id IS NULL OR line.store_id=p_store_id)
          AND (p_warehouse_id IS NULL OR line.warehouse_id=p_warehouse_id)
        GROUP BY account.id,account.account_code,account.account_name,account.account_type
    ), totals AS(
        SELECT
            COALESCE(sum(amount) FILTER(WHERE account_type='ASSET'),0) assets,
            COALESCE(sum(amount) FILTER(WHERE account_type='LIABILITY'),0) liabilities,
            COALESCE(sum(amount) FILTER(WHERE account_type='EQUITY'),0) equity,
            COALESCE(sum(amount) FILTER(WHERE account_type IN('REVENUE','OTHER_INCOME')),0)
              -COALESCE(sum(amount) FILTER(WHERE account_type IN('COGS','EXPENSE','OTHER_EXPENSE')),0)
                AS current_result
        FROM account_result
    ) SELECT jsonb_build_object(
        'companyId',v_company,'timezone',v_timezone,'asOf',p_as_of,
        'reportVersion',v_version,'postedOnly',TRUE,
        'assets',assets,'liabilities',liabilities,'equity',equity,
        'currentResult',current_result,
        'liabilitiesEquityAndResult',liabilities+equity+current_result,
        'balanced',round(assets-(liabilities+equity+current_result),4)=0,
        'rows',COALESCE((SELECT jsonb_agg(jsonb_build_object(
            'accountId',id,'accountCode',account_code,'accountName',account_name,
            'accountType',account_type,'amount',amount
        ) ORDER BY account_code) FROM account_result),'[]'::JSONB)
    ) FROM totals);
END;
$$;

CREATE FUNCTION private.g6_jsonb_numeric(p_object JSONB,p_key TEXT)
RETURNS NUMERIC LANGUAGE sql IMMUTABLE
SET search_path=public,pg_temp AS $$
    SELECT CASE WHEN jsonb_typeof(p_object->p_key)='number'
        THEN (p_object->>p_key)::NUMERIC ELSE NULL END
$$;

CREATE FUNCTION public.get_finance_pending_analysis(
    p_date_from DATE,p_as_of DATE,p_limit INTEGER DEFAULT 100,p_offset INTEGER DEFAULT 0
) RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id(); v_timezone TEXT; v_version BIGINT;
BEGIN
    IF auth.uid() IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF NOT private.g6_report_role_allowed(v_company) THEN
        RAISE EXCEPTION 'FINANCE_REPORT_ROLE_REQUIRED';
    END IF;
    IF p_date_from IS NULL OR p_as_of IS NULL OR p_date_from>p_as_of THEN
        RAISE EXCEPTION 'REPORT_DATE_RANGE_INVALID';
    END IF;
    IF p_limit IS NULL OR p_limit<1 OR p_limit>500
       OR p_offset IS NULL OR p_offset<0 THEN
        RAISE EXCEPTION 'REPORT_PAGINATION_INVALID';
    END IF;
    SELECT company.timezone INTO v_timezone FROM public.companies company
    WHERE company.id=v_company AND company.status='ACTIVE';
    SELECT version.version_no INTO v_version
    FROM public.finance_report_definitions definition
    JOIN public.finance_report_versions version
      ON version.company_id=definition.company_id
     AND version.report_definition_id=definition.id
    WHERE definition.company_id=v_company
      AND definition.report_code='PENDING_ANALYSIS' AND definition.is_active
      AND version.status='ACTIVE' AND version.effective_from<=p_as_of
      AND (version.effective_to IS NULL OR version.effective_to>p_as_of);
    IF v_version IS NULL THEN RAISE EXCEPTION 'ACTIVE_REPORT_VERSION_NOT_FOUND'; END IF;

    RETURN (WITH pending AS(
        SELECT event.status::TEXT status,event.system_event_key,event.source_table,
            event.store_id,
            count(*) event_count,min(event.event_date) oldest_event_at,
            max(event.event_date) newest_event_at,
            COALESCE(sum(CASE event.event_type::TEXT
                WHEN 'STOCK_OPENING' THEN private.g6_jsonb_numeric(event.amounts,'inventoryDebit')
                WHEN 'SALE_POSTED' THEN private.g6_jsonb_numeric(event.amounts,'grandTotal')
                WHEN 'SALES_REFUND' THEN private.g6_jsonb_numeric(event.amounts,'refundTotal')
                WHEN 'EXPENSE_DISBURSEMENT' THEN private.g6_jsonb_numeric(event.amounts,'disbursedAmount')
                WHEN 'BANK_DEPOSIT' THEN private.g6_jsonb_numeric(event.amounts,'actualDeposit')
                WHEN 'DEPOSIT_VARIANCE_RESOLUTION' THEN private.g6_jsonb_numeric(event.amounts,'allocationAmount')
                WHEN 'PURCHASE_POSTED' THEN private.g6_jsonb_numeric(event.amounts,'supplierApProvisionalCredit')
                WHEN 'SUPPLIER_INVOICE_VALIDATED' THEN private.g6_jsonb_numeric(event.amounts,'apFinalCredit')
                WHEN 'SUPPLIER_PAYMENT_VALIDATED' THEN private.g6_jsonb_numeric(event.amounts,'totalAmount')
                ELSE NULL END),0)::NUMERIC(24,4) potential_amount
        FROM public.financial_events event
        WHERE event.company_id=v_company AND event.status::TEXT<>'POSTED'
          AND (event.event_date AT TIME ZONE v_timezone)::DATE
              BETWEEN p_date_from AND p_as_of
        GROUP BY event.status::TEXT,event.system_event_key,event.source_table,event.store_id
    ), page AS(
        SELECT * FROM pending
        ORDER BY oldest_event_at,system_event_key,source_table,store_id
        LIMIT p_limit OFFSET p_offset
    ) SELECT jsonb_build_object(
        'companyId',v_company,'timezone',v_timezone,
        'dateFrom',p_date_from,'asOf',p_as_of,'reportVersion',v_version,
        'financialStatementIncluded',FALSE,
        'label','BELUM MASUK LAPORAN KEUANGAN',
        'totalRows',(SELECT count(*) FROM pending),'limit',p_limit,'offset',p_offset,
        'rows',COALESCE((SELECT jsonb_agg(jsonb_build_object(
            'status',status,'systemEventKey',system_event_key,
            'sourceTable',source_table,'storeId',store_id,'eventCount',event_count,
            'waitingOnParty',CASE WHEN status='HOLD' THEN 'FINANCE'
                WHEN status IN('ERROR','FAILED') THEN 'SYSTEM' ELSE 'UNKNOWN' END,
            'nextAction',CASE WHEN status='HOLD'
                THEN 'REVIEW_FINANCE_POSTING_READINESS'
                WHEN status IN('ERROR','FAILED') THEN 'INVESTIGATE_SYSTEM_ERROR'
                ELSE 'REVIEW_SOURCE_STATUS' END,
            'oldestEventAt',oldest_event_at,'newestEventAt',newest_event_at,
            'ageDays',p_as_of-(oldest_event_at AT TIME ZONE v_timezone)::DATE,
            'potentialAmount',potential_amount
        ) ORDER BY oldest_event_at,system_event_key,source_table,store_id) FROM page),'[]'::JSONB)
    ));
END;
$$;

CREATE FUNCTION public.get_finance_reconciliation_summary(p_as_of DATE)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id(); v_timezone TEXT; v_today DATE; v_version BIGINT;
BEGIN
    IF auth.uid() IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF NOT private.g6_report_role_allowed(v_company) THEN
        RAISE EXCEPTION 'FINANCE_REPORT_ROLE_REQUIRED';
    END IF;
    SELECT company.timezone INTO v_timezone FROM public.companies company
    WHERE company.id=v_company AND company.status='ACTIVE';
    v_today:=(clock_timestamp() AT TIME ZONE v_timezone)::DATE;
    IF p_as_of IS NULL OR p_as_of<>v_today THEN
        RAISE EXCEPTION 'HISTORICAL_SUBLEDGER_SNAPSHOT_UNAVAILABLE';
    END IF;
    SELECT version.version_no INTO v_version
    FROM public.finance_report_definitions definition
    JOIN public.finance_report_versions version
      ON version.company_id=definition.company_id
     AND version.report_definition_id=definition.id
    WHERE definition.company_id=v_company
      AND definition.report_code='RECONCILIATION_SUMMARY'
      AND definition.is_active AND version.status='ACTIVE'
      AND version.effective_from<=p_as_of
      AND (version.effective_to IS NULL OR version.effective_to>p_as_of);
    IF v_version IS NULL THEN RAISE EXCEPTION 'ACTIVE_REPORT_VERSION_NOT_FOUND'; END IF;

    RETURN (WITH validated_invoice AS(
        SELECT invoice.id,invoice.grand_total,
            COALESCE(sum(allocation.allocated_amount) FILTER(
                WHERE payment.status='VALIDATED'
            ),0) paid_amount
        FROM public.supplier_invoice_documents invoice
        LEFT JOIN public.supplier_payment_allocations allocation
          ON allocation.company_id=invoice.company_id
         AND allocation.invoice_id=invoice.id
        LEFT JOIN public.supplier_payment_documents payment
          ON payment.company_id=allocation.company_id
         AND payment.id=allocation.document_id
        WHERE invoice.company_id=v_company AND invoice.status='VALIDATED'
        GROUP BY invoice.id,invoice.grand_total
    ), values_state AS(
        SELECT
            COALESCE((SELECT sum(batch.qty_remaining*batch.cogs_unit)
                FROM public.product_batches batch
                WHERE batch.company_id=v_company AND batch.qty_remaining>0),0)::NUMERIC(24,4) fifo_value,
            COALESCE((SELECT sum(line.debit-line.credit)
                FROM public.finance_journal_lines line
                JOIN public.finance_journals journal
                  ON journal.company_id=line.company_id AND journal.id=line.journal_id
                 AND journal.status='POSTED' AND journal.accounting_date<=p_as_of
                WHERE line.company_id=v_company
                  AND line.account_function_key_snapshot='INVENTORY_ASSET'),0)::NUMERIC(24,4) inventory_gl,
            COALESCE((SELECT sum(greatest(grand_total-paid_amount,0))
                FROM validated_invoice),0)::NUMERIC(24,4) ap_subledger,
            COALESCE((SELECT sum(line.credit-line.debit)
                FROM public.finance_journal_lines line
                JOIN public.finance_journals journal
                  ON journal.company_id=line.company_id AND journal.id=line.journal_id
                 AND journal.status='POSTED' AND journal.accounting_date<=p_as_of
                WHERE line.company_id=v_company
                  AND line.account_function_key_snapshot='SUPPLIER_AP_FINAL'),0)::NUMERIC(24,4) ap_gl,
            COALESCE((SELECT sum(customer.current_balance)
                FROM public.customers customer
                WHERE customer.company_id=v_company
                  AND NOT customer.is_system_customer),0)::NUMERIC(24,4) customer_balance,
            COALESCE((SELECT sum(line.credit-line.debit)
                FROM public.finance_journal_lines line
                JOIN public.finance_journals journal
                  ON journal.company_id=line.company_id AND journal.id=line.journal_id
                 AND journal.status='POSTED' AND journal.accounting_date<=p_as_of
                WHERE line.company_id=v_company
                  AND line.account_function_key_snapshot='CUSTOMER_BALANCE_LIABILITY'),0)::NUMERIC(24,4) customer_balance_gl,
            COALESCE((SELECT sum(CASE
                    WHEN line.normal_balance_snapshot='DEBIT'
                        THEN line.debit-line.credit
                    ELSE line.credit-line.debit END)
                FROM public.finance_journal_lines line
                JOIN public.finance_journals journal
                  ON journal.company_id=line.company_id AND journal.id=line.journal_id
                 AND journal.status='POSTED' AND journal.accounting_date<=p_as_of
                WHERE line.company_id=v_company
                  AND line.account_function_key_snapshot IN(
                    'CASH_DRAWER','MAIN_CASH','BANK','CASH_IN_TRANSIT','PAYMENT_CLEARING'
                  )),0)::NUMERIC(24,4) cash_bank_gl
    ) SELECT jsonb_build_object(
        'companyId',v_company,'timezone',v_timezone,'asOf',p_as_of,
        'reportVersion',v_version,'valuationMode','CURRENT_ONLY',
        'autoAdjustment',FALSE,'rows',jsonb_build_array(
            jsonb_build_object('reconciliationType','STOCK_FIFO_GL',
                'subledgerBalance',fifo_value,'ledgerBalance',inventory_gl,
                'difference',fifo_value-inventory_gl,
                'status',CASE WHEN fifo_value=inventory_gl THEN 'MATCHED' ELSE 'UNMATCHED' END),
            jsonb_build_object('reconciliationType','SUPPLIER_AP_GL',
                'subledgerBalance',ap_subledger,'ledgerBalance',ap_gl,
                'difference',ap_subledger-ap_gl,
                'status',CASE WHEN ap_subledger=ap_gl THEN 'MATCHED' ELSE 'UNMATCHED' END),
            jsonb_build_object('reconciliationType','CUSTOMER_BALANCE_GL',
                'subledgerBalance',customer_balance,'ledgerBalance',customer_balance_gl,
                'difference',customer_balance-customer_balance_gl,
                'status',CASE WHEN customer_balance=customer_balance_gl THEN 'MATCHED' ELSE 'UNMATCHED' END),
            jsonb_build_object('reconciliationType','CASH_BANK_GL',
                'subledgerBalance',NULL,'ledgerBalance',cash_bank_gl,
                'difference',NULL,'status','DEFERRED',
                'reason','CASH_BANK_SUBLEDGER_RECONCILIATION_NOT_OPEN')
        )
    ) FROM values_state);
END;
$$;

ALTER TABLE public.finance_reconciliation_documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.finance_reconciliation_allocations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.finance_reconciliation_audit ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Finance reconciliation documents readable"
ON public.finance_reconciliation_documents FOR SELECT TO authenticated
USING(private.g6_report_role_allowed(company_id));
CREATE POLICY "Finance reconciliation allocations readable"
ON public.finance_reconciliation_allocations FOR SELECT TO authenticated
USING(private.g6_report_role_allowed(company_id));
CREATE POLICY "Finance reconciliation audit readable"
ON public.finance_reconciliation_audit FOR SELECT TO authenticated
USING(private.g6_report_role_allowed(company_id));

REVOKE ALL ON public.finance_reconciliation_documents,
    public.finance_reconciliation_allocations,
    public.finance_reconciliation_audit FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.finance_reconciliation_documents,
    public.finance_reconciliation_allocations,
    public.finance_reconciliation_audit TO authenticated;
GRANT ALL ON public.finance_reconciliation_documents,
    public.finance_reconciliation_allocations,
    public.finance_reconciliation_audit TO service_role;
REVOKE ALL ON FUNCTION
    private.trg_g6_guard_reconciliation_document(),
    private.trg_g6_guard_reconciliation_allocation(),
    private.trg_g6_audit_reconciliation_document(),
    private.trg_g6_audit_reconciliation_allocation(),
    private.trg_g6_guard_reconciliation_audit(),
    private.g6_jsonb_numeric(JSONB,TEXT)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
    private.trg_g6_guard_reconciliation_document(),
    private.trg_g6_guard_reconciliation_allocation(),
    private.trg_g6_audit_reconciliation_document(),
    private.trg_g6_audit_reconciliation_allocation(),
    private.trg_g6_guard_reconciliation_audit()
TO service_role;
REVOKE ALL ON FUNCTION
    public.get_finance_income_statement(DATE,DATE,UUID,UUID),
    public.get_finance_balance_sheet(DATE,UUID,UUID),
    public.get_finance_pending_analysis(DATE,DATE,INTEGER,INTEGER),
    public.get_finance_reconciliation_summary(DATE)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION
    public.get_finance_income_statement(DATE,DATE,UUID,UUID),
    public.get_finance_balance_sheet(DATE,UUID,UUID),
    public.get_finance_pending_analysis(DATE,DATE,INTEGER,INTEGER),
    public.get_finance_reconciliation_summary(DATE)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes) VALUES(
    '20260810230000','g6_phase6c_statements_pending_reconciliation',
    'POSTED-only P&L/Balance Sheet, explicitly non-financial pending analysis, current-only reconciliation read model, immutable reconciliation foundation, versioned report definitions, RLS, and zero HOLD/journal mutation'
);

COMMIT;
