BEGIN;

DO $guard$
DECLARE v_dependency_rows integer;v_runtime_shape text;v_fulfillment_shape text;
  v_post_rpc_definition text;v_public_post_definition text;
BEGIN
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20261030120000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20261030120000';
  END IF;
  SELECT count(*) INTO v_dependency_rows FROM private.kgs_schema_migrations
  WHERE version IN('20260811130000','20260827153000','20260828100000',
    '20260908100000','20260911120000','20260911130000');
  IF v_dependency_rows<>6 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: dependency ledger';
  END IF;
  IF to_regprocedure('public.post_pos_sale_with_pricelist(uuid,bigint,uuid)') IS NULL
    OR to_regprocedure('public.adopt_backoffice_cutover_sale_draft(uuid,bigint,uuid,uuid,boolean)') IS NULL
    OR to_regprocedure('private.sales_process_retail_identity_is_valid(text,text,uuid,uuid,uuid)') IS NULL
    OR to_regclass('public.sales_headers') IS NULL
    OR to_regclass('public.sales_stock_reservations') IS NULL
    OR to_regclass('public.company_sales_process_settings') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Retail post runtime';
  END IF;
  SELECT pg_get_functiondef('public.post_pos_sale_with_pricelist(uuid,bigint,uuid)'::regprocedure)
    INTO v_post_rpc_definition;
  SELECT pg_get_functiondef('public.post_pos_sale(uuid,bigint,uuid)'::regprocedure)
    INTO v_public_post_definition;
  IF v_post_rpc_definition NOT LIKE '%public.post_pos_sale(%'
    OR v_public_post_definition NOT LIKE '%private.post_pos_sale_before_schedule_core(%' THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Retail post call-chain drift';
  END IF;
  SELECT pg_get_constraintdef(constraint_row.oid) INTO v_runtime_shape
  FROM pg_constraint constraint_row
  WHERE constraint_row.conrelid='public.sales_headers'::regclass
    AND constraint_row.conname='sales_headers_order_runtime_shape';
  SELECT pg_get_constraintdef(constraint_row.oid) INTO v_fulfillment_shape
  FROM pg_constraint constraint_row
  WHERE constraint_row.conrelid='public.sales_headers'::regclass
    AND constraint_row.conname='sales_headers_fulfillment_shape_check';
  IF COALESCE(v_runtime_shape,'') NOT LIKE '%LEGACY_POSTED%'
    OR COALESCE(v_runtime_shape,'') NOT LIKE '%document_status = ''POSTED''%'
    OR COALESCE(v_fulfillment_shape,'') NOT LIKE '%fulfillment_mode%' THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Sales constraint drift';
  END IF;
  IF to_regprocedure('private.trg_pos_retail_direct_post_order_runtime_bridge()')
      IS NOT NULL
    OR EXISTS(SELECT 1 FROM pg_trigger trigger_row
      WHERE trigger_row.tgrelid='public.sales_headers'::regclass
        AND trigger_row.tgname='pos_retail_direct_post_order_runtime_bridge'
        AND NOT trigger_row.tgisinternal) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: bridge already exists';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
      WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
      WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
END
$guard$;

CREATE FUNCTION private.trg_pos_retail_direct_post_order_runtime_bridge()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_active_mode text;
BEGIN
  IF OLD.document_status='DRAFT' AND NEW.document_status='POSTED'
    AND OLD.order_runtime_status IN('DRAFT_INPUT','SCHEDULED') THEN
    IF OLD.sales_origin NOT IN('POS','BACKOFFICE_CUTOVER')
      OR OLD.sales_process_mode<>'RETAIL_CONFIRM_INVOICE' THEN
      RETURN NEW;
    END IF;
    IF NOT private.sales_process_retail_identity_is_valid(
        OLD.sales_origin,OLD.sales_process_mode,OLD.session_id,OLD.pos_id,
        OLD.created_session_id) THEN
      RAISE EXCEPTION 'RETAIL_DIRECT_POST_IDENTITY_INVALID';
    END IF;
    IF OLD.sales_origin='BACKOFFICE_CUTOVER' AND (
        OLD.session_id IS NULL OR OLD.pos_id IS NULL
        OR OLD.created_session_id IS NULL
        OR COALESCE((OLD.payload_snapshot->>'snapshotPreserved')::boolean,false)
          IS NOT TRUE) THEN
      RAISE EXCEPTION 'RETAIL_DIRECT_POST_CUTOVER_ADOPTION_REQUIRED';
    END IF;
    SELECT setting.active_mode INTO v_active_mode
    FROM public.company_sales_process_settings setting
    WHERE setting.company_id=OLD.company_id;
    IF v_active_mode IS DISTINCT FROM 'RETAIL_CONFIRM_INVOICE' THEN
      RAISE EXCEPTION 'RETAIL_DIRECT_POST_MODE_BLOCKED';
    END IF;
    IF NEW.order_runtime_status IS DISTINCT FROM OLD.order_runtime_status
      OR OLD.confirmed_at IS NOT NULL OR OLD.confirmed_by IS NOT NULL
      OR OLD.confirmation_idempotency_key IS NOT NULL
      OR OLD.reservation_version<>0
      OR EXISTS(SELECT 1 FROM public.sales_stock_reservations reservation
        WHERE reservation.company_id=OLD.company_id
          AND reservation.sales_id=OLD.id) THEN
      RAISE EXCEPTION 'RETAIL_DIRECT_POST_ORDER_STATE_INVALID';
    END IF;
    NEW.order_runtime_status:='LEGACY_POSTED';
  END IF;
  RETURN NEW;
END
$$;

CREATE TRIGGER pos_retail_direct_post_order_runtime_bridge
BEFORE UPDATE OF document_status ON public.sales_headers
FOR EACH ROW
EXECUTE FUNCTION private.trg_pos_retail_direct_post_order_runtime_bridge();

COMMENT ON FUNCTION private.trg_pos_retail_direct_post_order_runtime_bridge() IS
  'Bridges direct POS and already-adopted BACKOFFICE_CUTOVER Retail Draft-to-Posted transitions to the existing LEGACY_POSTED constraint shape. Active Backoffice and reserved Order lifecycles are excluded.';

REVOKE ALL ON FUNCTION private.trg_pos_retail_direct_post_order_runtime_bridge()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.trg_pos_retail_direct_post_order_runtime_bridge()
TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20261030120000','pos_retail_direct_post_order_runtime_bridge',
  'Forward-only bridge for direct POS and adopted BACKOFFICE_CUTOVER Retail Draft-to-Posted atomic finalization; preserves active Backoffice and reserved Order runtimes');

COMMIT;
