BEGIN;
SELECT pg_advisory_xact_lock(hashtextextended(
  '20260924110000_pos_session_close_stock_request_policy',0));

DO $guard$
DECLARE v_close text;v_request text;
BEGIN
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260924110000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260924100000')
    OR NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260829130000')
    OR NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260828170000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: required runtime ledger missing';
  END IF;
  IF to_regclass('public.company_purchase_replenishment_settings') IS NULL
    OR to_regclass('public.company_purchase_replenishment_setting_audit') IS NULL
    OR to_regclass('public.cashier_sessions') IS NULL
    OR to_regprocedure('public.get_purchase_replenishment_setting()') IS NULL
    OR to_regprocedure('public.close_cashier_session(uuid,bigint,numeric)') IS NULL
    OR to_regprocedure(
      'private.ensure_session_procurement_stock_request(uuid,uuid,uuid)') IS NULL
    OR to_regprocedure(
      'private.odr5d_close_cashier_session_legacy(uuid,bigint,numeric)') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: required runtime objects missing';
  END IF;
  IF (SELECT count(*) FROM pg_constraint constraint_row
      WHERE constraint_row.conrelid=
        'public.company_purchase_replenishment_setting_audit'::regclass
        AND constraint_row.conname=
          'company_purchase_replenishment_setting_audit_action_check')<>1 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: setting audit constraint missing';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
      WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
      WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
  IF EXISTS(SELECT 1 FROM information_schema.columns
      WHERE table_schema='public'
        AND table_name='company_purchase_replenishment_settings'
        AND column_name='session_close_stock_request_enabled')
    OR EXISTS(SELECT 1 FROM information_schema.columns
      WHERE table_schema='public' AND table_name='cashier_sessions'
        AND column_name IN('stock_request_on_close_enabled_snapshot',
          'stock_request_on_close_policy_decided_at'))
    OR to_regprocedure(
      'public.set_session_close_stock_request_policy(boolean,bigint)') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: object collision';
  END IF;
  SELECT pg_get_functiondef(
    'public.close_cashier_session(uuid,bigint,numeric)'::regprocedure)
  INTO v_close;
  SELECT pg_get_functiondef(
    'private.ensure_session_procurement_stock_request(uuid,uuid,uuid)'::regprocedure)
  INTO v_request;
  IF v_close !~'odr5d_close_cashier_session_legacy'
    OR v_close !~'paymentVerificationDeferred'
    OR v_request !~'SALES_ORDER_RESERVATION'
    OR v_request !~'stock_request_document_id' THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active close/request runtime drift';
  END IF;
END
$guard$;

ALTER TABLE public.company_purchase_replenishment_settings
  ADD COLUMN session_close_stock_request_enabled boolean NOT NULL DEFAULT false;

ALTER TABLE public.cashier_sessions
  ADD COLUMN stock_request_on_close_enabled_snapshot boolean NOT NULL DEFAULT false,
  ADD COLUMN stock_request_on_close_policy_decided_at timestamptz;

ALTER TABLE public.company_purchase_replenishment_setting_audit
  DROP CONSTRAINT company_purchase_replenishment_setting_audit_action_check,
  ADD CONSTRAINT company_purchase_replenishment_setting_audit_action_check CHECK(
    action IN('PROVISION','MODE_CHANGE','DEFAULT_WAREHOUSE_CHANGE',
      'DRAFT_ROLL_FORWARD_POLICY_CHANGE','STOCK_MATCH_POLICY_CHANGE',
      'SESSION_CLOSE_STOCK_REQUEST_POLICY_CHANGE'));

COMMENT ON COLUMN
  public.company_purchase_replenishment_settings.session_close_stock_request_enabled
IS 'When enabled, a newly closed POS Cashier Session may project its frozen reservation shortage into one submitted managed Stock Request. Default OFF; daily RO/PO scheduling is independent.';
COMMENT ON COLUMN public.cashier_sessions.stock_request_on_close_enabled_snapshot
IS 'Immutable decision snapshot used by close-session retry. Existing historical Sessions default to OFF and are never projected retroactively.';
COMMENT ON COLUMN public.cashier_sessions.stock_request_on_close_policy_decided_at
IS 'Timestamp at which an OPEN Session captured the Company stock-request-on-close policy immediately before canonical close.';

