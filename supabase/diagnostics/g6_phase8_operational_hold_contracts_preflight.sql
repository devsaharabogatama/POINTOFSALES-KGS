-- G6 phase 8 preflight: operational Financial Event HOLD contracts.
-- SAFETY: SELECT-only. This file never posts an Event or creates a Journal.
-- Run the complete statement and return every row before applying a posting
-- engine migration. BLOCKER must be zero; BACKFILL requires review.

WITH
supported_contracts(
    system_key,event_type,source_table,required_numeric_keys
) AS (
    VALUES
      ('SALE_POSTED','SALE_POSTED','sales_headers',
       ARRAY['grandTotal','netSalesInclusiveTax','fifoCostTotal','taxAmount']),
      ('SALES_RETURN','SALES_REFUND','sales_return_documents',
       ARRAY['refundTotal','fifoCostRestored','taxRefund']),
      ('GOODS_RECEIPT','PURCHASE_POSTED','goods_receipt_documents',
       ARRAY['inventoryDebit','supplierApProvisionalCredit']),
      ('SUPPLIER_INVOICE','SUPPLIER_INVOICE_VALIDATED',
       'supplier_invoice_documents',
       ARRAY['apFinalCredit','apProvisionalDebit','recoverableInputTaxDebit',
             'purchasePriceVariance']),
      ('SUPPLIER_PAYMENT','SUPPLIER_PAYMENT_VALIDATED',
       'supplier_payment_documents',ARRAY['totalAmount']),
      ('EXPENSE_DISBURSEMENT','EXPENSE_DISBURSEMENT',
       'expense_disbursements',ARRAY['disbursedAmount']),
      ('CASH_DEPOSIT','BANK_DEPOSIT','cash_deposit_documents',
       ARRAY['actualDeposit','expectedDeposit','depositVariance']),
      ('CASH_VARIANCE','DEPOSIT_VARIANCE_RESOLUTION',
       'deposit_variance_resolution_requests',ARRAY['allocationAmount']),
      ('STOCK_GAIN','STOCK_GAIN','stock_adjustment_documents',
       ARRAY['inventoryDebit','stockGainCredit'])
),
hold_events AS MATERIALIZED (
    SELECT event.*
    FROM public.financial_events event
    WHERE event.status::TEXT='HOLD'
),
contract_events AS MATERIALIZED (
    SELECT event.*,contract.required_numeric_keys
    FROM hold_events event
    JOIN supported_contracts contract
      ON contract.system_key=event.system_event_key
     AND contract.event_type=event.event_type::TEXT
     AND contract.source_table=event.source_table
),
unexpected_hold AS MATERIALIZED (
    SELECT event.*
    FROM hold_events event
    LEFT JOIN supported_contracts contract
      ON contract.system_key=event.system_event_key
     AND contract.event_type=event.event_type::TEXT
     AND contract.source_table=event.source_table
    WHERE contract.system_key IS NULL
      AND event.system_event_key<>'STOCK_OPENING'
),
numeric_key_violations AS MATERIALIZED (
    SELECT event.company_id,event.id,event.system_event_key,key_state.key
    FROM contract_events event
    CROSS JOIN LATERAL unnest(event.required_numeric_keys) key_state(key)
    WHERE jsonb_typeof(event.amounts->key_state.key)<>'number'
),
source_state AS MATERIALIZED (
    SELECT event.company_id,event.id,
      CASE event.source_table
        WHEN 'sales_headers' THEN EXISTS(
          SELECT 1 FROM public.sales_headers source
          WHERE source.company_id=event.company_id AND source.id=event.source_id
            AND source.document_status='POSTED')
        WHEN 'sales_return_documents' THEN EXISTS(
          SELECT 1 FROM public.sales_return_documents source
          WHERE source.company_id=event.company_id AND source.id=event.source_id
            AND source.status='POSTED')
        WHEN 'goods_receipt_documents' THEN EXISTS(
          SELECT 1 FROM public.goods_receipt_documents source
          WHERE source.company_id=event.company_id AND source.id=event.source_id
            AND source.status='POSTED')
        WHEN 'supplier_invoice_documents' THEN EXISTS(
          SELECT 1 FROM public.supplier_invoice_documents source
          WHERE source.company_id=event.company_id AND source.id=event.source_id
            AND source.status='VALIDATED')
        WHEN 'supplier_payment_documents' THEN EXISTS(
          SELECT 1 FROM public.supplier_payment_documents source
          WHERE source.company_id=event.company_id AND source.id=event.source_id
            AND source.status='VALIDATED')
        WHEN 'expense_disbursements' THEN EXISTS(
          SELECT 1 FROM public.expense_disbursements source
          WHERE source.company_id=event.company_id AND source.id=event.source_id)
        WHEN 'cash_deposit_documents' THEN EXISTS(
          SELECT 1 FROM public.cash_deposit_documents source
          WHERE source.company_id=event.company_id AND source.id=event.source_id
            AND source.status='APPROVED')
        WHEN 'deposit_variance_resolution_requests' THEN EXISTS(
          SELECT 1 FROM public.deposit_variance_resolution_requests source
          WHERE source.company_id=event.company_id AND source.id=event.source_id
            AND source.status='APPROVED')
        WHEN 'stock_adjustment_documents' THEN EXISTS(
          SELECT 1 FROM public.stock_adjustment_documents source
          WHERE source.company_id=event.company_id AND source.id=event.source_id
            AND source.status='POSTED')
        ELSE FALSE
      END AS source_is_final
    FROM contract_events event
),
required_functions AS MATERIALIZED (
    SELECT event.company_id,event.id,event.system_event_key,
           function_key.function_key
    FROM contract_events event
    JOIN public.system_events registry
      ON registry.system_key=event.system_event_key AND registry.is_active
    CROSS JOIN LATERAL unnest(registry.required_account_functions)
      function_key(function_key)
),
function_resolution AS MATERIALIZED (
    SELECT required.company_id,required.id,required.system_event_key,
           required.function_key,
           (SELECT count(*) FROM public.transaction_account_rules rule
            WHERE rule.company_id=required.company_id
              AND rule.transaction_category_id=event.transaction_category_id
              AND rule.system_key=required.system_event_key
              AND rule.account_function_key=required.function_key
              AND rule.status='ACTIVE'
              AND rule.effective_from<=event.event_date
              AND (rule.effective_to IS NULL
                   OR rule.effective_to>event.event_date)) AS exact_count,
           (SELECT count(*)
            FROM public.company_account_function_fallbacks fallback
            WHERE fallback.company_id=required.company_id
              AND fallback.account_function_key=required.function_key
              AND fallback.status='ACTIVE'
              AND fallback.effective_from<=event.event_date
              AND (fallback.effective_to IS NULL
                   OR fallback.effective_to>event.event_date)) AS fallback_count
    FROM required_functions required
    JOIN contract_events event
      ON event.company_id=required.company_id AND event.id=required.id
),
payment_shape AS MATERIALIZED (
    SELECT event.company_id,event.id,
           count(payment.id) AS payment_legs,
           count(DISTINCT payment.payment_method_type_snapshot) AS method_types,
           count(*) FILTER (WHERE payment.settlement_route_snapshot IS NULL)
             AS missing_settlement_route,
           COALESCE(sum(payment.amount),0) AS payment_amount,
           COALESCE(sum(payment.customer_surcharge_amount),0) AS surcharge_amount
    FROM contract_events event
    JOIN public.sales_headers sale
      ON event.source_table='sales_headers'
     AND sale.company_id=event.company_id AND sale.id=event.source_id
    LEFT JOIN public.sales_payments payment
      ON payment.company_id=sale.company_id AND payment.sales_id=sale.id
    GROUP BY event.company_id,event.id
),
checks(check_name,status,details) AS (
    SELECT 'g6_phase8_dependencies',
      CASE WHEN count(*)=5 THEN 'PASS' ELSE 'BLOCKER' END,
      jsonb_build_object('expected',5,'ledgerRows',count(*))
    FROM private.kgs_schema_migrations
    WHERE version=ANY(ARRAY[
      '20260810180000','20260810190000','20260810200000',
      '20260810210000','20260813150000'])

    UNION ALL
    SELECT 'active_finance_posting_queue',
      CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
      jsonb_build_object('runCount',count(*))
    FROM public.finance_posting_queue_runs
    WHERE status IN ('PREVIEWED','APPROVED','PROCESSING')

    UNION ALL
    SELECT 'operational_hold_contract_inventory',
      CASE WHEN count(DISTINCT system_event_key)=9 THEN 'PASS' ELSE 'REVIEW' END,
      jsonb_build_object('eventCount',COALESCE(sum(event_count),0),
        'contractCount',count(DISTINCT system_event_key),
        'byContract',COALESCE(jsonb_object_agg(system_event_key,event_count),'{}'))
    FROM (SELECT system_event_key,count(*) event_count
          FROM contract_events GROUP BY system_event_key) inventory

    UNION ALL
    SELECT 'unexpected_hold_event_contract',
      CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
      jsonb_build_object('eventCount',count(*),'contracts',COALESCE(
        jsonb_agg(DISTINCT jsonb_build_object('systemEventKey',system_event_key,
          'eventType',event_type::TEXT,'sourceTable',source_table)),'[]'))
    FROM unexpected_hold

    UNION ALL
    SELECT 'operational_hold_source_finality',
      CASE WHEN count(*) FILTER(WHERE NOT source_is_final)=0
           THEN 'PASS' ELSE 'BLOCKER' END,
      jsonb_build_object('invalidSourceRows',count(*) FILTER(WHERE NOT source_is_final))
    FROM source_state

    UNION ALL
    SELECT 'operational_hold_amount_snapshot_contract',
      CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
      jsonb_build_object('violationRows',count(*),'events',count(DISTINCT id),
        'keys',COALESCE(jsonb_agg(DISTINCT key),'[]'))
    FROM numeric_key_violations

    UNION ALL
    SELECT 'operational_hold_identity_contract',
      CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
      jsonb_build_object('rowCount',count(*))
    FROM contract_events event
    LEFT JOIN public.transaction_categories category
      ON category.company_id=event.company_id
     AND category.id=event.transaction_category_id
     AND category.system_key=event.system_event_key
    WHERE event.transaction_category_id IS NULL OR category.id IS NULL
       OR event.event_version<1 OR event.idempotency_key IS NULL

    UNION ALL
    SELECT 'required_account_function_resolution',
      CASE WHEN count(*) FILTER(WHERE NOT (
             exact_count=1 OR (exact_count=0 AND fallback_count=1)))=0
           THEN 'PASS' ELSE 'BACKFILL' END,
      jsonb_build_object('unresolvedRows',count(*) FILTER(
        WHERE exact_count+fallback_count=0),
        'ambiguousRows',count(*) FILTER(WHERE exact_count>1
          OR (exact_count=0 AND fallback_count>1)),
        'functions',COALESCE(jsonb_agg(DISTINCT function_key) FILTER(
          WHERE NOT (exact_count=1 OR
            (exact_count=0 AND fallback_count=1))),'[]'))
    FROM function_resolution

    UNION ALL
    SELECT 'sale_payment_posting_shape',
      CASE WHEN count(*) FILTER(WHERE missing_settlement_route>0)=0
           THEN 'PASS' ELSE 'BLOCKER' END,
      jsonb_build_object('sales',count(*),'splitSales',count(*) FILTER(
        WHERE payment_legs>1),'tempoSales',count(*) FILTER(WHERE payment_legs=0),
        'missingSettlementRoute',COALESCE(sum(missing_settlement_route),0),
        'paymentAmount',COALESCE(sum(payment_amount),0),
        'surchargeAmount',COALESCE(sum(surcharge_amount),0))
    FROM payment_shape

    UNION ALL
    SELECT 'operational_hold_period_readiness',
      CASE WHEN count(*) FILTER(WHERE period.id IS NULL)=0
           THEN 'PASS' ELSE 'BACKFILL' END,
      jsonb_build_object('eventsWithoutCurrentOrLaterOpenPeriod',count(*) FILTER(
        WHERE period.id IS NULL),'companies',count(DISTINCT event.company_id)
        FILTER(WHERE period.id IS NULL))
    FROM contract_events event
    LEFT JOIN LATERAL (
      SELECT candidate.id FROM public.accounting_periods candidate
      WHERE candidate.company_id=event.company_id
        AND candidate.status IN ('OPEN','REOPENED')
        AND candidate.end_date>=event.event_date::DATE
      ORDER BY CASE WHEN event.event_date::DATE BETWEEN candidate.start_date
                    AND candidate.end_date THEN 0 ELSE 1 END,
               candidate.start_date LIMIT 1
    ) period ON TRUE

    UNION ALL
    SELECT 'operational_hold_existing_journal_effect',
      CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
      jsonb_build_object('journalCount',count(*))
    FROM public.finance_journals journal
    JOIN contract_events event
      ON event.company_id=journal.company_id
     AND event.id=journal.financial_event_id

    UNION ALL
    SELECT 'canonical_operational_posting_runtime','SETUP',
      jsonb_build_object('currentSupportedContract','STOCK_OPENING',
        'targetContracts',9,
        'requiredDesign',jsonb_build_array(
          'source-verified immutable journal plan',
          'dynamic payment/refund legs',
          'exact idempotent event-to-journal identity',
          'open or prior-period posting',
          'no partial journal on resolver failure'))

    UNION ALL
    SELECT 'stock_fifo_gl_reconciliation_baseline','DEFERRED',
      jsonb_build_object('reason',
        'Operational HOLD events must post before final FIFO versus GL assertion')
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'BACKFILL' THEN 2
  WHEN 'REVIEW' THEN 3 WHEN 'SETUP' THEN 4 WHEN 'PASS' THEN 5 ELSE 6 END,
  check_name;
