BEGIN;

DO $guard$
DECLARE v_line_guard text;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260914160000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: 20260914160000 required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260914170000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260914170000';
  END IF;
  IF to_regclass('public.purchase_supplier_order_revision_operations') IS NOT NULL
    OR to_regprocedure('public.revise_purchase_supplier_order(uuid,bigint,uuid,uuid,date,text,jsonb)') IS NOT NULL
    OR to_regprocedure('private.revise_purchase_supplier_order_core(uuid,uuid,bigint,uuid,uuid,date,text,jsonb)') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: revision runtime collision';
  END IF;
  SELECT pg_get_functiondef('private.trg_g5_guard_order_line_mutation()'::regprocedure)
  INTO v_line_guard;
  IF v_line_guard !~ 'FINAL_SUPPLIER_ORDER_LINES_IMMUTABLE' THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Supplier Order line guard drift';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
      WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
      WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
  IF EXISTS(SELECT 1 FROM public.sales_process_cutover_plans
      WHERE status IN('DRAFT','PREVIEWED','APPLYING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: open Sales cutover plan';
  END IF;
END
$guard$;

CREATE TABLE public.purchase_supplier_order_revision_operations(
  id uuid PRIMARY KEY,
  company_id uuid NOT NULL,
  supplier_order_id uuid NOT NULL,
  expected_master_version bigint NOT NULL,
  request_hash text NOT NULL CHECK(btrim(request_hash)<>''),
  result_snapshot jsonb NOT NULL,
  actor_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT purchase_supplier_order_revision_ops_company_id_id_unique
    UNIQUE(company_id,id),
  CONSTRAINT purchase_supplier_order_revision_ops_order_fk
    FOREIGN KEY(company_id,supplier_order_id)
    REFERENCES public.supplier_order_documents(company_id,id) ON DELETE RESTRICT
);
CREATE INDEX purchase_supplier_order_revision_ops_order_idx
  ON public.purchase_supplier_order_revision_operations(
    company_id,supplier_order_id,created_at DESC);

CREATE TRIGGER guard_purchase_supplier_order_revision_operations
BEFORE UPDATE OR DELETE ON public.purchase_supplier_order_revision_operations
FOR EACH ROW EXECUTE FUNCTION private.trg_guard_purchase_scheduler_cancel_history();

CREATE OR REPLACE FUNCTION private.trg_g5_guard_order_line_mutation()
RETURNS trigger LANGUAGE plpgsql SET search_path=public,pg_temp AS $$
DECLARE v_document uuid;v_status text;
BEGIN
  v_document:=CASE WHEN TG_OP='DELETE' THEN OLD.document_id ELSE NEW.document_id END;
  SELECT document.status INTO v_status
  FROM public.supplier_order_documents document
  WHERE document.id=v_document;
  IF v_status='DRAFT' THEN
    IF TG_OP='DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
  END IF;
  IF TG_OP='UPDATE'
    AND v_status='CONFIRMED'
    AND current_setting('kgs.purchase_po_revision_id',true)=v_document::text THEN
    IF NEW.company_id IS DISTINCT FROM OLD.company_id
      OR NEW.id IS DISTINCT FROM OLD.id
      OR NEW.document_id IS DISTINCT FROM OLD.document_id
      OR NEW.line_no IS DISTINCT FROM OLD.line_no
      OR NEW.client_line_key IS DISTINCT FROM OLD.client_line_key
      OR NEW.product_id IS DISTINCT FROM OLD.product_id
      OR NEW.source_warehouse_id IS DISTINCT FROM OLD.source_warehouse_id
      OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
      RAISE EXCEPTION 'SUPPLIER_ORDER_REVISION_LINE_IDENTITY_IMMUTABLE';
    END IF;
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'FINAL_SUPPLIER_ORDER_LINES_IMMUTABLE';
END
$$;

CREATE FUNCTION private.purchase_supplier_order_document_snapshot(
  p_company_id uuid,p_document_id uuid
) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
  SELECT jsonb_build_object(
    'document',to_jsonb(document),
    'lines',COALESCE((SELECT jsonb_agg(to_jsonb(line) ORDER BY line.line_no,line.id)
      FROM public.supplier_order_lines line
      WHERE line.company_id=document.company_id
        AND line.document_id=document.id),'[]'::jsonb))
  FROM public.supplier_order_documents document
  WHERE document.company_id=p_company_id AND document.id=p_document_id
$$;

CREATE FUNCTION private.revise_purchase_supplier_order_core(
  p_company_id uuid,p_document_id uuid,p_expected_master_version bigint,
  p_operation_id uuid,p_supplier_id uuid,p_expected_date date,p_notes text,
  p_lines jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_actor uuid:=auth.uid();v_document public.supplier_order_documents%rowtype;
  v_existing record;v_hash text;v_before jsonb;v_after jsonb;v_result jsonb;
  v_item jsonb;v_line public.supplier_order_lines%rowtype;v_uom record;
  v_warehouse uuid;v_total numeric(20,4):=0;v_total_base numeric(24,6):=0;
  v_count integer:=0;v_input_count integer;v_supplier_code text;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF p_operation_id IS NULL THEN RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED'; END IF;
  IF p_lines IS NULL OR jsonb_typeof(p_lines)<>'array'
    OR jsonb_array_length(p_lines)=0 THEN
    RAISE EXCEPTION 'SUPPLIER_ORDER_LINES_REQUIRED';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(
    'PURCHASE_PO_REVISION_OPERATION:'||p_operation_id::text,0));
  v_hash:=md5(jsonb_build_object('documentId',p_document_id,
    'expectedVersion',p_expected_master_version,'supplierId',p_supplier_id,
    'expectedDate',p_expected_date,'notes',NULLIF(btrim(COALESCE(p_notes,'')),''),
    'lines',p_lines)::text);
  SELECT * INTO v_existing FROM public.purchase_supplier_order_revision_operations operation
  WHERE operation.company_id=p_company_id AND operation.id=p_operation_id;
  IF FOUND THEN
    IF v_existing.supplier_order_id<>p_document_id OR v_existing.request_hash<>v_hash THEN
      RAISE EXCEPTION 'IDEMPOTENCY_KEY_CONFLICT'; END IF;
    RETURN v_existing.result_snapshot||jsonb_build_object('exactRetry',true);
  END IF;
  IF EXISTS(SELECT 1 FROM public.purchase_supplier_order_revision_operations operation
      WHERE operation.id=p_operation_id) THEN
    RAISE EXCEPTION 'IDEMPOTENCY_KEY_CONFLICT';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(
    p_company_id::text||':PURCHASE_PO_REVISION:'||p_document_id::text,0));
  SELECT * INTO v_document FROM public.supplier_order_documents document
  WHERE document.company_id=p_company_id AND document.id=p_document_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'SUPPLIER_ORDER_NOT_FOUND'; END IF;
  IF v_document.order_source<>'DAILY_REPLENISHMENT'
    OR v_document.document_scope<>'COMPANY_MULTI_WAREHOUSE'
    OR v_document.status<>'CONFIRMED' THEN
    RAISE EXCEPTION 'PURCHASE_PO_PRE_RECEIPT_REVISION_NOT_ALLOWED';
  END IF;
  IF p_expected_master_version IS NULL
    OR p_expected_master_version<>v_document.master_version THEN
    RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
  IF EXISTS(SELECT 1 FROM public.goods_receipt_documents receipt
      WHERE receipt.company_id=p_company_id
        AND receipt.supplier_order_id=p_document_id
        AND receipt.status<>'CANCELED') THEN
    RAISE EXCEPTION 'PURCHASE_PO_RECEIPT_ALREADY_STARTED';
  END IF;
  IF EXISTS(SELECT 1 FROM public.supplier_invoice_allocations allocation
      JOIN public.supplier_order_lines line ON line.company_id=allocation.company_id
        AND line.id=allocation.supplier_order_line_id
      JOIN public.supplier_invoice_documents invoice
        ON invoice.company_id=allocation.company_id
       AND invoice.id=allocation.document_id AND invoice.status<>'CANCELED'
      WHERE line.company_id=p_company_id AND line.document_id=p_document_id) THEN
    RAISE EXCEPTION 'PURCHASE_PO_BILL_ALREADY_STARTED';
  END IF;
  IF p_expected_date IS NOT NULL AND p_expected_date<v_document.order_date THEN
    RAISE EXCEPTION 'SUPPLIER_ORDER_EXPECTED_DATE_INVALID'; END IF;
  IF p_supplier_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.suppliers supplier
      WHERE supplier.company_id=p_company_id AND supplier.id=p_supplier_id
        AND supplier.is_active) THEN
    RAISE EXCEPTION 'ACTIVE_SUPPLIER_NOT_FOUND';
  END IF;
  v_input_count:=jsonb_array_length(p_lines);
  IF v_input_count<>(SELECT count(*) FROM public.supplier_order_lines line
      WHERE line.company_id=p_company_id AND line.document_id=p_document_id)
    OR v_input_count<>(SELECT count(DISTINCT NULLIF(item->>'lineId','')::uuid)
      FROM jsonb_array_elements(p_lines) item) THEN
    RAISE EXCEPTION 'PURCHASE_PO_REVISION_ALL_LINES_REQUIRED';
  END IF;
  v_before:=private.purchase_supplier_order_document_snapshot(
    p_company_id,p_document_id);
  PERFORM set_config('kgs.purchase_po_revision_id',p_document_id::text,true);
  FOR v_item IN SELECT item FROM jsonb_array_elements(p_lines) item LOOP
    SELECT * INTO v_line FROM public.supplier_order_lines line
    WHERE line.company_id=p_company_id AND line.document_id=p_document_id
      AND line.id=NULLIF(v_item->>'lineId','')::uuid FOR UPDATE;
    IF NOT FOUND OR v_line.product_id IS DISTINCT FROM
        NULLIF(v_item->>'productId','')::uuid THEN
      RAISE EXCEPTION 'PURCHASE_PO_REVISION_LINE_INVALID'; END IF;
    SELECT product_uom.factor_to_base,uom.name,uom.allow_decimal,
      uom.decimal_precision INTO v_uom
    FROM public.product_uoms product_uom
    JOIN public.uoms uom ON uom.company_id=product_uom.company_id
      AND uom.id=product_uom.uom_id AND uom.is_active
    WHERE product_uom.company_id=p_company_id
      AND product_uom.product_id=v_line.product_id
      AND product_uom.uom_id=NULLIF(v_item->>'uomId','')::uuid
      AND product_uom.is_active AND product_uom.purchase_allowed;
    IF NOT FOUND THEN RAISE EXCEPTION 'ACTIVE_PURCHASE_PRODUCT_UOM_NOT_FOUND'; END IF;
    IF COALESCE(NULLIF(v_item->>'quantity','')::numeric,0)<=0 THEN
      RAISE EXCEPTION 'SUPPLIER_ORDER_QUANTITY_INVALID'; END IF;
    IF COALESCE(NULLIF(v_item->>'estimatedUnitPrice','')::numeric,-1)<0 THEN
      RAISE EXCEPTION 'SUPPLIER_ORDER_PRICE_INVALID'; END IF;
    IF NOT v_uom.allow_decimal
      AND (v_item->>'quantity')::numeric<>trunc((v_item->>'quantity')::numeric) THEN
      RAISE EXCEPTION 'PURCHASE_UOM_REQUIRES_INTEGER'; END IF;
    IF v_uom.allow_decimal AND (v_item->>'quantity')::numeric<>
        round((v_item->>'quantity')::numeric,v_uom.decimal_precision) THEN
      RAISE EXCEPTION 'PURCHASE_UOM_PRECISION_EXCEEDED'; END IF;
    v_warehouse:=NULLIF(v_item->>'destinationWarehouseId','')::uuid;
    IF v_warehouse IS NULL OR NOT EXISTS(SELECT 1 FROM public.warehouses warehouse
        WHERE warehouse.company_id=p_company_id AND warehouse.id=v_warehouse
          AND warehouse.is_active AND warehouse.is_purchase_destination
          AND warehouse.warehouse_type<>'TRANSIT') THEN
      RAISE EXCEPTION 'PURCHASE_RECEIPT_WAREHOUSE_INVALID'; END IF;
    SELECT relation.supplier_product_code INTO v_supplier_code
    FROM public.product_suppliers relation
    WHERE relation.company_id=p_company_id AND relation.product_id=v_line.product_id
      AND relation.supplier_id=p_supplier_id AND relation.is_active
    ORDER BY relation.selection_priority,relation.created_at,relation.id LIMIT 1;
    UPDATE public.supplier_order_lines SET
      ordered_uom_id=(v_item->>'uomId')::uuid,
      ordered_qty=(v_item->>'quantity')::numeric,
      factor_to_base_snapshot=v_uom.factor_to_base,
      ordered_base_qty=(v_item->>'quantity')::numeric*v_uom.factor_to_base,
      estimated_unit_price=(v_item->>'estimatedUnitPrice')::numeric,
      estimated_subtotal=round((v_item->>'quantity')::numeric*
        (v_item->>'estimatedUnitPrice')::numeric,4),
      ordered_uom_name_snapshot=v_uom.name,
      supplier_product_code_snapshot=v_supplier_code,
      destination_warehouse_id=v_warehouse
    WHERE company_id=p_company_id AND id=v_line.id;
    v_count:=v_count+1;
    v_total_base:=v_total_base+(v_item->>'quantity')::numeric*v_uom.factor_to_base;
    v_total:=v_total+round((v_item->>'quantity')::numeric*
      (v_item->>'estimatedUnitPrice')::numeric,4);
  END LOOP;
  BEGIN
    UPDATE public.supplier_order_documents SET supplier_id=p_supplier_id,
      supplier_assignment_status=CASE WHEN p_supplier_id IS NULL
        THEN 'SUPPLIER_PENDING' ELSE 'ASSIGNED' END,
      expected_date=p_expected_date,notes=NULLIF(btrim(COALESCE(p_notes,'')),''),
      line_count=v_count,total_ordered_base_qty=v_total_base,
      estimated_total=v_total,master_version=master_version+1,
      updated_at=clock_timestamp()
    WHERE company_id=p_company_id AND id=p_document_id;
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'PURCHASE_PO_SUPPLIER_GROUP_CONFLICT';
  END;
  v_after:=private.purchase_supplier_order_document_snapshot(
    p_company_id,p_document_id);
  INSERT INTO public.supplier_order_audit(company_id,document_id,action,actor_id,
    before_state,after_state)
  VALUES(p_company_id,p_document_id,'UPDATE',v_actor,v_before,v_after);
  v_result:=jsonb_build_object('documentId',p_document_id,
    'orderNo',v_document.order_no,'status','CONFIRMED',
    'masterVersion',v_document.master_version+1,'lineCount',v_count,
    'estimatedTotal',v_total,'exactRetry',false);
  INSERT INTO public.purchase_supplier_order_revision_operations(id,company_id,
    supplier_order_id,expected_master_version,request_hash,result_snapshot,actor_id)
  VALUES(p_operation_id,p_company_id,p_document_id,p_expected_master_version,
    v_hash,v_result,v_actor);
  RETURN v_result;
