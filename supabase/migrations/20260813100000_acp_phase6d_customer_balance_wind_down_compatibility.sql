-- ACP-6D forward fix: preserve Customer Balance authority during WIND_DOWN.
-- A disabled feature with an outstanding liability intentionally enters
-- WIND_DOWN. It must remain reachable by authorized roles until settled.

BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260813090000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: ACP-6D required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260813100000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED';
  END IF;
  IF (SELECT count(*) FROM public.access_permission_catalog
      WHERE permission_key='finance.customer_balances'
        AND enforcement_status='ENFORCED')<>1 THEN
    RAISE EXCEPTION 'CUSTOMER_BALANCE_PERMISSION_NOT_ENFORCED';
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

    IF cardinality(v_catalog.required_any_features)>0 THEN
      SELECT EXISTS(SELECT 1 FROM public.company_features feature
        WHERE feature.company_id=p_company_id AND feature.is_enabled
          AND feature.feature_code=ANY(v_catalog.required_any_features))
      INTO v_feature_enabled;

      -- The domain core still rejects new credit in WIND_DOWN. ACP only keeps
      -- role and optional user restrictions reachable for settlement/reporting.
      IF NOT v_feature_enabled
         AND p_permission_key='finance.customer_balances'
         AND EXISTS(SELECT 1
           FROM public.customer_balance_company_policies policy
           WHERE policy.company_id=p_company_id
             AND policy.lifecycle_state='WIND_DOWN') THEN
        v_feature_enabled:=TRUE;
      END IF;

      -- Once wind-down reaches zero the policy becomes DISABLED, but immutable
      -- historical statements remain auditable. Re-open only read/export
      -- capability when history exists; mutation cores stay unreachable.
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

    IF v_feature_enabled
       AND (v_role='SUPER_ADMIN' OR v_role=ANY(v_catalog.view_roles)) THEN
      v_baseline:=ARRAY['VIEW'];
      IF v_role='SUPER_ADMIN' OR v_role=ANY(v_catalog.operator_roles) THEN
        v_baseline:=v_baseline||ARRAY['CREATE_DRAFT','EDIT_DRAFT','MANAGE'];
      END IF;
      IF v_role='SUPER_ADMIN' OR v_role=ANY(v_catalog.approver_roles) THEN
        v_baseline:=v_baseline||ARRAY[
          'REVIEW','APPROVE','POST','CANCEL_FINAL','REVERSE','CLOSE_PERIOD'];
      END IF;
      IF v_role='SUPER_ADMIN' OR v_role=ANY(v_catalog.view_roles) THEN
        v_baseline:=v_baseline||ARRAY['EXPORT'];
      END IF;
      IF v_role='SUPER_ADMIN' OR v_role IN('COMPANY_OWNER','COMPANY_ADMIN') THEN
        v_baseline:=v_baseline||ARRAY['IMPORT'];
      END IF;
      SELECT COALESCE(array_agg(DISTINCT capability ORDER BY capability),'{}')
      INTO v_baseline FROM unnest(v_baseline) capability
      WHERE capability=ANY(v_catalog.supported_capabilities);
      IF v_customer_balance_history_only THEN
        SELECT COALESCE(array_agg(capability ORDER BY capability),'{}')
        INTO v_baseline FROM unnest(v_baseline) capability
        WHERE capability IN('VIEW','EXPORT');
      END IF;
    END IF;

    SELECT * INTO v_override
    FROM public.user_company_permission_overrides
    WHERE company_id=p_company_id AND user_id=p_target_user_id
      AND permission_key=p_permission_key;

    IF v_override.id IS NULL THEN v_effective:=v_baseline;
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
      'restrictionPreset',COALESCE(v_override.restriction_preset,'IKUTI_ROLE'),
      'overrideVersion',v_override.master_version,
      'effectiveCapabilities',to_jsonb(v_effective),
      'enforcementStatus',v_catalog.enforcement_status,
      'enforced',v_catalog.enforcement_status='ENFORCED');
END;
$$;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260813100000',
  'acp_phase6d_customer_balance_wind_down_compatibility',
  'Preserves ACP restrictions during Customer Balance WIND_DOWN and read-only historical access after final disable.');

COMMIT;
