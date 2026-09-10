-- SELECT-only preflight for 20260910100000.
WITH routine_state AS (
  SELECT pg_get_functiondef(
    'private.save_pos_sale_draft_before_schedule_core(jsonb)'::regprocedure
  ) definition
), public_wrapper_state AS (
  SELECT lower(regexp_replace(pg_get_functiondef(
    'public.save_pos_sale_draft_with_pricelist(jsonb)'::regprocedure),
    '[[:space:]]+','','g')) definition
), checks AS (
  SELECT 'scheduled_resume_dependency_chain'::text check_name,
    CASE WHEN count(*)=6 THEN 'PASS' ELSE 'BLOCKER' END status,
    abs(6-count(*))::bigint violation_rows,
    jsonb_build_object('expected',6,'ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version IN(
    '20260827090000','20260827154000','20260830100000',
    '20260904110000','20260904130000','20260904140000')
  UNION ALL
  SELECT 'scheduled_resume_runtime_state',
    CASE WHEN to_regprocedure(
        'private.validate_pos_scheduled_order_dates(uuid,date,timestamptz,text,timestamptz)') IS NOT NULL
      AND to_regprocedure(
        'private.validate_pos_tempo_effective_dates(uuid,timestamptz,timestamptz,text,timestamptz)') IS NOT NULL
      AND to_regprocedure(
        'private.save_pos_sale_draft_before_schedule_core(jsonb)') IS NOT NULL
      AND to_regprocedure(
        'public.save_pos_sale_draft_with_pricelist(jsonb)') IS NOT NULL
      AND to_regprocedure('private.save_pos_sale_draft_core(jsonb)') IS NOT NULL
      AND to_regprocedure('public.post_pos_sale(uuid,bigint,uuid)') IS NOT NULL
      THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN to_regprocedure(
        'private.validate_pos_scheduled_order_dates(uuid,date,timestamptz,text,timestamptz)') IS NOT NULL
      AND to_regprocedure(
        'private.validate_pos_tempo_effective_dates(uuid,timestamptz,timestamptz,text,timestamptz)') IS NOT NULL
      AND to_regprocedure(
        'private.save_pos_sale_draft_before_schedule_core(jsonb)') IS NOT NULL
      AND to_regprocedure(
        'public.save_pos_sale_draft_with_pricelist(jsonb)') IS NOT NULL
      AND to_regprocedure('private.save_pos_sale_draft_core(jsonb)') IS NOT NULL
      AND to_regprocedure('public.post_pos_sale(uuid,bigint,uuid)') IS NOT NULL
      THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('requiredRoutines',6)
  UNION ALL
  SELECT 'scheduled_resume_definition_before_fix',
    CASE WHEN count(*)=1
      AND bool_and(position('validate_pos_tempo_effective_dates' in definition)>0)
      AND bool_and(position('validate_pos_tempo_draft_save_dates' in definition)=0)
      THEN 'SETUP' ELSE 'BLOCKER' END,
    CASE WHEN count(*)=1
      AND bool_and(position('validate_pos_tempo_effective_dates' in definition)>0)
      AND bool_and(position('validate_pos_tempo_draft_save_dates' in definition)=0)
      THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('legacyDefinitionRows',count(*))
  FROM routine_state
  UNION ALL
  SELECT 'scheduled_public_wrapper_contract',
    CASE WHEN count(*)=1 AND bool_and(
      position('private.save_pos_sale_draft_before_schedule_core(v_core_payload)'
        in definition)>0
      AND position('v_mode:=''scheduled''' in definition)>0
      AND position('scheduled_order_tempo_required' in definition)>0)
      THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN count(*)=1 AND bool_and(
      position('private.save_pos_sale_draft_before_schedule_core(v_core_payload)'
        in definition)>0
      AND position('v_mode:=''scheduled''' in definition)>0
      AND position('scheduled_order_tempo_required' in definition)>0)
      THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('wrapperRows',count(*))
  FROM public_wrapper_state
  UNION ALL
  SELECT 'scheduled_early_post_guard',
    CASE WHEN position('SCHEDULED_ORDER_NOT_ACTIVE' in pg_get_functiondef(
      'public.post_pos_sale(uuid,bigint,uuid)'::regprocedure))>0
      THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN position('SCHEDULED_ORDER_NOT_ACTIVE' in pg_get_functiondef(
      'public.post_pos_sale(uuid,bigint,uuid)'::regprocedure))>0
      THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('guardPresent',position('SCHEDULED_ORDER_NOT_ACTIVE'
      in pg_get_functiondef(
        'public.post_pos_sale(uuid,bigint,uuid)'::regprocedure))>0)
  UNION ALL
  SELECT 'scheduled_resume_optimistic_version_guard',
    CASE WHEN position('MASTER_VERSION_CONFLICT' in pg_get_functiondef(
      'private.save_pos_sale_draft_core(jsonb)'::regprocedure))>0
      THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN position('MASTER_VERSION_CONFLICT' in pg_get_functiondef(
      'private.save_pos_sale_draft_core(jsonb)'::regprocedure))>0
      THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('guardPresent',position('MASTER_VERSION_CONFLICT'
      in pg_get_functiondef(
        'private.save_pos_sale_draft_core(jsonb)'::regprocedure))>0)
  UNION ALL
  SELECT 'scheduled_resume_helper_collision',
    CASE WHEN to_regprocedure(
      'private.validate_pos_tempo_draft_save_dates(uuid,text,date,timestamptz,timestamptz,text,timestamptz,text)'
      ) IS NULL THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN to_regprocedure(
      'private.validate_pos_tempo_draft_save_dates(uuid,text,date,timestamptz,timestamptz,text,timestamptz,text)'
      ) IS NULL THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('helperExists',to_regprocedure(
      'private.validate_pos_tempo_draft_save_dates(uuid,text,date,timestamptz,timestamptz,text,timestamptz,text)'
      ) IS NOT NULL)
  UNION ALL
  SELECT 'scheduled_draft_canonical_shape',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('invalidRows',count(*))
  FROM public.sales_headers sale
  WHERE sale.document_status='DRAFT' AND sale.order_timing_mode='SCHEDULED'
    AND (NOT sale.is_tempo OR sale.planned_order_date IS NULL
      OR sale.planned_order_selected_by IS NULL
      OR sale.planned_order_selected_at IS NULL)
  UNION ALL
  SELECT 'scheduled_draft_payload_tempo_contract',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('invalidRows',count(*),
      'draftNumbers',COALESCE(jsonb_agg(sale.draft_no ORDER BY sale.draft_no),'[]'::jsonb))
  FROM public.sales_headers sale
  JOIN public.companies company ON company.id=sale.company_id
  WHERE sale.document_status='DRAFT' AND sale.order_timing_mode='SCHEDULED'
    AND (sale.payload_snapshot IS NULL OR NOT(sale.payload_snapshot?'isTempo')
      OR jsonb_typeof(sale.payload_snapshot->'isTempo')<>'boolean'
      OR sale.payload_snapshot->'isTempo'<>'true'::jsonb
      OR NULLIF(sale.payload_snapshot->>'plannedOrderAt','') IS NULL
      OR (NULLIF(sale.payload_snapshot->>'plannedOrderAt','')::timestamptz
            AT TIME ZONE company.timezone)::date
          IS DISTINCT FROM sale.planned_order_date)
  UNION ALL
  SELECT 'future_scheduled_resume_inventory','INFO',0::bigint,
    jsonb_build_object('candidateRows',count(*),
      'draftNumbers',COALESCE(jsonb_agg(sale.draft_no ORDER BY sale.draft_no),'[]'::jsonb))
  FROM public.sales_headers sale
  JOIN public.companies company ON company.id=sale.company_id
  WHERE sale.document_status='DRAFT' AND sale.confirmed_at IS NULL
    AND sale.order_runtime_status='SCHEDULED'
    AND sale.order_timing_mode='SCHEDULED' AND sale.is_tempo
    AND sale.planned_order_date>(clock_timestamp() AT TIME ZONE company.timezone)::date
  UNION ALL
  SELECT 'active_finance_posting_queue','INFO',0::bigint,
    jsonb_build_object('runRows',count(*))
  FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'nonterminal_offline_submission','INFO',0::bigint,
    jsonb_build_object('submissionRows',count(*))
  FROM public.pos_offline_sale_submissions
  WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 0 WHEN 'PASS' THEN 1
  WHEN 'SETUP' THEN 2 ELSE 3 END,check_name;
