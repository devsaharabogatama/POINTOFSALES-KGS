-- Read-only verification after 20260923100000.
WITH required_routines(signature) AS (
  VALUES ('private.auto_verify_pos_cash_payment_request(uuid,uuid,uuid)'),
    ('private.sales_payment_blocks_order_cancel(uuid,uuid,uuid)'),
    ('private.trg_enforce_no_pending_pos_cash()'),
    ('private.trg_odr5_guard_payment_verification()'),
    ('private.capture_sales_order_payment_requests(uuid,uuid,uuid)'),
    ('private.cancel_pending_sales_order_payments(uuid,uuid,uuid,uuid,text)'),
    ('private.confirm_pos_sales_order_before_revision_core(uuid,bigint,uuid,text)'),
    ('public.confirm_pos_sales_order(uuid,bigint,uuid,text)'),
    ('public.get_finance_sales_payment_verifications()'),
    ('public.get_sales_documents()'),('public.get_sales_invoice_document(uuid)')
), routine_check AS (
  SELECT array_agg(signature ORDER BY signature) FILTER(
    WHERE to_regprocedure(signature) IS NULL) missing FROM required_routines
), definitions AS (
  SELECT 'capture' name,pg_get_functiondef(
      'private.capture_sales_order_payment_requests(uuid,uuid,uuid)'::regprocedure) body
  UNION ALL SELECT 'cancel',pg_get_functiondef(
      'private.cancel_pending_sales_order_payments(uuid,uuid,uuid,uuid,text)'::regprocedure)
  UNION ALL SELECT 'confirm',pg_get_functiondef(
      'public.confirm_pos_sales_order(uuid,bigint,uuid,text)'::regprocedure)
  UNION ALL SELECT 'confirm_composition',pg_get_functiondef(
      'private.confirm_pos_sales_order_before_revision_core(uuid,bigint,uuid,text)'::regprocedure)
  UNION ALL SELECT 'queue',pg_get_functiondef(
      'public.get_finance_sales_payment_verifications()'::regprocedure)
  UNION ALL SELECT 'list',pg_get_functiondef('public.get_sales_documents()'::regprocedure)
  UNION ALL SELECT 'detail',pg_get_functiondef(
      'public.get_sales_invoice_document(uuid)'::regprocedure)
), runtime_contract AS (
  SELECT count(*) FILTER(WHERE name='capture' AND body~'auto_verify_pos_cash_payment_request'
      AND body~'autoVerifiedCashCount') capture_rows,
    count(*) FILTER(WHERE name='cancel' AND body~'canceledHoldEvents'
      AND body~'SOURCE_ORDER_CANCELED_BEFORE_DISPATCH') cancel_rows,
    count(*) FILTER(WHERE name='confirm'
      AND body~'private.confirm_pos_sales_order_before_revision_core'
      AND body~'sales_order_revisions') confirm_wrapper_rows,
    count(*) FILTER(WHERE name='confirm_composition'
      AND body~'private.confirm_pos_sales_order_core'
      AND body~'ensure_confirmed_order_invoice_identity'
      AND body~'ensure_confirmed_order_documents'
      AND body~'refresh_sales_order_procurement_demand'
      AND body~'capture_sales_order_payment_requests') confirm_composition_rows,
    count(*) FILTER(WHERE name='queue'
      AND body~'settlement_route_snapshot.*<>.*CASH_DRAWER') queue_rows,
    count(*) FILTER(WHERE name IN('list','detail')
      AND body~'sales_payment_blocks_order_cancel') cancel_read_rows
  FROM definitions
), auto_rows AS (
  SELECT request.*,event.status event_status,event.source_table,event.source_id,
    event.system_event_key,event.amounts,event.root_sales_id,
    (SELECT count(*) FROM public.finance_journals journal
      WHERE journal.company_id=request.company_id
        AND journal.financial_event_id=request.financial_event_id) journal_rows,
    (SELECT count(*) FROM public.sales_payment_verification_audit audit
      WHERE audit.company_id=request.company_id
        AND audit.verification_request_id=request.id
        AND audit.action='AUTO_VERIFY_CASH') auto_audit_rows,
    (SELECT count(*) FROM public.cash_drawer_movements movement
      WHERE movement.company_id=request.company_id
        AND movement.id=request.cash_drawer_movement_id
        AND movement.direction='IN' AND movement.movement_type='SALE_PAYMENT_INTENT'
        AND movement.source_table='sales_payment_verification_requests'
        AND movement.source_id=request.id AND movement.amount=request.amount) cash_in_rows,
    (SELECT count(*) FROM public.cash_drawer_movements movement
      WHERE movement.company_id=request.company_id
        AND movement.source_table='sales_payment_verification_reversal'
        AND movement.source_id=request.id AND movement.direction='OUT'
        AND movement.movement_type='REVERSAL' AND movement.amount=request.amount) reversal_rows
  FROM public.sales_payment_verification_requests request
  LEFT JOIN public.financial_events event ON event.company_id=request.company_id
    AND event.id=request.financial_event_id
  WHERE request.verification_mode='AUTO_CASH'
)
SELECT 'pos_cash_auto_migration_ledger' check_name,
  CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
  abs(count(*)-1)::bigint violation_rows,jsonb_build_object('ledgerRows',count(*)) details
