-- ACP-6C preflight: Deposit Variance permission enforcement readiness.
-- SAFETY: SELECT-only; no DDL, DML, TEMP object, function call with side
-- effect, grant, or business-row exposure. Aggregate metadata only.

WITH required_versions(version) AS (VALUES
  ('20260804160000'),('20260812120000'),('20260813070000')
), expected_relations(relation_name) AS (VALUES
  ('deposit_variance_exceptions'),('deposit_variance_allocations'),
  ('deposit_variance_resolution_requests'),
  ('deposit_variance_resolution_audit')
), expected_routines(signature) AS (VALUES
  ('public.assign_deposit_variance_responsible_party(uuid,bigint,uuid,text)'),
  ('public.resolve_deposit_variance(uuid,bigint,numeric,text,text,text,text,text,uuid)'),
  ('public.review_deposit_variance_resolution(uuid,bigint,text,text,uuid)')
), mutation_routines AS (
  SELECT procedure.proname,pg_get_functiondef(procedure.oid) definition
  FROM pg_proc procedure WHERE procedure.oid IN(
    to_regprocedure('public.assign_deposit_variance_responsible_party(uuid,bigint,uuid,text)'),
    to_regprocedure('public.resolve_deposit_variance(uuid,bigint,numeric,text,text,text,text,text,uuid)'),
    to_regprocedure('public.review_deposit_variance_resolution(uuid,bigint,text,text,uuid)'))
), relation_privileges AS (
  SELECT relation_name,
    has_table_privilege('authenticated',format('public.%I',relation_name),
      'SELECT') readable,
    has_table_privilege('authenticated',format('public.%I',relation_name),
      'INSERT,UPDATE,DELETE') writable
  FROM expected_relations
), checks AS (
  SELECT 'acp_phase6c_dependencies'::TEXT check_name,
    CASE WHEN count(*) FILTER(WHERE migration.version IS NULL)=0
      THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('expected',count(*),'missing',COALESCE(
      jsonb_agg(required.version ORDER BY required.version)
        FILTER(WHERE migration.version IS NULL),'[]'::JSONB)) details
  FROM required_versions required
  LEFT JOIN private.kgs_schema_migrations migration
    ON migration.version=required.version

  UNION ALL SELECT 'deposit_variance_authority_split','REVIEW',
    jsonb_build_object(
      'managementRoles',ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE'],
      'reviewRoles',ARRAY['COMPANY_OWNER','COMPANY_ADMIN'],
      'requiredDesign',ARRAY[
        'VIEW grants Backoffice list and detail only',
        'MANAGE assigns responsible party and creates resolution requests',
        'APPROVE and REJECT remain maker-checker Owner or Admin actions',
        'custom permission may restrict but never widen Company or Store scope'])

  UNION ALL SELECT 'deposit_variance_direct_read_cutover_scope','REVIEW',
    jsonb_build_object('authenticatedReadRelations',COALESCE(
      jsonb_agg(relation_name ORDER BY relation_name)
        FILTER(WHERE readable),'[]'::JSONB),
      'requiredDesign',ARRAY[
        'replace Backoffice direct reads with one VIEW-guarded composed RPC',
        'include requests, allocations, actors and narrow linked Deposit labels',
        'revoke direct SELECT only after every active browser consumer migrates'])
  FROM relation_privileges

  UNION ALL SELECT 'deposit_variance_cash_deposit_boundary','REVIEW',
    jsonb_build_object(
      'cashDepositReferenceRpcExists',to_regprocedure(
        'public.get_deposit_variance_cash_deposit_references()') IS NOT NULL,
      'requiredDesign',ARRAY[
        'Deposit Variance authorizes linked Deposit references with its own VIEW',
        'it never inherits finance.cash_deposits APPROVE or Cashier authority',
        'Cash Deposit restriction must not hide already-linked variance evidence'])

  UNION ALL SELECT 'deposit_variance_finance_hold_boundary','REVIEW',
    jsonb_build_object(
      'holdEvents',(SELECT count(*) FROM public.financial_events
        WHERE event_type='DEPOSIT_VARIANCE_RESOLUTION' AND status='HOLD'),
      'requiredDesign',ARRAY[
        'ACP does not post or release Finance HOLD events',
        'resolution amount, type, account and source snapshots remain immutable',
        'Journal reversal and period authority remain finance.journals_reports'])

  UNION ALL SELECT 'canonical_deposit_variance_composed_read_state','SETUP',
    jsonb_build_object('rpcExists',to_regprocedure(
      'public.get_finance_deposit_variances()') IS NOT NULL,
      'requiredDesign',ARRAY[
        'guard list and detail with finance.deposit_variances VIEW',
        'return only exception, request, allocation, actor and linked Deposit proof',
        'do not expose unrelated Cash Deposit, drawer, account or Journal ledgers'])

  UNION ALL SELECT 'deposit_variance_runtime_permission_hook_state','SETUP',
    jsonb_build_object('routineRows',count(*),'hookedRows',count(*) FILTER(
      WHERE definition ILIKE '%acp_require_permission_capability%'))
  FROM mutation_routines

  UNION ALL SELECT 'canonical_deposit_variance_schema_state',
    CASE WHEN count(*) FILTER(WHERE to_regclass(
      format('public.%I',relation_name)) IS NULL)=0
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('expected',count(*),'missing',COALESCE(
      jsonb_agg(relation_name ORDER BY relation_name) FILTER(WHERE
        to_regclass(format('public.%I',relation_name)) IS NULL),'[]'::JSONB))
  FROM expected_relations

  UNION ALL SELECT 'canonical_deposit_variance_routine_state',
    CASE WHEN count(*) FILTER(WHERE to_regprocedure(signature) IS NULL)=0
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('expected',count(*),'missing',COALESCE(
      jsonb_agg(signature ORDER BY signature)
        FILTER(WHERE to_regprocedure(signature) IS NULL),'[]'::JSONB))
  FROM expected_routines

  UNION ALL SELECT 'deposit_variance_permission_catalog_state',
    CASE WHEN count(*)=1 AND bool_and(enforcement_status='SHADOW')
      AND bool_and('VIEW'=ANY(supported_capabilities))
      AND bool_and('MANAGE'=ANY(supported_capabilities))
      AND bool_and('APPROVE'=ANY(supported_capabilities))
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('rows',count(*),'statuses',COALESCE(
      jsonb_agg(enforcement_status),'[]'::JSONB),'capabilities',COALESCE(
      jsonb_agg(supported_capabilities),'[]'::JSONB))
  FROM public.access_permission_catalog
  WHERE permission_key='finance.deposit_variances'

  UNION ALL SELECT 'deposit_variance_direct_write_boundary',
    CASE WHEN count(*) FILTER(WHERE writable)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('directWriteRelations',COALESCE(
      jsonb_agg(relation_name ORDER BY relation_name)
        FILTER(WHERE writable),'[]'::JSONB))
  FROM relation_privileges

  UNION ALL SELECT 'deposit_variance_browser_rpc_execution',
    CASE WHEN count(*)=3
      AND count(*) FILTER(WHERE authenticated_execute)=3
      AND count(*) FILTER(WHERE anon_execute)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('routineRows',count(*),
      'authenticatedRows',count(*) FILTER(WHERE authenticated_execute),
      'anonRows',count(*) FILTER(WHERE anon_execute))
  FROM (SELECT signature,
    to_regprocedure(signature) IS NOT NULL
      AND has_function_privilege('authenticated',to_regprocedure(signature),
        'EXECUTE') authenticated_execute,
    to_regprocedure(signature) IS NOT NULL
      AND has_function_privilege('anon',to_regprocedure(signature),'EXECUTE')
        anon_execute FROM expected_routines) privilege_state

  UNION ALL SELECT 'invalid_deposit_variance_exception_lifecycle',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('rowCount',count(*))
  FROM public.deposit_variance_exceptions exception
  WHERE exception.original_amount<=0 OR exception.resolved_amount<0
    OR exception.remaining_amount<0
    OR exception.remaining_amount<>
      exception.original_amount-exception.resolved_amount
    OR (exception.status IN('RESOLVED','WRITTEN_OFF')
      AND exception.remaining_amount<>0)
    OR (exception.status NOT IN('RESOLVED','WRITTEN_OFF','CANCELED')
      AND exception.remaining_amount=0)

  UNION ALL SELECT 'invalid_deposit_variance_request_lifecycle',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('rowCount',count(*))
  FROM public.deposit_variance_resolution_requests request
  WHERE request.allocation_amount<=0
    OR (request.status='SUBMITTED' AND (request.reviewed_by IS NOT NULL
      OR request.allocation_id IS NOT NULL OR request.financial_event_id IS NOT NULL))
    OR (request.status='APPROVED' AND (request.reviewed_by IS NULL
      OR request.allocation_id IS NULL OR request.financial_event_id IS NULL))
    OR (request.status='REJECTED' AND (request.reviewed_by IS NULL
      OR NULLIF(btrim(request.rejection_reason),'') IS NULL
      OR request.allocation_id IS NOT NULL OR request.financial_event_id IS NOT NULL))

  UNION ALL SELECT 'maker_reviewed_own_deposit_variance_request',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('requestCount',count(*))
  FROM public.deposit_variance_resolution_requests request
  WHERE request.requires_review AND request.status IN('APPROVED','REJECTED')
    AND request.created_by=request.reviewed_by

  UNION ALL SELECT 'deposit_variance_allocation_request_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('requestCount',count(*))
  FROM public.deposit_variance_resolution_requests request
  LEFT JOIN public.deposit_variance_allocations allocation
    ON allocation.company_id=request.company_id
   AND allocation.id=request.allocation_id
  WHERE request.status='APPROVED' AND (
    allocation.id IS NULL
    OR allocation.variance_exception_id<>request.variance_exception_id
    OR allocation.resolution_request_id<>request.id
    OR allocation.allocation_amount<>request.allocation_amount
    OR allocation.resolution_type<>request.resolution_type
    OR allocation.financial_event_id<>request.financial_event_id)

  UNION ALL SELECT 'deposit_variance_resolution_event_coverage',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('requestCount',count(*))
  FROM public.deposit_variance_resolution_requests request
  LEFT JOIN public.financial_events event
    ON event.company_id=request.company_id
   AND event.id=request.financial_event_id
  WHERE request.status='APPROVED' AND (
    event.id IS NULL OR event.event_type<>'DEPOSIT_VARIANCE_RESOLUTION'
    OR event.source_table<>'deposit_variance_resolution_requests'
    OR event.source_id<>request.id OR event.status<>'HOLD')

  UNION ALL SELECT 'deposit_variance_tenant_reference_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('orphanOrCrossTenantRows',count(*))
  FROM (
    SELECT exception.id FROM public.deposit_variance_exceptions exception
    LEFT JOIN public.cash_deposit_documents deposit
      ON deposit.company_id=exception.company_id
     AND deposit.id=exception.cash_deposit_document_id
    LEFT JOIN public.stores store ON store.company_id=exception.company_id
      AND store.id=exception.store_id
    LEFT JOIN public.transaction_categories category
      ON category.company_id=exception.company_id
     AND category.id=exception.transaction_category_id
    LEFT JOIN public.chart_of_accounts account
      ON account.company_id=exception.company_id
     AND account.id=exception.control_account_id
    WHERE deposit.id IS NULL OR store.id IS NULL OR category.id IS NULL
      OR account.id IS NULL
    UNION ALL
    SELECT request.id FROM public.deposit_variance_resolution_requests request
    LEFT JOIN public.deposit_variance_exceptions exception
      ON exception.company_id=request.company_id
     AND exception.id=request.variance_exception_id
    LEFT JOIN public.stores store ON store.company_id=request.company_id
      AND store.id=request.store_id
    WHERE exception.id IS NULL OR store.id IS NULL
    UNION ALL
    SELECT allocation.id FROM public.deposit_variance_allocations allocation
    LEFT JOIN public.deposit_variance_exceptions exception
      ON exception.company_id=allocation.company_id
     AND exception.id=allocation.variance_exception_id
    LEFT JOIN public.deposit_variance_resolution_requests request
      ON request.company_id=allocation.company_id
     AND request.id=allocation.resolution_request_id
    WHERE exception.id IS NULL OR request.id IS NULL
  ) invalid_reference

  UNION ALL SELECT 'deposit_variance_resolution_audit_coverage',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('requestCount',count(*))
  FROM public.deposit_variance_resolution_requests request
  WHERE NOT EXISTS(SELECT 1 FROM public.deposit_variance_resolution_audit audit
    WHERE audit.company_id=request.company_id
      AND audit.resolution_request_id=request.id AND audit.action='REQUEST')

  UNION ALL SELECT 'deposit_variance_runtime_inventory','INFO',
    jsonb_build_object(
      'companies',(SELECT count(DISTINCT company_id)
        FROM public.deposit_variance_exceptions),
      'exceptions',(SELECT count(*) FROM public.deposit_variance_exceptions),
      'openExceptions',(SELECT count(*) FROM public.deposit_variance_exceptions
        WHERE status IN('OPEN','UNDER_INVESTIGATION','PARTIALLY_RESOLVED')),
      'resolvedExceptions',(SELECT count(*)
        FROM public.deposit_variance_exceptions
        WHERE status IN('RESOLVED','WRITTEN_OFF')),
      'requests',(SELECT count(*)
        FROM public.deposit_variance_resolution_requests),
      'submittedRequests',(SELECT count(*)
        FROM public.deposit_variance_resolution_requests
        WHERE status='SUBMITTED'),
      'allocations',(SELECT count(*) FROM public.deposit_variance_allocations),
      'resolutionHoldEvents',(SELECT count(*) FROM public.financial_events
        WHERE event_type='DEPOSIT_VARIANCE_RESOLUTION' AND status='HOLD'),
      'overrideRows',(SELECT count(*)
        FROM public.user_company_permission_overrides
        WHERE permission_key='finance.deposit_variances'))
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'BACKFILL' THEN 2
  WHEN 'SETUP' THEN 3 WHEN 'REVIEW' THEN 4 WHEN 'PASS' THEN 5 ELSE 6 END,
  check_name;
