-- KGS POS G4 phase 43: canonical multi-Session Cash Deposit foundation.
-- Requirement: POS-008
-- Dependencies: canonical Cashier Session and Additional Expense through
-- 20260729040000 and 20260804100000.
--
-- Opens guarded Draft -> Submitted -> Approved/Rejected/Canceled lifecycle,
-- Session locking, approval snapshots, variance exception opening, audit, and
-- Financial Event HOLD. UI, bank matching, variance resolution, and G6 journal
-- posting remain closed.

BEGIN;

DO $migration_guard$
BEGIN
    IF to_regclass('private.kgs_schema_migrations') IS NULL
       OR NOT EXISTS (
           SELECT 1 FROM private.kgs_schema_migrations
           WHERE version='20260729040000'
       )
       OR NOT EXISTS (
           SELECT 1 FROM private.kgs_schema_migrations
           WHERE version='20260804100000'
       ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: G4 Cash Deposit dependencies incomplete';
    END IF;
    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version='20260804130000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260804130000';
    END IF;
END
$migration_guard$;

-- The approved preflight reported an empty legacy deposit surface. Automatic
-- conversion would invent expected cash and variance history, so stop instead.
DO $legacy_surface_guard$
BEGIN
    IF EXISTS (SELECT 1 FROM public.bank_deposits) THEN
        RAISE EXCEPTION
            'G4_PHASE43_STATE_CHANGED: legacy bank deposits require explicit backfill';
    END IF;
END
$legacy_surface_guard$;

CREATE SEQUENCE private.cash_deposit_no_seq AS BIGINT START WITH 1;
REVOKE ALL ON SEQUENCE private.cash_deposit_no_seq
FROM PUBLIC,anon,authenticated;
GRANT USAGE,SELECT ON SEQUENCE private.cash_deposit_no_seq TO service_role;

CREATE TABLE public.cash_deposit_policies (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
    store_id UUID,
    proof_mode TEXT NOT NULL DEFAULT 'OPTIONAL',
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    master_version BIGINT NOT NULL DEFAULT 1,
    created_by UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
    updated_by UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT cash_deposit_policy_company_id_id_unique UNIQUE(company_id,id),
    CONSTRAINT cash_deposit_policy_proof_mode_check
        CHECK (proof_mode IN ('OPTIONAL','REQUIRED')),
    CONSTRAINT cash_deposit_policy_version_positive CHECK(master_version>0),
    CONSTRAINT fk_cash_deposit_policy_store
        FOREIGN KEY(company_id,store_id)
        REFERENCES public.stores(company_id,id) ON DELETE RESTRICT
);
CREATE UNIQUE INDEX uq_cash_deposit_policy_company_default
    ON public.cash_deposit_policies(company_id) WHERE store_id IS NULL;
CREATE UNIQUE INDEX uq_cash_deposit_policy_store
    ON public.cash_deposit_policies(company_id,store_id)
    WHERE store_id IS NOT NULL;

CREATE TABLE public.cash_deposit_documents (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL,
    store_id UUID NOT NULL,
    deposit_no TEXT NOT NULL,
    destination_type TEXT NOT NULL,
    destination_name_snapshot TEXT NOT NULL,
    actual_deposit_amount NUMERIC(20,4) NOT NULL,
    total_expected_deposit NUMERIC(20,4) NOT NULL DEFAULT 0,
    deposit_variance NUMERIC(20,4) NOT NULL DEFAULT 0,
    variance_type TEXT NOT NULL DEFAULT 'MATCHED',
    deposit_at TIMESTAMPTZ NOT NULL,
    evidence_url TEXT,
    notes TEXT,
    status TEXT NOT NULL DEFAULT 'DRAFT',
    proof_mode_snapshot TEXT,
    client_deposit_id UUID NOT NULL,
    payload_hash TEXT NOT NULL,
    submit_idempotency_key UUID,
    review_idempotency_key UUID,
    transaction_category_id UUID,
    cash_drawer_account_id UUID,
    destination_account_id UUID,
    variance_account_id UUID,
    financial_event_id UUID,
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
    CONSTRAINT cash_deposit_document_company_id_id_unique UNIQUE(company_id,id),
    CONSTRAINT cash_deposit_document_company_no_unique UNIQUE(company_id,deposit_no),
    CONSTRAINT cash_deposit_document_client_unique UNIQUE(company_id,client_deposit_id),
    CONSTRAINT cash_deposit_document_destination_check
        CHECK(destination_type IN ('BANK','VAULT')),
    CONSTRAINT cash_deposit_document_amount_positive
        CHECK(actual_deposit_amount>0),
    CONSTRAINT cash_deposit_document_expected_nonnegative
        CHECK(total_expected_deposit>=0),
    CONSTRAINT cash_deposit_document_variance_check CHECK(
        deposit_variance=actual_deposit_amount-total_expected_deposit
        AND variance_type=CASE
            WHEN deposit_variance<0 THEN 'UNDER_DEPOSIT'
            WHEN deposit_variance>0 THEN 'OVER_DEPOSIT'
            ELSE 'MATCHED' END
    ),
    CONSTRAINT cash_deposit_document_status_check CHECK(
        status IN ('DRAFT','SUBMITTED','APPROVED','REJECTED','CANCELED')
    ),
    CONSTRAINT cash_deposit_document_proof_mode_check CHECK(
        proof_mode_snapshot IS NULL
        OR proof_mode_snapshot IN ('OPTIONAL','REQUIRED')
    ),
    CONSTRAINT cash_deposit_document_evidence_https CHECK(
        evidence_url IS NULL OR evidence_url~*'^https://'
    ),
    CONSTRAINT cash_deposit_document_identity_not_blank CHECK(
        btrim(deposit_no)<>'' AND btrim(destination_name_snapshot)<>''
        AND btrim(payload_hash)<>''
    ),
    CONSTRAINT cash_deposit_document_version_positive CHECK(master_version>0),
    CONSTRAINT fk_cash_deposit_document_store FOREIGN KEY(company_id,store_id)
        REFERENCES public.stores(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_cash_deposit_document_category
        FOREIGN KEY(company_id,transaction_category_id)
        REFERENCES public.transaction_categories(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_cash_deposit_document_drawer_account
        FOREIGN KEY(company_id,cash_drawer_account_id)
        REFERENCES public.chart_of_accounts(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_cash_deposit_document_destination_account
        FOREIGN KEY(company_id,destination_account_id)
        REFERENCES public.chart_of_accounts(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_cash_deposit_document_variance_account
        FOREIGN KEY(company_id,variance_account_id)
        REFERENCES public.chart_of_accounts(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_cash_deposit_document_event
        FOREIGN KEY(financial_event_id) REFERENCES public.financial_events(id)
        ON DELETE RESTRICT
);
CREATE INDEX idx_cash_deposit_document_store_status
    ON public.cash_deposit_documents(company_id,store_id,status,created_at DESC);

CREATE TABLE public.cash_deposit_session_lines (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL,
    deposit_document_id UUID NOT NULL,
    store_id UUID NOT NULL,
    cashier_session_id UUID NOT NULL,
    line_no INTEGER NOT NULL,
    session_code_snapshot TEXT NOT NULL,
    cashier_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
    cashier_name_snapshot TEXT NOT NULL,
    closing_cash_actual_snapshot NUMERIC(20,4) NOT NULL,
    next_session_float_reserved NUMERIC(20,4) NOT NULL DEFAULT 0,
    posted_deposit_allocations_snapshot NUMERIC(20,4) NOT NULL DEFAULT 0,
    expected_deposit_amount NUMERIC(20,4) NOT NULL,
    allocation_status TEXT NOT NULL DEFAULT 'DRAFT',
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT cash_deposit_session_line_unique
        UNIQUE(deposit_document_id,cashier_session_id),
    CONSTRAINT cash_deposit_session_line_company_id_id_unique UNIQUE(company_id,id),
    CONSTRAINT cash_deposit_session_line_no_positive CHECK(line_no>0),
    CONSTRAINT cash_deposit_session_line_snapshot_nonnegative CHECK(
        closing_cash_actual_snapshot>=0
        AND next_session_float_reserved>=0
        AND posted_deposit_allocations_snapshot>=0
        AND expected_deposit_amount>0
        AND expected_deposit_amount=
            closing_cash_actual_snapshot-next_session_float_reserved-
            posted_deposit_allocations_snapshot
    ),
    CONSTRAINT cash_deposit_session_line_status_check CHECK(
        allocation_status IN ('DRAFT','LOCKED','POSTED','RELEASED')
    ),
    CONSTRAINT cash_deposit_session_line_snapshot_not_blank CHECK(
        btrim(session_code_snapshot)<>'' AND btrim(cashier_name_snapshot)<>''
    ),
    CONSTRAINT fk_cash_deposit_line_document
        FOREIGN KEY(company_id,deposit_document_id)
        REFERENCES public.cash_deposit_documents(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_cash_deposit_line_store
        FOREIGN KEY(company_id,store_id)
        REFERENCES public.stores(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_cash_deposit_line_session
        FOREIGN KEY(company_id,store_id,cashier_session_id)
        REFERENCES public.cashier_sessions(company_id,store_id,id) ON DELETE RESTRICT
);
CREATE UNIQUE INDEX uq_cash_deposit_locked_or_posted_session
    ON public.cash_deposit_session_lines(company_id,cashier_session_id)
    WHERE allocation_status IN ('LOCKED','POSTED');
CREATE INDEX idx_cash_deposit_session_line_document
    ON public.cash_deposit_session_lines(company_id,deposit_document_id,line_no);

CREATE TABLE public.cash_deposit_audit (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_id UUID NOT NULL,
    deposit_document_id UUID NOT NULL,
    action TEXT NOT NULL,
    actor_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
    before_state JSONB,
    after_state JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT cash_deposit_audit_action_check CHECK(
        action IN ('CREATE','UPDATE','SUBMIT','APPROVE','REJECT','CANCEL')
    ),
    CONSTRAINT fk_cash_deposit_audit_document
        FOREIGN KEY(company_id,deposit_document_id)
        REFERENCES public.cash_deposit_documents(company_id,id) ON DELETE RESTRICT
);
CREATE INDEX idx_cash_deposit_audit_document
    ON public.cash_deposit_audit(company_id,deposit_document_id,created_at DESC);

CREATE TABLE public.deposit_variance_exceptions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL,
    store_id UUID NOT NULL,
    cash_deposit_document_id UUID NOT NULL,
    variance_type TEXT NOT NULL,
    original_amount NUMERIC(20,4) NOT NULL,
    resolved_amount NUMERIC(20,4) NOT NULL DEFAULT 0,
    remaining_amount NUMERIC(20,4) NOT NULL,
    status TEXT NOT NULL DEFAULT 'OPEN',
    responsible_party_type TEXT,
    responsible_party_id UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
    transaction_category_id UUID NOT NULL,
    control_account_id UUID NOT NULL,
    opened_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    created_by UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
    updated_by UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT deposit_variance_exception_company_id_id_unique UNIQUE(company_id,id),
    CONSTRAINT deposit_variance_exception_document_unique
        UNIQUE(company_id,cash_deposit_document_id),
    CONSTRAINT deposit_variance_exception_type_check
        CHECK(variance_type IN ('UNDER_DEPOSIT','OVER_DEPOSIT')),
    CONSTRAINT deposit_variance_exception_amount_check CHECK(
        original_amount>0 AND resolved_amount>=0
        AND remaining_amount=original_amount-resolved_amount
        AND remaining_amount>=0
    ),
    CONSTRAINT deposit_variance_exception_status_check CHECK(
        status IN ('OPEN','PARTIALLY_RESOLVED','RESOLVED','WRITTEN_OFF','CANCELED')
    ),
    CONSTRAINT fk_deposit_variance_exception_document
        FOREIGN KEY(company_id,cash_deposit_document_id)
        REFERENCES public.cash_deposit_documents(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_deposit_variance_exception_store
        FOREIGN KEY(company_id,store_id)
        REFERENCES public.stores(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_deposit_variance_exception_category
        FOREIGN KEY(company_id,transaction_category_id)
        REFERENCES public.transaction_categories(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_deposit_variance_exception_account
        FOREIGN KEY(company_id,control_account_id)
        REFERENCES public.chart_of_accounts(company_id,id) ON DELETE RESTRICT
);

CREATE TABLE public.deposit_variance_allocations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL,
    variance_exception_id UUID NOT NULL,
    allocation_amount NUMERIC(20,4) NOT NULL,
    resolution_type TEXT NOT NULL,
    reason TEXT NOT NULL,
    evidence_url TEXT,
    account_id UUID,
    transaction_category_id UUID,
    financial_event_id UUID REFERENCES public.financial_events(id) ON DELETE RESTRICT,
    idempotency_key UUID NOT NULL,
    created_by UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT deposit_variance_allocation_idempotency_unique
        UNIQUE(company_id,idempotency_key),
    CONSTRAINT deposit_variance_allocation_amount_positive
        CHECK(allocation_amount>0),
    CONSTRAINT deposit_variance_allocation_resolution_check CHECK(
        resolution_type IN (
            'CASHIER_RECEIVABLE','COMPANY_EXPENSE','OTHER_RECEIVABLE',
            'CASH_OVERAGE_INCOME','REFUND_TO_SOURCE','WRITE_OFF'
        )
    ),
    CONSTRAINT deposit_variance_allocation_evidence_https CHECK(
        evidence_url IS NULL OR evidence_url~*'^https://'
    ),
    CONSTRAINT fk_deposit_variance_allocation_exception
        FOREIGN KEY(company_id,variance_exception_id)
        REFERENCES public.deposit_variance_exceptions(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_deposit_variance_allocation_account
        FOREIGN KEY(company_id,account_id)
        REFERENCES public.chart_of_accounts(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_deposit_variance_allocation_category
        FOREIGN KEY(company_id,transaction_category_id)
        REFERENCES public.transaction_categories(company_id,id) ON DELETE RESTRICT
);

INSERT INTO public.cash_deposit_policies(company_id,proof_mode,is_active)
SELECT company.id,'OPTIONAL',TRUE FROM public.companies company;

CREATE FUNCTION private.trg_g4_provision_cash_deposit_policy()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
BEGIN
    INSERT INTO public.cash_deposit_policies(company_id,proof_mode,is_active)
    VALUES(NEW.id,'OPTIONAL',TRUE) ON CONFLICT DO NOTHING;
    RETURN NEW;
END;
$$;
CREATE TRIGGER g4_provision_cash_deposit_policy
AFTER INSERT ON public.companies FOR EACH ROW
EXECUTE FUNCTION private.trg_g4_provision_cash_deposit_policy();

CREATE FUNCTION private.resolve_cash_deposit_account(
    p_company_id UUID,p_transaction_category_id UUID,
    p_account_function_key TEXT,p_effective_at TIMESTAMPTZ
) RETURNS UUID LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_account UUID; v_key TEXT:=upper(btrim(COALESCE(p_account_function_key,'')));
BEGIN
    IF v_key='' THEN RAISE EXCEPTION 'CASH_DEPOSIT_ACCOUNT_FUNCTION_REQUIRED'; END IF;
    SELECT rule.account_id INTO v_account
    FROM public.transaction_account_rules rule
    JOIN public.chart_of_accounts account
      ON account.company_id=rule.company_id AND account.id=rule.account_id
     AND account.is_active AND account.is_postable
    WHERE rule.company_id=p_company_id
      AND rule.transaction_category_id=p_transaction_category_id
      AND rule.account_function_key=v_key AND rule.status='ACTIVE'
      AND rule.effective_from<=p_effective_at
      AND (rule.effective_to IS NULL OR rule.effective_to>p_effective_at)
    ORDER BY rule.effective_from DESC,rule.rule_version DESC LIMIT 1;
    IF v_account IS NULL THEN
        SELECT fallback.account_id INTO v_account
        FROM public.company_account_function_fallbacks fallback
        JOIN public.chart_of_accounts account
          ON account.company_id=fallback.company_id AND account.id=fallback.account_id
         AND account.is_active AND account.is_postable
        WHERE fallback.company_id=p_company_id
          AND fallback.account_function_key=v_key AND fallback.status='ACTIVE'
          AND fallback.effective_from<=p_effective_at
          AND (fallback.effective_to IS NULL OR fallback.effective_to>p_effective_at)
        ORDER BY fallback.effective_from DESC,fallback.fallback_version DESC LIMIT 1;
    END IF;
    IF v_account IS NULL THEN
        SELECT account.id INTO v_account FROM public.chart_of_accounts account
        WHERE account.company_id=p_company_id
          AND account.system_function_key=v_key
          AND account.is_active AND account.is_postable
        ORDER BY account.account_code,account.id LIMIT 1;
    END IF;
    IF v_account IS NULL THEN
        RAISE EXCEPTION 'CASH_DEPOSIT_ACCOUNT_NOT_RESOLVED:%',v_key;
    END IF;
    RETURN v_account;
END;
$$;

CREATE FUNCTION private.cash_deposit_effective_proof_mode(
    p_company_id UUID,p_store_id UUID
) RETURNS TEXT LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
    SELECT COALESCE(
        (SELECT policy.proof_mode FROM public.cash_deposit_policies policy
         WHERE policy.company_id=p_company_id AND policy.store_id=p_store_id
           AND policy.is_active LIMIT 1),
        (SELECT policy.proof_mode FROM public.cash_deposit_policies policy
         WHERE policy.company_id=p_company_id AND policy.store_id IS NULL
           AND policy.is_active LIMIT 1),
        'OPTIONAL'
    );
$$;

CREATE FUNCTION private.cash_deposit_actor_can_operate(
    p_company_id UUID,p_store_id UUID,p_cashier_id UUID DEFAULT NULL
) RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
    SELECT auth.uid() IS NOT NULL AND (
        (p_cashier_id IS NOT NULL AND auth.uid()=p_cashier_id)
        OR public.private_user_has_any_store_role(
            p_store_id,ARRAY['STORE_MANAGER']::TEXT[]
        )
        OR public.private_user_has_any_company_role(
            p_company_id,
            ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE','ACCOUNTING']::TEXT[]
        )
    );
$$;

CREATE FUNCTION public.list_cash_deposit_eligible_sessions(p_store_id UUID)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id(); v_result JSONB;
BEGIN
    IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF NOT EXISTS(
        SELECT 1 FROM public.stores store
        WHERE store.company_id=v_company AND store.id=p_store_id
          AND store.status='ACTIVE'
    ) OR NOT public.private_user_has_store_access(p_store_id) THEN
        RAISE EXCEPTION 'ACTIVE_STORE_NOT_FOUND';
    END IF;
    SELECT COALESCE(jsonb_agg(row_data ORDER BY row_data->>'closedAt'),'[]'::JSONB)
    INTO v_result FROM (
        SELECT jsonb_build_object(
            'sessionId',session.id,'sessionCode',session.session_code,
            'cashierId',session.cashier_id,'cashierName',profile.name,
            'closedAt',session.closed_at,
            'closingCashActual',session.closing_cash_actual,
            'postedDepositAllocations',COALESCE(posted.amount,0),
            'availableDepositAmount',session.closing_cash_actual-COALESCE(posted.amount,0)
        ) row_data
        FROM public.cashier_sessions session
        JOIN public.profiles profile ON profile.id=session.cashier_id
        LEFT JOIN LATERAL (
            SELECT sum(line.expected_deposit_amount) amount
            FROM public.cash_deposit_session_lines line
            WHERE line.company_id=session.company_id
              AND line.cashier_session_id=session.id
              AND line.allocation_status='POSTED'
        ) posted ON TRUE
        WHERE session.company_id=v_company AND session.store_id=p_store_id
          AND session.status='CLOSED'::public.session_status
          AND session.closing_cash_actual IS NOT NULL
          AND session.closing_cash_actual-COALESCE(posted.amount,0)>0
          AND private.cash_deposit_actor_can_operate(
              v_company,p_store_id,session.cashier_id
          )
          AND NOT EXISTS(
              SELECT 1 FROM public.cash_deposit_session_lines locked
              WHERE locked.company_id=v_company
                AND locked.cashier_session_id=session.id
                AND locked.allocation_status IN ('LOCKED','POSTED')
          )
    ) eligible;
    RETURN v_result;
END;
$$;

CREATE FUNCTION public.save_cash_deposit_draft(
    p_document_id UUID,p_master_version BIGINT,p_store_id UUID,
    p_destination_type TEXT,p_destination_name TEXT,
    p_actual_deposit_amount NUMERIC,p_deposit_at TIMESTAMPTZ,
    p_evidence_url TEXT,p_notes TEXT,p_client_deposit_id UUID,p_sessions JSONB
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
    v_company UUID:=public.private_active_company_id(); v_actor UUID:=auth.uid();
    v_document public.cash_deposit_documents%ROWTYPE; v_item JSONB;
    v_session public.cashier_sessions%ROWTYPE; v_profile_name TEXT;
    v_session_id UUID; v_reserved NUMERIC(20,4); v_posted NUMERIC(20,4);
    v_expected NUMERIC(20,4); v_total NUMERIC(20,4):=0; v_line INTEGER:=0;
    v_variance NUMERIC(20,4); v_type TEXT; v_hash TEXT; v_now TIMESTAMPTZ:=clock_timestamp();
    v_before JSONB; v_new_version BIGINT; v_id UUID; v_is_new BOOLEAN:=FALSE;
BEGIN
    IF v_company IS NULL OR v_actor IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF NOT EXISTS(SELECT 1 FROM public.stores s WHERE s.company_id=v_company AND s.id=p_store_id AND s.status='ACTIVE')
       OR NOT public.private_user_has_store_access(p_store_id) THEN RAISE EXCEPTION 'ACTIVE_STORE_NOT_FOUND'; END IF;
    IF upper(btrim(COALESCE(p_destination_type,''))) NOT IN ('BANK','VAULT') THEN RAISE EXCEPTION 'DEPOSIT_DESTINATION_INVALID'; END IF;
    IF btrim(COALESCE(p_destination_name,''))='' THEN RAISE EXCEPTION 'DEPOSIT_DESTINATION_NAME_REQUIRED'; END IF;
    IF COALESCE(p_actual_deposit_amount,0)<=0 THEN RAISE EXCEPTION 'ACTUAL_DEPOSIT_AMOUNT_MUST_BE_POSITIVE'; END IF;
    IF p_deposit_at IS NULL THEN RAISE EXCEPTION 'DEPOSIT_AT_REQUIRED'; END IF;
    IF p_evidence_url IS NOT NULL AND p_evidence_url!~*'^https://' THEN RAISE EXCEPTION 'DEPOSIT_EVIDENCE_MUST_USE_HTTPS'; END IF;
    IF p_client_deposit_id IS NULL THEN RAISE EXCEPTION 'CLIENT_DEPOSIT_ID_REQUIRED'; END IF;
    IF jsonb_typeof(p_sessions) IS DISTINCT FROM 'array' OR jsonb_array_length(p_sessions)=0 THEN RAISE EXCEPTION 'DEPOSIT_SESSION_REQUIRED'; END IF;
    IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_sessions) item GROUP BY item->>'sessionId' HAVING count(*)>1) THEN RAISE EXCEPTION 'DUPLICATE_DEPOSIT_SESSION'; END IF;

    v_hash:=md5(jsonb_build_object(
        'storeId',p_store_id,'destinationType',upper(btrim(p_destination_type)),
        'destinationName',btrim(p_destination_name),
        'actualDepositAmount',p_actual_deposit_amount,'depositAt',p_deposit_at,
        'evidenceUrl',NULLIF(btrim(COALESCE(p_evidence_url,'')),''),
        'notes',NULLIF(btrim(COALESCE(p_notes,'')),''),
        'sessions',(SELECT jsonb_agg(item ORDER BY item->>'sessionId') FROM jsonb_array_elements(p_sessions) item)
    )::TEXT);

    IF p_document_id IS NULL THEN
        SELECT * INTO v_document FROM public.cash_deposit_documents
        WHERE company_id=v_company AND client_deposit_id=p_client_deposit_id;
        IF FOUND THEN
            IF v_document.payload_hash<>v_hash THEN RAISE EXCEPTION 'CLIENT_DEPOSIT_ID_CONFLICT'; END IF;
            RETURN jsonb_build_object('depositDocumentId',v_document.id,'depositNo',v_document.deposit_no,'status',v_document.status,'masterVersion',v_document.master_version,'idempotentReplay',TRUE);
        END IF;
        v_id:=gen_random_uuid(); v_is_new:=TRUE;
        INSERT INTO public.cash_deposit_documents(
            id,company_id,store_id,deposit_no,destination_type,
            destination_name_snapshot,actual_deposit_amount,
            total_expected_deposit,deposit_variance,variance_type,
            deposit_at,evidence_url,notes,client_deposit_id,payload_hash,
            created_by,updated_by
        ) VALUES(
            v_id,v_company,p_store_id,
            'DEP-'||to_char(v_now,'YYYYMMDD')||'-'||
                lpad(nextval('private.cash_deposit_no_seq')::TEXT,6,'0'),
            upper(btrim(p_destination_type)),btrim(p_destination_name),
            p_actual_deposit_amount,0,p_actual_deposit_amount,'OVER_DEPOSIT',
            p_deposit_at,NULLIF(btrim(COALESCE(p_evidence_url,'')),''),
            NULLIF(btrim(COALESCE(p_notes,'')),''),p_client_deposit_id,
            v_hash,v_actor,v_actor
        );
    ELSE
        SELECT * INTO v_document FROM public.cash_deposit_documents
        WHERE company_id=v_company AND id=p_document_id FOR UPDATE;
        IF NOT FOUND THEN RAISE EXCEPTION 'CASH_DEPOSIT_NOT_FOUND'; END IF;
        IF v_document.status<>'DRAFT' THEN RAISE EXCEPTION 'CASH_DEPOSIT_NOT_EDITABLE'; END IF;
        IF p_master_version IS DISTINCT FROM v_document.master_version THEN RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
        IF NOT private.cash_deposit_actor_can_operate(v_company,v_document.store_id,v_document.created_by) THEN RAISE EXCEPTION 'CASH_DEPOSIT_ACCESS_DENIED'; END IF;
        v_before:=to_jsonb(v_document); v_id:=v_document.id;
        DELETE FROM public.cash_deposit_session_lines
        WHERE company_id=v_company AND deposit_document_id=v_id;
    END IF;

    FOR v_item IN SELECT value FROM jsonb_array_elements(p_sessions) LOOP
        BEGIN v_session_id:=(v_item->>'sessionId')::UUID;
        EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'DEPOSIT_SESSION_ID_INVALID'; END;
        v_reserved:=COALESCE((v_item->>'nextSessionFloatReserved')::NUMERIC,0);
        SELECT * INTO v_session FROM public.cashier_sessions
        WHERE company_id=v_company AND store_id=p_store_id AND id=v_session_id FOR UPDATE;
        IF NOT FOUND OR v_session.status IS DISTINCT FROM 'CLOSED'::public.session_status OR v_session.closing_cash_actual IS NULL THEN RAISE EXCEPTION 'CLOSED_CASHIER_SESSION_NOT_FOUND'; END IF;
        IF NOT private.cash_deposit_actor_can_operate(v_company,p_store_id,v_session.cashier_id) THEN RAISE EXCEPTION 'CASH_DEPOSIT_SESSION_ACCESS_DENIED'; END IF;
        IF v_reserved<0 THEN RAISE EXCEPTION 'NEXT_SESSION_FLOAT_INVALID'; END IF;
        SELECT COALESCE(sum(line.expected_deposit_amount),0) INTO v_posted
        FROM public.cash_deposit_session_lines line
        WHERE line.company_id=v_company AND line.cashier_session_id=v_session.id
          AND line.allocation_status='POSTED';
        v_expected:=v_session.closing_cash_actual-v_reserved-v_posted;
        IF v_expected<=0 THEN RAISE EXCEPTION 'SESSION_HAS_NO_DEPOSITABLE_CASH'; END IF;
        SELECT profile.name INTO v_profile_name FROM public.profiles profile WHERE profile.id=v_session.cashier_id;
        v_line:=v_line+1; v_total:=v_total+v_expected;
        INSERT INTO public.cash_deposit_session_lines(
            company_id,deposit_document_id,store_id,cashier_session_id,line_no,
            session_code_snapshot,cashier_id,cashier_name_snapshot,
            closing_cash_actual_snapshot,next_session_float_reserved,
            posted_deposit_allocations_snapshot,expected_deposit_amount
        ) VALUES(v_company,v_id,p_store_id,v_session.id,v_line,
            v_session.session_code,v_session.cashier_id,v_profile_name,
            v_session.closing_cash_actual,v_reserved,v_posted,v_expected);
    END LOOP;
    v_variance:=p_actual_deposit_amount-v_total;
    v_type:=CASE WHEN v_variance<0 THEN 'UNDER_DEPOSIT' WHEN v_variance>0 THEN 'OVER_DEPOSIT' ELSE 'MATCHED' END;
    IF v_is_new THEN
        UPDATE public.cash_deposit_documents
        SET total_expected_deposit=v_total,deposit_variance=v_variance,
            variance_type=v_type,updated_at=v_now
        WHERE company_id=v_company AND id=v_id
        RETURNING master_version INTO v_new_version;
        INSERT INTO public.cash_deposit_audit(company_id,deposit_document_id,action,actor_id,after_state)
        SELECT v_company,id,'CREATE',v_actor,to_jsonb(document) FROM public.cash_deposit_documents document WHERE id=v_id;
    ELSE
        UPDATE public.cash_deposit_documents SET store_id=p_store_id,
            destination_type=upper(btrim(p_destination_type)),destination_name_snapshot=btrim(p_destination_name),
            actual_deposit_amount=p_actual_deposit_amount,total_expected_deposit=v_total,
            deposit_variance=v_variance,variance_type=v_type,deposit_at=p_deposit_at,
            evidence_url=NULLIF(btrim(COALESCE(p_evidence_url,'')),''),notes=NULLIF(btrim(COALESCE(p_notes,'')),''),
            client_deposit_id=p_client_deposit_id,payload_hash=v_hash,
            master_version=master_version+1,updated_by=v_actor,updated_at=v_now
        WHERE company_id=v_company AND id=v_id RETURNING master_version INTO v_new_version;
        INSERT INTO public.cash_deposit_audit(company_id,deposit_document_id,action,actor_id,before_state,after_state)
        SELECT v_company,id,'UPDATE',v_actor,v_before,to_jsonb(document) FROM public.cash_deposit_documents document WHERE id=v_id;
    END IF;
    RETURN jsonb_build_object('depositDocumentId',v_id,'status','DRAFT','masterVersion',v_new_version,'totalExpectedDeposit',v_total,'actualDepositAmount',p_actual_deposit_amount,'depositVariance',v_variance,'varianceType',v_type);
END;
$$;

CREATE FUNCTION public.submit_cash_deposit(
    p_document_id UUID,p_master_version BIGINT,p_idempotency_key UUID
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
    v_company UUID:=public.private_active_company_id(); v_actor UUID:=auth.uid();
    v_document public.cash_deposit_documents%ROWTYPE; v_line RECORD;
    v_session public.cashier_sessions%ROWTYPE; v_posted NUMERIC(20,4);
    v_expected NUMERIC(20,4); v_total NUMERIC(20,4):=0;
    v_variance NUMERIC(20,4); v_type TEXT; v_proof TEXT; v_now TIMESTAMPTZ:=clock_timestamp();
    v_before JSONB; v_new_version BIGINT;
BEGIN
    IF v_company IS NULL OR v_actor IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF p_idempotency_key IS NULL THEN RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED'; END IF;
    SELECT * INTO v_document FROM public.cash_deposit_documents
    WHERE company_id=v_company AND id=p_document_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'CASH_DEPOSIT_NOT_FOUND'; END IF;
    IF v_document.status IN ('SUBMITTED','APPROVED') AND v_document.submit_idempotency_key=p_idempotency_key THEN
        RETURN jsonb_build_object('depositDocumentId',v_document.id,'status',v_document.status,'masterVersion',v_document.master_version,'idempotentReplay',TRUE);
    END IF;
    IF v_document.status<>'DRAFT' THEN RAISE EXCEPTION 'CASH_DEPOSIT_NOT_SUBMITTABLE'; END IF;
    IF p_master_version IS DISTINCT FROM v_document.master_version THEN RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
    IF NOT private.cash_deposit_actor_can_operate(v_company,v_document.store_id,v_document.created_by) THEN RAISE EXCEPTION 'CASH_DEPOSIT_ACCESS_DENIED'; END IF;
    v_proof:=private.cash_deposit_effective_proof_mode(v_company,v_document.store_id);
    IF v_proof='REQUIRED' AND v_document.evidence_url IS NULL THEN RAISE EXCEPTION 'DEPOSIT_EVIDENCE_REQUIRED'; END IF;
    IF NOT EXISTS(SELECT 1 FROM public.cash_deposit_session_lines WHERE company_id=v_company AND deposit_document_id=v_document.id) THEN RAISE EXCEPTION 'DEPOSIT_SESSION_REQUIRED'; END IF;
    v_before:=to_jsonb(v_document);
    FOR v_line IN SELECT * FROM public.cash_deposit_session_lines
        WHERE company_id=v_company AND deposit_document_id=v_document.id
        ORDER BY cashier_session_id FOR UPDATE LOOP
        SELECT * INTO v_session FROM public.cashier_sessions
        WHERE company_id=v_company AND id=v_line.cashier_session_id FOR UPDATE;
        IF NOT FOUND OR v_session.status IS DISTINCT FROM 'CLOSED'::public.session_status OR v_session.store_id<>v_document.store_id OR v_session.closing_cash_actual IS NULL THEN RAISE EXCEPTION 'CLOSED_CASHIER_SESSION_NOT_FOUND'; END IF;
        IF EXISTS(SELECT 1 FROM public.cash_deposit_session_lines other WHERE other.company_id=v_company AND other.cashier_session_id=v_session.id AND other.deposit_document_id<>v_document.id AND other.allocation_status IN ('LOCKED','POSTED')) THEN RAISE EXCEPTION 'CASHIER_SESSION_ALREADY_DEPOSITED_OR_LOCKED'; END IF;
        SELECT COALESCE(sum(other.expected_deposit_amount),0) INTO v_posted FROM public.cash_deposit_session_lines other WHERE other.company_id=v_company AND other.cashier_session_id=v_session.id AND other.deposit_document_id<>v_document.id AND other.allocation_status='POSTED';
        v_expected:=v_session.closing_cash_actual-v_line.next_session_float_reserved-v_posted;
        IF v_expected<=0 THEN RAISE EXCEPTION 'SESSION_HAS_NO_DEPOSITABLE_CASH'; END IF;
        UPDATE public.cash_deposit_session_lines SET closing_cash_actual_snapshot=v_session.closing_cash_actual,posted_deposit_allocations_snapshot=v_posted,expected_deposit_amount=v_expected,allocation_status='LOCKED',updated_at=v_now WHERE id=v_line.id;
        v_total:=v_total+v_expected;
    END LOOP;
    v_variance:=v_document.actual_deposit_amount-v_total;
    v_type:=CASE WHEN v_variance<0 THEN 'UNDER_DEPOSIT' WHEN v_variance>0 THEN 'OVER_DEPOSIT' ELSE 'MATCHED' END;
    UPDATE public.cash_deposit_documents SET total_expected_deposit=v_total,deposit_variance=v_variance,variance_type=v_type,status='SUBMITTED',proof_mode_snapshot=v_proof,submit_idempotency_key=p_idempotency_key,submitted_by=v_actor,submitted_at=v_now,master_version=master_version+1,updated_by=v_actor,updated_at=v_now WHERE id=v_document.id RETURNING master_version INTO v_new_version;
    INSERT INTO public.cash_deposit_audit(company_id,deposit_document_id,action,actor_id,before_state,after_state) SELECT v_company,id,'SUBMIT',v_actor,v_before,to_jsonb(document) FROM public.cash_deposit_documents document WHERE id=v_document.id;
    RETURN jsonb_build_object('depositDocumentId',v_document.id,'status','SUBMITTED','masterVersion',v_new_version,'totalExpectedDeposit',v_total,'depositVariance',v_variance,'varianceType',v_type);
END;
$$;

CREATE FUNCTION public.review_cash_deposit(
    p_document_id UUID,p_master_version BIGINT,p_action TEXT,
    p_reason TEXT,p_idempotency_key UUID
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
    v_company UUID:=public.private_active_company_id(); v_actor UUID:=auth.uid();
    v_document public.cash_deposit_documents%ROWTYPE; v_action TEXT:=upper(btrim(COALESCE(p_action,'')));
    v_now TIMESTAMPTZ:=clock_timestamp(); v_before JSONB; v_category UUID;
    v_drawer UUID; v_destination UUID; v_variance_account UUID; v_event UUID;
    v_new_version BIGINT; v_function TEXT;
BEGIN
    IF v_company IS NULL OR v_actor IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF v_action NOT IN ('APPROVE','REJECT') THEN RAISE EXCEPTION 'DEPOSIT_REVIEW_ACTION_INVALID'; END IF;
    IF p_idempotency_key IS NULL THEN RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED'; END IF;
    IF NOT public.private_user_has_any_company_role(v_company,ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE']::TEXT[]) THEN RAISE EXCEPTION 'CASH_DEPOSIT_REVIEW_ACCESS_DENIED'; END IF;
    SELECT * INTO v_document FROM public.cash_deposit_documents WHERE company_id=v_company AND id=p_document_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'CASH_DEPOSIT_NOT_FOUND'; END IF;
    IF v_document.status IN ('APPROVED','REJECTED') AND v_document.review_idempotency_key=p_idempotency_key THEN RETURN jsonb_build_object('depositDocumentId',v_document.id,'status',v_document.status,'masterVersion',v_document.master_version,'idempotentReplay',TRUE); END IF;
    IF v_document.status<>'SUBMITTED' THEN RAISE EXCEPTION 'CASH_DEPOSIT_NOT_REVIEWABLE'; END IF;
    IF p_master_version IS DISTINCT FROM v_document.master_version THEN RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
    IF v_action='REJECT' AND btrim(COALESCE(p_reason,''))='' THEN RAISE EXCEPTION 'DEPOSIT_REJECTION_REASON_REQUIRED'; END IF;
    v_before:=to_jsonb(v_document);
    IF v_action='REJECT' THEN
        UPDATE public.cash_deposit_session_lines SET allocation_status='RELEASED',updated_at=v_now WHERE company_id=v_company AND deposit_document_id=v_document.id AND allocation_status='LOCKED';
        UPDATE public.cash_deposit_documents SET status='REJECTED',review_idempotency_key=p_idempotency_key,rejected_by=v_actor,rejected_at=v_now,rejection_reason=btrim(p_reason),master_version=master_version+1,updated_by=v_actor,updated_at=v_now WHERE id=v_document.id RETURNING master_version INTO v_new_version;
        INSERT INTO public.cash_deposit_audit(company_id,deposit_document_id,action,actor_id,before_state,after_state) SELECT v_company,id,'REJECT',v_actor,v_before,to_jsonb(document) FROM public.cash_deposit_documents document WHERE id=v_document.id;
        RETURN jsonb_build_object('depositDocumentId',v_document.id,'status','REJECTED','masterVersion',v_new_version);
    END IF;
    SELECT category.id INTO v_category FROM public.transaction_categories category WHERE category.company_id=v_company AND category.system_key='CASH_DEPOSIT' AND category.is_active ORDER BY category.is_system_default DESC,category.id LIMIT 1;
    IF v_category IS NULL THEN RAISE EXCEPTION 'CASH_DEPOSIT_TRANSACTION_CATEGORY_NOT_FOUND'; END IF;
    v_drawer:=private.resolve_cash_deposit_account(v_company,v_category,'CASH_DRAWER',v_now);
    v_function:=CASE WHEN v_document.destination_type='BANK' THEN 'CASH_IN_TRANSIT' ELSE 'MAIN_CASH' END;
    v_destination:=private.resolve_cash_deposit_account(v_company,v_category,v_function,v_now);
    IF v_document.variance_type<>'MATCHED' THEN
        v_function:=CASE WHEN v_document.variance_type='UNDER_DEPOSIT' THEN 'UNDER_DEPOSIT_CONTROL' ELSE 'CASH_OVERAGE_LIABILITY' END;
        v_variance_account:=private.resolve_cash_deposit_account(v_company,v_category,v_function,v_now);
    END IF;
    INSERT INTO public.financial_events(event_code,event_type,source_table,source_id,root_sales_id,event_date,event_version,idempotency_key,payment_method,amounts,status,error_message,created_by,company_id,store_id,system_event_key,transaction_category_id)
    VALUES('CASH-DEP-'||replace(v_document.id::TEXT,'-',''),'BANK_DEPOSIT'::public.event_type,'cash_deposit_documents',v_document.id,NULL,v_now,1,'CASH_DEPOSIT|'||v_company::TEXT||'|'||p_idempotency_key::TEXT,v_document.destination_type,jsonb_build_object('cashDepositDocumentId',v_document.id,'depositNo',v_document.deposit_no,'expectedDeposit',v_document.total_expected_deposit,'actualDeposit',v_document.actual_deposit_amount,'depositVariance',v_document.deposit_variance,'varianceType',v_document.variance_type,'cashDrawerAccountId',v_drawer,'destinationAccountId',v_destination,'varianceAccountId',v_variance_account,'sessionIds',(SELECT jsonb_agg(line.cashier_session_id ORDER BY line.line_no) FROM public.cash_deposit_session_lines line WHERE line.deposit_document_id=v_document.id),'financePostingState','HOLD_UNTIL_G6'),'HOLD'::public.event_status,'CANONICAL_FINANCE_POSTING_NOT_ENABLED',v_actor,v_company,v_document.store_id,'CASH_DEPOSIT',v_category)
    RETURNING id INTO v_event;
    UPDATE public.cash_deposit_session_lines SET allocation_status='POSTED',updated_at=v_now WHERE company_id=v_company AND deposit_document_id=v_document.id AND allocation_status='LOCKED';
    UPDATE public.cash_deposit_documents SET status='APPROVED',review_idempotency_key=p_idempotency_key,transaction_category_id=v_category,cash_drawer_account_id=v_drawer,destination_account_id=v_destination,variance_account_id=v_variance_account,financial_event_id=v_event,approved_by=v_actor,approved_at=v_now,master_version=master_version+1,updated_by=v_actor,updated_at=v_now WHERE id=v_document.id RETURNING master_version INTO v_new_version;
    IF v_document.deposit_variance<>0 THEN
        INSERT INTO public.deposit_variance_exceptions(company_id,store_id,cash_deposit_document_id,variance_type,original_amount,remaining_amount,transaction_category_id,control_account_id,created_by,updated_by)
        VALUES(v_company,v_document.store_id,v_document.id,v_document.variance_type,abs(v_document.deposit_variance),abs(v_document.deposit_variance),v_category,v_variance_account,v_actor,v_actor);
    END IF;
    INSERT INTO public.cash_deposit_audit(company_id,deposit_document_id,action,actor_id,before_state,after_state) SELECT v_company,id,'APPROVE',v_actor,v_before,to_jsonb(document) FROM public.cash_deposit_documents document WHERE id=v_document.id;
    RETURN jsonb_build_object('depositDocumentId',v_document.id,'status','APPROVED','masterVersion',v_new_version,'financialEventId',v_event,'varianceExceptionOpened',v_document.deposit_variance<>0);
END;
$$;

CREATE FUNCTION public.cancel_cash_deposit(
    p_document_id UUID,p_master_version BIGINT,p_reason TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id(); v_actor UUID:=auth.uid(); v_document public.cash_deposit_documents%ROWTYPE; v_before JSONB; v_version BIGINT; v_now TIMESTAMPTZ:=clock_timestamp();
BEGIN
    IF v_company IS NULL OR v_actor IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    SELECT * INTO v_document FROM public.cash_deposit_documents WHERE company_id=v_company AND id=p_document_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'CASH_DEPOSIT_NOT_FOUND'; END IF;
    IF v_document.status NOT IN ('DRAFT','SUBMITTED') THEN RAISE EXCEPTION 'CASH_DEPOSIT_NOT_CANCELABLE'; END IF;
    IF p_master_version IS DISTINCT FROM v_document.master_version THEN RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
    IF NOT private.cash_deposit_actor_can_operate(v_company,v_document.store_id,v_document.created_by) THEN RAISE EXCEPTION 'CASH_DEPOSIT_ACCESS_DENIED'; END IF;
    v_before:=to_jsonb(v_document);
    UPDATE public.cash_deposit_session_lines SET allocation_status='RELEASED',updated_at=v_now WHERE company_id=v_company AND deposit_document_id=v_document.id AND allocation_status IN ('DRAFT','LOCKED');
    UPDATE public.cash_deposit_documents SET status='CANCELED',canceled_by=v_actor,canceled_at=v_now,cancel_reason=NULLIF(btrim(COALESCE(p_reason,'')),''),master_version=master_version+1,updated_by=v_actor,updated_at=v_now WHERE id=v_document.id RETURNING master_version INTO v_version;
    INSERT INTO public.cash_deposit_audit(company_id,deposit_document_id,action,actor_id,before_state,after_state) SELECT v_company,id,'CANCEL',v_actor,v_before,to_jsonb(document) FROM public.cash_deposit_documents document WHERE id=v_document.id;
    RETURN jsonb_build_object('depositDocumentId',v_document.id,'status','CANCELED','masterVersion',v_version);
END;
$$;

CREATE FUNCTION private.trg_g4_cash_deposit_history_guard()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path=public,pg_temp AS $$
BEGIN RAISE EXCEPTION 'CASH_DEPOSIT_HISTORY_IMMUTABLE'; END;
$$;
CREATE TRIGGER g4_cash_deposit_audit_immutable
BEFORE UPDATE OR DELETE ON public.cash_deposit_audit FOR EACH ROW
EXECUTE FUNCTION private.trg_g4_cash_deposit_history_guard();
CREATE TRIGGER g4_deposit_variance_allocation_immutable
BEFORE UPDATE OR DELETE ON public.deposit_variance_allocations FOR EACH ROW
EXECUTE FUNCTION private.trg_g4_cash_deposit_history_guard();

ALTER TABLE public.cash_deposit_policies ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cash_deposit_documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cash_deposit_session_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cash_deposit_audit ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.deposit_variance_exceptions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.deposit_variance_allocations ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Cash Deposit policies readable in active Company"
ON public.cash_deposit_policies FOR SELECT TO authenticated
USING(public.private_request_company_matches(company_id) AND public.private_user_has_company_access(company_id));
CREATE POLICY "Cash Deposit documents readable by operational scope"
ON public.cash_deposit_documents FOR SELECT TO authenticated
USING(public.private_request_company_matches(company_id) AND (created_by=auth.uid() OR public.private_user_has_store_access(store_id) OR public.private_user_has_any_company_role(company_id,ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE','ACCOUNTING']::TEXT[])));
CREATE POLICY "Cash Deposit lines readable with document"
ON public.cash_deposit_session_lines FOR SELECT TO authenticated
USING(public.private_request_company_matches(company_id) AND EXISTS(SELECT 1 FROM public.cash_deposit_documents document WHERE document.id=deposit_document_id AND (document.created_by=auth.uid() OR cashier_id=auth.uid() OR public.private_user_has_store_access(document.store_id) OR public.private_user_has_any_company_role(company_id,ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE','ACCOUNTING']::TEXT[]))));
CREATE POLICY "Cash Deposit audit readable with document"
ON public.cash_deposit_audit FOR SELECT TO authenticated
USING(public.private_request_company_matches(company_id) AND EXISTS(SELECT 1 FROM public.cash_deposit_documents document WHERE document.id=deposit_document_id AND (document.created_by=auth.uid() OR public.private_user_has_store_access(document.store_id) OR public.private_user_has_any_company_role(company_id,ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE','ACCOUNTING']::TEXT[]))));
CREATE POLICY "Deposit variance readable by Finance"
ON public.deposit_variance_exceptions FOR SELECT TO authenticated
USING(public.private_request_company_matches(company_id) AND public.private_user_has_any_company_role(company_id,ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE','ACCOUNTING']::TEXT[]));
CREATE POLICY "Deposit variance allocations readable by Finance"
ON public.deposit_variance_allocations FOR SELECT TO authenticated
USING(public.private_request_company_matches(company_id) AND public.private_user_has_any_company_role(company_id,ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE','ACCOUNTING']::TEXT[]));

REVOKE ALL ON public.cash_deposit_policies,public.cash_deposit_documents,
    public.cash_deposit_session_lines,public.cash_deposit_audit,
    public.deposit_variance_exceptions,public.deposit_variance_allocations
FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.cash_deposit_policies,public.cash_deposit_documents,
    public.cash_deposit_session_lines,public.cash_deposit_audit,
    public.deposit_variance_exceptions,public.deposit_variance_allocations
TO authenticated;
GRANT ALL ON public.cash_deposit_policies,public.cash_deposit_documents,
    public.cash_deposit_session_lines,public.cash_deposit_audit,
    public.deposit_variance_exceptions,public.deposit_variance_allocations
TO service_role;

REVOKE ALL ON FUNCTION private.trg_g4_provision_cash_deposit_policy(),
    private.resolve_cash_deposit_account(UUID,UUID,TEXT,TIMESTAMPTZ),
    private.cash_deposit_effective_proof_mode(UUID,UUID),
    private.cash_deposit_actor_can_operate(UUID,UUID,UUID),
    private.trg_g4_cash_deposit_history_guard()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.trg_g4_provision_cash_deposit_policy(),
    private.resolve_cash_deposit_account(UUID,UUID,TEXT,TIMESTAMPTZ),
    private.cash_deposit_effective_proof_mode(UUID,UUID),
    private.cash_deposit_actor_can_operate(UUID,UUID,UUID),
    private.trg_g4_cash_deposit_history_guard()
TO service_role;

REVOKE ALL ON FUNCTION public.list_cash_deposit_eligible_sessions(UUID),
    public.save_cash_deposit_draft(UUID,BIGINT,UUID,TEXT,TEXT,NUMERIC,TIMESTAMPTZ,TEXT,TEXT,UUID,JSONB),
    public.submit_cash_deposit(UUID,BIGINT,UUID),
    public.review_cash_deposit(UUID,BIGINT,TEXT,TEXT,UUID),
    public.cancel_cash_deposit(UUID,BIGINT,TEXT)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.list_cash_deposit_eligible_sessions(UUID),
    public.save_cash_deposit_draft(UUID,BIGINT,UUID,TEXT,TEXT,NUMERIC,TIMESTAMPTZ,TEXT,TEXT,UUID,JSONB),
    public.submit_cash_deposit(UUID,BIGINT,UUID),
    public.review_cash_deposit(UUID,BIGINT,TEXT,TEXT,UUID),
    public.cancel_cash_deposit(UUID,BIGINT,TEXT)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260804130000','g4_phase43_cash_deposit_foundation',
    'POS-008 guarded multi-Session Cash Deposit lifecycle, Session lock, approval snapshot, variance exception, audit, and Financial Event HOLD; UI, bank matching, variance resolution, and G6 journal remain closed');

COMMIT;
