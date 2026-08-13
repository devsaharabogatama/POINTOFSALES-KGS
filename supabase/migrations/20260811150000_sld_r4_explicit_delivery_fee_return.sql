-- SLD-R4: explicit Delivery-fee refund on final/full Sales Return only.
-- Partial Product Return never refunds Delivery fee implicitly.

BEGIN;

DO $guard$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version='20260811143000'
    ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: SLD-R2 repricing fix missing';
    END IF;
    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version='20260811150000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260811150000';
    END IF;
    IF EXISTS (
        SELECT 1 FROM public.pos_offline_sale_submissions
        WHERE status IN ('QUEUED','SYNCING','NEEDS_CONFIRMATION')
    ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: nonterminal Offline Sale exists';
    END IF;
    IF EXISTS (
        SELECT 1 FROM public.sales_return_documents document
        JOIN public.sales_headers sale
          ON sale.company_id=document.company_id
         AND sale.id=document.source_sales_id
        WHERE document.status='DRAFT'
          AND sale.delivery_fee_amount>0
    ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: close Delivery Return Draft first';
    END IF;
END
$guard$;

ALTER TABLE public.sales_return_documents
    ADD COLUMN source_delivery_fee_amount_snapshot NUMERIC(20,4)
        NOT NULL DEFAULT 0,
    ADD COLUMN delivery_fee_refund_requested BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN delivery_fee_refund_amount NUMERIC(20,4) NOT NULL DEFAULT 0,
    ADD COLUMN delivery_fee_refund_decided_by UUID
        REFERENCES public.profiles(id) ON DELETE RESTRICT,
    ADD COLUMN delivery_fee_refund_decided_at TIMESTAMPTZ,
    ADD CONSTRAINT sales_return_delivery_fee_refund_contract CHECK (
        source_delivery_fee_amount_snapshot>=0
        AND delivery_fee_refund_amount>=0
        AND delivery_fee_refund_amount<=source_delivery_fee_amount_snapshot
        AND (
            (delivery_fee_refund_requested
             AND delivery_fee_refund_amount>0)
            OR
            (NOT delivery_fee_refund_requested
             AND delivery_fee_refund_amount=0)
        )
        AND (
            (status='DRAFT'
             AND delivery_fee_refund_decided_by IS NULL
             AND delivery_fee_refund_decided_at IS NULL)
            OR
            (status='POSTED'
             AND (
                 source_delivery_fee_amount_snapshot=0
                 OR (
                     delivery_fee_refund_decided_by IS NOT NULL
                     AND delivery_fee_refund_decided_at IS NOT NULL
                 )
             ))
            OR status='CANCELED'
        )
    );

CREATE UNIQUE INDEX uq_sales_return_one_posted_delivery_fee_refund
ON public.sales_return_documents(company_id,source_sales_id)
WHERE status='POSTED' AND delivery_fee_refund_amount>0;

ALTER TABLE public.sales_return_audit
    DROP CONSTRAINT sales_return_audit_action_check,
    ADD CONSTRAINT sales_return_audit_action_check CHECK (
        action IN (
            'CREATE_DRAFT','UPDATE_DRAFT','POST','CANCEL',
            'DELIVERY_FEE_REQUEST'
        )
    );

ALTER FUNCTION public.save_sales_return_draft(
    UUID,BIGINT,UUID,UUID,TEXT,TEXT,JSONB,JSONB
) SET SCHEMA private;
ALTER FUNCTION private.save_sales_return_draft(
    UUID,BIGINT,UUID,UUID,TEXT,TEXT,JSONB,JSONB
) RENAME TO save_sales_return_draft_sld_r4_core;

CREATE FUNCTION private.save_sales_return_draft_sld_r4(
    p_document_id UUID,
    p_master_version BIGINT,
    p_source_sales_id UUID,
    p_executing_session_id UUID,
    p_rounding_direction TEXT,
    p_notes TEXT,
    p_lines JSONB,
    p_refunds JSONB,
    p_refund_delivery_fee BOOLEAN
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE
    v_actor UUID:=auth.uid();
    v_company UUID:=public.private_active_company_id();
    v_sale public.sales_headers%ROWTYPE;
    v_full_remaining BOOLEAN:=FALSE;
    v_prior_fee NUMERIC(20,4):=0;
    v_available_fee NUMERIC(20,4):=0;
    v_requested_fee NUMERIC(20,4):=0;
    v_user_total NUMERIC(20,4):=0;
    v_core_refunds JSONB:=p_refunds;
    v_result JSONB;
    v_document_id UUID;
    v_core_total NUMERIC(20,4);
    v_final_total NUMERIC(20,4);
    v_first_refund_id UUID;
    v_refund JSONB;
    v_before_requested BOOLEAN:=FALSE;
    v_before_amount NUMERIC(20,4):=0;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF jsonb_typeof(p_lines) IS DISTINCT FROM 'array'
       OR jsonb_array_length(p_lines)=0 THEN
        RAISE EXCEPTION 'SALES_RETURN_LINES_REQUIRED';
    END IF;
    IF jsonb_typeof(p_refunds) IS DISTINCT FROM 'array'
       OR jsonb_array_length(p_refunds)=0 THEN
        RAISE EXCEPTION 'SALES_RETURN_REFUNDS_REQUIRED';
    END IF;

    SELECT * INTO v_sale
    FROM public.sales_headers sale
    WHERE sale.company_id=v_company AND sale.id=p_source_sales_id
      AND sale.document_status='POSTED';
    IF NOT FOUND THEN RAISE EXCEPTION 'POSTED_SOURCE_SALE_NOT_FOUND'; END IF;

    IF p_document_id IS NOT NULL THEN
        SELECT document.delivery_fee_refund_requested,
               document.delivery_fee_refund_amount
        INTO v_before_requested,v_before_amount
        FROM public.sales_return_documents document
        WHERE document.company_id=v_company
          AND document.id=p_document_id
          AND document.status='DRAFT';
    END IF;

    SELECT COALESCE(sum(document.delivery_fee_refund_amount),0)
    INTO v_prior_fee
    FROM public.sales_return_documents document
    WHERE document.company_id=v_company
      AND document.source_sales_id=v_sale.id
      AND document.status='POSTED';
    v_available_fee:=GREATEST(
        COALESCE(v_sale.delivery_fee_amount,0)-v_prior_fee,0
    );

    WITH input_lines AS (
        SELECT
            (line->>'sourceSalesDetailId')::UUID AS detail_id,
            sum((line->>'quantity')::NUMERIC) AS quantity
        FROM jsonb_array_elements(p_lines) line
        GROUP BY (line->>'sourceSalesDetailId')::UUID
    ), remaining AS (
        SELECT
            detail.id,
            detail.qty-COALESCE((
                SELECT sum(return_line.quantity_uom)
                FROM public.sales_return_lines return_line
                JOIN public.sales_return_documents return_document
                  ON return_document.company_id=return_line.company_id
                 AND return_document.id=return_line.document_id
                 AND return_document.status='POSTED'
                WHERE return_line.company_id=detail.company_id
                  AND return_line.source_sales_detail_id=detail.id
            ),0) AS quantity
        FROM public.sales_details detail
        WHERE detail.company_id=v_company AND detail.sales_id=v_sale.id
    )
    SELECT
        EXISTS(SELECT 1 FROM remaining WHERE quantity>0)
        AND NOT EXISTS(
            SELECT 1 FROM remaining
            LEFT JOIN input_lines input_line ON input_line.detail_id=remaining.id
            WHERE remaining.quantity>0
              AND COALESCE(input_line.quantity,0)<>remaining.quantity
        )
    INTO v_full_remaining;

    IF COALESCE(p_refund_delivery_fee,FALSE) THEN
        IF NOT v_full_remaining THEN
            RAISE EXCEPTION 'DELIVERY_FEE_REFUND_FULL_RETURN_REQUIRED';
        END IF;
        IF v_available_fee<=0 THEN
            RAISE EXCEPTION 'DELIVERY_FEE_NOT_REFUNDABLE';
        END IF;
        v_requested_fee:=v_available_fee;
    END IF;

    FOR v_refund IN SELECT value FROM jsonb_array_elements(p_refunds)
    LOOP
        BEGIN
            v_user_total:=v_user_total+(v_refund->>'amount')::NUMERIC;
        EXCEPTION WHEN OTHERS THEN
            RAISE EXCEPTION 'INVALID_REFUND_AMOUNT';
        END;
    END LOOP;

    -- The legacy core closes a full Return to the complete remaining Sale
    -- grand total. Inflate only its first internal refund leg, then remove the
    -- fee again after core validation when the operator did not request it.
    IF v_full_remaining
       AND NOT COALESCE(p_refund_delivery_fee,FALSE)
       AND v_available_fee>0 THEN
        v_core_refunds:=jsonb_set(
            v_core_refunds,'{0,amount}',
            to_jsonb(
                ((v_core_refunds->0->>'amount')::NUMERIC+v_available_fee)
            ),FALSE
        );
    END IF;

    v_result:=private.save_sales_return_draft_sld_r4_core(
        p_document_id,p_master_version,p_source_sales_id,
        p_executing_session_id,p_rounding_direction,p_notes,p_lines,
        v_core_refunds
    );
    v_document_id:=(v_result->>'documentId')::UUID;
    v_core_total:=(v_result->>'refundTotal')::NUMERIC;
    v_final_total:=v_core_total-CASE
        WHEN v_full_remaining
         AND NOT COALESCE(p_refund_delivery_fee,FALSE)
        THEN v_available_fee ELSE 0 END;

    IF abs(v_user_total-v_final_total)>0.0001 THEN
        RAISE EXCEPTION 'REFUND_PAYMENT_TOTAL_MISMATCH';
    END IF;

    IF v_core_total<>v_final_total THEN
        SELECT refund.id INTO v_first_refund_id
        FROM public.sales_return_refunds refund
        WHERE refund.company_id=v_company
          AND refund.document_id=v_document_id
        ORDER BY refund.created_at,refund.id LIMIT 1;
        UPDATE public.sales_return_refunds
        SET amount=amount-(v_core_total-v_final_total)
        WHERE company_id=v_company AND id=v_first_refund_id;
    END IF;

    UPDATE public.sales_return_documents document SET
        source_delivery_fee_amount_snapshot=COALESCE(
            v_sale.delivery_fee_amount,0
        ),
        delivery_fee_refund_requested=COALESCE(
            p_refund_delivery_fee,FALSE
        ),
        delivery_fee_refund_amount=v_requested_fee,
        refund_total=v_final_total,
        rounding_adjustment=
            v_final_total-document.refund_before_rounding-v_requested_fee
    WHERE document.company_id=v_company AND document.id=v_document_id;

    INSERT INTO public.sales_return_audit(
        company_id,document_id,action,actor_id,before_state,after_state
    )
    SELECT v_company,document.id,'DELIVERY_FEE_REQUEST',v_actor,
        jsonb_build_object(
            'requested',COALESCE(v_before_requested,FALSE),
            'amount',COALESCE(v_before_amount,0)
        ),
        jsonb_build_object(
            'requested',document.delivery_fee_refund_requested,
            'amount',document.delivery_fee_refund_amount,
            'sourceDeliveryFee',document.source_delivery_fee_amount_snapshot
        )
    FROM public.sales_return_documents document
    WHERE document.company_id=v_company AND document.id=v_document_id;

    RETURN v_result||jsonb_build_object(
        'refundTotal',v_final_total,
        'deliveryFeeRefundRequested',COALESCE(
            p_refund_delivery_fee,FALSE
        ),
        'deliveryFeeRefundAmount',v_requested_fee
    );
END;
$$;

CREATE FUNCTION public.save_sales_return_draft(
    p_document_id UUID,
    p_master_version BIGINT,
    p_source_sales_id UUID,
    p_executing_session_id UUID,
    p_rounding_direction TEXT,
    p_notes TEXT,
    p_lines JSONB,
    p_refunds JSONB
) RETURNS JSONB
LANGUAGE sql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
    SELECT private.save_sales_return_draft_sld_r4(
        p_document_id,p_master_version,p_source_sales_id,
        p_executing_session_id,p_rounding_direction,p_notes,p_lines,p_refunds,
        FALSE
    );
$$;

CREATE FUNCTION public.save_sales_return_draft_with_delivery_fee(
    p_document_id UUID,
    p_master_version BIGINT,
    p_source_sales_id UUID,
    p_executing_session_id UUID,
    p_rounding_direction TEXT,
    p_notes TEXT,
    p_lines JSONB,
    p_refunds JSONB,
    p_refund_delivery_fee BOOLEAN
) RETURNS JSONB
LANGUAGE sql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
    SELECT private.save_sales_return_draft_sld_r4(
        p_document_id,p_master_version,p_source_sales_id,
        p_executing_session_id,p_rounding_direction,p_notes,p_lines,p_refunds,
        COALESCE(p_refund_delivery_fee,FALSE)
    );
$$;

CREATE FUNCTION private.trg_sld_r4_validate_delivery_fee_refund_post()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE
    v_full_return BOOLEAN;
    v_prior_fee NUMERIC(20,4);
BEGIN
    IF OLD.status<>'DRAFT' OR NEW.status<>'POSTED' THEN RETURN NEW; END IF;
    IF NEW.source_delivery_fee_amount_snapshot=0 THEN RETURN NEW; END IF;

    WITH coverage AS (
        SELECT detail.id,detail.qty,
               COALESCE(sum(line.quantity_uom) FILTER(
                   WHERE document.id IS NOT NULL
               ),0) quantity
        FROM public.sales_details detail
        LEFT JOIN public.sales_return_lines line
          ON line.company_id=detail.company_id
         AND line.source_sales_detail_id=detail.id
        LEFT JOIN public.sales_return_documents document
          ON document.company_id=line.company_id
         AND document.id=line.document_id
         AND (document.status='POSTED' OR document.id=NEW.id)
        WHERE detail.company_id=NEW.company_id
          AND detail.sales_id=NEW.source_sales_id
        GROUP BY detail.id,detail.qty
    )
    SELECT bool_and(qty=quantity) INTO v_full_return FROM coverage;

    SELECT COALESCE(sum(document.delivery_fee_refund_amount),0)
    INTO v_prior_fee
    FROM public.sales_return_documents document
    WHERE document.company_id=NEW.company_id
      AND document.source_sales_id=NEW.source_sales_id
      AND document.status='POSTED' AND document.id<>NEW.id;

    IF NEW.delivery_fee_refund_requested THEN
        IF NOT COALESCE(v_full_return,FALSE) THEN
            RAISE EXCEPTION 'DELIVERY_FEE_REFUND_FULL_RETURN_REQUIRED';
        END IF;
        IF v_prior_fee>0 OR NEW.delivery_fee_refund_amount<>
           NEW.source_delivery_fee_amount_snapshot THEN
            RAISE EXCEPTION 'DELIVERY_FEE_REFUND_ALREADY_DECIDED';
        END IF;
    ELSIF NEW.delivery_fee_refund_amount<>0 THEN
        RAISE EXCEPTION 'UNREQUESTED_DELIVERY_FEE_REFUND';
    END IF;

    NEW.delivery_fee_refund_decided_by:=NEW.posted_by;
    NEW.delivery_fee_refund_decided_at:=NEW.posted_at;
    RETURN NEW;
END;
$$;

CREATE TRIGGER sld_r4_validate_delivery_fee_refund_post
BEFORE UPDATE OF status ON public.sales_return_documents
FOR EACH ROW EXECUTE FUNCTION
    private.trg_sld_r4_validate_delivery_fee_refund_post();

CREATE FUNCTION private.trg_sld_r4_sales_refund_event_fee_snapshot()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE
    v_requested BOOLEAN;
    v_amount NUMERIC(20,4);
BEGIN
    IF NEW.event_type<>'SALES_REFUND'::public.event_type
       OR NEW.source_table<>'sales_return_documents' THEN
        RETURN NEW;
    END IF;
    SELECT document.delivery_fee_refund_requested,
           document.delivery_fee_refund_amount
    INTO v_requested,v_amount
    FROM public.sales_return_documents document
    WHERE document.company_id=NEW.company_id AND document.id=NEW.source_id;
    NEW.amounts:=COALESCE(NEW.amounts,'{}'::JSONB)||jsonb_build_object(
        'deliveryFeeRefundRequested',COALESCE(v_requested,FALSE),
        'deliveryFeeRefund',COALESCE(v_amount,0)
    );
    RETURN NEW;
END;
$$;

CREATE TRIGGER sld_r4_sales_refund_event_fee_snapshot
BEFORE INSERT ON public.financial_events
FOR EACH ROW EXECUTE FUNCTION
    private.trg_sld_r4_sales_refund_event_fee_snapshot();

REVOKE ALL ON FUNCTION
    private.save_sales_return_draft_sld_r4_core(
        UUID,BIGINT,UUID,UUID,TEXT,TEXT,JSONB,JSONB
    ),
    private.save_sales_return_draft_sld_r4(
        UUID,BIGINT,UUID,UUID,TEXT,TEXT,JSONB,JSONB,BOOLEAN
    ),
    private.trg_sld_r4_validate_delivery_fee_refund_post(),
    private.trg_sld_r4_sales_refund_event_fee_snapshot()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
    private.save_sales_return_draft_sld_r4_core(
        UUID,BIGINT,UUID,UUID,TEXT,TEXT,JSONB,JSONB
    ),
    private.save_sales_return_draft_sld_r4(
        UUID,BIGINT,UUID,UUID,TEXT,TEXT,JSONB,JSONB,BOOLEAN
    ),
    private.trg_sld_r4_validate_delivery_fee_refund_post(),
    private.trg_sld_r4_sales_refund_event_fee_snapshot()
TO service_role;

REVOKE ALL ON FUNCTION public.save_sales_return_draft(
    UUID,BIGINT,UUID,UUID,TEXT,TEXT,JSONB,JSONB
),public.save_sales_return_draft_with_delivery_fee(
    UUID,BIGINT,UUID,UUID,TEXT,TEXT,JSONB,JSONB,BOOLEAN
) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.save_sales_return_draft(
    UUID,BIGINT,UUID,UUID,TEXT,TEXT,JSONB,JSONB
),public.save_sales_return_draft_with_delivery_fee(
    UUID,BIGINT,UUID,UUID,TEXT,TEXT,JSONB,JSONB,BOOLEAN
) TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES(
    '20260811150000','sld_r4_explicit_delivery_fee_return',
    'Separates Product and Delivery-fee refunds, defaults fee refund to off, permits explicit fee refund only on full remaining Return, snapshots the Manager/Admin posting decision, and enriches SALES_REFUND HOLD events without opening G6 posting'
);

COMMIT;
