BEGIN;

DO $test$
DECLARE
  v_actor uuid;
  v_invoice public.backoffice_sales_invoices%rowtype;
  v_other_company uuid;
  v_ui jsonb;
  v_payment jsonb;
  v_counts_before jsonb;
  v_counts_after jsonb;
  v_denied boolean:=false;
BEGIN
  IF NOT EXISTS(
    SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20261110120000'
  ) THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: exact forward migration required';
  END IF;

  SELECT invoice.* INTO v_invoice
  FROM public.backoffice_sales_invoices invoice
  JOIN public.company_sales_process_settings process
    ON process.company_id=invoice.company_id
   AND process.active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE'
  WHERE invoice.status='DRAFT'
  ORDER BY invoice.created_at DESC,invoice.id
  LIMIT 1;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: Backoffice Draft Invoice required';
  END IF;

  SELECT profile.id INTO v_actor
  FROM auth.users auth_user
  JOIN public.profiles profile ON profile.id=auth_user.id
  WHERE profile.role='super_admin'::public.user_role
  ORDER BY profile.id
  LIMIT 1;
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: linked Super Admin required';
  END IF;

  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub',v_actor,'role','authenticated')::text,true);
  PERFORM set_config('request.jwt.claim.sub',v_actor::text,true);
  PERFORM set_config('request.jwt.claim.role','authenticated',true);
  PERFORM public.set_active_company_context(
    v_invoice.company_id,'DRAFT_INVOICE_TEST');

  SELECT jsonb_build_object(
    'events',(SELECT count(*) FROM public.financial_events),
    'journals',(SELECT count(*) FROM public.finance_journals),
    'openItems',(SELECT count(*) FROM public.ar_open_item_registry),
    'invoiceVersion',(SELECT master_version
      FROM public.backoffice_sales_invoices WHERE id=v_invoice.id)
  ) INTO v_counts_before;

  v_ui:=public.get_backoffice_sales_invoice_ui(v_invoice.id);
  v_payment:=public.get_backoffice_sales_invoice_payment_context(v_invoice.id);

  IF v_ui->'data'->>'id'<>v_invoice.id::text
    OR v_ui->'data'->>'status'<>'DRAFT'
    OR (v_ui->'data'->>'grandTotal')::numeric<>v_invoice.grand_total
  THEN
    RAISE EXCEPTION 'TEST_FAILED: Draft Invoice UI base payload changed';
  END IF;
  IF v_payment->'summary'->>'status'<>'NOT_APPLICABLE'
    OR (v_payment->'summary'->>'originalAmount')::numeric<>v_invoice.grand_total
  THEN
    RAISE EXCEPTION 'TEST_FAILED: Draft payment context base payload changed';
  END IF;

  SELECT company.id INTO v_other_company
  FROM public.companies company
  WHERE company.id<>v_invoice.company_id AND company.status='ACTIVE'
  ORDER BY company.id LIMIT 1;
  IF v_other_company IS NOT NULL THEN
    PERFORM public.set_active_company_context(
      v_other_company,'DRAFT_INVOICE_CROSS_TEST');
    BEGIN
      PERFORM public.get_backoffice_sales_invoice_ui(v_invoice.id);
    EXCEPTION WHEN OTHERS THEN
      v_denied:=SQLERRM IN(
        'CUSTOM_PERMISSION_DENIED','BACKOFFICE_SALES_INVOICE_NOT_FOUND');
    END;
    IF NOT v_denied THEN
      RAISE EXCEPTION 'TEST_FAILED: cross-Company Draft read was not denied';
    END IF;
    PERFORM public.set_active_company_context(
      v_invoice.company_id,'DRAFT_INVOICE_RESTORE');
  END IF;

  SELECT jsonb_build_object(
    'events',(SELECT count(*) FROM public.financial_events),
    'journals',(SELECT count(*) FROM public.finance_journals),
    'openItems',(SELECT count(*) FROM public.ar_open_item_registry),
    'invoiceVersion',(SELECT master_version
      FROM public.backoffice_sales_invoices WHERE id=v_invoice.id)
  ) INTO v_counts_after;
  IF v_counts_after IS DISTINCT FROM v_counts_before THEN
    RAISE EXCEPTION 'TEST_FAILED: read path created business mutation: before %, after %',
      v_counts_before,v_counts_after;
  END IF;
END
$test$;

ROLLBACK;

SELECT
  'backoffice_draft_invoice_detail_partition_behavior' check_name,
  'PASS' status,
  0 violation_rows,
  jsonb_build_object('tested',jsonb_build_array(
    'installed exact forward migration',
    'authenticated Backoffice Draft Invoice UI read',
    'Draft payment context remains NOT_APPLICABLE',
    'cross-Company denial when fixture exists',
    'zero Finance Event/Journal/open-item/version mutation',
    'all context writes rolled back')) details;
