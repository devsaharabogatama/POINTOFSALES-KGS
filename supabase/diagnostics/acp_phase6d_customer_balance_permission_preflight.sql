-- ACP-6D preflight: Customer Balance permission enforcement readiness.
-- SAFETY: SELECT-only; no DDL, DML, TEMP object, side-effect function call,
-- grant, or business-row exposure. Aggregate metadata only.

WITH required_versions(version) AS (VALUES
  ('20260805160000'),('20260812120000'),('20260813080000')
), expected_relations(relation_name) AS (VALUES
  ('customer_balance_company_policies'),
  ('customer_balance_correction_requests'),
  ('customer_balance_ledger_entries'),('customer_balance_audit')
), expected_routines(signature) AS (VALUES
  ('public.get_finance_customer_balance_references()'),
  ('public.get_customer_balance_statement(uuid,timestamp with time zone,timestamp with time zone)'),
  ('public.request_customer_balance_correction(uuid,uuid,text,numeric,text,text,text,uuid)'),
  ('public.review_customer_balance_correction(uuid,bigint,text,text,uuid)')
), mutation_routines AS (
  SELECT procedure.proname,pg_get_functiondef(procedure.oid) definition
  FROM pg_proc procedure WHERE procedure.oid IN(
    to_regprocedure('public.request_customer_balance_correction(uuid,uuid,text,numeric,text,text,text,uuid)'),
    to_regprocedure('public.review_customer_balance_correction(uuid,bigint,text,text,uuid)'))
), read_routines AS (
  SELECT procedure.proname,pg_get_functiondef(procedure.oid) definition
  FROM pg_proc procedure WHERE procedure.oid IN(
    to_regprocedure('public.get_finance_customer_balance_references()'),
    to_regprocedure('public.get_customer_balance_statement(uuid,timestamp with time zone,timestamp with time zone)'))
), relation_privileges AS (
  SELECT relation_name,
    has_table_privilege('authenticated',format('public.%I',relation_name),
      'SELECT') readable,
    has_table_privilege('authenticated',format('public.%I',relation_name),
      'INSERT,UPDATE,DELETE') writable
  FROM expected_relations
), ledger_totals AS (
  SELECT entry.company_id,entry.customer_id,
    COALESCE(sum(CASE WHEN entry.direction='CREDIT'
      THEN entry.amount ELSE -entry.amount END),0) ledger_balance
  FROM public.customer_balance_ledger_entries entry
  GROUP BY entry.company_id,entry.customer_id
), checks AS (
  SELECT 'acp_phase6d_dependencies'::TEXT check_name,
    CASE WHEN count(*) FILTER(WHERE migration.version IS NULL)=0
      THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('expected',count(*),'missing',COALESCE(
      jsonb_agg(required.version ORDER BY required.version)
        FILTER(WHERE migration.version IS NULL),'[]'::JSONB)) details
  FROM required_versions required
  LEFT JOIN private.kgs_schema_migrations migration
    ON migration.version=required.version

  UNION ALL SELECT 'customer_balance_authority_split','REVIEW',
    jsonb_build_object(
      'viewRoles',ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE','ACCOUNTING'],
      'managementRoles',ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE'],
      'requiredDesign',ARRAY[
        'VIEW grants Backoffice balances, correction queue and statement only',
        'MANAGE creates a correction request; APPROVE or REVIEW decides it',
        'maker cannot review its own correction request',
        'custom permission may restrict but never widen Company or Store scope'])

  UNION ALL SELECT 'customer_balance_pos_consumer_scope','REVIEW',
    jsonb_build_object('requiredDesign',ARRAY[
      'POS overpayment credit and balance tender retain open-session Sale authority',
      'POS never inherits Backoffice correction or statement authority',
      'server remains authoritative for balance, payment and ledger effects',
      'offline and online Sale paths keep their independent entitlement guards'])

  UNION ALL SELECT 'customer_balance_customer_master_boundary','REVIEW',
    jsonb_build_object('requiredDesign',ARRAY[
      'Customer identity mutation remains contacts.customers MANAGE',
      'Customer Balance receives only narrow active Customer references',
      'Walk-In can never own or spend Customer Balance',
      'client-supplied purpose never bypasses either permission key'])

  UNION ALL SELECT 'customer_balance_direct_read_cutover_scope','REVIEW',
    jsonb_build_object('authenticatedReadRelations',COALESCE(
      jsonb_agg(relation_name ORDER BY relation_name)
        FILTER(WHERE readable),'[]'::JSONB),'requiredDesign',ARRAY[
      'replace Backoffice direct reads with one VIEW-guarded composed RPC',
      'return policy, Customer balances, requests, actors and Store labels only',
      'retain statement as a bounded VIEW-guarded RPC',
      'revoke direct SELECT only after every active consumer migrates'])
  FROM relation_privileges

  UNION ALL SELECT 'canonical_customer_balance_composed_read_state','SETUP',
    jsonb_build_object('rpcExists',to_regprocedure(
      'public.get_finance_customer_balances()') IS NOT NULL,
      'requiredDesign',ARRAY[
        'guard list and detail with finance.customer_balances VIEW',
        'do not expose unrelated Sale, Payment, Customer or Journal ledgers',
        'export requires finance.customer_balances EXPORT explicitly'])

  UNION ALL SELECT 'customer_balance_runtime_permission_hook_state','SETUP',
    jsonb_build_object('routineRows',count(*),'hookedRows',count(*) FILTER(
      WHERE definition ILIKE '%acp_require_permission_capability%'))
  FROM mutation_routines

  UNION ALL SELECT 'customer_balance_read_permission_hook_state','SETUP',
    jsonb_build_object('routineRows',count(*),'hookedRows',count(*) FILTER(
      WHERE definition ILIKE '%acp_require_permission_capability%'
         OR definition ILIKE '%acp_resolve_permission%'))
  FROM read_routines

  UNION ALL SELECT 'canonical_customer_balance_schema_state',
    CASE WHEN count(*) FILTER(WHERE to_regclass(
      format('public.%I',relation_name)) IS NULL)=0
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('expected',count(*),'missing',COALESCE(
      jsonb_agg(relation_name ORDER BY relation_name) FILTER(WHERE
        to_regclass(format('public.%I',relation_name)) IS NULL),'[]'::JSONB))
  FROM expected_relations

  UNION ALL SELECT 'canonical_customer_balance_routine_state',
    CASE WHEN count(*) FILTER(WHERE to_regprocedure(signature) IS NULL)=0
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('expected',count(*),'missing',COALESCE(
      jsonb_agg(signature ORDER BY signature)
        FILTER(WHERE to_regprocedure(signature) IS NULL),'[]'::JSONB))
  FROM expected_routines

  UNION ALL SELECT 'customer_balance_permission_catalog_state',
    CASE WHEN count(*)=1 AND bool_and(enforcement_status='SHADOW')
      AND bool_and('VIEW'=ANY(supported_capabilities))
      AND bool_and('MANAGE'=ANY(supported_capabilities))
      AND bool_and('APPROVE'=ANY(supported_capabilities))
      AND bool_and('EXPORT'=ANY(supported_capabilities))
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('rows',count(*),'statuses',COALESCE(
      jsonb_agg(enforcement_status),'[]'::JSONB),'capabilities',COALESCE(
      jsonb_agg(supported_capabilities),'[]'::JSONB))
  FROM public.access_permission_catalog
  WHERE permission_key='finance.customer_balances'

  UNION ALL SELECT 'customer_balance_direct_write_boundary',
    CASE WHEN count(*) FILTER(WHERE writable)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('directWriteRelations',COALESCE(
      jsonb_agg(relation_name ORDER BY relation_name)
        FILTER(WHERE writable),'[]'::JSONB))
  FROM relation_privileges

  UNION ALL SELECT 'invalid_customer_balance_policy_state',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('rowCount',count(*))
  FROM public.customer_balance_company_policies policy
  LEFT JOIN public.company_features feature
    ON feature.company_id=policy.company_id
   AND feature.feature_code='customer_balance_enabled'
  WHERE (policy.lifecycle_state='ACTIVE' AND NOT COALESCE(feature.is_enabled,FALSE))
     OR (policy.lifecycle_state='WIND_DOWN' AND NOT EXISTS(
       SELECT 1 FROM public.customers customer
       WHERE customer.company_id=policy.company_id
         AND customer.current_balance>0))

  UNION ALL SELECT 'invalid_customer_balance_correction_lifecycle',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('rowCount',count(*))
  FROM public.customer_balance_correction_requests request
  WHERE request.amount<=0
    OR (request.status='SUBMITTED' AND (request.reviewed_by IS NOT NULL
      OR request.ledger_entry_id IS NOT NULL
      OR request.financial_event_id IS NOT NULL))
    OR (request.status='APPROVED' AND (request.reviewed_by IS NULL
      OR request.ledger_entry_id IS NULL
      OR request.financial_event_id IS NULL))
    OR (request.status='REJECTED' AND (request.reviewed_by IS NULL
      OR NULLIF(btrim(request.rejection_reason),'') IS NULL
      OR request.ledger_entry_id IS NOT NULL
      OR request.financial_event_id IS NOT NULL))

  UNION ALL SELECT 'maker_reviewed_own_customer_balance_correction',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('requestCount',count(*))
  FROM public.customer_balance_correction_requests request
  WHERE request.status IN('APPROVED','REJECTED')
    AND request.created_by=request.reviewed_by

  UNION ALL SELECT 'customer_balance_cache_ledger_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('customerCount',count(*))
  FROM public.customers customer
  LEFT JOIN ledger_totals total ON total.company_id=customer.company_id
    AND total.customer_id=customer.id
  WHERE customer.current_balance<>COALESCE(total.ledger_balance,0)

  UNION ALL SELECT 'negative_or_walk_in_customer_balance',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('rowCount',count(*))
  FROM public.customers customer
  WHERE customer.current_balance<0
    OR (customer.is_system_customer AND customer.current_balance<>0)

  UNION ALL SELECT 'customer_balance_ledger_source_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('rowCount',count(*))
  FROM public.customer_balance_ledger_entries entry
  WHERE (entry.source_type='MANUAL_CORRECTION' AND NOT EXISTS(
      SELECT 1 FROM public.customer_balance_correction_requests request
      WHERE request.company_id=entry.company_id AND request.id=entry.source_id
        AND request.status='APPROVED' AND request.ledger_entry_id=entry.id))
    OR (entry.source_type IN('SALE_OVERPAYMENT','SALE_PAYMENT') AND NOT EXISTS(
      SELECT 1 FROM public.sales_payments payment
      WHERE payment.company_id=entry.company_id AND payment.id=entry.source_id
        AND NOT payment.is_reversal))
    OR entry.source_type NOT IN(
      'MANUAL_CORRECTION','SALE_OVERPAYMENT','SALE_PAYMENT')

  UNION ALL SELECT 'customer_balance_financial_event_coverage',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('ledgerCount',count(*))
  FROM public.customer_balance_ledger_entries entry
  LEFT JOIN public.financial_events event ON event.company_id=entry.company_id
    AND event.id=entry.financial_event_id
  WHERE event.id IS NULL OR event.status NOT IN('HOLD','POSTED')

  UNION ALL SELECT 'customer_balance_tenant_reference_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('orphanOrCrossTenantRows',count(*))
  FROM (
    SELECT request.id FROM public.customer_balance_correction_requests request
    LEFT JOIN public.customers customer ON customer.company_id=request.company_id
      AND customer.id=request.customer_id
    LEFT JOIN public.stores store ON store.company_id=request.company_id
      AND store.id=request.store_id
    WHERE customer.id IS NULL OR store.id IS NULL
    UNION ALL
    SELECT entry.id FROM public.customer_balance_ledger_entries entry
    LEFT JOIN public.customers customer ON customer.company_id=entry.company_id
      AND customer.id=entry.customer_id
    LEFT JOIN public.transaction_categories category
      ON category.company_id=entry.company_id
     AND category.id=entry.transaction_category_id
    LEFT JOIN public.chart_of_accounts liability
      ON liability.company_id=entry.company_id
     AND liability.id=entry.liability_account_id
    LEFT JOIN public.chart_of_accounts source_account
      ON source_account.company_id=entry.company_id
     AND source_account.id=entry.source_account_id
    WHERE customer.id IS NULL OR category.id IS NULL OR liability.id IS NULL
      OR source_account.id IS NULL
  ) invalid_reference

  UNION ALL SELECT 'customer_balance_audit_coverage',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('requestCount',count(*))
  FROM public.customer_balance_correction_requests request
  WHERE NOT EXISTS(SELECT 1 FROM public.customer_balance_audit audit
    WHERE audit.company_id=request.company_id
      AND audit.correction_request_id=request.id
      AND audit.action='REQUEST_CORRECTION')

  UNION ALL SELECT 'customer_balance_finance_hold_boundary','REVIEW',
    jsonb_build_object(
      'holdEvents',(SELECT count(*) FROM public.financial_events
        WHERE event_type='CUSTOMER_BALANCE_ADJUSTMENT' AND status='HOLD'),
      'requiredDesign',ARRAY[
        'ACP preserves existing event status and does not create Journal entries',
        'correction and Sale ledger snapshots remain immutable',
        'posting and reversal remain finance.journals_reports authority'])

  UNION ALL SELECT 'customer_balance_runtime_inventory','INFO',
    jsonb_build_object(
      'activePolicies',(SELECT count(*)
        FROM public.customer_balance_company_policies
        WHERE lifecycle_state='ACTIVE'),
      'windDownPolicies',(SELECT count(*)
        FROM public.customer_balance_company_policies
        WHERE lifecycle_state='WIND_DOWN'),
      'customersWithBalance',(SELECT count(*) FROM public.customers
        WHERE current_balance>0),
      'balanceTotal',(SELECT COALESCE(sum(current_balance),0)
        FROM public.customers),
      'correctionRequests',(SELECT count(*)
        FROM public.customer_balance_correction_requests),
      'submittedRequests',(SELECT count(*)
        FROM public.customer_balance_correction_requests
        WHERE status='SUBMITTED'),
      'ledgerEntries',(SELECT count(*)
        FROM public.customer_balance_ledger_entries),
      'manualEntries',(SELECT count(*)
        FROM public.customer_balance_ledger_entries
        WHERE source_type='MANUAL_CORRECTION'),
      'saleCreditEntries',(SELECT count(*)
        FROM public.customer_balance_ledger_entries
        WHERE source_type='SALE_OVERPAYMENT'),
      'saleUsageEntries',(SELECT count(*)
        FROM public.customer_balance_ledger_entries
        WHERE source_type='SALE_PAYMENT'),
      'overrideRows',(SELECT count(*)
        FROM public.user_company_permission_overrides
        WHERE permission_key='finance.customer_balances'))
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'BACKFILL' THEN 2
  WHEN 'SETUP' THEN 3 WHEN 'REVIEW' THEN 4 WHEN 'PASS' THEN 5 ELSE 6 END,
  check_name;
