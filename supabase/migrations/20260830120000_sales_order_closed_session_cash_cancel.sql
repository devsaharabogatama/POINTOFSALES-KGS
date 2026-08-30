-- Allow a Cash Order to be canceled after its source Cashier session closes.
-- The refund is recorded exactly once in the actor's current OPEN session for
-- the same Store. A CLOSED source session is never rewritten.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260830110000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: cancellation sync runtime required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260830120000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260830120000';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
      WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
      WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
END
$guard$;

CREATE OR REPLACE FUNCTION private.cancel_pending_sales_order_payments(
  p_company_id UUID,p_sales_id UUID,p_actor_id UUID,
  p_idempotency_key UUID,p_reason TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_request public.sales_payment_verification_requests%ROWTYPE;
  v_source_session public.cashier_sessions%ROWTYPE;
  v_refund_session public.cashier_sessions%ROWTYPE;
  v_reversal UUID;v_expected NUMERIC(24,4);v_before JSONB;v_after JSONB;
  v_count BIGINT:=0;v_cash_count BIGINT:=0;v_current_session_count BIGINT:=0;
  v_now TIMESTAMPTZ:=clock_timestamp();
BEGIN
  IF p_actor_id IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF p_idempotency_key IS NULL THEN RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED'; END IF;
  IF NULLIF(btrim(p_reason),'') IS NULL THEN RAISE EXCEPTION 'CANCEL_REASON_REQUIRED'; END IF;

  IF EXISTS(SELECT 1 FROM public.sales_payment_verification_requests request
    WHERE request.company_id=p_company_id AND request.sales_id=p_sales_id
      AND request.status='VERIFIED') THEN
    RAISE EXCEPTION 'SALES_ORDER_VERIFIED_PAYMENT_REVERSAL_REQUIRED';
  END IF;

  FOR v_request IN SELECT request.*
    FROM public.sales_payment_verification_requests request
    WHERE request.company_id=p_company_id AND request.sales_id=p_sales_id
      AND request.status='PENDING'
    ORDER BY request.id FOR UPDATE
  LOOP
    v_before:=to_jsonb(v_request);v_reversal:=NULL;
    IF v_request.settlement_route_snapshot='CASH_DRAWER' THEN
      SELECT session.* INTO v_source_session
      FROM public.cashier_sessions session
      WHERE session.company_id=p_company_id
        AND session.id=v_request.cashier_session_id FOR SHARE;
      IF NOT FOUND THEN RAISE EXCEPTION 'CASHIER_SESSION_NOT_FOUND'; END IF;

      IF v_source_session.status='OPEN'::public.session_status THEN
        v_refund_session:=v_source_session;
      ELSE
        SELECT session.* INTO v_refund_session
        FROM public.cashier_sessions session
        WHERE session.company_id=p_company_id
          AND session.cashier_id=p_actor_id
          AND session.store_id=v_request.store_id
          AND session.status='OPEN'::public.session_status
        ORDER BY session.opened_at DESC LIMIT 1 FOR SHARE;
        IF NOT FOUND THEN
          RAISE EXCEPTION 'SALES_ORDER_CASH_REFUND_REQUIRES_CURRENT_OPEN_SESSION';
        END IF;
        v_current_session_count:=v_current_session_count+1;
      END IF;

      SELECT movement.id INTO v_reversal
      FROM public.cash_drawer_movements movement
      WHERE movement.company_id=p_company_id
        AND movement.source_table='sales_payment_verification_reversal'
        AND movement.source_id=v_request.id;
      IF v_reversal IS NULL THEN
        v_expected:=private.calculate_cashier_session_expected_cash(
          p_company_id,v_refund_session.id)-v_request.amount;
        INSERT INTO public.cash_drawer_movements(company_id,store_id,pos_terminal_id,
          cashier_session_id,direction,movement_type,amount,source_table,source_id,
          expected_cash_after,actor_id)
        VALUES(p_company_id,v_refund_session.store_id,v_refund_session.pos_id,
          v_refund_session.id,'OUT','REVERSAL',v_request.amount,
          'sales_payment_verification_reversal',v_request.id,v_expected,p_actor_id)
        RETURNING id INTO v_reversal;
      END IF;
      v_cash_count:=v_cash_count+1;
    END IF;

    PERFORM set_config('kgs.odr5_payment_verification_mutation','1',TRUE);
    UPDATE public.sales_payment_verification_requests SET status='CANCELED',
      reviewed_by=p_actor_id,reviewed_at=v_now,
      review_note='Order dibatalkan: '||btrim(p_reason),
      cash_drawer_reversal_movement_id=v_reversal,
      master_version=master_version+1,updated_at=v_now
    WHERE company_id=p_company_id AND id=v_request.id
    RETURNING * INTO v_request;
    PERFORM set_config('kgs.odr5_payment_verification_mutation','',TRUE);
    v_after:=to_jsonb(v_request);
    INSERT INTO public.sales_payment_verification_audit(company_id,
      verification_request_id,action,actor_id,idempotency_key,before_state,after_state)
    VALUES(p_company_id,v_request.id,'CANCEL',p_actor_id,p_idempotency_key,
      v_before,v_after);
    v_count:=v_count+1;
  END LOOP;
  RETURN jsonb_build_object('canceledPaymentRequests',v_count,
    'cashDrawerReversals',v_cash_count,
    'currentSessionCashReversals',v_current_session_count);
END
$$;

-- The Backoffice action remains visible when the actor has an OPEN Cashier
-- session in the same Store, even if the source session is already CLOSED.
CREATE OR REPLACE FUNCTION public.get_sales_documents()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_actor UUID:=auth.uid();
  v_order_permission JSONB;v_can_cancel BOOLEAN;
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'sales.sales_documents','VIEW');
  v_order_permission:=private.acp_resolve_permission(
    v_company,v_actor,'sales.sales_orders');
  v_can_cancel:=(v_order_permission->'effectiveCapabilities') ? 'CANCEL_FINAL';
  RETURN jsonb_build_object('companyId',v_company,
    'effectiveOrderCapabilities',COALESCE(
      v_order_permission->'effectiveCapabilities','[]'::JSONB),
    'data',COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'salesId',invoice.sales_id,'invoiceSnapshotId',invoice.id,
      'invoiceNo',invoice.invoice_no,'snapshotProvenance',invoice.snapshot_provenance,
      'postedAt',COALESCE(sale.posted_at,sale.confirmed_at,invoice.created_at),
      'total',sale.grand_total_after_rounding,'fulfillmentMode',sale.fulfillment_mode,
      'sourceChannel',sale.source_channel,
      'customerName',COALESCE(customer.name,'Walk-In Customer'),
      'storeName',COALESCE(store.store_name,'Store'),
      'invoiceStatus',CASE WHEN sale.order_runtime_status='CANCELED'
        OR sale.document_status='CANCELED' THEN 'CANCELED' ELSE 'ACTIVE' END,
      'orderRuntimeStatus',sale.order_runtime_status,
      'masterVersion',sale.master_version,'canceledAt',sale.canceled_at,
      'cancelReason',sale.cancel_reason,'canceledBy',sale.canceled_by,
      'canceledByName',cancel_actor.name,
      'canCancel',v_can_cancel AND sale.document_status='DRAFT'
        AND sale.order_runtime_status IN('CONFIRMED','RESERVED')
        AND reservation.status='OPEN' AND reservation.total_dispatched_base_qty=0
        AND NOT EXISTS(SELECT 1 FROM public.sales_payment_verification_requests request
          WHERE request.company_id=sale.company_id AND request.sales_id=sale.id
            AND (request.status='VERIFIED' OR (request.status='PENDING'
              AND request.settlement_route_snapshot='CASH_DRAWER'
              AND NOT EXISTS(SELECT 1 FROM public.cashier_sessions session
                WHERE session.company_id=request.company_id
                  AND session.status='OPEN'::public.session_status
                  AND (session.id=request.cashier_session_id OR
                    (session.cashier_id=v_actor AND session.store_id=request.store_id))))))
      ) ORDER BY invoice.created_at DESC,invoice.id)
    FROM (SELECT candidate.* FROM public.sales_invoice_snapshots candidate
      WHERE candidate.company_id=v_company
      ORDER BY candidate.created_at DESC,candidate.id LIMIT 500) invoice
    JOIN public.sales_headers sale ON sale.company_id=invoice.company_id
      AND sale.id=invoice.sales_id
    LEFT JOIN public.customers customer ON customer.company_id=sale.company_id
      AND customer.id=sale.customer_id
    LEFT JOIN public.stores store ON store.company_id=sale.company_id
      AND store.id=sale.store_id
    LEFT JOIN public.profiles cancel_actor ON cancel_actor.id=sale.canceled_by
    LEFT JOIN public.sales_stock_reservations reservation
      ON reservation.company_id=sale.company_id AND reservation.sales_id=sale.id
  ),'[]'::JSONB));
