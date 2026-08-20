-- Rollback-safe behavior. Uses an Owner/Admin when available, otherwise a
-- linked Super Admin, against one active Company that already has a PO.
BEGIN;
DO $test$
DECLARE v_actor UUID;v_company UUID;v_order UUID;v_unknown UUID;v_payload JSONB;
BEGIN
  SELECT membership.user_id,membership.company_id INTO v_actor,v_company
  FROM public.company_memberships membership
  JOIN public.companies company ON company.id=membership.company_id AND company.status='ACTIVE'
  WHERE membership.status='ACTIVE' AND membership.role_code IN('COMPANY_OWNER','COMPANY_ADMIN')
    AND EXISTS(SELECT 1 FROM public.supplier_order_documents document
      WHERE document.company_id=membership.company_id)
  ORDER BY membership.role_code='COMPANY_OWNER' DESC,membership.created_at LIMIT 1;
  IF v_actor IS NULL THEN
    SELECT profile.id INTO v_actor FROM public.profiles profile
    JOIN auth.users auth_user ON auth_user.id=profile.id
    WHERE profile.role='super_admin'::public.user_role
    ORDER BY profile.id LIMIT 1;
    SELECT document.company_id INTO v_company
    FROM public.supplier_order_documents document
    JOIN public.companies company ON company.id=document.company_id
      AND company.status='ACTIVE'
    ORDER BY document.created_at,document.id LIMIT 1;
  END IF;
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: linked Super Admin required';
  END IF;
  IF v_company IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: active Company with Supplier Order required';
  END IF;
  SELECT document.id INTO v_order FROM public.supplier_order_documents document
  WHERE document.company_id=v_company ORDER BY document.created_at,document.id LIMIT 1;
  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub',v_actor,'role','authenticated')::TEXT,TRUE);
  INSERT INTO public.user_active_company_contexts(user_id,company_id,selection_source)
  VALUES(v_actor,v_company,'BACKOFFICE') ON CONFLICT(user_id) DO UPDATE SET
    company_id=EXCLUDED.company_id,selection_source=EXCLUDED.selection_source;

  v_payload:=public.export_purchase_supplier_orders(ARRAY[v_order]);
  IF jsonb_array_length(v_payload->'orders')<>1
     OR v_payload->'orders'->0->>'orderId'<>v_order::TEXT
     OR (v_payload->>'selectionCount')::INTEGER<>1 THEN
    RAISE EXCEPTION 'TEST_FAILED: selected export response invalid';
  END IF;
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(v_payload->'lines') line
    WHERE line->>'orderId'<>v_order::TEXT) THEN
    RAISE EXCEPTION 'TEST_FAILED: unrelated PO line leaked';
  END IF;
  LOOP
    v_unknown:=gen_random_uuid();
    EXIT WHEN NOT EXISTS(SELECT 1 FROM public.supplier_order_documents document
      WHERE document.id=v_unknown);
  END LOOP;
  BEGIN
    PERFORM public.export_purchase_supplier_orders(ARRAY[v_unknown]);
    RAISE EXCEPTION 'TEST_FAILED: unknown PO accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%SUPPLIER_ORDER_EXPORT_NOT_FOUND_OR_ACCESS_DENIED%' THEN RAISE; END IF;
  END;
END
$test$;
ROLLBACK;
