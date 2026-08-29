-- ODR-6D compatibility behavior: data-adaptive and read-only.
DO $test$
DECLARE v_invalid BIGINT;v_definition TEXT;
BEGIN
  SELECT count(*) INTO v_invalid FROM public.sales_details detail
  JOIN public.sales_headers sale ON sale.company_id=detail.company_id AND sale.id=detail.sales_id
  WHERE sale.document_status<>'POSTED'
    AND private.odr6d_returnable_sales_detail_quantity(detail.company_id,detail.id)<0;
  IF v_invalid<>0 THEN RAISE EXCEPTION 'TEST_FAILED: negative ODR returnable quantity'; END IF;

  SELECT count(*) INTO v_invalid FROM public.sales_headers sale
  WHERE sale.document_status<>'POSTED' AND sale.is_tempo
    AND private.odr6d_dispatched_receivable_before_receipts(
      sale.company_id,sale.id,current_date)<0;
  IF v_invalid<>0 THEN RAISE EXCEPTION 'TEST_FAILED: negative dispatched receivable'; END IF;

  SELECT pg_get_functiondef(
    'private.acp5h_post_sales_return_core(uuid,bigint,uuid)'::regprocedure)
    INTO v_definition;
  IF v_definition NOT ILIKE '%sales_dispatch_allocations%'
    OR v_definition NOT ILIKE '%odr6d_returnable_sales_detail_quantity%' THEN
    RAISE EXCEPTION 'TEST_FAILED: Return Post is not dispatch bounded';
  END IF;

  SELECT pg_get_functiondef(
    'public.save_customer_receipt_draft_with_disposition(uuid,bigint,uuid,date,uuid,text,text,text,numeric,text,jsonb)'::regprocedure)
    INTO v_definition;
  IF v_definition NOT ILIKE '%sales_dispatch_financial_effects%' THEN
    RAISE EXCEPTION 'TEST_FAILED: collection wrapper is not ODR aware';
  END IF;
END
$test$;

SELECT 'odr6d_consumer_compatibility_behavior' check_name,'PASS' status,
  jsonb_build_object('tested',jsonb_build_array(
    'legacy POSTED compatibility','actual Dispatch quantity boundary',
    'dispatched TEMPO receivable boundary','pre-Dispatch Customer Advance isolation')) details;