END
$$;

CREATE OR REPLACE FUNCTION public.get_sales_invoice_document(p_sales_id UUID)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_actor UUID:=auth.uid();
  v_result JSONB;v_snapshot UUID;v_sale public.sales_headers%ROWTYPE;
  v_reservation public.sales_stock_reservations%ROWTYPE;v_cancel_name TEXT;
  v_permission JSONB;v_can_cancel BOOLEAN;
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'sales.sales_documents','VIEW');
  v_result:=private.acp5e_get_sales_invoice_document_core(p_sales_id);
  SELECT invoice.id INTO v_snapshot FROM public.sales_invoice_snapshots invoice
  WHERE invoice.company_id=v_company AND invoice.sales_id=p_sales_id;
  SELECT sale.* INTO v_sale FROM public.sales_headers sale
  WHERE sale.company_id=v_company AND sale.id=p_sales_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'SALES_DOCUMENT_NOT_FOUND'; END IF;
  SELECT reservation.* INTO v_reservation FROM public.sales_stock_reservations reservation
  WHERE reservation.company_id=v_company AND reservation.sales_id=p_sales_id;
  SELECT profile.name INTO v_cancel_name FROM public.profiles profile
  WHERE profile.id=v_sale.canceled_by;
  v_permission:=private.acp_resolve_permission(v_company,v_actor,'sales.sales_orders');
  v_can_cancel:=(v_permission->'effectiveCapabilities') ? 'CANCEL_FINAL'
    AND v_sale.document_status='DRAFT'
    AND v_sale.order_runtime_status IN('CONFIRMED','RESERVED')
    AND v_reservation.status='OPEN' AND v_reservation.total_dispatched_base_qty=0
    AND NOT EXISTS(SELECT 1 FROM public.sales_payment_verification_requests request
      WHERE request.company_id=v_company AND request.sales_id=p_sales_id
        AND (request.status='VERIFIED' OR (request.status='PENDING'
          AND request.settlement_route_snapshot='CASH_DRAWER'
          AND NOT EXISTS(SELECT 1 FROM public.cashier_sessions session
            WHERE session.company_id=request.company_id
              AND session.status='OPEN'::public.session_status
              AND (session.id=request.cashier_session_id OR
                (session.cashier_id=v_actor AND session.store_id=request.store_id))))));
  RETURN v_result||jsonb_build_object('invoiceSnapshotId',v_snapshot,
    'invoiceStatus',CASE WHEN v_sale.order_runtime_status='CANCELED'
      OR v_sale.document_status='CANCELED' THEN 'CANCELED' ELSE 'ACTIVE' END,
    'orderRuntimeStatus',v_sale.order_runtime_status,
    'masterVersion',v_sale.master_version,'canceledAt',v_sale.canceled_at,
    'cancelReason',v_sale.cancel_reason,'canceledBy',v_sale.canceled_by,
    'canceledByName',v_cancel_name,'canCancel',v_can_cancel);
END
$$;

REVOKE ALL ON FUNCTION
  private.cancel_pending_sales_order_payments(UUID,UUID,UUID,UUID,TEXT)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.cancel_pending_sales_order_payments(UUID,UUID,UUID,UUID,TEXT)
TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260830120000','sales_order_closed_session_cash_cancel',
  'Cancel pending Cash Order after source session close by recording one reversal in actor current OPEN same-Store session; preserve source closing, Reservation/SJ/procurement composition, payment audit, verified-payment guard and idempotency');

NOTIFY pgrst,'reload schema';
COMMIT;
