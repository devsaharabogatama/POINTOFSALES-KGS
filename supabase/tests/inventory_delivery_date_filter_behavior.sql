-- Rollback-safe behavior for Inventory Delivery date filtering.
BEGIN;

DO $fixture$
DECLARE v_actor UUID;v_company UUID;
BEGIN
  SELECT profile.id INTO v_actor FROM public.profiles profile
  JOIN auth.users auth_user ON auth_user.id=profile.id
  WHERE public.private_is_super_admin(profile.id)
  ORDER BY profile.id LIMIT 1;
  SELECT company.id INTO v_company FROM public.companies company
  WHERE company.status='ACTIVE' ORDER BY company.id LIMIT 1;
  IF v_actor IS NULL OR v_company IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: linked Super Admin and active Company required';
  END IF;
  INSERT INTO public.user_active_company_contexts(user_id,company_id,selection_source)
  VALUES(v_actor,v_company,'BACKOFFICE') ON CONFLICT(user_id) DO UPDATE SET
    company_id=EXCLUDED.company_id,selection_source=EXCLUDED.selection_source;
  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub',v_actor,'role','authenticated')::TEXT,TRUE);
END
$fixture$;

SET LOCAL ROLE authenticated;

DO $behavior$
DECLARE v_all JSONB;v_future JSONB;v_invalid_rejected BOOLEAN:=FALSE;
BEGIN
  v_all:=public.get_inventory_delivery_documents(NULL,NULL);
  IF jsonb_typeof(v_all->'data')<>'array' OR v_all->>'timezone' IS NULL THEN
    RAISE EXCEPTION 'TEST_FAILED: unbounded date response invalid';
  END IF;
  v_future:=public.get_inventory_delivery_documents('2100-01-01','2100-01-31');
  IF jsonb_array_length(v_future->'data')<>0
    OR v_future->>'dateFrom'<>'2100-01-01'
    OR v_future->>'dateTo'<>'2100-01-31' THEN
    RAISE EXCEPTION 'TEST_FAILED: bounded date response invalid';
  END IF;
  BEGIN
    PERFORM public.get_inventory_delivery_documents('2026-08-31','2026-08-01');
  EXCEPTION WHEN OTHERS THEN
    v_invalid_rejected:=SQLERRM LIKE '%INVALID_DELIVERY_DATE_RANGE%';
  END;
  IF NOT v_invalid_rejected THEN
    RAISE EXCEPTION 'TEST_FAILED: invalid range was not rejected';
  END IF;
END
$behavior$;

RESET ROLE;
ROLLBACK;

SELECT 'inventory_delivery_date_filter_behavior' AS check_name,'PASS' AS status,
  jsonb_build_object('rolledBack',TRUE) AS details;
