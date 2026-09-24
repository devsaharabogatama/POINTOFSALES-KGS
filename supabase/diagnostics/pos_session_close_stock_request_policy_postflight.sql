-- Read-only verification after migration 20260924110000.
WITH columns AS (
  SELECT table_name,column_name,is_nullable,column_default
  FROM information_schema.columns WHERE table_schema='public' AND (
    (table_name='company_purchase_replenishment_settings'
      AND column_name='session_close_stock_request_enabled') OR
    (table_name='cashier_sessions' AND column_name IN(
      'stock_request_on_close_enabled_snapshot',
      'stock_request_on_close_policy_decided_at')))
), required_routines(signature) AS (
  VALUES ('public.get_purchase_replenishment_setting()'),
    ('public.set_session_close_stock_request_policy(boolean,bigint)'),
    ('public.close_cashier_session(uuid,bigint,numeric)'),
    ('private.ensure_session_procurement_stock_request(uuid,uuid,uuid)')
), routine_check AS (
  SELECT array_agg(signature ORDER BY signature) FILTER(
    WHERE to_regprocedure(signature) IS NULL) missing FROM required_routines
), definitions AS (
  SELECT 'getter' name,pg_get_functiondef(
      'public.get_purchase_replenishment_setting()'::regprocedure) body
  UNION ALL SELECT 'setter',pg_get_functiondef(
      'public.set_session_close_stock_request_policy(boolean,bigint)'::regprocedure)
  UNION ALL SELECT 'close',pg_get_functiondef(
      'public.close_cashier_session(uuid,bigint,numeric)'::regprocedure)
  UNION ALL SELECT 'request',pg_get_functiondef(
      'private.ensure_session_procurement_stock_request(uuid,uuid,uuid)'::regprocedure)
), contract AS (
  SELECT count(*) FILTER(WHERE name='getter'
      AND body~'sessionCloseStockRequestEnabled') getter_rows,
    count(*) FILTER(WHERE name='setter'
      AND body~'MASTER_VERSION_CONFLICT'
      AND body~'SESSION_CLOSE_STOCK_REQUEST_POLICY_CHANGE') setter_rows,
    count(*) FILTER(WHERE name='close'
      AND body~'stock_request_on_close_enabled_snapshot'
      AND body~'stock_request_on_close_policy_decided_at'
      AND body~'odr5d_close_cashier_session_legacy'
      AND body~'paymentVerificationDeferred') close_rows,
    count(*) FILTER(WHERE name='request'
      AND body~'COMPANY_POLICY_DISABLED'
      AND body~'NO_OUTSTANDING_DEMAND'
      AND body~'stock_request_document_id') request_rows
  FROM definitions
), constraint_contract AS (
  SELECT pg_get_constraintdef(constraint_row.oid) definition
  FROM pg_constraint constraint_row
  WHERE constraint_row.conrelid=
      'public.company_purchase_replenishment_setting_audit'::regclass
    AND constraint_row.conname=
      'company_purchase_replenishment_setting_audit_action_check'
), invalid_link AS (
  SELECT demand.id FROM public.sales_order_procurement_demands demand
  LEFT JOIN public.stock_request_documents request
    ON request.company_id=demand.company_id
   AND request.id=demand.stock_request_document_id
  WHERE demand.stock_request_document_id IS NOT NULL
    AND (request.id IS NULL OR request.request_source<>'SALES_ORDER_RESERVATION'
      OR request.requesting_session_id<>demand.cashier_session_id)
)
SELECT 'pos_session_request_policy_migration_ledger' check_name,
  CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
  abs(count(*)-1)::bigint violation_rows,
  jsonb_build_object('ledgerRows',count(*)) details
FROM private.kgs_schema_migrations WHERE version='20260924110000'
UNION ALL
SELECT 'pos_session_request_policy_column_contract',
  CASE WHEN count(*)=3
      AND count(*) FILTER(WHERE column_name IN(
        'session_close_stock_request_enabled',
        'stock_request_on_close_enabled_snapshot')
        AND is_nullable='NO'
        AND column_default IN('false','false::boolean'))=2
    THEN 'PASS' ELSE 'FAIL' END,
  CASE WHEN count(*)=3
      AND count(*) FILTER(WHERE column_name IN(
        'session_close_stock_request_enabled',
        'stock_request_on_close_enabled_snapshot')
        AND is_nullable='NO'
        AND column_default IN('false','false::boolean'))=2
    THEN 0 ELSE 1 END::bigint,
  jsonb_build_object('rows',count(*),'expected',3) FROM columns
