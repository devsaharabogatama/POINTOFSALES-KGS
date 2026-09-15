-- Authenticated rollback-only behavior for Backoffice delivery-fee parity.
BEGIN;
DO $test$
DECLARE
  v_actor uuid;v_company uuid;v_store uuid;v_warehouse uuid;v_customer uuid;
  v_product_uom uuid;v_product uuid;v_order uuid;v_order_line uuid;
  v_created jsonb;v_confirmed jsonb;v_first jsonb;v_second jsonb;v_edited jsonb;
  v_canceled jsonb;v_third jsonb;v_posted_first jsonb;v_posted_third jsonb;v_retry jsonb;
  v_first_id uuid;v_second_id uuid;v_third_id uuid;v_blocked boolean:=false;
  v_dp_blocked boolean:=false;
  v_period_date date:=current_date;v_sales_before bigint;v_delivery_account uuid;
  v_original_negative boolean;v_first_save_operation uuid;v_audit_snapshot jsonb;
  v_operation_snapshot jsonb;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260910151000') THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: immutable-history forward-fix required';
  END IF;
  SELECT profile.id INTO v_actor FROM public.profiles profile
  JOIN auth.users auth_user ON auth_user.id=profile.id
  WHERE profile.role='super_admin'::public.user_role ORDER BY profile.id LIMIT 1;
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: linked Super Admin profile required';
  END IF;
  SELECT company.id INTO v_company FROM public.companies company
  WHERE company.status='ACTIVE'
    AND EXISTS(SELECT 1 FROM public.stores store
      JOIN public.warehouses warehouse ON warehouse.company_id=store.company_id
        AND (warehouse.store_id IS NULL OR warehouse.store_id=store.id)
      WHERE store.company_id=company.id AND store.status='ACTIVE'
        AND warehouse.is_active AND warehouse.is_sale_source)
    AND EXISTS(SELECT 1 FROM public.customers customer
      WHERE customer.company_id=company.id AND customer.is_active)
    AND EXISTS(SELECT 1 FROM public.product_uoms product_uom
      JOIN public.products product ON product.company_id=product_uom.company_id
        AND product.id=product_uom.product_id AND product.is_active AND NOT product.is_bundle
      WHERE product_uom.company_id=company.id AND product_uom.is_active
        AND product_uom.sales_allowed AND product_uom.factor_to_base>0)
    AND EXISTS(SELECT 1 FROM public.accounting_periods period
      WHERE period.company_id=company.id AND period.status IN('OPEN','REOPENED')
        AND v_period_date BETWEEN period.start_date AND period.end_date)
    AND EXISTS(SELECT 1 FROM public.transaction_categories category
      JOIN public.transaction_account_rules rule ON rule.company_id=category.company_id
        AND rule.transaction_category_id=category.id
      WHERE category.company_id=company.id AND category.is_active
        AND category.system_key='BACKOFFICE_SALES_INVOICE'
        AND rule.system_key='BACKOFFICE_SALES_INVOICE'
        AND rule.account_function_key='DELIVERY_FEE_REVENUE' AND rule.status='ACTIVE')
  ORDER BY company.id LIMIT 1;
  IF v_company IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: canonical Company with open period and delivery mapping required';
  END IF;
  PERFORM set_config('request.jwt.claim.sub',v_actor::text,true);
  INSERT INTO public.user_active_company_contexts(user_id,company_id)
  VALUES(v_actor,v_company) ON CONFLICT(user_id) DO UPDATE SET
    company_id=excluded.company_id,selected_at=clock_timestamp(),updated_at=clock_timestamp();
  INSERT INTO public.company_features(company_id,feature_code,is_enabled,config,updated_by)
  VALUES(v_company,'backoffice_delivered_qty_sales_enabled',true,'{}',v_actor)
  ON CONFLICT(company_id,feature_code) DO UPDATE SET is_enabled=true,updated_by=excluded.updated_by;
  SELECT store.id,warehouse.id,warehouse.allow_negative_stock
  INTO v_store,v_warehouse,v_original_negative
  FROM public.stores store JOIN public.warehouses warehouse
    ON warehouse.company_id=store.company_id
    AND (warehouse.store_id IS NULL OR warehouse.store_id=store.id)
  WHERE store.company_id=v_company AND store.status='ACTIVE'
    AND warehouse.is_active AND warehouse.is_sale_source
  ORDER BY warehouse.store_id NULLS LAST,store.id,warehouse.id LIMIT 1;
  SELECT customer.id INTO v_customer FROM public.customers customer
  WHERE customer.company_id=v_company AND customer.is_active
  ORDER BY customer.is_system_customer DESC,customer.id LIMIT 1;
  SELECT product_uom.id,product_uom.product_id INTO v_product_uom,v_product
  FROM public.product_uoms product_uom JOIN public.products product
    ON product.company_id=product_uom.company_id AND product.id=product_uom.product_id
  WHERE product_uom.company_id=v_company AND product_uom.is_active
    AND product_uom.sales_allowed AND product_uom.factor_to_base>0
    AND product.is_active AND NOT product.is_bundle
  ORDER BY product_uom.product_id,product_uom.id LIMIT 1;
  SELECT rule.account_id INTO v_delivery_account
  FROM public.transaction_categories category
  JOIN public.transaction_account_rules rule ON rule.company_id=category.company_id
    AND rule.transaction_category_id=category.id
  WHERE category.company_id=v_company AND category.system_key='BACKOFFICE_SALES_INVOICE'
    AND category.is_active AND rule.system_key='BACKOFFICE_SALES_INVOICE'
    AND rule.account_function_key='DELIVERY_FEE_REVENUE' AND rule.status='ACTIVE'
  ORDER BY rule.rule_version DESC,rule.id LIMIT 1;
  IF v_store IS NULL OR v_warehouse IS NULL OR v_customer IS NULL
    OR v_product_uom IS NULL OR v_delivery_account IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: canonical Sales fixture missing';
  END IF;
  UPDATE public.warehouses SET allow_negative_stock=true
  WHERE company_id=v_company AND id=v_warehouse;
  SELECT count(*) INTO v_sales_before FROM public.sales_headers;

  v_created:=public.save_backoffice_sales_order_draft(NULL,NULL,gen_random_uuid(),
    jsonb_build_object('storeId',v_store,'warehouseId',v_warehouse,'customerId',v_customer,
      'selectedPricelistId',NULL,'orderDate',v_period_date,
      'plannedDeliveryDate',v_period_date,'isTempo',false,'currencyCode','IDR',
      'globalDiscount',0,'roundingDirection','NONE','roundingIncrement',100,
      'deliveryFeeAmount',30000,'deliveryFeeInvoiceDisplayMode','SHOW_SEPARATE',
      'lines',jsonb_build_array(jsonb_build_object('productUomId',v_product_uom,
        'quantity',2,'overrideUnitPrice',100000))));
  v_order:=(v_created->'data'->>'id')::uuid;
  IF (v_created->'data'->>'deliveryFeeAmount')::numeric<>30000
    OR (v_created->'data'->>'grandTotal')::numeric
      <>(v_created->'data'->>'grandTotalBeforeRounding')::numeric+30000 THEN
    RAISE EXCEPTION 'TEST_FAILED: SO delivery fee or total invalid';
  END IF;
  v_confirmed:=public.confirm_backoffice_sales_order(v_order,
    (v_created->'data'->>'masterVersion')::bigint,gen_random_uuid());
  SELECT line.id INTO v_order_line FROM public.backoffice_sales_order_lines line
  WHERE line.company_id=v_company AND line.sales_order_id=v_order
    AND line.product_id=v_product;
  UPDATE public.backoffice_sales_order_lines SET accepted_base_qty=ordered_base_qty
  WHERE company_id=v_company AND id=v_order_line;

  BEGIN
    PERFORM public.save_backoffice_sales_invoice_draft(NULL,NULL,gen_random_uuid(),v_order,
      jsonb_build_object('invoiceType','DOWN_PAYMENT','invoiceDate',v_period_date,
        'downPaymentMode','PERCENT','downPaymentInput',10,'deliveryFeeAmount',1));
  EXCEPTION WHEN OTHERS THEN
    v_dp_blocked:=SQLERRM LIKE '%BACKOFFICE_INVOICE_DELIVERY_FEE_NOT_ALLOWED_ON_DP%';
  END;
  IF NOT v_dp_blocked THEN
    RAISE EXCEPTION 'TEST_FAILED: Down Payment Invoice accepted delivery fee';
  END IF;

  v_first_save_operation:=gen_random_uuid();
  v_first:=public.save_backoffice_sales_invoice_draft(NULL,NULL,v_first_save_operation,v_order,
    jsonb_build_object('invoiceType','REGULAR','invoiceDate',v_period_date,
      'lines',jsonb_build_array(jsonb_build_object('salesOrderLineId',v_order_line,
        'quantityUom',1,'unitPrice',100000,'taxApplied',false))));
  v_first_id:=(v_first->'data'->>'id')::uuid;
  IF (v_first->'data'->>'deliveryFeeAmount')::numeric<>30000 THEN
    RAISE EXCEPTION 'TEST_FAILED: first Regular Invoice did not auto-fill full delivery fee';
  END IF;
  SELECT audit.after_state INTO STRICT v_audit_snapshot
  FROM public.backoffice_sales_invoice_audit audit
  WHERE audit.company_id=v_company AND audit.operation_id=v_first_save_operation
    AND audit.action='CREATE_DRAFT';
  SELECT operation.response_snapshot INTO STRICT v_operation_snapshot
  FROM public.backoffice_sales_invoice_operations operation
  WHERE operation.company_id=v_company AND operation.operation_id=v_first_save_operation
    AND operation.operation_type='SAVE_DRAFT';
  IF v_audit_snapshot IS DISTINCT FROM v_first->'data'
    OR v_operation_snapshot->'data' IS DISTINCT FROM v_first->'data'
    OR (v_audit_snapshot->>'deliveryFeeAmount')::numeric<>30000 THEN
    RAISE EXCEPTION 'TEST_FAILED: immutable audit/operation differs from canonical response';
  END IF;
  v_second:=public.save_backoffice_sales_invoice_draft(NULL,NULL,gen_random_uuid(),v_order,
    jsonb_build_object('invoiceType','REGULAR','invoiceDate',v_period_date,
      'lines',jsonb_build_array(jsonb_build_object('salesOrderLineId',v_order_line,
        'quantityUom',1,'unitPrice',100000,'taxApplied',false))));
  v_second_id:=(v_second->'data'->>'id')::uuid;
  IF (v_second->'data'->>'deliveryFeeAmount')::numeric<>0 THEN
    RAISE EXCEPTION 'TEST_FAILED: later Regular Invoice received duplicate delivery fee';
  END IF;
  IF NULLIF(current_setting('kgs.backoffice_invoice_delivery_fee_amount',true),'') IS NOT NULL THEN
    RAISE EXCEPTION 'TEST_FAILED: transaction-local delivery fee leaked after save';
  END IF;
  BEGIN
    PERFORM public.save_backoffice_sales_invoice_draft(v_second_id,
      (v_second->'data'->>'masterVersion')::bigint,gen_random_uuid(),v_order,
      jsonb_build_object('invoiceType','REGULAR','invoiceDate',v_period_date,
        'deliveryFeeAmount',1,'lines',jsonb_build_array(jsonb_build_object(
          'salesOrderLineId',v_order_line,'quantityUom',1,'unitPrice',100000,
          'taxApplied',false))));
  EXCEPTION WHEN OTHERS THEN
    v_blocked:=SQLERRM LIKE '%BACKOFFICE_INVOICE_DELIVERY_FEE_EXCEEDS_ORDER%';
  END;
  IF NOT v_blocked THEN
    RAISE EXCEPTION 'TEST_FAILED: aggregate delivery-fee over-allocation was accepted';
  END IF;

  v_edited:=public.save_backoffice_sales_invoice_draft(v_first_id,
    (v_first->'data'->>'masterVersion')::bigint,gen_random_uuid(),v_order,
    jsonb_build_object('invoiceType','REGULAR','invoiceDate',v_period_date,
      'deliveryFeeAmount',10000,'lines',jsonb_build_array(jsonb_build_object(
        'salesOrderLineId',v_order_line,'quantityUom',1,'unitPrice',100000,
        'taxApplied',false))));
  v_second:=public.save_backoffice_sales_invoice_draft(v_second_id,
    (v_second->'data'->>'masterVersion')::bigint,gen_random_uuid(),v_order,
    jsonb_build_object('invoiceType','REGULAR','invoiceDate',v_period_date,
      'deliveryFeeAmount',20000,'lines',jsonb_build_array(jsonb_build_object(
        'salesOrderLineId',v_order_line,'quantityUom',1,'unitPrice',100000,
        'taxApplied',false))));
  IF (SELECT sum(invoice.delivery_fee_amount) FROM public.backoffice_sales_invoices invoice
      WHERE invoice.company_id=v_company AND invoice.sales_order_id=v_order
        AND invoice.status='DRAFT' AND invoice.invoice_type='REGULAR')<>30000 THEN
    RAISE EXCEPTION 'TEST_FAILED: editable delivery-fee allocation invalid';
  END IF;
  v_canceled:=public.cancel_backoffice_sales_invoice_draft(v_second_id,
    (v_second->'data'->>'masterVersion')::bigint,gen_random_uuid(),'Uji pelepasan ongkir');
  IF v_canceled->'data'->>'status'<>'CANCELED' THEN
    RAISE EXCEPTION 'TEST_FAILED: second Draft Invoice was not canceled';
  END IF;
  v_third:=public.save_backoffice_sales_invoice_draft(NULL,NULL,gen_random_uuid(),v_order,
    jsonb_build_object('invoiceType','REGULAR','invoiceDate',v_period_date,
      'lines',jsonb_build_array(jsonb_build_object('salesOrderLineId',v_order_line,
        'quantityUom',1,'unitPrice',100000,'taxApplied',false))));
  v_third_id:=(v_third->'data'->>'id')::uuid;
  IF (v_third->'data'->>'deliveryFeeAmount')::numeric<>20000 THEN
    RAISE EXCEPTION 'TEST_FAILED: canceled Invoice did not release delivery-fee allocation';
  END IF;

  v_posted_first:=public.post_backoffice_sales_invoice(v_first_id,
    (v_edited->'data'->>'masterVersion')::bigint,gen_random_uuid());
  v_posted_third:=public.post_backoffice_sales_invoice(v_third_id,
    (v_third->'data'->>'masterVersion')::bigint,gen_random_uuid());
  IF NOT EXISTS(SELECT 1 FROM public.finance_journals journal
      JOIN public.finance_journal_lines line ON line.company_id=journal.company_id
        AND line.journal_id=journal.id
      WHERE journal.company_id=v_company
        AND journal.id=(v_posted_first->'finance'->>'journalId')::uuid
        AND journal.status='POSTED' AND line.account_id=v_delivery_account
        AND line.debit=0 AND line.credit=10000)
    OR NOT EXISTS(SELECT 1 FROM public.finance_journals journal
      JOIN public.finance_journal_lines line ON line.company_id=journal.company_id
        AND line.journal_id=journal.id
      WHERE journal.company_id=v_company
        AND journal.id=(v_posted_third->'finance'->>'journalId')::uuid
        AND journal.status='POSTED' AND line.account_id=v_delivery_account
        AND line.debit=0 AND line.credit=20000) THEN
    RAISE EXCEPTION 'TEST_FAILED: delivery-fee Finance line missing or mixed with Sales Revenue';
  END IF;
  v_retry:=public.post_backoffice_sales_invoice(v_third_id,
    (v_third->'data'->>'masterVersion')::bigint,
    (SELECT operation.operation_id FROM public.backoffice_sales_invoice_operations operation
      WHERE operation.company_id=v_company AND operation.invoice_id=v_third_id
        AND operation.operation_type='POST'));
  IF COALESCE((v_retry->>'exactRetry')::boolean,false) IS NOT TRUE
    OR (SELECT count(*) FROM public.finance_journals journal
      WHERE journal.company_id=v_company
        AND journal.financial_event_id=(v_posted_third->'data'->>'financialEventId')::uuid)<>1 THEN
    RAISE EXCEPTION 'TEST_FAILED: exact retry duplicated delivery-fee posting';
  END IF;
  IF (SELECT count(*) FROM public.sales_headers)<>v_sales_before THEN
    RAISE EXCEPTION 'TEST_FAILED: Backoffice delivery fee changed POS Retail Sales';
  END IF;
  UPDATE public.warehouses SET allow_negative_stock=v_original_negative
  WHERE company_id=v_company AND id=v_warehouse;
END
$test$;
ROLLBACK;
SELECT 'backoffice_sales_delivery_fee_parity_behavior' check_name,'PASS' status,
  0::bigint violation_rows,jsonb_build_object('tested',ARRAY[
    'SO delivery fee and payable total','first Regular Invoice full auto-fill',
    'DP delivery fee denied','later Invoice zero default','editable split before posting','aggregate cap denial',
    'immutable audit and operation equal canonical response','transaction-local fee cleared after save',
    'Draft cancel releases allocation','separate DELIVERY_FEE_REVENUE journal',
    'balanced posting and exact retry','POS Retail unchanged','all fixture writes rolled back']) details;
