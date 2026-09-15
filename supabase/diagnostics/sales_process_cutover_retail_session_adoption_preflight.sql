-- Step 4D/6 SELECT-only preflight. Run the entire file.
WITH required_ledger(version) AS (VALUES
  ('20260910130000'::text),('20260911110000'),('20260911111000')
), checks AS (
  SELECT 'step_4d_dependency_ledger' check_name,
    CASE WHEN count(m.version)=3 THEN 'PASS' ELSE 'BLOCKER' END status,
    3-count(m.version) violation_rows,
    jsonb_build_object('expected',3,'present',count(m.version)) details
  FROM required_ledger required
  LEFT JOIN private.kgs_schema_migrations m ON m.version=required.version
  UNION ALL
  SELECT 'step_4d_routine_dependency',
    CASE WHEN count(*)=5 THEN 'PASS' ELSE 'BLOCKER' END,5-count(*),
    jsonb_build_object('expected',5,'present',count(*))
  FROM pg_proc procedure JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
  WHERE (namespace.nspname,procedure.proname,pg_get_function_identity_arguments(procedure.oid)) IN(
    ('public','list_pos_sale_drafts','p_store_id uuid'),
    ('public','acquire_pos_sale_draft_lock','p_sales_id uuid, p_cashier_session_id uuid, p_confirm_takeover boolean'),
    ('public','save_pos_sale_draft_with_pricelist','p_payload jsonb'),
    ('private','sales_process_retail_identity_is_valid','p_sales_origin text, p_sales_process_mode text, p_session_id uuid, p_pos_id uuid, p_created_session_id uuid'),
    ('private','trg_guard_sales_process_identity',''))
  UNION ALL
  SELECT 'step_4d_object_collision',
    CASE WHEN to_regclass('public.sales_cutover_retail_adoption_operations') IS NULL
      AND to_regprocedure('public.adopt_backoffice_cutover_sale_draft(uuid,bigint,uuid,uuid,boolean)') IS NULL
      AND to_regprocedure('public.save_backoffice_cutover_sale_draft_preserved(uuid,bigint,uuid,uuid,jsonb)') IS NULL
      THEN 'SETUP' ELSE 'BLOCKER' END,
    CASE WHEN to_regclass('public.sales_cutover_retail_adoption_operations') IS NULL
      AND to_regprocedure('public.adopt_backoffice_cutover_sale_draft(uuid,bigint,uuid,uuid,boolean)') IS NULL
      AND to_regprocedure('public.save_backoffice_cutover_sale_draft_preserved(uuid,bigint,uuid,uuid,jsonb)') IS NULL
      THEN 1 ELSE 3 END,
    jsonb_build_object('required','All Step 4D objects absent before migration')
  UNION ALL
  SELECT 'step_4d_detached_identity_shape',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*),
    jsonb_build_object('invalidDrafts',count(*))
  FROM public.sales_headers sale WHERE sale.sales_origin='BACKOFFICE_CUTOVER'
    AND NOT((sale.session_id IS NULL AND sale.pos_id IS NULL AND sale.created_session_id IS NULL)
      OR (sale.session_id IS NOT NULL AND sale.pos_id IS NOT NULL
        AND sale.created_session_id IS NOT NULL))
  UNION ALL
  SELECT 'step_4d_nonterminal_offline',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*),jsonb_build_object('submissionRows',count(*))
  FROM public.pos_offline_sale_submissions
  WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
  UNION ALL
  SELECT 'step_4d_active_finance_queue',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*),jsonb_build_object('runRows',count(*))
  FROM public.finance_posting_queue_runs WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'step_4d_runtime_inventory','INFO',0,
    jsonb_build_object('detachedDrafts',count(*) FILTER(WHERE session_id IS NULL),
      'attachedDrafts',count(*) FILTER(WHERE session_id IS NOT NULL))
  FROM public.sales_headers WHERE sales_origin='BACKOFFICE_CUTOVER'
    AND document_status='DRAFT'
  UNION ALL
  SELECT 'preflight_revision','INFO',0,
    jsonb_build_object('revision','STEP_4D_V1_ONE_RESULT','writes',false,
      'executionRule','Run the entire file; do not run selected text')
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'PASS' THEN 2 WHEN 'SETUP' THEN 3 ELSE 4 END,
  check_name;
