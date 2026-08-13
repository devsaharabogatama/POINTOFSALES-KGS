-- ACP-4E: enforce Stock Transfer read and mutation capabilities.

BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260812160000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: ACP-4D required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260812170000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED';
  END IF;
  IF (SELECT count(*) FROM public.access_permission_catalog
      WHERE permission_key='inventory.stock_transfers'
        AND enforcement_status='SHADOW')<>1 THEN
    RAISE EXCEPTION 'STOCK_TRANSFER_PERMISSION_NOT_SHADOW';
  END IF;
END
$guard$;

-- Preserve the proven atomic/FIFO implementations as private cores.
ALTER FUNCTION public.save_stock_transfer_document(
  UUID,BIGINT,UUID,UUID,DATE,TEXT,JSONB
) SET SCHEMA private;
ALTER FUNCTION public.post_stock_transfer(UUID,BIGINT,UUID) SET SCHEMA private;
ALTER FUNCTION public.cancel_stock_transfer(UUID,BIGINT) SET SCHEMA private;

CREATE FUNCTION public.save_stock_transfer_document(
  p_document_id UUID,p_master_version BIGINT,
  p_source_warehouse_id UUID,p_destination_warehouse_id UUID,
  p_transfer_date DATE,p_notes TEXT,p_lines JSONB
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'inventory.stock_transfers',
    CASE WHEN p_document_id IS NULL THEN 'CREATE_DRAFT' ELSE 'EDIT_DRAFT' END);
  RETURN private.save_stock_transfer_document(
    p_document_id,p_master_version,p_source_warehouse_id,
    p_destination_warehouse_id,p_transfer_date,p_notes,p_lines);
END
$$;

CREATE FUNCTION public.post_stock_transfer(
  p_document_id UUID,p_master_version BIGINT,p_idempotency_key UUID
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'inventory.stock_transfers','POST');
  RETURN private.post_stock_transfer(
    p_document_id,p_master_version,p_idempotency_key);
END
$$;

CREATE FUNCTION public.cancel_stock_transfer(
  p_document_id UUID,p_master_version BIGINT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'inventory.stock_transfers','CANCEL_FINAL');
  RETURN private.cancel_stock_transfer(p_document_id,p_master_version);
END
$$;

