-- SELECT-only postflight. Run the entire file and retain its single result set.
WITH definition AS (
  SELECT pg_get_functiondef(
    'private.convert_retail_sale_to_backoffice_order(uuid,uuid,uuid,uuid)'::regprocedure) body
), checks(check_name,status,violation_rows,details) AS (
  SELECT 'pricelist_bridge_migration_ledger',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,abs(1-count(*)),
    jsonb_build_object('ledgerRows',count(*))
  FROM private.kgs_schema_migrations WHERE version='20260916120000'
  UNION ALL
  SELECT 'pricelist_bridge_runtime_contract',
    CASE WHEN position('v_save_pricelist uuid' IN body)>0
      AND position('''selectedPricelistId'',v_save_pricelist' IN body)>0
      AND position('pricelist_id=v_pricelist,' IN body)>0
      AND position('''selectedPricelistId'',NULL' IN body)=0
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN position('v_save_pricelist uuid' IN body)>0
      AND position('''selectedPricelistId'',v_save_pricelist' IN body)>0
      AND position('pricelist_id=v_pricelist,' IN body)>0
      AND position('''selectedPricelistId'',NULL' IN body)=0
      THEN 0 ELSE 1 END,
    jsonb_build_object('bridgeVariable',position('v_save_pricelist uuid' IN body)>0,
      'bridgePayload',position('''selectedPricelistId'',v_save_pricelist' IN body)>0,
      'sourcePricelistRestore',position('pricelist_id=v_pricelist,' IN body)>0,
      'legacyNullPayloadAbsent',position('''selectedPricelistId'',NULL' IN body)=0)
  FROM definition
  UNION ALL
  SELECT 'pricelist_bridge_private_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('authenticatedExecutableRows',count(*))
  FROM information_schema.routine_privileges
  WHERE routine_schema='private' AND routine_name='convert_retail_sale_to_backoffice_order'
    AND grantee IN('anon','authenticated') AND privilege_type='EXECUTE'
  UNION ALL
  SELECT 'pricelist_bridge_active_finance_queue',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),jsonb_build_object('runRows',count(*))
  FROM public.finance_posting_queue_runs WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'pricelist_bridge_runtime_inventory','INFO',0,
    jsonb_build_object('openPlans',count(*),'rule','No plan or transaction row is changed by this migration')
  FROM public.sales_process_cutover_plans WHERE status IN('DRAFT','PREVIEWED','APPLYING')
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;
