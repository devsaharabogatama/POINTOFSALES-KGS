-- Authenticated rollback-only behavior for generated Receipt operator handoff.
BEGIN;
DO $test$
DECLARE v_receipt public.goods_receipt_documents%rowtype;
  v_actor constant uuid:='00000000-0000-0000-0000-000000171411';v_other uuid;
  v_lines jsonb;v_result jsonb;v_stock bigint;v_events bigint;v_audit bigint;
  v_message text;v_stale boolean:=false;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260917141000') THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: migration 20260917141000 required';
  END IF;
  SELECT receipt.* INTO v_receipt
  FROM public.goods_receipt_documents receipt
  JOIN public.supplier_order_documents source
    ON source.company_id=receipt.company_id AND source.id=receipt.supplier_order_id
   AND source.status IN('CONFIRMED','PARTIALLY_RECEIVED')
  WHERE receipt.source_channel='BACKOFFICE' AND receipt.status='DRAFT'
    AND receipt.line_count>0
    AND EXISTS(SELECT 1 FROM public.goods_receipt_lines line
      WHERE line.company_id=receipt.company_id AND line.document_id=receipt.id)
  ORDER BY receipt.updated_at DESC,receipt.id LIMIT 1;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: one started generated Receipt Draft required';
  END IF;
  INSERT INTO auth.users(id,email,instance_id,raw_app_meta_data,raw_user_meta_data,
    is_super_admin,role,aud,email_confirmed_at)
  VALUES(v_actor,'receipt-handoff@example.invalid',
    '00000000-0000-0000-0000-000000000000',
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{"name":"Receipt Handoff Test"}'::jsonb,false,'authenticated','authenticated',now())
  ON CONFLICT(id) DO NOTHING;
  INSERT INTO public.profiles(id,email,name,role)
  VALUES(v_actor,'receipt-handoff@example.invalid','Receipt Handoff Test',
    'cashier'::public.user_role)
  ON CONFLICT(id) DO UPDATE SET email=excluded.email,name=excluded.name,role=excluded.role;
  INSERT INTO public.company_memberships(company_id,user_id,role_code,status,is_default_company)
  VALUES(v_receipt.company_id,v_actor,'WAREHOUSE_ADMIN','ACTIVE',false)
  ON CONFLICT(company_id,user_id) DO UPDATE
    SET role_code=excluded.role_code,status=excluded.status;
  v_other:=v_receipt.received_by;
  SELECT jsonb_agg(jsonb_build_object(
      'clientLineKey',line.client_line_key,
      'supplierOrderLineId',line.supplier_order_line_id,
      'receivedUomId',line.received_uom_id,
      'receivedQty',line.received_qty,
      'acceptedGoodQty',line.accepted_good_qty,
      'damagedQty',line.damaged_qty,
      'rejectedQty',line.rejected_qty) ORDER BY line.line_no)
    INTO v_lines
  FROM public.goods_receipt_lines line
  WHERE line.company_id=v_receipt.company_id AND line.document_id=v_receipt.id;
  IF v_lines IS NULL THEN RAISE EXCEPTION 'TEST_FAILED: source Receipt lines missing'; END IF;

  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub',v_actor,'role','authenticated')::text,true);
  PERFORM public.set_active_company_context(v_receipt.company_id,'RECEIPT_HANDOFF_TEST');
  SELECT count(*) INTO v_stock FROM public.stock_movements
    WHERE company_id=v_receipt.company_id;
  SELECT count(*) INTO v_events FROM public.financial_events
    WHERE company_id=v_receipt.company_id;
  SELECT count(*) INTO v_audit FROM public.goods_receipt_audit
    WHERE company_id=v_receipt.company_id AND document_id=v_receipt.id;

  v_result:=public.save_generated_backoffice_goods_receipt(v_receipt.id,
    v_receipt.master_version,v_receipt.supplier_order_id,
    v_receipt.supplier_delivery_no,v_receipt.notes,v_lines);
  IF v_result->>'status'<>'DRAFT'
    OR NOT EXISTS(SELECT 1 FROM public.goods_receipt_documents receipt
      WHERE receipt.company_id=v_receipt.company_id AND receipt.id=v_receipt.id
        AND receipt.received_by=v_actor)
    OR (SELECT count(*) FROM public.goods_receipt_audit audit
      WHERE audit.company_id=v_receipt.company_id AND audit.document_id=v_receipt.id)<v_audit+2
    OR (SELECT count(*) FROM public.stock_movements WHERE company_id=v_receipt.company_id)<>v_stock
    OR (SELECT count(*) FROM public.financial_events WHERE company_id=v_receipt.company_id)<>v_events THEN
    RAISE EXCEPTION 'TEST_FAILED: authorized operator handoff/audit/zero-effect contract invalid';
  END IF;
  BEGIN
    PERFORM public.save_generated_backoffice_goods_receipt(v_receipt.id,
      v_receipt.master_version,v_receipt.supplier_order_id,
      v_receipt.supplier_delivery_no,v_receipt.notes,v_lines);
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_message=MESSAGE_TEXT;
    IF v_message='MASTER_VERSION_CONFLICT' THEN v_stale:=true; ELSE RAISE; END IF;
  END;
  IF NOT v_stale THEN RAISE EXCEPTION 'TEST_FAILED: stale version accepted after handoff'; END IF;
  IF v_other=v_actor THEN RAISE EXCEPTION 'TEST_FAILED: behavior did not use a second actor'; END IF;
END
$test$;
ROLLBACK;
SELECT 'generated_goods_receipt_operator_handoff_behavior' check_name,'PASS' status,
  0::bigint violation_rows,jsonb_build_object('tested',jsonb_build_array(
    'authorized second operator continues started generated Receipt',
    'received_by becomes actual operator','handoff and save are audited',
    'Draft save has zero Stock/Finance effect','stale version rejected',
    'all fixture writes rolled back')) details;
