-- Cutover Step 4A/6: self-contained rollback-only POS behavior.
-- The test creates its own Auth actor, OPEN Session, canonical POS Draft and
-- deterministic shortage. It never depends on an operational Draft/Session.
BEGIN;

INSERT INTO auth.users(
  id,email,instance_id,raw_app_meta_data,raw_user_meta_data,
  is_super_admin,role,aud,email_confirmed_at
) VALUES(
  '00000000-0000-0000-0000-000000153091',
  'warehouse-negative-authority@example.invalid',
  '00000000-0000-0000-0000-000000000000',
  '{"provider":"email","providers":["email"]}'::jsonb,
  '{"name":"Warehouse Negative Authority Test"}'::jsonb,
  false,'authenticated','authenticated',clock_timestamp()
) ON CONFLICT(id) DO NOTHING;

INSERT INTO public.profiles(id,email,name,role)
VALUES(
  '00000000-0000-0000-0000-000000153091',
  'warehouse-negative-authority@example.invalid',
  'Warehouse Negative Authority Test','super_admin'::public.user_role
) ON CONFLICT(id) DO UPDATE SET
  email=excluded.email,name=excluded.name,role=excluded.role;

DO $test$
DECLARE
  v_actor uuid:='00000000-0000-0000-0000-000000153091';
  v_company uuid;v_store uuid;v_pos uuid;v_warehouse uuid;v_customer uuid;
  v_product uuid;v_product_uom uuid;v_payment_method uuid;
  v_session uuid:=gen_random_uuid();v_sale public.sales_headers%rowtype;
  v_sale_id uuid;v_payload jsonb;v_result jsonb;
  v_confirmation uuid:=gen_random_uuid();v_payment_key uuid:=gen_random_uuid();
  v_original_allow boolean;v_blocked boolean:=false;v_reservation uuid;
  v_shortage_rows bigint;v_shortages jsonb;v_direct_authorized boolean;
  v_grand_total numeric(24,4);
