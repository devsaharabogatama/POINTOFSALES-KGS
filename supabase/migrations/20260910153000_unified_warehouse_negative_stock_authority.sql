-- Cutover Step 4A/6: one negative-stock authority for Retail POS and Backoffice.
-- New shortage decisions depend only on the selected sale-source Warehouse.
-- Historical user/policy evidence remains immutable and readable.
BEGIN;

DO $guard$
DECLARE v_confirm text;v_composition text;v_public_confirm text;v_dispatch text;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260910152000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: cutover payment-term boundary required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260910153000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260910153000';
  END IF;
  IF EXISTS(SELECT 1 FROM public.sales_process_cutover_plans
      WHERE status IN('DRAFT','PREVIEWED','APPLYING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: cancel open cutover plan before negative authority upgrade';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
      WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
      WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
  IF to_regprocedure('private.confirm_pos_sales_order_core(uuid,bigint,uuid,text)') IS NULL
    OR to_regprocedure('private.confirm_pos_sales_order_before_revision_core(uuid,bigint,uuid,text)') IS NULL
    OR to_regprocedure('public.confirm_pos_sales_order(uuid,bigint,uuid,text)') IS NULL
    OR to_regprocedure('private.dispatch_sales_delivery_stock_core_odr3c(uuid,bigint,uuid,jsonb,text)') IS NULL
    OR to_regprocedure('private.authorize_pos_negative_stock(uuid,uuid,uuid,uuid,jsonb,text)') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical Retail runtime missing';
  END IF;
  IF EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='public'
      AND table_name='sales_stock_reservation_lines'
      AND column_name IN('negative_authority_source','negative_warehouse_version'))
    OR EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='public'
      AND table_name='pos_negative_stock_authorizations'
      AND column_name IN('authority_source','warehouse_version')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: warehouse authority column collision';
  END IF;
  IF EXISTS(SELECT 1 FROM public.sales_stock_reservation_lines
      WHERE shortage_base_qty>0
        AND (negative_policy_version IS NULL OR negative_permission_version IS NULL))
    OR EXISTS(SELECT 1 FROM public.pos_negative_stock_authorizations
      WHERE permission_id IS NULL OR NULLIF(btrim(reason),'') IS NULL
        OR policy_version<=0 OR permission_version<=0) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: legacy negative evidence invalid';
  END IF;
  SELECT pg_get_functiondef(
    'private.confirm_pos_sales_order_core(uuid,bigint,uuid,text)'::regprocedure)
  INTO v_confirm;
  SELECT pg_get_functiondef(
    'private.confirm_pos_sales_order_before_revision_core(uuid,bigint,uuid,text)'::regprocedure)
  INTO v_composition;
  SELECT pg_get_functiondef(
    'public.confirm_pos_sales_order(uuid,bigint,uuid,text)'::regprocedure)
  INTO v_public_confirm;
  SELECT pg_get_functiondef(
    'private.dispatch_sales_delivery_stock_core_odr3c(uuid,bigint,uuid,jsonb,text)'::regprocedure)
  INTO v_dispatch;
  IF v_confirm!~'pos_negative_stock_permissions'
    OR v_confirm!~'company_negative_limit_base_qty'
    OR v_composition!~'private.confirm_pos_sales_order_core'
    OR v_composition!~'ensure_confirmed_order_invoice_identity'
    OR v_composition!~'ensure_confirmed_order_documents'
    OR v_composition!~'refresh_sales_order_procurement_demand'
    OR v_composition!~'capture_sales_order_payment_requests'
    OR v_public_confirm!~'private.confirm_pos_sales_order_before_revision_core'
    OR v_public_confirm!~'sales_order_revisions'
    OR v_dispatch!~'NEGATIVE_STOCK_PERMISSION_SNAPSHOT_MISSING' THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical Retail call chain drift';
  END IF;
END
$guard$;

ALTER TABLE public.sales_stock_reservation_lines
  ADD COLUMN negative_authority_source text,
  ADD COLUMN negative_warehouse_version bigint;

UPDATE public.sales_stock_reservation_lines
SET negative_authority_source='LEGACY_USER_POLICY'
WHERE shortage_base_qty>0;

ALTER TABLE public.sales_stock_reservation_lines
  DROP CONSTRAINT sales_stock_reservation_lines_negative_snapshot_check,
  ADD CONSTRAINT sales_stock_reservation_lines_negative_snapshot_check CHECK(
    (shortage_base_qty=0 AND negative_authority_source IS NULL
      AND negative_policy_version IS NULL AND negative_permission_version IS NULL
      AND negative_warehouse_version IS NULL)
    OR (shortage_base_qty>0 AND negative_authority_source='LEGACY_USER_POLICY'
      AND negative_policy_version>0 AND negative_permission_version>0
      AND negative_warehouse_version IS NULL)
    OR (shortage_base_qty>0 AND negative_authority_source='WAREHOUSE'
      AND negative_policy_version IS NULL AND negative_permission_version IS NULL
      AND negative_warehouse_version>0));

ALTER TABLE public.pos_negative_stock_authorizations
  ADD COLUMN authority_source text,
  ADD COLUMN warehouse_version bigint;

UPDATE public.pos_negative_stock_authorizations
SET authority_source='LEGACY_USER_POLICY';

ALTER TABLE public.pos_negative_stock_authorizations
  ALTER COLUMN authority_source SET NOT NULL,
  ALTER COLUMN permission_id DROP NOT NULL,
  ALTER COLUMN reason DROP NOT NULL,
  ALTER COLUMN policy_version DROP NOT NULL,
  ALTER COLUMN permission_version DROP NOT NULL,
  DROP CONSTRAINT pos_negative_stock_authorizations_shape,
  ADD CONSTRAINT pos_negative_stock_authorizations_shape CHECK(
    requested_base_qty>0 AND available_base_qty>=0 AND shortage_base_qty>0
    AND balance_after_base_qty<0 AND provisional_unit_cost>=0
    AND ((authority_source='LEGACY_USER_POLICY' AND permission_id IS NOT NULL
      AND NULLIF(btrim(reason),'') IS NOT NULL AND policy_version>0
      AND permission_version>0 AND warehouse_version IS NULL)
    OR (authority_source='WAREHOUSE' AND permission_id IS NULL AND reason IS NULL
      AND policy_version IS NULL AND permission_version IS NULL
      AND warehouse_version>0)));

COMMENT ON COLUMN public.sales_stock_reservation_lines.negative_authority_source IS
  'LEGACY_USER_POLICY preserves historical POS evidence; WAREHOUSE is the sole authority for new shortages.';
COMMENT ON COLUMN public.pos_negative_stock_authorizations.authority_source IS
  'Authorization evidence model. New Retail and Backoffice sales use WAREHOUSE without per-user reason or limit.';

CREATE OR REPLACE FUNCTION private.authorize_pos_negative_stock(
  p_company_id uuid,p_sales_id uuid,p_warehouse_id uuid,
  p_actor_id uuid,p_shortages jsonb,p_reason text
) RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_item jsonb;v_product uuid;v_detail uuid;v_warehouse_version bigint;
  v_requested numeric(24,6);v_available numeric(24,6);v_shortage numeric(24,6);
  v_balance numeric(24,6);v_cost numeric(20,4);
BEGIN
  IF jsonb_typeof(p_shortages)<>'array' OR jsonb_array_length(p_shortages)=0 THEN
    RETURN false;
  END IF;
  SELECT warehouse.master_version INTO v_warehouse_version
  FROM public.warehouses warehouse
  WHERE warehouse.company_id=p_company_id AND warehouse.id=p_warehouse_id
    AND warehouse.is_active AND warehouse.is_sale_source
    AND warehouse.allow_negative_stock FOR SHARE;
  IF NOT FOUND THEN RETURN false; END IF;

  FOR v_item IN SELECT value FROM jsonb_array_elements(p_shortages)
  LOOP
    v_product:=(v_item->>'productId')::uuid;
    SELECT sum(requirement.quantity_base),min(requirement.sales_detail_id::text)::uuid
    INTO v_requested,v_detail FROM public.sale_stock_requirements requirement
    WHERE requirement.company_id=p_company_id AND requirement.sales_id=p_sales_id
      AND requirement.stock_product_id=v_product;
    SELECT GREATEST(LEAST(COALESCE(stock.stock_qty,0),COALESCE((
      SELECT sum(batch.qty_remaining) FROM public.product_batches batch
      WHERE batch.company_id=p_company_id AND batch.product_id=v_product
        AND batch.warehouse_id=p_warehouse_id AND batch.qty_remaining>0),0)),0),
      COALESCE(stock.stock_qty,0)-v_requested
    INTO v_available,v_balance FROM (SELECT 1) seed
    LEFT JOIN public.product_stocks stock ON stock.company_id=p_company_id
      AND stock.product_id=v_product AND stock.warehouse_id=p_warehouse_id;
    v_shortage:=v_requested-v_available;
    IF v_shortage<=0 OR v_balance>=0 THEN CONTINUE; END IF;
    v_cost:=private.resolve_pos_negative_stock_provisional_cost(
      p_company_id,v_product,p_warehouse_id);
    INSERT INTO public.pos_negative_stock_authorizations(
      company_id,sales_id,sales_detail_id,stock_product_id,warehouse_id,
      permission_id,actor_id,reason,requested_base_qty,available_base_qty,
      shortage_base_qty,balance_after_base_qty,provisional_unit_cost,
      policy_version,permission_version,authority_source,warehouse_version)
    VALUES(p_company_id,p_sales_id,v_detail,v_product,p_warehouse_id,NULL,
      p_actor_id,NULL,v_requested,v_available,v_shortage,v_balance,v_cost,
      NULL,NULL,'WAREHOUSE',v_warehouse_version);
  END LOOP;
  RETURN EXISTS(SELECT 1 FROM public.pos_negative_stock_authorizations authz
    WHERE authz.company_id=p_company_id AND authz.sales_id=p_sales_id);
END
$$;

CREATE OR REPLACE FUNCTION private.confirm_pos_sales_order_core(
  p_sales_id uuid,p_master_version bigint,p_idempotency_key uuid,
  p_negative_stock_reason text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
  v_sale public.sales_headers%rowtype;v_warehouse uuid;v_warehouse_row public.warehouses%rowtype;
  v_reservation uuid;v_total numeric(24,6);v_product record;v_requirement record;
  v_on_hand numeric(24,6);v_pos_reserved numeric(24,6);v_backoffice_reserved numeric(24,6);
  v_available numeric(24,6);v_available_remaining numeric(24,6);v_line_available numeric(24,6);
  v_shortage numeric(24,6);v_now timestamptz:=clock_timestamp();
  v_line_count integer:=0;v_shortage_count integer:=0;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
  IF p_idempotency_key IS NULL THEN RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED'; END IF;
  IF EXISTS(SELECT 1 FROM public.sales_headers other_sale
    WHERE other_sale.company_id=v_company
      AND other_sale.confirmation_idempotency_key=p_idempotency_key
      AND other_sale.id<>p_sales_id) THEN RAISE EXCEPTION 'IDEMPOTENCY_PAYLOAD_CONFLICT'; END IF;
  SELECT sale.* INTO v_sale FROM public.sales_headers sale
  WHERE sale.company_id=v_company AND sale.id=p_sales_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'SALES_ORDER_NOT_FOUND'; END IF;
  IF v_sale.confirmation_idempotency_key=p_idempotency_key
    AND v_sale.order_runtime_status IN('CONFIRMED','RESERVED') THEN
    SELECT reservation.id INTO v_reservation FROM public.sales_stock_reservations reservation
    WHERE reservation.company_id=v_company AND reservation.sales_id=p_sales_id;
    IF v_reservation IS NULL THEN RAISE EXCEPTION 'RESERVATION_STATE_MISMATCH'; END IF;
    RETURN jsonb_build_object('salesId',p_sales_id,'reservationId',v_reservation,
      'orderRuntimeStatus',v_sale.order_runtime_status,'masterVersion',v_sale.master_version,
      'exactRetry',true);
  END IF;
  IF v_sale.document_status<>'DRAFT'
    OR v_sale.order_runtime_status NOT IN('DRAFT_INPUT','SCHEDULED') THEN
    RAISE EXCEPTION 'SALES_ORDER_FINAL';
  END IF;
  IF v_sale.master_version IS DISTINCT FROM p_master_version THEN
    RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.cashier_sessions session
    WHERE session.company_id=v_company AND session.cashier_id=v_actor
      AND session.store_id=v_sale.store_id AND session.status='OPEN'::public.session_status) THEN
    RAISE EXCEPTION 'OPEN_CASHIER_SESSION_REQUIRED';
  END IF;
  SELECT session.sales_warehouse_id INTO v_warehouse FROM public.cashier_sessions session
  WHERE session.company_id=v_company AND session.id=v_sale.session_id;
  v_warehouse:=COALESCE(v_sale.sales_warehouse_id,v_warehouse);
  SELECT warehouse.* INTO v_warehouse_row FROM public.warehouses warehouse
  WHERE warehouse.company_id=v_company AND warehouse.id=v_warehouse
    AND warehouse.is_active AND warehouse.is_sale_source FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'WAREHOUSE_SCOPE_DENIED'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.sale_stock_requirements requirement
    WHERE requirement.company_id=v_company AND requirement.sales_id=p_sales_id) THEN
    RAISE EXCEPTION 'SALES_ORDER_REQUIREMENT_MISSING';
  END IF;
  SELECT sum(requirement.quantity_base) INTO v_total
  FROM public.sale_stock_requirements requirement
  WHERE requirement.company_id=v_company AND requirement.sales_id=p_sales_id;
  INSERT INTO public.sales_stock_reservations(company_id,sales_id,warehouse_id,
    total_reserved_base_qty,confirmation_idempotency_key,confirmed_by,confirmed_at)
  VALUES(v_company,p_sales_id,v_warehouse,v_total,p_idempotency_key,v_actor,v_now)
  RETURNING id INTO v_reservation;

  FOR v_product IN
    SELECT requirement.stock_product_id,sum(requirement.quantity_base) requested_base_qty
    FROM public.sale_stock_requirements requirement
    WHERE requirement.company_id=v_company AND requirement.sales_id=p_sales_id
    GROUP BY requirement.stock_product_id ORDER BY requirement.stock_product_id
  LOOP
    PERFORM pg_advisory_xact_lock(hashtextextended(v_company::text||':'||
      v_warehouse::text||':'||v_product.stock_product_id::text,0));
    SELECT stock.stock_qty INTO v_on_hand FROM public.product_stocks stock
    WHERE stock.company_id=v_company AND stock.warehouse_id=v_warehouse
      AND stock.product_id=v_product.stock_product_id FOR UPDATE;
    v_on_hand:=COALESCE(v_on_hand,0);
    SELECT COALESCE(sum(line.reserved_base_qty-line.released_base_qty-
      line.dispatched_base_qty),0) INTO v_pos_reserved
    FROM public.sales_stock_reservation_lines line
    JOIN public.sales_stock_reservations reservation
      ON reservation.company_id=line.company_id AND reservation.id=line.reservation_id
    WHERE line.company_id=v_company AND line.warehouse_id=v_warehouse
      AND line.stock_product_id=v_product.stock_product_id
      AND reservation.status IN('OPEN','PARTIALLY_DISPATCHED');
    SELECT COALESCE(sum(line.reserved_base_qty-line.released_base_qty-
      line.in_transit_base_qty-line.completed_base_qty),0) INTO v_backoffice_reserved
    FROM public.backoffice_sales_reservation_lines line
    JOIN public.backoffice_sales_reservations reservation
      ON reservation.company_id=line.company_id AND reservation.id=line.reservation_id
    WHERE line.company_id=v_company AND line.warehouse_id=v_warehouse
      AND line.product_id=v_product.stock_product_id AND reservation.status<>'RELEASED';
    v_available:=v_on_hand-v_pos_reserved-v_backoffice_reserved;
    v_shortage:=GREATEST(v_product.requested_base_qty-GREATEST(v_available,0),0);
    IF v_shortage>0 AND NOT v_warehouse_row.allow_negative_stock THEN
      RAISE EXCEPTION 'NEGATIVE_STOCK_REQUIRES_WAREHOUSE_OPT_IN';
    END IF;
    v_available_remaining:=GREATEST(v_available,0);
    FOR v_requirement IN SELECT requirement.* FROM public.sale_stock_requirements requirement
      WHERE requirement.company_id=v_company AND requirement.sales_id=p_sales_id
        AND requirement.stock_product_id=v_product.stock_product_id ORDER BY requirement.id
    LOOP
      v_line_available:=LEAST(v_requirement.quantity_base,v_available_remaining);
      v_available_remaining:=v_available_remaining-v_line_available;
      INSERT INTO public.sales_stock_reservation_lines(company_id,reservation_id,
        sales_id,sales_detail_id,stock_requirement_id,stock_product_id,warehouse_id,
        requested_base_qty,reserved_base_qty,available_base_qty_snapshot,
        shortage_base_qty,negative_authority_source,negative_warehouse_version)
      VALUES(v_company,v_reservation,p_sales_id,v_requirement.sales_detail_id,
        v_requirement.id,v_requirement.stock_product_id,v_warehouse,
        v_requirement.quantity_base,v_requirement.quantity_base,v_line_available,
        v_requirement.quantity_base-v_line_available,
        CASE WHEN v_requirement.quantity_base>v_line_available THEN 'WAREHOUSE' END,
        CASE WHEN v_requirement.quantity_base>v_line_available
          THEN v_warehouse_row.master_version END);
      v_line_count:=v_line_count+1;
      IF v_requirement.quantity_base>v_line_available THEN
        v_shortage_count:=v_shortage_count+1;
      END IF;
    END LOOP;
  END LOOP;
  UPDATE public.sales_headers SET order_runtime_status='RESERVED',confirmed_at=v_now,
    confirmed_by=v_actor,confirmation_idempotency_key=p_idempotency_key,
    reservation_version=reservation_version+1,sales_warehouse_id=v_warehouse,
    edit_lock_owner_id=NULL,edit_lock_session_id=NULL,edit_lock_acquired_at=NULL,
    edit_lock_heartbeat_at=NULL,master_version=master_version+1,updated_at=v_now
  WHERE company_id=v_company AND id=p_sales_id;
  INSERT INTO public.sales_stock_reservation_audit(company_id,reservation_id,sales_id,
    action,actor_id,idempotency_key,after_state)
  VALUES(v_company,v_reservation,p_sales_id,'CONFIRM',v_actor,p_idempotency_key,
    jsonb_build_object('status','OPEN','reservedBaseQty',v_total,
      'lineCount',v_line_count,'shortageLineCount',v_shortage_count,
      'negativeAuthoritySource',CASE WHEN v_shortage_count>0 THEN 'WAREHOUSE' END,
      'warehouseVersion',CASE WHEN v_shortage_count>0 THEN v_warehouse_row.master_version END,
      'masterVersion',v_sale.master_version+1));
  RETURN jsonb_build_object('salesId',p_sales_id,'reservationId',v_reservation,
    'orderRuntimeStatus','RESERVED','reservedBaseQty',v_total,'lineCount',v_line_count,
    'shortageLineCount',v_shortage_count,'masterVersion',v_sale.master_version+1,
    'exactRetry',false);
