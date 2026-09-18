-- SELECT-only preflight for 20260918110000.
WITH checks AS (
  SELECT 'permission_dependency_ledger'::text check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END status,
    abs(1-count(*))::bigint violation_rows,
    jsonb_build_object('requiredVersion','20260813100000','ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260813100000'

  UNION ALL
  SELECT 'permission_routine_contract',
    CASE WHEN count(*)=3 THEN 'PASS' ELSE 'BLOCKER' END,
    (3-count(*))::bigint,
    jsonb_build_object('present',count(*),'expected',3)
  FROM (VALUES
    (to_regprocedure('private.acp_resolve_permission(uuid,uuid,text)')),
    (to_regprocedure('public.resolve_user_permission(uuid,uuid,text)')),
    (to_regprocedure('public.save_user_permission_override(uuid,uuid,text,text,bigint)'))
  ) routine(oid) WHERE oid IS NOT NULL

  UNION ALL
  SELECT 'permission_catalog_contract',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('invalidRows',count(*))
  FROM public.access_permission_catalog catalog
  WHERE catalog.is_customizable
    AND (NOT ('VIEW'=ANY(catalog.supported_capabilities))
      OR cardinality(catalog.supported_capabilities)=0)

  UNION ALL
  SELECT 'existing_owner_restriction_inventory','INFO',0,
    jsonb_build_object('rows',count(*),'rule','Migration makes these rows dormant; it does not delete permission history')
  FROM public.user_company_permission_overrides override_row
  JOIN public.company_memberships membership
    ON membership.company_id=override_row.company_id
   AND membership.user_id=override_row.user_id
   AND membership.status='ACTIVE' AND membership.role_code='COMPANY_OWNER'

  UNION ALL
  SELECT 'privileged_identity_inventory','INFO',0,
    jsonb_build_object(
      'superAdmins',(SELECT count(*) FROM public.profiles WHERE role='super_admin'),
      'activeCompanyOwners',(SELECT count(*) FROM public.company_memberships
        WHERE status='ACTIVE' AND role_code='COMPANY_OWNER'))
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
