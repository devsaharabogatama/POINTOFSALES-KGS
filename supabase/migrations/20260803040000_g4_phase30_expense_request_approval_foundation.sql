-- KGS POS G4 phase 30: canonical Expense request and approval foundation.
-- Dependency: Sales Return foundation through 20260803020000.
--
-- This phase opens category/policy and Draft/Submit/Review/Cancel only.
-- Disbursement, settlement, return, Cash In, drawer mutation, offline flow,
-- Finance journal posting, and Deposit remain closed.

BEGIN;

DO $migration_guard$
BEGIN
    IF to_regclass('private.kgs_schema_migrations') IS NULL
       OR NOT EXISTS (
           SELECT 1 FROM private.kgs_schema_migrations
           WHERE version = '20260803020000'
       ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: G4 Sales Return chain incomplete';
    END IF;
    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260803040000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260803040000';
    END IF;
    IF EXISTS (SELECT 1 FROM public.cash_advances) THEN
        RAISE EXCEPTION
            'G4_PHASE30_STATE_CHANGED: legacy Cash Advance rows require explicit backfill';
    END IF;
    IF (
        SELECT count(*)
        FROM pg_trigger t
        JOIN pg_class c ON c.oid=t.tgrelid
        JOIN pg_namespace n ON n.oid=c.relnamespace
        JOIN pg_proc p ON p.oid=t.tgfoid
        JOIN pg_namespace pn ON pn.oid=p.pronamespace
        WHERE n.nspname='public'
          AND c.relname='cash_advances'
          AND NOT t.tgisinternal
          AND pn.nspname='public'
          AND p.proname='trg_cash_advances_to_financial_events'
    ) <> 1 THEN
        RAISE EXCEPTION
            'G4_PHASE30_STATE_CHANGED: legacy Cash Advance trigger contract changed';
    END IF;
    IF to_regclass('public.expense_categories') IS NOT NULL
       OR to_regclass('public.expense_approval_policies') IS NOT NULL
       OR to_regclass('public.expense_documents') IS NOT NULL
       OR to_regclass('public.expense_disbursements') IS NOT NULL
       OR to_regclass('public.expense_settlements') IS NOT NULL
       OR to_regclass('public.expense_returns') IS NOT NULL
       OR to_regclass('public.cash_in_documents') IS NOT NULL
       OR to_regclass('public.cash_drawer_movements') IS NOT NULL
       OR to_regclass('public.expense_audit') IS NOT NULL THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: canonical Expense object exists';
    END IF;
END
$migration_guard$;

INSERT INTO public.platform_features(
    feature_code,feature_name,module_code,description
) VALUES (
    'expense_enabled','Expense Operasional','POS',
    'Canonical Expense request, approval, cash/bank disbursement, settlement, and return workflow.'
) ON CONFLICT(feature_code) DO NOTHING;

CREATE SEQUENCE private.expense_document_number_seq AS BIGINT START WITH 1;
CREATE SEQUENCE private.cash_in_document_number_seq AS BIGINT START WITH 1;
REVOKE ALL ON SEQUENCE private.expense_document_number_seq,
    private.cash_in_document_number_seq FROM PUBLIC,anon,authenticated;
GRANT USAGE,SELECT ON SEQUENCE private.expense_document_number_seq,
    private.cash_in_document_number_seq TO service_role;

CREATE TABLE public.expense_categories (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL,
    category_code TEXT NOT NULL,
    category_name TEXT NOT NULL,
    description TEXT,
    transaction_category_id UUID NOT NULL,
    expense_account_id UUID,
    evidence_policy TEXT NOT NULL DEFAULT 'OPTIONAL',
    approval_policy TEXT NOT NULL DEFAULT 'USE_DEFAULT',
    default_payment_method_id UUID,
    is_system_default BOOLEAN NOT NULL DEFAULT FALSE,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    master_version BIGINT NOT NULL DEFAULT 1,
    created_by UUID REFERENCES public.profiles(id),
    updated_by UUID REFERENCES public.profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT expense_categories_company_id_id_unique UNIQUE(company_id,id),
    CONSTRAINT expense_categories_code_not_blank CHECK(btrim(category_code)<>''),
    CONSTRAINT expense_categories_name_not_blank CHECK(btrim(category_name)<>''),
    CONSTRAINT expense_categories_evidence_check
        CHECK(evidence_policy IN ('OPTIONAL','REQUIRED')),
    CONSTRAINT expense_categories_approval_check
        CHECK(approval_policy IN ('USE_DEFAULT','REQUIRED','NOT_REQUIRED')),
    CONSTRAINT expense_categories_system_default_active_check
        CHECK(NOT is_system_default OR is_active),
    CONSTRAINT expense_categories_version_positive CHECK(master_version>0),
    CONSTRAINT fk_expense_category_company
        FOREIGN KEY(company_id) REFERENCES public.companies(id) ON DELETE RESTRICT,
    CONSTRAINT fk_expense_category_transaction
        FOREIGN KEY(company_id,transaction_category_id)
        REFERENCES public.transaction_categories(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_expense_category_account
        FOREIGN KEY(company_id,expense_account_id)
        REFERENCES public.chart_of_accounts(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_expense_category_payment
        FOREIGN KEY(company_id,default_payment_method_id)
        REFERENCES public.payment_methods(company_id,id) ON DELETE RESTRICT
);
CREATE UNIQUE INDEX uq_expense_categories_company_normalized_code
    ON public.expense_categories(
        company_id,upper(regexp_replace(btrim(category_code),'\s+',' ','g'))
    );
CREATE UNIQUE INDEX uq_expense_categories_company_normalized_name
    ON public.expense_categories(
        company_id,lower(regexp_replace(btrim(category_name),'\s+',' ','g'))
    );
CREATE UNIQUE INDEX uq_expense_categories_company_default
    ON public.expense_categories(company_id) WHERE is_system_default;

CREATE TABLE public.expense_approval_policies (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL,
    store_id UUID,
    approval_required BOOLEAN NOT NULL DEFAULT TRUE,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    master_version BIGINT NOT NULL DEFAULT 1,
    created_by UUID REFERENCES public.profiles(id),
    updated_by UUID REFERENCES public.profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT expense_policy_company_id_id_unique UNIQUE(company_id,id),
    CONSTRAINT expense_policy_version_positive CHECK(master_version>0),
    CONSTRAINT fk_expense_policy_company
        FOREIGN KEY(company_id) REFERENCES public.companies(id) ON DELETE RESTRICT,
    CONSTRAINT fk_expense_policy_store
        FOREIGN KEY(company_id,store_id)
        REFERENCES public.stores(company_id,id) ON DELETE RESTRICT
);
CREATE UNIQUE INDEX uq_expense_policy_company_default
    ON public.expense_approval_policies(company_id) WHERE store_id IS NULL;
CREATE UNIQUE INDEX uq_expense_policy_store_override
    ON public.expense_approval_policies(company_id,store_id)
    WHERE store_id IS NOT NULL;

CREATE TABLE public.expense_documents (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL,
    document_no TEXT NOT NULL,
    store_id UUID NOT NULL,
    pos_terminal_id UUID,
    cashier_session_id UUID,
    category_id UUID NOT NULL,
    category_name_snapshot TEXT NOT NULL,
    transaction_category_id UUID NOT NULL,
    expense_account_id_snapshot UUID,
    responsible_party_type TEXT NOT NULL,
    responsible_party_id UUID,
    responsible_party_name_snapshot TEXT NOT NULL,
    requested_amount NUMERIC(20,4) NOT NULL,
    disbursed_amount NUMERIC(20,4) NOT NULL DEFAULT 0,
    actual_expense_amount NUMERIC(20,4) NOT NULL DEFAULT 0,
    returned_amount NUMERIC(20,4) NOT NULL DEFAULT 0,
    outstanding_amount NUMERIC(20,4) NOT NULL DEFAULT 0,
    requested_payment_method_id UUID NOT NULL,
    requested_payment_method_name_snapshot TEXT NOT NULL,
    requested_payment_method_type_snapshot TEXT NOT NULL,
    recipient TEXT,
    description TEXT NOT NULL,
    evidence_url TEXT,
    expected_settlement_date DATE,
    source_document_type TEXT,
    source_document_id UUID,
    status TEXT NOT NULL DEFAULT 'DRAFT',
    approval_required_snapshot BOOLEAN NOT NULL,
    evidence_policy_snapshot TEXT NOT NULL,
    client_expense_id UUID,
    master_version BIGINT NOT NULL DEFAULT 1,
    created_by UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
    updated_by UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
    submitted_by UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
    approved_by UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
    rejected_by UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
    canceled_by UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    submitted_at TIMESTAMPTZ,
    approved_at TIMESTAMPTZ,
    rejected_at TIMESTAMPTZ,
    canceled_at TIMESTAMPTZ,
    rejection_reason TEXT,
    cancel_reason TEXT,
    reversal_of_id UUID,
    CONSTRAINT expense_documents_company_id_id_unique UNIQUE(company_id,id),
    CONSTRAINT expense_documents_company_no_unique UNIQUE(company_id,document_no),
    CONSTRAINT expense_documents_status_check CHECK(status IN (
        'DRAFT','SUBMITTED','APPROVED','REJECTED','PAYMENT_PENDING',
        'DISBURSED','PARTIALLY_SETTLED','SETTLED','SETTLED_NO_EXPENSE',
        'REVERSED','CANCELED'
    )),
    CONSTRAINT expense_documents_responsible_type_check CHECK(
        responsible_party_type IN ('CASHIER','STORE_MANAGER','EMPLOYEE','EXTERNAL')
    ),
    CONSTRAINT expense_documents_amount_check CHECK(
        requested_amount>0 AND disbursed_amount>=0
        AND actual_expense_amount>=0 AND returned_amount>=0
        AND outstanding_amount>=0
        AND outstanding_amount=
            disbursed_amount-actual_expense_amount-returned_amount
    ),
    CONSTRAINT expense_documents_payment_type_check CHECK(
        requested_payment_method_type_snapshot IN (
            'CASH','TRANSFER','QRIS','CARD','E_WALLET'
        )
    ),
    CONSTRAINT expense_documents_evidence_policy_check
        CHECK(evidence_policy_snapshot IN ('OPTIONAL','REQUIRED')),
    CONSTRAINT expense_documents_text_check CHECK(
        btrim(category_name_snapshot)<>''
        AND btrim(responsible_party_name_snapshot)<>''
        AND btrim(requested_payment_method_name_snapshot)<>''
        AND btrim(description)<>''
        AND (recipient IS NULL OR btrim(recipient)<>'')
    ),
    CONSTRAINT expense_documents_url_check CHECK(
        evidence_url IS NULL OR evidence_url ~* '^https://'
    ),
    CONSTRAINT expense_documents_version_positive CHECK(master_version>0),
    CONSTRAINT expense_documents_draft_stage_zero_check CHECK(
        status NOT IN ('DRAFT','SUBMITTED','APPROVED','REJECTED','CANCELED')
        OR (disbursed_amount=0 AND actual_expense_amount=0
            AND returned_amount=0 AND outstanding_amount=0)
    ),
    CONSTRAINT expense_documents_review_shape_check CHECK(
        (status='DRAFT' AND submitted_by IS NULL AND submitted_at IS NULL
         AND approved_by IS NULL AND approved_at IS NULL
         AND rejected_by IS NULL AND rejected_at IS NULL
         AND canceled_by IS NULL AND canceled_at IS NULL)
        OR (status='SUBMITTED' AND submitted_by IS NOT NULL
            AND submitted_at IS NOT NULL AND approval_required_snapshot
            AND approved_by IS NULL AND rejected_by IS NULL
            AND canceled_by IS NULL)
        OR (status='APPROVED' AND submitted_by IS NOT NULL
            AND submitted_at IS NOT NULL AND approved_by IS NOT NULL
            AND approved_at IS NOT NULL AND rejected_by IS NULL
            AND canceled_by IS NULL)
        OR (status='REJECTED' AND submitted_by IS NOT NULL
            AND submitted_at IS NOT NULL AND rejected_by IS NOT NULL
            AND rejected_at IS NOT NULL AND btrim(rejection_reason)<>''
            AND approved_by IS NULL AND canceled_by IS NULL)
        OR (status='CANCELED' AND canceled_by IS NOT NULL
            AND canceled_at IS NOT NULL AND btrim(cancel_reason)<>'')
        OR status IN (
            'PAYMENT_PENDING','DISBURSED','PARTIALLY_SETTLED','SETTLED',
            'SETTLED_NO_EXPENSE','REVERSED'
        )
    ),
    CONSTRAINT fk_expense_document_store
        FOREIGN KEY(company_id,store_id)
        REFERENCES public.stores(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_expense_document_terminal
        FOREIGN KEY(company_id,store_id,pos_terminal_id)
        REFERENCES public.pos_terminals(company_id,store_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_expense_document_session
        FOREIGN KEY(company_id,store_id,cashier_session_id)
        REFERENCES public.cashier_sessions(company_id,store_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_expense_document_category
        FOREIGN KEY(company_id,category_id)
        REFERENCES public.expense_categories(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_expense_document_transaction_category
        FOREIGN KEY(company_id,transaction_category_id)
        REFERENCES public.transaction_categories(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_expense_document_account
        FOREIGN KEY(company_id,expense_account_id_snapshot)
        REFERENCES public.chart_of_accounts(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_expense_document_payment
        FOREIGN KEY(company_id,requested_payment_method_id)
        REFERENCES public.payment_methods(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_expense_document_responsible
        FOREIGN KEY(responsible_party_id)
        REFERENCES public.profiles(id) ON DELETE RESTRICT,
    CONSTRAINT fk_expense_document_reversal
        FOREIGN KEY(company_id,reversal_of_id)
        REFERENCES public.expense_documents(company_id,id) ON DELETE RESTRICT
);
CREATE UNIQUE INDEX uq_expense_document_client_identity
    ON public.expense_documents(company_id,client_expense_id)
    WHERE client_expense_id IS NOT NULL;
CREATE INDEX idx_expense_document_store_status
    ON public.expense_documents(company_id,store_id,status,updated_at DESC);
CREATE INDEX idx_expense_document_responsible
    ON public.expense_documents(company_id,responsible_party_id,status)
    WHERE responsible_party_id IS NOT NULL;

CREATE TABLE public.expense_disbursements (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(), company_id UUID NOT NULL,
    document_id UUID NOT NULL, amount NUMERIC(20,4) NOT NULL CHECK(amount>0),
    payment_method_id UUID NOT NULL, payment_method_name_snapshot TEXT NOT NULL,
    payment_method_type_snapshot TEXT NOT NULL,
    cashier_session_id UUID, evidence_url TEXT, idempotency_key UUID NOT NULL,
    financial_event_id UUID, created_by UUID NOT NULL REFERENCES public.profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT expense_disbursement_company_id_id_unique UNIQUE(company_id,id),
    CONSTRAINT expense_disbursement_idempotency_unique
        UNIQUE(company_id,idempotency_key),
    CONSTRAINT expense_disbursement_type_check CHECK(
        payment_method_type_snapshot IN ('CASH','TRANSFER','QRIS','CARD','E_WALLET')
    ),
    CONSTRAINT expense_disbursement_url_check CHECK(
        evidence_url IS NULL OR evidence_url ~* '^https://'
    ),
    CONSTRAINT fk_expense_disbursement_document FOREIGN KEY(company_id,document_id)
        REFERENCES public.expense_documents(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_expense_disbursement_method FOREIGN KEY(company_id,payment_method_id)
        REFERENCES public.payment_methods(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_expense_disbursement_session FOREIGN KEY(company_id,cashier_session_id)
        REFERENCES public.cashier_sessions(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_expense_disbursement_event FOREIGN KEY(company_id,financial_event_id)
        REFERENCES public.financial_events(company_id,id) ON DELETE RESTRICT
);

CREATE TABLE public.expense_settlements (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(), company_id UUID NOT NULL,
    document_id UUID NOT NULL, actual_expense_amount NUMERIC(20,4) NOT NULL
        CHECK(actual_expense_amount>=0), category_id UUID NOT NULL,
    category_name_snapshot TEXT NOT NULL, expense_account_id_snapshot UUID,
    evidence_url TEXT, idempotency_key UUID NOT NULL, financial_event_id UUID,
    created_by UUID NOT NULL REFERENCES public.profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT expense_settlement_company_id_id_unique UNIQUE(company_id,id),
    CONSTRAINT expense_settlement_idempotency_unique UNIQUE(company_id,idempotency_key),
    CONSTRAINT expense_settlement_url_check CHECK(
        evidence_url IS NULL OR evidence_url ~* '^https://'
    ),
    CONSTRAINT fk_expense_settlement_document FOREIGN KEY(company_id,document_id)
        REFERENCES public.expense_documents(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_expense_settlement_category FOREIGN KEY(company_id,category_id)
        REFERENCES public.expense_categories(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_expense_settlement_account FOREIGN KEY(company_id,expense_account_id_snapshot)
        REFERENCES public.chart_of_accounts(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_expense_settlement_event FOREIGN KEY(company_id,financial_event_id)
        REFERENCES public.financial_events(company_id,id) ON DELETE RESTRICT
);

CREATE TABLE public.expense_returns (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(), company_id UUID NOT NULL,
    document_id UUID NOT NULL, amount NUMERIC(20,4) NOT NULL CHECK(amount>0),
    payment_method_id UUID NOT NULL, payment_method_name_snapshot TEXT NOT NULL,
    payment_method_type_snapshot TEXT NOT NULL, receiving_session_id UUID,
    evidence_url TEXT, idempotency_key UUID NOT NULL, financial_event_id UUID,
    created_by UUID NOT NULL REFERENCES public.profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT expense_return_company_id_id_unique UNIQUE(company_id,id),
    CONSTRAINT expense_return_idempotency_unique UNIQUE(company_id,idempotency_key),
    CONSTRAINT expense_return_type_check CHECK(
        payment_method_type_snapshot IN ('CASH','TRANSFER','QRIS','CARD','E_WALLET')
    ),
    CONSTRAINT expense_return_url_check CHECK(
        evidence_url IS NULL OR evidence_url ~* '^https://'
    ),
    CONSTRAINT fk_expense_return_document FOREIGN KEY(company_id,document_id)
        REFERENCES public.expense_documents(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_expense_return_method FOREIGN KEY(company_id,payment_method_id)
        REFERENCES public.payment_methods(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_expense_return_session FOREIGN KEY(company_id,receiving_session_id)
        REFERENCES public.cashier_sessions(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_expense_return_event FOREIGN KEY(company_id,financial_event_id)
        REFERENCES public.financial_events(company_id,id) ON DELETE RESTRICT
);

CREATE TABLE public.cash_in_documents (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(), company_id UUID NOT NULL,
    document_no TEXT NOT NULL, store_id UUID NOT NULL, pos_terminal_id UUID NOT NULL,
    cashier_session_id UUID NOT NULL, source_type TEXT NOT NULL,
    source_document_id UUID, amount NUMERIC(20,4) NOT NULL CHECK(amount>0),
    reason TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'POSTED',
    idempotency_key UUID NOT NULL, financial_event_id UUID,
    created_by UUID NOT NULL REFERENCES public.profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT cash_in_company_id_id_unique UNIQUE(company_id,id),
    CONSTRAINT cash_in_company_no_unique UNIQUE(company_id,document_no),
    CONSTRAINT cash_in_idempotency_unique UNIQUE(company_id,idempotency_key),
    CONSTRAINT cash_in_source_check CHECK(source_type IN (
        'DRAWER_TOP_UP','EXPENSE_RETURN','CASHIER_SHORTAGE_TOP_UP','OTHER_WITH_REASON'
    )),
    CONSTRAINT cash_in_status_check CHECK(status IN ('POSTED','REVERSED')),
    CONSTRAINT cash_in_reason_not_blank CHECK(btrim(reason)<>''),
    CONSTRAINT fk_cash_in_store FOREIGN KEY(company_id,store_id)
        REFERENCES public.stores(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_cash_in_terminal FOREIGN KEY(company_id,store_id,pos_terminal_id)
        REFERENCES public.pos_terminals(company_id,store_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_cash_in_session FOREIGN KEY(company_id,store_id,cashier_session_id)
        REFERENCES public.cashier_sessions(company_id,store_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_cash_in_event FOREIGN KEY(company_id,financial_event_id)
        REFERENCES public.financial_events(company_id,id) ON DELETE RESTRICT
);

CREATE TABLE public.cash_drawer_movements (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(), company_id UUID NOT NULL,
    store_id UUID NOT NULL, pos_terminal_id UUID NOT NULL,
    cashier_session_id UUID NOT NULL, direction TEXT NOT NULL,
    movement_type TEXT NOT NULL, amount NUMERIC(20,4) NOT NULL CHECK(amount>0),
    source_table TEXT NOT NULL, source_id UUID NOT NULL,
    expected_cash_after NUMERIC(20,4) NOT NULL,
    actor_id UUID NOT NULL REFERENCES public.profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT cash_drawer_movement_company_id_id_unique UNIQUE(company_id,id),
    CONSTRAINT cash_drawer_movement_source_unique
        UNIQUE(company_id,source_table,source_id),
    CONSTRAINT cash_drawer_movement_direction_check CHECK(direction IN ('IN','OUT')),
    CONSTRAINT cash_drawer_movement_type_check CHECK(movement_type IN (
        'EXPENSE_DISBURSEMENT','EXPENSE_RETURN','CASH_IN','REVERSAL'
    )),
    CONSTRAINT cash_drawer_movement_source_not_blank CHECK(btrim(source_table)<>''),
    CONSTRAINT fk_cash_drawer_store FOREIGN KEY(company_id,store_id)
        REFERENCES public.stores(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_cash_drawer_terminal FOREIGN KEY(company_id,store_id,pos_terminal_id)
        REFERENCES public.pos_terminals(company_id,store_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_cash_drawer_session FOREIGN KEY(company_id,store_id,cashier_session_id)
        REFERENCES public.cashier_sessions(company_id,store_id,id) ON DELETE RESTRICT
);
CREATE INDEX idx_cash_drawer_session_time
    ON public.cash_drawer_movements(company_id,cashier_session_id,created_at);

CREATE TABLE public.expense_audit (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_id UUID NOT NULL, entity_type TEXT NOT NULL,
    entity_id UUID NOT NULL, document_id UUID,
    action TEXT NOT NULL, actor_id UUID NOT NULL REFERENCES public.profiles(id),
    before_state JSONB, after_state JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT expense_audit_entity_type_check CHECK(entity_type IN (
        'CATEGORY','POLICY','DOCUMENT','DISBURSEMENT','SETTLEMENT','RETURN','CASH_IN'
    )),
    CONSTRAINT expense_audit_action_check CHECK(action IN (
        'CREATE','UPDATE','SUBMIT','AUTO_APPROVE','APPROVE','REJECT','CANCEL',
        'DISBURSE','SETTLE','RETURN_FUNDS','POST_CASH_IN','REVERSE'
    )),
    CONSTRAINT fk_expense_audit_document FOREIGN KEY(company_id,document_id)
        REFERENCES public.expense_documents(company_id,id) ON DELETE RESTRICT
);
CREATE INDEX idx_expense_audit_entity_time
    ON public.expense_audit(company_id,entity_type,entity_id,created_at DESC);

-- Conservative defaults: required approval and one system category. The
-- helper is also used by the Company INSERT trigger so a Company created after
-- this rollout receives the same safe defaults. Its trigger name sorts after
-- the existing G2 COA and Transaction Category provisioning triggers.
CREATE FUNCTION private.provision_expense_request_defaults(p_company_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE
    v_transaction_category_id UUID;
    v_expense_account_id UUID;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.companies
        WHERE id=p_company_id AND status='ACTIVE'
    ) THEN
        RETURN;
    END IF;

    INSERT INTO public.expense_approval_policies(
        company_id,approval_required
    ) VALUES (p_company_id,TRUE)
    ON CONFLICT DO NOTHING;

    SELECT tc.id INTO v_transaction_category_id
    FROM public.transaction_categories tc
    WHERE tc.company_id=p_company_id
      AND tc.system_key='EXPENSE_SETTLEMENT'
      AND tc.is_active
    ORDER BY tc.is_system_default DESC,tc.created_at,tc.id
    LIMIT 1;
    IF v_transaction_category_id IS NULL THEN
        RAISE EXCEPTION
            'EXPENSE_DEFAULT_TRANSACTION_CATEGORY_NOT_READY: %',p_company_id;
    END IF;

    SELECT coa.id INTO v_expense_account_id
    FROM public.chart_of_accounts coa
    WHERE coa.company_id=p_company_id
      AND coa.system_function_key='EXPENSE'
      AND coa.is_active
      AND coa.is_postable
    ORDER BY coa.is_system_account DESC,coa.account_code,coa.id
    LIMIT 1;

    INSERT INTO public.expense_categories(
        company_id,category_code,category_name,description,
        transaction_category_id,expense_account_id,is_system_default
    ) VALUES (
        p_company_id,'EXP-GENERAL','Biaya Operasional Umum',
        'Kategori bawaan untuk Expense operasional umum.',
        v_transaction_category_id,v_expense_account_id,TRUE
    ) ON CONFLICT DO NOTHING;
END;
$$;

CREATE FUNCTION private.trg_provision_expense_request_defaults()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
BEGIN
    PERFORM private.provision_expense_request_defaults(NEW.id);
    RETURN NEW;
END;
$$;

SELECT private.provision_expense_request_defaults(c.id)
FROM public.companies c
WHERE c.status='ACTIVE';

CREATE TRIGGER g4_provision_expense_request_defaults
AFTER INSERT ON public.companies
FOR EACH ROW
EXECUTE FUNCTION private.trg_provision_expense_request_defaults();

CREATE TRIGGER g4_provision_expense_request_defaults_on_activation
AFTER UPDATE OF status ON public.companies
FOR EACH ROW
WHEN (NEW.status='ACTIVE' AND OLD.status IS DISTINCT FROM NEW.status)
EXECUTE FUNCTION private.trg_provision_expense_request_defaults();

-- Legacy Cash Advance remains readable for compatibility. Disable only its
-- legacy Finance-event trigger; unrelated USER triggers must remain enabled.
DO $disable_legacy_cash_advance_trigger$
DECLARE
    v_trigger_name TEXT;
BEGIN
    FOR v_trigger_name IN
        SELECT t.tgname
        FROM pg_trigger t
        JOIN pg_class c ON c.oid=t.tgrelid
        JOIN pg_namespace n ON n.oid=c.relnamespace
        JOIN pg_proc p ON p.oid=t.tgfoid
        JOIN pg_namespace pn ON pn.oid=p.pronamespace
        WHERE n.nspname='public'
          AND c.relname='cash_advances'
          AND NOT t.tgisinternal
          AND pn.nspname='public'
          AND p.proname='trg_cash_advances_to_financial_events'
    LOOP
        EXECUTE format(
            'ALTER TABLE public.cash_advances DISABLE TRIGGER %I',
            v_trigger_name
        );
    END LOOP;
END
$disable_legacy_cash_advance_trigger$;

CREATE FUNCTION private.trg_expense_history_immutable()
RETURNS TRIGGER LANGUAGE plpgsql
SET search_path=public,pg_temp AS $$
BEGIN
    RAISE EXCEPTION 'EXPENSE_HISTORY_IMMUTABLE';
END;
$$;
CREATE TRIGGER expense_disbursements_immutable
BEFORE UPDATE OR DELETE ON public.expense_disbursements
FOR EACH ROW EXECUTE FUNCTION private.trg_expense_history_immutable();
CREATE TRIGGER expense_settlements_immutable
BEFORE UPDATE OR DELETE ON public.expense_settlements
FOR EACH ROW EXECUTE FUNCTION private.trg_expense_history_immutable();
CREATE TRIGGER expense_returns_immutable
BEFORE UPDATE OR DELETE ON public.expense_returns
FOR EACH ROW EXECUTE FUNCTION private.trg_expense_history_immutable();
CREATE TRIGGER cash_in_documents_immutable
BEFORE UPDATE OR DELETE ON public.cash_in_documents
FOR EACH ROW EXECUTE FUNCTION private.trg_expense_history_immutable();
CREATE TRIGGER cash_drawer_movements_immutable
BEFORE UPDATE OR DELETE ON public.cash_drawer_movements
FOR EACH ROW EXECUTE FUNCTION private.trg_expense_history_immutable();
CREATE TRIGGER expense_audit_immutable
BEFORE UPDATE OR DELETE ON public.expense_audit
FOR EACH ROW EXECUTE FUNCTION private.trg_expense_history_immutable();

CREATE FUNCTION private.resolve_expense_approval_required(
    p_company_id UUID,p_store_id UUID,p_category_id UUID
) RETURNS BOOLEAN LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_category TEXT; v_result BOOLEAN;
BEGIN
    SELECT approval_policy INTO v_category
    FROM public.expense_categories
    WHERE company_id=p_company_id AND id=p_category_id AND is_active;
    IF NOT FOUND THEN RAISE EXCEPTION 'ACTIVE_EXPENSE_CATEGORY_NOT_FOUND'; END IF;
    IF v_category='REQUIRED' THEN RETURN TRUE; END IF;
    IF v_category='NOT_REQUIRED' THEN RETURN FALSE; END IF;
    SELECT approval_required INTO v_result
    FROM public.expense_approval_policies
    WHERE company_id=p_company_id AND is_active
      AND (store_id=p_store_id OR store_id IS NULL)
    ORDER BY (store_id IS NOT NULL) DESC LIMIT 1;
    RETURN COALESCE(v_result,TRUE);
END;
$$;

CREATE FUNCTION public.save_expense_category(
    p_category_id UUID,p_master_version BIGINT,p_category_name TEXT,
    p_description TEXT,p_transaction_category_id UUID,p_expense_account_id UUID,
    p_evidence_policy TEXT,p_approval_policy TEXT,
    p_default_payment_method_id UUID,p_is_active BOOLEAN
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_actor UUID:=auth.uid(); v_company UUID:=public.private_active_company_id();
    v_id UUID; v_before JSONB; v_version BIGINT; v_code TEXT;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF NOT public.private_user_has_any_company_role(
        v_company,ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE','ACCOUNTING']::TEXT[]
    ) THEN RAISE EXCEPTION 'EXPENSE_CATEGORY_MANAGER_REQUIRED'; END IF;
    IF NULLIF(btrim(p_category_name),'') IS NULL THEN
        RAISE EXCEPTION 'EXPENSE_CATEGORY_NAME_REQUIRED'; END IF;
    IF upper(COALESCE(p_evidence_policy,'')) NOT IN ('OPTIONAL','REQUIRED') THEN
        RAISE EXCEPTION 'INVALID_EVIDENCE_POLICY'; END IF;
    IF upper(COALESCE(p_approval_policy,'')) NOT IN
       ('USE_DEFAULT','REQUIRED','NOT_REQUIRED') THEN
        RAISE EXCEPTION 'INVALID_APPROVAL_POLICY'; END IF;
    IF NOT EXISTS (SELECT 1 FROM public.transaction_categories
        WHERE company_id=v_company AND id=p_transaction_category_id
          AND system_key='EXPENSE_SETTLEMENT' AND is_active) THEN
        RAISE EXCEPTION 'EXPENSE_TRANSACTION_CATEGORY_NOT_FOUND'; END IF;
    IF p_expense_account_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.chart_of_accounts WHERE company_id=v_company
          AND id=p_expense_account_id AND is_active AND is_postable
          AND account_type IN ('EXPENSE','OTHER_EXPENSE')
    ) THEN RAISE EXCEPTION 'EXPENSE_ACCOUNT_NOT_FOUND'; END IF;
    IF p_default_payment_method_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.payment_methods WHERE company_id=v_company
          AND id=p_default_payment_method_id AND is_active
          AND method_type IN ('CASH','TRANSFER','QRIS','CARD','E_WALLET')
    ) THEN RAISE EXCEPTION 'EXPENSE_PAYMENT_METHOD_NOT_FOUND'; END IF;
    IF p_category_id IS NULL THEN
        v_id:=gen_random_uuid();
        v_code:='EXP-'||upper(substr(replace(v_id::TEXT,'-',''),1,12));
        INSERT INTO public.expense_categories(
            id,company_id,category_code,category_name,description,
            transaction_category_id,expense_account_id,evidence_policy,
            approval_policy,default_payment_method_id,is_active,created_by,updated_by
        ) VALUES (v_id,v_company,v_code,btrim(p_category_name),NULLIF(btrim(p_description),''),
            p_transaction_category_id,p_expense_account_id,upper(p_evidence_policy),
            upper(p_approval_policy),p_default_payment_method_id,
            COALESCE(p_is_active,TRUE),v_actor,v_actor);
        INSERT INTO public.expense_audit(company_id,entity_type,entity_id,action,
            actor_id,after_state) SELECT v_company,'CATEGORY',v_id,'CREATE',v_actor,
            to_jsonb(c) FROM public.expense_categories c WHERE c.id=v_id;
        v_version:=1;
    ELSE
        SELECT to_jsonb(c),c.master_version INTO v_before,v_version
        FROM public.expense_categories c
        WHERE company_id=v_company AND id=p_category_id FOR UPDATE;
        IF NOT FOUND THEN RAISE EXCEPTION 'EXPENSE_CATEGORY_NOT_FOUND'; END IF;
        IF p_master_version IS NULL OR p_master_version<>v_version THEN
            RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
        UPDATE public.expense_categories SET
            category_name=btrim(p_category_name),description=NULLIF(btrim(p_description),''),
            transaction_category_id=p_transaction_category_id,
            expense_account_id=p_expense_account_id,
            evidence_policy=upper(p_evidence_policy),approval_policy=upper(p_approval_policy),
            default_payment_method_id=p_default_payment_method_id,
            is_active=COALESCE(p_is_active,TRUE),master_version=master_version+1,
            updated_by=v_actor,updated_at=clock_timestamp()
        WHERE company_id=v_company AND id=p_category_id
        RETURNING id,master_version INTO v_id,v_version;
        INSERT INTO public.expense_audit(company_id,entity_type,entity_id,action,
            actor_id,before_state,after_state) SELECT v_company,'CATEGORY',v_id,
            'UPDATE',v_actor,v_before,to_jsonb(c)
            FROM public.expense_categories c WHERE c.id=v_id;
    END IF;
    RETURN jsonb_build_object('categoryId',v_id,'masterVersion',v_version);
END;
$$;

CREATE FUNCTION public.save_expense_approval_policy(
    p_store_id UUID,p_master_version BIGINT,p_approval_required BOOLEAN,
    p_is_active BOOLEAN
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_actor UUID:=auth.uid(); v_company UUID:=public.private_active_company_id();
    v_row public.expense_approval_policies%ROWTYPE; v_before JSONB;
BEGIN
    IF v_actor IS NULL OR v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF p_store_id IS NULL THEN
        IF NOT public.private_user_has_any_company_role(
            v_company,ARRAY['COMPANY_OWNER','COMPANY_ADMIN']::TEXT[]
        ) THEN RAISE EXCEPTION 'COMPANY_EXPENSE_POLICY_MANAGER_REQUIRED'; END IF;
    ELSE
        IF NOT EXISTS (SELECT 1 FROM public.stores WHERE company_id=v_company
            AND id=p_store_id AND status='ACTIVE') THEN
            RAISE EXCEPTION 'ACTIVE_STORE_NOT_FOUND'; END IF;
        IF NOT (public.private_user_has_any_company_role(
            v_company,ARRAY['COMPANY_OWNER','COMPANY_ADMIN']::TEXT[])
            OR public.private_user_has_any_store_role(
                p_store_id,ARRAY['STORE_MANAGER']::TEXT[])) THEN
            RAISE EXCEPTION 'STORE_EXPENSE_POLICY_MANAGER_REQUIRED'; END IF;
    END IF;
    SELECT * INTO v_row FROM public.expense_approval_policies
    WHERE company_id=v_company AND store_id IS NOT DISTINCT FROM p_store_id FOR UPDATE;
    IF FOUND THEN
        IF p_master_version IS NULL OR p_master_version<>v_row.master_version THEN
            RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
        v_before:=to_jsonb(v_row);
        UPDATE public.expense_approval_policies SET
            approval_required=COALESCE(p_approval_required,TRUE),
            is_active=COALESCE(p_is_active,TRUE),master_version=master_version+1,
            updated_by=v_actor,updated_at=clock_timestamp()
        WHERE id=v_row.id RETURNING * INTO v_row;
        INSERT INTO public.expense_audit(company_id,entity_type,entity_id,action,
            actor_id,before_state,after_state) VALUES (
            v_company,'POLICY',v_row.id,'UPDATE',v_actor,v_before,to_jsonb(v_row));
    ELSE
        INSERT INTO public.expense_approval_policies(
            company_id,store_id,approval_required,is_active,created_by,updated_by
        ) VALUES (v_company,p_store_id,COALESCE(p_approval_required,TRUE),
            COALESCE(p_is_active,TRUE),v_actor,v_actor) RETURNING * INTO v_row;
        INSERT INTO public.expense_audit(company_id,entity_type,entity_id,action,
            actor_id,after_state) VALUES (
            v_company,'POLICY',v_row.id,'CREATE',v_actor,to_jsonb(v_row));
    END IF;
    RETURN jsonb_build_object('policyId',v_row.id,'masterVersion',v_row.master_version);
END;
$$;

CREATE FUNCTION public.save_expense_draft(
    p_document_id UUID,p_master_version BIGINT,p_store_id UUID,
    p_cashier_session_id UUID,p_category_id UUID,p_responsible_party_type TEXT,
    p_responsible_party_id UUID,p_responsible_party_name TEXT,
    p_requested_amount NUMERIC,p_payment_method_id UUID,p_recipient TEXT,
    p_description TEXT,p_evidence_url TEXT,p_expected_settlement_date DATE,
    p_client_expense_id UUID
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_actor UUID:=auth.uid(); v_company UUID:=public.private_active_company_id();
    v_category public.expense_categories%ROWTYPE; v_method public.payment_methods%ROWTYPE;
    v_session public.cashier_sessions%ROWTYPE; v_doc public.expense_documents%ROWTYPE;
    v_id UUID; v_before JSONB; v_approval BOOLEAN; v_no TEXT;
BEGIN
    IF v_actor IS NULL OR v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF NOT public.private_company_feature_enabled(v_company,'expense_enabled') THEN
        RAISE EXCEPTION 'EXPENSE_FEATURE_DISABLED'; END IF;
    IF NOT public.private_user_has_store_access(p_store_id) THEN
        RAISE EXCEPTION 'EXPENSE_STORE_ACCESS_REQUIRED'; END IF;
    IF NOT EXISTS (SELECT 1 FROM public.stores WHERE company_id=v_company
        AND id=p_store_id AND status='ACTIVE') THEN RAISE EXCEPTION 'ACTIVE_STORE_NOT_FOUND'; END IF;
    IF p_document_id IS NULL AND p_client_expense_id IS NOT NULL THEN
        PERFORM pg_advisory_xact_lock(hashtextextended(
            'G4_EXPENSE_DRAFT|'||v_company::TEXT||'|'||
                p_client_expense_id::TEXT,0
        ));
        SELECT * INTO v_doc
        FROM public.expense_documents
        WHERE company_id=v_company AND client_expense_id=p_client_expense_id
        FOR UPDATE;
        IF FOUND THEN
            IF v_doc.created_by IS DISTINCT FROM v_actor
               OR v_doc.store_id IS DISTINCT FROM p_store_id
               OR v_doc.cashier_session_id IS DISTINCT FROM p_cashier_session_id
               OR v_doc.category_id IS DISTINCT FROM p_category_id
               OR v_doc.responsible_party_type IS DISTINCT FROM
                    upper(COALESCE(p_responsible_party_type,''))
               OR v_doc.responsible_party_id IS DISTINCT FROM p_responsible_party_id
               OR v_doc.responsible_party_name_snapshot IS DISTINCT FROM
                    btrim(COALESCE(p_responsible_party_name,''))
               OR v_doc.requested_amount IS DISTINCT FROM p_requested_amount
               OR v_doc.requested_payment_method_id IS DISTINCT FROM p_payment_method_id
               OR v_doc.recipient IS DISTINCT FROM NULLIF(btrim(p_recipient),'')
               OR v_doc.description IS DISTINCT FROM btrim(COALESCE(p_description,''))
               OR v_doc.evidence_url IS DISTINCT FROM p_evidence_url
               OR v_doc.expected_settlement_date IS DISTINCT FROM
                    p_expected_settlement_date THEN
                RAISE EXCEPTION 'CLIENT_EXPENSE_ID_CONFLICT';
            END IF;
            RETURN jsonb_build_object(
                'documentId',v_doc.id,'documentNo',v_doc.document_no,
                'status',v_doc.status,'masterVersion',v_doc.master_version,
                'idempotentReplay',TRUE
            );
        END IF;
    END IF;
    SELECT * INTO v_category FROM public.expense_categories
    WHERE company_id=v_company AND id=p_category_id AND is_active;
    IF NOT FOUND THEN RAISE EXCEPTION 'ACTIVE_EXPENSE_CATEGORY_NOT_FOUND'; END IF;
    SELECT * INTO v_method FROM public.payment_methods pm
    WHERE pm.company_id=v_company AND pm.id=p_payment_method_id AND pm.is_active
      AND pm.effective_from<=clock_timestamp()
      AND (pm.effective_to IS NULL OR pm.effective_to>clock_timestamp())
      AND pm.method_type IN ('CASH','TRANSFER','QRIS','CARD','E_WALLET')
      AND (pm.available_all_stores OR EXISTS(
          SELECT 1 FROM public.payment_method_store_assignments a
          WHERE a.company_id=v_company AND a.payment_method_id=pm.id
            AND a.store_id=p_store_id));
    IF NOT FOUND THEN RAISE EXCEPTION 'ACTIVE_EXPENSE_PAYMENT_METHOD_NOT_FOUND'; END IF;
    IF p_requested_amount IS NULL OR p_requested_amount<=0 THEN
        RAISE EXCEPTION 'EXPENSE_REQUESTED_AMOUNT_INVALID'; END IF;
    IF NULLIF(btrim(p_description),'') IS NULL THEN RAISE EXCEPTION 'EXPENSE_DESCRIPTION_REQUIRED'; END IF;
    IF NULLIF(btrim(p_responsible_party_name),'') IS NULL THEN
        RAISE EXCEPTION 'RESPONSIBLE_PARTY_REQUIRED'; END IF;
    IF upper(COALESCE(p_responsible_party_type,'')) NOT IN
       ('CASHIER','STORE_MANAGER','EMPLOYEE','EXTERNAL') THEN
        RAISE EXCEPTION 'RESPONSIBLE_PARTY_TYPE_INVALID'; END IF;
    IF upper(p_responsible_party_type)='EXTERNAL'
       AND p_responsible_party_id IS NOT NULL THEN
        RAISE EXCEPTION 'EXTERNAL_RESPONSIBLE_PARTY_ID_NOT_ALLOWED';
    END IF;
    IF upper(p_responsible_party_type)<>'EXTERNAL' AND (
        p_responsible_party_id IS NULL OR NOT EXISTS (
            SELECT 1
            FROM public.profiles responsible
            WHERE responsible.id=p_responsible_party_id
              AND (
                  responsible.role='super_admin'::public.user_role
                  OR EXISTS (
                      SELECT 1 FROM public.company_memberships cm
                      WHERE cm.company_id=v_company
                        AND cm.user_id=responsible.id
                        AND cm.status='ACTIVE'
                  )
                  OR EXISTS (
                      SELECT 1 FROM public.store_memberships sm
                      WHERE sm.company_id=v_company
                        AND sm.user_id=responsible.id
                        AND sm.status='ACTIVE'
                  )
              )
        )
    ) THEN
        RAISE EXCEPTION 'RESPONSIBLE_PARTY_NOT_IN_ACTIVE_COMPANY';
    END IF;
    IF p_evidence_url IS NOT NULL AND p_evidence_url !~* '^https://' THEN
        RAISE EXCEPTION 'EXPENSE_EVIDENCE_HTTPS_REQUIRED'; END IF;
    IF v_category.evidence_policy='REQUIRED' AND p_evidence_url IS NULL THEN
        RAISE EXCEPTION 'EXPENSE_EVIDENCE_REQUIRED'; END IF;
    IF v_method.method_type='CASH' THEN
        SELECT * INTO v_session FROM public.cashier_sessions
        WHERE company_id=v_company AND store_id=p_store_id
          AND id=p_cashier_session_id AND status='OPEN'::public.session_status;
        IF NOT FOUND THEN RAISE EXCEPTION 'OPEN_EXPENSE_SESSION_REQUIRED'; END IF;
        IF NOT EXISTS (
            SELECT 1 FROM public.pos_terminals terminal
            WHERE terminal.company_id=v_company
              AND terminal.store_id=p_store_id
              AND terminal.id=v_session.pos_id
              AND terminal.status='ACTIVE'
        ) THEN RAISE EXCEPTION 'ACTIVE_EXPENSE_TERMINAL_REQUIRED'; END IF;
        IF v_session.cashier_id<>v_actor AND NOT (
            public.private_user_has_any_company_role(
                v_company,ARRAY['COMPANY_OWNER','COMPANY_ADMIN']::TEXT[])
            OR public.private_user_has_any_store_role(
                p_store_id,ARRAY['STORE_MANAGER']::TEXT[])
        ) THEN RAISE EXCEPTION 'EXPENSE_SESSION_OPERATOR_REQUIRED'; END IF;
    ELSIF p_cashier_session_id IS NOT NULL THEN
        SELECT * INTO v_session FROM public.cashier_sessions
        WHERE company_id=v_company AND store_id=p_store_id AND id=p_cashier_session_id;
        IF NOT FOUND THEN RAISE EXCEPTION 'EXPENSE_SESSION_NOT_FOUND'; END IF;
    END IF;
    v_approval:=private.resolve_expense_approval_required(
        v_company,p_store_id,p_category_id);
    IF p_document_id IS NULL THEN
        v_id:=gen_random_uuid();
        v_no:='EXP-'||to_char(clock_timestamp(),'YYYYMMDD')||'-'||
            lpad(nextval('private.expense_document_number_seq')::TEXT,10,'0');
        INSERT INTO public.expense_documents(
            id,company_id,document_no,store_id,pos_terminal_id,cashier_session_id,
            category_id,category_name_snapshot,transaction_category_id,
            expense_account_id_snapshot,responsible_party_type,responsible_party_id,
            responsible_party_name_snapshot,requested_amount,
            requested_payment_method_id,requested_payment_method_name_snapshot,
            requested_payment_method_type_snapshot,recipient,description,evidence_url,
            expected_settlement_date,approval_required_snapshot,
            evidence_policy_snapshot,client_expense_id,created_by,updated_by
        ) VALUES (v_id,v_company,v_no,p_store_id,v_session.pos_id,p_cashier_session_id,
            v_category.id,v_category.category_name,v_category.transaction_category_id,
            v_category.expense_account_id,upper(p_responsible_party_type),
            p_responsible_party_id,btrim(p_responsible_party_name),p_requested_amount,
            v_method.id,v_method.payment_method_name,v_method.method_type,
            NULLIF(btrim(p_recipient),''),btrim(p_description),p_evidence_url,
            p_expected_settlement_date,v_approval,v_category.evidence_policy,
            p_client_expense_id,v_actor,v_actor) RETURNING * INTO v_doc;
        INSERT INTO public.expense_audit(company_id,entity_type,entity_id,document_id,
            action,actor_id,after_state) VALUES (
            v_company,'DOCUMENT',v_id,v_id,'CREATE',v_actor,to_jsonb(v_doc));
    ELSE
        SELECT * INTO v_doc FROM public.expense_documents
        WHERE company_id=v_company AND id=p_document_id FOR UPDATE;
        IF NOT FOUND THEN RAISE EXCEPTION 'EXPENSE_DOCUMENT_NOT_FOUND'; END IF;
        IF v_doc.status<>'DRAFT' THEN RAISE EXCEPTION 'ONLY_DRAFT_EXPENSE_EDITABLE'; END IF;
        IF v_doc.created_by<>v_actor AND NOT (
            public.private_user_has_any_company_role(
                v_company,ARRAY['COMPANY_OWNER','COMPANY_ADMIN']::TEXT[])
            OR public.private_user_has_any_store_role(
                v_doc.store_id,ARRAY['STORE_MANAGER']::TEXT[])
        ) THEN RAISE EXCEPTION 'EXPENSE_DRAFT_EDITOR_REQUIRED'; END IF;
        IF p_master_version IS NULL OR p_master_version<>v_doc.master_version THEN
            RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
        v_before:=to_jsonb(v_doc);
        UPDATE public.expense_documents SET store_id=p_store_id,
            pos_terminal_id=v_session.pos_id,cashier_session_id=p_cashier_session_id,
            category_id=v_category.id,category_name_snapshot=v_category.category_name,
            transaction_category_id=v_category.transaction_category_id,
            expense_account_id_snapshot=v_category.expense_account_id,
            responsible_party_type=upper(p_responsible_party_type),
            responsible_party_id=p_responsible_party_id,
            responsible_party_name_snapshot=btrim(p_responsible_party_name),
            requested_amount=p_requested_amount,
            requested_payment_method_id=v_method.id,
            requested_payment_method_name_snapshot=v_method.payment_method_name,
            requested_payment_method_type_snapshot=v_method.method_type,
            recipient=NULLIF(btrim(p_recipient),''),description=btrim(p_description),
            evidence_url=p_evidence_url,expected_settlement_date=p_expected_settlement_date,
            approval_required_snapshot=v_approval,evidence_policy_snapshot=v_category.evidence_policy,
            master_version=master_version+1,updated_by=v_actor,updated_at=clock_timestamp()
        WHERE company_id=v_company AND id=p_document_id RETURNING * INTO v_doc;
        INSERT INTO public.expense_audit(company_id,entity_type,entity_id,document_id,
            action,actor_id,before_state,after_state) VALUES (
            v_company,'DOCUMENT',v_doc.id,v_doc.id,'UPDATE',v_actor,v_before,to_jsonb(v_doc));
    END IF;
    RETURN jsonb_build_object('documentId',v_doc.id,'documentNo',v_doc.document_no,
        'status',v_doc.status,'masterVersion',v_doc.master_version);
END;
$$;

CREATE FUNCTION public.submit_expense_request(
    p_document_id UUID,p_master_version BIGINT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_actor UUID:=auth.uid(); v_company UUID:=public.private_active_company_id();
    v_doc public.expense_documents%ROWTYPE; v_before JSONB; v_action TEXT;
BEGIN
    IF v_actor IS NULL OR v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF NOT public.private_company_feature_enabled(v_company,'expense_enabled') THEN
        RAISE EXCEPTION 'EXPENSE_FEATURE_DISABLED'; END IF;
    SELECT * INTO v_doc FROM public.expense_documents
    WHERE company_id=v_company AND id=p_document_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'EXPENSE_DOCUMENT_NOT_FOUND'; END IF;
    IF v_doc.status<>'DRAFT' THEN RAISE EXCEPTION 'ONLY_DRAFT_EXPENSE_SUBMITTABLE'; END IF;
    IF v_doc.created_by<>v_actor AND NOT (
        public.private_user_has_any_company_role(
            v_company,ARRAY['COMPANY_OWNER','COMPANY_ADMIN']::TEXT[])
        OR public.private_user_has_any_store_role(
            v_doc.store_id,ARRAY['STORE_MANAGER']::TEXT[])
    ) THEN RAISE EXCEPTION 'EXPENSE_SUBMITTER_REQUIRED'; END IF;
    IF p_master_version IS NULL OR p_master_version<>v_doc.master_version THEN
        RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
    v_before:=to_jsonb(v_doc);
    IF v_doc.approval_required_snapshot THEN
        UPDATE public.expense_documents SET status='SUBMITTED',submitted_by=v_actor,
            submitted_at=clock_timestamp(),master_version=master_version+1,
            updated_by=v_actor,updated_at=clock_timestamp()
        WHERE id=v_doc.id RETURNING * INTO v_doc;
        v_action:='SUBMIT';
    ELSE
        UPDATE public.expense_documents SET status='APPROVED',submitted_by=v_actor,
            submitted_at=clock_timestamp(),approved_by=v_actor,
            approved_at=clock_timestamp(),master_version=master_version+1,
            updated_by=v_actor,updated_at=clock_timestamp()
        WHERE id=v_doc.id RETURNING * INTO v_doc;
        v_action:='AUTO_APPROVE';
    END IF;
    INSERT INTO public.expense_audit(company_id,entity_type,entity_id,document_id,
        action,actor_id,before_state,after_state) VALUES (
        v_company,'DOCUMENT',v_doc.id,v_doc.id,v_action,v_actor,v_before,to_jsonb(v_doc));
    RETURN jsonb_build_object('documentId',v_doc.id,'status',v_doc.status,
        'masterVersion',v_doc.master_version);
END;
$$;

CREATE FUNCTION public.review_expense_request(
    p_document_id UUID,p_master_version BIGINT,p_approve BOOLEAN,p_reason TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_actor UUID:=auth.uid(); v_company UUID:=public.private_active_company_id();
    v_doc public.expense_documents%ROWTYPE; v_before JSONB; v_action TEXT;
BEGIN
    IF v_actor IS NULL OR v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    SELECT * INTO v_doc FROM public.expense_documents
    WHERE company_id=v_company AND id=p_document_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'EXPENSE_DOCUMENT_NOT_FOUND'; END IF;
    IF v_doc.status<>'SUBMITTED' THEN RAISE EXCEPTION 'ONLY_SUBMITTED_EXPENSE_REVIEWABLE'; END IF;
    IF NOT (
        public.private_user_has_any_company_role(v_company,
            ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE']::TEXT[])
        OR public.private_user_has_any_store_role(v_doc.store_id,
            ARRAY['STORE_MANAGER']::TEXT[])
    ) THEN RAISE EXCEPTION 'EXPENSE_APPROVER_REQUIRED'; END IF;
    IF p_master_version IS NULL OR p_master_version<>v_doc.master_version THEN
        RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
    IF NOT COALESCE(p_approve,FALSE) AND NULLIF(btrim(p_reason),'') IS NULL THEN
        RAISE EXCEPTION 'EXPENSE_REJECTION_REASON_REQUIRED'; END IF;
    v_before:=to_jsonb(v_doc);
    IF COALESCE(p_approve,FALSE) THEN
        UPDATE public.expense_documents SET status='APPROVED',approved_by=v_actor,
            approved_at=clock_timestamp(),master_version=master_version+1,
            updated_by=v_actor,updated_at=clock_timestamp()
        WHERE id=v_doc.id RETURNING * INTO v_doc; v_action:='APPROVE';
    ELSE
        UPDATE public.expense_documents SET status='REJECTED',rejected_by=v_actor,
            rejected_at=clock_timestamp(),rejection_reason=btrim(p_reason),
            master_version=master_version+1,updated_by=v_actor,
            updated_at=clock_timestamp()
        WHERE id=v_doc.id RETURNING * INTO v_doc; v_action:='REJECT';
    END IF;
    INSERT INTO public.expense_audit(company_id,entity_type,entity_id,document_id,
        action,actor_id,before_state,after_state) VALUES (
        v_company,'DOCUMENT',v_doc.id,v_doc.id,v_action,v_actor,v_before,to_jsonb(v_doc));
    RETURN jsonb_build_object('documentId',v_doc.id,'status',v_doc.status,
        'masterVersion',v_doc.master_version);
END;
$$;

CREATE FUNCTION public.cancel_expense_request(
    p_document_id UUID,p_master_version BIGINT,p_reason TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_actor UUID:=auth.uid(); v_company UUID:=public.private_active_company_id();
    v_doc public.expense_documents%ROWTYPE; v_before JSONB;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF NULLIF(btrim(p_reason),'') IS NULL THEN RAISE EXCEPTION 'CANCEL_REASON_REQUIRED'; END IF;
    SELECT * INTO v_doc FROM public.expense_documents
    WHERE company_id=v_company AND id=p_document_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'EXPENSE_DOCUMENT_NOT_FOUND'; END IF;
    IF v_doc.status NOT IN ('DRAFT','SUBMITTED') THEN
        RAISE EXCEPTION 'EXPENSE_CANCEL_NOT_ALLOWED'; END IF;
    IF v_doc.created_by<>v_actor AND NOT (
        public.private_user_has_any_company_role(
            v_company,ARRAY['COMPANY_OWNER','COMPANY_ADMIN']::TEXT[])
        OR public.private_user_has_any_store_role(
            v_doc.store_id,ARRAY['STORE_MANAGER']::TEXT[])
    ) THEN RAISE EXCEPTION 'EXPENSE_CANCELER_REQUIRED'; END IF;
    IF p_master_version IS NULL OR p_master_version<>v_doc.master_version THEN
        RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
    v_before:=to_jsonb(v_doc);
    UPDATE public.expense_documents SET status='CANCELED',canceled_by=v_actor,
        canceled_at=clock_timestamp(),cancel_reason=btrim(p_reason),
        master_version=master_version+1,updated_by=v_actor,updated_at=clock_timestamp()
    WHERE id=v_doc.id RETURNING * INTO v_doc;
    INSERT INTO public.expense_audit(company_id,entity_type,entity_id,document_id,
        action,actor_id,before_state,after_state) VALUES (
        v_company,'DOCUMENT',v_doc.id,v_doc.id,'CANCEL',v_actor,v_before,to_jsonb(v_doc));
    RETURN jsonb_build_object('documentId',v_doc.id,'status',v_doc.status,
        'masterVersion',v_doc.master_version);
END;
$$;

REVOKE ALL ON FUNCTION private.provision_expense_request_defaults(UUID),
    private.trg_provision_expense_request_defaults(),
    private.trg_expense_history_immutable(),
    private.resolve_expense_approval_required(UUID,UUID,UUID)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.provision_expense_request_defaults(UUID),
    private.trg_provision_expense_request_defaults(),
    private.trg_expense_history_immutable(),
    private.resolve_expense_approval_required(UUID,UUID,UUID) TO service_role;

REVOKE ALL ON FUNCTION public.save_expense_category(
    UUID,BIGINT,TEXT,TEXT,UUID,UUID,TEXT,TEXT,UUID,BOOLEAN
), public.save_expense_approval_policy(UUID,BIGINT,BOOLEAN,BOOLEAN),
public.save_expense_draft(
    UUID,BIGINT,UUID,UUID,UUID,TEXT,UUID,TEXT,NUMERIC,UUID,TEXT,TEXT,TEXT,DATE,UUID
), public.submit_expense_request(UUID,BIGINT),
public.review_expense_request(UUID,BIGINT,BOOLEAN,TEXT),
public.cancel_expense_request(UUID,BIGINT,TEXT)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.save_expense_category(
    UUID,BIGINT,TEXT,TEXT,UUID,UUID,TEXT,TEXT,UUID,BOOLEAN
), public.save_expense_approval_policy(UUID,BIGINT,BOOLEAN,BOOLEAN),
public.save_expense_draft(
    UUID,BIGINT,UUID,UUID,UUID,TEXT,UUID,TEXT,NUMERIC,UUID,TEXT,TEXT,TEXT,DATE,UUID
), public.submit_expense_request(UUID,BIGINT),
public.review_expense_request(UUID,BIGINT,BOOLEAN,TEXT),
public.cancel_expense_request(UUID,BIGINT,TEXT)
TO authenticated,service_role;

ALTER TABLE public.expense_categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.expense_approval_policies ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.expense_documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.expense_disbursements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.expense_settlements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.expense_returns ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cash_in_documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cash_drawer_movements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.expense_audit ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Expense categories readable in active Company"
ON public.expense_categories FOR SELECT TO authenticated USING(
    public.private_request_company_matches(company_id)
    AND public.private_user_has_company_access(company_id)
);
CREATE POLICY "Expense policies readable by managers"
ON public.expense_approval_policies FOR SELECT TO authenticated USING(
    public.private_request_company_matches(company_id)
    AND (public.private_user_has_any_company_role(company_id,
        ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE','ACCOUNTING']::TEXT[])
        OR (store_id IS NOT NULL AND public.private_user_has_any_store_role(
            store_id,ARRAY['STORE_MANAGER']::TEXT[])))
);
CREATE POLICY "Expense documents readable by participant or reviewer"
ON public.expense_documents FOR SELECT TO authenticated USING(
    public.private_request_company_matches(company_id)
    AND (created_by=auth.uid() OR responsible_party_id=auth.uid()
        OR public.private_user_has_any_company_role(company_id,
            ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE','ACCOUNTING']::TEXT[])
        OR public.private_user_has_any_store_role(store_id,
            ARRAY['STORE_MANAGER']::TEXT[]))
);
CREATE POLICY "Expense event rows readable through document"
ON public.expense_disbursements FOR SELECT TO authenticated USING(EXISTS(
    SELECT 1 FROM public.expense_documents d
    WHERE d.company_id=expense_disbursements.company_id
      AND d.id=expense_disbursements.document_id
));
CREATE POLICY "Expense settlements readable through document"
ON public.expense_settlements FOR SELECT TO authenticated USING(EXISTS(
    SELECT 1 FROM public.expense_documents d
    WHERE d.company_id=expense_settlements.company_id
      AND d.id=expense_settlements.document_id
));
CREATE POLICY "Expense returns readable through document"
ON public.expense_returns FOR SELECT TO authenticated USING(EXISTS(
    SELECT 1 FROM public.expense_documents d
    WHERE d.company_id=expense_returns.company_id
      AND d.id=expense_returns.document_id
));
CREATE POLICY "Cash In readable in visible Store"
ON public.cash_in_documents FOR SELECT TO authenticated USING(
    public.private_request_company_matches(company_id)
    AND public.private_user_has_store_access(store_id)
);
CREATE POLICY "Drawer movement readable by reviewers"
ON public.cash_drawer_movements FOR SELECT TO authenticated USING(
    public.private_request_company_matches(company_id)
    AND (public.private_user_has_any_company_role(company_id,
        ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE','ACCOUNTING']::TEXT[])
        OR public.private_user_has_any_store_role(store_id,
            ARRAY['STORE_MANAGER']::TEXT[]))
);
CREATE POLICY "Expense audit readable by reviewers"
ON public.expense_audit FOR SELECT TO authenticated USING(
    public.private_request_company_matches(company_id)
    AND public.private_user_has_any_company_role(company_id,
        ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE','ACCOUNTING']::TEXT[])
);

REVOKE ALL ON public.expense_categories,public.expense_approval_policies,
    public.expense_documents,public.expense_disbursements,
    public.expense_settlements,public.expense_returns,
    public.cash_in_documents,public.cash_drawer_movements,
    public.expense_audit FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.expense_categories,public.expense_approval_policies,
    public.expense_documents,public.expense_disbursements,
    public.expense_settlements,public.expense_returns,
    public.cash_in_documents,public.cash_drawer_movements,
    public.expense_audit TO authenticated;
GRANT ALL ON public.expense_categories,public.expense_approval_policies,
    public.expense_documents,public.expense_disbursements,
    public.expense_settlements,public.expense_returns,
    public.cash_in_documents,public.cash_drawer_movements,
    public.expense_audit TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES ('20260803040000','g4_phase30_expense_request_approval_foundation',
    'Canonical Expense category/policy and guarded Draft/Submit/Review/Cancel; cash mutation and Finance posting remain closed');

COMMIT;
