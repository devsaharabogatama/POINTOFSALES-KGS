-- KGS POS G4 phase 6: Sale Draft list, lifecycle, and single-editor lock.
-- Draft remains side-effect-free and does not reserve stock.

BEGIN;

DO $guard$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260729100000'
    ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: G4 phase 5 Pricelist closure missing';
    END IF;
    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260729120000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260729120000';
    END IF;
END
$guard$;

CREATE SEQUENCE private.pos_draft_number_seq AS BIGINT START WITH 1;
REVOKE ALL ON SEQUENCE private.pos_draft_number_seq
FROM PUBLIC, anon, authenticated;
GRANT USAGE, SELECT ON SEQUENCE private.pos_draft_number_seq TO service_role;

ALTER TABLE public.sales_headers
    ADD COLUMN draft_no TEXT,
    ADD COLUMN draft_label TEXT,
    ADD COLUMN draft_notes TEXT,
    ADD COLUMN created_session_id UUID,
    ADD COLUMN edit_lock_owner_id UUID REFERENCES public.profiles(id)
        ON DELETE RESTRICT,
    ADD COLUMN edit_lock_session_id UUID,
    ADD COLUMN edit_lock_acquired_at TIMESTAMPTZ,
    ADD COLUMN edit_lock_heartbeat_at TIMESTAMPTZ,
    ADD COLUMN canceled_at TIMESTAMPTZ,
    ADD COLUMN canceled_by UUID REFERENCES public.profiles(id)
        ON DELETE RESTRICT,
    ADD COLUMN cancel_reason TEXT;

UPDATE public.sales_headers
SET created_session_id = session_id
WHERE created_session_id IS NULL;

UPDATE public.sales_headers
SET draft_no = 'DRF-' || to_char(created_at, 'YYYYMMDD') || '-'
    || lpad(nextval('private.pos_draft_number_seq')::TEXT, 6, '0')
WHERE document_status = 'DRAFT'
  AND draft_no IS NULL;

ALTER TABLE public.sales_headers
    ALTER COLUMN created_session_id SET NOT NULL,
    ADD CONSTRAINT fk_sales_headers_company_created_session
        FOREIGN KEY(company_id,created_session_id)
        REFERENCES public.cashier_sessions(company_id,id) ON DELETE RESTRICT,
    ADD CONSTRAINT fk_sales_headers_company_edit_lock_session
        FOREIGN KEY(company_id,edit_lock_session_id)
        REFERENCES public.cashier_sessions(company_id,id) ON DELETE RESTRICT,
    ADD CONSTRAINT sales_headers_draft_label_not_blank CHECK (
        draft_label IS NULL OR btrim(draft_label) <> ''
    ),
    ADD CONSTRAINT sales_headers_draft_notes_not_blank CHECK (
        draft_notes IS NULL OR btrim(draft_notes) <> ''
    ),
    ADD CONSTRAINT sales_headers_draft_no_not_blank CHECK (
        draft_no IS NULL OR btrim(draft_no) <> ''
    ),
    ADD CONSTRAINT sales_headers_edit_lock_shape CHECK (
        (
            edit_lock_owner_id IS NULL
            AND edit_lock_session_id IS NULL
            AND edit_lock_acquired_at IS NULL
            AND edit_lock_heartbeat_at IS NULL
        )
        OR (
            edit_lock_owner_id IS NOT NULL
            AND edit_lock_session_id IS NOT NULL
            AND edit_lock_acquired_at IS NOT NULL
            AND edit_lock_heartbeat_at IS NOT NULL
            AND edit_lock_heartbeat_at >= edit_lock_acquired_at
        )
    ),
    ADD CONSTRAINT sales_headers_canceled_contract CHECK (
        document_status <> 'CANCELED'
        OR (canceled_at IS NOT NULL AND canceled_by IS NOT NULL)
    );

CREATE UNIQUE INDEX uq_sales_headers_company_draft_no
    ON public.sales_headers(company_id,draft_no)
    WHERE draft_no IS NOT NULL;
CREATE INDEX idx_sales_headers_store_draft_updated
    ON public.sales_headers(company_id,store_id,updated_at DESC)
    WHERE document_status = 'DRAFT';
