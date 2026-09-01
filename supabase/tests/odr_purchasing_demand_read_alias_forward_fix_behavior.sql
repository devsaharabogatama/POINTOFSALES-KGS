-- Runtime behavior for the ODR Purchasing demand composed-read forward-fix.
-- Uses existing authorized master data, writes only active-context state, and
-- always rolls the context change back.
BEGIN;

DO $setup$
DECLARE v_actor UUID;v_company UUID;
BEGIN
  SELECT membership.user_id,membership.company_id INTO v_actor,v_company
  FROM public.company_memberships membership
  JOIN public.companies company ON company.id=membership.company_id
    AND company.status='ACTIVE'
  WHERE membership.status='ACTIVE'
    AND (private.acp_resolve_permission(membership.company_id,
      membership.user_id,'purchase.supplier_orders')
      ->'effectiveCapabilities') ? 'VIEW'
  ORDER BY (membership.role_code IN('COMPANY_OWNER','COMPANY_ADMIN')) DESC,
    membership.created_at,membership.user_id LIMIT 1;
  IF v_actor IS NULL OR v_company IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: active Purchasing VIEW actor required';
  END IF;
  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub',v_actor,'role','authenticated')::TEXT,TRUE);
  INSERT INTO public.user_active_company_contexts(
    user_id,company_id,selection_source)
  VALUES(v_actor,v_company,'ODR_READ_TEST')
  ON CONFLICT(user_id) DO UPDATE SET company_id=EXCLUDED.company_id,
    selection_source=EXCLUDED.selection_source;
END
$setup$;

SET LOCAL ROLE authenticated;
DO $test$
DECLARE v_payload JSONB;
BEGIN
  v_payload:=public.get_purchase_procurement_demands();
  IF jsonb_typeof(v_payload)<>'object'
     OR jsonb_typeof(v_payload->'demands')<>'array'
     OR jsonb_typeof(v_payload->'lines')<>'array'
     OR jsonb_typeof(v_payload->'amendments')<>'array' THEN
    RAISE EXCEPTION 'TEST_FAILED: Purchasing demand response shape invalid';
  END IF;
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(v_payload->'lines') line
    WHERE NOT line ? 'product_name' OR NOT line ? 'product_sku'
      OR NOT line ? 'demand_id' OR NOT line ? 'id') THEN
    RAISE EXCEPTION 'TEST_FAILED: Purchasing demand product projection invalid';
  END IF;
END
$test$;
RESET ROLE;

SELECT 'odr_purchasing_demand_read_alias_forward_fix_behavior' check_name,
  'PASS' status,jsonb_build_object('tested',ARRAY[
    'authorized runtime execution','demand/line/amendment response shape',
    'Product identity projection']) details;
ROLLBACK;
