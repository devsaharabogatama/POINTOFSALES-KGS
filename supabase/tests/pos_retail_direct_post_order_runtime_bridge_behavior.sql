-- Rollback-only Production behavior for the exact failed KGS Pickup Draft.
-- Every Sale, Stock, FIFO, Payment, Finance and document effect is rolled back.
BEGIN;

DO $test$
DECLARE
  v_company uuid;
  v_actor uuid;
  v_sale public.sales_headers%rowtype;
  v_result jsonb;
  v_posting_key uuid := '2b734fc6-3886-44fd-90e6-1b3d1e270455';
  v_movement_rows integer;
  v_event_rows integer;
  v_payment_rows integer;
  v_invoice_rows integer;
  v_delivery_rows integer;
  v_fifo_rows integer;
  v_bridge_definition text;
BEGIN
  IF (SELECT count(*) FROM private.kgs_schema_migrations
      WHERE version='20261030120000')<>1
    OR to_regprocedure('private.trg_pos_retail_direct_post_order_runtime_bridge()') IS NULL
    OR NOT EXISTS(SELECT 1 FROM pg_trigger trigger_row
      WHERE trigger_row.tgrelid='public.sales_headers'::regclass
        AND trigger_row.tgname='pos_retail_direct_post_order_runtime_bridge'
        AND NOT trigger_row.tgisinternal) THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: bridge is not installed consistently';
  END IF;
  SELECT pg_get_functiondef(
    'private.trg_pos_retail_direct_post_order_runtime_bridge()'::regprocedure)
    INTO v_bridge_definition;
  IF v_bridge_definition NOT LIKE
      '%OLD.sales_origin NOT IN(''POS'',''BACKOFFICE_CUTOVER'')%'
    OR v_bridge_definition NOT LIKE '%RETURN NEW;%'
    OR v_bridge_definition NOT LIKE
      '%RETAIL_DIRECT_POST_CUTOVER_ADOPTION_REQUIRED%'
    OR v_bridge_definition NOT LIKE
      '%private.sales_process_retail_identity_is_valid(%' THEN
    RAISE EXCEPTION
      'TEST_PRECONDITION_FAILED: adopted cutover compatibility guard missing';
  END IF;

  SELECT company.id INTO STRICT v_company FROM public.companies company
  JOIN public.company_sales_process_settings setting ON setting.company_id=company.id
  WHERE company.company_code='KGS' AND company.status='ACTIVE'
    AND setting.active_mode='RETAIL_CONFIRM_INVOICE';

  SELECT sale.* INTO STRICT v_sale FROM public.sales_headers sale
  WHERE sale.company_id=v_company AND sale.draft_no='DRF-20261030-000455'
  FOR UPDATE;
  v_actor:=v_sale.created_by;

  IF v_sale.document_status<>'DRAFT'
    OR v_sale.order_runtime_status NOT IN('DRAFT_INPUT','SCHEDULED')
    OR v_sale.fulfillment_mode<>'PICKUP' OR v_sale.sj_required
    OR v_sale.sales_origin<>'POS'
    OR v_sale.sales_process_mode<>'RETAIL_CONFIRM_INVOICE'
    OR v_sale.confirmed_at IS NOT NULL OR v_sale.confirmed_by IS NOT NULL
    OR v_sale.confirmation_idempotency_key IS NOT NULL
    OR v_sale.reservation_version<>0
    OR NOT EXISTS(SELECT 1 FROM public.cashier_sessions session_row
      WHERE session_row.company_id=v_company AND session_row.id=v_sale.session_id
        AND session_row.status='OPEN')
    OR EXISTS(SELECT 1 FROM public.sales_stock_reservations reservation
      WHERE reservation.company_id=v_company AND reservation.sales_id=v_sale.id)
    OR EXISTS(SELECT 1 FROM public.sales_payments payment
      WHERE payment.company_id=v_company AND payment.sales_id=v_sale.id)
    OR EXISTS(SELECT 1 FROM public.stock_movements movement
      WHERE movement.company_id=v_company
        AND movement.reference_table='sales_headers' AND movement.reference_id=v_sale.id)
    OR EXISTS(SELECT 1 FROM public.financial_events event
      WHERE event.company_id=v_company
        AND event.source_table='sales_headers' AND event.source_id=v_sale.id)
    OR EXISTS(SELECT 1 FROM public.sales_invoice_snapshots invoice
      WHERE invoice.company_id=v_company AND invoice.sales_id=v_sale.id)
    OR EXISTS(SELECT 1 FROM public.sales_delivery_documents delivery
      WHERE delivery.company_id=v_company AND delivery.sales_id=v_sale.id) THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: exact failed Draft changed';
  END IF;

  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub',v_actor::text,'role','authenticated')::text,true);
  PERFORM public.set_active_company_context(v_company,'POS_RETAIL_TEST');

  v_result:=public.post_pos_sale_with_pricelist(
    v_sale.id,v_sale.master_version,v_posting_key);
  IF v_result->>'documentStatus'<>'POSTED'
    OR COALESCE((v_result->>'idempotentReplay')::boolean,false) THEN
    RAISE EXCEPTION 'TEST_FAILED: direct Retail post did not finalize: %',v_result;
  END IF;

  SET CONSTRAINTS sld_finalize_posted_sale IMMEDIATE;
  SET CONSTRAINTS sld_finalize_posted_sale DEFERRED;

  IF NOT EXISTS(SELECT 1 FROM public.sales_headers sale
      WHERE sale.company_id=v_company AND sale.id=v_sale.id
        AND sale.document_status='POSTED'
        AND sale.order_runtime_status='LEGACY_POSTED'
        AND sale.sales_origin='POS'
        AND sale.sales_process_mode='RETAIL_CONFIRM_INVOICE') THEN
    RAISE EXCEPTION 'TEST_FAILED: final Sale lifecycle shape invalid';
  END IF;

  SELECT count(*) INTO v_movement_rows FROM public.stock_movements movement
    WHERE movement.company_id=v_company
      AND movement.reference_table='sales_headers' AND movement.reference_id=v_sale.id;
  SELECT count(*) INTO v_event_rows FROM public.financial_events event
    WHERE event.company_id=v_company
      AND event.source_table='sales_headers' AND event.source_id=v_sale.id;
  SELECT count(*) INTO v_payment_rows FROM public.sales_payments payment
    WHERE payment.company_id=v_company AND payment.sales_id=v_sale.id;
  SELECT count(*) INTO v_invoice_rows FROM public.sales_invoice_snapshots invoice
    WHERE invoice.company_id=v_company AND invoice.sales_id=v_sale.id;
  SELECT count(*) INTO v_delivery_rows FROM public.sales_delivery_documents delivery
    WHERE delivery.company_id=v_company AND delivery.sales_id=v_sale.id;
  SELECT count(*) INTO v_fifo_rows FROM public.sale_fifo_allocations allocation
    WHERE allocation.company_id=v_company AND allocation.sales_id=v_sale.id;

  IF v_movement_rows<1 OR v_event_rows<1 OR v_payment_rows<1
    OR v_invoice_rows<>1 OR v_delivery_rows<>0 OR v_fifo_rows<1 THEN
    RAISE EXCEPTION
      'TEST_FAILED: downstream shape movement %, event %, payment %, invoice %, delivery %, fifo %',
      v_movement_rows,v_event_rows,v_payment_rows,v_invoice_rows,v_delivery_rows,v_fifo_rows;
  END IF;

  v_result:=public.post_pos_sale_with_pricelist(
    v_sale.id,v_sale.master_version,v_posting_key);
  SET CONSTRAINTS sld_finalize_posted_sale IMMEDIATE;
  SET CONSTRAINTS sld_finalize_posted_sale DEFERRED;
  IF NOT COALESCE((v_result->>'idempotentReplay')::boolean,false)
    OR (SELECT count(*) FROM public.stock_movements movement
      WHERE movement.company_id=v_company
        AND movement.reference_table='sales_headers' AND movement.reference_id=v_sale.id)<>v_movement_rows
    OR (SELECT count(*) FROM public.financial_events event
      WHERE event.company_id=v_company
        AND event.source_table='sales_headers' AND event.source_id=v_sale.id)<>v_event_rows
    OR (SELECT count(*) FROM public.sales_payments payment
      WHERE payment.company_id=v_company AND payment.sales_id=v_sale.id)<>v_payment_rows
    OR (SELECT count(*) FROM public.sales_invoice_snapshots invoice
      WHERE invoice.company_id=v_company AND invoice.sales_id=v_sale.id)<>v_invoice_rows
    OR (SELECT count(*) FROM public.sales_delivery_documents delivery
      WHERE delivery.company_id=v_company AND delivery.sales_id=v_sale.id)<>v_delivery_rows
    OR (SELECT count(*) FROM public.sale_fifo_allocations allocation
      WHERE allocation.company_id=v_company AND allocation.sales_id=v_sale.id)<>v_fifo_rows THEN
    RAISE EXCEPTION 'TEST_FAILED: exact retry duplicated a final effect';
  END IF;
END
$test$;

ROLLBACK;

SELECT 'pos_retail_direct_post_order_runtime_bridge_behavior' check_name,
  'PASS' status,0 violation_rows,
  jsonb_build_object('tested',jsonb_build_array(
    'installed exact bridge','same failed KGS Pickup Draft',
    'POS Retail Draft to Posted lifecycle','Stock and FIFO',
    'Payment and Finance event','Invoice without Surat Jalan',
    'idempotent retry','adopted BACKOFFICE_CUTOVER compatibility guard',
    'all test effects rolled back')) details;
