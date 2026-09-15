-- Read-only runtime exercised inside rollback-only authenticated context fixture.
BEGIN;
DO $test$
DECLARE v_actor uuid;v_company uuid;v_workspace jsonb;v_count bigint;
  v_generated boolean:=EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260914180000');
BEGIN
  SELECT profile.id,company.id INTO STRICT v_actor,v_company
  FROM public.profiles profile JOIN auth.users actor ON actor.id=profile.id
  CROSS JOIN public.companies company
  WHERE profile.role='super_admin'::public.user_role AND company.status='ACTIVE'
    AND EXISTS(SELECT 1 FROM public.supplier_order_documents document
      WHERE document.company_id=company.id
      AND document.status IN('CONFIRMED','PARTIALLY_RECEIVED')
      AND (NOT v_generated OR EXISTS(SELECT 1 FROM public.goods_receipt_documents receipt
        WHERE receipt.company_id=document.company_id AND receipt.supplier_order_id=document.id
          AND receipt.source_channel='BACKOFFICE' AND receipt.status='DRAFT')))
  ORDER BY company.id,profile.id LIMIT 1;
  INSERT INTO public.user_active_company_contexts(user_id,company_id,selection_source)
  VALUES(v_actor,v_company,'BACKOFFICE_TEST')
  ON CONFLICT(user_id) DO UPDATE SET company_id=excluded.company_id,
    selection_source=excluded.selection_source;
  PERFORM set_config('request.jwt.claim.sub',v_actor::text,true);
  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub',v_actor,'role','authenticated')::text,true);
  v_workspace:=public.get_backoffice_goods_receipt_workspace();
  IF jsonb_typeof(v_workspace->'draftLines')<>'array'
    OR jsonb_typeof(v_workspace->'orders')<>'array'
    OR jsonb_array_length(v_workspace->'orders')=0 THEN
    RAISE EXCEPTION 'TEST_FAILED: real legacy Receipt workspace invalid';
  END IF;
  SELECT count(*) INTO v_count FROM public.supplier_order_documents document
  WHERE document.company_id=v_company
    AND document.status IN('CONFIRMED','PARTIALLY_RECEIVED')
    AND (NOT v_generated OR EXISTS(SELECT 1 FROM public.goods_receipt_documents receipt
      WHERE receipt.company_id=document.company_id AND receipt.supplier_order_id=document.id
        AND receipt.source_channel='BACKOFFICE' AND receipt.status='DRAFT'));
  IF jsonb_array_length(v_workspace->'orders')<>v_count THEN
    RAISE EXCEPTION 'TEST_FAILED: legacy PO visibility changed';
  END IF;
  RAISE NOTICE 'PASS: authenticated Receipt workspace SQL executes with real legacy PO rows; context rolled back';
END $test$;
ROLLBACK;
