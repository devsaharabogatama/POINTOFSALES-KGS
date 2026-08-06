-- KGS POS G4 phase 49: Customer Balance ledger and correction foundation.
-- Requirement: POS-006
-- Dependency: G4 phase 46 Deposit variance resolution.
--
-- Opens append-only Customer Balance history, Company lifecycle policy,
-- guarded correction request/review, and read-only statement. Sale checkout,
-- refund-to-balance, exceptional settlement, offline use, and G6 journal stay
-- closed.

BEGIN;

DO $migration_guard$
BEGIN
    IF to_regclass('private.kgs_schema_migrations') IS NULL
       OR NOT EXISTS (
           SELECT 1 FROM private.kgs_schema_migrations
           WHERE version='20260804160000'
       ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: G4 phase 46 is incomplete';
    END IF;
    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version='20260805090000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260805090000';
    END IF;
    IF to_regclass('public.customer_balance_company_policies') IS NOT NULL
       OR to_regclass('public.customer_balance_ledger_entries') IS NOT NULL
       OR to_regclass('public.customer_balance_correction_requests') IS NOT NULL
       OR to_regclass('public.customer_balance_audit') IS NOT NULL THEN
        RAISE EXCEPTION 'G4_PHASE49_CANONICAL_OBJECT_ALREADY_EXISTS';
    END IF;
    -- Approved preflight reported no historical balance/payment provenance.
    IF EXISTS (SELECT 1 FROM public.customers WHERE current_balance<>0)
       OR EXISTS (
           SELECT 1 FROM public.sales_payments
           WHERE payment_method::TEXT='Customer_Balance'
              OR payment_method_type_snapshot='CUSTOMER_BALANCE'
       ) THEN
        RAISE EXCEPTION
            'G4_PHASE49_STATE_CHANGED: Customer Balance history requires explicit backfill';
    END IF;
    IF EXISTS (
        SELECT 1 FROM public.payment_methods
        WHERE method_type='CUSTOMER_BALANCE'
          AND (NOT is_system_method
               OR settlement_route<>'INTERNAL_LIABILITY'
               OR fee_enabled
               OR clearing_account_function IS NOT NULL
               OR bank_account_function IS NOT NULL)
    ) THEN
        RAISE EXCEPTION
            'G4_PHASE49_INVALID_CUSTOMER_BALANCE_PAYMENT_METHOD';
    END IF;
    IF EXISTS (
        SELECT 1 FROM public.payment_methods
        WHERE method_type='CUSTOMER_BALANCE'
        GROUP BY company_id HAVING count(*)>1
    ) THEN
        RAISE EXCEPTION
            'G4_PHASE49_MULTIPLE_CUSTOMER_BALANCE_PAYMENT_METHODS';
    END IF;
    IF EXISTS (
        SELECT 1 FROM public.payment_methods
        WHERE method_type<>'CUSTOMER_BALANCE'
          AND lower(regexp_replace(btrim(payment_method_name),'\s+',' ','g'))
              ='saldo customer'
    ) THEN
        RAISE EXCEPTION
            'G4_PHASE49_CUSTOMER_BALANCE_PAYMENT_METHOD_NAME_COLLISION';
    END IF;
END
$migration_guard$;

ALTER TYPE public.event_type
    ADD VALUE IF NOT EXISTS 'CUSTOMER_BALANCE_ADJUSTMENT';

CREATE SEQUENCE private.customer_balance_request_no_seq
AS BIGINT START WITH 1;
REVOKE ALL ON SEQUENCE private.customer_balance_request_no_seq
FROM PUBLIC,anon,authenticated;
GRANT USAGE,SELECT ON SEQUENCE private.customer_balance_request_no_seq
TO service_role;

CREATE TABLE public.customer_balance_company_policies (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL UNIQUE
        REFERENCES public.companies(id) ON DELETE RESTRICT,
    lifecycle_state TEXT NOT NULL DEFAULT 'DISABLED',
    master_version BIGINT NOT NULL DEFAULT 1,
    created_by UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
    updated_by UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT customer_balance_policy_state_check
        CHECK(lifecycle_state IN ('ACTIVE','WIND_DOWN','DISABLED')),
    CONSTRAINT customer_balance_policy_version_positive
        CHECK(master_version>0)
);

CREATE TABLE public.customer_balance_correction_requests (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL,
    customer_id UUID NOT NULL,
    store_id UUID NOT NULL,
    request_no TEXT NOT NULL,
    direction TEXT NOT NULL,
    amount NUMERIC(20,4) NOT NULL,
    source_account_function TEXT NOT NULL
        REFERENCES public.account_functions(function_key) ON DELETE RESTRICT,
    reason TEXT NOT NULL,
    evidence_url TEXT,
    status TEXT NOT NULL DEFAULT 'SUBMITTED',
    idempotency_key UUID NOT NULL,
    review_idempotency_key UUID,
    payload_hash TEXT NOT NULL,
    ledger_entry_id UUID,
    financial_event_id UUID REFERENCES public.financial_events(id)
        ON DELETE RESTRICT,
    created_by UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
    reviewed_by UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    reviewed_at TIMESTAMPTZ,
    rejection_reason TEXT,
    master_version BIGINT NOT NULL DEFAULT 1,
    CONSTRAINT customer_balance_request_company_id_id_unique
        UNIQUE(company_id,id),
    CONSTRAINT customer_balance_request_company_no_unique
        UNIQUE(company_id,request_no),
    CONSTRAINT customer_balance_request_idempotency_unique
        UNIQUE(company_id,idempotency_key),
    CONSTRAINT customer_balance_request_review_idempotency_unique
        UNIQUE(company_id,review_idempotency_key),
    CONSTRAINT customer_balance_request_direction_check
        CHECK(direction IN ('CREDIT','DEBIT')),
    CONSTRAINT customer_balance_request_amount_positive CHECK(amount>0),
    CONSTRAINT customer_balance_request_status_check
        CHECK(status IN ('SUBMITTED','APPROVED','REJECTED')),
    CONSTRAINT customer_balance_request_identity_not_blank CHECK(
        btrim(request_no)<>'' AND btrim(reason)<>''
        AND btrim(source_account_function)<>'' AND btrim(payload_hash)<>''
    ),
    CONSTRAINT customer_balance_request_evidence_https
        CHECK(evidence_url IS NULL OR evidence_url~*'^https://'),
    CONSTRAINT customer_balance_request_version_positive
        CHECK(master_version>0),
    CONSTRAINT customer_balance_request_lifecycle_shape CHECK(
        (status='SUBMITTED' AND reviewed_by IS NULL AND reviewed_at IS NULL
         AND rejection_reason IS NULL AND ledger_entry_id IS NULL
         AND financial_event_id IS NULL)
        OR
        (status='APPROVED' AND reviewed_by IS NOT NULL
         AND reviewed_at IS NOT NULL AND rejection_reason IS NULL
         AND ledger_entry_id IS NOT NULL AND financial_event_id IS NOT NULL)
        OR
        (status='REJECTED' AND reviewed_by IS NOT NULL
         AND reviewed_at IS NOT NULL
         AND NULLIF(btrim(rejection_reason),'') IS NOT NULL
         AND ledger_entry_id IS NULL AND financial_event_id IS NULL)
    ),
    CONSTRAINT fk_customer_balance_request_customer
        FOREIGN KEY(company_id,customer_id)
        REFERENCES public.customers(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_customer_balance_request_store
        FOREIGN KEY(company_id,store_id)
        REFERENCES public.stores(company_id,id) ON DELETE RESTRICT
);

CREATE TABLE public.customer_balance_ledger_entries (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL,
    customer_id UUID NOT NULL,
    store_id UUID,
    entry_no BIGINT NOT NULL,
    direction TEXT NOT NULL,
    amount NUMERIC(20,4) NOT NULL,
    source_type TEXT NOT NULL,
    source_id UUID NOT NULL,
    source_reference TEXT NOT NULL,
    reason TEXT NOT NULL,
    evidence_url TEXT,
    balance_before NUMERIC(20,4) NOT NULL,
    balance_after NUMERIC(20,4) NOT NULL,
    transaction_category_id UUID NOT NULL,
    liability_account_id UUID NOT NULL,
    source_account_id UUID NOT NULL,
    source_account_function TEXT NOT NULL,
    financial_event_id UUID NOT NULL
        REFERENCES public.financial_events(id) ON DELETE RESTRICT,
    idempotency_key UUID NOT NULL,
    payload_hash TEXT NOT NULL,
    created_by UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT customer_balance_ledger_company_id_id_unique
        UNIQUE(company_id,id),
    CONSTRAINT customer_balance_ledger_company_entry_unique
        UNIQUE(company_id,entry_no),
    CONSTRAINT customer_balance_ledger_source_unique
        UNIQUE(company_id,source_type,source_id),
    CONSTRAINT customer_balance_ledger_idempotency_unique
        UNIQUE(company_id,idempotency_key),
    CONSTRAINT customer_balance_ledger_direction_check
        CHECK(direction IN ('CREDIT','DEBIT')),
    CONSTRAINT customer_balance_ledger_amount_positive CHECK(amount>0),
    CONSTRAINT customer_balance_ledger_balance_nonnegative CHECK(
        balance_before>=0 AND balance_after>=0
    ),
    CONSTRAINT customer_balance_ledger_arithmetic_check CHECK(
        (direction='CREDIT' AND balance_after=balance_before+amount)
        OR (direction='DEBIT' AND balance_after=balance_before-amount)
    ),
    CONSTRAINT customer_balance_ledger_source_check
        CHECK(source_type='MANUAL_CORRECTION'),
    CONSTRAINT customer_balance_ledger_identity_not_blank CHECK(
        btrim(source_reference)<>'' AND btrim(reason)<>''
        AND btrim(source_account_function)<>'' AND btrim(payload_hash)<>''
    ),
    CONSTRAINT customer_balance_ledger_evidence_https
        CHECK(evidence_url IS NULL OR evidence_url~*'^https://'),
    CONSTRAINT fk_customer_balance_ledger_customer
        FOREIGN KEY(company_id,customer_id)
        REFERENCES public.customers(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_customer_balance_ledger_store
        FOREIGN KEY(company_id,store_id)
        REFERENCES public.stores(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_customer_balance_ledger_category
        FOREIGN KEY(company_id,transaction_category_id)
        REFERENCES public.transaction_categories(company_id,id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_customer_balance_ledger_liability_account
        FOREIGN KEY(company_id,liability_account_id)
        REFERENCES public.chart_of_accounts(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_customer_balance_ledger_source_account
        FOREIGN KEY(company_id,source_account_id)
        REFERENCES public.chart_of_accounts(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_customer_balance_ledger_request
        FOREIGN KEY(company_id,source_id)
        REFERENCES public.customer_balance_correction_requests(company_id,id)
        ON DELETE RESTRICT
);

ALTER TABLE public.customer_balance_correction_requests
    ADD CONSTRAINT fk_customer_balance_request_ledger
    FOREIGN KEY(company_id,ledger_entry_id)
    REFERENCES public.customer_balance_ledger_entries(company_id,id)
    ON DELETE RESTRICT;

CREATE TABLE public.customer_balance_audit (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_id UUID NOT NULL,
    customer_id UUID,
    correction_request_id UUID,
    action TEXT NOT NULL,
    actor_id UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
    before_state JSONB,
    after_state JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT customer_balance_audit_action_check CHECK(
        action IN (
            'POLICY_PROVISION','POLICY_SYNC','REQUEST_CORRECTION',
            'APPROVE_CORRECTION','REJECT_CORRECTION','AUTO_DISABLE'
        )
    ),
    CONSTRAINT customer_balance_audit_company_required
        FOREIGN KEY(company_id) REFERENCES public.companies(id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_customer_balance_audit_customer
        FOREIGN KEY(company_id,customer_id)
        REFERENCES public.customers(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_customer_balance_audit_request
        FOREIGN KEY(company_id,correction_request_id)
        REFERENCES public.customer_balance_correction_requests(company_id,id)
        ON DELETE RESTRICT
);

CREATE INDEX idx_customer_balance_ledger_statement
    ON public.customer_balance_ledger_entries(
        company_id,customer_id,created_at,entry_no
    );
CREATE INDEX idx_customer_balance_request_review
    ON public.customer_balance_correction_requests(
        company_id,status,created_at DESC
    );
CREATE INDEX idx_customer_balance_audit_company_time
    ON public.customer_balance_audit(company_id,created_at DESC);

CREATE FUNCTION private.resolve_customer_balance_account(
    p_company_id UUID,p_transaction_category_id UUID,
    p_account_function_key TEXT,p_effective_at TIMESTAMPTZ
) RETURNS UUID LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_account UUID; v_key TEXT:=upper(btrim(COALESCE(p_account_function_key,'')));
BEGIN
    IF v_key='' THEN RAISE EXCEPTION 'CUSTOMER_BALANCE_ACCOUNT_FUNCTION_REQUIRED'; END IF;
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
        SELECT account.id INTO v_account
        FROM public.chart_of_accounts account
        WHERE account.company_id=p_company_id
          AND account.system_function_key=v_key
          AND account.is_active AND account.is_postable
        ORDER BY account.account_code,account.id LIMIT 1;
    END IF;
    IF v_account IS NULL THEN
        RAISE EXCEPTION 'CUSTOMER_BALANCE_ACCOUNT_NOT_RESOLVED:%',v_key;
    END IF;
    RETURN v_account;
END;
$$;

CREATE FUNCTION private.trg_g4_customer_balance_history_guard()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path=public,pg_temp AS $$
BEGIN RAISE EXCEPTION 'CUSTOMER_BALANCE_HISTORY_IMMUTABLE'; END;
$$;

CREATE FUNCTION private.provision_customer_balance_company(
    p_company_id UUID,p_actor UUID DEFAULT NULL
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_enabled BOOLEAN; v_state TEXT; v_inserted BIGINT;
BEGIN
    SELECT COALESCE(bool_or(feature.is_enabled),FALSE) INTO v_enabled
    FROM public.company_features feature
    WHERE feature.company_id=p_company_id
      AND feature.feature_code='customer_balance_enabled';
    v_state:=CASE WHEN v_enabled THEN 'ACTIVE' ELSE 'DISABLED' END;
    INSERT INTO public.customer_balance_company_policies(
        company_id,lifecycle_state,created_by,updated_by
    ) VALUES(p_company_id,v_state,p_actor,p_actor)
    ON CONFLICT(company_id) DO NOTHING;
    GET DIAGNOSTICS v_inserted=ROW_COUNT;
    IF v_inserted=1 THEN
        INSERT INTO public.customer_balance_audit(
            company_id,action,actor_id,after_state
        ) VALUES(
            p_company_id,'POLICY_PROVISION',p_actor,
            jsonb_build_object('lifecycleState',v_state)
        );
    END IF;

    IF NOT EXISTS(
        SELECT 1 FROM public.payment_methods
        WHERE company_id=p_company_id AND method_type='CUSTOMER_BALANCE'
    ) THEN
        INSERT INTO public.payment_methods(
            company_id,payment_method_code,payment_method_name,method_type,
            settlement_route,is_default,available_all_stores,proof_mode,
            fee_enabled,is_active,is_system_method,created_by,updated_by
        ) VALUES(
            p_company_id,'','Saldo Customer','CUSTOMER_BALANCE',
            'INTERNAL_LIABILITY',FALSE,TRUE,'OPTIONAL',FALSE,v_enabled,TRUE,
            p_actor,p_actor
        );
    END IF;
END;
$$;

CREATE FUNCTION private.trg_g4_provision_customer_balance_company()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
BEGIN
    PERFORM private.provision_customer_balance_company(NEW.id,NULL);
    RETURN NEW;
END;
$$;

CREATE FUNCTION private.trg_g4_sync_customer_balance_feature()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_before TEXT; v_after TEXT; v_outstanding NUMERIC(20,4);
BEGIN
    IF NEW.feature_code<>'customer_balance_enabled' THEN RETURN NEW; END IF;
    PERFORM private.provision_customer_balance_company(NEW.company_id,NEW.updated_by);
    SELECT lifecycle_state INTO v_before
    FROM public.customer_balance_company_policies
    WHERE company_id=NEW.company_id FOR UPDATE;
    SELECT COALESCE(sum(current_balance),0) INTO v_outstanding
    FROM public.customers WHERE company_id=NEW.company_id;
    v_after:=CASE
        WHEN NEW.is_enabled THEN 'ACTIVE'
        WHEN v_outstanding>0 THEN 'WIND_DOWN'
        ELSE 'DISABLED'
    END;
    UPDATE public.customer_balance_company_policies
    SET lifecycle_state=v_after,master_version=master_version+1,
        updated_by=NEW.updated_by,updated_at=clock_timestamp()
    WHERE company_id=NEW.company_id AND lifecycle_state IS DISTINCT FROM v_after;
    UPDATE public.payment_methods
    SET is_active=(v_after<>'DISABLED'),updated_by=NEW.updated_by
    WHERE company_id=NEW.company_id AND method_type='CUSTOMER_BALANCE'
      AND is_active IS DISTINCT FROM (v_after<>'DISABLED');
    IF v_before IS DISTINCT FROM v_after THEN
        INSERT INTO public.customer_balance_audit(
            company_id,action,actor_id,before_state,after_state
        ) VALUES(
            NEW.company_id,'POLICY_SYNC',NEW.updated_by,
            jsonb_build_object('lifecycleState',v_before),
            jsonb_build_object('lifecycleState',v_after)
        );
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION public.request_customer_balance_correction(
    p_customer_id UUID,p_store_id UUID,p_direction TEXT,p_amount NUMERIC,
    p_source_account_function TEXT,p_reason TEXT,p_evidence_url TEXT,
    p_idempotency_key UUID
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
    v_company UUID:=public.private_active_company_id(); v_actor UUID:=auth.uid();
    v_customer public.customers%ROWTYPE; v_policy TEXT; v_direction TEXT:=upper(btrim(COALESCE(p_direction,'')));
    v_function TEXT:=upper(btrim(COALESCE(p_source_account_function,'')));
    v_hash TEXT; v_existing public.customer_balance_correction_requests%ROWTYPE;
    v_id UUID; v_no TEXT;
BEGIN
    IF v_company IS NULL OR v_actor IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF p_idempotency_key IS NULL THEN RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED'; END IF;
    IF v_direction NOT IN ('CREDIT','DEBIT') OR p_amount IS NULL OR p_amount<=0
       OR btrim(COALESCE(p_reason,''))='' OR v_function='' THEN
        RAISE EXCEPTION 'INVALID_CUSTOMER_BALANCE_CORRECTION';
    END IF;
    IF p_evidence_url IS NOT NULL AND p_evidence_url!~*'^https://' THEN
        RAISE EXCEPTION 'CUSTOMER_BALANCE_EVIDENCE_HTTPS_REQUIRED';
    END IF;
    IF NOT EXISTS(SELECT 1 FROM public.stores store WHERE store.company_id=v_company AND store.id=p_store_id AND store.status='ACTIVE')
       OR NOT public.private_user_has_store_access(p_store_id) THEN
        RAISE EXCEPTION 'ACTIVE_STORE_NOT_FOUND';
    END IF;
    IF NOT (public.private_user_has_store_access(p_store_id)
        OR public.private_user_has_any_company_role(v_company,ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE']::TEXT[])) THEN
        RAISE EXCEPTION 'CUSTOMER_BALANCE_REQUEST_ACCESS_DENIED';
    END IF;
    SELECT * INTO v_customer FROM public.customers
    WHERE company_id=v_company AND id=p_customer_id;
    IF NOT FOUND OR v_customer.is_system_customer THEN
        RAISE EXCEPTION 'CUSTOMER_BALANCE_CUSTOMER_NOT_FOUND';
    END IF;
    SELECT lifecycle_state INTO v_policy
    FROM public.customer_balance_company_policies WHERE company_id=v_company;
    IF v_direction='CREDIT' AND (
        v_policy<>'ACTIVE' OR NOT v_customer.is_active OR NOT EXISTS(
            SELECT 1 FROM public.company_features feature
            WHERE feature.company_id=v_company
              AND feature.feature_code='customer_balance_enabled'
              AND feature.is_enabled
        )
    ) THEN RAISE EXCEPTION 'CUSTOMER_BALANCE_CREDIT_DISABLED'; END IF;
    IF v_direction='DEBIT' AND v_policy NOT IN ('ACTIVE','WIND_DOWN') THEN
        RAISE EXCEPTION 'CUSTOMER_BALANCE_DEBIT_DISABLED';
    END IF;
    IF NOT EXISTS(SELECT 1 FROM public.account_functions af WHERE af.function_key=v_function) THEN
        RAISE EXCEPTION 'CUSTOMER_BALANCE_SOURCE_FUNCTION_NOT_FOUND';
    END IF;
    v_hash:=encode(digest(concat_ws('|',v_company,p_customer_id,p_store_id,v_direction,p_amount::NUMERIC(20,4),v_function,btrim(p_reason),COALESCE(p_evidence_url,'')),'sha256'),'hex');
    SELECT * INTO v_existing FROM public.customer_balance_correction_requests
    WHERE company_id=v_company AND idempotency_key=p_idempotency_key;
    IF FOUND THEN
        IF v_existing.payload_hash<>v_hash THEN RAISE EXCEPTION 'IDEMPOTENCY_PAYLOAD_CONFLICT'; END IF;
        RETURN jsonb_build_object('correctionRequestId',v_existing.id,'requestNo',v_existing.request_no,'status',v_existing.status,'masterVersion',v_existing.master_version,'idempotentReplay',TRUE);
    END IF;
    v_no:='CB-COR-'||to_char(clock_timestamp(),'YYYYMMDD')||'-'||lpad(nextval('private.customer_balance_request_no_seq')::TEXT,10,'0');
    INSERT INTO public.customer_balance_correction_requests(
        company_id,customer_id,store_id,request_no,direction,amount,
        source_account_function,reason,evidence_url,idempotency_key,
        payload_hash,created_by
    ) VALUES(v_company,p_customer_id,p_store_id,v_no,v_direction,p_amount,
        v_function,btrim(p_reason),NULLIF(btrim(COALESCE(p_evidence_url,'')),''),
        p_idempotency_key,v_hash,v_actor) RETURNING id INTO v_id;
    INSERT INTO public.customer_balance_audit(
        company_id,customer_id,correction_request_id,action,actor_id,after_state
    ) SELECT v_company,p_customer_id,id,'REQUEST_CORRECTION',v_actor,to_jsonb(request)
      FROM public.customer_balance_correction_requests request WHERE id=v_id;
    RETURN jsonb_build_object('correctionRequestId',v_id,'requestNo',v_no,'status','SUBMITTED','masterVersion',1);
END;
$$;

CREATE FUNCTION public.review_customer_balance_correction(
    p_request_id UUID,p_master_version BIGINT,p_action TEXT,
    p_reason TEXT,p_idempotency_key UUID
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
    v_company UUID:=public.private_active_company_id(); v_actor UUID:=auth.uid();
    v_request public.customer_balance_correction_requests%ROWTYPE;
    v_customer public.customers%ROWTYPE; v_action TEXT:=upper(btrim(COALESCE(p_action,'')));
    v_policy TEXT; v_now TIMESTAMPTZ:=clock_timestamp(); v_category UUID;
    v_liability UUID; v_source UUID; v_event UUID; v_entry UUID;
    v_before NUMERIC(20,4); v_after NUMERIC(20,4); v_entry_no BIGINT;
    v_new_version BIGINT; v_old JSONB; v_system_key TEXT;
BEGIN
    IF v_company IS NULL OR v_actor IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF v_action NOT IN ('APPROVE','REJECT') THEN RAISE EXCEPTION 'CUSTOMER_BALANCE_REVIEW_ACTION_INVALID'; END IF;
    IF p_idempotency_key IS NULL THEN RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED'; END IF;
    IF NOT public.private_user_has_any_company_role(v_company,ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE']::TEXT[]) THEN
        RAISE EXCEPTION 'CUSTOMER_BALANCE_REVIEW_ACCESS_DENIED';
    END IF;
    SELECT * INTO v_request FROM public.customer_balance_correction_requests
    WHERE company_id=v_company AND id=p_request_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'CUSTOMER_BALANCE_CORRECTION_NOT_FOUND'; END IF;
    IF v_request.status IN ('APPROVED','REJECTED')
       AND v_request.review_idempotency_key=p_idempotency_key THEN
        RETURN jsonb_build_object('correctionRequestId',v_request.id,'status',v_request.status,'masterVersion',v_request.master_version,'ledgerEntryId',v_request.ledger_entry_id,'idempotentReplay',TRUE);
    END IF;
    IF v_request.status<>'SUBMITTED' THEN RAISE EXCEPTION 'CUSTOMER_BALANCE_CORRECTION_NOT_REVIEWABLE'; END IF;
    IF p_master_version IS DISTINCT FROM v_request.master_version THEN RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
    IF v_request.created_by=v_actor THEN RAISE EXCEPTION 'MAKER_CANNOT_REVIEW_OWN_CUSTOMER_BALANCE_CORRECTION'; END IF;
    IF v_action='REJECT' AND btrim(COALESCE(p_reason,''))='' THEN RAISE EXCEPTION 'CUSTOMER_BALANCE_REJECTION_REASON_REQUIRED'; END IF;
    v_old:=to_jsonb(v_request);
    IF v_action='REJECT' THEN
        UPDATE public.customer_balance_correction_requests SET
            status='REJECTED',review_idempotency_key=p_idempotency_key,
            reviewed_by=v_actor,reviewed_at=v_now,rejection_reason=btrim(p_reason),
            master_version=master_version+1
        WHERE id=v_request.id RETURNING master_version INTO v_new_version;
        INSERT INTO public.customer_balance_audit(company_id,customer_id,correction_request_id,action,actor_id,before_state,after_state)
        SELECT v_company,customer_id,id,'REJECT_CORRECTION',v_actor,v_old,to_jsonb(request)
        FROM public.customer_balance_correction_requests request WHERE id=v_request.id;
        RETURN jsonb_build_object('correctionRequestId',v_request.id,'status','REJECTED','masterVersion',v_new_version);
    END IF;
    SELECT * INTO v_customer FROM public.customers
    WHERE company_id=v_company AND id=v_request.customer_id FOR UPDATE;
    IF NOT FOUND OR v_customer.is_system_customer THEN RAISE EXCEPTION 'CUSTOMER_BALANCE_CUSTOMER_NOT_FOUND'; END IF;
    SELECT lifecycle_state INTO v_policy FROM public.customer_balance_company_policies
    WHERE company_id=v_company FOR UPDATE;
    IF v_request.direction='CREDIT' AND (v_policy<>'ACTIVE' OR NOT v_customer.is_active) THEN
        RAISE EXCEPTION 'CUSTOMER_BALANCE_CREDIT_DISABLED';
    END IF;
    IF v_request.direction='DEBIT' AND v_policy NOT IN ('ACTIVE','WIND_DOWN') THEN
        RAISE EXCEPTION 'CUSTOMER_BALANCE_DEBIT_DISABLED';
    END IF;
    v_before:=v_customer.current_balance;
    v_after:=CASE WHEN v_request.direction='CREDIT' THEN v_before+v_request.amount ELSE v_before-v_request.amount END;
    IF v_after<0 THEN RAISE EXCEPTION 'INSUFFICIENT_CUSTOMER_BALANCE'; END IF;
    v_system_key:=CASE WHEN v_request.direction='CREDIT' THEN 'CUSTOMER_BALANCE_RECEIPT' ELSE 'CUSTOMER_BALANCE_USAGE' END;
    SELECT category.id INTO v_category FROM public.transaction_categories category
    WHERE category.company_id=v_company AND category.system_key=v_system_key
      AND category.is_active
    ORDER BY category.is_system_default DESC,category.id LIMIT 1;
    IF v_category IS NULL THEN RAISE EXCEPTION 'CUSTOMER_BALANCE_TRANSACTION_CATEGORY_NOT_FOUND'; END IF;
    v_liability:=private.resolve_customer_balance_account(v_company,v_category,'CUSTOMER_BALANCE_LIABILITY',v_now);
    v_source:=private.resolve_customer_balance_account(v_company,v_category,v_request.source_account_function,v_now);
    INSERT INTO public.financial_events(
        event_code,event_type,source_table,source_id,root_sales_id,event_date,
        event_version,idempotency_key,payment_method,amounts,status,error_message,
        created_by,company_id,store_id,system_event_key,transaction_category_id
    ) VALUES(
        'CB-ADJ-'||replace(v_request.id::TEXT,'-',''),
        'CUSTOMER_BALANCE_ADJUSTMENT'::public.event_type,
        'customer_balance_correction_requests',v_request.id,NULL,v_now,1,
        'CUSTOMER_BALANCE_CORRECTION|'||v_company::TEXT||'|'||p_idempotency_key::TEXT,
        'CUSTOMER_BALANCE',jsonb_build_object(
            'correctionRequestId',v_request.id,'requestNo',v_request.request_no,
            'customerId',v_request.customer_id,'direction',v_request.direction,
            'amount',v_request.amount,'balanceBefore',v_before,'balanceAfter',v_after,
            'liabilityAccountId',v_liability,'sourceAccountId',v_source,
            'sourceAccountFunction',v_request.source_account_function,
            'financePostingState','HOLD_UNTIL_G6'
        ),'HOLD'::public.event_status,'CANONICAL_FINANCE_POSTING_NOT_ENABLED',
        v_actor,v_company,v_request.store_id,v_system_key,v_category
    ) RETURNING id INTO v_event;
    -- A sequence avoids duplicate entry numbers under concurrent approvals.
    v_entry_no:=nextval('private.customer_balance_request_no_seq');
    INSERT INTO public.customer_balance_ledger_entries(
        company_id,customer_id,store_id,entry_no,direction,amount,source_type,
        source_id,source_reference,reason,evidence_url,balance_before,
        balance_after,transaction_category_id,liability_account_id,
        source_account_id,source_account_function,financial_event_id,
        idempotency_key,payload_hash,created_by
    ) VALUES(v_company,v_request.customer_id,v_request.store_id,v_entry_no,
        v_request.direction,v_request.amount,'MANUAL_CORRECTION',v_request.id,
        v_request.request_no,v_request.reason,v_request.evidence_url,v_before,
        v_after,v_category,v_liability,v_source,v_request.source_account_function,
        v_event,p_idempotency_key,v_request.payload_hash,v_actor)
    RETURNING id INTO v_entry;
    UPDATE public.customers SET current_balance=v_after,updated_by=v_actor
    WHERE company_id=v_company AND id=v_customer.id;
    UPDATE public.customer_balance_correction_requests SET
        status='APPROVED',review_idempotency_key=p_idempotency_key,
        reviewed_by=v_actor,reviewed_at=v_now,ledger_entry_id=v_entry,
        financial_event_id=v_event,master_version=master_version+1
    WHERE id=v_request.id RETURNING master_version INTO v_new_version;
    INSERT INTO public.customer_balance_audit(company_id,customer_id,correction_request_id,action,actor_id,before_state,after_state)
    SELECT v_company,customer_id,id,'APPROVE_CORRECTION',v_actor,v_old,to_jsonb(request)
    FROM public.customer_balance_correction_requests request WHERE id=v_request.id;
    IF v_policy='WIND_DOWN'
       AND NOT EXISTS(SELECT 1 FROM public.customers WHERE company_id=v_company AND current_balance>0) THEN
        UPDATE public.customer_balance_company_policies SET lifecycle_state='DISABLED',master_version=master_version+1,updated_by=v_actor,updated_at=v_now WHERE company_id=v_company;
        UPDATE public.payment_methods SET is_active=FALSE,updated_by=v_actor WHERE company_id=v_company AND method_type='CUSTOMER_BALANCE' AND is_active;
        INSERT INTO public.customer_balance_audit(company_id,action,actor_id,before_state,after_state)
        VALUES(v_company,'AUTO_DISABLE',v_actor,jsonb_build_object('lifecycleState','WIND_DOWN'),jsonb_build_object('lifecycleState','DISABLED'));
    END IF;
    RETURN jsonb_build_object('correctionRequestId',v_request.id,'status','APPROVED','masterVersion',v_new_version,'ledgerEntryId',v_entry,'financialEventId',v_event,'balanceAfter',v_after);
END;
$$;

CREATE FUNCTION public.get_customer_balance_statement(
    p_customer_id UUID,p_from TIMESTAMPTZ DEFAULT NULL,
    p_to TIMESTAMPTZ DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id(); v_customer public.customers%ROWTYPE; v_rows JSONB;
BEGIN
    IF v_company IS NULL OR auth.uid() IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF NOT public.private_user_has_company_access(v_company) THEN RAISE EXCEPTION 'CUSTOMER_BALANCE_STATEMENT_ACCESS_DENIED'; END IF;
    SELECT * INTO v_customer FROM public.customers WHERE company_id=v_company AND id=p_customer_id;
    IF NOT FOUND OR v_customer.is_system_customer THEN RAISE EXCEPTION 'CUSTOMER_BALANCE_CUSTOMER_NOT_FOUND'; END IF;
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'ledgerEntryId',entry.id,'entryNo',entry.entry_no,'direction',entry.direction,
        'amount',entry.amount,'balanceBefore',entry.balance_before,
        'balanceAfter',entry.balance_after,'sourceType',entry.source_type,
        'sourceReference',entry.source_reference,'reason',entry.reason,
        'storeId',entry.store_id,'actorId',entry.created_by,'createdAt',entry.created_at
    ) ORDER BY entry.created_at,entry.entry_no),'[]'::JSONB) INTO v_rows
    FROM public.customer_balance_ledger_entries entry
    WHERE entry.company_id=v_company AND entry.customer_id=p_customer_id
      AND (p_from IS NULL OR entry.created_at>=p_from)
      AND (p_to IS NULL OR entry.created_at<p_to);
    RETURN jsonb_build_object('customerId',v_customer.id,'customerName',v_customer.name,'currentBalance',v_customer.current_balance,'entries',v_rows);
END;
$$;

CREATE TRIGGER g4_customer_balance_ledger_immutable
BEFORE UPDATE OR DELETE ON public.customer_balance_ledger_entries
FOR EACH ROW EXECUTE FUNCTION private.trg_g4_customer_balance_history_guard();
CREATE TRIGGER g4_customer_balance_audit_immutable
BEFORE UPDATE OR DELETE ON public.customer_balance_audit
FOR EACH ROW EXECUTE FUNCTION private.trg_g4_customer_balance_history_guard();
CREATE TRIGGER g4_provision_customer_balance_company
AFTER INSERT ON public.companies
FOR EACH ROW EXECUTE FUNCTION private.trg_g4_provision_customer_balance_company();
CREATE TRIGGER g4_sync_customer_balance_feature
AFTER INSERT OR UPDATE OF is_enabled ON public.company_features
FOR EACH ROW EXECUTE FUNCTION private.trg_g4_sync_customer_balance_feature();

SELECT private.provision_customer_balance_company(company.id,NULL)
FROM public.companies company;

ALTER TABLE public.customer_balance_company_policies ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.customer_balance_correction_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.customer_balance_ledger_entries ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.customer_balance_audit ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Customer Balance policy readable in active Company"
ON public.customer_balance_company_policies FOR SELECT TO authenticated
USING(public.private_request_company_matches(company_id) AND public.private_user_has_company_access(company_id));
CREATE POLICY "Customer Balance requests readable by operational scope"
ON public.customer_balance_correction_requests FOR SELECT TO authenticated
USING(public.private_request_company_matches(company_id) AND (created_by=auth.uid() OR public.private_user_has_store_access(store_id) OR public.private_user_has_any_company_role(company_id,ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE','ACCOUNTING']::TEXT[])));
CREATE POLICY "Customer Balance ledger readable by Finance"
ON public.customer_balance_ledger_entries FOR SELECT TO authenticated
USING(public.private_request_company_matches(company_id) AND public.private_user_has_any_company_role(company_id,ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE','ACCOUNTING']::TEXT[]));
CREATE POLICY "Customer Balance audit readable by Finance"
ON public.customer_balance_audit FOR SELECT TO authenticated
USING(public.private_request_company_matches(company_id) AND public.private_user_has_any_company_role(company_id,ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE','ACCOUNTING']::TEXT[]));

REVOKE ALL ON public.customer_balance_company_policies,
    public.customer_balance_correction_requests,
    public.customer_balance_ledger_entries,public.customer_balance_audit
FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.customer_balance_company_policies,
    public.customer_balance_correction_requests,
    public.customer_balance_ledger_entries,public.customer_balance_audit
TO authenticated;
GRANT ALL ON public.customer_balance_company_policies,
    public.customer_balance_correction_requests,
    public.customer_balance_ledger_entries,public.customer_balance_audit
TO service_role;

REVOKE ALL ON FUNCTION
    private.resolve_customer_balance_account(UUID,UUID,TEXT,TIMESTAMPTZ),
    private.trg_g4_customer_balance_history_guard(),
    private.provision_customer_balance_company(UUID,UUID),
    private.trg_g4_provision_customer_balance_company(),
    private.trg_g4_sync_customer_balance_feature()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
    private.resolve_customer_balance_account(UUID,UUID,TEXT,TIMESTAMPTZ),
    private.trg_g4_customer_balance_history_guard(),
    private.provision_customer_balance_company(UUID,UUID),
    private.trg_g4_provision_customer_balance_company(),
    private.trg_g4_sync_customer_balance_feature()
TO service_role;
REVOKE ALL ON FUNCTION
    public.request_customer_balance_correction(UUID,UUID,TEXT,NUMERIC,TEXT,TEXT,TEXT,UUID),
    public.review_customer_balance_correction(UUID,BIGINT,TEXT,TEXT,UUID),
    public.get_customer_balance_statement(UUID,TIMESTAMPTZ,TIMESTAMPTZ)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION
    public.request_customer_balance_correction(UUID,UUID,TEXT,NUMERIC,TEXT,TEXT,TEXT,UUID),
    public.review_customer_balance_correction(UUID,BIGINT,TEXT,TEXT,UUID),
    public.get_customer_balance_statement(UUID,TIMESTAMPTZ,TIMESTAMPTZ)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES(
    '20260805090000','g4_phase49_customer_balance_foundation',
    'POS-006 append-only Customer Balance ledger, Company lifecycle, guarded correction approval, statement, and internal method provisioning; checkout/G6 remain closed'
);

COMMIT;
