-- Step 4/6.1: additive discrepancy/backorder contract foundation.
-- This migration does not replace the active clean Customer Receipt runtime and
-- performs no Stock, FIFO, Reservation, Invoice, Payment, or Finance mutation.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260911163000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: AR reporting integration required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260911164000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260911164000';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
    WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
  IF to_regprocedure('private.receive_backoffice_sales_delivery_core(uuid,bigint,uuid,date,text)') IS NULL
    OR to_regprocedure('public.receive_backoffice_sales_delivery(uuid,bigint,uuid,date,text)') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical Customer Receipt runtime missing';
  END IF;
  IF to_regclass('public.backoffice_sales_delivery_discrepancies') IS NOT NULL
    OR to_regclass('public.backoffice_sales_delivery_discrepancy_lines') IS NOT NULL
    OR to_regclass('public.backoffice_sales_discrepancy_operations') IS NOT NULL
    OR to_regclass('public.backoffice_sales_discrepancy_audit') IS NOT NULL
    OR to_regprocedure('private.classify_backoffice_sales_discrepancy(text,text)') IS NOT NULL
    OR to_regprocedure('private.validate_backoffice_sales_receipt_disposition_payload(jsonb)') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: discrepancy contract collision';
  END IF;
END
$guard$;

CREATE FUNCTION private.classify_backoffice_sales_discrepancy(
  p_discrepancy_type text,p_requested_resolution text
) RETURNS jsonb LANGUAGE plpgsql IMMUTABLE
SET search_path=public,pg_temp AS $$
DECLARE
  v_type text:=upper(btrim(COALESCE(p_discrepancy_type,'')));
  v_resolution text:=upper(btrim(COALESCE(p_requested_resolution,'')));
  v_valid boolean:=false;v_sales boolean:=false;v_warehouse boolean:=false;
BEGIN
  v_valid:=CASE v_type
    WHEN 'SHORT' THEN v_resolution IN('BACKORDER','ACCEPT_SHORT')
    WHEN 'OVERAGE' THEN v_resolution IN('ACCEPT_OVERAGE','RETURN_OVERAGE')
    WHEN 'WRONG_ITEM' THEN v_resolution='REPLACE_WRONG_ITEM'
    WHEN 'LOST' THEN v_resolution='WRITE_OFF_LOST'
    WHEN 'DAMAGED' THEN v_resolution='WRITE_OFF_DAMAGED'
    ELSE false END;
  IF NOT v_valid THEN RAISE EXCEPTION 'BACKOFFICE_DISCREPANCY_ACTION_INVALID'; END IF;
  v_sales:=v_resolution='ACCEPT_OVERAGE';
  v_warehouse:=v_resolution IN('BACKORDER','RETURN_OVERAGE','REPLACE_WRONG_ITEM',
    'WRITE_OFF_LOST','WRITE_OFF_DAMAGED');
  RETURN jsonb_build_object('discrepancyType',v_type,
    'requestedResolution',v_resolution,'requiresSalesApproval',v_sales,
    'requiresWarehouseResolution',v_warehouse);
END
$$;

CREATE FUNCTION private.validate_backoffice_sales_receipt_disposition_payload(
  p_lines jsonb
) RETURNS jsonb LANGUAGE plpgsql IMMUTABLE
SET search_path=public,pg_temp AS $$
DECLARE
  v_line jsonb;v_item jsonb;v_class jsonb;v_line_id uuid;v_actual_product_id uuid;
  v_accepted numeric;v_qty numeric;v_discrepancy numeric:=0;v_total_accepted numeric:=0;
  v_sales boolean:=false;v_warehouse boolean:=false;v_count integer:=0;
  v_seen uuid[]:='{}'::uuid[];