CREATE INDEX idx_sales_headers_draft_lock_heartbeat
    ON public.sales_headers(company_id,edit_lock_heartbeat_at)
    WHERE document_status = 'DRAFT'
      AND edit_lock_owner_id IS NOT NULL;

ALTER TABLE public.sale_master_audit
    DROP CONSTRAINT sale_master_audit_action_check,
    ADD CONSTRAINT sale_master_audit_action_check CHECK (
        action IN (
            'CREATE_DRAFT','UPDATE_DRAFT','STOCK_SHORTAGE','POST',
            'LOCK_ACQUIRE','LOCK_HEARTBEAT','LOCK_TAKEOVER',
            'LOCK_FORCE_RELEASE','LOCK_RELEASE','CANCEL_DRAFT'
        )
    );

CREATE FUNCTION private.trg_g4_prepare_sale_draft()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    NEW.created_session_id := COALESCE(NEW.created_session_id, NEW.session_id);
    IF NEW.document_status = 'DRAFT' AND NEW.draft_no IS NULL THEN
        NEW.draft_no := 'DRF-' || to_char(clock_timestamp(), 'YYYYMMDD') || '-'
            || lpad(nextval('private.pos_draft_number_seq')::TEXT, 6, '0');
    END IF;
    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION private.trg_g4_prepare_sale_draft()
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.trg_g4_prepare_sale_draft() TO service_role;

CREATE TRIGGER g4_prepare_sale_draft
BEFORE INSERT ON public.sales_headers
FOR EACH ROW EXECUTE FUNCTION private.trg_g4_prepare_sale_draft();

CREATE OR REPLACE FUNCTION public.private_sales_document_visible(
    p_sales_id UUID
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM public.sales_headers h
        WHERE h.id = p_sales_id
          AND public.private_request_company_matches(h.company_id)
          AND (
              h.created_by = auth.uid()
              OR public.private_user_has_any_company_role(
                  h.company_id,
                  ARRAY[
                      'COMPANY_OWNER','COMPANY_ADMIN','FINANCE','ACCOUNTING'
                  ]::TEXT[]
              )
              OR public.private_user_has_any_store_role(
                  h.store_id,
                  ARRAY['CASHIER','STORE_MANAGER']::TEXT[]
              )
          )
    );
$$;

ALTER FUNCTION public.save_pos_sale_draft(JSONB) SET SCHEMA private;
ALTER FUNCTION private.save_pos_sale_draft(JSONB)
    RENAME TO save_pos_sale_draft_core;
ALTER FUNCTION public.post_pos_sale(UUID,BIGINT,UUID) SET SCHEMA private;
ALTER FUNCTION private.post_pos_sale(UUID,BIGINT,UUID)
    RENAME TO post_pos_sale_core;

