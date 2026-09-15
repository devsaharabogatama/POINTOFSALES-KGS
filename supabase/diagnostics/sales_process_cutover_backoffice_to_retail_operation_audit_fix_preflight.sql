-- SELECT-only preflight for Step 4C operation/audit FK forward-fix.
WITH definition AS (
  SELECT pg_get_functiondef(
    'private.convert_backoffice_order_to_retail_sale(uuid,uuid,uuid,uuid)'::regprocedure
  ) body
), checks AS (
  SELECT 'step_4c_audit_fix_base_ledger'::text check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END status,
    abs(1-count(*))::bigint violation_rows,
    jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260911110000'
  UNION ALL
  SELECT 'step_4c_audit_fix_collision',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('existingLedgerRows',count(*))
  FROM private.kgs_schema_migrations WHERE version='20260911111000'
  UNION ALL
  SELECT 'step_4c_audit_fix_definition_contract',
    CASE WHEN body LIKE '%VALUES(p_company_id,v_source.id,gen_random_uuid(),''CANCEL'',p_actor_id,v_reason,v_before,%'
      AND body NOT LIKE '%VALUES(p_company_id,p_operation_id,''CANCEL'',v_source.id,%'
      THEN 'SETUP' ELSE 'BLOCKER' END,
    CASE WHEN body LIKE '%VALUES(p_company_id,v_source.id,gen_random_uuid(),''CANCEL'',p_actor_id,v_reason,v_before,%'
      AND body NOT LIKE '%VALUES(p_company_id,p_operation_id,''CANCEL'',v_source.id,%'
      THEN 1 ELSE 0 END::bigint,
    jsonb_build_object('required','Known Step 4C missing parent operation defect')
  FROM definition
  UNION ALL
  SELECT 'step_4c_audit_fix_fk_contract',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END,abs(1-count(*))::bigint,
    jsonb_build_object('fkRows',count(*))
  FROM pg_constraint constraint_row
  WHERE constraint_row.conrelid='public.backoffice_sales_order_audit'::regclass
    AND constraint_row.conname='backoffice_sales_order_audit_operation_fk'
  UNION ALL
  SELECT 'step_4c_audit_fix_digest_dependency',
    CASE WHEN to_regprocedure('extensions.digest(bytea,text)') IS NOT NULL
      THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN to_regprocedure('extensions.digest(bytea,text)') IS NOT NULL
      THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('digestExists',
      to_regprocedure('extensions.digest(bytea,text)') IS NOT NULL)
  UNION ALL
  SELECT 'step_4c_audit_fix_active_finance_queue',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('activeRuns',count(*))
  FROM public.finance_posting_queue_runs WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'step_4c_audit_fix_nonterminal_offline',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('submissions',count(*))
  FROM public.pos_offline_sale_submissions WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
  UNION ALL
  SELECT 'step_4c_audit_fix_open_plan',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('openPlans',count(*))
  FROM public.sales_process_cutover_plans WHERE status IN('DRAFT','PREVIEWED','APPLYING')
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 0 WHEN 'SETUP' THEN 1 ELSE 2 END,check_name;
