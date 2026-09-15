-- Persist an exact, version-locked cutover preview without applying a mode switch.
BEGIN;

DO $guard$
BEGIN
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260910110000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260910110000';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260909163000')
    OR to_regclass('public.sales_process_cutover_plans') IS NULL
    OR to_regclass('public.sales_process_cutover_items') IS NULL
    OR to_regclass('public.sales_process_cutover_audit') IS NULL
    OR to_regprocedure('private.get_sales_process_cutover_preview_core(uuid,text)') IS NULL
    OR to_regprocedure('extensions.digest(bytea,text)') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: persistent preview dependency incomplete';
  END IF;
  IF to_regprocedure('private.get_sales_process_cutover_plan_core(uuid,uuid)') IS NOT NULL
    OR to_regprocedure('private.create_sales_process_cutover_plan_core(uuid,uuid,text,timestamp with time zone,bigint,uuid,text)') IS NOT NULL
    OR to_regprocedure('public.get_sales_process_cutover_plan(uuid)') IS NOT NULL
    OR to_regprocedure('public.create_sales_process_cutover_plan(text,timestamp with time zone,bigint,uuid,text)') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: persistent preview routine collision';
  END IF;
END
$guard$;

CREATE FUNCTION private.get_sales_process_cutover_plan_core(
  p_company_id uuid,p_plan_id uuid
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='8s' AS $$
DECLARE v_plan public.sales_process_cutover_plans%rowtype;v_items jsonb;
BEGIN
  SELECT plan.* INTO STRICT v_plan
  FROM public.sales_process_cutover_plans plan
  WHERE plan.company_id=p_company_id AND plan.id=p_plan_id;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'itemId',item.id,
      'sourceMode',item.source_mode,
      'targetMode',item.target_mode,
      'sourceDocumentType',item.source_document_type,
      'sourceDocumentId',item.source_document_id,
      'sourceDocumentNo',item.source_document_no,
      'sourceStatus',item.source_status,
      'sourceMasterVersion',item.source_master_version,
      'decision',item.decision,
      'itemStatus',item.item_status,
      'blockerCodes',item.blocker_codes,
      'requirementCodes',item.requirement_codes,
      'sourceSnapshot',item.source_snapshot,
      'targetDocumentType',item.target_document_type,
      'targetDocumentId',item.target_document_id,
      'targetDocumentNo',item.target_document_no,
      'createdAt',item.created_at,
      'updatedAt',item.updated_at)
    ORDER BY item.source_document_type,item.source_document_no,item.id),'[]'::jsonb)
  INTO v_items
  FROM public.sales_process_cutover_items item
  WHERE item.company_id=p_company_id AND item.cutover_plan_id=p_plan_id;

  RETURN jsonb_build_object(
    'planId',v_plan.id,
    'companyId',v_plan.company_id,
    'sourceMode',v_plan.source_mode,
    'targetMode',v_plan.target_mode,
    'effectiveAt',v_plan.effective_at,
    'selectionPolicy',v_plan.selection_policy,
    'status',v_plan.status,
    'reason',v_plan.reason,
    'expectedSettingsVersion',v_plan.expected_settings_version,
    'operationId',v_plan.operation_id,
    'requestHash',v_plan.request_hash,
    'previewSnapshot',v_plan.preview_snapshot,
    'createdBy',v_plan.created_by,
    'createdAt',v_plan.created_at,
    'updatedAt',v_plan.updated_at,
    'items',v_items,
    'readOnlyPlanView',true);
EXCEPTION WHEN NO_DATA_FOUND THEN
  RAISE EXCEPTION 'SALES_PROCESS_CUTOVER_PLAN_NOT_FOUND';
END
$$;

