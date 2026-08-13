-- ACP-4D: enforce Stock Real and Stock Movement read models.

BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260812150000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: ACP-4C required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260812160000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED';
  END IF;
  IF (SELECT count(*) FROM public.access_permission_catalog
      WHERE permission_key IN('inventory.stock_real','inventory.stock_movements')
        AND enforcement_status='SHADOW')<>2 THEN
    RAISE EXCEPTION 'STOCK_READ_PERMISSION_NOT_SHADOW';
  END IF;
END
$guard$;

CREATE FUNCTION public.get_inventory_stock_overview()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE
  v_company UUID:=public.private_active_company_id();
  v_balances JSONB;
  v_warehouses JSONB;
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'inventory.stock_real','VIEW');

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'id',balance_row.id,
      'product_id',balance_row.product_id,
      'warehouse_id',balance_row.warehouse_id,
      'stock_qty',balance_row.stock_qty,
      'updated_at',balance_row.updated_at,
      'fifo_value',balance_row.fifo_value,
      'minimum_stock_base_qty',balance_row.minimum_stock_base_qty,
      'low_stock_alert_enabled',balance_row.low_stock_alert_enabled,
      'last_movement_type',balance_row.last_movement_type,
      'last_movement_at',balance_row.last_movement_at
    ) ORDER BY balance_row.updated_at DESC,balance_row.id
  ),'[]'::JSONB) INTO v_balances
  FROM (
    SELECT stock.id,stock.product_id,stock.warehouse_id,stock.stock_qty,
      stock.updated_at,COALESCE(fifo.fifo_value,0) fifo_value,
      setting.minimum_stock_base_qty,
      COALESCE(setting.low_stock_alert_enabled,FALSE) low_stock_alert_enabled,
      movement.movement_type::TEXT last_movement_type,
      movement.movement_at last_movement_at
    FROM public.product_stocks stock
    LEFT JOIN LATERAL (
      SELECT COALESCE(sum(batch.qty_remaining*batch.cogs_unit),0) fifo_value
      FROM public.product_batches batch
      WHERE batch.company_id=stock.company_id
        AND batch.product_id=stock.product_id
        AND batch.warehouse_id=stock.warehouse_id
        AND batch.qty_remaining>0
    ) fifo ON TRUE
    LEFT JOIN public.product_warehouse_stock_settings setting
      ON setting.company_id=stock.company_id
     AND setting.product_id=stock.product_id
     AND setting.warehouse_id=stock.warehouse_id
    LEFT JOIN LATERAL (
      SELECT stock_movement.movement_type,
        COALESCE(stock_movement.posted_at,stock_movement.created_at) movement_at
      FROM public.stock_movements stock_movement
      WHERE stock_movement.company_id=stock.company_id
        AND stock_movement.product_id=stock.product_id
        AND stock_movement.warehouse_id=stock.warehouse_id
        AND stock_movement.movement_status='POSTED'
      ORDER BY COALESCE(stock_movement.posted_at,stock_movement.created_at) DESC,
        stock_movement.id DESC
      LIMIT 1
    ) movement ON TRUE
    WHERE stock.company_id=v_company
    ORDER BY stock.updated_at DESC,stock.id
    LIMIT 20000
  ) balance_row;

  SELECT COALESCE(jsonb_agg(to_jsonb(warehouse_row)
    ORDER BY warehouse_row.name,warehouse_row.id),'[]'::JSONB)
  INTO v_warehouses
  FROM (
    SELECT warehouse.id,warehouse.name,warehouse.warehouse_type,
      warehouse.location,warehouse.is_active
    FROM public.warehouses warehouse
    WHERE warehouse.company_id=v_company
    ORDER BY warehouse.name,warehouse.id LIMIT 5000
  ) warehouse_row;

  RETURN jsonb_build_object(
    'companyId',v_company,'balances',v_balances,'warehouses',v_warehouses);
END
$$;

