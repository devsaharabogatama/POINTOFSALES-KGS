-- KGS POS G4 phase 8: canonical payment-leg identity and validation.
-- Dependency: G4 Sale Draft edit-lock through 20260729120000.
--
-- COMPATIBILITY:
-- - existing public Draft/Post signatures remain unchanged;
-- - legacy/internal inserts receive a generated payment-leg key;
-- - canonical clients may supply a stable clientPaymentKey;
-- - pricing, fee, stock, FIFO, Sale, and Finance calculations are unchanged.

BEGIN;

DO $migration_guard$
BEGIN
    IF to_regclass('private.kgs_schema_migrations') IS NULL
       OR NOT EXISTS (
           SELECT 1 FROM private.kgs_schema_migrations
           WHERE version = '20260729120000'
       ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: G4 phase 6 dependency missing';
    END IF;
    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260729150000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260729150000';
    END IF;
END
$migration_guard$;

ALTER TABLE public.sales_payments
    ADD COLUMN client_payment_key UUID
        NOT NULL DEFAULT gen_random_uuid();

CREATE UNIQUE INDEX uq_sales_payments_company_sale_client_key
    ON public.sales_payments(
        company_id,sales_id,client_payment_key
    );

CREATE FUNCTION private.trg_g4_normalize_sale_payment_legs()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_payment JSONB;
    v_normalized JSONB := '[]'::JSONB;
    v_client_key UUID;
    v_method_id UUID;
    v_client_keys UUID[] := ARRAY[]::UUID[];
    v_method_ids UUID[] := ARRAY[]::UUID[];
BEGIN
    IF NEW.payload_snapshot IS NULL
       OR NOT (NEW.payload_snapshot ? 'payments') THEN
        RETURN NEW;
    END IF;
    IF jsonb_typeof(NEW.payload_snapshot->'payments') <> 'array' THEN
        RAISE EXCEPTION 'INVALID_PAYMENT_INTENT';
    END IF;

    FOR v_payment IN
        SELECT value
        FROM jsonb_array_elements(NEW.payload_snapshot->'payments')
    LOOP
        BEGIN
            v_client_key := COALESCE(
                NULLIF(v_payment->>'clientPaymentKey','')::UUID,
                gen_random_uuid()
            );
            v_method_id := (v_payment->>'paymentMethodId')::UUID;
        EXCEPTION WHEN OTHERS THEN
            RAISE EXCEPTION 'INVALID_PAYMENT_LEG_IDENTITY';
        END;
        IF v_method_id IS NULL THEN
            RAISE EXCEPTION 'INVALID_PAYMENT_LEG_IDENTITY';
        END IF;
        IF v_client_key = ANY(v_client_keys) THEN
            RAISE EXCEPTION 'DUPLICATE_PAYMENT_LEG_KEY';
        END IF;
        IF v_method_id = ANY(v_method_ids) THEN
            RAISE EXCEPTION 'DUPLICATE_PAYMENT_METHOD';
        END IF;
        v_client_keys := array_append(v_client_keys,v_client_key);
        v_method_ids := array_append(v_method_ids,v_method_id);
        v_normalized := v_normalized || jsonb_build_array(
            jsonb_set(
                v_payment,
                '{clientPaymentKey}',
                to_jsonb(v_client_key::TEXT),
                TRUE
            )
        );
    END LOOP;

    NEW.payload_snapshot := jsonb_set(
        NEW.payload_snapshot,'{payments}',v_normalized,TRUE
    );
    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION private.trg_g4_normalize_sale_payment_legs()
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.trg_g4_normalize_sale_payment_legs()
TO service_role;

CREATE TRIGGER g4_normalize_sale_payment_legs
BEFORE INSERT OR UPDATE OF payload_snapshot ON public.sales_headers
FOR EACH ROW EXECUTE FUNCTION private.trg_g4_normalize_sale_payment_legs();

-- Technical backfill for existing payloads. This does not alter amount,
-- method, price, stock, master_version, or document lifecycle.
UPDATE public.sales_headers
SET payload_snapshot = payload_snapshot
WHERE jsonb_typeof(payload_snapshot->'payments') = 'array';

WITH payload_legs AS (
    SELECT
        sh.company_id,
        sh.id AS sales_id,
        payment.ordinality,
        (payment.value->>'clientPaymentKey')::UUID AS client_payment_key
    FROM public.sales_headers sh
    CROSS JOIN LATERAL jsonb_array_elements(
        sh.payload_snapshot->'payments'
    ) WITH ORDINALITY AS payment(value,ordinality)
    WHERE sh.document_status = 'POSTED'
), payment_rows AS (
    SELECT
        sp.id,
        sp.company_id,
        sp.sales_id,
        row_number() OVER (
            PARTITION BY sp.company_id,sp.sales_id
            ORDER BY sp.payment_no
        ) AS ordinality
    FROM public.sales_payments sp
    WHERE NOT sp.is_reversal
)
UPDATE public.sales_payments sp
SET client_payment_key = pl.client_payment_key
FROM payload_legs pl
JOIN payment_rows pr
  ON pr.company_id = pl.company_id
 AND pr.sales_id = pl.sales_id
 AND pr.ordinality = pl.ordinality
WHERE sp.id = pr.id;

UPDATE public.sales_headers sh
SET receipt_snapshot = jsonb_set(
    sh.receipt_snapshot,
    '{payments}',
    COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
            'clientPaymentKey',sp.client_payment_key,
            'paymentMethodName',sp.payment_method_name_snapshot,
            'paymentMethodType',sp.payment_method_type_snapshot,
            'amount',sp.amount,
            'configuredFee',sp.configured_fee_amount,
            'customerSurcharge',sp.customer_surcharge_amount,
            'tenderedAmount',sp.tendered_amount,
            'changeAmount',sp.change_amount,
            'proofUrl',sp.proof_url
        ) ORDER BY sp.payment_no)
        FROM public.sales_payments sp
        WHERE sp.company_id = sh.company_id
          AND sp.sales_id = sh.id
          AND NOT sp.is_reversal
    ),'[]'::JSONB),
    TRUE
)
WHERE sh.document_status = 'POSTED'
  AND sh.receipt_snapshot IS NOT NULL;

