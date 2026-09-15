-- SELECT-only postflight for Step 5/6.2 forward-fix 20260912136000.
WITH definition AS (
  SELECT proc.oid,proc.prosecdef,proc.proconfig,pg_get_functiondef(proc.oid) body
  FROM pg_proc proc WHERE proc.oid=to_regprocedure(
    'private.resolve_backoffice_sales_shortage_core(uuid,bigint,uuid,date,text)')
), checks AS (
  SELECT 's5_2f_migration_ledger' check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(count(*)-1)::bigint violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260912136000'
  UNION ALL SELECT 's5_2f_enum_contract',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,abs(count(*)-1)::bigint,
    jsonb_build_object('enumRows',count(*),'expected',1)
  FROM pg_enum enum_value
  JOIN pg_type enum_type ON enum_type.oid=enum_value.enumtypid
  JOIN pg_namespace namespace ON namespace.oid=enum_type.typnamespace
  WHERE namespace.nspname='public' AND enum_type.typname='stock_movement_type'
    AND enum_value.enumlabel='BACKOFFICE_DISCREPANCY_LOSS'
  UNION ALL SELECT 's5_2f_resolver_definition_contract',
    CASE WHEN count(*)=1 AND bool_and(
      position('''BACKOFFICE_DISCREPANCY_LOSS''::public.stock_movement_type' in body)>0
      AND position('''ADJUSTMENT''::public.stock_movement_type' in body)=0
      AND position('backoffice_sales_discrepancy_stock_effects' in body)>0)
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1 AND bool_and(
      position('''BACKOFFICE_DISCREPANCY_LOSS''::public.stock_movement_type' in body)>0
      AND position('''ADJUSTMENT''::public.stock_movement_type' in body)=0
      AND position('backoffice_sales_discrepancy_stock_effects' in body)>0)
      THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('routineRows',count(*),'newMarker',COALESCE(bool_and(
      position('''BACKOFFICE_DISCREPANCY_LOSS''::public.stock_movement_type' in body)>0),false),
      'legacyMarker',COALESCE(bool_or(
        position('''ADJUSTMENT''::public.stock_movement_type' in body)>0),false)) FROM definition
  UNION ALL SELECT 's5_2f_resolver_security_contract',
    CASE WHEN count(*)=1 AND bool_and(prosecdef
      AND proconfig @> ARRAY['search_path=public, pg_temp']
      AND proconfig @> ARRAY['statement_timeout=30s']) THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1 AND bool_and(prosecdef
      AND proconfig @> ARRAY['search_path=public, pg_temp']
      AND proconfig @> ARRAY['statement_timeout=30s']) THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('routineRows',count(*),'securityDefiner',COALESCE(bool_and(prosecdef),false),
      'config',min(proconfig::text)) FROM definition
  UNION ALL SELECT 's5_2f_private_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('browserExecutableRows',count(*))
  FROM definition WHERE has_function_privilege('anon',oid,'EXECUTE')
    OR has_function_privilege('authenticated',oid,'EXECUTE')
  UNION ALL SELECT 's5_2f_adjustment_boundary_preserved',
    CASE WHEN count(*)=1 AND bool_and(position('ADJUSTMENT' in definition)>0
      AND position('stock_adjustment_documents' in definition)>0)
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1 AND bool_and(position('ADJUSTMENT' in definition)>0
      AND position('stock_adjustment_documents' in definition)>0)
      THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('constraintRows',count(*))
  FROM (SELECT pg_get_constraintdef(constraint_state.oid) definition
    FROM pg_constraint constraint_state
    WHERE constraint_state.conrelid='public.stock_movements'::regclass
      AND constraint_state.conname='stock_movements_adjustment_snapshot_complete') constraint_definition
  UNION ALL SELECT 's5_2f_movement_lineage_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('invalidRows',count(*))
  FROM public.stock_movements movement
  LEFT JOIN public.backoffice_sales_discrepancy_stock_effects effect
    ON effect.company_id=movement.company_id AND effect.id=movement.reference_id
    AND effect.source_stock_movement_id=movement.id
  WHERE movement.movement_type='BACKOFFICE_DISCREPANCY_LOSS'::public.stock_movement_type
    AND (movement.reference_table<>'backoffice_sales_discrepancy_stock_effects'
      OR effect.id IS NULL OR effect.effect_type<>'EXPECTED_WRITE_OFF'
      OR movement.qty_change>=0 OR round(-movement.qty_change,6)<>round(effect.quantity_base,6)
      OR movement.product_id<>effect.product_id OR movement.warehouse_id<>effect.source_warehouse_id
      OR movement.movement_status<>'POSTED' OR movement.base_uom_id IS NULL
      OR NULLIF(btrim(movement.base_uom_name_snapshot),'') IS NULL
      OR movement.balance_after_base_qty IS NULL OR movement.actor_id IS NULL
      OR movement.posted_at IS NULL OR movement.source_line_id IS NULL)
  UNION ALL SELECT 's5_2f_runtime_inventory','INFO',0,
    jsonb_build_object('discrepancyLossMovements',(SELECT count(*)
      FROM public.stock_movements movement
      WHERE movement.movement_type='BACKOFFICE_DISCREPANCY_LOSS'::public.stock_movement_type),
      'legacyDiscrepancyAdjustments',(SELECT count(*) FROM public.stock_movements movement
      WHERE movement.reference_table='backoffice_sales_discrepancy_stock_effects'
        AND movement.movement_type='ADJUSTMENT'::public.stock_movement_type))
)
SELECT check_name,status,violation_rows,details FROM checks ORDER BY
  CASE status WHEN 'BLOCKER' THEN 0 WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
