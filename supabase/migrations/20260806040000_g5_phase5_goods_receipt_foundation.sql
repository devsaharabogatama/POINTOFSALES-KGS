-- KGS POS G5 phase 5: canonical Goods Receipt foundation.
BEGIN;

DO $guard$ BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260806010000')
    OR NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260805234500')
  THEN RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: G5 order or negative-stock chain missing'; END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260806040000')
  THEN RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260806040000'; END IF;
  IF to_regclass('public.goods_receipt_documents') IS NOT NULL
  THEN RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Goods Receipt objects already exist'; END IF;
END $guard$;

ALTER TYPE public.event_type ADD VALUE IF NOT EXISTS 'PURCHASE_POSTED';

CREATE SEQUENCE private.goods_receipt_no_seq AS BIGINT START 1;
REVOKE ALL ON SEQUENCE private.goods_receipt_no_seq FROM PUBLIC,anon,authenticated;
GRANT USAGE,SELECT ON SEQUENCE private.goods_receipt_no_seq TO service_role;

CREATE TABLE public.goods_receipt_documents(
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(), company_id UUID NOT NULL,
 receipt_no TEXT NOT NULL, supplier_order_id UUID NOT NULL, store_id UUID NOT NULL,
 warehouse_id UUID NOT NULL, receiving_session_id UUID NOT NULL,
 receiving_pos_id UUID NOT NULL, received_by UUID NOT NULL REFERENCES public.profiles(id),
 received_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(), supplier_delivery_no TEXT,
 notes TEXT,status TEXT NOT NULL DEFAULT 'DRAFT',line_count INTEGER NOT NULL DEFAULT 0,
 received_total_base_qty NUMERIC(24,6) NOT NULL DEFAULT 0,
 accepted_total_base_qty NUMERIC(24,6) NOT NULL DEFAULT 0,
 damaged_total_base_qty NUMERIC(24,6) NOT NULL DEFAULT 0,
 rejected_total_base_qty NUMERIC(24,6) NOT NULL DEFAULT 0,
 provisional_ap_total NUMERIC(20,4) NOT NULL DEFAULT 0,
 has_over_receipt BOOLEAN NOT NULL DEFAULT FALSE,posting_idempotency_key UUID,
 financial_event_id UUID REFERENCES public.financial_events(id) ON DELETE RESTRICT,
 posted_by UUID REFERENCES public.profiles(id),posted_at TIMESTAMPTZ,
 canceled_by UUID REFERENCES public.profiles(id),canceled_at TIMESTAMPTZ,
 master_version BIGINT NOT NULL DEFAULT 1,created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
 updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
 UNIQUE(company_id,id),UNIQUE(company_id,receipt_no),UNIQUE(company_id,posting_idempotency_key),
 FOREIGN KEY(company_id,supplier_order_id) REFERENCES public.supplier_order_documents(company_id,id) ON DELETE RESTRICT,
 FOREIGN KEY(company_id,store_id) REFERENCES public.stores(company_id,id) ON DELETE RESTRICT,
 FOREIGN KEY(company_id,warehouse_id) REFERENCES public.warehouses(company_id,id) ON DELETE RESTRICT,
 FOREIGN KEY(company_id,receiving_session_id) REFERENCES public.cashier_sessions(company_id,id) ON DELETE RESTRICT,
 FOREIGN KEY(company_id,receiving_pos_id) REFERENCES public.pos_terminals(company_id,id) ON DELETE RESTRICT,
 CHECK(btrim(receipt_no)<>''),CHECK(status IN('DRAFT','POSTED','CANCELED')),
 CHECK(line_count>=0 AND received_total_base_qty>=0 AND accepted_total_base_qty>=0
   AND damaged_total_base_qty>=0 AND rejected_total_base_qty>=0 AND provisional_ap_total>=0),
 CHECK(master_version>0),
 CHECK((status='DRAFT' AND posted_at IS NULL AND posted_by IS NULL AND posting_idempotency_key IS NULL AND financial_event_id IS NULL)
   OR status='CANCELED' OR (posted_at IS NOT NULL AND posted_by IS NOT NULL AND posting_idempotency_key IS NOT NULL AND financial_event_id IS NOT NULL)),
 CHECK((status='CANCELED' AND canceled_at IS NOT NULL AND canceled_by IS NOT NULL) OR (status<>'CANCELED' AND canceled_at IS NULL AND canceled_by IS NULL))
);

