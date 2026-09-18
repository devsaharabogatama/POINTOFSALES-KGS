-- Backoffice Sales Return commercial foundation.
-- Creates Draft -> Submitted -> Approved lifecycle only. This migration has zero
-- Stock, FIFO, Invoice, Credit Note, Refund, Cashier Session, Financial Event or
-- Finance Journal mutation.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260912140000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Backoffice Sales invoice status runtime required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260917110000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260917110000';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
    WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
  IF to_regclass('public.backoffice_sales_returns') IS NOT NULL
    OR to_regclass('public.backoffice_sales_return_lines') IS NOT NULL
    OR to_regclass('public.backoffice_sales_return_operations') IS NOT NULL
    OR to_regclass('public.backoffice_sales_return_audit') IS NOT NULL
    OR to_regprocedure('private.backoffice_sales_return_snapshot(uuid,uuid)') IS NOT NULL
    OR to_regprocedure('public.save_backoffice_sales_return_draft(uuid,bigint,uuid,uuid,jsonb)') IS NOT NULL
    OR EXISTS(SELECT 1 FROM public.access_permission_catalog
      WHERE permission_key='sales.backoffice_returns') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Backoffice Sales Return foundation collision';
  END IF;
END
$guard$;

INSERT INTO public.access_permission_catalog(
  permission_key,module_key,permission_label,description,view_roles,
  operator_roles,approver_roles,supported_capabilities,required_any_features,
  is_customizable,enforcement_status
) VALUES(
  'sales.backoffice_returns','SALES','Retur Penjualan Backoffice',
  'Pengajuan, review, dan persetujuan retur atas barang yang sudah diterima Customer',
  ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','SALES','SALES_ADMIN','FINANCE'],
  ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','SALES','SALES_ADMIN'],
  ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','SALES_ADMIN','FINANCE'],
  ARRAY['VIEW','CREATE_DRAFT','EDIT_DRAFT','REVIEW','APPROVE','CANCEL_FINAL'],
  ARRAY['backoffice_delivered_qty_sales_enabled'],true,'ENFORCED'
);

CREATE SEQUENCE private.backoffice_sales_return_no_seq AS bigint START WITH 1;
REVOKE ALL ON SEQUENCE private.backoffice_sales_return_no_seq
  FROM PUBLIC,anon,authenticated;
GRANT USAGE,SELECT ON SEQUENCE private.backoffice_sales_return_no_seq TO service_role;