CREATE FUNCTION public.save_pos_sale_draft(p_payload JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_actor UUID := auth.uid();
    v_company UUID := public.private_active_company_id();
    v_sale_id UUID;
    v_session_id UUID;
    v_sale public.sales_headers%ROWTYPE;
    v_result JSONB;
    v_draft_no TEXT;
    v_now TIMESTAMPTZ := clock_timestamp();
BEGIN
    BEGIN
        v_sale_id := NULLIF(p_payload->>'saleId','')::UUID;
        v_session_id := (p_payload->>'cashierSessionId')::UUID;
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'INVALID_SALE_IDENTITY';
    END;

    IF NOT EXISTS (
        SELECT 1 FROM public.cashier_sessions cs
        WHERE cs.company_id = v_company
          AND cs.id = v_session_id
          AND cs.cashier_id = v_actor
          AND cs.status = 'OPEN'::public.session_status
    ) THEN
        RAISE EXCEPTION 'OPEN_CASHIER_SESSION_REQUIRED';
    END IF;

    IF v_sale_id IS NOT NULL THEN
        SELECT * INTO v_sale
        FROM public.sales_headers sh
        WHERE sh.company_id = v_company AND sh.id = v_sale_id
        FOR UPDATE;
        IF NOT FOUND THEN RAISE EXCEPTION 'SALE_DRAFT_NOT_FOUND'; END IF;
        IF v_sale.document_status <> 'DRAFT' THEN
            RAISE EXCEPTION 'SALE_DRAFT_REQUIRED';
        END IF;
        IF v_sale.edit_lock_owner_id IS DISTINCT FROM v_actor
           OR v_sale.edit_lock_session_id IS DISTINCT FROM v_session_id
           OR v_sale.edit_lock_heartbeat_at IS NULL
           OR v_sale.edit_lock_heartbeat_at <
                v_now - interval '5 minutes' THEN
            RAISE EXCEPTION 'SALE_DRAFT_EDIT_LOCK_REQUIRED';
        END IF;
    END IF;

    v_result := private.save_pos_sale_draft_core(p_payload);
    v_sale_id := (v_result->>'salesId')::UUID;

    UPDATE public.sales_headers
    SET edit_lock_owner_id = v_actor,
        edit_lock_session_id = v_session_id,
        edit_lock_acquired_at = COALESCE(edit_lock_acquired_at,v_now),
        edit_lock_heartbeat_at = v_now,
        draft_label = CASE WHEN p_payload ? 'draftLabel'
            THEN NULLIF(btrim(p_payload->>'draftLabel'),'')
            ELSE draft_label END,
        draft_notes = CASE WHEN p_payload ? 'draftNotes'
            THEN NULLIF(btrim(p_payload->>'draftNotes'),'')
            ELSE draft_notes END
    WHERE company_id = v_company
      AND id = v_sale_id
      AND document_status = 'DRAFT';

    IF v_sale_id IS NOT NULL AND v_sale.id IS NULL THEN
        INSERT INTO public.sale_master_audit(
            company_id,sales_id,action,actor_id,before_state,after_state
        ) VALUES (
            v_company,v_sale_id,'LOCK_ACQUIRE',v_actor,NULL,
            jsonb_build_object(
                'sessionId',v_session_id,'acquiredAt',v_now
            )
        );
    END IF;

    SELECT sh.draft_no INTO STRICT v_draft_no
    FROM public.sales_headers sh
    WHERE sh.company_id = v_company AND sh.id = v_sale_id;

    RETURN v_result || jsonb_build_object('draftNo',v_draft_no);
END;
$$;

CREATE FUNCTION public.post_pos_sale(
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
        UPDATE public.sales_headers
        SET edit_lock_owner_id = NULL,
            edit_lock_session_id = NULL,
            edit_lock_acquired_at = NULL,
            edit_lock_heartbeat_at = NULL
        WHERE company_id = v_company AND id = p_sales_id;
    END IF;
    RETURN v_result;
END;
$$;

CREATE FUNCTION public.list_pos_sale_drafts(p_store_id UUID DEFAULT NULL)
RETURNS JSONB
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT COALESCE(jsonb_agg(item ORDER BY updated_at DESC),'[]'::jsonb)
    FROM (
        SELECT
            sh.updated_at,
            jsonb_build_object(
                'salesId',sh.id,
                'draftNo',sh.draft_no,
                'draftLabel',sh.draft_label,
                'draftNotes',sh.draft_notes,
                'draftReason',sh.draft_reason,
                'customerId',sh.customer_id,
                'customerName',c.name,
                'storeId',sh.store_id,
                'storeName',s.store_name,
                'createdBy',sh.created_by,
                'createdByName',creator.name,
                'createdAt',sh.created_at,
                'updatedAt',sh.updated_at,
                'masterVersion',sh.master_version,
                'grandTotal',sh.grand_total_after_rounding,
                'lineCount',(
                    SELECT count(*) FROM public.sales_details sd
                    WHERE sd.company_id = sh.company_id
                      AND sd.sales_id = sh.id
                ),
                'isStale',sh.created_at <
                    clock_timestamp() - interval '7 days',
                'lockOwnerId',sh.edit_lock_owner_id,
                'lockOwnerName',lock_owner.name,
                'lockSessionId',sh.edit_lock_session_id,
                'lockHeartbeatAt',sh.edit_lock_heartbeat_at,
                'lockExpired',sh.edit_lock_heartbeat_at IS NOT NULL
                    AND sh.edit_lock_heartbeat_at <
                        clock_timestamp() - interval '5 minutes',
                'payloadSnapshot',sh.payload_snapshot
            ) AS item
        FROM public.sales_headers sh
        JOIN public.customers c
          ON c.company_id = sh.company_id AND c.id = sh.customer_id
        JOIN public.stores s
          ON s.company_id = sh.company_id AND s.id = sh.store_id
        JOIN public.profiles creator ON creator.id = sh.created_by
        LEFT JOIN public.profiles lock_owner
          ON lock_owner.id = sh.edit_lock_owner_id
        WHERE sh.company_id = public.private_active_company_id()
          AND sh.document_status = 'DRAFT'
          AND (p_store_id IS NULL OR sh.store_id = p_store_id)
          AND (
              public.private_user_has_any_company_role(
                  sh.company_id,
                  ARRAY['COMPANY_OWNER','COMPANY_ADMIN']::TEXT[]
              )
              OR public.private_user_has_any_store_role(
                  sh.store_id,
                  ARRAY['CASHIER','STORE_MANAGER']::TEXT[]
              )
          )
    ) visible;
$$;

CREATE FUNCTION public.acquire_pos_sale_draft_lock(
    p_sales_id UUID,
    p_cashier_session_id UUID,
    p_confirm_takeover BOOLEAN DEFAULT FALSE
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
    v_session public.cashier_sessions%ROWTYPE;
    v_action TEXT;
    v_now TIMESTAMPTZ := clock_timestamp();
BEGIN
    SELECT * INTO v_session FROM public.cashier_sessions cs
    WHERE cs.company_id = v_company
      AND cs.id = p_cashier_session_id
      AND cs.cashier_id = v_actor
      AND cs.status = 'OPEN'::public.session_status;
    IF NOT FOUND THEN RAISE EXCEPTION 'OPEN_CASHIER_SESSION_REQUIRED'; END IF;

    SELECT * INTO v_sale FROM public.sales_headers sh
    WHERE sh.company_id = v_company AND sh.id = p_sales_id
    FOR UPDATE;
    IF NOT FOUND OR v_sale.document_status <> 'DRAFT' THEN
        RAISE EXCEPTION 'SALE_DRAFT_NOT_FOUND';
    END IF;
    IF v_sale.store_id IS DISTINCT FROM v_session.store_id THEN
        RAISE EXCEPTION 'SALE_DRAFT_STORE_ACCESS_DENIED';
    END IF;

    IF v_sale.edit_lock_owner_id IS NULL THEN
        v_action := 'LOCK_ACQUIRE';
    ELSIF v_sale.edit_lock_owner_id = v_actor
       AND v_sale.edit_lock_session_id = p_cashier_session_id THEN
        v_action := 'LOCK_HEARTBEAT';
    ELSIF v_sale.edit_lock_heartbeat_at >= v_now - interval '5 minutes' THEN
        RAISE EXCEPTION 'SALE_DRAFT_LOCKED';
    ELSIF NOT COALESCE(p_confirm_takeover,FALSE) THEN
        RAISE EXCEPTION 'SALE_DRAFT_TAKEOVER_CONFIRMATION_REQUIRED';
    ELSE
        v_action := 'LOCK_TAKEOVER';
    END IF;

    UPDATE public.sales_headers SET
        edit_lock_owner_id = v_actor,
        edit_lock_session_id = p_cashier_session_id,
        edit_lock_acquired_at = CASE
            WHEN v_action = 'LOCK_HEARTBEAT'
                THEN edit_lock_acquired_at
            ELSE v_now
        END,
        edit_lock_heartbeat_at = v_now
    WHERE company_id = v_company AND id = p_sales_id;

    INSERT INTO public.sale_master_audit(
        company_id,sales_id,action,actor_id,before_state,after_state
    ) VALUES (
        v_company,p_sales_id,v_action,v_actor,
        jsonb_build_object(
            'ownerId',v_sale.edit_lock_owner_id,
            'sessionId',v_sale.edit_lock_session_id,
            'heartbeatAt',v_sale.edit_lock_heartbeat_at
        ),
        jsonb_build_object(
            'ownerId',v_actor,'sessionId',p_cashier_session_id,
            'heartbeatAt',v_now
        )
    );

    RETURN jsonb_build_object(
        'salesId',p_sales_id,'lockOwnerId',v_actor,
        'lockSessionId',p_cashier_session_id,
        'lockHeartbeatAt',v_now,'action',v_action
    );
END;
$$;

CREATE FUNCTION public.heartbeat_pos_sale_draft_lock(
    p_sales_id UUID,
    p_cashier_session_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_actor UUID := auth.uid();
    v_company UUID := public.private_active_company_id();
    v_now TIMESTAMPTZ := clock_timestamp();
BEGIN
    UPDATE public.sales_headers sh SET edit_lock_heartbeat_at = v_now
    WHERE sh.company_id = v_company
      AND sh.id = p_sales_id
      AND sh.document_status = 'DRAFT'
      AND sh.edit_lock_owner_id = v_actor
      AND sh.edit_lock_session_id = p_cashier_session_id
      AND sh.edit_lock_heartbeat_at >= v_now - interval '5 minutes'
      AND EXISTS (
          SELECT 1 FROM public.cashier_sessions cs
          WHERE cs.company_id = v_company
            AND cs.id = p_cashier_session_id
            AND cs.cashier_id = v_actor
            AND cs.status = 'OPEN'::public.session_status
      );
    IF NOT FOUND THEN RAISE EXCEPTION 'SALE_DRAFT_EDIT_LOCK_LOST'; END IF;
    RETURN jsonb_build_object(
        'salesId',p_sales_id,'lockHeartbeatAt',v_now
    );
END;
$$;

CREATE FUNCTION public.release_pos_sale_draft_lock(
    p_sales_id UUID,
    p_cashier_session_id UUID,
    p_force BOOLEAN DEFAULT FALSE,
    p_reason TEXT DEFAULT NULL
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
    v_action TEXT;
BEGIN
    SELECT * INTO v_sale FROM public.sales_headers sh
    WHERE sh.company_id = v_company AND sh.id = p_sales_id
    FOR UPDATE;
    IF NOT FOUND OR v_sale.document_status <> 'DRAFT' THEN
        RAISE EXCEPTION 'SALE_DRAFT_NOT_FOUND';
    END IF;

    IF COALESCE(p_force,FALSE) THEN
        IF NOT (
            public.private_user_has_any_company_role(
                v_company,ARRAY['COMPANY_OWNER','COMPANY_ADMIN']::TEXT[]
            )
            OR public.private_user_has_any_store_role(
                v_sale.store_id,ARRAY['STORE_MANAGER']::TEXT[]
            )
        ) THEN
            RAISE EXCEPTION 'SALE_DRAFT_FORCE_RELEASE_FORBIDDEN';
        END IF;
        IF NULLIF(btrim(p_reason),'') IS NULL THEN
            RAISE EXCEPTION 'FORCE_RELEASE_REASON_REQUIRED';
        END IF;
        v_action := 'LOCK_FORCE_RELEASE';
    ELSE
        IF v_sale.edit_lock_owner_id IS DISTINCT FROM v_actor
           OR v_sale.edit_lock_session_id IS DISTINCT FROM
                p_cashier_session_id THEN
            RAISE EXCEPTION 'SALE_DRAFT_EDIT_LOCK_REQUIRED';
        END IF;
        v_action := 'LOCK_RELEASE';
    END IF;

    UPDATE public.sales_headers SET
        edit_lock_owner_id = NULL,edit_lock_session_id = NULL,
        edit_lock_acquired_at = NULL,edit_lock_heartbeat_at = NULL
    WHERE company_id = v_company AND id = p_sales_id;

    INSERT INTO public.sale_master_audit(
        company_id,sales_id,action,actor_id,before_state,after_state
    ) VALUES (
        v_company,p_sales_id,v_action,v_actor,
        jsonb_build_object(
            'ownerId',v_sale.edit_lock_owner_id,
            'sessionId',v_sale.edit_lock_session_id
        ),
        jsonb_build_object(
            'released',TRUE,'reason',NULLIF(btrim(p_reason),'')
        )
    );
    RETURN jsonb_build_object('salesId',p_sales_id,'released',TRUE);
END;
$$;

CREATE FUNCTION public.cancel_pos_sale_draft(
    p_sales_id UUID,
    p_master_version BIGINT,
    p_cashier_session_id UUID,
    p_reason TEXT DEFAULT NULL
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
    v_now TIMESTAMPTZ := clock_timestamp();
BEGIN
    SELECT * INTO v_sale FROM public.sales_headers sh
    WHERE sh.company_id = v_company AND sh.id = p_sales_id
    FOR UPDATE;
    IF NOT FOUND OR v_sale.document_status <> 'DRAFT' THEN
        RAISE EXCEPTION 'SALE_DRAFT_NOT_FOUND';
    END IF;
    IF v_sale.master_version IS DISTINCT FROM p_master_version THEN
        RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM public.cashier_sessions cs
        WHERE cs.company_id = v_company
          AND cs.id = p_cashier_session_id
          AND cs.cashier_id = v_actor
          AND cs.status = 'OPEN'::public.session_status
          AND cs.store_id = v_sale.store_id
    ) THEN
        RAISE EXCEPTION 'OPEN_CASHIER_SESSION_REQUIRED';
    END IF;
    IF v_sale.edit_lock_owner_id IS DISTINCT FROM v_actor
       OR v_sale.edit_lock_session_id IS DISTINCT FROM p_cashier_session_id
       OR v_sale.edit_lock_heartbeat_at <
            v_now - interval '5 minutes' THEN
        RAISE EXCEPTION 'SALE_DRAFT_EDIT_LOCK_REQUIRED';
    END IF;

    UPDATE public.sales_headers SET
        document_status = 'CANCELED',
        canceled_at = v_now,canceled_by = v_actor,
        cancel_reason = NULLIF(btrim(p_reason),''),
        edit_lock_owner_id = NULL,edit_lock_session_id = NULL,
        edit_lock_acquired_at = NULL,edit_lock_heartbeat_at = NULL,
        master_version = master_version + 1,updated_at = v_now
    WHERE company_id = v_company AND id = p_sales_id;

    INSERT INTO public.sale_master_audit(
        company_id,sales_id,action,actor_id,before_state,after_state
    ) VALUES (
        v_company,p_sales_id,'CANCEL_DRAFT',v_actor,to_jsonb(v_sale),
        jsonb_build_object(
            'documentStatus','CANCELED','canceledAt',v_now,
            'reason',NULLIF(btrim(p_reason),''),
            'masterVersion',v_sale.master_version + 1
        )
    );
    RETURN jsonb_build_object(
        'salesId',p_sales_id,'documentStatus','CANCELED',
        'masterVersion',v_sale.master_version + 1
    );
END;
$$;

REVOKE ALL ON FUNCTION private.save_pos_sale_draft_core(JSONB),
    private.post_pos_sale_core(UUID,BIGINT,UUID)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.save_pos_sale_draft_core(JSONB),
    private.post_pos_sale_core(UUID,BIGINT,UUID)
TO service_role;

REVOKE ALL ON FUNCTION public.save_pos_sale_draft(JSONB),
    public.post_pos_sale(UUID,BIGINT,UUID),
    public.list_pos_sale_drafts(UUID),
    public.acquire_pos_sale_draft_lock(UUID,UUID,BOOLEAN),
    public.heartbeat_pos_sale_draft_lock(UUID,UUID),
    public.release_pos_sale_draft_lock(UUID,UUID,BOOLEAN,TEXT),
    public.cancel_pos_sale_draft(UUID,BIGINT,UUID,TEXT)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.save_pos_sale_draft(JSONB),
    public.post_pos_sale(UUID,BIGINT,UUID),
    public.list_pos_sale_drafts(UUID),
    public.acquire_pos_sale_draft_lock(UUID,UUID,BOOLEAN),
    public.heartbeat_pos_sale_draft_lock(UUID,UUID),
    public.release_pos_sale_draft_lock(UUID,UUID,BOOLEAN,TEXT),
    public.cancel_pos_sale_draft(UUID,BIGINT,UUID,TEXT)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES (
    '20260729120000',
    'g4_phase6_sale_draft_edit_lock',
    'Side-effect-free Draft list, metadata, same-Store visibility, 5-minute single-editor heartbeat lock, takeover/force release, cancel, audit, and guarded Save/Post'
);

COMMIT;