CREATE TABLE public.goods_receipt_lines(
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(),company_id UUID NOT NULL,document_id UUID NOT NULL,
 line_no INTEGER NOT NULL,client_line_key UUID NOT NULL,supplier_order_line_id UUID NOT NULL,
 product_id UUID NOT NULL,received_uom_id UUID NOT NULL,received_qty NUMERIC(24,6) NOT NULL,
 factor_to_base_snapshot NUMERIC(24,6) NOT NULL,received_base_qty NUMERIC(24,6) NOT NULL,
 accepted_good_qty NUMERIC(24,6) NOT NULL,damaged_qty NUMERIC(24,6) NOT NULL,
 rejected_qty NUMERIC(24,6) NOT NULL,accepted_good_base_qty NUMERIC(24,6) NOT NULL,
 damaged_base_qty NUMERIC(24,6) NOT NULL,rejected_base_qty NUMERIC(24,6) NOT NULL,
 estimated_unit_price_snapshot NUMERIC(20,4) NOT NULL,estimated_base_unit_cost NUMERIC(20,4) NOT NULL,
 provisional_ap_amount NUMERIC(20,4) NOT NULL,is_over_received BOOLEAN NOT NULL,
 over_received_base_qty NUMERIC(24,6) NOT NULL DEFAULT 0,product_sku_snapshot TEXT NOT NULL,
 product_name_snapshot TEXT NOT NULL,received_uom_name_snapshot TEXT NOT NULL,
 base_uom_id UUID NOT NULL,base_uom_name_snapshot TEXT NOT NULL,created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
 UNIQUE(company_id,id),UNIQUE(company_id,document_id,line_no),UNIQUE(company_id,document_id,client_line_key),
 UNIQUE(company_id,document_id,supplier_order_line_id),
 FOREIGN KEY(company_id,document_id) REFERENCES public.goods_receipt_documents(company_id,id) ON DELETE RESTRICT,
 FOREIGN KEY(company_id,supplier_order_line_id) REFERENCES public.supplier_order_lines(company_id,id) ON DELETE RESTRICT,
 FOREIGN KEY(company_id,product_id) REFERENCES public.products(company_id,id) ON DELETE RESTRICT,
 FOREIGN KEY(company_id,product_id,received_uom_id) REFERENCES public.product_uoms(company_id,product_id,uom_id) ON DELETE RESTRICT,
 FOREIGN KEY(company_id,base_uom_id) REFERENCES public.uoms(company_id,id) ON DELETE RESTRICT,
 CHECK(line_no>0),CHECK(received_qty>0 AND factor_to_base_snapshot>0 AND received_base_qty>0),
 CHECK(accepted_good_qty>=0 AND damaged_qty>=0 AND rejected_qty>=0
  AND accepted_good_qty+damaged_qty+rejected_qty=received_qty),
 CHECK(accepted_good_base_qty>=0 AND damaged_base_qty>=0 AND rejected_base_qty>=0
  AND accepted_good_base_qty+damaged_base_qty+rejected_base_qty=received_base_qty),
 CHECK(estimated_unit_price_snapshot>=0 AND estimated_base_unit_cost>=0 AND provisional_ap_amount>=0),
 CHECK((is_over_received AND over_received_base_qty>0) OR (NOT is_over_received AND over_received_base_qty=0)),
 CHECK(btrim(product_sku_snapshot)<>'' AND btrim(product_name_snapshot)<>'' AND btrim(received_uom_name_snapshot)<>'' AND btrim(base_uom_name_snapshot)<>'')
);

CREATE TABLE public.goods_receipt_condition_allocations(
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(),company_id UUID NOT NULL,receipt_line_id UUID NOT NULL,
 condition_type TEXT NOT NULL,warehouse_id UUID,quantity_base NUMERIC(24,6) NOT NULL,
 product_batch_id UUID,created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
 UNIQUE(company_id,id),UNIQUE(company_id,receipt_line_id,condition_type),
 FOREIGN KEY(company_id,receipt_line_id) REFERENCES public.goods_receipt_lines(company_id,id) ON DELETE RESTRICT,
 FOREIGN KEY(company_id,warehouse_id) REFERENCES public.warehouses(company_id,id) ON DELETE RESTRICT,
 CHECK(condition_type IN('GOOD','DAMAGED','REJECTED')),CHECK(quantity_base>0),
 CHECK((condition_type='REJECTED' AND warehouse_id IS NULL AND product_batch_id IS NULL)
   OR (condition_type<>'REJECTED' AND warehouse_id IS NOT NULL))
);

CREATE TABLE public.goods_receipt_ap_provisionals(
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(),company_id UUID NOT NULL,receipt_id UUID NOT NULL,
 receipt_line_id UUID NOT NULL,supplier_id UUID NOT NULL,amount NUMERIC(20,4) NOT NULL,
 status TEXT NOT NULL DEFAULT 'OPEN',created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
 UNIQUE(company_id,id),UNIQUE(company_id,receipt_line_id),
 FOREIGN KEY(company_id,receipt_id) REFERENCES public.goods_receipt_documents(company_id,id) ON DELETE RESTRICT,
 FOREIGN KEY(company_id,receipt_line_id) REFERENCES public.goods_receipt_lines(company_id,id) ON DELETE RESTRICT,
 FOREIGN KEY(company_id,supplier_id) REFERENCES public.suppliers(company_id,id) ON DELETE RESTRICT,
 CHECK(amount>=0),CHECK(status IN('OPEN','MATCHED','REVERSED'))
);

CREATE TABLE public.goods_receipt_audit(
 id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,company_id UUID NOT NULL,document_id UUID NOT NULL,
 action TEXT NOT NULL CHECK(action IN('CREATE','UPDATE','POST','CANCEL')),actor_id UUID NOT NULL REFERENCES public.profiles(id),
 before_state JSONB,after_state JSONB NOT NULL,created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
 FOREIGN KEY(company_id,document_id) REFERENCES public.goods_receipt_documents(company_id,id) ON DELETE RESTRICT
);

CREATE INDEX idx_goods_receipt_order_status ON public.goods_receipt_documents(company_id,supplier_order_id,status);
CREATE INDEX idx_goods_receipt_lines_order_line ON public.goods_receipt_lines(company_id,supplier_order_line_id);

