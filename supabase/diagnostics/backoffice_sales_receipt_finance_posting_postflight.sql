-- Read-only postflight for 20260909155000.
WITH checks AS (
  SELECT 'migration_ledger' check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,count(*)<>1 violation,
    jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260909155000'
  UNION ALL
  SELECT 'required_receipt_finance_routines',CASE WHEN count(*)=5 THEN 'PASS' ELSE 'FAIL' END,
    count(*)<>5,jsonb_build_object('routineRows',count(*),'expected',5)
  FROM pg_proc proc JOIN pg_namespace ns ON ns.oid=proc.pronamespace
  WHERE ns.nspname='private' AND proc.proname IN(
    'post_backoffice_receipt_financial_event_core','post_financial_event_core',
    'post_financial_event_core_pre_backoffice_receipt','f4b_financial_event_supported',
    'f4b_financial_event_supported_pre_backoffice_receipt')
  UNION ALL
  SELECT 'private_receipt_finance_boundary',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)<>0,jsonb_build_object('browserExecutableRows',count(*))
  FROM pg_proc proc JOIN pg_namespace ns ON ns.oid=proc.pronamespace
  WHERE ns.nspname='private' AND proc.proname IN(
    'post_backoffice_receipt_financial_event_core','post_financial_event_core',
    'post_financial_event_core_pre_backoffice_receipt','f4b_financial_event_supported',
    'f4b_financial_event_supported_pre_backoffice_receipt')
    AND (has_function_privilege('anon',proc.oid,'EXECUTE')
      OR has_function_privilege('authenticated',proc.oid,'EXECUTE'))
  UNION ALL
  SELECT 'receipt_queue_support',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)<>0,jsonb_build_object('unsupportedHoldEvents',count(*))
  FROM public.financial_events event
  WHERE event.system_event_key='BACKOFFICE_CUSTOMER_RECEIPT' AND event.status='HOLD'
    AND NOT private.f4b_financial_event_supported(event)
  UNION ALL
  SELECT 'posted_receipt_journal_coverage',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)<>0,jsonb_build_object('invalidRows',count(*))
  FROM public.financial_events event
  LEFT JOIN public.finance_journals journal ON journal.company_id=event.company_id
    AND journal.financial_event_id=event.id AND journal.status='POSTED'
  WHERE event.system_event_key='BACKOFFICE_CUSTOMER_RECEIPT' AND event.status='POSTED'
    AND journal.id IS NULL
  UNION ALL
  SELECT 'posted_receipt_journal_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)<>0,
    jsonb_build_object('invalidRows',count(*))
  FROM (SELECT receipt.id,receipt.total_fifo_cost,journal.original_event_date,
      journal.source_type,journal.source_id,journal.warehouse_id,
      journal.total_debit,journal.total_credit,
      count(line.id) line_count,
      count(*) FILTER(WHERE line.description='COGS' AND line.debit=receipt.total_fifo_cost) cogs_rows,
      count(*) FILTER(WHERE line.description='INVENTORY_ASSET'
        AND line.credit=receipt.total_fifo_cost) inventory_rows
    FROM public.backoffice_sales_delivery_receipts receipt
    JOIN public.financial_events event ON event.company_id=receipt.company_id
      AND event.id=receipt.financial_event_id AND event.status='POSTED'
    JOIN public.finance_journals journal ON journal.company_id=event.company_id
      AND journal.financial_event_id=event.id AND journal.status='POSTED'
    LEFT JOIN public.finance_journal_lines line ON line.company_id=journal.company_id
      AND line.journal_id=journal.id
    GROUP BY receipt.id,receipt.total_fifo_cost,receipt.accepted_date,
      receipt.transit_warehouse_id,journal.original_event_date,journal.source_type,
      journal.source_id,journal.warehouse_id,journal.total_debit,journal.total_credit
    HAVING journal.source_type<>'backoffice_sales_delivery_receipts'
      OR journal.source_id<>receipt.id OR journal.original_event_date<>receipt.accepted_date
      OR journal.warehouse_id<>receipt.transit_warehouse_id
      OR round(journal.total_debit,4)<>round(receipt.total_fifo_cost,4)
      OR round(journal.total_credit,4)<>round(receipt.total_fifo_cost,4)
      OR count(line.id)<>2 OR count(*) FILTER(WHERE line.description='COGS'
        AND line.debit=receipt.total_fifo_cost)<>1
      OR count(*) FILTER(WHERE line.description='INVENTORY_ASSET'
        AND line.credit=receipt.total_fifo_cost)<>1) invalid
  UNION ALL
  SELECT 'zero_cost_event_contract',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)<>0,jsonb_build_object('invalidRows',count(*))
  FROM public.backoffice_sales_delivery_receipts receipt
  JOIN public.financial_events event ON event.company_id=receipt.company_id
    AND event.id=receipt.financial_event_id
  WHERE receipt.total_fifo_cost=0 AND NOT(event.status='HOLD'
    OR (event.status='CANCELED' AND event.error_message='NO_FINANCIAL_EFFECT'))
  UNION ALL
  SELECT 'receipt_finance_runtime_inventory','INFO',false,jsonb_build_object(
    'holdEvents',(SELECT count(*) FROM public.financial_events
      WHERE system_event_key='BACKOFFICE_CUSTOMER_RECEIPT' AND status='HOLD'),
    'postedEvents',(SELECT count(*) FROM public.financial_events
      WHERE system_event_key='BACKOFFICE_CUSTOMER_RECEIPT' AND status='POSTED'),
    'zeroEffectEvents',(SELECT count(*) FROM public.financial_events
      WHERE system_event_key='BACKOFFICE_CUSTOMER_RECEIPT' AND status='CANCELED'
        AND error_message='NO_FINANCIAL_EFFECT'))
)
SELECT check_name,status,CASE WHEN violation THEN 1 ELSE 0 END violation_rows,details
FROM checks ORDER BY check_name;