CREATE FUNCTION public.get_inventory_stock_transfers()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE
  v_company UUID:=public.private_active_company_id();
  v_documents JSONB;v_lines JSONB;v_allocations JSONB;
  v_balances JSONB;v_movements JSONB;v_products JSONB;v_warehouses JSONB;
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'inventory.stock_transfers','VIEW');

  SELECT COALESCE(jsonb_agg(to_jsonb(document_row)
    ORDER BY document_row.created_at DESC,document_row.id),'[]'::JSONB)
  INTO v_documents FROM (
    SELECT document.id,document.company_id,document.document_no,
      document.source_warehouse_id,document.destination_warehouse_id,
      document.transfer_date,document.status,document.notes,
      document.line_count,document.total_quantity_base,document.total_cost,
      document.master_version,document.posted_at,document.canceled_at,
      document.created_at,document.updated_at
    FROM public.stock_transfer_documents document
    WHERE document.company_id=v_company
    ORDER BY document.created_at DESC,document.id LIMIT 500
  ) document_row;

  SELECT COALESCE(jsonb_agg(to_jsonb(line_row)
    ORDER BY line_row.document_id,line_row.line_no),'[]'::JSONB)
  INTO v_lines FROM (
    SELECT line.id,line.company_id,line.document_id,line.line_no,
      line.product_id,line.base_uom_id,line.quantity_base,
      line.transferred_cost,line.fifo_layer_count,
      line.product_sku_snapshot,line.product_name_snapshot,
      line.base_uom_name_snapshot,line.notes,line.created_at
    FROM public.stock_transfer_lines line
    WHERE line.company_id=v_company AND line.document_id IN(
      SELECT document.id FROM public.stock_transfer_documents document
      WHERE document.company_id=v_company
      ORDER BY document.created_at DESC,document.id LIMIT 500)
    ORDER BY line.document_id,line.line_no LIMIT 10000
  ) line_row;

  SELECT COALESCE(jsonb_agg(to_jsonb(allocation_row)
    ORDER BY allocation_row.created_at,allocation_row.id),'[]'::JSONB)
  INTO v_allocations FROM (
    SELECT allocation.id,allocation.document_id,allocation.line_id,
      allocation.quantity_base,allocation.unit_cost_base,
      allocation.total_cost,allocation.created_at
    FROM public.stock_transfer_fifo_allocations allocation
    WHERE allocation.company_id=v_company AND allocation.document_id IN(
      SELECT document.id FROM public.stock_transfer_documents document
      WHERE document.company_id=v_company
      ORDER BY document.created_at DESC,document.id LIMIT 500)
    ORDER BY allocation.created_at,allocation.id LIMIT 20000
  ) allocation_row;

  SELECT COALESCE(jsonb_agg(to_jsonb(balance_row)),'[]'::JSONB)
  INTO v_balances FROM (
    SELECT stock.product_id,stock.warehouse_id,stock.stock_qty,stock.updated_at
    FROM public.product_stocks stock WHERE stock.company_id=v_company
    LIMIT 10000
  ) balance_row;

  SELECT COALESCE(jsonb_agg(to_jsonb(movement_row)
    ORDER BY movement_row.posted_at DESC,movement_row.id DESC),'[]'::JSONB)
  INTO v_movements FROM (
    SELECT movement.id,movement.product_id,movement.warehouse_id,
      movement.qty_change,movement.movement_type,movement.reference_table,
      movement.reference_id,movement.balance_after_base_qty,movement.posted_at
    FROM public.stock_movements movement
    WHERE movement.company_id=v_company
      AND movement.reference_table='stock_transfer_documents'
    ORDER BY movement.posted_at DESC,movement.id DESC LIMIT 20000
  ) movement_row;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',product_row.id,'sku',product_row.sku,'name',product_row.name,
    'uom_id',product_row.uom_id,'is_bundle',product_row.is_bundle,
    'is_active',product_row.is_active,'product_uoms',product_row.product_uoms)
    ORDER BY product_row.name,product_row.id),'[]'::JSONB)
  INTO v_products FROM (
    SELECT product.id,product.sku,product.name,product.uom_id,
      product.is_bundle,product.is_active,
      COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'uom_id',product_uom.uom_id,
        'factor_to_base',product_uom.factor_to_base,
        'is_active',product_uom.is_active,
        'uom',jsonb_build_object(
          'id',uom.id,'name',uom.name,'allow_decimal',uom.allow_decimal,
          'decimal_precision',uom.decimal_precision,'is_active',uom.is_active)))
        FROM public.product_uoms product_uom
        JOIN public.uoms uom ON uom.company_id=product_uom.company_id
          AND uom.id=product_uom.uom_id
        WHERE product_uom.company_id=v_company
          AND product_uom.product_id=product.id
          AND product_uom.uom_id=product.uom_id
          AND product_uom.factor_to_base=1),'[]'::JSONB) product_uoms
    FROM public.products product WHERE product.company_id=v_company
    ORDER BY product.name,product.id LIMIT 10000
  ) product_row;

  SELECT COALESCE(jsonb_agg(to_jsonb(warehouse_row)
    ORDER BY warehouse_row.name,warehouse_row.id),'[]'::JSONB)
  INTO v_warehouses FROM (
    SELECT warehouse.id,warehouse.name,warehouse.warehouse_type,
      warehouse.location,warehouse.is_active
    FROM public.warehouses warehouse WHERE warehouse.company_id=v_company
    ORDER BY warehouse.name,warehouse.id LIMIT 5000
  ) warehouse_row;

  RETURN jsonb_build_object(
    'companyId',v_company,'data',v_documents,'lines',v_lines,
    'allocations',v_allocations,'balances',v_balances,'movements',v_movements,
    'products',v_products,'warehouses',v_warehouses);
END
$$;

DO $enforce$
DECLARE v_rows BIGINT;
BEGIN
  UPDATE public.access_permission_catalog SET
    enforcement_status='ENFORCED',catalog_version=catalog_version+1,
    updated_at=clock_timestamp()
  WHERE permission_key='inventory.stock_transfers'
    AND enforcement_status='SHADOW';
  GET DIAGNOSTICS v_rows=ROW_COUNT;
  IF v_rows<>1 THEN RAISE EXCEPTION 'STOCK_TRANSFER_PERMISSION_CUTOVER_FAILED'; END IF;
END
$enforce$;

REVOKE SELECT ON public.stock_transfer_documents,public.stock_transfer_lines,
  public.stock_transfer_fifo_allocations,public.stock_transfer_audit
FROM authenticated;

REVOKE ALL ON FUNCTION
  private.save_stock_transfer_document(UUID,BIGINT,UUID,UUID,DATE,TEXT,JSONB),
  private.post_stock_transfer(UUID,BIGINT,UUID),
  private.cancel_stock_transfer(UUID,BIGINT)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.save_stock_transfer_document(UUID,BIGINT,UUID,UUID,DATE,TEXT,JSONB),
  private.post_stock_transfer(UUID,BIGINT,UUID),
  private.cancel_stock_transfer(UUID,BIGINT)
TO service_role;

REVOKE ALL ON FUNCTION
  public.save_stock_transfer_document(UUID,BIGINT,UUID,UUID,DATE,TEXT,JSONB),
  public.post_stock_transfer(UUID,BIGINT,UUID),
  public.cancel_stock_transfer(UUID,BIGINT),
  public.get_inventory_stock_transfers()
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION
  public.save_stock_transfer_document(UUID,BIGINT,UUID,UUID,DATE,TEXT,JSONB),
  public.post_stock_transfer(UUID,BIGINT,UUID),
  public.cancel_stock_transfer(UUID,BIGINT),
  public.get_inventory_stock_transfers()
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260812170000','acp_phase4e_stock_transfer_permission_enforcement',
  'Enforced Stock Transfer VIEW and Draft/Post/Cancel capabilities through guarded composed RPCs while preserving atomic FIFO and Movement cores');

COMMIT;
