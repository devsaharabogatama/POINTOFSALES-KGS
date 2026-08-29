-- ODR-5E Dispatch advance/surcharge reconciliation postflight. SELECT-only.
WITH checks AS (
  SELECT 'active_finance_posting_queue'::TEXT check_name,
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END status,count(*) violation_rows,
    jsonb_build_object('runCount',count(*)) details
  FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'automatic_posting_remains_closed',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('automaticCompanies',count(*))
  FROM public.finance_company_policies WHERE posting_mode='AUTOMATIC'
  UNION ALL
  SELECT 'migration_ledger',CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    abs(count(*)-1),jsonb_build_object('ledgerRows',count(*))
  FROM private.kgs_schema_migrations WHERE version='20260828250000'
  UNION ALL
  SELECT 'required_dispatch_rebalance_routines',
    CASE WHEN count(*)=4 THEN 'PASS' ELSE 'FAIL' END,abs(count(*)-4),
    jsonb_build_object('expected',4,'routineRows',count(*))
  FROM unnest(ARRAY[
    'private.rebalance_dispatch_settlement_odr5e(uuid,uuid,uuid,uuid)',
    'private.dispatch_sales_delivery_core(uuid,bigint,uuid,jsonb,text)',
    'private.post_financial_event_core(uuid,uuid,bigint,uuid)',
    'private.trg_odr5_guard_dispatch_financial_effect()'
  ]) signature WHERE to_regprocedure(signature) IS NOT NULL
  UNION ALL
  SELECT 'required_dispatch_rebalance_columns',
    CASE WHEN count(*)=2 THEN 'PASS' ELSE 'FAIL' END,abs(count(*)-2),
    jsonb_build_object('expected',2,'columnRows',count(*))
  FROM information_schema.columns column_state
  WHERE column_state.table_schema='public'
    AND column_state.table_name='sales_dispatch_financial_effects'
    AND column_state.column_name IN(
      'settlement_rebalance_version','settlement_rebalanced_at')
  UNION ALL
  SELECT 'atomic_dispatch_rebalance_definition',
    CASE WHEN definition~'dispatch_sales_delivery_core_pre_odr5d'
      AND definition~'rebalance_dispatch_settlement_odr5e'
      AND definition!~'ODR_PREDISPATCH_ADVANCE_APPLICATION_NOT_READY'
      AND definition!~'ODR_PAYMENT_SURCHARGE_DISPATCH_APPLICATION_NOT_READY'
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN definition~'dispatch_sales_delivery_core_pre_odr5d'
      AND definition~'rebalance_dispatch_settlement_odr5e'
      AND definition!~'ODR_PREDISPATCH_ADVANCE_APPLICATION_NOT_READY'
      AND definition!~'ODR_PAYMENT_SURCHARGE_DISPATCH_APPLICATION_NOT_READY'
      THEN 0 ELSE 1 END,jsonb_build_object('routineRows',1)
  FROM (SELECT pg_get_functiondef(
    'private.dispatch_sales_delivery_core(uuid,bigint,uuid,jsonb,text)'::regprocedure
  ) definition) runtime
  UNION ALL
  SELECT 'predispatch_advance_posting_order_contract',
    CASE WHEN definition~'PREDISPATCH_ADVANCE_EVENT_NOT_POSTED'
      AND definition~'post_odr_payment_financial_event_core'
      AND definition~'post_financial_event_core_pre_odr5d'
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN definition~'PREDISPATCH_ADVANCE_EVENT_NOT_POSTED'
      AND definition~'post_odr_payment_financial_event_core'
      AND definition~'post_financial_event_core_pre_odr5d'
      THEN 0 ELSE 1 END,jsonb_build_object('routineRows',1)
  FROM (SELECT pg_get_functiondef(
    'private.post_financial_event_core(uuid,uuid,bigint,uuid)'::regprocedure
  ) definition) runtime
  UNION ALL
  SELECT 'private_dispatch_rebalance_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('authenticatedExecutableRows',count(*))
  FROM information_schema.routine_privileges privilege
  WHERE privilege.grantee IN('anon','authenticated','PUBLIC')
    AND privilege.privilege_type='EXECUTE' AND privilege.specific_schema='private'
    AND privilege.routine_name IN('rebalance_dispatch_settlement_odr5e',
      'dispatch_sales_delivery_core','post_financial_event_core',
      'trg_odr5_guard_dispatch_financial_effect')
  UNION ALL
  SELECT 'dispatch_effect_rebalance_coverage',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('effectCount',count(*))
  FROM public.sales_dispatch_financial_effects effect
  WHERE effect.settlement_rebalance_version<>1
    OR effect.settlement_rebalanced_at IS NULL
    OR NOT (effect.source_snapshot?'settlementRebalance')
  UNION ALL
  SELECT 'dispatch_effect_settlement_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('effectCount',count(*))
  FROM public.sales_dispatch_financial_effects effect
  WHERE round(effect.receivable_amount+effect.clearing_amount+
      effect.advance_applied_amount,4)<>round(effect.commercial_amount+
      effect.tax_amount+effect.delivery_fee_amount+
      effect.payment_surcharge_amount+effect.rounding_adjustment,4)
  UNION ALL
  SELECT 'dispatch_event_rebalance_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('rowCount',count(*))
  FROM public.sales_dispatch_financial_effects effect
  JOIN public.financial_events event ON event.company_id=effect.company_id
    AND event.id=effect.financial_event_id
  WHERE event.system_event_key<>'SALE_DISPATCHED'
    OR round((event.amounts->>'paymentSurchargeAmount')::NUMERIC,4)
      IS DISTINCT FROM effect.payment_surcharge_amount
    OR round((event.amounts->>'receivableAmount')::NUMERIC,4)
      IS DISTINCT FROM effect.receivable_amount
    OR round((event.amounts->>'clearingAmount')::NUMERIC,4)
      IS DISTINCT FROM effect.clearing_amount
    OR round((event.amounts->>'advanceAppliedAmount')::NUMERIC,4)
      IS DISTINCT FROM effect.advance_applied_amount
  UNION ALL
  SELECT 'dispatch_surcharge_final_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('salesCount',count(*))
  FROM (SELECT effect.company_id,effect.sales_id,
      sum(effect.payment_surcharge_amount) effect_surcharge,
      bool_or(COALESCE((effect.source_snapshot->>'finalDispatch')::BOOLEAN,FALSE)) final_seen
    FROM public.sales_dispatch_financial_effects effect
    GROUP BY effect.company_id,effect.sales_id) dispatch
  LEFT JOIN LATERAL(SELECT COALESCE(sum(COALESCE(
      (request.intent_snapshot->>'customerSurchargeAmount')::NUMERIC,0)),0) target
    FROM public.sales_payment_verification_requests request
    WHERE request.company_id=dispatch.company_id
      AND request.sales_id=dispatch.sales_id AND request.status<>'CANCELED') surcharge
    ON TRUE
  WHERE dispatch.effect_surcharge>surcharge.target
    OR (dispatch.final_seen AND dispatch.effect_surcharge<>surcharge.target)
  UNION ALL
  SELECT 'dispatch_advance_application_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('salesCount',count(*))
  FROM (SELECT effect.company_id,effect.sales_id,
      sum(effect.advance_applied_amount) applied
    FROM public.sales_dispatch_financial_effects effect
    GROUP BY effect.company_id,effect.sales_id) dispatch
  LEFT JOIN LATERAL(SELECT COALESCE(sum(request.amount),0) verified
    FROM public.sales_payment_verification_requests request
    WHERE request.company_id=dispatch.company_id
      AND request.sales_id=dispatch.sales_id AND request.status='VERIFIED'
      AND request.receipt_timing='PRE_DISPATCH'
      AND request.settlement_target='CUSTOMER_ADVANCE') advance ON TRUE
  WHERE dispatch.applied>advance.verified
  UNION ALL
  SELECT 'dispatch_rebalance_audit_coverage',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('effectCount',count(*))
  FROM public.sales_dispatch_financial_effects effect
  WHERE NOT EXISTS(SELECT 1 FROM public.sales_dispatch_financial_effect_audit audit
    WHERE audit.company_id=effect.company_id
      AND audit.dispatch_financial_effect_id=effect.id AND audit.action='REBALANCE'
      AND audit.idempotency_key=effect.dispatch_idempotency_key)
),inventory AS (
  SELECT 'dispatch_rebalance_runtime_inventory'::TEXT check_name,'INFO'::TEXT status,
    0::BIGINT violation_rows,jsonb_build_object(
      'effects',(SELECT count(*) FROM public.sales_dispatch_financial_effects),
      'paymentRequests',(SELECT count(*)
        FROM public.sales_payment_verification_requests),
      'verifiedPredispatch',(SELECT count(*)
        FROM public.sales_payment_verification_requests
        WHERE status='VERIFIED' AND receipt_timing='PRE_DISPATCH'),
      'advanceApplied',(SELECT COALESCE(sum(advance_applied_amount),0)
        FROM public.sales_dispatch_financial_effects),
      'surchargeRecognized',(SELECT COALESCE(sum(payment_surcharge_amount),0)
        FROM public.sales_dispatch_financial_effects),
      'holdDispatchEvents',(SELECT count(*) FROM public.financial_events
        WHERE system_event_key='SALE_DISPATCHED' AND status::TEXT='HOLD'),
      'postedDispatchEvents',(SELECT count(*) FROM public.financial_events
        WHERE system_event_key='SALE_DISPATCHED' AND status::TEXT='POSTED')
    ) details
)
SELECT * FROM (SELECT * FROM checks UNION ALL SELECT * FROM inventory) result
ORDER BY check_name;