END
$$;

-- The stock/FIFO dispatch core is patched below after exact source markers are verified.
DO $patch_dispatch$
DECLARE v_definition text;v_patched text;v_pattern text;v_new text;v_match_count integer;
BEGIN
  SELECT pg_get_functiondef(
    'private.dispatch_sales_delivery_stock_core_odr3c(uuid,bigint,uuid,jsonb,text)'::regprocedure)
  INTO v_definition;
  v_patched:=v_definition;
  v_pattern:='IF[[:space:]]+v_remaining[[:space:]]*>[[:space:]]*0[[:space:]]+THEN[[:space:]]+IF[[:space:]]+v_res_line[.]negative_policy_version[[:space:]]+IS[[:space:]]+NULL[[:space:]]+OR[[:space:]]+v_res_line[.]negative_permission_version[[:space:]]+IS[[:space:]]+NULL[[:space:]]+OR[[:space:]]+v_res_line[.]commercial_is_bundle[[:space:]]+THEN[[:space:]]+RAISE[[:space:]]+EXCEPTION[[:space:]]+''FIFO_STOCK_CHANGED'';[[:space:]]+END[[:space:]]+IF;';
  v_new:='IF v_remaining>0 THEN
        IF (v_res_line.negative_authority_source=''LEGACY_USER_POLICY''
              AND (v_res_line.negative_policy_version IS NULL
                OR v_res_line.negative_permission_version IS NULL))
          OR (v_res_line.negative_authority_source=''WAREHOUSE''
              AND v_res_line.negative_warehouse_version IS NULL)
          OR v_res_line.negative_authority_source IS NULL THEN
          RAISE EXCEPTION ''FIFO_STOCK_CHANGED'';
        END IF;';
  SELECT count(*) INTO v_match_count FROM regexp_matches(v_patched,v_pattern,'g');
  IF v_match_count<>1 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: dispatch shortage marker drift (matches=%)',v_match_count;
  END IF;
  v_patched:=regexp_replace(v_patched,v_pattern,v_new);

  v_pattern:='SELECT[[:space:]]+permission[.]id[[:space:]]+INTO[[:space:]]+v_permission[[:space:]]+FROM[[:space:]]+public[.]pos_negative_stock_permissions[[:space:]]+permission[[:space:]]+WHERE[[:space:]]+permission[.]company_id[[:space:]]*=[[:space:]]*v_company[[:space:]]+AND[[:space:]]+permission[.]warehouse_id[[:space:]]*=[[:space:]]*v_res_line[.]warehouse_id[[:space:]]+AND[[:space:]]+permission[.]user_id[[:space:]]*=[[:space:]]*v_reservation[.]confirmed_by[[:space:]]+ORDER[[:space:]]+BY[[:space:]]+[(]permission[.]master_version[[:space:]]*=[[:space:]]*v_res_line[.]negative_permission_version[)][[:space:]]+DESC,[[:space:]]+permission[.]updated_at[[:space:]]+DESC[[:space:]]+LIMIT[[:space:]]+1;[[:space:]]+IF[[:space:]]+v_permission[[:space:]]+IS[[:space:]]+NULL[[:space:]]+THEN[[:space:]]+RAISE[[:space:]]+EXCEPTION[[:space:]]+''NEGATIVE_STOCK_PERMISSION_SNAPSHOT_MISSING'';[[:space:]]+END[[:space:]]+IF;[[:space:]]+SELECT[[:space:]]+COALESCE[(]audit[.]after_state->>''negativeReason'',''Reservation-approved negative stock''[)][[:space:]]+INTO[[:space:]]+v_negative_reason[[:space:]]+FROM[[:space:]]+public[.]sales_stock_reservation_audit[[:space:]]+audit[[:space:]]+WHERE[[:space:]]+audit[.]company_id[[:space:]]*=[[:space:]]*v_company[[:space:]]+AND[[:space:]]+audit[.]reservation_id[[:space:]]*=[[:space:]]*v_reservation[.]id[[:space:]]+AND[[:space:]]+audit[.]action[[:space:]]*=[[:space:]]*''CONFIRM''[[:space:]]+ORDER[[:space:]]+BY[[:space:]]+audit[.]created_at[[:space:]]+LIMIT[[:space:]]+1;[[:space:]]+v_negative_reason[[:space:]]*:=[[:space:]]*COALESCE[(]v_negative_reason,[[:space:]]*''Reservation-approved negative stock''[)];';
  v_new:='IF v_res_line.negative_authority_source=''LEGACY_USER_POLICY'' THEN
          SELECT permission.id INTO v_permission
          FROM public.pos_negative_stock_permissions permission
          WHERE permission.company_id=v_company
            AND permission.warehouse_id=v_res_line.warehouse_id
            AND permission.user_id=v_reservation.confirmed_by
          ORDER BY (permission.master_version=v_res_line.negative_permission_version) DESC,
            permission.updated_at DESC LIMIT 1;
          IF v_permission IS NULL THEN RAISE EXCEPTION ''NEGATIVE_STOCK_PERMISSION_SNAPSHOT_MISSING''; END IF;
          SELECT COALESCE(audit.after_state->>''negativeReason'',''Reservation-approved negative stock'')
          INTO v_negative_reason FROM public.sales_stock_reservation_audit audit
          WHERE audit.company_id=v_company AND audit.reservation_id=v_reservation.id
            AND audit.action=''CONFIRM'' ORDER BY audit.created_at LIMIT 1;
          v_negative_reason:=COALESCE(v_negative_reason,''Reservation-approved negative stock'');
        ELSE
          v_permission:=NULL;v_negative_reason:=NULL;
        END IF;';
  SELECT count(*) INTO v_match_count FROM regexp_matches(v_patched,v_pattern,'g');
  IF v_match_count<>1 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: dispatch permission marker drift (matches=%)',v_match_count;
  END IF;
  v_patched:=regexp_replace(v_patched,v_pattern,v_new);

  v_pattern:='balance_after_base_qty,[[:space:]]*provisional_unit_cost,[[:space:]]*policy_version,[[:space:]]*permission_version[)]';
  v_new:='balance_after_base_qty,provisional_unit_cost,policy_version,permission_version,
          authority_source,warehouse_version)';
  SELECT count(*) INTO v_match_count FROM regexp_matches(v_patched,v_pattern,'g');
  IF v_match_count<>1 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: dispatch authorization columns drift (matches=%)',v_match_count;
  END IF;
  v_patched:=regexp_replace(v_patched,v_pattern,v_new);

  v_pattern:='v_res_line[.]negative_policy_version,[[:space:]]*v_res_line[.]negative_permission_version[)]';
  v_new:='v_res_line.negative_policy_version,v_res_line.negative_permission_version,
          v_res_line.negative_authority_source,v_res_line.negative_warehouse_version)';
  SELECT count(*) INTO v_match_count FROM regexp_matches(v_patched,v_pattern,'g');
  IF v_match_count<>1 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: dispatch authorization values drift (matches=%)',v_match_count;
  END IF;
  v_patched:=regexp_replace(v_patched,v_pattern,v_new);
  IF v_patched~'OR v_res_line.commercial_is_bundle'
    OR v_patched!~'negative_warehouse_version'
    OR v_patched!~'authority_source,warehouse_version' THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: dispatch patch contract invalid';
  END IF;
  EXECUTE v_patched;
