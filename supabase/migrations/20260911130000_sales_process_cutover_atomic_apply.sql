-- Step 4E/6: atomically apply a persisted Sales-process cutover plan and make
-- Company active_mode authoritative for new root transactions.
BEGIN;

DO $guard$
BEGIN
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260911130000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260911130000';
  END IF;
  IF (SELECT count(*) FROM private.kgs_schema_migrations WHERE version IN(
      '20260909162000','20260909163000','20260910110000','20260910120000',
      '20260910130000','20260910140000','20260910152000','20260910153000',
      '20260911100000','20260911110000','20260911111000','20260911120000'))<>12
    OR to_regprocedure('private.get_sales_process_cutover_plan_core(uuid,uuid)') IS NULL
    OR to_regprocedure('private.get_sales_process_cutover_preview_core(uuid,text)') IS NULL
    OR to_regprocedure('private.convert_retail_sale_to_backoffice_order(uuid,uuid,uuid,uuid)') IS NULL
    OR to_regprocedure('private.convert_backoffice_order_to_retail_sale(uuid,uuid,uuid,uuid)') IS NULL
    OR to_regprocedure('public.save_pos_sale_draft(jsonb)') IS NULL
    OR to_regprocedure('public.save_backoffice_sales_order_draft(uuid,bigint,uuid,jsonb)') IS NULL
    OR to_regprocedure('public.start_pos_sales_order_revision(uuid,bigint,uuid,uuid,text)') IS NULL
    OR to_regprocedure('public.submit_pos_offline_sale(jsonb)') IS NULL
    OR NOT EXISTS(SELECT 1 FROM pg_trigger
      WHERE tgrelid='public.sales_headers'::regclass
        AND tgname='sales_headers_process_identity_guard' AND NOT tgisinternal)
    OR position('BACKOFFICE_CUTOVER_SCOPE_IMMUTABLE' IN pg_get_functiondef(
      'private.trg_guard_sales_process_identity()'::regprocedure))=0 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Step 4E dependency chain incomplete';
  END IF;
  IF to_regprocedure('private.assert_sales_process_root_creation_allowed(uuid,text)') IS NOT NULL
    OR to_regprocedure('private.apply_sales_process_cutover_plan_core(uuid,uuid,uuid,bigint,bigint,uuid)') IS NOT NULL
    OR to_regprocedure('public.apply_sales_process_cutover_plan(uuid,bigint,bigint,uuid)') IS NOT NULL
    OR to_regprocedure('private.save_pos_sale_draft_before_process_mode_gate(jsonb)') IS NOT NULL
    OR to_regprocedure('private.save_backoffice_sales_order_draft_before_process_mode_gate(uuid,bigint,uuid,jsonb)') IS NOT NULL
    OR to_regprocedure('private.start_pos_sales_order_revision_before_process_mode_gate(uuid,bigint,uuid,uuid,text)') IS NOT NULL
    OR to_regprocedure('private.submit_pos_offline_sale_before_process_mode_gate(jsonb)') IS NOT NULL
    OR to_regprocedure('private.get_sales_process_cutover_plan_before_atomic_apply(uuid,uuid)') IS NOT NULL
    OR EXISTS(SELECT 1 FROM pg_trigger
      WHERE tgrelid='public.backoffice_sales_orders'::regclass
        AND tgname='backoffice_sales_process_mode_creation_gate'
        AND NOT tgisinternal) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Step 4E routine/trigger collision';
  END IF;
END
$guard$;

ALTER FUNCTION private.get_sales_process_cutover_plan_core(uuid,uuid)
  RENAME TO get_sales_process_cutover_plan_before_atomic_apply;
