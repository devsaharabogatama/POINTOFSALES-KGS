-- Purchase Daily Replenishment Step 2/6.
-- Adds the read-only negative-On-Hand candidate resolver and separates the
-- shortage source Warehouse from the editable purchase receipt destination.
-- No RO/PO/Receipt, Stock, FIFO, AP or Finance mutation is activated here.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260913100000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Purchase replenishment Step 1 required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260913110000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260913110000';
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
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: open Sales process cutover plan';
  END IF;
  IF EXISTS(SELECT 1 FROM information_schema.columns
      WHERE table_schema='public' AND (
        (table_name='company_purchase_replenishment_settings'
          AND column_name='default_purchase_receipt_warehouse_id') OR
        (table_name='purchase_daily_batch_lines'
          AND column_name IN('destination_warehouse_id','requires_transfer')) OR
        (table_name='stock_request_lines'
          AND column_name IN('source_warehouse_id','destination_warehouse_id')) OR
        (table_name='supplier_order_lines'
          AND column_name IN('source_warehouse_id','destination_warehouse_id')))) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Step 2 column collision';
  END IF;
  IF to_regprocedure('private.purchase_uncovered_negative_qty(numeric,numeric)') IS NOT NULL
    OR to_regprocedure('private.get_purchase_daily_replenishment_candidates_core(uuid,date)') IS NOT NULL
    OR to_regprocedure('private.trg_guard_purchase_line_source_warehouse()') IS NOT NULL
    OR to_regprocedure('public.get_purchase_daily_replenishment_preview()') IS NOT NULL
    OR to_regprocedure('public.set_purchase_replenishment_default_warehouse(uuid,bigint)') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Step 2 routine collision';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM pg_constraint constraint_row
      WHERE constraint_row.conrelid='public.stock_request_lines'::regclass
        AND constraint_row.conname='stock_request_lines_document_product_uom_unique')
    OR NOT EXISTS(SELECT 1 FROM pg_constraint constraint_row
      WHERE constraint_row.conrelid='public.supplier_order_lines'::regclass
        AND constraint_row.conname='supplier_order_lines_document_product_uom_unique') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical Purchase line uniqueness drift';
  END IF;
END
$guard$;

ALTER TABLE public.company_purchase_replenishment_settings
  ADD COLUMN default_purchase_receipt_warehouse_id uuid,
  ADD CONSTRAINT company_purchase_replenishment_default_warehouse_fk
    FOREIGN KEY(company_id,default_purchase_receipt_warehouse_id)
    REFERENCES public.warehouses(company_id,id) ON DELETE RESTRICT;

ALTER TABLE public.company_purchase_replenishment_setting_audit
  DROP CONSTRAINT company_purchase_replenishment_setting_audit_action_check,
  ADD CONSTRAINT company_purchase_replenishment_setting_audit_action_check
    CHECK(action IN('PROVISION','MODE_CHANGE','DEFAULT_WAREHOUSE_CHANGE'));

ALTER TABLE public.stock_request_lines
  ADD COLUMN source_warehouse_id uuid,
  ADD COLUMN destination_warehouse_id uuid,
  ADD CONSTRAINT stock_request_line_source_warehouse_fk
    FOREIGN KEY(company_id,source_warehouse_id)
    REFERENCES public.warehouses(company_id,id) ON DELETE RESTRICT,
  ADD CONSTRAINT stock_request_line_destination_warehouse_fk
    FOREIGN KEY(company_id,destination_warehouse_id)
    REFERENCES public.warehouses(company_id,id) ON DELETE RESTRICT,
  ADD CONSTRAINT stock_request_line_warehouse_pair_check CHECK(
    (source_warehouse_id IS NULL AND destination_warehouse_id IS NULL)
    OR (source_warehouse_id IS NOT NULL AND destination_warehouse_id IS NOT NULL));

ALTER TABLE public.stock_request_lines
  DROP CONSTRAINT stock_request_lines_document_product_uom_unique;
CREATE UNIQUE INDEX stock_request_lines_legacy_product_uom_unique
  ON public.stock_request_lines(company_id,document_id,product_id,requested_uom_id)
  WHERE source_warehouse_id IS NULL;
