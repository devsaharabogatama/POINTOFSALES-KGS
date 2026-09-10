-- SELECT-only postflight for 20260910100000.
WITH functions AS (
  SELECT namespace.nspname schema_name,proc.proname,
    proc.prosecdef,proc.provolatile,proc.proconfig,pg_get_functiondef(proc.oid) definition
  FROM pg_proc proc JOIN pg_namespace namespace ON namespace.oid=proc.pronamespace
  WHERE (namespace.nspname='private' AND proc.proname IN(
    'validate_pos_tempo_draft_save_dates','save_pos_sale_draft_before_schedule_core'))
), checks AS (
  SELECT 'migration_ledger'::text check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(1-count(*))::bigint violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260910100000'
  UNION ALL
  SELECT 'scheduled_resume_required_routines',
    CASE WHEN count(*)=2 THEN 'PASS' ELSE 'FAIL' END,abs(2-count(*))::bigint,
    jsonb_build_object('routineRows',count(*)) FROM functions
  UNION ALL
  SELECT 'scheduled_resume_security_contract',
    CASE WHEN count(*)=2 AND bool_and(prosecdef)
      AND bool_and(proconfig @>ARRAY['search_path=public, pg_temp'])
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=2 AND bool_and(prosecdef)
      AND bool_and(proconfig @>ARRAY['search_path=public, pg_temp'])
      THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('routineRows',count(*),'securityDefiner',
      COALESCE(bool_and(prosecdef),false)) FROM functions
  UNION ALL
  SELECT 'scheduled_resume_definition_contract',
    CASE WHEN count(*)=1 AND bool_and(
      position('validate_pos_tempo_draft_save_dates' in definition)>0
      AND position('validate_pos_tempo_effective_dates' in definition)=0
      AND position('v_existing_payload->>''plannedOrderAt''' in definition)>0
      AND position('''plannedOrderAt'',v_requested_at' in definition)>0
      AND position('v_sale.order_timing_mode=''SCHEDULED''' in definition)>0)
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1 AND bool_and(
      position('validate_pos_tempo_draft_save_dates' in definition)>0
      AND position('validate_pos_tempo_effective_dates' in definition)=0
      AND position('v_existing_payload->>''plannedOrderAt''' in definition)>0
      AND position('''plannedOrderAt'',v_requested_at' in definition)>0
      AND position('v_sale.order_timing_mode=''SCHEDULED''' in definition)>0)
      THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('wrapperRows',count(*),
      'preservesScheduledTimestamp',COALESCE(bool_and(
        position('v_existing_payload->>''plannedOrderAt''' in definition)>0
        AND position('''plannedOrderAt'',v_requested_at' in definition)>0),false))
  FROM functions WHERE proname='save_pos_sale_draft_before_schedule_core'
  UNION ALL
  SELECT 'scheduled_resume_helper_contract',
    CASE WHEN count(*)=1 AND bool_and(
      position('SCHEDULED_PRESERVE' in definition)>0
      AND position('validate_pos_scheduled_order_dates' in definition)>0
      AND position('validate_pos_tempo_effective_dates' in definition)>0
      AND position('SCHEDULED_ORDER_DATE_IDENTITY_MISMATCH' in definition)>0)
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1 AND bool_and(
      position('SCHEDULED_PRESERVE' in definition)>0
      AND position('validate_pos_scheduled_order_dates' in definition)>0
      AND position('validate_pos_tempo_effective_dates' in definition)>0
      AND position('SCHEDULED_ORDER_DATE_IDENTITY_MISMATCH' in definition)>0)
      THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('helperRows',count(*))
  FROM functions WHERE proname='validate_pos_tempo_draft_save_dates'
  UNION ALL
  SELECT 'scheduled_resume_private_browser_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('browserExecutableRows',count(*))
  FROM information_schema.routine_privileges privilege
  WHERE privilege.specific_schema='private' AND privilege.privilege_type='EXECUTE'
    AND privilege.routine_name IN(
      'validate_pos_tempo_draft_save_dates','save_pos_sale_draft_before_schedule_core')
    AND privilege.grantee IN('anon','authenticated')
  UNION ALL
  SELECT 'scheduled_draft_canonical_shape',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('invalidRows',count(*))
  FROM public.sales_headers sale
  WHERE sale.document_status='DRAFT' AND sale.order_timing_mode='SCHEDULED'
    AND (NOT sale.is_tempo OR sale.planned_order_date IS NULL
      OR sale.planned_order_selected_by IS NULL
      OR sale.planned_order_selected_at IS NULL)
  UNION ALL
  SELECT 'scheduled_draft_payload_tempo_contract',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
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
  SELECT 'future_scheduled_resume_runtime_inventory','INFO',0::bigint,
    jsonb_build_object('candidateRows',count(*),
      'draftNumbers',COALESCE(jsonb_agg(sale.draft_no ORDER BY sale.draft_no),'[]'::jsonb))
  FROM public.sales_headers sale
  JOIN public.companies company ON company.id=sale.company_id
  WHERE sale.document_status='DRAFT' AND sale.confirmed_at IS NULL
    AND sale.order_runtime_status='SCHEDULED'
    AND sale.order_timing_mode='SCHEDULED' AND sale.is_tempo
    AND sale.planned_order_date>(clock_timestamp() AT TIME ZONE company.timezone)::date
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;
