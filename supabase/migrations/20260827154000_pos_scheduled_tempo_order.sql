BEGIN;

DO $guard$
DECLARE v_count INTEGER;
BEGIN
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260827154000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED';
  END IF;
  SELECT count(*) INTO v_count FROM pg_proc procedure
  JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
  WHERE (namespace.nspname,procedure.proname,
    pg_get_function_identity_arguments(procedure.oid)) IN (
      ('public','save_pos_sale_draft_with_pricelist','p_payload jsonb'),
      ('public','list_pos_sale_drafts','p_store_id uuid'),
      ('public','post_pos_sale','p_sales_id uuid, p_master_version bigint, p_posting_idempotency_key uuid')
    );
  IF v_count<>3 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical POS Draft runtime';
  END IF;
END
$guard$;

ALTER TABLE public.sales_headers
  ADD COLUMN planned_order_date DATE,
  ADD COLUMN order_timing_mode TEXT NOT NULL DEFAULT 'IMMEDIATE',
  ADD COLUMN planned_order_selected_by UUID
    REFERENCES public.profiles(id) ON DELETE RESTRICT,
  ADD COLUMN planned_order_selected_at TIMESTAMPTZ,
  ADD COLUMN scheduled_activated_at TIMESTAMPTZ,
  ADD CONSTRAINT sales_headers_order_timing_mode_check CHECK(
    order_timing_mode IN('IMMEDIATE','BACKORDER','SCHEDULED')),
  ADD CONSTRAINT sales_headers_planned_order_contract CHECK(
    (order_timing_mode='IMMEDIATE' AND planned_order_date IS NULL
      AND planned_order_selected_by IS NULL
      AND planned_order_selected_at IS NULL)
    OR
    (order_timing_mode IN('BACKORDER','SCHEDULED')
      AND is_tempo AND planned_order_date IS NOT NULL
      AND planned_order_selected_by IS NOT NULL
      AND planned_order_selected_at IS NOT NULL)),
  ADD CONSTRAINT sales_headers_schedule_activation_contract CHECK(
    scheduled_activated_at IS NULL OR order_timing_mode='SCHEDULED');

CREATE INDEX idx_sales_headers_scheduled_draft_date
  ON public.sales_headers(company_id,store_id,planned_order_date,updated_at DESC)
  WHERE document_status='DRAFT' AND order_timing_mode='SCHEDULED';

ALTER TABLE public.sale_master_audit
  DROP CONSTRAINT sale_master_audit_action_check,
  ADD CONSTRAINT sale_master_audit_action_check CHECK(action IN(
    'CREATE_DRAFT','UPDATE_DRAFT','STOCK_SHORTAGE','POST',
    'LOCK_ACQUIRE','LOCK_HEARTBEAT','LOCK_TAKEOVER',
    'LOCK_FORCE_RELEASE','LOCK_RELEASE','CANCEL_DRAFT','SCHEDULE_ACTIVATE'));