CREATE UNIQUE INDEX stock_request_lines_source_product_uom_unique
  ON public.stock_request_lines(company_id,document_id,product_id,requested_uom_id,
    source_warehouse_id,destination_warehouse_id)
  WHERE source_warehouse_id IS NOT NULL;

ALTER TABLE public.supplier_order_lines
  ADD COLUMN source_warehouse_id uuid,
  ADD COLUMN destination_warehouse_id uuid,
  ADD CONSTRAINT supplier_order_line_source_warehouse_fk
    FOREIGN KEY(company_id,source_warehouse_id)
    REFERENCES public.warehouses(company_id,id) ON DELETE RESTRICT,
  ADD CONSTRAINT supplier_order_line_destination_warehouse_fk
    FOREIGN KEY(company_id,destination_warehouse_id)
    REFERENCES public.warehouses(company_id,id) ON DELETE RESTRICT,
  ADD CONSTRAINT supplier_order_line_warehouse_pair_check CHECK(
    (source_warehouse_id IS NULL AND destination_warehouse_id IS NULL)
    OR (source_warehouse_id IS NOT NULL AND destination_warehouse_id IS NOT NULL));

ALTER TABLE public.supplier_order_lines
  DROP CONSTRAINT supplier_order_lines_document_product_uom_unique;
CREATE UNIQUE INDEX supplier_order_lines_legacy_product_uom_unique
  ON public.supplier_order_lines(company_id,document_id,product_id,ordered_uom_id)
  WHERE source_warehouse_id IS NULL;
CREATE UNIQUE INDEX supplier_order_lines_source_product_uom_unique
  ON public.supplier_order_lines(company_id,document_id,product_id,ordered_uom_id,
    source_warehouse_id,destination_warehouse_id)
  WHERE source_warehouse_id IS NOT NULL;

ALTER TABLE public.purchase_daily_batch_lines
  ADD COLUMN destination_warehouse_id uuid,
  ADD COLUMN requires_transfer boolean NOT NULL DEFAULT false,
  ADD COLUMN destination_warehouse_code_snapshot text,
  ADD COLUMN destination_warehouse_name_snapshot text,
  ADD CONSTRAINT purchase_daily_line_destination_warehouse_fk
    FOREIGN KEY(company_id,destination_warehouse_id)
    REFERENCES public.warehouses(company_id,id) ON DELETE RESTRICT,
  ADD CONSTRAINT purchase_daily_line_destination_shape_check CHECK(
    (destination_warehouse_id IS NULL AND NOT requires_transfer
      AND destination_warehouse_code_snapshot IS NULL
      AND destination_warehouse_name_snapshot IS NULL)
    OR (destination_warehouse_id IS NOT NULL
      AND requires_transfer=(destination_warehouse_id<>warehouse_id)
      AND destination_warehouse_code_snapshot IS NOT NULL
      AND destination_warehouse_name_snapshot IS NOT NULL
      AND btrim(destination_warehouse_code_snapshot)<>''
      AND btrim(destination_warehouse_name_snapshot)<>''));

COMMENT ON COLUMN public.purchase_daily_batch_lines.warehouse_id IS
  'Immutable source Warehouse where negative On Hand was measured.';
COMMENT ON COLUMN public.purchase_daily_batch_lines.destination_warehouse_id IS
  'Editable receipt destination until the first Goods Receipt is posted.';
COMMENT ON COLUMN public.stock_request_lines.source_warehouse_id IS
  'Optional exact shortage source; NULL preserves legacy/manual Request compatibility.';
COMMENT ON COLUMN public.supplier_order_lines.destination_warehouse_id IS
  'Per-line receipt destination; NULL falls back to the legacy Supplier Order header destination.';

CREATE INDEX purchase_daily_line_destination_idx
  ON public.purchase_daily_batch_lines(company_id,batch_id,destination_warehouse_id);
CREATE INDEX stock_request_line_source_warehouse_idx
  ON public.stock_request_lines(company_id,source_warehouse_id,product_id)
  WHERE is_active AND source_warehouse_id IS NOT NULL;
