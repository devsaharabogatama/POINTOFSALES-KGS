-- ODR-5F Finance runtime closure postflight. SELECT-only.
WITH checks AS (
  SELECT 'active_finance_posting_queue'::TEXT check_name,
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END status,count(*) violation_rows,
    jsonb_build_object('runCount',count(*)) details
  FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'migration_ledger',CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    abs(count(*)-1),jsonb_build_object('ledgerRows',count(*))
  FROM private.kgs_schema_migrations WHERE version='20260828260000'
  UNION ALL
  SELECT 'odr_finance_migration_chain',
    CASE WHEN count(*)=6 THEN 'PASS' ELSE 'FAIL' END,abs(count(*)-6),
    jsonb_build_object('expected',6,'ledgerRows',count(*))
  FROM private.kgs_schema_migrations WHERE version IN('20260828210000',
    '20260828220000','20260828230000','20260828240000','20260828250000',
    '20260828260000')
  UNION ALL
  SELECT 'automatic_policy_switch_contract',
    CASE WHEN definition~'20260828260000' THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN definition~'20260828260000' THEN 0 ELSE 1 END,
    jsonb_build_object('routineRows',1)
  FROM (SELECT pg_get_functiondef(
    'private.trg_odr5c_guard_automatic_posting_policy()'::regprocedure
  ) definition) runtime
  UNION ALL
  SELECT 'controlled_automatic_dispatcher_parity',
    CASE WHEN definition~'NO_FINANCIAL_EFFECT'
      AND definition~'noFinancialEffect'
      AND definition~'PREDISPATCH_ADVANCE_EVENT_NOT_POSTED'
      AND definition~'post_odr_payment_financial_event_core'
      AND definition~'post_financial_event_core_pre_odr5d'
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN definition~'NO_FINANCIAL_EFFECT'
      AND definition~'noFinancialEffect'
      AND definition~'PREDISPATCH_ADVANCE_EVENT_NOT_POSTED'
      AND definition~'post_odr_payment_financial_event_core'
      AND definition~'post_financial_event_core_pre_odr5d'
      THEN 0 ELSE 1 END,jsonb_build_object('routineRows',1)
  FROM (SELECT pg_get_functiondef(
    'private.post_financial_event_core(uuid,uuid,bigint,uuid)'::regprocedure
  ) definition) runtime
  UNION ALL
  SELECT 'private_finance_dispatcher_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('authenticatedExecutableRows',count(*))
  FROM information_schema.routine_privileges privilege
  WHERE privilege.grantee IN('anon','authenticated','PUBLIC')
    AND privilege.privilege_type='EXECUTE' AND privilege.specific_schema='private'
    AND privilege.routine_name IN('post_financial_event_core',
      'trg_odr5c_guard_automatic_posting_policy')
  UNION ALL
  SELECT 'open_finance_posting_exception',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('exceptionRows',count(*))
  FROM public.finance_posting_exceptions WHERE status<>'RESOLVED'
  UNION ALL
  SELECT 'duplicate_odr_event_journal',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('duplicateGroups',count(*))
  FROM (SELECT journal.company_id,journal.financial_event_id
    FROM public.finance_journals journal
    WHERE journal.system_event_key IN('SALE_DISPATCHED','SALE_PAYMENT_VERIFIED')
      AND journal.financial_event_id IS NOT NULL
    GROUP BY journal.company_id,journal.financial_event_id HAVING count(*)>1) duplicate
  UNION ALL
  SELECT 'posted_odr_event_journal_coverage',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('rowCount',count(*))
  FROM public.financial_events event
  LEFT JOIN public.finance_journals journal ON journal.company_id=event.company_id
    AND journal.financial_event_id=event.id AND journal.status='POSTED'
  WHERE event.system_event_key IN('SALE_DISPATCHED','SALE_PAYMENT_VERIFIED')
    AND ((event.status::TEXT='POSTED' AND journal.id IS NULL)
      OR (event.status::TEXT='HOLD' AND journal.id IS NOT NULL)
      OR (event.status::TEXT='CANCELED' AND journal.id IS NOT NULL))
  UNION ALL
  SELECT 'posted_odr_journal_balance',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('journalCount',count(*))
  FROM public.finance_journals journal
  WHERE journal.system_event_key IN('SALE_DISPATCHED','SALE_PAYMENT_VERIFIED')
    AND journal.status='POSTED' AND (journal.total_debit<=0
      OR journal.total_debit<>journal.total_credit)
  UNION ALL
  SELECT 'dispatch_source_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('effectCount',count(*))
  FROM public.sales_dispatch_financial_effects effect
  WHERE effect.settlement_rebalance_version<>1
    OR round(effect.receivable_amount+effect.clearing_amount+
      effect.advance_applied_amount,4)<>round(effect.commercial_amount+
      effect.tax_amount+effect.delivery_fee_amount+
      effect.payment_surcharge_amount+effect.rounding_adjustment,4)
  UNION ALL
  SELECT 'payment_verification_source_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('requestCount',count(*))
  FROM public.sales_payment_verification_requests request
  LEFT JOIN public.financial_events event ON event.company_id=request.company_id
    AND event.id=request.financial_event_id
  WHERE request.status='VERIFIED' AND (event.id IS NULL
    OR event.source_table<>'sales_payment_verification_requests'
    OR event.source_id<>request.id OR event.system_event_key<>'SALE_PAYMENT_VERIFIED')
  UNION ALL
  SELECT 'predispatch_advance_posting_order',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('dispatchEventCount',count(*))
  FROM public.sales_dispatch_financial_effects effect
  JOIN public.financial_events dispatch_event
    ON dispatch_event.company_id=effect.company_id
   AND dispatch_event.id=effect.financial_event_id
  WHERE effect.advance_applied_amount>0 AND dispatch_event.status::TEXT='POSTED'
    AND EXISTS(SELECT 1 FROM public.sales_payment_verification_requests request
      JOIN public.financial_events payment_event
        ON payment_event.company_id=request.company_id
       AND payment_event.id=request.financial_event_id
      WHERE request.company_id=effect.company_id AND request.sales_id=effect.sales_id
        AND request.status='VERIFIED' AND request.receipt_timing='PRE_DISPATCH'
        AND request.settlement_target='CUSTOMER_ADVANCE'
        AND payment_event.status::TEXT<>'POSTED')
),inventory AS (
  SELECT 'odr_finance_closure_inventory'::TEXT check_name,'INFO'::TEXT status,
    0::BIGINT violation_rows,jsonb_build_object(
      'controlledCompanies',(SELECT count(*) FROM public.finance_company_policies
        WHERE posting_mode='CONTROLLED'),
      'automaticCompanies',(SELECT count(*) FROM public.finance_company_policies
        WHERE posting_mode='AUTOMATIC'),
      'dispatchEffects',(SELECT count(*) FROM public.sales_dispatch_financial_effects),
      'paymentRequests',(SELECT count(*)
        FROM public.sales_payment_verification_requests),
      'holdEvents',(SELECT count(*) FROM public.financial_events
        WHERE system_event_key IN('SALE_DISPATCHED','SALE_PAYMENT_VERIFIED')
          AND status::TEXT='HOLD'),
      'postedEvents',(SELECT count(*) FROM public.financial_events
        WHERE system_event_key IN('SALE_DISPATCHED','SALE_PAYMENT_VERIFIED')
          AND status::TEXT='POSTED'),
      'postedJournals',(SELECT count(*) FROM public.finance_journals
        WHERE system_event_key IN('SALE_DISPATCHED','SALE_PAYMENT_VERIFIED')
          AND status='POSTED')
    ) details
)
SELECT * FROM (SELECT * FROM checks UNION ALL SELECT * FROM inventory) result
ORDER BY check_name;
