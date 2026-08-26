-- F3 Historical collection and explicit Customer advance postflight.
-- SAFETY: SELECT-only.
WITH checks AS (
  SELECT 'migration_ledger' check_name,CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    CASE WHEN count(*)=1 THEN 0 ELSE 1 END::BIGINT violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260827120000'
  UNION ALL
  SELECT 'required_historical_collection_columns',CASE WHEN count(*)=5 THEN 'PASS' ELSE 'FAIL' END,
    (5-count(*))::BIGINT,jsonb_build_object('expected',5,'columnRows',count(*))
  FROM information_schema.columns WHERE table_schema='public' AND table_name='customer_receipt_documents'
    AND column_name IN('received_amount','unapplied_amount','unapplied_disposition',
      'customer_balance_ledger_entry_id','advance_liability_account_id_snapshot')
  UNION ALL
  SELECT 'required_historical_collection_routines',CASE WHEN count(*)=4 THEN 'PASS' ELSE 'FAIL' END,
    (4-count(*))::BIGINT,jsonb_build_object('expected',4,'routineRows',count(*))
  FROM pg_proc routine JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
  WHERE (namespace.nspname='public' AND routine.proname IN(
    'get_customer_receipt_advance_policy','save_customer_receipt_draft_with_disposition',
    'post_customer_receipt_with_disposition'))
    OR (namespace.nspname='private' AND routine.proname='post_customer_advance_financial_event_core')
  UNION ALL
  SELECT 'customer_receipt_advance_source_contract',
    CASE WHEN COALESCE((SELECT pg_get_constraintdef(constraint_state.oid) ILIKE '%CUSTOMER_RECEIPT%'
      FROM pg_constraint constraint_state WHERE constraint_state.conrelid='public.customer_balance_ledger_entries'::regclass
        AND constraint_state.conname='customer_balance_ledger_source_check'),FALSE)
      AND COALESCE((SELECT pg_get_functiondef(routine.oid) ILIKE '%CUSTOMER_RECEIPT%'
        FROM pg_proc routine JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
        WHERE namespace.nspname='private' AND routine.proname='trg_g4_customer_balance_source_integrity'),FALSE)
      THEN 'PASS' ELSE 'FAIL' END,0,jsonb_build_object('source','CUSTOMER_RECEIPT')
  UNION ALL
  SELECT 'disabled_customer_balance_policy_preserved',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*),jsonb_build_object('unexpectedActivePolicies',count(*))
  FROM public.customer_balance_company_policies policy
  WHERE policy.lifecycle_state='ACTIVE'
  UNION ALL
  SELECT 'browser_historical_collection_table_boundary',
    CASE WHEN bool_or(has_table_privilege('authenticated',format('%I.%I',relation.schema_name,relation.table_name),'INSERT,UPDATE,DELETE'))
      THEN 'FAIL' ELSE 'PASS' END,
    count(*) FILTER(WHERE has_table_privilege('authenticated',format('%I.%I',relation.schema_name,relation.table_name),'INSERT,UPDATE,DELETE')),
    jsonb_build_object('writableRelations',COALESCE(jsonb_agg(relation.table_name)
      FILTER(WHERE has_table_privilege('authenticated',format('%I.%I',relation.schema_name,relation.table_name),'INSERT,UPDATE,DELETE')),'[]'::jsonb))
  FROM (VALUES('public','customer_receipt_documents'),('public','customer_receipt_allocations'),
    ('public','customer_balance_ledger_entries')) relation(schema_name,table_name)
  UNION ALL
  SELECT 'historical_receipt_effective_date_integrity',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*),jsonb_build_object('rowCount',count(*))
  FROM public.customer_receipt_documents document JOIN public.financial_events event
    ON event.company_id=document.company_id AND event.id=document.financial_event_id
  WHERE document.status='POSTED' AND event.event_date::DATE<>document.receipt_date
  UNION ALL
  SELECT 'advance_customer_balance_cache_ledger_reconciliation',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*),jsonb_build_object('customerCount',count(*))
  FROM public.customers customer LEFT JOIN LATERAL(
    SELECT COALESCE(sum(CASE ledger.direction WHEN 'CREDIT' THEN ledger.amount ELSE -ledger.amount END),0) balance
    FROM public.customer_balance_ledger_entries ledger
    WHERE ledger.company_id=customer.company_id AND ledger.customer_id=customer.id) ledger ON TRUE
  WHERE round(customer.current_balance,4)<>round(ledger.balance,4)
  UNION ALL
  SELECT 'advance_event_journal_coverage',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*),jsonb_build_object('rowCount',count(*))
  FROM public.customer_receipt_documents document
  LEFT JOIN public.financial_events event ON event.company_id=document.company_id AND event.id=document.financial_event_id
  LEFT JOIN public.finance_journals journal ON journal.company_id=event.company_id AND journal.financial_event_id=event.id
  WHERE document.status='POSTED' AND document.unapplied_disposition='CUSTOMER_BALANCE'
    AND (event.status<>'POSTED' OR journal.status<>'POSTED')
  UNION ALL
  SELECT 'historical_collection_runtime_inventory','INFO',0,jsonb_build_object(
    'documents',count(*),'allocatedReceipts',count(*) FILTER(WHERE unapplied_disposition='NONE'),
    'advanceReceipts',count(*) FILTER(WHERE unapplied_disposition='CUSTOMER_BALANCE'),
    'receivedTotal',COALESCE(sum(received_amount),0),'unappliedTotal',COALESCE(sum(unapplied_amount),0))
  FROM public.customer_receipt_documents
)
SELECT check_name,status,violation_rows,details FROM checks ORDER BY
  CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
