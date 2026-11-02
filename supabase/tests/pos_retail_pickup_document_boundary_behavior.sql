-- Rollback-only Production behavior for the exact KGS POS Retail Pickup Draft.
-- Proves Invoice-without-Delivery and reconciles positive FIFO plus authorized
-- negative-stock allocation without persisting any business effect.
BEGIN;

DO $test$
DECLARE
  v_company uuid;v_actor uuid;v_sale public.sales_headers%rowtype;v_result jsonb;
  v_posting_key uuid:='d12d306a-091f-48f8-8740-8a4bcf300455';
  v_movement_rows integer;v_event_rows integer;v_payment_rows integer;
  v_invoice_rows integer;v_delivery_rows integer;v_fifo_rows integer;
  v_negative_auth_rows integer;v_negative_allocation_rows integer;
  v_definition text;
BEGIN
  IF (SELECT count(*) FROM private.kgs_schema_migrations
      WHERE version IN('20261030120000','20261030130000'))<>2 THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: exact forward chain missing';
  END IF;
  SELECT pg_get_functiondef(
    'private.ensure_sales_documents(uuid,uuid,text)'::regprocedure)
    INTO v_definition;
  IF v_definition NOT LIKE '%POS_RETAIL_PICKUP_DOCUMENT_BOUNDARY%'
    OR v_definition !~ 'v_sale[.]sales_origin[[:space:]]*=[[:space:]]*''POS'''
    OR v_definition !~ 'v_sale[.]sales_process_mode[[:space:]]*=[[:space:]]*''RETAIL_CONFIRM_INVOICE'''
    OR v_definition NOT LIKE '%NOT v_pos_retail_pickup%' THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: Pickup document boundary missing';
  END IF;

  SELECT company.id INTO STRICT v_company FROM public.companies company
  JOIN public.company_sales_process_settings setting
    ON setting.company_id=company.id
  WHERE company.company_code='KGS' AND company.status='ACTIVE'
    AND setting.active_mode='RETAIL_CONFIRM_INVOICE';
  SELECT sale.* INTO STRICT v_sale FROM public.sales_headers sale
  WHERE sale.company_id=v_company AND sale.draft_no='DRF-20261030-000455'
  FOR UPDATE;
  v_actor:=v_sale.created_by;
  IF v_sale.document_status<>'DRAFT'
    OR v_sale.order_runtime_status NOT IN('DRAFT_INPUT','SCHEDULED')
    OR v_sale.sales_origin<>'POS'
    OR v_sale.sales_process_mode<>'RETAIL_CONFIRM_INVOICE'
    OR v_sale.fulfillment_mode<>'PICKUP' OR v_sale.sj_required
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
      WHERE delivery.company_id=v_company AND delivery.sales_id=v_sale.id)
    OR EXISTS(SELECT 1 FROM public.sale_fifo_allocations allocation
      WHERE allocation.company_id=v_company AND allocation.sales_id=v_sale.id)
    OR EXISTS(SELECT 1 FROM public.negative_stock_sale_allocations allocation
      WHERE allocation.company_id=v_company AND allocation.sales_id=v_sale.id) THEN
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

  IF NOT EXISTS(SELECT 1 FROM public.sales_headers posted
      WHERE posted.company_id=v_company AND posted.id=v_sale.id
        AND posted.document_status='POSTED'
        AND posted.order_runtime_status='LEGACY_POSTED'
        AND posted.sales_origin='POS'
        AND posted.sales_process_mode='RETAIL_CONFIRM_INVOICE'
        AND posted.fulfillment_mode='PICKUP'
        AND NOT posted.sj_required AND posted.sj_no IS NULL) THEN
    RAISE EXCEPTION 'TEST_FAILED: final POS Retail Pickup lifecycle invalid';
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
  SELECT count(*) INTO v_negative_auth_rows
    FROM public.pos_negative_stock_authorizations authz
    WHERE authz.company_id=v_company AND authz.sales_id=v_sale.id;
  SELECT count(*) INTO v_negative_allocation_rows
    FROM public.negative_stock_sale_allocations allocation
    WHERE allocation.company_id=v_company AND allocation.sales_id=v_sale.id;

  IF v_movement_rows<1 OR v_event_rows<1 OR v_payment_rows<1
    OR v_invoice_rows<>1 OR v_delivery_rows<>0
    OR v_negative_auth_rows<1 OR v_negative_allocation_rows<1 THEN
    RAISE EXCEPTION
      'TEST_FAILED: downstream shape movement %, event %, payment %, invoice %, delivery %, fifo %, negative auth %, negative allocation %',
      v_movement_rows,v_event_rows,v_payment_rows,v_invoice_rows,v_delivery_rows,
      v_fifo_rows,v_negative_auth_rows,v_negative_allocation_rows;
  END IF;

  IF EXISTS(
    SELECT 1 FROM public.sale_stock_requirements requirement
    WHERE requirement.company_id=v_company AND requirement.sales_id=v_sale.id
      AND requirement.quantity_base IS DISTINCT FROM
        COALESCE((SELECT sum(fifo.quantity_base)
          FROM public.sale_fifo_allocations fifo
          WHERE fifo.company_id=requirement.company_id
            AND fifo.stock_requirement_id=requirement.id),0)
        +COALESCE((SELECT sum(neg_alloc.shortage_base_qty)
          FROM public.negative_stock_sale_allocations neg_alloc
          WHERE neg_alloc.company_id=requirement.company_id
            AND neg_alloc.stock_requirement_id=requirement.id),0)
  ) THEN
    RAISE EXCEPTION 'TEST_FAILED: FIFO plus negative allocation does not cover stock requirement';
  END IF;

  v_result:=public.post_pos_sale_with_pricelist(
    v_sale.id,v_sale.master_version,v_posting_key);
  SET CONSTRAINTS sld_finalize_posted_sale IMMEDIATE;
  SET CONSTRAINTS sld_finalize_posted_sale DEFERRED;
  IF NOT COALESCE((v_result->>'idempotentReplay')::boolean,false)
    OR (SELECT count(*) FROM public.stock_movements movement
      WHERE movement.company_id=v_company
        AND movement.reference_table='sales_headers'
        AND movement.reference_id=v_sale.id)<>v_movement_rows
    OR (SELECT count(*) FROM public.financial_events event
      WHERE event.company_id=v_company AND event.source_table='sales_headers'
        AND event.source_id=v_sale.id)<>v_event_rows
    OR (SELECT count(*) FROM public.sales_payments payment
      WHERE payment.company_id=v_company AND payment.sales_id=v_sale.id)<>v_payment_rows
    OR (SELECT count(*) FROM public.sales_invoice_snapshots invoice
      WHERE invoice.company_id=v_company AND invoice.sales_id=v_sale.id)<>v_invoice_rows
    OR (SELECT count(*) FROM public.sales_delivery_documents delivery
      WHERE delivery.company_id=v_company AND delivery.sales_id=v_sale.id)<>v_delivery_rows
    OR (SELECT count(*) FROM public.sale_fifo_allocations fifo
      WHERE fifo.company_id=v_company AND fifo.sales_id=v_sale.id)<>v_fifo_rows
    OR (SELECT count(*) FROM public.pos_negative_stock_authorizations authz
      WHERE authz.company_id=v_company AND authz.sales_id=v_sale.id)<>v_negative_auth_rows
    OR (SELECT count(*) FROM public.negative_stock_sale_allocations neg_alloc
      WHERE neg_alloc.company_id=v_company
        AND neg_alloc.sales_id=v_sale.id)<>v_negative_allocation_rows THEN
    RAISE EXCEPTION 'TEST_FAILED: exact retry duplicated a final effect';
  END IF;
END
$test$;

ROLLBACK;

SELECT 'pos_retail_pickup_document_boundary_behavior' check_name,
  'PASS' status,0 violation_rows,
  jsonb_build_object('tested',jsonb_build_array(
    'installed exact forward chain','same failed KGS POS Retail Pickup Draft',
    'Posted plus LEGACY_POSTED lifecycle','Invoice without Delivery Document',
    'Payment, Movement and Finance event','Warehouse negative-stock authority',
    'FIFO plus negative allocation requirement coverage','idempotent retry',
    'all test effects rolled back')) details;
