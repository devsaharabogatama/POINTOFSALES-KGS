-- Behavioral contract for Platform Operational Health Dashboard.
-- No business data is written. JWT claims are transaction-local.
BEGIN;

DO $precondition$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM public.profiles profile
    WHERE profile.role::TEXT='super_admin') THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: linked Super Admin required';
  END IF;
END
$precondition$;

SELECT set_config('request.jwt.claims',jsonb_build_object(
  'sub',(SELECT profile.id FROM public.profiles profile
    WHERE profile.role::TEXT='super_admin' ORDER BY profile.id LIMIT 1),
  'role','authenticated')::TEXT,TRUE);
SET LOCAL ROLE authenticated;
DO $super_test$
DECLARE v_payload JSONB;
BEGIN
  v_payload:=public.get_platform_operational_health();
  IF jsonb_typeof(v_payload)<>'object'
    OR v_payload->>'contractVersion'<>'1'
    OR v_payload->>'refreshMode'<>'MANUAL'
    OR v_payload->>'readOnly'<>'true'
    OR jsonb_typeof(v_payload->'summary')<>'object'
    OR jsonb_typeof(v_payload->'companies')<>'array'
    OR jsonb_typeof(v_payload->'issues')<>'array'
    OR jsonb_array_length(v_payload->'companies')<>
      (SELECT count(*) FROM public.companies) THEN
    RAISE EXCEPTION 'TEST_FAILED: Super Admin health response invalid';
  END IF;
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(v_payload->'companies') item
    WHERE NOT item ? 'companyId' OR NOT item ? 'healthStatus'
      OR NOT item ? 'metrics') THEN
    RAISE EXCEPTION 'TEST_FAILED: Company health projection invalid';
  END IF;
END
$super_test$;
RESET ROLE;

SELECT set_config('request.jwt.claims',jsonb_build_object(
  'sub',gen_random_uuid(),
  'role','authenticated')::TEXT,TRUE);
SET LOCAL ROLE authenticated;
DO $regular_test$
DECLARE v_denied BOOLEAN:=FALSE;
BEGIN
  BEGIN
    PERFORM public.get_platform_operational_health();
  EXCEPTION WHEN OTHERS THEN
    v_denied:=SQLERRM LIKE '%SUPER_ADMIN_REQUIRED%';
  END;
  IF NOT v_denied THEN
    RAISE EXCEPTION 'TEST_FAILED: regular user health access not denied';
  END IF;
END
$regular_test$;
RESET ROLE;

SELECT 'platform_operational_health_dashboard_behavior' check_name,
  'PASS' status,jsonb_build_object('tested',ARRAY[
    'Super Admin global response','all Company projection',
    'manual read-only contract','regular-user denial when fixture exists'],
    'writesPersisted',FALSE) details;
ROLLBACK;
