-- KGS POS G4 phase 12: canonical Offline Sale submission and sync.
-- Requirement: POS-004
-- Dependency: Offline Stock Allowance foundation through 20260729180000.
--
-- This migration opens guarded server submission/sync RPCs only. The PWA
-- offline queue remains closed until its own API/UI phase and UAT gate.

BEGIN;

DO $migration_guard$
BEGIN
    IF to_regclass('private.kgs_schema_migrations') IS NULL
       OR NOT EXISTS (
           SELECT 1 FROM private.kgs_schema_migrations
           WHERE version = '20260729180000'
       ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: G4 Offline Allowance foundation missing';
    END IF;
    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260729210000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260729210000';
    END IF;
    IF EXISTS (
        SELECT 1 FROM public.company_features
        WHERE feature_code = 'offline_pos_enabled' AND is_enabled
    ) THEN
        RAISE EXCEPTION
            'G4_PHASE12_STATE_CHANGED: disable Offline POS before sync rollout';
    END IF;
    IF EXISTS (
        SELECT 1 FROM public.pos_offline_sale_submissions
        WHERE status IN (
            'QUEUED','SYNCING','NEEDS_CONFIRMATION','FAILED'
        )
    ) THEN
        RAISE EXCEPTION
            'G4_PHASE12_STATE_CHANGED: resolve nonterminal Offline submissions';
    END IF;
    IF to_regclass(
        'public.pos_offline_sale_allowance_consumptions'
    ) IS NOT NULL
       OR to_regclass('public.pos_offline_sync_exceptions') IS NOT NULL
       OR to_regclass('public.offline_payment_exceptions') IS NOT NULL
       OR to_regprocedure(
           'public.submit_pos_offline_sale(jsonb)'
       ) IS NOT NULL
       OR to_regprocedure(
           'public.process_pos_offline_sale_submission(uuid)'
       ) IS NOT NULL
       OR to_regprocedure(
           'public.get_pos_offline_submission_status(uuid)'
       ) IS NOT NULL THEN
        RAISE EXCEPTION 'G4_PHASE12_CANONICAL_OBJECT_ALREADY_EXISTS';
    END IF;
    IF to_regprocedure('extensions.digest(bytea,text)') IS NULL THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: pgcrypto digest unavailable';
    END IF;
END
$migration_guard$;

-- -------------------------------------------------------------------------
-- 1. Offline snapshots on the canonical Sale
-- -------------------------------------------------------------------------

ALTER TABLE public.sales_headers
    ADD COLUMN source_channel TEXT NOT NULL DEFAULT 'ONLINE',
    ADD COLUMN offline_submission_id UUID,
    ADD COLUMN offline_transaction_at TIMESTAMPTZ,
    ADD COLUMN offline_price_variance_total NUMERIC(20,4),
    ADD CONSTRAINT sales_headers_source_channel_check CHECK (
        source_channel IN ('ONLINE','OFFLINE')
    ),
    ADD CONSTRAINT sales_headers_offline_snapshot_check CHECK (
        (
            source_channel = 'ONLINE'
            AND offline_submission_id IS NULL
            AND offline_transaction_at IS NULL
            AND offline_price_variance_total IS NULL
        )
        OR (
            source_channel = 'OFFLINE'
            AND offline_submission_id IS NOT NULL
            AND offline_transaction_at IS NOT NULL
            AND offline_price_variance_total IS NOT NULL
        )
    ),
    ADD CONSTRAINT fk_sales_headers_company_offline_submission
        FOREIGN KEY(company_id,offline_submission_id)
        REFERENCES public.pos_offline_sale_submissions(company_id,id)
        ON DELETE RESTRICT;

CREATE UNIQUE INDEX uq_sales_headers_company_offline_submission
    ON public.sales_headers(company_id,offline_submission_id)
    WHERE offline_submission_id IS NOT NULL;

ALTER TABLE public.sales_details
    ADD COLUMN offline_snapshot_unit_price NUMERIC(20,4),
    ADD COLUMN offline_resolved_unit_price NUMERIC(20,4),
    ADD COLUMN offline_price_variance NUMERIC(20,4),
    ADD CONSTRAINT sales_details_offline_price_nonnegative CHECK (
        offline_snapshot_unit_price IS NULL
        OR offline_snapshot_unit_price >= 0
    ),
    ADD CONSTRAINT sales_details_offline_price_shape CHECK (
        (
            offline_snapshot_unit_price IS NULL
            AND offline_resolved_unit_price IS NULL
            AND offline_price_variance IS NULL
        )
        OR (
            offline_snapshot_unit_price IS NOT NULL
            AND offline_resolved_unit_price IS NOT NULL
            AND offline_price_variance IS NOT NULL
        )
    );

ALTER TABLE public.sales_payments
    ADD COLUMN offline_verification_status TEXT,
    ADD COLUMN offline_reference_snapshot JSONB,
    ADD CONSTRAINT sales_payments_offline_verification_check CHECK (
        offline_verification_status IS NULL
        OR offline_verification_status IN (
            'VERIFIED','PENDING_VERIFICATION','FAILED','RESOLVED'
        )
    ),
    ADD CONSTRAINT sales_payments_offline_reference_shape CHECK (
        (
            offline_verification_status IS NULL
            AND offline_reference_snapshot IS NULL
        )
        OR (
            offline_verification_status IS NOT NULL
            AND jsonb_typeof(offline_reference_snapshot) = 'object'
        )
    );

ALTER TABLE public.pos_offline_sale_submissions
    ADD COLUMN payload_version BIGINT NOT NULL DEFAULT 1,
    ADD COLUMN server_payload_hash TEXT,
    ADD COLUMN processing_attempts INTEGER NOT NULL DEFAULT 0,
    ADD COLUMN last_attempt_at TIMESTAMPTZ,
    ADD CONSTRAINT pos_offline_submission_payload_version_positive
        CHECK(payload_version > 0),
    ADD CONSTRAINT pos_offline_submission_server_hash_check CHECK (
        server_payload_hash IS NULL
        OR server_payload_hash ~ '^[0-9a-f]{64}$'
    ),
    ADD CONSTRAINT pos_offline_submission_attempt_nonnegative
        CHECK(processing_attempts >= 0);

UPDATE public.pos_offline_sale_submissions
SET server_payload_hash = payload_hash
WHERE server_payload_hash IS NULL;

ALTER TABLE public.pos_offline_sale_submissions
    ALTER COLUMN server_payload_hash SET NOT NULL;

-- -------------------------------------------------------------------------
-- 2. Consumption and append-only exception ledgers
-- -------------------------------------------------------------------------

CREATE TABLE public.pos_offline_sale_allowance_consumptions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL,
    submission_id UUID NOT NULL,
    allowance_id UUID NOT NULL,
    sales_id UUID NOT NULL,
    product_id UUID NOT NULL,
    base_uom_id UUID NOT NULL,
    consumed_base_qty NUMERIC(24,6) NOT NULL,
    allowance_before_base_qty NUMERIC(24,6) NOT NULL,
    allowance_after_base_qty NUMERIC(24,6) NOT NULL,
    created_by UUID NOT NULL
        REFERENCES public.profiles(id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT offline_consumption_company_id_id_unique
        UNIQUE(company_id,id),
    CONSTRAINT offline_consumption_submission_product_unique
        UNIQUE(company_id,submission_id,product_id),
    CONSTRAINT offline_consumption_quantity_check CHECK (
        consumed_base_qty > 0
        AND allowance_before_base_qty >= consumed_base_qty
        AND allowance_after_base_qty =
            allowance_before_base_qty - consumed_base_qty
        AND allowance_after_base_qty >= 0
    ),
    CONSTRAINT fk_offline_consumption_submission
        FOREIGN KEY(company_id,submission_id)
        REFERENCES public.pos_offline_sale_submissions(company_id,id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_offline_consumption_allowance
        FOREIGN KEY(company_id,allowance_id)
        REFERENCES public.pos_offline_stock_allowances(company_id,id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_offline_consumption_sale
        FOREIGN KEY(company_id,sales_id)
        REFERENCES public.sales_headers(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_offline_consumption_product
        FOREIGN KEY(company_id,product_id)
        REFERENCES public.products(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_offline_consumption_uom
        FOREIGN KEY(company_id,base_uom_id)
        REFERENCES public.uoms(company_id,id) ON DELETE RESTRICT
);

CREATE INDEX idx_offline_consumption_sale
    ON public.pos_offline_sale_allowance_consumptions(
        company_id,sales_id,created_at
    );
CREATE INDEX idx_offline_consumption_allowance
    ON public.pos_offline_sale_allowance_consumptions(
        company_id,allowance_id,created_at
    );

CREATE TABLE public.pos_offline_sync_exceptions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL,
    submission_id UUID NOT NULL,
    sales_id UUID,
    exception_type TEXT NOT NULL,
    error_code TEXT NOT NULL,
    details JSONB NOT NULL,
    actor_id UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT offline_sync_exception_company_id_id_unique
        UNIQUE(company_id,id),
    CONSTRAINT offline_sync_exception_type_check CHECK (
        exception_type IN (
            'PRICE_VARIANCE','PROCESSING_FAILURE',
            'PAYMENT_VERIFICATION','MASTER_VERSION_VARIANCE'
        )
    ),
    CONSTRAINT offline_sync_exception_code_not_blank
        CHECK(btrim(error_code) <> ''),
    CONSTRAINT offline_sync_exception_details_object
        CHECK(jsonb_typeof(details) = 'object'),
    CONSTRAINT fk_offline_sync_exception_submission
        FOREIGN KEY(company_id,submission_id)
        REFERENCES public.pos_offline_sale_submissions(company_id,id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_offline_sync_exception_sale
        FOREIGN KEY(company_id,sales_id)
        REFERENCES public.sales_headers(company_id,id) ON DELETE RESTRICT
);

CREATE INDEX idx_offline_sync_exception_submission
    ON public.pos_offline_sync_exceptions(
        company_id,submission_id,created_at
    );

CREATE TABLE public.offline_payment_exceptions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL,
    submission_id UUID NOT NULL,
    sales_id UUID NOT NULL,
    sales_payment_id UUID NOT NULL,
    payment_method_id UUID NOT NULL,
    client_payment_key UUID NOT NULL,
    amount_snapshot NUMERIC(20,4) NOT NULL,
    exception_status TEXT NOT NULL DEFAULT 'PENDING_VERIFICATION',
    reference_snapshot JSONB NOT NULL,
    created_by UUID NOT NULL
        REFERENCES public.profiles(id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT offline_payment_exception_company_id_id_unique
        UNIQUE(company_id,id),
    CONSTRAINT offline_payment_exception_payment_unique
        UNIQUE(company_id,sales_payment_id),
    CONSTRAINT offline_payment_exception_client_leg_unique
        UNIQUE(company_id,submission_id,client_payment_key),
    CONSTRAINT offline_payment_exception_amount_positive
        CHECK(amount_snapshot > 0),
    CONSTRAINT offline_payment_exception_status_check CHECK (
        exception_status IN (
            'PENDING_VERIFICATION','VERIFIED','FAILED','RESOLVED'
        )
    ),
    CONSTRAINT offline_payment_exception_reference_object
        CHECK(jsonb_typeof(reference_snapshot) = 'object'),
    CONSTRAINT fk_offline_payment_exception_submission
        FOREIGN KEY(company_id,submission_id)
        REFERENCES public.pos_offline_sale_submissions(company_id,id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_offline_payment_exception_sale
        FOREIGN KEY(company_id,sales_id)
        REFERENCES public.sales_headers(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_offline_payment_exception_payment
        FOREIGN KEY(company_id,sales_payment_id)
        REFERENCES public.sales_payments(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_offline_payment_exception_method
        FOREIGN KEY(company_id,payment_method_id)
        REFERENCES public.payment_methods(company_id,id) ON DELETE RESTRICT
);

CREATE INDEX idx_offline_payment_exception_status
    ON public.offline_payment_exceptions(
        company_id,exception_status,created_at
    );

CREATE TRIGGER g4_guard_offline_consumption_immutable
BEFORE UPDATE OR DELETE
ON public.pos_offline_sale_allowance_consumptions
FOR EACH ROW EXECUTE FUNCTION
    private.trg_g4_reject_offline_history_mutation();
CREATE TRIGGER g4_guard_offline_sync_exception_immutable
BEFORE UPDATE OR DELETE ON public.pos_offline_sync_exceptions
FOR EACH ROW EXECUTE FUNCTION
    private.trg_g4_reject_offline_history_mutation();
CREATE TRIGGER g4_guard_offline_payment_exception_immutable
BEFORE UPDATE OR DELETE ON public.offline_payment_exceptions
FOR EACH ROW EXECUTE FUNCTION
    private.trg_g4_reject_offline_history_mutation();

-- -------------------------------------------------------------------------
-- 3. Offline snapshot-aware price resolver
-- -------------------------------------------------------------------------

ALTER FUNCTION private.resolve_pos_sale_price(
    UUID,UUID,UUID,UUID,NUMERIC,TIMESTAMPTZ
) RENAME TO resolve_pos_sale_price_online_core;

CREATE FUNCTION private.resolve_pos_sale_price(
    p_company_id UUID,
    p_store_id UUID,
    p_customer_id UUID,
    p_product_uom_id UUID,
    p_quantity NUMERIC,
    p_resolved_at TIMESTAMPTZ
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_result JSONB;
    v_submission_raw TEXT :=
        NULLIF(current_setting('kgs.offline_submission_id',TRUE),'');
    v_submission_id UUID;
    v_snapshot_price NUMERIC(20,4);
    v_match_count BIGINT;
BEGIN
    v_result := private.resolve_pos_sale_price_online_core(
        p_company_id,p_store_id,p_customer_id,p_product_uom_id,
        p_quantity,p_resolved_at
    );
    IF v_submission_raw IS NULL THEN
        RETURN v_result;
    END IF;
    BEGIN
        v_submission_id := v_submission_raw::UUID;
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'INVALID_OFFLINE_PRICE_CONTEXT';
    END;

    SELECT
        count(*),
        min((line.value->>'snapshotUnitPrice')::NUMERIC)
    INTO v_match_count,v_snapshot_price
    FROM public.pos_offline_sale_submissions s
    CROSS JOIN LATERAL jsonb_array_elements(
        COALESCE(s.payload_snapshot->'lines','[]'::JSONB)
    ) line(value)
    WHERE s.company_id = p_company_id
      AND s.id = v_submission_id
      AND s.cashier_id = auth.uid()
      AND s.status = 'SYNCING'
      AND (line.value->>'productUomId')::UUID = p_product_uom_id;

    -- Bundle component valuation can resolve a component UOM that is not a
    -- commercial line. Only commercial lines are overridden.
    IF v_match_count = 0 THEN
        RETURN v_result;
    END IF;
    IF v_match_count <> 1
       OR v_snapshot_price IS NULL
       OR v_snapshot_price < 0 THEN
        RAISE EXCEPTION 'OFFLINE_PRICE_SNAPSHOT_INVALID';
    END IF;

    RETURN v_result
        || jsonb_build_object(
            'resolvedUnitPrice',v_snapshot_price,
            'pricingSelectionSource','OFFLINE_SNAPSHOT',
            'offlineSubmissionId',v_submission_id
        );
END;
$$;

-- -------------------------------------------------------------------------
-- 4. Submission lifecycle guard
-- -------------------------------------------------------------------------

CREATE FUNCTION private.trg_g4_guard_offline_submission_lifecycle()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
    IF NEW.company_id IS DISTINCT FROM OLD.company_id
       OR NEW.client_transaction_id IS DISTINCT FROM OLD.client_transaction_id
       OR NEW.posting_idempotency_key
            IS DISTINCT FROM OLD.posting_idempotency_key
       OR NEW.store_id IS DISTINCT FROM OLD.store_id
       OR NEW.warehouse_id IS DISTINCT FROM OLD.warehouse_id
       OR NEW.terminal_id IS DISTINCT FROM OLD.terminal_id
       OR NEW.cashier_session_id IS DISTINCT FROM OLD.cashier_session_id
       OR NEW.cashier_id IS DISTINCT FROM OLD.cashier_id
       OR NEW.local_master_version IS DISTINCT FROM OLD.local_master_version
       OR NEW.local_transaction_at IS DISTINCT FROM OLD.local_transaction_at
       OR NEW.payload_version IS DISTINCT FROM OLD.payload_version
       OR NEW.payload_snapshot IS DISTINCT FROM OLD.payload_snapshot
       OR NEW.payload_hash IS DISTINCT FROM OLD.payload_hash
       OR NEW.server_payload_hash IS DISTINCT FROM OLD.server_payload_hash
       OR NEW.received_at IS DISTINCT FROM OLD.received_at THEN
        RAISE EXCEPTION 'OFFLINE_SUBMISSION_IDENTITY_IMMUTABLE';
    END IF;
    IF OLD.status IN ('POSTED','INVALIDATED')
       AND NEW IS DISTINCT FROM OLD THEN
        RAISE EXCEPTION 'OFFLINE_SUBMISSION_TERMINAL_IMMUTABLE';
    END IF;
    IF NEW.status IS DISTINCT FROM OLD.status
       AND NOT (
           (OLD.status = 'QUEUED'
                AND NEW.status IN ('SYNCING','INVALIDATED'))
           OR (OLD.status IN ('FAILED','NEEDS_CONFIRMATION')
                AND NEW.status IN ('SYNCING','INVALIDATED'))
           OR (OLD.status = 'SYNCING'
                AND NEW.status IN (
                    'POSTED','FAILED','NEEDS_CONFIRMATION','INVALIDATED'
                ))
       ) THEN
        RAISE EXCEPTION 'OFFLINE_SUBMISSION_STATUS_TRANSITION_INVALID';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER g4_guard_offline_submission_lifecycle
BEFORE UPDATE ON public.pos_offline_sale_submissions
FOR EACH ROW EXECUTE FUNCTION
    private.trg_g4_guard_offline_submission_lifecycle();

-- -------------------------------------------------------------------------
-- 5. Guarded submit, process, and acknowledgement RPCs
-- -------------------------------------------------------------------------

CREATE FUNCTION public.submit_pos_offline_sale(p_envelope JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_actor UUID := auth.uid();
    v_company UUID := public.private_active_company_id();
    v_session public.cashier_sessions%ROWTYPE;
    v_submission public.pos_offline_sale_submissions%ROWTYPE;
    v_client_transaction_id UUID;
    v_posting_key UUID;
    v_session_id UUID;
    v_local_master_version BIGINT;
    v_payload_version BIGINT;
    v_local_transaction_at TIMESTAMPTZ;
    v_sale_payload JSONB;
    v_client_hash TEXT;
    v_server_hash TEXT;
    v_line JSONB;
    v_submission_id UUID;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF jsonb_typeof(p_envelope) IS DISTINCT FROM 'object' THEN
        RAISE EXCEPTION 'OFFLINE_ENVELOPE_OBJECT_REQUIRED';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM public.company_features cf
        WHERE cf.company_id = v_company
          AND cf.feature_code = 'offline_pos_enabled'
          AND cf.is_enabled
    ) THEN
        RAISE EXCEPTION 'OFFLINE_POS_FEATURE_DISABLED';
    END IF;
    BEGIN
        v_client_transaction_id :=
            (p_envelope->>'clientTransactionId')::UUID;
        v_posting_key := (p_envelope->>'postingIdempotencyKey')::UUID;
        v_session_id := (p_envelope->>'cashierSessionId')::UUID;
        v_local_master_version :=
            (p_envelope->>'localMasterVersion')::BIGINT;
        v_payload_version := COALESCE(
            (p_envelope->>'payloadVersion')::BIGINT,1
        );
        v_local_transaction_at :=
            (p_envelope->>'localTransactionAt')::TIMESTAMPTZ;
        v_sale_payload := p_envelope->'salePayload';
        v_client_hash := lower(btrim(p_envelope->>'payloadHash'));
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'INVALID_OFFLINE_ENVELOPE';
    END;
    IF v_client_transaction_id IS NULL
       OR v_posting_key IS NULL
       OR v_local_master_version IS NULL
       OR v_local_master_version <= 0
       OR v_payload_version <= 0
       OR v_local_transaction_at IS NULL
       OR v_local_transaction_at > clock_timestamp() + interval '5 minutes'
       OR jsonb_typeof(v_sale_payload) IS DISTINCT FROM 'object'
       OR v_client_hash !~ '^[0-9a-f]{64}$' THEN
        RAISE EXCEPTION 'INVALID_OFFLINE_ENVELOPE';
    END IF;
    IF (v_sale_payload->>'clientTransactionId')::UUID
            IS DISTINCT FROM v_client_transaction_id
       OR (v_sale_payload->>'cashierSessionId')::UUID
            IS DISTINCT FROM v_session_id
       OR NULLIF(v_sale_payload->>'saleId','') IS NOT NULL
       OR NULLIF(v_sale_payload->>'masterVersion','') IS NOT NULL THEN
        RAISE EXCEPTION 'OFFLINE_SALE_PAYLOAD_IDENTITY_INVALID';
    END IF;
    IF COALESCE((v_sale_payload->>'isTempo')::BOOLEAN,FALSE) THEN
        RAISE EXCEPTION 'OFFLINE_TEMPO_NOT_ENABLED';
    END IF;
    IF jsonb_typeof(v_sale_payload->'lines') IS DISTINCT FROM 'array'
       OR jsonb_array_length(v_sale_payload->'lines') = 0
       OR jsonb_array_length(v_sale_payload->'lines') > 200 THEN
        RAISE EXCEPTION 'SALE_LINES_ARRAY_REQUIRED';
    END IF;
    FOR v_line IN
        SELECT value FROM jsonb_array_elements(v_sale_payload->'lines')
    LOOP
        IF NULLIF(btrim(v_line->>'lineKey'),'') IS NULL
           OR NULLIF(v_line->>'productUomId','') IS NULL
           OR NULLIF(v_line->>'quantity','') IS NULL
           OR (v_line->>'quantity')::NUMERIC <= 0
           OR NULLIF(v_line->>'snapshotUnitPrice','') IS NULL
           OR (v_line->>'snapshotUnitPrice')::NUMERIC < 0 THEN
            RAISE EXCEPTION 'OFFLINE_LINE_SNAPSHOT_INVALID';
        END IF;
    END LOOP;
    IF EXISTS (
        SELECT 1
        FROM jsonb_array_elements(v_sale_payload->'lines') line(value)
        GROUP BY line.value->>'lineKey'
        HAVING count(*) > 1
    ) OR EXISTS (
        SELECT 1
        FROM jsonb_array_elements(v_sale_payload->'lines') line(value)
        GROUP BY line.value->>'productUomId'
        HAVING count(*) > 1
    ) THEN
        RAISE EXCEPTION 'OFFLINE_LINE_IDENTITY_DUPLICATE';
    END IF;

    v_server_hash := encode(
        extensions.digest(
            convert_to(v_sale_payload::TEXT,'UTF8'),'sha256'
        ),
        'hex'
    );
    IF v_client_hash <> v_server_hash THEN
        RAISE EXCEPTION 'OFFLINE_PAYLOAD_HASH_MISMATCH';
    END IF;

    SELECT * INTO v_session
    FROM public.cashier_sessions cs
    WHERE cs.company_id = v_company
      AND cs.id = v_session_id
      AND cs.cashier_id = v_actor
      AND cs.status = 'OPEN'::public.session_status
    FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'OPEN_CASHIER_SESSION_REQUIRED'; END IF;
    IF NOT EXISTS (
        SELECT 1 FROM public.pos_offline_allowance_policies p
        WHERE p.company_id = v_company
          AND p.scope_type = 'TERMINAL'
          AND p.store_id = v_session.store_id
          AND p.terminal_id = v_session.pos_id
          AND p.is_enabled
    ) THEN
        RAISE EXCEPTION 'OFFLINE_TERMINAL_NOT_ENABLED';
    END IF;

    PERFORM pg_advisory_xact_lock(hashtextextended(
        v_company::TEXT || ':OFFLINE_SUBMIT:'
            || v_client_transaction_id::TEXT,0
    ));
    SELECT * INTO v_submission
    FROM public.pos_offline_sale_submissions s
    WHERE s.company_id = v_company
      AND (
          s.client_transaction_id = v_client_transaction_id
          OR s.posting_idempotency_key = v_posting_key
      )
    FOR UPDATE;
    IF FOUND THEN
        IF v_submission.client_transaction_id
                IS DISTINCT FROM v_client_transaction_id
           OR v_submission.posting_idempotency_key
                IS DISTINCT FROM v_posting_key
           OR v_submission.payload_hash IS DISTINCT FROM v_client_hash
           OR v_submission.server_payload_hash
                IS DISTINCT FROM v_server_hash
           OR v_submission.payload_version
                IS DISTINCT FROM v_payload_version THEN
            RAISE EXCEPTION 'OFFLINE_SUBMISSION_IDEMPOTENCY_CONFLICT';
        END IF;
        RETURN jsonb_build_object(
            'submissionId',v_submission.id,
            'status',v_submission.status,
            'payloadHash',v_submission.payload_hash,
            'serverPayloadHash',v_submission.server_payload_hash,
            'acknowledgement',v_submission.acknowledgement,
            'errorCode',v_submission.error_code,
            'idempotentReplay',TRUE
        );
    END IF;

    INSERT INTO public.pos_offline_sale_submissions(
        company_id,client_transaction_id,posting_idempotency_key,
        store_id,warehouse_id,terminal_id,cashier_session_id,cashier_id,
        local_master_version,local_transaction_at,payload_snapshot,
        payload_hash,payload_version,server_payload_hash
    ) VALUES (
        v_company,v_client_transaction_id,v_posting_key,
        v_session.store_id,v_session.sales_warehouse_id,v_session.pos_id,
        v_session.id,v_actor,v_local_master_version,
        v_local_transaction_at,v_sale_payload,v_client_hash,
        v_payload_version,v_server_hash
    )
    RETURNING id INTO v_submission_id;

    INSERT INTO public.pos_offline_sale_submission_events(
        company_id,submission_id,event_type,actor_id,after_state
    ) VALUES (
        v_company,v_submission_id,'RECEIVED',v_actor,
        jsonb_build_object(
            'status','QUEUED','payloadVersion',v_payload_version,
            'payloadHash',v_client_hash,
            'serverPayloadHash',v_server_hash
        )
    );

    RETURN jsonb_build_object(
        'submissionId',v_submission_id,'status','QUEUED',
        'payloadHash',v_client_hash,'serverPayloadHash',v_server_hash,
        'idempotentReplay',FALSE
    );
EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION 'OFFLINE_SUBMISSION_IDEMPOTENCY_CONFLICT';
END;
$$;

CREATE FUNCTION public.process_pos_offline_sale_submission(
    p_submission_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_actor UUID := auth.uid();
    v_company UUID := public.private_active_company_id();
    v_submission public.pos_offline_sale_submissions%ROWTYPE;
    v_sale_payload JSONB;
    v_post_payload JSONB;
    v_draft_result JSONB;
    v_post_result JSONB;
    v_sale_id UUID;
    v_sale_version BIGINT;
    v_online_prices JSONB;
    v_requirement RECORD;
    v_allowance public.pos_offline_stock_allowances%ROWTYPE;
    v_before JSONB;
    v_after JSONB;
    v_remaining NUMERIC(24,6);
    v_variance_total NUMERIC(20,4);
    v_variance_lines BIGINT;
    v_error_code TEXT;
    v_error_detail TEXT;
    v_now TIMESTAMPTZ := clock_timestamp();
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF NOT EXISTS (
        SELECT 1 FROM public.company_features cf
        WHERE cf.company_id = v_company
          AND cf.feature_code = 'offline_pos_enabled'
          AND cf.is_enabled
    ) THEN
        RAISE EXCEPTION 'OFFLINE_POS_FEATURE_DISABLED';
    END IF;

    SELECT * INTO v_submission
    FROM public.pos_offline_sale_submissions s
    WHERE s.company_id = v_company AND s.id = p_submission_id
    FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'OFFLINE_SUBMISSION_NOT_FOUND'; END IF;
    IF v_submission.cashier_id IS DISTINCT FROM v_actor THEN
        RAISE EXCEPTION 'OFFLINE_SUBMISSION_CASHIER_REQUIRED';
    END IF;
    IF v_submission.status = 'POSTED' THEN
        RETURN v_submission.acknowledgement
            || jsonb_build_object('idempotentReplay',TRUE);
    END IF;
    IF v_submission.status = 'INVALIDATED' THEN
        RAISE EXCEPTION 'OFFLINE_SUBMISSION_INVALIDATED';
    END IF;
    IF v_submission.status NOT IN (
        'QUEUED','FAILED','NEEDS_CONFIRMATION'
    ) THEN
        RAISE EXCEPTION 'OFFLINE_SUBMISSION_ALREADY_SYNCING';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM public.cashier_sessions cs
        WHERE cs.company_id = v_company
          AND cs.id = v_submission.cashier_session_id
          AND cs.cashier_id = v_actor
          AND cs.store_id = v_submission.store_id
          AND cs.pos_id = v_submission.terminal_id
          AND cs.sales_warehouse_id = v_submission.warehouse_id
          AND cs.status = 'OPEN'::public.session_status
    ) THEN
        RAISE EXCEPTION 'OPEN_CASHIER_SESSION_REQUIRED';
    END IF;

    UPDATE public.pos_offline_sale_submissions
    SET status = 'SYNCING',
        processing_attempts = processing_attempts + 1,
        last_attempt_at = v_now,
        error_code = NULL,
        error_message = NULL,
        processed_at = NULL,
        updated_at = v_now
    WHERE company_id = v_company AND id = p_submission_id;
    INSERT INTO public.pos_offline_sale_submission_events(
        company_id,submission_id,event_type,actor_id,
        before_state,after_state
    ) VALUES (
        v_company,p_submission_id,
        CASE WHEN v_submission.processing_attempts = 0
            THEN 'SYNC_STARTED' ELSE 'RETRY' END,
        v_actor,
        jsonb_build_object(
            'status',v_submission.status,
            'attempts',v_submission.processing_attempts
        ),
        jsonb_build_object(
            'status','SYNCING',
            'attempts',v_submission.processing_attempts + 1
        )
    );

    BEGIN
        v_sale_payload := v_submission.payload_snapshot;

        -- The online Post contract can require a proof URL. Offline electronic
        -- proof may be added after reconnect, so an internal transaction-only
        -- HTTPS marker satisfies validation and is removed before commit.
        SELECT jsonb_set(
            v_sale_payload,
            '{payments}',
            COALESCE(jsonb_agg(
                CASE
                    WHEN pm.proof_mode = 'REQUIRED'
                     AND NULLIF(btrim(pay.value->>'proofUrl'),'') IS NULL
                    THEN pay.value || jsonb_build_object(
                        'proofUrl',
                        'https://offline.pending.invalid/'
                            || (pay.value->>'clientPaymentKey')
                    )
                    ELSE pay.value
                END
                ORDER BY pay.ordinality
            ),'[]'::JSONB),
            TRUE
        )
        INTO v_post_payload
        FROM jsonb_array_elements(
            COALESCE(v_sale_payload->'payments','[]'::JSONB)
        ) WITH ORDINALITY pay(value,ordinality)
        LEFT JOIN public.payment_methods pm
          ON pm.company_id = v_company
         AND pm.id = (pay.value->>'paymentMethodId')::UUID;

        v_draft_result :=
            public.save_pos_sale_draft_with_pricelist(v_post_payload);
        v_sale_id := (v_draft_result->>'salesId')::UUID;
        v_sale_version := (v_draft_result->>'masterVersion')::BIGINT;

        SELECT COALESCE(
            jsonb_object_agg(
                sd.client_line_key,to_jsonb(sd.resolved_unit_price)
            ),
            '{}'::JSONB
        )
        INTO v_online_prices
        FROM public.sales_details sd
        WHERE sd.company_id = v_company AND sd.sales_id = v_sale_id;

        UPDATE public.sales_headers
        SET source_channel = 'OFFLINE',
            offline_submission_id = p_submission_id,
            offline_transaction_at = v_submission.local_transaction_at,
            offline_price_variance_total = 0
        WHERE company_id = v_company AND id = v_sale_id;

        FOR v_requirement IN
            SELECT
                r.stock_product_id AS product_id,
                p.uom_id AS base_uom_id,
                sum(r.quantity_base) AS required_base_qty
            FROM public.sale_stock_requirements r
            JOIN public.products p
              ON p.company_id = r.company_id
             AND p.id = r.stock_product_id
            WHERE r.company_id = v_company AND r.sales_id = v_sale_id
            GROUP BY r.stock_product_id,p.uom_id
            ORDER BY r.stock_product_id
        LOOP
            SELECT * INTO v_allowance
            FROM public.pos_offline_stock_allowances a
            WHERE a.company_id = v_company
              AND a.cashier_session_id =
                    v_submission.cashier_session_id
              AND a.product_id = v_requirement.product_id
              AND a.warehouse_id = v_submission.warehouse_id
              AND a.status = 'ACTIVE'
            FOR UPDATE;
            IF NOT FOUND THEN
                RAISE EXCEPTION 'OFFLINE_ALLOWANCE_REQUIRED';
            END IF;
            v_remaining := v_allowance.allocated_base_qty
                - v_allowance.consumed_base_qty;
            IF v_remaining < v_requirement.required_base_qty THEN
                RAISE EXCEPTION 'OFFLINE_ALLOWANCE_INSUFFICIENT';
            END IF;

            INSERT INTO public.pos_offline_sale_allowance_consumptions(
                company_id,submission_id,allowance_id,sales_id,
                product_id,base_uom_id,consumed_base_qty,
                allowance_before_base_qty,allowance_after_base_qty,
                created_by
            ) VALUES (
                v_company,p_submission_id,v_allowance.id,v_sale_id,
                v_requirement.product_id,v_requirement.base_uom_id,
                v_requirement.required_base_qty,v_remaining,
                v_remaining - v_requirement.required_base_qty,v_actor
            );

            v_before := to_jsonb(v_allowance);
            UPDATE public.pos_offline_stock_allowances
            SET consumed_base_qty = consumed_base_qty
                    + v_requirement.required_base_qty,
                status = CASE
                    WHEN consumed_base_qty
                            + v_requirement.required_base_qty
                         = allocated_base_qty
                    THEN 'CONSUMED' ELSE 'ACTIVE' END,
                updated_by = v_actor
            WHERE company_id = v_company AND id = v_allowance.id;
            SELECT to_jsonb(a) INTO v_after
            FROM public.pos_offline_stock_allowances a
            WHERE a.company_id = v_company AND a.id = v_allowance.id;
            INSERT INTO public.pos_offline_stock_allowance_audit(
                company_id,allowance_id,action,actor_id,
                before_state,after_state
            ) VALUES (
                v_company,v_allowance.id,'CONSUME',v_actor,
                v_before,v_after
            );
        END LOOP;

        PERFORM set_config(
            'kgs.offline_submission_id',p_submission_id::TEXT,TRUE
        );
        v_post_result := public.post_pos_sale_with_pricelist(
            v_sale_id,v_sale_version,
            v_submission.posting_idempotency_key
        );
        IF v_post_result->>'documentStatus' <> 'POSTED' THEN
            RAISE EXCEPTION 'OFFLINE_POST_NOT_FINAL';
        END IF;

        UPDATE public.sales_details sd
        SET offline_snapshot_unit_price =
                (line.value->>'snapshotUnitPrice')::NUMERIC,
            offline_resolved_unit_price =
                (v_online_prices->>sd.client_line_key)::NUMERIC,
            offline_price_variance =
                (line.value->>'snapshotUnitPrice')::NUMERIC
                - (v_online_prices->>sd.client_line_key)::NUMERIC
        FROM jsonb_array_elements(v_sale_payload->'lines') line(value)
        WHERE sd.company_id = v_company
          AND sd.sales_id = v_sale_id
          AND line.value->>'lineKey' = sd.client_line_key;

        IF EXISTS (
            SELECT 1 FROM public.sales_details sd
            WHERE sd.company_id = v_company
              AND sd.sales_id = v_sale_id
              AND (
                  sd.offline_snapshot_unit_price IS NULL
                  OR sd.offline_resolved_unit_price IS NULL
                  OR sd.offline_price_variance IS NULL
              )
        ) THEN
            RAISE EXCEPTION 'OFFLINE_PRICE_SNAPSHOT_MAPPING_FAILED';
        END IF;

        SELECT
            COALESCE(sum(offline_price_variance * qty),0),
            count(*) FILTER (WHERE offline_price_variance <> 0)
        INTO v_variance_total,v_variance_lines
        FROM public.sales_details
        WHERE company_id = v_company AND sales_id = v_sale_id;

        UPDATE public.sales_payments sp
        SET proof_url = NULLIF(
                btrim(reference.value->>'proofUrl'),''
            ),
            offline_reference_snapshot = reference.value,
            offline_verification_status = CASE
                WHEN sp.payment_method_type_snapshot = 'CASH'
                THEN 'VERIFIED'
                ELSE 'PENDING_VERIFICATION'
            END
        FROM jsonb_array_elements(
            COALESCE(v_sale_payload->'payments','[]'::JSONB)
        ) reference(value)
        WHERE sp.company_id = v_company
          AND sp.sales_id = v_sale_id
          AND sp.client_payment_key =
                (reference.value->>'clientPaymentKey')::UUID;

        IF EXISTS (
            SELECT 1 FROM public.sales_payments sp
            WHERE sp.company_id = v_company
              AND sp.sales_id = v_sale_id
              AND (
                  sp.offline_verification_status IS NULL
                  OR sp.offline_reference_snapshot IS NULL
              )
        ) THEN
            RAISE EXCEPTION 'OFFLINE_PAYMENT_SNAPSHOT_MAPPING_FAILED';
        END IF;

        INSERT INTO public.offline_payment_exceptions(
            company_id,submission_id,sales_id,sales_payment_id,
            payment_method_id,client_payment_key,amount_snapshot,
            reference_snapshot,created_by
        )
        SELECT
            v_company,p_submission_id,v_sale_id,sp.id,
            sp.payment_method_id,sp.client_payment_key,sp.amount,
            sp.offline_reference_snapshot,v_actor
        FROM public.sales_payments sp
        WHERE sp.company_id = v_company
          AND sp.sales_id = v_sale_id
          AND sp.offline_verification_status = 'PENDING_VERIFICATION';

        IF v_variance_lines > 0 THEN
            INSERT INTO public.pos_offline_sync_exceptions(
                company_id,submission_id,sales_id,exception_type,
                error_code,details,actor_id
            ) VALUES (
                v_company,p_submission_id,v_sale_id,'PRICE_VARIANCE',
                'OFFLINE_PRICE_VARIANCE',
                jsonb_build_object(
                    'lineCount',v_variance_lines,
                    'varianceTotal',v_variance_total,
                    'accountingImpact',FALSE
                ),
                v_actor
            );
        END IF;

        UPDATE public.sales_headers sh
        SET payload_snapshot = v_sale_payload || jsonb_build_object(
                'sourceChannel','OFFLINE',
                'offlineSubmissionId',p_submission_id,
                'offlineTransactionAt',
                    v_submission.local_transaction_at,
                'serverProcessedAt',v_now
            ),
            offline_price_variance_total = v_variance_total,
            receipt_snapshot = sh.receipt_snapshot
                || jsonb_build_object(
                    'sourceChannel','OFFLINE',
                    'offlineSubmissionId',p_submission_id,
                    'offlineTransactionAt',
                        v_submission.local_transaction_at,
                    'offlinePriceVarianceTotal',v_variance_total,
                    'payments',(
                        SELECT COALESCE(jsonb_agg(jsonb_build_object(
                            'clientPaymentKey',sp.client_payment_key,
                            'paymentMethodName',
                                sp.payment_method_name_snapshot,
                            'paymentMethodType',
                                sp.payment_method_type_snapshot,
                            'amount',sp.amount,
                            'configuredFee',sp.configured_fee_amount,
                            'customerSurcharge',
                                sp.customer_surcharge_amount,
                            'tenderedAmount',sp.tendered_amount,
                            'changeAmount',sp.change_amount,
                            'proofUrl',sp.proof_url,
                            'verificationStatus',
                                sp.offline_verification_status
                        ) ORDER BY sp.payment_no),'[]'::JSONB)
                        FROM public.sales_payments sp
                        WHERE sp.company_id = v_company
                          AND sp.sales_id = v_sale_id
                          AND NOT sp.is_reversal
                    )
                )
        WHERE sh.company_id = v_company AND sh.id = v_sale_id;

    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS
            v_error_detail = MESSAGE_TEXT;
        v_error_code := CASE
            WHEN v_error_detail ~ '^[A-Z][A-Z0-9_]+$'
                THEN v_error_detail
            ELSE 'OFFLINE_SYNC_PROCESSING_FAILED'
        END;
        UPDATE public.pos_offline_sale_submissions
        SET status = 'FAILED',
            error_code = v_error_code,
            error_message = v_error_code,
            processed_at = clock_timestamp(),
            updated_at = clock_timestamp()
        WHERE company_id = v_company AND id = p_submission_id;
        INSERT INTO public.pos_offline_sale_submission_events(
            company_id,submission_id,event_type,actor_id,
            before_state,after_state
        ) VALUES (
            v_company,p_submission_id,'FAILED',v_actor,
            jsonb_build_object('status','SYNCING'),
            jsonb_build_object(
                'status','FAILED','errorCode',v_error_code
            )
        );
        INSERT INTO public.pos_offline_sync_exceptions(
            company_id,submission_id,exception_type,
            error_code,details,actor_id
        ) VALUES (
            v_company,p_submission_id,'PROCESSING_FAILURE',
            v_error_code,
            jsonb_build_object(
                'attemptedAt',clock_timestamp(),
                'finalEffectWritten',FALSE
            ),
            v_actor
        );
        RETURN jsonb_build_object(
            'submissionId',p_submission_id,'status','FAILED',
            'errorCode',v_error_code,'retryable',TRUE,
            'idempotentReplay',FALSE
        );
    END;

    UPDATE public.pos_offline_sale_submissions
    SET status = 'POSTED',
        sales_id = v_sale_id,
        acknowledgement = jsonb_build_object(
            'submissionId',p_submission_id,
            'clientTransactionId',
                v_submission.client_transaction_id,
            'salesId',v_sale_id,
            'invoiceNo',v_post_result->>'invoiceNo',
            'documentStatus','POSTED',
            'postedAt',clock_timestamp(),
            'offlineTransactionAt',v_submission.local_transaction_at,
            'payloadVersion',v_submission.payload_version,
            'payloadHash',v_submission.payload_hash,
            'serverPayloadHash',v_submission.server_payload_hash,
            'priceVarianceTotal',v_variance_total,
            'paymentVerificationPending',EXISTS (
                SELECT 1 FROM public.sales_payments sp
                WHERE sp.company_id = v_company
                  AND sp.sales_id = v_sale_id
                  AND sp.offline_verification_status =
                        'PENDING_VERIFICATION'
            )
        ),
        error_code = NULL,
        error_message = NULL,
        processed_at = clock_timestamp(),
        updated_at = clock_timestamp()
    WHERE company_id = v_company AND id = p_submission_id
    RETURNING acknowledgement INTO v_post_result;

    INSERT INTO public.pos_offline_sale_submission_events(
        company_id,submission_id,event_type,actor_id,
        before_state,after_state
    ) VALUES (
        v_company,p_submission_id,'POSTED',v_actor,
        jsonb_build_object('status','SYNCING'),
        v_post_result
    );

    RETURN v_post_result || jsonb_build_object(
        'status','POSTED','idempotentReplay',FALSE
    );
END;
$$;

CREATE FUNCTION public.get_pos_offline_submission_status(
    p_client_transaction_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_actor UUID := auth.uid();
    v_company UUID := public.private_active_company_id();
    v_submission public.pos_offline_sale_submissions%ROWTYPE;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    SELECT * INTO v_submission
    FROM public.pos_offline_sale_submissions s
    WHERE s.company_id = v_company
      AND s.client_transaction_id = p_client_transaction_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'OFFLINE_SUBMISSION_NOT_FOUND'; END IF;
    IF NOT (
        v_submission.cashier_id = v_actor
        OR public.private_user_has_any_company_role(
            v_company,ARRAY['COMPANY_OWNER','COMPANY_ADMIN']::TEXT[]
        )
        OR public.private_user_has_any_store_role(
            v_submission.store_id,ARRAY['STORE_MANAGER']::TEXT[]
        )
    ) THEN
        RAISE EXCEPTION 'OFFLINE_SUBMISSION_ACCESS_DENIED';
    END IF;
    RETURN jsonb_build_object(
        'submissionId',v_submission.id,
        'clientTransactionId',v_submission.client_transaction_id,
        'status',v_submission.status,
        'processingAttempts',v_submission.processing_attempts,
        'receivedAt',v_submission.received_at,
        'lastAttemptAt',v_submission.last_attempt_at,
        'processedAt',v_submission.processed_at,
        'acknowledgement',v_submission.acknowledgement,
        'errorCode',v_submission.error_code,
        'retryable',v_submission.status IN (
            'QUEUED','FAILED','NEEDS_CONFIRMATION'
        )
    );
END;
$$;

-- Finance catalog entry only. Verification resolution and posting remain a
-- later Finance/POS gate.
INSERT INTO public.system_events(
    system_key,event_group,event_name,required_account_functions,
    conditional_account_functions,optional_account_functions
)
SELECT
    'OFFLINE_PAYMENT_EXCEPTION','SALES',
    'Pengecualian Pembayaran Offline',
    ARRAY['OFFLINE_PAYMENT_RECEIVABLE']::TEXT[],
    ARRAY['CASH_DRAWER','BANK','PAYMENT_CLEARING']::TEXT[],
    ARRAY[]::TEXT[]
WHERE NOT EXISTS (
    SELECT 1 FROM public.system_events
    WHERE system_key = 'OFFLINE_PAYMENT_EXCEPTION'
);

-- -------------------------------------------------------------------------
-- 6. RLS and exact browser boundary
-- -------------------------------------------------------------------------

ALTER TABLE public.pos_offline_sale_allowance_consumptions
    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pos_offline_sync_exceptions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.offline_payment_exceptions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "POS operators read scoped Offline consumptions"
ON public.pos_offline_sale_allowance_consumptions
FOR SELECT TO authenticated
USING (
    public.private_request_company_matches(company_id)
    AND EXISTS (
        SELECT 1 FROM public.pos_offline_sale_submissions s
        WHERE s.company_id =
                pos_offline_sale_allowance_consumptions.company_id
          AND s.id =
                pos_offline_sale_allowance_consumptions.submission_id
          AND (
              s.cashier_id = auth.uid()
              OR public.private_user_has_any_company_role(
                  s.company_id,
                  ARRAY['COMPANY_OWNER','COMPANY_ADMIN']::TEXT[]
              )
              OR public.private_user_has_any_store_role(
                  s.store_id,ARRAY['STORE_MANAGER']::TEXT[]
              )
          )
    )
);

CREATE POLICY "POS managers read scoped Offline sync exceptions"
ON public.pos_offline_sync_exceptions
FOR SELECT TO authenticated
USING (
    public.private_request_company_matches(company_id)
    AND EXISTS (
        SELECT 1 FROM public.pos_offline_sale_submissions s
        WHERE s.company_id = pos_offline_sync_exceptions.company_id
          AND s.id = pos_offline_sync_exceptions.submission_id
          AND (
              s.cashier_id = auth.uid()
              OR public.private_user_has_any_company_role(
                  s.company_id,
                  ARRAY['COMPANY_OWNER','COMPANY_ADMIN']::TEXT[]
              )
              OR public.private_user_has_any_store_role(
                  s.store_id,ARRAY['STORE_MANAGER']::TEXT[]
              )
          )
    )
);

CREATE POLICY "Finance and POS managers read Offline payment exceptions"
ON public.offline_payment_exceptions
FOR SELECT TO authenticated
USING (
    public.private_request_company_matches(company_id)
    AND EXISTS (
        SELECT 1 FROM public.pos_offline_sale_submissions s
        WHERE s.company_id = offline_payment_exceptions.company_id
          AND s.id = offline_payment_exceptions.submission_id
          AND (
              public.private_user_has_any_company_role(
                  s.company_id,
                  ARRAY[
                      'COMPANY_OWNER','COMPANY_ADMIN',
                      'FINANCE','ACCOUNTING'
                  ]::TEXT[]
              )
              OR public.private_user_has_any_store_role(
                  s.store_id,ARRAY['STORE_MANAGER']::TEXT[]
              )
          )
    )
);

REVOKE ALL ON
    public.pos_offline_sale_allowance_consumptions,
    public.pos_offline_sync_exceptions,
    public.offline_payment_exceptions
FROM PUBLIC,anon,authenticated;
GRANT SELECT ON
    public.pos_offline_sale_allowance_consumptions,
    public.pos_offline_sync_exceptions,
    public.offline_payment_exceptions
TO authenticated;
GRANT ALL ON
    public.pos_offline_sale_allowance_consumptions,
    public.pos_offline_sync_exceptions,
    public.offline_payment_exceptions
TO service_role;

REVOKE ALL ON FUNCTION
    private.resolve_pos_sale_price_online_core(
        UUID,UUID,UUID,UUID,NUMERIC,TIMESTAMPTZ
    ),
    private.resolve_pos_sale_price(
        UUID,UUID,UUID,UUID,NUMERIC,TIMESTAMPTZ
    ),
    private.trg_g4_guard_offline_submission_lifecycle()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
    private.resolve_pos_sale_price_online_core(
        UUID,UUID,UUID,UUID,NUMERIC,TIMESTAMPTZ
    ),
    private.resolve_pos_sale_price(
        UUID,UUID,UUID,UUID,NUMERIC,TIMESTAMPTZ
    ),
    private.trg_g4_guard_offline_submission_lifecycle()
TO service_role;

REVOKE ALL ON FUNCTION public.submit_pos_offline_sale(JSONB)
FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION
    public.process_pos_offline_sale_submission(UUID)
FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION
    public.get_pos_offline_submission_status(UUID)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.submit_pos_offline_sale(JSONB)
TO authenticated,service_role;
GRANT EXECUTE ON FUNCTION
    public.process_pos_offline_sale_submission(UUID)
TO authenticated,service_role;
GRANT EXECUTE ON FUNCTION
    public.get_pos_offline_submission_status(UUID)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES (
    '20260729210000',
    'g4_phase12_offline_sale_sync',
    'POS-004 guarded hash/version submission, canonical Draft/Post sync, atomic allowance consumption, Offline price/payment snapshots, acknowledgement, and append-only exceptions; PWA remains closed'
);

COMMIT;
