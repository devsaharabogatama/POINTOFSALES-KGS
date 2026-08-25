-- Rollback-safe behavior for POS live Pricelist preview.
BEGIN;

DO $fixture$
DECLARE v_actor UUID;v_company UUID;v_session UUID;v_customer UUID;
  v_product_uom UUID;v_cross_customer UUID;
BEGIN
  SELECT session.cashier_id,session.company_id,session.id
    INTO v_actor,v_company,v_session
  FROM public.cashier_sessions session
  JOIN public.companies company ON company.id=session.company_id
  WHERE session.status='OPEN'::public.session_status
    AND company.status='ACTIVE'
  ORDER BY session.opened_at DESC,session.id LIMIT 1;
  SELECT customer.id INTO v_customer FROM public.customers customer
  WHERE customer.company_id=v_company AND customer.is_active
  ORDER BY customer.is_system_customer DESC,customer.id LIMIT 1;
  SELECT product_uom.id INTO v_product_uom
  FROM public.product_uoms product_uom
  JOIN public.products product ON product.company_id=product_uom.company_id
    AND product.id=product_uom.product_id
  JOIN public.uoms uom ON uom.company_id=product_uom.company_id
    AND uom.id=product_uom.uom_id
  WHERE product_uom.company_id=v_company AND product_uom.is_active
    AND product_uom.sales_allowed AND product_uom.sale_price IS NOT NULL
    AND product.is_active AND uom.is_active
  ORDER BY product_uom.id LIMIT 1;
  IF v_actor IS NULL OR v_customer IS NULL OR v_product_uom IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: open Cashier session, active Customer and sales Product-UOM required';
  END IF;
  SELECT customer.id INTO v_cross_customer
  FROM public.customers customer
  WHERE customer.company_id<>v_company AND customer.is_active
  ORDER BY customer.id LIMIT 1;
  INSERT INTO public.user_active_company_contexts(user_id,company_id,selection_source)
  VALUES(v_actor,v_company,'POS') ON CONFLICT(user_id) DO UPDATE SET
    company_id=EXCLUDED.company_id,selection_source=EXCLUDED.selection_source;
  PERFORM set_config('pos_preview_test.actor',v_actor::TEXT,TRUE);
  PERFORM set_config('pos_preview_test.company',v_company::TEXT,TRUE);
  PERFORM set_config('pos_preview_test.session',v_session::TEXT,TRUE);
  PERFORM set_config('pos_preview_test.customer',v_customer::TEXT,TRUE);
  PERFORM set_config('pos_preview_test.product_uom',v_product_uom::TEXT,TRUE);
  PERFORM set_config(
    'pos_preview_test.cross_customer',COALESCE(v_cross_customer::TEXT,''),TRUE
  );
END
$fixture$;

SELECT set_config('request.jwt.claims',jsonb_build_object(
  'sub',current_setting('pos_preview_test.actor'),'role','authenticated'
)::TEXT,TRUE);
SET LOCAL ROLE authenticated;

DO $behavior$
DECLARE v_result JSONB;v_line JSONB;v_cross_customer UUID;
  v_cross_tenant_rejected BOOLEAN:=FALSE;
BEGIN
  v_cross_customer:=NULLIF(
    current_setting('pos_preview_test.cross_customer',TRUE),''
  )::UUID;
  v_result:=public.preview_pos_sale_prices(
    current_setting('pos_preview_test.session')::UUID,
    current_setting('pos_preview_test.customer')::UUID,
    NULL,
    jsonb_build_array(jsonb_build_object(
      'lineKey',current_setting('pos_preview_test.product_uom'),
      'productUomId',current_setting('pos_preview_test.product_uom'),
      'quantity',1
    ))
  );
  v_line:=v_result->'lines'->0;
  IF jsonb_array_length(v_result->'lines')<>1
     OR v_line->>'lineKey'<>current_setting('pos_preview_test.product_uom')
     OR (v_line->>'unitPrice')::NUMERIC<0
     OR v_line->>'pricingSelectionSource'<>'AUTO' THEN
    RAISE EXCEPTION 'TEST_FAILED: canonical price preview response invalid';
  END IF;

  IF v_cross_customer IS NOT NULL THEN
    BEGIN
      PERFORM public.preview_pos_sale_prices(
        current_setting('pos_preview_test.session')::UUID,v_cross_customer,NULL,
        jsonb_build_array(jsonb_build_object(
          'lineKey',current_setting('pos_preview_test.product_uom'),
          'productUomId',current_setting('pos_preview_test.product_uom'),
          'quantity',1
        ))
      );
    EXCEPTION WHEN OTHERS THEN
      v_cross_tenant_rejected:=SQLERRM LIKE '%ACTIVE_CUSTOMER_NOT_FOUND%';
    END;
    IF NOT v_cross_tenant_rejected THEN
      RAISE EXCEPTION 'TEST_FAILED: cross-Company Customer was not rejected';
    END IF;
  END IF;
END
$behavior$;

RESET ROLE;
ROLLBACK;

SELECT 'pos_live_pricelist_preview_behavior' AS check_name,'PASS' AS status,
  jsonb_build_object('rolledBack',TRUE) AS details;