CREATE INDEX supplier_order_line_destination_warehouse_idx
  ON public.supplier_order_lines(company_id,destination_warehouse_id,product_id)
  WHERE destination_warehouse_id IS NOT NULL;

CREATE FUNCTION private.trg_guard_purchase_line_source_warehouse()
RETURNS trigger LANGUAGE plpgsql SET search_path=public,pg_temp AS $$
BEGIN
  IF OLD.source_warehouse_id IS NOT NULL
    AND NEW.source_warehouse_id IS DISTINCT FROM OLD.source_warehouse_id THEN
    RAISE EXCEPTION 'PURCHASE_LINE_SOURCE_WAREHOUSE_IMMUTABLE';
  END IF;
  RETURN NEW;
END
$$;

CREATE TRIGGER guard_stock_request_line_source_warehouse
BEFORE UPDATE OF source_warehouse_id ON public.stock_request_lines
FOR EACH ROW EXECUTE FUNCTION private.trg_guard_purchase_line_source_warehouse();
CREATE TRIGGER guard_supplier_order_line_source_warehouse
BEFORE UPDATE OF source_warehouse_id ON public.supplier_order_lines
FOR EACH ROW EXECUTE FUNCTION private.trg_guard_purchase_line_source_warehouse();

CREATE FUNCTION private.purchase_uncovered_negative_qty(
  p_on_hand_base_qty numeric,p_open_purchase_base_qty numeric
) RETURNS numeric LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
SET search_path=public,pg_temp AS $$
  SELECT GREATEST(-LEAST(p_on_hand_base_qty,0)-GREATEST(p_open_purchase_base_qty,0),0)
$$;

