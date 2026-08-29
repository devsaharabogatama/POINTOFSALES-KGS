BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260828160000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: ODR-4B required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260828170000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
    WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
  IF EXISTS(SELECT 1 FROM public.stock_request_documents
    WHERE request_source='SALES_ORDER_RESERVATION') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: reservation Stock Request already exists';
  END IF;
END
$guard$;

ALTER TABLE public.stock_request_documents
  DROP CONSTRAINT stock_request_documents_source_check,
  ADD CONSTRAINT stock_request_documents_source_check CHECK(
    request_source IN('MANUAL','NEGATIVE_STOCK_SESSION_CLOSE',
      'SALES_ORDER_RESERVATION'));

CREATE UNIQUE INDEX uq_stock_request_reservation_session
  ON public.stock_request_documents(company_id,requesting_session_id)
  WHERE request_source='SALES_ORDER_RESERVATION';

-- A single Product line in the projected Stock Request can aggregate shortage
-- from several Sales Orders in the same Session. Keep the FK, but remove the
-- accidental one-demand-line-per-request-line uniqueness from ODR-4A.
ALTER TABLE public.sales_order_procurement_demand_lines
  DROP CONSTRAINT sales_order_procurement_demand_lines_request_unique;
CREATE INDEX idx_sales_order_procurement_demand_line_request
  ON public.sales_order_procurement_demand_lines(
    company_id,stock_request_line_id)
  WHERE stock_request_line_id IS NOT NULL;

CREATE OR REPLACE FUNCTION private.trg_prd_guard_automatic_stock_request()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path=public,pg_temp AS $$
BEGIN
  IF NEW.request_source IS DISTINCT FROM OLD.request_source THEN
    RAISE EXCEPTION 'STOCK_REQUEST_SOURCE_IMMUTABLE';
  END IF;
  IF OLD.request_source='NEGATIVE_STOCK_SESSION_CLOSE'
     AND NEW.status='CANCELED' THEN
    RAISE EXCEPTION 'AUTOMATIC_NEGATIVE_STOCK_REQUEST_CANNOT_BE_CANCELED';
  END IF;
  IF OLD.request_source='SALES_ORDER_RESERVATION'
     AND NEW.status='CANCELED' THEN
    RAISE EXCEPTION 'MANAGED_RESERVATION_STOCK_REQUEST_CANNOT_BE_CANCELED';
  END IF;
  RETURN NEW;
END
$$;

CREATE FUNCTION private.ensure_session_procurement_stock_request(
  p_company_id UUID,p_cashier_session_id UUID,p_actor_id UUID
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
  v_session public.cashier_sessions%ROWTYPE;
  v_demand public.sales_order_procurement_demands%ROWTYPE;
  v_document public.stock_request_documents%ROWTYPE;
  v_product RECORD;
  v_document_id UUID;v_line_id UUID;v_request_no TEXT;
  v_line_no INTEGER:=0;v_line_count INTEGER:=0;
  v_total NUMERIC(24,6):=0;v_now TIMESTAMPTZ:=clock_timestamp();
  v_draft JSONB;v_submitted JSONB;v_key UUID;
BEGIN
  IF p_company_id IS NULL OR p_cashier_session_id IS NULL
    OR p_actor_id IS NULL THEN
    RAISE EXCEPTION 'PROCUREMENT_REQUEST_CONTEXT_REQUIRED';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(
    p_company_id::TEXT||':PROCUREMENT-REQUEST:'||p_cashier_session_id::TEXT,0));

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
      'stockRequestTotalBaseQty',0,'stockRequestCreated',FALSE);
  END IF;

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
      'stockRequestCreated',FALSE,'exactRetry',TRUE);
  END IF;

  IF NOT EXISTS(SELECT 1
    FROM public.sales_order_procurement_demand_lines line
    WHERE line.company_id=p_company_id AND line.demand_id=v_demand.id
      AND line.demand_base_qty>line.released_base_qty) THEN
    RETURN jsonb_build_object('stockRequestId',NULL,'stockRequestNo',NULL,
      'stockRequestStatus',NULL,'stockRequestLineCount',0,
      'stockRequestTotalBaseQty',0,'stockRequestCreated',FALSE,
      'exactRetry',FALSE);
  END IF;

  v_request_no:='REQ-'||to_char(v_now,'YYYYMMDD')||'-'||
    lpad(nextval('private.stock_request_document_no_seq')::TEXT,10,'0');
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
  v_key:=md5(p_company_id::TEXT||':'||v_demand.id::TEXT||
    ':STOCK_REQUEST_LINK')::UUID;
  INSERT INTO public.sales_order_procurement_demand_audit(
    company_id,demand_id,action,idempotency_key,actor_id,after_state
  ) VALUES(p_company_id,v_demand.id,'REQUEST_LINK',v_key,p_actor_id,
    jsonb_build_object('stockRequestId',v_document_id,
      'stockRequestNo',v_request_no,'lineCount',v_line_count,
      'requestedBaseQty',v_total,'masterVersion',v_demand.master_version));

  RETURN jsonb_build_object('stockRequestId',v_document_id,
    'stockRequestNo',v_request_no,'stockRequestStatus','SUBMITTED',
    'stockRequestLineCount',v_line_count,
    'stockRequestTotalBaseQty',v_total,'stockRequestCreated',TRUE,
    'exactRetry',FALSE);
END
$$;

ALTER FUNCTION public.close_cashier_session(UUID,BIGINT,NUMERIC)
  RENAME TO odr4c_close_cashier_session_legacy;
ALTER FUNCTION public.odr4c_close_cashier_session_legacy(UUID,BIGINT,NUMERIC)
  SET SCHEMA private;

CREATE FUNCTION public.close_cashier_session(
  p_cashier_session_id UUID,p_master_version BIGINT,
  p_closing_cash_actual NUMERIC
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
  v_actor UUID:=auth.uid();v_result JSONB;v_request JSONB;
BEGIN
  v_result:=private.odr4c_close_cashier_session_legacy(
    p_cashier_session_id,p_master_version,p_closing_cash_actual);
  v_request:=private.ensure_session_procurement_stock_request(
    v_company,p_cashier_session_id,v_actor);
  RETURN v_result||jsonb_build_object('procurementStockRequest',v_request);
END
$$;

REVOKE ALL ON FUNCTION
  private.ensure_session_procurement_stock_request(UUID,UUID,UUID),
  private.odr4c_close_cashier_session_legacy(UUID,BIGINT,NUMERIC)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.ensure_session_procurement_stock_request(UUID,UUID,UUID),
  private.odr4c_close_cashier_session_legacy(UUID,BIGINT,NUMERIC)
TO service_role;
REVOKE ALL ON FUNCTION public.close_cashier_session(UUID,BIGINT,NUMERIC)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.close_cashier_session(UUID,BIGINT,NUMERIC)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260828170000','odr_phase4c_session_stock_request_projection',
  'Project frozen Session reservation shortage into one submitted managed Stock Request, aggregate by base Product-UOM, link immutable demand lineage, preserve legacy requests and leave Supplier Order, Stock and Finance untouched');

NOTIFY pgrst,'reload schema';
COMMIT;
