-- F2 Customer Receipt / AR foundation postflight. SELECT-only.
WITH routines AS (
  SELECT procedure.proname,pg_get_functiondef(procedure.oid) definition
  FROM pg_proc procedure JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname='public' AND procedure.proname IN(
    'get_finance_customer_receipts','save_customer_receipt_draft',
    'post_customer_receipt','cancel_customer_receipt_draft')
), checks AS (
  SELECT 'migration_ledger' check_name,CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(1-count(*)) violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260827100000'
  UNION ALL
  SELECT 'required_customer_receipt_schema',CASE WHEN count(*)=3 THEN 'PASS' ELSE 'FAIL' END,
    abs(3-count(*)),jsonb_build_object('expected',3,'relationRows',count(*))
  FROM pg_class relation JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
  WHERE namespace.nspname='public' AND relation.relname IN(
    'customer_receipt_documents','customer_receipt_allocations','customer_receipt_audit')
  UNION ALL
  SELECT 'required_customer_receipt_routines',CASE WHEN count(*)=4 THEN 'PASS' ELSE 'FAIL' END,
    abs(4-count(*)),jsonb_build_object('expected',4,'routineRows',count(*)) FROM routines
  UNION ALL
  SELECT 'customer_receipt_permission_enforced',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,CASE WHEN count(*)=1 THEN 0 ELSE 1 END,
    jsonb_build_object('rows',count(*),'statuses',COALESCE(jsonb_agg(enforcement_status),'[]'::JSONB))
  FROM public.access_permission_catalog WHERE permission_key='finance.customer_receipts'
    AND enforcement_status='ENFORCED'
  UNION ALL
  SELECT 'browser_customer_receipt_table_boundary',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*),jsonb_build_object('writableRelations',COALESCE(jsonb_agg(table_name),'[]'::JSONB))
  FROM information_schema.role_table_grants WHERE grantee='authenticated'
    AND table_schema='public' AND table_name IN('customer_receipt_documents',
      'customer_receipt_allocations','customer_receipt_audit')
    AND privilege_type IN('INSERT','UPDATE','DELETE')
  UNION ALL
  SELECT 'customer_receipt_event_hold_contract',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,CASE WHEN count(*)=1 THEN 0 ELSE 1 END,
    jsonb_build_object('routineRows',count(*)) FROM routines
  WHERE proname='post_customer_receipt' AND definition LIKE '%SALE_PAYMENT%'
    AND definition LIKE '%''HOLD''%'
  UNION ALL
  SELECT 'posted_allocation_reconciliation',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*),jsonb_build_object('documentCount',count(*))
  FROM public.customer_receipt_documents document
  LEFT JOIN LATERAL(SELECT sum(allocation.allocated_amount) total
    FROM public.customer_receipt_allocations allocation WHERE allocation.company_id=document.company_id
      AND allocation.document_id=document.id) allocated ON TRUE
  WHERE document.status='POSTED' AND abs(document.total_amount-COALESCE(allocated.total,0))>0.0001
  UNION ALL
  SELECT 'posted_receipt_event_coverage',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*),jsonb_build_object('documentCount',count(*))
  FROM public.customer_receipt_documents document LEFT JOIN public.financial_events event
    ON event.company_id=document.company_id AND event.id=document.financial_event_id
  WHERE document.status='POSTED' AND (event.id IS NULL OR event.system_event_key<>'SALE_PAYMENT'
    OR event.source_table<>'customer_receipt_documents' OR event.source_id<>document.id)
  UNION ALL
  SELECT 'customer_receipt_runtime_inventory','INFO',0,jsonb_build_object(
    'documents',count(*),'drafts',count(*) FILTER(WHERE status='DRAFT'),
    'posted',count(*) FILTER(WHERE status='POSTED'),
    'canceled',count(*) FILTER(WHERE status='CANCELED'),
    'postedTotal',COALESCE(sum(total_amount) FILTER(WHERE status='POSTED'),0))
  FROM public.customer_receipt_documents
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;
