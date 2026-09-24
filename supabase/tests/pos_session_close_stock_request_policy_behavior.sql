-- Rollback-only behavior for the default-OFF Session-close Stock Request policy.
-- Self-created Sessions/Demands prove policy snapshots without mutating
-- Stock, FIFO, Finance, Purchase Orders, or historical Stock Requests.
BEGIN;

DO $test$
DECLARE v_company uuid;v_store uuid;v_pos uuid;v_warehouse uuid;
  v_actor uuid;v_non_admin uuid;v_off_session uuid:=gen_random_uuid();
  v_on_session uuid:=gen_random_uuid();v_off_demand uuid:=gen_random_uuid();
  v_on_demand uuid:=gen_random_uuid();v_version bigint;v_new_version bigint;
  v_original boolean;v_target boolean;v_result jsonb;v_before_requests bigint;
  v_after_requests bigint;v_audit_before bigint;v_audit_after bigint;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260924110000') THEN
    RAISE EXCEPTION 'TEST_PHASE_FAILED [DEPENDENCY]: migration 20260924110000 missing';
  END IF;

  SELECT company.id,store.id,terminal.id,warehouse.id INTO
    v_company,v_store,v_pos,v_warehouse
  FROM public.companies company
  JOIN public.company_purchase_replenishment_settings setting
    ON setting.company_id=company.id
  JOIN public.stores store ON store.company_id=company.id
    AND store.status='ACTIVE'
  JOIN public.pos_terminals terminal ON terminal.company_id=company.id
    AND terminal.store_id=store.id AND terminal.status='ACTIVE'
  JOIN public.warehouses warehouse ON warehouse.company_id=company.id
    AND warehouse.is_active AND warehouse.is_sale_source
    AND (warehouse.store_id=store.id OR warehouse.store_id IS NULL)
  WHERE company.status='ACTIVE'
  ORDER BY company.id,store.id,terminal.id,warehouse.id LIMIT 1;
  SELECT profile.id INTO v_actor FROM public.profiles profile
  WHERE profile.role='super_admin' ORDER BY profile.id LIMIT 1;
  SELECT profile.id INTO v_non_admin FROM public.profiles profile
  WHERE profile.role<>'super_admin' ORDER BY profile.id LIMIT 1;
  IF v_company IS NULL OR v_actor IS NULL THEN
    RAISE EXCEPTION 'TEST_PHASE_FAILED [FIXTURE]: active Company/POS/Warehouse and Super Admin required';
  END IF;

  INSERT INTO public.user_active_company_contexts(user_id,company_id,selection_source)
  VALUES(v_actor,v_company,'POS_SESSION_REQUEST_POLICY_TEST')
  ON CONFLICT(user_id) DO UPDATE SET company_id=excluded.company_id,
    selection_source=excluded.selection_source,updated_at=clock_timestamp();
  PERFORM set_config('request.jwt.claim.sub',v_actor::text,true);
  PERFORM set_config('request.jwt.claim.role','authenticated',true);

  SELECT setting.master_version,setting.session_close_stock_request_enabled
  INTO v_version,v_original
  FROM public.company_purchase_replenishment_settings setting
  WHERE setting.company_id=v_company FOR UPDATE;
  v_target:=NOT v_original;
  SELECT public.set_session_close_stock_request_policy(v_target,v_version)
  INTO v_result;
  v_new_version:=(v_result->>'masterVersion')::bigint;
  IF (v_result->>'changed')::boolean IS NOT TRUE
    OR (v_result->>'enabled')::boolean IS DISTINCT FROM v_target
    OR v_new_version<>v_version+1 THEN
    RAISE EXCEPTION 'TEST_PHASE_FAILED [SETTER]: audited policy change mismatch';
  END IF;
  SELECT count(*) INTO v_audit_before
  FROM public.company_purchase_replenishment_setting_audit audit
  WHERE audit.company_id=v_company
    AND audit.action='SESSION_CLOSE_STOCK_REQUEST_POLICY_CHANGE';
  SELECT public.set_session_close_stock_request_policy(v_target,v_new_version)
  INTO v_result;
  SELECT count(*) INTO v_audit_after
  FROM public.company_purchase_replenishment_setting_audit audit
  WHERE audit.company_id=v_company
    AND audit.action='SESSION_CLOSE_STOCK_REQUEST_POLICY_CHANGE';
  IF (v_result->>'changed')::boolean IS NOT FALSE
    OR v_audit_after<>v_audit_before THEN
    RAISE EXCEPTION 'TEST_PHASE_FAILED [RETRY]: exact policy retry wrote audit';
  END IF;
  BEGIN
    PERFORM public.set_session_close_stock_request_policy(v_original,v_version);
    RAISE EXCEPTION 'TEST_PHASE_FAILED [STALE]: stale version accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%MASTER_VERSION_CONFLICT%' THEN RAISE; END IF;
  END;

  IF v_non_admin IS NOT NULL THEN
    INSERT INTO public.user_active_company_contexts(user_id,company_id,selection_source)
    VALUES(v_non_admin,v_company,'POS_SESSION_REQUEST_POLICY_TEST')
    ON CONFLICT(user_id) DO UPDATE SET company_id=excluded.company_id,
      selection_source=excluded.selection_source,updated_at=clock_timestamp();
    PERFORM set_config('request.jwt.claim.sub',v_non_admin::text,true);
    BEGIN
      PERFORM public.set_session_close_stock_request_policy(
        v_original,v_new_version);
      RAISE EXCEPTION 'TEST_PHASE_FAILED [ROLE]: non-Super Admin accepted';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%SUPER_ADMIN_REQUIRED%' THEN RAISE; END IF;
    END;
    PERFORM set_config('request.jwt.claim.sub',v_actor::text,true);
  END IF;

  INSERT INTO public.cashier_sessions(
    id,session_code,cashier_id,opened_at,closed_at,opening_balance,
    expected_cash,actual_cash,difference,status,company_id,store_id,pos_id,
    sales_warehouse_id,opening_cash_actual,closing_cash_actual,master_version,
    updated_at,stock_request_on_close_enabled_snapshot,
    stock_request_on_close_policy_decided_at)
  VALUES
    (v_off_session,'TEST-OFF-'||left(replace(v_off_session::text,'-',''),16),
      v_actor,clock_timestamp()-interval '1 hour',clock_timestamp(),0,0,0,0,
      'CLOSED',v_company,v_store,v_pos,v_warehouse,0,0,1,clock_timestamp(),
      false,clock_timestamp()),
    (v_on_session,'TEST-ON-'||left(replace(v_on_session::text,'-',''),16),
      v_actor,clock_timestamp()-interval '1 hour',clock_timestamp(),0,0,0,0,
      'CLOSED',v_company,v_store,v_pos,v_warehouse,0,0,1,clock_timestamp(),
      true,clock_timestamp());
  INSERT INTO public.sales_order_procurement_demands(
    id,company_id,store_id,warehouse_id,cashier_session_id,status,
    total_demand_base_qty,total_released_base_qty,session_closed_at,created_by)
  VALUES
    (v_off_demand,v_company,v_store,v_warehouse,v_off_session,'FROZEN',
      1,0,clock_timestamp(),v_actor),
    (v_on_demand,v_company,v_store,v_warehouse,v_on_session,'CLOSED',
      0,0,clock_timestamp(),v_actor);

  SELECT count(*) INTO v_before_requests
  FROM public.stock_request_documents request
  WHERE request.requesting_session_id IN(v_off_session,v_on_session);
  SELECT private.ensure_session_procurement_stock_request(
    v_company,v_off_session,v_actor) INTO v_result;
  IF v_result->>'skipReason'<>'COMPANY_POLICY_DISABLED'
    OR (v_result->>'stockRequestCreated')::boolean
    OR (v_result->>'sessionCloseStockRequestEnabled')::boolean THEN
    RAISE EXCEPTION 'TEST_PHASE_FAILED [OFF]: disabled snapshot created or exposed a request';
  END IF;

  -- A later Company policy change cannot alter a Session decision snapshot.
  UPDATE public.company_purchase_replenishment_settings SET
    session_close_stock_request_enabled=true WHERE company_id=v_company;
  SELECT private.ensure_session_procurement_stock_request(
    v_company,v_off_session,v_actor) INTO v_result;
  IF v_result->>'skipReason'<>'COMPANY_POLICY_DISABLED' THEN
    RAISE EXCEPTION 'TEST_PHASE_FAILED [SNAPSHOT]: closed Session followed live policy';
  END IF;

  SELECT private.ensure_session_procurement_stock_request(
    v_company,v_on_session,v_actor) INTO v_result;
  IF v_result->>'skipReason'<>'NO_OUTSTANDING_DEMAND'
    OR (v_result->>'sessionCloseStockRequestEnabled')::boolean IS NOT TRUE
    OR (v_result->>'stockRequestCreated')::boolean THEN
    RAISE EXCEPTION 'TEST_PHASE_FAILED [ON]: enabled zero-demand boundary invalid';
  END IF;
  SELECT count(*) INTO v_after_requests
  FROM public.stock_request_documents request
  WHERE request.requesting_session_id IN(v_off_session,v_on_session);
  IF v_before_requests<>0 OR v_after_requests<>0 THEN
    RAISE EXCEPTION 'TEST_PHASE_FAILED [BOUNDARY]: fixture created Stock Request';
  END IF;

  IF pg_get_functiondef(
      'public.close_cashier_session(uuid,bigint,numeric)'::regprocedure)
      !~'stock_request_on_close_enabled_snapshot'
    OR pg_get_functiondef(
      'public.close_cashier_session(uuid,bigint,numeric)'::regprocedure)
      !~'odr5d_close_cashier_session_legacy'
    OR pg_get_functiondef(
      'private.ensure_session_procurement_stock_request(uuid,uuid,uuid)'::regprocedure)
      ~'product_stocks|product_batches|stock_movements|financial_events|supplier_order' THEN
    RAISE EXCEPTION 'TEST_PHASE_FAILED [RUNTIME]: close snapshot or boundary drift';
  END IF;
END
$test$;

SELECT 'pos_session_close_stock_request_policy_behavior' check_name,
  'PASS' status,0::bigint violation_rows,jsonb_build_object('tested',ARRAY[
    'default-OFF Company policy setter','exact policy retry',
    'stale version rejection','Super Admin boundary',
    'disabled Session snapshot skips request',
    'closed Session snapshot ignores later Company policy change',
    'enabled Session with no outstanding demand creates no request',
    'no Stock/FIFO/Finance/PO runtime dependency',
    'all fixture writes rolled back']) details;
ROLLBACK;
