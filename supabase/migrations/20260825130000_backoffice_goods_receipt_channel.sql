-- Backoffice Goods Receipt channel.
-- Keeps the proven canonical Goods Receipt posting path for Stock/FIFO/AP/Finance.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260813000000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: ACP Supplier Order required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260825130000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED';
  END IF;
  IF to_regprocedure('public.save_goods_receipt(uuid,bigint,uuid,uuid,text,text,jsonb)') IS NULL
    OR to_regprocedure('public.post_goods_receipt(uuid,bigint,uuid)') IS NULL
    OR to_regprocedure('public.cancel_goods_receipt(uuid,bigint)') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical Goods Receipt runtime missing';
  END IF;
END
$guard$;

INSERT INTO public.access_permission_catalog(
  permission_key,module_key,permission_label,description,view_roles,
  operator_roles,approver_roles,supported_capabilities,required_any_features,
  is_customizable,enforcement_status
) VALUES(
  'purchase.goods_receipts','PURCHASE','Penerimaan Barang',
  'Penerimaan Supplier Order melalui Backoffice Gudang',
  ARRAY['COMPANY_OWNER','COMPANY_ADMIN','WAREHOUSE_ADMIN'],
  ARRAY['COMPANY_OWNER','COMPANY_ADMIN','WAREHOUSE_ADMIN'],
  ARRAY['COMPANY_OWNER','COMPANY_ADMIN','WAREHOUSE_ADMIN'],
  ARRAY['VIEW','CREATE_DRAFT','EDIT_DRAFT','POST','CANCEL_FINAL'],
  '{}',TRUE,'ENFORCED'
);

ALTER TABLE public.goods_receipt_documents
  ALTER COLUMN receiving_session_id DROP NOT NULL,
  ALTER COLUMN receiving_pos_id DROP NOT NULL,
  ADD COLUMN source_channel TEXT NOT NULL DEFAULT 'POS';

ALTER TABLE public.goods_receipt_documents
  ADD CONSTRAINT goods_receipt_source_channel_check
    CHECK(source_channel IN('POS','BACKOFFICE')),
  ADD CONSTRAINT goods_receipt_channel_scope_check CHECK(
    (source_channel='POS' AND receiving_session_id IS NOT NULL
      AND receiving_pos_id IS NOT NULL)
    OR (source_channel='BACKOFFICE' AND receiving_session_id IS NULL
      AND receiving_pos_id IS NULL)
  );