BEGIN
  -- Only active POS master configuration is reused. No operational Draft,
  -- Order, Reservation, or Cashier Session is borrowed by this fixture.
  SELECT company.id,store.id,terminal.id,warehouse.id,customer.id,
    product.id,product_uom.id,payment_method.id
  INTO v_company,v_store,v_pos,v_warehouse,v_customer,
    v_product,v_product_uom,v_payment_method
  FROM public.companies company
  JOIN LATERAL (
    SELECT candidate.* FROM public.stores candidate
    WHERE candidate.company_id=company.id AND candidate.status='ACTIVE'
    ORDER BY candidate.id LIMIT 1
  ) store ON true
  JOIN LATERAL (
    SELECT candidate.* FROM public.pos_terminals candidate
    WHERE candidate.company_id=company.id AND candidate.store_id=store.id
      AND candidate.status='ACTIVE'
    ORDER BY candidate.id LIMIT 1
  ) terminal ON true
  JOIN LATERAL (
    SELECT candidate.* FROM public.warehouses candidate
    WHERE candidate.company_id=company.id AND candidate.is_active
      AND candidate.is_sale_source
      AND (candidate.store_id=store.id OR candidate.store_id IS NULL)
    ORDER BY (candidate.store_id=store.id) DESC,candidate.id LIMIT 1
  ) warehouse ON true
  JOIN LATERAL (
    SELECT candidate.* FROM public.customers candidate
    WHERE candidate.company_id=company.id AND candidate.is_active
    ORDER BY candidate.is_system_customer DESC,candidate.id LIMIT 1
  ) customer ON true
  JOIN LATERAL (
    SELECT product_candidate.id,uom_candidate.id product_uom_id
    FROM public.products product_candidate
    JOIN public.product_uoms uom_candidate
      ON uom_candidate.company_id=product_candidate.company_id
     AND uom_candidate.product_id=product_candidate.id
    JOIN public.uoms unit ON unit.company_id=uom_candidate.company_id
      AND unit.id=uom_candidate.uom_id
    WHERE product_candidate.company_id=company.id
      AND product_candidate.is_active AND NOT product_candidate.is_bundle
      AND uom_candidate.is_active AND uom_candidate.sales_allowed
      AND uom_candidate.factor_to_base>0
      AND uom_candidate.sale_price IS NOT NULL AND uom_candidate.sale_price>0
      AND unit.is_active
      AND (private.resolve_pos_sale_price(company.id,store.id,customer.id,
        uom_candidate.id,1,clock_timestamp())->>'resolvedUnitPrice')::numeric>0
      AND COALESCE((SELECT stock.stock_qty FROM public.product_stocks stock
        WHERE stock.company_id=company.id AND stock.warehouse_id=warehouse.id
          AND stock.product_id=product_candidate.id),0)>=0
      AND NOT EXISTS(
        SELECT 1 FROM public.pos_offline_stock_allowances allowance
        WHERE allowance.company_id=company.id
          AND allowance.warehouse_id=warehouse.id
          AND allowance.product_id=product_candidate.id
          AND allowance.status='ACTIVE'
          AND allowance.allocated_base_qty>allowance.consumed_base_qty)
    ORDER BY product_candidate.id,uom_candidate.id LIMIT 1
  ) product ON true
  JOIN public.product_uoms product_uom
    ON product_uom.company_id=company.id AND product_uom.id=product.product_uom_id
  JOIN LATERAL (
    SELECT candidate.* FROM public.payment_methods candidate
    WHERE candidate.company_id=company.id AND candidate.is_active
      AND candidate.effective_from<=clock_timestamp()
      AND (candidate.effective_to IS NULL OR candidate.effective_to>=clock_timestamp())
      AND candidate.proof_mode<>'REQUIRED'
      AND candidate.settlement_route<>'INTERNAL_LIABILITY'
      AND candidate.method_type::text NOT IN('CUSTOMER_BALANCE','KETUL_OFFSET','TEMPO')
      AND private.odr5d_settlement_account_function(candidate) IS NOT NULL
      AND (candidate.available_all_stores OR EXISTS(
        SELECT 1 FROM public.payment_method_store_assignments assignment
        WHERE assignment.company_id=candidate.company_id
          AND assignment.payment_method_id=candidate.id
          AND assignment.store_id=store.id))
    ORDER BY (candidate.method_type::text='CASH') DESC,
      candidate.is_default DESC,candidate.id LIMIT 1
  ) payment_method ON true
  WHERE company.status='ACTIVE'
  ORDER BY company.id LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: active POS master tuple required (Company, Store, Terminal, sale-source Warehouse, Customer, positive-price non-bundle Product-UOM, eligible Payment Method)';
  END IF;

  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub',v_actor,'role','authenticated')::text,true);
  PERFORM public.set_active_company_context(v_company,'WAREHOUSE_AUTH_TEST');

  -- Direct fixture insert avoids consuming the non-transactional Session code
  -- sequence. Canonical save/confirm below still enforce this OPEN Session.
  INSERT INTO public.cashier_sessions(
    id,session_code,cashier_id,opening_balance,expected_cash,actual_cash,
    difference,status,company_id,store_id,pos_id,sales_warehouse_id,
    opening_cash_actual,master_version,updated_at)
  VALUES(v_session,'TST-NEG-'||substr(replace(v_session::text,'-',''),1,12),
    v_actor,0,0,0,0,'OPEN'::public.session_status,v_company,v_store,v_pos,
    v_warehouse,0,1,clock_timestamp());

  v_payload:=jsonb_build_object(
    'clientTransactionId',gen_random_uuid(),
    'cashierSessionId',v_session,
    'customerId',v_customer,
    'draftLabel','Rollback-only Warehouse authority test',
    'selectedPricelistId',NULL,
    'pricingSelectionSource','AUTO',
    'lines',jsonb_build_array(jsonb_build_object(
      'lineKey','WAREHOUSE-AUTH-L1','productUomId',v_product_uom,'quantity',1)),
    'globalDiscount',0,
    'roundingDirection','NONE',
    'roundingIncrement',100,
    'isTempo',false,
    'transactionDateIntent','PRESERVE',
    'dueDate',NULL,
    -- ODR confirmation creates a Delivery Document/SJ. Use the canonical
    -- DELIVERY shape so this focused authority test does not cross into the
    -- separately recorded legacy PICKUP/header-shape incompatibility.
    'fulfillmentMode','DELIVERY',
    'deliveryRecipientName','Warehouse Authority Test',
    'deliveryRecipientPhone',NULL,
    'deliveryAddress',NULL,
    'deliveryScheduledAt',NULL,
    'deliveryNotes',NULL,
    'deliveryFeeAmount',0,
    'deliveryFeeInvoiceDisplayMode','SHOW_SEPARATE',
    'payments','[]'::jsonb);

  -- First canonical save obtains the server-owned price/tax/rounding total.
  v_result:=public.save_pos_sale_draft_with_pricelist(v_payload);
  v_sale_id:=(v_result->>'salesId')::uuid;
  v_grand_total:=(v_result->>'grandTotalAfterRounding')::numeric;
  IF v_sale_id IS NULL OR v_grand_total IS NULL OR v_grand_total<=0 THEN
    RAISE EXCEPTION 'TEST_FAILED: canonical Draft creation response invalid: %',v_result;
  END IF;

  -- Second canonical save supplies a payment matching that server-owned total.
  v_payload:=v_payload||jsonb_build_object(
    'saleId',v_sale_id,
    'masterVersion',(v_result->>'masterVersion')::bigint,
    'payments',jsonb_build_array(jsonb_build_object(
      'clientPaymentKey',v_payment_key,
      'paymentMethodId',v_payment_method,
      'amount',v_grand_total,
      'tenderedAmount',v_grand_total)));
  v_result:=public.save_pos_sale_draft_with_pricelist(v_payload);
  SELECT sale.* INTO STRICT v_sale FROM public.sales_headers sale
  WHERE sale.company_id=v_company AND sale.id=v_sale_id;

  IF v_sale.master_version IS DISTINCT FROM (v_result->>'masterVersion')::bigint
    OR NOT EXISTS(SELECT 1 FROM public.sale_stock_requirements requirement
      WHERE requirement.company_id=v_company AND requirement.sales_id=v_sale_id
        AND requirement.stock_product_id=v_product
        AND requirement.quantity_base>0)
    OR EXISTS(SELECT 1 FROM public.sales_stock_reservations reservation
      WHERE reservation.company_id=v_company AND reservation.sales_id=v_sale_id) THEN
    RAISE EXCEPTION 'TEST_FAILED: canonical Draft/Stock Requirement fixture invalid';
  END IF;

  SELECT allow_negative_stock INTO STRICT v_original_allow
  FROM public.warehouses WHERE company_id=v_company AND id=v_warehouse;

  -- There is no active Offline allowance for this Product. Zero On Hand is a
  -- deterministic shortage and the outer rollback restores the original row.
  UPDATE public.product_stocks stock SET stock_qty=0,updated_at=clock_timestamp()
  WHERE stock.company_id=v_company AND stock.warehouse_id=v_warehouse
    AND stock.product_id=v_product;

  UPDATE public.warehouses SET allow_negative_stock=false
  WHERE company_id=v_company AND id=v_warehouse;
  BEGIN
    PERFORM public.confirm_pos_sales_order(
      v_sale.id,v_sale.master_version,v_confirmation,NULL);
  EXCEPTION WHEN OTHERS THEN
    v_blocked:=SQLERRM LIKE '%NEGATIVE_STOCK_REQUIRES_WAREHOUSE_OPT_IN%';
  END;
  IF NOT v_blocked OR EXISTS(SELECT 1 FROM public.sales_stock_reservations
      WHERE company_id=v_company AND sales_id=v_sale.id) THEN
    RAISE EXCEPTION 'TEST_FAILED: Warehouse OFF did not reject shortage atomically';
  END IF;

  UPDATE public.warehouses SET allow_negative_stock=true
  WHERE company_id=v_company AND id=v_warehouse;
  v_result:=public.confirm_pos_sales_order(
    v_sale.id,v_sale.master_version,v_confirmation,NULL);
  v_reservation:=(v_result->>'reservationId')::uuid;
  SELECT count(*) INTO v_shortage_rows
  FROM public.sales_stock_reservation_lines line
  WHERE line.company_id=v_company AND line.reservation_id=v_reservation
    AND line.shortage_base_qty>0 AND line.negative_authority_source='WAREHOUSE'
    AND line.negative_warehouse_version>0 AND line.negative_policy_version IS NULL
    AND line.negative_permission_version IS NULL;
  IF v_shortage_rows=0
    OR COALESCE((v_result->>'shortageLineCount')::bigint,0)<>v_shortage_rows THEN
    RAISE EXCEPTION 'TEST_FAILED: Warehouse ON reservation evidence invalid';
  END IF;

  SELECT jsonb_agg(jsonb_build_object('productId',line.stock_product_id))
  INTO v_shortages FROM (SELECT DISTINCT stock_product_id
    FROM public.sales_stock_reservation_lines
    WHERE company_id=v_company AND reservation_id=v_reservation
      AND shortage_base_qty>0) line;
  v_direct_authorized:=private.authorize_pos_negative_stock(
    v_company,v_sale.id,v_warehouse,v_actor,v_shortages,NULL);
  IF NOT v_direct_authorized OR NOT EXISTS(
    SELECT 1 FROM public.pos_negative_stock_authorizations authz
    WHERE authz.company_id=v_company AND authz.sales_id=v_sale.id
      AND authz.authority_source='WAREHOUSE' AND authz.warehouse_version>0
      AND authz.permission_id IS NULL AND authz.reason IS NULL
      AND authz.policy_version IS NULL AND authz.permission_version IS NULL) THEN
    RAISE EXCEPTION 'TEST_FAILED: direct POS Warehouse authorization invalid';
  END IF;

  IF NOT COALESCE((public.confirm_pos_sales_order(v_sale.id,v_sale.master_version,
      v_confirmation,'ignored by warehouse authority')->>'exactRetry')::boolean,false) THEN
    RAISE EXCEPTION 'TEST_FAILED: reason-independent exact retry failed';
  END IF;

  UPDATE public.warehouses SET allow_negative_stock=v_original_allow
  WHERE company_id=v_company AND id=v_warehouse;
END
$test$;

SELECT 'unified_warehouse_negative_stock_authority_behavior' check_name,
  'PASS' status,0::bigint violation_rows,
  jsonb_build_object('tested',jsonb_build_array(
    'self-created canonical POS Draft and Stock Requirement',
    'canonical DELIVERY confirmation document path',
    'Warehouse OFF rejects shortage atomically',
    'Warehouse ON allows shortage without user permission or reason',
    'new evidence uses Warehouse version',
    'direct POS authorization needs no user permission or reason',
    'exact retry ignores obsolete reason input'),
    'transactionEnd','ROLLBACK') details;
ROLLBACK;
