-- Authorized negative Sale -> idempotent submitted Stock Request on Session close.
-- SAFETY: every fixture and final effect is rolled back.

BEGIN;

-- Use a rollback-only Auth identity so an operational user's already-open
-- Cashier Session can never collide with this isolated fixture.
INSERT INTO auth.users(
  id,email,instance_id,raw_app_meta_data,raw_user_meta_data,
  is_super_admin,role,aud,email_confirmed_at
) VALUES(
  '00000000-0000-0000-0000-000000138091',
  'negative-session-request@example.invalid',
  '00000000-0000-0000-0000-000000000000',
  '{"provider":"email","providers":["email"]}'::JSONB,
  '{"name":"Negative Session Request Test"}'::JSONB,
  FALSE,'authenticated','authenticated',clock_timestamp()
) ON CONFLICT(id) DO NOTHING;

INSERT INTO public.profiles(id,email,name,role)
VALUES(
  '00000000-0000-0000-0000-000000138091',
  'negative-session-request@example.invalid',
  'Negative Session Request Test','super_admin'::public.user_role
) ON CONFLICT(id) DO UPDATE SET
  email=EXCLUDED.email,name=EXCLUDED.name,role=EXCLUDED.role;

DO $test$
DECLARE
  v_actor UUID:='00000000-0000-0000-0000-000000138091';
  v_company UUID:='00000000-0000-0000-0000-000000138001';
  v_store UUID:='00000000-0000-0000-0000-000000138011';
  v_terminal UUID:='00000000-0000-0000-0000-000000138021';
  v_warehouse UUID:='00000000-0000-0000-0000-000000138031';
  v_category UUID:='00000000-0000-0000-0000-000000138041';
  v_uom UUID:='00000000-0000-0000-0000-000000138051';
  v_product UUID:='00000000-0000-0000-0000-000000138061';
  v_product_uom UUID:='00000000-0000-0000-0000-000000138071';
  v_session UUID;v_customer UUID;v_cash UUID;v_sale UUID;v_request UUID;
  v_result JSONB;v_payload JSONB;v_count BIGINT;v_value NUMERIC;
  v_session_version BIGINT;