FROM private.kgs_schema_migrations WHERE version='20260923100000'
UNION ALL
SELECT 'pos_cash_auto_column_contract',
  CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,abs(count(*)-1)::bigint,
  jsonb_build_object('rows',count(*)) FROM information_schema.columns
  WHERE table_schema='public' AND table_name='sales_payment_verification_requests'
    AND column_name='verification_mode' AND is_nullable='NO'
UNION ALL
SELECT 'pos_cash_auto_routine_contract',
  CASE WHEN coalesce(cardinality(missing),0)=0 THEN 'PASS' ELSE 'FAIL' END,
  coalesce(cardinality(missing),0)::bigint,
    jsonb_build_object('missing',coalesce(to_jsonb(missing),'[]'::jsonb),'expected',11)
FROM routine_check
UNION ALL
SELECT 'pos_cash_auto_mutation_guard_contract',
  CASE WHEN body~'POS_CASH_MANUAL_VERIFICATION_FORBIDDEN'
    AND body~'PAYMENT_VERIFICATION_MODE_IMMUTABLE' THEN 'PASS' ELSE 'FAIL' END,
  CASE WHEN body~'POS_CASH_MANUAL_VERIFICATION_FORBIDDEN'
    AND body~'PAYMENT_VERIFICATION_MODE_IMMUTABLE' THEN 0 ELSE 1 END::bigint,
  jsonb_build_object('manualCashBlocked',body~'POS_CASH_MANUAL_VERIFICATION_FORBIDDEN',
    'modeImmutable',body~'PAYMENT_VERIFICATION_MODE_IMMUTABLE')
FROM (SELECT pg_get_functiondef(
  'private.trg_odr5_guard_payment_verification()'::regprocedure) body) guard
UNION ALL
SELECT 'pos_cash_auto_deferred_trigger_contract',
  CASE WHEN count(*)=1 AND count(*) FILTER(WHERE trigger_state.tgenabled='O')=1
    AND bool_and(trigger_state.tgdeferrable AND trigger_state.tginitdeferred)
    THEN 'PASS' ELSE 'FAIL' END,
  CASE WHEN count(*)=1 AND count(*) FILTER(WHERE trigger_state.tgenabled='O')=1
    AND bool_and(trigger_state.tgdeferrable AND trigger_state.tginitdeferred)
    THEN 0 ELSE 1 END::bigint,
  jsonb_build_object('rows',count(*),'enabled',count(*) FILTER(WHERE trigger_state.tgenabled='O'))
FROM pg_trigger trigger_state
JOIN pg_class relation ON relation.oid=trigger_state.tgrelid
JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
WHERE namespace.nspname='public' AND relation.relname='sales_payment_verification_requests'
  AND trigger_state.tgname='enforce_no_pending_pos_cash'