CREATE FUNCTION public.set_session_close_stock_request_policy(
  p_enabled boolean,p_master_version bigint
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_actor uuid:=auth.uid();v_company uuid:=public.private_active_company_id();
  v_before public.company_purchase_replenishment_settings%rowtype;
  v_after public.company_purchase_replenishment_settings%rowtype;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM public.profiles profile
      WHERE profile.id=v_actor AND profile.role='super_admin') THEN
    RAISE EXCEPTION 'SUPER_ADMIN_REQUIRED';
  END IF;
  IF p_enabled IS NULL THEN
    RAISE EXCEPTION 'SESSION_CLOSE_STOCK_REQUEST_POLICY_INVALID';
  END IF;
  SELECT * INTO v_before
  FROM public.company_purchase_replenishment_settings setting
  WHERE setting.company_id=v_company FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'PURCHASE_REPLENISHMENT_SETTING_NOT_FOUND';
  END IF;
  IF p_master_version IS NULL OR p_master_version<>v_before.master_version THEN
    RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
  END IF;
  IF v_before.session_close_stock_request_enabled=p_enabled THEN
    RETURN jsonb_build_object('companyId',v_company,'enabled',p_enabled,
      'masterVersion',v_before.master_version,'changed',false);
  END IF;
  UPDATE public.company_purchase_replenishment_settings SET
    session_close_stock_request_enabled=p_enabled,
    master_version=master_version+1,updated_by=v_actor,
    updated_at=clock_timestamp()
  WHERE company_id=v_company RETURNING * INTO v_after;
  INSERT INTO public.company_purchase_replenishment_setting_audit(
    company_id,action,actor_id,before_state,after_state)
  VALUES(v_company,'SESSION_CLOSE_STOCK_REQUEST_POLICY_CHANGE',v_actor,
    to_jsonb(v_before),to_jsonb(v_after));
  RETURN jsonb_build_object('companyId',v_company,
    'enabled',v_after.session_close_stock_request_enabled,
    'masterVersion',v_after.master_version,'changed',true);
END
$$;

CREATE OR REPLACE FUNCTION public.get_purchase_replenishment_setting()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_setting record;
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'purchase.supplier_orders','VIEW');
  SELECT setting.*,company.timezone,warehouse.code default_warehouse_code,
    warehouse.name default_warehouse_name INTO v_setting
  FROM public.company_purchase_replenishment_settings setting
  JOIN public.companies company ON company.id=setting.company_id
  LEFT JOIN public.warehouses warehouse ON warehouse.company_id=setting.company_id
    AND warehouse.id=setting.default_purchase_receipt_warehouse_id
  WHERE setting.company_id=v_company;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'PURCHASE_REPLENISHMENT_SETTING_NOT_FOUND';
  END IF;
  RETURN jsonb_build_object('companyId',v_company,
    'mode',v_setting.replenishment_mode,
    'cutoffLocalTime',to_char(v_setting.cutoff_local_time,'HH24:MI'),
    'targetOnHandBaseQty',v_setting.target_on_hand_base_qty,
    'timezone',v_setting.timezone,
    'defaultPurchaseReceiptWarehouseId',
      v_setting.default_purchase_receipt_warehouse_id,
    'defaultPurchaseReceiptWarehouse',CASE
      WHEN v_setting.default_purchase_receipt_warehouse_id IS NULL THEN NULL
      ELSE jsonb_build_object('id',v_setting.default_purchase_receipt_warehouse_id,
        'code',v_setting.default_warehouse_code,
        'name',v_setting.default_warehouse_name) END,
    'sessionCloseStockRequestEnabled',
      v_setting.session_close_stock_request_enabled,
    'masterVersion',v_setting.master_version,'updatedAt',v_setting.updated_at);
END
$$;

