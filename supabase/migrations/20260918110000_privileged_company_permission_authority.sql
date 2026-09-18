-- ACP authority correction: Platform Super Admin has every supported
-- capability across Companies; Company Owner has the same Company-scoped
-- capability set. Feature entitlement and domain lifecycle guards still apply.

BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260813100000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: ACP resolver required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260918110000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260918110000';
  END IF;
  IF to_regprocedure('private.acp_resolve_permission(uuid,uuid,text)') IS NULL
     OR to_regprocedure('public.save_user_permission_override(uuid,uuid,text,text,bigint)') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical permission routines missing';
  END IF;
END
$guard$;

CREATE OR REPLACE FUNCTION private.acp_resolve_permission(
    p_company_id UUID,p_target_user_id UUID,p_permission_key TEXT
) RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE
    v_catalog public.access_permission_catalog%ROWTYPE;
    v_override public.user_company_permission_overrides%ROWTYPE;
    v_role TEXT;
    v_baseline TEXT[]:='{}';
    v_effective TEXT[]:='{}';
    v_feature_enabled BOOLEAN:=TRUE;
    v_customer_balance_history_only BOOLEAN:=FALSE;
    v_privileged_company_authority BOOLEAN:=FALSE;
BEGIN
    SELECT * INTO v_catalog FROM public.access_permission_catalog
    WHERE permission_key=p_permission_key;
    IF NOT FOUND THEN RAISE EXCEPTION 'PERMISSION_KEY_NOT_FOUND'; END IF;

    IF public.private_is_super_admin(p_target_user_id) THEN
      v_role:='SUPER_ADMIN';
    ELSE
      SELECT role_code INTO v_role FROM public.company_memberships
      WHERE company_id=p_company_id AND user_id=p_target_user_id
        AND status='ACTIVE';
    END IF;
    IF v_role IS NULL THEN
      RAISE EXCEPTION 'TARGET_COMPANY_MEMBERSHIP_NOT_FOUND';
    END IF;
    -- Non-customizable platform authority (currently platform.companies)
    -- remains Super-Admin-only. Company Owner authority is otherwise complete
    -- for the active Company.
    v_privileged_company_authority:=v_role='SUPER_ADMIN'
      OR (v_role='COMPANY_OWNER' AND v_catalog.is_customizable);

    IF cardinality(v_catalog.required_any_features)>0 THEN
      SELECT EXISTS(SELECT 1 FROM public.company_features feature
        WHERE feature.company_id=p_company_id AND feature.is_enabled
          AND feature.feature_code=ANY(v_catalog.required_any_features))
      INTO v_feature_enabled;

      IF NOT v_feature_enabled
         AND p_permission_key='finance.customer_balances'
         AND EXISTS(SELECT 1
           FROM public.customer_balance_company_policies policy
           WHERE policy.company_id=p_company_id
             AND policy.lifecycle_state='WIND_DOWN') THEN
        v_feature_enabled:=TRUE;
      END IF;

      IF NOT v_feature_enabled
         AND p_permission_key='finance.customer_balances'
         AND EXISTS(SELECT 1
           FROM public.customer_balance_company_policies policy
           WHERE policy.company_id=p_company_id
             AND policy.lifecycle_state='DISABLED')
         AND EXISTS(SELECT 1
           FROM public.customer_balance_ledger_entries entry
           WHERE entry.company_id=p_company_id) THEN
        v_feature_enabled:=TRUE;
        v_customer_balance_history_only:=TRUE;
      END IF;
    END IF;

    IF v_feature_enabled AND v_privileged_company_authority THEN
      SELECT COALESCE(array_agg(DISTINCT capability ORDER BY capability),'{}')
      INTO v_baseline FROM unnest(v_catalog.supported_capabilities) capability;
    ELSIF v_feature_enabled AND v_role=ANY(v_catalog.view_roles) THEN
      v_baseline:=ARRAY['VIEW'];
      IF v_role=ANY(v_catalog.operator_roles) THEN
        v_baseline:=v_baseline||ARRAY['CREATE_DRAFT','EDIT_DRAFT','MANAGE'];
      END IF;
      IF v_role=ANY(v_catalog.approver_roles) THEN
        v_baseline:=v_baseline||ARRAY[
          'REVIEW','APPROVE','POST','CANCEL_FINAL','REVERSE','CLOSE_PERIOD'];
      END IF;
      v_baseline:=v_baseline||ARRAY['EXPORT'];
      IF v_role='COMPANY_ADMIN' THEN
        v_baseline:=v_baseline||ARRAY['IMPORT'];
      END IF;
      SELECT COALESCE(array_agg(DISTINCT capability ORDER BY capability),'{}')
      INTO v_baseline FROM unnest(v_baseline) capability
      WHERE capability=ANY(v_catalog.supported_capabilities);
    END IF;

    IF v_customer_balance_history_only THEN
      SELECT COALESCE(array_agg(capability ORDER BY capability),'{}')
      INTO v_baseline FROM unnest(v_baseline) capability
      WHERE capability IN('VIEW','EXPORT');
    END IF;

    SELECT * INTO v_override
    FROM public.user_company_permission_overrides
    WHERE company_id=p_company_id AND user_id=p_target_user_id
      AND permission_key=p_permission_key;

    IF v_privileged_company_authority OR v_override.id IS NULL THEN
      v_effective:=v_baseline;
    ELSIF v_override.restriction_preset='LIHAT_SAJA' THEN
      SELECT COALESCE(array_agg(capability ORDER BY capability),'{}')
      INTO v_effective FROM unnest(v_baseline) capability
      WHERE capability='VIEW';
    ELSIF v_override.restriction_preset='OPERASIONAL' THEN
      SELECT COALESCE(array_agg(capability ORDER BY capability),'{}')
      INTO v_effective FROM unnest(v_baseline) capability
      WHERE capability IN('VIEW','CREATE_DRAFT','EDIT_DRAFT');
    ELSE v_effective:='{}'; END IF;

    RETURN jsonb_build_object(
      'companyId',p_company_id,'userId',p_target_user_id,
      'permissionKey',p_permission_key,'roleCode',v_role,
      'featureEnabled',v_feature_enabled,
      'historyOnly',v_customer_balance_history_only,
      'baselineCapabilities',to_jsonb(v_baseline),
      'restrictionPreset',CASE WHEN v_privileged_company_authority
        THEN 'IKUTI_ROLE' ELSE COALESCE(v_override.restriction_preset,'IKUTI_ROLE') END,
      'overrideVersion',CASE WHEN v_privileged_company_authority
        THEN NULL ELSE v_override.master_version END,
      'effectiveCapabilities',to_jsonb(v_effective),
      'enforcementStatus',v_catalog.enforcement_status,
      'enforced',v_catalog.enforcement_status='ENFORCED');
