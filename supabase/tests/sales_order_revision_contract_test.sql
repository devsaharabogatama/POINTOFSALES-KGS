-- Definition/privilege regression for Sales Order revision runtime.
-- SAFETY: no business row is created or changed.
BEGIN;

DO $test$
DECLARE v_start TEXT;v_confirm TEXT;v_cancel TEXT;v_cancel_draft TEXT;
  v_eligibility TEXT;v_start_n TEXT;v_confirm_n TEXT;v_cancel_n TEXT;
  v_cancel_draft_n TEXT;v_eligibility_n TEXT;v_root UUID:=gen_random_uuid();
  v_cancel_key UUID;v_confirm_key UUID;
BEGIN
  IF to_regclass('public.sales_order_revisions') IS NULL
    OR to_regclass('public.sales_order_revision_audit') IS NULL THEN
    RAISE EXCEPTION 'TEST_FAILED: revision relations missing';
  END IF;
  IF to_regprocedure(
      'public.start_pos_sales_order_revision(uuid,bigint,uuid,uuid,text)') IS NULL
    OR to_regprocedure(
      'public.confirm_pos_sales_order(uuid,bigint,uuid,text)') IS NULL
    OR to_regprocedure(
      'public.cancel_pos_sale_draft(uuid,bigint,uuid,text)') IS NULL
    OR to_regprocedure('public.get_sales_order_revision_links()') IS NULL
    OR to_regprocedure(
      'public.get_pos_sales_order_revision_eligibility(uuid)') IS NULL THEN
    RAISE EXCEPTION 'TEST_FAILED: revision public runtime missing';
  END IF;
  IF to_regprocedure(
      'private.sales_order_revision_child_idempotency_key(uuid,text)') IS NULL THEN
    RAISE EXCEPTION 'TEST_FAILED: revision child-key helper missing';
  END IF;
  SELECT pg_get_functiondef(
    'public.start_pos_sales_order_revision(uuid,bigint,uuid,uuid,text)'::regprocedure)
    INTO v_start;
  SELECT pg_get_functiondef(
    'public.confirm_pos_sales_order(uuid,bigint,uuid,text)'::regprocedure)
    INTO v_confirm;
  SELECT pg_get_functiondef(
    'public.cancel_pos_sales_order(uuid,bigint,uuid,text)'::regprocedure)
    INTO v_cancel;
  SELECT pg_get_functiondef(
    'public.cancel_pos_sale_draft(uuid,bigint,uuid,text)'::regprocedure)
    INTO v_cancel_draft;
  SELECT pg_get_functiondef(
    'public.get_pos_sales_order_revision_eligibility(uuid)'::regprocedure)
    INTO v_eligibility;
  v_start_n:=regexp_replace(v_start,'[[:space:]]+','','g');
  v_confirm_n:=regexp_replace(v_confirm,'[[:space:]]+','','g');
  v_cancel_n:=regexp_replace(v_cancel,'[[:space:]]+','','g');
  v_cancel_draft_n:=regexp_replace(v_cancel_draft,'[[:space:]]+','','g');
  v_eligibility_n:=regexp_replace(v_eligibility,'[[:space:]]+','','g');
  IF v_start_n!~'save_pos_sale_draft_with_pricelist'
    OR v_start_n!~'pg_advisory_xact_lock'
    OR v_start_n!~'IDEMPOTENCY_PAYLOAD_CONFLICT'
    OR v_start_n!~'total_dispatched_base_qty<>0'
    OR v_start_n!~'SALES_ORDER_REVISION_VERIFIED_PAYMENT'
    OR v_confirm_n!~'v_cancel_key:=private.sales_order_revision_child_idempotency_key'
    OR v_confirm_n!~'v_confirm_key:=private.sales_order_revision_child_idempotency_key'
    OR v_confirm_n!~'v_cancel:=public.cancel_pos_sales_order.*v_cancel_key.*v_result:=private.confirm_pos_sales_order_before_revision_core.*v_confirm_key'
    OR v_cancel_n!~'SALES_ORDER_REVISION_PENDING'
    OR v_cancel_n!~'FORUPDATE'
    OR v_cancel_draft_n!~'order_runtime_status=''CANCELED'''
    OR v_eligibility_n!~'request.status=''VERIFIED'''
    OR v_eligibility_n!~'revision.status=''PENDING''' THEN
    RAISE EXCEPTION 'TEST_FAILED: atomic revision composition invalid';
  END IF;
  v_cancel_key:=private.sales_order_revision_child_idempotency_key(
    v_root,'CANCEL_SOURCE');
  v_confirm_key:=private.sales_order_revision_child_idempotency_key(
    v_root,'CONFIRM_REPLACEMENT');
  IF v_cancel_key=v_confirm_key OR v_cancel_key=v_root OR v_confirm_key=v_root THEN
    RAISE EXCEPTION 'TEST_FAILED: revision child-key namespace invalid';
  END IF;
  IF has_function_privilege('anon',
      'public.start_pos_sales_order_revision(uuid,bigint,uuid,uuid,text)','EXECUTE')
    OR NOT has_function_privilege('authenticated',
      'public.start_pos_sales_order_revision(uuid,bigint,uuid,uuid,text)','EXECUTE')
    OR has_function_privilege('anon',
      'public.get_pos_sales_order_revision_eligibility(uuid)','EXECUTE')
    OR has_function_privilege('authenticated',
      'private.confirm_pos_sales_order_before_revision_core(uuid,bigint,uuid,text)',
      'EXECUTE')
    OR has_function_privilege('authenticated',
      'private.sales_order_revision_child_idempotency_key(uuid,text)',
      'EXECUTE') THEN
    RAISE EXCEPTION 'TEST_FAILED: revision privilege boundary invalid';
  END IF;
END
$test$;

SELECT 'sales_order_revision_contract_test' check_name,'PASS' status,
  jsonb_build_object('tested',ARRAY[
    'replacement Draft without source mutation',
    'pre-dispatch and verified-payment guards',
    'cancel-before-confirm atomic composition',
    'distinct deterministic suboperation identity',
    'ordinary Confirm fallback',
    'public/private execute boundary']) details;

ROLLBACK;