CREATE FUNCTION private.create_sales_process_cutover_plan_core(
  p_actor uuid,p_company_id uuid,p_target_mode text,p_effective_at timestamptz,
  p_expected_settings_version bigint,p_operation_id uuid,p_reason text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='15s' AS $$
DECLARE v_setting public.company_sales_process_settings%rowtype;
  v_existing public.sales_process_cutover_plans%rowtype;v_plan_id uuid;
  v_preview jsonb;v_candidate jsonb;v_request_hash text;v_reason text;
BEGIN
  IF p_actor IS NULL OR p_company_id IS NULL THEN
    RAISE EXCEPTION 'AUTHENTICATION_REQUIRED';
  END IF;
  IF p_operation_id IS NULL THEN
    RAISE EXCEPTION 'SALES_PROCESS_CUTOVER_OPERATION_ID_REQUIRED';
  END IF;
  IF p_effective_at IS NULL OR NOT isfinite(p_effective_at) THEN
    RAISE EXCEPTION 'SALES_PROCESS_CUTOVER_EFFECTIVE_AT_INVALID';
  END IF;
  IF p_expected_settings_version IS NULL OR p_expected_settings_version<1 THEN
    RAISE EXCEPTION 'SALES_PROCESS_CUTOVER_SETTINGS_VERSION_REQUIRED';
  END IF;
  v_reason:=nullif(btrim(COALESCE(p_reason,'')),'');
  IF v_reason IS NULL OR length(v_reason)>500 THEN
    RAISE EXCEPTION 'SALES_PROCESS_CUTOVER_REASON_INVALID';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(p_company_id::text,20260910110000));
  SELECT setting.* INTO STRICT v_setting
  FROM public.company_sales_process_settings setting
  WHERE setting.company_id=p_company_id
  FOR UPDATE;

  v_request_hash:=encode(extensions.digest(convert_to(jsonb_build_object(
    'companyId',p_company_id,
    'targetMode',p_target_mode,
    'effectiveAt',p_effective_at,
    'expectedSettingsVersion',p_expected_settings_version,
    'selectionPolicy','CONVERT_ELIGIBLE_KEEP_BLOCKED',
    'reason',v_reason)::text,'UTF8'),'sha256'),'hex');

  SELECT plan.* INTO v_existing
  FROM public.sales_process_cutover_plans plan
  WHERE plan.company_id=p_company_id AND plan.operation_id=p_operation_id;
  IF FOUND THEN
    IF v_existing.request_hash<>v_request_hash THEN
      RAISE EXCEPTION 'SALES_PROCESS_CUTOVER_IDEMPOTENCY_PAYLOAD_CONFLICT';
    END IF;
    RETURN private.get_sales_process_cutover_plan_core(p_company_id,v_existing.id);
  END IF;

  IF p_target_mode NOT IN('RETAIL_CONFIRM_INVOICE','BACKOFFICE_DELIVERED_QTY_INVOICE')
    OR p_target_mode=v_setting.active_mode THEN
    RAISE EXCEPTION 'SALES_PROCESS_CUTOVER_TARGET_INVALID';
  END IF;
  IF v_setting.master_version<>p_expected_settings_version THEN
    RAISE EXCEPTION 'SALES_PROCESS_CUTOVER_SETTINGS_VERSION_STALE';
  END IF;
  IF EXISTS(SELECT 1 FROM public.sales_process_cutover_plans plan
    WHERE plan.company_id=p_company_id
      AND plan.status IN('DRAFT','PREVIEWED','APPLYING')) THEN
    RAISE EXCEPTION 'SALES_PROCESS_CUTOVER_OPEN_PLAN_EXISTS';
  END IF;

  v_preview:=private.get_sales_process_cutover_preview_core(p_company_id,p_target_mode);
  IF (v_preview->>'settingsVersion')::bigint<>p_expected_settings_version
    OR v_preview->>'currentMode'<>v_setting.active_mode
    OR v_preview->>'targetMode'<>p_target_mode THEN
    RAISE EXCEPTION 'SALES_PROCESS_CUTOVER_PREVIEW_VERSION_DRIFT';
  END IF;

  INSERT INTO public.sales_process_cutover_plans(company_id,source_mode,target_mode,
    effective_at,selection_policy,status,reason,expected_settings_version,
    operation_id,request_hash,preview_snapshot,created_by)
  VALUES(p_company_id,v_setting.active_mode,p_target_mode,p_effective_at,
    'CONVERT_ELIGIBLE_KEEP_BLOCKED','PREVIEWED',v_reason,
    p_expected_settings_version,p_operation_id,v_request_hash,v_preview,p_actor)
  RETURNING id INTO v_plan_id;

  FOR v_candidate IN SELECT value FROM jsonb_array_elements(v_preview->'candidates')
  LOOP
    INSERT INTO public.sales_process_cutover_items(company_id,cutover_plan_id,
      source_mode,target_mode,source_document_type,source_document_id,
      source_document_no,source_status,source_master_version,decision,item_status,
      blocker_codes,requirement_codes,source_snapshot)
    VALUES(p_company_id,v_plan_id,v_setting.active_mode,p_target_mode,
      v_candidate->>'sourceDocumentType',(v_candidate->>'sourceDocumentId')::uuid,
      v_candidate->>'sourceDocumentNo',v_candidate->>'sourceStatus',
      (v_candidate->>'sourceMasterVersion')::bigint,v_candidate->>'decision','PLANNED',
      COALESCE(v_candidate->'blockerCodes','[]'::jsonb),
      COALESCE(v_candidate->'requirementCodes','[]'::jsonb),
      COALESCE(v_candidate->'facts','{}'::jsonb));
  END LOOP;

  INSERT INTO public.sales_process_cutover_audit(company_id,cutover_plan_id,
    action,actor_id,operation_id,before_state,after_state)
  VALUES(p_company_id,v_plan_id,'CREATE_PLAN',p_actor,p_operation_id,NULL,
    jsonb_build_object('status','PREVIEWED','sourceMode',v_setting.active_mode,
      'targetMode',p_target_mode,'effectiveAt',p_effective_at,
      'expectedSettingsVersion',p_expected_settings_version,
      'candidateCount',jsonb_array_length(v_preview->'candidates'),
      'summary',v_preview->'summary'));

  RETURN private.get_sales_process_cutover_plan_core(p_company_id,v_plan_id);
