-- Allow a canonical future Scheduled TEMPO Draft to be saved/repriced without
-- weakening the effective-date guard used by active posting.
BEGIN;

DO $guard$
DECLARE v_definition text;v_public_definition text;
BEGIN
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260910100000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260910100000';
  END IF;
  IF (SELECT count(*) FROM private.kgs_schema_migrations WHERE version IN(
      '20260827090000','20260827154000','20260830100000',
      '20260904110000','20260904130000','20260904140000'))<>6
    OR to_regprocedure(
      'private.validate_pos_scheduled_order_dates(uuid,date,timestamptz,text,timestamptz)') IS NULL
    OR to_regprocedure(
      'private.validate_pos_tempo_effective_dates(uuid,timestamptz,timestamptz,text,timestamptz)') IS NULL
    OR to_regprocedure(
      'private.save_pos_sale_draft_before_schedule_core(jsonb)') IS NULL
    OR to_regprocedure('private.save_pos_sale_draft_core(jsonb)') IS NULL
    OR to_regprocedure('public.post_pos_sale(uuid,bigint,uuid)') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical Scheduled/TEMPO/revision chain incomplete';
  END IF;
  IF to_regprocedure(
      'private.validate_pos_tempo_draft_save_dates(uuid,text,date,timestamptz,timestamptz,text,timestamptz,text)'
    ) IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: scheduled resume helper collision';
  END IF;
  SELECT pg_get_functiondef(
    'private.save_pos_sale_draft_before_schedule_core(jsonb)'::regprocedure
  ) INTO v_definition;
  IF position('validate_pos_tempo_effective_dates' in v_definition)=0
    OR position('validate_pos_tempo_draft_save_dates' in v_definition)>0 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Draft save wrapper drift';
  END IF;
  SELECT lower(regexp_replace(pg_get_functiondef(
    'public.save_pos_sale_draft_with_pricelist(jsonb)'::regprocedure),
    '[[:space:]]+','','g')) INTO v_public_definition;
  IF position('private.save_pos_sale_draft_before_schedule_core(v_core_payload)'
      in v_public_definition)=0
    OR position('v_mode:=''scheduled''' in v_public_definition)=0
    OR position('scheduled_order_tempo_required' in v_public_definition)=0 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: public Scheduled Draft wrapper drift';
  END IF;
  IF position('SCHEDULED_ORDER_NOT_ACTIVE' in pg_get_functiondef(
      'public.post_pos_sale(uuid,bigint,uuid)'::regprocedure))=0 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Scheduled early-post guard drift';
  END IF;
  IF position('MASTER_VERSION_CONFLICT' in pg_get_functiondef(
      'private.save_pos_sale_draft_core(jsonb)'::regprocedure))=0 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Draft optimistic-version guard drift';
  END IF;
  IF EXISTS(SELECT 1 FROM public.sales_headers sale
    WHERE sale.document_status='DRAFT' AND sale.order_timing_mode='SCHEDULED'
      AND (NOT sale.is_tempo OR sale.planned_order_date IS NULL
        OR sale.planned_order_selected_by IS NULL
        OR sale.planned_order_selected_at IS NULL)) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: invalid Scheduled Draft shape';
  END IF;
  IF EXISTS(SELECT 1 FROM public.sales_headers sale
    JOIN public.companies company ON company.id=sale.company_id
    WHERE sale.document_status='DRAFT' AND sale.order_timing_mode='SCHEDULED'
      AND (sale.payload_snapshot IS NULL OR NOT(sale.payload_snapshot?'isTempo')
        OR jsonb_typeof(sale.payload_snapshot->'isTempo')<>'boolean'
        OR sale.payload_snapshot->'isTempo'<>'true'::jsonb
        OR NULLIF(sale.payload_snapshot->>'plannedOrderAt','') IS NULL
        OR (NULLIF(sale.payload_snapshot->>'plannedOrderAt','')::timestamptz
              AT TIME ZONE company.timezone)::date
            IS DISTINCT FROM sale.planned_order_date)) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Scheduled Draft payload identity drift';
  END IF;
END
$guard$;

