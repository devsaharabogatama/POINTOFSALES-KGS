-- KGS POS G4 phase 37: Expense actual/return/outstanding foundation.
-- Requirement: POS-007
-- Dependency: G4 phase 34 initial disbursement foundation.
--
-- BOUNDARY:
-- - actual Expense is proposed, then reviewed before changing document totals;
-- - approved actual and returned funds are immutable append-only facts;
-- - Cash return creates one Cash In and one drawer IN in an OPEN Session;
-- - non-Cash return never changes the drawer;
-- - additional disbursement is request-only in this phase and never pays out;
-- - Offline Expense, correction/reversal, Deposit, and G6 journal stay closed.

BEGIN;

DO $migration_guard$
BEGIN
    IF to_regclass('private.kgs_schema_migrations') IS NULL
       OR NOT EXISTS (
           SELECT 1 FROM private.kgs_schema_migrations
           WHERE version='20260803070000'
       ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: G4 phase 34 is incomplete';
    END IF;
    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version='20260803100000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260803100000';
    END IF;
    IF EXISTS (SELECT 1 FROM public.expense_settlements)
       OR EXISTS (SELECT 1 FROM public.expense_returns)
       OR to_regclass('public.expense_settlement_requests') IS NOT NULL
       OR to_regclass(
           'public.expense_additional_disbursement_requests'
       ) IS NOT NULL THEN
        RAISE EXCEPTION
            'G4_PHASE37_STATE_CHANGED: settlement/return runtime is not empty';
    END IF;
END
$migration_guard$;

ALTER TYPE public.event_type
    ADD VALUE IF NOT EXISTS 'EXPENSE_SETTLEMENT';
ALTER TYPE public.event_type
    ADD VALUE IF NOT EXISTS 'EXPENSE_RETURN';

ALTER TABLE public.expense_documents
    ADD COLUMN disbursed_by UUID REFERENCES public.profiles(id),
    ADD COLUMN disbursed_at TIMESTAMPTZ,
    ADD COLUMN settled_by UUID REFERENCES public.profiles(id),
    ADD COLUMN settled_at TIMESTAMPTZ,
    ADD CONSTRAINT expense_document_disbursement_time_shape CHECK (
        (disbursed_amount=0 AND disbursed_by IS NULL AND disbursed_at IS NULL)
        OR (disbursed_amount>0 AND disbursed_by IS NOT NULL
            AND disbursed_at IS NOT NULL)
    ) NOT VALID,
    ADD CONSTRAINT expense_document_settlement_time_shape CHECK (
        (status IN ('SETTLED','SETTLED_NO_EXPENSE')
         AND settled_by IS NOT NULL AND settled_at IS NOT NULL)
        OR (status NOT IN ('SETTLED','SETTLED_NO_EXPENSE')
            AND settled_by IS NULL AND settled_at IS NULL)
    ) NOT VALID;

UPDATE public.expense_documents document
SET disbursed_by=source.created_by,disbursed_at=source.created_at
FROM (
    SELECT DISTINCT ON (row.company_id,row.document_id)
        row.company_id,row.document_id,row.created_by,row.created_at
    FROM public.expense_disbursements row
    ORDER BY row.company_id,row.document_id,row.created_at,row.id
) source
WHERE document.company_id=source.company_id
  AND document.id=source.document_id
  AND document.disbursed_amount>0;

ALTER TABLE public.expense_documents
    VALIDATE CONSTRAINT expense_document_disbursement_time_shape;
ALTER TABLE public.expense_documents
    VALIDATE CONSTRAINT expense_document_settlement_time_shape;

CREATE FUNCTION private.trg_expense_document_lifecycle_timestamps()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path=public,pg_temp
AS $$
BEGIN
    IF NEW.disbursed_amount>0 AND OLD.disbursed_amount=0 THEN
        NEW.disbursed_by:=COALESCE(NEW.disbursed_by,auth.uid());
        NEW.disbursed_at:=COALESCE(NEW.disbursed_at,clock_timestamp());
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER expense_document_lifecycle_timestamps
BEFORE UPDATE ON public.expense_documents
FOR EACH ROW EXECUTE FUNCTION
    private.trg_expense_document_lifecycle_timestamps();

ALTER TABLE public.expense_settlements
    ADD COLUMN store_id UUID NOT NULL,
    ADD COLUMN transaction_category_id UUID NOT NULL,
    ADD COLUMN outstanding_account_id_snapshot UUID NOT NULL,
    ADD COLUMN document_master_version_snapshot BIGINT NOT NULL,
    ADD CONSTRAINT expense_settlement_document_version_positive CHECK (
        document_master_version_snapshot>0
    ),
    ADD CONSTRAINT fk_expense_settlement_store
        FOREIGN KEY(company_id,store_id)
        REFERENCES public.stores(company_id,id) ON DELETE RESTRICT,
    ADD CONSTRAINT fk_expense_settlement_transaction_category
        FOREIGN KEY(company_id,transaction_category_id)
        REFERENCES public.transaction_categories(company_id,id)
        ON DELETE RESTRICT,
    ADD CONSTRAINT fk_expense_settlement_outstanding_account
        FOREIGN KEY(company_id,outstanding_account_id_snapshot)
        REFERENCES public.chart_of_accounts(company_id,id)
        ON DELETE RESTRICT;

ALTER TABLE public.expense_returns
    ADD COLUMN store_id UUID NOT NULL,
    ADD COLUMN pos_terminal_id UUID,
    ADD COLUMN payment_settlement_route_snapshot TEXT NOT NULL,
    ADD COLUMN payment_account_function_snapshot TEXT NOT NULL,
    ADD COLUMN transaction_category_id UUID NOT NULL,
    ADD COLUMN outstanding_account_id_snapshot UUID NOT NULL,
    ADD COLUMN payment_account_id_snapshot UUID NOT NULL,
    ADD COLUMN document_master_version_snapshot BIGINT NOT NULL,
    ADD CONSTRAINT expense_return_route_check CHECK (
        (payment_method_type_snapshot='CASH'
         AND payment_settlement_route_snapshot='CASH_DRAWER'
         AND receiving_session_id IS NOT NULL
         AND pos_terminal_id IS NOT NULL)
        OR
        (payment_method_type_snapshot IN (
            'TRANSFER','QRIS','CARD','E_WALLET'
         ) AND payment_settlement_route_snapshot IN ('DIRECT_BANK','CLEARING')
         AND receiving_session_id IS NULL AND pos_terminal_id IS NULL)
    ),
    ADD CONSTRAINT expense_return_account_function_not_blank CHECK (
        btrim(payment_account_function_snapshot)<>''
    ),
    ADD CONSTRAINT expense_return_document_version_positive CHECK (
        document_master_version_snapshot>0
    ),
    ADD CONSTRAINT fk_expense_return_store
        FOREIGN KEY(company_id,store_id)
        REFERENCES public.stores(company_id,id) ON DELETE RESTRICT,
    ADD CONSTRAINT fk_expense_return_terminal
        FOREIGN KEY(company_id,store_id,pos_terminal_id)
        REFERENCES public.pos_terminals(company_id,store_id,id)
        ON DELETE RESTRICT,
    ADD CONSTRAINT fk_expense_return_store_session
        FOREIGN KEY(company_id,store_id,receiving_session_id)
        REFERENCES public.cashier_sessions(company_id,store_id,id)
        ON DELETE RESTRICT,
    ADD CONSTRAINT fk_expense_return_transaction_category
        FOREIGN KEY(company_id,transaction_category_id)
        REFERENCES public.transaction_categories(company_id,id)
        ON DELETE RESTRICT,
    ADD CONSTRAINT fk_expense_return_outstanding_account
        FOREIGN KEY(company_id,outstanding_account_id_snapshot)
        REFERENCES public.chart_of_accounts(company_id,id)
        ON DELETE RESTRICT,
    ADD CONSTRAINT fk_expense_return_payment_account
        FOREIGN KEY(company_id,payment_account_id_snapshot)
        REFERENCES public.chart_of_accounts(company_id,id)
        ON DELETE RESTRICT;

CREATE TABLE public.expense_settlement_requests (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL,
    document_id UUID NOT NULL,
    store_id UUID NOT NULL,
    actual_expense_amount NUMERIC(20,4) NOT NULL,
    category_id UUID NOT NULL,
    category_name_snapshot TEXT NOT NULL,
    expense_account_id_snapshot UUID,
    evidence_url TEXT,
    status TEXT NOT NULL DEFAULT 'SUBMITTED',
    idempotency_key UUID NOT NULL,
    document_master_version_snapshot BIGINT NOT NULL,
    submitted_by UUID NOT NULL REFERENCES public.profiles(id),
    reviewed_by UUID REFERENCES public.profiles(id),
    submitted_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    reviewed_at TIMESTAMPTZ,
    rejection_reason TEXT,
    master_version BIGINT NOT NULL DEFAULT 1,
    CONSTRAINT expense_settlement_request_company_id_id_unique
        UNIQUE(company_id,id),
    CONSTRAINT expense_settlement_request_idempotency_unique
        UNIQUE(company_id,idempotency_key),
    CONSTRAINT expense_settlement_request_amount_positive CHECK (
        actual_expense_amount>0
    ),
    CONSTRAINT expense_settlement_request_status_check CHECK (
        status IN ('SUBMITTED','APPROVED','REJECTED')
    ),
    CONSTRAINT expense_settlement_request_review_shape CHECK (
        (status='SUBMITTED' AND reviewed_by IS NULL AND reviewed_at IS NULL
         AND rejection_reason IS NULL)
        OR (status='APPROVED' AND reviewed_by IS NOT NULL
            AND reviewed_at IS NOT NULL AND rejection_reason IS NULL)
        OR (status='REJECTED' AND reviewed_by IS NOT NULL
            AND reviewed_at IS NOT NULL
            AND btrim(rejection_reason)<>'')
    ),
    CONSTRAINT expense_settlement_request_url_check CHECK (
        evidence_url IS NULL OR evidence_url~*'^https://'
    ),
    CONSTRAINT expense_settlement_request_version_positive CHECK (
        document_master_version_snapshot>0 AND master_version>0
    ),
    CONSTRAINT fk_expense_settlement_request_document
        FOREIGN KEY(company_id,document_id)
        REFERENCES public.expense_documents(company_id,id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_expense_settlement_request_store
        FOREIGN KEY(company_id,store_id)
        REFERENCES public.stores(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_expense_settlement_request_category
        FOREIGN KEY(company_id,category_id)
        REFERENCES public.expense_categories(company_id,id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_expense_settlement_request_account
        FOREIGN KEY(company_id,expense_account_id_snapshot)
        REFERENCES public.chart_of_accounts(company_id,id)
        ON DELETE RESTRICT
);
CREATE UNIQUE INDEX uq_expense_settlement_request_open_document
    ON public.expense_settlement_requests(company_id,document_id)
    WHERE status='SUBMITTED';
CREATE INDEX idx_expense_settlement_request_store_status
    ON public.expense_settlement_requests(
        company_id,store_id,status,submitted_at DESC
    );

CREATE TABLE public.expense_additional_disbursement_requests (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL,
    document_id UUID NOT NULL,
    store_id UUID NOT NULL,
    amount NUMERIC(20,4) NOT NULL,
    payment_method_id UUID NOT NULL,
    payment_method_name_snapshot TEXT NOT NULL,
    payment_method_type_snapshot TEXT NOT NULL,
    evidence_url TEXT,
    approval_required_snapshot BOOLEAN NOT NULL,
    status TEXT NOT NULL,
    idempotency_key UUID NOT NULL,
    document_master_version_snapshot BIGINT NOT NULL,
    requested_by UUID NOT NULL REFERENCES public.profiles(id),
    approved_by UUID REFERENCES public.profiles(id),
    requested_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    approved_at TIMESTAMPTZ,
    master_version BIGINT NOT NULL DEFAULT 1,
    CONSTRAINT expense_additional_request_company_id_id_unique
        UNIQUE(company_id,id),
    CONSTRAINT expense_additional_request_idempotency_unique
        UNIQUE(company_id,idempotency_key),
    CONSTRAINT expense_additional_request_amount_positive CHECK(amount>0),
    CONSTRAINT expense_additional_request_payment_type_check CHECK (
        payment_method_type_snapshot IN (
            'CASH','TRANSFER','QRIS','CARD','E_WALLET'
        )
    ),
    CONSTRAINT expense_additional_request_status_check CHECK (
        status IN ('SUBMITTED','APPROVED','DISBURSED','REJECTED','CANCELED')
    ),
    CONSTRAINT expense_additional_request_approval_shape CHECK (
        (status='SUBMITTED' AND approval_required_snapshot
         AND approved_by IS NULL AND approved_at IS NULL)
        OR (status='APPROVED' AND approved_by IS NOT NULL
            AND approved_at IS NOT NULL)
        OR status IN ('DISBURSED','REJECTED','CANCELED')
    ),
    CONSTRAINT expense_additional_request_url_check CHECK (
        evidence_url IS NULL OR evidence_url~*'^https://'
    ),
    CONSTRAINT expense_additional_request_version_positive CHECK (
        document_master_version_snapshot>0 AND master_version>0
    ),
    CONSTRAINT fk_expense_additional_request_document
        FOREIGN KEY(company_id,document_id)
        REFERENCES public.expense_documents(company_id,id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_expense_additional_request_store
        FOREIGN KEY(company_id,store_id)
        REFERENCES public.stores(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_expense_additional_request_payment
        FOREIGN KEY(company_id,payment_method_id)
        REFERENCES public.payment_methods(company_id,id)
        ON DELETE RESTRICT
);
CREATE UNIQUE INDEX uq_expense_additional_request_open_document
    ON public.expense_additional_disbursement_requests(company_id,document_id)
    WHERE status IN ('SUBMITTED','APPROVED');

ALTER TABLE public.expense_settlement_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.expense_additional_disbursement_requests
    ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Expense settlement request readable in active Company"
ON public.expense_settlement_requests FOR SELECT TO authenticated
USING (EXISTS (
    SELECT 1 FROM public.expense_documents document
    WHERE document.company_id=expense_settlement_requests.company_id
      AND document.id=expense_settlement_requests.document_id
));
CREATE POLICY "Expense additional request readable in active Company"
ON public.expense_additional_disbursement_requests FOR SELECT TO authenticated
USING (EXISTS (
    SELECT 1 FROM public.expense_documents document
    WHERE document.company_id=
        expense_additional_disbursement_requests.company_id
      AND document.id=expense_additional_disbursement_requests.document_id
));

REVOKE ALL ON public.expense_settlement_requests,
    public.expense_additional_disbursement_requests
FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.expense_settlement_requests,
    public.expense_additional_disbursement_requests TO authenticated;
GRANT ALL ON public.expense_settlement_requests,
    public.expense_additional_disbursement_requests TO service_role;

CREATE FUNCTION private.expense_status_from_totals(
    p_disbursed NUMERIC,p_actual NUMERIC,p_returned NUMERIC
)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
SET search_path=public,pg_temp
AS $$
DECLARE
    v_outstanding NUMERIC:=p_disbursed-p_actual-p_returned;
BEGIN
    IF p_disbursed<=0 OR p_actual<0 OR p_returned<0 OR v_outstanding<0 THEN
        RAISE EXCEPTION 'EXPENSE_TOTALS_INVALID';
    END IF;
    IF v_outstanding=0 THEN
        IF p_actual=0 THEN RETURN 'SETTLED_NO_EXPENSE'; END IF;
        RETURN 'SETTLED';
    END IF;
    IF p_actual>0 OR p_returned>0 THEN RETURN 'PARTIALLY_SETTLED'; END IF;
    RETURN 'DISBURSED';
END;
$$;

CREATE FUNCTION public.save_expense_settlement(
    p_document_id UUID,p_master_version BIGINT,
    p_actual_expense_amount NUMERIC,p_evidence_url TEXT,
    p_idempotency_key UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE
    v_actor UUID:=auth.uid();
    v_company UUID:=public.private_active_company_id();
    v_document public.expense_documents%ROWTYPE;
    v_existing public.expense_settlement_requests%ROWTYPE;
    v_request_id UUID:=gen_random_uuid();
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF p_idempotency_key IS NULL THEN
        RAISE EXCEPTION 'EXPENSE_SETTLEMENT_IDEMPOTENCY_KEY_REQUIRED';
    END IF;
    IF p_actual_expense_amount IS NULL OR p_actual_expense_amount<=0 THEN
        RAISE EXCEPTION 'EXPENSE_ACTUAL_AMOUNT_INVALID';
    END IF;
    IF p_evidence_url IS NOT NULL AND p_evidence_url!~*'^https://' THEN
        RAISE EXCEPTION 'EXPENSE_SETTLEMENT_EVIDENCE_HTTPS_REQUIRED';
    END IF;
    IF NOT public.private_company_feature_enabled(
        v_company,'expense_enabled'
    ) THEN RAISE EXCEPTION 'EXPENSE_FEATURE_DISABLED'; END IF;

    PERFORM pg_advisory_xact_lock(hashtextextended(
        'G4_EXPENSE_SETTLEMENT_REQUEST|'||v_company::TEXT||'|'||
        p_idempotency_key::TEXT,0
    ));
    SELECT * INTO v_existing
    FROM public.expense_settlement_requests
    WHERE company_id=v_company AND idempotency_key=p_idempotency_key;
    IF FOUND THEN
        IF v_existing.document_id IS DISTINCT FROM p_document_id
           OR v_existing.actual_expense_amount IS DISTINCT FROM
              p_actual_expense_amount
           OR v_existing.evidence_url IS DISTINCT FROM p_evidence_url THEN
            RAISE EXCEPTION 'EXPENSE_SETTLEMENT_IDEMPOTENCY_CONFLICT';
        END IF;
        RETURN jsonb_build_object(
            'settlementRequestId',v_existing.id,
            'documentId',v_existing.document_id,
            'status',v_existing.status,
            'masterVersion',v_existing.master_version,
            'idempotentReplay',TRUE
        );
    END IF;

    SELECT * INTO v_document
    FROM public.expense_documents
    WHERE company_id=v_company AND id=p_document_id
    FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'EXPENSE_DOCUMENT_NOT_FOUND'; END IF;
    IF v_document.status NOT IN ('DISBURSED','PARTIALLY_SETTLED') THEN
        RAISE EXCEPTION 'EXPENSE_NOT_SETTLEABLE';
    END IF;
    IF p_master_version IS NULL OR p_master_version<>v_document.master_version
    THEN RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
    IF p_actual_expense_amount>v_document.outstanding_amount THEN
        RAISE EXCEPTION 'EXPENSE_ACTUAL_EXCEEDS_OUTSTANDING';
    END IF;
    IF v_document.evidence_policy_snapshot='REQUIRED'
       AND p_evidence_url IS NULL THEN
        RAISE EXCEPTION 'EXPENSE_SETTLEMENT_EVIDENCE_REQUIRED';
    END IF;
    IF NOT public.private_user_has_store_access(v_document.store_id) THEN
        RAISE EXCEPTION 'EXPENSE_STORE_ACCESS_REQUIRED';
    END IF;

    INSERT INTO public.expense_settlement_requests(
        id,company_id,document_id,store_id,actual_expense_amount,
        category_id,category_name_snapshot,expense_account_id_snapshot,
        evidence_url,idempotency_key,document_master_version_snapshot,
        submitted_by
    ) VALUES (
        v_request_id,v_company,v_document.id,v_document.store_id,
        p_actual_expense_amount,v_document.category_id,
        v_document.category_name_snapshot,
        v_document.expense_account_id_snapshot,p_evidence_url,
        p_idempotency_key,v_document.master_version,v_actor
    );
    INSERT INTO public.expense_audit(
        company_id,entity_type,entity_id,document_id,action,actor_id,
        after_state
    ) VALUES (
        v_company,'SETTLEMENT',v_request_id,v_document.id,'SUBMIT',v_actor,
        jsonb_build_object(
            'status','SUBMITTED','actualExpenseAmount',p_actual_expense_amount,
            'documentMasterVersion',v_document.master_version
        )
    );
    RETURN jsonb_build_object(
        'settlementRequestId',v_request_id,'documentId',v_document.id,
        'status','SUBMITTED','masterVersion',1,'idempotentReplay',FALSE
    );
END;
$$;

CREATE FUNCTION public.review_expense_settlement(
    p_settlement_request_id UUID,p_master_version BIGINT,
    p_action TEXT,p_reason TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE
    v_actor UUID:=auth.uid();
    v_company UUID:=public.private_active_company_id();
    v_now TIMESTAMPTZ:=clock_timestamp();
    v_request public.expense_settlement_requests%ROWTYPE;
    v_document public.expense_documents%ROWTYPE;
    v_action TEXT:=upper(btrim(COALESCE(p_action,'')));
    v_settlement_id UUID:=gen_random_uuid();
    v_event_id UUID;
    v_expense_account_id UUID;
    v_outstanding_account_id UUID;
    v_actual NUMERIC;
    v_outstanding NUMERIC;
    v_status TEXT;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF v_action NOT IN ('APPROVE','REJECT') THEN
        RAISE EXCEPTION 'EXPENSE_SETTLEMENT_REVIEW_ACTION_INVALID';
    END IF;
    IF NOT public.private_company_feature_enabled(
        v_company,'expense_enabled'
    ) THEN RAISE EXCEPTION 'EXPENSE_FEATURE_DISABLED'; END IF;
    IF v_action='REJECT' AND NULLIF(btrim(p_reason),'') IS NULL THEN
        RAISE EXCEPTION 'EXPENSE_SETTLEMENT_REJECTION_REASON_REQUIRED';
    END IF;

    SELECT * INTO v_request
    FROM public.expense_settlement_requests
    WHERE company_id=v_company AND id=p_settlement_request_id
    FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'EXPENSE_SETTLEMENT_REQUEST_NOT_FOUND';
    END IF;
    IF v_request.status<>'SUBMITTED' THEN
        RAISE EXCEPTION 'ONLY_SUBMITTED_SETTLEMENT_REVIEWABLE';
    END IF;
    IF p_master_version IS NULL OR p_master_version<>v_request.master_version
    THEN RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
    IF NOT (
        public.private_user_has_any_company_role(
            v_company,ARRAY[
                'COMPANY_OWNER','COMPANY_ADMIN','FINANCE'
            ]::TEXT[]
        ) OR public.private_user_has_any_store_role(
            v_request.store_id,ARRAY['STORE_MANAGER']::TEXT[]
        )
    ) THEN RAISE EXCEPTION 'EXPENSE_SETTLEMENT_REVIEWER_REQUIRED'; END IF;

    IF v_action='REJECT' THEN
        UPDATE public.expense_settlement_requests
        SET status='REJECTED',reviewed_by=v_actor,reviewed_at=v_now,
            rejection_reason=btrim(p_reason),master_version=master_version+1
        WHERE company_id=v_company AND id=v_request.id;
        INSERT INTO public.expense_audit(
            company_id,entity_type,entity_id,document_id,action,actor_id,
            before_state,after_state
        ) VALUES (
            v_company,'SETTLEMENT',v_request.id,v_request.document_id,
            'REJECT',v_actor,to_jsonb(v_request),
            jsonb_build_object('status','REJECTED','reason',btrim(p_reason))
        );
        RETURN jsonb_build_object(
            'settlementRequestId',v_request.id,'status','REJECTED',
            'masterVersion',v_request.master_version+1
        );
    END IF;

    SELECT * INTO v_document
    FROM public.expense_documents
    WHERE company_id=v_company AND id=v_request.document_id
    FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'EXPENSE_DOCUMENT_NOT_FOUND'; END IF;
    IF v_document.status NOT IN ('DISBURSED','PARTIALLY_SETTLED') THEN
        RAISE EXCEPTION 'EXPENSE_NOT_SETTLEABLE';
    END IF;
    IF v_request.actual_expense_amount>v_document.outstanding_amount THEN
        RAISE EXCEPTION 'EXPENSE_ACTUAL_EXCEEDS_OUTSTANDING';
    END IF;

    v_expense_account_id:=v_request.expense_account_id_snapshot;
    IF v_expense_account_id IS NULL THEN
        v_expense_account_id:=private.resolve_expense_disbursement_account(
            v_company,v_document.transaction_category_id,'EXPENSE',v_now
        );
    END IF;
    v_outstanding_account_id:=private.resolve_expense_disbursement_account(
        v_company,v_document.transaction_category_id,
        'OUTSTANDING_EXPENSE',v_now
    );
    v_actual:=v_document.actual_expense_amount+
        v_request.actual_expense_amount;
    v_outstanding:=v_document.disbursed_amount-v_actual-
        v_document.returned_amount;
    v_status:=private.expense_status_from_totals(
        v_document.disbursed_amount,v_actual,v_document.returned_amount
    );

    INSERT INTO public.financial_events(
        event_code,event_type,source_table,source_id,event_date,event_version,
        idempotency_key,amounts,status,error_message,created_by,company_id,
        store_id,system_event_key,transaction_category_id
    ) VALUES (
        'EXP-SET-'||replace(v_settlement_id::TEXT,'-',''),
        'EXPENSE_SETTLEMENT'::public.event_type,
        'expense_settlements',v_settlement_id,v_now,1,
        'EXPENSE_SETTLEMENT|'||v_company::TEXT||'|'||v_request.id::TEXT,
        jsonb_build_object(
            'expenseDocumentId',v_document.id,
            'actualExpenseAmount',v_request.actual_expense_amount,
            'expenseAccountId',v_expense_account_id,
            'outstandingAccountId',v_outstanding_account_id,
            'financePostingState','HOLD_UNTIL_G6'
        ),'HOLD'::public.event_status,
        'CANONICAL_FINANCE_POSTING_NOT_ENABLED',v_actor,v_company,
        v_document.store_id,'EXPENSE_SETTLEMENT',
        v_document.transaction_category_id
    ) RETURNING id INTO v_event_id;

    INSERT INTO public.expense_settlements(
        id,company_id,document_id,store_id,actual_expense_amount,
        category_id,category_name_snapshot,expense_account_id_snapshot,
        outstanding_account_id_snapshot,transaction_category_id,
        evidence_url,idempotency_key,financial_event_id,
        document_master_version_snapshot,created_by,created_at
    ) VALUES (
        v_settlement_id,v_company,v_document.id,v_document.store_id,
        v_request.actual_expense_amount,v_request.category_id,
        v_request.category_name_snapshot,v_expense_account_id,
        v_outstanding_account_id,v_document.transaction_category_id,
        v_request.evidence_url,v_request.idempotency_key,v_event_id,
        v_document.master_version,v_actor,v_now
    );
    UPDATE public.expense_settlement_requests
    SET status='APPROVED',reviewed_by=v_actor,reviewed_at=v_now,
        master_version=master_version+1
    WHERE company_id=v_company AND id=v_request.id;
    UPDATE public.expense_documents
    SET actual_expense_amount=v_actual,outstanding_amount=v_outstanding,
        status=v_status,
        settled_by=CASE WHEN v_outstanding=0 THEN v_actor ELSE NULL END,
        settled_at=CASE WHEN v_outstanding=0 THEN v_now ELSE NULL END,
        master_version=master_version+1,updated_by=v_actor,updated_at=v_now
    WHERE company_id=v_company AND id=v_document.id;
    INSERT INTO public.expense_audit(
        company_id,entity_type,entity_id,document_id,action,actor_id,
        before_state,after_state
    ) VALUES (
        v_company,'SETTLEMENT',v_settlement_id,v_document.id,'SETTLE',v_actor,
        to_jsonb(v_document),jsonb_build_object(
            'status',v_status,'actualExpenseAmount',v_actual,
            'outstandingAmount',v_outstanding,'financialEventId',v_event_id
        )
    );
    RETURN jsonb_build_object(
        'settlementRequestId',v_request.id,'settlementId',v_settlement_id,
        'documentId',v_document.id,'status',v_status,
        'masterVersion',v_document.master_version+1,
        'outstandingAmount',v_outstanding
    );
END;
$$;

CREATE FUNCTION public.return_expense_funds(
    p_document_id UUID,p_master_version BIGINT,p_amount NUMERIC,
    p_payment_method_id UUID,p_receiving_session_id UUID,
    p_evidence_url TEXT,p_idempotency_key UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE
    v_actor UUID:=auth.uid();
    v_company UUID:=public.private_active_company_id();
    v_now TIMESTAMPTZ:=clock_timestamp();
    v_document public.expense_documents%ROWTYPE;
    v_method public.payment_methods%ROWTYPE;
    v_session public.cashier_sessions%ROWTYPE;
    v_existing public.expense_returns%ROWTYPE;
    v_return_id UUID:=gen_random_uuid();
    v_cash_in_id UUID:=gen_random_uuid();
    v_event_id UUID;
    v_payment_function TEXT;
    v_outstanding_account_id UUID;
    v_payment_account_id UUID;
    v_expected_after NUMERIC;
    v_returned NUMERIC;
    v_outstanding NUMERIC;
    v_status TEXT;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF p_idempotency_key IS NULL THEN
        RAISE EXCEPTION 'EXPENSE_RETURN_IDEMPOTENCY_KEY_REQUIRED';
    END IF;
    IF p_amount IS NULL OR p_amount<=0 THEN
        RAISE EXCEPTION 'EXPENSE_RETURN_AMOUNT_INVALID';
    END IF;
    IF p_evidence_url IS NOT NULL AND p_evidence_url!~*'^https://' THEN
        RAISE EXCEPTION 'EXPENSE_RETURN_EVIDENCE_HTTPS_REQUIRED';
    END IF;
    IF NOT public.private_company_feature_enabled(
        v_company,'expense_enabled'
    ) THEN RAISE EXCEPTION 'EXPENSE_FEATURE_DISABLED'; END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended(
        'G4_EXPENSE_RETURN|'||v_company::TEXT||'|'||
        p_idempotency_key::TEXT,0
    ));
    SELECT * INTO v_existing FROM public.expense_returns
    WHERE company_id=v_company AND idempotency_key=p_idempotency_key;
    IF FOUND THEN
        IF v_existing.document_id IS DISTINCT FROM p_document_id
           OR v_existing.amount IS DISTINCT FROM p_amount
           OR v_existing.payment_method_id IS DISTINCT FROM p_payment_method_id
           OR v_existing.receiving_session_id IS DISTINCT FROM
              p_receiving_session_id
           OR v_existing.evidence_url IS DISTINCT FROM p_evidence_url THEN
            RAISE EXCEPTION 'EXPENSE_RETURN_IDEMPOTENCY_CONFLICT';
        END IF;
        SELECT * INTO v_document FROM public.expense_documents
        WHERE company_id=v_company AND id=v_existing.document_id;
        RETURN jsonb_build_object(
            'returnId',v_existing.id,'documentId',v_existing.document_id,
            'status',v_document.status,
            'masterVersion',v_document.master_version,
            'outstandingAmount',v_document.outstanding_amount,
            'idempotentReplay',TRUE
        );
    END IF;

    SELECT * INTO v_document FROM public.expense_documents
    WHERE company_id=v_company AND id=p_document_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'EXPENSE_DOCUMENT_NOT_FOUND'; END IF;
    IF v_document.status NOT IN ('DISBURSED','PARTIALLY_SETTLED') THEN
        RAISE EXCEPTION 'EXPENSE_RETURN_NOT_ALLOWED';
    END IF;
    IF p_master_version IS NULL OR p_master_version<>v_document.master_version
    THEN RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
    IF p_amount>v_document.outstanding_amount THEN
        RAISE EXCEPTION 'EXPENSE_RETURN_EXCEEDS_OUTSTANDING';
    END IF;
    IF NOT public.private_user_has_store_access(v_document.store_id) THEN
        RAISE EXCEPTION 'EXPENSE_STORE_ACCESS_REQUIRED';
    END IF;

    SELECT * INTO v_method FROM public.payment_methods method
    WHERE method.company_id=v_company AND method.id=p_payment_method_id
      AND method.is_active AND method.effective_from<=v_now
      AND (method.effective_to IS NULL OR method.effective_to>v_now)
      AND method.method_type IN ('CASH','TRANSFER','QRIS','CARD','E_WALLET')
      AND (method.available_all_stores OR EXISTS (
          SELECT 1 FROM public.payment_method_store_assignments assignment
          WHERE assignment.company_id=v_company
            AND assignment.payment_method_id=method.id
            AND assignment.store_id=v_document.store_id
      ));
    IF NOT FOUND THEN RAISE EXCEPTION 'ACTIVE_EXPENSE_PAYMENT_METHOD_NOT_FOUND';
    END IF;
    IF v_method.proof_mode='REQUIRED' AND p_evidence_url IS NULL THEN
        RAISE EXCEPTION 'EXPENSE_RETURN_EVIDENCE_REQUIRED';
    END IF;

    IF v_method.method_type='CASH' THEN
        IF v_method.settlement_route<>'CASH_DRAWER' THEN
            RAISE EXCEPTION 'EXPENSE_CASH_RETURN_ROUTE_INVALID';
        END IF;
        SELECT * INTO v_session FROM public.cashier_sessions session
        WHERE session.company_id=v_company
          AND session.store_id=v_document.store_id
          AND session.id=p_receiving_session_id
          AND session.status='OPEN'::public.session_status
        FOR UPDATE;
        IF NOT FOUND THEN RAISE EXCEPTION 'OPEN_EXPENSE_RETURN_SESSION_REQUIRED';
        END IF;
        IF NOT EXISTS (
            SELECT 1 FROM public.pos_terminals terminal
            WHERE terminal.company_id=v_company
              AND terminal.store_id=v_document.store_id
              AND terminal.id=v_session.pos_id
              AND terminal.status='ACTIVE'
        ) THEN RAISE EXCEPTION 'ACTIVE_EXPENSE_TERMINAL_REQUIRED'; END IF;
        IF v_session.cashier_id<>v_actor AND NOT (
            public.private_user_has_any_company_role(
                v_company,ARRAY['COMPANY_OWNER','COMPANY_ADMIN']::TEXT[]
            ) OR public.private_user_has_any_store_role(
                v_document.store_id,ARRAY['STORE_MANAGER']::TEXT[]
            )
        ) THEN RAISE EXCEPTION 'EXPENSE_CASH_RETURN_RECEIVER_REQUIRED'; END IF;
        v_payment_function:='CASH_DRAWER';
        v_expected_after:=private.calculate_cashier_session_expected_cash(
            v_company,v_session.id
        );
        IF v_expected_after IS NULL THEN
            RAISE EXCEPTION 'EXPENSE_EXPECTED_CASH_NOT_RESOLVED';
        END IF;
        v_expected_after:=v_expected_after+p_amount;
    ELSE
        IF p_receiving_session_id IS NOT NULL THEN
            RAISE EXCEPTION 'NONCASH_EXPENSE_RETURN_SESSION_NOT_ALLOWED';
        END IF;
        IF v_method.settlement_route NOT IN ('DIRECT_BANK','CLEARING') THEN
            RAISE EXCEPTION 'EXPENSE_NONCASH_RETURN_ROUTE_INVALID';
        END IF;
        IF NOT public.private_user_has_any_company_role(
            v_company,ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE']::TEXT[]
        ) THEN RAISE EXCEPTION 'EXPENSE_NONCASH_RETURN_RECEIVER_REQUIRED';
        END IF;
        v_payment_function:=CASE v_method.settlement_route
            WHEN 'DIRECT_BANK' THEN v_method.bank_account_function
            WHEN 'CLEARING' THEN v_method.clearing_account_function
        END;
    END IF;

    v_outstanding_account_id:=private.resolve_expense_disbursement_account(
        v_company,v_document.transaction_category_id,
        'OUTSTANDING_EXPENSE',v_now
    );
    v_payment_account_id:=private.resolve_expense_disbursement_account(
        v_company,v_document.transaction_category_id,v_payment_function,v_now
    );
    v_returned:=v_document.returned_amount+p_amount;
    v_outstanding:=v_document.disbursed_amount-
        v_document.actual_expense_amount-v_returned;
    v_status:=private.expense_status_from_totals(
        v_document.disbursed_amount,v_document.actual_expense_amount,v_returned
    );

    INSERT INTO public.financial_events(
        event_code,event_type,source_table,source_id,event_date,event_version,
        idempotency_key,payment_method,amounts,status,error_message,created_by,
        company_id,store_id,system_event_key,transaction_category_id
    ) VALUES (
        'EXP-RET-'||replace(v_return_id::TEXT,'-',''),
        'EXPENSE_RETURN'::public.event_type,'expense_returns',v_return_id,
        v_now,1,'EXPENSE_RETURN|'||v_company::TEXT||'|'||
            p_idempotency_key::TEXT,v_method.payment_method_name,
        jsonb_build_object(
            'expenseDocumentId',v_document.id,'returnedAmount',p_amount,
            'outstandingAccountId',v_outstanding_account_id,
            'paymentAccountId',v_payment_account_id,
            'paymentAccountFunction',v_payment_function,
            'financePostingState','HOLD_UNTIL_G6'
        ),'HOLD'::public.event_status,
        'CANONICAL_FINANCE_POSTING_NOT_ENABLED',v_actor,v_company,
        v_document.store_id,'EXPENSE_SETTLEMENT',
        v_document.transaction_category_id
    ) RETURNING id INTO v_event_id;

    INSERT INTO public.expense_returns(
        id,company_id,document_id,store_id,pos_terminal_id,amount,
        payment_method_id,payment_method_name_snapshot,
        payment_method_type_snapshot,payment_settlement_route_snapshot,
        payment_account_function_snapshot,receiving_session_id,evidence_url,
        idempotency_key,financial_event_id,transaction_category_id,
        outstanding_account_id_snapshot,payment_account_id_snapshot,
        document_master_version_snapshot,created_by,created_at
    ) VALUES (
        v_return_id,v_company,v_document.id,v_document.store_id,
        v_session.pos_id,p_amount,v_method.id,v_method.payment_method_name,
        v_method.method_type,v_method.settlement_route,v_payment_function,
        v_session.id,p_evidence_url,p_idempotency_key,v_event_id,
        v_document.transaction_category_id,v_outstanding_account_id,
        v_payment_account_id,v_document.master_version,v_actor,v_now
    );

    IF v_method.method_type='CASH' THEN
        INSERT INTO public.cash_in_documents(
            id,company_id,document_no,store_id,pos_terminal_id,
            cashier_session_id,source_type,source_document_id,amount,reason,
            status,idempotency_key,financial_event_id,created_by,created_at
        ) VALUES (
            v_cash_in_id,v_company,
            'CIN-'||to_char(v_now,'YYYYMMDD')||'-'||
                lpad(nextval(
                    'private.cash_in_document_number_seq'
                )::TEXT,6,'0'),
            v_document.store_id,v_session.pos_id,v_session.id,
            'EXPENSE_RETURN',v_document.id,p_amount,
            'Pengembalian dana Expense '||v_document.document_no,
            'POSTED',p_idempotency_key,v_event_id,v_actor,v_now
        );
        INSERT INTO public.cash_drawer_movements(
            company_id,store_id,pos_terminal_id,cashier_session_id,
            direction,movement_type,amount,source_table,source_id,
            expected_cash_after,actor_id,created_at
        ) VALUES (
            v_company,v_document.store_id,v_session.pos_id,v_session.id,
            'IN','EXPENSE_RETURN',p_amount,'expense_returns',v_return_id,
            v_expected_after,v_actor,v_now
        );
    END IF;

    UPDATE public.expense_documents
    SET returned_amount=v_returned,outstanding_amount=v_outstanding,
        status=v_status,
        settled_by=CASE WHEN v_outstanding=0 THEN v_actor ELSE NULL END,
        settled_at=CASE WHEN v_outstanding=0 THEN v_now ELSE NULL END,
        master_version=master_version+1,updated_by=v_actor,updated_at=v_now
    WHERE company_id=v_company AND id=v_document.id;
    INSERT INTO public.expense_audit(
        company_id,entity_type,entity_id,document_id,action,actor_id,
        before_state,after_state
    ) VALUES (
        v_company,'RETURN',v_return_id,v_document.id,'RETURN_FUNDS',v_actor,
        to_jsonb(v_document),jsonb_build_object(
            'status',v_status,'returnedAmount',v_returned,
            'outstandingAmount',v_outstanding,'financialEventId',v_event_id
        )
    );
    RETURN jsonb_build_object(
        'returnId',v_return_id,'documentId',v_document.id,'status',v_status,
        'masterVersion',v_document.master_version+1,
        'outstandingAmount',v_outstanding,
        'expectedCashAfter',v_expected_after,'idempotentReplay',FALSE
    );
END;
$$;

CREATE FUNCTION public.request_additional_expense_disbursement(
    p_document_id UUID,p_master_version BIGINT,p_amount NUMERIC,
    p_payment_method_id UUID,p_evidence_url TEXT,p_idempotency_key UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE
    v_actor UUID:=auth.uid();
    v_company UUID:=public.private_active_company_id();
    v_now TIMESTAMPTZ:=clock_timestamp();
    v_document public.expense_documents%ROWTYPE;
    v_method public.payment_methods%ROWTYPE;
    v_category public.expense_categories%ROWTYPE;
    v_existing public.expense_additional_disbursement_requests%ROWTYPE;
    v_request_id UUID:=gen_random_uuid();
    v_approval_required BOOLEAN;
    v_status TEXT;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF p_idempotency_key IS NULL THEN
        RAISE EXCEPTION 'EXPENSE_ADDITIONAL_IDEMPOTENCY_KEY_REQUIRED';
    END IF;
    IF p_amount IS NULL OR p_amount<=0 THEN
        RAISE EXCEPTION 'EXPENSE_ADDITIONAL_AMOUNT_INVALID';
    END IF;
    IF p_evidence_url IS NOT NULL AND p_evidence_url!~*'^https://' THEN
        RAISE EXCEPTION 'EXPENSE_ADDITIONAL_EVIDENCE_HTTPS_REQUIRED';
    END IF;
    IF NOT public.private_company_feature_enabled(
        v_company,'expense_enabled'
    ) THEN RAISE EXCEPTION 'EXPENSE_FEATURE_DISABLED'; END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended(
        'G4_EXPENSE_ADDITIONAL_REQUEST|'||v_company::TEXT||'|'||
        p_idempotency_key::TEXT,0
    ));
    SELECT * INTO v_existing
    FROM public.expense_additional_disbursement_requests
    WHERE company_id=v_company AND idempotency_key=p_idempotency_key;
    IF FOUND THEN
        IF v_existing.document_id IS DISTINCT FROM p_document_id
           OR v_existing.amount IS DISTINCT FROM p_amount
           OR v_existing.payment_method_id IS DISTINCT FROM p_payment_method_id
           OR v_existing.evidence_url IS DISTINCT FROM p_evidence_url THEN
            RAISE EXCEPTION 'EXPENSE_ADDITIONAL_IDEMPOTENCY_CONFLICT';
        END IF;
        RETURN jsonb_build_object(
            'additionalRequestId',v_existing.id,
            'documentId',v_existing.document_id,'status',v_existing.status,
            'masterVersion',v_existing.master_version,
            'idempotentReplay',TRUE
        );
    END IF;

    SELECT * INTO v_document FROM public.expense_documents
    WHERE company_id=v_company AND id=p_document_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'EXPENSE_DOCUMENT_NOT_FOUND'; END IF;
    IF v_document.status NOT IN ('DISBURSED','PARTIALLY_SETTLED') THEN
        RAISE EXCEPTION 'EXPENSE_ADDITIONAL_REQUEST_NOT_ALLOWED';
    END IF;
    IF p_master_version IS NULL OR p_master_version<>v_document.master_version
    THEN RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
    IF NOT public.private_user_has_store_access(v_document.store_id) THEN
        RAISE EXCEPTION 'EXPENSE_STORE_ACCESS_REQUIRED';
    END IF;
    SELECT * INTO v_category FROM public.expense_categories
    WHERE company_id=v_company AND id=v_document.category_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'EXPENSE_CATEGORY_NOT_FOUND'; END IF;
    SELECT * INTO v_method FROM public.payment_methods method
    WHERE method.company_id=v_company AND method.id=p_payment_method_id
      AND method.is_active AND method.effective_from<=v_now
      AND (method.effective_to IS NULL OR method.effective_to>v_now)
      AND method.method_type IN ('CASH','TRANSFER','QRIS','CARD','E_WALLET')
      AND (method.available_all_stores OR EXISTS (
          SELECT 1 FROM public.payment_method_store_assignments assignment
          WHERE assignment.company_id=v_company
            AND assignment.payment_method_id=method.id
            AND assignment.store_id=v_document.store_id
      ));
    IF NOT FOUND THEN RAISE EXCEPTION 'ACTIVE_EXPENSE_PAYMENT_METHOD_NOT_FOUND';
    END IF;
    IF v_method.proof_mode='REQUIRED' AND p_evidence_url IS NULL THEN
        RAISE EXCEPTION 'EXPENSE_ADDITIONAL_EVIDENCE_REQUIRED';
    END IF;

    IF v_category.approval_policy='REQUIRED' THEN
        v_approval_required:=TRUE;
    ELSIF v_category.approval_policy='NOT_REQUIRED' THEN
        v_approval_required:=FALSE;
    ELSE
        SELECT policy.approval_required INTO v_approval_required
        FROM public.expense_approval_policies policy
        WHERE policy.company_id=v_company AND policy.is_active
          AND (policy.store_id=v_document.store_id OR policy.store_id IS NULL)
        ORDER BY (policy.store_id IS NOT NULL) DESC
        LIMIT 1;
        v_approval_required:=COALESCE(v_approval_required,TRUE);
    END IF;
    v_status:=CASE WHEN v_approval_required THEN 'SUBMITTED'
                   ELSE 'APPROVED' END;

    INSERT INTO public.expense_additional_disbursement_requests(
        id,company_id,document_id,store_id,amount,payment_method_id,
        payment_method_name_snapshot,payment_method_type_snapshot,
        evidence_url,approval_required_snapshot,status,idempotency_key,
        document_master_version_snapshot,requested_by,approved_by,approved_at
    ) VALUES (
        v_request_id,v_company,v_document.id,v_document.store_id,p_amount,
        v_method.id,v_method.payment_method_name,v_method.method_type,
        p_evidence_url,v_approval_required,v_status,p_idempotency_key,
        v_document.master_version,v_actor,
        CASE WHEN v_approval_required THEN NULL ELSE v_actor END,
        CASE WHEN v_approval_required THEN NULL ELSE v_now END
    );
    INSERT INTO public.expense_audit(
        company_id,entity_type,entity_id,document_id,action,actor_id,
        after_state
    ) VALUES (
        v_company,'DISBURSEMENT',v_request_id,v_document.id,'SUBMIT',v_actor,
        jsonb_build_object(
            'status',v_status,'amount',p_amount,
            'approvalRequired',v_approval_required,
            'paymentMethodId',v_method.id,
            'boundary','REQUEST_ONLY_NO_CASH_EFFECT'
        )
    );
    RETURN jsonb_build_object(
        'additionalRequestId',v_request_id,'documentId',v_document.id,
        'status',v_status,'masterVersion',1,
        'approvalRequired',v_approval_required,
        'cashEffect',FALSE,'idempotentReplay',FALSE
    );
END;
$$;

REVOKE ALL ON FUNCTION private.expense_status_from_totals(
    NUMERIC,NUMERIC,NUMERIC
) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION private.trg_expense_document_lifecycle_timestamps()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.expense_status_from_totals(
    NUMERIC,NUMERIC,NUMERIC
) TO service_role;
GRANT EXECUTE ON FUNCTION
    private.trg_expense_document_lifecycle_timestamps() TO service_role;

REVOKE ALL ON FUNCTION public.save_expense_settlement(
    UUID,BIGINT,NUMERIC,TEXT,UUID
),public.review_expense_settlement(UUID,BIGINT,TEXT,TEXT),
public.return_expense_funds(UUID,BIGINT,NUMERIC,UUID,UUID,TEXT,UUID),
public.request_additional_expense_disbursement(
    UUID,BIGINT,NUMERIC,UUID,TEXT,UUID
) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.save_expense_settlement(
    UUID,BIGINT,NUMERIC,TEXT,UUID
),public.review_expense_settlement(UUID,BIGINT,TEXT,TEXT),
public.return_expense_funds(UUID,BIGINT,NUMERIC,UUID,UUID,TEXT,UUID),
public.request_additional_expense_disbursement(
    UUID,BIGINT,NUMERIC,UUID,TEXT,UUID
) TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES (
    '20260803100000','g4_phase37_expense_settlement_foundation',
    'POS-007 reviewed actual Expense, immutable settlement/return, Cash In drawer reconciliation, outstanding lifecycle, and request-only additional disbursement'
);

COMMIT;
