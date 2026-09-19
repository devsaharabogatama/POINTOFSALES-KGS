-- Backoffice Purchase Return source workspace and Draft runtime.
-- The existing POS/Cashier path and signatures remain unchanged.
BEGIN;

DO $guard$
BEGIN
  IF (SELECT count(*) FROM private.kgs_schema_migrations
    WHERE version IN('20260813010000','20260814140000','20260825130000','20260914140000'))<>4 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Purchase Return ACP, Purchase/AP Finance, Backoffice Receipt, and PO cancellation runtimes required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260919140000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260919140000';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF to_regprocedure('public.save_purchase_return_draft(uuid,bigint,uuid,uuid,uuid,date,text,text,text,jsonb)') IS NULL
    OR to_regprocedure('public.get_purchase_returns()') IS NULL
    OR to_regprocedure('private.acp_require_permission_capability(uuid,text,text)') IS NULL
    OR to_regprocedure('public.private_purchase_manager_allowed(uuid,uuid)') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical Purchase Return runtime drift';
  END IF;
  IF to_regclass('public.purchase_return_draft_operations') IS NOT NULL
    OR to_regprocedure('public.get_backoffice_purchase_return_workspace(uuid)') IS NOT NULL
    OR to_regprocedure('public.save_backoffice_purchase_return_draft(uuid,bigint,uuid,uuid,uuid,date,text,text,text,jsonb)') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Backoffice Purchase Return collision';
  END IF;
  IF EXISTS(SELECT 1 FROM public.purchase_return_documents document
    WHERE document.status='DRAFT'
    GROUP BY document.company_id,document.source_receipt_id,
      document.source_warehouse_id HAVING count(*)>1) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: duplicate active Purchase Return Draft source';
  END IF;
END
$guard$;

ALTER TABLE public.purchase_return_documents
  ALTER COLUMN created_session_id DROP NOT NULL,
  ALTER COLUMN created_pos_id DROP NOT NULL,
  ADD COLUMN source_channel text NOT NULL DEFAULT 'POS';

ALTER TABLE public.purchase_return_documents
  ADD CONSTRAINT purchase_return_source_channel_check
    CHECK(source_channel IN('POS','BACKOFFICE')),
  ADD CONSTRAINT purchase_return_channel_scope_check CHECK(
    (source_channel='POS' AND created_session_id IS NOT NULL
      AND created_pos_id IS NOT NULL)
    OR (source_channel='BACKOFFICE' AND created_session_id IS NULL
      AND created_pos_id IS NULL)
  );

CREATE UNIQUE INDEX uq_purchase_return_active_receipt_warehouse
  ON public.purchase_return_documents(company_id,source_receipt_id,source_warehouse_id)
  WHERE status='DRAFT';

