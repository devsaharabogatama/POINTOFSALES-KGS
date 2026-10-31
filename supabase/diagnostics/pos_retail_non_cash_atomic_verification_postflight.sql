-- SELECT-only postflight for direct Retail POS non-cash atomic verification.
WITH
non_cash AS (
  SELECT sale.company_id,sale.id sales_id,payment.client_payment_key,
    payment.settlement_route_snapshot,event.status::text sale_event_status,
    (SELECT count(*) FROM public.finance_journals journal
      WHERE journal.company_id=event.company_id
        AND journal.financial_event_id=event.id
        AND journal.status='POSTED') posted_sale_journal_rows,
    request.id request_id,request.status request_status
  FROM public.sales_headers sale
  JOIN public.sales_payments payment
    ON payment.company_id=sale.company_id AND payment.sales_id=sale.id
   AND payment.settlement_route_snapshot IN ('DIRECT_BANK','CLEARING')
  JOIN public.financial_events event
    ON event.company_id=sale.company_id AND event.source_table='sales_headers'
   AND event.source_id=sale.id AND event.system_event_key='SALE_POSTED'
  LEFT JOIN public.sales_payment_verification_requests request
    ON request.company_id=payment.company_id AND request.sales_id=payment.sales_id
   AND request.client_payment_key=payment.client_payment_key
  WHERE sale.sales_origin='POS'
    AND sale.sales_process_mode='RETAIL_CONFIRM_INVOICE'
    AND sale.document_status='POSTED'
    AND sale.order_runtime_status='LEGACY_POSTED'
),
runtime AS (
  SELECT
    pg_get_functiondef(
      'public.review_sales_payment_verification(uuid,bigint,text,text,uuid)'::regprocedure
    ) review_definition,
    pg_get_functiondef(
      'private.post_sale_return_financial_event_core(uuid,uuid,bigint,uuid)'::regprocedure
    ) sale_definition
),
auto_cash_cutover AS (
  SELECT max(applied_at) auto_cash_applied_at
  FROM private.kgs_schema_migrations
  WHERE version='20260923100000'
),
cash_boundary AS (
  SELECT cutover.auto_cash_applied_at,
    count(request.id) manual_cash_rows,
    count(request.id) FILTER (WHERE
      request.requested_at>=cutover.auto_cash_applied_at
      OR request.status='PENDING') invalid_manual_cash_rows,
    count(request.id) FILTER (WHERE
      request.requested_at<cutover.auto_cash_applied_at
      AND request.status IN ('VERIFIED','REJECTED','CANCELED'))
      legacy_terminal_rows
  FROM auto_cash_cutover cutover
  LEFT JOIN public.sales_payment_verification_requests request
    ON request.settlement_route_snapshot='CASH_DRAWER'
   AND request.verification_mode='MANUAL_REVIEW'
  GROUP BY cutover.auto_cash_applied_at
),
checks AS (
  SELECT 10 seq,'pos_retail_non_cash_atomic_postflight_migration_ledger'::text check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,abs(count(*)-1) violation_rows,
    jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20261031100000'
  UNION ALL
  SELECT 20,'pos_retail_non_cash_atomic_postflight_runtime_contract',
    CASE WHEN to_regprocedure(
        'private.capture_direct_retail_non_cash_payment_requests(uuid,uuid,uuid)') IS NOT NULL
      AND to_regprocedure(
        'private.resolve_direct_retail_sale_payment_function(uuid,uuid,uuid,text)') IS NOT NULL
      AND to_regprocedure(
        'private.trg_capture_direct_retail_non_cash_payment_requests()') IS NOT NULL
      AND review_definition~'private.post_financial_event_core'
      AND sale_definition~'resolve_direct_retail_sale_payment_function'
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN to_regprocedure(
        'private.capture_direct_retail_non_cash_payment_requests(uuid,uuid,uuid)') IS NOT NULL
      AND to_regprocedure(
        'private.resolve_direct_retail_sale_payment_function(uuid,uuid,uuid,text)') IS NOT NULL
      AND to_regprocedure(
        'private.trg_capture_direct_retail_non_cash_payment_requests()') IS NOT NULL
      AND review_definition~'private.post_financial_event_core'
      AND sale_definition~'resolve_direct_retail_sale_payment_function'
      THEN 0 ELSE 1 END,
    jsonb_build_object('atomicReview',review_definition~'private.post_financial_event_core',
      'clearingOwnership',sale_definition~'resolve_direct_retail_sale_payment_function')
  FROM runtime
  UNION ALL
  SELECT 30,'pos_retail_non_cash_atomic_postflight_backlog_contract',
    CASE WHEN count(*) FILTER (WHERE sale_event_status='HOLD'
        AND posted_sale_journal_rows=0 AND request_id IS NULL)=0
      THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER (WHERE sale_event_status='HOLD'
      AND posted_sale_journal_rows=0 AND request_id IS NULL),
    jsonb_build_object('nonCashLegs',count(*),
      'capturedRequests',count(*) FILTER (WHERE request_id IS NOT NULL),
      'pending',count(*) FILTER (WHERE request_status='PENDING'),
      'verified',count(*) FILTER (WHERE request_status='VERIFIED'),
      'legacyPostedExcluded',count(*) FILTER (WHERE sale_event_status='POSTED'
        AND posted_sale_journal_rows=1 AND request_id IS NULL))
  FROM non_cash
  UNION ALL
  SELECT 40,'pos_retail_non_cash_atomic_postflight_cash_boundary',
    CASE WHEN auto_cash_applied_at IS NOT NULL
      AND invalid_manual_cash_rows=0 THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN auto_cash_applied_at IS NULL THEN 1
      ELSE invalid_manual_cash_rows END,
    jsonb_build_object(
      'autoCashAppliedAt',auto_cash_applied_at,
      'manualCashRows',manual_cash_rows,
      'invalidManualCashRows',invalid_manual_cash_rows,
      'legacyTerminalExcluded',legacy_terminal_rows)
  FROM cash_boundary
  UNION ALL
  SELECT 50,'pos_retail_non_cash_atomic_postflight_customer_receipt_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('invalidPostedReceipts',count(*))
  FROM public.customer_receipt_documents receipt
  LEFT JOIN public.financial_events event
    ON event.company_id=receipt.company_id
   AND event.source_table='customer_receipt_documents'
   AND event.source_id=receipt.id AND event.system_event_key='SALE_PAYMENT'
  LEFT JOIN public.finance_journals journal
    ON journal.company_id=event.company_id AND journal.financial_event_id=event.id
   AND journal.status='POSTED'
  WHERE receipt.status='POSTED' AND (event.status::text<>'POSTED' OR journal.id IS NULL)
  UNION ALL
  SELECT 60,'pos_retail_non_cash_atomic_postflight_business_boundary','INFO',0,
    jsonb_build_object('changed',jsonb_build_array(
      'direct Retail DIRECT_BANK/CLEARING request capture',
      'Finance Verify posts payment Event atomically',
      'direct Retail non-cash Sale settlement uses PAYMENT_CLEARING'),
      'preserved',jsonb_build_array('Cash auto-verification','Tempo Customer Receipt',
        'Backoffice/ODR fulfillment','Stock/Reservation/FIFO','Return/Refund',
        'legacy Posted Journals','other Companies'))
)
SELECT check_name,status,violation_rows,details FROM checks ORDER BY seq;
