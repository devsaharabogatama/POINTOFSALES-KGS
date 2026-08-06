-- KGS POS G4 phase 34: guarded initial Expense disbursement foundation.
-- Requirement: POS-007
-- Dependency: G4 phase 30 request/approval foundation.
--
-- BOUNDARY:
-- - only an APPROVED Expense can be disbursed;
-- - the first disbursement always equals the approved requested amount;
-- - Cash creates exactly one immutable drawer OUT movement in an OPEN Session;
-- - non-Cash requires Finance/Admin authority and never changes the drawer;
-- - a HOLD Financial Event is emitted, but final G6 journal posting stays off;
-- - settlement, return, Cash In, additional disbursement, and Offline remain off.

BEGIN;

DO $migration_guard$
BEGIN
    IF to_regclass('private.kgs_schema_migrations') IS NULL
       OR NOT EXISTS (
           SELECT 1 FROM private.kgs_schema_migrations
           WHERE version='20260803040000'
       ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: G4 phase 30 is incomplete';
    END IF;
    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version='20260803070000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260803070000';
    END IF;
    IF EXISTS (SELECT 1 FROM public.expense_disbursements)
       OR EXISTS (SELECT 1 FROM public.cash_drawer_movements) THEN
        RAISE EXCEPTION
            'G4_PHASE34_STATE_CHANGED: disbursement or drawer history exists';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema='public'
          AND table_name='expense_disbursements'
          AND column_name IN (
              'store_id','pos_terminal_id','payment_settlement_route_snapshot',
              'payment_account_function_snapshot','transaction_category_id',
              'outstanding_account_id_snapshot','payment_account_id_snapshot',
              'document_master_version_snapshot','approval_snapshot'
          )
    ) OR to_regprocedure(
        'public.disburse_expense(uuid,bigint,uuid,text,uuid)'
    ) IS NOT NULL THEN
        RAISE EXCEPTION
            'G4_PHASE34_STATE_CHANGED: disbursement runtime already exists';
    END IF;
END
$migration_guard$;

ALTER TYPE public.event_type ADD VALUE IF NOT EXISTS 'EXPENSE_DISBURSEMENT';

ALTER TABLE public.expense_disbursements
    ADD COLUMN store_id UUID NOT NULL,
    ADD COLUMN pos_terminal_id UUID,
    ADD COLUMN payment_settlement_route_snapshot TEXT NOT NULL,
    ADD COLUMN payment_account_function_snapshot TEXT NOT NULL,
    ADD COLUMN transaction_category_id UUID NOT NULL,
    ADD COLUMN outstanding_account_id_snapshot UUID NOT NULL,
    ADD COLUMN payment_account_id_snapshot UUID NOT NULL,
    ADD COLUMN document_master_version_snapshot BIGINT NOT NULL,
    ADD COLUMN approval_snapshot JSONB NOT NULL,
    ADD CONSTRAINT expense_disbursement_route_check CHECK (
        (payment_method_type_snapshot='CASH'
         AND payment_settlement_route_snapshot='CASH_DRAWER'
         AND cashier_session_id IS NOT NULL
         AND pos_terminal_id IS NOT NULL)
        OR
        (payment_method_type_snapshot IN ('TRANSFER','QRIS','CARD','E_WALLET')
         AND payment_settlement_route_snapshot IN ('DIRECT_BANK','CLEARING')
         AND cashier_session_id IS NULL
         AND pos_terminal_id IS NULL)
    ),
    ADD CONSTRAINT expense_disbursement_account_function_not_blank CHECK (
        btrim(payment_account_function_snapshot)<>''
    ),
    ADD CONSTRAINT expense_disbursement_document_version_positive CHECK (
        document_master_version_snapshot>0
    ),
    ADD CONSTRAINT expense_disbursement_approval_snapshot_check CHECK (
        jsonb_typeof(approval_snapshot)='object'
        AND approval_snapshot ? 'approvalRequired'
        AND approval_snapshot ? 'approvedBy'
        AND approval_snapshot ? 'approvedAt'
        AND approval_snapshot ? 'documentMasterVersion'
    ),
    ADD CONSTRAINT fk_expense_disbursement_store
        FOREIGN KEY(company_id,store_id)
        REFERENCES public.stores(company_id,id) ON DELETE RESTRICT,
    ADD CONSTRAINT fk_expense_disbursement_terminal
        FOREIGN KEY(company_id,store_id,pos_terminal_id)
        REFERENCES public.pos_terminals(company_id,store_id,id)
        ON DELETE RESTRICT,
    ADD CONSTRAINT fk_expense_disbursement_store_session
        FOREIGN KEY(company_id,store_id,cashier_session_id)
        REFERENCES public.cashier_sessions(company_id,store_id,id)
        ON DELETE RESTRICT,
    ADD CONSTRAINT fk_expense_disbursement_transaction_category
        FOREIGN KEY(company_id,transaction_category_id)
        REFERENCES public.transaction_categories(company_id,id)
        ON DELETE RESTRICT,
    ADD CONSTRAINT fk_expense_disbursement_outstanding_account
        FOREIGN KEY(company_id,outstanding_account_id_snapshot)
        REFERENCES public.chart_of_accounts(company_id,id)
        ON DELETE RESTRICT,
    ADD CONSTRAINT fk_expense_disbursement_payment_account
        FOREIGN KEY(company_id,payment_account_id_snapshot)
        REFERENCES public.chart_of_accounts(company_id,id)
        ON DELETE RESTRICT;

