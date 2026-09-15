-- Purchase Daily Replenishment Step 5/6: multi-Warehouse Receipt and
-- append-only SUPPLIER_PENDING clearing/assignment runtime.
BEGIN;

DO $guard$
DECLARE v_missing text[];
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260913130000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Purchase AUTO_PO Step 4 required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260914100000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260914100000';
  END IF;
  SELECT array_agg(required_object) INTO v_missing FROM (VALUES
    ('public.goods_receipt_documents'::text,to_regclass('public.goods_receipt_documents') IS NOT NULL),
    ('public.goods_receipt_lines',to_regclass('public.goods_receipt_lines') IS NOT NULL),
    ('public.goods_receipt_ap_provisionals',to_regclass('public.goods_receipt_ap_provisionals') IS NOT NULL),
    ('public.purchase_daily_batches',to_regclass('public.purchase_daily_batches') IS NOT NULL),
    ('public.purchase_daily_batch_lines',to_regclass('public.purchase_daily_batch_lines') IS NOT NULL),
    ('public.save_backoffice_goods_receipt',to_regprocedure('public.save_backoffice_goods_receipt(uuid,bigint,uuid,text,text,jsonb)') IS NOT NULL),
    ('public.post_backoffice_goods_receipt',to_regprocedure('public.post_backoffice_goods_receipt(uuid,bigint,uuid)') IS NOT NULL),
    ('private.resolve_opening_stock_account',to_regprocedure('private.resolve_opening_stock_account(uuid,uuid,text,timestamptz)') IS NOT NULL)
  ) dependency(required_object,present) WHERE NOT present;
  IF v_missing IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: missing %',v_missing;
  END IF;
  IF to_regclass('public.goods_receipt_unassigned_clearings') IS NOT NULL
    OR to_regclass('public.goods_receipt_supplier_assignments') IS NOT NULL
    OR to_regclass('public.goods_receipt_supplier_assignment_operations') IS NOT NULL
    OR to_regprocedure('public.save_purchase_daily_goods_receipt(uuid,bigint,uuid,uuid,text,text,jsonb)') IS NOT NULL
    OR to_regprocedure('public.post_purchase_daily_goods_receipt(uuid,bigint,uuid)') IS NOT NULL
    OR to_regprocedure('public.assign_purchase_daily_receipt_suppliers(uuid,bigint,uuid,jsonb)') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Step 5 object collision';
  END IF;
  IF EXISTS(SELECT 1 FROM public.account_functions
      WHERE function_key='PURCHASE_UNASSIGNED_CLEARING')
    OR EXISTS(SELECT 1 FROM public.system_events
      WHERE system_key='GOODS_RECEIPT_SUPPLIER_ASSIGNMENT') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Step 5 Finance catalog collision';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs run
      WHERE run.status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue exists';
  END IF;
END
$guard$;

INSERT INTO public.account_functions(function_key,function_name,
  compatible_account_types,default_normal_balance,allow_reconciliation)
VALUES('PURCHASE_UNASSIGNED_CLEARING','Penerimaan Belum Ditentukan Supplier',
  ARRAY['LIABILITY'],'CREDIT',true);

INSERT INTO public.chart_of_accounts(company_id,account_code,account_name,
  account_type,normal_balance,system_function_key,is_system_account,is_postable,
  allow_manual_posting,allow_reconciliation)
SELECT company.id,
  CASE WHEN EXISTS(SELECT 1 FROM public.chart_of_accounts existing
      WHERE existing.company_id=company.id AND upper(btrim(existing.account_code))='2115')
    THEN '2115-U-'||upper(left(replace(company.id::text,'-',''),6)) ELSE '2115' END,
  CASE WHEN EXISTS(SELECT 1 FROM public.chart_of_accounts existing
      WHERE existing.company_id=company.id
        AND lower(btrim(existing.account_name))='penerimaan belum ditentukan supplier')
    THEN 'Penerimaan Belum Ditentukan Supplier '||upper(left(replace(company.id::text,'-',''),6))
    ELSE 'Penerimaan Belum Ditentukan Supplier' END,
  'LIABILITY','CREDIT',
  'PURCHASE_UNASSIGNED_CLEARING',true,true,false,true
FROM public.companies company
WHERE NOT EXISTS(SELECT 1 FROM public.chart_of_accounts existing
  WHERE existing.company_id=company.id
    AND existing.system_function_key='PURCHASE_UNASSIGNED_CLEARING');

INSERT INTO public.system_events(system_key,event_group,event_name,
  required_account_functions,conditional_account_functions,
  optional_account_functions,is_active)
VALUES('GOODS_RECEIPT_SUPPLIER_ASSIGNMENT','PURCHASE',
  'Penetapan Supplier Penerimaan',
  ARRAY['PURCHASE_UNASSIGNED_CLEARING','SUPPLIER_AP_PROVISIONAL'],
  ARRAY[]::text[],ARRAY[]::text[],true);

INSERT INTO public.transaction_categories(company_id,category_code,category_name,
  system_key,description,is_active)
SELECT company.id,
  CASE WHEN EXISTS(SELECT 1 FROM public.transaction_categories existing
      WHERE existing.company_id=company.id
        AND upper(btrim(existing.category_code))='GR-SUPPLIER-ASSIGN')
    THEN 'GR-SUPPLIER-ASSIGN-'||upper(left(replace(company.id::text,'-',''),6))
    ELSE 'GR-SUPPLIER-ASSIGN' END,
  CASE WHEN EXISTS(SELECT 1 FROM public.transaction_categories existing
      WHERE existing.company_id=company.id
        AND lower(btrim(existing.category_name))='penetapan supplier penerimaan')
    THEN 'Penetapan Supplier Penerimaan '||upper(left(replace(company.id::text,'-',''),6))
    ELSE 'Penetapan Supplier Penerimaan' END,
  'GOODS_RECEIPT_SUPPLIER_ASSIGNMENT',
  'Reklasifikasi clearing penerimaan setelah Supplier ditentukan',true
FROM public.companies company
WHERE NOT EXISTS(SELECT 1 FROM public.transaction_categories existing
  WHERE existing.company_id=company.id
    AND existing.system_key='GOODS_RECEIPT_SUPPLIER_ASSIGNMENT');

ALTER TABLE public.goods_receipt_documents
  ALTER COLUMN store_id DROP NOT NULL,
  ADD COLUMN receipt_scope text NOT NULL DEFAULT 'STORE',
  ADD COLUMN purchase_daily_batch_id uuid,
  ADD COLUMN supplier_id_snapshot uuid,
  ADD COLUMN supplier_assignment_status text NOT NULL DEFAULT 'ASSIGNED',
  ADD COLUMN unassigned_clearing_status text NOT NULL DEFAULT 'NOT_APPLICABLE',
  ADD CONSTRAINT goods_receipt_daily_batch_fk
    FOREIGN KEY(company_id,purchase_daily_batch_id)
    REFERENCES public.purchase_daily_batches(company_id,id) ON DELETE RESTRICT,
  ADD CONSTRAINT goods_receipt_supplier_snapshot_fk
    FOREIGN KEY(company_id,supplier_id_snapshot)
    REFERENCES public.suppliers(company_id,id) ON DELETE RESTRICT;

