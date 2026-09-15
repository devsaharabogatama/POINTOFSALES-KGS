-- Refresh/cancel a versioned preview plan without applying any process switch.
BEGIN;

DO $guard$
BEGIN
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260910120000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260910120000';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260910110000')
    OR to_regclass('public.sales_process_cutover_plans') IS NULL
    OR to_regclass('public.sales_process_cutover_items') IS NULL
    OR to_regclass('public.sales_process_cutover_audit') IS NULL
    OR to_regprocedure('private.get_sales_process_cutover_plan_core(uuid,uuid)') IS NULL
    OR to_regprocedure('private.get_sales_process_cutover_preview_core(uuid,text)') IS NULL
    OR to_regprocedure('extensions.digest(bytea,text)') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: persistent preview dependency incomplete';
  END IF;
  IF EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='public'
      AND table_name='sales_process_cutover_plans' AND column_name='master_version')
    OR to_regprocedure('private.refresh_sales_process_cutover_plan_core(uuid,uuid,uuid,bigint,bigint,uuid)') IS NOT NULL
    OR to_regprocedure('private.cancel_sales_process_cutover_plan_core(uuid,uuid,uuid,bigint,uuid,text)') IS NOT NULL
    OR to_regprocedure('public.refresh_sales_process_cutover_plan(uuid,bigint,bigint,uuid)') IS NOT NULL
    OR to_regprocedure('public.cancel_sales_process_cutover_plan(uuid,bigint,uuid,text)') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: refresh/cancel contract collision';
  END IF;
END
$guard$;

ALTER TABLE public.sales_process_cutover_plans
  ADD COLUMN master_version bigint NOT NULL DEFAULT 1,
  ADD CONSTRAINT sales_process_cutover_plans_master_version_check CHECK(master_version>0);

CREATE OR REPLACE FUNCTION private.get_sales_process_cutover_plan_core(
  p_company_id uuid,p_plan_id uuid
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='8s' AS $$
DECLARE v_plan public.sales_process_cutover_plans%rowtype;v_items jsonb;
BEGIN
  SELECT plan.* INTO STRICT v_plan FROM public.sales_process_cutover_plans plan
  WHERE plan.company_id=p_company_id AND plan.id=p_plan_id;
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'itemId',item.id,'sourceMode',item.source_mode,'targetMode',item.target_mode,
      'sourceDocumentType',item.source_document_type,
      'sourceDocumentId',item.source_document_id,'sourceDocumentNo',item.source_document_no,
      'sourceStatus',item.source_status,'sourceMasterVersion',item.source_master_version,
      'decision',item.decision,'itemStatus',item.item_status,
      'blockerCodes',item.blocker_codes,'requirementCodes',item.requirement_codes,
      'sourceSnapshot',item.source_snapshot,'targetDocumentType',item.target_document_type,
      'targetDocumentId',item.target_document_id,'targetDocumentNo',item.target_document_no,
      'createdAt',item.created_at,'updatedAt',item.updated_at)
    ORDER BY item.source_document_type,item.source_document_no,item.id),'[]'::jsonb)
  INTO v_items FROM public.sales_process_cutover_items item
  WHERE item.company_id=p_company_id AND item.cutover_plan_id=p_plan_id;
  RETURN jsonb_build_object('planId',v_plan.id,'companyId',v_plan.company_id,
    'sourceMode',v_plan.source_mode,'targetMode',v_plan.target_mode,
    'effectiveAt',v_plan.effective_at,'selectionPolicy',v_plan.selection_policy,
    'status',v_plan.status,'reason',v_plan.reason,
    'expectedSettingsVersion',v_plan.expected_settings_version,
    'masterVersion',v_plan.master_version,'operationId',v_plan.operation_id,
    'requestHash',v_plan.request_hash,'previewSnapshot',v_plan.preview_snapshot,
    'createdBy',v_plan.created_by,'createdAt',v_plan.created_at,
    'updatedAt',v_plan.updated_at,'canceledBy',v_plan.canceled_by,
    'canceledAt',v_plan.canceled_at,'cancelReason',v_plan.cancel_reason,
    'items',v_items,'readOnlyPlanView',true);
