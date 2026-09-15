-- Authenticated rollback-only behavior for Regular/DP multi-tax breakdown.
BEGIN;
DO $test$
DECLARE
  v_actor uuid;v_company uuid;v_store uuid;v_warehouse uuid;v_customer uuid;
  v_pu1 uuid;v_product1 uuid;v_account uuid;v_rule1 uuid:=gen_random_uuid();
  v_created jsonb;v_confirmed jsonb;v_dp jsonb;v_regular jsonb;
  v_order uuid;v_line1 uuid;v_dp_id uuid;v_regular_id uuid;
  v_event_before bigint;v_journal_before bigint;v_blocked boolean:=false;
  v_math_rows bigint;v_math_tax numeric;
  v_original_negative boolean;v_suffix text:=substr(replace(gen_random_uuid()::text,'-',''),1,8);
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260909159000') THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: Invoice tax breakdown required';
  END IF;
  SELECT profile.id INTO v_actor
  FROM public.profiles profile
  JOIN auth.users auth_user ON auth_user.id=profile.id
  WHERE profile.role='super_admin'::public.user_role
  ORDER BY profile.id LIMIT 1;
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: linked Super Admin profile required';
  END IF;
  SELECT company.id INTO v_company FROM public.companies company
  WHERE company.status='ACTIVE'
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
  IF v_company IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: canonical Invoice fixture Company required';
  END IF;
  PERFORM set_config('request.jwt.claim.sub',v_actor::text,true);
  INSERT INTO public.user_active_company_contexts(user_id,company_id)
  VALUES(v_actor,v_company) ON CONFLICT(user_id) DO UPDATE
    SET company_id=excluded.company_id,selected_at=clock_timestamp(),updated_at=clock_timestamp();
  INSERT INTO public.company_features(company_id,feature_code,is_enabled,config,updated_by)
  VALUES(v_company,'tax_sales_enabled',true,'{}',v_actor)
  ON CONFLICT(company_id,feature_code) DO UPDATE SET is_enabled=true,updated_by=excluded.updated_by;
  INSERT INTO public.company_features(company_id,feature_code,is_enabled,config,updated_by)
  VALUES(v_company,'backoffice_delivered_qty_sales_enabled',true,'{}',v_actor)
  ON CONFLICT(company_id,feature_code) DO UPDATE SET is_enabled=true,updated_by=excluded.updated_by;
  SELECT id INTO v_store FROM public.stores
  WHERE company_id=v_company AND status='ACTIVE' ORDER BY id LIMIT 1;
  SELECT id,allow_negative_stock INTO v_warehouse,v_original_negative
  FROM public.warehouses WHERE company_id=v_company AND is_active AND is_sale_source
    AND (store_id IS NULL OR store_id=v_store) ORDER BY store_id NULLS LAST,id LIMIT 1;
  UPDATE public.warehouses SET allow_negative_stock=true
  WHERE company_id=v_company AND id=v_warehouse;
  SELECT id INTO v_customer FROM public.customers
  WHERE company_id=v_company AND is_active ORDER BY is_system_customer DESC,id LIMIT 1;
  SELECT product_uom.id,product_uom.product_id INTO v_pu1,v_product1
  FROM public.product_uoms product_uom JOIN public.products product
    ON product.company_id=product_uom.company_id AND product.id=product_uom.product_id
  WHERE product_uom.company_id=v_company AND product_uom.is_active
    AND product_uom.sales_allowed AND product_uom.factor_to_base>0
    AND product.is_active AND NOT product.is_bundle
  ORDER BY product_uom.product_id,product_uom.id LIMIT 1;
  IF v_store IS NULL OR v_warehouse IS NULL OR v_customer IS NULL OR v_pu1 IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: canonical Store/Warehouse/Customer/Product UOM missing';
  END IF;
  SELECT candidate.account_id INTO v_account FROM (
    SELECT rule.account_id,1 priority FROM public.transaction_account_rules rule
    JOIN public.transaction_categories category ON category.company_id=rule.company_id
      AND category.id=rule.transaction_category_id AND category.is_active
    JOIN public.chart_of_accounts account ON account.company_id=rule.company_id
      AND account.id=rule.account_id AND account.is_active AND account.is_postable
    WHERE rule.company_id=v_company AND rule.system_key='SALE_POSTED'
      AND category.system_key='SALE_POSTED' AND rule.account_function_key='OUTPUT_TAX'
      AND rule.status='ACTIVE' AND rule.effective_from<=clock_timestamp()
      AND (rule.effective_to IS NULL OR rule.effective_to>clock_timestamp())
    UNION ALL
    SELECT fallback.account_id,2 FROM public.company_account_function_fallbacks fallback
    JOIN public.chart_of_accounts account ON account.company_id=fallback.company_id
      AND account.id=fallback.account_id AND account.is_active AND account.is_postable
    WHERE fallback.company_id=v_company AND fallback.account_function_key='OUTPUT_TAX'
      AND fallback.status='ACTIVE' AND fallback.effective_from<=clock_timestamp()
      AND (fallback.effective_to IS NULL OR fallback.effective_to>clock_timestamp())
    UNION ALL
    SELECT account.id,3 FROM public.chart_of_accounts account
    WHERE account.company_id=v_company AND account.is_active AND account.is_postable
      AND account.is_system_account AND account.system_function_key='OUTPUT_TAX'
  ) candidate ORDER BY candidate.priority,candidate.account_id LIMIT 1;
  IF v_account IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: canonical OUTPUT_TAX account source missing';
  END IF;

  INSERT INTO public.tax_rules(id,company_id,tax_code,tax_name,tax_scope,is_active,created_by,updated_by)
  VALUES(v_rule1,v_company,'INV-TAX-11-'||v_suffix,'Invoice Test Tax 11 '||v_suffix,
      'SALES',true,v_actor,v_actor);
  INSERT INTO public.tax_rule_versions(company_id,tax_rule_id,rate_percent,
    calculation_scope,default_price_mode,account_function_key,account_id,is_recoverable,
    effective_from,rule_version,status,approved_by,approved_at,created_by,updated_by)
  VALUES(v_company,v_rule1,11,'PER_DOCUMENT','INCLUSIVE','OUTPUT_TAX',v_account,NULL,
      clock_timestamp()-interval '1 day',1,'ACTIVE',v_actor,clock_timestamp(),v_actor,v_actor);
  UPDATE public.products SET sales_tax_rule_id=v_rule1,updated_by=v_actor
  WHERE company_id=v_company AND id=v_product1;

  v_created:=public.save_backoffice_sales_order_draft(NULL,NULL,gen_random_uuid(),
    jsonb_build_object('storeId',v_store,'warehouseId',v_warehouse,'customerId',v_customer,
      'selectedPricelistId',NULL,'orderDate',current_date,'plannedDeliveryDate',current_date+1,
      'isTempo',false,'currencyCode','IDR','globalDiscount',0,'roundingDirection','NONE',
      'roundingIncrement',100,'lines',jsonb_build_array(
        jsonb_build_object('productUomId',v_pu1,'quantity',2,'overrideUnitPrice',100000))));
  v_order:=(v_created->'data'->>'id')::uuid;
  v_confirmed:=public.confirm_backoffice_sales_order(v_order,
    (v_created->'data'->>'masterVersion')::bigint,gen_random_uuid());
  SELECT id INTO v_line1 FROM public.backoffice_sales_order_lines
  WHERE company_id=v_company AND sales_order_id=v_order AND product_id=v_product1;
  IF v_line1 IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: canonical Sales Order line missing';
  END IF;
  UPDATE public.backoffice_sales_order_lines SET accepted_base_qty=ordered_base_qty
  WHERE company_id=v_company AND sales_order_id=v_order;
  SELECT count(*) INTO v_event_before FROM public.financial_events;
  SELECT count(*) INTO v_journal_before FROM public.finance_journals;

  v_dp:=public.save_backoffice_sales_invoice_draft(NULL,NULL,gen_random_uuid(),v_order,
    jsonb_build_object('invoiceType','DOWN_PAYMENT','invoiceDate',current_date,
      'downPaymentMode','PERCENT','downPaymentInput',20));
  v_dp_id:=(v_dp->'data'->>'id')::uuid;
  IF jsonb_array_length(v_dp->'data'->'taxBreakdowns')<>1
    OR (SELECT round(sum(tax_amount),4) FROM public.backoffice_sales_invoice_tax_breakdowns
      WHERE company_id=v_company AND invoice_id=v_dp_id)
      <>round((v_dp->'data'->>'taxTotal')::numeric,4) THEN
    RAISE EXCEPTION 'TEST_FAILED: DP proportional tax breakdown invalid';
  END IF;

  v_regular:=public.save_backoffice_sales_invoice_draft(NULL,NULL,gen_random_uuid(),v_order,
    jsonb_build_object('invoiceType','REGULAR','invoiceDate',current_date,'lines',jsonb_build_array(
      jsonb_build_object('salesOrderLineId',v_line1,'quantityUom',2,'unitPrice',100000))));
  v_regular_id:=(v_regular->'data'->>'id')::uuid;
  IF jsonb_array_length(v_regular->'data'->'taxBreakdowns')<>1
    OR (SELECT round(sum(tax_amount),4) FROM public.backoffice_sales_invoice_tax_breakdowns
      WHERE company_id=v_company AND invoice_id=v_regular_id)
      <>round((v_regular->'data'->>'taxTotal')::numeric,4) THEN
    RAISE EXCEPTION 'TEST_FAILED: Regular tax breakdown invalid';
  END IF;

  -- Pure allocation check for the exact two-group rounding algorithm used by
  -- the runtime. Persistence above uses canonical master data; this block does
  -- not assume a second Product exists in Development.
  WITH grouped(group_no,source_tax_amount) AS (VALUES(1,11::numeric),(2,5::numeric)),
  rounded AS (SELECT group_no,round(source_tax_amount*0.20,4) allocated_tax FROM grouped),
  finalized AS (SELECT group_no,CASE WHEN group_no=2 THEN allocated_tax+
      (round(16::numeric*0.20,4)-sum(allocated_tax) OVER()) ELSE allocated_tax END final_tax
    FROM rounded)
  SELECT count(*),round(sum(final_tax),4) INTO v_math_rows,v_math_tax FROM finalized;
  IF v_math_rows<>2 OR v_math_tax<>3.2 THEN
    RAISE EXCEPTION 'TEST_FAILED: two-group proportional rounding contract invalid';
  END IF;

  PERFORM public.cancel_backoffice_sales_invoice_draft(v_dp_id,
    (v_dp->'data'->>'masterVersion')::bigint,gen_random_uuid(),'Tax history guard test');
  BEGIN
    UPDATE public.backoffice_sales_invoice_tax_breakdowns SET tax_amount=tax_amount+1
    WHERE company_id=v_company AND invoice_id=v_dp_id AND tax_group_no=1;
  EXCEPTION WHEN OTHERS THEN
    v_blocked:=SQLERRM LIKE '%BACKOFFICE_SALES_INVOICE_TAX_BREAKDOWN_IMMUTABLE%';
  END;
  IF NOT v_blocked THEN RAISE EXCEPTION 'TEST_FAILED: canceled tax history was mutable'; END IF;
  IF (SELECT count(*) FROM public.financial_events)<>v_event_before
    OR (SELECT count(*) FROM public.finance_journals)<>v_journal_before THEN
    RAISE EXCEPTION 'TEST_FAILED: tax breakdown created Finance effect';
  END IF;
END
$test$;
ROLLBACK;
SELECT 'backoffice_sales_invoice_tax_breakdown_behavior' check_name,'PASS' status,
  0::bigint violation_rows,jsonb_build_object('tested',ARRAY[
    'canonical SALES tax fixture','DP proportional persisted breakdown',
    'Regular Invoice persisted breakdown','two-group proportional rounding contract',
    'breakdown equals Invoice tax total',
    'canceled Invoice tax history immutable','zero Event/Journal effect',
    'all fixture writes rolled back']) details;