CREATE FUNCTION public.get_backoffice_goods_receipt_workspace()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'purchase.goods_receipts','VIEW');
  RETURN jsonb_build_object(
    'orders',(SELECT COALESCE(jsonb_agg(to_jsonb(row_data)
      ORDER BY row_data.expected_date NULLS LAST,row_data.order_no),'[]'::JSONB)
      FROM (SELECT document.id,document.order_no,document.store_id,
          document.supplier_id,supplier.supplier_name,
          document.destination_warehouse_id,warehouse.name warehouse_name,
          document.status,document.expected_date
        FROM public.supplier_order_documents document
        JOIN public.suppliers supplier ON supplier.company_id=document.company_id
          AND supplier.id=document.supplier_id
        JOIN public.warehouses warehouse ON warehouse.company_id=document.company_id
          AND warehouse.id=document.destination_warehouse_id
        WHERE document.company_id=v_company
          AND document.status IN('CONFIRMED','PARTIALLY_RECEIVED')) row_data),
    'orderLines',(SELECT COALESCE(jsonb_agg(to_jsonb(row_data)
      ORDER BY row_data.document_id,row_data.line_no),'[]'::JSONB)
      FROM (SELECT line.id,line.document_id,line.line_no,line.product_id,
          line.ordered_uom_id,line.ordered_qty,line.ordered_base_qty,
          line.product_name_snapshot,line.ordered_uom_name_snapshot,
          GREATEST(line.ordered_base_qty-COALESCE((SELECT sum(receipt_line.received_base_qty)
            FROM public.goods_receipt_lines receipt_line
            JOIN public.goods_receipt_documents receipt
              ON receipt.company_id=receipt_line.company_id
             AND receipt.id=receipt_line.document_id
             AND receipt.status='POSTED'
            WHERE receipt_line.company_id=v_company
              AND receipt_line.supplier_order_line_id=line.id),0),0) remaining_base_qty
        FROM public.supplier_order_lines line
        JOIN public.supplier_order_documents document
          ON document.company_id=line.company_id AND document.id=line.document_id
        WHERE line.company_id=v_company
          AND document.status IN('CONFIRMED','PARTIALLY_RECEIVED')) row_data),
    'productUoms',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'product_id',product_uom.product_id,'uom_id',product_uom.uom_id,
        'factor_to_base',product_uom.factor_to_base,'uom_name',uom.name,
        'allow_decimal',uom.allow_decimal,
        'decimal_precision',uom.decimal_precision)
      ORDER BY product_uom.product_id,product_uom.factor_to_base DESC,uom.name),
      '[]'::JSONB)
      FROM public.product_uoms product_uom
      JOIN public.uoms uom ON uom.company_id=product_uom.company_id
        AND uom.id=product_uom.uom_id
      WHERE product_uom.company_id=v_company AND product_uom.is_active
        AND product_uom.purchase_allowed AND uom.is_active
        AND EXISTS(SELECT 1 FROM public.supplier_order_lines line
          JOIN public.supplier_order_documents document
            ON document.company_id=line.company_id AND document.id=line.document_id
          WHERE line.company_id=v_company AND line.product_id=product_uom.product_id
            AND document.status IN('CONFIRMED','PARTIALLY_RECEIVED'))),
    'drafts',(SELECT COALESCE(jsonb_agg(to_jsonb(row_data)
      ORDER BY row_data.received_at DESC,row_data.id),'[]'::JSONB)
      FROM (SELECT document.id,document.receipt_no,document.supplier_order_id,
          document.supplier_delivery_no,document.notes,document.master_version,
          document.received_at
        FROM public.goods_receipt_documents document
        WHERE document.company_id=v_company AND document.status='DRAFT'
          AND document.source_channel='BACKOFFICE' AND document.received_by=auth.uid()) row_data),
    'draftLines',(SELECT COALESCE(jsonb_agg(to_jsonb(row_data)
      ORDER BY row_data.document_id,row_data.line_no),'[]'::JSONB)
      FROM (SELECT line.document_id,line.line_no,line.client_line_key,
          line.supplier_order_line_id,line.received_uom_id,
          line.received_qty,line.accepted_good_qty,line.damaged_qty,line.rejected_qty
        FROM public.goods_receipt_lines line
        JOIN public.goods_receipt_documents document
          ON document.company_id=line.company_id AND document.id=line.document_id
        WHERE line.company_id=v_company AND document.status='DRAFT'
          AND document.source_channel='BACKOFFICE' AND document.received_by=auth.uid()) row_data));
END $$;

