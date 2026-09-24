-- Read-only installation postflight. Feature must still be OFF everywhere.
SELECT 'auto_ro_stock_match_migration_ledger' check_name,
  CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
  abs(count(*)-1)::bigint violation_rows,jsonb_build_object('ledgerRows',count(*)) details
FROM private.kgs_schema_migrations WHERE version='20260924100000'
UNION ALL
SELECT 'auto_ro_stock_match_column_contract',
  CASE WHEN count(*)=4 AND count(*) FILTER(WHERE is_nullable='NO')=1
      AND count(*) FILTER(WHERE column_name='auto_ro_stock_match_enabled'
        AND column_default IN('false','false::boolean'))=1 THEN 'PASS' ELSE 'FAIL' END,
  CASE WHEN count(*)=4 AND count(*) FILTER(WHERE is_nullable='NO')=1
      AND count(*) FILTER(WHERE column_name='auto_ro_stock_match_enabled'
        AND column_default IN('false','false::boolean'))=1 THEN 0 ELSE 1 END::bigint,
  jsonb_build_object('rows',count(*),'expected',4)
FROM information_schema.columns
WHERE table_schema='public' AND (
  (table_name='company_purchase_replenishment_settings'
    AND column_name='auto_ro_stock_match_enabled') OR
  (table_name='purchase_daily_batches' AND column_name IN(
    'stock_match_fingerprint','stock_matched_at','stock_match_operation_id')))
UNION ALL
SELECT 'auto_ro_stock_match_default_policy',
  CASE WHEN count(*) FILTER(WHERE auto_ro_stock_match_enabled)=0 THEN 'PASS' ELSE 'FAIL' END,
  count(*) FILTER(WHERE auto_ro_stock_match_enabled)::bigint,
  jsonb_build_object('companyPolicies',count(*),'enabledCompanies',
    count(*) FILTER(WHERE auto_ro_stock_match_enabled))
FROM public.company_purchase_replenishment_settings
UNION ALL
SELECT 'auto_ro_stock_match_routine_contract',
  CASE WHEN count(*)=5 THEN 'PASS' ELSE 'FAIL' END,abs(count(*)-5)::bigint,
  jsonb_build_object('present',count(*),'expected',5)
FROM (VALUES
  (to_regprocedure('private.get_purchase_daily_auto_ro_stock_match_core(uuid,uuid)')),
  (to_regprocedure('private.reconcile_purchase_daily_auto_ro_stock_core(uuid,uuid,bigint,uuid,uuid,timestamptz)')),
  (to_regprocedure('public.get_purchase_daily_auto_ro_stock_match(uuid)')),
  (to_regprocedure('public.reconcile_purchase_daily_auto_ro_stock(uuid,bigint,uuid)')),
  (to_regprocedure('public.confirm_purchase_daily_auto_ro_matched(uuid,bigint,uuid,uuid,boolean,jsonb)'))
) routine(oid) WHERE oid IS NOT NULL
UNION ALL
SELECT 'auto_ro_stock_match_dispatch_contract',
  CASE WHEN position('batch.status=''DRAFT''' IN pg_get_functiondef(to_regprocedure(
      'private.get_purchase_daily_auto_ro_stock_match_core(uuid,uuid)')))>0
    AND position('batch.id<>p_batch_id' IN pg_get_functiondef(to_regprocedure(
      'private.get_purchase_daily_auto_ro_stock_match_core(uuid,uuid)')))>0
    AND position('get_purchase_daily_replenishment_candidates_core' IN pg_get_functiondef(
      to_regprocedure('private.get_purchase_daily_auto_ro_stock_match_core(uuid,uuid)')))>0
    AND position('PURCHASE_AUTO_RO_STOCK_MATCH_REQUIRED' IN pg_get_functiondef(
      to_regprocedure('public.confirm_purchase_daily_auto_ro(uuid,bigint,uuid,jsonb)')))>0
    THEN 'PASS' ELSE 'FAIL' END,
  CASE WHEN position('batch.status=''DRAFT''' IN pg_get_functiondef(to_regprocedure(
      'private.get_purchase_daily_auto_ro_stock_match_core(uuid,uuid)')))>0
    AND position('batch.id<>p_batch_id' IN pg_get_functiondef(to_regprocedure(
      'private.get_purchase_daily_auto_ro_stock_match_core(uuid,uuid)')))>0
    AND position('get_purchase_daily_replenishment_candidates_core' IN pg_get_functiondef(
      to_regprocedure('private.get_purchase_daily_auto_ro_stock_match_core(uuid,uuid)')))>0
    AND position('PURCHASE_AUTO_RO_STOCK_MATCH_REQUIRED' IN pg_get_functiondef(
      to_regprocedure('public.confirm_purchase_daily_auto_ro(uuid,bigint,uuid,jsonb)')))>0
    THEN 0 ELSE 1 END::bigint,
  jsonb_build_object('required',ARRAY[
    'only other DRAFT RO contributes coverage','current RO excluded from itself',
    'canonical remaining PO/request lineage retained','legacy confirm blocked when enabled'])
UNION ALL
SELECT 'auto_ro_stock_match_permission_contract',
  CASE WHEN NOT has_function_privilege('authenticated',
      'private.reconcile_purchase_daily_auto_ro_stock_core(uuid,uuid,bigint,uuid,uuid,timestamptz)','EXECUTE')
    AND has_function_privilege('authenticated',
      'public.get_purchase_daily_auto_ro_stock_match(uuid)','EXECUTE')
    AND has_function_privilege('authenticated',
      'public.reconcile_purchase_daily_auto_ro_stock(uuid,bigint,uuid)','EXECUTE')
    AND has_function_privilege('authenticated',
      'public.confirm_purchase_daily_auto_ro_matched(uuid,bigint,uuid,uuid,boolean,jsonb)','EXECUTE')
    THEN 'PASS' ELSE 'FAIL' END,
  CASE WHEN NOT has_function_privilege('authenticated',
      'private.reconcile_purchase_daily_auto_ro_stock_core(uuid,uuid,bigint,uuid,uuid,timestamptz)','EXECUTE')
    AND has_function_privilege('authenticated',
      'public.get_purchase_daily_auto_ro_stock_match(uuid)','EXECUTE')
    AND has_function_privilege('authenticated',
      'public.reconcile_purchase_daily_auto_ro_stock(uuid,bigint,uuid)','EXECUTE')
    AND has_function_privilege('authenticated',
      'public.confirm_purchase_daily_auto_ro_matched(uuid,bigint,uuid,uuid,boolean,jsonb)','EXECUTE')
    THEN 0 ELSE 1 END::bigint,
  jsonb_build_object('privateAuthenticated',false,'publicAuthenticated',true)
UNION ALL
SELECT 'auto_ro_stock_match_existing_batch_reconciliation',
  CASE WHEN count(*) FILTER(WHERE stock_match_operation_id IS NOT NULL)=0
    THEN 'PASS' ELSE 'FAIL' END,
  count(*) FILTER(WHERE stock_match_operation_id IS NOT NULL)::bigint,
  jsonb_build_object('existingBatches',count(*),'matchedExistingBatches',
    count(*) FILTER(WHERE stock_match_operation_id IS NOT NULL))
FROM public.purchase_daily_batches;
