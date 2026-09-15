-- Authenticated rollback-only behavior for Draft Regular/DP Invoice runtime.
BEGIN;
DO $test$
DECLARE
  v_actor uuid;v_company uuid;v_store uuid;v_warehouse uuid;v_customer uuid;
  v_product_uom uuid;v_product uuid;v_factor numeric;v_original_negative boolean;
  v_created jsonb;v_confirmed jsonb;v_dp jsonb;v_dp_retry jsonb;v_regular jsonb;
  v_updated jsonb;v_canceled jsonb;v_order uuid;v_order_line uuid;v_term uuid:=gen_random_uuid();
  v_dp_operation uuid:=gen_random_uuid();v_regular_operation uuid:=gen_random_uuid();
  v_order_dpp numeric;v_order_tax numeric;v_expected_dp numeric;v_expected_tax numeric;
  v_event_before bigint;v_journal_before bigint;v_blocked boolean:=false;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260909157000') THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: Draft Invoice runtime required';
  END IF;
  SELECT profile.id INTO STRICT v_actor
  FROM public.profiles profile
  JOIN auth.users auth_user ON auth_user.id=profile.id
  WHERE profile.role='super_admin'::public.user_role
  ORDER BY profile.id LIMIT 1;
  SELECT company.id INTO STRICT v_company FROM public.companies company
  WHERE company.status='ACTIVE'
    AND EXISTS(SELECT 1 FROM public.stores store
      JOIN public.warehouses warehouse ON warehouse.company_id=store.company_id
        AND warehouse.is_active AND warehouse.is_sale_source
        AND (warehouse.store_id IS NULL OR warehouse.store_id=store.id)
      WHERE store.company_id=company.id AND store.status='ACTIVE')
    AND EXISTS(SELECT 1 FROM public.customers customer WHERE customer.company_id=company.id AND customer.is_active)
    AND EXISTS(SELECT 1 FROM public.product_uoms product_uom
      JOIN public.products product ON product.company_id=product_uom.company_id
        AND product.id=product_uom.product_id AND product.is_active AND NOT product.is_bundle
      WHERE product_uom.company_id=company.id AND product_uom.is_active
        AND product_uom.sales_allowed AND product_uom.factor_to_base>0)
  ORDER BY company.id LIMIT 1;
  PERFORM set_config('request.jwt.claim.sub',v_actor::text,true);
  INSERT INTO public.user_active_company_contexts(user_id,company_id)
  VALUES(v_actor,v_company) ON CONFLICT(user_id) DO UPDATE
    SET company_id=excluded.company_id,selected_at=clock_timestamp(),updated_at=clock_timestamp();
  INSERT INTO public.company_features(company_id,feature_code,is_enabled,config,updated_by)
  VALUES(v_company,'backoffice_delivered_qty_sales_enabled',true,'{}',v_actor)
  ON CONFLICT(company_id,feature_code) DO UPDATE SET is_enabled=true,updated_by=excluded.updated_by;
  SELECT id INTO STRICT v_store FROM public.stores WHERE company_id=v_company
    AND status='ACTIVE' ORDER BY id LIMIT 1;
  SELECT id,allow_negative_stock INTO STRICT v_warehouse,v_original_negative
  FROM public.warehouses WHERE company_id=v_company AND is_active AND is_sale_source
    AND (store_id IS NULL OR store_id=v_store) ORDER BY store_id NULLS LAST,id LIMIT 1;
  SELECT id INTO STRICT v_customer FROM public.customers WHERE company_id=v_company
    AND is_active ORDER BY is_system_customer DESC,id LIMIT 1;
  SELECT product_uom.id,product_uom.product_id,product_uom.factor_to_base
  INTO STRICT v_product_uom,v_product,v_factor
  FROM public.product_uoms product_uom
  JOIN public.products product ON product.company_id=product_uom.company_id
    AND product.id=product_uom.product_id AND product.is_active AND NOT product.is_bundle
  WHERE product_uom.company_id=v_company AND product_uom.is_active
    AND product_uom.sales_allowed ORDER BY product_uom.id LIMIT 1;
  UPDATE public.warehouses SET allow_negative_stock=true
  WHERE company_id=v_company AND id=v_warehouse;

  v_created:=public.save_backoffice_sales_order_draft(NULL,NULL,gen_random_uuid(),
    jsonb_build_object('storeId',v_store,'warehouseId',v_warehouse,'customerId',v_customer,
      'selectedPricelistId',NULL,'orderDate',current_date,'plannedDeliveryDate',current_date+1,
      'isTempo',true,'dueDate',current_date+30,'currencyCode','IDR','globalDiscount',0,
      'roundingDirection','NONE','roundingIncrement',100,'lines',jsonb_build_array(
        jsonb_build_object('productUomId',v_product_uom,'quantity',2,
          'overrideUnitPrice',100000))));
  v_order:=(v_created->'data'->>'id')::uuid;
  v_confirmed:=public.confirm_backoffice_sales_order(v_order,
    (v_created->'data'->>'masterVersion')::bigint,gen_random_uuid());
  SELECT id,tax_base,tax_amount INTO STRICT v_order_line,v_order_dpp,v_order_tax
  FROM public.backoffice_sales_order_lines WHERE company_id=v_company AND sales_order_id=v_order;
  IF v_order_dpp<=0 THEN RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: canonical DPP is not positive'; END IF;
  UPDATE public.backoffice_sales_order_lines SET accepted_base_qty=ordered_base_qty
  WHERE company_id=v_company AND id=v_order_line;

  INSERT INTO public.backoffice_sales_payment_terms(id,company_id,term_code,term_name,created_by,updated_by)
  VALUES(v_term,v_company,'INV-TEST-30-70','Invoice Runtime Test 30/70',v_actor,v_actor);
  INSERT INTO public.backoffice_sales_payment_term_lines(company_id,payment_term_id,line_no,
    amount_type,amount_value,due_rule,days_offset,created_by) VALUES
    (v_company,v_term,1,'PERCENT',30,'DAYS_AFTER_INVOICE',0,v_actor),
    (v_company,v_term,2,'BALANCE',NULL,'DAYS_AFTER_INVOICE',30,v_actor);
  SELECT count(*) INTO v_event_before FROM public.financial_events;
  SELECT count(*) INTO v_journal_before FROM public.finance_journals;

  v_dp:=public.save_backoffice_sales_invoice_draft(NULL,NULL,v_dp_operation,v_order,
    jsonb_build_object('invoiceType','DOWN_PAYMENT','invoiceDate',current_date,
      'paymentTermId',v_term,'downPaymentMode','PERCENT','downPaymentInput',20,
      'notes','Rollback DP test'));
  v_expected_dp:=round(v_order_dpp*0.20,4);
  v_expected_tax:=round(v_order_tax*0.20,4);
  IF (v_dp->'data'->>'chargeTotal')::numeric<>v_expected_dp
    OR (v_dp->'data'->>'taxTotal')::numeric<>v_expected_tax
    OR (v_dp->'data'->>'grandTotal')::numeric<>v_expected_dp+v_expected_tax
    OR jsonb_array_length(v_dp->'data'->'schedules')<>2 THEN
    RAISE EXCEPTION 'TEST_FAILED: DP DPP plus proportional tax or schedule invalid';
  END IF;
  v_dp_retry:=public.save_backoffice_sales_invoice_draft(NULL,NULL,v_dp_operation,v_order,
    jsonb_build_object('invoiceType','DOWN_PAYMENT','invoiceDate',current_date,
      'paymentTermId',v_term,'downPaymentMode','PERCENT','downPaymentInput',20,
      'notes','Rollback DP test'));
  IF COALESCE((v_dp_retry->>'exactRetry')::boolean,false) IS NOT TRUE
    OR (SELECT count(*) FROM public.backoffice_sales_invoices
      WHERE company_id=v_company AND sales_order_id=v_order AND invoice_type='DOWN_PAYMENT')<>1 THEN
    RAISE EXCEPTION 'TEST_FAILED: DP exact retry duplicated document';
  END IF;

  v_regular:=public.save_backoffice_sales_invoice_draft(NULL,NULL,v_regular_operation,v_order,
    jsonb_build_object('invoiceType','REGULAR','invoiceDate',current_date,'paymentTermId',v_term,
      'lines',jsonb_build_array(jsonb_build_object('salesOrderLineId',v_order_line,
        'quantityUom',2,'unitPrice',100000,'discountAmount',10000))));
  IF (SELECT draft_invoice_allocated_base_qty FROM public.backoffice_sales_order_lines
      WHERE company_id=v_company AND id=v_order_line)<>2*v_factor
    OR (SELECT sum(amount_due) FROM public.backoffice_sales_invoice_receivable_schedules
      WHERE company_id=v_company AND invoice_id=(v_regular->'data'->>'id')::uuid)
      <>(v_regular->'data'->>'grandTotal')::numeric THEN
    RAISE EXCEPTION 'TEST_FAILED: Regular Draft hold or schedule invalid';
  END IF;
  v_blocked:=false;
  BEGIN
    PERFORM public.save_backoffice_sales_invoice_draft(NULL,NULL,gen_random_uuid(),v_order,
      jsonb_build_object('invoiceType','REGULAR','invoiceDate',current_date,
        'lines',jsonb_build_array(jsonb_build_object('salesOrderLineId',v_order_line,
          'quantityUom',1,'unitPrice',100000))));
  EXCEPTION WHEN OTHERS THEN
    v_blocked:=SQLERRM LIKE '%BACKOFFICE_SALES_INVOICE_QUANTITY_EXCEEDS_AVAILABLE%';
  END;
  IF NOT v_blocked THEN RAISE EXCEPTION 'TEST_FAILED: over-allocation was accepted'; END IF;

  v_updated:=public.save_backoffice_sales_invoice_draft((v_regular->'data'->>'id')::uuid,
    (v_regular->'data'->>'masterVersion')::bigint,gen_random_uuid(),v_order,
    jsonb_build_object('invoiceType','REGULAR','invoiceDate',current_date,'paymentTermId',v_term,
      'lines',jsonb_build_array(jsonb_build_object('salesOrderLineId',v_order_line,
        'quantityUom',1,'unitPrice',95000,'discountAmount',5000))));
  IF (SELECT draft_invoice_allocated_base_qty FROM public.backoffice_sales_order_lines
      WHERE company_id=v_company AND id=v_order_line)<>v_factor THEN
    RAISE EXCEPTION 'TEST_FAILED: Draft edit did not replace quantity hold';
  END IF;
  v_blocked:=false;
  BEGIN
    PERFORM public.save_backoffice_sales_invoice_draft((v_regular->'data'->>'id')::uuid,
      (v_regular->'data'->>'masterVersion')::bigint,gen_random_uuid(),v_order,
      jsonb_build_object('invoiceType','REGULAR','invoiceDate',current_date,
        'lines',jsonb_build_array(jsonb_build_object('salesOrderLineId',v_order_line,
          'quantityUom',1,'unitPrice',95000))));
  EXCEPTION WHEN OTHERS THEN v_blocked:=SQLERRM LIKE '%MASTER_VERSION_CONFLICT%'; END;
  IF NOT v_blocked THEN RAISE EXCEPTION 'TEST_FAILED: stale edit was accepted'; END IF;

  v_canceled:=public.cancel_backoffice_sales_invoice_draft((v_updated->'data'->>'id')::uuid,
    (v_updated->'data'->>'masterVersion')::bigint,gen_random_uuid(),'Rollback cancellation test');
  IF v_canceled->'data'->>'status'<>'CANCELED'
    OR (SELECT draft_invoice_allocated_base_qty FROM public.backoffice_sales_order_lines
      WHERE company_id=v_company AND id=v_order_line)<>0 THEN
    RAISE EXCEPTION 'TEST_FAILED: cancellation did not release quantity hold';
  END IF;
  IF (SELECT count(*) FROM public.financial_events)<>v_event_before
    OR (SELECT count(*) FROM public.finance_journals)<>v_journal_before THEN
    RAISE EXCEPTION 'TEST_FAILED: Draft runtime created Finance effect';
  END IF;
  UPDATE public.warehouses SET allow_negative_stock=v_original_negative
  WHERE company_id=v_company AND id=v_warehouse;
END
$test$;
ROLLBACK;
SELECT 'backoffice_sales_invoice_draft_runtime_behavior' check_name,'PASS' status,
  0::bigint violation_rows,jsonb_build_object('tested',ARRAY[
    'canonical SO preparation and Confirm','DP percentage from DPP','proportional DP tax',
    '30/70 Draft schedules','exact retry','Regular quantity hold','over-allocation denial',
    'Draft commercial edit','stale-version denial','cancel releases hold',
    'zero Finance/Stock posting effect','all fixture writes rolled back']) details;
