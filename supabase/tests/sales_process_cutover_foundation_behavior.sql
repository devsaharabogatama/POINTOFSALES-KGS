-- Rollback-only behavior for cutover classification and persistence contracts.
BEGIN;
DO $test$
DECLARE v_actor uuid;v_company uuid;v_plan uuid:=gen_random_uuid();
  v_item uuid:=gen_random_uuid();v_result jsonb;v_blocked boolean:=false;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260909162000') THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: cutover foundation required';
  END IF;
  SELECT profile.id INTO v_actor FROM public.profiles profile
  JOIN auth.users auth_user ON auth_user.id=profile.id
  WHERE profile.role='super_admin'::public.user_role ORDER BY profile.id LIMIT 1;
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: linked Super Admin profile required';
  END IF;
  SELECT setting.company_id INTO v_company FROM public.company_sales_process_settings setting
  JOIN public.companies company ON company.id=setting.company_id
  WHERE company.status='ACTIVE' ORDER BY setting.company_id LIMIT 1;
  IF v_company IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: active Company setting required';
  END IF;

  v_result:=private.classify_sales_process_conversion_candidate(
    'RETAIL_CONFIRM_INVOICE','BACKOFFICE_DELIVERED_QTY_INVOICE',false,
    false,false,false,false,true,true,true);
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260910130000') THEN
    IF v_result->>'decision'<>'BLOCKED'
      OR NOT (v_result->'blockerCodes' ? 'PENDING_REVISION_MUST_RESOLVE')
      OR v_result->'requirementCodes' ? 'CONVERT_REVISION_PAIR' THEN
      RAISE EXCEPTION 'TEST_FAILED: canonical pending Revision blocker invalid';
    END IF;
  ELSIF v_result->>'decision'<>'CONVERT'
    OR NOT (v_result->'requirementCodes' ? 'FORMAL_CANCEL_SOURCE_INVOICE')
    OR NOT (v_result->'requirementCodes' ? 'CONVERT_REVISION_PAIR')
    OR NOT (v_result->'requirementCodes' ? 'TRANSFER_PROCUREMENT_LINEAGE') THEN
    RAISE EXCEPTION 'TEST_FAILED: foundation Retail conversion requirements invalid';
  END IF;
  v_result:=private.classify_sales_process_conversion_candidate(
    'BACKOFFICE_DELIVERED_QTY_INVOICE','RETAIL_CONFIRM_INVOICE',false,
    true,true,true,true,false,false,false);
  IF v_result->>'decision'<>'BLOCKED' OR jsonb_array_length(v_result->'blockerCodes')<>4 THEN
    RAISE EXCEPTION 'TEST_FAILED: irreversible Office conversion was not blocked';
  END IF;
  v_result:=private.classify_sales_process_conversion_candidate(
    'RETAIL_CONFIRM_INVOICE','BACKOFFICE_DELIVERED_QTY_INVOICE',true,
    false,false,false,false,false,false,false);
  IF v_result->>'decision'<>'KEEP_SOURCE' THEN
    RAISE EXCEPTION 'TEST_FAILED: final source was not kept';
  END IF;
  BEGIN
    PERFORM private.classify_sales_process_conversion_candidate(
      'RETAIL_CONFIRM_INVOICE','RETAIL_CONFIRM_INVOICE',false,
      false,false,false,false,false,false,false);
  EXCEPTION WHEN OTHERS THEN
    v_blocked:=SQLERRM LIKE '%SALES_PROCESS_CONVERSION_MODE_INVALID%';
  END;
  IF NOT v_blocked THEN RAISE EXCEPTION 'TEST_FAILED: same-mode conversion accepted'; END IF;

  INSERT INTO public.sales_process_cutover_plans(id,company_id,source_mode,target_mode,
    effective_at,reason,expected_settings_version,operation_id,request_hash,
    preview_snapshot,created_by)
  SELECT v_plan,v_company,setting.active_mode,
    CASE setting.active_mode WHEN 'RETAIL_CONFIRM_INVOICE'
      THEN 'BACKOFFICE_DELIVERED_QTY_INVOICE' ELSE 'RETAIL_CONFIRM_INVOICE' END,
    clock_timestamp()+interval '1 day','Behavioral rollback-only cutover plan',
    setting.master_version,gen_random_uuid(),repeat('a',64),'{}',v_actor
  FROM public.company_sales_process_settings setting WHERE setting.company_id=v_company;
  v_result:=private.classify_sales_process_conversion_candidate(
    (SELECT source_mode FROM public.sales_process_cutover_plans WHERE id=v_plan),
    (SELECT target_mode FROM public.sales_process_cutover_plans WHERE id=v_plan),
    false,false,false,false,false,true,false,true);
  INSERT INTO public.sales_process_cutover_items(id,company_id,cutover_plan_id,
    source_mode,target_mode,source_document_type,source_document_id,source_document_no,
    source_status,source_master_version,decision,blocker_codes,requirement_codes,
    source_snapshot)
  SELECT v_item,v_company,v_plan,plan.source_mode,plan.target_mode,
    CASE plan.source_mode WHEN 'RETAIL_CONFIRM_INVOICE' THEN 'RETAIL_SALE'
      ELSE 'BACKOFFICE_SALES_ORDER' END,gen_random_uuid(),'BEHAVIOR-DOC-1','ACTIVE',1,
    v_result->>'decision',v_result->'blockerCodes',v_result->'requirementCodes',
    jsonb_build_object('rollbackOnly',true)
  FROM public.sales_process_cutover_plans plan WHERE plan.id=v_plan;
  INSERT INTO public.sales_process_cutover_audit(company_id,cutover_plan_id,
    cutover_item_id,action,actor_id,operation_id,after_state)
  VALUES(v_company,v_plan,v_item,'CREATE_PLAN',v_actor,gen_random_uuid(),
    jsonb_build_object('status','DRAFT'));
  IF (SELECT decision FROM public.sales_process_cutover_items WHERE id=v_item)<>'CONVERT' THEN
    RAISE EXCEPTION 'TEST_FAILED: planned eligible item not persisted';
  END IF;
  v_blocked:=false;
  BEGIN
    UPDATE public.company_sales_process_settings SET master_version=master_version+1
    WHERE company_id=v_company;
  EXCEPTION WHEN OTHERS THEN
    v_blocked:=SQLERRM LIKE '%SALES_PROCESS_SETTING_RUNTIME_REQUIRED%';
  END;
  IF NOT v_blocked THEN RAISE EXCEPTION 'TEST_FAILED: direct mode setting update accepted'; END IF;
  v_blocked:=false;
  BEGIN
    UPDATE public.sales_process_cutover_audit SET after_state='{"tampered":true}'::jsonb
    WHERE company_id=v_company AND cutover_plan_id=v_plan;
  EXCEPTION WHEN OTHERS THEN
    v_blocked:=SQLERRM LIKE '%SALES_PROCESS_HISTORY_IMMUTABLE%';
  END;
  IF NOT v_blocked THEN RAISE EXCEPTION 'TEST_FAILED: cutover audit mutation accepted'; END IF;
END
$test$;
ROLLBACK;
SELECT 'sales_process_cutover_foundation_behavior' check_name,'PASS' status,
  0::bigint violation_rows,jsonb_build_object('tested',ARRAY[
    'current canonical pending Revision classification',
    'Retail eligible conversion with Invoice and Procurement requirements',
    'Office irreversible conversion blocked','final document kept in source process',
    'same-mode conversion rejected','plan and candidate persistence',
    'direct Company mode mutation rejected','cutover audit immutable',
    'all fixture writes rolled back']) details;
