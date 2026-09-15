-- Read-only preflight for dedicated Transit usage foundation.
WITH checks AS (
  SELECT 'transit_foundation_dependencies'::text check_name,
    CASE WHEN to_regprocedure('private.save_inventory_warehouse(uuid,bigint,text,text,uuid,text,boolean,boolean,boolean)') IS NOT NULL
      AND to_regprocedure('private.allocate_master_code(uuid,text)') IS NOT NULL
      AND EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260909149000')
      THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('warehouseWriter',to_regprocedure('private.save_inventory_warehouse(uuid,bigint,text,text,uuid,text,boolean,boolean,boolean)') IS NOT NULL,
      'codeAllocator',to_regprocedure('private.allocate_master_code(uuid,text)') IS NOT NULL,
      'deliveryReadGate',EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260909149000')) details
  UNION ALL
  SELECT 'existing_transit_operation_flags',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'REVIEW' END,
    jsonb_build_object('rowCount',count(*))
  FROM public.warehouses warehouse WHERE warehouse.warehouse_type='TRANSIT'
    AND (warehouse.is_sale_source OR warehouse.is_purchase_destination
      OR warehouse.allow_negative_stock)
), inventory AS (
  SELECT 'warehouse_transit_inventory'::text check_name,'INFO'::text status,
    jsonb_build_object('companies',(SELECT count(*) FROM public.companies WHERE status='ACTIVE'),
      'operationalWarehouses',(SELECT count(*) FROM public.warehouses
        WHERE is_active AND warehouse_type IS DISTINCT FROM 'TRANSIT'),
      'existingTransitWarehouses',(SELECT count(*) FROM public.warehouses
        WHERE warehouse_type='TRANSIT'),
      'rule','Existing Transit rows are preserved and remain unassigned until explicitly mapped') details
)
SELECT * FROM (SELECT * FROM checks UNION ALL SELECT * FROM inventory) result
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'REVIEW' THEN 2 WHEN 'PASS' THEN 3 ELSE 4 END,check_name;