CREATE OR REPLACE FUNCTION private.ensure_session_procurement_stock_request(
  p_company_id uuid,p_cashier_session_id uuid,p_actor_id uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
  v_session public.cashier_sessions%rowtype;
  v_demand public.sales_order_procurement_demands%rowtype;
  v_document public.stock_request_documents%rowtype;
  v_product record;
  v_document_id uuid;v_line_id uuid;v_request_no text;
  v_line_no integer:=0;v_line_count integer:=0;
  v_total numeric(24,6):=0;v_now timestamptz:=clock_timestamp();
  v_draft jsonb;v_submitted jsonb;v_key uuid;
BEGIN
  IF p_company_id IS NULL OR p_cashier_session_id IS NULL
    OR p_actor_id IS NULL THEN
    RAISE EXCEPTION 'PROCUREMENT_REQUEST_CONTEXT_REQUIRED';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(
    p_company_id::text||':PROCUREMENT-REQUEST:'||p_cashier_session_id::text,0));

  SELECT session.* INTO v_session FROM public.cashier_sessions session
  WHERE session.company_id=p_company_id AND session.id=p_cashier_session_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'CASHIER_SESSION_NOT_FOUND'; END IF;
  IF v_session.status='OPEN'::public.session_status THEN
    RAISE EXCEPTION 'PROCUREMENT_REQUEST_REQUIRES_CLOSED_SESSION';
  END IF;

  SELECT demand.* INTO v_demand
  FROM public.sales_order_procurement_demands demand
  WHERE demand.company_id=p_company_id
    AND demand.cashier_session_id=p_cashier_session_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('stockRequestId',NULL,'stockRequestNo',NULL,
      'stockRequestStatus',NULL,'stockRequestLineCount',0,
      'stockRequestTotalBaseQty',0,'stockRequestCreated',false,
      'sessionCloseStockRequestEnabled',
        v_session.stock_request_on_close_enabled_snapshot,
      'stockRequestSkipped',true,'skipReason','NO_FROZEN_DEMAND');
  END IF;

  -- Existing lineage always wins over the current Company setting. Turning the
  -- policy OFF never hides, cancels or recreates an already-linked request.
  IF v_demand.stock_request_document_id IS NOT NULL THEN
    SELECT document.* INTO v_document
    FROM public.stock_request_documents document
    WHERE document.company_id=p_company_id
      AND document.id=v_demand.stock_request_document_id;
    IF NOT FOUND OR v_document.request_source<>'SALES_ORDER_RESERVATION'
      OR v_document.requesting_session_id<>p_cashier_session_id THEN
      RAISE EXCEPTION 'PROCUREMENT_REQUEST_LINK_INVALID';
    END IF;
    RETURN jsonb_build_object('stockRequestId',v_document.id,
      'stockRequestNo',v_document.request_no,
      'stockRequestStatus',v_document.status,
      'stockRequestLineCount',v_document.line_count,
      'stockRequestTotalBaseQty',v_document.requested_total_base_qty,
      'stockRequestCreated',false,'exactRetry',true,
      'sessionCloseStockRequestEnabled',
        v_session.stock_request_on_close_enabled_snapshot,
      'stockRequestSkipped',false,'skipReason',NULL);
  END IF;

  IF NOT v_session.stock_request_on_close_enabled_snapshot THEN
    RETURN jsonb_build_object('stockRequestId',NULL,'stockRequestNo',NULL,
      'stockRequestStatus',NULL,'stockRequestLineCount',0,
      'stockRequestTotalBaseQty',0,'stockRequestCreated',false,
      'exactRetry',false,'sessionCloseStockRequestEnabled',false,
      'stockRequestSkipped',true,'skipReason','COMPANY_POLICY_DISABLED');
  END IF;

  IF NOT EXISTS(SELECT 1
    FROM public.sales_order_procurement_demand_lines line
    WHERE line.company_id=p_company_id AND line.demand_id=v_demand.id
      AND line.demand_base_qty>line.released_base_qty) THEN
    RETURN jsonb_build_object('stockRequestId',NULL,'stockRequestNo',NULL,
      'stockRequestStatus',NULL,'stockRequestLineCount',0,
      'stockRequestTotalBaseQty',0,'stockRequestCreated',false,
      'exactRetry',false,'sessionCloseStockRequestEnabled',true,
      'stockRequestSkipped',true,'skipReason','NO_OUTSTANDING_DEMAND');
  END IF;

  v_request_no:='REQ-'||to_char(v_now,'YYYYMMDD')||'-'||
    lpad(nextval('private.stock_request_document_no_seq')::text,10,'0');
  INSERT INTO public.stock_request_documents(
    company_id,request_no,store_id,requesting_pos_id,requesting_session_id,
    requested_by,needed_date,notes,status,request_source
  ) VALUES(
    p_company_id,v_request_no,v_session.store_id,v_session.pos_id,
    p_cashier_session_id,p_actor_id,CURRENT_DATE,
    'Otomatis dari kekurangan reservasi order sesi '||v_session.session_code,
    'DRAFT','SALES_ORDER_RESERVATION'
  ) RETURNING id INTO v_document_id;

  SELECT to_jsonb(document) INTO v_draft
  FROM public.stock_request_documents document
  WHERE document.company_id=p_company_id AND document.id=v_document_id;
  INSERT INTO public.stock_request_audit(
    company_id,document_id,action,actor_id,before_state,after_state
  ) VALUES(p_company_id,v_document_id,'CREATE',p_actor_id,NULL,v_draft);

  FOR v_product IN
    SELECT line.stock_product_id product_id,product.sku,product.name,
      product.uom_id,uom.name uom_name,
      sum(line.demand_base_qty-line.released_base_qty) requested_base_qty
    FROM public.sales_order_procurement_demand_lines line
    JOIN public.products product ON product.company_id=line.company_id
      AND product.id=line.stock_product_id
    JOIN public.uoms uom ON uom.company_id=product.company_id
      AND uom.id=product.uom_id
    WHERE line.company_id=p_company_id AND line.demand_id=v_demand.id
      AND line.demand_base_qty>line.released_base_qty
    GROUP BY line.stock_product_id,product.sku,product.name,
      product.uom_id,uom.name
    ORDER BY product.name,line.stock_product_id
  LOOP
    v_line_no:=v_line_no+1;
    INSERT INTO public.stock_request_lines(
      company_id,document_id,line_no,client_line_key,product_id,
      requested_uom_id,requested_qty,factor_to_base_snapshot,
      requested_base_qty,product_sku_snapshot,product_name_snapshot,
      requested_uom_name_snapshot,notes
    ) VALUES(
      p_company_id,v_document_id,v_line_no,gen_random_uuid(),
      v_product.product_id,v_product.uom_id,v_product.requested_base_qty,1,
      v_product.requested_base_qty,v_product.sku,v_product.name,
      v_product.uom_name,'Kekurangan reservasi order per sesi kasir'
    ) RETURNING id INTO v_line_id;

    UPDATE public.sales_order_procurement_demand_lines SET
      stock_request_line_id=v_line_id,status='REQUESTED',
      master_version=master_version+1,updated_at=v_now
    WHERE company_id=p_company_id AND demand_id=v_demand.id
      AND stock_product_id=v_product.product_id
      AND demand_base_qty>released_base_qty;
    v_line_count:=v_line_count+1;
    v_total:=v_total+v_product.requested_base_qty;
  END LOOP;

  UPDATE public.stock_request_documents SET
    status='SUBMITTED',line_count=v_line_count,
    requested_total_base_qty=v_total,submitted_by=p_actor_id,
    submitted_at=v_now,master_version=master_version+1,updated_at=v_now
  WHERE company_id=p_company_id AND id=v_document_id;
  SELECT to_jsonb(document) INTO v_submitted
  FROM public.stock_request_documents document
  WHERE document.company_id=p_company_id AND document.id=v_document_id;
  INSERT INTO public.stock_request_audit(
    company_id,document_id,action,actor_id,before_state,after_state
  ) VALUES(p_company_id,v_document_id,'SUBMIT',p_actor_id,v_draft,v_submitted);

  UPDATE public.sales_order_procurement_demands SET
    stock_request_document_id=v_document_id,
    master_version=master_version+1,updated_at=v_now
  WHERE company_id=p_company_id AND id=v_demand.id
  RETURNING * INTO v_demand;
  v_key:=md5(p_company_id::text||':'||v_demand.id::text||
    ':STOCK_REQUEST_LINK')::uuid;
  INSERT INTO public.sales_order_procurement_demand_audit(
    company_id,demand_id,action,idempotency_key,actor_id,after_state
  ) VALUES(p_company_id,v_demand.id,'REQUEST_LINK',v_key,p_actor_id,
    jsonb_build_object('stockRequestId',v_document_id,
      'stockRequestNo',v_request_no,'lineCount',v_line_count,
      'requestedBaseQty',v_total,'masterVersion',v_demand.master_version));

  RETURN jsonb_build_object('stockRequestId',v_document_id,
    'stockRequestNo',v_request_no,'stockRequestStatus','SUBMITTED',
    'stockRequestLineCount',v_line_count,
    'stockRequestTotalBaseQty',v_total,'stockRequestCreated',true,
    'exactRetry',false,'sessionCloseStockRequestEnabled',true,
    'stockRequestSkipped',false,'skipReason',NULL);
