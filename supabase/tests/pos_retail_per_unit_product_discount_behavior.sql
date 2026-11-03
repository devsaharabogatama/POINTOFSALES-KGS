-- Authenticated rollback-only behavior for Retail POS Product discount basis.
-- Creates Drafts only; no Sale is posted and every effect is rolled back.
BEGIN;

DO $test$
DECLARE
  v_company UUID;
  v_actor UUID;
  v_session UUID;
  v_customer UUID;
  v_ordinary_uom UUID;
  v_lettuce_uom UUID;
  v_bombay_uom UUID;
  v_payload JSONB;
  v_saved JSONB;
  v_sale UUID;
  v_legacy_sale UUID;
  v_before_events BIGINT;
  v_before_movements BIGINT;
  v_before_journals BIGINT;
  v_rejected BOOLEAN;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations ledger
      WHERE ledger.version='20261102160000') THEN
    RAISE EXCEPTION
      'TEST_PRECONDITION_FAILED: per-unit Product discount migration missing';
  END IF;

  SELECT company.id INTO STRICT v_company
  FROM public.companies company
  JOIN public.company_sales_process_settings setting
    ON setting.company_id=company.id
   AND setting.active_mode='RETAIL_CONFIRM_INVOICE'
  WHERE company.company_code='KGS' AND company.status='ACTIVE';

  SELECT session.cashier_id,session.id
  INTO v_actor,v_session
  FROM public.cashier_sessions session
  JOIN auth.users auth_user ON auth_user.id=session.cashier_id
  WHERE session.company_id=v_company
    AND session.status='OPEN'::public.session_status
  ORDER BY public.private_is_super_admin(session.cashier_id) DESC,session.id
  LIMIT 1;
  IF v_session IS NULL THEN RAISE EXCEPTION
    'TEST_PRECONDITION_FAILED: authenticated OPEN KGS session required';
  END IF;

  SELECT customer.id INTO v_customer
  FROM public.customers customer
  WHERE customer.company_id=v_company AND customer.is_active
  ORDER BY customer.is_system_customer DESC,customer.id LIMIT 1;
  IF v_customer IS NULL THEN RAISE EXCEPTION
    'TEST_PRECONDITION_FAILED: active KGS Customer required'; END IF;

  SELECT product_uom.id INTO v_ordinary_uom
  FROM public.products product
  JOIN public.product_uoms product_uom
    ON product_uom.company_id=product.company_id
   AND product_uom.product_id=product.id
   AND product_uom.is_active AND product_uom.sales_allowed
  WHERE product.company_id=v_company AND product.is_active
    AND NOT product.is_bundle
    AND product.pos_line_discount_amount_basis='PER_UNIT'
    AND NOT ((product.sku='L' AND product.name='Lettuce')
      OR (product.sku='BB' AND product.name='Bawang Bombay'))
  ORDER BY CASE WHEN product.sku='DB' AND product.name='Daging Burger Sapi'
    THEN 0 ELSE 1 END,product.sku,product_uom.id LIMIT 1;
  SELECT product_uom.id INTO v_lettuce_uom
  FROM public.products product
  JOIN public.product_uoms product_uom
    ON product_uom.company_id=product.company_id
   AND product_uom.product_id=product.id
   AND product_uom.is_active AND product_uom.sales_allowed
  WHERE product.company_id=v_company AND product.is_active
    AND product.sku='L' AND product.name='Lettuce'
    AND product.pos_line_discount_amount_basis='LINE_TOTAL'
  ORDER BY product_uom.id LIMIT 1;
  SELECT product_uom.id INTO v_bombay_uom
  FROM public.products product
  JOIN public.product_uoms product_uom
    ON product_uom.company_id=product.company_id
   AND product_uom.product_id=product.id
   AND product_uom.is_active AND product_uom.sales_allowed
  WHERE product.company_id=v_company AND product.is_active
    AND product.sku='BB' AND product.name='Bawang Bombay'
    AND product.pos_line_discount_amount_basis='LINE_TOTAL'
  ORDER BY product_uom.id LIMIT 1;
  IF v_ordinary_uom IS NULL OR v_lettuce_uom IS NULL OR v_bombay_uom IS NULL THEN
    RAISE EXCEPTION
      'TEST_PRECONDITION_FAILED: ordinary/Lettuce/Bawang Bombay sales UOM tuple required';
  END IF;

  SELECT count(*) INTO v_before_events FROM public.financial_events;
  SELECT count(*) INTO v_before_movements FROM public.stock_movements;
  SELECT count(*) INTO v_before_journals FROM public.finance_journals;

  PERFORM set_config('request.jwt.claim.sub',v_actor::text,true);
  PERFORM set_config('request.jwt.claim.role','authenticated',true);
  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub',v_actor,'role','authenticated')::text,true);
  PERFORM public.set_active_company_context(v_company,'POS_DISCOUNT_TEST');

  v_payload:=jsonb_build_object(
    'clientTransactionId',gen_random_uuid(),'cashierSessionId',v_session,
    'customerId',v_customer,'draftLabel','Rollback per-unit discount behavior',
    'draftNotes',NULL,'selectedPricelistId',NULL,
    'pricingSelectionSource','AUTO','globalDiscount',0,
    'roundingDirection','NONE','roundingIncrement',100,'isTempo',false,
    'transactionDateIntent','PRESERVE','dueDate',NULL,
    'fulfillmentMode','PICKUP','deliveryFeeAmount',0,
    'deliveryFeeInvoiceDisplayMode','SHOW_SEPARATE','payments','[]'::jsonb,
    'ketulIntakeLines','[]'::jsonb,
    'lines',jsonb_build_array(
      jsonb_build_object('lineKey','DISCOUNT-ORDINARY','productUomId',v_ordinary_uom,
        'quantity',10,'lineDiscountType','AMOUNT','lineDiscountInput',100,
        'lineDiscountAmountBasis','PER_UNIT'),
      jsonb_build_object('lineKey','DISCOUNT-LETTUCE','productUomId',v_lettuce_uom,
        'quantity',10,'lineDiscountType','AMOUNT','lineDiscountInput',1,
        'lineDiscountAmountBasis','LINE_TOTAL'),
      jsonb_build_object('lineKey','DISCOUNT-BOMBAY','productUomId',v_bombay_uom,
        'quantity',10,'lineDiscountType','AMOUNT','lineDiscountInput',1,
        'lineDiscountAmountBasis','LINE_TOTAL')));
  v_saved:=public.save_pos_sale_draft_with_ketul(v_payload);
  v_sale:=(v_saved->>'salesId')::uuid;

  IF (SELECT count(*) FROM public.sales_details detail
      WHERE detail.company_id=v_company AND detail.sales_id=v_sale
        AND detail.client_line_key='DISCOUNT-ORDINARY'
        AND detail.qty=10 AND detail.line_discount_input=100
        AND detail.line_discount_amount=1000
        AND detail.line_discount_amount_basis='PER_UNIT'
        AND detail.line_total=round(detail.resolved_unit_price*10-1000,4))<>1
    OR (SELECT count(*) FROM public.sales_details detail
      WHERE detail.company_id=v_company AND detail.sales_id=v_sale
        AND detail.client_line_key IN('DISCOUNT-LETTUCE','DISCOUNT-BOMBAY')
        AND detail.qty=10 AND detail.line_discount_input=1
        AND detail.line_discount_amount=1
        AND detail.line_discount_amount_basis='LINE_TOTAL'
        AND detail.line_total=round(detail.resolved_unit_price*10-1,4))<>2 THEN
    RAISE EXCEPTION 'TEST_FAILED: Product discount basis calculation mismatch';
  END IF;

  -- A Draft basis is immutable even if a later payload tries to reinterpret it.
  v_rejected:=false;
  BEGIN
    PERFORM public.save_pos_sale_draft_with_ketul(
      v_payload||jsonb_build_object('saleId',v_sale,
        'masterVersion',(v_saved->>'masterVersion')::bigint,
        'lines',jsonb_build_array(jsonb_build_object(
          'lineKey','DISCOUNT-ORDINARY','productUomId',v_ordinary_uom,
          'quantity',10,'lineDiscountType','AMOUNT','lineDiscountInput',100,
          'lineDiscountAmountBasis','LINE_TOTAL'))));
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='LINE_DISCOUNT_AMOUNT_BASIS_IMMUTABLE' THEN v_rejected:=true;
    ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION
    'TEST_FAILED: persisted Draft discount basis was mutable'; END IF;

  -- Database-first compatibility: an old client omitting the new field gets
  -- the legacy whole-line meaning, which is immediately snapshotted.
  v_payload:=jsonb_set(v_payload,'{clientTransactionId}',to_jsonb(gen_random_uuid()));
  v_payload:=jsonb_set(v_payload,'{lines}',jsonb_build_array(jsonb_build_object(
    'lineKey','DISCOUNT-LEGACY','productUomId',v_ordinary_uom,'quantity',10,
    'lineDiscountType','AMOUNT','lineDiscountInput',100)));
  v_saved:=public.save_pos_sale_draft_with_ketul(v_payload);
  v_legacy_sale:=(v_saved->>'salesId')::uuid;
  IF (SELECT count(*) FROM public.sales_details detail
      WHERE detail.company_id=v_company AND detail.sales_id=v_legacy_sale
        AND detail.client_line_key='DISCOUNT-LEGACY'
        AND detail.line_discount_input=100 AND detail.line_discount_amount=100
        AND detail.line_discount_amount_basis='LINE_TOTAL')<>1
    OR NOT EXISTS(SELECT 1 FROM public.sales_headers sale
      CROSS JOIN LATERAL jsonb_array_elements(sale.payload_snapshot->'lines') line
      WHERE sale.company_id=v_company AND sale.id=v_legacy_sale
        AND line->>'lineKey'='DISCOUNT-LEGACY'
        AND line->>'lineDiscountAmountBasis'='LINE_TOTAL') THEN
    RAISE EXCEPTION 'TEST_FAILED: old-client Draft compatibility mismatch';
  END IF;

  -- A new client cannot forge whole-line semantics for a per-unit Product.
  v_rejected:=false;
  BEGIN
    PERFORM public.save_pos_sale_draft_with_ketul(
      jsonb_set(jsonb_set(v_payload,'{clientTransactionId}',to_jsonb(gen_random_uuid())),
        '{lines}',jsonb_build_array(jsonb_build_object(
          'lineKey','DISCOUNT-FORGED','productUomId',v_ordinary_uom,
          'quantity',10,'lineDiscountType','AMOUNT','lineDiscountInput',100,
          'lineDiscountAmountBasis','LINE_TOTAL'))));
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='LINE_DISCOUNT_AMOUNT_BASIS_MISMATCH' THEN v_rejected:=true;
    ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION
    'TEST_FAILED: forged Product discount basis was accepted'; END IF;

  -- Percentage behavior remains percent-of-gross and does not consume a basis.
  v_payload:=v_payload||jsonb_build_object('saleId',v_legacy_sale,
    'masterVersion',(v_saved->>'masterVersion')::bigint,
    'lines',jsonb_build_array(jsonb_build_object(
      'lineKey','DISCOUNT-PERCENT','productUomId',v_ordinary_uom,'quantity',10,
      'lineDiscountType','PERCENT','lineDiscountInput',10)));
  PERFORM public.save_pos_sale_draft_with_ketul(v_payload);
  IF (SELECT count(*) FROM public.sales_details detail
      WHERE detail.company_id=v_company AND detail.sales_id=v_legacy_sale
        AND detail.client_line_key='DISCOUNT-PERCENT'
        AND detail.line_discount_amount=round(
          detail.resolved_unit_price*detail.qty*0.10,4))<>1 THEN
    RAISE EXCEPTION 'TEST_FAILED: percentage discount behavior changed';
  END IF;

  IF (SELECT count(*) FROM public.financial_events)<>v_before_events
    OR (SELECT count(*) FROM public.stock_movements)<>v_before_movements
    OR (SELECT count(*) FROM public.finance_journals)<>v_before_journals THEN
    RAISE EXCEPTION 'TEST_FAILED: Draft discount changed Stock/Finance effects';
  END IF;

  RAISE NOTICE 'pos_retail_per_unit_product_discount_behavior PASS: %',
    jsonb_build_object('tested',jsonb_build_array(
      'installed exact forward migration','authenticated OPEN Retail POS Session',
      'ordinary Product qty 10 x nominal 100 equals discount 1000',
      'Lettuce whole-line nominal remains unmultiplied',
      'Bawang Bombay whole-line nominal remains unmultiplied',
      'live canonical line total','Draft basis immutability',
      'old-client omitted-basis compatibility','forged basis denial',
      'percentage discount unchanged','zero Stock/Finance/Journal effect',
      'all test effects rolled back'));
END
$test$;

ROLLBACK;