CREATE INDEX idx_expense_disbursement_document_time
    ON public.expense_disbursements(company_id,document_id,created_at);
CREATE INDEX idx_expense_disbursement_session_time
    ON public.expense_disbursements(company_id,cashier_session_id,created_at)
    WHERE cashier_session_id IS NOT NULL;

CREATE FUNCTION private.resolve_expense_disbursement_account(
    p_company_id UUID,
    p_transaction_category_id UUID,
    p_account_function_key TEXT,
    p_effective_at TIMESTAMPTZ
)
RETURNS UUID
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE
    v_account_id UUID;
    v_function_key TEXT:=upper(btrim(COALESCE(p_account_function_key,'')));
BEGIN
    IF v_function_key='' THEN
        RAISE EXCEPTION 'EXPENSE_DISBURSEMENT_ACCOUNT_FUNCTION_REQUIRED';
    END IF;

    SELECT rule.account_id INTO v_account_id
    FROM public.transaction_account_rules rule
    JOIN public.chart_of_accounts account
      ON account.company_id=rule.company_id
     AND account.id=rule.account_id
     AND account.is_active
     AND account.is_postable
    WHERE rule.company_id=p_company_id
      AND rule.transaction_category_id=p_transaction_category_id
      AND rule.account_function_key=v_function_key
      AND rule.status='ACTIVE'
      AND rule.effective_from<=p_effective_at
      AND (rule.effective_to IS NULL OR rule.effective_to>p_effective_at)
    ORDER BY rule.effective_from DESC,rule.rule_version DESC
    LIMIT 1;

    IF v_account_id IS NULL THEN
        SELECT fallback.account_id INTO v_account_id
        FROM public.company_account_function_fallbacks fallback
        JOIN public.chart_of_accounts account
          ON account.company_id=fallback.company_id
         AND account.id=fallback.account_id
         AND account.is_active
         AND account.is_postable
        WHERE fallback.company_id=p_company_id
          AND fallback.account_function_key=v_function_key
          AND fallback.status='ACTIVE'
          AND fallback.effective_from<=p_effective_at
          AND (fallback.effective_to IS NULL
               OR fallback.effective_to>p_effective_at)
        ORDER BY fallback.effective_from DESC,fallback.fallback_version DESC
        LIMIT 1;
    END IF;

    IF v_account_id IS NULL THEN
        SELECT account.id INTO v_account_id
        FROM public.chart_of_accounts account
        WHERE account.company_id=p_company_id
          AND account.system_function_key=v_function_key
          AND account.is_active
          AND account.is_postable
        ORDER BY account.account_code,account.id
        LIMIT 1;
    END IF;

    IF v_account_id IS NULL THEN
        RAISE EXCEPTION 'EXPENSE_DISBURSEMENT_ACCOUNT_NOT_RESOLVED:%',
            v_function_key;
    END IF;
    RETURN v_account_id;
