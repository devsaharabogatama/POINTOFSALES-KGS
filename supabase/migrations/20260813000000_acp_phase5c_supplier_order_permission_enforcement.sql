-- ACP-5C: enforce Supplier Order without widening Cashier/Purchase consumers.

BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260812230000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: ACP-5B required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260813000000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED';
  END IF;
  IF (SELECT count(*) FROM public.access_permission_catalog
    WHERE permission_key='purchase.supplier_orders'
      AND enforcement_status='SHADOW')<>1 THEN
    RAISE EXCEPTION 'SUPPLIER_ORDER_PERMISSION_NOT_SHADOW';
  END IF;
  IF EXISTS(SELECT 1 FROM public.supplier_order_lines line
    JOIN public.supplier_order_documents document
      ON document.company_id=line.company_id AND document.id=line.document_id
    LEFT JOIN public.supplier_order_request_allocations allocation
      ON allocation.company_id=line.company_id
     AND allocation.supplier_order_line_id=line.id
    WHERE document.status IN('CONFIRMED','PARTIALLY_RECEIVED','RECEIVED')
    GROUP BY line.id,line.ordered_base_qty
    HAVING COALESCE(sum(allocation.allocated_base_qty),0)<>line.ordered_base_qty
  ) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: order allocation mismatch';
  END IF;
END
$guard$;

CREATE FUNCTION public.get_purchase_supplier_orders()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'purchase.supplier_orders','VIEW');
  RETURN jsonb_build_object(
    'companyId',v_company,
    'requests',(SELECT COALESCE(jsonb_agg(to_jsonb(request_row)
      ORDER BY request_row.requested_at DESC,request_row.id),'[]'::JSONB)
      FROM (SELECT document.id,document.request_no,document.store_id,
          document.needed_date,document.notes,document.status,
          document.line_count,document.requested_total_base_qty,
          document.master_version,document.requested_at
        FROM public.stock_request_documents document
        WHERE document.company_id=v_company
          AND document.status IN('SUBMITTED','ORDERED')
        ORDER BY document.requested_at DESC,document.id LIMIT 500) request_row),
    'requestLines',(SELECT COALESCE(jsonb_agg(to_jsonb(line_row)
      ORDER BY line_row.document_id,line_row.line_no),'[]'::JSONB)
      FROM (SELECT line.id,line.document_id,line.line_no,line.product_id,
          line.requested_uom_id,line.requested_qty,
          line.factor_to_base_snapshot,line.requested_base_qty,
          line.product_sku_snapshot,line.product_name_snapshot,
          line.requested_uom_name_snapshot,line.notes
        FROM public.stock_request_lines line
        JOIN public.stock_request_documents document
          ON document.company_id=line.company_id AND document.id=line.document_id
        WHERE line.company_id=v_company
          AND document.status IN('SUBMITTED','ORDERED')
        ORDER BY line.document_id,line.line_no LIMIT 10000) line_row),
    'orders',(SELECT COALESCE(jsonb_agg(to_jsonb(order_row)
      ORDER BY order_row.created_at DESC,order_row.id),'[]'::JSONB)
      FROM (SELECT document.id,document.order_no,document.store_id,
          document.destination_warehouse_id,document.supplier_id,
          document.order_date,document.expected_date,document.status,
          document.notes,document.line_count,document.total_ordered_base_qty,
          document.estimated_total,document.master_version,document.created_at
        FROM public.supplier_order_documents document
        WHERE document.company_id=v_company
        ORDER BY document.created_at DESC,document.id LIMIT 500) order_row),
    'orderLines',(SELECT COALESCE(jsonb_agg(to_jsonb(line_row)
      ORDER BY line_row.document_id,line_row.line_no),'[]'::JSONB)
      FROM (SELECT line.id,line.document_id,line.line_no,line.product_id,
          line.ordered_uom_id,line.ordered_qty,line.ordered_base_qty,
          line.estimated_unit_price,line.estimated_subtotal,
          line.product_name_snapshot,line.ordered_uom_name_snapshot
        FROM public.supplier_order_lines line
        WHERE line.company_id=v_company
        ORDER BY line.document_id,line.line_no LIMIT 10000) line_row),
    'allocations',(SELECT COALESCE(jsonb_agg(to_jsonb(allocation_row)
      ORDER BY allocation_row.id),'[]'::JSONB)
      FROM (SELECT allocation.id,allocation.supplier_order_line_id,
          allocation.stock_request_line_id,allocation.allocated_base_qty
        FROM public.supplier_order_request_allocations allocation
        WHERE allocation.company_id=v_company LIMIT 20000) allocation_row),
    'suppliers',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',supplier.id,'supplier_name',supplier.supplier_name)
      ORDER BY supplier.supplier_name,supplier.id),'[]'::JSONB)
      FROM public.suppliers supplier WHERE supplier.company_id=v_company
        AND supplier.is_active),
    'productSuppliers',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'product_id',relation.product_id,'supplier_id',relation.supplier_id,
      'purchase_uom_id',relation.purchase_uom_id,
      'reference_purchase_price',relation.reference_purchase_price,
      'last_purchase_price',relation.last_purchase_price,
      'is_preferred_supplier',relation.is_preferred_supplier,
      'is_active',relation.is_active)),'[]'::JSONB)
      FROM public.product_suppliers relation
      WHERE relation.company_id=v_company AND relation.is_active),
    'warehouses',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',warehouse.id,'name',warehouse.name,'store_id',warehouse.store_id)
      ORDER BY warehouse.name,warehouse.id),'[]'::JSONB)
      FROM public.warehouses warehouse WHERE warehouse.company_id=v_company
        AND warehouse.is_active AND warehouse.is_purchase_destination),
    'stores',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',store.id,'store_name',store.store_name)
      ORDER BY store.store_name,store.id),'[]'::JSONB)
      FROM public.stores store WHERE store.company_id=v_company
        AND store.status='ACTIVE'),
    'purchaseUoms',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'product_id',product_uom.product_id,'uom_id',product_uom.uom_id,
      'purchase_price',product_uom.purchase_price)),'[]'::JSONB)
      FROM public.product_uoms product_uom
      WHERE product_uom.company_id=v_company AND product_uom.is_active
        AND product_uom.purchase_allowed));