EXCEPTION WHEN NO_DATA_FOUND THEN RAISE EXCEPTION 'SALES_PROCESS_CUTOVER_PLAN_NOT_FOUND';
END
$$;

CREATE FUNCTION private.refresh_sales_process_cutover_plan_core(
  p_actor uuid,p_company_id uuid,p_plan_id uuid,p_expected_plan_version bigint,
  p_expected_settings_version bigint,p_operation_id uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='15s' AS $$
DECLARE v_plan public.sales_process_cutover_plans%rowtype;
  v_setting public.company_sales_process_settings%rowtype;v_audit record;
  v_preview jsonb;v_candidate jsonb;v_before jsonb;v_response jsonb;v_hash text;
BEGIN
  IF p_actor IS NULL OR p_company_id IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF p_plan_id IS NULL OR p_operation_id IS NULL THEN
    RAISE EXCEPTION 'SALES_PROCESS_CUTOVER_REFRESH_IDENTITY_REQUIRED';
  END IF;
  IF p_expected_plan_version IS NULL OR p_expected_plan_version<1
    OR p_expected_settings_version IS NULL OR p_expected_settings_version<1 THEN
    RAISE EXCEPTION 'SALES_PROCESS_CUTOVER_REFRESH_VERSION_REQUIRED';
  END IF;
  v_hash:=encode(extensions.digest(convert_to(jsonb_build_object('companyId',p_company_id,
    'planId',p_plan_id,'expectedPlanVersion',p_expected_plan_version,
    'expectedSettingsVersion',p_expected_settings_version)::text,'UTF8'),'sha256'),'hex');
  PERFORM pg_advisory_xact_lock(hashtextextended(p_company_id::text,20260910120000));
  SELECT audit.* INTO v_audit FROM public.sales_process_cutover_audit audit
  WHERE audit.company_id=p_company_id AND audit.cutover_plan_id=p_plan_id
    AND audit.action='REFRESH_PREVIEW' AND audit.operation_id=p_operation_id;
  IF FOUND THEN
    IF v_audit.after_state->>'requestHash'<>v_hash THEN
      RAISE EXCEPTION 'SALES_PROCESS_CUTOVER_IDEMPOTENCY_PAYLOAD_CONFLICT';
    END IF;
    RETURN v_audit.after_state->'response';
  END IF;
  SELECT plan.* INTO STRICT v_plan FROM public.sales_process_cutover_plans plan
  WHERE plan.company_id=p_company_id AND plan.id=p_plan_id FOR UPDATE;
  IF v_plan.status<>'PREVIEWED' THEN RAISE EXCEPTION 'SALES_PROCESS_CUTOVER_PLAN_NOT_REFRESHABLE'; END IF;
  IF v_plan.master_version<>p_expected_plan_version THEN
    RAISE EXCEPTION 'SALES_PROCESS_CUTOVER_PLAN_VERSION_STALE';
  END IF;
  SELECT setting.* INTO STRICT v_setting FROM public.company_sales_process_settings setting
  WHERE setting.company_id=p_company_id FOR UPDATE;
  IF v_setting.master_version<>p_expected_settings_version
    OR v_setting.master_version<>v_plan.expected_settings_version
    OR v_setting.active_mode<>v_plan.source_mode THEN
    RAISE EXCEPTION 'SALES_PROCESS_CUTOVER_SETTINGS_VERSION_STALE';
  END IF;
  IF EXISTS(SELECT 1 FROM public.sales_process_cutover_audit audit
    WHERE audit.company_id=p_company_id AND audit.cutover_plan_id=p_plan_id
      AND audit.cutover_item_id IS NOT NULL) THEN
    RAISE EXCEPTION 'SALES_PROCESS_CUTOVER_PLAN_ITEM_AUDIT_EXISTS';
  END IF;
  v_before:=private.get_sales_process_cutover_plan_core(p_company_id,p_plan_id);
  v_preview:=private.get_sales_process_cutover_preview_core(p_company_id,v_plan.target_mode);
  IF (v_preview->>'settingsVersion')::bigint<>p_expected_settings_version THEN
    RAISE EXCEPTION 'SALES_PROCESS_CUTOVER_PREVIEW_VERSION_DRIFT';
  END IF;
  DELETE FROM public.sales_process_cutover_items item
  WHERE item.company_id=p_company_id AND item.cutover_plan_id=p_plan_id;
  FOR v_candidate IN SELECT value FROM jsonb_array_elements(v_preview->'candidates') LOOP
    INSERT INTO public.sales_process_cutover_items(company_id,cutover_plan_id,source_mode,
      target_mode,source_document_type,source_document_id,source_document_no,source_status,
      source_master_version,decision,item_status,blocker_codes,requirement_codes,source_snapshot)
    VALUES(p_company_id,p_plan_id,v_plan.source_mode,v_plan.target_mode,
      v_candidate->>'sourceDocumentType',(v_candidate->>'sourceDocumentId')::uuid,
      v_candidate->>'sourceDocumentNo',v_candidate->>'sourceStatus',
      (v_candidate->>'sourceMasterVersion')::bigint,v_candidate->>'decision','PLANNED',
      COALESCE(v_candidate->'blockerCodes','[]'),COALESCE(v_candidate->'requirementCodes','[]'),
      COALESCE(v_candidate->'facts','{}'));
  END LOOP;
  UPDATE public.sales_process_cutover_plans SET preview_snapshot=v_preview,
    master_version=master_version+1,updated_at=clock_timestamp()
  WHERE company_id=p_company_id AND id=p_plan_id;
  v_response:=private.get_sales_process_cutover_plan_core(p_company_id,p_plan_id);
  INSERT INTO public.sales_process_cutover_audit(company_id,cutover_plan_id,action,actor_id,
    operation_id,before_state,after_state)
  VALUES(p_company_id,p_plan_id,'REFRESH_PREVIEW',p_actor,p_operation_id,v_before,
    jsonb_build_object('requestHash',v_hash,'response',v_response));
  RETURN v_response;
EXCEPTION WHEN NO_DATA_FOUND THEN RAISE EXCEPTION 'SALES_PROCESS_CUTOVER_PLAN_NOT_FOUND';
END
$$;

CREATE FUNCTION private.cancel_sales_process_cutover_plan_core(
  p_actor uuid,p_company_id uuid,p_plan_id uuid,p_expected_plan_version bigint,
  p_operation_id uuid,p_cancel_reason text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='15s' AS $$
DECLARE v_plan public.sales_process_cutover_plans%rowtype;v_audit record;
  v_reason text;v_hash text;v_before jsonb;v_response jsonb;
BEGIN
  IF p_actor IS NULL OR p_company_id IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF p_plan_id IS NULL OR p_operation_id IS NULL OR p_expected_plan_version IS NULL
    OR p_expected_plan_version<1 THEN RAISE EXCEPTION 'SALES_PROCESS_CUTOVER_CANCEL_IDENTITY_REQUIRED'; END IF;
  v_reason:=nullif(btrim(COALESCE(p_cancel_reason,'')),'');
  IF v_reason IS NULL OR length(v_reason)>500 THEN RAISE EXCEPTION 'SALES_PROCESS_CUTOVER_CANCEL_REASON_INVALID'; END IF;
  v_hash:=encode(extensions.digest(convert_to(jsonb_build_object('companyId',p_company_id,
    'planId',p_plan_id,'expectedPlanVersion',p_expected_plan_version,
    'cancelReason',v_reason)::text,'UTF8'),'sha256'),'hex');
  PERFORM pg_advisory_xact_lock(hashtextextended(p_company_id::text,20260910120000));
  SELECT audit.* INTO v_audit FROM public.sales_process_cutover_audit audit
  WHERE audit.company_id=p_company_id AND audit.cutover_plan_id=p_plan_id
    AND audit.action='CANCEL_PLAN' AND audit.operation_id=p_operation_id;
  IF FOUND THEN
    IF v_audit.after_state->>'requestHash'<>v_hash THEN
      RAISE EXCEPTION 'SALES_PROCESS_CUTOVER_IDEMPOTENCY_PAYLOAD_CONFLICT';
    END IF;
    RETURN v_audit.after_state->'response';
  END IF;
  SELECT plan.* INTO STRICT v_plan FROM public.sales_process_cutover_plans plan
  WHERE plan.company_id=p_company_id AND plan.id=p_plan_id FOR UPDATE;
  IF v_plan.status NOT IN('DRAFT','PREVIEWED') THEN
    RAISE EXCEPTION 'SALES_PROCESS_CUTOVER_PLAN_NOT_CANCELABLE';
  END IF;
  IF v_plan.master_version<>p_expected_plan_version THEN
    RAISE EXCEPTION 'SALES_PROCESS_CUTOVER_PLAN_VERSION_STALE';
  END IF;
  v_before:=private.get_sales_process_cutover_plan_core(p_company_id,p_plan_id);
  UPDATE public.sales_process_cutover_plans SET status='CANCELED',
    master_version=master_version+1,canceled_by=p_actor,canceled_at=clock_timestamp(),
    cancel_reason=v_reason,updated_at=clock_timestamp()
  WHERE company_id=p_company_id AND id=p_plan_id;
  v_response:=private.get_sales_process_cutover_plan_core(p_company_id,p_plan_id);
  INSERT INTO public.sales_process_cutover_audit(company_id,cutover_plan_id,action,actor_id,
    operation_id,before_state,after_state)
  VALUES(p_company_id,p_plan_id,'CANCEL_PLAN',p_actor,p_operation_id,v_before,
    jsonb_build_object('requestHash',v_hash,'response',v_response));
  RETURN v_response;
EXCEPTION WHEN NO_DATA_FOUND THEN RAISE EXCEPTION 'SALES_PROCESS_CUTOVER_PLAN_NOT_FOUND';
END
$$;

CREATE FUNCTION public.refresh_sales_process_cutover_plan(p_plan_id uuid,
  p_expected_plan_version bigint,p_expected_settings_version bigint,p_operation_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='15s' AS $$
DECLARE v_actor uuid:=auth.uid();v_company uuid;v_role text;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  SELECT role::text INTO v_role FROM public.profiles WHERE id=v_actor;
  IF v_role IS DISTINCT FROM 'super_admin' THEN RAISE EXCEPTION 'SALES_PROCESS_CUTOVER_SUPER_ADMIN_REQUIRED'; END IF;
  v_company:=public.private_active_company_id();
  RETURN private.refresh_sales_process_cutover_plan_core(v_actor,v_company,p_plan_id,
    p_expected_plan_version,p_expected_settings_version,p_operation_id);
END
$$;

CREATE FUNCTION public.cancel_sales_process_cutover_plan(p_plan_id uuid,
  p_expected_plan_version bigint,p_operation_id uuid,p_cancel_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='15s' AS $$
DECLARE v_actor uuid:=auth.uid();v_company uuid;v_role text;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  SELECT role::text INTO v_role FROM public.profiles WHERE id=v_actor;
  IF v_role IS DISTINCT FROM 'super_admin' THEN RAISE EXCEPTION 'SALES_PROCESS_CUTOVER_SUPER_ADMIN_REQUIRED'; END IF;
  v_company:=public.private_active_company_id();
  RETURN private.cancel_sales_process_cutover_plan_core(v_actor,v_company,p_plan_id,
    p_expected_plan_version,p_operation_id,p_cancel_reason);
END
$$;

REVOKE ALL ON FUNCTION private.refresh_sales_process_cutover_plan_core(uuid,uuid,uuid,bigint,bigint,uuid),
  private.cancel_sales_process_cutover_plan_core(uuid,uuid,uuid,bigint,uuid,text)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.refresh_sales_process_cutover_plan_core(uuid,uuid,uuid,bigint,bigint,uuid),
  private.cancel_sales_process_cutover_plan_core(uuid,uuid,uuid,bigint,uuid,text) TO service_role;
REVOKE ALL ON FUNCTION public.refresh_sales_process_cutover_plan(uuid,bigint,bigint,uuid),
  public.cancel_sales_process_cutover_plan(uuid,bigint,uuid,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.refresh_sales_process_cutover_plan(uuid,bigint,bigint,uuid),
  public.cancel_sales_process_cutover_plan(uuid,bigint,uuid,text) TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260910120000','sales_process_cutover_plan_refresh_cancel',
  'Add optimistic plan version, immutable-target preview refresh and audited cancel; no apply, Company mode switch or operational document effect');
COMMIT;
