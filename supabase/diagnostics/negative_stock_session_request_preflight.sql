-- SELECT-only readiness for automatic negative-stock Session requests.

WITH checks AS (
  SELECT 'required_runtime_dependencies' check_name,
    count(*)=6 passed,
    jsonb_build_object('routineRows',count(*),'expected',6) details
  FROM unnest(ARRAY[
    to_regprocedure('public.close_cashier_session(uuid,bigint,numeric)'),
    to_regprocedure('private.authorize_pos_negative_stock(uuid,uuid,uuid,uuid,jsonb,text)'),
    to_regprocedure('private.reconcile_negative_stock_replenishment()'),
    to_regprocedure('public.get_purchase_supplier_orders()'),
    to_regprocedure('public.save_stock_request(uuid,bigint,uuid,date,text,jsonb)'),
    to_regprocedure('public.submit_stock_request(uuid,bigint)')
  ]) routine_oid WHERE routine_oid IS NOT NULL
  UNION ALL
  SELECT 'negative_allocation_session_lineage',count(*)=0,
    jsonb_build_object('rowCount',count(*))
  FROM public.negative_stock_sale_allocations allocation
  LEFT JOIN public.sales_headers sale
    ON sale.company_id=allocation.company_id AND sale.id=allocation.sales_id
  LEFT JOIN public.cashier_sessions session
    ON session.company_id=sale.company_id
   AND session.id=COALESCE(sale.posted_session_id,sale.session_id)
  WHERE sale.id IS NULL OR session.id IS NULL
    OR allocation.warehouse_id IS DISTINCT FROM session.sales_warehouse_id
  UNION ALL
  SELECT 'negative_allocation_shape',count(*)=0,
    jsonb_build_object('rowCount',count(*))
  FROM public.negative_stock_sale_allocations allocation
  WHERE allocation.shortage_base_qty<=0
    OR allocation.replenished_base_qty<0
    OR allocation.replenished_base_qty>allocation.shortage_base_qty
    OR ((allocation.replenished_base_qty=allocation.shortage_base_qty)
      IS DISTINCT FROM (allocation.reconciled_at IS NOT NULL))
  UNION ALL
  SELECT 'active_finance_queue_inventory',TRUE,
    jsonb_build_object('runCount',count(*))
  FROM public.finance_posting_queue_runs run
  WHERE run.status IN('PREVIEWED','PROCESSING')
  UNION ALL
  SELECT 'open_offline_submission_inventory',TRUE,
    jsonb_build_object('submissionCount',count(*))
  FROM public.pos_offline_sale_submissions submission
  WHERE submission.status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
  UNION ALL
  SELECT 'automatic_request_schema_state',
    to_regclass('public.stock_request_negative_allocations') IS NULL
      AND NOT EXISTS(SELECT 1 FROM information_schema.columns
        WHERE table_schema='public' AND table_name='stock_request_documents'
          AND column_name='request_source'),
    jsonb_build_object(
      'allocationTableExists',to_regclass(
        'public.stock_request_negative_allocations') IS NOT NULL,
      'requestSourceExists',EXISTS(SELECT 1 FROM information_schema.columns
        WHERE table_schema='public' AND table_name='stock_request_documents'
          AND column_name='request_source'))
  UNION ALL
  SELECT 'negative_stock_configuration_inventory',TRUE,
    jsonb_build_object(
      'enabledCompanies',count(DISTINCT feature.company_id)
        FILTER(WHERE feature.is_enabled),
      'activePolicies',count(DISTINCT policy.company_id)
        FILTER(WHERE policy.is_active),
      'optedInWarehouses',count(DISTINCT warehouse.id)
        FILTER(WHERE warehouse.allow_negative_stock),
      'activeUserPermissions',count(DISTINCT permission.id)
        FILTER(WHERE permission.is_active AND (permission.valid_until IS NULL
          OR permission.valid_until>clock_timestamp())))
  FROM public.company_features feature
  LEFT JOIN public.pos_negative_stock_policies policy
    ON policy.company_id=feature.company_id
  LEFT JOIN public.warehouses warehouse
    ON warehouse.company_id=feature.company_id AND warehouse.is_sale_source
  LEFT JOIN public.pos_negative_stock_permissions permission
    ON permission.company_id=feature.company_id
  WHERE feature.feature_code='pos_negative_stock_enabled'
  UNION ALL
  SELECT 'outstanding_negative_session_inventory',TRUE,
    jsonb_build_object('sessions',count(DISTINCT
      COALESCE(sale.posted_session_id,sale.session_id)),
      'allocations',count(*),'outstandingBaseQty',COALESCE(sum(
        allocation.shortage_base_qty-allocation.replenished_base_qty),0))
  FROM public.negative_stock_sale_allocations allocation
  JOIN public.sales_headers sale
    ON sale.company_id=allocation.company_id AND sale.id=allocation.sales_id
  WHERE allocation.reconciled_at IS NULL
)
SELECT check_name,
  CASE WHEN check_name IN('automatic_request_schema_state') THEN
    CASE WHEN passed THEN 'SETUP' ELSE 'REVIEW' END
  WHEN check_name LIKE '%inventory' THEN 'INFO'
  WHEN passed THEN 'PASS' ELSE 'BLOCKER' END status,details
FROM checks ORDER BY
  CASE WHEN NOT passed AND check_name<>'automatic_request_schema_state' THEN 0
    WHEN check_name='automatic_request_schema_state' THEN 1
    WHEN check_name LIKE '%inventory' THEN 3 ELSE 2 END,check_name;