END
$$;

CREATE FUNCTION public.revise_purchase_supplier_order(
  p_document_id uuid,p_master_version bigint,p_operation_id uuid,
  p_supplier_id uuid,p_expected_date date,p_notes text,p_lines jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'purchase.supplier_orders','EDIT_DRAFT');
  RETURN private.revise_purchase_supplier_order_core(v_company,p_document_id,
    p_master_version,p_operation_id,p_supplier_id,p_expected_date,p_notes,p_lines);
END
$$;

ALTER FUNCTION public.get_purchase_supplier_orders()
  RENAME TO purchase_order_list_v2_base;
ALTER FUNCTION public.purchase_order_list_v2_base() SET SCHEMA private;

CREATE FUNCTION public.get_purchase_supplier_orders()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_base jsonb;
  v_lines jsonb;v_activity jsonb;
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'purchase.supplier_orders','VIEW');
  v_base:=private.purchase_order_list_v2_base();
  WITH progress AS (
    SELECT receipt_line.supplier_order_line_id,
      sum(receipt_line.received_base_qty) received_base_qty,
      count(DISTINCT receipt.id) posted_receipt_count,max(receipt.posted_at) last_received_at
    FROM public.goods_receipt_lines receipt_line
    JOIN public.goods_receipt_documents receipt
      ON receipt.company_id=receipt_line.company_id AND receipt.id=receipt_line.document_id
     AND receipt.status='POSTED'
    WHERE receipt_line.company_id=v_company GROUP BY receipt_line.supplier_order_line_id
  )
  SELECT COALESCE(jsonb_agg(to_jsonb(row_data)
    ORDER BY row_data.document_id,row_data.line_no),'[]'::jsonb) INTO v_lines
  FROM (SELECT line.id,line.document_id,line.line_no,line.client_line_key,
      line.product_id,line.ordered_uom_id,line.ordered_qty,
      line.factor_to_base_snapshot,line.ordered_base_qty,line.estimated_unit_price,
      line.estimated_subtotal,line.product_sku_snapshot,line.product_name_snapshot,
      line.ordered_uom_name_snapshot,line.source_warehouse_id,
      line.destination_warehouse_id,COALESCE(progress.received_base_qty,0) received_base_qty,
      greatest(line.ordered_base_qty-COALESCE(progress.received_base_qty,0),0)
        remaining_base_qty,
      COALESCE(progress.received_base_qty,0)/line.factor_to_base_snapshot
        received_ordered_qty,
      greatest(line.ordered_base_qty-COALESCE(progress.received_base_qty,0),0)
        /line.factor_to_base_snapshot remaining_ordered_qty,
      greatest(COALESCE(progress.received_base_qty,0)-line.ordered_base_qty,0)
        over_received_base_qty,
      CASE WHEN COALESCE(progress.received_base_qty,0)<=0 THEN 'NOT_RECEIVED'
        WHEN progress.received_base_qty<line.ordered_base_qty THEN 'PARTIAL'
        ELSE 'COMPLETE' END receipt_progress,
      COALESCE(progress.posted_receipt_count,0) posted_receipt_count,
      progress.last_received_at
    FROM public.supplier_order_lines line
    LEFT JOIN progress ON progress.supplier_order_line_id=line.id
    WHERE line.company_id=v_company
    ORDER BY line.document_id,line.line_no LIMIT 10000) row_data;
  SELECT COALESCE(jsonb_agg(jsonb_build_object('id',audit.id,
      'documentId',audit.document_id,'action',audit.action,
      'actorName',COALESCE(profile.name,profile.email,'Sistem'),
      'createdAt',audit.created_at) ORDER BY audit.created_at,audit.id),'[]'::jsonb)
  INTO v_activity FROM public.supplier_order_audit audit
  LEFT JOIN public.profiles profile ON profile.id=audit.actor_id
  WHERE audit.company_id=v_company;
  RETURN jsonb_set(v_base,'{orderLines}',v_lines,true)||jsonb_build_object(
    'supplierOrderListVersion',3,'supplierOrderActivity',v_activity);