END
$$;

CREATE FUNCTION public.get_pos_stock_request_workspace(
  p_cashier_session_id UUID
) RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_actor UUID:=auth.uid();
  v_store UUID;
BEGIN
  SELECT session.store_id INTO v_store FROM public.cashier_sessions session
  WHERE session.company_id=v_company AND session.id=p_cashier_session_id
    AND session.cashier_id=v_actor AND session.status='OPEN'::public.session_status;
  IF v_store IS NULL THEN RAISE EXCEPTION 'OPEN_CASHIER_SESSION_REQUIRED'; END IF;
  RETURN jsonb_build_object(
    'options',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'product_id',product.id,'uom_id',product_uom.uom_id,'sku',product.sku,
      'product_name',product.name,'uom_name',uom.name,
      'factor_to_base',product_uom.factor_to_base,
      'allow_decimal',uom.allow_decimal,
      'decimal_precision',uom.decimal_precision)
      ORDER BY product.name,uom.name,product.id,product_uom.uom_id),'[]'::JSONB)
      FROM public.products product
      JOIN public.product_uoms product_uom
        ON product_uom.company_id=product.company_id
       AND product_uom.product_id=product.id
      JOIN public.uoms uom ON uom.company_id=product_uom.company_id
        AND uom.id=product_uom.uom_id
      WHERE product.company_id=v_company AND product.is_active
        AND NOT product.is_bundle AND product_uom.is_active
        AND product_uom.purchase_allowed AND uom.is_active),
    'documents',(SELECT COALESCE(jsonb_agg(to_jsonb(document_row)
      ORDER BY document_row.requested_at DESC,document_row.id),'[]'::JSONB)
      FROM (SELECT document.id,document.request_no,document.needed_date,
          document.notes,document.status,document.line_count,
          document.requested_total_base_qty,document.master_version,
          document.requested_at
        FROM public.stock_request_documents document
        WHERE document.company_id=v_company AND document.store_id=v_store
          AND document.requested_by=v_actor
        ORDER BY document.requested_at DESC,document.id LIMIT 100) document_row));