END
$$;

CREATE OR REPLACE FUNCTION public.close_cashier_session(
  p_cashier_session_id uuid,p_master_version bigint,
  p_closing_cash_actual numeric
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();
  v_pending bigint;v_result jsonb;v_status public.session_status;
  v_decided_at timestamptz;v_enabled boolean:=false;
BEGIN
  SELECT session.status,session.stock_request_on_close_policy_decided_at
  INTO v_status,v_decided_at
  FROM public.cashier_sessions session
  WHERE session.company_id=v_company AND session.id=p_cashier_session_id
  FOR UPDATE;

  -- Snapshot only an OPEN Session. Historical CLOSED Sessions keep the
  -- migration default OFF, so retries cannot create a retroactive request.
  IF FOUND AND v_status='OPEN'::public.session_status AND v_decided_at IS NULL THEN
    SELECT COALESCE(setting.session_close_stock_request_enabled,false)
    INTO v_enabled
    FROM public.company_purchase_replenishment_settings setting
    WHERE setting.company_id=v_company;
    UPDATE public.cashier_sessions SET
      stock_request_on_close_enabled_snapshot=COALESCE(v_enabled,false),
      stock_request_on_close_policy_decided_at=clock_timestamp()
    WHERE company_id=v_company AND id=p_cashier_session_id;
  END IF;

  SELECT count(*) INTO v_pending
  FROM public.sales_payment_verification_requests request
  WHERE request.company_id=v_company
    AND request.cashier_session_id=p_cashier_session_id
    AND request.status='PENDING';

  v_result:=private.odr5d_close_cashier_session_legacy(
    p_cashier_session_id,p_master_version,p_closing_cash_actual);
  RETURN v_result||jsonb_build_object(
    'paymentVerificationDeferred',v_pending>0,
    'pendingPaymentVerificationCount',v_pending);
END
$$;

REVOKE ALL ON FUNCTION
  public.set_session_close_stock_request_policy(boolean,bigint)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION
  public.set_session_close_stock_request_policy(boolean,bigint)
TO authenticated,service_role;
REVOKE ALL ON FUNCTION
  private.ensure_session_procurement_stock_request(uuid,uuid,uuid)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.ensure_session_procurement_stock_request(uuid,uuid,uuid)
TO service_role;
REVOKE ALL ON FUNCTION public.close_cashier_session(uuid,bigint,numeric)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.close_cashier_session(uuid,bigint,numeric)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260924110000','pos_session_close_stock_request_policy',
  'Add default-OFF per-Company policy and per-Session close snapshot for optional POS Session shortage Stock Request projection; preserve Session close, frozen demand, historical lineage, daily RO/PO scheduler, Stock, FIFO and Finance boundaries');

NOTIFY pgrst,'reload schema';
COMMIT;