CREATE FUNCTION private.validate_pos_scheduled_order_dates(
  p_company_id UUID,p_planned_order_date DATE,p_due_at TIMESTAMPTZ,
  p_fulfillment_mode TEXT,p_delivery_scheduled_at TIMESTAMPTZ
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_timezone TEXT; v_due_date DATE; v_delivery_date DATE;
BEGIN
  SELECT company.timezone INTO v_timezone FROM public.companies company
  WHERE company.id=p_company_id AND company.status='ACTIVE';
  IF v_timezone IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_NOT_FOUND'; END IF;
  IF p_planned_order_date IS NULL THEN RAISE EXCEPTION 'PLANNED_ORDER_DATE_REQUIRED'; END IF;
  v_due_date:=CASE WHEN p_due_at IS NULL THEN NULL
    ELSE (p_due_at AT TIME ZONE v_timezone)::DATE END;
  v_delivery_date:=CASE WHEN p_delivery_scheduled_at IS NULL THEN NULL
    ELSE (p_delivery_scheduled_at AT TIME ZONE v_timezone)::DATE END;
  IF v_due_date IS NULL OR v_due_date<p_planned_order_date THEN
    RAISE EXCEPTION 'TEMPO_DUE_DATE_BEFORE_PLANNED_ORDER';
  END IF;
  IF p_fulfillment_mode='DELIVERY' AND v_delivery_date IS NOT NULL
     AND v_delivery_date<p_planned_order_date THEN
    RAISE EXCEPTION 'DELIVERY_DATE_BEFORE_PLANNED_ORDER';
  END IF;
END
$$;

REVOKE ALL ON FUNCTION private.validate_pos_scheduled_order_dates(
  UUID,DATE,TIMESTAMPTZ,TEXT,TIMESTAMPTZ) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.validate_pos_scheduled_order_dates(
  UUID,DATE,TIMESTAMPTZ,TEXT,TIMESTAMPTZ) TO service_role;

ALTER FUNCTION public.save_pos_sale_draft_with_pricelist(JSONB)
  SET SCHEMA private;
ALTER FUNCTION private.save_pos_sale_draft_with_pricelist(JSONB)
  RENAME TO save_pos_sale_draft_before_schedule_core;

CREATE FUNCTION public.save_pos_sale_draft_with_pricelist(p_payload JSONB)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
  v_company UUID:=public.private_active_company_id();
  v_actor UUID:=auth.uid();
  v_timezone TEXT;
  v_today DATE;
  v_intent TEXT:=upper(COALESCE(NULLIF(p_payload->>'transactionDateIntent',''),'PRESERVE'));
  v_requested_at TIMESTAMPTZ;
  v_requested_date DATE;
  v_core_payload JSONB:=p_payload;
  v_result JSONB;
  v_sale public.sales_headers%ROWTYPE;
  v_mode TEXT;
BEGIN
  IF jsonb_typeof(p_payload)<>'object' THEN RAISE EXCEPTION 'INVALID_SALE_PAYLOAD'; END IF;
  SELECT company.timezone INTO v_timezone FROM public.companies company
  WHERE company.id=v_company AND company.status='ACTIVE';
  IF v_timezone IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_NOT_FOUND'; END IF;
  v_today:=(clock_timestamp() AT TIME ZONE v_timezone)::DATE;

  IF v_intent='CASHIER_SELECTED' THEN
    BEGIN v_requested_at:=(p_payload->>'transactionAt')::TIMESTAMPTZ;
    EXCEPTION WHEN invalid_datetime_format OR null_value_not_allowed THEN
      RAISE EXCEPTION 'TEMPO_TRANSACTION_DATE_INVALID';
    END;
    IF v_requested_at IS NULL THEN RAISE EXCEPTION 'TEMPO_TRANSACTION_DATE_REQUIRED'; END IF;
    v_requested_date:=(v_requested_at AT TIME ZONE v_timezone)::DATE;
  ELSIF v_intent<>'PRESERVE' THEN
    RAISE EXCEPTION 'TEMPO_TRANSACTION_DATE_INTENT_INVALID';
  END IF;

  IF v_intent='CASHIER_SELECTED' AND v_requested_date>v_today THEN
    IF NOT COALESCE((p_payload->>'isTempo')::BOOLEAN,FALSE) THEN
      RAISE EXCEPTION 'SCHEDULED_ORDER_TEMPO_REQUIRED';
    END IF;
    PERFORM private.validate_pos_scheduled_order_dates(v_company,v_requested_date,
      NULLIF(p_payload->>'dueDate','')::TIMESTAMPTZ,
      upper(COALESCE(NULLIF(p_payload->>'fulfillmentMode',''),'PICKUP')),
      NULLIF(p_payload->>'deliveryScheduledAt','')::TIMESTAMPTZ);
    v_core_payload:=(p_payload-'transactionAt')||jsonb_build_object(
      'transactionDateIntent','PRESERVE');
  END IF;

  v_result:=private.save_pos_sale_draft_before_schedule_core(v_core_payload);
  SELECT sale.* INTO v_sale FROM public.sales_headers sale
  WHERE sale.company_id=v_company AND sale.id=(v_result->>'salesId')::UUID
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'SALE_DRAFT_TRANSACTION_DATE_NOT_FOUND'; END IF;

  IF NOT v_sale.is_tempo THEN
    UPDATE public.sales_headers SET planned_order_date=NULL,
      order_timing_mode='IMMEDIATE',planned_order_selected_by=NULL,
      planned_order_selected_at=NULL,scheduled_activated_at=NULL,
      payload_snapshot=COALESCE(payload_snapshot,'{}'::JSONB)
        -'plannedOrderDate'-'orderTimingMode'-'plannedOrderAt'
    WHERE company_id=v_company AND id=v_sale.id;
    v_mode:='IMMEDIATE';
  ELSIF v_intent='CASHIER_SELECTED' AND v_requested_date>v_today THEN
    UPDATE public.sales_headers SET planned_order_date=v_requested_date,
      order_timing_mode='SCHEDULED',planned_order_selected_by=v_actor,
      planned_order_selected_at=clock_timestamp(),scheduled_activated_at=NULL,
      payload_snapshot=COALESCE(payload_snapshot,'{}'::JSONB)||jsonb_build_object(
        'plannedOrderDate',v_requested_date,'plannedOrderAt',v_requested_at,
        'orderTimingMode','SCHEDULED','transactionAt',v_requested_at,
        'transactionDateIntent','CASHIER_SELECTED')
    WHERE company_id=v_company AND id=v_sale.id;
    v_mode:='SCHEDULED';
  ELSIF v_intent='CASHIER_SELECTED' AND v_requested_date<v_today THEN
    UPDATE public.sales_headers SET planned_order_date=v_requested_date,
      order_timing_mode='BACKORDER',planned_order_selected_by=v_actor,
      planned_order_selected_at=clock_timestamp(),scheduled_activated_at=NULL,
      payload_snapshot=COALESCE(payload_snapshot,'{}'::JSONB)||jsonb_build_object(
        'plannedOrderDate',v_requested_date,'orderTimingMode','BACKORDER')
    WHERE company_id=v_company AND id=v_sale.id;
    v_mode:='BACKORDER';
  ELSIF v_intent='CASHIER_SELECTED' THEN
    UPDATE public.sales_headers SET planned_order_date=NULL,
      order_timing_mode='IMMEDIATE',planned_order_selected_by=NULL,
      planned_order_selected_at=NULL,scheduled_activated_at=NULL,
      payload_snapshot=COALESCE(payload_snapshot,'{}'::JSONB)
        -'plannedOrderDate'-'orderTimingMode'-'plannedOrderAt'
    WHERE company_id=v_company AND id=v_sale.id;
    v_mode:='IMMEDIATE';
  ELSE
    v_mode:=v_sale.order_timing_mode;
    v_requested_date:=v_sale.planned_order_date;
    IF v_mode='SCHEDULED' THEN
      v_requested_at:=COALESCE(
        NULLIF(v_sale.payload_snapshot->>'plannedOrderAt','')::TIMESTAMPTZ,
        (v_requested_date::TEXT||' 12:00:00')::TIMESTAMP AT TIME ZONE v_timezone
      );
      UPDATE public.sales_headers SET
        payload_snapshot=COALESCE(payload_snapshot,'{}'::JSONB)||jsonb_build_object(
          'plannedOrderDate',v_requested_date,'plannedOrderAt',v_requested_at,
          'orderTimingMode','SCHEDULED','transactionAt',v_requested_at,
          'transactionDateIntent','CASHIER_SELECTED')
      WHERE company_id=v_company AND id=v_sale.id;
    END IF;
  END IF;

  RETURN v_result||jsonb_build_object('orderTimingMode',v_mode,
    'plannedOrderDate',v_requested_date,
    'operationalStatus',CASE WHEN v_mode='SCHEDULED' AND v_requested_date>v_today
      THEN 'SCHEDULED' ELSE 'ACTIVE' END,
    'transactionAt',COALESCE(v_requested_at::TEXT,v_result->>'transactionAt'));
END
$$;

ALTER FUNCTION public.post_pos_sale(UUID,BIGINT,UUID) SET SCHEMA private;
ALTER FUNCTION private.post_pos_sale(UUID,BIGINT,UUID)
  RENAME TO post_pos_sale_before_schedule_core;

CREATE FUNCTION public.post_pos_sale(p_sales_id UUID,p_master_version BIGINT,
  p_posting_idempotency_key UUID) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE
  v_company UUID:=public.private_active_company_id();
  v_actor UUID:=auth.uid();
  v_timezone TEXT;
  v_today DATE;
  v_now TIMESTAMPTZ:=clock_timestamp();
  v_sale public.sales_headers%ROWTYPE;
BEGIN
  SELECT sale.* INTO v_sale FROM public.sales_headers sale
  WHERE sale.company_id=v_company AND sale.id=p_sales_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'SALE_DRAFT_NOT_FOUND'; END IF;
  IF v_sale.document_status='DRAFT' AND v_sale.order_timing_mode='SCHEDULED' THEN
    SELECT company.timezone INTO v_timezone FROM public.companies company
    WHERE company.id=v_company AND company.status='ACTIVE';
    v_today:=(v_now AT TIME ZONE v_timezone)::DATE;
    IF v_sale.planned_order_date>v_today THEN
      RAISE EXCEPTION 'SCHEDULED_ORDER_NOT_ACTIVE';
    END IF;
    IF v_sale.scheduled_activated_at IS NULL THEN
      PERFORM private.validate_pos_tempo_effective_dates(v_company,v_now,
        v_sale.due_date,v_sale.fulfillment_mode,v_sale.delivery_scheduled_at);
      UPDATE public.sales_headers SET transaction_date=v_now,
        transaction_date_source='SERVER_CREATED',transaction_date_selected_by=NULL,
        transaction_date_selected_at=NULL,scheduled_activated_at=v_now,
        payload_snapshot=COALESCE(payload_snapshot,'{}'::JSONB)||jsonb_build_object(
          'activatedAt',v_now,'actualTransactionAt',v_now)
      WHERE company_id=v_company AND id=p_sales_id;
      INSERT INTO public.sale_master_audit(company_id,sales_id,action,actor_id,
        before_state,after_state) VALUES(v_company,p_sales_id,'SCHEDULE_ACTIVATE',v_actor,
        jsonb_build_object('plannedOrderDate',v_sale.planned_order_date,
          'transactionAt',v_sale.transaction_date),
        jsonb_build_object('plannedOrderDate',v_sale.planned_order_date,
          'transactionAt',v_now));
    END IF;
  END IF;
  RETURN private.post_pos_sale_before_schedule_core(p_sales_id,p_master_version,
    p_posting_idempotency_key);
END
$$;

CREATE OR REPLACE FUNCTION public.list_pos_sale_drafts(p_store_id UUID DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id(); v_timezone TEXT; v_today DATE;
BEGIN
  SELECT company.timezone INTO v_timezone FROM public.companies company
  WHERE company.id=v_company;
  v_today:=(clock_timestamp() AT TIME ZONE v_timezone)::DATE;
  RETURN (SELECT COALESCE(jsonb_agg(item ORDER BY
      CASE WHEN operational_status='ACTIVE' THEN 1 ELSE 2 END,
      planned_date NULLS FIRST,updated_at DESC),'[]'::JSONB)
    FROM (SELECT sale.updated_at,sale.planned_order_date planned_date,
      CASE WHEN sale.order_timing_mode='SCHEDULED'
        AND sale.planned_order_date>v_today THEN 'SCHEDULED' ELSE 'ACTIVE' END operational_status,
      jsonb_build_object('salesId',sale.id,'draftNo',sale.draft_no,
        'draftLabel',sale.draft_label,'draftNotes',sale.draft_notes,
        'draftReason',sale.draft_reason,'customerId',sale.customer_id,
        'customerName',customer.name,'storeId',sale.store_id,'storeName',store.store_name,
        'createdBy',sale.created_by,'createdByName',creator.name,'createdAt',sale.created_at,
        'transactionAt',CASE WHEN sale.order_timing_mode='SCHEDULED'
          THEN COALESCE(sale.payload_snapshot->>'plannedOrderAt',sale.transaction_date::TEXT)
          ELSE sale.transaction_date::TEXT END,
        'transactionDateSource',sale.transaction_date_source,'updatedAt',sale.updated_at,
        'masterVersion',sale.master_version,'grandTotal',sale.grand_total_after_rounding,
        'lineCount',(SELECT count(*) FROM public.sales_details detail
          WHERE detail.company_id=sale.company_id AND detail.sales_id=sale.id),
        'isStale',sale.created_at<clock_timestamp()-interval '7 days',
        'orderTimingMode',sale.order_timing_mode,
        'plannedOrderDate',sale.planned_order_date,
        'operationalStatus',CASE WHEN sale.order_timing_mode='SCHEDULED'
          AND sale.planned_order_date>v_today THEN 'SCHEDULED' ELSE 'ACTIVE' END,
        'canPost',NOT(sale.order_timing_mode='SCHEDULED'
          AND sale.planned_order_date>v_today),
        'lockOwnerId',sale.edit_lock_owner_id,'lockOwnerName',lock_owner.name,
        'lockSessionId',sale.edit_lock_session_id,
        'lockHeartbeatAt',sale.edit_lock_heartbeat_at,
        'lockExpired',sale.edit_lock_heartbeat_at IS NOT NULL AND
          sale.edit_lock_heartbeat_at<clock_timestamp()-interval '5 minutes',
        'payloadSnapshot',sale.payload_snapshot) item
      FROM public.sales_headers sale
      JOIN public.customers customer ON customer.company_id=sale.company_id
       AND customer.id=sale.customer_id
      JOIN public.stores store ON store.company_id=sale.company_id AND store.id=sale.store_id
      JOIN public.profiles creator ON creator.id=sale.created_by
      LEFT JOIN public.profiles lock_owner ON lock_owner.id=sale.edit_lock_owner_id
      WHERE sale.company_id=v_company AND sale.document_status='DRAFT'
        AND (p_store_id IS NULL OR sale.store_id=p_store_id)
        AND (public.private_user_has_any_company_role(sale.company_id,
          ARRAY['COMPANY_OWNER','COMPANY_ADMIN']::TEXT[])
          OR public.private_user_has_any_store_role(sale.store_id,
          ARRAY['CASHIER','STORE_MANAGER']::TEXT[]))) visible);
END
$$;

REVOKE ALL ON FUNCTION
  private.save_pos_sale_draft_before_schedule_core(JSONB),
  private.post_pos_sale_before_schedule_core(UUID,BIGINT,UUID)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.save_pos_sale_draft_before_schedule_core(JSONB),
  private.post_pos_sale_before_schedule_core(UUID,BIGINT,UUID)
TO service_role;
REVOKE ALL ON FUNCTION public.save_pos_sale_draft_with_pricelist(JSONB),
  public.post_pos_sale(UUID,BIGINT,UUID),public.list_pos_sale_drafts(UUID)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.save_pos_sale_draft_with_pricelist(JSONB),
  public.post_pos_sale(UUID,BIGINT,UUID),public.list_pos_sale_drafts(UUID)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260827154000','pos_scheduled_tempo_order',
  'Adds future TEMPO Draft scheduling with Company-date activation, server Post guard, preserved planned date, same-Store session continuation, and zero final effect before manual Post');

COMMIT;