CREATE FUNCTION public.get_inventory_stock_movements()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE
  v_company UUID:=public.private_active_company_id();
  v_movements JSONB;v_products JSONB;v_warehouses JSONB;
  v_opening JSONB;v_transfers JSONB;v_adjustments JSONB;v_actors JSONB;
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'inventory.stock_movements','VIEW');

  SELECT COALESCE(jsonb_agg(to_jsonb(movement_row)
    ORDER BY COALESCE(movement_row.posted_at,movement_row.created_at) DESC,
      movement_row.id DESC),'[]'::JSONB)
  INTO v_movements FROM (
    SELECT movement.id,movement.product_id,movement.warehouse_id,
      movement.qty_change,movement.movement_type,movement.reference_table,
      movement.reference_id,movement.created_at,
      movement.base_uom_name_snapshot,movement.balance_after_base_qty,
      movement.actor_id,movement.posted_at,movement.movement_status,movement.notes
    FROM public.stock_movements movement
    WHERE movement.company_id=v_company
    ORDER BY COALESCE(movement.posted_at,movement.created_at) DESC,
      movement.id DESC LIMIT 20000
  ) movement_row;

  SELECT COALESCE(jsonb_agg(to_jsonb(product_row)
    ORDER BY product_row.name,product_row.id),'[]'::JSONB)
  INTO v_products FROM (
    SELECT product.id,product.sku,product.name,product.is_active
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

  SELECT COALESCE(jsonb_agg(to_jsonb(document_row)),'[]'::JSONB)
  INTO v_opening FROM (
    SELECT document.id,document.document_no,document.status
    FROM public.opening_stock_documents document
    WHERE document.company_id=v_company LIMIT 10000
  ) document_row;
  SELECT COALESCE(jsonb_agg(to_jsonb(document_row)),'[]'::JSONB)
  INTO v_transfers FROM (
    SELECT document.id,document.document_no,document.status
    FROM public.stock_transfer_documents document
    WHERE document.company_id=v_company LIMIT 10000
  ) document_row;
  SELECT COALESCE(jsonb_agg(to_jsonb(document_row)),'[]'::JSONB)
  INTO v_adjustments FROM (
    SELECT document.id,document.document_no,document.status
    FROM public.stock_adjustment_documents document
    WHERE document.company_id=v_company LIMIT 10000
  ) document_row;

  SELECT COALESCE(jsonb_agg(to_jsonb(actor_row)
    ORDER BY actor_row.name,actor_row.id),'[]'::JSONB)
  INTO v_actors FROM (
    SELECT DISTINCT profile.id,profile.name
    FROM public.stock_movements movement
    JOIN public.profiles profile ON profile.id=movement.actor_id
    WHERE movement.company_id=v_company
  ) actor_row;

  RETURN jsonb_build_object(
    'companyId',v_company,'data',v_movements,'products',v_products,
    'warehouses',v_warehouses,'openingDocuments',v_opening,
    'transferDocuments',v_transfers,'adjustmentDocuments',v_adjustments,
    'actors',v_actors);
END
$$;

DO $enforce$
DECLARE v_rows BIGINT;
BEGIN
  UPDATE public.access_permission_catalog SET
    enforcement_status='ENFORCED',catalog_version=catalog_version+1,
    updated_at=clock_timestamp()
  WHERE permission_key IN('inventory.stock_real','inventory.stock_movements')
    AND enforcement_status='SHADOW';
  GET DIAGNOSTICS v_rows=ROW_COUNT;
  IF v_rows<>2 THEN RAISE EXCEPTION 'STOCK_READ_PERMISSION_CUTOVER_FAILED'; END IF;
END
$enforce$;

REVOKE ALL ON FUNCTION public.get_inventory_stock_overview(),
  public.get_inventory_stock_movements() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_inventory_stock_overview(),
  public.get_inventory_stock_movements() TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260812160000','acp_phase4d_stock_read_model_enforcement',
  'Enforced Stock Real and Stock Movement read models with guarded composed RPCs and separate export authority');

COMMIT;