CREATE TABLE public.purchase_return_draft_operations(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL,
  operation_id uuid NOT NULL,
  document_id uuid NOT NULL,
  request_digest text NOT NULL,
  resulting_master_version bigint NOT NULL,
  actor_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT purchase_return_draft_operation_company_id_id_unique
    UNIQUE(company_id,id),
  CONSTRAINT purchase_return_draft_operation_key_unique
    UNIQUE(company_id,operation_id),
  CONSTRAINT fk_purchase_return_draft_operation_document
    FOREIGN KEY(company_id,document_id)
    REFERENCES public.purchase_return_documents(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT purchase_return_draft_operation_digest_not_blank
    CHECK(btrim(request_digest)<>''),
  CONSTRAINT purchase_return_draft_operation_version_positive
    CHECK(resulting_master_version>0)
);

CREATE FUNCTION private.trg_purchase_return_draft_operation_immutable()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
BEGIN
  RAISE EXCEPTION 'PURCHASE_RETURN_DRAFT_OPERATION_IMMUTABLE';
END
$$;
CREATE TRIGGER purchase_return_draft_operation_immutable
BEFORE UPDATE OR DELETE ON public.purchase_return_draft_operations
FOR EACH ROW EXECUTE FUNCTION private.trg_purchase_return_draft_operation_immutable();

ALTER TABLE public.purchase_return_draft_operations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.purchase_return_draft_operations FROM PUBLIC,anon,authenticated;
GRANT SELECT,INSERT ON public.purchase_return_draft_operations TO service_role;

CREATE FUNCTION public.get_backoffice_purchase_return_workspace(
  p_supplier_order_id uuid DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'purchase.purchase_returns','VIEW');
  IF p_supplier_order_id IS NOT NULL AND NOT EXISTS(
    SELECT 1 FROM public.supplier_order_documents order_document
    WHERE order_document.company_id=v_company
      AND order_document.id=p_supplier_order_id
  ) THEN RAISE EXCEPTION 'SUPPLIER_ORDER_NOT_FOUND'; END IF;

  RETURN jsonb_build_object(
    'workspaceVersion',1,
    'policy',jsonb_build_object(
      'financeAllocation','UNINVOICED_FIRST',
      'documentBoundary','ONE_RECEIPT_AND_WAREHOUSE',
      'fifoBoundary','EXACT_SOURCE_BATCH',
      'retailPathChanged',false),
    'receipts',(SELECT COALESCE(jsonb_agg(to_jsonb(row_data)
      ORDER BY row_data.received_at DESC,row_data.receipt_no),'[]'::jsonb)
      FROM (SELECT receipt.id,receipt.receipt_no,receipt.supplier_order_id,
          order_document.order_no,order_document.supplier_id,supplier.supplier_name,
          receipt.store_id,store.store_name,receipt.received_at,
          receipt.supplier_delivery_no,receipt.status,
          count(DISTINCT allocation.warehouse_id)::integer return_warehouse_count,
          round(COALESCE(sum(GREATEST(LEAST(
            allocation.quantity_base-COALESCE(posted_return.base_qty,0),
            batch.qty_remaining),0)),0),6) returnable_base_qty,
          CASE
            WHEN order_document.supplier_id IS NULL THEN 'SUPPLIER_ASSIGNMENT_REQUIRED'
            WHEN count(allocation.id)=0 THEN 'RETURNABLE_RECEIPT_ALLOCATION_NOT_FOUND'
            WHEN COALESCE(sum(GREATEST(LEAST(
              allocation.quantity_base-COALESCE(posted_return.base_qty,0),
              batch.qty_remaining),0)),0)<=0 THEN 'PURCHASE_RETURN_FIFO_NOT_AVAILABLE'
            ELSE NULL END blocker_code
        FROM public.goods_receipt_documents receipt
        JOIN public.supplier_order_documents order_document
          ON order_document.company_id=receipt.company_id
         AND order_document.id=receipt.supplier_order_id
        JOIN public.suppliers supplier ON supplier.company_id=receipt.company_id
         AND supplier.id=order_document.supplier_id
        JOIN public.stores store ON store.company_id=receipt.company_id
         AND store.id=receipt.store_id
        LEFT JOIN public.goods_receipt_lines receipt_line
          ON receipt_line.company_id=receipt.company_id
         AND receipt_line.document_id=receipt.id
        LEFT JOIN public.goods_receipt_condition_allocations allocation
          ON allocation.company_id=receipt_line.company_id
         AND allocation.receipt_line_id=receipt_line.id
         AND allocation.condition_type IN('GOOD','DAMAGED')
        LEFT JOIN public.product_batches batch
          ON batch.company_id=allocation.company_id
         AND batch.id=allocation.product_batch_id
        LEFT JOIN LATERAL(SELECT sum(return_line.return_base_qty) base_qty
          FROM public.purchase_return_lines return_line
          JOIN public.purchase_return_documents return_document
            ON return_document.company_id=return_line.company_id
           AND return_document.id=return_line.document_id
           AND return_document.status='POSTED'
          WHERE return_line.company_id=allocation.company_id
            AND return_line.source_condition_allocation_id=allocation.id
        ) posted_return ON TRUE
        WHERE receipt.company_id=v_company AND receipt.status='POSTED'
          AND (p_supplier_order_id IS NULL
            OR receipt.supplier_order_id=p_supplier_order_id)
        GROUP BY receipt.id,order_document.id,supplier.id,store.id) row_data),
    'sourceLines',(SELECT COALESCE(jsonb_agg(to_jsonb(row_data)
      ORDER BY row_data.receipt_id,row_data.warehouse_name,
        row_data.product_name_snapshot,row_data.source_condition),'[]'::jsonb)
      FROM (SELECT receipt.id receipt_id,receipt.supplier_order_id,
          receipt_line.id receipt_line_id,allocation.id condition_allocation_id,
          allocation.product_batch_id,allocation.warehouse_id,warehouse.name warehouse_name,
          receipt_line.product_id,receipt_line.product_sku_snapshot,
          receipt_line.product_name_snapshot,receipt_line.base_uom_id,
          receipt_line.base_uom_name_snapshot,allocation.condition_type source_condition,
          allocation.quantity_base source_base_qty,
          round(COALESCE(posted_return.base_qty,0),6) posted_return_base_qty,
          round(batch.qty_remaining,6) fifo_remaining_base_qty,
          round(GREATEST(LEAST(
            allocation.quantity_base-COALESCE(posted_return.base_qty,0),
            batch.qty_remaining),0),6) returnable_base_qty,
          receipt_line.estimated_base_unit_cost provisional_base_unit_cost,
          round(GREATEST(LEAST(
            allocation.quantity_base-COALESCE(posted_return.base_qty,0),
            batch.qty_remaining),0)*receipt_line.estimated_base_unit_cost,4)
            returnable_provisional_value,
          CASE
            WHEN batch.qty_remaining<=0 THEN 'PURCHASE_RETURN_FIFO_NOT_AVAILABLE'
            WHEN allocation.quantity_base-COALESCE(posted_return.base_qty,0)<=0
              THEN 'PURCHASE_RETURN_SOURCE_FULLY_RETURNED'
            ELSE NULL END blocker_code
        FROM public.goods_receipt_documents receipt
        JOIN public.goods_receipt_lines receipt_line
          ON receipt_line.company_id=receipt.company_id
         AND receipt_line.document_id=receipt.id
        JOIN public.goods_receipt_condition_allocations allocation
          ON allocation.company_id=receipt_line.company_id
         AND allocation.receipt_line_id=receipt_line.id
         AND allocation.condition_type IN('GOOD','DAMAGED')
        JOIN public.product_batches batch
          ON batch.company_id=allocation.company_id
         AND batch.id=allocation.product_batch_id
        JOIN public.warehouses warehouse
          ON warehouse.company_id=allocation.company_id
         AND warehouse.id=allocation.warehouse_id
        LEFT JOIN LATERAL(SELECT sum(return_line.return_base_qty) base_qty
          FROM public.purchase_return_lines return_line
          JOIN public.purchase_return_documents return_document
            ON return_document.company_id=return_line.company_id
           AND return_document.id=return_line.document_id
           AND return_document.status='POSTED'
          WHERE return_line.company_id=allocation.company_id
            AND return_line.source_condition_allocation_id=allocation.id
        ) posted_return ON TRUE
        WHERE receipt.company_id=v_company AND receipt.status='POSTED'
          AND (p_supplier_order_id IS NULL
            OR receipt.supplier_order_id=p_supplier_order_id)) row_data),
    'productUoms',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'productId',product_uom.product_id,'uomId',product_uom.uom_id,
        'uomName',uom.name,'factorToBase',product_uom.factor_to_base,
        'allowDecimal',uom.allow_decimal,'decimalPrecision',uom.decimal_precision)
      ORDER BY product_uom.product_id,product_uom.factor_to_base DESC,uom.name),'[]'::jsonb)
      FROM public.product_uoms product_uom
      JOIN public.uoms uom ON uom.company_id=product_uom.company_id
       AND uom.id=product_uom.uom_id
      WHERE product_uom.company_id=v_company AND product_uom.is_active
        AND uom.is_active
        AND EXISTS(SELECT 1 FROM public.goods_receipt_lines receipt_line
          JOIN public.goods_receipt_documents receipt
            ON receipt.company_id=receipt_line.company_id
           AND receipt.id=receipt_line.document_id AND receipt.status='POSTED'
          WHERE receipt_line.company_id=v_company
            AND receipt_line.product_id=product_uom.product_id
            AND (p_supplier_order_id IS NULL
              OR receipt.supplier_order_id=p_supplier_order_id))),
    'drafts',(SELECT COALESCE(jsonb_agg(to_jsonb(document)
      ORDER BY document.updated_at DESC,document.id),'[]'::jsonb)
      FROM public.purchase_return_documents document
      WHERE document.company_id=v_company AND document.status='DRAFT'
        AND document.source_channel='BACKOFFICE'
        AND (p_supplier_order_id IS NULL
          OR document.supplier_order_id=p_supplier_order_id)),
    'draftLines',(SELECT COALESCE(jsonb_agg(to_jsonb(return_line)
      ORDER BY return_line.document_id,return_line.line_no),'[]'::jsonb)
      FROM public.purchase_return_lines return_line
      JOIN public.purchase_return_documents document
        ON document.company_id=return_line.company_id
       AND document.id=return_line.document_id
      WHERE return_line.company_id=v_company AND document.status='DRAFT'
        AND document.source_channel='BACKOFFICE'
        AND (p_supplier_order_id IS NULL
          OR document.supplier_order_id=p_supplier_order_id)));
