-- Rollback-only behavior for privileged Company permission authority.
BEGIN;

DO $test$
DECLARE
  v_owner UUID;v_super UUID;v_company UUID;v_version BIGINT;
  v_result JSONB;v_expected JSONB;v_rejected BOOLEAN:=FALSE;
BEGIN
  SELECT membership.user_id,membership.company_id INTO v_owner,v_company
  FROM public.company_memberships membership
  JOIN auth.users auth_user ON auth_user.id=membership.user_id
  WHERE membership.status='ACTIVE' AND membership.role_code='COMPANY_OWNER'
  ORDER BY membership.company_id,membership.user_id LIMIT 1;
  SELECT profile.id INTO v_super FROM public.profiles profile
  JOIN auth.users auth_user ON auth_user.id=profile.id
  WHERE profile.role='super_admin' ORDER BY profile.id LIMIT 1;
  IF v_owner IS NULL OR v_super IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: authenticated Super Admin and active Company Owner required';
  END IF;

  INSERT INTO public.user_company_permission_overrides(
    company_id,user_id,permission_key,restriction_preset,created_by,updated_by
  ) VALUES(v_company,v_owner,'finance.payment_methods','TANPA_AKSES',v_super,v_super)
  ON CONFLICT(company_id,user_id,permission_key) DO UPDATE SET
    restriction_preset='TANPA_AKSES',master_version=
      public.user_company_permission_overrides.master_version+1,
    updated_by=v_super,updated_at=clock_timestamp()
  RETURNING master_version INTO v_version;

  SELECT jsonb_agg(capability ORDER BY capability) INTO v_expected
  FROM (SELECT DISTINCT unnest(catalog.supported_capabilities) capability
    FROM public.access_permission_catalog catalog
    WHERE catalog.permission_key='finance.payment_methods') expected;

  v_result:=private.acp_resolve_permission(
    v_company,v_owner,'finance.payment_methods');
  IF v_result->>'roleCode'<>'COMPANY_OWNER'
     OR v_result->>'restrictionPreset'<>'IKUTI_ROLE'
     OR v_result->'effectiveCapabilities'<>v_expected THEN
    RAISE EXCEPTION 'TEST_FAILED: Company Owner was narrowed by user override';
  END IF;

  v_result:=private.acp_resolve_permission(
    v_company,v_super,'finance.payment_methods');
  IF v_result->>'roleCode'<>'SUPER_ADMIN'
     OR v_result->'effectiveCapabilities'<>v_expected THEN
    RAISE EXCEPTION 'TEST_FAILED: Super Admin lacks supported Payment Method capabilities';
  END IF;

  IF jsonb_array_length(private.acp_resolve_permission(
    v_company,v_owner,'platform.companies')->'effectiveCapabilities')<>0 THEN
    RAISE EXCEPTION 'TEST_FAILED: Company Owner crossed platform Company boundary';
  END IF;

  EXECUTE 'SET LOCAL ROLE authenticated';
  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub',v_super,'role','authenticated')::text,TRUE);
  BEGIN
    PERFORM public.save_user_permission_override(v_company,v_owner,
      'finance.payment_methods','LIHAT_SAJA',v_version);
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='PRIVILEGED_ROLE_PERMISSION_RESTRICTION_NOT_ALLOWED' THEN
      v_rejected:=TRUE;
    ELSE RAISE;
    END IF;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'TEST_FAILED: Company Owner restriction was accepted';
  END IF;

  v_result:=public.save_user_permission_override(v_company,v_owner,
    'finance.payment_methods','IKUTI_ROLE',v_version);
  IF v_result->>'action'<>'RESET_OVERRIDE' THEN
    RAISE EXCEPTION 'TEST_FAILED: Company Owner override reset invalid';
  END IF;

  RAISE NOTICE 'TEST PASSED: Super Admin is global, Company Owner is Company-scoped, and platform/domain guards remain intact.';
END
$test$;

ROLLBACK;