END
$patch_dispatch$;

CREATE OR REPLACE FUNCTION private.trg_g4_guard_negative_sale_movement()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
  IF NEW.balance_after_base_qty<0 AND NOT EXISTS(
    SELECT 1 FROM public.pos_negative_stock_authorizations authz
    WHERE authz.company_id=NEW.company_id AND authz.sales_id=NEW.reference_id
      AND authz.stock_product_id=NEW.product_id AND authz.warehouse_id=NEW.warehouse_id
      AND authz.balance_after_base_qty=NEW.balance_after_base_qty
      AND ((authz.authority_source='LEGACY_USER_POLICY'
          AND authz.policy_version IS NOT NULL AND authz.permission_version IS NOT NULL)
        OR (authz.authority_source='WAREHOUSE' AND authz.warehouse_version IS NOT NULL))) THEN
    RAISE EXCEPTION 'NEGATIVE_STOCK_AUTHORIZATION_REQUIRED';
  END IF;
  RETURN NEW;
END
$$;

REVOKE ALL ON FUNCTION
  private.authorize_pos_negative_stock(uuid,uuid,uuid,uuid,jsonb,text),
  private.confirm_pos_sales_order_core(uuid,bigint,uuid,text),
  private.dispatch_sales_delivery_stock_core_odr3c(uuid,bigint,uuid,jsonb,text),
  private.trg_g4_guard_negative_sale_movement()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.authorize_pos_negative_stock(uuid,uuid,uuid,uuid,jsonb,text),
  private.confirm_pos_sales_order_core(uuid,bigint,uuid,text),
  private.dispatch_sales_delivery_stock_core_odr3c(uuid,bigint,uuid,jsonb,text),
  private.trg_g4_guard_negative_sale_movement()
TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260910153000','unified_warehouse_negative_stock_authority',
  'Use active sale-source Warehouse allow_negative_stock as sole authority for new Retail and Backoffice shortages; no user, terminal, Company feature, limit, or reason gate; preserve legacy evidence and update reservation, Dispatch/FIFO, direct POS and cutover compatibility');

NOTIFY pgrst,'reload schema';
COMMIT;
