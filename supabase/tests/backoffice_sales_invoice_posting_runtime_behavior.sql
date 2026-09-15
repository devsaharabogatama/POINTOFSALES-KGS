-- Authenticated rollback-only behavior for Backoffice Invoice posting and DP deduction.
BEGIN;
DO $test$
DECLARE
  v_actor uuid;v_company uuid;v_store uuid;v_warehouse uuid;v_customer uuid;
  v_product_uom uuid;v_product uuid;v_factor numeric;v_tax_account uuid;
  v_tax_rule uuid:=gen_random_uuid();v_suffix text:=substr(replace(gen_random_uuid()::text,'-',''),1,8);
  v_created jsonb;v_confirmed jsonb;v_dp jsonb;v_dp_posted jsonb;
  v_regular jsonb;v_adjusted jsonb;v_regular_posted jsonb;v_retry jsonb;
  v_order uuid;v_order_line uuid;v_dp_id uuid;v_regular_id uuid;
  v_delivery uuid;v_delivery_line uuid;v_delivery_version bigint;v_receipt jsonb;
  v_original_negative boolean;v_period_date date;v_blocked boolean:=false;
  v_dp_total numeric;v_manual_amount numeric;v_event_before bigint;v_journal_before bigint;
  v_sales_before bigint;v_journal public.finance_journals%rowtype;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260909161000') THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: Invoice posting runtime required';
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
        AND current_date BETWEEN period.start_date AND period.end_date)
  ORDER BY company.id LIMIT 1;
  IF v_company IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: canonical Company with current open period required';
  END IF;
  SELECT current_date INTO v_period_date;
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
  -- Company-mode preparation is rolled back and cleared before Sales RPCs.
  PERFORM pg_advisory_xact_lock(hashtextextended(v_company::text,20260911130000));
  PERFORM set_config('kgs.sales_process_cutover_mutation','1',true);
  UPDATE public.company_sales_process_settings SET
    active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE',mode_effective_at='-infinity',
    master_version=master_version+1,updated_by=v_actor,updated_at=clock_timestamp()
  WHERE company_id=v_company;
  IF NOT FOUND THEN RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: Company sales process setting required'; END IF;
  PERFORM set_config('kgs.sales_process_cutover_mutation','',true);
  PERFORM private.assert_sales_process_root_creation_allowed(
    v_company,'BACKOFFICE_DELIVERED_QTY_INVOICE');
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
  SELECT product_uom.id,product_uom.product_id,product_uom.factor_to_base
  INTO v_product_uom,v_product,v_factor
  FROM public.product_uoms product_uom JOIN public.products product
    ON product.company_id=product_uom.company_id AND product.id=product_uom.product_id
  WHERE product_uom.company_id=v_company AND product_uom.is_active
    AND product_uom.sales_allowed AND product_uom.factor_to_base>0
    AND product.is_active AND NOT product.is_bundle
  ORDER BY product_uom.product_id,product_uom.id LIMIT 1;
  IF v_store IS NULL OR v_warehouse IS NULL OR v_customer IS NULL OR v_product_uom IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: canonical Sales fixture missing';
  END IF;
  SELECT candidate.account_id INTO v_tax_account FROM (
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
  IF v_tax_account IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: canonical OUTPUT_TAX account missing';
  END IF;
  UPDATE public.warehouses SET allow_negative_stock=true
  WHERE company_id=v_company AND id=v_warehouse;
  INSERT INTO public.tax_rules(id,company_id,tax_code,tax_name,tax_scope,is_active,created_by,updated_by)
  VALUES(v_tax_rule,v_company,'POST-TAX-'||v_suffix,'Posting Tax '||v_suffix,
    'SALES',true,v_actor,v_actor);
  INSERT INTO public.tax_rule_versions(company_id,tax_rule_id,rate_percent,
    calculation_scope,default_price_mode,account_function_key,account_id,is_recoverable,
    effective_from,rule_version,status,approved_by,approved_at,created_by,updated_by)
  VALUES(v_company,v_tax_rule,11,'PER_DOCUMENT','INCLUSIVE','OUTPUT_TAX',v_tax_account,NULL,
    clock_timestamp()-interval '1 day',1,'ACTIVE',v_actor,clock_timestamp(),v_actor,v_actor);
  UPDATE public.products SET sales_tax_rule_id=v_tax_rule,updated_by=v_actor
  WHERE company_id=v_company AND id=v_product;

  SELECT count(*) INTO v_event_before FROM public.financial_events;
  SELECT count(*) INTO v_journal_before FROM public.finance_journals;
  SELECT count(*) INTO v_sales_before FROM public.sales_headers;
  v_created:=public.save_backoffice_sales_order_draft(NULL,NULL,gen_random_uuid(),
    jsonb_build_object('storeId',v_store,'warehouseId',v_warehouse,'customerId',v_customer,
      'selectedPricelistId',NULL,'orderDate',v_period_date,
      'plannedDeliveryDate',v_period_date,'isTempo',false,'currencyCode','IDR',
      'globalDiscount',0,'roundingDirection','NONE','roundingIncrement',100,
      'lines',jsonb_build_array(jsonb_build_object('productUomId',v_product_uom,
        'quantity',2,'overrideUnitPrice',100000))));
  v_order:=(v_created->'data'->>'id')::uuid;
  v_confirmed:=public.confirm_backoffice_sales_order(v_order,
    (v_created->'data'->>'masterVersion')::bigint,gen_random_uuid());
  SELECT line.id INTO v_order_line FROM public.backoffice_sales_order_lines line
  WHERE line.company_id=v_company AND line.sales_order_id=v_order AND line.product_id=v_product;
  IF v_order_line IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: canonical Sales Order line missing';
  END IF;
  -- The current public Invoice gate requires a completed Customer Receipt.
  -- Exercise the real DO chain instead of fabricating acceptance counters.
  v_delivery:=(v_confirmed->'fulfillment'->>'deliveryOrderId')::uuid;
  SELECT line.id INTO STRICT v_delivery_line
  FROM public.backoffice_sales_delivery_order_lines line
  WHERE line.company_id=v_company AND line.delivery_order_id=v_delivery;
  SELECT master_version INTO STRICT v_delivery_version
  FROM public.backoffice_sales_delivery_orders
  WHERE company_id=v_company AND id=v_delivery;
  PERFORM public.dispatch_backoffice_sales_delivery(v_delivery,v_delivery_version,
    gen_random_uuid(),jsonb_build_array(jsonb_build_object(
      'deliveryLineId',v_delivery_line,'quantityUom',2)),
    'Rollback-only Invoice posting regression preparation');
  SELECT master_version INTO STRICT v_delivery_version
  FROM public.backoffice_sales_delivery_orders
  WHERE company_id=v_company AND id=v_delivery;
  v_receipt:=public.receive_backoffice_sales_delivery(v_delivery,v_delivery_version,
    gen_random_uuid(),v_period_date,'Rollback-only Invoice posting regression preparation');
  IF v_receipt->>'deliveryStatus' IS DISTINCT FROM 'COMPLETED' THEN
    RAISE EXCEPTION 'TEST_FAILED: canonical Customer Receipt did not complete';
  END IF;
  -- Receipt may create its own COGS event. Count Invoice-only effects afterward.
  SELECT count(*) INTO v_event_before FROM public.financial_events;
  SELECT count(*) INTO v_journal_before FROM public.finance_journals;

  v_dp:=public.save_backoffice_sales_invoice_draft(NULL,NULL,gen_random_uuid(),v_order,
    jsonb_build_object('invoiceType','DOWN_PAYMENT','invoiceDate',v_period_date,
      'downPaymentMode','PERCENT','downPaymentInput',40));
  v_dp_id:=(v_dp->'data'->>'id')::uuid;
  INSERT INTO public.user_company_permission_overrides AS current_override(company_id,user_id,
    permission_key,restriction_preset,created_by,updated_by)
  VALUES(v_company,v_actor,'finance.journals_reports','TANPA_AKSES',v_actor,v_actor)
  ON CONFLICT(company_id,user_id,permission_key) DO UPDATE
    SET restriction_preset='TANPA_AKSES',updated_by=excluded.updated_by,
      master_version=current_override.master_version+1,
      updated_at=clock_timestamp();
  v_blocked:=false;
  BEGIN
    PERFORM public.post_backoffice_sales_invoice(v_dp_id,
      (v_dp->'data'->>'masterVersion')::bigint,gen_random_uuid());
  EXCEPTION WHEN OTHERS THEN v_blocked:=SQLERRM LIKE '%CUSTOM_PERMISSION_DENIED%'; END;
  IF NOT v_blocked THEN
    RAISE EXCEPTION 'TEST_FAILED: custom Finance denial did not block Invoice posting';
  END IF;
  DELETE FROM public.user_company_permission_overrides override_state
  WHERE override_state.company_id=v_company AND override_state.user_id=v_actor
    AND override_state.permission_key='finance.journals_reports';
  v_blocked:=false;
  BEGIN
    PERFORM public.post_backoffice_sales_invoice(v_dp_id,
      (v_dp->'data'->>'masterVersion')::bigint+1,gen_random_uuid());
  EXCEPTION WHEN OTHERS THEN v_blocked:=SQLERRM LIKE '%MASTER_VERSION_CONFLICT%'; END;
  IF NOT v_blocked THEN RAISE EXCEPTION 'TEST_FAILED: stale DP posting was accepted'; END IF;
  v_dp_posted:=public.post_backoffice_sales_invoice(v_dp_id,
    (v_dp->'data'->>'masterVersion')::bigint,gen_random_uuid());
  IF v_dp_posted->'data'->>'status'<>'POSTED'
    OR v_dp_posted->'data'->>'invoiceNo' NOT LIKE 'INV-'||to_char(v_period_date,'YYYYMMDD')||'-%'
    OR v_dp_posted->'finance'->>'status'<>'POSTED' THEN
    RAISE EXCEPTION 'TEST_FAILED: DP Invoice was not posted canonically';
  END IF;
  SELECT dp.grand_total INTO v_dp_total FROM public.backoffice_sales_invoices dp
  WHERE dp.company_id=v_company AND dp.id=v_dp_id;

  v_regular:=public.save_backoffice_sales_invoice_draft(NULL,NULL,gen_random_uuid(),v_order,
    jsonb_build_object('invoiceType','REGULAR','invoiceDate',v_period_date,
      'lines',jsonb_build_array(jsonb_build_object('salesOrderLineId',v_order_line,
        'quantityUom',2,'unitPrice',100000))));
  v_regular_id:=(v_regular->'data'->>'id')::uuid;
  IF (v_regular->'data'->>'downPaymentDeductionTotal')::numeric<>v_dp_total
    OR jsonb_array_length(v_regular->'data'->'downPaymentApplications')<>1 THEN
    RAISE EXCEPTION 'TEST_FAILED: posted DP was not auto-filled on Regular Draft';
  END IF;
  v_manual_amount:=round(v_dp_total/2,4);
  v_adjusted:=public.set_backoffice_sales_invoice_down_payments(v_regular_id,
    (v_regular->'data'->>'masterVersion')::bigint,gen_random_uuid(),
    jsonb_build_array(jsonb_build_object('downPaymentInvoiceId',v_dp_id,
      'appliedAmount',v_manual_amount)));
  IF (v_adjusted->'data'->>'downPaymentDeductionTotal')::numeric<>v_manual_amount
    OR (SELECT round(sum(application.applied_basis_amount+application.applied_tax_amount),4)
      FROM public.backoffice_sales_down_payment_applications application
      WHERE application.company_id=v_company AND application.regular_invoice_id=v_regular_id
        AND application.status='HELD')<>v_manual_amount
    OR (SELECT round(sum(tax.applied_tax_amount),4)
      FROM public.backoffice_sales_down_payment_application_tax_breakdowns tax
      JOIN public.backoffice_sales_down_payment_applications application
        ON application.company_id=tax.company_id AND application.id=tax.application_id
      WHERE tax.company_id=v_company AND application.regular_invoice_id=v_regular_id)
      <>round((SELECT sum(application.applied_tax_amount)
        FROM public.backoffice_sales_down_payment_applications application
        WHERE application.company_id=v_company
          AND application.regular_invoice_id=v_regular_id),4) THEN
    RAISE EXCEPTION 'TEST_FAILED: editable DP split or tax lineage invalid';
  END IF;
  v_regular_posted:=public.post_backoffice_sales_invoice(v_regular_id,
    (v_adjusted->'data'->>'masterVersion')::bigint,gen_random_uuid());
  IF v_regular_posted->'data'->>'status'<>'POSTED'
    OR (SELECT draft_invoice_allocated_base_qty FROM public.backoffice_sales_order_lines
      WHERE company_id=v_company AND id=v_order_line)<>0
    OR (SELECT invoiced_base_qty FROM public.backoffice_sales_order_lines
      WHERE company_id=v_company AND id=v_order_line)<>2*v_factor
    OR EXISTS(SELECT 1 FROM public.backoffice_sales_invoice_quantity_allocations allocation
      WHERE allocation.company_id=v_company AND allocation.invoice_id=v_regular_id
        AND allocation.status<>'POSTED')
    OR EXISTS(SELECT 1 FROM public.backoffice_sales_down_payment_applications application
      WHERE application.company_id=v_company AND application.regular_invoice_id=v_regular_id
        AND application.status<>'POSTED') THEN
    RAISE EXCEPTION 'TEST_FAILED: Regular posting final state invalid';
  END IF;
  SELECT journal.* INTO v_journal FROM public.finance_journals journal
  WHERE journal.company_id=v_company
    AND journal.id=(v_regular_posted->'finance'->>'journalId')::uuid;
  IF v_journal.status<>'POSTED' OR round(v_journal.total_debit,4)<>round(v_journal.total_credit,4)
    OR NOT EXISTS(SELECT 1 FROM public.finance_journal_lines line
      WHERE line.company_id=v_company AND line.journal_id=v_journal.id
        AND line.account_id=v_tax_account AND line.debit>0)
    OR NOT EXISTS(SELECT 1 FROM public.finance_journal_lines line
      WHERE line.company_id=v_company AND line.journal_id=v_journal.id
        AND line.account_id=v_tax_account AND line.credit>0) THEN
    RAISE EXCEPTION 'TEST_FAILED: balanced explicit DP tax debit/current tax credit missing';
  END IF;
  v_retry:=public.post_backoffice_sales_invoice(v_regular_id,
    (v_adjusted->'data'->>'masterVersion')::bigint,
    (SELECT operation.operation_id FROM public.backoffice_sales_invoice_operations operation
      WHERE operation.company_id=v_company AND operation.invoice_id=v_regular_id
        AND operation.operation_type='POST'));
  IF COALESCE((v_retry->>'exactRetry')::boolean,false) IS NOT TRUE
    OR (SELECT count(*) FROM public.finance_journals journal
      WHERE journal.company_id=v_company AND journal.financial_event_id=
        (v_regular_posted->'data'->>'financialEventId')::uuid)<>1 THEN
    RAISE EXCEPTION 'TEST_FAILED: exact retry duplicated posting';
  END IF;
  IF (SELECT count(*) FROM public.sales_headers)<>v_sales_before THEN
    RAISE EXCEPTION 'TEST_FAILED: Backoffice posting changed POS Sales';
  END IF;
  IF (SELECT count(*) FROM public.financial_events)<>v_event_before+2
    OR (SELECT count(*) FROM public.finance_journals)<>v_journal_before+2 THEN
    RAISE EXCEPTION 'TEST_FAILED: Invoice posting effect count invalid';
  END IF;
  UPDATE public.warehouses SET allow_negative_stock=v_original_negative
  WHERE company_id=v_company AND id=v_warehouse;
END
$test$;
ROLLBACK;
SELECT 'backoffice_sales_invoice_posting_runtime_behavior' check_name,'PASS' status,
  0::bigint violation_rows,jsonb_build_object('tested',ARRAY[
    'canonical taxed SO preparation','stale posting denial','DP Invoice posting',
    'local strict Finance role and custom override denial',
    'shared canonical Invoice numbering','auto oldest available DP application',
    'editable DP application','DP basis and per-account tax lineage',
    'Regular quantity hold finalization','balanced AR Advance Revenue and tax journal',
    'explicit DP tax debit and current Invoice tax credit','exact posting retry',
    'POS Sales unchanged','all fixture writes rolled back']) details;