ALTER TABLE public.product_batches ADD COLUMN goods_receipt_line_id UUID,
 ADD COLUMN supplier_order_line_id UUID,
 ADD COLUMN goods_receipt_condition_allocation_id UUID,
 ADD CONSTRAINT fk_batches_goods_receipt_line FOREIGN KEY(company_id,goods_receipt_line_id) REFERENCES public.goods_receipt_lines(company_id,id) ON DELETE RESTRICT,
 ADD CONSTRAINT fk_batches_supplier_order_line FOREIGN KEY(company_id,supplier_order_line_id) REFERENCES public.supplier_order_lines(company_id,id) ON DELETE RESTRICT,
 ADD CONSTRAINT fk_batches_goods_condition FOREIGN KEY(company_id,goods_receipt_condition_allocation_id) REFERENCES public.goods_receipt_condition_allocations(company_id,id) ON DELETE RESTRICT,
 ADD CONSTRAINT product_batches_goods_receipt_lineage_check CHECK(
   (goods_receipt_line_id IS NULL AND supplier_order_line_id IS NULL AND goods_receipt_condition_allocation_id IS NULL)
   OR (goods_receipt_line_id IS NOT NULL AND supplier_order_line_id IS NOT NULL AND goods_receipt_condition_allocation_id IS NOT NULL
     AND purchase_detail_id IS NULL AND opening_stock_line_id IS NULL AND stock_transfer_line_id IS NULL
     AND source_batch_id IS NULL AND stock_adjustment_line_id IS NULL AND sales_return_line_id IS NULL));

ALTER TABLE public.goods_receipt_condition_allocations ADD CONSTRAINT fk_goods_condition_batch
 FOREIGN KEY(product_batch_id) REFERENCES public.product_batches(id) ON DELETE RESTRICT;

CREATE FUNCTION private.trg_g5_goods_receipt_history_guard() RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_doc UUID;v_status TEXT;
BEGIN
 IF TG_TABLE_NAME='goods_receipt_documents' THEN
   IF TG_OP<>'INSERT' AND OLD.status IN('POSTED','CANCELED') THEN RAISE EXCEPTION 'FINAL_GOODS_RECEIPT_IMMUTABLE'; END IF;
   RETURN COALESCE(NEW,OLD);
 END IF;
 v_doc:=CASE WHEN TG_TABLE_NAME='goods_receipt_lines' THEN COALESCE(NEW.document_id,OLD.document_id)
   WHEN TG_TABLE_NAME='goods_receipt_condition_allocations' THEN (SELECT document_id FROM public.goods_receipt_lines WHERE id=COALESCE(NEW.receipt_line_id,OLD.receipt_line_id))
   ELSE COALESCE(NEW.receipt_id,OLD.receipt_id) END;
 SELECT status INTO v_status FROM public.goods_receipt_documents WHERE id=v_doc;
 IF v_status<>'DRAFT' THEN RAISE EXCEPTION 'FINAL_GOODS_RECEIPT_IMMUTABLE'; END IF;
 RETURN COALESCE(NEW,OLD);
END $$;
CREATE TRIGGER g5_guard_goods_receipt_documents BEFORE UPDATE OR DELETE ON public.goods_receipt_documents FOR EACH ROW EXECUTE FUNCTION private.trg_g5_goods_receipt_history_guard();
CREATE TRIGGER g5_guard_goods_receipt_lines BEFORE INSERT OR UPDATE OR DELETE ON public.goods_receipt_lines FOR EACH ROW EXECUTE FUNCTION private.trg_g5_goods_receipt_history_guard();
CREATE TRIGGER g5_guard_goods_receipt_conditions BEFORE INSERT OR UPDATE OR DELETE ON public.goods_receipt_condition_allocations FOR EACH ROW EXECUTE FUNCTION private.trg_g5_goods_receipt_history_guard();
CREATE TRIGGER g5_guard_goods_receipt_ap BEFORE INSERT OR UPDATE OR DELETE ON public.goods_receipt_ap_provisionals FOR EACH ROW EXECUTE FUNCTION private.trg_g5_goods_receipt_history_guard();

CREATE FUNCTION public.save_goods_receipt(p_document_id UUID,p_master_version BIGINT,p_cashier_session_id UUID,p_supplier_order_id UUID,p_supplier_delivery_no TEXT,p_notes TEXT,p_lines JSONB)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_actor UUID:=auth.uid();v_company UUID:=public.private_active_company_id();v_session RECORD;v_order public.supplier_order_documents%ROWTYPE;
 v_doc UUID;v_no TEXT;v_old public.goods_receipt_documents%ROWTYPE;v_before JSONB;v_line RECORD;v_source RECORD;v_uom RECORD;
 v_n INT:=0;v_received NUMERIC:=0;v_good NUMERIC:=0;v_damaged NUMERIC:=0;v_rejected NUMERIC:=0;v_ap NUMERIC:=0;
 v_received_base NUMERIC;v_good_base NUMERIC;v_damaged_base NUMERIC;v_rejected_base NUMERIC;v_prior NUMERIC;v_over NUMERIC;v_line_id UUID;v_version BIGINT;