BEGIN
  IF jsonb_typeof(p_lines)<>'array' OR jsonb_array_length(p_lines)=0
    OR jsonb_array_length(p_lines)>500 THEN
    RAISE EXCEPTION 'BACKOFFICE_RECEIPT_DISPOSITION_LINES_INVALID';
  END IF;
  FOR v_line IN SELECT value FROM jsonb_array_elements(p_lines)
  LOOP
    IF jsonb_typeof(v_line)<>'object' THEN
      RAISE EXCEPTION 'BACKOFFICE_RECEIPT_DISPOSITION_LINES_INVALID';
    END IF;
    BEGIN v_line_id:=(v_line->>'deliveryLineId')::uuid;
    EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'BACKOFFICE_RECEIPT_DISPOSITION_LINE_ID_INVALID'; END;
    IF v_line_id IS NULL THEN RAISE EXCEPTION 'BACKOFFICE_RECEIPT_DISPOSITION_LINE_ID_INVALID'; END IF;
    IF v_line_id=ANY(v_seen) THEN RAISE EXCEPTION 'BACKOFFICE_RECEIPT_DISPOSITION_LINE_DUPLICATE'; END IF;
    v_seen:=array_append(v_seen,v_line_id);
    BEGIN v_accepted:=(v_line->>'acceptedBaseQty')::numeric;
    EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'BACKOFFICE_RECEIPT_ACCEPTED_QUANTITY_INVALID'; END;
    IF v_accepted IS NULL OR v_accepted<0 THEN RAISE EXCEPTION 'BACKOFFICE_RECEIPT_ACCEPTED_QUANTITY_INVALID'; END IF;
    v_total_accepted:=v_total_accepted+v_accepted;
    IF COALESCE(jsonb_typeof(v_line->'discrepancies'),'array')<>'array' THEN
      RAISE EXCEPTION 'BACKOFFICE_RECEIPT_DISCREPANCY_LINES_INVALID';
    END IF;
    FOR v_item IN SELECT value FROM jsonb_array_elements(COALESCE(v_line->'discrepancies','[]'::jsonb))
    LOOP
      IF jsonb_typeof(v_item)<>'object' THEN RAISE EXCEPTION 'BACKOFFICE_RECEIPT_DISCREPANCY_LINES_INVALID'; END IF;
      BEGIN v_qty:=(v_item->>'quantityBase')::numeric;
      EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'BACKOFFICE_DISCREPANCY_QUANTITY_INVALID'; END;
      IF v_qty IS NULL OR v_qty<=0 THEN RAISE EXCEPTION 'BACKOFFICE_DISCREPANCY_QUANTITY_INVALID'; END IF;
      v_class:=private.classify_backoffice_sales_discrepancy(
        v_item->>'discrepancyType',v_item->>'requestedResolution');
      IF v_class->>'discrepancyType'='WRONG_ITEM'
        AND NULLIF(btrim(v_item->>'actualProductId'),'') IS NULL THEN
        RAISE EXCEPTION 'BACKOFFICE_DISCREPANCY_ACTUAL_PRODUCT_REQUIRED';
      END IF;
      IF v_class->>'discrepancyType'='WRONG_ITEM' THEN
        BEGIN v_actual_product_id:=(v_item->>'actualProductId')::uuid;
        EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'BACKOFFICE_DISCREPANCY_ACTUAL_PRODUCT_INVALID'; END;
        IF v_actual_product_id IS NULL THEN RAISE EXCEPTION 'BACKOFFICE_DISCREPANCY_ACTUAL_PRODUCT_INVALID'; END IF;
      END IF;
      IF v_class->>'discrepancyType'<>'WRONG_ITEM'
        AND NULLIF(btrim(v_item->>'actualProductId'),'') IS NOT NULL THEN
        RAISE EXCEPTION 'BACKOFFICE_DISCREPANCY_ACTUAL_PRODUCT_NOT_ALLOWED';
      END IF;
      v_discrepancy:=v_discrepancy+v_qty;v_count:=v_count+1;
      v_sales:=v_sales OR (v_class->>'requiresSalesApproval')::boolean;
      v_warehouse:=v_warehouse OR (v_class->>'requiresWarehouseResolution')::boolean;
    END LOOP;
  END LOOP;
  IF v_total_accepted<=0 AND v_discrepancy<=0 THEN
    RAISE EXCEPTION 'BACKOFFICE_RECEIPT_DISPOSITION_EMPTY';
  END IF;
  RETURN jsonb_build_object('lineCount',jsonb_array_length(p_lines),
    'discrepancyCount',v_count,'acceptedBaseQty',v_total_accepted,
    'discrepancyBaseQty',v_discrepancy,'requiresSalesApproval',v_sales,
    'requiresWarehouseResolution',v_warehouse);
