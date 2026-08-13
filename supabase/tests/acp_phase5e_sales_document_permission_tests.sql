-- ACP-5E behavior: Sales Document restriction and independent POS access.
-- SAFETY: override, print audit, and attempted lifecycle mutation roll back.

BEGIN;

DO $test$
DECLARE v_actor UUID;v_company UUID;v_sale UUID;v_invoice UUID;
  v_result JSONB;v_rejected BOOLEAN:=FALSE;
BEGIN
  SELECT membership.user_id,membership.company_id
  INTO v_actor,v_company
  FROM public.company_memberships membership
  JOIN auth.users auth_user ON auth_user.id=membership.user_id
  WHERE membership.status='ACTIVE'
    AND membership.role_code IN('COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER')
    AND EXISTS(SELECT 1 FROM public.sales_invoice_snapshots invoice
      WHERE invoice.company_id=membership.company_id)
  ORDER BY membership.company_id,membership.user_id LIMIT 1;
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: manager and Invoice required';
  END IF;
  SELECT invoice.sales_id,invoice.id INTO v_sale,v_invoice
  FROM public.sales_invoice_snapshots invoice
  WHERE invoice.company_id=v_company ORDER BY invoice.created_at LIMIT 1;

  INSERT INTO public.user_company_permission_overrides(
    company_id,user_id,permission_key,restriction_preset,created_by,updated_by
  ) VALUES(v_company,v_actor,'sales.sales_documents','LIHAT_SAJA',v_actor,v_actor)
  ON CONFLICT(company_id,user_id,permission_key) DO UPDATE SET
    restriction_preset='LIHAT_SAJA',master_version=
      public.user_company_permission_overrides.master_version+1,
    updated_by=v_actor,updated_at=clock_timestamp();

  EXECUTE 'SET LOCAL ROLE authenticated';
  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub',v_actor,'role','authenticated')::TEXT,TRUE);
  PERFORM public.set_active_company_context(v_company,'ACP5E_TEST');

  v_result:=public.get_sales_documents();
  IF jsonb_typeof(v_result->'data')<>'array' THEN
    RAISE EXCEPTION 'TEST_FAILED: composed VIEW response invalid';
  END IF;
  v_result:=public.get_sales_invoice_document(v_sale);
  IF (v_result->>'invoiceSnapshotId')::UUID<>v_invoice THEN
    RAISE EXCEPTION 'TEST_FAILED: Invoice identity missing';
  END IF;
  v_result:=public.record_sales_document_print('SALES_INVOICE',v_invoice);
  IF COALESCE((v_result->>'printRecorded')::BOOLEAN,FALSE) IS NOT TRUE THEN
    RAISE EXCEPTION 'TEST_FAILED: print was not recorded';
  END IF;

  BEGIN
    PERFORM public.export_sales_documents();
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='CUSTOM_PERMISSION_DENIED' THEN v_rejected:=TRUE; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'TEST_FAILED: LIHAT_SAJA exported Sales documents';
  END IF;

  v_result:=public.get_pos_sales_invoice_document(v_sale);
  IF (v_result->>'invoiceSnapshotId')::UUID<>v_invoice THEN
    RAISE EXCEPTION 'TEST_FAILED: POS Invoice path broken';
  END IF;
  PERFORM public.record_pos_sales_document_print('SALES_INVOICE',v_invoice);

  IF has_table_privilege('authenticated','public.sales_invoice_snapshots','SELECT')
    OR has_table_privilege('authenticated','public.sales_delivery_documents','SELECT')
    OR has_table_privilege('authenticated','public.sales_delivery_lines','SELECT')
    OR has_table_privilege('authenticated','public.sales_document_audit','SELECT')
  THEN RAISE EXCEPTION 'TEST_FAILED: direct Sales Document read remains'; END IF;

  RAISE NOTICE 'TEST PASSED: Invoice VIEW/EXPORT and POS authority are separated; Delivery authority is tested independently.';
END
$test$;

ROLLBACK;
