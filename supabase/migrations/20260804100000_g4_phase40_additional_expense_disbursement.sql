-- KGS POS G4 phase 40: additional Expense review/disbursement foundation.
-- Requirement: POS-007
-- Dependency: G4 phase 37 Expense settlement foundation.
--
-- BOUNDARY:
-- - request review is cash-neutral;
-- - only an APPROVED additional request can be disbursed;
-- - Cash execution uses one OPEN Session and one immutable drawer OUT;
-- - non-Cash execution requires Finance/Admin and never changes the drawer;
-- - a HOLD Financial Event is emitted; G6 journal posting remains closed;
-- - Offline Expense, correction/reversal, and Deposit remain closed.

BEGIN;

DO $migration_guard$
BEGIN
    IF to_regclass('private.kgs_schema_migrations') IS NULL
       OR NOT EXISTS (
           SELECT 1 FROM private.kgs_schema_migrations
           WHERE version='20260803100000'
       ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: G4 phase 37 is incomplete';
    END IF;
    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version='20260804100000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260804100000';
    END IF;
    IF EXISTS (
        SELECT 1 FROM public.expense_additional_disbursement_requests
        WHERE status IN ('REJECTED','DISBURSED','CANCELED')
    ) THEN
        RAISE EXCEPTION
            'G4_PHASE40_STATE_CHANGED: terminal additional request exists';
    END IF;
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='public'
          AND table_name='expense_additional_disbursement_requests'
          AND column_name IN (
              'rejected_by','rejected_at','rejection_reason',
              'disbursed_by','disbursed_at','expense_disbursement_id'
          )
    ) OR to_regprocedure(
        'public.review_additional_expense_disbursement(uuid,bigint,text,text)'
    ) IS NOT NULL OR to_regprocedure(
        'public.disburse_additional_expense(uuid,bigint,bigint,uuid,text,uuid)'
    ) IS NOT NULL THEN
        RAISE EXCEPTION
            'G4_PHASE40_STATE_CHANGED: additional runtime already exists';
    END IF;
END
$migration_guard$;

ALTER TYPE public.event_type
    ADD VALUE IF NOT EXISTS 'EXPENSE_ADDITIONAL_DISBURSEMENT';

ALTER TABLE public.expense_additional_disbursement_requests
    ADD COLUMN rejected_by UUID REFERENCES public.profiles(id),
    ADD COLUMN rejected_at TIMESTAMPTZ,
    ADD COLUMN rejection_reason TEXT,
    ADD COLUMN disbursed_by UUID REFERENCES public.profiles(id),
    ADD COLUMN disbursed_at TIMESTAMPTZ,
    ADD COLUMN expense_disbursement_id UUID,
    ADD CONSTRAINT expense_additional_request_terminal_shape CHECK (
        (
            status='SUBMITTED'
            AND approved_by IS NULL AND approved_at IS NULL
            AND rejected_by IS NULL AND rejected_at IS NULL
            AND rejection_reason IS NULL
            AND disbursed_by IS NULL AND disbursed_at IS NULL
            AND expense_disbursement_id IS NULL
        ) OR (
            status='APPROVED'
            AND approved_by IS NOT NULL AND approved_at IS NOT NULL
            AND rejected_by IS NULL AND rejected_at IS NULL
            AND rejection_reason IS NULL
            AND disbursed_by IS NULL AND disbursed_at IS NULL
            AND expense_disbursement_id IS NULL
        ) OR (
            status='REJECTED'
            AND rejected_by IS NOT NULL AND rejected_at IS NOT NULL
            AND NULLIF(btrim(rejection_reason),'') IS NOT NULL
            AND disbursed_by IS NULL AND disbursed_at IS NULL
            AND expense_disbursement_id IS NULL
        ) OR (
            status='DISBURSED'
            AND approved_by IS NOT NULL AND approved_at IS NOT NULL
            AND rejected_by IS NULL AND rejected_at IS NULL
            AND rejection_reason IS NULL
            AND disbursed_by IS NOT NULL AND disbursed_at IS NOT NULL
            AND expense_disbursement_id IS NOT NULL
        ) OR status='CANCELED'
    ),
    ADD CONSTRAINT fk_expense_additional_request_disbursement
        FOREIGN KEY(company_id,expense_disbursement_id)
        REFERENCES public.expense_disbursements(company_id,id)
        ON DELETE RESTRICT;