ALTER TABLE public.goods_receipt_documents
  ADD CONSTRAINT goods_receipt_scope_check CHECK(receipt_scope IN('STORE','DAILY_WAREHOUSE')),
  ADD CONSTRAINT goods_receipt_supplier_assignment_check CHECK(
    supplier_assignment_status IN('ASSIGNED','SUPPLIER_PENDING')),
  ADD CONSTRAINT goods_receipt_clearing_status_check CHECK(
    unassigned_clearing_status IN('NOT_APPLICABLE','OPEN','ASSIGNED')),
  ADD CONSTRAINT goods_receipt_daily_shape_check CHECK(
    (receipt_scope='STORE' AND purchase_daily_batch_id IS NULL AND store_id IS NOT NULL
      AND supplier_assignment_status='ASSIGNED'
      AND unassigned_clearing_status='NOT_APPLICABLE')
    OR (receipt_scope='DAILY_WAREHOUSE' AND purchase_daily_batch_id IS NOT NULL
      AND warehouse_id IS NOT NULL
      AND ((supplier_assignment_status='ASSIGNED' AND supplier_id_snapshot IS NOT NULL
            AND unassigned_clearing_status='NOT_APPLICABLE')
        OR (supplier_assignment_status='SUPPLIER_PENDING' AND supplier_id_snapshot IS NULL
            AND unassigned_clearing_status IN('OPEN','ASSIGNED')))));

ALTER TABLE public.goods_receipt_lines
  ADD COLUMN provisional_cost_source text NOT NULL DEFAULT 'SUPPLIER_ORDER',
  ADD CONSTRAINT goods_receipt_line_cost_source_check CHECK(
    provisional_cost_source IN('SUPPLIER_ORDER','PRODUCT_COGS','USER_OVERRIDE'));

