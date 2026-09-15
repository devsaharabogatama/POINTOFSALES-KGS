-- SELECT-only verification for C3 Delivery-kind forward-fix. Run the whole file.
WITH function_fact AS (
  SELECT pg_get_functiondef(to_regprocedure(
    'private.resolve_backoffice_sales_overage_wrong_item_core(uuid,bigint,uuid,date,text)')) definition
), constraint_fact AS (
  SELECT pg_get_constraintdef(oid) definition
  FROM pg_constraint
  WHERE conrelid='public.backoffice_sales_delivery_orders'::regclass
    AND conname='backoffice_sales_delivery_orders_kind_check'
), checks AS (
  SELECT 'c3f_migration_ledger' check_name,CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(1-count(*)) violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260912131000'
  UNION ALL
  SELECT 'c3f_resolver_definition_contract',
    CASE WHEN count(*)=1
      AND bool_and(position('''CORRECTION'',v_delivery.id,''READY''' in definition)=0)
      AND bool_and(position('''BACKORDER'',v_delivery.id,''READY''' in definition)>0)
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1
      AND bool_and(position('''CORRECTION'',v_delivery.id,''READY''' in definition)=0)
      AND bool_and(position('''BACKORDER'',v_delivery.id,''READY''' in definition)>0)
      THEN 0 ELSE 1 END,
    jsonb_build_object('routineRows',count(*),'oldAnchorRows',count(*) FILTER(
      WHERE position('''CORRECTION'',v_delivery.id,''READY''' in definition)>0),'newAnchorRows',count(*) FILTER(
      WHERE position('''BACKORDER'',v_delivery.id,''READY''' in definition)>0))
  FROM function_fact
  UNION ALL
  SELECT 'c3f_canonical_delivery_kind_contract',
    CASE WHEN count(*)=1 AND bool_and(position('BACKORDER' in definition)>0
      AND position('CORRECTION' in definition)=0) THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1 AND bool_and(position('BACKORDER' in definition)>0
      AND position('CORRECTION' in definition)=0) THEN 0 ELSE 1 END,
    jsonb_build_object('constraintRows',count(*),'definitions',coalesce(jsonb_agg(definition),'[]'::jsonb))
  FROM constraint_fact
  UNION ALL
  SELECT 'c3f_wrong_item_lineage_contract',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*),jsonb_build_object('invalidRows',count(*))
  FROM public.backoffice_sales_discrepancy_backorders header
  LEFT JOIN public.backoffice_sales_delivery_orders delivery
    ON delivery.company_id=header.company_id AND delivery.id=header.backorder_delivery_order_id
  WHERE header.resolution_kind='WRONG_ITEM_CORRECTION'
    AND (delivery.id IS NULL OR delivery.delivery_kind<>'BACKORDER'
      OR delivery.parent_delivery_order_id<>header.source_delivery_order_id)
  UNION ALL
  SELECT 'c3f_public_private_boundary',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*),jsonb_build_object('authenticatedPrivateExecuteRows',count(*))
  FROM information_schema.routine_privileges
  WHERE specific_schema='private' AND grantee IN('anon','authenticated')
    AND routine_name='resolve_backoffice_sales_overage_wrong_item_core'
    AND privilege_type='EXECUTE'
  UNION ALL
  SELECT 'c3f_runtime_inventory','INFO',0,jsonb_build_object(
    'wrongItemCorrectionHeaders',count(*),'linkedCanonicalDeliveries',count(delivery.id) FILTER(
      WHERE delivery.delivery_kind='BACKORDER'))
  FROM public.backoffice_sales_discrepancy_backorders header
  LEFT JOIN public.backoffice_sales_delivery_orders delivery
    ON delivery.company_id=header.company_id AND delivery.id=header.backorder_delivery_order_id
  WHERE header.resolution_kind='WRONG_ITEM_CORRECTION'
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;
