-- Rollback-safe behavior for canonical Invoice display date.
BEGIN;
DO $test$
DECLARE v_date DATE;v_actor UUID;v_company UUID;v_payload JSONB;
  v_sales_id UUID;v_detail JSONB;v_mismatch BIGINT;
BEGIN
  v_date:=private.resolve_sales_invoice_display_date(
    '{"branding":{"invoiceDateDisplayMode":"ORDER_DATE"},"company":{"timezone":"Asia/Jakarta"},"transactionAt":"2026-08-29T05:19:05Z"}'::JSONB,
    '{"order_timing_mode":"SCHEDULED","planned_order_date":"2026-08-31","transaction_date":"2026-08-29T05:19:05Z"}'::JSONB,
    '2026-08-31T07:19:11Z','Asia/Jakarta');
  IF v_date IS DISTINCT FROM DATE '2026-08-31' THEN
    RAISE EXCEPTION 'TEST_FAILED: Scheduled ORDER_DATE did not use planned date';
  END IF;

  v_date:=private.resolve_sales_invoice_display_date(
    '{"branding":{"invoiceDateDisplayMode":"ORDER_DATE"},"company":{"timezone":"Asia/Jakarta"},"transactionAt":"2026-08-29T17:30:00Z"}'::JSONB,
    '{"order_timing_mode":"IMMEDIATE","transaction_date":"2026-08-29T17:30:00Z"}'::JSONB,
    '2026-08-31T07:19:11Z','Asia/Jakarta');
  IF v_date IS DISTINCT FROM DATE '2026-08-30' THEN
    RAISE EXCEPTION 'TEST_FAILED: Immediate ORDER_DATE timezone behavior changed';
  END IF;

  v_date:=private.resolve_sales_invoice_display_date(
    '{"branding":{"invoiceDateDisplayMode":"POSTED_DATE"},"company":{"timezone":"Asia/Jakarta"},"transactionAt":"2026-08-29T05:19:05Z"}'::JSONB,
    '{"order_timing_mode":"SCHEDULED","planned_order_date":"2026-08-31","confirmed_at":"2026-09-01T02:00:00Z"}'::JSONB,
    '2026-09-01T02:00:00Z','Asia/Jakarta');
  IF v_date IS DISTINCT FROM DATE '2026-09-01' THEN
    RAISE EXCEPTION 'TEST_FAILED: POSTED_DATE behavior changed';
  END IF;

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
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: Invoice reader actor required';
  END IF;
  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub',v_actor,'role','authenticated')::TEXT,TRUE);
  INSERT INTO public.user_active_company_contexts(user_id,company_id,selection_source)
  VALUES(v_actor,v_company,'BACKOFFICE') ON CONFLICT(user_id) DO UPDATE SET
    company_id=EXCLUDED.company_id,selection_source=EXCLUDED.selection_source;

  v_payload:=public.get_sales_documents();
  SELECT count(*) INTO v_mismatch
  FROM jsonb_array_elements(v_payload->'data') item
  JOIN public.sales_invoice_snapshots invoice
    ON invoice.company_id=v_company AND invoice.sales_id=(item->>'salesId')::UUID
  JOIN public.sales_headers sale ON sale.company_id=invoice.company_id
    AND sale.id=invoice.sales_id
  JOIN public.companies company ON company.id=invoice.company_id
  WHERE (item->>'invoiceDate')::DATE IS DISTINCT FROM
    private.resolve_sales_invoice_display_date(invoice.snapshot_payload,
      to_jsonb(sale),invoice.created_at,company.timezone);
  IF v_mismatch<>0 THEN
    RAISE EXCEPTION 'TEST_FAILED: Invoice list date mismatch';
  END IF;

  SELECT invoice.sales_id INTO v_sales_id FROM public.sales_invoice_snapshots invoice
    WHERE invoice.company_id=v_company ORDER BY invoice.created_at DESC LIMIT 1;
  v_detail:=public.get_sales_invoice_document(v_sales_id);
  IF NULLIF(v_detail->>'invoiceDate','') IS NULL THEN
    RAISE EXCEPTION 'TEST_FAILED: Invoice detail missing canonical date';
  END IF;

  v_payload:=public.export_sales_documents(DATE '1900-01-01',DATE '2999-12-31');
  SELECT count(*) INTO v_mismatch
  FROM jsonb_array_elements(v_payload->'invoices') item
  JOIN public.sales_invoice_snapshots invoice
    ON invoice.company_id=v_company AND invoice.sales_id=(item->>'salesId')::UUID
  JOIN public.sales_headers sale ON sale.company_id=invoice.company_id
    AND sale.id=invoice.sales_id
  JOIN public.companies company ON company.id=invoice.company_id
  WHERE (item->>'invoiceDate')::DATE IS DISTINCT FROM
    private.resolve_sales_invoice_display_date(invoice.snapshot_payload,
      to_jsonb(sale),invoice.created_at,company.timezone);
  IF v_mismatch<>0 THEN
    RAISE EXCEPTION 'TEST_FAILED: Invoice export date mismatch';
  END IF;
END
$test$;
ROLLBACK;