CREATE OR REPLACE FUNCTION public.post_pos_sale(
    p_sales_id UUID,
    p_master_version BIGINT,
    p_posting_idempotency_key UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_actor UUID := auth.uid();
    v_company UUID := public.private_active_company_id();
    v_sale public.sales_headers%ROWTYPE;
    v_result JSONB;
    v_expected_legs BIGINT;
    v_mapped_legs BIGINT;
BEGIN
    SELECT * INTO v_sale
    FROM public.sales_headers sh
    WHERE sh.company_id = v_company AND sh.id = p_sales_id
    FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'SALE_DRAFT_NOT_FOUND'; END IF;

    IF v_sale.document_status = 'DRAFT'
       AND (
           v_sale.edit_lock_owner_id IS DISTINCT FROM v_actor
           OR v_sale.edit_lock_session_id IS DISTINCT FROM v_sale.session_id
           OR v_sale.edit_lock_heartbeat_at IS NULL
           OR v_sale.edit_lock_heartbeat_at <
                clock_timestamp() - interval '5 minutes'
       ) THEN
        RAISE EXCEPTION 'SALE_DRAFT_EDIT_LOCK_REQUIRED';
    END IF;

    v_result := private.post_pos_sale_core(
        p_sales_id,p_master_version,p_posting_idempotency_key
    );

    IF v_result->>'documentStatus' = 'POSTED' THEN
        v_expected_legs := COALESCE(
            jsonb_array_length(v_sale.payload_snapshot->'payments'),0
        );
        WITH payload_legs AS (
            SELECT
                ordinality,
                (value->>'clientPaymentKey')::UUID AS client_payment_key
            FROM jsonb_array_elements(
                COALESCE(v_sale.payload_snapshot->'payments','[]'::JSONB)
            ) WITH ORDINALITY
        ), payment_rows AS (
            SELECT
                sp.id,
                row_number() OVER (ORDER BY sp.payment_no) AS ordinality
            FROM public.sales_payments sp
            WHERE sp.company_id = v_company
              AND sp.sales_id = p_sales_id
              AND NOT sp.is_reversal
        ), mapped AS (
            UPDATE public.sales_payments sp
            SET client_payment_key = pl.client_payment_key
            FROM payload_legs pl
            JOIN payment_rows pr ON pr.ordinality = pl.ordinality
            WHERE sp.id = pr.id
            RETURNING sp.id
        )
        SELECT count(*) INTO v_mapped_legs FROM mapped;

        IF v_mapped_legs <> v_expected_legs THEN
            RAISE EXCEPTION 'PAYMENT_LEG_IDENTITY_MAPPING_FAILED';
        END IF;

        UPDATE public.sales_headers sh
        SET receipt_snapshot = jsonb_set(
            sh.receipt_snapshot,
            '{payments}',
            COALESCE((
                SELECT jsonb_agg(jsonb_build_object(
                    'clientPaymentKey',sp.client_payment_key,
                    'paymentMethodName',sp.payment_method_name_snapshot,
                    'paymentMethodType',sp.payment_method_type_snapshot,
                    'amount',sp.amount,
                    'configuredFee',sp.configured_fee_amount,
                    'customerSurcharge',sp.customer_surcharge_amount,
                    'tenderedAmount',sp.tendered_amount,
                    'changeAmount',sp.change_amount,
                    'proofUrl',sp.proof_url
                ) ORDER BY sp.payment_no)
                FROM public.sales_payments sp
                WHERE sp.company_id = v_company
                  AND sp.sales_id = p_sales_id
                  AND NOT sp.is_reversal
            ),'[]'::JSONB),
            TRUE
        ),
        edit_lock_owner_id = NULL,
        edit_lock_session_id = NULL,
        edit_lock_acquired_at = NULL,
        edit_lock_heartbeat_at = NULL
        WHERE sh.company_id = v_company AND sh.id = p_sales_id;
    END IF;
    RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.post_pos_sale(UUID,BIGINT,UUID)
FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.post_pos_sale(UUID,BIGINT,UUID)
TO authenticated, service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES (
    '20260729150000',
    'g4_phase8_payment_leg_identity',
    'Stable client payment-leg key, duplicate method/key guard, technical Draft payload normalization, and receipt/payment traceability'
);

COMMIT;
