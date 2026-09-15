-- SELECT-only postflight for Step 4/6.2.
WITH checks AS (
  SELECT 'migration_ledger' check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(1-count(*))::bigint violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260911165000'
  UNION ALL
  SELECT 'physical_state_columns',CASE WHEN count(*)=4 THEN 'PASS' ELSE 'FAIL' END,
    abs(4-count(*)),jsonb_build_object('columns',jsonb_agg(column_name ORDER BY column_name),
      'expected',4)
  FROM information_schema.columns WHERE table_schema='public'
    AND table_name='backoffice_sales_delivery_discrepancy_lines'
    AND column_name IN('physical_state','actual_uom_id',
      'actual_quantity_uom','actual_quantity_base')
  UNION ALL
  SELECT 'physical_state_constraints',CASE WHEN count(*)=5 THEN 'PASS' ELSE 'FAIL' END,
    abs(5-count(*)),jsonb_build_object('constraints',jsonb_agg(con.conname ORDER BY con.conname),
      'expected',5)
  FROM pg_constraint con JOIN pg_class rel ON rel.oid=con.conrelid
  JOIN pg_namespace ns ON ns.oid=rel.relnamespace
  WHERE ns.nspname='public'
    AND rel.relname='backoffice_sales_delivery_discrepancy_lines'
    AND con.conname IN('backoffice_sales_delivery_discrepancy_lines_actual_uom_fk',
      'backoffice_sales_delivery_discrepancy_lines_type_check',
      'backoffice_sales_delivery_discrepancy_lines_physical_check',
      'backoffice_sales_delivery_discrepancy_lines_resolution_check',
      'backoffice_sales_delivery_discrepancy_lines_warehouse_check')
  UNION ALL
  SELECT 'physical_state_routines',CASE WHEN count(*)=3 THEN 'PASS' ELSE 'FAIL' END,
    abs(3-count(*)),jsonb_build_object('routineRows',count(*),'expected',3)
  FROM pg_proc proc JOIN pg_namespace ns ON ns.oid=proc.pronamespace
  WHERE ns.nspname='private' AND proc.oid IN(
    to_regprocedure('private.classify_backoffice_sales_discrepancy(text,text)'),
    to_regprocedure('private.classify_backoffice_sales_discrepancy(text,text,text)'),
    to_regprocedure('private.validate_backoffice_sales_receipt_disposition_payload(jsonb)'))
  UNION ALL
  SELECT 'physical_state_classifier_private_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('browserExecutableRows',count(*))
  FROM information_schema.routine_privileges
  WHERE routine_schema='private' AND grantee IN('PUBLIC','anon','authenticated')
    AND routine_name IN('classify_backoffice_sales_discrepancy',
      'validate_backoffice_sales_receipt_disposition_payload')
  UNION ALL
  SELECT 'physical_state_clean_receipt_compatibility',
    CASE WHEN to_regprocedure(
      'public.receive_backoffice_sales_delivery(uuid,bigint,uuid,date,text)') IS NOT NULL
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN to_regprocedure(
      'public.receive_backoffice_sales_delivery(uuid,bigint,uuid,date,text)') IS NULL
      THEN 1 ELSE 0 END,
    jsonb_build_object('legacyWrapperPreserved',to_regprocedure(
      'public.receive_backoffice_sales_delivery(uuid,bigint,uuid,date,text)') IS NOT NULL)
  UNION ALL
  SELECT 'physical_state_runtime_inventory','INFO',0,
    jsonb_build_object('cases',count(DISTINCT discrepancy.id),
      'lines',count(line.id),'shortLines',count(line.id) FILTER(
        WHERE line.discrepancy_type='SHORT'),
      'wrongItemLines',count(line.id) FILTER(
        WHERE line.discrepancy_type='WRONG_ITEM'))
  FROM public.backoffice_sales_delivery_discrepancies discrepancy
  LEFT JOIN public.backoffice_sales_delivery_discrepancy_lines line
    ON line.company_id=discrepancy.company_id AND line.discrepancy_id=discrepancy.id
)
SELECT check_name,status,violation_rows,details FROM checks ORDER BY check_name;
