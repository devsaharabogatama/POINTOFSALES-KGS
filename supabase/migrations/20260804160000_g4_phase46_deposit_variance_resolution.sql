-- KGS POS G4 phase 46: Deposit variance resolution foundation.
-- Requirement: POS-008
-- Dependency: G4 phase 43 Cash Deposit foundation.
--
-- Opens investigation, internal responsible-party assignment, partial
-- append-only resolution, maker-checker for loss/income/source correction,
-- audit, and Financial Event HOLD. Bank matching and G6 journal remain closed.

BEGIN;

DO $migration_guard$
BEGIN
    IF to_regclass('private.kgs_schema_migrations') IS NULL
       OR NOT EXISTS (
           SELECT 1 FROM private.kgs_schema_migrations
           WHERE version='20260804130000'
       ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: G4 phase 43 is incomplete';
    END IF;
    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version='20260804160000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260804160000';
    END IF;
    -- Approved preflight reported zero exception/allocation history. Stop if
    -- that changed because lifecycle backfill must be explicit.
    IF EXISTS (SELECT 1 FROM public.deposit_variance_exceptions)
       OR EXISTS (SELECT 1 FROM public.deposit_variance_allocations) THEN
        RAISE EXCEPTION
            'G4_PHASE46_STATE_CHANGED: variance history requires explicit backfill';
    END IF;
END
$migration_guard$;

ALTER TYPE public.event_type
    ADD VALUE IF NOT EXISTS 'DEPOSIT_VARIANCE_RESOLUTION';

ALTER TABLE public.deposit_variance_exceptions
    DROP CONSTRAINT deposit_variance_exception_status_check,
    ADD COLUMN master_version BIGINT NOT NULL DEFAULT 1,
    ADD COLUMN responsible_party_reason TEXT,
    ADD COLUMN responsible_party_assigned_by UUID
        REFERENCES public.profiles(id) ON DELETE RESTRICT,
    ADD COLUMN responsible_party_assigned_at TIMESTAMPTZ,
    ADD COLUMN resolved_by UUID
        REFERENCES public.profiles(id) ON DELETE RESTRICT,
    ADD COLUMN resolved_at TIMESTAMPTZ,
    ADD COLUMN written_off_by UUID
        REFERENCES public.profiles(id) ON DELETE RESTRICT,
    ADD COLUMN written_off_at TIMESTAMPTZ,
    ADD CONSTRAINT deposit_variance_exception_status_check CHECK(
        status IN (
            'OPEN','UNDER_INVESTIGATION','PARTIALLY_RESOLVED',
            'RESOLVED','WRITTEN_OFF','CANCELED'
        )
    ),
    ADD CONSTRAINT deposit_variance_exception_version_positive
        CHECK(master_version>0),
    ADD CONSTRAINT deposit_variance_exception_party_shape CHECK(
        (
            responsible_party_type IS NULL
            AND responsible_party_id IS NULL
            AND responsible_party_reason IS NULL
            AND responsible_party_assigned_by IS NULL
            AND responsible_party_assigned_at IS NULL
        ) OR (
            responsible_party_type='INTERNAL_USER'
            AND responsible_party_id IS NOT NULL
            AND NULLIF(btrim(responsible_party_reason),'') IS NOT NULL
            AND responsible_party_assigned_by IS NOT NULL
            AND responsible_party_assigned_at IS NOT NULL
        )
    ),
    ADD CONSTRAINT deposit_variance_exception_terminal_shape CHECK(
        (
            status NOT IN ('RESOLVED','WRITTEN_OFF')
            AND resolved_by IS NULL AND resolved_at IS NULL
            AND written_off_by IS NULL AND written_off_at IS NULL
        ) OR (
            status='RESOLVED' AND remaining_amount=0
            AND resolved_by IS NOT NULL AND resolved_at IS NOT NULL
            AND written_off_by IS NULL AND written_off_at IS NULL
        ) OR (
            status='WRITTEN_OFF' AND remaining_amount=0
            AND resolved_by IS NOT NULL AND resolved_at IS NOT NULL
            AND written_off_by IS NOT NULL AND written_off_at IS NOT NULL
        )
    );

ALTER TABLE public.deposit_variance_allocations
    DROP CONSTRAINT deposit_variance_allocation_resolution_check,
    ADD COLUMN status TEXT NOT NULL DEFAULT 'APPROVED',
    ADD COLUMN rejection_reason TEXT,
    ADD COLUMN resolution_reference TEXT,
    ADD COLUMN account_function_snapshot TEXT,
    ADD COLUMN submitted_by UUID
        REFERENCES public.profiles(id) ON DELETE RESTRICT,
    ADD COLUMN submitted_at TIMESTAMPTZ,
    ADD COLUMN reviewed_by UUID
        REFERENCES public.profiles(id) ON DELETE RESTRICT,
    ADD COLUMN reviewed_at TIMESTAMPTZ,
    ADD CONSTRAINT deposit_variance_allocation_company_id_id_unique
        UNIQUE(company_id,id),
    ADD CONSTRAINT deposit_variance_allocation_resolution_check CHECK(
        resolution_type IN (
            'CASHIER_RECEIVABLE','COMPANY_EXPENSE','OTHER_RECEIVABLE',
            'CASH_OVERAGE_INCOME','REFUND_TO_SOURCE','WRITE_OFF',
            'RECOVERED_FUNDS','SOURCE_CORRECTION'
        )
    ),
    ADD CONSTRAINT deposit_variance_allocation_status_check CHECK(
        status='APPROVED' AND rejection_reason IS NULL
    ),
    ADD CONSTRAINT deposit_variance_allocation_snapshot_shape CHECK(
        NULLIF(btrim(account_function_snapshot),'') IS NOT NULL
        AND submitted_by IS NOT NULL AND submitted_at IS NOT NULL
        AND reviewed_by IS NOT NULL AND reviewed_at IS NOT NULL
    );

CREATE SEQUENCE private.deposit_variance_resolution_no_seq
AS BIGINT START WITH 1;
REVOKE ALL ON SEQUENCE private.deposit_variance_resolution_no_seq
FROM PUBLIC,anon,authenticated;
GRANT USAGE,SELECT
ON SEQUENCE private.deposit_variance_resolution_no_seq TO service_role;

CREATE TABLE public.deposit_variance_resolution_requests (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL,
    store_id UUID NOT NULL,
    variance_exception_id UUID NOT NULL,
    request_no TEXT NOT NULL,
    allocation_amount NUMERIC(20,4) NOT NULL,
    resolution_type TEXT NOT NULL,
    settlement_account_function TEXT,
    reason TEXT NOT NULL,
    evidence_url TEXT,
    resolution_reference TEXT,
    status TEXT NOT NULL,
    requires_review BOOLEAN NOT NULL,
    idempotency_key UUID NOT NULL,
    review_idempotency_key UUID,
    payload_hash TEXT NOT NULL,
    allocation_id UUID,
    financial_event_id UUID REFERENCES public.financial_events(id)
        ON DELETE RESTRICT,
    created_by UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
    reviewed_by UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    reviewed_at TIMESTAMPTZ,
    rejection_reason TEXT,
    master_version BIGINT NOT NULL DEFAULT 1,
    CONSTRAINT deposit_variance_request_company_id_id_unique
        UNIQUE(company_id,id),
    CONSTRAINT deposit_variance_request_company_no_unique
        UNIQUE(company_id,request_no),
    CONSTRAINT deposit_variance_request_idempotency_unique
        UNIQUE(company_id,idempotency_key),
    CONSTRAINT deposit_variance_request_amount_positive
        CHECK(allocation_amount>0),
    CONSTRAINT deposit_variance_request_resolution_check CHECK(
        resolution_type IN (
            'CASHIER_RECEIVABLE','COMPANY_EXPENSE','OTHER_RECEIVABLE',
            'CASH_OVERAGE_INCOME','REFUND_TO_SOURCE','WRITE_OFF',
            'RECOVERED_FUNDS','SOURCE_CORRECTION'
        )
    ),
    CONSTRAINT deposit_variance_request_status_check
        CHECK(status IN ('SUBMITTED','APPROVED','REJECTED')),
    CONSTRAINT deposit_variance_request_evidence_https
        CHECK(evidence_url IS NULL OR evidence_url~*'^https://'),
    CONSTRAINT deposit_variance_request_identity_not_blank CHECK(
        btrim(request_no)<>'' AND btrim(reason)<>'' AND btrim(payload_hash)<>''
    ),
    CONSTRAINT deposit_variance_request_version_positive
        CHECK(master_version>0),
    CONSTRAINT deposit_variance_request_lifecycle_shape CHECK(
        (
            status='SUBMITTED'
            AND reviewed_by IS NULL AND reviewed_at IS NULL
            AND rejection_reason IS NULL
            AND allocation_id IS NULL AND financial_event_id IS NULL
        ) OR (
            status='APPROVED'
            AND reviewed_by IS NOT NULL AND reviewed_at IS NOT NULL
            AND rejection_reason IS NULL
            AND allocation_id IS NOT NULL AND financial_event_id IS NOT NULL
        ) OR (
            status='REJECTED' AND requires_review
            AND reviewed_by IS NOT NULL AND reviewed_at IS NOT NULL
            AND NULLIF(btrim(rejection_reason),'') IS NOT NULL
            AND allocation_id IS NULL AND financial_event_id IS NULL
        )
    ),
    CONSTRAINT fk_deposit_variance_request_exception
        FOREIGN KEY(company_id,variance_exception_id)
        REFERENCES public.deposit_variance_exceptions(company_id,id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_deposit_variance_request_store
        FOREIGN KEY(company_id,store_id)
        REFERENCES public.stores(company_id,id) ON DELETE RESTRICT
);

ALTER TABLE public.deposit_variance_allocations
    ADD COLUMN resolution_request_id UUID NOT NULL,
    ADD CONSTRAINT fk_deposit_variance_allocation_request
        FOREIGN KEY(company_id,resolution_request_id)
        REFERENCES public.deposit_variance_resolution_requests(company_id,id)
        ON DELETE RESTRICT;

ALTER TABLE public.deposit_variance_resolution_requests
    ADD CONSTRAINT fk_deposit_variance_request_allocation
        FOREIGN KEY(company_id,allocation_id)
        REFERENCES public.deposit_variance_allocations(company_id,id)
        ON DELETE RESTRICT;

CREATE UNIQUE INDEX uq_deposit_variance_request_allocation
    ON public.deposit_variance_resolution_requests(company_id,allocation_id)
    WHERE allocation_id IS NOT NULL;
CREATE INDEX idx_deposit_variance_request_review
    ON public.deposit_variance_resolution_requests(
        company_id,status,created_at DESC
    );
CREATE UNIQUE INDEX uq_deposit_variance_request_review_idempotency
    ON public.deposit_variance_resolution_requests(
        company_id,review_idempotency_key
    ) WHERE review_idempotency_key IS NOT NULL;

CREATE TABLE public.deposit_variance_resolution_audit (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_id UUID NOT NULL,
    variance_exception_id UUID NOT NULL,
    resolution_request_id UUID,
    action TEXT NOT NULL,
    actor_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
    before_state JSONB,
    after_state JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT deposit_variance_resolution_audit_action_check CHECK(
        action IN (
            'ASSIGN_RESPONSIBLE_PARTY','REQUEST','AUTO_APPROVE',
            'APPROVE','REJECT','APPLY'
        )
    ),
    CONSTRAINT fk_deposit_variance_audit_exception
        FOREIGN KEY(company_id,variance_exception_id)
        REFERENCES public.deposit_variance_exceptions(company_id,id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_deposit_variance_audit_request
        FOREIGN KEY(company_id,resolution_request_id)
        REFERENCES public.deposit_variance_resolution_requests(company_id,id)
        ON DELETE RESTRICT
);

CREATE INDEX idx_deposit_variance_resolution_audit_source
    ON public.deposit_variance_resolution_audit(
        company_id,variance_exception_id,created_at DESC
    );

CREATE FUNCTION private.apply_deposit_variance_resolution(
    p_request_id UUID,p_reviewer_id UUID
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
    v_request public.deposit_variance_resolution_requests%ROWTYPE;
    v_exception public.deposit_variance_exceptions%ROWTYPE;
    v_category UUID; v_account_function TEXT; v_account UUID;
    v_allocation UUID; v_event UUID; v_now TIMESTAMPTZ:=clock_timestamp();
    v_remaining NUMERIC(20,4); v_status TEXT; v_before JSONB;
BEGIN
    SELECT * INTO v_request
    FROM public.deposit_variance_resolution_requests request
    WHERE request.id=p_request_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'DEPOSIT_VARIANCE_REQUEST_NOT_FOUND'; END IF;
    SELECT * INTO v_exception
    FROM public.deposit_variance_exceptions exception
    WHERE exception.company_id=v_request.company_id
      AND exception.id=v_request.variance_exception_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'DEPOSIT_VARIANCE_EXCEPTION_NOT_FOUND'; END IF;
    IF v_exception.status IN ('RESOLVED','WRITTEN_OFF','CANCELED') THEN
        RAISE EXCEPTION 'DEPOSIT_VARIANCE_EXCEPTION_NOT_RESOLVABLE';
    END IF;
    IF v_request.allocation_amount>v_exception.remaining_amount THEN
        RAISE EXCEPTION 'DEPOSIT_VARIANCE_ALLOCATION_EXCEEDS_REMAINING';
    END IF;

    SELECT category.id INTO v_category
    FROM public.transaction_categories category
    WHERE category.company_id=v_request.company_id
      AND category.system_key='CASH_VARIANCE' AND category.is_active
    ORDER BY category.is_system_default DESC,category.id LIMIT 1;
    IF v_category IS NULL THEN
        RAISE EXCEPTION 'CASH_VARIANCE_TRANSACTION_CATEGORY_NOT_FOUND';
    END IF;

    v_account_function:=CASE v_request.resolution_type
        WHEN 'CASHIER_RECEIVABLE' THEN 'CASH_SHORTAGE_CONTROL'
        WHEN 'OTHER_RECEIVABLE' THEN 'CASH_SHORTAGE_CONTROL'
        WHEN 'COMPANY_EXPENSE' THEN 'EXPENSE'
        WHEN 'WRITE_OFF' THEN 'EXPENSE'
        WHEN 'CASH_OVERAGE_INCOME' THEN 'OTHER_INCOME'
        WHEN 'SOURCE_CORRECTION' THEN
            CASE v_exception.variance_type
                WHEN 'UNDER_DEPOSIT' THEN 'UNDER_DEPOSIT_CONTROL'
                ELSE 'CASH_OVERAGE_LIABILITY' END
        ELSE upper(btrim(COALESCE(
            v_request.settlement_account_function,''
        )))
    END;
    IF v_request.resolution_type IN ('RECOVERED_FUNDS','REFUND_TO_SOURCE')
       AND v_account_function NOT IN (
           'CASH_DRAWER','MAIN_CASH','BANK','CASH_IN_TRANSIT'
       ) THEN
        RAISE EXCEPTION 'DEPOSIT_VARIANCE_SETTLEMENT_ACCOUNT_INVALID';
    END IF;
    v_account:=private.resolve_cash_deposit_account(
        v_request.company_id,v_category,v_account_function,v_now
    );

    INSERT INTO public.financial_events(
        event_code,event_type,source_table,source_id,root_sales_id,event_date,
        event_version,idempotency_key,payment_method,amounts,status,error_message,
        created_by,company_id,store_id,system_event_key,transaction_category_id
    ) VALUES(
        'DEP-VAR-'||replace(v_request.id::TEXT,'-',''),
        'DEPOSIT_VARIANCE_RESOLUTION'::public.event_type,
        'deposit_variance_resolution_requests',v_request.id,NULL,v_now,1,
        'DEPOSIT_VARIANCE|'||v_request.company_id::TEXT||'|'||
            v_request.idempotency_key::TEXT,
        v_account_function,
        jsonb_build_object(
            'varianceExceptionId',v_exception.id,
            'cashDepositDocumentId',v_exception.cash_deposit_document_id,
            'resolutionRequestId',v_request.id,
            'resolutionType',v_request.resolution_type,
            'allocationAmount',v_request.allocation_amount,
            'varianceType',v_exception.variance_type,
            'controlAccountId',v_exception.control_account_id,
            'resolutionAccountId',v_account,
            'responsiblePartyId',v_exception.responsible_party_id,
            'resolutionReference',v_request.resolution_reference,
            'financePostingState','HOLD_UNTIL_G6'
        ),
        'HOLD'::public.event_status,'CANONICAL_FINANCE_POSTING_NOT_ENABLED',
        p_reviewer_id,v_request.company_id,v_request.store_id,
        'CASH_VARIANCE',v_category
    ) RETURNING id INTO v_event;

    INSERT INTO public.deposit_variance_allocations(
        company_id,variance_exception_id,allocation_amount,resolution_type,
        reason,evidence_url,account_id,transaction_category_id,
        financial_event_id,idempotency_key,created_by,resolution_reference,
        account_function_snapshot,submitted_by,submitted_at,reviewed_by,
        reviewed_at,resolution_request_id
    ) VALUES(
        v_request.company_id,v_exception.id,v_request.allocation_amount,
        v_request.resolution_type,v_request.reason,v_request.evidence_url,
        v_account,v_category,v_event,v_request.idempotency_key,
        v_request.created_by,v_request.resolution_reference,v_account_function,
        v_request.created_by,v_request.created_at,p_reviewer_id,v_now,v_request.id
    ) RETURNING id INTO v_allocation;

    v_before:=to_jsonb(v_exception);
    v_remaining:=v_exception.remaining_amount-v_request.allocation_amount;
    v_status:=CASE
        WHEN v_remaining>0 THEN 'PARTIALLY_RESOLVED'
        WHEN v_request.resolution_type IN ('WRITE_OFF','COMPANY_EXPENSE')
            THEN 'WRITTEN_OFF'
        ELSE 'RESOLVED' END;
    UPDATE public.deposit_variance_exceptions SET
        resolved_amount=resolved_amount+v_request.allocation_amount,
        remaining_amount=v_remaining,status=v_status,
        resolved_by=CASE WHEN v_remaining=0 THEN p_reviewer_id ELSE NULL END,
        resolved_at=CASE WHEN v_remaining=0 THEN v_now ELSE NULL END,
        written_off_by=CASE WHEN v_status='WRITTEN_OFF' THEN p_reviewer_id ELSE NULL END,
        written_off_at=CASE WHEN v_status='WRITTEN_OFF' THEN v_now ELSE NULL END,
        master_version=master_version+1,updated_by=p_reviewer_id,updated_at=v_now
    WHERE id=v_exception.id;

    UPDATE public.deposit_variance_resolution_requests SET
        status='APPROVED',allocation_id=v_allocation,financial_event_id=v_event,
        reviewed_by=p_reviewer_id,reviewed_at=v_now,
        master_version=master_version+1
    WHERE id=v_request.id;
    INSERT INTO public.deposit_variance_resolution_audit(
        company_id,variance_exception_id,resolution_request_id,action,
        actor_id,before_state,after_state
    ) SELECT v_request.company_id,v_exception.id,v_request.id,'APPLY',
        p_reviewer_id,v_before,to_jsonb(exception)
      FROM public.deposit_variance_exceptions exception
      WHERE exception.id=v_exception.id;
    RETURN jsonb_build_object(
        'resolutionRequestId',v_request.id,'allocationId',v_allocation,
        'financialEventId',v_event,'status','APPROVED',
        'exceptionStatus',v_status,'remainingAmount',v_remaining
    );
END;
$$;

CREATE FUNCTION public.assign_deposit_variance_responsible_party(
    p_exception_id UUID,p_master_version BIGINT,
    p_responsible_user_id UUID,p_reason TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
    v_company UUID:=public.private_active_company_id(); v_actor UUID:=auth.uid();
    v_exception public.deposit_variance_exceptions%ROWTYPE;
    v_now TIMESTAMPTZ:=clock_timestamp(); v_before JSONB; v_version BIGINT;
BEGIN
    IF v_company IS NULL OR v_actor IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF NOT public.private_user_has_any_company_role(
        v_company,ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE']::TEXT[]
    ) THEN RAISE EXCEPTION 'DEPOSIT_VARIANCE_FINANCE_ACCESS_DENIED'; END IF;
    IF btrim(COALESCE(p_reason,''))='' THEN
        RAISE EXCEPTION 'RESPONSIBLE_PARTY_REASON_REQUIRED';
    END IF;
    SELECT * INTO v_exception FROM public.deposit_variance_exceptions
    WHERE company_id=v_company AND id=p_exception_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'DEPOSIT_VARIANCE_EXCEPTION_NOT_FOUND'; END IF;
    IF v_exception.variance_type<>'UNDER_DEPOSIT' THEN
        RAISE EXCEPTION 'RESPONSIBLE_PARTY_ONLY_FOR_UNDER_DEPOSIT';
    END IF;
    IF v_exception.status IN ('RESOLVED','WRITTEN_OFF','CANCELED') THEN
        RAISE EXCEPTION 'DEPOSIT_VARIANCE_EXCEPTION_NOT_INVESTIGABLE';
    END IF;
    IF p_master_version IS DISTINCT FROM v_exception.master_version THEN
        RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
    END IF;
    IF NOT EXISTS(
        SELECT 1 FROM public.company_memberships membership
        WHERE membership.company_id=v_company
          AND membership.user_id=p_responsible_user_id
          AND membership.status='ACTIVE'
    ) THEN RAISE EXCEPTION 'ACTIVE_RESPONSIBLE_USER_NOT_FOUND'; END IF;
    v_before:=to_jsonb(v_exception);
    UPDATE public.deposit_variance_exceptions SET
        status=CASE WHEN resolved_amount>0
            THEN 'PARTIALLY_RESOLVED' ELSE 'UNDER_INVESTIGATION' END,
        responsible_party_type='INTERNAL_USER',
        responsible_party_id=p_responsible_user_id,
        responsible_party_reason=btrim(p_reason),
        responsible_party_assigned_by=v_actor,
        responsible_party_assigned_at=v_now,
        master_version=master_version+1,updated_by=v_actor,updated_at=v_now
    WHERE id=v_exception.id RETURNING master_version INTO v_version;
    INSERT INTO public.deposit_variance_resolution_audit(
        company_id,variance_exception_id,action,actor_id,before_state,after_state
    ) SELECT v_company,id,'ASSIGN_RESPONSIBLE_PARTY',v_actor,v_before,
        to_jsonb(exception) FROM public.deposit_variance_exceptions exception
      WHERE id=v_exception.id;
    RETURN jsonb_build_object(
        'varianceExceptionId',v_exception.id,
        'status',CASE WHEN v_exception.resolved_amount>0
            THEN 'PARTIALLY_RESOLVED' ELSE 'UNDER_INVESTIGATION' END,
        'masterVersion',v_version
    );
END;
$$;

CREATE FUNCTION public.resolve_deposit_variance(
    p_exception_id UUID,p_master_version BIGINT,p_allocation_amount NUMERIC,
    p_resolution_type TEXT,p_settlement_account_function TEXT,p_reason TEXT,
    p_evidence_url TEXT,p_resolution_reference TEXT,p_idempotency_key UUID
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
    v_company UUID:=public.private_active_company_id(); v_actor UUID:=auth.uid();
    v_exception public.deposit_variance_exceptions%ROWTYPE;
    v_existing public.deposit_variance_resolution_requests%ROWTYPE;
    v_type TEXT:=upper(btrim(COALESCE(p_resolution_type,'')));
    v_function TEXT:=NULLIF(upper(btrim(COALESCE(p_settlement_account_function,''))), '');
    v_evidence TEXT:=NULLIF(btrim(COALESCE(p_evidence_url,'')),'');
    v_reference TEXT:=NULLIF(btrim(COALESCE(p_resolution_reference,'')),'');
    v_hash TEXT; v_request UUID:=gen_random_uuid(); v_review BOOLEAN;
    v_now TIMESTAMPTZ:=clock_timestamp(); v_result JSONB;
BEGIN
    IF v_company IS NULL OR v_actor IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF NOT public.private_user_has_any_company_role(
        v_company,ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE']::TEXT[]
    ) THEN RAISE EXCEPTION 'DEPOSIT_VARIANCE_FINANCE_ACCESS_DENIED'; END IF;
    IF COALESCE(p_allocation_amount,0)<=0 THEN RAISE EXCEPTION 'RESOLUTION_AMOUNT_MUST_BE_POSITIVE'; END IF;
    IF btrim(COALESCE(p_reason,''))='' THEN RAISE EXCEPTION 'RESOLUTION_REASON_REQUIRED'; END IF;
    IF v_evidence IS NOT NULL AND v_evidence!~*'^https://' THEN RAISE EXCEPTION 'RESOLUTION_EVIDENCE_MUST_USE_HTTPS'; END IF;
    IF p_idempotency_key IS NULL THEN RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED'; END IF;
    IF v_type NOT IN (
        'CASHIER_RECEIVABLE','COMPANY_EXPENSE','OTHER_RECEIVABLE',
        'CASH_OVERAGE_INCOME','REFUND_TO_SOURCE','WRITE_OFF',
        'RECOVERED_FUNDS','SOURCE_CORRECTION'
    ) THEN RAISE EXCEPTION 'DEPOSIT_VARIANCE_RESOLUTION_TYPE_INVALID'; END IF;
    IF v_type='OTHER_RECEIVABLE' THEN
        RAISE EXCEPTION 'OTHER_RESPONSIBLE_PARTY_NOT_SUPPORTED';
    END IF;

    v_review:=v_type IN (
        'COMPANY_EXPENSE','WRITE_OFF','CASH_OVERAGE_INCOME','SOURCE_CORRECTION'
    );
    v_hash:=md5(jsonb_build_object(
        'exceptionId',p_exception_id,'amount',p_allocation_amount,
        'resolutionType',v_type,'accountFunction',v_function,
        'reason',btrim(p_reason),'evidenceUrl',v_evidence,
        'resolutionReference',v_reference
    )::TEXT);
    SELECT * INTO v_existing
    FROM public.deposit_variance_resolution_requests request
    WHERE request.company_id=v_company
      AND request.idempotency_key=p_idempotency_key;
    IF FOUND THEN
        IF v_existing.payload_hash<>v_hash THEN
            RAISE EXCEPTION 'DEPOSIT_VARIANCE_IDEMPOTENCY_CONFLICT';
        END IF;
        RETURN jsonb_build_object(
            'resolutionRequestId',v_existing.id,'requestNo',v_existing.request_no,
            'status',v_existing.status,'masterVersion',v_existing.master_version,
            'idempotentReplay',TRUE
        );
    END IF;

    SELECT * INTO v_exception FROM public.deposit_variance_exceptions
    WHERE company_id=v_company AND id=p_exception_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'DEPOSIT_VARIANCE_EXCEPTION_NOT_FOUND'; END IF;
    IF p_master_version IS DISTINCT FROM v_exception.master_version THEN RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
    IF v_exception.status IN ('RESOLVED','WRITTEN_OFF','CANCELED') THEN RAISE EXCEPTION 'DEPOSIT_VARIANCE_EXCEPTION_NOT_RESOLVABLE'; END IF;
    IF p_allocation_amount>v_exception.remaining_amount THEN RAISE EXCEPTION 'DEPOSIT_VARIANCE_ALLOCATION_EXCEEDS_REMAINING'; END IF;
    IF v_exception.variance_type='UNDER_DEPOSIT'
       AND v_type NOT IN (
           'CASHIER_RECEIVABLE','OTHER_RECEIVABLE','RECOVERED_FUNDS',
           'COMPANY_EXPENSE','WRITE_OFF','SOURCE_CORRECTION'
       ) THEN RAISE EXCEPTION 'UNDER_DEPOSIT_RESOLUTION_TYPE_INVALID'; END IF;
    IF v_exception.variance_type='OVER_DEPOSIT'
       AND v_type NOT IN (
           'REFUND_TO_SOURCE','CASH_OVERAGE_INCOME','SOURCE_CORRECTION'
       ) THEN RAISE EXCEPTION 'OVER_DEPOSIT_RESOLUTION_TYPE_INVALID'; END IF;
    IF v_type='CASHIER_RECEIVABLE'
       AND v_exception.responsible_party_id IS NULL THEN
        RAISE EXCEPTION 'RESPONSIBLE_PARTY_REQUIRED';
    END IF;
    IF v_type IN ('RECOVERED_FUNDS','REFUND_TO_SOURCE')
       AND v_function NOT IN (
           'CASH_DRAWER','MAIN_CASH','BANK','CASH_IN_TRANSIT'
       ) THEN RAISE EXCEPTION 'DEPOSIT_VARIANCE_SETTLEMENT_ACCOUNT_INVALID'; END IF;
    IF v_type IN ('SOURCE_CORRECTION','REFUND_TO_SOURCE')
       AND v_reference IS NULL THEN RAISE EXCEPTION 'RESOLUTION_REFERENCE_REQUIRED'; END IF;

    INSERT INTO public.deposit_variance_resolution_requests(
        id,company_id,store_id,variance_exception_id,request_no,
        allocation_amount,resolution_type,settlement_account_function,
        reason,evidence_url,resolution_reference,status,requires_review,
        idempotency_key,payload_hash,created_by,reviewed_by,reviewed_at
    ) VALUES(
        v_request,v_company,v_exception.store_id,v_exception.id,
        'DVR-'||to_char(v_now,'YYYYMMDD')||'-'||lpad(
            nextval('private.deposit_variance_resolution_no_seq')::TEXT,6,'0'
        ),p_allocation_amount,v_type,v_function,btrim(p_reason),v_evidence,
        v_reference,'SUBMITTED',
        v_review,p_idempotency_key,v_hash,v_actor,NULL,NULL
    );
    INSERT INTO public.deposit_variance_resolution_audit(
        company_id,variance_exception_id,resolution_request_id,action,
        actor_id,after_state
    ) SELECT v_company,v_exception.id,id,'REQUEST',v_actor,to_jsonb(request)
      FROM public.deposit_variance_resolution_requests request
      WHERE id=v_request;
    IF v_review THEN
        RETURN jsonb_build_object(
            'resolutionRequestId',v_request,'status','SUBMITTED',
            'masterVersion',1,'requiresReview',TRUE
        );
    END IF;
    v_result:=private.apply_deposit_variance_resolution(v_request,v_actor);
    INSERT INTO public.deposit_variance_resolution_audit(
        company_id,variance_exception_id,resolution_request_id,action,
        actor_id,after_state
    ) VALUES(v_company,v_exception.id,v_request,'AUTO_APPROVE',v_actor,v_result);
    RETURN v_result||jsonb_build_object('requiresReview',FALSE);
END;
$$;

CREATE FUNCTION public.review_deposit_variance_resolution(
    p_request_id UUID,p_master_version BIGINT,p_action TEXT,
    p_reason TEXT,p_idempotency_key UUID
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
    v_company UUID:=public.private_active_company_id(); v_actor UUID:=auth.uid();
    v_request public.deposit_variance_resolution_requests%ROWTYPE;
    v_action TEXT:=upper(btrim(COALESCE(p_action,'')));
    v_now TIMESTAMPTZ:=clock_timestamp(); v_before JSONB; v_result JSONB;
BEGIN
    IF v_company IS NULL OR v_actor IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF NOT public.private_user_has_any_company_role(
        v_company,ARRAY['COMPANY_OWNER','COMPANY_ADMIN']::TEXT[]
    ) THEN RAISE EXCEPTION 'DEPOSIT_VARIANCE_REVIEW_ACCESS_DENIED'; END IF;
    IF v_action NOT IN ('APPROVE','REJECT') THEN RAISE EXCEPTION 'RESOLUTION_REVIEW_ACTION_INVALID'; END IF;
    IF p_idempotency_key IS NULL THEN RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED'; END IF;
    SELECT * INTO v_request
    FROM public.deposit_variance_resolution_requests request
    WHERE request.company_id=v_company AND request.id=p_request_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'DEPOSIT_VARIANCE_REQUEST_NOT_FOUND'; END IF;
    IF v_request.status IN ('APPROVED','REJECTED') THEN
        IF v_request.review_idempotency_key=p_idempotency_key
           AND (
               (v_action='APPROVE' AND v_request.status='APPROVED')
               OR (
                   v_action='REJECT' AND v_request.status='REJECTED'
                   AND v_request.rejection_reason=btrim(COALESCE(p_reason,''))
               )
           ) THEN
            RETURN jsonb_build_object(
                'resolutionRequestId',v_request.id,'status',v_request.status,
                'masterVersion',v_request.master_version,'idempotentReplay',TRUE
            );
        END IF;
        RAISE EXCEPTION 'DEPOSIT_VARIANCE_REVIEW_IDEMPOTENCY_CONFLICT';
    END IF;
    IF v_request.status<>'SUBMITTED' OR NOT v_request.requires_review THEN RAISE EXCEPTION 'DEPOSIT_VARIANCE_REQUEST_NOT_REVIEWABLE'; END IF;
    IF p_master_version IS DISTINCT FROM v_request.master_version THEN RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
    IF v_request.created_by=v_actor THEN RAISE EXCEPTION 'MAKER_CANNOT_APPROVE_OWN_RESOLUTION'; END IF;
    IF v_action='REJECT' AND btrim(COALESCE(p_reason,''))='' THEN RAISE EXCEPTION 'RESOLUTION_REJECTION_REASON_REQUIRED'; END IF;
    v_before:=to_jsonb(v_request);
    IF v_action='REJECT' THEN
        UPDATE public.deposit_variance_resolution_requests SET
            status='REJECTED',reviewed_by=v_actor,reviewed_at=v_now,
            rejection_reason=btrim(p_reason),master_version=master_version+1
            ,review_idempotency_key=p_idempotency_key
        WHERE id=v_request.id;
        INSERT INTO public.deposit_variance_resolution_audit(
            company_id,variance_exception_id,resolution_request_id,action,
            actor_id,before_state,after_state
        ) SELECT v_company,v_request.variance_exception_id,id,'REJECT',v_actor,
            v_before,to_jsonb(request)
          FROM public.deposit_variance_resolution_requests request
          WHERE id=v_request.id;
        RETURN jsonb_build_object(
            'resolutionRequestId',v_request.id,'status','REJECTED',
            'masterVersion',v_request.master_version+1
        );
    END IF;
    UPDATE public.deposit_variance_resolution_requests
    SET review_idempotency_key=p_idempotency_key
    WHERE id=v_request.id;
    v_result:=private.apply_deposit_variance_resolution(v_request.id,v_actor);
    INSERT INTO public.deposit_variance_resolution_audit(
        company_id,variance_exception_id,resolution_request_id,action,
        actor_id,before_state,after_state
    ) VALUES(v_company,v_request.variance_exception_id,v_request.id,'APPROVE',
        v_actor,v_before,v_result);
    RETURN v_result;
END;
$$;

CREATE FUNCTION private.trg_g4_variance_resolution_history_guard()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path=public,pg_temp AS $$
BEGIN RAISE EXCEPTION 'DEPOSIT_VARIANCE_RESOLUTION_HISTORY_IMMUTABLE'; END;
$$;
CREATE TRIGGER g4_deposit_variance_resolution_audit_immutable
BEFORE UPDATE OR DELETE ON public.deposit_variance_resolution_audit
FOR EACH ROW EXECUTE FUNCTION private.trg_g4_variance_resolution_history_guard();

ALTER TABLE public.deposit_variance_resolution_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.deposit_variance_resolution_audit ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Variance resolution requests readable by Finance"
ON public.deposit_variance_resolution_requests FOR SELECT TO authenticated
USING(
    public.private_request_company_matches(company_id)
    AND public.private_user_has_any_company_role(
        company_id,
        ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE','ACCOUNTING']::TEXT[]
    )
);
CREATE POLICY "Variance resolution audit readable by Finance"
ON public.deposit_variance_resolution_audit FOR SELECT TO authenticated
USING(
    public.private_request_company_matches(company_id)
    AND public.private_user_has_any_company_role(
        company_id,
        ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE','ACCOUNTING']::TEXT[]
    )
);

REVOKE ALL ON public.deposit_variance_resolution_requests,
    public.deposit_variance_resolution_audit
FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.deposit_variance_resolution_requests,
    public.deposit_variance_resolution_audit TO authenticated;
GRANT ALL ON public.deposit_variance_resolution_requests,
    public.deposit_variance_resolution_audit TO service_role;

REVOKE ALL ON FUNCTION private.apply_deposit_variance_resolution(UUID,UUID),
    private.trg_g4_variance_resolution_history_guard(),
    public.assign_deposit_variance_responsible_party(UUID,BIGINT,UUID,TEXT),
    public.resolve_deposit_variance(UUID,BIGINT,NUMERIC,TEXT,TEXT,TEXT,TEXT,TEXT,UUID),
    public.review_deposit_variance_resolution(UUID,BIGINT,TEXT,TEXT,UUID)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
    public.assign_deposit_variance_responsible_party(UUID,BIGINT,UUID,TEXT),
    public.resolve_deposit_variance(UUID,BIGINT,NUMERIC,TEXT,TEXT,TEXT,TEXT,TEXT,UUID),
    public.review_deposit_variance_resolution(UUID,BIGINT,TEXT,TEXT,UUID)
TO authenticated;
GRANT EXECUTE ON FUNCTION private.apply_deposit_variance_resolution(UUID,UUID),
    private.trg_g4_variance_resolution_history_guard(),
    public.assign_deposit_variance_responsible_party(UUID,BIGINT,UUID,TEXT),
    public.resolve_deposit_variance(UUID,BIGINT,NUMERIC,TEXT,TEXT,TEXT,TEXT,TEXT,UUID),
    public.review_deposit_variance_resolution(UUID,BIGINT,TEXT,TEXT,UUID)
TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES(
    '20260804160000','g4_phase46_deposit_variance_resolution',
    'POS-008 append-only variance investigation, partial resolution, maker-checker, audit, and Finance HOLD'
);

COMMIT;