CREATE UNIQUE INDEX uq_expense_additional_request_disbursement
    ON public.expense_additional_disbursement_requests(
        company_id,expense_disbursement_id
    ) WHERE expense_disbursement_id IS NOT NULL;

CREATE FUNCTION public.review_additional_expense_disbursement(
    p_request_id UUID,
    p_master_version BIGINT,
    p_action TEXT,
    p_reason TEXT
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
    v_request public.expense_additional_disbursement_requests%ROWTYPE;
    v_document public.expense_documents%ROWTYPE;
    v_action TEXT:=upper(btrim(COALESCE(p_action,'')));
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF v_action NOT IN ('APPROVE','REJECT') THEN
        RAISE EXCEPTION 'EXPENSE_ADDITIONAL_REVIEW_ACTION_INVALID';
    END IF;
    IF v_action='REJECT' AND NULLIF(btrim(p_reason),'') IS NULL THEN
        RAISE EXCEPTION 'EXPENSE_ADDITIONAL_REJECTION_REASON_REQUIRED';
    END IF;
    IF NOT public.private_company_feature_enabled(
        v_company,'expense_enabled'
    ) THEN RAISE EXCEPTION 'EXPENSE_FEATURE_DISABLED'; END IF;

    SELECT * INTO v_request
    FROM public.expense_additional_disbursement_requests request
    WHERE request.company_id=v_company AND request.id=p_request_id
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'EXPENSE_ADDITIONAL_REQUEST_NOT_FOUND';
    END IF;
    IF v_request.status<>'SUBMITTED' THEN
        RAISE EXCEPTION 'ONLY_SUBMITTED_ADDITIONAL_REQUEST_REVIEWABLE';
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
    ) THEN RAISE EXCEPTION 'EXPENSE_ADDITIONAL_REVIEWER_REQUIRED'; END IF;

    SELECT * INTO v_document
    FROM public.expense_documents document
    WHERE document.company_id=v_company
      AND document.id=v_request.document_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'EXPENSE_DOCUMENT_NOT_FOUND'; END IF;

    IF v_action='APPROVE' THEN
        IF v_document.status NOT IN ('DISBURSED','PARTIALLY_SETTLED') THEN
            RAISE EXCEPTION 'EXPENSE_ADDITIONAL_DOCUMENT_NOT_OPEN';
        END IF;
        UPDATE public.expense_additional_disbursement_requests
        SET status='APPROVED',approved_by=v_actor,approved_at=v_now,
            master_version=master_version+1
        WHERE company_id=v_company AND id=v_request.id;
    ELSE
        UPDATE public.expense_additional_disbursement_requests
        SET status='REJECTED',rejected_by=v_actor,rejected_at=v_now,
            rejection_reason=btrim(p_reason),master_version=master_version+1
        WHERE company_id=v_company AND id=v_request.id;
    END IF;

    INSERT INTO public.expense_audit(
        company_id,entity_type,entity_id,document_id,action,actor_id,
        before_state,after_state,created_at
    ) VALUES (
        v_company,'DISBURSEMENT',v_request.id,v_request.document_id,
        CASE WHEN v_action='APPROVE' THEN 'APPROVE' ELSE 'REJECT' END,
        v_actor,to_jsonb(v_request),
        jsonb_build_object(
            'status',CASE WHEN v_action='APPROVE'
                          THEN 'APPROVED' ELSE 'REJECTED' END,
            'reason',CASE WHEN v_action='REJECT'
                          THEN btrim(p_reason) ELSE NULL END
        ),v_now
    );

    RETURN jsonb_build_object(
        'additionalRequestId',v_request.id,
        'documentId',v_request.document_id,
        'status',CASE WHEN v_action='APPROVE'
                      THEN 'APPROVED' ELSE 'REJECTED' END,
        'masterVersion',v_request.master_version+1,
        'cashEffect',FALSE
    );