END
$$;

CREATE FUNCTION public.save_backoffice_purchase_return_draft(
  p_document_id uuid,p_master_version bigint,p_operation_id uuid,
  p_source_receipt_id uuid,p_source_warehouse_id uuid,p_return_date date,
  p_return_reason text,p_supplier_document_no text,p_notes text,p_lines jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
  v_actor uuid:=auth.uid();v_company uuid:=public.private_active_company_id();
  v_receipt record;v_document public.purchase_return_documents%rowtype;
  v_document_id uuid;v_return_no text;v_line record;v_source record;v_uom record;
  v_line_no integer:=0;v_return_base numeric(24,6);v_prior_return numeric(24,6);
  v_total_base numeric(24,6):=0;v_total_value numeric(20,4):=0;
  v_before jsonb;v_version bigint;v_digest text;v_existing record;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF p_operation_id IS NULL THEN RAISE EXCEPTION 'OPERATION_ID_REQUIRED'; END IF;
  IF NULLIF(btrim(p_return_reason),'') IS NULL THEN
    RAISE EXCEPTION 'PURCHASE_RETURN_REASON_REQUIRED'; END IF;
  IF p_return_date IS NULL THEN RAISE EXCEPTION 'RETURN_DATE_REQUIRED'; END IF;
  IF p_lines IS NULL OR jsonb_typeof(p_lines)<>'array'
    OR jsonb_array_length(p_lines)=0 THEN RAISE EXCEPTION 'PURCHASE_RETURN_LINES_REQUIRED'; END IF;
  PERFORM private.acp_require_permission_capability(v_company,
    'purchase.purchase_returns',CASE WHEN p_document_id IS NULL
      THEN 'CREATE_DRAFT' ELSE 'EDIT_DRAFT' END);
  v_digest:=md5(jsonb_build_object('documentId',p_document_id,
    'masterVersion',p_master_version,'sourceReceiptId',p_source_receipt_id,
    'sourceWarehouseId',p_source_warehouse_id,'returnDate',p_return_date,
    'returnReason',btrim(p_return_reason),
    'supplierDocumentNo',NULLIF(btrim(p_supplier_document_no),''),
    'notes',NULLIF(btrim(p_notes),''),'lines',p_lines)::text);
  PERFORM pg_advisory_xact_lock(hashtextextended(
    v_company::text||':PURCHASE_RETURN_DRAFT_OPERATION:'||p_operation_id::text,0));
  SELECT operation.*,document.return_no,document.status
    INTO v_existing
  FROM public.purchase_return_draft_operations operation
  JOIN public.purchase_return_documents document
    ON document.company_id=operation.company_id AND document.id=operation.document_id
  WHERE operation.company_id=v_company AND operation.operation_id=p_operation_id;
  IF FOUND THEN
    IF v_existing.request_digest<>v_digest THEN
      RAISE EXCEPTION 'PURCHASE_RETURN_DRAFT_IDEMPOTENCY_CONFLICT'; END IF;
    RETURN jsonb_build_object('documentId',v_existing.document_id,
      'returnNo',v_existing.return_no,'status',v_existing.status,
      'masterVersion',v_existing.resulting_master_version,
      'idempotentReplay',true);
  END IF;
  SELECT receipt.*,order_document.supplier_id
    INTO v_receipt
  FROM public.goods_receipt_documents receipt
  JOIN public.supplier_order_documents order_document
    ON order_document.company_id=receipt.company_id
   AND order_document.id=receipt.supplier_order_id
  WHERE receipt.company_id=v_company AND receipt.id=p_source_receipt_id
    AND receipt.status='POSTED' FOR SHARE OF receipt,order_document;
  IF NOT FOUND THEN RAISE EXCEPTION 'POSTED_GOODS_RECEIPT_NOT_FOUND'; END IF;
  IF v_receipt.supplier_id IS NULL THEN RAISE EXCEPTION 'SUPPLIER_ASSIGNMENT_REQUIRED'; END IF;
  IF NOT public.private_purchase_manager_allowed(v_company,v_receipt.store_id) THEN
    RAISE EXCEPTION 'PURCHASE_RETURN_STORE_SCOPE_INVALID'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.warehouses warehouse
    WHERE warehouse.company_id=v_company AND warehouse.id=p_source_warehouse_id
      AND warehouse.is_active AND (warehouse.store_id=v_receipt.store_id
        OR warehouse.store_id IS NULL)) THEN
    RAISE EXCEPTION 'ACTIVE_RETURN_SOURCE_WAREHOUSE_NOT_FOUND'; END IF;

  IF p_document_id IS NULL THEN
    IF p_master_version IS NOT NULL THEN
      RAISE EXCEPTION 'MASTER_VERSION_NOT_ALLOWED_ON_CREATE'; END IF;
    IF EXISTS(SELECT 1 FROM public.purchase_return_documents document
      WHERE document.company_id=v_company
        AND document.source_receipt_id=p_source_receipt_id
        AND document.source_warehouse_id=p_source_warehouse_id
        AND document.status='DRAFT') THEN
      RAISE EXCEPTION 'ACTIVE_PURCHASE_RETURN_DRAFT_ALREADY_EXISTS'; END IF;
    v_return_no:='PR-'||to_char(clock_timestamp(),'YYYYMMDD')||'-'
      ||lpad(nextval('private.purchase_return_no_seq')::text,10,'0');
    INSERT INTO public.purchase_return_documents(company_id,return_no,
      source_receipt_id,supplier_order_id,supplier_id,store_id,
      source_warehouse_id,created_session_id,created_pos_id,return_date,
      return_reason,supplier_document_no,notes,created_by,source_channel)
    VALUES(v_company,v_return_no,v_receipt.id,v_receipt.supplier_order_id,
      v_receipt.supplier_id,v_receipt.store_id,p_source_warehouse_id,NULL,NULL,
      p_return_date,btrim(p_return_reason),NULLIF(btrim(p_supplier_document_no),''),
      NULLIF(btrim(p_notes),''),v_actor,'BACKOFFICE')
    RETURNING id,master_version INTO v_document_id,v_version;
  ELSE
    SELECT * INTO v_document FROM public.purchase_return_documents document
    WHERE document.company_id=v_company AND document.id=p_document_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'PURCHASE_RETURN_NOT_FOUND'; END IF;
    IF v_document.status<>'DRAFT' THEN RAISE EXCEPTION 'FINAL_PURCHASE_RETURN_IMMUTABLE'; END IF;
    IF v_document.source_channel<>'BACKOFFICE' THEN
      RAISE EXCEPTION 'PURCHASE_RETURN_CHANNEL_INVALID'; END IF;
    IF v_document.source_receipt_id<>p_source_receipt_id
      OR v_document.source_warehouse_id<>p_source_warehouse_id THEN
      RAISE EXCEPTION 'PURCHASE_RETURN_SOURCE_IMMUTABLE'; END IF;
    IF p_master_version IS DISTINCT FROM v_document.master_version THEN
      RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
    v_before:=to_jsonb(v_document);v_document_id:=v_document.id;
    v_return_no:=v_document.return_no;
    DELETE FROM public.purchase_return_lines return_line
    WHERE return_line.company_id=v_company AND return_line.document_id=v_document_id;
  END IF;

  FOR v_line IN SELECT * FROM jsonb_to_recordset(p_lines) AS input(
    "clientLineKey" uuid,"sourceConditionAllocationId" uuid,
    "returnUomId" uuid,"returnQty" numeric)
  LOOP
    v_line_no:=v_line_no+1;
    IF v_line."clientLineKey" IS NULL THEN
      RAISE EXCEPTION 'PURCHASE_RETURN_CLIENT_LINE_KEY_REQUIRED'; END IF;
    SELECT allocation.id allocation_id,allocation.condition_type,
      allocation.warehouse_id,allocation.quantity_base,allocation.product_batch_id,
      receipt_line.id receipt_line_id,receipt_line.product_id,
      receipt_line.base_uom_id,receipt_line.base_uom_name_snapshot,
      receipt_line.estimated_base_unit_cost,receipt_line.product_sku_snapshot,
      receipt_line.product_name_snapshot,batch.qty_remaining
      INTO v_source
    FROM public.goods_receipt_condition_allocations allocation
    JOIN public.goods_receipt_lines receipt_line
      ON receipt_line.company_id=allocation.company_id
     AND receipt_line.id=allocation.receipt_line_id
    JOIN public.product_batches batch
      ON batch.company_id=allocation.company_id
     AND batch.id=allocation.product_batch_id
    WHERE allocation.company_id=v_company
      AND allocation.id=v_line."sourceConditionAllocationId"
      AND receipt_line.document_id=v_receipt.id
      AND allocation.condition_type IN('GOOD','DAMAGED')
      AND allocation.warehouse_id=p_source_warehouse_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'RETURNABLE_RECEIPT_ALLOCATION_NOT_FOUND'; END IF;
    SELECT product_uom.factor_to_base,uom.name,uom.allow_decimal
      INTO v_uom
    FROM public.product_uoms product_uom
    JOIN public.uoms uom ON uom.company_id=product_uom.company_id
     AND uom.id=product_uom.uom_id
    WHERE product_uom.company_id=v_company
      AND product_uom.product_id=v_source.product_id
      AND product_uom.uom_id=v_line."returnUomId"
      AND product_uom.is_active AND uom.is_active;
    IF NOT FOUND THEN RAISE EXCEPTION 'ACTIVE_RETURN_PRODUCT_UOM_NOT_FOUND'; END IF;
    IF v_line."returnQty" IS NULL OR v_line."returnQty"<=0 THEN
      RAISE EXCEPTION 'PURCHASE_RETURN_QUANTITY_INVALID'; END IF;
    IF NOT v_uom.allow_decimal AND v_line."returnQty"<>trunc(v_line."returnQty") THEN
      RAISE EXCEPTION 'RETURN_UOM_REQUIRES_INTEGER'; END IF;
    v_return_base:=v_line."returnQty"*v_uom.factor_to_base;
    SELECT COALESCE(sum(return_line.return_base_qty),0) INTO v_prior_return
    FROM public.purchase_return_lines return_line
    JOIN public.purchase_return_documents return_document
      ON return_document.company_id=return_line.company_id
     AND return_document.id=return_line.document_id
     AND return_document.status='POSTED'
    WHERE return_line.company_id=v_company
      AND return_line.source_condition_allocation_id=v_source.allocation_id;
    IF v_prior_return+v_return_base>v_source.quantity_base
      OR v_return_base>v_source.qty_remaining THEN
      RAISE EXCEPTION 'PURCHASE_RETURN_QUANTITY_EXCEEDS_AVAILABLE'; END IF;
    INSERT INTO public.purchase_return_lines(company_id,document_id,line_no,
      client_line_key,source_receipt_line_id,source_condition_allocation_id,
      source_product_batch_id,product_id,return_uom_id,return_qty,
      factor_to_base_snapshot,return_base_qty,provisional_base_unit_cost_snapshot,
      provisional_return_value,source_condition_snapshot,product_sku_snapshot,
      product_name_snapshot,return_uom_name_snapshot,base_uom_id,
      base_uom_name_snapshot)
    VALUES(v_company,v_document_id,v_line_no,v_line."clientLineKey",
      v_source.receipt_line_id,v_source.allocation_id,v_source.product_batch_id,
      v_source.product_id,v_line."returnUomId",v_line."returnQty",
      v_uom.factor_to_base,v_return_base,v_source.estimated_base_unit_cost,
      round(v_return_base*v_source.estimated_base_unit_cost,4),
      v_source.condition_type,v_source.product_sku_snapshot,
      v_source.product_name_snapshot,v_uom.name,v_source.base_uom_id,
      v_source.base_uom_name_snapshot);
    v_total_base:=v_total_base+v_return_base;
    v_total_value:=v_total_value+round(v_return_base*v_source.estimated_base_unit_cost,4);
  END LOOP;
  UPDATE public.purchase_return_documents document SET
    return_date=p_return_date,return_reason=btrim(p_return_reason),
    supplier_document_no=NULLIF(btrim(p_supplier_document_no),''),
    notes=NULLIF(btrim(p_notes),''),review_status='PENDING',reviewed_by=NULL,
    reviewed_at=NULL,review_reason=NULL,line_count=v_line_no,
    total_return_base_qty=v_total_base,
    provisional_ap_adjustment_total=v_total_value,
    master_version=CASE WHEN p_document_id IS NULL THEN document.master_version
      ELSE document.master_version+1 END,updated_at=clock_timestamp()
  WHERE document.company_id=v_company AND document.id=v_document_id
  RETURNING document.master_version INTO v_version;
  INSERT INTO public.purchase_return_audit(company_id,document_id,action,
    actor_id,before_state,after_state)
  SELECT v_company,v_document_id,CASE WHEN p_document_id IS NULL
      THEN 'CREATE' ELSE 'UPDATE' END,v_actor,v_before,to_jsonb(document)
  FROM public.purchase_return_documents document
  WHERE document.company_id=v_company AND document.id=v_document_id;
  INSERT INTO public.purchase_return_draft_operations(company_id,operation_id,
    document_id,request_digest,resulting_master_version,actor_id)
  VALUES(v_company,p_operation_id,v_document_id,v_digest,v_version,v_actor);
  RETURN jsonb_build_object('documentId',v_document_id,'returnNo',v_return_no,
    'status','DRAFT','reviewStatus','PENDING','masterVersion',v_version,
    'provisionalReturnValue',v_total_value,'idempotentReplay',false);
EXCEPTION WHEN unique_violation THEN
  RAISE EXCEPTION 'PURCHASE_RETURN_DRAFT_IDEMPOTENCY_CONFLICT';
END
$$;

REVOKE ALL ON FUNCTION public.get_backoffice_purchase_return_workspace(uuid),
  public.save_backoffice_purchase_return_draft(uuid,bigint,uuid,uuid,uuid,date,text,text,text,jsonb)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_backoffice_purchase_return_workspace(uuid),
  public.save_backoffice_purchase_return_draft(uuid,bigint,uuid,uuid,uuid,date,text,text,text,jsonb)
TO authenticated,service_role;
REVOKE ALL ON FUNCTION private.trg_purchase_return_draft_operation_immutable()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.trg_purchase_return_draft_operation_immutable()
TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260919140000','backoffice_purchase_return_draft_runtime',
  'Adds source-channel-safe Backoffice Supplier Return workspace and idempotent Draft/Edit runtime while preserving the existing POS/Cashier Purchase Return path');
NOTIFY pgrst,'reload schema';
COMMIT;
