-- Authenticated rollback-only behavior for Backoffice Sales Return commercial foundation.
BEGIN;
DO $test$
DECLARE
  v_actor uuid;v_company uuid;v_store uuid;v_warehouse uuid;v_customer uuid;
  v_product_uom uuid;v_factor numeric;v_created jsonb;v_confirmed jsonb;
  v_order uuid;v_order_line uuid;v_return uuid;v_saved jsonb;v_retry jsonb;
  v_updated jsonb;v_submitted jsonb;v_approved jsonb;v_canceled jsonb;
  v_second jsonb;v_blocked boolean;v_save_operation uuid:=gen_random_uuid();
  v_submit_operation uuid:=gen_random_uuid();v_event_before bigint;v_journal_before bigint;
  v_stock_before bigint;v_invoice_before bigint;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260917110000') THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: Return commercial foundation required';
  END IF;
  SELECT profile.id INTO STRICT v_actor FROM public.profiles profile
  JOIN auth.users auth_user ON auth_user.id=profile.id
  WHERE profile.role='super_admin'::public.user_role ORDER BY profile.id LIMIT 1;
  SELECT company.id INTO STRICT v_company FROM public.companies company
  WHERE company.status='ACTIVE'
    AND EXISTS(SELECT 1 FROM public.company_sales_process_settings setting
      WHERE setting.company_id=company.id)
    AND EXISTS(SELECT 1 FROM public.stores store
      JOIN public.warehouses warehouse ON warehouse.company_id=store.company_id
        AND warehouse.is_active AND warehouse.is_sale_source
        AND (warehouse.store_id IS NULL OR warehouse.store_id=store.id)
      WHERE store.company_id=company.id AND store.status='ACTIVE')
    AND EXISTS(SELECT 1 FROM public.customers customer
      WHERE customer.company_id=company.id AND customer.is_active)
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
  -- Test-only mode preparation is transaction-local because the complete file
  -- ends in ROLLBACK. It avoids depending on the Company's current UI mode.
  PERFORM pg_advisory_xact_lock(hashtextextended(v_company::text,20260911130000));
  PERFORM set_config('kgs.sales_process_cutover_mutation','1',true);
  UPDATE public.company_sales_process_settings SET
    active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE',mode_effective_at='-infinity',
    master_version=master_version+1,updated_by=v_actor,updated_at=clock_timestamp()
  WHERE company_id=v_company;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: Company sales process setting required';
  END IF;
  PERFORM set_config('kgs.sales_process_cutover_mutation','',true);
  PERFORM private.assert_sales_process_root_creation_allowed(
    v_company,'BACKOFFICE_DELIVERED_QTY_INVOICE');
  SELECT id INTO STRICT v_store FROM public.stores
    WHERE company_id=v_company AND status='ACTIVE' ORDER BY id LIMIT 1;
  SELECT id INTO STRICT v_warehouse FROM public.warehouses
    WHERE company_id=v_company AND is_active AND is_sale_source
      AND (store_id IS NULL OR store_id=v_store)
    ORDER BY store_id NULLS LAST,id LIMIT 1;
  UPDATE public.warehouses SET allow_negative_stock=true
    WHERE company_id=v_company AND id=v_warehouse;
  SELECT id INTO STRICT v_customer FROM public.customers
    WHERE company_id=v_company AND is_active ORDER BY is_system_customer DESC,id LIMIT 1;
  SELECT product_uom.id,product_uom.factor_to_base INTO STRICT v_product_uom,v_factor
  FROM public.product_uoms product_uom
  JOIN public.products product ON product.company_id=product_uom.company_id
    AND product.id=product_uom.product_id AND product.is_active AND NOT product.is_bundle
  WHERE product_uom.company_id=v_company AND product_uom.is_active
    AND product_uom.sales_allowed ORDER BY product_uom.id LIMIT 1;

  v_created:=public.save_backoffice_sales_order_draft(NULL,NULL,gen_random_uuid(),
    jsonb_build_object('storeId',v_store,'warehouseId',v_warehouse,'customerId',v_customer,
      'selectedPricelistId',NULL,'orderDate',current_date,'plannedDeliveryDate',current_date,
      'isTempo',false,'currencyCode','IDR','globalDiscount',0,
      'roundingDirection','NONE','roundingIncrement',100,'lines',jsonb_build_array(
        jsonb_build_object('productUomId',v_product_uom,'quantity',2,'overrideUnitPrice',100000))));
  v_order:=(v_created->'data'->>'id')::uuid;
  v_confirmed:=public.confirm_backoffice_sales_order(v_order,
    (v_created->'data'->>'masterVersion')::bigint,gen_random_uuid());
  SELECT id INTO STRICT v_order_line FROM public.backoffice_sales_order_lines
    WHERE company_id=v_company AND sales_order_id=v_order;
  UPDATE public.backoffice_sales_order_lines SET accepted_base_qty=ordered_base_qty
    WHERE company_id=v_company AND id=v_order_line;

  SELECT count(*) INTO v_event_before FROM public.financial_events;
  SELECT count(*) INTO v_journal_before FROM public.finance_journals;
  SELECT count(*) INTO v_stock_before FROM public.stock_movements;
  SELECT count(*) INTO v_invoice_before FROM public.backoffice_sales_invoices;

  v_saved:=public.save_backoffice_sales_return_draft(NULL,NULL,v_save_operation,v_order,
    jsonb_build_object('reason','Customer mengembalikan sebagian barang','notes','Rollback-only test',
      'lines',jsonb_build_array(jsonb_build_object('salesOrderLineId',v_order_line,
        'quantityUom',1,'reason','Tidak sesuai kebutuhan'))));
  v_return:=(v_saved->'data'->>'id')::uuid;
  IF v_saved->'data'->>'status'<>'DRAFT'
    OR (v_saved->'data'->>'totalRequestedBaseQty')::numeric<>v_factor THEN
    RAISE EXCEPTION 'TEST_FAILED: Return Draft snapshot invalid';
  END IF;
  v_retry:=public.save_backoffice_sales_return_draft(NULL,NULL,v_save_operation,v_order,
    jsonb_build_object('reason','Customer mengembalikan sebagian barang','notes','Rollback-only test',
      'lines',jsonb_build_array(jsonb_build_object('salesOrderLineId',v_order_line,
        'quantityUom',1,'reason','Tidak sesuai kebutuhan'))));
  IF COALESCE((v_retry->>'exactRetry')::boolean,false) IS NOT TRUE
    OR (SELECT count(*) FROM public.backoffice_sales_returns
      WHERE company_id=v_company AND sales_order_id=v_order)<>1 THEN
    RAISE EXCEPTION 'TEST_FAILED: Save Draft exact retry duplicated Return';
  END IF;

  v_updated:=public.save_backoffice_sales_return_draft(v_return,
    (v_saved->'data'->>'masterVersion')::bigint,gen_random_uuid(),v_order,
    jsonb_build_object('reason','Customer mengembalikan barang','notes','Editable before submit',
      'lines',jsonb_build_array(jsonb_build_object('salesOrderLineId',v_order_line,
        'quantityUom',1,'reason','Final commercial reason'))));
  v_submitted:=public.submit_backoffice_sales_return(v_return,
    (v_updated->'data'->>'masterVersion')::bigint,v_submit_operation);
  v_retry:=public.submit_backoffice_sales_return(v_return,
    (v_updated->'data'->>'masterVersion')::bigint,v_submit_operation);
  IF v_submitted->'data'->>'status'<>'SUBMITTED'
    OR COALESCE((v_retry->>'exactRetry')::boolean,false) IS NOT TRUE THEN
    RAISE EXCEPTION 'TEST_FAILED: Submit or exact retry invalid';
  END IF;

  v_blocked:=false;
  BEGIN
    PERFORM public.approve_backoffice_sales_return(v_return,
      (v_updated->'data'->>'masterVersion')::bigint,gen_random_uuid());
  EXCEPTION WHEN OTHERS THEN v_blocked:=SQLERRM LIKE '%MASTER_VERSION_CONFLICT%'; END;
  IF NOT v_blocked THEN RAISE EXCEPTION 'TEST_FAILED: stale Return approval accepted'; END IF;

  v_second:=public.save_backoffice_sales_return_draft(NULL,NULL,gen_random_uuid(),v_order,
    jsonb_build_object('reason','Concurrent quantity test','lines',jsonb_build_array(
      jsonb_build_object('salesOrderLineId',v_order_line,'quantityUom',2))));
  v_blocked:=false;
  BEGIN
    PERFORM public.submit_backoffice_sales_return((v_second->'data'->>'id')::uuid,
      (v_second->'data'->>'masterVersion')::bigint,gen_random_uuid());
  EXCEPTION WHEN OTHERS THEN
    v_blocked:=SQLERRM LIKE '%BACKOFFICE_SALES_RETURN_QUANTITY_EXCEEDS_RETURNABLE%';
  END;
  IF NOT v_blocked THEN RAISE EXCEPTION 'TEST_FAILED: concurrent Return over-allocation accepted'; END IF;

  v_approved:=public.approve_backoffice_sales_return(v_return,
    (v_submitted->'data'->>'masterVersion')::bigint,gen_random_uuid());
  IF v_approved->'data'->>'status'<>'APPROVED' THEN
    RAISE EXCEPTION 'TEST_FAILED: commercial approval invalid';
  END IF;
  v_canceled:=public.cancel_backoffice_sales_return(v_return,
    (v_approved->'data'->>'masterVersion')::bigint,gen_random_uuid(),'Customer membatalkan retur');
  IF v_canceled->'data'->>'status'<>'CANCELED' THEN
    RAISE EXCEPTION 'TEST_FAILED: pre-receipt cancellation invalid';
  END IF;

  v_submitted:=public.submit_backoffice_sales_return((v_second->'data'->>'id')::uuid,
    (v_second->'data'->>'masterVersion')::bigint,gen_random_uuid());
  IF v_submitted->'data'->>'status'<>'SUBMITTED' THEN
    RAISE EXCEPTION 'TEST_FAILED: cancellation did not release quantity hold';
  END IF;

  v_blocked:=false;
  BEGIN
    UPDATE public.backoffice_sales_return_audit SET reason='forbidden'
    WHERE company_id=v_company AND return_id=v_return;
  EXCEPTION WHEN OTHERS THEN
    v_blocked:=SQLERRM LIKE '%BACKOFFICE_SALES_RETURN_HISTORY_IMMUTABLE%';
  END;
  IF NOT v_blocked THEN RAISE EXCEPTION 'TEST_FAILED: Return audit was mutable'; END IF;
  IF (SELECT count(*) FROM public.financial_events)<>v_event_before
    OR (SELECT count(*) FROM public.finance_journals)<>v_journal_before
    OR (SELECT count(*) FROM public.stock_movements)<>v_stock_before
    OR (SELECT count(*) FROM public.backoffice_sales_invoices)<>v_invoice_before THEN
    RAISE EXCEPTION 'TEST_FAILED: commercial Return changed Stock, Invoice or Finance';
  END IF;
END
$test$;
ROLLBACK;
SELECT 'backoffice_sales_return_commercial_behavior' check_name,'PASS' status,
  0::bigint violation_rows,jsonb_build_object('tested',ARRAY[
    'canonical confirmed SO with accepted quantity','Return Draft create and edit',
    'Save and Submit exact retry','stale-version rejection','concurrent quantity hold',
    'commercial approval','pre-receipt cancellation releases hold','immutable audit',
    'zero Stock, Invoice, Financial Event and Journal effect','all fixture writes rolled back']) details;
