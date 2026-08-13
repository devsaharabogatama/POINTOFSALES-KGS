-- G6 phase 8A postflight: Sale/Return settlement mappings.
-- SAFETY: SELECT-only.

WITH settlement_scope AS MATERIALIZED (
  SELECT event.company_id,event.id event_id,event.transaction_category_id,
    event.system_event_key,event.event_date,
    CASE payment.settlement_route_snapshot
      WHEN 'CASH_DRAWER' THEN 'CASH_DRAWER'
      WHEN 'DIRECT_BANK' THEN method.bank_account_function
      WHEN 'CLEARING' THEN method.clearing_account_function
      WHEN 'RECEIVABLE' THEN 'CUSTOMER_RECEIVABLE'
      WHEN 'INTERNAL_LIABILITY' THEN 'CUSTOMER_BALANCE_LIABILITY'
    END function_key
  FROM public.financial_events event
  JOIN public.sales_payments payment ON payment.company_id=event.company_id
   AND payment.sales_id=event.source_id
  JOIN public.payment_methods method ON method.company_id=payment.company_id
   AND method.id=payment.payment_method_id
  WHERE event.status='HOLD'::public.event_status
    AND event.system_event_key='SALE_POSTED'
  UNION ALL
  SELECT event.company_id,event.id,event.transaction_category_id,
    event.system_event_key,event.event_date,
    CASE refund.settlement_route_snapshot
      WHEN 'CASH_DRAWER' THEN 'CASH_DRAWER'
      WHEN 'DIRECT_BANK' THEN method.bank_account_function
      WHEN 'CLEARING' THEN method.clearing_account_function
      WHEN 'RECEIVABLE' THEN 'CUSTOMER_RECEIVABLE'
      WHEN 'INTERNAL_LIABILITY' THEN 'CUSTOMER_BALANCE_LIABILITY'
    END
  FROM public.financial_events event
  JOIN public.sales_return_refunds refund ON refund.company_id=event.company_id
   AND refund.document_id=event.source_id
  JOIN public.payment_methods method ON method.company_id=refund.company_id
   AND method.id=refund.payment_method_id
  WHERE event.status='HOLD'::public.event_status
    AND event.system_event_key='SALES_RETURN'
), resolution AS MATERIALIZED (
  SELECT scope.*,(SELECT count(*)
    FROM public.transaction_account_rules rule
    WHERE rule.company_id=scope.company_id
      AND rule.transaction_category_id=scope.transaction_category_id
      AND rule.system_key=scope.system_event_key
      AND rule.account_function_key=scope.function_key
      AND rule.status='ACTIVE' AND rule.effective_from<=scope.event_date
      AND (rule.effective_to IS NULL OR rule.effective_to>scope.event_date)
    ) exact_count,(SELECT count(*)
    FROM public.company_account_function_fallbacks fallback
    WHERE fallback.company_id=scope.company_id
      AND fallback.account_function_key=scope.function_key
      AND fallback.status='ACTIVE'
      AND fallback.effective_from<=scope.event_date
      AND (fallback.effective_to IS NULL
           OR fallback.effective_to>scope.event_date)) fallback_count
  FROM settlement_scope scope
), checks(check_name,status,violation_rows,details) AS (
  SELECT 'migration_ledger',CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    abs(1-count(*)),jsonb_build_object('ledgerRows',count(*))
  FROM private.kgs_schema_migrations WHERE version='20260814100000'
  UNION ALL
  SELECT 'settlement_account_function_resolution',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('unresolvedRows',count(*),
      'functions',COALESCE(jsonb_agg(DISTINCT function_key),'[]'))
  FROM resolution WHERE function_key IS NULL
    OR NOT(exact_count=1 OR (exact_count=0 AND fallback_count=1))
  UNION ALL
  SELECT 'canonical_settlement_fallback_shape',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('invalidRows',count(*))
  FROM public.company_account_function_fallbacks fallback
  JOIN public.chart_of_accounts account ON account.company_id=fallback.company_id
   AND account.id=fallback.account_id
  WHERE fallback.status='ACTIVE'
    AND fallback.account_function_key IN('CASH_DRAWER','BANK_RECEIPT')
    AND (NOT account.is_active OR NOT account.is_postable
      OR NOT account.is_system_account OR account.account_type<>'ASSET'
      OR (fallback.account_function_key='CASH_DRAWER'
          AND account.system_function_key<>'CASH_DRAWER')
      OR (fallback.account_function_key='BANK_RECEIPT'
          AND account.system_function_key NOT IN('BANK_RECEIPT','BANK')))
  UNION ALL
  SELECT 'sale_return_finance_effect_remains_closed',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('journalRows',count(*))
  FROM public.finance_journals journal
  JOIN public.financial_events event ON event.company_id=journal.company_id
   AND event.id=journal.financial_event_id
  WHERE event.system_event_key IN('SALE_POSTED','SALES_RETURN')
  UNION ALL
  SELECT 'settlement_mapping_runtime_inventory','INFO',0,
    jsonb_build_object('paymentRefundLegs',(SELECT count(*) FROM settlement_scope),
      'resolvedLegs',(SELECT count(*) FROM resolution
        WHERE exact_count=1 OR (exact_count=0 AND fallback_count=1)),
      'activeFallbacks',(SELECT count(*)
        FROM public.company_account_function_fallbacks fallback
        WHERE fallback.status='ACTIVE' AND fallback.account_function_key
          IN('CASH_DRAWER','BANK_RECEIPT')))
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