BEGIN
  INSERT INTO public.companies(id,company_code,company_name,company_slug,status)
  VALUES(v_company,'G138','G138 Negative Session Request',
    'g138-negative-session-request','ACTIVE');
  INSERT INTO public.stores(id,company_id,store_code,store_name,status)
  VALUES(v_store,v_company,'G138S','G138 Store','ACTIVE');
  INSERT INTO public.pos_terminals(id,company_id,store_id,pos_code,pos_name,status)
  VALUES(v_terminal,v_company,v_store,'G138P','G138 POS','ACTIVE');
  INSERT INTO public.warehouses(id,company_id,code,name,warehouse_type,store_id,
    is_sale_source,is_purchase_destination,is_active)
  VALUES(v_warehouse,v_company,'G138W','G138 Warehouse','STORE',v_store,
    TRUE,TRUE,TRUE);
  INSERT INTO public.product_categories(
    id,company_id,category_code,category_name)
  VALUES(v_category,v_company,'G138CAT','G138 Product');
  INSERT INTO public.uoms(
    id,company_id,code,name,uom_type,allow_decimal,decimal_precision)
  VALUES(v_uom,v_company,'G138PCS','Piece','UNIT',FALSE,0);
  INSERT INTO public.products(id,company_id,sku,name,category,category_id,
    price,cogs,uom,uom_id,weight_reference_uom_id,weight_per_uom_kg,
    is_active,is_bundle)
  VALUES(v_product,v_company,'G138-PROD','G138 Product','G138 Product',v_category,
    100,50,'G138PCS',v_uom,v_uom,1,TRUE,FALSE);
  INSERT INTO public.product_uoms(id,company_id,product_id,uom_id,
    factor_to_base,purchase_allowed,sales_allowed,purchase_price,sale_price,
    is_active)
  VALUES(v_product_uom,v_company,v_product,v_uom,1,TRUE,TRUE,50,100,TRUE);
  INSERT INTO public.product_stocks(company_id,product_id,warehouse_id,stock_qty)
  VALUES(v_company,v_product,v_warehouse,1);
  INSERT INTO public.product_batches(id,product_id,warehouse_id,qty_purchased,
    qty_remaining,cogs_unit,company_id)
  VALUES('00000000-0000-0000-0000-000000138072',v_product,v_warehouse,
    1,1,50,v_company);
  INSERT INTO public.stock_movements(product_id,warehouse_id,qty_change,
    movement_type,reference_table,reference_id,company_id,base_uom_id,
    base_uom_name_snapshot,balance_after_base_qty,actor_id,posted_at,
    movement_status,source_line_id,notes)
  VALUES(v_product,v_warehouse,1,'PURCHASE'::public.stock_movement_type,
    'NEGATIVE_SESSION_REQUEST_TEST',
    '00000000-0000-0000-0000-000000138073',v_company,v_uom,'Piece',1,
    v_actor,clock_timestamp(),'POSTED',
    '00000000-0000-0000-0000-000000138074','Rollback fixture');

  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub',v_actor,'role','authenticated')::TEXT,TRUE);
  PERFORM public.set_active_company_context(v_company,'G4_PHASE60_TEST');
  PERFORM public.set_company_feature(
    v_company,'pos_negative_stock_enabled',TRUE,'{}');
  PERFORM public.save_pos_negative_stock_policy(1,TRUE,TRUE,10);
  PERFORM public.set_warehouse_negative_stock_opt_in(v_warehouse,TRUE);
  PERFORM public.save_pos_negative_stock_permission(
    NULL,NULL,v_warehouse,v_actor,10,clock_timestamp()+interval '1 day',
    'Rollback permission',TRUE);
  SELECT id INTO v_customer FROM public.customers
  WHERE company_id=v_company AND is_system_customer ORDER BY id LIMIT 1;
  SELECT id INTO v_cash FROM public.payment_methods
  WHERE company_id=v_company AND method_type='CASH' AND is_active
  ORDER BY is_default DESC,id LIMIT 1;
  IF v_customer IS NULL OR v_cash IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: provisioned POS master missing';
  END IF;

  v_result:=public.open_cashier_session(v_terminal,v_warehouse,0);
  v_session:=(v_result->>'cashierSessionId')::UUID;
  v_session_version:=(v_result->>'masterVersion')::BIGINT;
  v_result:=public.get_pos_negative_stock_readiness();
  IF NOT (v_result->>'enabled')::BOOLEAN OR
     v_result->>'blockerCode' IS NOT NULL THEN
    RAISE EXCEPTION 'TEST_FAILED: readiness invalid: %',v_result;
  END IF;

  v_payload:=jsonb_build_object(
    'clientTransactionId','00000000-0000-0000-0000-000000138101',
    'cashierSessionId',v_session,'customerId',v_customer,
    'negativeStockReason','Automatic replenishment request test',
    'roundingDirection','NONE','lines',jsonb_build_array(jsonb_build_object(
      'lineKey','G138-L1','productUomId',v_product_uom,'quantity',3)),
    'payments',jsonb_build_array(jsonb_build_object(
      'clientPaymentKey','00000000-0000-0000-0000-000000138111',
      'paymentMethodId',v_cash,'amount',300,'tenderedAmount',300)));
  v_result:=public.save_pos_sale_draft(v_payload);
  v_sale:=(v_result->>'salesId')::UUID;
  v_result:=public.post_pos_sale(v_sale,
    (v_result->>'masterVersion')::BIGINT,
    '00000000-0000-0000-0000-000000138121');
  IF v_result->>'documentStatus'<>'POSTED' THEN
    RAISE EXCEPTION 'TEST_FAILED: negative Sale not posted: %',v_result;
  END IF;

  v_result:=public.close_cashier_session(v_session,v_session_version,300);
  IF NOT (v_result->>'stockRequestCreated')::BOOLEAN
     OR v_result->>'stockRequestStatus'<>'SUBMITTED'
     OR (v_result->>'stockRequestLineCount')::INTEGER<>1
     OR (v_result->>'stockRequestTotalBaseQty')::NUMERIC<>2 THEN
    RAISE EXCEPTION 'TEST_FAILED: close request response invalid: %',v_result;
  END IF;
  v_request:=(v_result->>'stockRequestId')::UUID;
  SELECT count(*) INTO v_count FROM public.stock_request_documents document
  JOIN public.stock_request_lines line
    ON line.company_id=document.company_id AND line.document_id=document.id
  JOIN public.stock_request_negative_allocations lineage
    ON lineage.company_id=line.company_id AND lineage.stock_request_line_id=line.id
  WHERE document.company_id=v_company AND document.id=v_request
    AND document.request_source='NEGATIVE_STOCK_SESSION_CLOSE'
    AND document.requesting_session_id=v_session
    AND document.status='SUBMITTED' AND document.line_count=1
    AND document.requested_total_base_qty=2
    AND line.product_id=v_product AND line.requested_uom_id=v_uom
    AND line.requested_base_qty=2 AND lineage.requested_base_qty=2;
  IF v_count<>1 THEN
    RAISE EXCEPTION 'TEST_FAILED: automatic request lineage invalid';
  END IF;
  SELECT stock_qty_base INTO v_value
  FROM public.cashier_session_stock_snapshots snapshot
  WHERE snapshot.company_id=v_company AND snapshot.cashier_session_id=v_session
    AND snapshot.snapshot_stage='CLOSING' AND snapshot.product_id=v_product;
  IF v_value<>-2 THEN
    RAISE EXCEPTION 'TEST_FAILED: negative closing snapshot %, expected -2',v_value;
  END IF;

  v_result:=public.close_cashier_session(v_session,v_session_version,300);
  IF (v_result->>'stockRequestCreated')::BOOLEAN
     OR (v_result->>'stockRequestId')::UUID<>v_request THEN
    RAISE EXCEPTION 'TEST_FAILED: close retry not idempotent: %',v_result;
  END IF;
  SELECT count(*) INTO v_count FROM public.stock_request_documents document
  WHERE document.company_id=v_company
    AND document.requesting_session_id=v_session
    AND document.request_source='NEGATIVE_STOCK_SESSION_CLOSE';
  IF v_count<>1 THEN
    RAISE EXCEPTION 'TEST_FAILED: duplicate automatic request';
  END IF;

  -- A later Session may open while the warehouse is still negative, but it
  -- must not inherit or duplicate the prior Session's request.
  v_result:=public.open_cashier_session(v_terminal,v_warehouse,0);
  v_session:=(v_result->>'cashierSessionId')::UUID;
  v_session_version:=(v_result->>'masterVersion')::BIGINT;
  v_result:=public.close_cashier_session(v_session,v_session_version,0);
  IF v_result->>'stockRequestId' IS NOT NULL
     OR (v_result->>'stockRequestLineCount')::INTEGER<>0 THEN
    RAISE EXCEPTION 'TEST_FAILED: later Session inherited old shortage: %',
      v_result;
  END IF;
  SELECT count(*) INTO v_count FROM public.stock_request_documents document
  WHERE document.company_id=v_company
    AND document.request_source='NEGATIVE_STOCK_SESSION_CLOSE';
  IF v_count<>1 THEN
    RAISE EXCEPTION 'TEST_FAILED: cross-Session request duplicated';
  END IF;

  RAISE NOTICE 'TEST PASSED: authorized negative Sale posts, close captures negative snapshot, and creates exactly one submitted Session request with exact shortage lineage.';
END
$test$;
ROLLBACK;