CREATE TABLE public.goods_receipt_unassigned_clearings(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),company_id uuid NOT NULL,
  receipt_id uuid NOT NULL,receipt_line_id uuid NOT NULL,
  clearing_account_id uuid NOT NULL,amount numeric(20,4) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT goods_receipt_unassigned_clearings_company_id_id_unique UNIQUE(company_id,id),
  CONSTRAINT goods_receipt_unassigned_clearings_line_unique UNIQUE(company_id,receipt_line_id),
  CONSTRAINT goods_receipt_unassigned_clearings_receipt_fk FOREIGN KEY(company_id,receipt_id)
    REFERENCES public.goods_receipt_documents(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT goods_receipt_unassigned_clearings_line_fk FOREIGN KEY(company_id,receipt_line_id)
    REFERENCES public.goods_receipt_lines(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT goods_receipt_unassigned_clearings_account_fk FOREIGN KEY(company_id,clearing_account_id)
    REFERENCES public.chart_of_accounts(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT goods_receipt_unassigned_clearings_amount_check CHECK(amount>=0)
);

CREATE TABLE public.goods_receipt_supplier_assignment_operations(
  id uuid PRIMARY KEY,company_id uuid NOT NULL,receipt_id uuid NOT NULL,
  request_hash text NOT NULL,result_snapshot jsonb NOT NULL,actor_id uuid NOT NULL,
  financial_event_id uuid,created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT goods_receipt_supplier_assignment_ops_company_id_id_unique UNIQUE(company_id,id),
  CONSTRAINT goods_receipt_supplier_assignment_ops_receipt_fk FOREIGN KEY(company_id,receipt_id)
    REFERENCES public.goods_receipt_documents(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT goods_receipt_supplier_assignment_ops_actor_fk FOREIGN KEY(actor_id)
    REFERENCES public.profiles(id) ON DELETE RESTRICT,
  CONSTRAINT goods_receipt_supplier_assignment_ops_event_fk FOREIGN KEY(financial_event_id)
    REFERENCES public.financial_events(id) ON DELETE RESTRICT,
  CONSTRAINT goods_receipt_supplier_assignment_ops_hash_check CHECK(btrim(request_hash)<>'')
);

CREATE TABLE public.goods_receipt_supplier_assignments(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),company_id uuid NOT NULL,
  receipt_id uuid NOT NULL,receipt_line_id uuid NOT NULL,clearing_id uuid NOT NULL,
  supplier_id uuid NOT NULL,operation_id uuid NOT NULL,assigned_amount numeric(20,4) NOT NULL,
  assigned_by uuid NOT NULL,assigned_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT goods_receipt_supplier_assignments_company_id_id_unique UNIQUE(company_id,id),
  CONSTRAINT goods_receipt_supplier_assignments_line_unique UNIQUE(company_id,receipt_line_id),
  CONSTRAINT goods_receipt_supplier_assignments_receipt_fk FOREIGN KEY(company_id,receipt_id)
    REFERENCES public.goods_receipt_documents(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT goods_receipt_supplier_assignments_line_fk FOREIGN KEY(company_id,receipt_line_id)
    REFERENCES public.goods_receipt_lines(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT goods_receipt_supplier_assignments_clearing_fk FOREIGN KEY(company_id,clearing_id)
    REFERENCES public.goods_receipt_unassigned_clearings(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT goods_receipt_supplier_assignments_supplier_fk FOREIGN KEY(company_id,supplier_id)
    REFERENCES public.suppliers(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT goods_receipt_supplier_assignments_operation_fk FOREIGN KEY(company_id,operation_id)
    REFERENCES public.goods_receipt_supplier_assignment_operations(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT goods_receipt_supplier_assignments_actor_fk FOREIGN KEY(assigned_by)
    REFERENCES public.profiles(id) ON DELETE RESTRICT,
  CONSTRAINT goods_receipt_supplier_assignments_amount_check CHECK(assigned_amount>=0)
);

CREATE INDEX goods_receipt_daily_order_warehouse_idx
  ON public.goods_receipt_documents(company_id,supplier_order_id,warehouse_id,status)
  WHERE receipt_scope='DAILY_WAREHOUSE';
CREATE INDEX goods_receipt_supplier_assignment_receipt_idx
  ON public.goods_receipt_supplier_assignments(company_id,receipt_id,assigned_at);

COMMENT ON COLUMN public.goods_receipt_documents.unassigned_clearing_status IS
  'Immutable posting-origin snapshot. Current resolution is derived from append-only goods_receipt_supplier_assignments; posted Receipt is never updated.';
COMMENT ON TABLE public.goods_receipt_unassigned_clearings IS
  'Append-only provisional liability per SUPPLIER_PENDING Receipt line.';
COMMENT ON TABLE public.goods_receipt_supplier_assignments IS
  'Append-only per-line Supplier resolution; does not rewrite the posted Receipt.';

CREATE FUNCTION private.trg_guard_purchase_receipt_assignment_history()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
  IF TG_OP<>'INSERT' THEN RAISE EXCEPTION 'PURCHASE_RECEIPT_ASSIGNMENT_HISTORY_IMMUTABLE'; END IF;
  RETURN NEW;
END
$$;
CREATE TRIGGER guard_goods_receipt_unassigned_clearings
BEFORE UPDATE OR DELETE ON public.goods_receipt_unassigned_clearings
FOR EACH ROW EXECUTE FUNCTION private.trg_guard_purchase_receipt_assignment_history();
CREATE TRIGGER guard_goods_receipt_supplier_assignment_ops
BEFORE UPDATE OR DELETE ON public.goods_receipt_supplier_assignment_operations
FOR EACH ROW EXECUTE FUNCTION private.trg_guard_purchase_receipt_assignment_history();
CREATE TRIGGER guard_goods_receipt_supplier_assignments
BEFORE UPDATE OR DELETE ON public.goods_receipt_supplier_assignments
FOR EACH ROW EXECUTE FUNCTION private.trg_guard_purchase_receipt_assignment_history();

CREATE FUNCTION private.purchase_daily_goods_receipt_snapshot(
  p_company_id uuid,p_receipt_id uuid
) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
  SELECT to_jsonb(receipt)||jsonb_build_object(
    'lines',COALESCE((SELECT jsonb_agg(to_jsonb(line) ORDER BY line.line_no)
      FROM public.goods_receipt_lines line WHERE line.company_id=receipt.company_id
        AND line.document_id=receipt.id),'[]'::jsonb),
    'clearings',COALESCE((SELECT jsonb_agg(to_jsonb(clearing) ORDER BY clearing.created_at,clearing.id)
      FROM public.goods_receipt_unassigned_clearings clearing
      WHERE clearing.company_id=receipt.company_id AND clearing.receipt_id=receipt.id),'[]'::jsonb),
    'assignments',COALESCE((SELECT jsonb_agg(to_jsonb(assignment) ORDER BY assignment.assigned_at,assignment.id)
      FROM public.goods_receipt_supplier_assignments assignment
      WHERE assignment.company_id=receipt.company_id AND assignment.receipt_id=receipt.id),'[]'::jsonb))
  FROM public.goods_receipt_documents receipt
  WHERE receipt.company_id=p_company_id AND receipt.id=p_receipt_id
$$;

CREATE FUNCTION public.save_purchase_daily_goods_receipt(
  p_document_id uuid,p_master_version bigint,p_supplier_order_id uuid,
  p_destination_warehouse_id uuid,p_supplier_delivery_no text,p_notes text,p_lines jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_actor uuid:=auth.uid();v_company uuid:=public.private_active_company_id();
  v_order public.supplier_order_documents%rowtype;v_warehouse public.warehouses%rowtype;
  v_old public.goods_receipt_documents%rowtype;v_before jsonb;v_doc uuid;v_no text;
  v_item jsonb;v_source record;v_uom record;v_line_id uuid;v_n integer:=0;
  v_received numeric:=0;v_good numeric:=0;v_damaged numeric:=0;v_rejected numeric:=0;
  v_received_base numeric;v_good_base numeric;v_damaged_base numeric;v_rejected_base numeric;
  v_prior numeric;v_over numeric;v_base_cost numeric;v_ap numeric:=0;v_version bigint;
  v_cost_source text;v_damaged_warehouse uuid;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  PERFORM private.acp_require_permission_capability(v_company,'purchase.goods_receipts',
    CASE WHEN p_document_id IS NULL THEN 'CREATE_DRAFT' ELSE 'EDIT_DRAFT' END);
  SELECT * INTO v_order FROM public.supplier_order_documents source
  WHERE source.company_id=v_company AND source.id=p_supplier_order_id FOR UPDATE;
  IF NOT FOUND OR v_order.order_source<>'DAILY_REPLENISHMENT'
    OR v_order.document_scope<>'COMPANY_MULTI_WAREHOUSE'
    OR v_order.status NOT IN('CONFIRMED','PARTIALLY_RECEIVED') THEN
    RAISE EXCEPTION 'RECEIVABLE_DAILY_SUPPLIER_ORDER_NOT_FOUND';
  END IF;
  SELECT * INTO v_warehouse FROM public.warehouses warehouse
  WHERE warehouse.company_id=v_company AND warehouse.id=p_destination_warehouse_id
    AND warehouse.is_active AND warehouse.is_purchase_destination
    AND warehouse.warehouse_type IS DISTINCT FROM 'TRANSIT';
  IF NOT FOUND THEN RAISE EXCEPTION 'PURCHASE_RECEIPT_WAREHOUSE_INVALID'; END IF;
  IF p_lines IS NULL OR jsonb_typeof(p_lines)<>'array' OR jsonb_array_length(p_lines)=0 THEN
    RAISE EXCEPTION 'GOODS_RECEIPT_LINES_REQUIRED';
  END IF;
  IF p_document_id IS NULL THEN
    IF p_master_version IS NOT NULL THEN RAISE EXCEPTION 'MASTER_VERSION_NOT_ALLOWED_ON_CREATE'; END IF;
    v_no:='GR-'||to_char(clock_timestamp(),'YYYYMMDD')||'-'||
      lpad(nextval('private.goods_receipt_no_seq')::text,10,'0');
    INSERT INTO public.goods_receipt_documents(company_id,receipt_no,supplier_order_id,
      store_id,warehouse_id,receiving_session_id,receiving_pos_id,received_by,
      supplier_delivery_no,notes,source_channel,receipt_scope,purchase_daily_batch_id,
      supplier_id_snapshot,supplier_assignment_status,unassigned_clearing_status)
    VALUES(v_company,v_no,v_order.id,v_warehouse.store_id,v_warehouse.id,NULL,NULL,v_actor,
      NULLIF(btrim(p_supplier_delivery_no),''),NULLIF(btrim(p_notes),''),'BACKOFFICE',
      'DAILY_WAREHOUSE',v_order.purchase_daily_batch_id,v_order.supplier_id,
      v_order.supplier_assignment_status,
      CASE WHEN v_order.supplier_assignment_status='SUPPLIER_PENDING' THEN 'OPEN'
        ELSE 'NOT_APPLICABLE' END)
    RETURNING id,master_version INTO v_doc,v_version;
  ELSE
    SELECT * INTO v_old FROM public.goods_receipt_documents receipt
    WHERE receipt.company_id=v_company AND receipt.id=p_document_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'GOODS_RECEIPT_NOT_FOUND'; END IF;
    IF v_old.status<>'DRAFT' THEN RAISE EXCEPTION 'FINAL_GOODS_RECEIPT_IMMUTABLE'; END IF;
    IF v_old.receipt_scope<>'DAILY_WAREHOUSE' OR v_old.source_channel<>'BACKOFFICE'
      OR v_old.received_by<>v_actor OR v_old.supplier_order_id<>v_order.id
      OR v_old.warehouse_id<>v_warehouse.id THEN
      RAISE EXCEPTION 'GOODS_RECEIPT_OWNER_SCOPE_INVALID';
    END IF;
    IF p_master_version IS DISTINCT FROM v_old.master_version THEN
      RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
    END IF;
    v_doc:=v_old.id;v_before:=private.purchase_daily_goods_receipt_snapshot(v_company,v_doc);
    DELETE FROM public.goods_receipt_condition_allocations allocation
    USING public.goods_receipt_lines line WHERE allocation.company_id=v_company
      AND line.company_id=allocation.company_id AND line.id=allocation.receipt_line_id
      AND line.document_id=v_doc;
    DELETE FROM public.goods_receipt_lines line
    WHERE line.company_id=v_company AND line.document_id=v_doc;
  END IF;
  FOR v_item IN SELECT item FROM jsonb_array_elements(p_lines) item LOOP
    v_n:=v_n+1;
    SELECT line.*,product.uom_id product_base_uom_id,product.cogs product_cogs,
      product.sku,product.name,base.name base_name
    INTO v_source FROM public.supplier_order_lines line
    JOIN public.products product ON product.company_id=line.company_id
      AND product.id=line.product_id AND product.is_active AND NOT product.is_bundle
    JOIN public.uoms base ON base.company_id=product.company_id
      AND base.id=product.uom_id AND base.is_active
    WHERE line.company_id=v_company AND line.document_id=v_order.id
      AND line.id=NULLIF(v_item->>'supplierOrderLineId','')::uuid
      AND line.destination_warehouse_id=v_warehouse.id;
    IF NOT FOUND THEN RAISE EXCEPTION 'DAILY_SUPPLIER_ORDER_LINE_WAREHOUSE_INVALID'; END IF;
    SELECT product_uom.factor_to_base,uom.name,uom.allow_decimal,uom.decimal_precision
    INTO v_uom FROM public.product_uoms product_uom
    JOIN public.uoms uom ON uom.company_id=product_uom.company_id AND uom.id=product_uom.uom_id
    WHERE product_uom.company_id=v_company AND product_uom.product_id=v_source.product_id
      AND product_uom.uom_id=NULLIF(v_item->>'receivedUomId','')::uuid
      AND product_uom.is_active AND product_uom.purchase_allowed AND uom.is_active;
    IF NOT FOUND THEN RAISE EXCEPTION 'ACTIVE_PURCHASE_PRODUCT_UOM_NOT_FOUND'; END IF;
    IF COALESCE((v_item->>'receivedQty')::numeric,0)<=0 THEN
      RAISE EXCEPTION 'GOODS_RECEIPT_QUANTITY_INVALID'; END IF;
    v_received_base:=(v_item->>'receivedQty')::numeric*v_uom.factor_to_base;
    v_good_base:=COALESCE((v_item->>'acceptedGoodQty')::numeric,
      (v_item->>'receivedQty')::numeric)*v_uom.factor_to_base;
    v_damaged_base:=COALESCE((v_item->>'damagedQty')::numeric,0)*v_uom.factor_to_base;
    v_rejected_base:=COALESCE((v_item->>'rejectedQty')::numeric,0)*v_uom.factor_to_base;
    IF v_good_base<0 OR v_damaged_base<0 OR v_rejected_base<0
      OR v_good_base+v_damaged_base+v_rejected_base<>v_received_base THEN
      RAISE EXCEPTION 'GOODS_RECEIPT_CONDITION_TOTAL_INVALID'; END IF;
    IF NOT v_uom.allow_decimal AND ((v_item->>'receivedQty')::numeric<>trunc((v_item->>'receivedQty')::numeric)
      OR v_good_base/v_uom.factor_to_base<>trunc(v_good_base/v_uom.factor_to_base)
      OR v_damaged_base/v_uom.factor_to_base<>trunc(v_damaged_base/v_uom.factor_to_base)
      OR v_rejected_base/v_uom.factor_to_base<>trunc(v_rejected_base/v_uom.factor_to_base)) THEN
      RAISE EXCEPTION 'PURCHASE_UOM_REQUIRES_INTEGER'; END IF;
    IF v_order.supplier_assignment_status='SUPPLIER_PENDING' THEN
      v_base_cost:=COALESCE(NULLIF(v_item->>'provisionalUnitCost','')::numeric,v_source.product_cogs,0);
      v_cost_source:=CASE WHEN NULLIF(v_item->>'provisionalUnitCost','') IS NULL
        THEN 'PRODUCT_COGS' ELSE 'USER_OVERRIDE' END;
    ELSE
      v_base_cost:=v_source.estimated_unit_price/v_source.factor_to_base_snapshot;
      v_cost_source:='SUPPLIER_ORDER';
    END IF;
    IF v_base_cost<0 THEN RAISE EXCEPTION 'GOODS_RECEIPT_PROVISIONAL_COST_INVALID'; END IF;
    IF v_base_cost=0 AND COALESCE((v_item->>'confirmZeroCost')::boolean,false)=false THEN
      RAISE EXCEPTION 'GOODS_RECEIPT_ZERO_COST_CONFIRMATION_REQUIRED'; END IF;
    SELECT COALESCE(sum(receipt_line.received_base_qty),0) INTO v_prior
    FROM public.goods_receipt_lines receipt_line
    JOIN public.goods_receipt_documents receipt ON receipt.company_id=receipt_line.company_id
      AND receipt.id=receipt_line.document_id AND receipt.status='POSTED'
    WHERE receipt_line.company_id=v_company
      AND receipt_line.supplier_order_line_id=v_source.id;
    v_over:=GREATEST(v_prior+v_received_base-v_source.ordered_base_qty,0);
    INSERT INTO public.goods_receipt_lines(company_id,document_id,line_no,client_line_key,
      supplier_order_line_id,product_id,received_uom_id,received_qty,factor_to_base_snapshot,
      received_base_qty,accepted_good_qty,damaged_qty,rejected_qty,accepted_good_base_qty,
      damaged_base_qty,rejected_base_qty,estimated_unit_price_snapshot,
      estimated_base_unit_cost,provisional_ap_amount,is_over_received,over_received_base_qty,
      product_sku_snapshot,product_name_snapshot,received_uom_name_snapshot,
      base_uom_id,base_uom_name_snapshot,provisional_cost_source)
    VALUES(v_company,v_doc,v_n,COALESCE(NULLIF(v_item->>'clientLineKey','')::uuid,gen_random_uuid()),
      v_source.id,v_source.product_id,NULLIF(v_item->>'receivedUomId','')::uuid,
      (v_item->>'receivedQty')::numeric,v_uom.factor_to_base,v_received_base,
      v_good_base/v_uom.factor_to_base,v_damaged_base/v_uom.factor_to_base,
      v_rejected_base/v_uom.factor_to_base,v_good_base,v_damaged_base,v_rejected_base,
      v_base_cost*v_uom.factor_to_base,v_base_cost,
      round((v_good_base+v_damaged_base)*v_base_cost,4),v_over>0,v_over,
      v_source.sku,v_source.name,v_uom.name,v_source.product_base_uom_id,
      v_source.base_name,v_cost_source) RETURNING id INTO v_line_id;
    IF v_good_base>0 THEN
      INSERT INTO public.goods_receipt_condition_allocations(company_id,receipt_line_id,
        condition_type,warehouse_id,quantity_base)
      VALUES(v_company,v_line_id,'GOOD',v_warehouse.id,v_good_base);
    END IF;
    IF v_damaged_base>0 THEN
      SELECT damaged.id INTO v_damaged_warehouse FROM public.warehouses damaged
      WHERE damaged.company_id=v_company AND damaged.is_active
        AND damaged.warehouse_type='DAMAGED'
        AND (damaged.store_id=v_warehouse.store_id OR damaged.store_id IS NULL)
      ORDER BY (damaged.store_id=v_warehouse.store_id) DESC,damaged.id LIMIT 1;
      IF v_damaged_warehouse IS NULL THEN RAISE EXCEPTION 'ACTIVE_DAMAGED_WAREHOUSE_NOT_FOUND'; END IF;
      INSERT INTO public.goods_receipt_condition_allocations(company_id,receipt_line_id,
        condition_type,warehouse_id,quantity_base)
      VALUES(v_company,v_line_id,'DAMAGED',v_damaged_warehouse,v_damaged_base);
    END IF;
    IF v_rejected_base>0 THEN
      INSERT INTO public.goods_receipt_condition_allocations(company_id,receipt_line_id,
        condition_type,warehouse_id,quantity_base)
      VALUES(v_company,v_line_id,'REJECTED',NULL,v_rejected_base);
    END IF;
    v_received:=v_received+v_received_base;v_good:=v_good+v_good_base;
    v_damaged:=v_damaged+v_damaged_base;v_rejected:=v_rejected+v_rejected_base;
    v_ap:=v_ap+round((v_good_base+v_damaged_base)*v_base_cost,4);
  END LOOP;
  UPDATE public.goods_receipt_documents receipt SET
    supplier_delivery_no=NULLIF(btrim(p_supplier_delivery_no),''),notes=NULLIF(btrim(p_notes),''),
    line_count=v_n,received_total_base_qty=v_received,accepted_total_base_qty=v_good,
    damaged_total_base_qty=v_damaged,rejected_total_base_qty=v_rejected,
    provisional_ap_total=v_ap,has_over_receipt=EXISTS(SELECT 1
      FROM public.goods_receipt_lines line WHERE line.company_id=v_company
        AND line.document_id=v_doc AND line.is_over_received),
    master_version=CASE WHEN p_document_id IS NULL THEN receipt.master_version
      ELSE receipt.master_version+1 END,updated_at=clock_timestamp()
  WHERE receipt.company_id=v_company AND receipt.id=v_doc
  RETURNING master_version INTO v_version;
  INSERT INTO public.goods_receipt_audit(company_id,document_id,action,actor_id,
    before_state,after_state)
  SELECT v_company,v_doc,CASE WHEN p_document_id IS NULL THEN 'CREATE' ELSE 'UPDATE' END,
    v_actor,v_before,private.purchase_daily_goods_receipt_snapshot(v_company,v_doc);
  RETURN jsonb_build_object('documentId',v_doc,'receiptNo',COALESCE(v_no,v_old.receipt_no),
    'status','DRAFT','masterVersion',v_version,'warehouseId',v_warehouse.id,
    'supplierAssignmentStatus',v_order.supplier_assignment_status);
END
$$;

CREATE FUNCTION public.post_purchase_daily_goods_receipt(
  p_document_id uuid,p_master_version bigint,p_idempotency_key uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_actor uuid:=auth.uid();v_company uuid:=public.private_active_company_id();
  v_receipt public.goods_receipt_documents%rowtype;v_order public.supplier_order_documents%rowtype;
  v_allocation record;v_line public.goods_receipt_lines%rowtype;v_stock_after numeric;
  v_batch uuid;v_event uuid;v_category uuid;v_inventory_account uuid;
  v_clearing_account uuid;v_before jsonb;v_now timestamptz:=clock_timestamp();
  v_version bigint;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF p_idempotency_key IS NULL THEN RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED'; END IF;
  PERFORM private.acp_require_permission_capability(v_company,'purchase.goods_receipts','POST');
  SELECT * INTO v_receipt FROM public.goods_receipt_documents receipt
  WHERE receipt.company_id=v_company AND receipt.id=p_document_id FOR UPDATE;
  IF NOT FOUND OR v_receipt.receipt_scope<>'DAILY_WAREHOUSE'
    OR v_receipt.source_channel<>'BACKOFFICE' THEN RAISE EXCEPTION 'DAILY_GOODS_RECEIPT_NOT_FOUND'; END IF;
  IF v_receipt.status='POSTED' THEN
    IF v_receipt.posting_idempotency_key=p_idempotency_key THEN
      RETURN jsonb_build_object('documentId',v_receipt.id,'receiptNo',v_receipt.receipt_no,
        'status','POSTED','masterVersion',v_receipt.master_version,
        'financialEventId',v_receipt.financial_event_id,'idempotentReplay',true);
    END IF;
    RAISE EXCEPTION 'GOODS_RECEIPT_ALREADY_POSTED';
  END IF;
  IF v_receipt.status<>'DRAFT' THEN RAISE EXCEPTION 'GOODS_RECEIPT_NOT_POSTABLE'; END IF;
  IF p_master_version IS DISTINCT FROM v_receipt.master_version THEN
    RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
  IF v_receipt.received_by<>v_actor THEN RAISE EXCEPTION 'GOODS_RECEIPT_OWNER_SCOPE_INVALID'; END IF;
  IF v_receipt.line_count<=0 THEN RAISE EXCEPTION 'GOODS_RECEIPT_LINES_REQUIRED'; END IF;
  SELECT * INTO v_order FROM public.supplier_order_documents source
  WHERE source.company_id=v_company AND source.id=v_receipt.supplier_order_id FOR UPDATE;
  IF NOT FOUND OR v_order.order_source<>'DAILY_REPLENISHMENT'
    OR v_order.status NOT IN('CONFIRMED','PARTIALLY_RECEIVED') THEN
    RAISE EXCEPTION 'RECEIVABLE_DAILY_SUPPLIER_ORDER_NOT_FOUND'; END IF;
  IF v_receipt.supplier_assignment_status='ASSIGNED' THEN
    IF v_order.supplier_id IS DISTINCT FROM v_receipt.supplier_id_snapshot THEN
      RAISE EXCEPTION 'GOODS_RECEIPT_SUPPLIER_SNAPSHOT_MISMATCH'; END IF;
    RETURN public.post_backoffice_goods_receipt(
      p_document_id,p_master_version,p_idempotency_key);
  END IF;
  IF v_order.supplier_assignment_status<>'SUPPLIER_PENDING' OR v_order.supplier_id IS NOT NULL
    OR v_receipt.supplier_id_snapshot IS NOT NULL THEN
    RAISE EXCEPTION 'GOODS_RECEIPT_PENDING_SUPPLIER_SHAPE_INVALID'; END IF;
  SELECT category.id INTO v_category FROM public.transaction_categories category
  WHERE category.company_id=v_company AND category.system_key='GOODS_RECEIPT'
    AND category.is_active ORDER BY category.id LIMIT 1;
  IF v_category IS NULL THEN RAISE EXCEPTION 'GOODS_RECEIPT_TRANSACTION_CATEGORY_NOT_FOUND'; END IF;
  v_inventory_account:=private.resolve_opening_stock_account(
    v_company,v_category,'INVENTORY_ASSET',v_now);
  v_clearing_account:=private.resolve_opening_stock_account(
    v_company,v_category,'PURCHASE_UNASSIGNED_CLEARING',v_now);
  v_before:=private.purchase_daily_goods_receipt_snapshot(v_company,v_receipt.id);

  FOR v_allocation IN SELECT allocation.*,line.product_id,line.base_uom_id,
      line.base_uom_name_snapshot,line.estimated_base_unit_cost,line.supplier_order_line_id
    FROM public.goods_receipt_condition_allocations allocation
    JOIN public.goods_receipt_lines line ON line.company_id=allocation.company_id
      AND line.id=allocation.receipt_line_id
    WHERE allocation.company_id=v_company AND line.document_id=v_receipt.id
      AND allocation.condition_type IN('GOOD','DAMAGED')
    ORDER BY allocation.warehouse_id,line.product_id,allocation.id
  LOOP
    PERFORM pg_advisory_xact_lock(hashtextextended(v_company::text||':STOCK:'||
      v_allocation.product_id::text||':'||v_allocation.warehouse_id::text,0));
    INSERT INTO public.product_stocks(product_id,warehouse_id,stock_qty,company_id)
    VALUES(v_allocation.product_id,v_allocation.warehouse_id,
      v_allocation.quantity_base,v_company)
    ON CONFLICT(product_id,warehouse_id) DO UPDATE SET
      stock_qty=public.product_stocks.stock_qty+excluded.stock_qty,updated_at=v_now
    RETURNING stock_qty INTO v_stock_after;
    INSERT INTO public.product_batches(product_id,warehouse_id,purchase_detail_id,
      qty_purchased,qty_remaining,cogs_unit,company_id,goods_receipt_line_id,
      supplier_order_line_id,goods_receipt_condition_allocation_id)
    VALUES(v_allocation.product_id,v_allocation.warehouse_id,NULL,
      v_allocation.quantity_base,v_allocation.quantity_base,
      v_allocation.estimated_base_unit_cost,v_company,v_allocation.receipt_line_id,
      v_allocation.supplier_order_line_id,v_allocation.id) RETURNING id INTO v_batch;
    UPDATE public.goods_receipt_condition_allocations SET product_batch_id=v_batch
    WHERE company_id=v_company AND id=v_allocation.id;
    INSERT INTO public.stock_movements(product_id,warehouse_id,qty_change,movement_type,
      reference_table,reference_id,company_id,base_uom_id,base_uom_name_snapshot,
      balance_after_base_qty,actor_id,posted_at,movement_status,source_line_id,notes)
    VALUES(v_allocation.product_id,v_allocation.warehouse_id,v_allocation.quantity_base,
      'PURCHASE'::public.stock_movement_type,'goods_receipt_documents',v_receipt.id,
      v_company,v_allocation.base_uom_id,v_allocation.base_uom_name_snapshot,
      v_stock_after,v_actor,v_now,'POSTED',v_allocation.id,
      'Goods Receipt SUPPLIER_PENDING '||v_allocation.condition_type);
  END LOOP;
  FOR v_line IN SELECT * FROM public.goods_receipt_lines line
    WHERE line.company_id=v_company AND line.document_id=v_receipt.id
  LOOP
    INSERT INTO public.goods_receipt_unassigned_clearings(company_id,receipt_id,
      receipt_line_id,clearing_account_id,amount)
    VALUES(v_company,v_receipt.id,v_line.id,v_clearing_account,v_line.provisional_ap_amount);
  END LOOP;
  INSERT INTO public.financial_events(event_code,event_type,source_table,source_id,
    root_sales_id,event_date,event_version,idempotency_key,amounts,status,error_message,
    created_by,company_id,store_id,system_event_key,transaction_category_id)
  VALUES('GR-PENDING-'||replace(v_receipt.id::text,'-',''),
    'PURCHASE_POSTED'::public.event_type,'goods_receipt_documents',v_receipt.id,NULL,
    v_now,1,'GOODS_RECEIPT_PENDING|'||v_company::text||'|'||p_idempotency_key::text,
    jsonb_build_object('inventoryDebit',v_receipt.provisional_ap_total,
      'supplierApProvisionalCredit',0,
      'unassignedSupplierClearingCredit',v_receipt.provisional_ap_total,
      'inventoryAccountId',v_inventory_account,
      'unassignedSupplierClearingAccountId',v_clearing_account,
      'acceptedBaseQty',v_receipt.accepted_total_base_qty,
      'damagedBaseQty',v_receipt.damaged_total_base_qty,
      'rejectedBaseQty',v_receipt.rejected_total_base_qty,
      'hasOverReceipt',v_receipt.has_over_receipt,
      'financePostingState','HOLD_FOR_SUPPLIER_ASSIGNMENT'),
    'HOLD'::public.event_status,'SUPPLIER_ASSIGNMENT_REQUIRED',v_actor,v_company,
    v_receipt.store_id,'GOODS_RECEIPT',v_category) RETURNING id INTO v_event;
  UPDATE public.goods_receipt_documents receipt SET status='POSTED',
    posting_idempotency_key=p_idempotency_key,financial_event_id=v_event,
    posted_by=v_actor,posted_at=v_now,master_version=master_version+1,
    updated_at=v_now WHERE receipt.company_id=v_company AND receipt.id=v_receipt.id
  RETURNING master_version INTO v_version;
  UPDATE public.supplier_order_documents source SET status=CASE WHEN NOT EXISTS(
      SELECT 1 FROM public.supplier_order_lines order_line
      WHERE order_line.company_id=v_company AND order_line.document_id=source.id
        AND COALESCE((SELECT sum(receipt_line.received_base_qty)
          FROM public.goods_receipt_lines receipt_line
          JOIN public.goods_receipt_documents posted ON posted.company_id=receipt_line.company_id
            AND posted.id=receipt_line.document_id AND posted.status='POSTED'
          WHERE receipt_line.company_id=v_company
            AND receipt_line.supplier_order_line_id=order_line.id),0)<order_line.ordered_base_qty)
      THEN 'RECEIVED' ELSE 'PARTIALLY_RECEIVED' END,
    master_version=master_version+1,updated_at=v_now
  WHERE source.company_id=v_company AND source.id=v_order.id;
  INSERT INTO public.goods_receipt_audit(company_id,document_id,action,actor_id,
    before_state,after_state)
  VALUES(v_company,v_receipt.id,'POST',v_actor,v_before,
    private.purchase_daily_goods_receipt_snapshot(v_company,v_receipt.id));
  RETURN jsonb_build_object('documentId',v_receipt.id,'receiptNo',v_receipt.receipt_no,
    'status','POSTED','masterVersion',v_version,'financialEventId',v_event,
    'supplierAssignmentStatus','SUPPLIER_PENDING','financePostingState',
    'HOLD_FOR_SUPPLIER_ASSIGNMENT','idempotentReplay',false);
END
$$;

CREATE FUNCTION public.assign_purchase_daily_receipt_suppliers(
  p_receipt_id uuid,p_expected_master_version bigint,p_operation_id uuid,p_assignments jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_actor uuid:=auth.uid();v_company uuid:=public.private_active_company_id();
  v_receipt public.goods_receipt_documents%rowtype;v_existing record;v_hash text;
  v_item jsonb;v_line public.goods_receipt_lines%rowtype;v_clearing record;
  v_supplier uuid;v_event uuid;v_category uuid;v_ap_account uuid;v_clearing_account uuid;
  v_total numeric:=0;v_count integer:=0;v_result jsonb;v_now timestamptz:=clock_timestamp();
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF p_operation_id IS NULL THEN RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED'; END IF;
  IF p_assignments IS NULL OR jsonb_typeof(p_assignments)<>'array'
    OR jsonb_array_length(p_assignments)=0 THEN RAISE EXCEPTION 'SUPPLIER_ASSIGNMENTS_REQUIRED'; END IF;
  PERFORM private.acp_require_permission_capability(v_company,'purchase.supplier_orders','EDIT_DRAFT');
  v_hash:=md5(jsonb_build_object('receiptId',p_receipt_id,
    'expectedVersion',p_expected_master_version,'assignments',p_assignments)::text);
  SELECT * INTO v_existing FROM public.goods_receipt_supplier_assignment_operations operation
  WHERE operation.company_id=v_company AND operation.id=p_operation_id;
  IF FOUND THEN
    IF v_existing.request_hash<>v_hash OR v_existing.receipt_id<>p_receipt_id THEN
      RAISE EXCEPTION 'IDEMPOTENCY_KEY_CONFLICT'; END IF;
    RETURN v_existing.result_snapshot||jsonb_build_object('exactRetry',true);
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(
    v_company::text||':RECEIPT_SUPPLIER_ASSIGNMENT:'||p_receipt_id::text,0));
  SELECT * INTO v_receipt FROM public.goods_receipt_documents receipt
  WHERE receipt.company_id=v_company AND receipt.id=p_receipt_id FOR UPDATE;
  IF NOT FOUND OR v_receipt.status<>'POSTED' OR v_receipt.receipt_scope<>'DAILY_WAREHOUSE'
    OR v_receipt.supplier_assignment_status<>'SUPPLIER_PENDING'
    OR v_receipt.unassigned_clearing_status<>'OPEN' THEN
    RAISE EXCEPTION 'POSTED_PENDING_SUPPLIER_RECEIPT_REQUIRED'; END IF;
  IF v_receipt.master_version<>p_expected_master_version THEN
    RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
  IF jsonb_array_length(p_assignments)<>
       (SELECT count(DISTINCT NULLIF(item->>'receiptLineId','')::uuid)
        FROM jsonb_array_elements(p_assignments) item)
    OR jsonb_array_length(p_assignments)<>
       (SELECT count(*) FROM public.goods_receipt_lines line
        WHERE line.company_id=v_company AND line.document_id=p_receipt_id) THEN
    RAISE EXCEPTION 'ALL_RECEIPT_LINES_REQUIRE_SUPPLIER'; END IF;
  SELECT category.id INTO v_category FROM public.transaction_categories category
  WHERE category.company_id=v_company
    AND category.system_key='GOODS_RECEIPT_SUPPLIER_ASSIGNMENT'
    AND category.is_active ORDER BY category.id LIMIT 1;
  IF v_category IS NULL THEN RAISE EXCEPTION 'GOODS_RECEIPT_TRANSACTION_CATEGORY_NOT_FOUND'; END IF;
  v_ap_account:=private.resolve_opening_stock_account(
    v_company,v_category,'SUPPLIER_AP_PROVISIONAL',v_now);
  v_clearing_account:=private.resolve_opening_stock_account(
    v_company,v_category,'PURCHASE_UNASSIGNED_CLEARING',v_now);
  v_result:=jsonb_build_object('receiptId',p_receipt_id,'status','ASSIGNED',
    'exactRetry',false);
  -- First pass validates the full payload and computes its immutable amount.
  FOR v_item IN SELECT item FROM jsonb_array_elements(p_assignments) item LOOP
    SELECT * INTO v_line FROM public.goods_receipt_lines line
    WHERE line.company_id=v_company AND line.document_id=p_receipt_id
      AND line.id=NULLIF(v_item->>'receiptLineId','')::uuid;
    IF NOT FOUND THEN RAISE EXCEPTION 'GOODS_RECEIPT_LINE_NOT_FOUND'; END IF;
    v_supplier:=NULLIF(v_item->>'supplierId','')::uuid;
    IF NOT EXISTS(SELECT 1 FROM public.suppliers supplier
        WHERE supplier.company_id=v_company AND supplier.id=v_supplier
          AND supplier.is_active) THEN RAISE EXCEPTION 'ACTIVE_SUPPLIER_NOT_FOUND'; END IF;
    SELECT * INTO v_clearing FROM public.goods_receipt_unassigned_clearings clearing
    WHERE clearing.company_id=v_company AND clearing.receipt_id=p_receipt_id
      AND clearing.receipt_line_id=v_line.id;
    IF NOT FOUND THEN RAISE EXCEPTION 'GOODS_RECEIPT_CLEARING_NOT_FOUND'; END IF;
    IF EXISTS(SELECT 1 FROM public.goods_receipt_supplier_assignments assignment
        WHERE assignment.company_id=v_company AND assignment.receipt_line_id=v_line.id) THEN
      RAISE EXCEPTION 'GOODS_RECEIPT_LINE_SUPPLIER_ALREADY_ASSIGNED'; END IF;
    v_total:=v_total+v_clearing.amount;v_count:=v_count+1;
  END LOOP;
  INSERT INTO public.financial_events(event_code,event_type,source_table,source_id,
    root_sales_id,event_date,event_version,idempotency_key,amounts,status,error_message,
    created_by,company_id,store_id,system_event_key,transaction_category_id)
  VALUES('GR-SUPPLIER-'||replace(p_operation_id::text,'-',''),
    'PURCHASE_POSTED'::public.event_type,'goods_receipt_supplier_assignment_operations',
    p_operation_id,NULL,v_now,1,'GOODS_RECEIPT_SUPPLIER_ASSIGNMENT|'||v_company::text||'|'||p_operation_id::text,
    jsonb_build_object('unassignedSupplierClearingDebit',round(v_total,4),
      'supplierApProvisionalCredit',round(v_total,4),
      'unassignedSupplierClearingAccountId',v_clearing_account,
      'supplierApProvisionalAccountId',v_ap_account,
      'receiptId',p_receipt_id,'assignmentCount',v_count,
      'financePostingState','HOLD_FOR_STEP_6_RECLASSIFICATION'),
    'HOLD'::public.event_status,'SUPPLIER_ASSIGNMENT_RECLASSIFICATION_PENDING',
    v_actor,v_company,v_receipt.store_id,'GOODS_RECEIPT_SUPPLIER_ASSIGNMENT',v_category)
  RETURNING id INTO v_event;
  v_result:=v_result||jsonb_build_object('assignmentCount',v_count,
    'assignedAmount',round(v_total,4),'financialEventId',v_event,
    'financePostingState','HOLD_FOR_STEP_6_RECLASSIFICATION');
  INSERT INTO public.goods_receipt_supplier_assignment_operations(id,company_id,
    receipt_id,request_hash,result_snapshot,actor_id,financial_event_id)
  VALUES(p_operation_id,v_company,p_receipt_id,v_hash,v_result,v_actor,v_event);
  -- Second pass appends assignments only after every line and Supplier passed.
  FOR v_item IN SELECT item FROM jsonb_array_elements(p_assignments) item LOOP
    SELECT * INTO v_line FROM public.goods_receipt_lines line
    WHERE line.company_id=v_company AND line.document_id=p_receipt_id
      AND line.id=NULLIF(v_item->>'receiptLineId','')::uuid;
    SELECT * INTO v_clearing FROM public.goods_receipt_unassigned_clearings clearing
    WHERE clearing.company_id=v_company AND clearing.receipt_id=p_receipt_id
      AND clearing.receipt_line_id=v_line.id;
    v_supplier:=NULLIF(v_item->>'supplierId','')::uuid;
    INSERT INTO public.goods_receipt_supplier_assignments(company_id,receipt_id,
      receipt_line_id,clearing_id,supplier_id,operation_id,assigned_amount,assigned_by)
    VALUES(v_company,p_receipt_id,v_line.id,v_clearing.id,v_supplier,p_operation_id,
      v_clearing.amount,v_actor);
  END LOOP;
  RETURN v_result;
END
$$;

-- Keep supplier-pending Goods Receipt events out of the legacy Purchase/AP
-- queue. Their reclassification event is completed by Step 6 after assignment.
CREATE OR REPLACE FUNCTION public.preview_purchase_ap_posting_queue(
  p_limit integer DEFAULT 100
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_actor uuid:=auth.uid();v_company uuid:=public.private_active_company_id();
  v_run_id uuid:=gen_random_uuid();v_run public.finance_posting_queue_runs%rowtype;
  v_count integer;v_hash text;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
  IF p_limit IS NULL OR p_limit<1 OR p_limit>500 THEN RAISE EXCEPTION 'QUEUE_PREVIEW_LIMIT_INVALID'; END IF;
  IF NOT private.g6_finance_queue_role_allowed(v_company) THEN RAISE EXCEPTION 'FINANCE_QUEUE_ROLE_REQUIRED'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('G6_FINANCE_QUEUE|'||v_company,0));
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs run
      WHERE run.company_id=v_company AND run.status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'ACTIVE_FINANCE_POSTING_QUEUE_ALREADY_EXISTS'; END IF;
  INSERT INTO public.finance_posting_queue_runs(id,company_id,queue_no,scope_system_key,
    status,preview_limit,preview_hash,created_by)
  VALUES(v_run_id,v_company,'FQ-'||to_char(clock_timestamp(),'YYYYMMDD')||'-'||
    upper(substr(replace(v_run_id::text,'-',''),1,8)),'PURCHASE_AP','PREVIEWED',p_limit,
    md5('EMPTY|'||v_company||'|'||v_run_id),v_actor);
  INSERT INTO public.finance_posting_queue_items(company_id,queue_run_id,line_no,
    financial_event_id,event_version_snapshot,event_code_snapshot,system_event_key_snapshot,
    source_table_snapshot,source_id_snapshot,transaction_category_id_snapshot,event_date_snapshot)
  SELECT event.company_id,v_run_id,row_number() OVER(ORDER BY event.event_date,event.id)::integer,
    event.id,event.event_version,event.event_code,event.system_event_key,event.source_table,
    event.source_id,event.transaction_category_id,event.event_date
  FROM public.financial_events event
  WHERE event.company_id=v_company AND event.status='HOLD'::public.event_status
    AND COALESCE(event.amounts->>'financePostingState','') NOT IN(
      'HOLD_FOR_SUPPLIER_ASSIGNMENT','HOLD_FOR_STEP_6_RECLASSIFICATION')
    AND ((event.system_event_key='GOODS_RECEIPT' AND event.event_type::text='PURCHASE_POSTED'
        AND event.source_table='goods_receipt_documents'
        AND EXISTS(SELECT 1 FROM public.goods_receipt_documents receipt
          WHERE receipt.company_id=event.company_id AND receipt.id=event.source_id
            AND receipt.status='POSTED' AND receipt.financial_event_id=event.id))
      OR (event.system_event_key='SUPPLIER_INVOICE' AND event.event_type::text='SUPPLIER_INVOICE_VALIDATED'
        AND event.source_table='supplier_invoice_documents'
        AND EXISTS(SELECT 1 FROM public.supplier_invoice_documents invoice
          WHERE invoice.company_id=event.company_id AND invoice.id=event.source_id
            AND invoice.status='VALIDATED' AND invoice.financial_event_id=event.id))
      OR (event.system_event_key='SUPPLIER_PAYMENT' AND event.event_type::text='SUPPLIER_PAYMENT_VALIDATED'
        AND event.source_table='supplier_payment_documents'
        AND EXISTS(SELECT 1 FROM public.supplier_payment_documents payment
          WHERE payment.company_id=event.company_id AND payment.id=event.source_id
            AND payment.status='VALIDATED' AND payment.financial_event_id=event.id)))
    AND NOT EXISTS(SELECT 1 FROM public.finance_journals journal
      WHERE journal.company_id=event.company_id AND journal.financial_event_id=event.id)
  ORDER BY event.event_date,event.id LIMIT p_limit;
  GET DIAGNOSTICS v_count=ROW_COUNT;
  IF v_count=0 THEN RAISE EXCEPTION 'NO_SUPPORTED_HOLD_EVENTS'; END IF;
  SELECT md5(string_agg(item.financial_event_id||':'||item.event_version_snapshot,
    '|' ORDER BY item.line_no)) INTO v_hash FROM public.finance_posting_queue_items item
  WHERE item.company_id=v_company AND item.queue_run_id=v_run_id;
  UPDATE public.finance_posting_queue_runs SET previewed_event_count=v_count,
    preview_hash=v_hash WHERE company_id=v_company AND id=v_run_id RETURNING * INTO v_run;
  INSERT INTO public.finance_posting_queue_audit(company_id,queue_run_id,action,actor_id,after_state)
  VALUES(v_company,v_run_id,'PREVIEW',v_actor,jsonb_build_object('status',v_run.status,
    'masterVersion',v_run.master_version,'eventCount',v_count,'previewHash',v_hash,
    'scopeSystemKey','PURCHASE_AP'));
  RETURN jsonb_build_object('queueRunId',v_run.id,'queueNo',v_run.queue_no,
    'status',v_run.status,'masterVersion',v_run.master_version,'eventCount',v_count,
    'previewHash',v_hash,'scopeSystemKey','PURCHASE_AP');
END
$$;

ALTER TABLE public.goods_receipt_unassigned_clearings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.goods_receipt_supplier_assignment_operations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.goods_receipt_supplier_assignments ENABLE ROW LEVEL SECURITY;
CREATE POLICY goods_receipt_unassigned_clearings_read
  ON public.goods_receipt_unassigned_clearings FOR SELECT TO authenticated
  USING(public.private_request_company_matches(company_id));
CREATE POLICY goods_receipt_supplier_assignment_ops_read
  ON public.goods_receipt_supplier_assignment_operations FOR SELECT TO authenticated
  USING(public.private_request_company_matches(company_id));
CREATE POLICY goods_receipt_supplier_assignments_read
  ON public.goods_receipt_supplier_assignments FOR SELECT TO authenticated
  USING(public.private_request_company_matches(company_id));

REVOKE ALL ON TABLE public.goods_receipt_unassigned_clearings,
  public.goods_receipt_supplier_assignment_operations,
  public.goods_receipt_supplier_assignments FROM PUBLIC,anon,authenticated;
GRANT SELECT ON TABLE public.goods_receipt_unassigned_clearings,
  public.goods_receipt_supplier_assignment_operations,
  public.goods_receipt_supplier_assignments TO authenticated;
GRANT SELECT,INSERT,UPDATE,DELETE ON TABLE public.goods_receipt_unassigned_clearings,
  public.goods_receipt_supplier_assignment_operations,
  public.goods_receipt_supplier_assignments TO service_role;
REVOKE ALL ON FUNCTION private.trg_guard_purchase_receipt_assignment_history(),
  private.purchase_daily_goods_receipt_snapshot(uuid,uuid)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.trg_guard_purchase_receipt_assignment_history(),
  private.purchase_daily_goods_receipt_snapshot(uuid,uuid) TO service_role;
REVOKE ALL ON FUNCTION public.save_purchase_daily_goods_receipt(uuid,bigint,uuid,uuid,text,text,jsonb),
  public.post_purchase_daily_goods_receipt(uuid,bigint,uuid),
  public.assign_purchase_daily_receipt_suppliers(uuid,bigint,uuid,jsonb)
  FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.save_purchase_daily_goods_receipt(uuid,bigint,uuid,uuid,text,text,jsonb),
  public.post_purchase_daily_goods_receipt(uuid,bigint,uuid),
  public.assign_purchase_daily_receipt_suppliers(uuid,bigint,uuid,jsonb)
  TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260914100000','purchase_daily_multiwarehouse_receipt',
  'Step 5 multi-Warehouse daily Receipt, Product COGS or editable provisional cost, append-only unassigned Supplier clearing and assignment lineage; legacy Receipt remains canonical');
COMMIT;
