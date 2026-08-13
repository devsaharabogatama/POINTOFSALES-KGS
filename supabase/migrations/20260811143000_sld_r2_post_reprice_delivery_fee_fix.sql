-- SLD-R2 forward fix: preserve delivery fee during mandatory POST repricing.
-- The active Post core always reprices Product lines before validating Payment.
-- Delivery fee therefore belongs at the shared repricing boundary, not only
-- at the public Draft wrapper.

BEGIN;

DO $migration_guard$
BEGIN
    IF NOT EXISTS(
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version='20260811140000'
    ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: SLD-R2 foundation required';
    END IF;
    IF EXISTS(
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version='20260811143000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260811143000';
    END IF;
    IF to_regprocedure(
        'private.reprice_pos_sale_draft(uuid,uuid,uuid,jsonb,timestamptz)'
    ) IS NULL OR to_regprocedure(
        'private.reprice_pos_sale_draft_sld_r2_core(uuid,uuid,uuid,jsonb,timestamptz)'
    ) IS NOT NULL THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: unexpected repricing routine state';
    END IF;
    IF EXISTS(
        SELECT 1 FROM public.pos_offline_sale_submissions
        WHERE status IN ('QUEUED','SYNCING','NEEDS_CONFIRMATION')
    ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: nonterminal Offline Sale exists';
    END IF;
END
$migration_guard$;

ALTER FUNCTION private.reprice_pos_sale_draft(
    UUID,UUID,UUID,JSONB,TIMESTAMPTZ
) RENAME TO reprice_pos_sale_draft_sld_r2_core;

CREATE FUNCTION private.reprice_pos_sale_draft(
    p_company_id UUID,
    p_sales_id UUID,
    p_actor_id UUID,
    p_payload JSONB,
    p_resolved_at TIMESTAMPTZ
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE
    v_fee NUMERIC(20,4):=0;
    v_mode TEXT:='SHOW_SEPARATE';
    v_fulfillment TEXT:='PICKUP';
    v_payload JSONB;
    v_result JSONB;
BEGIN
    IF jsonb_typeof(p_payload) IS DISTINCT FROM 'object' THEN
        RAISE EXCEPTION 'SALE_PAYLOAD_OBJECT_REQUIRED';
    END IF;
    BEGIN
        v_fee:=round(COALESCE(NULLIF(
            btrim(p_payload->>'deliveryFeeAmount'),''
        )::NUMERIC,0),4);
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'INVALID_DELIVERY_FEE_AMOUNT';
    END;
    IF v_fee<0 OR v_fee>999999999999999.9999 THEN
        RAISE EXCEPTION 'INVALID_DELIVERY_FEE_AMOUNT';
    END IF;
    v_mode:=upper(btrim(COALESCE(
        NULLIF(p_payload->>'deliveryFeeInvoiceDisplayMode',''),
        'SHOW_SEPARATE'
    )));
    IF v_mode NOT IN ('SHOW_SEPARATE','HIDE_BREAKDOWN') THEN
        RAISE EXCEPTION 'INVALID_DELIVERY_FEE_INVOICE_DISPLAY_MODE';
    END IF;
    v_fulfillment:=upper(btrim(COALESCE(
        NULLIF(p_payload->>'fulfillmentMode',''),'PICKUP'
    )));
    IF v_fulfillment NOT IN ('PICKUP','DELIVERY') THEN
        RAISE EXCEPTION 'INVALID_FULFILLMENT_MODE';
    END IF;
    IF v_fulfillment='PICKUP' AND v_fee<>0 THEN
        RAISE EXCEPTION 'PICKUP_DELIVERY_FEE_NOT_ALLOWED';
    END IF;

    v_payload:=p_payload||jsonb_build_object(
        'fulfillmentMode',v_fulfillment,
        'deliveryFeeAmount',v_fee,
        'deliveryFeeInvoiceDisplayMode',v_mode
    );
    v_result:=private.reprice_pos_sale_draft_sld_r2_core(
        p_company_id,p_sales_id,p_actor_id,v_payload,p_resolved_at
    );

    -- The Product core resets all commercial totals first. Adding the fee
    -- here is deterministic on Draft save and on mandatory POST repricing.
    UPDATE public.sales_headers SET
        delivery_fee_amount=v_fee,
        delivery_fee_invoice_display_mode=v_mode,
        grand_total=grand_total+v_fee,
        grand_total_before_rounding=grand_total_before_rounding+v_fee,
        grand_total_after_rounding=grand_total_after_rounding+v_fee,
        payload_snapshot=payload_snapshot||jsonb_build_object(
            'fulfillmentMode',v_fulfillment,
            'deliveryFeeAmount',v_fee,
            'deliveryFeeInvoiceDisplayMode',v_mode
        )
    WHERE company_id=p_company_id AND id=p_sales_id
      AND document_status='DRAFT';

    RETURN v_result||jsonb_build_object(
        'deliveryFeeAmount',v_fee,
        'deliveryFeeInvoiceDisplayMode',v_mode,
        'grandTotalBeforeRounding',
            (v_result->>'grandTotalBeforeRounding')::NUMERIC+v_fee,
        'grandTotalAfterRounding',
            (v_result->>'grandTotalAfterRounding')::NUMERIC+v_fee
    );
END;
$$;

-- Replace the first R2 Draft wrapper so it validates/canonicalizes input but
-- does not add the fee a second time. The shared repricer is now authoritative.
CREATE OR REPLACE FUNCTION public.save_pos_sale_draft(p_payload JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE
    v_company UUID:=public.private_active_company_id();
    v_fee NUMERIC(20,4):=0;
    v_mode TEXT:='SHOW_SEPARATE';
    v_fulfillment TEXT:='PICKUP';
    v_payload JSONB;
BEGIN
    IF auth.uid() IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF jsonb_typeof(p_payload) IS DISTINCT FROM 'object' THEN
        RAISE EXCEPTION 'SALE_PAYLOAD_OBJECT_REQUIRED';
    END IF;
    BEGIN
        v_fee:=round(COALESCE(NULLIF(
            btrim(p_payload->>'deliveryFeeAmount'),''
        )::NUMERIC,0),4);
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'INVALID_DELIVERY_FEE_AMOUNT';
    END;
    IF v_fee<0 OR v_fee>999999999999999.9999 THEN
        RAISE EXCEPTION 'INVALID_DELIVERY_FEE_AMOUNT';
    END IF;
    v_mode:=upper(btrim(COALESCE(
        NULLIF(p_payload->>'deliveryFeeInvoiceDisplayMode',''),
        'SHOW_SEPARATE'
    )));
    IF v_mode NOT IN ('SHOW_SEPARATE','HIDE_BREAKDOWN') THEN
        RAISE EXCEPTION 'INVALID_DELIVERY_FEE_INVOICE_DISPLAY_MODE';
    END IF;
    v_fulfillment:=upper(btrim(COALESCE(
        NULLIF(p_payload->>'fulfillmentMode',''),'PICKUP'
    )));
    IF v_fulfillment NOT IN ('PICKUP','DELIVERY') THEN
        RAISE EXCEPTION 'INVALID_FULFILLMENT_MODE';
    END IF;
    IF v_fulfillment='PICKUP' AND v_fee<>0 THEN
        RAISE EXCEPTION 'PICKUP_DELIVERY_FEE_NOT_ALLOWED';
    END IF;

    v_payload:=p_payload||jsonb_build_object(
        'fulfillmentMode',v_fulfillment,
        'deliveryFeeAmount',v_fee,
        'deliveryFeeInvoiceDisplayMode',v_mode
    );
    RETURN private.save_pos_sale_draft_sld_r2_core(v_payload);
END;
$$;

REVOKE ALL ON FUNCTION
    private.reprice_pos_sale_draft_sld_r2_core(
        UUID,UUID,UUID,JSONB,TIMESTAMPTZ
    ),
    private.reprice_pos_sale_draft(UUID,UUID,UUID,JSONB,TIMESTAMPTZ)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
    private.reprice_pos_sale_draft_sld_r2_core(
        UUID,UUID,UUID,JSONB,TIMESTAMPTZ
    ),
    private.reprice_pos_sale_draft(UUID,UUID,UUID,JSONB,TIMESTAMPTZ)
TO service_role;

REVOKE ALL ON FUNCTION public.save_pos_sale_draft(JSONB)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.save_pos_sale_draft(JSONB)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES(
    '20260811143000','sld_r2_post_reprice_delivery_fee_fix',
    'Moves delivery-fee total resolution to the shared Draft/Post repricing boundary so Payment validation, Offline replay, and retries preserve the same authoritative grand total'
);

COMMIT;
