-- SELECT-only postflight for Purchase Daily Replenishment Step 5/6.
WITH checks AS (
  SELECT 's5_migration_ledger' check_name,CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(1-count(*)) violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260914100000'
  UNION ALL
  SELECT 's5_relation_contract',CASE WHEN count(*)=3 THEN 'PASS' ELSE 'FAIL' END,
    3-count(*),jsonb_build_object('expected',3,'present',count(*))
  FROM unnest(ARRAY[to_regclass('public.goods_receipt_unassigned_clearings'),
    to_regclass('public.goods_receipt_supplier_assignments'),
    to_regclass('public.goods_receipt_supplier_assignment_operations')]) relation_oid
  WHERE relation_oid IS NOT NULL
  UNION ALL
  SELECT 's5_routine_contract',CASE WHEN count(*)=5 THEN 'PASS' ELSE 'FAIL' END,
    5-count(*),jsonb_build_object('expected',5,'present',count(*))
  FROM unnest(ARRAY[
    to_regprocedure('private.purchase_daily_goods_receipt_snapshot(uuid,uuid)'),
    to_regprocedure('public.save_purchase_daily_goods_receipt(uuid,bigint,uuid,uuid,text,text,jsonb)'),
    to_regprocedure('public.post_purchase_daily_goods_receipt(uuid,bigint,uuid)'),
    to_regprocedure('public.assign_purchase_daily_receipt_suppliers(uuid,bigint,uuid,jsonb)'),
    to_regprocedure('public.preview_purchase_ap_posting_queue(integer)')]) routine_oid
  WHERE routine_oid IS NOT NULL
  UNION ALL
  SELECT 's5_account_catalog_contract',
    CASE WHEN function_rows=1 AND missing_company_rows=0 THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN function_rows=1 THEN missing_company_rows ELSE missing_company_rows+1 END,
    jsonb_build_object('functionRows',function_rows,'missingCompanyRows',missing_company_rows)
  FROM (SELECT
    (SELECT count(*) FROM public.account_functions
      WHERE function_key='PURCHASE_UNASSIGNED_CLEARING') function_rows,
    (SELECT count(*) FROM public.companies company WHERE NOT EXISTS(
      SELECT 1 FROM public.chart_of_accounts account WHERE account.company_id=company.id
        AND account.system_function_key='PURCHASE_UNASSIGNED_CLEARING'
        AND account.is_active AND account.is_postable)) missing_company_rows) catalog
  UNION ALL
  SELECT 's5_queue_exclusion_contract',
    CASE WHEN definition LIKE '%HOLD_FOR_SUPPLIER_ASSIGNMENT%'
      AND definition LIKE '%HOLD_FOR_STEP_6_RECLASSIFICATION%' THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN definition LIKE '%HOLD_FOR_SUPPLIER_ASSIGNMENT%'
      AND definition LIKE '%HOLD_FOR_STEP_6_RECLASSIFICATION%' THEN 0 ELSE 1 END,
    jsonb_build_object('pendingStatesExcluded',definition LIKE '%HOLD_FOR_SUPPLIER_ASSIGNMENT%'
      AND definition LIKE '%HOLD_FOR_STEP_6_RECLASSIFICATION%')
  FROM (SELECT pg_get_functiondef(
    'public.preview_purchase_ap_posting_queue(integer)'::regprocedure) definition) source
  UNION ALL
  SELECT 's5_pending_receipt_reconciliation',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*),jsonb_build_object('invalidRows',count(*))
  FROM public.goods_receipt_documents receipt
  WHERE receipt.receipt_scope='DAILY_WAREHOUSE' AND receipt.status='POSTED'
    AND receipt.supplier_assignment_status='SUPPLIER_PENDING'
    AND ((SELECT count(*) FROM public.goods_receipt_unassigned_clearings clearing
      WHERE clearing.company_id=receipt.company_id AND clearing.receipt_id=receipt.id)
      <>receipt.line_count OR round(COALESCE((SELECT sum(clearing.amount)
      FROM public.goods_receipt_unassigned_clearings clearing
      WHERE clearing.company_id=receipt.company_id AND clearing.receipt_id=receipt.id),0),4)
      <>round(receipt.provisional_ap_total,4))
  UNION ALL
  SELECT 's5_assignment_history_reconciliation',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*),jsonb_build_object('invalidOperations',count(*))
  FROM public.goods_receipt_supplier_assignment_operations operation
  WHERE (SELECT count(*) FROM public.goods_receipt_supplier_assignments assignment
      WHERE assignment.company_id=operation.company_id AND assignment.operation_id=operation.id)
    <>COALESCE((operation.result_snapshot->>'assignmentCount')::integer,0)
  UNION ALL
  SELECT 's5_runtime_inventory','INFO',0,jsonb_build_object(
    'dailyReceipts',(SELECT count(*) FROM public.goods_receipt_documents
      WHERE receipt_scope='DAILY_WAREHOUSE'),
    'openClearings',(SELECT count(*) FROM public.goods_receipt_unassigned_clearings clearing
      WHERE NOT EXISTS(SELECT 1 FROM public.goods_receipt_supplier_assignments assignment
        WHERE assignment.company_id=clearing.company_id AND assignment.clearing_id=clearing.id)),
    'assignments',(SELECT count(*) FROM public.goods_receipt_supplier_assignments))
)
SELECT check_name,status,violation_rows,details FROM checks ORDER BY
  CASE status WHEN 'FAIL' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;
