-- Read-only Production preflight for POS Cash auto-verification.
-- Stop when any row is BLOCKER. INFO rows are inventory only.
WITH required_relations(name) AS (
  VALUES ('sales_payment_verification_requests'),
    ('sales_payment_verification_audit'),('cash_drawer_movements'),
    ('financial_events'),('transaction_categories'),('sales_headers'),
    ('cashier_sessions'),('finance_posting_queue_runs'),('finance_journals'),
    ('sales_invoice_snapshots'),('sales_stock_reservations')
), relation_check AS (
  SELECT array_agg(name ORDER BY name) FILTER (WHERE to_regclass('public.'||name) IS NULL) missing
  FROM required_relations
), required_routines(signature) AS (
  VALUES ('private.capture_sales_order_payment_requests(uuid,uuid,uuid)'),
    ('private.cancel_pending_sales_order_payments(uuid,uuid,uuid,uuid,text)'),
    ('private.post_odr_payment_financial_event_core(uuid,uuid,bigint,uuid)'),
    ('public.review_sales_payment_verification(uuid,bigint,text,text,uuid)'),
    ('public.get_finance_sales_payment_verifications()'),
    ('public.confirm_pos_sales_order(uuid,bigint,uuid,text)'),
    ('private.confirm_pos_sales_order_before_revision_core(uuid,bigint,uuid,text)'),
    ('public.close_cashier_session(uuid,bigint,numeric)'),
    ('public.get_sales_documents()'),('public.get_sales_invoice_document(uuid)'),
    ('private.resolve_sales_invoice_display_date(jsonb,jsonb,timestamptz,text)'),
    ('private.acp5e_get_sales_invoice_document_core(uuid)'),
    ('private.odr5d_settlement_account_function(public.payment_methods)'),
    ('private.calculate_cashier_session_expected_cash(uuid,uuid)')
), routine_check AS (
  SELECT array_agg(signature ORDER BY signature) FILTER (
    WHERE to_regprocedure(signature) IS NULL) missing FROM required_routines
), dependency_check AS (
  SELECT required.version,ledger.version installed
  FROM (VALUES ('20260828240000'),('20260829130000'),('20260830120000'),
    ('20260903120000'),('20260907100000')) required(version)
  LEFT JOIN private.kgs_schema_migrations ledger ON ledger.version=required.version
), definitions AS (
  SELECT 'capture' name,pg_get_functiondef(
      'private.capture_sales_order_payment_requests(uuid,uuid,uuid)'::regprocedure) body
  UNION ALL SELECT 'cancel',pg_get_functiondef(
      'private.cancel_pending_sales_order_payments(uuid,uuid,uuid,uuid,text)'::regprocedure)
  UNION ALL SELECT 'review',pg_get_functiondef(
      'public.review_sales_payment_verification(uuid,bigint,text,text,uuid)'::regprocedure)
  UNION ALL SELECT 'confirm',pg_get_functiondef(
      'public.confirm_pos_sales_order(uuid,bigint,uuid,text)'::regprocedure)
  UNION ALL SELECT 'confirm_composition',pg_get_functiondef(
      'private.confirm_pos_sales_order_before_revision_core(uuid,bigint,uuid,text)'::regprocedure)
  UNION ALL SELECT 'close',pg_get_functiondef(
      'public.close_cashier_session(uuid,bigint,numeric)'::regprocedure)
), runtime_anchor AS (
  SELECT count(*) FILTER (WHERE name='capture' AND body~'SALE_PAYMENT_INTENT'
      AND body~'IDEMPOTENCY_PAYLOAD_CONFLICT') capture_rows,
    count(*) FILTER (WHERE name='cancel'
      AND body~'SALES_ORDER_CASH_REFUND_REQUIRES_CURRENT_OPEN_SESSION') cancel_rows,
    count(*) FILTER (WHERE name='review' AND body~'MAKER_CHECKER_REQUIRED'
      AND body~'SALE_PAYMENT_VERIFIED') review_rows,
    count(*) FILTER (WHERE name='confirm'
      AND body~'private.confirm_pos_sales_order_before_revision_core'
      AND body~'sales_order_revisions') confirm_wrapper_rows,
    count(*) FILTER (WHERE name='confirm_composition'
      AND body~'private.confirm_pos_sales_order_core'
      AND body~'ensure_confirmed_order_invoice_identity'
      AND body~'ensure_confirmed_order_documents'
      AND body~'refresh_sales_order_procurement_demand'
      AND body~'capture_sales_order_payment_requests') confirm_composition_rows,
    count(*) FILTER (WHERE name='close'
      AND body~'paymentVerificationDeferred') close_rows
  FROM definitions
), pending_cash AS (
  SELECT request.*,sale.id sale_row,sale.order_runtime_status,movement.id movement_row,
    movement.company_id movement_company_id,movement.cashier_session_id movement_session_id,
    movement.store_id movement_store_id,movement.pos_terminal_id movement_pos_id,
    movement.amount movement_amount,movement.direction movement_direction,
    movement.movement_type movement_type,movement.source_table movement_source_table,
    movement.source_id movement_source_id,session.id session_row
  FROM public.sales_payment_verification_requests request
  LEFT JOIN public.sales_headers sale ON sale.company_id=request.company_id
    AND sale.id=request.sales_id
  LEFT JOIN public.cash_drawer_movements movement
    ON movement.company_id=request.company_id AND movement.id=request.cash_drawer_movement_id
  LEFT JOIN public.cashier_sessions session ON session.company_id=request.company_id
    AND session.id=request.cashier_session_id
  WHERE request.status='PENDING' AND request.settlement_route_snapshot='CASH_DRAWER'
), invalid_pending_cash AS (
  SELECT * FROM pending_cash request WHERE request.sale_row IS NULL
    OR request.order_runtime_status='CANCELED'
    OR request.cash_drawer_reversal_movement_id IS NOT NULL
    OR request.settlement_account_function_snapshot<>'CASH_DRAWER'
    OR request.movement_row IS NULL OR request.session_row IS NULL
    OR request.movement_company_id<>request.company_id
    OR request.movement_session_id<>request.cashier_session_id
    OR request.movement_store_id<>request.store_id
    OR request.movement_pos_id IS DISTINCT FROM request.pos_terminal_id
    OR request.movement_amount<>request.amount OR request.movement_direction<>'IN'
    OR request.movement_type<>'SALE_PAYMENT_INTENT'
    OR request.movement_source_table<>'sales_payment_verification_requests'
    OR request.movement_source_id<>request.id
), category_scope AS (
  SELECT pending.company_id,count(category.id) active_categories
  FROM (SELECT DISTINCT company_id FROM pending_cash) pending
  LEFT JOIN public.transaction_categories category ON category.company_id=pending.company_id
    AND category.system_key='SALE_PAYMENT_VERIFIED' AND category.is_active
  GROUP BY pending.company_id
)
SELECT 'pos_cash_auto_required_relations' check_name,
  CASE WHEN coalesce(cardinality(missing),0)=0 THEN 'PASS' ELSE 'BLOCKER' END status,
  coalesce(cardinality(missing),0)::bigint violation_rows,
  jsonb_build_object('missing',coalesce(to_jsonb(missing),'[]'::jsonb)) details
