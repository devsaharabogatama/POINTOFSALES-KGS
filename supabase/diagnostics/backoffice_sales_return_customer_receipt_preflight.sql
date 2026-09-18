-- SELECT-only preflight for 20260917120000. Run the entire file.
WITH state AS (
  SELECT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260917120000') applied
), checks AS (
  SELECT 'customer_return_receipt_dependency_ledger' check_name,
    CASE WHEN EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260917110000') THEN 'PASS' ELSE 'BLOCKER' END status,
    CASE WHEN EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260917110000') THEN 0 ELSE 1 END::bigint violation_rows,
    jsonb_build_object('requiredVersion','20260917110000') details
  UNION ALL
  SELECT 'customer_return_receipt_active_finance_queue',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('runRows',count(*))
  FROM public.finance_posting_queue_runs WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'customer_return_receipt_nonterminal_offline',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('submissionRows',count(*))
  FROM public.pos_offline_sale_submissions WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
  UNION ALL
  SELECT 'customer_return_receipt_relation_boundary',
    CASE WHEN (NOT state.applied AND count(*) FILTER(WHERE to_regclass('public.'||candidate.name) IS NOT NULL)=0)
      OR (state.applied AND count(*) FILTER(WHERE to_regclass('public.'||candidate.name) IS NOT NULL)=5)
      THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN (NOT state.applied AND count(*) FILTER(WHERE to_regclass('public.'||candidate.name) IS NOT NULL)=0)
      OR (state.applied AND count(*) FILTER(WHERE to_regclass('public.'||candidate.name) IS NOT NULL)=5)
      THEN 0 ELSE abs(5*state.applied::int-
        count(*) FILTER(WHERE to_regclass('public.'||candidate.name) IS NOT NULL)) END::bigint,
    jsonb_build_object('migrationApplied',state.applied,'expected',CASE WHEN state.applied THEN 5 ELSE 0 END,
      'present',count(*) FILTER(WHERE to_regclass('public.'||candidate.name) IS NOT NULL),
      'relations',COALESCE(jsonb_agg(candidate.name ORDER BY candidate.name)
        FILTER(WHERE to_regclass('public.'||candidate.name) IS NOT NULL),'[]'::jsonb))
  FROM state CROSS JOIN (VALUES('backoffice_sales_return_receipts'),
    ('backoffice_sales_return_receipt_lines'),('backoffice_sales_return_receipt_fifo_restorations'),
    ('backoffice_sales_return_receipt_operations'),('backoffice_sales_return_receipt_audit')) candidate(name)
  GROUP BY state.applied
  UNION ALL
  SELECT 'customer_return_receipt_routine_boundary',
    CASE WHEN (NOT state.applied AND count(*) FILTER(WHERE to_regprocedure(candidate.signature) IS NOT NULL)=0)
      OR (state.applied AND count(*) FILTER(WHERE to_regprocedure(candidate.signature) IS NOT NULL)=3)
      THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN (NOT state.applied AND count(*) FILTER(WHERE to_regprocedure(candidate.signature) IS NOT NULL)=0)
      OR (state.applied AND count(*) FILTER(WHERE to_regprocedure(candidate.signature) IS NOT NULL)=3)
      THEN 0 ELSE abs(3*state.applied::int-
        count(*) FILTER(WHERE to_regprocedure(candidate.signature) IS NOT NULL)) END::bigint,
    jsonb_build_object('migrationApplied',state.applied,'expected',CASE WHEN state.applied THEN 3 ELSE 0 END,
      'present',count(*) FILTER(WHERE to_regprocedure(candidate.signature) IS NOT NULL))
  FROM state CROSS JOIN (VALUES
    ('private.backoffice_sales_return_receipt_operation_retry(uuid,uuid,text)'),
    ('private.post_backoffice_sales_return_receipt_core(uuid,bigint,uuid,date,jsonb,text)'),
    ('public.post_backoffice_sales_return_receipt(uuid,bigint,uuid,date,jsonb,text)')) candidate(signature)
  GROUP BY state.applied
  UNION ALL
  SELECT 'customer_return_receipt_source_fifo_contract',
    CASE WHEN to_regclass('public.backoffice_sales_receipt_fifo_allocations') IS NOT NULL
      AND to_regclass('public.backoffice_sales_delivery_receipt_lines') IS NOT NULL
      AND enum_range(NULL::public.stock_movement_type)
        @> ARRAY['SALES_RETURN'::public.stock_movement_type]
      THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN to_regclass('public.backoffice_sales_receipt_fifo_allocations') IS NOT NULL
      AND to_regclass('public.backoffice_sales_delivery_receipt_lines') IS NOT NULL
      AND enum_range(NULL::public.stock_movement_type)
        @> ARRAY['SALES_RETURN'::public.stock_movement_type]
      THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('customerReceiptFifo',to_regclass('public.backoffice_sales_receipt_fifo_allocations') IS NOT NULL,
      'customerReceiptLines',to_regclass('public.backoffice_sales_delivery_receipt_lines') IS NOT NULL,
      'salesReturnMovement',enum_range(NULL::public.stock_movement_type)
        @> ARRAY['SALES_RETURN'::public.stock_movement_type])
  UNION ALL
  SELECT 'customer_return_receipt_candidate_inventory','INFO',0::bigint,
    jsonb_build_object('approvedReturns',count(*) FILTER(WHERE status='APPROVED'),
      'partiallyReceivedReturns',count(*) FILTER(WHERE status='PARTIALLY_RECEIVED'))
  FROM public.backoffice_sales_returns
  UNION ALL
  SELECT 'preflight_revision','INFO',0::bigint,
    jsonb_build_object('revision','BACKOFFICE_RETURN_STEP_2_V1','writes',false,
      'executionRule','Run the entire file; do not run selected text')
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 0 WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