END
$$;

CREATE FUNCTION public.get_pos_goods_receipt_supplier_orders(
  p_cashier_session_id UUID
) RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_actor UUID:=auth.uid();
  v_store UUID;
BEGIN
  SELECT session.store_id INTO v_store FROM public.cashier_sessions session
  WHERE session.company_id=v_company AND session.id=p_cashier_session_id
    AND session.cashier_id=v_actor AND session.status='OPEN'::public.session_status;
  IF v_store IS NULL THEN RAISE EXCEPTION 'OPEN_CASHIER_SESSION_REQUIRED'; END IF;
  RETURN jsonb_build_object(
    'orders',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',document.id,'order_no',document.order_no,
      'supplier_id',document.supplier_id,
      'supplier_name',supplier.supplier_name,
      'destination_warehouse_id',document.destination_warehouse_id,
      'warehouse_name',warehouse.name,'status',document.status,
      'expected_date',document.expected_date)
      ORDER BY document.expected_date NULLS LAST,document.order_no,document.id),
      '[]'::JSONB)
      FROM public.supplier_order_documents document
      JOIN public.suppliers supplier ON supplier.company_id=document.company_id
        AND supplier.id=document.supplier_id
      JOIN public.warehouses warehouse
        ON warehouse.company_id=document.company_id
       AND warehouse.id=document.destination_warehouse_id
      WHERE document.company_id=v_company AND document.store_id=v_store
        AND document.status IN('CONFIRMED','PARTIALLY_RECEIVED')),
    'lines',(SELECT COALESCE(jsonb_agg(to_jsonb(line_row)
      ORDER BY line_row.document_id,line_row.line_no),'[]'::JSONB)
      FROM (SELECT line.id,line.document_id,line.line_no,line.product_id,
          line.ordered_uom_id,line.ordered_qty,line.ordered_base_qty,
          line.product_name_snapshot,line.ordered_uom_name_snapshot
        FROM public.supplier_order_lines line
        JOIN public.supplier_order_documents document
          ON document.company_id=line.company_id AND document.id=line.document_id
        WHERE line.company_id=v_company AND document.store_id=v_store
          AND document.status IN('CONFIRMED','PARTIALLY_RECEIVED')
        ORDER BY line.document_id,line.line_no) line_row));
END
$$;

CREATE FUNCTION public.get_pos_purchase_return_order_references(
  p_cashier_session_id UUID,p_supplier_order_ids UUID[]
) RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_actor UUID:=auth.uid();
  v_store UUID;
BEGIN
  IF COALESCE(cardinality(p_supplier_order_ids),0)>1000 THEN
    RAISE EXCEPTION 'SUPPLIER_ORDER_REFERENCE_LIMIT_EXCEEDED';
  END IF;
  SELECT session.store_id INTO v_store FROM public.cashier_sessions session
  WHERE session.company_id=v_company AND session.id=p_cashier_session_id
    AND session.cashier_id=v_actor AND session.status='OPEN'::public.session_status;
  IF v_store IS NULL THEN RAISE EXCEPTION 'OPEN_CASHIER_SESSION_REQUIRED'; END IF;
  RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object(
    'id',document.id,'order_no',document.order_no,
    'supplier_id',document.supplier_id) ORDER BY document.order_no,document.id)
    FROM public.supplier_order_documents document
    WHERE document.company_id=v_company
      AND document.id=ANY(COALESCE(p_supplier_order_ids,'{}'::UUID[]))
      AND EXISTS(SELECT 1 FROM public.goods_receipt_documents receipt
        WHERE receipt.company_id=v_company AND receipt.store_id=v_store
          AND receipt.supplier_order_id=document.id
          AND receipt.status='POSTED')),'[]'::JSONB);
