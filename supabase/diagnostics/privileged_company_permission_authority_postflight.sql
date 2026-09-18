-- SELECT-only postflight for 20260918110000.
WITH owner_resolution AS (
  SELECT membership.company_id,membership.user_id,catalog.permission_key,
    catalog.supported_capabilities,
    private.acp_resolve_permission(
      membership.company_id,membership.user_id,catalog.permission_key) resolved
  FROM public.company_memberships membership
  CROSS JOIN public.access_permission_catalog catalog
  WHERE membership.status='ACTIVE' AND membership.role_code='COMPANY_OWNER'
    AND catalog.is_customizable
    AND (cardinality(catalog.required_any_features)=0 OR EXISTS(
      SELECT 1 FROM public.company_features feature
      WHERE feature.company_id=membership.company_id AND feature.is_enabled
        AND feature.feature_code=ANY(catalog.required_any_features)))
), super_resolution AS (
  SELECT company.id company_id,profile.id user_id,catalog.permission_key,
    catalog.supported_capabilities,
    private.acp_resolve_permission(company.id,profile.id,catalog.permission_key) resolved
  FROM public.companies company
  CROSS JOIN public.profiles profile
  CROSS JOIN public.access_permission_catalog catalog
  WHERE company.status='ACTIVE' AND profile.role='super_admin'
    AND (cardinality(catalog.required_any_features)=0 OR EXISTS(
      SELECT 1 FROM public.company_features feature
      WHERE feature.company_id=company.id AND feature.is_enabled
        AND feature.feature_code=ANY(catalog.required_any_features)))
), checks AS (
  SELECT 'privileged_authority_migration_ledger'::text check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(1-count(*))::bigint violation_rows,
    jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260918110000'

  UNION ALL
  SELECT 'company_owner_full_capability_contract',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('invalidRows',count(*),'zeroRowsNotBehaviorProof',
      NOT EXISTS(SELECT 1 FROM owner_resolution))
  FROM owner_resolution resolution
  WHERE resolution.resolved->>'roleCode'<>'COMPANY_OWNER'
     OR resolution.resolved->>'restrictionPreset'<>'IKUTI_ROLE'
     OR resolution.resolved->'effectiveCapabilities' <>
        (SELECT jsonb_agg(capability ORDER BY capability)
         FROM (SELECT DISTINCT unnest(resolution.supported_capabilities) capability) item)

  UNION ALL
  SELECT 'super_admin_full_capability_contract',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('invalidRows',count(*),'zeroRowsNotBehaviorProof',
      NOT EXISTS(SELECT 1 FROM super_resolution))
  FROM super_resolution resolution
  WHERE resolution.resolved->>'roleCode'<>'SUPER_ADMIN'
     OR resolution.resolved->>'restrictionPreset'<>'IKUTI_ROLE'
     OR resolution.resolved->'effectiveCapabilities' <>
        (SELECT jsonb_agg(capability ORDER BY capability)
         FROM (SELECT DISTINCT unnest(resolution.supported_capabilities) capability) item)

  UNION ALL
  SELECT 'owner_override_reset_contract',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('invalidRows',count(*))
  FROM public.user_company_permission_overrides override_row
  JOIN public.company_memberships membership
    ON membership.company_id=override_row.company_id
   AND membership.user_id=override_row.user_id
   AND membership.status='ACTIVE' AND membership.role_code='COMPANY_OWNER'

  UNION ALL
  SELECT 'platform_company_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('ownersWithPlatformCompanyCapability',count(*))
  FROM public.company_memberships membership
  WHERE membership.status='ACTIVE' AND membership.role_code='COMPANY_OWNER'
    AND jsonb_array_length(private.acp_resolve_permission(
      membership.company_id,membership.user_id,'platform.companies')
      ->'effectiveCapabilities')>0

  UNION ALL
  SELECT 'privileged_permission_acl_contract',
    CASE WHEN NOT has_function_privilege('authenticated',
      'private.acp_resolve_permission(uuid,uuid,text)','EXECUTE')
      AND has_function_privilege('authenticated',
      'public.resolve_user_permission(uuid,uuid,text)','EXECUTE')
      AND has_function_privilege('authenticated',
      'public.save_user_permission_override(uuid,uuid,text,text,bigint)','EXECUTE')
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN NOT has_function_privilege('authenticated',
      'private.acp_resolve_permission(uuid,uuid,text)','EXECUTE')
      AND has_function_privilege('authenticated',
      'public.resolve_user_permission(uuid,uuid,text)','EXECUTE')
      AND has_function_privilege('authenticated',
      'public.save_user_permission_override(uuid,uuid,text,text,bigint)','EXECUTE')
      THEN 0 ELSE 1 END::bigint,
    '{}'::jsonb

  UNION ALL
  SELECT 'privileged_authority_runtime_inventory','INFO',0,
    jsonb_build_object(
      'ownerResolutionRows',(SELECT count(*) FROM owner_resolution),
      'superResolutionRows',(SELECT count(*) FROM super_resolution),
      'ownerOverrideRows',(SELECT count(*)
        FROM public.user_company_permission_overrides override_row
        JOIN public.company_memberships membership
          ON membership.company_id=override_row.company_id
         AND membership.user_id=override_row.user_id
         AND membership.status='ACTIVE' AND membership.role_code='COMPANY_OWNER'))
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