CREATE FUNCTION private.get_purchase_daily_replenishment_candidates_core(
  p_company_id uuid,p_business_date date
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_setting public.company_purchase_replenishment_settings%rowtype;
  v_result jsonb;
BEGIN
  IF p_company_id IS NULL OR p_business_date IS NULL THEN
    RAISE EXCEPTION 'PURCHASE_REPLENISHMENT_PREVIEW_INPUT_INVALID';
  END IF;
  SELECT * INTO v_setting FROM public.company_purchase_replenishment_settings setting
  WHERE setting.company_id=p_company_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'PURCHASE_REPLENISHMENT_SETTING_NOT_FOUND'; END IF;

  WITH posted_receipt AS (
    SELECT line.company_id,line.supplier_order_line_id,
      sum(line.received_base_qty) received_base_qty
    FROM public.goods_receipt_lines line
    JOIN public.goods_receipt_documents document
      ON document.company_id=line.company_id AND document.id=line.document_id
    WHERE line.company_id=p_company_id AND document.status='POSTED'
    GROUP BY line.company_id,line.supplier_order_line_id
  ), order_coverage AS (
    SELECT line.company_id,line.product_id,
      COALESCE(line.source_warehouse_id,line.destination_warehouse_id,
        document.destination_warehouse_id) warehouse_id,
      sum(GREATEST(line.ordered_base_qty-COALESCE(receipt.received_base_qty,0),0))
        open_base_qty
    FROM public.supplier_order_lines line
    JOIN public.supplier_order_documents document
      ON document.company_id=line.company_id AND document.id=line.document_id
    LEFT JOIN posted_receipt receipt
      ON receipt.company_id=line.company_id AND receipt.supplier_order_line_id=line.id
    WHERE line.company_id=p_company_id
      AND document.status IN('DRAFT','CONFIRMED','PARTIALLY_RECEIVED')
    GROUP BY line.company_id,line.product_id,
      COALESCE(line.source_warehouse_id,line.destination_warehouse_id,
        document.destination_warehouse_id)
  ), active_order_allocation AS (
    SELECT allocation.company_id,allocation.stock_request_line_id,
      sum(allocation.allocated_base_qty) allocated_base_qty
    FROM public.supplier_order_request_allocations allocation
    JOIN public.supplier_order_lines order_line
      ON order_line.company_id=allocation.company_id
     AND order_line.id=allocation.supplier_order_line_id
    JOIN public.supplier_order_documents order_document
      ON order_document.company_id=order_line.company_id
     AND order_document.id=order_line.document_id
    WHERE allocation.company_id=p_company_id
      AND order_document.status IN('DRAFT','CONFIRMED','PARTIALLY_RECEIVED')
    GROUP BY allocation.company_id,allocation.stock_request_line_id
  ), request_fact AS (
    SELECT request_line.company_id,request_line.id,request_line.product_id,
      COALESCE(request_line.source_warehouse_id,demand_line.warehouse_id) warehouse_id,
      GREATEST(request_line.requested_base_qty-
        COALESCE(allocation.allocated_base_qty,0),0) open_base_qty
    FROM public.stock_request_lines request_line
    JOIN public.stock_request_documents request_document
      ON request_document.company_id=request_line.company_id
     AND request_document.id=request_line.document_id
    LEFT JOIN public.sales_order_procurement_demand_lines demand_line
      ON demand_line.company_id=request_line.company_id
     AND demand_line.stock_request_line_id=request_line.id
    LEFT JOIN active_order_allocation allocation
      ON allocation.company_id=request_line.company_id
     AND allocation.stock_request_line_id=request_line.id
    WHERE request_line.company_id=p_company_id AND request_line.is_active
      AND request_document.status IN('DRAFT','SUBMITTED','ORDERED','PARTIALLY_RECEIVED')
  ), request_coverage AS (
    SELECT company_id,product_id,warehouse_id,sum(open_base_qty) open_base_qty
    FROM request_fact WHERE warehouse_id IS NOT NULL AND open_base_qty>0
    GROUP BY company_id,product_id,warehouse_id
  ), ambiguous_request AS (
    SELECT product_id,sum(open_base_qty) open_base_qty
    FROM request_fact WHERE warehouse_id IS NULL AND open_base_qty>0 GROUP BY product_id
  ), receiving_warehouses AS (
    SELECT warehouse.id,warehouse.code,warehouse.name
    FROM public.warehouses warehouse
    WHERE warehouse.company_id=p_company_id AND warehouse.is_active
      AND warehouse.is_purchase_destination
      AND warehouse.warehouse_type IS DISTINCT FROM 'TRANSIT'
  ), facts AS (
    SELECT stock.product_id,stock.warehouse_id source_warehouse_id,
      stock.stock_qty on_hand_base_qty,product.sku product_sku,product.name product_name,
      product.is_active product_active,
      product.uom_id base_uom_id,uom.name base_uom_name,
      source.code source_warehouse_code,source.name source_warehouse_name,
      source.is_active source_warehouse_active,
      COALESCE(ordering.open_base_qty,0) open_supplier_order_base_qty,
      COALESCE(requesting.open_base_qty,0) open_exact_request_base_qty,
      COALESCE(ambiguous.open_base_qty,0) ambiguous_request_base_qty,
      destination.id destination_warehouse_id,destination.code destination_warehouse_code,
      destination.name destination_warehouse_name,
      supplier_relation.id suggested_product_supplier_id,
      supplier_relation.supplier_id suggested_supplier_id,
      supplier.supplier_code suggested_supplier_code,
      supplier.supplier_name suggested_supplier_name,
      supplier_relation.purchase_uom_id suggested_purchase_uom_id,
      purchase_uom.name suggested_purchase_uom_name,
      purchase_product_uom.factor_to_base suggested_factor_to_base,
      COALESCE(supplier_relation.last_purchase_price,
        supplier_relation.reference_purchase_price,
        purchase_product_uom.purchase_price,0) suggested_unit_price,
      supplier_relation.selection_priority
    FROM public.product_stocks stock
    JOIN public.products product ON product.company_id=stock.company_id
      AND product.id=stock.product_id
    JOIN public.uoms uom ON uom.company_id=product.company_id AND uom.id=product.uom_id
    JOIN public.warehouses source ON source.company_id=stock.company_id
      AND source.id=stock.warehouse_id
    LEFT JOIN order_coverage ordering ON ordering.company_id=stock.company_id
      AND ordering.product_id=stock.product_id AND ordering.warehouse_id=stock.warehouse_id
    LEFT JOIN request_coverage requesting ON requesting.company_id=stock.company_id
      AND requesting.product_id=stock.product_id AND requesting.warehouse_id=stock.warehouse_id
    LEFT JOIN ambiguous_request ambiguous ON ambiguous.product_id=stock.product_id
    LEFT JOIN LATERAL (
      SELECT receiver.* FROM receiving_warehouses receiver
      WHERE receiver.id=CASE WHEN source.is_active AND source.is_purchase_destination
          AND source.warehouse_type IS DISTINCT FROM 'TRANSIT' THEN source.id
        ELSE v_setting.default_purchase_receipt_warehouse_id END
    ) destination ON true
    LEFT JOIN LATERAL (
      SELECT relation.* FROM public.product_suppliers relation
      JOIN public.suppliers candidate_supplier
        ON candidate_supplier.company_id=relation.company_id
       AND candidate_supplier.id=relation.supplier_id AND candidate_supplier.is_active
      JOIN public.product_uoms candidate_uom
        ON candidate_uom.company_id=relation.company_id
       AND candidate_uom.product_id=relation.product_id
       AND candidate_uom.uom_id=relation.purchase_uom_id
       AND candidate_uom.is_active AND candidate_uom.purchase_allowed
      WHERE relation.company_id=stock.company_id AND relation.product_id=stock.product_id
        AND relation.is_active
      ORDER BY relation.selection_priority,relation.is_preferred_supplier DESC,
        relation.created_at,relation.id LIMIT 1
    ) supplier_relation ON true
    LEFT JOIN public.suppliers supplier ON supplier.company_id=supplier_relation.company_id
      AND supplier.id=supplier_relation.supplier_id
    LEFT JOIN public.uoms purchase_uom ON purchase_uom.company_id=supplier_relation.company_id
      AND purchase_uom.id=supplier_relation.purchase_uom_id
    LEFT JOIN public.product_uoms purchase_product_uom
      ON purchase_product_uom.company_id=supplier_relation.company_id
     AND purchase_product_uom.product_id=supplier_relation.product_id
     AND purchase_product_uom.uom_id=supplier_relation.purchase_uom_id
    WHERE stock.company_id=p_company_id AND stock.stock_qty<0
  ), resolved AS (
    SELECT fact.*,
      fact.open_supplier_order_base_qty+fact.open_exact_request_base_qty open_purchase_base_qty,
      private.purchase_uncovered_negative_qty(fact.on_hand_base_qty,
        fact.open_supplier_order_base_qty+fact.open_exact_request_base_qty) requested_base_qty
    FROM facts fact
  ), shaped AS (
    SELECT resolved.*,
      CASE
        WHEN ambiguous_request_base_qty>0 THEN 'OPEN_REQUEST_WAREHOUSE_AMBIGUOUS'
        WHEN NOT product_active THEN 'PRODUCT_INACTIVE'
        WHEN NOT source_warehouse_active THEN 'SOURCE_WAREHOUSE_INACTIVE'
        WHEN destination_warehouse_id IS NULL THEN 'WAREHOUSE_SETUP_REQUIRED'
        WHEN requested_base_qty=0 THEN 'FULLY_COVERED'
        WHEN suggested_supplier_id IS NULL THEN 'SUPPLIER_PENDING'
        ELSE 'READY'
      END candidate_status
    FROM resolved
  )
  SELECT jsonb_build_object(
    'companyId',p_company_id,'businessDate',p_business_date,
    'mode',v_setting.replenishment_mode,
    'defaultPurchaseReceiptWarehouseId',v_setting.default_purchase_receipt_warehouse_id,
    'generationActive',false,
    'summary',jsonb_build_object(
      'negativeOnHandRows',(SELECT count(*) FROM shaped),
      'actionableRows',(SELECT count(*) FROM shaped
        WHERE requested_base_qty>0 AND candidate_status IN('READY','SUPPLIER_PENDING')),
      'coveredRows',(SELECT count(*) FROM shaped WHERE candidate_status='FULLY_COVERED'),
      'blockedRows',(SELECT count(*) FROM shaped WHERE candidate_status IN(
        'OPEN_REQUEST_WAREHOUSE_AMBIGUOUS','PRODUCT_INACTIVE','SOURCE_WAREHOUSE_INACTIVE',
        'WAREHOUSE_SETUP_REQUIRED'))),
    'receivingWarehouses',COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'id',warehouse.id,'code',warehouse.code,'name',warehouse.name) ORDER BY warehouse.name,warehouse.id)
      FROM receiving_warehouses warehouse),'[]'::jsonb),
    'candidates',COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'productId',row.product_id,'productSku',row.product_sku,'productName',row.product_name,
      'baseUomId',row.base_uom_id,'baseUomName',row.base_uom_name,
      'sourceWarehouseId',row.source_warehouse_id,
      'sourceWarehouseCode',row.source_warehouse_code,
      'sourceWarehouseName',row.source_warehouse_name,
      'onHandBaseQty',row.on_hand_base_qty,
      'openSupplierOrderBaseQty',row.open_supplier_order_base_qty,
      'openExactRequestBaseQty',row.open_exact_request_base_qty,
      'openPurchaseBaseQty',row.open_purchase_base_qty,
      'ambiguousOpenRequestBaseQty',row.ambiguous_request_base_qty,
      'requestedBaseQty',row.requested_base_qty,
      'destinationWarehouseId',row.destination_warehouse_id,
      'destinationWarehouseCode',row.destination_warehouse_code,
      'destinationWarehouseName',row.destination_warehouse_name,
      'requiresTransfer',row.destination_warehouse_id IS NOT NULL
        AND row.destination_warehouse_id<>row.source_warehouse_id,
      'supplierAssignmentStatus',CASE WHEN row.suggested_supplier_id IS NULL
        THEN 'SUPPLIER_PENDING' ELSE 'ASSIGNED' END,
      'suggestedProductSupplierId',row.suggested_product_supplier_id,
      'suggestedSupplierId',row.suggested_supplier_id,
      'suggestedSupplierCode',row.suggested_supplier_code,
      'suggestedSupplierName',row.suggested_supplier_name,
      'suggestedPurchaseUomId',row.suggested_purchase_uom_id,
      'suggestedPurchaseUomName',row.suggested_purchase_uom_name,
      'suggestedFactorToBase',row.suggested_factor_to_base,
      'suggestedUnitPrice',row.suggested_unit_price,
      'selectionPriority',row.selection_priority,
      'status',row.candidate_status
    ) ORDER BY row.source_warehouse_name,row.product_name,row.product_id) FROM shaped row),'[]'::jsonb)
  ) INTO v_result;
  RETURN v_result;
