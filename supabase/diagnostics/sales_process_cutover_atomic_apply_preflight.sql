-- Step 4E/6 SELECT-only preflight. Run the entire file in isolated Development.
WITH required_migrations(version) AS (VALUES
  ('20260909162000'),('20260909163000'),('20260910110000'),('20260910120000'),
  ('20260910130000'),('20260910140000'),('20260910152000'),('20260910153000'),
  ('20260911100000'),('20260911110000'),('20260911111000'),('20260911120000')
), required_routines(signature) AS (VALUES
  ('private.get_sales_process_cutover_plan_core(uuid,uuid)'),
  ('private.get_sales_process_cutover_preview_core(uuid,text)'),
  ('private.convert_retail_sale_to_backoffice_order(uuid,uuid,uuid,uuid)'),
  ('private.convert_backoffice_order_to_retail_sale(uuid,uuid,uuid,uuid)'),
  ('public.save_pos_sale_draft(jsonb)'),
  ('public.save_backoffice_sales_order_draft(uuid,bigint,uuid,jsonb)'),
  ('public.start_pos_sales_order_revision(uuid,bigint,uuid,uuid,text)'),
  ('public.submit_pos_offline_sale(jsonb)')
), checks AS (
  SELECT 'step_4e_dependency_ledger' check_name,
    CASE WHEN count(migration.version)=12 THEN 'PASS' ELSE 'BLOCKER' END status,
    (12-count(migration.version))::bigint violation_rows,
    jsonb_build_object('expected',12,'present',count(migration.version),
      'missing',COALESCE(jsonb_agg(required.version) FILTER(WHERE migration.version IS NULL),'[]')) details
  FROM required_migrations required LEFT JOIN private.kgs_schema_migrations migration
    ON migration.version=required.version
  UNION ALL
  SELECT 'step_4e_routine_contract',CASE WHEN count(resolved.signature)=8 THEN 'PASS' ELSE 'BLOCKER' END,
    (8-count(resolved.signature))::bigint,
    jsonb_build_object('expected',8,'present',count(resolved.signature),
      'missing',COALESCE(jsonb_agg(required.signature) FILTER(WHERE resolved.signature IS NULL),'[]'))
  FROM required_routines required LEFT JOIN LATERAL(
    SELECT required.signature WHERE to_regprocedure(required.signature) IS NOT NULL) resolved ON true
  UNION ALL
  SELECT 'step_4e_apply_collision',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('existing',COALESCE(jsonb_agg(signature),'[]'))
  FROM (SELECT signature FROM (VALUES
    ('private.assert_sales_process_root_creation_allowed(uuid,text)'),
    ('private.get_sales_process_cutover_plan_before_atomic_apply(uuid,uuid)'),
    ('private.apply_sales_process_cutover_plan_core(uuid,uuid,uuid,bigint,bigint,uuid)'),
    ('public.apply_sales_process_cutover_plan(uuid,bigint,bigint,uuid)')) candidate(signature)
    WHERE to_regprocedure(signature) IS NOT NULL) collision
  UNION ALL
  SELECT 'step_4e_retail_identity_guard_dependency',CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN count(*)=1 THEN 0 ELSE 1 END::bigint,jsonb_build_object('matchingRows',count(*))
  FROM pg_proc procedure JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname='private' AND procedure.proname='trg_guard_sales_process_identity'
    AND pg_get_functiondef(procedure.oid) LIKE '%BACKOFFICE_CUTOVER_SCOPE_IMMUTABLE%'
    AND EXISTS(SELECT 1 FROM pg_trigger trigger
      WHERE trigger.tgrelid='public.sales_headers'::regclass
        AND trigger.tgname='sales_headers_process_identity_guard' AND NOT trigger.tgisinternal)
  UNION ALL
  SELECT 'step_4e_open_plan_inventory','INFO',count(*)::bigint,
    jsonb_build_object('plans',COALESCE(jsonb_agg(jsonb_build_object(
      'planId',plan.id,'companyId',plan.company_id,'status',plan.status,
      'sourceMode',plan.source_mode,'targetMode',plan.target_mode)),'[]'))
  FROM public.sales_process_cutover_plans plan
  WHERE plan.status IN('DRAFT','PREVIEWED','APPLYING')
  UNION ALL
  SELECT 'step_4e_active_finance_queue',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('runRows',count(*)) FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'step_4e_nonterminal_offline',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('submissionRows',count(*)) FROM public.pos_offline_sale_submissions
    WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
  UNION ALL
  SELECT 'step_4e_setting_shape',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('invalidRows',count(*)) FROM public.company_sales_process_settings setting
    WHERE setting.active_mode NOT IN('RETAIL_CONFIRM_INVOICE','BACKOFFICE_DELIVERED_QTY_INVOICE')
      OR setting.master_version<1
  UNION ALL
  SELECT 'step_4e_setting_coverage',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('companiesWithoutSetting',count(*))
  FROM public.companies company LEFT JOIN public.company_sales_process_settings setting
    ON setting.company_id=company.id WHERE setting.company_id IS NULL
  UNION ALL
  SELECT 'step_4e_behavior_fixture',CASE WHEN count(*)>0 THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN count(*)>0 THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('eligibleCompanies',count(*),
      'rule','Active canonical Company with no open cutover plan, Finance queue or Offline submission')
  FROM public.companies company
  JOIN public.company_sales_process_settings setting ON setting.company_id=company.id
  WHERE company.status='ACTIVE'
    AND EXISTS(SELECT 1 FROM public.profiles profile WHERE profile.role::text='super_admin')
    AND EXISTS(SELECT 1 FROM public.stores store
      WHERE store.company_id=company.id AND store.status='ACTIVE')
    AND EXISTS(SELECT 1 FROM public.warehouses warehouse
      WHERE warehouse.company_id=company.id AND warehouse.is_active AND warehouse.is_sale_source)
    AND EXISTS(SELECT 1 FROM public.customers customer
      WHERE customer.company_id=company.id AND customer.is_active)
    AND EXISTS(SELECT 1 FROM public.product_uoms product_uom
      JOIN public.products product ON product.company_id=product_uom.company_id
        AND product.id=product_uom.product_id AND product.is_active AND NOT product.is_bundle
      JOIN public.uoms uom ON uom.company_id=product_uom.company_id
        AND uom.id=product_uom.uom_id AND uom.is_active
      WHERE product_uom.company_id=company.id AND product_uom.is_active
        AND product_uom.sales_allowed AND product_uom.sale_price>0)
    AND NOT EXISTS(SELECT 1 FROM public.finance_posting_queue_runs queue
      WHERE queue.company_id=company.id AND queue.status IN('PREVIEWED','APPROVED','PROCESSING'))
    AND NOT EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions submission
      WHERE submission.company_id=company.id
        AND submission.status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION'))
    AND NOT EXISTS(SELECT 1 FROM public.sales_process_cutover_plans plan
      WHERE plan.company_id=company.id AND plan.status IN('DRAFT','PREVIEWED','APPLYING'))
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'FAIL' THEN 2 WHEN 'PASS' THEN 3 ELSE 4 END,check_name;