BEGIN
 IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
 SELECT session.store_id,session.pos_id INTO v_session FROM public.cashier_sessions session
  WHERE session.company_id=v_company AND session.id=p_cashier_session_id AND session.cashier_id=v_actor AND session.status='OPEN'::public.session_status;
 IF NOT FOUND THEN RAISE EXCEPTION 'OPEN_CASHIER_SESSION_REQUIRED'; END IF;
 SELECT * INTO v_order FROM public.supplier_order_documents o WHERE o.company_id=v_company AND o.id=p_supplier_order_id FOR UPDATE;
 IF NOT FOUND OR v_order.status NOT IN('CONFIRMED','PARTIALLY_RECEIVED') THEN RAISE EXCEPTION 'RECEIVABLE_SUPPLIER_ORDER_NOT_FOUND'; END IF;
 IF v_order.store_id<>v_session.store_id THEN RAISE EXCEPTION 'GOODS_RECEIPT_STORE_SCOPE_INVALID'; END IF;
 IF p_lines IS NULL OR jsonb_typeof(p_lines)<>'array' OR jsonb_array_length(p_lines)=0 THEN RAISE EXCEPTION 'GOODS_RECEIPT_LINES_REQUIRED'; END IF;
 IF p_document_id IS NULL THEN
  IF p_master_version IS NOT NULL THEN RAISE EXCEPTION 'MASTER_VERSION_NOT_ALLOWED_ON_CREATE'; END IF;
  v_no:='GR-'||to_char(clock_timestamp(),'YYYYMMDD')||'-'||lpad(nextval('private.goods_receipt_no_seq')::text,10,'0');
  INSERT INTO public.goods_receipt_documents(company_id,receipt_no,supplier_order_id,store_id,warehouse_id,receiving_session_id,receiving_pos_id,received_by,supplier_delivery_no,notes)
   VALUES(v_company,v_no,v_order.id,v_order.store_id,v_order.destination_warehouse_id,p_cashier_session_id,v_session.pos_id,v_actor,NULLIF(btrim(p_supplier_delivery_no),''),NULLIF(btrim(p_notes),'')) RETURNING id,master_version INTO v_doc,v_version;
 ELSE
  SELECT * INTO v_old FROM public.goods_receipt_documents d WHERE d.company_id=v_company AND d.id=p_document_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'GOODS_RECEIPT_NOT_FOUND'; END IF;
  IF v_old.status<>'DRAFT' THEN RAISE EXCEPTION 'FINAL_GOODS_RECEIPT_IMMUTABLE'; END IF;
  IF v_old.received_by<>v_actor OR v_old.receiving_session_id<>p_cashier_session_id OR v_old.supplier_order_id<>p_supplier_order_id THEN RAISE EXCEPTION 'GOODS_RECEIPT_OWNER_SCOPE_INVALID'; END IF;
  IF p_master_version IS DISTINCT FROM v_old.master_version THEN RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
  v_before:=to_jsonb(v_old);v_doc:=v_old.id;
  DELETE FROM public.goods_receipt_condition_allocations allocation
   USING public.goods_receipt_lines line
   WHERE allocation.company_id=v_company
     AND line.company_id=allocation.company_id
     AND line.id=allocation.receipt_line_id
     AND line.document_id=v_doc;
  DELETE FROM public.goods_receipt_lines
   WHERE company_id=v_company AND document_id=v_doc;
 END IF;
 FOR v_line IN SELECT * FROM jsonb_to_recordset(p_lines) AS x("clientLineKey" UUID,"supplierOrderLineId" UUID,"receivedUomId" UUID,"receivedQty" NUMERIC,"acceptedGoodQty" NUMERIC,"damagedQty" NUMERIC,"rejectedQty" NUMERIC) LOOP
  v_n:=v_n+1;
  SELECT l.*,p.uom_id,p.sku,p.name,base.name base_name INTO v_source FROM public.supplier_order_lines l
   JOIN public.products p ON p.company_id=l.company_id AND p.id=l.product_id AND p.is_active AND NOT p.is_bundle
   JOIN public.uoms base ON base.company_id=p.company_id AND base.id=p.uom_id AND base.is_active
   WHERE l.company_id=v_company AND l.id=v_line."supplierOrderLineId" AND l.document_id=v_order.id;
  IF NOT FOUND THEN RAISE EXCEPTION 'SUPPLIER_ORDER_LINE_NOT_FOUND'; END IF;
  SELECT pu.factor_to_base,u.name,u.allow_decimal,u.decimal_precision INTO v_uom FROM public.product_uoms pu JOIN public.uoms u ON u.company_id=pu.company_id AND u.id=pu.uom_id
   WHERE pu.company_id=v_company AND pu.product_id=v_source.product_id AND pu.uom_id=v_line."receivedUomId" AND pu.is_active AND pu.purchase_allowed AND u.is_active;
  IF NOT FOUND THEN RAISE EXCEPTION 'ACTIVE_PURCHASE_PRODUCT_UOM_NOT_FOUND'; END IF;
  IF v_line."receivedQty"<=0 THEN RAISE EXCEPTION 'GOODS_RECEIPT_QUANTITY_INVALID'; END IF;
  v_line."acceptedGoodQty":=COALESCE(v_line."acceptedGoodQty",v_line."receivedQty");v_line."damagedQty":=COALESCE(v_line."damagedQty",0);v_line."rejectedQty":=COALESCE(v_line."rejectedQty",0);
  IF v_line."acceptedGoodQty"<0 OR v_line."damagedQty"<0 OR v_line."rejectedQty"<0 OR v_line."acceptedGoodQty"+v_line."damagedQty"+v_line."rejectedQty"<>v_line."receivedQty" THEN RAISE EXCEPTION 'GOODS_RECEIPT_CONDITION_TOTAL_INVALID'; END IF;
  IF NOT v_uom.allow_decimal AND (v_line."receivedQty"<>trunc(v_line."receivedQty") OR v_line."acceptedGoodQty"<>trunc(v_line."acceptedGoodQty") OR v_line."damagedQty"<>trunc(v_line."damagedQty") OR v_line."rejectedQty"<>trunc(v_line."rejectedQty")) THEN RAISE EXCEPTION 'PURCHASE_UOM_REQUIRES_INTEGER'; END IF;
  v_received_base:=v_line."receivedQty"*v_uom.factor_to_base;v_good_base:=v_line."acceptedGoodQty"*v_uom.factor_to_base;v_damaged_base:=v_line."damagedQty"*v_uom.factor_to_base;v_rejected_base:=v_line."rejectedQty"*v_uom.factor_to_base;
  SELECT COALESCE(sum(gl.received_base_qty),0) INTO v_prior FROM public.goods_receipt_lines gl JOIN public.goods_receipt_documents gd ON gd.company_id=gl.company_id AND gd.id=gl.document_id WHERE gl.company_id=v_company AND gl.supplier_order_line_id=v_source.id AND gd.status='POSTED';
  v_over:=GREATEST(v_prior+v_received_base-v_source.ordered_base_qty,0);
  INSERT INTO public.goods_receipt_lines(company_id,document_id,line_no,client_line_key,supplier_order_line_id,product_id,received_uom_id,received_qty,factor_to_base_snapshot,received_base_qty,accepted_good_qty,damaged_qty,rejected_qty,accepted_good_base_qty,damaged_base_qty,rejected_base_qty,estimated_unit_price_snapshot,estimated_base_unit_cost,provisional_ap_amount,is_over_received,over_received_base_qty,product_sku_snapshot,product_name_snapshot,received_uom_name_snapshot,base_uom_id,base_uom_name_snapshot)
   VALUES(v_company,v_doc,v_n,v_line."clientLineKey",v_source.id,v_source.product_id,v_line."receivedUomId",v_line."receivedQty",v_uom.factor_to_base,v_received_base,v_line."acceptedGoodQty",v_line."damagedQty",v_line."rejectedQty",v_good_base,v_damaged_base,v_rejected_base,v_source.estimated_unit_price,v_source.estimated_unit_price/v_source.factor_to_base_snapshot,round((v_good_base+v_damaged_base)*(v_source.estimated_unit_price/v_source.factor_to_base_snapshot),4),v_over>0,v_over,v_source.product_sku_snapshot,v_source.product_name_snapshot,v_uom.name,v_source.uom_id,v_source.base_name) RETURNING id INTO v_line_id;
  IF v_good_base>0 THEN INSERT INTO public.goods_receipt_condition_allocations(company_id,receipt_line_id,condition_type,warehouse_id,quantity_base) VALUES(v_company,v_line_id,'GOOD',v_order.destination_warehouse_id,v_good_base); END IF;
  IF v_damaged_base>0 THEN INSERT INTO public.goods_receipt_condition_allocations(company_id,receipt_line_id,condition_type,warehouse_id,quantity_base) SELECT v_company,v_line_id,'DAMAGED',w.id,v_damaged_base FROM public.warehouses w WHERE w.company_id=v_company AND w.is_active AND w.warehouse_type='DAMAGED' AND (w.store_id=v_order.store_id OR w.store_id IS NULL) ORDER BY (w.store_id=v_order.store_id) DESC,w.id LIMIT 1; IF NOT FOUND THEN RAISE EXCEPTION 'ACTIVE_DAMAGED_WAREHOUSE_NOT_FOUND'; END IF; END IF;
  IF v_rejected_base>0 THEN INSERT INTO public.goods_receipt_condition_allocations(company_id,receipt_line_id,condition_type,warehouse_id,quantity_base) VALUES(v_company,v_line_id,'REJECTED',NULL,v_rejected_base); END IF;
  v_received:=v_received+v_received_base;v_good:=v_good+v_good_base;v_damaged:=v_damaged+v_damaged_base;v_rejected:=v_rejected+v_rejected_base;v_ap:=v_ap+round((v_good_base+v_damaged_base)*(v_source.estimated_unit_price/v_source.factor_to_base_snapshot),4);
 END LOOP;
 UPDATE public.goods_receipt_documents SET supplier_delivery_no=NULLIF(btrim(p_supplier_delivery_no),''),notes=NULLIF(btrim(p_notes),''),line_count=v_n,received_total_base_qty=v_received,accepted_total_base_qty=v_good,damaged_total_base_qty=v_damaged,rejected_total_base_qty=v_rejected,provisional_ap_total=v_ap,has_over_receipt=EXISTS(SELECT 1 FROM public.goods_receipt_lines WHERE document_id=v_doc AND is_over_received),master_version=CASE WHEN p_document_id IS NULL THEN master_version ELSE master_version+1 END,updated_at=clock_timestamp() WHERE company_id=v_company AND id=v_doc RETURNING master_version INTO v_version;
 INSERT INTO public.goods_receipt_audit(company_id,document_id,action,actor_id,before_state,after_state) SELECT v_company,v_doc,CASE WHEN p_document_id IS NULL THEN 'CREATE' ELSE 'UPDATE' END,v_actor,v_before,to_jsonb(d) FROM public.goods_receipt_documents d WHERE d.id=v_doc;
 RETURN jsonb_build_object('documentId',v_doc,'receiptNo',COALESCE(v_no,v_old.receipt_no),'status','DRAFT','masterVersion',v_version);