END
$$;

CREATE FUNCTION public.get_purchase_daily_replenishment_preview()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_date date;
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'purchase.supplier_orders','VIEW');
  SELECT (clock_timestamp() AT TIME ZONE company.timezone)::date INTO v_date
  FROM public.companies company WHERE company.id=v_company AND company.status='ACTIVE';
  IF v_date IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_NOT_FOUND'; END IF;
  RETURN private.get_purchase_daily_replenishment_candidates_core(v_company,v_date);
END
$$;

CREATE FUNCTION public.set_purchase_replenishment_default_warehouse(
  p_warehouse_id uuid,p_master_version bigint
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_actor uuid:=auth.uid();v_company uuid:=public.private_active_company_id();
  v_before public.company_purchase_replenishment_settings%rowtype;
  v_after public.company_purchase_replenishment_settings%rowtype;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM public.profiles profile
      WHERE profile.id=v_actor AND profile.role='super_admin') THEN
    RAISE EXCEPTION 'SUPER_ADMIN_REQUIRED';
  END IF;
  IF p_warehouse_id IS NOT NULL AND NOT EXISTS(
      SELECT 1 FROM public.warehouses warehouse
      WHERE warehouse.company_id=v_company AND warehouse.id=p_warehouse_id
        AND warehouse.is_active AND warehouse.is_purchase_destination
        AND warehouse.warehouse_type IS DISTINCT FROM 'TRANSIT') THEN
    RAISE EXCEPTION 'PURCHASE_RECEIPT_WAREHOUSE_INVALID';
  END IF;
  SELECT * INTO v_before FROM public.company_purchase_replenishment_settings setting
  WHERE setting.company_id=v_company FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'PURCHASE_REPLENISHMENT_SETTING_NOT_FOUND'; END IF;
  IF p_master_version IS NULL OR p_master_version<>v_before.master_version THEN
    RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
  END IF;
  IF v_before.default_purchase_receipt_warehouse_id IS NOT DISTINCT FROM p_warehouse_id THEN
    RETURN jsonb_build_object('companyId',v_company,
      'defaultPurchaseReceiptWarehouseId',p_warehouse_id,
      'masterVersion',v_before.master_version,'changed',false);
  END IF;
  UPDATE public.company_purchase_replenishment_settings SET
    default_purchase_receipt_warehouse_id=p_warehouse_id,
    master_version=master_version+1,updated_by=v_actor,updated_at=clock_timestamp()
  WHERE company_id=v_company RETURNING * INTO v_after;
  INSERT INTO public.company_purchase_replenishment_setting_audit(
    company_id,action,actor_id,before_state,after_state)
  VALUES(v_company,'DEFAULT_WAREHOUSE_CHANGE',v_actor,to_jsonb(v_before),to_jsonb(v_after));
  RETURN jsonb_build_object('companyId',v_company,
    'defaultPurchaseReceiptWarehouseId',v_after.default_purchase_receipt_warehouse_id,
    'masterVersion',v_after.master_version,'changed',true);