END
$$;

ALTER FUNCTION public.close_stock_request(UUID,BIGINT)
  RENAME TO acp5c_close_stock_request_core;
ALTER FUNCTION public.acp5c_close_stock_request_core(UUID,BIGINT)
  SET SCHEMA private;
ALTER FUNCTION public.cancel_stock_request(UUID,BIGINT)
  RENAME TO acp5c_cancel_stock_request_core;
ALTER FUNCTION public.acp5c_cancel_stock_request_core(UUID,BIGINT)
  SET SCHEMA private;
ALTER FUNCTION public.save_supplier_order(
  UUID,BIGINT,UUID,UUID,UUID,DATE,DATE,TEXT,JSONB,JSONB)
  RENAME TO acp5c_save_supplier_order_core;
ALTER FUNCTION public.acp5c_save_supplier_order_core(
  UUID,BIGINT,UUID,UUID,UUID,DATE,DATE,TEXT,JSONB,JSONB)
  SET SCHEMA private;
ALTER FUNCTION public.confirm_supplier_order(UUID,BIGINT,UUID)
  RENAME TO acp5c_confirm_supplier_order_core;
ALTER FUNCTION public.acp5c_confirm_supplier_order_core(UUID,BIGINT,UUID)
  SET SCHEMA private;
ALTER FUNCTION public.cancel_supplier_order(UUID,BIGINT,TEXT)
  RENAME TO acp5c_cancel_supplier_order_core;
ALTER FUNCTION public.acp5c_cancel_supplier_order_core(UUID,BIGINT,TEXT)
  SET SCHEMA private;

CREATE FUNCTION public.close_stock_request(
  p_document_id UUID,p_master_version BIGINT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'purchase.supplier_orders','POST');
  RETURN private.acp5c_close_stock_request_core(
    p_document_id,p_master_version);
END
$$;