END;
$$;

-- Keep one canonical Session calculation. Cash Drawer Movement is additive to
-- existing Cash Sale and Sales Return behavior; non-Cash never enters it.
CREATE OR REPLACE FUNCTION private.calculate_cashier_session_expected_cash(
    p_company_id UUID,
    p_cashier_session_id UUID
)
RETURNS NUMERIC
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
    SELECT session.opening_cash_actual
        + COALESCE((
            SELECT sum(CASE WHEN payment.is_reversal
                            THEN -payment.amount ELSE payment.amount END)
            FROM public.sales_payments payment
            JOIN public.sales_headers sale
              ON sale.company_id=payment.company_id
             AND sale.id=payment.sales_id
            LEFT JOIN public.payment_methods method
              ON method.company_id=payment.company_id
             AND method.id=payment.payment_method_id
            WHERE payment.company_id=session.company_id
              AND payment.session_id=session.id
              AND sale.invoice_status::TEXT='GENERATED'
              AND (method.method_type='CASH' OR (
                  payment.payment_method_id IS NULL
                  AND payment.payment_method::TEXT='Cash'
              ))
        ),0)
        - COALESCE((
            SELECT sum(refund.amount)
            FROM public.sales_return_refunds refund
            JOIN public.sales_return_documents document
              ON document.company_id=refund.company_id
             AND document.id=refund.document_id
             AND document.status='POSTED'
            WHERE refund.company_id=session.company_id
              AND document.executing_session_id=session.id
              AND refund.payment_method_type_snapshot='CASH'
        ),0)
        + COALESCE((
            SELECT sum(CASE WHEN movement.direction='IN'
                            THEN movement.amount ELSE -movement.amount END)
            FROM public.cash_drawer_movements movement
            WHERE movement.company_id=session.company_id
              AND movement.cashier_session_id=session.id
        ),0)
    FROM public.cashier_sessions session
    WHERE session.company_id=p_company_id
      AND session.id=p_cashier_session_id;
$$;