END
$$;

CREATE OR REPLACE FUNCTION public.get_purchase_replenishment_setting()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_setting record;
BEGIN
  PERFORM private.acp_require_permission_capability(v_company,'purchase.supplier_orders','VIEW');
  SELECT setting.*,company.timezone,warehouse.code default_warehouse_code,
    warehouse.name default_warehouse_name INTO v_setting
  FROM public.company_purchase_replenishment_settings setting
  JOIN public.companies company ON company.id=setting.company_id
  LEFT JOIN public.warehouses warehouse ON warehouse.company_id=setting.company_id
    AND warehouse.id=setting.default_purchase_receipt_warehouse_id
  WHERE setting.company_id=v_company;
  IF NOT FOUND THEN RAISE EXCEPTION 'PURCHASE_REPLENISHMENT_SETTING_NOT_FOUND'; END IF;
  RETURN jsonb_build_object('companyId',v_company,'mode',v_setting.replenishment_mode,
    'cutoffLocalTime',to_char(v_setting.cutoff_local_time,'HH24:MI'),
    'targetOnHandBaseQty',v_setting.target_on_hand_base_qty,
    'timezone',v_setting.timezone,
    'defaultPurchaseReceiptWarehouseId',v_setting.default_purchase_receipt_warehouse_id,
    'defaultPurchaseReceiptWarehouse',CASE
      WHEN v_setting.default_purchase_receipt_warehouse_id IS NULL THEN NULL
      ELSE jsonb_build_object('id',v_setting.default_purchase_receipt_warehouse_id,
        'code',v_setting.default_warehouse_code,'name',v_setting.default_warehouse_name) END,
    'masterVersion',v_setting.master_version,'updatedAt',v_setting.updated_at);
END
$$;

REVOKE ALL ON FUNCTION private.purchase_uncovered_negative_qty(numeric,numeric),
  private.get_purchase_daily_replenishment_candidates_core(uuid,date),
  private.trg_guard_purchase_line_source_warehouse()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.purchase_uncovered_negative_qty(numeric,numeric),
  private.get_purchase_daily_replenishment_candidates_core(uuid,date),
  private.trg_guard_purchase_line_source_warehouse()
TO service_role;
REVOKE ALL ON FUNCTION public.get_purchase_daily_replenishment_preview(),
  public.set_purchase_replenishment_default_warehouse(uuid,bigint)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_purchase_daily_replenishment_preview(),
  public.set_purchase_replenishment_default_warehouse(uuid,bigint)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260913110000','purchase_daily_replenishment_candidate_preview',
  'Purchase Step 2/6: read-only exact negative-On-Hand candidate preview, open RO/PO coverage, Product-Supplier priority, Company default receipt Warehouse, and distinct source/destination Warehouse line identity; no generator or operational mutation');

COMMIT;
