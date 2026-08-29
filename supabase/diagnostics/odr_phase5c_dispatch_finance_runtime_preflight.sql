-- ODR-5C Dispatch Finance runtime exact preflight.
-- SAFETY: SELECT-only. No Dispatch, Stock, Event, Queue or Journal mutation.
WITH dependency_versions(version) AS (
  VALUES('20260828140000'::TEXT),('20260828210000'),('20260828220000')
),odr_orders AS (
  SELECT sale.company_id,sale.id sales_id,sale.store_id,
    sale.sales_warehouse_id warehouse_id,sale.customer_id,
    sale.document_status,sale.order_runtime_status,sale.is_tempo,
    sale.grand_total_after_rounding,sale.rounding_adjustment,
    sale.delivery_fee_amount,reservation.id reservation_id,
    delivery.id delivery_document_id,delivery.status delivery_status,
    delivery.dispatch_version,invoice.id invoice_snapshot_id
  FROM public.sales_stock_reservations reservation
  JOIN public.sales_headers sale ON sale.company_id=reservation.company_id
    AND sale.id=reservation.sales_id
  LEFT JOIN public.sales_delivery_documents delivery
    ON delivery.company_id=reservation.company_id
   AND delivery.reservation_id=reservation.id
  LEFT JOIN public.sales_invoice_snapshots invoice
    ON invoice.company_id=sale.company_id AND invoice.sales_id=sale.id
),dispatch_operations AS (
  SELECT allocation.company_id,allocation.delivery_document_id,
    allocation.reservation_id,allocation.dispatch_idempotency_key,
    min(allocation.created_at) dispatch_at,
    sum(allocation.dispatched_base_qty) dispatched_base_qty,
    round(sum(CASE WHEN allocation.allocation_kind='FIFO'
      THEN allocation.dispatched_base_qty*allocation.unit_cost_snapshot
      ELSE 0 END),4) fifo_cost_total,
    count(*) allocation_count
  FROM public.sales_dispatch_allocations allocation
  GROUP BY allocation.company_id,allocation.delivery_document_id,
    allocation.reservation_id,allocation.dispatch_idempotency_key
),effect_scope AS (
  SELECT effect.*,event.status event_status,journal.id journal_id
  FROM public.sales_dispatch_financial_effects effect
  LEFT JOIN public.financial_events event ON event.company_id=effect.company_id
    AND event.id=effect.financial_event_id
  LEFT JOIN public.finance_journals journal ON journal.company_id=event.company_id
    AND journal.financial_event_id=event.id
),target_categories AS (
  SELECT company.id company_id,company.company_code,event.system_key,
    category.id category_id
  FROM public.companies company
  CROSS JOIN (VALUES('SALE_DISPATCHED'::TEXT)) event(system_key)
  LEFT JOIN public.transaction_categories category
    ON category.company_id=company.id AND category.system_key=event.system_key
   AND category.category_code='ODR-SALE-DISPATCHED' AND category.is_active
  WHERE company.status='ACTIVE'
),required_functions(function_key) AS (
  VALUES('CUSTOMER_RECEIVABLE'::TEXT),('PAYMENT_CLEARING'),
    ('CUSTOMER_ADVANCE_LIABILITY'),('SALES_REVENUE'),('OUTPUT_TAX'),
    ('DELIVERY_FEE_REVENUE'),('PAYMENT_SURCHARGE_INCOME'),
    ('ROUNDING_GAIN'),('ROUNDING_LOSS'),('COGS'),('INVENTORY_ASSET')
),checks AS (
  SELECT 'odr_phase5c_dependencies'::TEXT check_name,
    CASE WHEN count(*) FILTER(WHERE migration.version IS NULL)=0
      THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('expected',count(*),'missing',COALESCE(jsonb_agg(
      dependency.version ORDER BY dependency.version)
      FILTER(WHERE migration.version IS NULL),'[]'::JSONB)) details
  FROM dependency_versions dependency
  LEFT JOIN private.kgs_schema_migrations migration
    ON migration.version=dependency.version

  UNION ALL
  SELECT 'active_finance_posting_queue',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('runCount',count(*))
  FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')

  UNION ALL
  SELECT 'nonterminal_offline_submission',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('submissionCount',count(*))
  FROM public.pos_offline_sale_submissions
  WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')

  UNION ALL
  SELECT 'posted_journal_balance',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('journalCount',count(*))
  FROM public.finance_journals journal
  WHERE journal.status='POSTED'
    AND (journal.total_debit<>journal.total_credit OR journal.total_debit<0)

  UNION ALL
  SELECT 'dispatch_source_schema_contract',
    CASE WHEN count(*)=18 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('expected',18,'columnRows',count(*))
  FROM information_schema.columns column_state
  WHERE column_state.table_schema='public'
    AND column_state.table_name='sales_dispatch_financial_effects'
    AND column_state.column_name IN('id','company_id','sales_id',
      'delivery_document_id','reservation_id','dispatch_idempotency_key',
      'dispatch_version','effective_date','dispatched_base_qty',
      'commercial_amount','tax_amount','delivery_fee_amount',
      'payment_surcharge_amount','rounding_adjustment','receivable_amount',
      'clearing_amount','fifo_cost_total','source_snapshot')

  UNION ALL
  SELECT 'dispatch_finance_source_zero_runtime',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('effectRows',count(*))
  FROM public.sales_dispatch_financial_effects

  UNION ALL
  SELECT 'dispatch_operation_source_coverage',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('operationCount',count(*))
  FROM dispatch_operations operation
  LEFT JOIN public.sales_dispatch_financial_effects effect
    ON effect.company_id=operation.company_id
   AND effect.delivery_document_id=operation.delivery_document_id
   AND effect.dispatch_idempotency_key=operation.dispatch_idempotency_key
  WHERE effect.id IS NULL

  UNION ALL
  SELECT 'dispatch_source_operation_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('effectCount',count(*))
  FROM effect_scope effect
  LEFT JOIN dispatch_operations operation ON operation.company_id=effect.company_id
    AND operation.delivery_document_id=effect.delivery_document_id
    AND operation.dispatch_idempotency_key=effect.dispatch_idempotency_key
  WHERE operation.delivery_document_id IS NULL
    OR operation.reservation_id<>effect.reservation_id
    OR abs(operation.dispatched_base_qty-effect.dispatched_base_qty)>0.000001
    OR abs(operation.fifo_cost_total-effect.fifo_cost_total)>0.0001

  UNION ALL
  SELECT 'dispatch_document_snapshot_readiness',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('orderCount',count(*))
  FROM odr_orders sale
  WHERE sale.invoice_snapshot_id IS NULL OR sale.delivery_document_id IS NULL

  UNION ALL
  SELECT 'dispatch_allocation_movement_coverage',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('allocationRows',count(*))
  FROM public.sales_dispatch_allocations allocation
  LEFT JOIN public.stock_movements movement ON movement.company_id=allocation.company_id
    AND movement.id=allocation.stock_movement_id
  WHERE allocation.stock_movement_id IS NULL OR movement.id IS NULL

  UNION ALL
  SELECT 'dispatch_accounting_period_readiness',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('operationCount',count(*))
  FROM dispatch_operations operation
  WHERE NOT EXISTS(SELECT 1 FROM public.accounting_periods period
    WHERE period.company_id=operation.company_id
      AND period.status IN('OPEN','REOPENED')
      AND (operation.dispatch_at::DATE BETWEEN period.start_date AND period.end_date
        OR period.start_date>operation.dispatch_at::DATE))

  UNION ALL
  SELECT 'dispatch_exact_account_mapping',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('invalidRows',count(*))
  FROM target_categories category CROSS JOIN required_functions account_function
  WHERE category.category_id IS NULL OR (SELECT count(*)
    FROM public.transaction_account_rules rule
    JOIN public.chart_of_accounts account ON account.company_id=rule.company_id
      AND account.id=rule.account_id AND account.is_active AND account.is_postable
    WHERE rule.company_id=category.company_id
      AND rule.transaction_category_id=category.category_id
      AND rule.system_key=category.system_key
      AND rule.account_function_key=account_function.function_key
      AND rule.status='ACTIVE' AND rule.effective_from<=clock_timestamp()
      AND (rule.effective_to IS NULL OR rule.effective_to>clock_timestamp()))<>1

  UNION ALL
  SELECT 'dispatch_approved_posting_rule',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('invalidRows',count(*))
  FROM target_categories category
  WHERE category.category_id IS NULL OR (SELECT count(*)
    FROM public.posting_rule_sets rule_set
    WHERE rule_set.company_id=category.company_id
      AND rule_set.transaction_category_id=category.category_id
      AND rule_set.system_key=category.system_key AND rule_set.status='APPROVED'
      AND rule_set.effective_from<=clock_timestamp()
      AND (rule_set.effective_to IS NULL
        OR rule_set.effective_to>clock_timestamp()))<>1

  UNION ALL
  SELECT 'dispatch_event_type_compatibility',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('legacyEventType','SALE_POSTED','enumRows',count(*))
  FROM pg_type type_state JOIN pg_enum enum_state
    ON enum_state.enumtypid=type_state.oid
  WHERE type_state.typname=(SELECT column_state.udt_name
    FROM information_schema.columns column_state
    WHERE column_state.table_schema='public'
      AND column_state.table_name='financial_events'
      AND column_state.column_name='event_type')
    AND enum_state.enumlabel='SALE_POSTED'

  UNION ALL
  SELECT 'canonical_dispatch_finance_hook_state','SETUP',
    jsonb_build_object('routineRows',count(*),
      'routinesReferencingDispatchSource',count(*) FILTER(
        WHERE routine.prosrc~'sales_dispatch_financial_effects'),
      'routinesReferencingFinancialEvent',count(*) FILTER(
        WHERE routine.prosrc~'financial_events'))
  FROM pg_proc routine JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
  WHERE namespace.nspname='private' AND routine.proname='dispatch_sales_delivery_core'

  UNION ALL
  SELECT 'dispatch_partial_commercial_allocation_scope','REVIEW',
    jsonb_build_object('dispatchOperations',count(*),
      'partialOperations',count(*) FILTER(
        WHERE sale.delivery_status='PARTIALLY_DISPATCHED'),
      'requiredDesign',jsonb_build_array(
        'one immutable effect and Event per dispatch idempotency key',
        'line commercial value allocated by dispatched ratio',
        'actual FIFO or approved negative provisional cost',
        'tax delivery surcharge and rounding residual only close on final dispatch'))
  FROM dispatch_operations operation JOIN odr_orders sale
    ON sale.company_id=operation.company_id
   AND sale.reservation_id=operation.reservation_id

  UNION ALL
  SELECT 'dispatch_payment_settlement_boundary','REVIEW',jsonb_build_object(
    'requiredDesign',jsonb_build_array(
      'Dispatch recognizes commercial and stock effect only',
      'unverified payment remains Payment Clearing or Customer Advance',
      'verified payment settlement is ODR-5D authority',
      'legacy POSTED Sale journals remain immutable'))

  UNION ALL
  SELECT 'odr5c_dispatch_runtime_inventory','INFO',jsonb_build_object(
    'orders',(SELECT count(*) FROM odr_orders),
    'dispatchOperations',(SELECT count(*) FROM dispatch_operations),
    'dispatchAllocations',(SELECT count(*) FROM public.sales_dispatch_allocations),
    'dispatchEffects',(SELECT count(*) FROM public.sales_dispatch_financial_effects),
    'dispatchEvents',(SELECT count(*) FROM public.financial_events
      WHERE system_event_key='SALE_DISPATCHED'),
    'dispatchJournals',(SELECT count(*) FROM public.finance_journals journal
      JOIN public.financial_events event ON event.company_id=journal.company_id
        AND event.id=journal.financial_event_id
      WHERE event.system_event_key='SALE_DISPATCHED'),
    'historicalPostedJournals',(SELECT count(*) FROM public.finance_journals
      WHERE status='POSTED'))
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 0 WHEN 'PASS' THEN 1
  WHEN 'REVIEW' THEN 2 WHEN 'SETUP' THEN 3 ELSE 4 END,check_name;
