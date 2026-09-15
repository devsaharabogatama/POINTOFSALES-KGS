-- SELECT-only preflight for Step 4/6.3. Isolated Development only.
WITH migration_state AS (
  SELECT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260911166000') applied
), invoice_definition AS (
  SELECT pg_get_functiondef(to_regprocedure(
    'public.save_backoffice_sales_invoice_draft(uuid,bigint,uuid,uuid,jsonb)')) body
), checks AS (
  SELECT 'mixed_receipt_dependency_ledger' check_name,
    CASE WHEN count(*)=4 THEN 'PASS' ELSE 'BLOCKER' END status,
    abs(4-count(*))::bigint violation_rows,
    jsonb_build_object('present',count(*),'expected',4) details
  FROM private.kgs_schema_migrations WHERE version IN(
    '20260909154000','20260911150000','20260911164000','20260911165000')
  UNION ALL
  SELECT 'mixed_receipt_routine_contract',
    CASE WHEN (state.applied AND inventory.routine_count=2)
      OR (NOT state.applied AND inventory.routine_count=0) THEN 'PASS' ELSE 'BLOCKER' END,
    abs((CASE WHEN state.applied THEN 2 ELSE 0 END)-inventory.routine_count),
    jsonb_build_object('migrationApplied',state.applied,'present',inventory.routines,
      'expected',CASE WHEN state.applied THEN 2 ELSE 0 END)
  FROM migration_state state CROSS JOIN LATERAL (
    SELECT count(*) routine_count,
      COALESCE(jsonb_agg(proc.oid::regprocedure::text ORDER BY proc.oid::regprocedure::text),
        '[]'::jsonb) routines
    FROM pg_proc proc WHERE proc.oid IN(
      to_regprocedure('private.receive_backoffice_sales_delivery_disposition_core(uuid,bigint,uuid,date,jsonb,text)'),
      to_regprocedure('public.receive_backoffice_sales_delivery(uuid,bigint,uuid,date,jsonb,text)'))
  ) inventory
  UNION ALL
  SELECT 'mixed_receipt_pre_runtime_rows',
    CASE WHEN state.applied OR inventory.row_count=0 THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN state.applied THEN 0 ELSE inventory.row_count END,
    jsonb_build_object('migrationApplied',state.applied,'discrepancyRows',inventory.row_count)
  FROM migration_state state CROSS JOIN LATERAL (
    SELECT count(*) row_count FROM public.backoffice_sales_delivery_discrepancies
  ) inventory
  UNION ALL
  SELECT 'mixed_receipt_legacy_receipt_shape',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*),
    jsonb_build_object('invalidRows',count(*),
      'rule','Before mixed runtime every existing receipt is positive and event-linked')
  FROM public.backoffice_sales_delivery_receipts receipt
  CROSS JOIN migration_state state
  WHERE NOT state.applied
    AND (receipt.total_received_base_qty<=0 OR receipt.financial_event_id IS NULL)
  UNION ALL
  SELECT 'mixed_receipt_invoice_gate_contract',
    CASE WHEN (state.applied AND definition.body LIKE '%to_invoice_base_qty>0%'
        AND definition.body LIKE '%fulfillment_status=''IN_TRANSIT''%')
      OR (NOT state.applied
        AND definition.body LIKE '%fulfillment_status=''COMPLETED''%'
        AND definition.body NOT LIKE '%to_invoice_base_qty>0%')
      THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN (state.applied AND definition.body LIKE '%to_invoice_base_qty>0%'
        AND definition.body LIKE '%fulfillment_status=''IN_TRANSIT''%')
      OR (NOT state.applied
        AND definition.body LIKE '%fulfillment_status=''COMPLETED''%'
        AND definition.body NOT LIKE '%to_invoice_base_qty>0%')
      THEN 0 ELSE 1 END,
    jsonb_build_object('migrationApplied',state.applied,
      'completedGate',definition.body LIKE '%fulfillment_status=''COMPLETED''%',
      'mixedInvoiceableGate',definition.body LIKE '%to_invoice_base_qty>0%')
  FROM migration_state state CROSS JOIN invoice_definition definition
  UNION ALL
  SELECT 'mixed_receipt_clean_wrapper_compatibility',
    CASE WHEN to_regprocedure(
      'public.receive_backoffice_sales_delivery(uuid,bigint,uuid,date,text)') IS NOT NULL
      THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN to_regprocedure(
      'public.receive_backoffice_sales_delivery(uuid,bigint,uuid,date,text)') IS NULL
      THEN 1 ELSE 0 END,
    jsonb_build_object('legacyWrapperPreserved',to_regprocedure(
      'public.receive_backoffice_sales_delivery(uuid,bigint,uuid,date,text)') IS NOT NULL)
  UNION ALL
  SELECT 'mixed_receipt_active_finance_queue',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*),
    jsonb_build_object('runRows',count(*))
  FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'mixed_receipt_nonterminal_offline',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*),
    jsonb_build_object('submissionRows',count(*))
  FROM public.pos_offline_sale_submissions
  WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
  UNION ALL
  SELECT 'mixed_receipt_runtime_inventory','INFO',0,
    jsonb_build_object('inTransitDeliveries',count(*) FILTER(WHERE status='IN_TRANSIT'),
      'completedDeliveries',count(*) FILTER(WHERE status='COMPLETED'))
  FROM public.backoffice_sales_delivery_orders
)
SELECT check_name,status,violation_rows,details FROM checks ORDER BY check_name;
