-- Finance TEMPO Sale posting forward-fix preflight.
-- SAFETY: SELECT-only. No Sale, Event, Queue, Journal or mapping is changed.
WITH tempo_events AS MATERIALIZED (
  SELECT event.id,event.company_id,event.event_date,event.transaction_category_id,
    event.amounts,sale.id sales_id,sale.customer_id,sale.grand_total_after_rounding,
    sale.paid_amount,sale.sisa_piutang
  FROM public.financial_events event
  JOIN public.sales_headers sale ON sale.company_id=event.company_id
    AND sale.id=event.source_id AND sale.document_status='POSTED'
  WHERE event.status::TEXT='HOLD' AND event.system_event_key='SALE_POSTED'
    AND event.event_type::TEXT='SALE_POSTED' AND event.source_table='sales_headers'
    AND sale.sisa_piutang>0
),tempo_totals AS MATERIALIZED (
  SELECT event.*,
    COALESCE((SELECT sum(payment.amount) FROM public.sales_payments payment
      WHERE payment.company_id=event.company_id
        AND payment.sales_id=event.sales_id),0) payment_total,
    COALESCE((SELECT sum(payment.customer_surcharge_amount)
      FROM public.sales_payments payment
      WHERE payment.company_id=event.company_id
        AND payment.sales_id=event.sales_id),0) surcharge_total
  FROM tempo_events event
),mapping_scope AS MATERIALIZED (
  SELECT event.*,
    (SELECT count(*) FROM public.transaction_account_rules rule
      WHERE rule.company_id=event.company_id
        AND rule.transaction_category_id=event.transaction_category_id
        AND rule.system_key='SALE_POSTED'
        AND rule.account_function_key='CUSTOMER_RECEIVABLE'
        AND rule.status='ACTIVE' AND rule.effective_from<=event.event_date
        AND (rule.effective_to IS NULL OR rule.effective_to>event.event_date)) exact_count,
    (SELECT count(*) FROM public.company_account_function_fallbacks fallback
      WHERE fallback.company_id=event.company_id
        AND fallback.account_function_key='CUSTOMER_RECEIVABLE'
        AND fallback.status='ACTIVE' AND fallback.effective_from<=event.event_date
        AND (fallback.effective_to IS NULL
          OR fallback.effective_to>event.event_date)) fallback_count
  FROM tempo_totals event
),mapping_plan AS MATERIALIZED (
  SELECT scope.*,
    COALESCE(future_fallback.account_id,
      CASE WHEN canonical.candidate_count=1 THEN canonical.account_id END)
      planned_account_id,
    CASE WHEN future_fallback.account_id IS NOT NULL THEN 'EARLIEST_ACTIVE_FALLBACK'
      WHEN canonical.candidate_count=1 THEN 'CANONICAL_SYSTEM_ACCOUNT'
      ELSE 'UNRESOLVED' END candidate_source,
    planned_account.is_active planned_account_active,
    planned_account.is_postable planned_account_postable,
    planned_account.account_type=ANY(function_state.compatible_account_types)
      planned_account_compatible
  FROM mapping_scope scope
  LEFT JOIN LATERAL (
    SELECT fallback.account_id
    FROM public.company_account_function_fallbacks fallback
    WHERE fallback.company_id=scope.company_id
      AND fallback.account_function_key='CUSTOMER_RECEIVABLE'
      AND fallback.status='ACTIVE' AND fallback.effective_from>scope.event_date
    ORDER BY fallback.effective_from,fallback.fallback_version,fallback.id LIMIT 1
  ) future_fallback ON TRUE
  LEFT JOIN LATERAL (
    SELECT count(*) candidate_count,
      (array_agg(account.id ORDER BY account.id))[1] account_id
    FROM public.chart_of_accounts account
    JOIN public.account_functions function_catalog
      ON function_catalog.function_key='CUSTOMER_RECEIVABLE'
      AND function_catalog.is_active
    WHERE account.company_id=scope.company_id
      AND account.system_function_key='CUSTOMER_RECEIVABLE'
      AND account.is_system_account AND account.is_active AND account.is_postable
      AND account.account_type=ANY(function_catalog.compatible_account_types)
  ) canonical ON TRUE
  LEFT JOIN public.chart_of_accounts planned_account
    ON planned_account.company_id=scope.company_id
    AND planned_account.id=COALESCE(future_fallback.account_id,
      CASE WHEN canonical.candidate_count=1 THEN canonical.account_id END)
  LEFT JOIN public.account_functions function_state
    ON function_state.function_key='CUSTOMER_RECEIVABLE' AND function_state.is_active
),checks(check_name,status,details) AS (
  SELECT 'tempo_posting_fix_dependency',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('expected',1,'ledgerRows',count(*),
      'requiredVersion','20260827140000')
  FROM private.kgs_schema_migrations WHERE version='20260827140000'
  UNION ALL
  SELECT 'active_finance_posting_queue',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('runCount',count(*))
  FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'tempo_hold_source_contract',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('violationRows',count(*))
  FROM tempo_totals event
  WHERE event.customer_id IS NULL OR event.sisa_piutang<=0
    OR round(COALESCE((event.amounts->>'receivable')::NUMERIC,-1),4)
      <>round(event.sisa_piutang,4)
    OR round(COALESCE((event.amounts->>'paymentTotal')::NUMERIC,-1),4)
      <>round(event.payment_total,4)
    OR round(event.paid_amount,4)<>round(event.payment_total,4)
    OR round(event.payment_total+event.sisa_piutang,4)
      <>round(event.grand_total_after_rounding+event.surcharge_total,4)
  UNION ALL
  SELECT 'tempo_receivable_account_resolution',
    CASE WHEN count(*)=0 THEN 'PASS'
      WHEN count(*) FILTER(WHERE event.exact_count>1 OR event.fallback_count>1
        OR event.planned_account_id IS NULL
        OR NOT COALESCE(event.planned_account_active,FALSE)
        OR NOT COALESCE(event.planned_account_postable,FALSE)
        OR NOT COALESCE(event.planned_account_compatible,FALSE))=0
      THEN 'BACKFILL' ELSE 'BLOCKER' END,
    jsonb_build_object('unresolvedOrAmbiguousRows',count(*),'mappingPlan',
      COALESCE(jsonb_agg(jsonb_build_object('companyId',event.company_id,
        'eventId',event.id,'eventDate',event.event_date,
        'exactCount',event.exact_count,'fallbackCount',event.fallback_count,
        'plannedAccountId',event.planned_account_id,
        'candidateSource',event.candidate_source)),'[]'::JSONB))
  FROM mapping_plan event
  WHERE NOT(event.exact_count=1
    OR (event.exact_count=0 AND event.fallback_count=1))
  UNION ALL
  SELECT 'existing_tempo_journal_effect',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('journalRows',count(*))
  FROM tempo_events event
  JOIN public.finance_journals journal ON journal.company_id=event.company_id
    AND journal.financial_event_id=event.id
  UNION ALL
  SELECT 'tempo_hold_runtime_inventory','INFO',jsonb_build_object(
    'events',count(*),'companies',count(DISTINCT company_id),
    'receivableTotal',COALESCE(sum(sisa_piutang),0),
    'paymentTotal',COALESCE(sum(payment_total),0))
  FROM tempo_totals
)
SELECT check_name,status,details FROM checks ORDER BY
  CASE status WHEN 'BLOCKER' THEN 1 WHEN 'BACKFILL' THEN 2
    WHEN 'PASS' THEN 3 ELSE 4 END,check_name;
