-- SELECT-only preflight for direct Retail POS non-cash atomic verification.
WITH
runtime AS (
  SELECT
    pg_get_functiondef(
      'public.review_sales_payment_verification(uuid,bigint,text,text,uuid)'::regprocedure
    ) review_definition,
    pg_get_functiondef(
      'private.post_sale_return_financial_event_core(uuid,uuid,bigint,uuid)'::regprocedure
    ) sale_post_definition
),
non_cash AS (
  SELECT sale.company_id,sale.id sales_id,payment.client_payment_key,
    payment.settlement_route_snapshot,event.id sale_event_id,
    event.status::text sale_event_status,
    (SELECT count(*) FROM public.finance_journals journal
      WHERE journal.company_id=event.company_id
        AND journal.financial_event_id=event.id
        AND journal.status='POSTED') posted_journal_rows,
    request.id request_id
  FROM public.sales_headers sale
  JOIN public.sales_payments payment
    ON payment.company_id=sale.company_id AND payment.sales_id=sale.id
   AND payment.settlement_route_snapshot IN ('DIRECT_BANK','CLEARING')
  LEFT JOIN public.sales_payment_verification_requests request
    ON request.company_id=payment.company_id AND request.sales_id=payment.sales_id
   AND request.client_payment_key=payment.client_payment_key
  LEFT JOIN public.financial_events event
    ON event.company_id=sale.company_id AND event.source_table='sales_headers'
   AND event.source_id=sale.id AND event.system_event_key='SALE_POSTED'
  WHERE sale.sales_origin='POS'
    AND sale.sales_process_mode='RETAIL_CONFIRM_INVOICE'
    AND sale.document_status='POSTED'
    AND sale.order_runtime_status='LEGACY_POSTED'
),
checks AS (
  SELECT 10 seq,'pos_retail_non_cash_atomic_preflight_dependency_ledger'::text check_name,
    CASE WHEN count(*)=3 THEN 'PASS' ELSE 'BLOCKER' END status,
    abs(count(*)-3) violation_rows,
    jsonb_build_object('required',jsonb_build_array('20260923100000',
      '20261030120000','20261030130000'),'installed',count(*)) details
  FROM private.kgs_schema_migrations
  WHERE version IN ('20260923100000','20261030120000','20261030130000')
  UNION ALL
  SELECT 20,'pos_retail_non_cash_atomic_preflight_installation_state',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*),
    jsonb_build_object('state',CASE WHEN count(*)=0 THEN 'NOT_INSTALLED'
      ELSE 'INSTALLED_OR_PARTIAL' END,'ledgerRows',count(*))
  FROM private.kgs_schema_migrations WHERE version='20261031100000'
  UNION ALL
  SELECT 30,'pos_retail_non_cash_atomic_preflight_runtime_anchors',
    CASE WHEN review_definition~'MAKER_CHECKER_REQUIRED'
      AND review_definition~'SALE_PAYMENT_VERIFIED'
      AND review_definition~'kgs.odr5_payment_verification_mutation'
      AND sale_post_definition~'FINANCIAL_EVENT_GROSS_DISCOUNT_MISMATCH'
      AND sale_post_definition~'kgs_retail_sale_category_components'
      AND sale_post_definition~
        'payment\.settlement_account_function_snapshot[[:space:]]+(AS[[:space:]]+)?function_key'
      THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN review_definition~'MAKER_CHECKER_REQUIRED'
      AND review_definition~'SALE_PAYMENT_VERIFIED'
      AND review_definition~'kgs.odr5_payment_verification_mutation'
      AND sale_post_definition~'FINANCIAL_EVENT_GROSS_DISCOUNT_MISMATCH'
      AND sale_post_definition~'kgs_retail_sale_category_components'
      AND sale_post_definition~
        'payment\.settlement_account_function_snapshot[[:space:]]+(AS[[:space:]]+)?function_key'
      THEN 0 ELSE 1 END,
    jsonb_build_object('reviewAtomicPostingAlreadyPresent',
      review_definition~'private.post_financial_event_core',
      'saleOwnershipAlreadyPresent',
      sale_post_definition~'resolve_direct_retail_sale_payment_function')
  FROM runtime
  UNION ALL
  SELECT 40,'pos_retail_non_cash_atomic_preflight_backlog_partition',
    CASE WHEN count(*) FILTER (WHERE sale_event_id IS NULL)=0
      AND count(*) FILTER (WHERE request_id IS NULL
        AND NOT ((sale_event_status='HOLD' AND posted_journal_rows=0)
          OR (sale_event_status='POSTED' AND posted_journal_rows=1)))=0
      THEN 'PASS' ELSE 'BLOCKER' END,
    count(*) FILTER (WHERE sale_event_id IS NULL)
      +count(*) FILTER (WHERE request_id IS NULL
        AND NOT ((sale_event_status='HOLD' AND posted_journal_rows=0)
          OR (sale_event_status='POSTED' AND posted_journal_rows=1))),
    jsonb_build_object('nonCashLegs',count(*),
      'missingRequests',count(*) FILTER (WHERE request_id IS NULL),
      'safeHoldBackfill',count(*) FILTER (WHERE request_id IS NULL
        AND sale_event_status='HOLD' AND posted_journal_rows=0),
      'legacyPostedExcluded',count(*) FILTER (WHERE request_id IS NULL
        AND sale_event_status='POSTED' AND posted_journal_rows=1),
      'missingSaleEvents',count(*) FILTER (WHERE sale_event_id IS NULL))
  FROM non_cash
  UNION ALL
  SELECT 50,'pos_retail_non_cash_atomic_preflight_finance_authority',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*),
    jsonb_build_object('invalidCompanies',coalesce(jsonb_agg(company_code)
      FILTER (WHERE company_code IS NOT NULL),'[]'::jsonb))
  FROM (
    SELECT company.company_code
    FROM (SELECT DISTINCT company_id FROM non_cash) scope
    JOIN public.companies company ON company.id=scope.company_id
    WHERE (SELECT count(*) FROM public.transaction_categories category
      WHERE category.company_id=scope.company_id
        AND category.system_key='SALE_PAYMENT_VERIFIED' AND category.is_active)<>1
      OR NOT EXISTS (SELECT 1 FROM public.accounting_periods period
        WHERE period.company_id=scope.company_id
          AND current_date BETWEEN period.start_date AND period.end_date
          AND period.status IN ('OPEN','REOPENED'))
  ) invalid
  UNION ALL
  SELECT 60,'pos_retail_non_cash_atomic_preflight_runtime_boundary',
    CASE WHEN (SELECT count(*) FROM public.finance_posting_queue_runs
        WHERE status IN ('PREVIEWED','APPROVED','PROCESSING'))=0
      AND (SELECT count(*) FROM public.pos_offline_sale_submissions
        WHERE status IN ('QUEUED','SYNCING','NEEDS_CONFIRMATION'))=0
      THEN 'PASS' ELSE 'BLOCKER' END,
    (SELECT count(*) FROM public.finance_posting_queue_runs
      WHERE status IN ('PREVIEWED','APPROVED','PROCESSING'))
    +(SELECT count(*) FROM public.pos_offline_sale_submissions
      WHERE status IN ('QUEUED','SYNCING','NEEDS_CONFIRMATION')),
    jsonb_build_object('activeFinanceQueue',(SELECT count(*)
      FROM public.finance_posting_queue_runs
      WHERE status IN ('PREVIEWED','APPROVED','PROCESSING')),
      'nonterminalOffline',(SELECT count(*) FROM public.pos_offline_sale_submissions
      WHERE status IN ('QUEUED','SYNCING','NEEDS_CONFIRMATION')))
)
SELECT check_name,status,violation_rows,details FROM checks ORDER BY seq;
