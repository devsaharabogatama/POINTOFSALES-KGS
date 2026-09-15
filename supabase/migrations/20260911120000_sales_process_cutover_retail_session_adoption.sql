-- Step 4D/6: attach Backoffice-cutover Retail Drafts to a real matching POS
-- session and allow payment-only saves without silently repricing commerce.
BEGIN;

DO $guard$
DECLARE v_definition text;
BEGIN
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260911120000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED';
  END IF;
  IF (SELECT count(*) FROM private.kgs_schema_migrations
    WHERE version IN('20260910130000','20260911110000','20260911111000'))<>3
    OR to_regprocedure('public.list_pos_sale_drafts(uuid)') IS NULL
    OR to_regprocedure('public.acquire_pos_sale_draft_lock(uuid,uuid,boolean)') IS NULL
    OR to_regprocedure('public.save_pos_sale_draft_with_pricelist(jsonb)') IS NULL
    OR to_regprocedure('private.sales_process_retail_identity_is_valid(text,text,uuid,uuid,uuid)') IS NULL
    OR to_regprocedure('private.trg_guard_sales_process_identity()') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical cutover/POS chain incomplete';
  END IF;
  IF to_regclass('public.sales_cutover_retail_adoption_operations') IS NOT NULL
    OR to_regprocedure('public.adopt_backoffice_cutover_sale_draft(uuid,bigint,uuid,uuid,boolean)') IS NOT NULL
    OR to_regprocedure('public.save_backoffice_cutover_sale_draft_preserved(uuid,bigint,uuid,uuid,jsonb)') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Step 4D object collision';
  END IF;
  SELECT pg_get_functiondef('public.list_pos_sale_drafts(uuid)'::regprocedure)
    INTO v_definition;
  IF position('sale.confirmed_at IS NULL' in v_definition)=0
    OR position('sale.order_runtime_status IN(''DRAFT_INPUT'',''SCHEDULED'')' in v_definition)=0 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical Draft list drift';
  END IF;
END
$guard$;

