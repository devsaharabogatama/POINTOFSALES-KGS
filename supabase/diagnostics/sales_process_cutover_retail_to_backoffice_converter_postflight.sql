-- Step 4B/6 SELECT-only verification.
WITH checks AS (
 SELECT 'migration_ledger' check_name,CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
   abs(1-count(*))::bigint violation_rows,jsonb_build_object('ledgerRows',count(*)) details
 FROM private.kgs_schema_migrations WHERE version='20260911100000'
 UNION ALL SELECT 'retail_to_backoffice_converter_contract',
   CASE WHEN to_regprocedure('private.convert_retail_sale_to_backoffice_order(uuid,uuid,uuid,uuid)') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END,
   CASE WHEN to_regprocedure('private.convert_retail_sale_to_backoffice_order(uuid,uuid,uuid,uuid)') IS NOT NULL THEN 0 ELSE 1 END,
   jsonb_build_object('routineExists',to_regprocedure('private.convert_retail_sale_to_backoffice_order(uuid,uuid,uuid,uuid)') IS NOT NULL)
 UNION ALL SELECT 'retail_converter_private_boundary',
   CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
   jsonb_build_object('authenticatedExecutableRows',count(*))
 FROM information_schema.routine_privileges privilege
 WHERE privilege.routine_schema='private'
   AND privilege.routine_name='convert_retail_sale_to_backoffice_order'
   AND privilege.grantee IN('anon','authenticated') AND privilege.privilege_type='EXECUTE'
 UNION ALL SELECT 'step_4b_no_apply_routine',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
   count(*)::bigint,jsonb_build_object('applyRows',count(*)) FROM pg_proc procedure
   JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
   WHERE procedure.proname='apply_sales_process_cutover_plan'
 UNION ALL SELECT 'retail_converter_runtime_contract',
   CASE WHEN COALESCE(procedure.prosecdef,false) AND procedure.provolatile='v'
      AND position('kgs.sales_process_cutover_mutation' in pg_get_functiondef(procedure.oid))>0
      AND position('save_backoffice_sales_order_draft' in pg_get_functiondef(procedure.oid))>0
      AND position('confirm_backoffice_sales_order' in pg_get_functiondef(procedure.oid))>0
      AND position('cancel_pos_sales_order' in pg_get_functiondef(procedure.oid))>0
      AND position('IDEMPOTENCY_PAYLOAD_CONFLICT' in pg_get_functiondef(procedure.oid))>0
      AND position('CUTOVER_SOURCE_RETAIL_MASTER_DATA_INACTIVE' in pg_get_functiondef(procedure.oid))>0
     THEN 'PASS' ELSE 'FAIL' END,
   CASE WHEN COALESCE(procedure.prosecdef,false) AND procedure.provolatile='v'
      AND position('kgs.sales_process_cutover_mutation' in pg_get_functiondef(procedure.oid))>0
      AND position('save_backoffice_sales_order_draft' in pg_get_functiondef(procedure.oid))>0
      AND position('confirm_backoffice_sales_order' in pg_get_functiondef(procedure.oid))>0
      AND position('cancel_pos_sales_order' in pg_get_functiondef(procedure.oid))>0
      AND position('IDEMPOTENCY_PAYLOAD_CONFLICT' in pg_get_functiondef(procedure.oid))>0
      AND position('CUTOVER_SOURCE_RETAIL_MASTER_DATA_INACTIVE' in pg_get_functiondef(procedure.oid))>0
     THEN 0 ELSE 1 END,
   jsonb_build_object('securityDefiner',procedure.prosecdef,
     'volatility',procedure.provolatile,'config',procedure.proconfig)
 FROM (SELECT to_regprocedure(
     'private.convert_retail_sale_to_backoffice_order(uuid,uuid,uuid,uuid)') oid) target
 LEFT JOIN pg_proc procedure ON procedure.oid=target.oid
)
SELECT * FROM checks ORDER BY CASE status WHEN 'FAIL' THEN 1 ELSE 2 END,check_name;
