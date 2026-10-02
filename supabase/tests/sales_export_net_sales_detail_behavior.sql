-- Read-only production-data behavior proof plus authenticated wrapper smoke.
BEGIN;
DO $test$
DECLARE
  v_company record;v_rows jsonb;v_combined jsonb;v_actor uuid;v_tested integer:=0;
  v_stock_before bigint;v_stock_after bigint;v_event_before bigint;v_event_after bigint;
  v_journal_before bigint;v_journal_after bigint;
BEGIN
  SELECT count(*) INTO v_stock_before FROM public.stock_movements;
  SELECT count(*) INTO v_event_before FROM public.financial_events;
  SELECT count(*) INTO v_journal_before FROM public.finance_journals;

  FOR v_company IN SELECT company.id,company.company_name
    FROM public.companies company WHERE company.status='ACTIVE'
  LOOP
    v_rows:=private.get_sales_export_net_detail_core(
      v_company.id,date '2026-08-01',current_date);
    IF jsonb_typeof(v_rows)<>'array' THEN
      RAISE EXCEPTION 'TEST_FAILED: invalid net detail shape for %',v_company.company_name;
    END IF;
    IF EXISTS(SELECT 1 FROM jsonb_array_elements(v_rows) item
      WHERE (item->>'invoice_base_qty')::numeric<0
        OR (item->>'returned_base_qty')::numeric<0
        OR (item->>'net_sales_base_qty')::numeric<0
        OR (item->>'net_stock_out_base_qty')::numeric<0
        OR (item->>'net_sales_base_qty')::numeric<>
          greatest((item->>'invoice_base_qty')::numeric-
            (item->>'canceled_base_qty')::numeric-
            (item->>'returned_base_qty')::numeric,0)
        OR (item->>'net_stock_out_base_qty')::numeric<>
          greatest((item->>'outbound_base_qty')::numeric-
            (item->>'reversed_base_qty')::numeric-
            (item->>'restocked_base_qty')::numeric,0)) THEN
      RAISE EXCEPTION 'TEST_FAILED: net arithmetic mismatch for %',v_company.company_name;
    END IF;
    v_tested:=v_tested+1;
  END LOOP;
  IF v_tested=0 THEN RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: active Company required'; END IF;

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
    OR jsonb_typeof(v_combined->'reconciliation')<>'object'
    OR jsonb_typeof(v_combined->'netSalesLines')<>'array'
    OR jsonb_array_length(v_combined->'netSalesLines')=0 THEN
    RAISE EXCEPTION 'TEST_FAILED: authenticated workbook payload invalid';
  END IF;
  IF (SELECT count(*) FROM jsonb_array_elements(v_combined->'netSalesLines') item
    WHERE item->>'invoice_no'='INV-20260827-0000000072'
      AND item->>'sku' IN('T20B','T22B')
      AND (item->>'net_sales_base_qty')::numeric=0
      AND (item->>'net_stock_out_base_qty')::numeric=0)<>2 THEN
    RAISE EXCEPTION 'TEST_FAILED: corrected SMS duplicate Sale is not net zero';
  END IF;

  SELECT count(*) INTO v_stock_after FROM public.stock_movements;
  SELECT count(*) INTO v_event_after FROM public.financial_events;
  SELECT count(*) INTO v_journal_after FROM public.finance_journals;
  IF (v_stock_before,v_event_before,v_journal_before) IS DISTINCT FROM
     (v_stock_after,v_event_after,v_journal_after) THEN
    RAISE EXCEPTION 'TEST_FAILED: net export mutated Stock or Finance';
  END IF;
END
$test$;
SELECT 'sales_export_net_sales_detail_behavior' check_name,'PASS' status,
  0::bigint violation_rows,jsonb_build_object('tested',ARRAY[
    'all active Company payloads','net Sales arithmetic','net Stock arithmetic',
    'authenticated atomic workbook payload','nonzero runtime rows',
    'corrected SMS duplicate Sale nets to zero','no Stock Event or Journal mutation',
    'context write rolled back']) details;
ROLLBACK;
