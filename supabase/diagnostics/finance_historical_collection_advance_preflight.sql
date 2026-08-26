-- F3 Historical collection, backorder-after-payment and explicit advance preflight.
-- SAFETY: SELECT-only; no fixture and no write.
WITH active_companies AS (
  SELECT company.id FROM public.companies company WHERE company.status='ACTIVE'
), balance_policy AS (
  SELECT policy.company_id,policy.lifecycle_state
  FROM public.customer_balance_company_policies policy
  JOIN active_companies company ON company.id=policy.company_id
), advance_account_scope AS (
  SELECT policy.company_id,
    EXISTS(SELECT 1 FROM public.chart_of_accounts account
      WHERE account.company_id=policy.company_id
        AND account.system_function_key='CUSTOMER_BALANCE_LIABILITY'
        AND account.is_active AND account.is_postable)
    OR EXISTS(SELECT 1 FROM public.company_account_function_fallbacks fallback
      JOIN public.chart_of_accounts account ON account.company_id=fallback.company_id
        AND account.id=fallback.account_id AND account.is_active AND account.is_postable
      WHERE fallback.company_id=policy.company_id
        AND fallback.account_function_key='CUSTOMER_BALANCE_LIABILITY'
        AND fallback.status='ACTIVE') account_ready
  FROM balance_policy policy WHERE policy.lifecycle_state='ACTIVE'
), checks AS (
  SELECT 'f3_dependencies' check_name,
    CASE WHEN count(*)=2 THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('expected',2,'ledgerRows',count(*),
      'requiredVersions',jsonb_build_array('20260827100000','20260827110000')) details
  FROM private.kgs_schema_migrations WHERE version IN('20260827100000','20260827110000')
  UNION ALL
  SELECT 'historical_receipt_effective_date_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('rowCount',count(*))
  FROM public.customer_receipt_documents document
  JOIN public.financial_events event ON event.company_id=document.company_id
    AND event.id=document.financial_event_id
  WHERE document.status='POSTED' AND event.event_date::DATE<>document.receipt_date
  UNION ALL
  SELECT 'posted_receipt_allocation_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('documentCount',count(*))
  FROM public.customer_receipt_documents document
  LEFT JOIN LATERAL(SELECT COALESCE(sum(allocation.allocated_amount),0) allocated
    FROM public.customer_receipt_allocations allocation
    WHERE allocation.company_id=document.company_id AND allocation.document_id=document.id) allocation ON TRUE
  WHERE document.status='POSTED' AND round(document.total_amount,4)<>round(allocation.allocated,4)
  UNION ALL
  SELECT 'receipt_customer_balance_schema_state','SETUP',jsonb_build_object(
    'missingColumns',(SELECT COALESCE(jsonb_agg(required.column_name ORDER BY required.column_name),'[]'::jsonb)
      FROM (VALUES('received_amount'),('unapplied_amount'),('unapplied_disposition'),
        ('customer_balance_ledger_entry_id')) required(column_name)
      WHERE NOT EXISTS(SELECT 1 FROM information_schema.columns column_state
        WHERE column_state.table_schema='public' AND column_state.table_name='customer_receipt_documents'
          AND column_state.column_name=required.column_name)),
    'requiredDesign',jsonb_build_array('ALLOCATE_TO_INVOICE','CUSTOMER_BALANCE_EXPLICIT','no automatic revenue'))
  UNION ALL
  SELECT 'customer_balance_receipt_source_contract','SETUP',jsonb_build_object(
    'sourceSupported',COALESCE((SELECT pg_get_constraintdef(constraint_state.oid) ILIKE '%CUSTOMER_RECEIPT%'
      FROM pg_constraint constraint_state WHERE constraint_state.conrelid='public.customer_balance_ledger_entries'::regclass
        AND constraint_state.conname='customer_balance_ledger_source_check'),FALSE),
    'sourceGuardPresent',COALESCE((SELECT pg_get_functiondef(routine.oid) ILIKE '%CUSTOMER_RECEIPT%'
      FROM pg_proc routine JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
      WHERE namespace.nspname='private' AND routine.proname='trg_g4_customer_balance_source_integrity'),FALSE))
  UNION ALL
  SELECT 'active_customer_balance_advance_readiness',
    CASE WHEN count(*) FILTER(WHERE NOT account_ready)=0 THEN 'PASS' ELSE 'BACKFILL' END,
    jsonb_build_object('activePolicies',count(*),
      'companiesWithoutLiabilityAccount',count(*) FILTER(WHERE NOT account_ready))
  FROM advance_account_scope
  UNION ALL
  SELECT 'active_customer_balance_event_category_readiness',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BACKFILL' END,
    jsonb_build_object('companiesAffected',count(*))
  FROM balance_policy policy WHERE policy.lifecycle_state='ACTIVE'
    AND NOT EXISTS(SELECT 1 FROM public.transaction_categories category
      WHERE category.company_id=policy.company_id
        AND category.system_key='CUSTOMER_BALANCE_RECEIPT' AND category.is_active)
  UNION ALL
  SELECT 'browser_direct_historical_collection_write_boundary',
    CASE WHEN bool_or(has_table_privilege('authenticated',format('%I.%I',relation.schema_name,relation.table_name),'INSERT,UPDATE,DELETE'))
      THEN 'BLOCKER' ELSE 'PASS' END,
    jsonb_build_object('writableRelations',COALESCE(jsonb_agg(relation.table_name)
      FILTER(WHERE has_table_privilege('authenticated',format('%I.%I',relation.schema_name,relation.table_name),'INSERT,UPDATE,DELETE')),'[]'::jsonb))
  FROM (VALUES('public','customer_receipt_documents'),('public','customer_receipt_allocations'),
    ('public','customer_balance_ledger_entries')) relation(schema_name,table_name)
  UNION ALL
  SELECT 'historical_backorder_candidate_inventory','INFO',jsonb_build_object(
    'openTempoInvoices',count(*),'receivableTotal',COALESCE(sum(sale.sisa_piutang),0),
    'companies',count(DISTINCT sale.company_id))
  FROM public.sales_headers sale WHERE sale.document_status='POSTED' AND sale.is_tempo AND sale.sisa_piutang>0
  UNION ALL
  SELECT 'customer_balance_policy_inventory','INFO',jsonb_build_object(
    'active',count(*) FILTER(WHERE lifecycle_state='ACTIVE'),
    'windDown',count(*) FILTER(WHERE lifecycle_state='WIND_DOWN'),
    'disabled',count(*) FILTER(WHERE lifecycle_state='DISABLED'),
    'activeCompaniesWithoutPolicy',(SELECT count(*) FROM active_companies company
      WHERE NOT EXISTS(SELECT 1 FROM balance_policy policy WHERE policy.company_id=company.id)))
  FROM balance_policy
  UNION ALL
  SELECT 'customer_receipt_runtime_inventory','INFO',jsonb_build_object(
    'documents',count(*),'drafts',count(*) FILTER(WHERE status='DRAFT'),
    'posted',count(*) FILTER(WHERE status='POSTED'),'canceled',count(*) FILTER(WHERE status='CANCELED'))
  FROM public.customer_receipt_documents
)
SELECT check_name,status,details FROM checks ORDER BY
  CASE status WHEN 'BLOCKER' THEN 1 WHEN 'BACKFILL' THEN 2 WHEN 'SETUP' THEN 3 WHEN 'PASS' THEN 4 ELSE 5 END,check_name;