CREATE FUNCTION private.get_sales_process_cutover_plan_core(
  p_company_id uuid,p_plan_id uuid
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='8s' AS $$
DECLARE v_plan public.sales_process_cutover_plans%rowtype;v_result jsonb;
BEGIN
  SELECT plan.* INTO v_plan FROM public.sales_process_cutover_plans plan
  WHERE plan.company_id=p_company_id AND plan.id=p_plan_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'SALES_PROCESS_CUTOVER_PLAN_NOT_FOUND'; END IF;
  v_result:=private.get_sales_process_cutover_plan_before_atomic_apply(
    p_company_id,p_plan_id);
  RETURN v_result||jsonb_build_object('appliedBy',v_plan.applied_by,
    'appliedAt',v_plan.applied_at);
END
$$;

CREATE FUNCTION private.assert_sales_process_root_creation_allowed(
  p_company_id uuid,p_requested_mode text
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='8s' AS $$
DECLARE v_active_mode text;
BEGIN
  IF p_company_id IS NULL OR p_requested_mode IS NULL OR p_requested_mode NOT IN(
      'RETAIL_CONFIRM_INVOICE','BACKOFFICE_DELIVERED_QTY_INVOICE') THEN
    RAISE EXCEPTION 'SALES_PROCESS_ROOT_CREATION_CONTEXT_INVALID';
  END IF;
  IF COALESCE(current_setting('kgs.sales_process_cutover_mutation',true),'')='1'
    OR COALESCE(current_setting('kgs.sales_process_grandfathered_lineage',true),'')='1' THEN
    RETURN;
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(p_company_id::text,20260911130000));
  SELECT setting.active_mode INTO STRICT v_active_mode
  FROM public.company_sales_process_settings setting
  WHERE setting.company_id=p_company_id;
  IF v_active_mode<>p_requested_mode THEN
    RAISE EXCEPTION 'SALES_PROCESS_ROOT_CREATION_MODE_BLOCKED';
  END IF;
EXCEPTION WHEN NO_DATA_FOUND THEN
  RAISE EXCEPTION 'SALES_PROCESS_SETTING_NOT_FOUND';
END
$$;

-- Extend the existing central Retail identity trigger. Existing document
-- updates remain source-routed; only INSERT/root creation is mode-gated.
CREATE OR REPLACE FUNCTION private.trg_guard_sales_process_identity()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
BEGIN
  IF TG_OP='UPDATE' AND (
    NEW.sales_origin IS DISTINCT FROM OLD.sales_origin
    OR NEW.sales_process_mode IS DISTINCT FROM OLD.sales_process_mode
  ) THEN
    RAISE EXCEPTION 'SALES_PROCESS_IDENTITY_IMMUTABLE';
  END IF;

  IF TG_OP='UPDATE' AND OLD.sales_origin='BACKOFFICE_CUTOVER'
    AND (NEW.company_id IS DISTINCT FROM OLD.company_id
      OR NEW.store_id IS DISTINCT FROM OLD.store_id
      OR NEW.sales_warehouse_id IS DISTINCT FROM OLD.sales_warehouse_id) THEN
    RAISE EXCEPTION 'BACKOFFICE_CUTOVER_SCOPE_IMMUTABLE';
  END IF;

  IF TG_OP='INSERT' AND NEW.sales_origin='BACKOFFICE_CUTOVER'
    AND COALESCE(current_setting('kgs.sales_process_cutover_mutation',true),'')<>'1' THEN
    RAISE EXCEPTION 'BACKOFFICE_CUTOVER_RUNTIME_REQUIRED';
  END IF;

  IF TG_OP='INSERT' AND NEW.sales_origin<>'BACKOFFICE_CUTOVER' THEN
    PERFORM private.assert_sales_process_root_creation_allowed(
      NEW.company_id,NEW.sales_process_mode);
  END IF;

  IF NEW.sales_origin='BACKOFFICE_SALES' AND NOT EXISTS(
    SELECT 1 FROM public.company_features feature
    WHERE feature.company_id=NEW.company_id
      AND feature.feature_code='backoffice_delivered_qty_sales_enabled'
      AND feature.is_enabled
  ) THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_FEATURE_NOT_ENABLED';
  END IF;
  RETURN NEW;
END
$$;

DROP TRIGGER sales_headers_process_identity_guard ON public.sales_headers;
CREATE TRIGGER sales_headers_process_identity_guard
BEFORE INSERT OR UPDATE OF sales_origin,sales_process_mode,company_id,store_id,sales_warehouse_id
ON public.sales_headers
FOR EACH ROW EXECUTE FUNCTION private.trg_guard_sales_process_identity();

CREATE FUNCTION private.trg_guard_backoffice_sales_process_creation()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
BEGIN
  PERFORM private.assert_sales_process_root_creation_allowed(
    NEW.company_id,'BACKOFFICE_DELIVERED_QTY_INVOICE');
  RETURN NEW;
END
$$;

CREATE TRIGGER backoffice_sales_process_mode_creation_gate
BEFORE INSERT ON public.backoffice_sales_orders
FOR EACH ROW EXECUTE FUNCTION private.trg_guard_backoffice_sales_process_creation();

-- Reject a newly submitted Offline envelope before it can become a queued
-- server-side submission in a Company whose active process is Backoffice.
ALTER FUNCTION public.submit_pos_offline_sale(jsonb)
  RENAME TO submit_pos_offline_sale_before_process_mode_gate;
ALTER FUNCTION public.submit_pos_offline_sale_before_process_mode_gate(jsonb)
  SET SCHEMA private;
CREATE FUNCTION public.submit_pos_offline_sale(p_envelope jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();
BEGIN
  PERFORM private.assert_sales_process_root_creation_allowed(
    v_company,'RETAIL_CONFIRM_INVOICE');
  RETURN private.submit_pos_offline_sale_before_process_mode_gate(p_envelope);
END
$$;

-- A Revision of an already-existing Retail Order is continuation lineage, not
-- a new root Sale. The existing canonical Revision routine still performs all
-- eligibility, session, payment, dispatch and optimistic-version checks.
ALTER FUNCTION public.start_pos_sales_order_revision(uuid,bigint,uuid,uuid,text)
  RENAME TO start_pos_sales_order_revision_before_process_mode_gate;
ALTER FUNCTION public.start_pos_sales_order_revision_before_process_mode_gate(
  uuid,bigint,uuid,uuid,text) SET SCHEMA private;
CREATE FUNCTION public.start_pos_sales_order_revision(
  p_source_sales_id uuid,p_source_master_version bigint,
  p_cashier_session_id uuid,p_idempotency_key uuid,p_reason text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_source_mode text;
  v_active_mode text;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended(v_company::text,20260911130000));
  SELECT sale.sales_process_mode INTO v_source_mode
  FROM public.sales_headers sale
  WHERE sale.company_id=v_company AND sale.id=p_source_sales_id;
  SELECT setting.active_mode INTO STRICT v_active_mode
  FROM public.company_sales_process_settings setting
  WHERE setting.company_id=v_company;
  IF v_source_mode IS NOT NULL AND v_source_mode<>v_active_mode THEN
    PERFORM set_config('kgs.sales_process_grandfathered_lineage','1',true);
  END IF;
  RETURN private.start_pos_sales_order_revision_before_process_mode_gate(
    p_source_sales_id,p_source_master_version,p_cashier_session_id,
    p_idempotency_key,p_reason);
END
$$;

CREATE FUNCTION private.apply_sales_process_cutover_plan_core(
  p_actor uuid,p_company_id uuid,p_plan_id uuid,p_expected_plan_version bigint,
  p_expected_settings_version bigint,p_operation_id uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='60s' AS $$
DECLARE v_plan public.sales_process_cutover_plans%rowtype;
  v_setting public.company_sales_process_settings%rowtype;v_item record;
  v_existing_audit record;v_preview jsonb;v_result jsonb;v_before jsonb;
  v_response jsonb;v_request_hash text;v_expected_target_type text;
BEGIN
  IF p_actor IS NULL OR p_company_id IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF p_plan_id IS NULL OR p_operation_id IS NULL
    OR p_expected_plan_version IS NULL OR p_expected_plan_version<1
    OR p_expected_settings_version IS NULL OR p_expected_settings_version<1 THEN
    RAISE EXCEPTION 'SALES_PROCESS_CUTOVER_APPLY_CONTEXT_REQUIRED';
  END IF;
  v_request_hash:=encode(extensions.digest(convert_to(jsonb_build_object(
    'companyId',p_company_id,'planId',p_plan_id,
    'expectedPlanVersion',p_expected_plan_version,
    'expectedSettingsVersion',p_expected_settings_version)::text,'UTF8'),
    'sha256'),'hex');

  PERFORM pg_advisory_xact_lock(hashtextextended(p_company_id::text,20260911130000));
  SELECT audit.* INTO v_existing_audit
  FROM public.sales_process_cutover_audit audit
  WHERE audit.company_id=p_company_id AND audit.cutover_plan_id=p_plan_id
    AND audit.action='APPLY_MODE' AND audit.operation_id=p_operation_id;
  IF FOUND THEN
    IF v_existing_audit.after_state->>'requestHash'<>v_request_hash THEN
      RAISE EXCEPTION 'SALES_PROCESS_CUTOVER_IDEMPOTENCY_PAYLOAD_CONFLICT';
    END IF;
    RETURN v_existing_audit.after_state->'response';
  END IF;

  SELECT plan.* INTO v_plan
  FROM public.sales_process_cutover_plans plan
  WHERE plan.company_id=p_company_id AND plan.id=p_plan_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'SALES_PROCESS_CUTOVER_PLAN_NOT_FOUND'; END IF;
  SELECT setting.* INTO v_setting
  FROM public.company_sales_process_settings setting
  WHERE setting.company_id=p_company_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'SALES_PROCESS_SETTING_NOT_FOUND'; END IF;

  IF v_plan.status<>'PREVIEWED' THEN
    RAISE EXCEPTION 'SALES_PROCESS_CUTOVER_PLAN_NOT_APPLICABLE';
  END IF;
  IF v_plan.master_version<>p_expected_plan_version THEN
    RAISE EXCEPTION 'SALES_PROCESS_CUTOVER_PLAN_VERSION_STALE';
  END IF;
  IF v_setting.master_version<>p_expected_settings_version
    OR v_setting.master_version<>v_plan.expected_settings_version
    OR v_setting.active_mode<>v_plan.source_mode
    OR v_plan.target_mode=v_setting.active_mode THEN
    RAISE EXCEPTION 'SALES_PROCESS_CUTOVER_SETTINGS_VERSION_STALE';
  END IF;
  IF clock_timestamp()<v_plan.effective_at THEN
    RAISE EXCEPTION 'SALES_PROCESS_CUTOVER_EFFECTIVE_AT_NOT_REACHED';
  END IF;
  IF v_plan.target_mode='BACKOFFICE_DELIVERED_QTY_INVOICE' AND NOT EXISTS(
    SELECT 1 FROM public.company_features feature
    WHERE feature.company_id=p_company_id
      AND feature.feature_code='backoffice_delivered_qty_sales_enabled'
      AND feature.is_enabled) THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_FEATURE_NOT_ENABLED';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs queue
    WHERE queue.company_id=p_company_id
      AND queue.status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'SALES_PROCESS_CUTOVER_ACTIVE_FINANCE_QUEUE';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions submission
    WHERE submission.company_id=p_company_id
      AND submission.status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'SALES_PROCESS_CUTOVER_NONTERMINAL_OFFLINE_SUBMISSION';
  END IF;

  -- Serialize canonical source mutations before recomputing the preview.
  IF v_plan.source_mode='RETAIL_CONFIRM_INVOICE' THEN
    PERFORM sale.id FROM public.sales_headers sale
    JOIN public.sales_process_cutover_items item
      ON item.company_id=sale.company_id AND item.source_document_id=sale.id
    WHERE item.company_id=p_company_id AND item.cutover_plan_id=p_plan_id
      AND item.source_document_type='RETAIL_SALE'
    ORDER BY sale.id FOR UPDATE OF sale;
  ELSE
    PERFORM document.id FROM public.backoffice_sales_orders document
    JOIN public.sales_process_cutover_items item
      ON item.company_id=document.company_id AND item.source_document_id=document.id
    WHERE item.company_id=p_company_id AND item.cutover_plan_id=p_plan_id
      AND item.source_document_type='BACKOFFICE_SALES_ORDER'
    ORDER BY document.id FOR UPDATE OF document;
  END IF;

  v_preview:=private.get_sales_process_cutover_preview_core(
    p_company_id,v_plan.target_mode);
  IF (v_preview->>'settingsVersion')::bigint<>p_expected_settings_version
    OR v_preview->>'currentMode'<>v_plan.source_mode
    OR v_preview->>'targetMode'<>v_plan.target_mode
    OR EXISTS(
      SELECT 1 FROM jsonb_array_elements(v_preview->'candidates') candidate
      LEFT JOIN public.sales_process_cutover_items item
        ON item.company_id=p_company_id AND item.cutover_plan_id=p_plan_id
       AND item.source_document_type=candidate->>'sourceDocumentType'
       AND item.source_document_id=(candidate->>'sourceDocumentId')::uuid
      WHERE item.id IS NULL OR item.item_status<>'PLANNED'
        OR item.source_status<>candidate->>'sourceStatus'
        OR item.source_master_version<>(candidate->>'sourceMasterVersion')::bigint
        OR item.decision<>candidate->>'decision'
        OR item.blocker_codes<>COALESCE(candidate->'blockerCodes','[]'::jsonb)
        OR item.requirement_codes<>COALESCE(candidate->'requirementCodes','[]'::jsonb)
        OR item.source_snapshot<>COALESCE(candidate->'facts','{}'::jsonb))
    OR EXISTS(
      SELECT 1 FROM public.sales_process_cutover_items item
      WHERE item.company_id=p_company_id AND item.cutover_plan_id=p_plan_id
        AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(v_preview->'candidates') candidate
          WHERE candidate->>'sourceDocumentType'=item.source_document_type
            AND (candidate->>'sourceDocumentId')::uuid=item.source_document_id)) THEN
    RAISE EXCEPTION 'SALES_PROCESS_CUTOVER_PREVIEW_STALE';
  END IF;

  v_before:=private.get_sales_process_cutover_plan_core(p_company_id,p_plan_id);
  UPDATE public.sales_process_cutover_plans SET status='APPLYING',
    updated_at=clock_timestamp()
  WHERE company_id=p_company_id AND id=p_plan_id;
  PERFORM set_config('kgs.sales_process_cutover_mutation','1',true);

  FOR v_item IN
    SELECT item.* FROM public.sales_process_cutover_items item
    WHERE item.company_id=p_company_id AND item.cutover_plan_id=p_plan_id
    ORDER BY item.source_document_type,item.source_document_no,item.id
    FOR UPDATE
  LOOP
    IF v_item.decision='CONVERT' THEN
      IF v_item.source_document_type='RETAIL_SALE'
        AND v_plan.target_mode='BACKOFFICE_DELIVERED_QTY_INVOICE' THEN
        v_expected_target_type:='BACKOFFICE_SALES_ORDER';
        v_result:=private.convert_retail_sale_to_backoffice_order(
          p_company_id,v_item.source_document_id,p_actor,v_item.id);
      ELSIF v_item.source_document_type='BACKOFFICE_SALES_ORDER'
        AND v_plan.target_mode='RETAIL_CONFIRM_INVOICE' THEN
        v_expected_target_type:='RETAIL_SALE';
        v_result:=private.convert_backoffice_order_to_retail_sale(
          p_company_id,v_item.source_document_id,p_actor,v_item.id);
      ELSE
        RAISE EXCEPTION 'SALES_PROCESS_CUTOVER_ITEM_DIRECTION_INVALID';
      END IF;
      IF NOT COALESCE((v_result->>'sourceClosed')::boolean,false)
        OR v_result->>'targetDocumentType'<>v_expected_target_type
        OR NULLIF(v_result->>'targetDocumentId','') IS NULL
        OR NULLIF(v_result->>'targetDocumentNo','') IS NULL THEN
        RAISE EXCEPTION 'SALES_PROCESS_CUTOVER_CONVERTER_RESULT_INVALID';
      END IF;
      UPDATE public.sales_process_cutover_items SET item_status='APPLIED',
        target_document_type=v_result->>'targetDocumentType',
        target_document_id=(v_result->>'targetDocumentId')::uuid,
        target_document_no=v_result->>'targetDocumentNo',updated_at=clock_timestamp()
      WHERE company_id=p_company_id AND id=v_item.id;
      INSERT INTO public.sales_process_cutover_audit(company_id,cutover_plan_id,
        cutover_item_id,action,actor_id,operation_id,before_state,after_state)
      VALUES(p_company_id,p_plan_id,v_item.id,'APPLY_ITEM',p_actor,v_item.id,
        to_jsonb(v_item),jsonb_build_object('converterResult',v_result));
    ELSE
      UPDATE public.sales_process_cutover_items SET item_status='KEPT',
        updated_at=clock_timestamp()
      WHERE company_id=p_company_id AND id=v_item.id;
      INSERT INTO public.sales_process_cutover_audit(company_id,cutover_plan_id,
        cutover_item_id,action,actor_id,operation_id,before_state,after_state)
      VALUES(p_company_id,p_plan_id,v_item.id,'KEEP_ITEM',p_actor,v_item.id,
        to_jsonb(v_item),jsonb_build_object('decision',v_item.decision,
          'blockerCodes',v_item.blocker_codes,
          'requirementCodes',v_item.requirement_codes,
          'sourceRetained',true));
    END IF;
  END LOOP;

  UPDATE public.company_sales_process_settings SET active_mode=v_plan.target_mode,
    mode_effective_at=v_plan.effective_at,master_version=master_version+1,
    updated_by=p_actor,updated_at=clock_timestamp()
  WHERE company_id=p_company_id;
  INSERT INTO public.company_sales_process_mode_history(company_id,change_type,
    source_mode,target_mode,effective_at,reason,cutover_plan_id,actor_id)
  VALUES(p_company_id,'SWITCH',v_plan.source_mode,v_plan.target_mode,
    v_plan.effective_at,v_plan.reason,p_plan_id,p_actor);
  UPDATE public.sales_process_cutover_plans SET status='APPLIED',
    master_version=master_version+1,applied_by=p_actor,
    applied_at=clock_timestamp(),updated_at=clock_timestamp()
  WHERE company_id=p_company_id AND id=p_plan_id;
  PERFORM set_config('kgs.sales_process_cutover_mutation','',true);

  v_response:=private.get_sales_process_cutover_plan_core(p_company_id,p_plan_id)
    ||jsonb_build_object('modeSwitched',true,
      'previousMode',v_plan.source_mode,'activeMode',v_plan.target_mode);
  INSERT INTO public.sales_process_cutover_audit(company_id,cutover_plan_id,
    action,actor_id,operation_id,before_state,after_state)
  VALUES(p_company_id,p_plan_id,'APPLY_MODE',p_actor,p_operation_id,v_before,
    jsonb_build_object('requestHash',v_request_hash,'response',v_response));
  RETURN v_response;
END
$$;

CREATE FUNCTION public.apply_sales_process_cutover_plan(
  p_plan_id uuid,p_expected_plan_version bigint,
  p_expected_settings_version bigint,p_operation_id uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='60s' AS $$
DECLARE v_actor uuid:=auth.uid();v_company uuid;v_role text;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  SELECT profile.role::text INTO v_role FROM public.profiles profile
  WHERE profile.id=v_actor;
  IF v_role IS DISTINCT FROM 'super_admin' THEN
    RAISE EXCEPTION 'SALES_PROCESS_CUTOVER_SUPER_ADMIN_REQUIRED';
  END IF;
  v_company:=public.private_active_company_id();
  RETURN private.apply_sales_process_cutover_plan_core(v_actor,v_company,
    p_plan_id,p_expected_plan_version,p_expected_settings_version,p_operation_id);
END
$$;

REVOKE ALL ON FUNCTION
  private.assert_sales_process_root_creation_allowed(uuid,text),
  private.get_sales_process_cutover_plan_before_atomic_apply(uuid,uuid),
  private.get_sales_process_cutover_plan_core(uuid,uuid),
  private.trg_guard_backoffice_sales_process_creation(),
  private.apply_sales_process_cutover_plan_core(uuid,uuid,uuid,bigint,bigint,uuid),
  private.submit_pos_offline_sale_before_process_mode_gate(jsonb),
  private.start_pos_sales_order_revision_before_process_mode_gate(uuid,bigint,uuid,uuid,text)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.assert_sales_process_root_creation_allowed(uuid,text),
  private.get_sales_process_cutover_plan_before_atomic_apply(uuid,uuid),
  private.get_sales_process_cutover_plan_core(uuid,uuid),
  private.trg_guard_backoffice_sales_process_creation(),
  private.apply_sales_process_cutover_plan_core(uuid,uuid,uuid,bigint,bigint,uuid),
  private.submit_pos_offline_sale_before_process_mode_gate(jsonb),
  private.start_pos_sales_order_revision_before_process_mode_gate(uuid,bigint,uuid,uuid,text)
TO service_role;
REVOKE ALL ON FUNCTION public.submit_pos_offline_sale(jsonb),
  public.start_pos_sales_order_revision(uuid,bigint,uuid,uuid,text),
  public.apply_sales_process_cutover_plan(uuid,bigint,bigint,uuid)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.submit_pos_offline_sale(jsonb),
  public.start_pos_sales_order_revision(uuid,bigint,uuid,uuid,text),
  public.apply_sales_process_cutover_plan(uuid,bigint,bigint,uuid)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260911130000','sales_process_cutover_atomic_apply',
  'Add Super-Admin atomic Apply with live preview revalidation, two-way private conversion, immutable item/mode lineage, exact retry and Company mode-authoritative root creation gates; preserve source-routed grandfathered completion and create no standalone Stock, Payment or Finance effect');

NOTIFY pgrst,'reload schema';
COMMIT;
