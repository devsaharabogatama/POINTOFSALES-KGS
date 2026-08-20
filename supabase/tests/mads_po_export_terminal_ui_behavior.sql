BEGIN;
DO $setup$
DECLARE v_actor UUID;v_company UUID;v_terminal UUID;
BEGIN
  SELECT profile.id INTO v_actor FROM public.profiles profile
  WHERE profile.role='super_admin' ORDER BY profile.id LIMIT 1;
  SELECT terminal.company_id,terminal.id
    INTO v_company,v_terminal
  FROM public.pos_terminals terminal JOIN public.companies company ON company.id=terminal.company_id
  WHERE terminal.status='ACTIVE' AND company.status='ACTIVE'
  ORDER BY terminal.id LIMIT 1;
  IF v_actor IS NULL OR v_terminal IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: linked Super Admin and active Terminal required';
  END IF;
  INSERT INTO public.user_active_company_contexts(user_id,company_id,selection_source)
  VALUES(v_actor,v_company,'BACKOFFICE') ON CONFLICT(user_id) DO UPDATE SET
    company_id=EXCLUDED.company_id,selection_source=EXCLUDED.selection_source;
  PERFORM set_config('mads_test.actor',v_actor::TEXT,TRUE);
  PERFORM set_config('mads_test.company',v_company::TEXT,TRUE);
  PERFORM set_config('mads_test.terminal',v_terminal::TEXT,TRUE);
END
$setup$;

SELECT set_config('request.jwt.claims',jsonb_build_object(
  'sub',current_setting('mads_test.actor'),'role','authenticated')::TEXT,TRUE);
SET LOCAL ROLE authenticated;

DO $test$
DECLARE v_company UUID:=current_setting('mads_test.company')::UUID;
  v_terminal UUID:=current_setting('mads_test.terminal')::UUID;
  v_version BIGINT;v_result JSONB;v_export JSONB;
BEGIN
  SELECT (item->>'masterVersion')::BIGINT INTO v_version
  FROM jsonb_array_elements(
    public.get_pos_terminal_ui_settings()->'terminals'
  ) item
  WHERE (item->>'terminalId')::UUID=v_terminal;
  v_result:=public.save_pos_terminal_ui_settings(v_terminal,v_version,ARRAY['OFFLINE','EXPENSE','OFFLINE']);
  IF v_result->>'action'<>'UPDATE' OR v_result->'hiddenFeatureKeys'<>jsonb_build_array('EXPENSE','OFFLINE') THEN
    RAISE EXCEPTION 'TEST_FAILED: terminal UI setting normalization invalid';
  END IF;
  v_result:=public.save_pos_terminal_ui_settings(v_terminal,(v_result->>'masterVersion')::BIGINT,ARRAY['EXPENSE','OFFLINE']);
  IF v_result->>'action'<>'EXACT_RETRY' THEN
    RAISE EXCEPTION 'TEST_FAILED: terminal UI exact retry invalid';
  END IF;
  IF NOT ((public.get_pos_terminal_ui_settings()->'terminals') @> jsonb_build_array(jsonb_build_object('terminalId',v_terminal,'hiddenFeatureKeys',jsonb_build_array('EXPENSE','OFFLINE')))) THEN
    RAISE EXCEPTION 'TEST_FAILED: terminal UI composed read invalid';
  END IF;
  v_export:=public.export_purchase_supplier_orders();
  IF jsonb_typeof(v_export->'orders')<>'array' OR jsonb_typeof(v_export->'lines')<>'array' THEN
    RAISE EXCEPTION 'TEST_FAILED: Supplier Order export shape invalid';
  END IF;
END
$test$;
ROLLBACK;
