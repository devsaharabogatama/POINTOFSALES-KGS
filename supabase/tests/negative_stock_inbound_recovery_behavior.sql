-- Rollback-only behavior: inbound recovery is allowed; unauthorized outbound
-- negative Stock remains blocked. Run the entire file.
BEGIN;

DO $test$
DECLARE
  v_company uuid;v_product uuid;v_warehouse uuid;v_uom uuid;v_uom_name text;
  v_actor uuid;v_inbound uuid:=gen_random_uuid();v_blocked boolean:=false;
BEGIN
  SELECT stock.company_id,stock.product_id,stock.warehouse_id,product.uom_id,
    uom.name INTO v_company,v_product,v_warehouse,v_uom,v_uom_name
  FROM public.product_stocks stock
  JOIN public.products product ON product.company_id=stock.company_id
    AND product.id=stock.product_id
  JOIN public.warehouses warehouse ON warehouse.company_id=stock.company_id
    AND warehouse.id=stock.warehouse_id
  JOIN public.uoms uom ON uom.company_id=product.company_id AND uom.id=product.uom_id
  WHERE product.is_active AND warehouse.is_active
  ORDER BY stock.company_id,stock.product_id,stock.warehouse_id LIMIT 1;
  SELECT profile.id INTO v_actor FROM public.profiles profile
  ORDER BY CASE WHEN profile.role='super_admin'::public.user_role THEN 0 ELSE 1 END,
    profile.created_at,profile.id LIMIT 1;
  IF v_company IS NULL OR v_actor IS NULL THEN
    RAISE EXCEPTION 'TEST_SETUP_FAILED: active Product Stock, Warehouse, UOM and Profile required';
  END IF;

  INSERT INTO public.stock_movements(id,product_id,warehouse_id,qty_change,
    movement_type,reference_table,reference_id,company_id,base_uom_id,
    base_uom_name_snapshot,balance_after_base_qty,actor_id,posted_at,
    movement_status,source_line_id,notes)
  VALUES(v_inbound,v_product,v_warehouse,1,'PURCHASE'::public.stock_movement_type,
    'negative_stock_inbound_recovery_test',gen_random_uuid(),v_company,v_uom,
    v_uom_name,-1,v_actor,clock_timestamp(),'POSTED',gen_random_uuid(),
    'Rollback-only inbound recovery behavior');
  IF NOT EXISTS(SELECT 1 FROM public.stock_movements WHERE id=v_inbound
      AND qty_change=1 AND balance_after_base_qty=-1) THEN
    RAISE EXCEPTION 'TEST_FAILED: positive inbound movement was not accepted';
  END IF;

  BEGIN
    INSERT INTO public.stock_movements(product_id,warehouse_id,qty_change,
      movement_type,reference_table,reference_id,company_id,base_uom_id,
      base_uom_name_snapshot,balance_after_base_qty,actor_id,posted_at,
      movement_status,source_line_id,notes)
    VALUES(v_product,v_warehouse,-1,'SALE'::public.stock_movement_type,
      'sales_headers',gen_random_uuid(),v_company,v_uom,v_uom_name,-2,v_actor,
      clock_timestamp(),'POSTED',gen_random_uuid(),
      'Rollback-only unauthorized outbound behavior');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%NEGATIVE_STOCK_AUTHORIZATION_REQUIRED%' THEN
      v_blocked:=true;
    ELSE
      RAISE;
    END IF;
  END;
  IF NOT v_blocked THEN
    RAISE EXCEPTION 'TEST_FAILED: unauthorized outbound negative movement accepted';
  END IF;
END
$test$;

SELECT 'negative_stock_inbound_recovery_behavior' check_name,'PASS' status,
  0::bigint violation_rows,jsonb_build_object('tested',ARRAY[
    'positive Purchase movement may improve a still-negative balance',
    'unauthorized outbound Sale ending negative remains blocked',
    'all fixture writes rolled back']) details;

ROLLBACK;
