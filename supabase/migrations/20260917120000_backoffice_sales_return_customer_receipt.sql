-- Backoffice Sales Return Step 2/5: Customer Return Receipt.
-- Warehouse posts actual returned quantity and chooses RESTOCK or DESTROY per
-- line. DESTROY requires a note, but no photo or second approval. This step
-- does not create Invoice/Credit Note, Refund, Financial Event, or Journal.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260917110000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Backoffice Sales Return commercial foundation required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260917120000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260917120000';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
    WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
  IF to_regclass('public.backoffice_sales_return_receipts') IS NOT NULL
    OR to_regclass('public.backoffice_sales_return_receipt_lines') IS NOT NULL
    OR to_regclass('public.backoffice_sales_return_receipt_fifo_restorations') IS NOT NULL
    OR to_regclass('public.backoffice_sales_return_receipt_operations') IS NOT NULL
    OR to_regclass('public.backoffice_sales_return_receipt_audit') IS NOT NULL
    OR to_regprocedure('public.post_backoffice_sales_return_receipt(uuid,bigint,uuid,date,jsonb,text)') IS NOT NULL
    OR EXISTS(SELECT 1 FROM public.access_permission_catalog
      WHERE permission_key='inventory.customer_return_receipts') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Customer Return Receipt collision';
  END IF;
END
$guard$;

INSERT INTO public.access_permission_catalog(
  permission_key,module_key,permission_label,description,view_roles,
  operator_roles,approver_roles,supported_capabilities,required_any_features,
  is_customizable,enforcement_status
) VALUES(
  'inventory.customer_return_receipts','INVENTORY','Penerimaan Retur Customer',
  'Penerimaan fisik retur Customer dan disposition Masuk Stok atau Dihancurkan',
  ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','WAREHOUSE_ADMIN','SALES','SALES_ADMIN','FINANCE'],
  ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','WAREHOUSE_ADMIN'],
  ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','WAREHOUSE_ADMIN'],
  ARRAY['VIEW','POST'],
  ARRAY['backoffice_delivered_qty_sales_enabled'],true,'ENFORCED'
);

ALTER TABLE public.backoffice_sales_returns
  ADD COLUMN total_received_base_qty numeric(24,6) NOT NULL DEFAULT 0,
  ADD COLUMN total_restocked_base_qty numeric(24,6) NOT NULL DEFAULT 0,
  ADD COLUMN total_destroyed_base_qty numeric(24,6) NOT NULL DEFAULT 0,
  ADD CONSTRAINT backoffice_sales_returns_receipt_quantity_check CHECK(
    total_received_base_qty>=0
    AND total_received_base_qty<=total_requested_base_qty
    AND total_restocked_base_qty>=0 AND total_destroyed_base_qty>=0
    AND total_restocked_base_qty+total_destroyed_base_qty=total_received_base_qty);

CREATE SEQUENCE private.backoffice_sales_return_receipt_no_seq AS bigint START WITH 1;
REVOKE ALL ON SEQUENCE private.backoffice_sales_return_receipt_no_seq
  FROM PUBLIC,anon,authenticated;
GRANT USAGE,SELECT ON SEQUENCE private.backoffice_sales_return_receipt_no_seq TO service_role;

