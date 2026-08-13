-- G6 phase 8A: Sale and Sales Return posting preflight.
-- SAFETY: one SELECT statement; no business state is changed.

WITH sale_events AS MATERIALIZED (
  SELECT event.*,sale.grand_total_after_rounding,sale.rounding_adjustment,
         sale.delivery_fee_amount,sale.customer_id,sale.sales_warehouse_id
  FROM public.financial_events event
  JOIN public.sales_headers sale ON sale.company_id=event.company_id
   AND sale.id=event.source_id AND sale.document_status='POSTED'
  WHERE event.status='HOLD'::public.event_status
    AND event.system_event_key='SALE_POSTED'
    AND event.event_type='SALE_POSTED'::public.event_type
    AND event.source_table='sales_headers'
),
sale_totals AS MATERIALIZED (
  SELECT event.company_id,event.id,event.source_id,
    event.grand_total_after_rounding,event.rounding_adjustment,
    event.delivery_fee_amount,
    COALESCE(sum(detail.tax_amount),0) tax_amount,
    COALESCE(sum(detail.fifo_cost_total),0) fifo_cost,
    COALESCE((SELECT sum(payment.amount)
      FROM public.sales_payments payment
      WHERE payment.company_id=event.company_id
        AND payment.sales_id=event.source_id),0) payment_total,
    COALESCE((SELECT sum(payment.customer_surcharge_amount)
      FROM public.sales_payments payment
      WHERE payment.company_id=event.company_id
        AND payment.sales_id=event.source_id),0) surcharge_total
  FROM sale_events event
  JOIN public.sales_details detail ON detail.company_id=event.company_id
   AND detail.sales_id=event.source_id
  GROUP BY event.company_id,event.id,event.source_id,
    event.grand_total_after_rounding,event.rounding_adjustment,
    event.delivery_fee_amount
),
sale_leg_functions AS MATERIALIZED (
  SELECT payment.company_id,event.id,
    CASE payment.settlement_route_snapshot
      WHEN 'CASH_DRAWER' THEN 'CASH_DRAWER'
      WHEN 'DIRECT_BANK' THEN method.bank_account_function
      WHEN 'CLEARING' THEN method.clearing_account_function
      WHEN 'RECEIVABLE' THEN 'CUSTOMER_RECEIVABLE'
      WHEN 'INTERNAL_LIABILITY' THEN 'CUSTOMER_BALANCE_LIABILITY'
    END function_key,
    payment.id payment_id
  FROM sale_events event
  JOIN public.sales_payments payment ON payment.company_id=event.company_id
   AND payment.sales_id=event.source_id
  JOIN public.payment_methods method ON method.company_id=payment.company_id
   AND method.id=payment.payment_method_id
),
return_events AS MATERIALIZED (
  SELECT event.*,document.refund_before_rounding,
    document.rounding_adjustment,document.refund_total,
    document.delivery_fee_refund_amount,document.customer_id
  FROM public.financial_events event
  JOIN public.sales_return_documents document
    ON document.company_id=event.company_id AND document.id=event.source_id
   AND document.status='POSTED' AND document.financial_event_id=event.id
  WHERE event.status='HOLD'::public.event_status
    AND event.system_event_key='SALES_RETURN'
    AND event.event_type='SALES_REFUND'::public.event_type
    AND event.source_table='sales_return_documents'
),
return_totals AS MATERIALIZED (
  SELECT event.company_id,event.id,event.source_id,event.refund_before_rounding,
    event.rounding_adjustment,event.refund_total,
    event.delivery_fee_refund_amount,
    COALESCE(sum(line.tax_refund_amount),0) tax_refund,
    COALESCE(sum(line.fifo_cost_restored),0) fifo_restored,
    COALESCE((SELECT sum(refund.amount)
      FROM public.sales_return_refunds refund
      WHERE refund.company_id=event.company_id
        AND refund.document_id=event.source_id),0) refund_payment_total
  FROM return_events event
  JOIN public.sales_return_lines line ON line.company_id=event.company_id
   AND line.document_id=event.source_id
  GROUP BY event.company_id,event.id,event.source_id,
    event.refund_before_rounding,event.rounding_adjustment,event.refund_total,
    event.delivery_fee_refund_amount
),
return_leg_functions AS MATERIALIZED (
  SELECT refund.company_id,event.id,
    CASE refund.settlement_route_snapshot
      WHEN 'CASH_DRAWER' THEN 'CASH_DRAWER'
      WHEN 'DIRECT_BANK' THEN method.bank_account_function
      WHEN 'CLEARING' THEN method.clearing_account_function
      WHEN 'RECEIVABLE' THEN 'CUSTOMER_RECEIVABLE'
      WHEN 'INTERNAL_LIABILITY' THEN 'CUSTOMER_BALANCE_LIABILITY'
    END function_key,refund.id refund_id
  FROM return_events event
  JOIN public.sales_return_refunds refund ON refund.company_id=event.company_id
   AND refund.document_id=event.source_id
  JOIN public.payment_methods method ON method.company_id=refund.company_id
   AND method.id=refund.payment_method_id
),
conditional_functions AS MATERIALIZED (
  SELECT company_id,id,function_key FROM sale_leg_functions
  UNION ALL SELECT company_id,id,function_key FROM return_leg_functions
  UNION ALL SELECT company_id,id,'OUTPUT_TAX' FROM sale_totals WHERE tax_amount>0
  UNION ALL SELECT company_id,id,'OUTPUT_TAX' FROM return_totals WHERE tax_refund>0
  UNION ALL SELECT company_id,id,'DELIVERY_FEE_REVENUE' FROM sale_totals
    WHERE delivery_fee_amount>0
  UNION ALL SELECT company_id,id,'DELIVERY_FEE_REVENUE' FROM return_totals
    WHERE delivery_fee_refund_amount>0
  UNION ALL SELECT company_id,id,'ROUNDING_GAIN' FROM sale_totals
    WHERE rounding_adjustment>0
  UNION ALL SELECT company_id,id,'ROUNDING_LOSS' FROM sale_totals
    WHERE rounding_adjustment<0
  UNION ALL SELECT company_id,id,'ROUNDING_LOSS' FROM return_totals
    WHERE rounding_adjustment>0
  UNION ALL SELECT company_id,id,'ROUNDING_GAIN' FROM return_totals
    WHERE rounding_adjustment<0
  UNION ALL SELECT company_id,id,'PAYMENT_SURCHARGE_INCOME' FROM sale_totals
    WHERE surcharge_total>0
),
conditional_resolution AS MATERIALIZED (
  SELECT scope.*,
    (SELECT count(*) FROM public.transaction_account_rules rule
      JOIN public.financial_events event ON event.company_id=scope.company_id
       AND event.id=scope.id
      WHERE rule.company_id=scope.company_id
       AND rule.transaction_category_id=event.transaction_category_id
       AND rule.system_key=event.system_event_key
       AND rule.account_function_key=scope.function_key
       AND rule.status='ACTIVE' AND rule.effective_from<=event.event_date
       AND (rule.effective_to IS NULL OR rule.effective_to>event.event_date)) exact_count,
    (SELECT count(*) FROM public.company_account_function_fallbacks fallback
      JOIN public.financial_events event ON event.company_id=scope.company_id
       AND event.id=scope.id
      WHERE fallback.company_id=scope.company_id
       AND fallback.account_function_key=scope.function_key
       AND fallback.status='ACTIVE' AND fallback.effective_from<=event.event_date
       AND (fallback.effective_to IS NULL
            OR fallback.effective_to>event.event_date)) fallback_count
  FROM conditional_functions scope
),
checks(check_name,status,details) AS (
  SELECT 'sale_event_source_amount_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('saleCount',(SELECT count(*) FROM sale_totals),
      'violationRows',count(*))
  FROM sale_totals total JOIN sale_events event USING(company_id,id)
  WHERE round((event.amounts->>'grandTotal')::NUMERIC,4)<>
          round(total.grand_total_after_rounding,4)
     OR round((event.amounts->>'taxAmount')::NUMERIC,4)<>round(total.tax_amount,4)
     OR round((event.amounts->>'fifoCostTotal')::NUMERIC,4)<>
          round(total.fifo_cost,4)
     OR round((event.amounts->>'paymentTotal')::NUMERIC,4)<>
          round(total.payment_total,4)
     OR round((event.amounts->>'customerSurcharge')::NUMERIC,4)<>
          round(total.surcharge_total,4)
     OR round((event.amounts->>'deliveryFee')::NUMERIC,4)<>
          round(total.delivery_fee_amount,4)
     OR round(total.grand_total_after_rounding,4)<>
          round((event.amounts->>'netSalesInclusiveTax')::NUMERIC
            +total.delivery_fee_amount+total.rounding_adjustment,4)

  UNION ALL
  SELECT 'sale_revenue_component_shape',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('violationRows',count(*))
  FROM sale_totals total JOIN sale_events event USING(company_id,id)
  WHERE (event.amounts->>'netSalesInclusiveTax')::NUMERIC<total.tax_amount
     OR total.fifo_cost<0 OR total.payment_total<0
     OR round(total.payment_total,4)<>
        round(total.grand_total_after_rounding+total.surcharge_total,4)

  UNION ALL
  SELECT 'sales_return_event_source_amount_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('returnCount',(SELECT count(*) FROM return_totals),
      'violationRows',count(*))
  FROM return_totals total JOIN return_events event USING(company_id,id)
  WHERE round((event.amounts->>'refundTotal')::NUMERIC,4)<>
          round(total.refund_total,4)
     OR round((event.amounts->>'taxRefund')::NUMERIC,4)<>
          round(total.tax_refund,4)
     OR round((event.amounts->>'fifoCostRestored')::NUMERIC,4)<>
          round(total.fifo_restored,4)
     OR round((event.amounts->>'deliveryFeeRefund')::NUMERIC,4)<>
          round(total.delivery_fee_refund_amount,4)
     OR round(total.refund_payment_total,4)<>round(total.refund_total,4)
     OR round(total.refund_total,4)<>round(total.refund_before_rounding+
          total.delivery_fee_refund_amount+total.rounding_adjustment,4)

  UNION ALL
  SELECT 'sales_return_component_shape',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('violationRows',count(*))
  FROM return_totals
  WHERE refund_before_rounding<tax_refund OR fifo_restored<0

  UNION ALL
  SELECT 'payment_refund_settlement_function_snapshot_scope',
    CASE WHEN count(*) FILTER(WHERE function_key IS NULL)=0
         THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('salePaymentLegs',(SELECT count(*) FROM sale_leg_functions),
      'returnRefundLegs',(SELECT count(*) FROM return_leg_functions),
      'missingFunctionRows',count(*) FILTER(WHERE function_key IS NULL))
  FROM (SELECT function_key FROM sale_leg_functions
        UNION ALL SELECT function_key FROM return_leg_functions) leg

  UNION ALL
  SELECT 'conditional_account_function_resolution',
    CASE WHEN count(*) FILTER(WHERE NOT(exact_count=1 OR
      (exact_count=0 AND fallback_count=1)))=0 THEN 'PASS' ELSE 'BACKFILL' END,
    jsonb_build_object('unresolvedRows',count(*) FILTER(WHERE
      exact_count=0 AND fallback_count=0),'ambiguousRows',count(*) FILTER(WHERE
      exact_count>1 OR (exact_count=0 AND fallback_count>1)),
      'functions',COALESCE(jsonb_agg(DISTINCT function_key) FILTER(WHERE
       NOT(exact_count=1 OR (exact_count=0 AND fallback_count=1))),'[]'))
  FROM conditional_resolution

  UNION ALL
  SELECT 'sale_return_existing_journal_effect',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('journalCount',count(*))
  FROM public.finance_journals journal
  JOIN public.financial_events event ON event.company_id=journal.company_id
   AND event.id=journal.financial_event_id
  WHERE event.system_event_key IN('SALE_POSTED','SALES_RETURN')

  UNION ALL
  SELECT 'sale_return_posting_runtime','SETUP',jsonb_build_object(
    'targetContracts',ARRAY['SALE_POSTED','SALES_RETURN'],
    'historicalSaleEvents',(SELECT count(*) FROM sale_events),
    'historicalReturnEvents',(SELECT count(*) FROM return_events),
    'requiredMigrationCapabilities',jsonb_build_array(
      'immutable settlement account-function snapshots',
      'dynamic payment and refund journal legs','tax delivery rounding surcharge',
      'COGS and FIFO reversal','exact idempotent replay'))
)
SELECT check_name,status,details FROM checks ORDER BY CASE status
  WHEN 'BLOCKER' THEN 1 WHEN 'BACKFILL' THEN 2 WHEN 'SETUP' THEN 3 ELSE 4 END,
  check_name;