CREATE FUNCTION private.validate_pos_tempo_draft_save_dates(
  p_company_id uuid,p_order_timing_mode text,p_planned_order_date date,
  p_transaction_at timestamptz,p_due_at timestamptz,p_fulfillment_mode text,
  p_delivery_scheduled_at timestamptz,p_transaction_date_intent text
) RETURNS text LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_timezone text;v_today date;v_transaction_date date;
BEGIN
  SELECT company.timezone INTO v_timezone FROM public.companies company
  WHERE company.id=p_company_id AND company.status='ACTIVE';
  IF v_timezone IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_NOT_FOUND'; END IF;
  IF p_transaction_at IS NULL THEN
    RAISE EXCEPTION 'TEMPO_TRANSACTION_DATE_REQUIRED';
  END IF;
  v_today:=(clock_timestamp() AT TIME ZONE v_timezone)::date;
  v_transaction_date:=(p_transaction_at AT TIME ZONE v_timezone)::date;

  IF p_transaction_date_intent='PRESERVE'
    AND p_order_timing_mode='SCHEDULED'
    AND p_planned_order_date IS NOT NULL
    AND p_planned_order_date>v_today THEN
    IF v_transaction_date IS DISTINCT FROM p_planned_order_date THEN
      RAISE EXCEPTION 'SCHEDULED_ORDER_DATE_IDENTITY_MISMATCH';
    END IF;
    PERFORM private.validate_pos_scheduled_order_dates(
      p_company_id,p_planned_order_date,p_due_at,p_fulfillment_mode,
      p_delivery_scheduled_at);
    RETURN 'SCHEDULED_PRESERVE';
  END IF;

  PERFORM private.validate_pos_tempo_effective_dates(
    p_company_id,p_transaction_at,p_due_at,p_fulfillment_mode,
    p_delivery_scheduled_at);
  RETURN 'EFFECTIVE';
END
$$;