FROM relation_check
UNION ALL
SELECT 'pos_cash_auto_required_routines',
  CASE WHEN coalesce(cardinality(missing),0)=0 THEN 'PASS' ELSE 'BLOCKER' END,
  coalesce(cardinality(missing),0)::bigint,
  jsonb_build_object('missing',coalesce(to_jsonb(missing),'[]'::jsonb))
FROM routine_check
UNION ALL
SELECT 'pos_cash_auto_dependency_ledger',
  CASE WHEN count(*) FILTER(WHERE installed IS NULL)=0 THEN 'PASS' ELSE 'BLOCKER' END,
  count(*) FILTER(WHERE installed IS NULL)::bigint,
  jsonb_build_object('missing',coalesce(jsonb_agg(version ORDER BY version)
    FILTER(WHERE installed IS NULL),'[]'::jsonb)) FROM dependency_check
UNION ALL
SELECT 'pos_cash_auto_runtime_anchor',
  CASE WHEN capture_rows=1 AND cancel_rows=1 AND review_rows=1
    AND confirm_wrapper_rows=1 AND confirm_composition_rows=1
    AND close_rows=1 THEN 'PASS' ELSE 'BLOCKER' END,
  CASE WHEN capture_rows=1 AND cancel_rows=1 AND review_rows=1
    AND confirm_wrapper_rows=1 AND confirm_composition_rows=1
    AND close_rows=1 THEN 0 ELSE 1 END::bigint,
  jsonb_build_object('capture',capture_rows,'cancel',cancel_rows,'review',review_rows,
    'confirmWrapper',confirm_wrapper_rows,
    'confirmComposition',confirm_composition_rows,'close',close_rows) FROM runtime_anchor
UNION ALL
SELECT 'pos_cash_auto_object_collision',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
  jsonb_build_object('existing',coalesce(jsonb_agg(name),'[]'::jsonb))
FROM (
  SELECT 'sales_payment_verification_requests.verification_mode' name WHERE EXISTS(
    SELECT 1 FROM information_schema.columns WHERE table_schema='public'
      AND table_name='sales_payment_verification_requests' AND column_name='verification_mode')
  UNION ALL SELECT 'private.auto_verify_pos_cash_payment_request(uuid,uuid,uuid)' WHERE
    to_regprocedure('private.auto_verify_pos_cash_payment_request(uuid,uuid,uuid)') IS NOT NULL
  UNION ALL SELECT 'migration:20260923100000' WHERE EXISTS(
    SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260923100000')
) collision
UNION ALL
SELECT 'pos_cash_auto_pending_source_shape',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
  jsonb_build_object('invalidRows',count(*)) FROM invalid_pending_cash
UNION ALL
SELECT 'pos_cash_auto_category_shape',
  CASE WHEN count(*) FILTER(WHERE active_categories<>1)=0 THEN 'PASS' ELSE 'BLOCKER' END,
  count(*) FILTER(WHERE active_categories<>1)::bigint,
  jsonb_build_object('invalidCompanies',coalesce(jsonb_agg(jsonb_build_object(
    'companyId',company_id,'activeCategories',active_categories))
    FILTER(WHERE active_categories<>1),'[]'::jsonb)) FROM category_scope
UNION ALL
SELECT 'pos_cash_auto_active_finance_queue',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
  jsonb_build_object('runRows',count(*)) FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
UNION ALL
SELECT 'pos_cash_auto_pending_inventory','INFO',0,
  jsonb_build_object('pendingCash',count(*) FILTER(
      WHERE status='PENDING' AND settlement_route_snapshot='CASH_DRAWER'),
    'pendingNonCash',count(*) FILTER(
      WHERE status='PENDING' AND settlement_route_snapshot<>'CASH_DRAWER'),
    'verifiedCash',count(*) FILTER(
      WHERE status='VERIFIED' AND settlement_route_snapshot='CASH_DRAWER'))
FROM public.sales_payment_verification_requests;
