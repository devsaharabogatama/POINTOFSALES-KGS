-- Step 4D/6 authenticated rollback-only behavior.
BEGIN;
DO $test$
DECLARE v_actor uuid:=gen_random_uuid();v_company uuid;v_store uuid;v_terminal uuid;v_warehouse uuid;
  v_customer uuid;v_product_uom uuid;v_payment_method uuid;v_timezone text;
  v_session uuid:=gen_random_uuid();
  v_source uuid;v_target uuid;v_operation uuid:=gen_random_uuid();
  v_adopt_operation uuid:=gen_random_uuid();v_save_operation uuid:=gen_random_uuid();
  v_created jsonb;v_converted jsonb;v_result jsonb;v_retry jsonb;v_payload jsonb;
  v_price_result jsonb;
  v_before jsonb;v_after jsonb;v_master bigint;v_total numeric;v_stale boolean:=false;
BEGIN
  IF (SELECT count(*) FROM private.kgs_schema_migrations
    WHERE version IN('20260911110000','20260911111000','20260911120000'))<>3 THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: Step 4C base/fix and Step 4D required';
  END IF;
  -- A fresh actor isolates the OPEN-session fixture from operational cashiers.
  -- Auth, Profile, Session and all resulting documents roll back together.
  INSERT INTO auth.users(id,email,instance_id,raw_app_meta_data,raw_user_meta_data,
    is_super_admin,role,aud,email_confirmed_at)
  VALUES(v_actor,'cutover-session-'||v_actor::text||'@example.invalid',
    '00000000-0000-0000-0000-000000000000',
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{"name":"Cutover Session Adoption Test"}'::jsonb,
    false,'authenticated','authenticated',clock_timestamp());
  INSERT INTO public.profiles(id,email,name,role)
  VALUES(v_actor,'cutover-session-'||v_actor::text||'@example.invalid',
    'Cutover Session Adoption Test','super_admin'::public.user_role)
  ON CONFLICT(id) DO UPDATE SET role=excluded.role;
  SELECT company.id,store.id,terminal.id,warehouse.id,customer.id,product_uom.id,
    payment_method.id,company.timezone
  INTO v_company,v_store,v_terminal,v_warehouse,v_customer,v_product_uom,
    v_payment_method,v_timezone
  FROM public.companies company
  JOIN LATERAL(SELECT candidate.id FROM public.stores candidate
    WHERE candidate.company_id=company.id AND candidate.status='ACTIVE'
    ORDER BY candidate.id LIMIT 1) store ON true
  JOIN LATERAL(SELECT candidate.id FROM public.pos_terminals candidate
    WHERE candidate.company_id=company.id AND candidate.store_id=store.id
      AND candidate.status='ACTIVE' ORDER BY candidate.id LIMIT 1) terminal ON true
  JOIN LATERAL(SELECT candidate.id FROM public.warehouses candidate
    WHERE candidate.company_id=company.id AND candidate.is_active
      AND candidate.is_sale_source
      AND (candidate.store_id=store.id OR candidate.store_id IS NULL)
    ORDER BY (candidate.store_id=store.id) DESC,candidate.id LIMIT 1) warehouse ON true
  JOIN LATERAL(SELECT candidate.id FROM public.customers candidate
    WHERE candidate.company_id=company.id AND candidate.is_active
    ORDER BY candidate.is_system_customer DESC,candidate.id LIMIT 1) customer ON true
  JOIN LATERAL(SELECT candidate.id FROM public.product_uoms candidate
    JOIN public.products product ON product.company_id=candidate.company_id
      AND product.id=candidate.product_id AND product.is_active AND NOT product.is_bundle
    JOIN public.uoms uom ON uom.company_id=candidate.company_id
      AND uom.id=candidate.uom_id AND uom.is_active
    WHERE candidate.company_id=company.id AND candidate.is_active
      AND candidate.sales_allowed AND candidate.factor_to_base>0
      AND candidate.sale_price>0
    ORDER BY candidate.id LIMIT 1) product_uom ON true
  JOIN LATERAL(SELECT candidate.id FROM public.payment_methods candidate
    WHERE candidate.company_id=company.id AND candidate.is_active
      AND candidate.effective_from<=clock_timestamp()
      AND (candidate.effective_to IS NULL OR candidate.effective_to>=clock_timestamp())
      AND candidate.proof_mode<>'REQUIRED'
      AND candidate.settlement_route<>'INTERNAL_LIABILITY'
      AND candidate.method_type::text NOT IN('CUSTOMER_BALANCE','KETUL_OFFSET','TEMPO')
      AND (candidate.available_all_stores OR EXISTS(SELECT 1
        FROM public.payment_method_store_assignments assignment
        WHERE assignment.company_id=candidate.company_id
          AND assignment.payment_method_id=candidate.id
          AND assignment.store_id=store.id))
    ORDER BY candidate.is_default DESC,candidate.id LIMIT 1) payment_method ON true
  WHERE company.status='ACTIVE' ORDER BY company.id LIMIT 1;
  IF v_actor IS NULL OR v_company IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: canonical Super Admin/POS master tuple required';
  END IF;
  v_price_result:=private.resolve_pos_sale_price(v_company,v_store,v_customer,
    v_product_uom,1,clock_timestamp());
  IF (v_price_result->>'resolvedUnitPrice')::numeric<=0 THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: selected Product-UOM price must be positive';
  END IF;
  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub',v_actor,'role','authenticated')::text,true);
  INSERT INTO public.user_active_company_contexts(user_id,company_id)
  VALUES(v_actor,v_company) ON CONFLICT(user_id) DO UPDATE
    SET company_id=excluded.company_id,selected_at=clock_timestamp(),updated_at=clock_timestamp();
  INSERT INTO public.company_features(company_id,feature_code,is_enabled,config,updated_by)
  VALUES(v_company,'backoffice_delivered_qty_sales_enabled',true,'{}',v_actor)
  ON CONFLICT(company_id,feature_code) DO UPDATE SET is_enabled=true,updated_by=excluded.updated_by;

  v_payload:=jsonb_build_object('storeId',v_store,'warehouseId',v_warehouse,
    'customerId',v_customer,'selectedPricelistId',NULL,
    'orderDate',(clock_timestamp() AT TIME ZONE v_timezone)::date,
    'plannedDeliveryDate',(clock_timestamp() AT TIME ZONE v_timezone)::date,
    'isTempo',false,'currencyCode','IDR','globalDiscount',0,
    'roundingDirection','NONE','roundingIncrement',100,'deliveryFeeAmount',0,
    'deliveryFeeInvoiceDisplayMode','SHOW_SEPARATE',
    'lines',jsonb_build_array(jsonb_build_object('productUomId',v_product_uom,
      'quantity',2,'lineDiscountType','PERCENT','lineDiscountInput',5)),
    'notes','Step 4D rollback fixture');
  v_created:=public.save_backoffice_sales_order_draft(NULL,NULL,gen_random_uuid(),v_payload);
  v_source:=(v_created->'data'->>'id')::uuid;
  PERFORM set_config('kgs.sales_process_cutover_mutation','1',true);
  v_converted:=private.convert_backoffice_order_to_retail_sale(
    v_company,v_source,v_actor,v_operation);
  v_target:=(v_converted->>'targetDocumentId')::uuid;

  INSERT INTO public.cashier_sessions(id,session_code,cashier_id,opening_balance,
    expected_cash,actual_cash,difference,status,company_id,store_id,pos_id,
    sales_warehouse_id,opening_cash_actual,master_version,updated_at)
  VALUES(v_session,'TST-4D-'||substr(replace(v_session::text,'-',''),1,12),v_actor,
    0,0,0,0,'OPEN'::public.session_status,v_company,v_store,v_terminal,v_warehouse,
    0,1,clock_timestamp());
  SELECT master_version,grand_total_after_rounding,
    jsonb_build_object('subtotal',subtotal,'itemDiscount',item_discount,
      'globalDiscount',global_discount,'grandTotal',grand_total,
      'beforeRounding',grand_total_before_rounding,'rounding',rounding_adjustment,
      'deliveryFee',delivery_fee_amount,'transactionDate',transaction_date,
      'dueDate',due_date,'lineState',(SELECT jsonb_agg(to_jsonb(detail) ORDER BY detail.id)
        FROM public.sales_details detail WHERE detail.company_id=sale.company_id
          AND detail.sales_id=sale.id),'payload',payload_snapshot)
  INTO v_master,v_total,v_before FROM public.sales_headers sale
  WHERE sale.company_id=v_company AND sale.id=v_target;

  v_result:=public.adopt_backoffice_cutover_sale_draft(v_target,v_master,
    v_session,v_adopt_operation,false);
  v_retry:=public.adopt_backoffice_cutover_sale_draft(v_target,v_master,
    v_session,v_adopt_operation,false);
  IF NOT COALESCE((v_retry->>'exactRetry')::boolean,false)
    OR v_retry->>'salesId'<>v_target::text THEN
    RAISE EXCEPTION 'TEST_FAILED: adoption exact retry invalid: %',v_retry;
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.sales_headers sale
    WHERE sale.company_id=v_company AND sale.id=v_target
      AND sale.session_id=v_session AND sale.pos_id=v_terminal
      AND sale.created_session_id=v_session AND sale.sales_warehouse_id=v_warehouse
      AND sale.master_version=v_master+1
      AND sale.edit_lock_owner_id=v_actor AND sale.edit_lock_session_id=v_session)
    OR COALESCE((v_result->>'commercialSnapshotPreserved')::boolean,false) IS NOT TRUE THEN
    RAISE EXCEPTION 'TEST_FAILED: matching real-session adoption invalid: %',v_result;
  END IF;

  v_result:=public.save_backoffice_cutover_sale_draft_preserved(v_target,v_master+1,
    v_session,v_save_operation,jsonb_build_array(jsonb_build_object(
      'clientPaymentKey',gen_random_uuid(),'paymentMethodId',v_payment_method,
      'amount',v_total,'tenderedAmount',v_total)));
  v_retry:=public.save_backoffice_cutover_sale_draft_preserved(v_target,v_master+1,
    v_session,v_save_operation,
    (SELECT payload_snapshot->'payments' FROM public.sales_headers
      WHERE company_id=v_company AND id=v_target));
  IF NOT COALESCE((v_retry->>'exactRetry')::boolean,false)
    OR (v_result->>'masterVersion')::bigint<>v_master+2 THEN
    RAISE EXCEPTION 'TEST_FAILED: preserved save exact retry/version invalid';
  END IF;
  SELECT jsonb_build_object('subtotal',subtotal,'itemDiscount',item_discount,
      'globalDiscount',global_discount,'grandTotal',grand_total,
      'beforeRounding',grand_total_before_rounding,'rounding',rounding_adjustment,
      'deliveryFee',delivery_fee_amount,'transactionDate',transaction_date,
      'dueDate',due_date,'lineState',(SELECT jsonb_agg(to_jsonb(detail) ORDER BY detail.id)
        FROM public.sales_details detail WHERE detail.company_id=sale.company_id
          AND detail.sales_id=sale.id),'payload',payload_snapshot-'payments')
  INTO v_after FROM public.sales_headers sale
  WHERE sale.company_id=v_company AND sale.id=v_target;
  v_before:=jsonb_set(v_before,'{payload}',(v_before->'payload')-'payments');
  IF v_after IS DISTINCT FROM v_before
    OR (SELECT grand_total_after_rounding FROM public.sales_headers
      WHERE company_id=v_company AND id=v_target) IS DISTINCT FROM v_total THEN
    RAISE EXCEPTION 'TEST_FAILED: adoption/preserved save changed commercial snapshot';
  END IF;
  IF (SELECT jsonb_array_length(payload_snapshot->'payments')
    FROM public.sales_headers WHERE company_id=v_company AND id=v_target)<>1 THEN
    RAISE EXCEPTION 'TEST_FAILED: preserved payment intent was not stored';
  END IF;
  BEGIN
    PERFORM public.save_backoffice_cutover_sale_draft_preserved(v_target,v_master+1,
      v_session,gen_random_uuid(),'[]'::jsonb);
  EXCEPTION WHEN OTHERS THEN v_stale:=SQLERRM LIKE '%MASTER_VERSION_CONFLICT%'; END;
  IF NOT v_stale THEN RAISE EXCEPTION 'TEST_FAILED: stale version was not rejected'; END IF;
  IF (SELECT count(*) FROM public.sales_cutover_retail_adoption_operations
    WHERE company_id=v_company AND sales_id=v_target)<>2 THEN
    RAISE EXCEPTION 'TEST_FAILED: adoption operation history invalid';
  END IF;
END
$test$;
ROLLBACK;

SELECT 'sales_process_cutover_retail_session_adoption_behavior' check_name,
  'PASS' status,0 violation_rows,
  jsonb_build_object('tested',jsonb_build_array('matching OPEN session adoption',
    'Company/Store/Warehouse identity retained','commercial snapshot unchanged',
    'payment-only preserved save','exact retry','stale version rejection',
    'all fixture writes rolled back')) details;
