-- Sales Order revision child-idempotency regression.
-- SAFETY: definition checks only; no business row is changed.
BEGIN;

DO $test$
DECLARE v_definition TEXT;v_root UUID:=gen_random_uuid();
  v_cancel UUID;v_confirm UUID;
BEGIN
  IF to_regprocedure(
      'private.sales_order_revision_child_idempotency_key(uuid,text)') IS NULL THEN
    RAISE EXCEPTION 'TEST_FAILED: revision child-key helper missing';
  END IF;
  v_cancel:=private.sales_order_revision_child_idempotency_key(
    v_root,'CANCEL_SOURCE');
  v_confirm:=private.sales_order_revision_child_idempotency_key(
    v_root,'CONFIRM_REPLACEMENT');
  IF v_cancel IS NULL OR v_confirm IS NULL OR v_cancel=v_confirm
    OR v_cancel=v_root OR v_confirm=v_root
    OR v_cancel<>private.sales_order_revision_child_idempotency_key(
      v_root,'CANCEL_SOURCE')
    OR v_confirm<>private.sales_order_revision_child_idempotency_key(
      v_root,'CONFIRM_REPLACEMENT') THEN
    RAISE EXCEPTION 'TEST_FAILED: revision child-key determinism or separation invalid';
  END IF;
  SELECT pg_get_functiondef(
    'public.confirm_pos_sales_order(uuid,bigint,uuid,text)'::regprocedure)
    INTO v_definition;
  v_definition:=regexp_replace(v_definition,'[[:space:]]+','','g');
  IF v_definition!~'v_cancel_key:=private.sales_order_revision_child_idempotency_key\(p_idempotency_key,''CANCEL_SOURCE''\)'
    OR v_definition!~'v_confirm_key:=private.sales_order_revision_child_idempotency_key\(p_idempotency_key,''CONFIRM_REPLACEMENT''\)'
    OR v_definition!~'cancel_pos_sales_order\(v_source.id,v_source.master_version,v_cancel_key'
    OR v_definition!~'confirm_pos_sales_order_before_revision_core\(p_sales_id,p_master_version,v_confirm_key'
    OR v_definition!~'apply_idempotency_key=p_idempotency_key' THEN
    RAISE EXCEPTION 'TEST_FAILED: revision suboperation namespace composition invalid';
  END IF;
  IF has_function_privilege('authenticated',
      'private.sales_order_revision_child_idempotency_key(uuid,text)','EXECUTE')
    OR has_function_privilege('anon',
      'public.confirm_pos_sales_order(uuid,bigint,uuid,text)','EXECUTE')
    OR NOT has_function_privilege('authenticated',
      'public.confirm_pos_sales_order(uuid,bigint,uuid,text)','EXECUTE') THEN
    RAISE EXCEPTION 'TEST_FAILED: revision idempotency privilege boundary invalid';
  END IF;
END
$test$;

SELECT 'sales_order_revision_idempotency_contract_test' check_name,'PASS' status,
  jsonb_build_object('tested',ARRAY[
    'deterministic child identities',
    'source/replacement namespace separation',
    'public root operation identity preserved',
    'public/private execute boundary']) details;

ROLLBACK;