END;
$$;

CREATE FUNCTION public.disburse_additional_expense(
    p_request_id UUID,
    p_request_master_version BIGINT,
    p_document_master_version BIGINT,
    p_cashier_session_id UUID,
    p_evidence_url TEXT,
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
    v_now TIMESTAMPTZ:=clock_timestamp();
    v_request public.expense_additional_disbursement_requests%ROWTYPE;
    v_document public.expense_documents%ROWTYPE;
    v_method public.payment_methods%ROWTYPE;
    v_session public.cashier_sessions%ROWTYPE;
    v_existing public.expense_disbursements%ROWTYPE;
    v_disbursement_id UUID:=gen_random_uuid();
    v_financial_event_id UUID;
    v_transaction_category_id UUID;
    v_outstanding_account_id UUID;
    v_payment_account_id UUID;
    v_payment_function TEXT;
    v_approval_snapshot JSONB;
    v_before JSONB;
    v_expected_before NUMERIC;
    v_expected_after NUMERIC;
    v_disbursed NUMERIC;
    v_outstanding NUMERIC;
    v_status TEXT;
    v_new_document_version BIGINT;
    v_new_request_version BIGINT;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF p_idempotency_key IS NULL THEN
        RAISE EXCEPTION 'EXPENSE_ADDITIONAL_DISBURSEMENT_IDEMPOTENCY_REQUIRED';
    END IF;
    IF p_evidence_url IS NOT NULL AND p_evidence_url!~*'^https://' THEN
        RAISE EXCEPTION
            'EXPENSE_ADDITIONAL_DISBURSEMENT_EVIDENCE_HTTPS_REQUIRED';
    END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended(
        'G4_EXPENSE_ADDITIONAL_DISBURSE|'||v_company::TEXT||'|'||
        p_request_id::TEXT,0
    ));

    SELECT * INTO v_request
    FROM public.expense_additional_disbursement_requests request
    WHERE request.company_id=v_company AND request.id=p_request_id
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'EXPENSE_ADDITIONAL_REQUEST_NOT_FOUND';
    END IF;

    IF v_request.status='DISBURSED' THEN
        SELECT * INTO v_existing
        FROM public.expense_disbursements disbursement
        WHERE disbursement.company_id=v_company
          AND disbursement.id=v_request.expense_disbursement_id;
        IF NOT FOUND OR v_existing.idempotency_key IS DISTINCT FROM
           p_idempotency_key
           OR v_existing.cashier_session_id IS DISTINCT FROM
              p_cashier_session_id
           OR v_existing.evidence_url IS DISTINCT FROM p_evidence_url THEN
            RAISE EXCEPTION
                'EXPENSE_ADDITIONAL_DISBURSEMENT_IDEMPOTENCY_CONFLICT';
        END IF;
        SELECT * INTO v_document
        FROM public.expense_documents document
        WHERE document.company_id=v_company
          AND document.id=v_request.document_id;
        IF v_existing.payment_method_type_snapshot='CASH' THEN
            SELECT movement.expected_cash_after INTO v_expected_after
            FROM public.cash_drawer_movements movement
            WHERE movement.company_id=v_company
              AND movement.source_table='expense_disbursements'
              AND movement.source_id=v_existing.id;
            IF v_expected_after IS NULL THEN
                RAISE EXCEPTION
                    'EXPENSE_ADDITIONAL_CASH_DRAWER_EFFECT_NOT_FOUND';
            END IF;
        END IF;
        RETURN jsonb_build_object(
            'additionalRequestId',v_request.id,
            'documentId',v_document.id,
            'disbursementId',v_existing.id,
            'status',v_document.status,
            'requestStatus','DISBURSED',
            'requestMasterVersion',v_request.master_version,
            'documentMasterVersion',v_document.master_version,
            'amount',v_existing.amount,
            'paymentMethodType',v_existing.payment_method_type_snapshot,
            'expectedCashAfter',v_expected_after,
            'idempotentReplay',TRUE
        );
    END IF;

    IF NOT public.private_company_feature_enabled(
        v_company,'expense_enabled'
    ) THEN RAISE EXCEPTION 'EXPENSE_FEATURE_DISABLED'; END IF;

    IF v_request.status<>'APPROVED' THEN
        RAISE EXCEPTION 'ONLY_APPROVED_ADDITIONAL_REQUEST_DISBURSABLE';
    END IF;
    IF p_request_master_version IS NULL
       OR p_request_master_version<>v_request.master_version THEN
        RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
    END IF;

    SELECT * INTO v_document
    FROM public.expense_documents document
    WHERE document.company_id=v_company
      AND document.id=v_request.document_id
    FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'EXPENSE_DOCUMENT_NOT_FOUND'; END IF;
    IF v_document.status NOT IN ('DISBURSED','PARTIALLY_SETTLED') THEN
        RAISE EXCEPTION 'EXPENSE_ADDITIONAL_DOCUMENT_NOT_OPEN';
    END IF;
    IF p_document_master_version IS NULL
       OR p_document_master_version<>v_document.master_version THEN
        RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM public.stores store
        WHERE store.company_id=v_company AND store.id=v_document.store_id
          AND store.status='ACTIVE'
    ) THEN RAISE EXCEPTION 'ACTIVE_STORE_NOT_FOUND'; END IF;
    IF NOT public.private_user_has_store_access(v_document.store_id) THEN
        RAISE EXCEPTION 'EXPENSE_STORE_ACCESS_REQUIRED';
    END IF;

    SELECT * INTO v_method
    FROM public.payment_methods method
    WHERE method.company_id=v_company
      AND method.id=v_request.payment_method_id
      AND method.is_active
      AND method.effective_from<=v_now
      AND (method.effective_to IS NULL OR method.effective_to>v_now)
      AND method.method_type IN ('CASH','TRANSFER','QRIS','CARD','E_WALLET')
      AND (
          method.available_all_stores OR EXISTS (
              SELECT 1 FROM public.payment_method_store_assignments assignment
              WHERE assignment.company_id=v_company
                AND assignment.payment_method_id=method.id
                AND assignment.store_id=v_document.store_id
          )
      );
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ACTIVE_EXPENSE_PAYMENT_METHOD_NOT_FOUND';
    END IF;
    IF v_method.method_type IS DISTINCT FROM
       v_request.payment_method_type_snapshot THEN
        RAISE EXCEPTION 'EXPENSE_PAYMENT_METHOD_SNAPSHOT_CONFLICT';
    END IF;
    IF v_method.proof_mode='REQUIRED' AND p_evidence_url IS NULL THEN
        RAISE EXCEPTION
            'EXPENSE_ADDITIONAL_DISBURSEMENT_EVIDENCE_REQUIRED';
    END IF;

    IF v_method.method_type='CASH' THEN
        IF v_method.settlement_route<>'CASH_DRAWER' THEN
            RAISE EXCEPTION 'EXPENSE_CASH_ROUTE_INVALID';
        END IF;
        SELECT * INTO v_session
        FROM public.cashier_sessions session
        WHERE session.company_id=v_company
          AND session.store_id=v_document.store_id
          AND session.id=p_cashier_session_id
          AND session.status='OPEN'::public.session_status
        FOR UPDATE;
        IF NOT FOUND THEN RAISE EXCEPTION 'OPEN_EXPENSE_SESSION_REQUIRED'; END IF;
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
        ) THEN RAISE EXCEPTION 'EXPENSE_CASH_DISBURSER_REQUIRED'; END IF;
        v_payment_function:='CASH_DRAWER';
        v_expected_before:=private.calculate_cashier_session_expected_cash(
            v_company,v_session.id
        );
        IF v_expected_before IS NULL THEN
            RAISE EXCEPTION 'EXPENSE_EXPECTED_CASH_NOT_RESOLVED';
        END IF;
        IF v_expected_before<v_request.amount THEN
            RAISE EXCEPTION 'INSUFFICIENT_EXPECTED_CASH';
        END IF;
        v_expected_after:=v_expected_before-v_request.amount;
    ELSE
        IF p_cashier_session_id IS NOT NULL THEN
            RAISE EXCEPTION 'NONCASH_EXPENSE_SESSION_NOT_ALLOWED';
        END IF;
        IF v_method.settlement_route NOT IN ('DIRECT_BANK','CLEARING') THEN
            RAISE EXCEPTION 'EXPENSE_NONCASH_ROUTE_INVALID';
        END IF;
        IF NOT public.private_user_has_any_company_role(
            v_company,ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE']::TEXT[]
        ) THEN RAISE EXCEPTION 'EXPENSE_NONCASH_DISBURSER_REQUIRED'; END IF;
        v_payment_function:=CASE v_method.settlement_route
            WHEN 'DIRECT_BANK' THEN v_method.bank_account_function
            WHEN 'CLEARING' THEN v_method.clearing_account_function
        END;
    END IF;

    SELECT category.id INTO v_transaction_category_id
    FROM public.transaction_categories category
    WHERE category.company_id=v_company
      AND category.system_key='EXPENSE_DISBURSEMENT'
      AND category.is_active
    ORDER BY category.created_at,category.id
    LIMIT 1;
    IF v_transaction_category_id IS NULL THEN
        RAISE EXCEPTION 'EXPENSE_DISBURSEMENT_CATEGORY_NOT_FOUND';
    END IF;

    v_outstanding_account_id:=private.resolve_expense_disbursement_account(
        v_company,v_transaction_category_id,'OUTSTANDING_EXPENSE',v_now
    );
    v_payment_account_id:=private.resolve_expense_disbursement_account(
        v_company,v_transaction_category_id,v_payment_function,v_now
    );
    v_approval_snapshot:=jsonb_build_object(
        'approvalRequired',v_request.approval_required_snapshot,
        'approvedBy',v_request.approved_by,
        'approvedAt',v_request.approved_at,
        'requestMasterVersion',v_request.master_version,
        'documentMasterVersion',v_document.master_version,
        'additionalRequestId',v_request.id
    );
    v_before:=to_jsonb(v_document);

    INSERT INTO public.financial_events(
        event_code,event_type,source_table,source_id,root_sales_id,
        event_date,event_version,idempotency_key,payment_method,amounts,
        status,error_message,created_by,company_id,store_id,
        system_event_key,transaction_category_id
    ) VALUES (
        'EXP-ADD-'||replace(v_disbursement_id::TEXT,'-',''),
        'EXPENSE_ADDITIONAL_DISBURSEMENT'::public.event_type,
        'expense_disbursements',v_disbursement_id,NULL,v_now,1,
        'EXPENSE_ADDITIONAL_DISBURSEMENT|'||v_company::TEXT||'|'||
            p_idempotency_key::TEXT,
        v_method.payment_method_name,
        jsonb_build_object(
            'expenseDocumentId',v_document.id,
            'additionalRequestId',v_request.id,
            'disbursedAmount',v_request.amount,
            'outstandingAccountId',v_outstanding_account_id,
            'paymentAccountId',v_payment_account_id,
            'paymentAccountFunction',v_payment_function,
            'settlementRoute',v_method.settlement_route,
            'cashierSessionId',v_session.id,
            'approvalSnapshot',v_approval_snapshot,
            'financePostingState','HOLD_UNTIL_G6'
        ),
        'HOLD'::public.event_status,
        'CANONICAL_FINANCE_POSTING_NOT_ENABLED',v_actor,v_company,
        v_document.store_id,'EXPENSE_DISBURSEMENT',v_transaction_category_id
    ) RETURNING id INTO v_financial_event_id;

    INSERT INTO public.expense_disbursements(
        id,company_id,document_id,store_id,pos_terminal_id,amount,
        payment_method_id,payment_method_name_snapshot,
        payment_method_type_snapshot,payment_settlement_route_snapshot,
        payment_account_function_snapshot,cashier_session_id,evidence_url,
        idempotency_key,financial_event_id,transaction_category_id,
        outstanding_account_id_snapshot,payment_account_id_snapshot,
        document_master_version_snapshot,approval_snapshot,created_by,created_at
    ) VALUES (
        v_disbursement_id,v_company,v_document.id,v_document.store_id,
        v_session.pos_id,v_request.amount,v_method.id,
        v_method.payment_method_name,v_method.method_type,
        v_method.settlement_route,v_payment_function,v_session.id,
        p_evidence_url,p_idempotency_key,v_financial_event_id,
        v_transaction_category_id,v_outstanding_account_id,
        v_payment_account_id,v_document.master_version,
        v_approval_snapshot,v_actor,v_now
    );

    IF v_method.method_type='CASH' THEN
        INSERT INTO public.cash_drawer_movements(
            company_id,store_id,pos_terminal_id,cashier_session_id,
            direction,movement_type,amount,source_table,source_id,
            expected_cash_after,actor_id,created_at
        ) VALUES (
            v_company,v_document.store_id,v_session.pos_id,v_session.id,
            'OUT','EXPENSE_DISBURSEMENT',v_request.amount,
            'expense_disbursements',v_disbursement_id,
            v_expected_after,v_actor,v_now
        );
    END IF;

    v_disbursed:=v_document.disbursed_amount+v_request.amount;
    v_outstanding:=v_disbursed-v_document.actual_expense_amount-
        v_document.returned_amount;
    v_status:=private.expense_status_from_totals(
        v_disbursed,v_document.actual_expense_amount,
        v_document.returned_amount
    );

    UPDATE public.expense_documents
    SET status=v_status,disbursed_amount=v_disbursed,
        outstanding_amount=v_outstanding,
        master_version=master_version+1,updated_by=v_actor,updated_at=v_now
    WHERE company_id=v_company AND id=v_document.id
    RETURNING master_version INTO v_new_document_version;

    UPDATE public.expense_additional_disbursement_requests
    SET status='DISBURSED',disbursed_by=v_actor,disbursed_at=v_now,
        expense_disbursement_id=v_disbursement_id,
        master_version=master_version+1
    WHERE company_id=v_company AND id=v_request.id
    RETURNING master_version INTO v_new_request_version;

    INSERT INTO public.expense_audit(
        company_id,entity_type,entity_id,document_id,action,actor_id,
        before_state,after_state,created_at
    )
    SELECT v_company,'DISBURSEMENT',v_disbursement_id,v_document.id,
        'DISBURSE',v_actor,v_before,
        jsonb_build_object(
            'document',to_jsonb(document),
            'disbursement',to_jsonb(disbursement),
            'additionalRequestId',v_request.id
        ),v_now
    FROM public.expense_documents document
    JOIN public.expense_disbursements disbursement
      ON disbursement.company_id=document.company_id
     AND disbursement.document_id=document.id
     AND disbursement.id=v_disbursement_id
    WHERE document.company_id=v_company AND document.id=v_document.id;

    RETURN jsonb_build_object(
        'additionalRequestId',v_request.id,
        'documentId',v_document.id,
        'disbursementId',v_disbursement_id,
        'status',v_status,
        'requestStatus','DISBURSED',
        'requestMasterVersion',v_new_request_version,
        'documentMasterVersion',v_new_document_version,
        'amount',v_request.amount,
        'paymentMethodType',v_method.method_type,
        'expectedCashAfter',v_expected_after,
        'financialEventId',v_financial_event_id,
        'idempotentReplay',FALSE
    );
END;
$$;

REVOKE ALL ON FUNCTION public.review_additional_expense_disbursement(
    UUID,BIGINT,TEXT,TEXT
) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.review_additional_expense_disbursement(
    UUID,BIGINT,TEXT,TEXT
) TO authenticated,service_role;

REVOKE ALL ON FUNCTION public.disburse_additional_expense(
    UUID,BIGINT,BIGINT,UUID,TEXT,UUID
) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.disburse_additional_expense(
    UUID,BIGINT,BIGINT,UUID,TEXT,UUID
) TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES(
    '20260804100000',
    'g4_phase40_additional_expense_disbursement',
    'POS-007 guarded additional Expense request review and Cash/non-Cash disbursement with exact idempotency, drawer isolation, audit, and Finance HOLD event'
);

COMMIT;
