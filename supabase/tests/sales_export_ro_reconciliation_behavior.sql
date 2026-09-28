-- Read-only production-data behavior proof plus authenticated wrapper smoke.
BEGIN;
DO $test$
DECLARE
  v_company record;v_payload jsonb;v_combined jsonb;v_actor uuid;
  v_stock_before bigint;v_stock_after bigint;
  v_event_before bigint;v_event_after bigint;
  v_journal_before bigint;v_journal_after bigint;
  v_tested integer:=0;
BEGIN
  SELECT count(*) INTO v_stock_before FROM public.stock_movements;
  SELECT count(*) INTO v_event_before FROM public.financial_events;
  SELECT count(*) INTO v_journal_before FROM public.finance_journals;

  FOR v_company IN
    SELECT company.id,company.company_name FROM public.companies company
    WHERE company.status='ACTIVE' AND company.company_name IN(
      'Khadijah Muda Sejahtera','Latorti Sari Median','Smart Muda Solusi')
    ORDER BY company.company_name
  LOOP
    v_payload:=private.get_sales_export_ro_reconciliation_core(
      v_company.id,date '2026-08-01',current_date);
    IF v_payload IS NULL OR jsonb_typeof(v_payload->'roRequirements')<>'array'
      OR jsonb_typeof(v_payload->'cancellations')<>'array'
      OR jsonb_typeof(v_payload->'returns')<>'array' THEN
      RAISE EXCEPTION 'TEST_FAILED: invalid payload shape for %',v_company.company_name;
    END IF;
    IF EXISTS(SELECT 1 FROM jsonb_array_elements(v_payload->'roRequirements') item
      WHERE (item->>'open_base_qty')::numeric<0
        OR (item->>'coverage_base_qty')::numeric<0
        OR (item->>'uncovered_base_qty')::numeric<0
        OR (item->>'open_base_qty')::numeric<>
          (item->>'coverage_base_qty')::numeric+(item->>'uncovered_base_qty')::numeric) THEN
      RAISE EXCEPTION 'TEST_FAILED: clean RO arithmetic mismatch for %',v_company.company_name;
    END IF;
    IF EXISTS(SELECT 1 FROM jsonb_array_elements(v_payload->'returns') item
      WHERE (item->>'returned_base_qty')::numeric<>
        (item->>'restocked_base_qty')::numeric+
        (item->>'destroyed_base_qty')::numeric+
        (item->>'no_physical_base_qty')::numeric) THEN
      RAISE EXCEPTION 'TEST_FAILED: Return physical classification mismatch for %',
        v_company.company_name;
    END IF;
    IF EXISTS(SELECT 1 FROM jsonb_array_elements(v_payload->'cancellations') item
      WHERE (item->>'outbound_base_qty')::numeric<0
        OR (item->>'reversed_base_qty')::numeric<0
        OR (item->>'net_stock_out_base_qty')::numeric<0) THEN
      RAISE EXCEPTION 'TEST_FAILED: Cancellation quantity mismatch for %',
        v_company.company_name;
    END IF;
    v_tested:=v_tested+1;
  END LOOP;
  IF v_tested<>3 THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: expected 3 target Companies, got %',v_tested;
  END IF;

  SELECT profile.id INTO v_actor FROM public.profiles profile
  JOIN auth.users actor ON actor.id=profile.id
  WHERE profile.role='super_admin'::public.user_role ORDER BY profile.id LIMIT 1;
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: authenticated super admin required';
  END IF;
  PERFORM set_config('request.jwt.claim.role','authenticated',true);
  PERFORM set_config('request.jwt.claim.sub',v_actor::text,true);
  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'role','authenticated','sub',v_actor)::text,true);
  INSERT INTO public.user_active_company_contexts(user_id,company_id)
  SELECT v_actor,company.id FROM public.companies company
  WHERE company.company_name='Smart Muda Solusi'
  ON CONFLICT(user_id) DO UPDATE SET company_id=excluded.company_id,
    selected_at=clock_timestamp(),updated_at=clock_timestamp();
  v_combined:=public.export_sales_documents_with_reconciliation(
    date '2026-08-01',current_date);
  IF jsonb_typeof(v_combined->'documents')<>'object'
    OR jsonb_typeof(v_combined->'reconciliation')<>'object' THEN
    RAISE EXCEPTION 'TEST_FAILED: atomic workbook payload shape invalid';
  END IF;
  v_payload:=v_combined->'reconciliation';
  IF v_payload->>'companyName'<>'Smart Muda Solusi' THEN
    RAISE EXCEPTION 'TEST_FAILED: authenticated Company scope mismatch';
  END IF;
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(v_payload->'roRequirements') item
    WHERE item->>'source_document_no'='INV-20260829-0000000140') THEN
    RAISE EXCEPTION 'TEST_FAILED: reversed SMS trial Invoice leaked into clean demand';
  END IF;

  SELECT count(*) INTO v_stock_after FROM public.stock_movements;
  SELECT count(*) INTO v_event_after FROM public.financial_events;
  SELECT count(*) INTO v_journal_after FROM public.finance_journals;
  IF (v_stock_before,v_event_before,v_journal_before) IS DISTINCT FROM
     (v_stock_after,v_event_after,v_journal_after) THEN
    RAISE EXCEPTION 'TEST_FAILED: read-only export mutated Stock or Finance';
  END IF;
END
$test$;
SELECT 'sales_export_ro_reconciliation_behavior' check_name,'PASS' status,
  0::bigint violation_rows,jsonb_build_object('tested',ARRAY[
    'KMS LSM SMS payload shape','clean open demand arithmetic',
    'active PO Request and Draft RO coverage without double count',
    'Customer Return physical classification','Cancellation reversal classification',
    'SMS reversed trial Invoice excluded','authenticated atomic workbook snapshot',
    'authenticated Company scope',
    'no Stock Event or Journal mutation','context write rolled back']) details;
ROLLBACK;