UNION ALL
SELECT 'pos_session_request_policy_routine_contract',
  CASE WHEN coalesce(cardinality(missing),0)=0 THEN 'PASS' ELSE 'FAIL' END,
  coalesce(cardinality(missing),0)::bigint,
  jsonb_build_object('missing',coalesce(to_jsonb(missing),'[]'::jsonb),
    'expected',4) FROM routine_check
UNION ALL
SELECT 'pos_session_request_policy_runtime_contract',
  CASE WHEN getter_rows=1 AND setter_rows=1 AND close_rows=1 AND request_rows=1
    THEN 'PASS' ELSE 'FAIL' END,
  CASE WHEN getter_rows=1 AND setter_rows=1 AND close_rows=1 AND request_rows=1
    THEN 0 ELSE 1 END::bigint,
  jsonb_build_object('getter',getter_rows,'setter',setter_rows,
    'close',close_rows,'request',request_rows) FROM contract
UNION ALL
SELECT 'pos_session_request_policy_audit_constraint',
  CASE WHEN count(*)=1
      AND bool_and(definition~'PROVISION' AND definition~'MODE_CHANGE'
        AND definition~'DEFAULT_WAREHOUSE_CHANGE'
        AND definition~'DRAFT_ROLL_FORWARD_POLICY_CHANGE'
        AND definition~'STOCK_MATCH_POLICY_CHANGE'
        AND definition~'SESSION_CLOSE_STOCK_REQUEST_POLICY_CHANGE')
    THEN 'PASS' ELSE 'FAIL' END,
  CASE WHEN count(*)=1
      AND bool_and(definition~'PROVISION' AND definition~'MODE_CHANGE'
        AND definition~'DEFAULT_WAREHOUSE_CHANGE'
        AND definition~'DRAFT_ROLL_FORWARD_POLICY_CHANGE'
        AND definition~'STOCK_MATCH_POLICY_CHANGE'
        AND definition~'SESSION_CLOSE_STOCK_REQUEST_POLICY_CHANGE')
    THEN 0 ELSE 1 END::bigint,
  jsonb_build_object('rows',count(*)) FROM constraint_contract
UNION ALL
SELECT 'pos_session_request_policy_default_policy',
  CASE WHEN count(*) FILTER(WHERE session_close_stock_request_enabled)=0
    THEN 'PASS' ELSE 'REVIEW' END,
  count(*) FILTER(WHERE session_close_stock_request_enabled)::bigint,
  jsonb_build_object('companyPolicies',count(*),'enabledCompanies',
    count(*) FILTER(WHERE session_close_stock_request_enabled))
FROM public.company_purchase_replenishment_settings
UNION ALL
SELECT 'pos_session_request_policy_historical_snapshot',
  CASE WHEN count(*) FILTER(WHERE stock_request_on_close_policy_decided_at IS NOT NULL)=0
    THEN 'PASS' ELSE 'REVIEW' END,
  count(*) FILTER(WHERE stock_request_on_close_policy_decided_at IS NOT NULL)::bigint,
  jsonb_build_object('decidedSessions',count(*) FILTER(
    WHERE stock_request_on_close_policy_decided_at IS NOT NULL),
    'enabledSnapshots',count(*) FILTER(
      WHERE stock_request_on_close_enabled_snapshot))
FROM public.cashier_sessions
UNION ALL
SELECT 'pos_session_request_policy_lineage_reconciliation',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
  jsonb_build_object('invalidRows',count(*)) FROM invalid_link
UNION ALL
SELECT 'pos_session_request_policy_permission_contract',
  CASE WHEN has_function_privilege('authenticated',
      'public.set_session_close_stock_request_policy(boolean,bigint)','EXECUTE')
    AND NOT has_function_privilege('authenticated',
      'private.ensure_session_procurement_stock_request(uuid,uuid,uuid)','EXECUTE')
    THEN 'PASS' ELSE 'FAIL' END,
  CASE WHEN has_function_privilege('authenticated',
      'public.set_session_close_stock_request_policy(boolean,bigint)','EXECUTE')
    AND NOT has_function_privilege('authenticated',
      'private.ensure_session_procurement_stock_request(uuid,uuid,uuid)','EXECUTE')
    THEN 0 ELSE 1 END::bigint,
  jsonb_build_object('publicAuthenticated',has_function_privilege('authenticated',
      'public.set_session_close_stock_request_policy(boolean,bigint)','EXECUTE'),
    'privateAuthenticated',has_function_privilege('authenticated',
      'private.ensure_session_procurement_stock_request(uuid,uuid,uuid)','EXECUTE'));
