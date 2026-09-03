-- POS Stock Opname online workspace definition test.
-- SAFETY: read-only and fixture-free.

DO $test$
DECLARE v_definition TEXT;
BEGIN
  IF to_regprocedure('public.get_pos_stock_opname_workspace()') IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: POS Stock Opname workspace missing';
  END IF;
  SELECT pg_get_functiondef('public.get_pos_stock_opname_workspace()'::regprocedure)
  INTO v_definition;
  IF v_definition NOT ILIKE '%opname.created_by=v_actor%'
     OR v_definition NOT ILIKE '%private_stock_opname_counter_allowed%'
     OR v_definition NOT ILIKE '%restrictionPreset%'
     OR v_definition ILIKE '%physical_qty%'
     OR v_definition ILIKE '%system_qty%'
     OR v_definition ILIKE '%expected_qty%'
     OR v_definition ILIKE '%variance_at_count%'
     OR v_definition ILIKE '%difference%' THEN
    RAISE EXCEPTION 'TEST_FAILED: blind workspace boundary invalid';
  END IF;
  IF has_function_privilege('anon',
       'public.get_pos_stock_opname_workspace()','EXECUTE')
     OR NOT has_function_privilege('authenticated',
       'public.get_pos_stock_opname_workspace()','EXECUTE') THEN
    RAISE EXCEPTION 'TEST_FAILED: workspace RPC privilege boundary invalid';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM pg_constraint
    WHERE conrelid='public.pos_terminals'::regclass
      AND conname='pos_terminal_hidden_feature_keys_check'
      AND pg_get_constraintdef(oid) ILIKE '%STOCK_OPNAME%') THEN
    RAISE EXCEPTION 'TEST_FAILED: terminal Stock Opname visibility constraint invalid';
  END IF;
  SELECT pg_get_functiondef(
    'public.save_pos_terminal_ui_settings(uuid,bigint,text[],boolean)'::regprocedure)
  INTO v_definition;
  IF v_definition NOT ILIKE '%STOCK_OPNAME%' THEN
    RAISE EXCEPTION 'TEST_FAILED: terminal Stock Opname visibility save contract invalid';
  END IF;
  RAISE NOTICE 'TEST PASSED: POS Stock Opname workspace is owner-scoped, restriction-aware, blind-safe, and authenticated-only.';
END
$test$;
