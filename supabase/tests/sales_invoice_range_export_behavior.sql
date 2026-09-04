-- Rollback-safe behavior for bounded Sales Invoice export.
BEGIN;
DO $test$
DECLARE v_actor UUID;v_company UUID;v_payload JSONB;v_legacy JSONB;
  v_invoice_count BIGINT;v_line_count BIGINT;
BEGIN
  SELECT membership.user_id,membership.company_id INTO v_actor,v_company
  FROM public.company_memberships membership
  JOIN public.companies company ON company.id=membership.company_id
    AND company.status='ACTIVE'
  WHERE membership.status='ACTIVE'
    AND membership.role_code IN('COMPANY_OWNER','COMPANY_ADMIN')
    AND EXISTS(SELECT 1 FROM public.sales_invoice_snapshots invoice
      WHERE invoice.company_id=membership.company_id)
  ORDER BY membership.role_code='COMPANY_OWNER' DESC,membership.created_at LIMIT 1;
  IF v_actor IS NULL THEN
    SELECT profile.id INTO v_actor FROM public.profiles profile
    JOIN auth.users auth_user ON auth_user.id=profile.id
    WHERE profile.role='super_admin'::public.user_role ORDER BY profile.id LIMIT 1;
    SELECT invoice.company_id INTO v_company FROM public.sales_invoice_snapshots invoice
    JOIN public.companies company ON company.id=invoice.company_id AND company.status='ACTIVE'
    ORDER BY invoice.created_at,invoice.id LIMIT 1;
  END IF;
  IF v_actor IS NULL OR v_company IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: export actor and Invoice snapshot required';
  END IF;

  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub',v_actor,'role','authenticated')::TEXT,TRUE);
  INSERT INTO public.user_active_company_contexts(user_id,company_id,selection_source)
  VALUES(v_actor,v_company,'BACKOFFICE') ON CONFLICT(user_id) DO UPDATE SET
    company_id=EXCLUDED.company_id,selection_source=EXCLUDED.selection_source;

  SELECT count(*) INTO v_invoice_count FROM public.sales_invoice_snapshots
  WHERE company_id=v_company;
  SELECT COALESCE(sum(jsonb_array_length(snapshot_payload->'lines')),0)
    INTO v_line_count FROM public.sales_invoice_snapshots
  WHERE company_id=v_company AND jsonb_typeof(snapshot_payload->'lines')='array';

  v_payload:=public.export_sales_documents(DATE '1900-01-01',DATE '2999-12-31');
  IF jsonb_typeof(v_payload)<>'object'
    OR jsonb_typeof(v_payload->'invoices')<>'array'
    OR jsonb_typeof(v_payload->'lines')<>'array'
    OR (v_payload->>'companyId')::UUID<>v_company
    OR jsonb_array_length(v_payload->'invoices')<>v_invoice_count
    OR jsonb_array_length(v_payload->'lines')<>v_line_count THEN
    RAISE EXCEPTION 'TEST_FAILED: ranged Invoice export response invalid';
  END IF;
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(v_payload->'invoices') invoice
    WHERE (invoice->>'invoiceDate')::DATE NOT BETWEEN DATE '1900-01-01' AND DATE '2999-12-31') THEN
    RAISE EXCEPTION 'TEST_FAILED: Invoice outside selected date range';
  END IF;

  v_legacy:=public.export_sales_documents();
  IF jsonb_typeof(v_legacy)<>'array' THEN
    RAISE EXCEPTION 'TEST_FAILED: compatible no-argument export changed';
  END IF;
  BEGIN
    PERFORM public.export_sales_documents(DATE '2026-02-02',DATE '2026-02-01');
    RAISE EXCEPTION 'TEST_FAILED: invalid date range accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%SALES_DOCUMENT_EXPORT_DATE_RANGE_INVALID%' THEN RAISE; END IF;
  END;
END
$test$;
ROLLBACK;