CREATE OR REPLACE FUNCTION private.save_pos_sale_draft_before_schedule_core(
  p_payload jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
  v_company uuid:=public.private_active_company_id();
  v_actor uuid:=auth.uid();
  v_existing_id uuid;
  v_existing_payload jsonb;
  v_timezone text;
  v_result jsonb;
  v_sale public.sales_headers%rowtype;
  v_requested_at timestamptz;
  v_intent text:=upper(COALESCE(NULLIF(p_payload->>'transactionDateIntent',''),
    CASE WHEN p_payload?'transactionAt' THEN 'CASHIER_SELECTED' ELSE 'PRESERVE' END));
BEGIN
  IF jsonb_typeof(p_payload)<>'object' THEN RAISE EXCEPTION 'INVALID_SALE_PAYLOAD'; END IF;
  IF v_intent NOT IN('PRESERVE','CASHIER_SELECTED') THEN
    RAISE EXCEPTION 'TEMPO_TRANSACTION_DATE_INTENT_INVALID';
  END IF;
  BEGIN
    v_existing_id:=NULLIF(p_payload->>'saleId','')::uuid;
  EXCEPTION WHEN invalid_text_representation THEN
    RAISE EXCEPTION 'INVALID_SALE_IDENTITY';
  END;
  IF v_existing_id IS NOT NULL THEN
    -- Deliberately no pre-save row lock: the unchanged canonical save below
    -- owns lock ordering and rejects a stale payload through masterVersion.
    SELECT sale.payload_snapshot INTO v_existing_payload
    FROM public.sales_headers sale
    WHERE sale.company_id=v_company AND sale.id=v_existing_id;
  END IF;
  PERFORM set_config('kgs.selected_pricelist_id',
    COALESCE(NULLIF(p_payload->>'selectedPricelistId',''),''),true);
  v_result:=public.save_pos_sale_draft(p_payload);
  SELECT sale.* INTO v_sale FROM public.sales_headers sale
  WHERE sale.company_id=v_company AND sale.id=(v_result->>'salesId')::uuid
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'SALE_DRAFT_TRANSACTION_DATE_NOT_FOUND'; END IF;
  SELECT company.timezone INTO v_timezone FROM public.companies company
  WHERE company.id=v_company AND company.status='ACTIVE';
  IF v_timezone IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_NOT_FOUND'; END IF;

  IF v_sale.document_status='DRAFT' AND v_sale.is_tempo THEN
    BEGIN
      v_requested_at:=CASE WHEN v_intent='CASHIER_SELECTED'
        THEN (p_payload->>'transactionAt')::timestamptz
        WHEN v_sale.order_timing_mode='SCHEDULED'
          THEN COALESCE(
            NULLIF(v_existing_payload->>'plannedOrderAt','')::timestamptz,
            CASE WHEN (v_sale.transaction_date AT TIME ZONE v_timezone)::date
                IS NOT DISTINCT FROM v_sale.planned_order_date
              THEN v_sale.transaction_date END,
            (v_sale.planned_order_date::text||' 12:00:00')::timestamp
              AT TIME ZONE v_timezone)
        ELSE v_sale.transaction_date END;
    EXCEPTION WHEN invalid_datetime_format THEN
      RAISE EXCEPTION 'TEMPO_TRANSACTION_DATE_INVALID';
    END;
    IF v_requested_at IS NULL THEN RAISE EXCEPTION 'TEMPO_TRANSACTION_DATE_REQUIRED'; END IF;
    PERFORM private.validate_pos_tempo_draft_save_dates(
      v_company,v_sale.order_timing_mode,v_sale.planned_order_date,
      v_requested_at,v_sale.due_date,v_sale.fulfillment_mode,
      v_sale.delivery_scheduled_at,v_intent);
    IF v_intent='PRESERVE' AND v_sale.order_timing_mode='SCHEDULED' THEN
      UPDATE public.sales_headers sale SET
        payload_snapshot=COALESCE(sale.payload_snapshot,'{}'::jsonb)
          ||jsonb_build_object('plannedOrderDate',v_sale.planned_order_date,
            'plannedOrderAt',v_requested_at,'orderTimingMode','SCHEDULED',
            'transactionAt',v_requested_at,
            'transactionDateIntent','CASHIER_SELECTED')
      WHERE sale.company_id=v_company AND sale.id=v_sale.id;
    END IF;
    IF v_intent='CASHIER_SELECTED' THEN
      UPDATE public.sales_headers sale SET
        transaction_date=v_requested_at,
        transaction_date_source='CASHIER_SELECTED',
        transaction_date_selected_by=v_actor,
        transaction_date_selected_at=clock_timestamp(),
        payload_snapshot=COALESCE(sale.payload_snapshot,'{}'::jsonb)
          ||jsonb_build_object('transactionAt',v_requested_at,
            'transactionDateIntent','CASHIER_SELECTED')
      WHERE sale.company_id=v_company AND sale.id=v_sale.id;
      v_sale.transaction_date:=v_requested_at;
      v_sale.transaction_date_source:='CASHIER_SELECTED';
    END IF;
  ELSIF v_sale.document_status='DRAFT'
        AND v_sale.transaction_date_source='CASHIER_SELECTED' THEN
    UPDATE public.sales_headers sale SET
      transaction_date=sale.created_at,transaction_date_source='SERVER_CREATED',
      transaction_date_selected_by=NULL,transaction_date_selected_at=NULL,
      payload_snapshot=COALESCE(sale.payload_snapshot,'{}'::jsonb)
        -'transactionAt'-'transactionDateIntent'
    WHERE sale.company_id=v_company AND sale.id=v_sale.id;
    v_sale.transaction_date:=v_sale.created_at;
    v_sale.transaction_date_source:='SERVER_CREATED';
  END IF;
  RETURN v_result||jsonb_build_object('transactionAt',v_sale.transaction_date,
    'transactionDateSource',v_sale.transaction_date_source);
END
$$;

REVOKE ALL ON FUNCTION private.validate_pos_tempo_draft_save_dates(
  uuid,text,date,timestamptz,timestamptz,text,timestamptz,text)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.validate_pos_tempo_draft_save_dates(
  uuid,text,date,timestamptz,timestamptz,text,timestamptz,text)
TO service_role;
REVOKE ALL ON FUNCTION private.save_pos_sale_draft_before_schedule_core(jsonb)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.save_pos_sale_draft_before_schedule_core(jsonb)
TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260910100000','pos_scheduled_draft_resume_fix',
  'Route future Scheduled TEMPO Draft save/reprice with PRESERVE intent through Scheduled date validation while retaining active TEMPO effective-date, posting, period, due-date and delivery guards');

NOTIFY pgrst,'reload schema';
COMMIT;