CREATE TABLE public.sales_cutover_retail_adoption_operations(
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id uuid NOT NULL,
  operation_id uuid NOT NULL,
  sales_id uuid NOT NULL,
  cashier_session_id uuid NOT NULL,
  operation_type text NOT NULL,
  expected_master_version bigint NOT NULL,
  request_hash text NOT NULL,
  response_snapshot jsonb NOT NULL,
  actor_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT sales_cutover_retail_adoption_operation_unique
    UNIQUE(company_id,operation_id),
  CONSTRAINT sales_cutover_retail_adoption_sale_fk
    FOREIGN KEY(company_id,sales_id)
    REFERENCES public.sales_headers(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT sales_cutover_retail_adoption_type_check
    CHECK(operation_type IN('ADOPT','PRESERVE_SAVE')),
  CONSTRAINT sales_cutover_retail_adoption_version_check
    CHECK(expected_master_version>0),
  CONSTRAINT sales_cutover_retail_adoption_hash_check
    CHECK(request_hash~'^[0-9a-f]{64}$'),
  CONSTRAINT sales_cutover_retail_adoption_response_check
    CHECK(jsonb_typeof(response_snapshot)='object')
);
CREATE INDEX sales_cutover_retail_adoption_sale_time
  ON public.sales_cutover_retail_adoption_operations(company_id,sales_id,created_at DESC);
ALTER TABLE public.sales_cutover_retail_adoption_operations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.sales_cutover_retail_adoption_operations
  FROM PUBLIC,anon,authenticated;
GRANT SELECT,INSERT ON TABLE public.sales_cutover_retail_adoption_operations
  TO service_role;
GRANT USAGE,SELECT ON SEQUENCE public.sales_cutover_retail_adoption_operations_id_seq
  TO service_role;

CREATE FUNCTION private.trg_sales_cutover_retail_adoption_immutable()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
BEGIN
  RAISE EXCEPTION 'SALES_CUTOVER_RETAIL_ADOPTION_HISTORY_IMMUTABLE';
END
$$;
CREATE TRIGGER sales_cutover_retail_adoption_immutable
BEFORE UPDATE OR DELETE ON public.sales_cutover_retail_adoption_operations
FOR EACH ROW EXECUTE FUNCTION private.trg_sales_cutover_retail_adoption_immutable();
REVOKE ALL ON FUNCTION private.trg_sales_cutover_retail_adoption_immutable()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.trg_sales_cutover_retail_adoption_immutable()
TO service_role;

CREATE OR REPLACE FUNCTION private.sales_process_retail_identity_is_valid(
  p_sales_origin text,p_sales_process_mode text,p_session_id uuid,
  p_pos_id uuid,p_created_session_id uuid
) RETURNS boolean LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path=public,pg_temp AS $$
  SELECT CASE
    WHEN p_sales_origin='BACKOFFICE_CUTOVER'
      AND p_sales_process_mode='RETAIL_CONFIRM_INVOICE'
    THEN (p_session_id IS NULL AND p_pos_id IS NULL AND p_created_session_id IS NULL)
      OR (p_session_id IS NOT NULL AND p_pos_id IS NOT NULL
        AND p_created_session_id IS NOT NULL)
    WHEN p_sales_origin IN('POS','BACKOFFICE_SALES')
    THEN p_session_id IS NOT NULL AND p_pos_id IS NOT NULL
      AND p_created_session_id IS NOT NULL
    ELSE false
  END;
$$;

CREATE OR REPLACE FUNCTION private.trg_guard_sales_process_identity()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
BEGIN
  IF TG_OP='UPDATE' AND (
    NEW.sales_origin IS DISTINCT FROM OLD.sales_origin
    OR NEW.sales_process_mode IS DISTINCT FROM OLD.sales_process_mode
  ) THEN
    RAISE EXCEPTION 'SALES_PROCESS_IDENTITY_IMMUTABLE';
  END IF;
  IF TG_OP='UPDATE' AND OLD.sales_origin='BACKOFFICE_CUTOVER'
    AND (NEW.company_id IS DISTINCT FROM OLD.company_id
      OR NEW.store_id IS DISTINCT FROM OLD.store_id
      OR NEW.sales_warehouse_id IS DISTINCT FROM OLD.sales_warehouse_id) THEN
    RAISE EXCEPTION 'BACKOFFICE_CUTOVER_SCOPE_IMMUTABLE';
  END IF;
  IF TG_OP='INSERT' AND NEW.sales_origin='BACKOFFICE_CUTOVER'
    AND COALESCE(current_setting('kgs.sales_process_cutover_mutation',true),'')<>'1' THEN
    RAISE EXCEPTION 'BACKOFFICE_CUTOVER_RUNTIME_REQUIRED';
  END IF;
  IF NEW.sales_origin='BACKOFFICE_SALES' AND NOT EXISTS(
    SELECT 1 FROM public.company_features feature
    WHERE feature.company_id=NEW.company_id
      AND feature.feature_code='backoffice_delivered_qty_sales_enabled'
      AND feature.is_enabled
  ) THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_FEATURE_NOT_ENABLED';
  END IF;
  RETURN NEW;
END
$$;

CREATE FUNCTION private.backoffice_cutover_retail_draft_response(
  p_company_id uuid,p_sales_id uuid,p_exact_retry boolean,p_operation text
) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
  SELECT jsonb_build_object(
    'salesId',sale.id,'draftNo',sale.draft_no,'masterVersion',sale.master_version,
    'transactionAt',CASE WHEN sale.order_timing_mode='SCHEDULED'
      THEN COALESCE(sale.payload_snapshot->>'plannedOrderAt',sale.transaction_date::text)
      ELSE sale.transaction_date::text END,
    'transactionDateSource',sale.transaction_date_source,
    'orderTimingMode',sale.order_timing_mode,'plannedOrderDate',sale.planned_order_date,
    'operationalStatus',CASE WHEN sale.order_timing_mode='SCHEDULED'
      AND sale.planned_order_date>(clock_timestamp() AT TIME ZONE company.timezone)::date
      THEN 'SCHEDULED' ELSE 'ACTIVE' END,
    'grandTotalBeforeRounding',sale.grand_total_before_rounding,
    'roundingAdjustment',sale.rounding_adjustment,
    'grandTotalAfterRounding',sale.grand_total_after_rounding,
    'deliveryFeeAmount',sale.delivery_fee_amount,
    'deliveryFeeInvoiceDisplayMode',sale.delivery_fee_invoice_display_mode,
    'salesOrigin',sale.sales_origin,'salesWarehouseId',sale.sales_warehouse_id,
    'commercialSnapshotPreserved',COALESCE(
      (sale.payload_snapshot->>'snapshotPreserved')::boolean,false),
    'exactRetry',p_exact_retry,'operation',p_operation)
  FROM public.sales_headers sale
  JOIN public.companies company ON company.id=sale.company_id
  WHERE sale.company_id=p_company_id AND sale.id=p_sales_id;
$$;

CREATE FUNCTION public.adopt_backoffice_cutover_sale_draft(
  p_sales_id uuid,p_expected_master_version bigint,p_cashier_session_id uuid,
  p_operation_id uuid,p_confirm_takeover boolean DEFAULT false
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='8s' AS $$
DECLARE v_actor uuid:=auth.uid();v_company uuid:=public.private_active_company_id();
  v_sale public.sales_headers%rowtype;v_session public.cashier_sessions%rowtype;
  v_existing public.sales_cutover_retail_adoption_operations%rowtype;
  v_hash text;v_action text;v_now timestamptz:=clock_timestamp();v_response jsonb;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF p_operation_id IS NULL OR p_expected_master_version IS NULL THEN
    RAISE EXCEPTION 'CUTOVER_RETAIL_ADOPTION_IDENTITY_REQUIRED';
  END IF;
  v_hash:=encode(extensions.digest(convert_to(jsonb_build_object(
    'salesId',p_sales_id,'expectedMasterVersion',p_expected_master_version,
    'cashierSessionId',p_cashier_session_id,
    'confirmTakeover',COALESCE(p_confirm_takeover,false))::text,'UTF8'),'sha256'),'hex');
  PERFORM pg_advisory_xact_lock(hashtextextended(
    v_company::text||':'||p_operation_id::text,20260911120000));
  SELECT operation.* INTO v_existing
  FROM public.sales_cutover_retail_adoption_operations operation
  WHERE operation.company_id=v_company AND operation.operation_id=p_operation_id;
  IF FOUND THEN
    IF v_existing.request_hash<>v_hash OR v_existing.operation_type<>'ADOPT' THEN
      RAISE EXCEPTION 'CUTOVER_RETAIL_ADOPTION_IDEMPOTENCY_CONFLICT';
    END IF;
    RETURN v_existing.response_snapshot||jsonb_build_object('exactRetry',true);
  END IF;
  SELECT session.* INTO v_session FROM public.cashier_sessions session
  WHERE session.company_id=v_company AND session.id=p_cashier_session_id
    AND session.cashier_id=v_actor AND session.status='OPEN'::public.session_status
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'OPEN_CASHIER_SESSION_REQUIRED'; END IF;
  SELECT sale.* INTO v_sale FROM public.sales_headers sale
  WHERE sale.company_id=v_company AND sale.id=p_sales_id FOR UPDATE;
  IF NOT FOUND OR v_sale.document_status<>'DRAFT' OR v_sale.confirmed_at IS NOT NULL
    OR v_sale.order_runtime_status NOT IN('DRAFT_INPUT','SCHEDULED') THEN
    RAISE EXCEPTION 'SALE_DRAFT_NOT_FOUND';
  END IF;
  IF v_sale.sales_origin<>'BACKOFFICE_CUTOVER'
    OR v_sale.sales_process_mode<>'RETAIL_CONFIRM_INVOICE' THEN
    RAISE EXCEPTION 'BACKOFFICE_CUTOVER_DRAFT_REQUIRED';
  END IF;
  IF v_sale.master_version<>p_expected_master_version THEN
    RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
  END IF;
  IF v_sale.store_id IS DISTINCT FROM v_session.store_id THEN
    RAISE EXCEPTION 'SALE_DRAFT_STORE_ACCESS_DENIED';
  END IF;
  IF v_sale.sales_warehouse_id IS DISTINCT FROM v_session.sales_warehouse_id THEN
    RAISE EXCEPTION 'SALE_DRAFT_WAREHOUSE_ACCESS_DENIED';
  END IF;
  IF v_sale.edit_lock_owner_id IS NULL THEN v_action:='LOCK_ACQUIRE';
  ELSIF v_sale.edit_lock_owner_id=v_actor
    AND v_sale.edit_lock_session_id=p_cashier_session_id THEN v_action:='LOCK_HEARTBEAT';
  ELSIF v_sale.edit_lock_heartbeat_at>=v_now-interval '5 minutes' THEN
    RAISE EXCEPTION 'SALE_DRAFT_LOCKED';
  ELSIF NOT COALESCE(p_confirm_takeover,false) THEN
    RAISE EXCEPTION 'SALE_DRAFT_TAKEOVER_CONFIRMATION_REQUIRED';
  ELSE v_action:='LOCK_TAKEOVER'; END IF;
  UPDATE public.sales_headers SET session_id=v_session.id,pos_id=v_session.pos_id,
    created_session_id=COALESCE(created_session_id,v_session.id),
    edit_lock_owner_id=v_actor,edit_lock_session_id=v_session.id,
    edit_lock_acquired_at=CASE WHEN v_action='LOCK_HEARTBEAT'
      THEN edit_lock_acquired_at ELSE v_now END,
    edit_lock_heartbeat_at=v_now,master_version=master_version+1,updated_at=v_now
  WHERE company_id=v_company AND id=v_sale.id;
  INSERT INTO public.sale_master_audit(company_id,sales_id,action,actor_id,
    before_state,after_state) VALUES(v_company,v_sale.id,v_action,v_actor,
    jsonb_build_object('sessionId',v_sale.session_id,'posId',v_sale.pos_id,
      'warehouseId',v_sale.sales_warehouse_id,'masterVersion',v_sale.master_version),
    jsonb_build_object('sessionId',v_session.id,'posId',v_session.pos_id,
      'warehouseId',v_session.sales_warehouse_id,
      'masterVersion',v_sale.master_version+1,'commercialSnapshotPreserved',true));
  v_response:=private.backoffice_cutover_retail_draft_response(
    v_company,v_sale.id,false,'ADOPT');
  INSERT INTO public.sales_cutover_retail_adoption_operations(company_id,
    operation_id,sales_id,cashier_session_id,operation_type,
    expected_master_version,request_hash,response_snapshot,actor_id)
  VALUES(v_company,p_operation_id,v_sale.id,v_session.id,'ADOPT',
    p_expected_master_version,v_hash,v_response,v_actor);
  RETURN v_response;
END
$$;

CREATE FUNCTION public.save_backoffice_cutover_sale_draft_preserved(
  p_sales_id uuid,p_expected_master_version bigint,p_cashier_session_id uuid,
  p_operation_id uuid,p_payments jsonb DEFAULT '[]'::jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='8s' AS $$
DECLARE v_actor uuid:=auth.uid();v_company uuid:=public.private_active_company_id();
  v_sale public.sales_headers%rowtype;v_session public.cashier_sessions%rowtype;
  v_existing public.sales_cutover_retail_adoption_operations%rowtype;
  v_hash text;v_response jsonb;v_now timestamptz:=clock_timestamp();
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF p_operation_id IS NULL OR p_expected_master_version IS NULL
    OR jsonb_typeof(p_payments) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'CUTOVER_RETAIL_PRESERVE_SAVE_PAYLOAD_INVALID';
  END IF;
  v_hash:=encode(extensions.digest(convert_to(jsonb_build_object(
    'salesId',p_sales_id,'expectedMasterVersion',p_expected_master_version,
    'cashierSessionId',p_cashier_session_id,'payments',p_payments)::text,
    'UTF8'),'sha256'),'hex');
  PERFORM pg_advisory_xact_lock(hashtextextended(
    v_company::text||':'||p_operation_id::text,20260911120000));
  SELECT operation.* INTO v_existing
  FROM public.sales_cutover_retail_adoption_operations operation
  WHERE operation.company_id=v_company AND operation.operation_id=p_operation_id;
  IF FOUND THEN
    IF v_existing.request_hash<>v_hash OR v_existing.operation_type<>'PRESERVE_SAVE' THEN
      RAISE EXCEPTION 'CUTOVER_RETAIL_ADOPTION_IDEMPOTENCY_CONFLICT';
    END IF;
    RETURN v_existing.response_snapshot||jsonb_build_object('exactRetry',true);
  END IF;
  SELECT session.* INTO v_session FROM public.cashier_sessions session
  WHERE session.company_id=v_company AND session.id=p_cashier_session_id
    AND session.cashier_id=v_actor AND session.status='OPEN'::public.session_status
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'OPEN_CASHIER_SESSION_REQUIRED'; END IF;
  SELECT sale.* INTO v_sale FROM public.sales_headers sale
  WHERE sale.company_id=v_company AND sale.id=p_sales_id FOR UPDATE;
  IF NOT FOUND OR v_sale.document_status<>'DRAFT'
    OR v_sale.sales_origin<>'BACKOFFICE_CUTOVER'
    OR v_sale.sales_process_mode<>'RETAIL_CONFIRM_INVOICE'
    OR COALESCE((v_sale.payload_snapshot->>'snapshotPreserved')::boolean,false) IS NOT TRUE THEN
    RAISE EXCEPTION 'BACKOFFICE_CUTOVER_PRESERVED_DRAFT_REQUIRED';
  END IF;
  IF v_sale.master_version<>p_expected_master_version THEN
    RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
  END IF;
  IF v_sale.store_id IS DISTINCT FROM v_session.store_id
    OR v_sale.sales_warehouse_id IS DISTINCT FROM v_session.sales_warehouse_id THEN
    RAISE EXCEPTION 'SALE_DRAFT_SCOPE_ACCESS_DENIED';
  END IF;
  IF v_sale.session_id IS DISTINCT FROM v_session.id
    OR v_sale.pos_id IS DISTINCT FROM v_session.pos_id
    OR v_sale.edit_lock_owner_id IS DISTINCT FROM v_actor
    OR v_sale.edit_lock_session_id IS DISTINCT FROM v_session.id
    OR v_sale.edit_lock_heartbeat_at IS NULL
    OR v_sale.edit_lock_heartbeat_at<v_now-interval '5 minutes' THEN
    RAISE EXCEPTION 'SALE_DRAFT_EDIT_LOCK_REQUIRED';
  END IF;
  UPDATE public.sales_headers SET
    payload_snapshot=jsonb_set(COALESCE(payload_snapshot,'{}'::jsonb),
      '{payments}',p_payments,true),
    edit_lock_heartbeat_at=v_now,master_version=master_version+1,updated_at=v_now
  WHERE company_id=v_company AND id=v_sale.id;
  INSERT INTO public.sale_master_audit(company_id,sales_id,action,actor_id,
    before_state,after_state) VALUES(v_company,v_sale.id,'UPDATE_DRAFT',v_actor,
    jsonb_build_object('masterVersion',v_sale.master_version,
      'commercialSnapshotPreserved',true),
    jsonb_build_object('masterVersion',v_sale.master_version+1,
      'commercialSnapshotPreserved',true,
      'paymentCount',jsonb_array_length(p_payments)));
  v_response:=private.backoffice_cutover_retail_draft_response(
    v_company,v_sale.id,false,'PRESERVE_SAVE');
  INSERT INTO public.sales_cutover_retail_adoption_operations(company_id,
    operation_id,sales_id,cashier_session_id,operation_type,
    expected_master_version,request_hash,response_snapshot,actor_id)
  VALUES(v_company,p_operation_id,v_sale.id,v_session.id,'PRESERVE_SAVE',
    p_expected_master_version,v_hash,v_response,v_actor);
  RETURN v_response;
END
$$;

CREATE OR REPLACE FUNCTION public.list_pos_sale_drafts(p_store_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_timezone text;v_today date;
BEGIN
  SELECT company.timezone INTO v_timezone FROM public.companies company
  WHERE company.id=v_company;
  v_today:=(clock_timestamp() AT TIME ZONE v_timezone)::date;
  RETURN (SELECT COALESCE(jsonb_agg(item ORDER BY
      CASE WHEN operational_status='ACTIVE' THEN 1 ELSE 2 END,
      planned_date NULLS FIRST,updated_at DESC),'[]'::jsonb)
    FROM (SELECT sale.updated_at,sale.planned_order_date planned_date,
      CASE WHEN sale.order_timing_mode='SCHEDULED'
        AND sale.planned_order_date>v_today THEN 'SCHEDULED' ELSE 'ACTIVE' END operational_status,
      jsonb_build_object('salesId',sale.id,'draftNo',sale.draft_no,
        'draftLabel',sale.draft_label,'draftNotes',sale.draft_notes,
        'draftReason',sale.draft_reason,'customerId',sale.customer_id,
        'customerName',customer.name,'storeId',sale.store_id,'storeName',store.store_name,
        'salesWarehouseId',sale.sales_warehouse_id,'salesOrigin',sale.sales_origin,
        'commercialSnapshotPreserved',COALESCE(
          (sale.payload_snapshot->>'snapshotPreserved')::boolean,false),
        'createdBy',sale.created_by,'createdByName',creator.name,'createdAt',sale.created_at,
        'transactionAt',CASE WHEN sale.order_timing_mode='SCHEDULED'
          THEN COALESCE(sale.payload_snapshot->>'plannedOrderAt',sale.transaction_date::text)
          ELSE sale.transaction_date::text END,
        'transactionDateSource',sale.transaction_date_source,'updatedAt',sale.updated_at,
        'masterVersion',sale.master_version,'grandTotal',sale.grand_total_after_rounding,
        'lineCount',(SELECT count(*) FROM public.sales_details detail
          WHERE detail.company_id=sale.company_id AND detail.sales_id=sale.id),
        'isStale',sale.created_at<clock_timestamp()-interval '7 days',
        'orderTimingMode',sale.order_timing_mode,'plannedOrderDate',sale.planned_order_date,
        'operationalStatus',CASE WHEN sale.order_timing_mode='SCHEDULED'
          AND sale.planned_order_date>v_today THEN 'SCHEDULED' ELSE 'ACTIVE' END,
        'canPost',NOT(sale.order_timing_mode='SCHEDULED'
          AND sale.planned_order_date>v_today),
        'orderRuntimeStatus',sale.order_runtime_status,
        'lockOwnerId',sale.edit_lock_owner_id,'lockOwnerName',lock_owner.name,
        'lockSessionId',sale.edit_lock_session_id,'lockHeartbeatAt',sale.edit_lock_heartbeat_at,
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
        AND sale.confirmed_at IS NULL
        AND sale.order_runtime_status IN('DRAFT_INPUT','SCHEDULED')
        AND (p_store_id IS NULL OR sale.store_id=p_store_id)
        AND (public.private_user_has_any_company_role(sale.company_id,
          ARRAY['COMPANY_OWNER','COMPANY_ADMIN']::text[])
          OR public.private_user_has_any_store_role(sale.store_id,
          ARRAY['CASHIER','STORE_MANAGER']::text[]))) visible);
END
$$;

REVOKE ALL ON FUNCTION
  private.backoffice_cutover_retail_draft_response(uuid,uuid,boolean,text),
  public.adopt_backoffice_cutover_sale_draft(uuid,bigint,uuid,uuid,boolean),
  public.save_backoffice_cutover_sale_draft_preserved(uuid,bigint,uuid,uuid,jsonb)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.backoffice_cutover_retail_draft_response(uuid,uuid,boolean,text)
TO service_role;
GRANT EXECUTE ON FUNCTION
  public.adopt_backoffice_cutover_sale_draft(uuid,bigint,uuid,uuid,boolean),
  public.save_backoffice_cutover_sale_draft_preserved(uuid,bigint,uuid,uuid,jsonb)
TO authenticated,service_role;
REVOKE ALL ON FUNCTION public.list_pos_sale_drafts(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.list_pos_sale_drafts(uuid) TO authenticated,service_role;

COMMENT ON COLUMN public.sales_headers.sales_origin IS
  'Immutable source. BACKOFFICE_CUTOVER starts detached and may later attach atomically to a real matching Retail POS session; its Company, Store, and Warehouse remain immutable.';

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260911120000','sales_process_cutover_retail_session_adoption',
  'Attach BACKOFFICE_CUTOVER Drafts only to matching OPEN Retail Company/Store/Warehouse sessions; preserve commercial snapshot for payment-only save; exact retry, optimistic version, immutable audit; no Apply, mode, Stock, Invoice or Finance effect');
NOTIFY pgrst,'reload schema';
COMMIT;
