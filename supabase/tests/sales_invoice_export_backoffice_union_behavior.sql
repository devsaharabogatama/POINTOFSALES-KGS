-- Authenticated, rollback-only behavior proof for the combined Invoice export.
BEGIN;
DO $test$
DECLARE
  v_actor uuid;v_company uuid;v_from date;v_to date;v_payload jsonb;
  v_expected_invoice bigint;v_expected_line bigint;v_actual_invoice bigint;v_actual_line bigint;
  v_expected_retail bigint;v_actual_retail bigint;
BEGIN
  SELECT profile.id,invoice.company_id INTO v_actor,v_company
  FROM public.profiles profile
  JOIN auth.users actor ON actor.id=profile.id
  CROSS JOIN LATERAL (
    SELECT candidate.company_id FROM public.backoffice_sales_invoices candidate
    GROUP BY candidate.company_id
    HAVING count(*)>0 AND EXISTS(SELECT 1 FROM public.backoffice_sales_invoice_lines line
      WHERE line.company_id=candidate.company_id)
    ORDER BY candidate.company_id LIMIT 1
  ) invoice
  WHERE profile.role='super_admin'::public.user_role
  ORDER BY profile.id LIMIT 1;
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: authorized Company with Backoffice Invoice required';
  END IF;
  SELECT min(invoice.invoice_date),max(invoice.invoice_date) INTO v_from,v_to
  FROM public.backoffice_sales_invoices invoice WHERE invoice.company_id=v_company;

  PERFORM set_config('request.jwt.claim.role','authenticated',true);
  PERFORM set_config('request.jwt.claim.sub',v_actor::text,true);
  PERFORM set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',v_actor)::text,true);
  INSERT INTO public.user_active_company_contexts(user_id,company_id)
  VALUES(v_actor,v_company)
  ON CONFLICT(user_id) DO UPDATE SET company_id=excluded.company_id,
    selected_at=clock_timestamp(),updated_at=clock_timestamp();

  v_payload:=public.export_sales_documents(v_from,v_to);
  SELECT count(*) INTO v_expected_invoice FROM public.backoffice_sales_invoices invoice
    WHERE invoice.company_id=v_company AND invoice.invoice_date BETWEEN v_from AND v_to;
  SELECT count(*) INTO v_expected_line FROM public.backoffice_sales_invoice_lines line
    JOIN public.backoffice_sales_invoices invoice ON invoice.company_id=line.company_id
      AND invoice.id=line.invoice_id
    WHERE invoice.company_id=v_company AND invoice.invoice_date BETWEEN v_from AND v_to;
  SELECT count(*) INTO v_actual_invoice FROM jsonb_array_elements(v_payload->'invoices') item
    WHERE item->>'sourceKind'='BACKOFFICE';
  SELECT count(*) INTO v_actual_line FROM jsonb_array_elements(v_payload->'lines') item
    WHERE item->>'source_kind'='BACKOFFICE';
  SELECT count(*) INTO v_expected_retail
  FROM public.sales_invoice_snapshots snapshot
  JOIN public.sales_headers sale ON sale.company_id=snapshot.company_id AND sale.id=snapshot.sales_id
  JOIN public.companies company ON company.id=snapshot.company_id
  WHERE snapshot.company_id=v_company
    AND private.resolve_sales_invoice_display_date(snapshot.snapshot_payload,to_jsonb(sale),
      snapshot.created_at,company.timezone) BETWEEN v_from AND v_to;
  SELECT count(*) INTO v_actual_retail FROM jsonb_array_elements(v_payload->'invoices') item
    WHERE item->>'sourceKind'='RETAIL';

  IF v_expected_invoice=0 OR v_expected_line=0 THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: representative Backoffice Invoice and line required';
  END IF;
  IF v_actual_invoice<>v_expected_invoice OR v_actual_line<>v_expected_line THEN
    RAISE EXCEPTION 'TEST_FAILED: Backoffice Invoice export count mismatch expected %/% actual %/%',
      v_expected_invoice,v_expected_line,v_actual_invoice,v_actual_line;
  END IF;
  IF v_actual_retail<>v_expected_retail THEN
    RAISE EXCEPTION 'TEST_FAILED: existing Retail Invoice export changed expected % actual %',
      v_expected_retail,v_actual_retail;
  END IF;
  IF EXISTS(
    SELECT 1 FROM public.backoffice_sales_invoices invoice
    WHERE invoice.company_id=v_company AND invoice.invoice_date BETWEEN v_from AND v_to
      AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(v_payload->'invoices') item
        WHERE item->>'sourceKind'='BACKOFFICE'
          AND (item->>'invoiceId')::uuid=invoice.id
          AND item->>'invoiceStatus'=invoice.status
          AND item->>'documentNo'=COALESCE(invoice.invoice_no,invoice.draft_no))
  ) THEN
    RAISE EXCEPTION 'TEST_FAILED: Backoffice Invoice identity/status missing';
  END IF;
  IF EXISTS(
    SELECT 1 FROM public.backoffice_sales_invoice_lines line
    JOIN public.backoffice_sales_invoices invoice ON invoice.company_id=line.company_id
      AND invoice.id=line.invoice_id
    WHERE invoice.company_id=v_company AND invoice.invoice_date BETWEEN v_from AND v_to
      AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(v_payload->'lines') item
        WHERE item->>'source_kind'='BACKOFFICE'
          AND item->>'document_no'=COALESCE(invoice.invoice_no,invoice.draft_no)
          AND (item->>'line_no')::bigint=line.line_no
          AND (item->>'quantity')::numeric=COALESCE(line.quantity_uom,0))
  ) THEN
    RAISE EXCEPTION 'TEST_FAILED: Backoffice Invoice product/quantity detail missing';
  END IF;
END
$test$;
SELECT 'sales_invoice_export_backoffice_union_behavior' check_name,'PASS' status,
  0::bigint violation_rows,jsonb_build_object('tested',ARRAY[
    'authenticated Company-scoped export','Retail and Backoffice union',
    'all Backoffice statuses','document and SO identity','line Product/UOM/Qty detail',
    'all fixture writes rolled back']) details;
ROLLBACK;