CREATE TABLE public.backoffice_sales_returns(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
  return_no text NOT NULL,
  sales_order_id uuid NOT NULL,
  customer_id uuid NOT NULL,
  status text NOT NULL DEFAULT 'DRAFT',
  reason text NOT NULL,
  notes text,
  total_requested_base_qty numeric(24,6) NOT NULL DEFAULT 0,
  master_version bigint NOT NULL DEFAULT 1,
  created_by uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  updated_by uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  submitted_by uuid REFERENCES public.profiles(id) ON DELETE RESTRICT,
  submitted_at timestamptz,
  approved_by uuid REFERENCES public.profiles(id) ON DELETE RESTRICT,
  approved_at timestamptz,
  canceled_by uuid REFERENCES public.profiles(id) ON DELETE RESTRICT,
  canceled_at timestamptz,
  cancel_reason text,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT backoffice_sales_returns_company_id_unique UNIQUE(company_id,id),
  CONSTRAINT backoffice_sales_returns_number_unique UNIQUE(company_id,return_no),
  CONSTRAINT backoffice_sales_returns_order_fk FOREIGN KEY(company_id,sales_order_id)
    REFERENCES public.backoffice_sales_orders(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_returns_customer_fk FOREIGN KEY(company_id,customer_id)
    REFERENCES public.customers(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_returns_status_check CHECK(status IN(
    'DRAFT','SUBMITTED','APPROVED','PARTIALLY_RECEIVED','RECEIVED',
    'CREDIT_PENDING','REFUND_PENDING','COMPLETED','CANCELED')),
  CONSTRAINT backoffice_sales_returns_reason_check CHECK(
    nullif(btrim(reason),'') IS NOT NULL AND length(reason)<=500),
  CONSTRAINT backoffice_sales_returns_notes_check CHECK(notes IS NULL OR length(notes)<=2000),
  CONSTRAINT backoffice_sales_returns_quantity_check CHECK(total_requested_base_qty>=0),
  CONSTRAINT backoffice_sales_returns_version_check CHECK(master_version>0),
  CONSTRAINT backoffice_sales_returns_actor_time_check CHECK(
    (submitted_by IS NULL)=(submitted_at IS NULL)
    AND (approved_by IS NULL)=(approved_at IS NULL)
    AND (canceled_by IS NULL)=(canceled_at IS NULL)),
  CONSTRAINT backoffice_sales_returns_lifecycle_check CHECK(
    (status='DRAFT' AND submitted_at IS NULL AND approved_at IS NULL AND canceled_at IS NULL)
    OR (status='SUBMITTED' AND submitted_at IS NOT NULL AND approved_at IS NULL AND canceled_at IS NULL)
    OR (status IN('APPROVED','PARTIALLY_RECEIVED','RECEIVED','CREDIT_PENDING',
        'REFUND_PENDING','COMPLETED') AND submitted_at IS NOT NULL
        AND approved_at IS NOT NULL AND canceled_at IS NULL)
    OR (status='CANCELED' AND canceled_at IS NOT NULL
        AND nullif(btrim(cancel_reason),'') IS NOT NULL))
);

CREATE INDEX backoffice_sales_returns_company_status_time
  ON public.backoffice_sales_returns(company_id,status,updated_at DESC,id);
CREATE INDEX backoffice_sales_returns_order_time
  ON public.backoffice_sales_returns(company_id,sales_order_id,created_at DESC,id);

CREATE TABLE public.backoffice_sales_return_lines(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL,
  return_id uuid NOT NULL,
  sales_order_line_id uuid NOT NULL,
  line_no integer NOT NULL,
  product_id uuid NOT NULL,
  uom_id uuid NOT NULL,
  requested_qty_uom numeric(24,6) NOT NULL,
  base_qty_per_uom numeric(24,6) NOT NULL,
  requested_base_qty numeric(24,6)
    GENERATED ALWAYS AS (requested_qty_uom*base_qty_per_uom) STORED,
  line_reason text,
  product_code_snapshot text NOT NULL,
  product_name_snapshot text NOT NULL,
  uom_code_snapshot text NOT NULL,
  uom_name_snapshot text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT backoffice_sales_return_lines_company_id_unique UNIQUE(company_id,id),
  CONSTRAINT backoffice_sales_return_lines_return_line_unique UNIQUE(company_id,return_id,line_no),
  CONSTRAINT backoffice_sales_return_lines_source_unique UNIQUE(company_id,return_id,sales_order_line_id),
  CONSTRAINT backoffice_sales_return_lines_return_fk FOREIGN KEY(company_id,return_id)
    REFERENCES public.backoffice_sales_returns(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_return_lines_source_fk FOREIGN KEY(company_id,sales_order_line_id)
    REFERENCES public.backoffice_sales_order_lines(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_return_lines_product_fk FOREIGN KEY(company_id,product_id)
    REFERENCES public.products(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_return_lines_uom_fk FOREIGN KEY(company_id,uom_id)
    REFERENCES public.uoms(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_return_lines_quantity_check CHECK(
    line_no>0 AND requested_qty_uom>0 AND base_qty_per_uom>0),
  CONSTRAINT backoffice_sales_return_lines_reason_check CHECK(
    line_reason IS NULL OR length(line_reason)<=500),
  CONSTRAINT backoffice_sales_return_lines_snapshot_check CHECK(
    nullif(btrim(product_code_snapshot),'') IS NOT NULL
    AND nullif(btrim(product_name_snapshot),'') IS NOT NULL
    AND nullif(btrim(uom_code_snapshot),'') IS NOT NULL
    AND nullif(btrim(uom_name_snapshot),'') IS NOT NULL)
);

CREATE INDEX backoffice_sales_return_lines_source
  ON public.backoffice_sales_return_lines(company_id,sales_order_line_id,return_id);

CREATE TABLE public.backoffice_sales_return_operations(
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
  operation_id uuid NOT NULL,
  operation_type text NOT NULL,
  return_id uuid NOT NULL,
  expected_version bigint,
  request_hash text NOT NULL,
  response_snapshot jsonb NOT NULL,
  actor_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT backoffice_sales_return_operations_identity_unique UNIQUE(company_id,operation_id),
  CONSTRAINT backoffice_sales_return_operations_return_fk FOREIGN KEY(company_id,return_id)
    REFERENCES public.backoffice_sales_returns(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_return_operations_type_check CHECK(
    operation_type IN('SAVE_DRAFT','SUBMIT','APPROVE','CANCEL')),
  CONSTRAINT backoffice_sales_return_operations_version_check CHECK(
    expected_version IS NULL OR expected_version>0),
  CONSTRAINT backoffice_sales_return_operations_hash_check CHECK(
    request_hash~'^[0-9a-f]{64}$'),
  CONSTRAINT backoffice_sales_return_operations_response_check CHECK(
    jsonb_typeof(response_snapshot)='object')
);

CREATE TABLE public.backoffice_sales_return_audit(
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
  return_id uuid NOT NULL,
  operation_id uuid NOT NULL,
  action text NOT NULL,
  actor_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  reason text,
  before_state jsonb,
  after_state jsonb,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT backoffice_sales_return_audit_return_fk FOREIGN KEY(company_id,return_id)
    REFERENCES public.backoffice_sales_returns(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_return_audit_operation_fk FOREIGN KEY(company_id,operation_id)
    REFERENCES public.backoffice_sales_return_operations(company_id,operation_id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_return_audit_action_check CHECK(
    action IN('CREATE_DRAFT','UPDATE_DRAFT','SUBMIT','APPROVE','CANCEL')),
  CONSTRAINT backoffice_sales_return_audit_state_check CHECK(
    (before_state IS NULL OR jsonb_typeof(before_state)='object')
    AND (after_state IS NULL OR jsonb_typeof(after_state)='object')
    AND (before_state IS NOT NULL OR after_state IS NOT NULL))
);

CREATE INDEX backoffice_sales_return_operations_return_time
  ON public.backoffice_sales_return_operations(company_id,return_id,created_at DESC,id DESC);
CREATE INDEX backoffice_sales_return_audit_return_time
  ON public.backoffice_sales_return_audit(company_id,return_id,created_at DESC,id DESC);

CREATE FUNCTION private.trg_guard_backoffice_sales_return_history()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
  RAISE EXCEPTION 'BACKOFFICE_SALES_RETURN_HISTORY_IMMUTABLE';
END
$$;
CREATE TRIGGER backoffice_sales_return_operations_immutable
BEFORE UPDATE OR DELETE ON public.backoffice_sales_return_operations
FOR EACH ROW EXECUTE FUNCTION private.trg_guard_backoffice_sales_return_history();
CREATE TRIGGER backoffice_sales_return_audit_immutable
BEFORE UPDATE OR DELETE ON public.backoffice_sales_return_audit
FOR EACH ROW EXECUTE FUNCTION private.trg_guard_backoffice_sales_return_history();

CREATE FUNCTION private.backoffice_sales_return_snapshot(p_company_id uuid,p_return_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
  SELECT jsonb_build_object(
    'id',document.id,'returnNo',document.return_no,'salesOrderId',document.sales_order_id,
    'salesOrderNo',sales_order.order_no,'quotationNo',sales_order.quotation_no,
    'customerId',document.customer_id,'customerSnapshot',sales_order.customer_snapshot,
    'status',document.status,'reason',document.reason,'notes',document.notes,
    'totalRequestedBaseQty',document.total_requested_base_qty,
    'masterVersion',document.master_version,'createdAt',document.created_at,
    'updatedAt',document.updated_at,'submittedAt',document.submitted_at,
    'approvedAt',document.approved_at,'canceledAt',document.canceled_at,
    'cancelReason',document.cancel_reason,
    'lines',COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'id',line.id,'lineNo',line.line_no,'salesOrderLineId',line.sales_order_line_id,
      'productId',line.product_id,'uomId',line.uom_id,
      'requestedQtyUom',line.requested_qty_uom,'baseQtyPerUom',line.base_qty_per_uom,
      'requestedBaseQty',line.requested_base_qty,'lineReason',line.line_reason,
      'productCode',line.product_code_snapshot,'productName',line.product_name_snapshot,
      'uomCode',line.uom_code_snapshot,'uomName',line.uom_name_snapshot
    ) ORDER BY line.line_no) FROM public.backoffice_sales_return_lines line
      WHERE line.company_id=document.company_id AND line.return_id=document.id),'[]'::jsonb)
  )
  FROM public.backoffice_sales_returns document
  JOIN public.backoffice_sales_orders sales_order ON sales_order.company_id=document.company_id
    AND sales_order.id=document.sales_order_id
  WHERE document.company_id=p_company_id AND document.id=p_return_id
$$;

CREATE FUNCTION private.backoffice_sales_return_operation_retry(
  p_company_id uuid,p_operation_id uuid,p_operation_type text,p_request_hash text
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_operation public.backoffice_sales_return_operations%rowtype;
BEGIN
  SELECT * INTO v_operation FROM public.backoffice_sales_return_operations
  WHERE company_id=p_company_id AND operation_id=p_operation_id;
  IF NOT FOUND THEN RETURN NULL; END IF;
  IF v_operation.operation_type<>p_operation_type OR v_operation.request_hash<>p_request_hash THEN
    RAISE EXCEPTION 'IDEMPOTENCY_PAYLOAD_CONFLICT';
  END IF;
  RETURN v_operation.response_snapshot||jsonb_build_object('exactRetry',true);
END
$$;

CREATE FUNCTION private.assert_backoffice_sales_return_quantities(
  p_company_id uuid,p_return_id uuid,p_sales_order_id uuid
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_invalid bigint;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended(
    p_company_id::text||':backoffice-return:'||p_sales_order_id::text,0));
  SELECT count(*) INTO v_invalid
  FROM public.backoffice_sales_return_lines candidate
  JOIN public.backoffice_sales_order_lines source
    ON source.company_id=candidate.company_id AND source.id=candidate.sales_order_line_id
  WHERE candidate.company_id=p_company_id AND candidate.return_id=p_return_id
    AND candidate.requested_base_qty > greatest(0,
      source.accepted_base_qty-source.returned_before_invoice_base_qty
      -COALESCE((SELECT sum(other_line.requested_base_qty)
        FROM public.backoffice_sales_return_lines other_line
        JOIN public.backoffice_sales_returns other_return
          ON other_return.company_id=other_line.company_id AND other_return.id=other_line.return_id
        WHERE other_line.company_id=candidate.company_id
          AND other_line.sales_order_line_id=candidate.sales_order_line_id
          AND other_return.id<>p_return_id
          AND other_return.status NOT IN('DRAFT','CANCELED')),0));
  IF v_invalid>0 THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_RETURN_QUANTITY_EXCEEDS_RETURNABLE';
  END IF;
END
$$;

CREATE FUNCTION public.get_backoffice_sales_returns(
  p_status text DEFAULT NULL,p_search text DEFAULT NULL,p_limit integer DEFAULT 100
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_status text;
BEGIN
  PERFORM private.acp_require_permission_capability(v_company,'sales.backoffice_returns','VIEW');
  v_status:=nullif(upper(btrim(COALESCE(p_status,''))), '');
  IF v_status IS NOT NULL AND v_status NOT IN('DRAFT','SUBMITTED','APPROVED',
    'PARTIALLY_RECEIVED','RECEIVED','CREDIT_PENDING','REFUND_PENDING','COMPLETED','CANCELED') THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_RETURN_STATUS_INVALID';
  END IF;
  IF p_limit IS NULL OR p_limit<1 OR p_limit>500 THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_RETURN_LIMIT_INVALID';
  END IF;
  RETURN jsonb_build_object('companyId',v_company,'data',COALESCE((SELECT jsonb_agg(
    private.backoffice_sales_return_snapshot(v_company,row_data.id)
    ORDER BY row_data.updated_at DESC,row_data.id)
    FROM (SELECT document.id,document.updated_at
      FROM public.backoffice_sales_returns document
      JOIN public.backoffice_sales_orders sales_order
        ON sales_order.company_id=document.company_id AND sales_order.id=document.sales_order_id
      WHERE document.company_id=v_company AND (v_status IS NULL OR document.status=v_status)
        AND (nullif(btrim(COALESCE(p_search,'')),'') IS NULL
          OR document.return_no ILIKE '%'||btrim(p_search)||'%'
          OR COALESCE(sales_order.order_no,sales_order.quotation_no) ILIKE '%'||btrim(p_search)||'%'
          OR sales_order.customer_snapshot->>'name' ILIKE '%'||btrim(p_search)||'%')
      ORDER BY document.updated_at DESC,document.id LIMIT p_limit) row_data),'[]'::jsonb));
END
$$;

CREATE FUNCTION public.get_backoffice_sales_return(p_return_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_result jsonb;
BEGIN
  PERFORM private.acp_require_permission_capability(v_company,'sales.backoffice_returns','VIEW');
  v_result:=private.backoffice_sales_return_snapshot(v_company,p_return_id);
  IF v_result IS NULL THEN RAISE EXCEPTION 'BACKOFFICE_SALES_RETURN_NOT_FOUND'; END IF;
  RETURN jsonb_build_object('companyId',v_company,'data',v_result);
END
$$;

CREATE FUNCTION public.get_backoffice_sales_return_source(p_sales_order_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_order public.backoffice_sales_orders%rowtype;
BEGIN
  PERFORM private.acp_require_permission_capability(v_company,'sales.backoffice_returns','VIEW');
  SELECT * INTO v_order FROM public.backoffice_sales_orders
  WHERE company_id=v_company AND id=p_sales_order_id AND status='CONFIRMED';
  IF NOT FOUND THEN RAISE EXCEPTION 'BACKOFFICE_SALES_RETURN_SOURCE_NOT_FOUND'; END IF;
  RETURN jsonb_build_object('companyId',v_company,'data',jsonb_build_object(
    'salesOrderId',v_order.id,'salesOrderNo',v_order.order_no,'quotationNo',v_order.quotation_no,
    'customerId',v_order.customer_id,'customerSnapshot',v_order.customer_snapshot,
    'lines',COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'salesOrderLineId',line.id,'productId',line.product_id,'uomId',line.uom_id,
      'productCode',line.product_code_snapshot,'productName',line.product_name_snapshot,
      'uomCode',line.uom_code_snapshot,'uomName',line.uom_name_snapshot,
      'baseQtyPerUom',line.base_qty_per_uom,'acceptedBaseQty',line.accepted_base_qty,
      'returnableBaseQty',greatest(0,line.accepted_base_qty-line.returned_before_invoice_base_qty
        -COALESCE((SELECT sum(return_line.requested_base_qty)
          FROM public.backoffice_sales_return_lines return_line
          JOIN public.backoffice_sales_returns return_document
            ON return_document.company_id=return_line.company_id AND return_document.id=return_line.return_id
          WHERE return_line.company_id=line.company_id AND return_line.sales_order_line_id=line.id
            AND return_document.status NOT IN('DRAFT','CANCELED')),0))
    ) ORDER BY line.line_no) FROM public.backoffice_sales_order_lines line
      WHERE line.company_id=v_company AND line.sales_order_id=v_order.id
        AND line.accepted_base_qty>line.returned_before_invoice_base_qty),'[]'::jsonb)));
END
$$;

CREATE FUNCTION public.save_backoffice_sales_return_draft(
  p_return_id uuid,p_expected_version bigint,p_operation_id uuid,
  p_sales_order_id uuid,p_payload jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE
  v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
  v_document public.backoffice_sales_returns%rowtype;v_order public.backoffice_sales_orders%rowtype;
  v_before jsonb;v_after jsonb;v_response jsonb;v_retry jsonb;v_hash text;
  v_item jsonb;v_source public.backoffice_sales_order_lines%rowtype;
  v_source_id uuid;v_qty numeric;v_total numeric:=0;v_line_no integer:=0;v_ids uuid[]:='{}';
BEGIN
  PERFORM private.acp_require_permission_capability(v_company,'sales.backoffice_returns',
    CASE WHEN p_return_id IS NULL THEN 'CREATE_DRAFT' ELSE 'EDIT_DRAFT' END);
  IF p_operation_id IS NULL OR p_sales_order_id IS NULL OR p_payload IS NULL
    OR jsonb_typeof(p_payload)<>'object' OR jsonb_typeof(p_payload->'lines')<>'array'
    OR jsonb_array_length(p_payload->'lines')=0
    OR nullif(btrim(p_payload->>'reason'),'') IS NULL THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_RETURN_PAYLOAD_INVALID';
  END IF;
  v_hash:=encode(extensions.digest(convert_to(jsonb_build_object(
    'returnId',p_return_id,'expectedVersion',p_expected_version,
    'salesOrderId',p_sales_order_id,'payload',p_payload)::text,'UTF8'),'sha256'),'hex');
  PERFORM pg_advisory_xact_lock(hashtextextended(v_company::text||':'||p_operation_id::text,0));
  v_retry:=private.backoffice_sales_return_operation_retry(
    v_company,p_operation_id,'SAVE_DRAFT',v_hash);
  IF v_retry IS NOT NULL THEN RETURN v_retry; END IF;
  SELECT * INTO v_order FROM public.backoffice_sales_orders
  WHERE company_id=v_company AND id=p_sales_order_id AND status='CONFIRMED' FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'BACKOFFICE_SALES_RETURN_SOURCE_NOT_FOUND'; END IF;

  IF p_return_id IS NULL THEN
    IF p_expected_version IS NOT NULL THEN RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
    INSERT INTO public.backoffice_sales_returns(company_id,return_no,sales_order_id,
      customer_id,reason,notes,created_by,updated_by)
    VALUES(v_company,'RTN-'||to_char((clock_timestamp() AT TIME ZONE
        (SELECT timezone FROM public.companies WHERE id=v_company))::date,'YYYYMMDD')||'-'||
        lpad(nextval('private.backoffice_sales_return_no_seq')::text,10,'0'),
      v_order.id,v_order.customer_id,btrim(p_payload->>'reason'),
      nullif(btrim(p_payload->>'notes'),''),v_actor,v_actor) RETURNING * INTO v_document;
  ELSE
    SELECT * INTO v_document FROM public.backoffice_sales_returns
    WHERE company_id=v_company AND id=p_return_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'BACKOFFICE_SALES_RETURN_NOT_FOUND'; END IF;
    IF v_document.sales_order_id<>p_sales_order_id THEN
      RAISE EXCEPTION 'BACKOFFICE_SALES_RETURN_SOURCE_IMMUTABLE';
    END IF;
    IF v_document.status<>'DRAFT' THEN RAISE EXCEPTION 'BACKOFFICE_SALES_RETURN_NOT_DRAFT'; END IF;
    IF p_expected_version IS DISTINCT FROM v_document.master_version THEN
      RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
    END IF;
    v_before:=private.backoffice_sales_return_snapshot(v_company,v_document.id);
    DELETE FROM public.backoffice_sales_return_lines
      WHERE company_id=v_company AND return_id=v_document.id;
    UPDATE public.backoffice_sales_returns SET reason=btrim(p_payload->>'reason'),
      notes=nullif(btrim(p_payload->>'notes'),''),total_requested_base_qty=0,
      master_version=master_version+1,updated_by=v_actor,updated_at=clock_timestamp()
    WHERE company_id=v_company AND id=v_document.id RETURNING * INTO v_document;
  END IF;

  FOR v_item IN SELECT value FROM jsonb_array_elements(p_payload->'lines') LOOP
    v_line_no:=v_line_no+1;
    BEGIN
      v_source_id:=(v_item->>'salesOrderLineId')::uuid;
      v_qty:=(v_item->>'quantityUom')::numeric;
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'BACKOFFICE_SALES_RETURN_LINE_INVALID';
    END;
    IF v_source_id IS NULL OR v_qty IS NULL OR v_qty<=0 OR v_source_id=ANY(v_ids) THEN
      RAISE EXCEPTION 'BACKOFFICE_SALES_RETURN_LINE_INVALID';
    END IF;
    v_ids:=array_append(v_ids,v_source_id);
    SELECT * INTO v_source FROM public.backoffice_sales_order_lines
    WHERE company_id=v_company AND id=v_source_id AND sales_order_id=v_order.id;
    IF NOT FOUND OR v_qty*v_source.base_qty_per_uom>
      v_source.accepted_base_qty-v_source.returned_before_invoice_base_qty THEN
      RAISE EXCEPTION 'BACKOFFICE_SALES_RETURN_QUANTITY_EXCEEDS_RETURNABLE';
    END IF;
    INSERT INTO public.backoffice_sales_return_lines(company_id,return_id,
      sales_order_line_id,line_no,product_id,uom_id,requested_qty_uom,base_qty_per_uom,
      line_reason,product_code_snapshot,product_name_snapshot,uom_code_snapshot,uom_name_snapshot)
    VALUES(v_company,v_document.id,v_source.id,v_line_no,v_source.product_id,v_source.uom_id,
      v_qty,v_source.base_qty_per_uom,nullif(btrim(v_item->>'reason'),''),
      v_source.product_code_snapshot,v_source.product_name_snapshot,
      v_source.uom_code_snapshot,v_source.uom_name_snapshot);
    v_total:=v_total+v_qty*v_source.base_qty_per_uom;
  END LOOP;
  UPDATE public.backoffice_sales_returns SET total_requested_base_qty=v_total,
    updated_by=v_actor,updated_at=clock_timestamp()
  WHERE company_id=v_company AND id=v_document.id RETURNING * INTO v_document;
  v_after:=private.backoffice_sales_return_snapshot(v_company,v_document.id);
  v_response:=jsonb_build_object('companyId',v_company,'data',v_after,'exactRetry',false);
  INSERT INTO public.backoffice_sales_return_operations(company_id,operation_id,
    operation_type,return_id,expected_version,request_hash,response_snapshot,actor_id)
  VALUES(v_company,p_operation_id,'SAVE_DRAFT',v_document.id,p_expected_version,
    v_hash,v_response,v_actor);
  INSERT INTO public.backoffice_sales_return_audit(company_id,return_id,operation_id,
    action,actor_id,before_state,after_state)
  VALUES(v_company,v_document.id,p_operation_id,
    CASE WHEN v_before IS NULL THEN 'CREATE_DRAFT' ELSE 'UPDATE_DRAFT' END,
    v_actor,v_before,v_after);
  RETURN v_response;
END
$$;

CREATE FUNCTION private.transition_backoffice_sales_return(
  p_return_id uuid,p_expected_version bigint,p_operation_id uuid,
  p_operation_type text,p_reason text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE
  v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
  v_document public.backoffice_sales_returns%rowtype;v_hash text;v_retry jsonb;
  v_before jsonb;v_after jsonb;v_response jsonb;v_capability text;
BEGIN
  v_capability:=CASE p_operation_type WHEN 'SUBMIT' THEN 'EDIT_DRAFT'
    WHEN 'APPROVE' THEN 'APPROVE' WHEN 'CANCEL' THEN 'CANCEL_FINAL' ELSE NULL END;
  IF v_capability IS NULL THEN RAISE EXCEPTION 'BACKOFFICE_SALES_RETURN_OPERATION_INVALID'; END IF;
  PERFORM private.acp_require_permission_capability(
    v_company,'sales.backoffice_returns',v_capability);
  IF p_return_id IS NULL OR p_expected_version IS NULL OR p_operation_id IS NULL THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_RETURN_TRANSITION_INPUT_REQUIRED';
  END IF;
  v_hash:=encode(extensions.digest(convert_to(jsonb_build_object(
    'returnId',p_return_id,'expectedVersion',p_expected_version,
    'operationType',p_operation_type,'reason',nullif(btrim(COALESCE(p_reason,'')),''))
    ::text,'UTF8'),'sha256'),'hex');
  PERFORM pg_advisory_xact_lock(hashtextextended(v_company::text||':'||p_operation_id::text,0));
  v_retry:=private.backoffice_sales_return_operation_retry(
    v_company,p_operation_id,p_operation_type,v_hash);
  IF v_retry IS NOT NULL THEN RETURN v_retry; END IF;
  SELECT * INTO v_document FROM public.backoffice_sales_returns
  WHERE company_id=v_company AND id=p_return_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'BACKOFFICE_SALES_RETURN_NOT_FOUND'; END IF;
  IF p_expected_version IS DISTINCT FROM v_document.master_version THEN
    RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
  END IF;
  v_before:=private.backoffice_sales_return_snapshot(v_company,p_return_id);
  IF p_operation_type='SUBMIT' THEN
    IF v_document.status<>'DRAFT' THEN RAISE EXCEPTION 'BACKOFFICE_SALES_RETURN_SUBMIT_STATE_INVALID'; END IF;
    PERFORM private.assert_backoffice_sales_return_quantities(
      v_company,v_document.id,v_document.sales_order_id);
    UPDATE public.backoffice_sales_returns SET status='SUBMITTED',submitted_by=v_actor,
      submitted_at=clock_timestamp(),master_version=master_version+1,
      updated_by=v_actor,updated_at=clock_timestamp()
    WHERE company_id=v_company AND id=v_document.id;
  ELSIF p_operation_type='APPROVE' THEN
    IF v_document.status<>'SUBMITTED' THEN RAISE EXCEPTION 'BACKOFFICE_SALES_RETURN_APPROVE_STATE_INVALID'; END IF;
    PERFORM private.assert_backoffice_sales_return_quantities(
      v_company,v_document.id,v_document.sales_order_id);
    UPDATE public.backoffice_sales_returns SET status='APPROVED',approved_by=v_actor,
      approved_at=clock_timestamp(),master_version=master_version+1,
      updated_by=v_actor,updated_at=clock_timestamp()
    WHERE company_id=v_company AND id=v_document.id;
  ELSE
    IF v_document.status NOT IN('DRAFT','SUBMITTED','APPROVED') THEN
      RAISE EXCEPTION 'BACKOFFICE_SALES_RETURN_CANCEL_STATE_INVALID';
    END IF;
    IF nullif(btrim(COALESCE(p_reason,'')),'') IS NULL THEN RAISE EXCEPTION 'CANCEL_REASON_REQUIRED'; END IF;
    UPDATE public.backoffice_sales_returns SET status='CANCELED',canceled_by=v_actor,
      canceled_at=clock_timestamp(),cancel_reason=btrim(p_reason),
      master_version=master_version+1,updated_by=v_actor,updated_at=clock_timestamp()
    WHERE company_id=v_company AND id=v_document.id;
  END IF;
  v_after:=private.backoffice_sales_return_snapshot(v_company,p_return_id);
  v_response:=jsonb_build_object('companyId',v_company,'data',v_after,'exactRetry',false);
  INSERT INTO public.backoffice_sales_return_operations(company_id,operation_id,
    operation_type,return_id,expected_version,request_hash,response_snapshot,actor_id)
  VALUES(v_company,p_operation_id,p_operation_type,p_return_id,p_expected_version,
    v_hash,v_response,v_actor);
  INSERT INTO public.backoffice_sales_return_audit(company_id,return_id,operation_id,
    action,actor_id,reason,before_state,after_state)
  VALUES(v_company,p_return_id,p_operation_id,p_operation_type,v_actor,
    nullif(btrim(COALESCE(p_reason,'')),''),v_before,v_after);
  RETURN v_response;
END
$$;

CREATE FUNCTION public.submit_backoffice_sales_return(
  p_return_id uuid,p_expected_version bigint,p_operation_id uuid
) RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path=public,pg_temp AS $$
  SELECT private.transition_backoffice_sales_return(
    p_return_id,p_expected_version,p_operation_id,'SUBMIT',NULL)
$$;
CREATE FUNCTION public.approve_backoffice_sales_return(
  p_return_id uuid,p_expected_version bigint,p_operation_id uuid
) RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path=public,pg_temp AS $$
  SELECT private.transition_backoffice_sales_return(
    p_return_id,p_expected_version,p_operation_id,'APPROVE',NULL)
$$;
CREATE FUNCTION public.cancel_backoffice_sales_return(
  p_return_id uuid,p_expected_version bigint,p_operation_id uuid,p_reason text
) RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path=public,pg_temp AS $$
  SELECT private.transition_backoffice_sales_return(
    p_return_id,p_expected_version,p_operation_id,'CANCEL',p_reason)
$$;

ALTER TABLE public.backoffice_sales_returns ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.backoffice_sales_return_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.backoffice_sales_return_operations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.backoffice_sales_return_audit ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.backoffice_sales_returns,public.backoffice_sales_return_lines,
  public.backoffice_sales_return_operations,public.backoffice_sales_return_audit
FROM PUBLIC,anon,authenticated;
GRANT SELECT,INSERT,UPDATE,DELETE ON TABLE public.backoffice_sales_returns,
  public.backoffice_sales_return_lines TO service_role;
GRANT SELECT,INSERT ON TABLE public.backoffice_sales_return_operations,
  public.backoffice_sales_return_audit TO service_role;
GRANT USAGE,SELECT ON SEQUENCE public.backoffice_sales_return_operations_id_seq,
  public.backoffice_sales_return_audit_id_seq TO service_role;

REVOKE ALL ON FUNCTION private.trg_guard_backoffice_sales_return_history(),
  private.backoffice_sales_return_snapshot(uuid,uuid),
  private.backoffice_sales_return_operation_retry(uuid,uuid,text,text),
  private.assert_backoffice_sales_return_quantities(uuid,uuid,uuid),
  private.transition_backoffice_sales_return(uuid,bigint,uuid,text,text)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.trg_guard_backoffice_sales_return_history(),
  private.backoffice_sales_return_snapshot(uuid,uuid),
  private.backoffice_sales_return_operation_retry(uuid,uuid,text,text),
  private.assert_backoffice_sales_return_quantities(uuid,uuid,uuid),
  private.transition_backoffice_sales_return(uuid,bigint,uuid,text,text)
TO service_role;

REVOKE ALL ON FUNCTION public.get_backoffice_sales_returns(text,text,integer),
  public.get_backoffice_sales_return(uuid),public.get_backoffice_sales_return_source(uuid),
  public.save_backoffice_sales_return_draft(uuid,bigint,uuid,uuid,jsonb),
  public.submit_backoffice_sales_return(uuid,bigint,uuid),
  public.approve_backoffice_sales_return(uuid,bigint,uuid),
  public.cancel_backoffice_sales_return(uuid,bigint,uuid,text)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_backoffice_sales_returns(text,text,integer),
  public.get_backoffice_sales_return(uuid),public.get_backoffice_sales_return_source(uuid),
  public.save_backoffice_sales_return_draft(uuid,bigint,uuid,uuid,jsonb),
  public.submit_backoffice_sales_return(uuid,bigint,uuid),
  public.approve_backoffice_sales_return(uuid,bigint,uuid),
  public.cancel_backoffice_sales_return(uuid,bigint,uuid,text)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260917110000','backoffice_sales_return_commercial_foundation',
  'Backoffice Return Draft, Submit, Finance-or-Sales Admin approval and pre-receipt cancellation with quantity hold, exact retry and immutable audit; zero Stock, Invoice, Refund or Finance posting effect');

NOTIFY pgrst,'reload schema';
COMMIT;