CREATE FUNCTION public.save_backoffice_goods_receipt(
  p_document_id UUID,p_master_version BIGINT,p_supplier_order_id UUID,
  p_supplier_delivery_no TEXT,p_notes TEXT,p_lines JSONB
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_actor UUID:=auth.uid();v_company UUID:=public.private_active_company_id();
  v_order public.supplier_order_documents%ROWTYPE;v_old public.goods_receipt_documents%ROWTYPE;
  v_doc UUID;v_no TEXT;v_before JSONB;v_line RECORD;v_source RECORD;v_uom RECORD;
  v_n INT:=0;v_received NUMERIC:=0;v_good NUMERIC:=0;v_damaged NUMERIC:=0;
  v_rejected NUMERIC:=0;v_ap NUMERIC:=0;v_received_base NUMERIC;
  v_good_base NUMERIC;v_damaged_base NUMERIC;v_rejected_base NUMERIC;
  v_prior NUMERIC;v_over NUMERIC;v_line_id UUID;v_version BIGINT;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  PERFORM private.acp_require_permission_capability(v_company,
    'purchase.goods_receipts',CASE WHEN p_document_id IS NULL
      THEN 'CREATE_DRAFT' ELSE 'EDIT_DRAFT' END);
  SELECT * INTO v_order FROM public.supplier_order_documents document
  WHERE document.company_id=v_company AND document.id=p_supplier_order_id FOR UPDATE;
  IF NOT FOUND OR v_order.status NOT IN('CONFIRMED','PARTIALLY_RECEIVED') THEN
    RAISE EXCEPTION 'RECEIVABLE_SUPPLIER_ORDER_NOT_FOUND'; END IF;
  IF p_lines IS NULL OR jsonb_typeof(p_lines)<>'array'
    OR jsonb_array_length(p_lines)=0 THEN RAISE EXCEPTION 'GOODS_RECEIPT_LINES_REQUIRED'; END IF;
  IF p_document_id IS NULL THEN
    IF p_master_version IS NOT NULL THEN RAISE EXCEPTION 'MASTER_VERSION_NOT_ALLOWED_ON_CREATE'; END IF;
    v_no:='GR-'||to_char(clock_timestamp(),'YYYYMMDD')||'-'||
      lpad(nextval('private.goods_receipt_no_seq')::TEXT,10,'0');
    INSERT INTO public.goods_receipt_documents(company_id,receipt_no,
      supplier_order_id,store_id,warehouse_id,receiving_session_id,
      receiving_pos_id,received_by,supplier_delivery_no,notes,source_channel)
    VALUES(v_company,v_no,v_order.id,v_order.store_id,
      v_order.destination_warehouse_id,NULL,NULL,v_actor,
      NULLIF(btrim(p_supplier_delivery_no),''),NULLIF(btrim(p_notes),''),'BACKOFFICE')
    RETURNING id,master_version INTO v_doc,v_version;
  ELSE
    SELECT * INTO v_old FROM public.goods_receipt_documents document
    WHERE document.company_id=v_company AND document.id=p_document_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'GOODS_RECEIPT_NOT_FOUND'; END IF;
    IF v_old.status<>'DRAFT' THEN RAISE EXCEPTION 'FINAL_GOODS_RECEIPT_IMMUTABLE'; END IF;
    IF v_old.source_channel<>'BACKOFFICE' OR v_old.received_by<>v_actor
      OR v_old.supplier_order_id<>p_supplier_order_id THEN
      RAISE EXCEPTION 'GOODS_RECEIPT_OWNER_SCOPE_INVALID'; END IF;
    IF p_master_version IS DISTINCT FROM v_old.master_version THEN
      RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
    v_before:=to_jsonb(v_old);v_doc:=v_old.id;
    DELETE FROM public.goods_receipt_condition_allocations allocation
    USING public.goods_receipt_lines line
    WHERE allocation.company_id=v_company AND line.company_id=allocation.company_id
      AND line.id=allocation.receipt_line_id AND line.document_id=v_doc;
    DELETE FROM public.goods_receipt_lines line
    WHERE line.company_id=v_company AND line.document_id=v_doc;
  END IF;
  FOR v_line IN SELECT * FROM jsonb_to_recordset(p_lines) AS x(
    "clientLineKey" UUID,"supplierOrderLineId" UUID,"receivedUomId" UUID,
    "receivedQty" NUMERIC,"acceptedGoodQty" NUMERIC,"damagedQty" NUMERIC,
    "rejectedQty" NUMERIC) LOOP
    v_n:=v_n+1;
    SELECT line.*,product.uom_id,product.sku,product.name,base.name base_name
    INTO v_source FROM public.supplier_order_lines line
    JOIN public.products product ON product.company_id=line.company_id
      AND product.id=line.product_id AND product.is_active AND NOT product.is_bundle
    JOIN public.uoms base ON base.company_id=product.company_id
      AND base.id=product.uom_id AND base.is_active
    WHERE line.company_id=v_company AND line.id=v_line."supplierOrderLineId"
      AND line.document_id=v_order.id;
    IF NOT FOUND THEN RAISE EXCEPTION 'SUPPLIER_ORDER_LINE_NOT_FOUND'; END IF;
    SELECT product_uom.factor_to_base,uom.name,uom.allow_decimal,
      uom.decimal_precision INTO v_uom FROM public.product_uoms product_uom
    JOIN public.uoms uom ON uom.company_id=product_uom.company_id
      AND uom.id=product_uom.uom_id
    WHERE product_uom.company_id=v_company AND product_uom.product_id=v_source.product_id
      AND product_uom.uom_id=v_line."receivedUomId" AND product_uom.is_active
      AND product_uom.purchase_allowed AND uom.is_active;
    IF NOT FOUND THEN RAISE EXCEPTION 'ACTIVE_PURCHASE_PRODUCT_UOM_NOT_FOUND'; END IF;
    IF v_line."receivedQty"<=0 THEN RAISE EXCEPTION 'GOODS_RECEIPT_QUANTITY_INVALID'; END IF;
    v_line."acceptedGoodQty":=COALESCE(v_line."acceptedGoodQty",v_line."receivedQty");
    v_line."damagedQty":=COALESCE(v_line."damagedQty",0);
    v_line."rejectedQty":=COALESCE(v_line."rejectedQty",0);
    IF v_line."acceptedGoodQty"<0 OR v_line."damagedQty"<0
      OR v_line."rejectedQty"<0 OR v_line."acceptedGoodQty"+
        v_line."damagedQty"+v_line."rejectedQty"<>v_line."receivedQty" THEN
      RAISE EXCEPTION 'GOODS_RECEIPT_CONDITION_TOTAL_INVALID'; END IF;
    IF NOT v_uom.allow_decimal AND (v_line."receivedQty"<>trunc(v_line."receivedQty")
      OR v_line."acceptedGoodQty"<>trunc(v_line."acceptedGoodQty")
      OR v_line."damagedQty"<>trunc(v_line."damagedQty")
      OR v_line."rejectedQty"<>trunc(v_line."rejectedQty")) THEN
      RAISE EXCEPTION 'PURCHASE_UOM_REQUIRES_INTEGER'; END IF;
    v_received_base:=v_line."receivedQty"*v_uom.factor_to_base;
    v_good_base:=v_line."acceptedGoodQty"*v_uom.factor_to_base;
    v_damaged_base:=v_line."damagedQty"*v_uom.factor_to_base;
    v_rejected_base:=v_line."rejectedQty"*v_uom.factor_to_base;
    SELECT COALESCE(sum(receipt_line.received_base_qty),0) INTO v_prior
    FROM public.goods_receipt_lines receipt_line
    JOIN public.goods_receipt_documents receipt ON receipt.company_id=receipt_line.company_id
      AND receipt.id=receipt_line.document_id
    WHERE receipt_line.company_id=v_company
      AND receipt_line.supplier_order_line_id=v_source.id AND receipt.status='POSTED';
    v_over:=GREATEST(v_prior+v_received_base-v_source.ordered_base_qty,0);
    INSERT INTO public.goods_receipt_lines(company_id,document_id,line_no,
      client_line_key,supplier_order_line_id,product_id,received_uom_id,
      received_qty,factor_to_base_snapshot,received_base_qty,accepted_good_qty,
      damaged_qty,rejected_qty,accepted_good_base_qty,damaged_base_qty,
      rejected_base_qty,estimated_unit_price_snapshot,estimated_base_unit_cost,
      provisional_ap_amount,is_over_received,over_received_base_qty,
      product_sku_snapshot,product_name_snapshot,received_uom_name_snapshot,
      base_uom_id,base_uom_name_snapshot)
    VALUES(v_company,v_doc,v_n,v_line."clientLineKey",v_source.id,
      v_source.product_id,v_line."receivedUomId",v_line."receivedQty",
      v_uom.factor_to_base,v_received_base,v_line."acceptedGoodQty",
      v_line."damagedQty",v_line."rejectedQty",v_good_base,v_damaged_base,
      v_rejected_base,v_source.estimated_unit_price,
      v_source.estimated_unit_price/v_source.factor_to_base_snapshot,
      round((v_good_base+v_damaged_base)*
        (v_source.estimated_unit_price/v_source.factor_to_base_snapshot),4),
      v_over>0,v_over,v_source.product_sku_snapshot,v_source.product_name_snapshot,
      v_uom.name,v_source.uom_id,v_source.base_name) RETURNING id INTO v_line_id;
    IF v_good_base>0 THEN
      INSERT INTO public.goods_receipt_condition_allocations(company_id,
        receipt_line_id,condition_type,warehouse_id,quantity_base)
      VALUES(v_company,v_line_id,'GOOD',v_order.destination_warehouse_id,v_good_base);
    END IF;
    IF v_damaged_base>0 THEN
      INSERT INTO public.goods_receipt_condition_allocations(company_id,
        receipt_line_id,condition_type,warehouse_id,quantity_base)
      SELECT v_company,v_line_id,'DAMAGED',warehouse.id,v_damaged_base
      FROM public.warehouses warehouse WHERE warehouse.company_id=v_company
        AND warehouse.is_active AND warehouse.warehouse_type='DAMAGED'
        AND (warehouse.store_id=v_order.store_id OR warehouse.store_id IS NULL)
      ORDER BY (warehouse.store_id=v_order.store_id) DESC,warehouse.id LIMIT 1;
      IF NOT FOUND THEN RAISE EXCEPTION 'ACTIVE_DAMAGED_WAREHOUSE_NOT_FOUND'; END IF;
    END IF;
    IF v_rejected_base>0 THEN
      INSERT INTO public.goods_receipt_condition_allocations(company_id,
        receipt_line_id,condition_type,warehouse_id,quantity_base)
      VALUES(v_company,v_line_id,'REJECTED',NULL,v_rejected_base);
    END IF;
    v_received:=v_received+v_received_base;v_good:=v_good+v_good_base;
    v_damaged:=v_damaged+v_damaged_base;v_rejected:=v_rejected+v_rejected_base;
    v_ap:=v_ap+round((v_good_base+v_damaged_base)*
      (v_source.estimated_unit_price/v_source.factor_to_base_snapshot),4);
  END LOOP;
  UPDATE public.goods_receipt_documents document SET
    supplier_delivery_no=NULLIF(btrim(p_supplier_delivery_no),''),
    notes=NULLIF(btrim(p_notes),''),line_count=v_n,
    received_total_base_qty=v_received,accepted_total_base_qty=v_good,
    damaged_total_base_qty=v_damaged,rejected_total_base_qty=v_rejected,
    provisional_ap_total=v_ap,has_over_receipt=EXISTS(SELECT 1
      FROM public.goods_receipt_lines line WHERE line.document_id=v_doc
        AND line.is_over_received),
    master_version=CASE WHEN p_document_id IS NULL THEN document.master_version
      ELSE document.master_version+1 END,updated_at=clock_timestamp()
  WHERE document.company_id=v_company AND document.id=v_doc
  RETURNING document.master_version INTO v_version;
  INSERT INTO public.goods_receipt_audit(company_id,document_id,action,actor_id,
    before_state,after_state) SELECT v_company,v_doc,
      CASE WHEN p_document_id IS NULL THEN 'CREATE' ELSE 'UPDATE' END,
      v_actor,v_before,to_jsonb(document)
    FROM public.goods_receipt_documents document WHERE document.id=v_doc;
  RETURN jsonb_build_object('documentId',v_doc,'receiptNo',COALESCE(v_no,v_old.receipt_no),
    'status','DRAFT','masterVersion',v_version);
END $$;

-- Preserve the proven posting/cancel implementation as a private core, then
-- put channel-aware authorization in front of the old public signatures.
ALTER FUNCTION public.post_goods_receipt(UUID,BIGINT,UUID)
  RENAME TO backoffice_channel_post_goods_receipt_core;
ALTER FUNCTION public.backoffice_channel_post_goods_receipt_core(UUID,BIGINT,UUID)
  SET SCHEMA private;
ALTER FUNCTION public.cancel_goods_receipt(UUID,BIGINT)
  RENAME TO backoffice_channel_cancel_goods_receipt_core;
ALTER FUNCTION public.backoffice_channel_cancel_goods_receipt_core(UUID,BIGINT)
  SET SCHEMA private;

CREATE FUNCTION public.post_goods_receipt(
  p_document_id UUID,p_master_version BIGINT,p_idempotency_key UUID
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_channel TEXT;
BEGIN
  SELECT document.source_channel INTO v_channel
  FROM public.goods_receipt_documents document
  WHERE document.company_id=v_company AND document.id=p_document_id;
  IF v_channel IS NULL THEN RAISE EXCEPTION 'GOODS_RECEIPT_NOT_FOUND'; END IF;
  IF v_channel='BACKOFFICE' THEN
    PERFORM private.acp_require_permission_capability(
      v_company,'purchase.goods_receipts','POST');
  END IF;
  RETURN private.backoffice_channel_post_goods_receipt_core(
    p_document_id,p_master_version,p_idempotency_key);
END $$;

CREATE FUNCTION public.cancel_goods_receipt(
  p_document_id UUID,p_master_version BIGINT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_channel TEXT;
BEGIN
  SELECT document.source_channel INTO v_channel
  FROM public.goods_receipt_documents document
  WHERE document.company_id=v_company AND document.id=p_document_id;
  IF v_channel IS NULL THEN RAISE EXCEPTION 'GOODS_RECEIPT_NOT_FOUND'; END IF;
  IF v_channel='BACKOFFICE' THEN
    PERFORM private.acp_require_permission_capability(
      v_company,'purchase.goods_receipts','CANCEL_FINAL');
  END IF;
  RETURN private.backoffice_channel_cancel_goods_receipt_core(
    p_document_id,p_master_version);
END $$;

CREATE FUNCTION public.post_backoffice_goods_receipt(
  p_document_id UUID,p_master_version BIGINT,p_idempotency_key UUID
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_document RECORD;
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'purchase.goods_receipts','POST');
  SELECT source_channel,received_by INTO v_document
  FROM public.goods_receipt_documents WHERE company_id=v_company
    AND id=p_document_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'GOODS_RECEIPT_NOT_FOUND'; END IF;
  IF v_document.source_channel<>'BACKOFFICE' OR v_document.received_by<>auth.uid()
    THEN RAISE EXCEPTION 'GOODS_RECEIPT_OWNER_SCOPE_INVALID'; END IF;
  RETURN public.post_goods_receipt(p_document_id,p_master_version,p_idempotency_key);
END $$;

CREATE FUNCTION public.cancel_backoffice_goods_receipt(
  p_document_id UUID,p_master_version BIGINT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_document RECORD;
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'purchase.goods_receipts','CANCEL_FINAL');
  SELECT source_channel,received_by INTO v_document
  FROM public.goods_receipt_documents WHERE company_id=v_company
    AND id=p_document_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'GOODS_RECEIPT_NOT_FOUND'; END IF;
  IF v_document.source_channel<>'BACKOFFICE' OR v_document.received_by<>auth.uid()
    THEN RAISE EXCEPTION 'GOODS_RECEIPT_OWNER_SCOPE_INVALID'; END IF;
  RETURN public.cancel_goods_receipt(p_document_id,p_master_version);
END $$;

REVOKE ALL ON FUNCTION public.get_backoffice_goods_receipt_workspace(),
  public.save_backoffice_goods_receipt(UUID,BIGINT,UUID,TEXT,TEXT,JSONB),
  public.post_backoffice_goods_receipt(UUID,BIGINT,UUID),
  public.cancel_backoffice_goods_receipt(UUID,BIGINT)
FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION
  private.backoffice_channel_post_goods_receipt_core(UUID,BIGINT,UUID),
  private.backoffice_channel_cancel_goods_receipt_core(UUID,BIGINT)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.backoffice_channel_post_goods_receipt_core(UUID,BIGINT,UUID),
  private.backoffice_channel_cancel_goods_receipt_core(UUID,BIGINT)
TO service_role;
REVOKE ALL ON FUNCTION public.post_goods_receipt(UUID,BIGINT,UUID),
  public.cancel_goods_receipt(UUID,BIGINT) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_backoffice_goods_receipt_workspace(),
  public.save_backoffice_goods_receipt(UUID,BIGINT,UUID,TEXT,TEXT,JSONB),
  public.post_backoffice_goods_receipt(UUID,BIGINT,UUID),
  public.cancel_backoffice_goods_receipt(UUID,BIGINT),
  public.post_goods_receipt(UUID,BIGINT,UUID),
  public.cancel_goods_receipt(UUID,BIGINT)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260825130000','backoffice_goods_receipt_channel',
  'Adds Warehouse Backoffice Goods Receipt Draft channel while preserving canonical Post stock, FIFO, AP provisional and Finance event effects');
NOTIFY pgrst,'reload schema';
COMMIT;