CREATE FUNCTION public.disburse_expense(
    p_document_id UUID,
    p_master_version BIGINT,
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
    v_new_version BIGINT;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF p_idempotency_key IS NULL THEN
        RAISE EXCEPTION 'EXPENSE_DISBURSEMENT_IDEMPOTENCY_KEY_REQUIRED';
    END IF;
    IF NOT public.private_company_feature_enabled(
        v_company,'expense_enabled'
    ) THEN RAISE EXCEPTION 'EXPENSE_FEATURE_DISABLED'; END IF;

    PERFORM pg_advisory_xact_lock(hashtextextended(
        'G4_EXPENSE_DISBURSEMENT|'||v_company::TEXT||'|'||
            p_idempotency_key::TEXT,0
    ));
    SELECT * INTO v_existing
    FROM public.expense_disbursements
    WHERE company_id=v_company AND idempotency_key=p_idempotency_key;
    IF FOUND THEN
        IF v_existing.document_id IS DISTINCT FROM p_document_id
           OR v_existing.cashier_session_id IS DISTINCT FROM p_cashier_session_id
           OR v_existing.evidence_url IS DISTINCT FROM p_evidence_url THEN
            RAISE EXCEPTION 'EXPENSE_DISBURSEMENT_IDEMPOTENCY_CONFLICT';
        END IF;
        SELECT * INTO v_document
        FROM public.expense_documents
        WHERE company_id=v_company AND id=v_existing.document_id;
        RETURN jsonb_build_object(
            'documentId',v_existing.document_id,
            'disbursementId',v_existing.id,
            'status',v_document.status,
            'masterVersion',v_document.master_version,
            'amount',v_existing.amount,
            'paymentMethodType',v_existing.payment_method_type_snapshot,
            'idempotentReplay',TRUE
        );
    END IF;

    SELECT * INTO v_document
    FROM public.expense_documents
    WHERE company_id=v_company AND id=p_document_id
    FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'EXPENSE_DOCUMENT_NOT_FOUND'; END IF;
    IF v_document.status<>'APPROVED' THEN
        RAISE EXCEPTION 'ONLY_APPROVED_EXPENSE_DISBURSABLE';
    END IF;
    IF p_master_version IS NULL
       OR p_master_version<>v_document.master_version THEN
        RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
    END IF;
    IF v_document.requested_amount<=0
       OR v_document.disbursed_amount<>0
       OR v_document.actual_expense_amount<>0
       OR v_document.returned_amount<>0
       OR v_document.outstanding_amount<>0 THEN
        RAISE EXCEPTION 'EXPENSE_INITIAL_DISBURSEMENT_STATE_INVALID';
    END IF;
    IF v_document.approved_by IS NULL OR v_document.approved_at IS NULL THEN
        RAISE EXCEPTION 'EXPENSE_APPROVAL_SNAPSHOT_INCOMPLETE';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM public.stores store
        WHERE store.company_id=v_company
          AND store.id=v_document.store_id
          AND store.status='ACTIVE'
    ) THEN RAISE EXCEPTION 'ACTIVE_STORE_NOT_FOUND'; END IF;
    IF NOT public.private_user_has_store_access(v_document.store_id) THEN
        RAISE EXCEPTION 'EXPENSE_STORE_ACCESS_REQUIRED';
    END IF;

    SELECT * INTO v_method
    FROM public.payment_methods method
    WHERE method.company_id=v_company
      AND method.id=v_document.requested_payment_method_id
      AND method.is_active
      AND method.effective_from<=v_now
      AND (method.effective_to IS NULL OR method.effective_to>v_now)
      AND method.method_type IN ('CASH','TRANSFER','QRIS','CARD','E_WALLET')
      AND (
          method.available_all_stores
          OR EXISTS (
              SELECT 1
              FROM public.payment_method_store_assignments assignment
              WHERE assignment.company_id=v_company
                AND assignment.payment_method_id=method.id
                AND assignment.store_id=v_document.store_id
          )
      );
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ACTIVE_EXPENSE_PAYMENT_METHOD_NOT_FOUND';
    END IF;
    IF v_method.method_type IS DISTINCT FROM
       v_document.requested_payment_method_type_snapshot THEN
        RAISE EXCEPTION 'EXPENSE_PAYMENT_METHOD_SNAPSHOT_CONFLICT';
    END IF;
    IF p_evidence_url IS NOT NULL AND p_evidence_url !~* '^https://' THEN
        RAISE EXCEPTION 'EXPENSE_DISBURSEMENT_EVIDENCE_HTTPS_REQUIRED';
    END IF;
    IF v_method.proof_mode='REQUIRED' AND p_evidence_url IS NULL THEN
        RAISE EXCEPTION 'EXPENSE_DISBURSEMENT_EVIDENCE_REQUIRED';
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
        IF v_expected_before<v_document.requested_amount THEN
            RAISE EXCEPTION 'INSUFFICIENT_EXPECTED_CASH';
        END IF;
        v_expected_after:=v_expected_before-v_document.requested_amount;
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
        'approvalRequired',v_document.approval_required_snapshot,
        'approvedBy',v_document.approved_by,
        'approvedAt',v_document.approved_at,
        'documentMasterVersion',v_document.master_version
    );
    v_before:=to_jsonb(v_document);

    INSERT INTO public.financial_events(
        event_code,event_type,source_table,source_id,root_sales_id,
        event_date,event_version,idempotency_key,payment_method,amounts,
        status,error_message,created_by,company_id,store_id,
        system_event_key,transaction_category_id
    ) VALUES (
        'EXP-DISB-'||replace(v_disbursement_id::TEXT,'-',''),
        'EXPENSE_DISBURSEMENT'::public.event_type,
        'expense_disbursements',v_disbursement_id,NULL,v_now,1,
        'EXPENSE_DISBURSEMENT|'||v_company::TEXT||'|'||
            p_idempotency_key::TEXT,
        v_method.payment_method_name,
        jsonb_build_object(
            'expenseDocumentId',v_document.id,
            'requestedAmount',v_document.requested_amount,
            'disbursedAmount',v_document.requested_amount,
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
        v_session.pos_id,v_document.requested_amount,v_method.id,
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
            'OUT','EXPENSE_DISBURSEMENT',v_document.requested_amount,
            'expense_disbursements',v_disbursement_id,
            v_expected_after,v_actor,v_now
        );
    END IF;

    UPDATE public.expense_documents
    SET status='DISBURSED',
        disbursed_amount=v_document.requested_amount,
        outstanding_amount=v_document.requested_amount,
        master_version=master_version+1,
        updated_by=v_actor,
        updated_at=v_now
    WHERE company_id=v_company AND id=v_document.id
    RETURNING master_version INTO v_new_version;

    INSERT INTO public.expense_audit(
        company_id,entity_type,entity_id,document_id,action,actor_id,
        before_state,after_state,created_at
    )
    SELECT v_company,'DISBURSEMENT',v_disbursement_id,v_document.id,
        'DISBURSE',v_actor,v_before,
        jsonb_build_object(
            'document',to_jsonb(document),
            'disbursement',to_jsonb(disbursement)
        ),v_now
    FROM public.expense_documents document
    JOIN public.expense_disbursements disbursement
      ON disbursement.company_id=document.company_id
     AND disbursement.document_id=document.id
     AND disbursement.id=v_disbursement_id
    WHERE document.company_id=v_company AND document.id=v_document.id;

    RETURN jsonb_build_object(
        'documentId',v_document.id,
        'disbursementId',v_disbursement_id,
        'status','DISBURSED',
        'masterVersion',v_new_version,
        'amount',v_document.requested_amount,
        'paymentMethodType',v_method.method_type,
        'expectedCashAfter',v_expected_after,
        'financialEventId',v_financial_event_id,
        'idempotentReplay',FALSE
    );
END;
$$;

REVOKE ALL ON FUNCTION private.resolve_expense_disbursement_account(
    UUID,UUID,TEXT,TIMESTAMPTZ
) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.resolve_expense_disbursement_account(
    UUID,UUID,TEXT,TIMESTAMPTZ
) TO service_role;

REVOKE ALL ON FUNCTION public.disburse_expense(
    UUID,BIGINT,UUID,TEXT,UUID
) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.disburse_expense(
    UUID,BIGINT,UUID,TEXT,UUID
) TO authenticated,service_role;

-- The replacement remains private; browser access is only through the guarded
-- disbursement RPC and the existing close-session RPC.
REVOKE ALL ON FUNCTION private.calculate_cashier_session_expected_cash(
    UUID,UUID
) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.calculate_cashier_session_expected_cash(
    UUID,UUID
) TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES(
    '20260803070000','g4_phase34_expense_disbursement_foundation',
    'Guarded initial approved Expense disbursement with approval/payment/account snapshots, Cash Drawer OUT, non-Cash isolation, idempotency, audit, and Finance HOLD event'
);

COMMIT;
