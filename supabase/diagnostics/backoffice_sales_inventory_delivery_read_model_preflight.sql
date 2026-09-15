-- Read-only preflight for Backoffice Delivery visibility in Inventory.
WITH dependency AS (
  SELECT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260909148000') inventory_reservation_read_model,
    to_regprocedure('public.get_inventory_delivery_documents(date,date)') IS NOT NULL
      retail_delivery_reader,
    to_regprocedure('public.get_inventory_stock_overview()') IS NOT NULL
      stock_reader
), checks AS (
  SELECT 'backoffice_delivery_read_dependencies'::text check_name,
    CASE WHEN inventory_reservation_read_model AND retail_delivery_reader
      AND stock_reader THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('inventoryReservationReadModel',inventory_reservation_read_model,
      'retailDeliveryReader',retail_delivery_reader,'stockReader',stock_reader) details
  FROM dependency
  UNION ALL
  SELECT 'backoffice_delivery_header_line_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('deliveryCount',count(*))
  FROM (SELECT delivery.id
    FROM public.backoffice_sales_delivery_orders delivery
    LEFT JOIN public.backoffice_sales_delivery_order_lines line
      ON line.company_id=delivery.company_id
     AND line.delivery_order_id=delivery.id
    GROUP BY delivery.id,delivery.total_planned_base_qty,
      delivery.total_shipped_base_qty,delivery.total_received_base_qty
    HAVING round(COALESCE(sum(line.planned_base_qty),0),6)<>
        round(delivery.total_planned_base_qty,6)
      OR round(COALESCE(sum(line.shipped_base_qty),0),6)<>
        round(delivery.total_shipped_base_qty,6)
      OR round(COALESCE(sum(line.received_base_qty),0),6)<>
        round(delivery.total_received_base_qty,6)) invalid
  UNION ALL
  SELECT 'backoffice_delivery_quantity_shape',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('lineCount',count(*))
  FROM public.backoffice_sales_delivery_order_lines line
  WHERE line.base_qty_per_uom<=0 OR line.planned_qty_uom<=0
    OR line.planned_base_qty<=0 OR line.shipped_base_qty<0
    OR line.received_base_qty<0
  UNION ALL
  SELECT 'backoffice_delivery_browser_table_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('privilegeRows',count(*))
  FROM information_schema.role_table_grants privilege
  WHERE privilege.table_schema='public'
    AND privilege.table_name IN('backoffice_sales_delivery_orders',
      'backoffice_sales_delivery_order_lines')
    AND privilege.grantee IN('anon','authenticated','PUBLIC')
), inventory AS (
  SELECT 'backoffice_delivery_read_inventory'::text check_name,'INFO'::text status,
    jsonb_build_object(
      'deliveries',(SELECT count(*) FROM public.backoffice_sales_delivery_orders),
      'lines',(SELECT count(*) FROM public.backoffice_sales_delivery_order_lines),
      'ready',(SELECT count(*) FROM public.backoffice_sales_delivery_orders
        WHERE status='READY'),
      'rule','Visibility only; operational mutation remains closed') details
)
SELECT * FROM (SELECT * FROM checks UNION ALL SELECT * FROM inventory) result
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;