CREATE TABLE public.backoffice_sales_return_receipts(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
  receipt_no text NOT NULL,
  return_id uuid NOT NULL,
  receipt_date date NOT NULL,
  status text NOT NULL DEFAULT 'POSTED',
  total_received_base_qty numeric(24,6) NOT NULL,
  total_restocked_base_qty numeric(24,6) NOT NULL,
  total_destroyed_base_qty numeric(24,6) NOT NULL,
  total_fifo_cost numeric(24,4) NOT NULL,
  total_destroyed_fifo_cost numeric(24,4) NOT NULL,
  notes text,
  posted_by uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  posted_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT backoffice_sales_return_receipts_company_id_unique UNIQUE(company_id,id),
  CONSTRAINT backoffice_sales_return_receipts_number_unique UNIQUE(company_id,receipt_no),
  CONSTRAINT backoffice_sales_return_receipts_return_fk FOREIGN KEY(company_id,return_id)
    REFERENCES public.backoffice_sales_returns(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_return_receipts_status_check CHECK(status='POSTED'),
  CONSTRAINT backoffice_sales_return_receipts_quantity_check CHECK(
    total_received_base_qty>0 AND total_restocked_base_qty>=0
    AND total_destroyed_base_qty>=0
    AND total_restocked_base_qty+total_destroyed_base_qty=total_received_base_qty),
  CONSTRAINT backoffice_sales_return_receipts_cost_check CHECK(
    total_fifo_cost>=0 AND total_destroyed_fifo_cost>=0
    AND total_destroyed_fifo_cost<=total_fifo_cost),
  CONSTRAINT backoffice_sales_return_receipts_notes_check CHECK(
    notes IS NULL OR length(notes)<=2000)
);

CREATE INDEX backoffice_sales_return_receipts_return_time
  ON public.backoffice_sales_return_receipts(company_id,return_id,posted_at,id);

CREATE TABLE public.backoffice_sales_return_receipt_lines(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL,
  receipt_id uuid NOT NULL,
  return_id uuid NOT NULL,
  return_line_id uuid NOT NULL,
  line_no integer NOT NULL,
  product_id uuid NOT NULL,
  uom_id uuid NOT NULL,
  warehouse_id uuid NOT NULL,
  disposition text NOT NULL,
  received_qty_uom numeric(24,6) NOT NULL,
  base_qty_per_uom numeric(24,6) NOT NULL,
  received_base_qty numeric(24,6) NOT NULL,
  fifo_cost_total numeric(24,4) NOT NULL,
  stock_movement_id uuid REFERENCES public.stock_movements(id) ON DELETE RESTRICT,
  notes text,
  product_code_snapshot text NOT NULL,
  product_name_snapshot text NOT NULL,
  uom_code_snapshot text NOT NULL,
  uom_name_snapshot text NOT NULL,
  warehouse_name_snapshot text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT backoffice_sales_return_receipt_lines_company_id_unique UNIQUE(company_id,id),
  CONSTRAINT backoffice_sales_return_receipt_lines_number_unique UNIQUE(company_id,receipt_id,line_no),
  CONSTRAINT backoffice_sales_return_receipt_lines_header_fk FOREIGN KEY(company_id,receipt_id)
    REFERENCES public.backoffice_sales_return_receipts(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_return_receipt_lines_return_fk FOREIGN KEY(company_id,return_id)
    REFERENCES public.backoffice_sales_returns(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_return_receipt_lines_source_fk FOREIGN KEY(company_id,return_line_id)
    REFERENCES public.backoffice_sales_return_lines(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_return_receipt_lines_product_fk FOREIGN KEY(company_id,product_id)
    REFERENCES public.products(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_return_receipt_lines_uom_fk FOREIGN KEY(company_id,uom_id)
    REFERENCES public.uoms(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_return_receipt_lines_warehouse_fk FOREIGN KEY(company_id,warehouse_id)
    REFERENCES public.warehouses(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_return_receipt_lines_quantity_check CHECK(
    line_no>0 AND received_qty_uom>0 AND base_qty_per_uom>0
    AND received_base_qty=received_qty_uom*base_qty_per_uom),
  CONSTRAINT backoffice_sales_return_receipt_lines_disposition_check CHECK(
    disposition IN('RESTOCK','DESTROY')
    AND ((disposition='RESTOCK' AND stock_movement_id IS NOT NULL)
      OR (disposition='DESTROY' AND stock_movement_id IS NULL
        AND nullif(btrim(notes),'') IS NOT NULL))),
  CONSTRAINT backoffice_sales_return_receipt_lines_cost_check CHECK(fifo_cost_total>=0),
  CONSTRAINT backoffice_sales_return_receipt_lines_snapshot_check CHECK(
    nullif(btrim(product_code_snapshot),'') IS NOT NULL
    AND nullif(btrim(product_name_snapshot),'') IS NOT NULL
    AND nullif(btrim(uom_code_snapshot),'') IS NOT NULL
    AND nullif(btrim(uom_name_snapshot),'') IS NOT NULL
    AND nullif(btrim(warehouse_name_snapshot),'') IS NOT NULL),
  CONSTRAINT backoffice_sales_return_receipt_lines_notes_check CHECK(
    notes IS NULL OR length(notes)<=2000)
);

CREATE INDEX backoffice_sales_return_receipt_lines_source
  ON public.backoffice_sales_return_receipt_lines(company_id,return_line_id,created_at,id);

CREATE TABLE public.backoffice_sales_return_receipt_fifo_restorations(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL,
  receipt_id uuid NOT NULL,
  receipt_line_id uuid NOT NULL,
  source_customer_receipt_fifo_allocation_id uuid NOT NULL,
  source_transit_batch_id uuid NOT NULL,
  restored_product_batch_id uuid,
  disposition text NOT NULL,
  quantity_base numeric(24,6) NOT NULL,
  unit_cost numeric(24,4) NOT NULL,
  total_cost numeric(24,4) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT backoffice_sales_return_receipt_fifo_company_id_unique UNIQUE(company_id,id),
  CONSTRAINT backoffice_sales_return_receipt_fifo_header_fk FOREIGN KEY(company_id,receipt_id)
    REFERENCES public.backoffice_sales_return_receipts(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_return_receipt_fifo_line_fk FOREIGN KEY(company_id,receipt_line_id)
    REFERENCES public.backoffice_sales_return_receipt_lines(company_id,id) DEFERRABLE INITIALLY DEFERRED,
  CONSTRAINT backoffice_sales_return_receipt_fifo_source_fk
    FOREIGN KEY(company_id,source_customer_receipt_fifo_allocation_id)
    REFERENCES public.backoffice_sales_receipt_fifo_allocations(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_return_receipt_fifo_source_batch_fk
    FOREIGN KEY(company_id,source_transit_batch_id)
    REFERENCES public.product_batches(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_return_receipt_fifo_restored_batch_fk
    FOREIGN KEY(company_id,restored_product_batch_id)
    REFERENCES public.product_batches(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_return_receipt_fifo_shape_check CHECK(
    disposition IN('RESTOCK','DESTROY') AND quantity_base>0 AND unit_cost>=0
    AND total_cost=round(quantity_base*unit_cost,4)
    AND ((disposition='RESTOCK' AND restored_product_batch_id IS NOT NULL)
      OR (disposition='DESTROY' AND restored_product_batch_id IS NULL)))
);

CREATE INDEX backoffice_sales_return_receipt_fifo_source
  ON public.backoffice_sales_return_receipt_fifo_restorations(
    company_id,source_customer_receipt_fifo_allocation_id,id);

CREATE TABLE public.backoffice_sales_return_receipt_operations(
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
  operation_id uuid NOT NULL,
  return_id uuid NOT NULL,
  receipt_id uuid NOT NULL,
  expected_version bigint NOT NULL,
  request_hash text NOT NULL,
  response_snapshot jsonb NOT NULL,
  actor_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT backoffice_sales_return_receipt_operations_identity_unique UNIQUE(company_id,operation_id),
  CONSTRAINT backoffice_sales_return_receipt_operations_return_fk FOREIGN KEY(company_id,return_id)
    REFERENCES public.backoffice_sales_returns(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_return_receipt_operations_receipt_fk FOREIGN KEY(company_id,receipt_id)
    REFERENCES public.backoffice_sales_return_receipts(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_return_receipt_operations_shape_check CHECK(
    expected_version>0 AND request_hash~'^[0-9a-f]{64}$'
    AND jsonb_typeof(response_snapshot)='object')
);

CREATE TABLE public.backoffice_sales_return_receipt_audit(
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
  return_id uuid NOT NULL,
  receipt_id uuid NOT NULL,
  operation_id uuid NOT NULL,
  actor_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  before_state jsonb NOT NULL,
  after_state jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT backoffice_sales_return_receipt_audit_return_fk FOREIGN KEY(company_id,return_id)
    REFERENCES public.backoffice_sales_returns(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_return_receipt_audit_receipt_fk FOREIGN KEY(company_id,receipt_id)
    REFERENCES public.backoffice_sales_return_receipts(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_return_receipt_audit_operation_fk FOREIGN KEY(company_id,operation_id)
    REFERENCES public.backoffice_sales_return_receipt_operations(company_id,operation_id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_return_receipt_audit_shape_check CHECK(
    jsonb_typeof(before_state)='object' AND jsonb_typeof(after_state)='object')
);

CREATE FUNCTION private.trg_guard_backoffice_sales_return_receipt_history()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
  IF TG_OP='UPDATE' AND TG_TABLE_NAME='backoffice_sales_return_receipts'
    AND current_setting('kgs.backoffice_return_receipt_finalize',true)='1'
    AND NEW.id=OLD.id AND NEW.company_id=OLD.company_id
    AND NEW.receipt_no=OLD.receipt_no AND NEW.return_id=OLD.return_id
    AND NEW.receipt_date=OLD.receipt_date AND NEW.status=OLD.status
    AND NEW.total_received_base_qty=OLD.total_received_base_qty
    AND NEW.total_restocked_base_qty=OLD.total_restocked_base_qty
    AND NEW.total_destroyed_base_qty=OLD.total_destroyed_base_qty
    AND OLD.total_fifo_cost=0 AND OLD.total_destroyed_fifo_cost=0
    AND NEW.total_fifo_cost>=0 AND NEW.total_destroyed_fifo_cost>=0
    AND NEW.notes IS NOT DISTINCT FROM OLD.notes AND NEW.posted_by=OLD.posted_by
    AND NEW.posted_at=OLD.posted_at AND NEW.created_at=OLD.created_at THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'BACKOFFICE_SALES_RETURN_RECEIPT_HISTORY_IMMUTABLE';
END
$$;

CREATE TRIGGER backoffice_sales_return_receipts_immutable
BEFORE UPDATE OR DELETE ON public.backoffice_sales_return_receipts
FOR EACH ROW EXECUTE FUNCTION private.trg_guard_backoffice_sales_return_receipt_history();
CREATE TRIGGER backoffice_sales_return_receipt_lines_immutable
BEFORE UPDATE OR DELETE ON public.backoffice_sales_return_receipt_lines
FOR EACH ROW EXECUTE FUNCTION private.trg_guard_backoffice_sales_return_receipt_history();
CREATE TRIGGER backoffice_sales_return_receipt_fifo_immutable
BEFORE UPDATE OR DELETE ON public.backoffice_sales_return_receipt_fifo_restorations
FOR EACH ROW EXECUTE FUNCTION private.trg_guard_backoffice_sales_return_receipt_history();
CREATE TRIGGER backoffice_sales_return_receipt_operations_immutable
BEFORE UPDATE OR DELETE ON public.backoffice_sales_return_receipt_operations
FOR EACH ROW EXECUTE FUNCTION private.trg_guard_backoffice_sales_return_receipt_history();
CREATE TRIGGER backoffice_sales_return_receipt_audit_immutable
BEFORE UPDATE OR DELETE ON public.backoffice_sales_return_receipt_audit
FOR EACH ROW EXECUTE FUNCTION private.trg_guard_backoffice_sales_return_receipt_history();

CREATE OR REPLACE FUNCTION private.backoffice_sales_return_snapshot(
  p_company_id uuid,p_return_id uuid
) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
  SELECT jsonb_build_object(
    'id',document.id,'returnNo',document.return_no,'salesOrderId',document.sales_order_id,
    'salesOrderNo',sales_order.order_no,'quotationNo',sales_order.quotation_no,
    'customerId',document.customer_id,'customerSnapshot',sales_order.customer_snapshot,
    'status',document.status,'reason',document.reason,'notes',document.notes,
    'totalRequestedBaseQty',document.total_requested_base_qty,
    'totalReceivedBaseQty',document.total_received_base_qty,
    'totalRestockedBaseQty',document.total_restocked_base_qty,
    'totalDestroyedBaseQty',document.total_destroyed_base_qty,
    'goodsStatus',CASE WHEN document.total_received_base_qty=0 THEN 'WAITING_RECEIPT'
      WHEN document.total_received_base_qty<document.total_requested_base_qty THEN 'PARTIALLY_RECEIVED'
      ELSE 'RECEIVED' END,
    'masterVersion',document.master_version,'createdAt',document.created_at,
    'updatedAt',document.updated_at,'submittedAt',document.submitted_at,
    'approvedAt',document.approved_at,'canceledAt',document.canceled_at,
    'cancelReason',document.cancel_reason,
    'lines',COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'id',line.id,'lineNo',line.line_no,'salesOrderLineId',line.sales_order_line_id,
      'productId',line.product_id,'uomId',line.uom_id,
      'requestedQtyUom',line.requested_qty_uom,'baseQtyPerUom',line.base_qty_per_uom,
      'requestedBaseQty',line.requested_base_qty,'lineReason',line.line_reason,
      'receivedBaseQty',COALESCE((SELECT sum(receipt_line.received_base_qty)
        FROM public.backoffice_sales_return_receipt_lines receipt_line
        WHERE receipt_line.company_id=line.company_id AND receipt_line.return_line_id=line.id),0),
      'productCode',line.product_code_snapshot,'productName',line.product_name_snapshot,
      'uomCode',line.uom_code_snapshot,'uomName',line.uom_name_snapshot
    ) ORDER BY line.line_no) FROM public.backoffice_sales_return_lines line
      WHERE line.company_id=document.company_id AND line.return_id=document.id),'[]'::jsonb),
    'receipts',COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'id',receipt.id,'receiptNo',receipt.receipt_no,'receiptDate',receipt.receipt_date,
      'status',receipt.status,'totalReceivedBaseQty',receipt.total_received_base_qty,
      'totalRestockedBaseQty',receipt.total_restocked_base_qty,
      'totalDestroyedBaseQty',receipt.total_destroyed_base_qty,
      'totalFifoCost',receipt.total_fifo_cost,'notes',receipt.notes,'postedAt',receipt.posted_at
    ) ORDER BY receipt.posted_at,receipt.id)
    FROM public.backoffice_sales_return_receipts receipt
    WHERE receipt.company_id=document.company_id AND receipt.return_id=document.id),'[]'::jsonb)
  )
  FROM public.backoffice_sales_returns document
  JOIN public.backoffice_sales_orders sales_order ON sales_order.company_id=document.company_id
    AND sales_order.id=document.sales_order_id
  WHERE document.company_id=p_company_id AND document.id=p_return_id
$$;

CREATE FUNCTION private.backoffice_sales_return_receipt_operation_retry(
  p_company_id uuid,p_operation_id uuid,p_request_hash text
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_existing public.backoffice_sales_return_receipt_operations%rowtype;
BEGIN
  SELECT * INTO v_existing FROM public.backoffice_sales_return_receipt_operations
  WHERE company_id=p_company_id AND operation_id=p_operation_id;
  IF NOT FOUND THEN RETURN NULL; END IF;
  IF v_existing.request_hash<>p_request_hash THEN
    RAISE EXCEPTION 'IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_REQUEST';
  END IF;
  RETURN v_existing.response_snapshot||jsonb_build_object('exactRetry',true);
END
$$;

CREATE FUNCTION private.post_backoffice_sales_return_receipt_core(
  p_return_id uuid,p_expected_version bigint,p_operation_id uuid,
  p_receipt_date date,p_lines jsonb,p_notes text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE
  v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
  v_document public.backoffice_sales_returns%rowtype;v_return_line public.backoffice_sales_return_lines%rowtype;
  v_item jsonb;v_receipt_id uuid:=gen_random_uuid();v_receipt_no text;v_receipt_line_id uuid;
  v_line_no integer:=0;v_qty_uom numeric;v_qty_base numeric;v_received_before numeric;
  v_disposition text;v_warehouse uuid;v_warehouse_name text;v_line_notes text;
  v_hash text;v_retry jsonb;v_before jsonb;v_after jsonb;v_response jsonb;
  v_total numeric:=0;v_total_restock numeric:=0;v_total_destroy numeric:=0;
  v_total_cost numeric:=0;v_destroy_cost numeric:=0;v_line_cost numeric;v_remaining numeric;
  v_source record;v_available numeric;v_take numeric;v_batch_id uuid;v_movement_id uuid;
  v_stock_after numeric;v_base_uom uuid;v_base_uom_name text;v_company_today date;
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'inventory.customer_return_receipts','POST');
  IF p_return_id IS NULL OR p_expected_version IS NULL OR p_operation_id IS NULL
    OR p_receipt_date IS NULL OR jsonb_typeof(p_lines)<>'array'
    OR jsonb_array_length(p_lines)=0 THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_RETURN_RECEIPT_INPUT_REQUIRED';
  END IF;
  IF p_notes IS NOT NULL AND length(p_notes)>2000 THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_RETURN_RECEIPT_NOTES_TOO_LONG';
  END IF;
  SELECT (clock_timestamp() AT TIME ZONE company.timezone)::date INTO v_company_today
  FROM public.companies company WHERE company.id=v_company AND company.status='ACTIVE';
  IF v_company_today IS NULL OR p_receipt_date>v_company_today THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_RETURN_RECEIPT_DATE_FUTURE';
  END IF;
  v_hash:=encode(extensions.digest(convert_to(jsonb_build_object(
    'returnId',p_return_id,'expectedVersion',p_expected_version,
    'receiptDate',p_receipt_date,'lines',p_lines,
    'notes',nullif(btrim(COALESCE(p_notes,'')),'')
  )::text,'UTF8'),'sha256'),'hex');
  PERFORM pg_advisory_xact_lock(hashtextextended(v_company::text||':'||p_operation_id::text,0));
  v_retry:=private.backoffice_sales_return_receipt_operation_retry(
    v_company,p_operation_id,v_hash);
  IF v_retry IS NOT NULL THEN RETURN v_retry; END IF;

  SELECT * INTO v_document FROM public.backoffice_sales_returns
  WHERE company_id=v_company AND id=p_return_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'BACKOFFICE_SALES_RETURN_NOT_FOUND'; END IF;
  IF p_expected_version IS DISTINCT FROM v_document.master_version THEN
    RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
  END IF;
  IF v_document.status NOT IN('APPROVED','PARTIALLY_RECEIVED','RECEIVED')
    OR v_document.approved_at IS NULL THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_RETURN_RECEIPT_STATE_INVALID';
  END IF;
  IF v_document.total_received_base_qty>=v_document.total_requested_base_qty THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_RETURN_ALREADY_FULLY_RECEIVED';
  END IF;
  v_before:=private.backoffice_sales_return_snapshot(v_company,p_return_id);
  v_receipt_no:='CRR-'||to_char(p_receipt_date,'YYYYMMDD')||'-'||
    lpad(nextval('private.backoffice_sales_return_receipt_no_seq')::text,10,'0');

  -- Header is inserted before its immutable lines; totals are known from the
  -- validated loop below and written only once.
  FOR v_item IN SELECT value FROM jsonb_array_elements(p_lines) LOOP
    v_line_no:=v_line_no+1;
    BEGIN
      SELECT * INTO STRICT v_return_line FROM public.backoffice_sales_return_lines
      WHERE company_id=v_company AND id=(v_item->>'returnLineId')::uuid
        AND return_id=p_return_id;
      v_qty_uom:=(v_item->>'quantityUom')::numeric;
      v_warehouse:=(v_item->>'warehouseId')::uuid;
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'BACKOFFICE_SALES_RETURN_RECEIPT_LINE_INVALID';
    END;
    v_disposition:=upper(btrim(COALESCE(v_item->>'disposition','')));
    v_line_notes:=nullif(btrim(COALESCE(v_item->>'notes','')),'');
    IF v_qty_uom IS NULL OR v_qty_uom<=0 OR v_disposition NOT IN('RESTOCK','DESTROY')
      OR (v_disposition='DESTROY' AND v_line_notes IS NULL) THEN
      RAISE EXCEPTION 'BACKOFFICE_SALES_RETURN_RECEIPT_LINE_INVALID';
    END IF;
    SELECT warehouse.name INTO v_warehouse_name FROM public.warehouses warehouse
    WHERE warehouse.company_id=v_company AND warehouse.id=v_warehouse
      AND warehouse.is_active;
    IF v_warehouse_name IS NULL THEN
      RAISE EXCEPTION 'BACKOFFICE_SALES_RETURN_RECEIPT_WAREHOUSE_INVALID';
    END IF;
    v_qty_base:=v_qty_uom*v_return_line.base_qty_per_uom;
    SELECT COALESCE(sum(line.received_base_qty),0) INTO v_received_before
    FROM public.backoffice_sales_return_receipt_lines line
    WHERE line.company_id=v_company AND line.return_line_id=v_return_line.id;
    -- Include earlier entries for the same Return line in this payload.
    SELECT v_received_before+COALESCE(sum((entry.value->>'quantityUom')::numeric
      *v_return_line.base_qty_per_uom),0) INTO v_received_before
    FROM jsonb_array_elements(p_lines) WITH ORDINALITY entry(value,ordinality)
    WHERE entry.ordinality<v_line_no
      AND entry.value->>'returnLineId'=v_return_line.id::text;
    IF v_received_before+v_qty_base>v_return_line.requested_base_qty THEN
      RAISE EXCEPTION 'BACKOFFICE_SALES_RETURN_RECEIPT_QUANTITY_EXCEEDS_APPROVED';
    END IF;
    v_total:=v_total+v_qty_base;
    IF v_disposition='RESTOCK' THEN v_total_restock:=v_total_restock+v_qty_base;
    ELSE v_total_destroy:=v_total_destroy+v_qty_base; END IF;
  END LOOP;
  IF v_document.total_received_base_qty+v_total>v_document.total_requested_base_qty THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_RETURN_RECEIPT_QUANTITY_EXCEEDS_APPROVED';
  END IF;

  INSERT INTO public.backoffice_sales_return_receipts(id,company_id,receipt_no,
    return_id,receipt_date,total_received_base_qty,total_restocked_base_qty,
    total_destroyed_base_qty,total_fifo_cost,total_destroyed_fifo_cost,notes,posted_by)
  VALUES(v_receipt_id,v_company,v_receipt_no,p_return_id,p_receipt_date,v_total,
    v_total_restock,v_total_destroy,0,0,nullif(btrim(COALESCE(p_notes,'')),''),v_actor);

  v_line_no:=0;
  FOR v_item IN SELECT value FROM jsonb_array_elements(p_lines) LOOP
    v_line_no:=v_line_no+1;
    SELECT * INTO STRICT v_return_line FROM public.backoffice_sales_return_lines
    WHERE company_id=v_company AND id=(v_item->>'returnLineId')::uuid AND return_id=p_return_id;
    v_qty_uom:=(v_item->>'quantityUom')::numeric;
    v_qty_base:=v_qty_uom*v_return_line.base_qty_per_uom;
    v_warehouse:=(v_item->>'warehouseId')::uuid;
    v_disposition:=upper(btrim(v_item->>'disposition'));
    v_line_notes:=nullif(btrim(COALESCE(v_item->>'notes','')),'');
    SELECT warehouse.name INTO STRICT v_warehouse_name FROM public.warehouses warehouse
    WHERE warehouse.company_id=v_company AND warehouse.id=v_warehouse AND warehouse.is_active;
    SELECT product.uom_id,uom.name INTO STRICT v_base_uom,v_base_uom_name
    FROM public.products product JOIN public.uoms uom
      ON uom.company_id=product.company_id AND uom.id=product.uom_id
    WHERE product.company_id=v_company AND product.id=v_return_line.product_id;
    v_receipt_line_id:=gen_random_uuid();v_line_cost:=0;v_remaining:=v_qty_base;
    FOR v_source IN
      SELECT allocation.id allocation_id,allocation.transit_batch_id,
        allocation.quantity_base,allocation.unit_cost
      FROM public.backoffice_sales_receipt_fifo_allocations allocation
      JOIN public.backoffice_sales_delivery_receipt_lines customer_line
        ON customer_line.company_id=allocation.company_id
       AND customer_line.id=allocation.receipt_line_id
      JOIN public.backoffice_sales_delivery_receipts customer_receipt
        ON customer_receipt.company_id=customer_line.company_id
       AND customer_receipt.id=customer_line.receipt_id
      WHERE allocation.company_id=v_company
        AND customer_line.sales_order_line_id=v_return_line.sales_order_line_id
      ORDER BY customer_receipt.accepted_at,allocation.created_at,allocation.id
      FOR UPDATE OF allocation
    LOOP
      EXIT WHEN v_remaining<=0;
      SELECT v_source.quantity_base-COALESCE(sum(restoration.quantity_base),0)
      INTO v_available
      FROM public.backoffice_sales_return_receipt_fifo_restorations restoration
      WHERE restoration.company_id=v_company
        AND restoration.source_customer_receipt_fifo_allocation_id=v_source.allocation_id;
      v_available:=COALESCE(v_available,v_source.quantity_base);
      IF v_available<=0 THEN CONTINUE; END IF;
      v_take:=LEAST(v_remaining,v_available);v_batch_id:=NULL;
      IF v_disposition='RESTOCK' THEN
        INSERT INTO public.product_batches(product_id,warehouse_id,purchase_detail_id,
          qty_purchased,qty_remaining,cogs_unit,company_id)
        VALUES(v_return_line.product_id,v_warehouse,NULL,v_take,v_take,
          v_source.unit_cost,v_company) RETURNING id INTO v_batch_id;
      END IF;
      INSERT INTO public.backoffice_sales_return_receipt_fifo_restorations(
        company_id,receipt_id,receipt_line_id,source_customer_receipt_fifo_allocation_id,
        source_transit_batch_id,restored_product_batch_id,disposition,
        quantity_base,unit_cost,total_cost)
      VALUES(v_company,v_receipt_id,v_receipt_line_id,v_source.allocation_id,
        v_source.transit_batch_id,v_batch_id,v_disposition,v_take,v_source.unit_cost,
        round(v_take*v_source.unit_cost,4));
      v_line_cost:=v_line_cost+round(v_take*v_source.unit_cost,4);
      v_remaining:=v_remaining-v_take;
    END LOOP;
    IF v_remaining<>0 THEN
      RAISE EXCEPTION 'BACKOFFICE_SALES_RETURN_SOURCE_FIFO_EXHAUSTED';
    END IF;
    v_movement_id:=NULL;
    IF v_disposition='RESTOCK' THEN
      v_movement_id:=gen_random_uuid();
      INSERT INTO public.product_stocks(product_id,warehouse_id,stock_qty,company_id)
      VALUES(v_return_line.product_id,v_warehouse,v_qty_base,v_company)
      ON CONFLICT(product_id,warehouse_id) DO UPDATE SET
        stock_qty=public.product_stocks.stock_qty+excluded.stock_qty,
        updated_at=clock_timestamp()
      RETURNING stock_qty INTO v_stock_after;
      INSERT INTO public.stock_movements(id,product_id,warehouse_id,qty_change,
        movement_type,reference_table,reference_id,company_id,base_uom_id,
        base_uom_name_snapshot,balance_after_base_qty,actor_id,posted_at,
        movement_status,source_line_id,notes)
      VALUES(v_movement_id,v_return_line.product_id,v_warehouse,v_qty_base,
        'SALES_RETURN'::public.stock_movement_type,'backoffice_sales_return_receipts',
        v_receipt_id,v_company,v_base_uom,v_base_uom_name,v_stock_after,v_actor,
        clock_timestamp(),'POSTED',v_receipt_line_id,
        COALESCE(v_line_notes,'Backoffice Customer Return restock'));
    END IF;
    INSERT INTO public.backoffice_sales_return_receipt_lines(id,company_id,receipt_id,
      return_id,return_line_id,line_no,product_id,uom_id,warehouse_id,disposition,
      received_qty_uom,base_qty_per_uom,received_base_qty,fifo_cost_total,
      stock_movement_id,notes,product_code_snapshot,product_name_snapshot,
      uom_code_snapshot,uom_name_snapshot,warehouse_name_snapshot)
    VALUES(v_receipt_line_id,v_company,v_receipt_id,p_return_id,v_return_line.id,
      v_line_no,v_return_line.product_id,v_return_line.uom_id,v_warehouse,v_disposition,
      v_qty_uom,v_return_line.base_qty_per_uom,v_qty_base,v_line_cost,v_movement_id,
      v_line_notes,v_return_line.product_code_snapshot,v_return_line.product_name_snapshot,
      v_return_line.uom_code_snapshot,v_return_line.uom_name_snapshot,v_warehouse_name);
    v_total_cost:=v_total_cost+v_line_cost;
    IF v_disposition='DESTROY' THEN v_destroy_cost:=v_destroy_cost+v_line_cost; END IF;
  END LOOP;

  PERFORM set_config('kgs.backoffice_return_receipt_finalize','1',true);
  UPDATE public.backoffice_sales_return_receipts SET
    total_fifo_cost=v_total_cost,total_destroyed_fifo_cost=v_destroy_cost
  WHERE company_id=v_company AND id=v_receipt_id;
  PERFORM set_config('kgs.backoffice_return_receipt_finalize','',true);
  UPDATE public.backoffice_sales_returns SET
    total_received_base_qty=total_received_base_qty+v_total,
    total_restocked_base_qty=total_restocked_base_qty+v_total_restock,
    total_destroyed_base_qty=total_destroyed_base_qty+v_total_destroy,
    status=CASE WHEN total_received_base_qty+v_total=total_requested_base_qty
      THEN 'RECEIVED' ELSE 'PARTIALLY_RECEIVED' END,
    master_version=master_version+1,updated_by=v_actor,updated_at=clock_timestamp()
  WHERE company_id=v_company AND id=p_return_id;
  v_after:=private.backoffice_sales_return_snapshot(v_company,p_return_id);
  v_response:=jsonb_build_object('companyId',v_company,'returnId',p_return_id,
    'receiptId',v_receipt_id,'receiptNo',v_receipt_no,'data',v_after,
    'exactRetry',false);
  INSERT INTO public.backoffice_sales_return_receipt_operations(company_id,
    operation_id,return_id,receipt_id,expected_version,request_hash,
    response_snapshot,actor_id)
  VALUES(v_company,p_operation_id,p_return_id,v_receipt_id,p_expected_version,
    v_hash,v_response,v_actor);
  INSERT INTO public.backoffice_sales_return_receipt_audit(company_id,return_id,
    receipt_id,operation_id,actor_id,before_state,after_state)
  VALUES(v_company,p_return_id,v_receipt_id,p_operation_id,v_actor,v_before,v_after);
  RETURN v_response;
END
$$;

CREATE FUNCTION public.post_backoffice_sales_return_receipt(
  p_return_id uuid,p_expected_version bigint,p_operation_id uuid,
  p_receipt_date date,p_lines jsonb,p_notes text DEFAULT NULL
) RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path=public,pg_temp AS $$
  SELECT private.post_backoffice_sales_return_receipt_core(
    p_return_id,p_expected_version,p_operation_id,p_receipt_date,p_lines,p_notes)
$$;

ALTER TABLE public.backoffice_sales_return_receipts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.backoffice_sales_return_receipt_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.backoffice_sales_return_receipt_fifo_restorations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.backoffice_sales_return_receipt_operations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.backoffice_sales_return_receipt_audit ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.backoffice_sales_return_receipts,
  public.backoffice_sales_return_receipt_lines,
  public.backoffice_sales_return_receipt_fifo_restorations,
  public.backoffice_sales_return_receipt_operations,
  public.backoffice_sales_return_receipt_audit FROM PUBLIC,anon,authenticated;
GRANT SELECT,INSERT ON TABLE public.backoffice_sales_return_receipts,
  public.backoffice_sales_return_receipt_lines,
  public.backoffice_sales_return_receipt_fifo_restorations,
  public.backoffice_sales_return_receipt_operations,
  public.backoffice_sales_return_receipt_audit TO service_role;
GRANT UPDATE ON TABLE public.backoffice_sales_return_receipts TO service_role;
GRANT USAGE,SELECT ON SEQUENCE public.backoffice_sales_return_receipt_operations_id_seq,
  public.backoffice_sales_return_receipt_audit_id_seq TO service_role;

REVOKE ALL ON FUNCTION private.trg_guard_backoffice_sales_return_receipt_history(),
  private.backoffice_sales_return_receipt_operation_retry(uuid,uuid,text),
  private.post_backoffice_sales_return_receipt_core(uuid,bigint,uuid,date,jsonb,text)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.trg_guard_backoffice_sales_return_receipt_history(),
  private.backoffice_sales_return_receipt_operation_retry(uuid,uuid,text),
  private.post_backoffice_sales_return_receipt_core(uuid,bigint,uuid,date,jsonb,text)
TO service_role;
REVOKE ALL ON FUNCTION public.post_backoffice_sales_return_receipt(
  uuid,bigint,uuid,date,jsonb,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.post_backoffice_sales_return_receipt(
  uuid,bigint,uuid,date,jsonb,text) TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260917120000','backoffice_sales_return_customer_receipt',
  'Warehouse Customer Return Receipt with partial actual quantity, per-line RESTOCK or note-required DESTROY, original Customer Receipt FIFO lineage, exact retry and immutable audit; zero Invoice, Refund or Finance posting');

NOTIFY pgrst,'reload schema';
COMMIT;
