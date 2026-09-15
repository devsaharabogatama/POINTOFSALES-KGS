-- Nonzero real-source read verification. Actor/context fixture always rolled back.
BEGIN;
CREATE TEMP TABLE history_read_evidence(check_name text,status text,details jsonb) ON COMMIT DROP;
DO $test$
DECLARE v_actor uuid;v_company uuid;v_rows jsonb;v_repeat jsonb;v_source record;
 v_count bigint;v_detail jsonb;v_before text;v_after text;v_denied boolean:=false;
BEGIN
 SELECT profile.id INTO STRICT v_actor FROM public.profiles profile
 WHERE profile.role::text='super_admin' ORDER BY profile.id LIMIT 1;
 SELECT company_id INTO STRICT v_company FROM public.sales_headers
 GROUP BY company_id ORDER BY count(*) DESC LIMIT 1;
 SELECT md5(string_agg(row_value,'|' ORDER BY row_value)) INTO v_before FROM (
 SELECT to_jsonb(sale)::text row_value FROM public.sales_headers sale
 UNION ALL SELECT to_jsonb(detail)::text FROM public.sales_details detail
 UNION ALL SELECT to_jsonb(stock)::text FROM public.product_stocks stock
 UNION ALL SELECT to_jsonb(movement)::text FROM public.stock_movements movement
 UNION ALL SELECT to_jsonb(event)::text FROM public.financial_events event
 UNION ALL SELECT to_jsonb(journal)::text FROM public.finance_journals journal) protected;
 PERFORM set_config('request.jwt.claim.sub',v_actor::text,true);
 PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',v_actor,'role','authenticated')::text,true);
 PERFORM public.set_active_company_context(v_company,'CUTOVER_TEST');
 INSERT INTO public.company_features(company_id,feature_code,is_enabled,config,updated_by)
 VALUES(v_company,'backoffice_delivered_qty_sales_enabled',true,'{}',v_actor)
 ON CONFLICT(company_id,feature_code) DO UPDATE SET is_enabled=true;
 v_rows:=public.get_office_retail_history();
 v_repeat:=public.get_office_retail_history();
 IF v_rows IS DISTINCT FROM v_repeat THEN RAISE EXCEPTION 'TEST_FAILED: unstable read retry'; END IF;
 SELECT count(*) INTO v_count FROM public.sales_headers WHERE company_id=v_company;
 IF v_count=0 THEN RAISE EXCEPTION 'TEST_FAILED: zero source rows'; END IF;
 FOR v_source IN SELECT id FROM public.sales_headers WHERE company_id=v_company LOOP
  v_detail:=public.get_office_retail_history(v_source.id);
  IF jsonb_array_length(v_detail->'data')<>1 OR v_detail->>'companyId'<>v_company::text
  OR v_detail->'data'->0->>'id'<>v_source.id::text THEN
   RAISE EXCEPTION 'TEST_FAILED: source detail coverage'; END IF;
  IF jsonb_array_length(v_detail->'data'->0->'lines')<>(SELECT count(*) FROM public.sales_details
   WHERE company_id=v_company AND sales_id=v_source.id) THEN RAISE EXCEPTION 'TEST_FAILED: detail line coverage'; END IF;
  IF v_detail->'data'->0->>'targetId' IS NULL AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(v_rows->'data') row
   WHERE row->>'id'=v_source.id::text) THEN RAISE EXCEPTION 'TEST_FAILED: unconverted source missing'; END IF;
  IF v_detail->'data'->0->>'targetId' IS NOT NULL AND EXISTS(SELECT 1 FROM jsonb_array_elements(v_rows->'data') row
   WHERE row->>'id'=v_source.id::text) THEN RAISE EXCEPTION 'TEST_FAILED: converted source duplicate'; END IF;
 END LOOP;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(v_rows->'data') row
 WHERE row->>'companyId'<>v_company::text) THEN RAISE EXCEPTION 'TEST_FAILED: tenant leak'; END IF;
 PERFORM set_config('request.jwt.claim.sub','',true);
 PERFORM set_config('request.jwt.claims','{}',true);
 BEGIN PERFORM public.get_office_retail_history(); EXCEPTION WHEN OTHERS THEN v_denied:=true; END;
 IF NOT v_denied THEN RAISE EXCEPTION 'TEST_FAILED: anonymous read accepted'; END IF;
 SELECT md5(string_agg(row_value,'|' ORDER BY row_value)) INTO v_after FROM (
 SELECT to_jsonb(sale)::text row_value FROM public.sales_headers sale
 UNION ALL SELECT to_jsonb(detail)::text FROM public.sales_details detail
 UNION ALL SELECT to_jsonb(stock)::text FROM public.product_stocks stock
 UNION ALL SELECT to_jsonb(movement)::text FROM public.stock_movements movement
 UNION ALL SELECT to_jsonb(event)::text FROM public.financial_events event
 UNION ALL SELECT to_jsonb(journal)::text FROM public.finance_journals journal) protected;
 IF v_before IS DISTINCT FROM v_after THEN RAISE EXCEPTION 'TEST_FAILED: read mutated transaction values'; END IF;
 INSERT INTO history_read_evidence VALUES('office_retail_history_behavior','PASS',
 jsonb_build_object('originalSources',v_count,'visibleSources',jsonb_array_length(v_rows->'data'),
 'allSourceDetailsAndLinesChecked',true,'retryStable',true,'anonymousDenied',true,
 'protectedTransactionValuesUnchanged',true,'fixtureRolledBack',true));
 RAISE NOTICE 'PASS: % original sources detail/line coverage, list dedupe, tenant scope, retry, anonymous denial, protected values unchanged',v_count;
END $test$;
SELECT * FROM history_read_evidence;
ROLLBACK;