END
$$;

CREATE TABLE public.backoffice_sales_delivery_discrepancies(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
  discrepancy_no text NOT NULL,
  delivery_order_id uuid NOT NULL,
  sales_order_id uuid NOT NULL,
  receipt_id uuid,
  status text NOT NULL DEFAULT 'OPEN',
  total_discrepancy_base_qty numeric(24,6) NOT NULL,
  requires_sales_approval boolean NOT NULL DEFAULT false,
  requires_warehouse_resolution boolean NOT NULL DEFAULT false,
  created_by uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_by uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  resolved_by uuid REFERENCES public.profiles(id) ON DELETE RESTRICT,
  resolved_at timestamptz,
  CONSTRAINT backoffice_sales_delivery_discrepancies_company_id_unique UNIQUE(company_id,id),
  CONSTRAINT backoffice_sales_delivery_discrepancies_number_unique UNIQUE(company_id,discrepancy_no),
  CONSTRAINT backoffice_sales_delivery_discrepancies_delivery_unique UNIQUE(company_id,delivery_order_id),
  CONSTRAINT backoffice_sales_delivery_discrepancies_delivery_fk
    FOREIGN KEY(company_id,sales_order_id,delivery_order_id)
    REFERENCES public.backoffice_sales_delivery_orders(company_id,sales_order_id,id)
    ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_delivery_discrepancies_receipt_fk
    FOREIGN KEY(company_id,receipt_id)
    REFERENCES public.backoffice_sales_delivery_receipts(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_delivery_discrepancies_status_check CHECK(status IN(
    'OPEN','PENDING_SALES_APPROVAL','PENDING_WAREHOUSE_RESOLUTION','RESOLVED','CANCELED')),
  CONSTRAINT backoffice_sales_delivery_discrepancies_shape_check CHECK(
    nullif(btrim(discrepancy_no),'') IS NOT NULL AND total_discrepancy_base_qty>0
    AND ((status='RESOLVED' AND resolved_by IS NOT NULL AND resolved_at IS NOT NULL)
      OR (status<>'RESOLVED' AND resolved_by IS NULL AND resolved_at IS NULL)))
);

CREATE TABLE public.backoffice_sales_delivery_discrepancy_lines(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL,
  discrepancy_id uuid NOT NULL,
  delivery_order_id uuid NOT NULL,
  sales_order_id uuid NOT NULL,
  delivery_order_line_id uuid NOT NULL,
  sales_order_line_id uuid NOT NULL,
  expected_product_id uuid NOT NULL,
  actual_product_id uuid,
  uom_id uuid NOT NULL,
  discrepancy_type text NOT NULL,
  requested_resolution text NOT NULL,
  quantity_uom numeric(24,6) NOT NULL,
  quantity_base numeric(24,6) NOT NULL,
  commercial_approval_status text NOT NULL,
  warehouse_resolution_status text NOT NULL,
  reason text,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT backoffice_sales_delivery_discrepancy_lines_company_id_unique UNIQUE(company_id,id),
  CONSTRAINT backoffice_sales_delivery_discrepancy_lines_header_fk
    FOREIGN KEY(company_id,discrepancy_id)
    REFERENCES public.backoffice_sales_delivery_discrepancies(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_delivery_discrepancy_lines_document_fk
    FOREIGN KEY(company_id,sales_order_id,delivery_order_id)
    REFERENCES public.backoffice_sales_delivery_orders(company_id,sales_order_id,id)
    ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_delivery_discrepancy_lines_delivery_fk
    FOREIGN KEY(company_id,delivery_order_line_id)
    REFERENCES public.backoffice_sales_delivery_order_lines(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_delivery_discrepancy_lines_order_fk
    FOREIGN KEY(company_id,sales_order_id,sales_order_line_id)
    REFERENCES public.backoffice_sales_order_lines(company_id,sales_order_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_delivery_discrepancy_lines_expected_product_fk
    FOREIGN KEY(company_id,expected_product_id)
    REFERENCES public.products(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_delivery_discrepancy_lines_actual_product_fk
    FOREIGN KEY(company_id,actual_product_id)
    REFERENCES public.products(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_delivery_discrepancy_lines_uom_fk
    FOREIGN KEY(company_id,uom_id) REFERENCES public.uoms(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_delivery_discrepancy_lines_quantity_check CHECK(
    quantity_uom>0 AND quantity_base>0),
  CONSTRAINT backoffice_sales_delivery_discrepancy_lines_type_check CHECK(
    discrepancy_type IN('SHORT','OVERAGE','WRONG_ITEM','LOST','DAMAGED')
    AND ((discrepancy_type='WRONG_ITEM' AND actual_product_id IS NOT NULL)
      OR (discrepancy_type<>'WRONG_ITEM' AND actual_product_id IS NULL))),
  CONSTRAINT backoffice_sales_delivery_discrepancy_lines_resolution_check CHECK(
    (discrepancy_type='SHORT' AND requested_resolution IN('BACKORDER','ACCEPT_SHORT'))
    OR (discrepancy_type='OVERAGE' AND requested_resolution IN('ACCEPT_OVERAGE','RETURN_OVERAGE'))
    OR (discrepancy_type='WRONG_ITEM' AND requested_resolution='REPLACE_WRONG_ITEM'
      AND actual_product_id IS NOT NULL)
    OR (discrepancy_type='LOST' AND requested_resolution='WRITE_OFF_LOST')
    OR (discrepancy_type='DAMAGED' AND requested_resolution='WRITE_OFF_DAMAGED')),
  CONSTRAINT backoffice_sales_delivery_discrepancy_lines_approval_check CHECK(
    (requested_resolution='ACCEPT_OVERAGE' AND commercial_approval_status IN('PENDING','APPROVED','REJECTED'))
    OR (requested_resolution<>'ACCEPT_OVERAGE' AND commercial_approval_status='NOT_REQUIRED')),
  CONSTRAINT backoffice_sales_delivery_discrepancy_lines_warehouse_check CHECK(
    (requested_resolution IN('BACKORDER','RETURN_OVERAGE','REPLACE_WRONG_ITEM','WRITE_OFF_LOST','WRITE_OFF_DAMAGED')
      AND warehouse_resolution_status IN('PENDING','RESOLVED','REJECTED'))
    OR (requested_resolution NOT IN('BACKORDER','RETURN_OVERAGE','REPLACE_WRONG_ITEM','WRITE_OFF_LOST','WRITE_OFF_DAMAGED')
      AND warehouse_resolution_status='NOT_REQUIRED')),
  CONSTRAINT backoffice_sales_delivery_discrepancy_lines_reason_check CHECK(
    reason IS NULL OR length(reason)<=500)
);

CREATE TABLE public.backoffice_sales_discrepancy_operations(
  id uuid PRIMARY KEY,
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
  discrepancy_id uuid,
  operation_type text NOT NULL,
  request_payload jsonb NOT NULL,
  result_payload jsonb,
  actor_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  completed_at timestamptz,
  CONSTRAINT backoffice_sales_discrepancy_operations_company_id_unique UNIQUE(company_id,id),
  CONSTRAINT backoffice_sales_discrepancy_operations_case_fk
    FOREIGN KEY(company_id,discrepancy_id)
    REFERENCES public.backoffice_sales_delivery_discrepancies(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_discrepancy_operations_type_check CHECK(operation_type IN(
    'CUSTOMER_CONFIRM','SALES_APPROVE_OVERAGE','WAREHOUSE_RESOLVE','CREATE_BACKORDER','CANCEL')),
  CONSTRAINT backoffice_sales_discrepancy_operations_shape_check CHECK(
    jsonb_typeof(request_payload)='object'
    AND (result_payload IS NULL OR jsonb_typeof(result_payload)='object')
    AND ((completed_at IS NULL AND result_payload IS NULL)
      OR (completed_at IS NOT NULL AND result_payload IS NOT NULL)))
);

CREATE TABLE public.backoffice_sales_discrepancy_audit(
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
  discrepancy_id uuid NOT NULL,
  operation_id uuid NOT NULL,
  action text NOT NULL,
  actor_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  before_state jsonb,
  after_state jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT backoffice_sales_discrepancy_audit_operation_unique UNIQUE(company_id,operation_id),
  CONSTRAINT backoffice_sales_discrepancy_audit_case_fk
    FOREIGN KEY(company_id,discrepancy_id)
    REFERENCES public.backoffice_sales_delivery_discrepancies(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_discrepancy_audit_operation_fk
    FOREIGN KEY(company_id,operation_id)
    REFERENCES public.backoffice_sales_discrepancy_operations(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_discrepancy_audit_shape_check CHECK(
    nullif(btrim(action),'') IS NOT NULL AND jsonb_typeof(after_state)='object'
    AND (before_state IS NULL OR jsonb_typeof(before_state)='object'))
);

CREATE INDEX backoffice_sales_delivery_discrepancies_open
  ON public.backoffice_sales_delivery_discrepancies(company_id,status,created_at,id)
  WHERE status NOT IN('RESOLVED','CANCELED');
CREATE INDEX backoffice_sales_delivery_discrepancy_lines_case
  ON public.backoffice_sales_delivery_discrepancy_lines(company_id,discrepancy_id,id);

CREATE FUNCTION private.trg_guard_backoffice_sales_discrepancy_history()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
BEGIN
  RAISE EXCEPTION 'BACKOFFICE_SALES_DISCREPANCY_HISTORY_IMMUTABLE';
END
$$;
CREATE TRIGGER backoffice_sales_discrepancy_operations_immutable
BEFORE UPDATE OR DELETE ON public.backoffice_sales_discrepancy_operations
FOR EACH ROW EXECUTE FUNCTION private.trg_guard_backoffice_sales_discrepancy_history();
CREATE TRIGGER backoffice_sales_discrepancy_audit_immutable
BEFORE UPDATE OR DELETE ON public.backoffice_sales_discrepancy_audit
FOR EACH ROW EXECUTE FUNCTION private.trg_guard_backoffice_sales_discrepancy_history();

ALTER TABLE public.backoffice_sales_delivery_discrepancies ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.backoffice_sales_delivery_discrepancy_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.backoffice_sales_discrepancy_operations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.backoffice_sales_discrepancy_audit ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.backoffice_sales_delivery_discrepancies,
  public.backoffice_sales_delivery_discrepancy_lines,
  public.backoffice_sales_discrepancy_operations,
  public.backoffice_sales_discrepancy_audit FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.backoffice_sales_delivery_discrepancies,
  public.backoffice_sales_delivery_discrepancy_lines,
  public.backoffice_sales_discrepancy_operations,
  public.backoffice_sales_discrepancy_audit TO service_role;
REVOKE ALL ON FUNCTION private.classify_backoffice_sales_discrepancy(text,text),
  private.validate_backoffice_sales_receipt_disposition_payload(jsonb),
  private.trg_guard_backoffice_sales_discrepancy_history()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.classify_backoffice_sales_discrepancy(text,text),
  private.validate_backoffice_sales_receipt_disposition_payload(jsonb),
  private.trg_guard_backoffice_sales_discrepancy_history() TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260911164000','backoffice_sales_discrepancy_contract_foundation',
  'Step 4/6.1 normalized mixed Customer acceptance/discrepancy, approval and resolution contract; zero operational effect');

NOTIFY pgrst,'reload schema';
COMMIT;