UNION ALL
SELECT 'pos_cash_auto_runtime_contract',
  CASE WHEN capture_rows=1 AND cancel_rows=1
    AND confirm_wrapper_rows=1 AND confirm_composition_rows=1 AND queue_rows=1
    AND cancel_read_rows=2 THEN 'PASS' ELSE 'FAIL' END,
  CASE WHEN capture_rows=1 AND cancel_rows=1
    AND confirm_wrapper_rows=1 AND confirm_composition_rows=1 AND queue_rows=1
    AND cancel_read_rows=2 THEN 0 ELSE 1 END::bigint,
  jsonb_build_object('capture',capture_rows,'cancel',cancel_rows,
    'confirmWrapper',confirm_wrapper_rows,
    'confirmComposition',confirm_composition_rows,
    'manualQueue',queue_rows,'cancelReadModels',cancel_read_rows) FROM runtime_contract
UNION ALL
SELECT 'pos_cash_auto_pending_cash_absence',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
  jsonb_build_object('pendingCashRows',count(*))
FROM public.sales_payment_verification_requests
WHERE status='PENDING' AND settlement_route_snapshot='CASH_DRAWER'
UNION ALL
SELECT 'pos_cash_auto_source_contract',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
  jsonb_build_object('invalidRows',count(*)) FROM auto_rows request
WHERE request.settlement_route_snapshot<>'CASH_DRAWER'
  OR request.settlement_account_function_snapshot<>'CASH_DRAWER'
  OR request.status NOT IN('VERIFIED','CANCELED')
  OR request.cash_in_rows<>1 OR request.auto_audit_rows<>1
UNION ALL
SELECT 'pos_cash_auto_event_contract',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
  jsonb_build_object('invalidRows',count(*)) FROM auto_rows request
WHERE request.financial_event_id IS NULL
  OR request.source_table<>'sales_payment_verification_requests'
  OR request.source_id<>request.id OR request.root_sales_id<>request.sales_id
  OR request.system_event_key<>'SALE_PAYMENT_VERIFIED'
  OR round((request.amounts->>'settlementAmount')::numeric,4)<>request.amount
  OR request.amounts->>'sourceAccountFunction'<>'CASH_DRAWER'
  OR (request.status='VERIFIED' AND request.event_status NOT IN(
      'HOLD'::public.event_status,'POSTED'::public.event_status,'CANCELED'::public.event_status))
  OR (request.status='CANCELED' AND request.event_status<>'CANCELED'::public.event_status)
UNION ALL
SELECT 'pos_cash_auto_cancel_reconciliation',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
  jsonb_build_object('invalidRows',count(*)) FROM auto_rows request
WHERE (request.status='CANCELED' AND request.reversal_rows<>1)
   OR (request.status='VERIFIED' AND request.reversal_rows<>0)
   OR request.reversal_rows>1
UNION ALL
SELECT 'pos_cash_auto_posted_journal_reconciliation',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
  jsonb_build_object('invalidRows',count(*)) FROM auto_rows request
WHERE (request.event_status='POSTED'::public.event_status AND request.journal_rows<>1)
   OR (request.event_status='HOLD'::public.event_status AND request.journal_rows<>0)
UNION ALL
SELECT 'pos_cash_auto_permission_contract',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
  jsonb_build_object('authenticatedPrivateExecuteRows',count(*))
FROM information_schema.routine_privileges privilege
WHERE privilege.specific_schema='private'
  AND privilege.routine_name IN('auto_verify_pos_cash_payment_request',
    'sales_payment_blocks_order_cancel','capture_sales_order_payment_requests',
    'cancel_pending_sales_order_payments')
  AND privilege.grantee IN('PUBLIC','anon','authenticated')
  AND privilege.privilege_type='EXECUTE'
UNION ALL
SELECT 'pos_cash_auto_runtime_inventory','INFO',0,
  jsonb_build_object('autoCash',count(*),
    'verified',count(*) FILTER(WHERE status='VERIFIED'),
    'canceled',count(*) FILTER(WHERE status='CANCELED'),
    'holdEvents',count(*) FILTER(WHERE event_status='HOLD'::public.event_status),
    'postedEvents',count(*) FILTER(WHERE event_status='POSTED'::public.event_status))
FROM auto_rows;
