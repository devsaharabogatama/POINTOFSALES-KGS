-- ODR-5C Dispatch Finance runtime postflight. SELECT-only.
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
  FROM private.kgs_schema_migrations WHERE version='20260828230000'
  UNION ALL
  SELECT 'required_dispatch_finance_routines',
    CASE WHEN count(*)=8 THEN 'PASS' ELSE 'FAIL' END,abs(count(*)-8),
    jsonb_build_object('expected',8,'routineRows',count(*))
  FROM unnest(ARRAY[
    'private.dispatch_sales_delivery_stock_core_odr3c(uuid,bigint,uuid,jsonb,text)',
    'private.capture_dispatch_financial_effect_core(uuid,uuid,uuid,jsonb)',
    'private.dispatch_sales_delivery_core(uuid,bigint,uuid,jsonb,text)',
    'private.post_odr_dispatch_financial_event_core(uuid,uuid,bigint,uuid)',
    'private.post_financial_event_core_pre_odr5c(uuid,uuid,bigint,uuid)',
    'private.post_financial_event_core(uuid,uuid,bigint,uuid)',
    'private.f4b_financial_event_supported(public.financial_events)',
    'private.trg_odr5c_guard_automatic_posting_policy()'
  ]) AS signatures(signature) WHERE to_regprocedure(signature) IS NOT NULL
  UNION ALL
  SELECT 'dispatch_finance_source_schema',
    CASE WHEN count(*)=2 THEN 'PASS' ELSE 'FAIL' END,abs(count(*)-2),
    jsonb_build_object('expected',2,'columnRows',count(*))
  FROM information_schema.columns column_state
  WHERE column_state.table_schema='public'
    AND column_state.table_name='sales_dispatch_financial_effects'
    AND ((column_state.column_name='advance_applied_amount'
          AND column_state.is_nullable='NO')
      OR (column_state.column_name='financial_event_id'
          AND column_state.is_nullable='NO'))
  UNION ALL
  SELECT 'atomic_dispatch_finance_definition',
    CASE WHEN definition~'capture_dispatch_financial_effect_core'
      AND definition~'dispatch_sales_delivery_stock_core_odr3c'
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN definition~'capture_dispatch_financial_effect_core'
      AND definition~'dispatch_sales_delivery_stock_core_odr3c' THEN 0 ELSE 1 END,
    jsonb_build_object('routineRows',1)
  FROM (SELECT pg_get_functiondef(
    'private.dispatch_sales_delivery_core(uuid,bigint,uuid,jsonb,text)'::regprocedure
  ) definition) runtime
  UNION ALL
  SELECT 'controlled_dispatcher_contract',
    CASE WHEN definition~'SALE_DISPATCHED'
      AND definition~'post_odr_dispatch_financial_event_core'
      AND definition~'post_financial_event_core_pre_odr5c'
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN definition~'SALE_DISPATCHED'
      AND definition~'post_odr_dispatch_financial_event_core'
      AND definition~'post_financial_event_core_pre_odr5c' THEN 0 ELSE 1 END,
    jsonb_build_object('routineRows',1)
  FROM (SELECT pg_get_functiondef(
    'private.post_financial_event_core(uuid,uuid,bigint,uuid)'::regprocedure
  ) definition) runtime
  UNION ALL
  SELECT 'private_dispatch_finance_runtime_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('authenticatedExecutableRows',count(*))
  FROM information_schema.routine_privileges privilege
  WHERE privilege.grantee IN('anon','authenticated','PUBLIC')
    AND privilege.privilege_type='EXECUTE'
    AND privilege.specific_schema='private'
    AND privilege.routine_name IN('dispatch_sales_delivery_stock_core_odr3c',
      'capture_dispatch_financial_effect_core',
      'dispatch_sales_delivery_core','post_odr_dispatch_financial_event_core',
      'post_financial_event_core_pre_odr5c','post_financial_event_core')
  UNION ALL
  SELECT 'automatic_policy_guard',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,abs(count(*)-1),
    jsonb_build_object('triggerRows',count(*))
  FROM pg_trigger trigger_state JOIN pg_class relation ON relation.oid=trigger_state.tgrelid
  JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
  WHERE namespace.nspname='public' AND relation.relname='finance_company_policies'
    AND trigger_state.tgname='odr5c_guard_automatic_posting_policy'
    AND NOT trigger_state.tgisinternal
  UNION ALL
  SELECT 'dispatch_operation_source_coverage',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('operationCount',count(*))
  FROM (SELECT allocation.company_id,allocation.delivery_document_id,
      allocation.dispatch_idempotency_key
    FROM public.sales_dispatch_allocations allocation
    JOIN public.sales_delivery_documents delivery
      ON delivery.company_id=allocation.company_id
     AND delivery.id=allocation.delivery_document_id
    WHERE delivery.reservation_id IS NOT NULL
    GROUP BY allocation.company_id,allocation.delivery_document_id,
      allocation.dispatch_idempotency_key) operation
  LEFT JOIN public.sales_dispatch_financial_effects effect
    ON effect.company_id=operation.company_id
   AND effect.delivery_document_id=operation.delivery_document_id
   AND effect.dispatch_idempotency_key=operation.dispatch_idempotency_key
  WHERE effect.id IS NULL
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
  SELECT 'dispatch_fifo_cost_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('effectCount',count(*))
  FROM public.sales_dispatch_financial_effects effect
  LEFT JOIN LATERAL (
    SELECT round(COALESCE(sum(allocation.dispatched_base_qty*
        allocation.unit_cost_snapshot) FILTER(
          WHERE allocation.allocation_kind='FIFO'),0),4) fifo_amount,
      count(*) FILTER(WHERE allocation.allocation_kind='NEGATIVE'
        AND negative_allocation.id IS NULL) missing_negative
    FROM public.sales_dispatch_allocations allocation
    JOIN public.sales_stock_reservation_lines reservation_line
      ON reservation_line.company_id=allocation.company_id
     AND reservation_line.id=allocation.reservation_line_id
    LEFT JOIN public.negative_stock_sale_allocations negative_allocation
      ON negative_allocation.company_id=reservation_line.company_id
     AND negative_allocation.stock_requirement_id=reservation_line.stock_requirement_id
    WHERE allocation.company_id=effect.company_id
      AND allocation.delivery_document_id=effect.delivery_document_id
      AND allocation.dispatch_idempotency_key=effect.dispatch_idempotency_key
  ) allocation_total ON TRUE
  WHERE allocation_total.missing_negative<>0 OR CASE
    WHEN jsonb_typeof(effect.source_snapshot#>'{costBreakdown,fifoCost}')='number'
      AND jsonb_typeof(effect.source_snapshot#>
        '{costBreakdown,negativeProvisionalCost}')='number'
    THEN round((effect.source_snapshot#>>'{costBreakdown,fifoCost}')::NUMERIC+
      (effect.source_snapshot#>>'{costBreakdown,negativeProvisionalCost}')::NUMERIC,4)
      IS DISTINCT FROM effect.fifo_cost_total
      OR round((effect.source_snapshot#>>'{costBreakdown,fifoCost}')::NUMERIC,4)
        IS DISTINCT FROM allocation_total.fifo_amount
    ELSE TRUE END
  UNION ALL
  SELECT 'dispatch_event_source_contract',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('rowCount',count(*))
  FROM public.sales_dispatch_financial_effects effect
  LEFT JOIN public.financial_events event ON event.company_id=effect.company_id
    AND event.id=effect.financial_event_id
  WHERE event.id IS NULL OR event.source_table<>'sales_dispatch_financial_effects'
    OR event.source_id<>effect.id OR event.system_event_key<>'SALE_DISPATCHED'
    OR event.event_type::TEXT<>'SALE_POSTED'
    OR event.status::TEXT NOT IN('HOLD','POSTED')
    OR CASE WHEN jsonb_typeof(event.amounts->'commercialAmount')='number'
        AND jsonb_typeof(event.amounts->'taxAmount')='number'
        AND jsonb_typeof(event.amounts->'deliveryFeeAmount')='number'
        AND jsonb_typeof(event.amounts->'paymentSurchargeAmount')='number'
        AND jsonb_typeof(event.amounts->'roundingAdjustment')='number'
        AND jsonb_typeof(event.amounts->'receivableAmount')='number'
        AND jsonb_typeof(event.amounts->'clearingAmount')='number'
        AND jsonb_typeof(event.amounts->'advanceAppliedAmount')='number'
        AND jsonb_typeof(event.amounts->'fifoCostTotal')='number'
      THEN round((event.amounts->>'commercialAmount')::NUMERIC,4)
          IS DISTINCT FROM effect.commercial_amount
        OR round((event.amounts->>'taxAmount')::NUMERIC,4)
          IS DISTINCT FROM effect.tax_amount
        OR round((event.amounts->>'deliveryFeeAmount')::NUMERIC,4)
          IS DISTINCT FROM effect.delivery_fee_amount
        OR round((event.amounts->>'paymentSurchargeAmount')::NUMERIC,4)
          IS DISTINCT FROM effect.payment_surcharge_amount
        OR round((event.amounts->>'roundingAdjustment')::NUMERIC,4)
          IS DISTINCT FROM effect.rounding_adjustment
        OR round((event.amounts->>'receivableAmount')::NUMERIC,4)
          IS DISTINCT FROM effect.receivable_amount
        OR round((event.amounts->>'clearingAmount')::NUMERIC,4)
          IS DISTINCT FROM effect.clearing_amount
        OR round((event.amounts->>'advanceAppliedAmount')::NUMERIC,4)
          IS DISTINCT FROM effect.advance_applied_amount
        OR round((event.amounts->>'fifoCostTotal')::NUMERIC,4)
          IS DISTINCT FROM effect.fifo_cost_total
      ELSE TRUE END
  UNION ALL
  SELECT 'dispatch_event_journal_coverage',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('rowCount',count(*))
  FROM public.financial_events event
  LEFT JOIN public.finance_journals journal ON journal.company_id=event.company_id
    AND journal.financial_event_id=event.id AND journal.status='POSTED'
  WHERE event.system_event_key='SALE_DISPATCHED'
    AND event.source_table='sales_dispatch_financial_effects'
    AND ((event.status::TEXT='POSTED' AND journal.id IS NULL)
      OR (event.status::TEXT='HOLD' AND journal.id IS NOT NULL))
  UNION ALL
  SELECT 'posted_dispatch_journal_balance',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('journalCount',count(*))
  FROM public.finance_journals journal
  WHERE journal.system_event_key='SALE_DISPATCHED' AND journal.status='POSTED'
    AND (journal.total_debit<=0 OR journal.total_debit<>journal.total_credit)
),inventory AS (
  SELECT 'dispatch_finance_runtime_inventory'::TEXT check_name,'INFO'::TEXT status,
    0::BIGINT violation_rows,jsonb_build_object(
      'effects',(SELECT count(*) FROM public.sales_dispatch_financial_effects),
      'holdEvents',(SELECT count(*) FROM public.financial_events
        WHERE system_event_key='SALE_DISPATCHED' AND status::TEXT='HOLD'),
      'postedEvents',(SELECT count(*) FROM public.financial_events
        WHERE system_event_key='SALE_DISPATCHED' AND status::TEXT='POSTED'),
      'postedJournals',(SELECT count(*) FROM public.finance_journals
        WHERE system_event_key='SALE_DISPATCHED' AND status='POSTED'),
      'legacyPostedJournals',(SELECT count(*) FROM public.finance_journals
        WHERE status='POSTED' AND COALESCE(system_event_key,'')<>'SALE_DISPATCHED')
    ) details
)
SELECT * FROM (SELECT * FROM checks UNION ALL SELECT * FROM inventory) result
ORDER BY check_name;
