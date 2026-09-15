-- Read-only postflight for migration 20260909150000.
WITH checks AS (
  SELECT 'migration_ledger'::text check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(count(*)-1)::bigint violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260909150000'
  UNION ALL
  SELECT 'required_transit_columns',CASE WHEN count(*)=2 THEN 'PASS' ELSE 'FAIL' END,
    abs(count(*)-2)::bigint,jsonb_build_object('columnRows',count(*),'expected',2)
  FROM information_schema.columns WHERE table_schema='public' AND table_name='warehouses'
    AND column_name IN('transit_parent_warehouse_id','transit_operation')
  UNION ALL
  SELECT 'required_transit_routines',CASE WHEN count(*)=3 THEN 'PASS' ELSE 'FAIL' END,
    abs(count(*)-3)::bigint,jsonb_build_object('routineRows',count(*),'expected',3)
  FROM (VALUES
    (to_regprocedure('private.trg_guard_warehouse_transit_usage()')),
    (to_regprocedure('private.resolve_or_create_warehouse_transit(uuid,uuid,text,uuid)')),
    (to_regprocedure('public.save_inventory_transit_warehouse(uuid,bigint,text,uuid,text,text,boolean)'))
  ) routine(oid) WHERE oid IS NOT NULL
  UNION ALL
  SELECT 'transit_usage_rpc_boundary',CASE WHEN has_function_privilege('authenticated',
      'public.save_inventory_transit_warehouse(uuid,bigint,text,uuid,text,text,boolean)','EXECUTE')
      AND NOT has_function_privilege('anon','public.save_inventory_transit_warehouse(uuid,bigint,text,uuid,text,text,boolean)','EXECUTE')
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN has_function_privilege('authenticated','public.save_inventory_transit_warehouse(uuid,bigint,text,uuid,text,text,boolean)','EXECUTE')
      AND NOT has_function_privilege('anon','public.save_inventory_transit_warehouse(uuid,bigint,text,uuid,text,text,boolean)','EXECUTE') THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('authenticatedExecute',has_function_privilege('authenticated','public.save_inventory_transit_warehouse(uuid,bigint,text,uuid,text,text,boolean)','EXECUTE'),
      'anonExecute',has_function_privilege('anon','public.save_inventory_transit_warehouse(uuid,bigint,text,uuid,text,text,boolean)','EXECUTE'))
  UNION ALL
  SELECT 'private_transit_runtime_boundary',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('browserExecutableRows',count(*))
  FROM (VALUES
    ('private.trg_guard_warehouse_transit_usage()'::regprocedure),
    ('private.resolve_or_create_warehouse_transit(uuid,uuid,text,uuid)'::regprocedure)
  ) routine(oid) WHERE has_function_privilege('authenticated',oid,'EXECUTE')
    OR has_function_privilege('anon',oid,'EXECUTE')
  UNION ALL
  SELECT 'active_transit_usage_uniqueness',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('duplicateGroups',count(*))
  FROM (SELECT company_id,transit_parent_warehouse_id,transit_operation
    FROM public.warehouses WHERE is_active AND transit_parent_warehouse_id IS NOT NULL
    GROUP BY company_id,transit_parent_warehouse_id,transit_operation HAVING count(*)>1) duplicate
  UNION ALL
  SELECT 'assigned_transit_shape',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('invalidRows',count(*))
  FROM public.warehouses transit LEFT JOIN public.warehouses parent
    ON parent.company_id=transit.company_id AND parent.id=transit.transit_parent_warehouse_id
  WHERE transit.transit_parent_warehouse_id IS NOT NULL AND (
    transit.warehouse_type<>'TRANSIT' OR transit.transit_operation NOT IN(
      'SALES_DELIVERY_OUTBOUND','WAREHOUSE_TRANSFER_OUTBOUND','CUSTOMER_RETURN_INBOUND')
    OR parent.id IS NULL OR parent.warehouse_type='TRANSIT'
    OR transit.is_sale_source OR transit.is_purchase_destination OR transit.allow_negative_stock)
  UNION ALL
  SELECT 'transit_foundation_runtime_inventory','INFO',0,
    jsonb_build_object('assignedTransit',(SELECT count(*) FROM public.warehouses
      WHERE transit_parent_warehouse_id IS NOT NULL),
      'unassignedLegacyTransit',(SELECT count(*) FROM public.warehouses
      WHERE warehouse_type='TRANSIT' AND transit_parent_warehouse_id IS NULL),
      'stockEffect','NONE')
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