END;
$$;

CREATE OR REPLACE FUNCTION public.save_user_permission_override(
    p_company_id UUID,p_target_user_id UUID,p_permission_key TEXT,
    p_restriction_preset TEXT,p_expected_version BIGINT DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp
AS $$
DECLARE
    v_actor UUID:=auth.uid();v_preset TEXT:=upper(btrim(COALESCE(p_restriction_preset,'')));
    v_catalog public.access_permission_catalog%ROWTYPE;
    v_current public.user_company_permission_overrides%ROWTYPE;
    v_result public.user_company_permission_overrides%ROWTYPE;
    v_before JSONB;v_after JSONB;v_action TEXT;v_new_version BIGINT;
    v_target_role TEXT;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF NOT private.acp_can_manage_target(v_actor,p_company_id,p_target_user_id) THEN
      RAISE EXCEPTION 'PERMISSION_TARGET_ACCESS_DENIED';
    END IF;
    IF v_preset NOT IN('IKUTI_ROLE','LIHAT_SAJA','OPERASIONAL','TANPA_AKSES') THEN
      RAISE EXCEPTION 'PERMISSION_PRESET_INVALID';
    END IF;
    SELECT * INTO v_catalog FROM public.access_permission_catalog
    WHERE permission_key=p_permission_key;
    IF NOT FOUND THEN RAISE EXCEPTION 'PERMISSION_KEY_NOT_FOUND'; END IF;
    IF NOT v_catalog.is_customizable THEN RAISE EXCEPTION 'PERMISSION_KEY_NOT_CUSTOMIZABLE'; END IF;

    IF public.private_is_super_admin(p_target_user_id) THEN
      v_target_role:='SUPER_ADMIN';
    ELSE
      SELECT role_code INTO v_target_role FROM public.company_memberships
      WHERE company_id=p_company_id AND user_id=p_target_user_id AND status='ACTIVE';
    END IF;
    IF v_target_role IS NULL THEN RAISE EXCEPTION 'TARGET_COMPANY_MEMBERSHIP_NOT_FOUND'; END IF;
    IF v_target_role IN('SUPER_ADMIN','COMPANY_OWNER') AND v_preset<>'IKUTI_ROLE' THEN
      RAISE EXCEPTION 'PRIVILEGED_ROLE_PERMISSION_RESTRICTION_NOT_ALLOWED';
    END IF;

    SELECT * INTO v_current FROM public.user_company_permission_overrides
    WHERE company_id=p_company_id AND user_id=p_target_user_id
      AND permission_key=p_permission_key FOR UPDATE;
    IF v_current.id IS NOT NULL AND v_current.restriction_preset=v_preset THEN
      RETURN jsonb_build_object('success',TRUE,'action','EXACT_RETRY',
        'permissionKey',p_permission_key,'restrictionPreset',v_preset,
        'masterVersion',v_current.master_version,'enforced',FALSE);
    END IF;
    IF v_current.id IS NULL AND v_preset='IKUTI_ROLE' THEN
      RETURN jsonb_build_object('success',TRUE,'action','EXACT_RETRY',
        'permissionKey',p_permission_key,'restrictionPreset',v_preset,
        'masterVersion',NULL,'enforced',FALSE);
    END IF;
    IF v_current.id IS NOT NULL AND p_expected_version IS DISTINCT FROM v_current.master_version THEN
      RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
    END IF;
    IF v_current.id IS NULL AND p_expected_version IS NOT NULL THEN
      RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
    END IF;
    v_before:=CASE WHEN v_current.id IS NULL THEN NULL ELSE jsonb_build_object(
      'restrictionPreset',v_current.restriction_preset,'masterVersion',v_current.master_version) END;

    IF v_preset='IKUTI_ROLE' THEN
      DELETE FROM public.user_company_permission_overrides WHERE id=v_current.id;
      v_action:='RESET_OVERRIDE';v_after:=jsonb_build_object('restrictionPreset','IKUTI_ROLE');
      v_new_version:=NULL;
    ELSIF v_current.id IS NULL THEN
      INSERT INTO public.user_company_permission_overrides(
        company_id,user_id,permission_key,restriction_preset,created_by,updated_by
      ) VALUES(p_company_id,p_target_user_id,p_permission_key,v_preset,v_actor,v_actor)
      RETURNING * INTO v_result;
      v_action:='CREATE_OVERRIDE';v_new_version:=v_result.master_version;
      v_after:=jsonb_build_object('restrictionPreset',v_result.restriction_preset,
        'masterVersion',v_result.master_version);
    ELSE
      UPDATE public.user_company_permission_overrides SET
        restriction_preset=v_preset,master_version=master_version+1,
        updated_by=v_actor,updated_at=clock_timestamp()
      WHERE id=v_current.id RETURNING * INTO v_result;
      v_action:='UPDATE_OVERRIDE';v_new_version:=v_result.master_version;
      v_after:=jsonb_build_object('restrictionPreset',v_result.restriction_preset,
        'masterVersion',v_result.master_version);
    END IF;

    INSERT INTO public.user_company_permission_audit(
      company_id,target_user_id,permission_key,actor_id,action,before_state,after_state
    ) VALUES(p_company_id,p_target_user_id,p_permission_key,v_actor,v_action,v_before,v_after);
    RETURN jsonb_build_object('success',TRUE,'action',v_action,
      'permissionKey',p_permission_key,'restrictionPreset',v_preset,
      'masterVersion',v_new_version,'enforced',FALSE);
END;
$$;

REVOKE ALL ON FUNCTION private.acp_resolve_permission(UUID,UUID,TEXT) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.acp_resolve_permission(UUID,UUID,TEXT) TO service_role;
REVOKE ALL ON FUNCTION public.save_user_permission_override(UUID,UUID,TEXT,TEXT,BIGINT) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.save_user_permission_override(UUID,UUID,TEXT,TEXT,BIGINT)
TO authenticated,service_role;

-- Existing Owner restrictions contradict the new authority contract. Preserve
-- the previous state in the immutable audit before resetting those config rows.
INSERT INTO public.user_company_permission_audit(
  company_id,target_user_id,permission_key,actor_id,action,before_state,after_state
)
SELECT override_row.company_id,override_row.user_id,override_row.permission_key,
  override_row.updated_by,'RESET_OVERRIDE',
  jsonb_build_object('restrictionPreset',override_row.restriction_preset,
    'masterVersion',override_row.master_version,'migration','20260918110000'),
  jsonb_build_object('restrictionPreset','IKUTI_ROLE','migration','20260918110000')
FROM public.user_company_permission_overrides override_row
JOIN public.company_memberships membership
  ON membership.company_id=override_row.company_id
 AND membership.user_id=override_row.user_id
 AND membership.status='ACTIVE' AND membership.role_code='COMPANY_OWNER';

DELETE FROM public.user_company_permission_overrides override_row
USING public.company_memberships membership
WHERE membership.company_id=override_row.company_id
  AND membership.user_id=override_row.user_id
  AND membership.status='ACTIVE' AND membership.role_code='COMPANY_OWNER';

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260918110000','privileged_company_permission_authority',
  'Makes Super Admin globally and Company Owner tenant-locally authoritative for every supported enabled capability; resets Owner restrictions with immutable audit and keeps restrictions for non-privileged Company roles.');

COMMIT;