END
$$;

REVOKE ALL ON TABLE public.purchase_supplier_order_revision_operations
FROM PUBLIC,anon,authenticated;
GRANT SELECT,INSERT ON TABLE public.purchase_supplier_order_revision_operations
TO service_role;
REVOKE ALL ON FUNCTION
  private.purchase_supplier_order_document_snapshot(uuid,uuid),
  private.revise_purchase_supplier_order_core(uuid,uuid,bigint,uuid,uuid,date,text,jsonb),
  private.purchase_order_list_v2_base()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.purchase_supplier_order_document_snapshot(uuid,uuid),
  private.revise_purchase_supplier_order_core(uuid,uuid,bigint,uuid,uuid,date,text,jsonb),
  private.purchase_order_list_v2_base()
TO service_role;
REVOKE ALL ON FUNCTION public.revise_purchase_supplier_order(
  uuid,bigint,uuid,uuid,date,text,jsonb),public.get_purchase_supplier_orders()
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.revise_purchase_supplier_order(
  uuid,bigint,uuid,uuid,date,text,jsonb),public.get_purchase_supplier_orders()
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260914170000','purchase_order_pre_receipt_revision',
  'Add idempotent confirmed daily PO revision before any Receipt, enriched PO document reader and activity projection; no Stock, FIFO, AP, Bill, Payment, Journal, Sales or POS mutation');

NOTIFY pgrst,'reload schema';
COMMIT;
