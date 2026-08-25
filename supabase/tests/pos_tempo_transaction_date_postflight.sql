-- POS TEMPO transaction date postflight. SELECT-only.
WITH routine_state AS (
  SELECT procedure.proname,procedure.prosecdef,
    pg_get_functiondef(procedure.oid) AS definition
  FROM pg_proc procedure
  JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname='public'
    AND procedure.proname IN(
      'get_pos_customer_references',
      'save_pos_sale_draft_with_pricelist',
      'list_pos_sale_drafts'
    )
),checks AS (
  SELECT 'migration_ledger'::TEXT AS check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END AS status,
    abs(1-count(*))::BIGINT AS violation_rows,
    jsonb_build_object('ledgerRows',count(*)) AS details
  FROM private.kgs_schema_migrations WHERE version='20260825110000'
  UNION ALL
  SELECT 'required_tempo_display_routines',
    CASE WHEN count(*)=3 THEN 'PASS' ELSE 'FAIL' END,
    abs(3-count(*))::BIGINT,jsonb_build_object('routineRows',count(*))
  FROM routine_state
  UNION ALL
  SELECT 'customer_credit_term_reference_contract',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    abs(1-count(*))::BIGINT,jsonb_build_object('routineRows',count(*))
  FROM routine_state
  WHERE proname='get_pos_customer_references'
    AND definition LIKE '%credit_term_days%'
    AND definition LIKE '%credit_limit%'
  UNION ALL
  SELECT 'canonical_transaction_date_response_contract',
    CASE WHEN count(*)=2 THEN 'PASS' ELSE 'FAIL' END,
    abs(2-count(*))::BIGINT,jsonb_build_object('routineRows',count(*))
  FROM routine_state
  WHERE proname IN('save_pos_sale_draft_with_pricelist','list_pos_sale_drafts')
    AND definition LIKE '%transactionAt%'
    AND definition LIKE '%transaction_date%'
    AND prosecdef
  UNION ALL
  SELECT 'tempo_display_rpc_boundary',
    CASE WHEN NOT has_function_privilege(
      'anon','public.get_pos_customer_references()','EXECUTE'
    ) AND has_function_privilege(
      'authenticated','public.get_pos_customer_references()','EXECUTE'
    ) AND NOT has_function_privilege(
      'anon','public.save_pos_sale_draft_with_pricelist(jsonb)','EXECUTE'
    ) AND has_function_privilege(
      'authenticated','public.save_pos_sale_draft_with_pricelist(jsonb)','EXECUTE'
    ) THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN NOT has_function_privilege(
      'anon','public.get_pos_customer_references()','EXECUTE'
    ) AND has_function_privilege(
      'authenticated','public.get_pos_customer_references()','EXECUTE'
    ) AND NOT has_function_privilege(
      'anon','public.save_pos_sale_draft_with_pricelist(jsonb)','EXECUTE'
    ) AND has_function_privilege(
      'authenticated','public.save_pos_sale_draft_with_pricelist(jsonb)','EXECUTE'
    ) THEN 0 ELSE 1 END,
    jsonb_build_object(
      'customerReferenceAuthenticated',has_function_privilege(
        'authenticated','public.get_pos_customer_references()','EXECUTE'),
      'draftSaveAuthenticated',has_function_privilege(
        'authenticated','public.save_pos_sale_draft_with_pricelist(jsonb)','EXECUTE')
    )
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 ELSE 2 END,check_name;
