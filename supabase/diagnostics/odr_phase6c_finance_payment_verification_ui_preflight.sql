-- ODR-6C.2 Finance payment-verification UI preflight.
-- SAFETY: SELECT-only. Run before deploying the Backoffice client cutover.
WITH routine_state AS (
  SELECT to_regprocedure(signature) routine_oid
  FROM unnest(ARRAY[
    'public.get_finance_sales_payment_verifications()',
    'public.review_sales_payment_verification(uuid,bigint,text,text,uuid)'
  ]) signature
), checks AS (
  SELECT 'odr_phase6c2_dependencies'::TEXT check_name,
    CASE WHEN count(*)=3 THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('expected',3,'ledgerRows',count(*),'requiredVersions',
      ARRAY['20260828240000','20260828250000','20260828260000']) details
  FROM private.kgs_schema_migrations
  WHERE version IN('20260828240000','20260828250000','20260828260000')
  UNION ALL
  SELECT 'canonical_payment_verification_runtime',
    CASE WHEN count(*)=2 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('expected',2,'routineRows',count(*))
  FROM routine_state WHERE routine_oid IS NOT NULL
  UNION ALL
  SELECT 'payment_verification_permission_state',
    CASE WHEN count(*)=1 AND min(enforcement_status)='ENFORCED'
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('rows',count(*),'statuses',COALESCE(
      jsonb_agg(enforcement_status ORDER BY enforcement_status),'[]'::JSONB))
  FROM public.access_permission_catalog
  WHERE permission_key='finance.sales_payment_verification'
  UNION ALL
  SELECT 'browser_payment_verification_table_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('privilegeRows',count(*))
  FROM information_schema.table_privileges privilege
  WHERE privilege.table_schema='public'
    AND privilege.table_name IN('sales_payment_verification_requests',
      'sales_payment_verification_audit','financial_events','finance_journals')
    AND privilege.grantee IN('anon','authenticated','PUBLIC')
    AND privilege.privilege_type IN('INSERT','UPDATE','DELETE')
  UNION ALL
  SELECT 'payment_verification_rpc_boundary',
    CASE WHEN count(*) FILTER(WHERE privilege.grantee='authenticated')=2
      AND count(*) FILTER(WHERE privilege.grantee IN('anon','PUBLIC'))=0
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object(
      'authenticatedRows',count(*) FILTER(WHERE privilege.grantee='authenticated'),
      'anonOrPublicRows',count(*) FILTER(WHERE privilege.grantee IN('anon','PUBLIC')))
  FROM information_schema.routine_privileges privilege
  WHERE privilege.specific_schema='public' AND privilege.privilege_type='EXECUTE'
    AND privilege.routine_name IN('get_finance_sales_payment_verifications',
      'review_sales_payment_verification')
  UNION ALL
  SELECT 'payment_verification_definition_contract',
    CASE WHEN count(*)=2 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('routineRows',count(*))
  FROM routine_state
  WHERE routine_oid IS NOT NULL
    AND pg_get_functiondef(routine_oid) ILIKE '%finance.sales_payment_verification%'
    AND (pg_get_functiondef(routine_oid) ILIKE '%effectiveCapabilities%'
      OR (pg_get_functiondef(routine_oid) ILIKE '%MAKER_CHECKER_REQUIRED%'
        AND pg_get_functiondef(routine_oid) ILIKE '%p_idempotency_key%'))
  UNION ALL
  SELECT 'active_finance_posting_queue',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('runCount',count(*))
  FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'open_finance_posting_exception',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('exceptionRows',count(*))
  FROM public.finance_posting_exceptions WHERE status='OPEN'
  UNION ALL
  SELECT 'payment_request_tenant_source_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('rowCount',count(*))
  FROM public.sales_payment_verification_requests req
  LEFT JOIN public.sales_headers sale ON sale.company_id=req.company_id
    AND sale.id=req.sales_id
  LEFT JOIN public.stores store_row ON store_row.company_id=req.company_id
    AND store_row.id=req.store_id
  WHERE sale.id IS NULL OR store_row.id IS NULL
  UNION ALL
  SELECT 'payment_request_maker_checker_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('rowCount',count(*))
  FROM public.sales_payment_verification_requests req
  WHERE (req.status IN('VERIFIED','REJECTED') AND
      (req.reviewed_by IS NULL OR req.reviewed_at IS NULL
        OR req.requested_by=req.reviewed_by))
    OR (req.status='PENDING' AND (req.reviewed_by IS NOT NULL
      OR req.reviewed_at IS NOT NULL))
  UNION ALL
  SELECT 'payment_request_event_source_contract',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('rowCount',count(*))
  FROM public.sales_payment_verification_requests req
  LEFT JOIN public.financial_events evt ON evt.company_id=req.company_id
    AND evt.id=req.financial_event_id
  WHERE req.status='VERIFIED' AND (evt.id IS NULL
    OR evt.source_table<>'sales_payment_verification_requests'
    OR evt.source_id<>req.id OR evt.system_event_key<>'SALE_PAYMENT_VERIFIED'
    OR evt.status::TEXT NOT IN('HOLD','POSTED','CANCELED'))
), inventory AS (
  SELECT 'finance_payment_verification_ui_inventory'::TEXT check_name,
    'INFO'::TEXT status,jsonb_build_object(
      'requests',(SELECT count(*) FROM public.sales_payment_verification_requests),
      'pending',(SELECT count(*) FROM public.sales_payment_verification_requests
        WHERE status='PENDING'),
      'verified',(SELECT count(*) FROM public.sales_payment_verification_requests
        WHERE status='VERIFIED'),
      'rejected',(SELECT count(*) FROM public.sales_payment_verification_requests
        WHERE status='REJECTED'),
      'holdEvents',(SELECT count(*) FROM public.financial_events
        WHERE system_event_key='SALE_PAYMENT_VERIFIED' AND status::TEXT='HOLD'),
      'postedEvents',(SELECT count(*) FROM public.financial_events
        WHERE system_event_key='SALE_PAYMENT_VERIFIED' AND status::TEXT='POSTED')) details
)
SELECT * FROM (SELECT * FROM checks UNION ALL SELECT * FROM inventory) result
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,
  check_name;