CREATE FUNCTION public.cancel_stock_request(
  p_document_id UUID,p_master_version BIGINT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_actor UUID:=auth.uid();
  v_requester UUID;
BEGIN
  SELECT document.requested_by INTO v_requester
  FROM public.stock_request_documents document
  WHERE document.company_id=v_company AND document.id=p_document_id;
  IF v_requester IS NULL THEN RAISE EXCEPTION 'STOCK_REQUEST_NOT_FOUND'; END IF;
  IF v_requester<>v_actor THEN
    PERFORM private.acp_require_permission_capability(
      v_company,'purchase.supplier_orders','CANCEL_FINAL');
  END IF;
  RETURN private.acp5c_cancel_stock_request_core(
    p_document_id,p_master_version);
END
$$;

CREATE FUNCTION public.save_supplier_order(
  p_document_id UUID,p_master_version BIGINT,p_store_id UUID,
  p_destination_warehouse_id UUID,p_supplier_id UUID,p_order_date DATE,
  p_expected_date DATE,p_notes TEXT,p_lines JSONB,p_allocations JSONB
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(v_company,
    'purchase.supplier_orders',CASE WHEN p_document_id IS NULL
      THEN 'CREATE_DRAFT' ELSE 'EDIT_DRAFT' END);
  RETURN private.acp5c_save_supplier_order_core(
    p_document_id,p_master_version,p_store_id,p_destination_warehouse_id,
    p_supplier_id,p_order_date,p_expected_date,p_notes,p_lines,p_allocations);
END
$$;

CREATE FUNCTION public.confirm_supplier_order(
  p_document_id UUID,p_master_version BIGINT,p_idempotency_key UUID
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'purchase.supplier_orders','POST');
  RETURN private.acp5c_confirm_supplier_order_core(
    p_document_id,p_master_version,p_idempotency_key);
END
$$;

CREATE FUNCTION public.cancel_supplier_order(
  p_document_id UUID,p_master_version BIGINT,p_reason TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'purchase.supplier_orders','CANCEL_FINAL');
  RETURN private.acp5c_cancel_supplier_order_core(
    p_document_id,p_master_version,p_reason);
END
$$;

DO $enforce$
DECLARE v_rows BIGINT;
BEGIN
  UPDATE public.access_permission_catalog SET
    supported_capabilities=ARRAY[
      'VIEW','CREATE_DRAFT','EDIT_DRAFT','POST','CANCEL_FINAL'
    ]::TEXT[],enforcement_status='ENFORCED',
    catalog_version=catalog_version+1,updated_at=clock_timestamp()
  WHERE permission_key='purchase.supplier_orders'
    AND enforcement_status='SHADOW';
  GET DIAGNOSTICS v_rows=ROW_COUNT;
  IF v_rows<>1 THEN
    RAISE EXCEPTION 'SUPPLIER_ORDER_PERMISSION_CUTOVER_FAILED';
  END IF;
END
$enforce$;

REVOKE SELECT ON public.stock_request_documents,public.stock_request_lines,
  public.supplier_order_documents,public.supplier_order_lines,
  public.supplier_order_request_allocations,public.stock_request_audit,
  public.supplier_order_audit
FROM authenticated;

REVOKE ALL ON FUNCTION
  private.acp5c_close_stock_request_core(UUID,BIGINT),
  private.acp5c_cancel_stock_request_core(UUID,BIGINT),
  private.acp5c_save_supplier_order_core(
    UUID,BIGINT,UUID,UUID,UUID,DATE,DATE,TEXT,JSONB,JSONB),
  private.acp5c_confirm_supplier_order_core(UUID,BIGINT,UUID),
  private.acp5c_cancel_supplier_order_core(UUID,BIGINT,TEXT)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.acp5c_close_stock_request_core(UUID,BIGINT),
  private.acp5c_cancel_stock_request_core(UUID,BIGINT),
  private.acp5c_save_supplier_order_core(
    UUID,BIGINT,UUID,UUID,UUID,DATE,DATE,TEXT,JSONB,JSONB),
  private.acp5c_confirm_supplier_order_core(UUID,BIGINT,UUID),
  private.acp5c_cancel_supplier_order_core(UUID,BIGINT,TEXT)
TO service_role;

REVOKE ALL ON FUNCTION
  public.get_purchase_supplier_orders(),
  public.get_pos_stock_request_workspace(UUID),
  public.get_pos_goods_receipt_supplier_orders(UUID),
  public.get_pos_purchase_return_order_references(UUID,UUID[]),
  public.close_stock_request(UUID,BIGINT),
  public.cancel_stock_request(UUID,BIGINT),
  public.save_supplier_order(
    UUID,BIGINT,UUID,UUID,UUID,DATE,DATE,TEXT,JSONB,JSONB),
  public.confirm_supplier_order(UUID,BIGINT,UUID),
  public.cancel_supplier_order(UUID,BIGINT,TEXT)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION
  public.get_purchase_supplier_orders(),
  public.get_pos_stock_request_workspace(UUID),
  public.get_pos_goods_receipt_supplier_orders(UUID),
  public.get_pos_purchase_return_order_references(UUID,UUID[]),
  public.close_stock_request(UUID,BIGINT),
  public.cancel_stock_request(UUID,BIGINT),
  public.save_supplier_order(
    UUID,BIGINT,UUID,UUID,UUID,DATE,DATE,TEXT,JSONB,JSONB),
  public.confirm_supplier_order(UUID,BIGINT,UUID),
  public.cancel_supplier_order(UUID,BIGINT,TEXT)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260813000000','acp_phase5c_supplier_order_permission_enforcement',
  'Enforced Supplier Order workspace and mutations while preserving Store-scoped Cashier Stock Request, Goods Receipt, Purchase Return, and zero-effect order boundary');

NOTIFY pgrst,'reload schema';
COMMIT;
