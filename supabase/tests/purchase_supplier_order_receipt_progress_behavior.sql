-- Runtime behavior for Supplier Order ordered/received/remaining detail.
-- Uses an existing authorized actor and rolls active-context changes back.
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
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: active Supplier Order VIEW actor required';
  END IF;
  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub',v_actor,'role','authenticated')::TEXT,TRUE);
  INSERT INTO public.user_active_company_contexts(
    user_id,company_id,selection_source)
  VALUES(v_actor,v_company,'PURCHASE_READ_TEST')
  ON CONFLICT(user_id) DO UPDATE SET company_id=EXCLUDED.company_id,
    selection_source=EXCLUDED.selection_source;
END
$setup$;

SET LOCAL ROLE authenticated;
DO $test$
DECLARE v_payload JSONB;v_line JSONB;v_ordered NUMERIC;v_received NUMERIC;
  v_remaining NUMERIC;v_factor NUMERIC;v_expected_status TEXT;
BEGIN
  v_payload:=public.get_purchase_supplier_orders();
  IF jsonb_typeof(v_payload)<>'object'
     OR jsonb_typeof(v_payload->'orders')<>'array'
     OR jsonb_typeof(v_payload->'orderLines')<>'array'
     OR (v_payload->>'supplierOrderReceiptProgressVersion')<>'1' THEN
    RAISE EXCEPTION 'TEST_FAILED: Supplier Order response shape invalid';
  END IF;
  FOR v_line IN SELECT value FROM jsonb_array_elements(v_payload->'orderLines')
  LOOP
    IF NOT (v_line ?& ARRAY['id','document_id','product_name_snapshot',
        'ordered_qty','ordered_base_qty','factor_to_base_snapshot',
        'received_base_qty','remaining_base_qty','received_ordered_qty',
        'remaining_ordered_qty','receipt_progress','posted_receipt_count']) THEN
      RAISE EXCEPTION 'TEST_FAILED: Supplier Order line detail incomplete';
    END IF;
    v_ordered:=(v_line->>'ordered_base_qty')::NUMERIC;
    v_received:=(v_line->>'received_base_qty')::NUMERIC;
    v_remaining:=(v_line->>'remaining_base_qty')::NUMERIC;
    v_factor:=(v_line->>'factor_to_base_snapshot')::NUMERIC;
    v_expected_status:=CASE WHEN v_received<=0 THEN 'NOT_RECEIVED'
      WHEN v_received<v_ordered THEN 'PARTIAL' ELSE 'COMPLETE' END;
    IF v_factor<=0 OR v_received<0
       OR v_remaining<>GREATEST(v_ordered-v_received,0)
       OR (v_line->>'received_ordered_qty')::NUMERIC<>v_received/v_factor
       OR (v_line->>'remaining_ordered_qty')::NUMERIC<>v_remaining/v_factor
       OR (v_line->>'receipt_progress')<>v_expected_status THEN
      RAISE EXCEPTION 'TEST_FAILED: Supplier Order receipt progress invalid';
    END IF;
  END LOOP;
END
$test$;
RESET ROLE;

SELECT 'purchase_supplier_order_receipt_progress_behavior' check_name,
  'PASS' status,jsonb_build_object('tested',ARRAY[
    'authenticated Supplier Order read','line detail response shape',
    'ordered/received/remaining conversion','receipt progress status']) details;
ROLLBACK;
