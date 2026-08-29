-- ODR-5 Finance Dispatch and Payment verification preflight.
-- SAFETY: SELECT-only. No Sale, Payment, Stock, Financial Event or Journal write.
WITH dependency_versions(version) AS (
  VALUES ('20260828130000'::TEXT),('20260828140000'::TEXT),
    ('20260828200000'::TEXT),('20260827140000'::TEXT),
    ('20260827141000'::TEXT)
), odr_sales AS (
  SELECT sale.company_id,sale.id sales_id,sale.store_id,
    sale.sales_warehouse_id warehouse_id,sale.customer_id,sale.session_id,
    sale.document_status,sale.order_runtime_status,sale.is_tempo,
    sale.transaction_date,sale.due_date,sale.grand_total_after_rounding,
    sale.sisa_piutang,sale.payload_snapshot,reservation.id reservation_id,
    delivery.id delivery_document_id,delivery.status delivery_status,
    invoice.id invoice_snapshot_id
  FROM public.sales_stock_reservations reservation
  JOIN public.sales_headers sale ON sale.company_id=reservation.company_id
    AND sale.id=reservation.sales_id
  LEFT JOIN public.sales_delivery_documents delivery
    ON delivery.company_id=reservation.company_id
   AND delivery.reservation_id=reservation.id
  LEFT JOIN public.sales_invoice_snapshots invoice
    ON invoice.company_id=sale.company_id AND invoice.sales_id=sale.id
), dispatch_operations AS (
  SELECT allocation.company_id,allocation.delivery_document_id,
    allocation.reservation_id,allocation.dispatch_idempotency_key,
    min(allocation.created_at) dispatch_at,
    sum(allocation.dispatched_base_qty) dispatched_base_qty,
    sum(CASE WHEN allocation.allocation_kind='FIFO'
      THEN allocation.dispatched_base_qty*allocation.unit_cost_snapshot
      ELSE 0 END) fifo_cost_total,
    count(*) allocation_count
  FROM public.sales_dispatch_allocations allocation
  GROUP BY allocation.company_id,allocation.delivery_document_id,
    allocation.reservation_id,allocation.dispatch_idempotency_key
), payment_intents AS (
  SELECT sale.company_id,sale.sales_id,sale.is_tempo,
    payment.value payment_payload,
    payment.value->>'clientPaymentKey' client_payment_key,
    payment.value->>'paymentMethodId' payment_method_text,
    CASE WHEN payment.value->>'paymentMethodId' ~*
      '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
      THEN (payment.value->>'paymentMethodId')::UUID END payment_method_id,
    CASE WHEN payment.value->>'amount' ~ '^[0-9]+([.][0-9]+)?$'
      THEN (payment.value->>'amount')::NUMERIC END amount
  FROM odr_sales sale
  CROSS JOIN LATERAL jsonb_array_elements(CASE
    WHEN jsonb_typeof(sale.payload_snapshot->'payments')='array'
      THEN sale.payload_snapshot->'payments' ELSE '[]'::JSONB END) payment(value)
), payment_intent_shape AS (
  SELECT intent.*,method.payment_method_code,method.method_type,
    method.settlement_route,method.clearing_account_function,
    method.bank_account_function,method.is_active method_is_active
  FROM payment_intents intent
  LEFT JOIN public.payment_methods method
    ON method.company_id=intent.company_id AND method.id=intent.payment_method_id
), odr_event_effect AS (
  SELECT event.company_id,event.id,event.root_sales_id,event.system_event_key,
    event.status
  FROM public.financial_events event
  JOIN odr_sales sale ON sale.company_id=event.company_id
    AND sale.sales_id=event.root_sales_id
  WHERE event.system_event_key IN('SALE_POSTED','SALE_PAYMENT',
    'SALE_DISPATCHED','SALE_PAYMENT_VERIFIED','CUSTOMER_BALANCE_RECEIPT')
), required_functions(function_key) AS (
  VALUES ('SALES_REVENUE'::TEXT),('INVENTORY_ASSET'),('COGS'),
    ('CUSTOMER_RECEIVABLE'),('PAYMENT_CLEARING'),('CASH_DRAWER'),('BANK'),
    ('OUTPUT_TAX'),('DELIVERY_FEE_REVENUE'),('PAYMENT_SURCHARGE_INCOME'),
    ('ROUNDING_GAIN'),('ROUNDING_LOSS')
), active_function_candidates AS (
  SELECT company.id company_id,required_function.function_key,
    count(DISTINCT account.id) FILTER(WHERE account.is_active
      AND account.is_postable) direct_accounts,
    count(DISTINCT fallback.id) FILTER(WHERE fallback.status='ACTIVE'
      AND fallback.effective_from<=clock_timestamp()
      AND (fallback.effective_to IS NULL
        OR fallback.effective_to>clock_timestamp())
      AND fallback_account.is_active AND fallback_account.is_postable)
      fallback_rows
  FROM public.companies company CROSS JOIN required_functions required_function
  LEFT JOIN public.chart_of_accounts account ON account.company_id=company.id
    AND account.system_function_key=required_function.function_key
  LEFT JOIN public.company_account_function_fallbacks fallback
    ON fallback.company_id=company.id
   AND fallback.account_function_key=required_function.function_key
  LEFT JOIN public.chart_of_accounts fallback_account
    ON fallback_account.company_id=fallback.company_id
   AND fallback_account.id=fallback.account_id
  WHERE company.status='ACTIVE'
  GROUP BY company.id,required_function.function_key
), checks AS (
  SELECT 'odr_phase5_dependencies'::TEXT check_name,
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
  SELECT 'duplicate_financial_event_journal',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('duplicateGroups',count(*))
  FROM (SELECT journal.company_id,journal.financial_event_id
    FROM public.finance_journals journal
    WHERE journal.financial_event_id IS NOT NULL
    GROUP BY journal.company_id,journal.financial_event_id HAVING count(*)>1) duplicate

  UNION ALL
  SELECT 'odr_order_zero_existing_finance_effect',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('eventRows',count(*))
  FROM odr_event_effect

  UNION ALL
  SELECT 'odr_order_document_snapshot_coverage',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('orderCount',count(*))
  FROM odr_sales sale
  WHERE sale.invoice_snapshot_id IS NULL OR sale.delivery_document_id IS NULL

  UNION ALL
  SELECT 'dispatch_allocation_movement_coverage',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('allocationRows',count(*))
  FROM public.sales_dispatch_allocations allocation
  LEFT JOIN public.stock_movements movement
    ON movement.company_id=allocation.company_id
   AND movement.id=allocation.stock_movement_id
  WHERE allocation.stock_movement_id IS NULL OR movement.id IS NULL

  UNION ALL
  SELECT 'odr_payment_intent_shape',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('invalidRows',count(*))
  FROM payment_intent_shape intent
  WHERE intent.client_payment_key IS NULL OR intent.payment_method_id IS NULL
    OR intent.amount IS NULL OR intent.amount<=0
    OR intent.payment_method_code IS NULL OR NOT intent.method_is_active
    OR intent.method_type='TEMPO'

  UNION ALL
  SELECT 'odr_legacy_sales_payment_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'REVIEW' END,
    jsonb_build_object('paymentRows',count(*),'contractCode',
      'PAYMENT_INTENT_UNVERIFIED')
  FROM public.sales_payments payment
  JOIN odr_sales sale ON sale.company_id=payment.company_id
    AND sale.sales_id=payment.sales_id
  WHERE NOT payment.is_reversal

  UNION ALL
  SELECT 'dispatch_partial_revenue_recognition_scope','REVIEW',
    jsonb_build_object('dispatchOperations',count(*),
      'partialDeliveryOperations',count(*) FILTER(
        WHERE sale.delivery_status='PARTIALLY_DISPATCHED'),
      'contractCodes',jsonb_build_array('DISPATCH_EVENT_PER_OPERATION',
        'PROPORTIONAL_COMMERCIAL_ALLOCATION','ACTUAL_FIFO_COST',
        'FINAL_DISPATCH_ROUNDING_RESIDUAL'))
  FROM dispatch_operations operation
  JOIN odr_sales sale ON sale.company_id=operation.company_id
    AND sale.reservation_id=operation.reservation_id

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
  SELECT 'finance_account_function_candidate_scope',
    CASE WHEN count(*) FILTER(WHERE direct_accounts=0 AND fallback_rows=0)=0
      THEN 'PASS' ELSE 'BACKFILL' END,
    jsonb_build_object('unresolvedRows',count(*) FILTER(
      WHERE direct_accounts=0 AND fallback_rows=0),
      'ambiguousRows',count(*) FILTER(
      WHERE direct_accounts>1 OR fallback_rows>1),
      'functions',COALESCE(jsonb_agg(DISTINCT function_key)
        FILTER(WHERE direct_accounts=0 AND fallback_rows=0),'[]'::JSONB))
  FROM active_function_candidates

  UNION ALL
  SELECT 'odr_finance_event_catalog_state','SETUP',jsonb_build_object(
    'existingReusableKeys',(SELECT COALESCE(jsonb_agg(system_key ORDER BY system_key),
      '[]'::JSONB) FROM public.system_events
      WHERE system_key IN('SALE_POSTED','SALE_PAYMENT')),
    'missingDedicatedKeys',(SELECT COALESCE(jsonb_agg(candidate.key ORDER BY candidate.key),
      '[]'::JSONB) FROM (VALUES('SALE_DISPATCHED'),('SALE_PAYMENT_VERIFIED')) candidate(key)
      WHERE NOT EXISTS(SELECT 1 FROM public.system_events event
        WHERE event.system_key=candidate.key)),
    'contractCode','DEDICATED_DISPATCH_AND_PAYMENT_EVENTS')

  UNION ALL
  SELECT 'odr_finance_runtime_state','SETUP',jsonb_build_object(
    'missingRelations',jsonb_strip_nulls(jsonb_build_object(
      'salesDispatchFinancialEffects',CASE WHEN
        to_regclass('public.sales_dispatch_financial_effects') IS NULL
        THEN 'MISSING' END,
      'salesPaymentVerificationRequests',CASE WHEN
        to_regclass('public.sales_payment_verification_requests') IS NULL
        THEN 'MISSING' END)),
    'contractCodes',jsonb_build_array('DISPATCH_COMMERCIAL_AND_STOCK_EVENT',
      'VERIFIED_PAYMENT_SETTLEMENT_EVENT','PREDISPATCH_PAYMENT_CLEARING',
      'CONTROLLED_POSTING_FIRST','LEGACY_SALE_JOURNAL_IMMUTABLE'))

  UNION ALL
  SELECT 'odr_finance_runtime_inventory','INFO',jsonb_build_object(
    'orders',(SELECT count(*) FROM odr_sales),
    'tempoOrders',(SELECT count(*) FROM odr_sales WHERE is_tempo),
    'dispatchOperations',(SELECT count(*) FROM dispatch_operations),
    'dispatchFifoCost',COALESCE((SELECT sum(fifo_cost_total)
      FROM dispatch_operations),0),
    'paymentIntentRows',(SELECT count(*) FROM payment_intents),
    'paymentIntentTotal',COALESCE((SELECT sum(amount) FROM payment_intents),0),
    'legacyPaymentRows',(SELECT count(*) FROM public.sales_payments payment
      JOIN odr_sales sale ON sale.company_id=payment.company_id
       AND sale.sales_id=payment.sales_id WHERE NOT payment.is_reversal),
    'historicalPostedSaleEvents',(SELECT count(*) FROM public.financial_events
      WHERE system_event_key='SALE_POSTED' AND status='POSTED'),
    'historicalPostedJournals',(SELECT count(*) FROM public.finance_journals
      WHERE status='POSTED'))
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 0 WHEN 'BACKFILL' THEN 1
  WHEN 'PASS' THEN 2 WHEN 'REVIEW' THEN 3 WHEN 'SETUP' THEN 4 ELSE 5 END,
  check_name;