END
$$;

CREATE FUNCTION public.get_sales_process_cutover_plan(p_plan_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='8s' AS $$
DECLARE v_actor uuid:=auth.uid();v_company uuid;v_role text;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  SELECT profile.role::text INTO v_role FROM public.profiles profile WHERE profile.id=v_actor;
  IF v_role IS DISTINCT FROM 'super_admin' THEN
    RAISE EXCEPTION 'SALES_PROCESS_CUTOVER_SUPER_ADMIN_REQUIRED';
  END IF;
  v_company:=public.private_active_company_id();
  RETURN private.get_sales_process_cutover_plan_core(v_company,p_plan_id);
END
$$;

CREATE FUNCTION public.create_sales_process_cutover_plan(
  p_target_mode text,p_effective_at timestamptz,p_expected_settings_version bigint,
  p_operation_id uuid,p_reason text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='15s' AS $$
DECLARE v_actor uuid:=auth.uid();v_company uuid;v_role text;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  SELECT profile.role::text INTO v_role FROM public.profiles profile WHERE profile.id=v_actor;
  IF v_role IS DISTINCT FROM 'super_admin' THEN
    RAISE EXCEPTION 'SALES_PROCESS_CUTOVER_SUPER_ADMIN_REQUIRED';
  END IF;
  v_company:=public.private_active_company_id();
  RETURN private.create_sales_process_cutover_plan_core(v_actor,v_company,
    p_target_mode,p_effective_at,p_expected_settings_version,p_operation_id,p_reason);
END
$$;

REVOKE ALL ON FUNCTION private.get_sales_process_cutover_plan_core(uuid,uuid),
  private.create_sales_process_cutover_plan_core(uuid,uuid,text,timestamptz,bigint,uuid,text)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.get_sales_process_cutover_plan_core(uuid,uuid),
  private.create_sales_process_cutover_plan_core(uuid,uuid,text,timestamptz,bigint,uuid,text)
TO service_role;
REVOKE ALL ON FUNCTION public.get_sales_process_cutover_plan(uuid),
  public.create_sales_process_cutover_plan(text,timestamptz,bigint,uuid,text)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_sales_process_cutover_plan(uuid),
  public.create_sales_process_cutover_plan(text,timestamptz,bigint,uuid,text)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260910110000','sales_process_cutover_persistent_preview',
  'Persist Super-Admin cutover preview with exact settings/document versions, Company lock, operation idempotency and immutable CREATE_PLAN audit; no mode switch or operational mutation');

COMMIT;