END $$;

CREATE FUNCTION public.post_goods_receipt(
 p_document_id UUID,p_master_version BIGINT,p_idempotency_key UUID
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE
 v_actor UUID:=auth.uid();v_company UUID:=public.private_active_company_id();
 v_document public.goods_receipt_documents%ROWTYPE;
 v_order public.supplier_order_documents%ROWTYPE;v_allocation RECORD;
 v_line RECORD;v_stock_after NUMERIC(24,6);v_batch UUID;v_event UUID;
 v_category UUID;v_inventory_account UUID;v_ap_account UUID;
 v_before JSONB;v_version BIGINT;v_now TIMESTAMPTZ:=clock_timestamp();
BEGIN
 IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
 IF p_idempotency_key IS NULL THEN RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED'; END IF;

 SELECT * INTO v_document FROM public.goods_receipt_documents document
 WHERE document.company_id=v_company AND document.id=p_document_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'GOODS_RECEIPT_NOT_FOUND'; END IF;
 IF v_document.status='POSTED' THEN
  IF v_document.posting_idempotency_key=p_idempotency_key THEN
   RETURN jsonb_build_object('documentId',v_document.id,'receiptNo',v_document.receipt_no,
    'status','POSTED','masterVersion',v_document.master_version,
    'financialEventId',v_document.financial_event_id,'idempotentReplay',TRUE);
  END IF;
  RAISE EXCEPTION 'GOODS_RECEIPT_ALREADY_POSTED';
 END IF;
 IF v_document.status<>'DRAFT' THEN RAISE EXCEPTION 'GOODS_RECEIPT_NOT_POSTABLE'; END IF;
 IF p_master_version IS DISTINCT FROM v_document.master_version THEN
  RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
 END IF;
 IF v_document.received_by<>v_actor THEN RAISE EXCEPTION 'GOODS_RECEIPT_OWNER_SCOPE_INVALID'; END IF;
 IF v_document.line_count<=0 THEN RAISE EXCEPTION 'GOODS_RECEIPT_LINES_REQUIRED'; END IF;

 SELECT * INTO v_order FROM public.supplier_order_documents document
 WHERE document.company_id=v_company AND document.id=v_document.supplier_order_id
 FOR UPDATE;
 IF NOT FOUND OR v_order.status NOT IN('CONFIRMED','PARTIALLY_RECEIVED') THEN
  RAISE EXCEPTION 'RECEIVABLE_SUPPLIER_ORDER_NOT_FOUND';
 END IF;
 SELECT category.id INTO v_category FROM public.transaction_categories category
 WHERE category.company_id=v_company AND category.system_key='GOODS_RECEIPT'
   AND category.is_active ORDER BY category.id LIMIT 1;
 IF v_category IS NULL THEN RAISE EXCEPTION 'GOODS_RECEIPT_TRANSACTION_CATEGORY_NOT_FOUND'; END IF;
 v_inventory_account:=private.resolve_opening_stock_account(
  v_company,v_category,'INVENTORY_ASSET',v_now);
 v_ap_account:=private.resolve_opening_stock_account(
  v_company,v_category,'SUPPLIER_AP_PROVISIONAL',v_now);
 v_before:=to_jsonb(v_document);

 FOR v_allocation IN
  SELECT allocation.*,line.product_id,line.base_uom_id,
   line.base_uom_name_snapshot,line.estimated_base_unit_cost,
   line.supplier_order_line_id
  FROM public.goods_receipt_condition_allocations allocation
  JOIN public.goods_receipt_lines line
   ON line.company_id=allocation.company_id AND line.id=allocation.receipt_line_id
  WHERE allocation.company_id=v_company AND line.document_id=v_document.id
    AND allocation.condition_type IN('GOOD','DAMAGED')
  ORDER BY allocation.warehouse_id,line.product_id,allocation.id
 LOOP
  PERFORM pg_advisory_xact_lock(hashtextextended(
   v_company::TEXT||':STOCK:'||v_allocation.product_id::TEXT||':'||
   v_allocation.warehouse_id::TEXT,0));
  INSERT INTO public.product_stocks(product_id,warehouse_id,stock_qty,company_id)
  VALUES(v_allocation.product_id,v_allocation.warehouse_id,
   v_allocation.quantity_base,v_company)
  ON CONFLICT(product_id,warehouse_id) DO UPDATE SET
   stock_qty=public.product_stocks.stock_qty+EXCLUDED.stock_qty,
   updated_at=v_now RETURNING stock_qty INTO v_stock_after;

  INSERT INTO public.product_batches(
   product_id,warehouse_id,purchase_detail_id,qty_purchased,qty_remaining,
   cogs_unit,company_id,goods_receipt_line_id,supplier_order_line_id,
   goods_receipt_condition_allocation_id
  ) VALUES(
   v_allocation.product_id,v_allocation.warehouse_id,NULL,
   v_allocation.quantity_base,v_allocation.quantity_base,
   v_allocation.estimated_base_unit_cost,v_company,
   v_allocation.receipt_line_id,v_allocation.supplier_order_line_id,
   v_allocation.id
  ) RETURNING id INTO v_batch;
  UPDATE public.goods_receipt_condition_allocations SET product_batch_id=v_batch
  WHERE company_id=v_company AND id=v_allocation.id;
  INSERT INTO public.stock_movements(
   product_id,warehouse_id,qty_change,movement_type,reference_table,
   reference_id,company_id,base_uom_id,base_uom_name_snapshot,
   balance_after_base_qty,actor_id,posted_at,movement_status,source_line_id,notes
  ) VALUES(
   v_allocation.product_id,v_allocation.warehouse_id,v_allocation.quantity_base,
   'PURCHASE'::public.stock_movement_type,'goods_receipt_documents',
   v_document.id,v_company,v_allocation.base_uom_id,
   v_allocation.base_uom_name_snapshot,v_stock_after,v_actor,v_now,'POSTED',
   v_allocation.id,'Goods Receipt '||v_allocation.condition_type
  );
 END LOOP;

 FOR v_line IN SELECT * FROM public.goods_receipt_lines line
  WHERE line.company_id=v_company AND line.document_id=v_document.id
    AND line.provisional_ap_amount>0
 LOOP
  INSERT INTO public.goods_receipt_ap_provisionals(
   company_id,receipt_id,receipt_line_id,supplier_id,amount
  ) VALUES(v_company,v_document.id,v_line.id,v_order.supplier_id,
   v_line.provisional_ap_amount);
 END LOOP;

 INSERT INTO public.financial_events(
  event_code,event_type,source_table,source_id,root_sales_id,event_date,
  event_version,idempotency_key,amounts,status,error_message,created_by,
  company_id,store_id,system_event_key,transaction_category_id
 ) VALUES(
  'GR-'||replace(v_document.id::TEXT,'-',''),'PURCHASE_POSTED'::public.event_type,
  'goods_receipt_documents',v_document.id,NULL,v_now,1,
  'GOODS_RECEIPT|'||v_company::TEXT||'|'||p_idempotency_key::TEXT,
  jsonb_build_object('inventoryDebit',v_document.provisional_ap_total,
   'supplierApProvisionalCredit',v_document.provisional_ap_total,
   'inventoryAccountId',v_inventory_account,'supplierApAccountId',v_ap_account,
   'acceptedBaseQty',v_document.accepted_total_base_qty,
   'damagedBaseQty',v_document.damaged_total_base_qty,
   'rejectedBaseQty',v_document.rejected_total_base_qty,
   'hasOverReceipt',v_document.has_over_receipt,
   'financePostingState','HOLD_UNTIL_G6'),
  'HOLD'::public.event_status,'CANONICAL_FINANCE_POSTING_NOT_ENABLED',
  v_actor,v_company,v_document.store_id,'GOODS_RECEIPT',v_category
 ) RETURNING id INTO v_event;

 UPDATE public.goods_receipt_documents SET status='POSTED',
  posting_idempotency_key=p_idempotency_key,financial_event_id=v_event,
  posted_by=v_actor,posted_at=v_now,master_version=master_version+1,
  updated_at=v_now WHERE company_id=v_company AND id=v_document.id
  RETURNING master_version INTO v_version;

 UPDATE public.supplier_order_documents SET status=CASE WHEN NOT EXISTS(
   SELECT 1 FROM public.supplier_order_lines order_line
   WHERE order_line.company_id=v_company AND order_line.document_id=v_order.id
    AND COALESCE((SELECT sum(receipt_line.received_base_qty)
     FROM public.goods_receipt_lines receipt_line
     JOIN public.goods_receipt_documents receipt
      ON receipt.company_id=receipt_line.company_id
      AND receipt.id=receipt_line.document_id AND receipt.status='POSTED'
     WHERE receipt_line.company_id=v_company
      AND receipt_line.supplier_order_line_id=order_line.id),0)
      < order_line.ordered_base_qty
  ) THEN 'RECEIVED' ELSE 'PARTIALLY_RECEIVED' END,
  master_version=master_version+1,updated_at=v_now
 WHERE company_id=v_company AND id=v_order.id;

 INSERT INTO public.goods_receipt_audit(
  company_id,document_id,action,actor_id,before_state,after_state
 ) SELECT v_company,v_document.id,'POST',v_actor,v_before,to_jsonb(document)
 FROM public.goods_receipt_documents document
 WHERE document.company_id=v_company AND document.id=v_document.id;
 RETURN jsonb_build_object('documentId',v_document.id,'receiptNo',v_document.receipt_no,
  'status','POSTED','masterVersion',v_version,'financialEventId',v_event,
  'idempotentReplay',FALSE);
EXCEPTION WHEN unique_violation THEN
 RAISE EXCEPTION 'GOODS_RECEIPT_IDEMPOTENCY_CONFLICT';
END $$;

CREATE FUNCTION public.cancel_goods_receipt(p_document_id UUID,p_master_version BIGINT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_actor UUID:=auth.uid();v_company UUID:=public.private_active_company_id();
 v_document public.goods_receipt_documents%ROWTYPE;v_version BIGINT;v_before JSONB;
BEGIN
 IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
 SELECT * INTO v_document FROM public.goods_receipt_documents document
 WHERE document.company_id=v_company AND document.id=p_document_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'GOODS_RECEIPT_NOT_FOUND'; END IF;
 IF v_document.status<>'DRAFT' THEN RAISE EXCEPTION 'GOODS_RECEIPT_NOT_CANCELABLE'; END IF;
 IF v_document.received_by<>v_actor THEN RAISE EXCEPTION 'GOODS_RECEIPT_OWNER_SCOPE_INVALID'; END IF;
 IF p_master_version IS DISTINCT FROM v_document.master_version THEN RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
 v_before:=to_jsonb(v_document);
 UPDATE public.goods_receipt_documents SET status='CANCELED',canceled_by=v_actor,
  canceled_at=clock_timestamp(),master_version=master_version+1,
  updated_at=clock_timestamp() WHERE company_id=v_company AND id=v_document.id
  RETURNING master_version INTO v_version;
 INSERT INTO public.goods_receipt_audit(company_id,document_id,action,actor_id,before_state,after_state)
 SELECT v_company,v_document.id,'CANCEL',v_actor,v_before,to_jsonb(document)
 FROM public.goods_receipt_documents document WHERE document.id=v_document.id;
 RETURN jsonb_build_object('documentId',v_document.id,'status','CANCELED','masterVersion',v_version);
END $$;

ALTER TABLE public.goods_receipt_documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.goods_receipt_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.goods_receipt_condition_allocations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.goods_receipt_ap_provisionals ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.goods_receipt_audit ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Goods Receipt documents readable in Store" ON public.goods_receipt_documents
 FOR SELECT TO authenticated USING(public.private_purchase_document_visible(company_id,store_id));
CREATE POLICY "Goods Receipt lines readable in Store" ON public.goods_receipt_lines
 FOR SELECT TO authenticated USING(EXISTS(SELECT 1 FROM public.goods_receipt_documents document
  WHERE document.company_id=goods_receipt_lines.company_id AND document.id=goods_receipt_lines.document_id
   AND public.private_purchase_document_visible(document.company_id,document.store_id)));
CREATE POLICY "Goods Receipt conditions readable in Store" ON public.goods_receipt_condition_allocations
 FOR SELECT TO authenticated USING(EXISTS(SELECT 1 FROM public.goods_receipt_lines line
  JOIN public.goods_receipt_documents document ON document.company_id=line.company_id AND document.id=line.document_id
  WHERE line.company_id=goods_receipt_condition_allocations.company_id
   AND line.id=goods_receipt_condition_allocations.receipt_line_id
   AND public.private_purchase_document_visible(document.company_id,document.store_id)));
CREATE POLICY "Goods Receipt AP readable in Store" ON public.goods_receipt_ap_provisionals
 FOR SELECT TO authenticated USING(EXISTS(SELECT 1 FROM public.goods_receipt_documents document
  WHERE document.company_id=goods_receipt_ap_provisionals.company_id
   AND document.id=goods_receipt_ap_provisionals.receipt_id
   AND public.private_purchase_document_visible(document.company_id,document.store_id)));
CREATE POLICY "Goods Receipt audit readable in Store" ON public.goods_receipt_audit
 FOR SELECT TO authenticated USING(EXISTS(SELECT 1 FROM public.goods_receipt_documents document
  WHERE document.company_id=goods_receipt_audit.company_id AND document.id=goods_receipt_audit.document_id
   AND public.private_purchase_document_visible(document.company_id,document.store_id)));

REVOKE ALL ON public.goods_receipt_documents,public.goods_receipt_lines,
 public.goods_receipt_condition_allocations,public.goods_receipt_ap_provisionals,
 public.goods_receipt_audit FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.goods_receipt_documents,public.goods_receipt_lines,
 public.goods_receipt_condition_allocations,public.goods_receipt_ap_provisionals,
 public.goods_receipt_audit TO authenticated;
GRANT ALL ON public.goods_receipt_documents,public.goods_receipt_lines,
 public.goods_receipt_condition_allocations,public.goods_receipt_ap_provisionals,
 public.goods_receipt_audit TO service_role;

REVOKE ALL ON FUNCTION public.save_goods_receipt(UUID,BIGINT,UUID,UUID,TEXT,TEXT,JSONB),
 public.post_goods_receipt(UUID,BIGINT,UUID),public.cancel_goods_receipt(UUID,BIGINT)
 FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.save_goods_receipt(UUID,BIGINT,UUID,UUID,TEXT,TEXT,JSONB),
 public.post_goods_receipt(UUID,BIGINT,UUID),public.cancel_goods_receipt(UUID,BIGINT)
 TO authenticated,service_role;
REVOKE ALL ON FUNCTION private.trg_g5_goods_receipt_history_guard()
 FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.trg_g5_goods_receipt_history_guard() TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260806040000','g5_phase5_goods_receipt_foundation',
 'Canonical partial/over Goods Receipt, condition routing, FIFO intake, stock movement, provisional AP HOLD, idempotent posting');

COMMIT;
