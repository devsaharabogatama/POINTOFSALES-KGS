-- SELECT-only verification for 20260910130000.
WITH checks AS (
  SELECT 'migration_ledger' check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(1-count(*))::bigint violation_rows,
    jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260910130000'
  UNION ALL
  SELECT 'cutover_identity_column_nullability',
    CASE WHEN count(*)=3 AND count(*) FILTER(WHERE is_nullable='YES')=3
      THEN 'PASS' ELSE 'FAIL' END,
    (3-count(*) FILTER(WHERE is_nullable='YES'))::bigint,
    jsonb_build_object('expectedNullable',3,'columns',
      COALESCE(jsonb_agg(jsonb_build_array(column_name,is_nullable)
        ORDER BY column_name),'[]'::jsonb))
  FROM information_schema.columns
  WHERE table_schema='public' AND table_name='sales_headers'
    AND column_name IN('session_id','pos_id','created_session_id')
  UNION ALL
  SELECT 'cutover_identity_helper_contract',
    CASE WHEN count(*)=1 AND bool_and(proc.provolatile='i')
      AND bool_and(proc.prosecdef=false) THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1 AND bool_and(proc.provolatile='i')
      AND bool_and(proc.prosecdef=false) THEN 0 ELSE 1 END,
    jsonb_build_object('routineRows',count(*),'volatility',min(proc.provolatile::text),
      'securityDefiner',bool_or(proc.prosecdef))
  FROM pg_proc proc JOIN pg_namespace namespace ON namespace.oid=proc.pronamespace
  WHERE namespace.nspname='private'
    AND proc.oid=to_regprocedure(
      'private.sales_process_retail_identity_is_valid(text,text,uuid,uuid,uuid)')
  UNION ALL
  SELECT 'cutover_identity_private_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('browserExecutableRows',count(*))
  FROM information_schema.routine_privileges privilege
  WHERE privilege.specific_schema='private'
    AND privilege.routine_name IN('sales_process_retail_identity_is_valid',
      'classify_sales_process_conversion_candidate','trg_guard_sales_process_identity',
      'trg_g4_prepare_sale_draft')
    AND privilege.grantee IN('PUBLIC','anon','authenticated')
    AND privilege.privilege_type='EXECUTE'
  UNION ALL
  SELECT 'cutover_identity_constraint_contract',
    CASE WHEN count(*)=3
      AND bool_or(con_row.conname='sales_headers_origin_check'
        AND pg_get_constraintdef(con_row.oid) LIKE '%BACKOFFICE_CUTOVER%')
      AND bool_or(con_row.conname='sales_headers_origin_process_pair_check'
        AND pg_get_constraintdef(con_row.oid) LIKE '%BACKOFFICE_CUTOVER%')
      AND bool_or(con_row.conname='sales_headers_retail_identity_context_check'
        AND pg_get_constraintdef(con_row.oid)
          LIKE '%sales_process_retail_identity_is_valid%')
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=3
      AND bool_or(con_row.conname='sales_headers_origin_check'
        AND pg_get_constraintdef(con_row.oid) LIKE '%BACKOFFICE_CUTOVER%')
      AND bool_or(con_row.conname='sales_headers_origin_process_pair_check'
        AND pg_get_constraintdef(con_row.oid) LIKE '%BACKOFFICE_CUTOVER%')
      AND bool_or(con_row.conname='sales_headers_retail_identity_context_check'
        AND pg_get_constraintdef(con_row.oid)
          LIKE '%sales_process_retail_identity_is_valid%')
      THEN 0 ELSE 1 END,
    jsonb_build_object('constraintRows',count(*))
  FROM pg_constraint con_row
  JOIN pg_class relation ON relation.oid=con_row.conrelid
  JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
  WHERE namespace.nspname='public' AND relation.relname='sales_headers'
    AND con_row.conname IN('sales_headers_origin_check',
      'sales_headers_origin_process_pair_check',
      'sales_headers_retail_identity_context_check')
  UNION ALL
  SELECT 'cutover_identity_trigger_contract',
    CASE WHEN count(*)=2
      AND bool_or(proc.proname='trg_guard_sales_process_identity'
        AND pg_get_functiondef(proc.oid) LIKE '%BACKOFFICE_CUTOVER_RUNTIME_REQUIRED%')
      AND bool_or(proc.proname='trg_g4_prepare_sale_draft'
        AND pg_get_functiondef(proc.oid) LIKE '%BACKOFFICE_CUTOVER%')
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=2
      AND bool_or(proc.proname='trg_guard_sales_process_identity'
        AND pg_get_functiondef(proc.oid) LIKE '%BACKOFFICE_CUTOVER_RUNTIME_REQUIRED%')
      AND bool_or(proc.proname='trg_g4_prepare_sale_draft'
        AND pg_get_functiondef(proc.oid) LIKE '%BACKOFFICE_CUTOVER%')
      THEN 0 ELSE 1 END,
    jsonb_build_object('routineRows',count(*))
  FROM pg_proc proc JOIN pg_namespace namespace ON namespace.oid=proc.pronamespace
  WHERE namespace.nspname='private'
    AND proc.proname IN('trg_guard_sales_process_identity','trg_g4_prepare_sale_draft')
  UNION ALL
  SELECT 'cutover_revision_classifier_contract',
    CASE WHEN count(*)=1
      AND bool_and(pg_get_functiondef(proc.oid) LIKE '%PENDING_REVISION_MUST_RESOLVE%')
      AND bool_and(pg_get_functiondef(proc.oid) NOT LIKE '%CONVERT_REVISION_PAIR%')
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1
      AND bool_and(pg_get_functiondef(proc.oid) LIKE '%PENDING_REVISION_MUST_RESOLVE%')
      AND bool_and(pg_get_functiondef(proc.oid) NOT LIKE '%CONVERT_REVISION_PAIR%')
      THEN 0 ELSE 1 END,
    jsonb_build_object('routineRows',count(*))
  FROM pg_proc proc JOIN pg_namespace namespace ON namespace.oid=proc.pronamespace
  WHERE namespace.nspname='private'
    AND proc.oid=to_regprocedure(
      'private.classify_sales_process_conversion_candidate(text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean)')
  UNION ALL
  SELECT 'sales_identity_runtime_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('invalidRows',count(*))
  FROM public.sales_headers sale
  WHERE NOT private.sales_process_retail_identity_is_valid(sale.sales_origin,
    sale.sales_process_mode,sale.session_id,sale.pos_id,sale.created_session_id)
  UNION ALL
  SELECT 'open_cutover_plan_inventory','INFO',0::bigint,
    jsonb_build_object('openPlans',count(*),'rule',
      'Plans created after this migration use the canonical Revision blocker classifier')
  FROM public.sales_process_cutover_plans
  WHERE status IN('DRAFT','PREVIEWED','APPLYING')
)
SELECT * FROM checks ORDER BY
  CASE status WHEN 'FAIL' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;
