-- Read-only Production preflight for the default-OFF POS Session-close
-- Stock Request policy. Stop on BLOCKER; INFO is inventory only.
WITH required_relations(name) AS (
  VALUES ('company_purchase_replenishment_settings'),
    ('company_purchase_replenishment_setting_audit'),('cashier_sessions'),
    ('sales_order_procurement_demands'),
    ('sales_order_procurement_demand_lines'),('stock_request_documents'),
    ('finance_posting_queue_runs'),('pos_offline_sale_submissions')
), relation_check AS (
  SELECT array_agg(name ORDER BY name) FILTER(
    WHERE to_regclass('public.'||name) IS NULL) missing FROM required_relations
), required_routines(signature) AS (
  VALUES ('public.get_purchase_replenishment_setting()'),
    ('public.close_cashier_session(uuid,bigint,numeric)'),
    ('private.ensure_session_procurement_stock_request(uuid,uuid,uuid)'),
    ('private.odr5d_close_cashier_session_legacy(uuid,bigint,numeric)')
), routine_check AS (
  SELECT array_agg(signature ORDER BY signature) FILTER(
    WHERE to_regprocedure(signature) IS NULL) missing FROM required_routines
), dependency_check AS (
  SELECT required.version,ledger.version installed
  FROM (VALUES ('20260828170000'),('20260829130000'),('20260924100000'))
    required(version)
  LEFT JOIN private.kgs_schema_migrations ledger ON ledger.version=required.version
), definitions AS (
  SELECT 'close' name,pg_get_functiondef(
    'public.close_cashier_session(uuid,bigint,numeric)'::regprocedure) body
  UNION ALL SELECT 'request',pg_get_functiondef(
    'private.ensure_session_procurement_stock_request(uuid,uuid,uuid)'::regprocedure)
), runtime_anchor AS (
  SELECT count(*) FILTER(WHERE name='close'
      AND body~'odr5d_close_cashier_session_legacy'
      AND body~'paymentVerificationDeferred') close_rows,
    count(*) FILTER(WHERE name='request'
      AND body~'SALES_ORDER_RESERVATION'
      AND body~'stock_request_document_id') request_rows
  FROM definitions
), constraint_anchor AS (
  SELECT count(*) rows FROM pg_constraint constraint_row
  WHERE constraint_row.conrelid=
      'public.company_purchase_replenishment_setting_audit'::regclass
    AND constraint_row.conname=
      'company_purchase_replenishment_setting_audit_action_check'
), lineage_invalid AS (
  SELECT demand.id FROM public.sales_order_procurement_demands demand
  LEFT JOIN public.stock_request_documents request
    ON request.company_id=demand.company_id
   AND request.id=demand.stock_request_document_id
  WHERE demand.stock_request_document_id IS NOT NULL
    AND (request.id IS NULL OR request.request_source<>'SALES_ORDER_RESERVATION'
      OR request.requesting_session_id<>demand.cashier_session_id)
), setting_inventory AS (
  SELECT count(*) setting_rows,
    count(*) FILTER(WHERE company.status='ACTIVE') active_company_rows
  FROM public.company_purchase_replenishment_settings setting
  JOIN public.companies company ON company.id=setting.company_id
)
SELECT 'pos_session_request_policy_required_relations' check_name,
  CASE WHEN coalesce(cardinality(missing),0)=0 THEN 'PASS' ELSE 'BLOCKER' END status,
  coalesce(cardinality(missing),0)::bigint violation_rows,
  jsonb_build_object('missing',coalesce(to_jsonb(missing),'[]'::jsonb)) details
FROM relation_check
UNION ALL
SELECT 'pos_session_request_policy_required_routines',
  CASE WHEN coalesce(cardinality(missing),0)=0 THEN 'PASS' ELSE 'BLOCKER' END,
  coalesce(cardinality(missing),0)::bigint,
  jsonb_build_object('missing',coalesce(to_jsonb(missing),'[]'::jsonb))
FROM routine_check
UNION ALL
SELECT 'pos_session_request_policy_dependency_ledger',
  CASE WHEN count(*) FILTER(WHERE installed IS NULL)=0 THEN 'PASS' ELSE 'BLOCKER' END,
  count(*) FILTER(WHERE installed IS NULL)::bigint,
  jsonb_build_object('missing',coalesce(jsonb_agg(version ORDER BY version)
    FILTER(WHERE installed IS NULL),'[]'::jsonb)) FROM dependency_check
UNION ALL
SELECT 'pos_session_request_policy_runtime_anchor',
  CASE WHEN close_rows=1 AND request_rows=1 THEN 'PASS' ELSE 'BLOCKER' END,
  CASE WHEN close_rows=1 AND request_rows=1 THEN 0 ELSE 1 END::bigint,
  jsonb_build_object('close',close_rows,'request',request_rows) FROM runtime_anchor
UNION ALL
SELECT 'pos_session_request_policy_constraint_anchor',
  CASE WHEN rows=1 THEN 'PASS' ELSE 'BLOCKER' END,
  abs(rows-1)::bigint,jsonb_build_object('rows',rows,'expected',1)
FROM constraint_anchor
UNION ALL
SELECT 'pos_session_request_policy_object_collision',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
  jsonb_build_object('existing',coalesce(jsonb_agg(name ORDER BY name),'[]'::jsonb))
FROM (
  SELECT 'settings.session_close_stock_request_enabled' name WHERE EXISTS(
    SELECT 1 FROM information_schema.columns WHERE table_schema='public'
      AND table_name='company_purchase_replenishment_settings'
      AND column_name='session_close_stock_request_enabled')
  UNION ALL SELECT 'cashier_sessions.stock_request_on_close_enabled_snapshot'
  WHERE EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='public'
    AND table_name='cashier_sessions'
    AND column_name='stock_request_on_close_enabled_snapshot')
  UNION ALL SELECT 'cashier_sessions.stock_request_on_close_policy_decided_at'
  WHERE EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='public'
    AND table_name='cashier_sessions'
    AND column_name='stock_request_on_close_policy_decided_at')
  UNION ALL SELECT 'set_session_close_stock_request_policy(boolean,bigint)'
  WHERE to_regprocedure(
    'public.set_session_close_stock_request_policy(boolean,bigint)') IS NOT NULL
  UNION ALL SELECT 'migration:20260924110000' WHERE EXISTS(
    SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260924110000')
) collision
UNION ALL
SELECT 'pos_session_request_policy_existing_lineage',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
  jsonb_build_object('invalidRows',count(*)) FROM lineage_invalid
UNION ALL
SELECT 'pos_session_request_policy_active_finance_queue',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
  jsonb_build_object('runRows',count(*))
FROM public.finance_posting_queue_runs
WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
UNION ALL
SELECT 'pos_session_request_policy_nonterminal_offline',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
  jsonb_build_object('submissionRows',count(*))
FROM public.pos_offline_sale_submissions
WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
UNION ALL
SELECT 'pos_session_request_policy_setting_inventory','INFO',0,
  jsonb_build_object('settingRows',setting_rows,
    'activeCompanyRows',active_company_rows) FROM setting_inventory
UNION ALL
SELECT 'pos_session_request_policy_runtime_inventory','INFO',0,
  jsonb_build_object(
    'openSessions',count(*) FILTER(WHERE status='OPEN'::public.session_status),
    'closedSessions',count(*) FILTER(WHERE status='CLOSED'::public.session_status))
FROM public.cashier_sessions;
