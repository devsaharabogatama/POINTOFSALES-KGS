-- Authenticated rollback-only behavior for Step 5/6.2.
BEGIN;
DO $test$
DECLARE
  v_actor uuid;v_company uuid;v_other_company uuid;v_store uuid;v_warehouse uuid;
  v_customer uuid;v_customer_category uuid;v_product_uom uuid;v_product uuid;
  v_today date;v_original_negative boolean;v_fixture_code text;
  v_stock numeric;v_topup numeric;v_batch uuid:=gen_random_uuid();
  v_period uuid;v_period_start date;v_created jsonb;v_confirmed jsonb;
  v_dispatched jsonb;v_received jsonb;v_resolved jsonb;v_posted jsonb;v_retry jsonb;
  v_order uuid;v_delivery uuid;v_delivery_line uuid;v_discrepancy uuid;
  v_discrepancy_line uuid;v_event uuid;v_effect uuid;v_journal uuid;
  v_version bigint;v_cost numeric;v_failed boolean:=false;
  v_movement_before bigint;v_invoice_before bigint;v_payment_before bigint;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260912136000') THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: Step 5/6.2 movement-type forward-fix required';
  END IF;
  SELECT profile.id INTO v_actor FROM public.profiles profile
  JOIN auth.users actor ON actor.id=profile.id
  WHERE profile.role='super_admin'::public.user_role ORDER BY profile.id LIMIT 1;
  SELECT company.id,store.id,warehouse.id,warehouse.allow_negative_stock,
    product_uom.id,product_uom.product_id,
    (clock_timestamp() AT TIME ZONE company.timezone)::date
  INTO v_company,v_store,v_warehouse,v_original_negative,
    v_product_uom,v_product,v_today
  FROM public.companies company
  JOIN public.stores store ON store.company_id=company.id AND store.status='ACTIVE'
  JOIN public.warehouses warehouse ON warehouse.company_id=company.id
    AND warehouse.is_active AND warehouse.is_sale_source
    AND (warehouse.store_id IS NULL OR warehouse.store_id=store.id)
  JOIN public.product_uoms product_uom ON product_uom.company_id=company.id
    AND product_uom.is_active AND product_uom.sales_allowed
    AND product_uom.factor_to_base=1
  JOIN public.products product ON product.company_id=product_uom.company_id
    AND product.id=product_uom.product_id AND product.is_active
    AND NOT product.is_bundle AND product.uom_id=product_uom.uom_id
  WHERE company.status='ACTIVE'
    AND EXISTS(SELECT 1 FROM public.transaction_categories category
      WHERE category.company_id=company.id AND category.system_key='STOCK_TRANSFER'
        AND category.is_active AND category.is_system_default)
    AND (SELECT count(DISTINCT rule.account_function_key)
      FROM public.transaction_categories category
      JOIN public.transaction_account_rules rule ON rule.company_id=category.company_id
       AND rule.transaction_category_id=category.id AND rule.status='ACTIVE'
      WHERE category.company_id=company.id AND category.system_key='STOCK_LOSS'
        AND category.is_active
        AND rule.account_function_key IN('STOCK_LOSS_EXPENSE','INVENTORY_ASSET'))=2
    AND (SELECT count(*) FROM public.transaction_categories category
      JOIN public.posting_rule_sets rule_set ON rule_set.company_id=category.company_id
       AND rule_set.transaction_category_id=category.id
      WHERE category.company_id=company.id AND category.system_key='STOCK_LOSS'
        AND rule_set.system_key='STOCK_LOSS' AND rule_set.status='APPROVED'
        AND rule_set.effective_from<=clock_timestamp()
        AND (rule_set.effective_to IS NULL OR rule_set.effective_to>clock_timestamp()))=1
    AND (SELECT count(DISTINCT rule.account_function_key)
      FROM public.transaction_categories category
      JOIN public.transaction_account_rules rule ON rule.company_id=category.company_id
       AND rule.transaction_category_id=category.id AND rule.status='ACTIVE'
      WHERE category.company_id=company.id
        AND category.system_key='BACKOFFICE_CUSTOMER_RECEIPT'
        AND rule.account_function_key IN('COGS','INVENTORY_ASSET'))=2
  ORDER BY company.id,store.id,warehouse.id,product_uom.id LIMIT 1;
  IF v_actor IS NULL OR v_company IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: canonical Stock Loss Finance fixture missing';
  END IF;
  SELECT id INTO v_other_company FROM public.companies
  WHERE status='ACTIVE' AND id<>v_company ORDER BY id LIMIT 1;
  PERFORM set_config('request.jwt.claim.sub',v_actor::text,true);
  INSERT INTO public.user_active_company_contexts(user_id,company_id)
  VALUES(v_actor,v_company) ON CONFLICT(user_id) DO UPDATE
    SET company_id=excluded.company_id,selected_at=clock_timestamp(),updated_at=clock_timestamp();
  INSERT INTO public.company_features(company_id,feature_code,is_enabled,config,updated_by)
  VALUES(v_company,'backoffice_delivered_qty_sales_enabled',true,'{}'::jsonb,v_actor)
  ON CONFLICT(company_id,feature_code) DO UPDATE SET is_enabled=true,updated_by=excluded.updated_by;
  -- Rollback-only Company mode setup; runtime guards stay active for RPCs.
  PERFORM pg_advisory_xact_lock(hashtextextended(v_company::text,20260911130000));
  PERFORM set_config('kgs.sales_process_cutover_mutation','1',true);
  UPDATE public.company_sales_process_settings SET
    active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE',mode_effective_at='-infinity',
    master_version=master_version+1,updated_by=v_actor,updated_at=clock_timestamp()
  WHERE company_id=v_company;
  IF NOT FOUND THEN RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: Company mode setting required'; END IF;
  PERFORM set_config('kgs.sales_process_cutover_mutation','',true);
  PERFORM private.assert_sales_process_root_creation_allowed(v_company,'BACKOFFICE_DELIVERED_QTY_INVOICE');
  UPDATE public.warehouses SET allow_negative_stock=true
  WHERE company_id=v_company AND id=v_warehouse;

  SELECT customer.id INTO v_customer FROM public.customers customer
  WHERE customer.company_id=v_company AND customer.is_active
    AND NOT customer.is_system_customer ORDER BY customer.id LIMIT 1;
  IF v_customer IS NULL THEN
    SELECT category.id INTO v_customer_category FROM public.customer_categories category
    WHERE category.company_id=v_company AND category.is_active
    ORDER BY category.is_system_category DESC,category.id LIMIT 1;
    IF v_customer_category IS NULL THEN
      RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: active Customer Category required';
    END IF;
    v_fixture_code:='S52-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,12));
    v_created:=public.save_customer_with_pricelist(NULL,NULL,v_fixture_code,
      'Step 5.2 Rollback Customer',v_customer_category,NULL,NULL,NULL,
      'BUSINESS',0,NULL,'Rollback-only Stock Loss Finance fixture',TRUE,NULL,NULL);
    v_customer:=(v_created->>'customerId')::uuid;
  END IF;

  SELECT period.id INTO v_period FROM public.accounting_periods period
  WHERE period.company_id=v_company AND period.status IN('OPEN','REOPENED')
    AND period.end_date>=v_today ORDER BY period.start_date LIMIT 1;
  IF v_period IS NULL THEN
    SELECT candidate.month_start::date INTO v_period_start
    FROM generate_series(date_trunc('month',v_today::timestamp),
      date_trunc('month',v_today::timestamp)+interval '10 years',interval '1 month')
      candidate(month_start)
    WHERE NOT EXISTS(SELECT 1 FROM public.accounting_periods period
      WHERE period.company_id=v_company
        AND daterange(period.start_date,period.end_date,'[]') && daterange(
          candidate.month_start::date,
          (candidate.month_start+interval '1 month'-interval '1 day')::date,'[]'))
    ORDER BY candidate.month_start LIMIT 1;
    IF v_period_start IS NULL THEN
      RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: no free accounting month for rollback fixture';
    END IF;
    INSERT INTO public.accounting_periods(company_id,period_year,period_month,
      start_date,end_date,status,created_by,updated_by)
    VALUES(v_company,extract(year FROM v_period_start)::integer,
      extract(month FROM v_period_start)::integer,v_period_start,
      (v_period_start+interval '1 month'-interval '1 day')::date,'OPEN',v_actor,v_actor)
    RETURNING id INTO v_period;
  END IF;

  SELECT COALESCE(stock_qty,0) INTO v_stock FROM public.product_stocks
  WHERE company_id=v_company AND warehouse_id=v_warehouse AND product_id=v_product;
  v_stock:=COALESCE(v_stock,0);v_topup:=CASE WHEN v_stock<10 THEN 10-v_stock ELSE 10 END;
  INSERT INTO public.product_stocks(product_id,warehouse_id,stock_qty,company_id)
  VALUES(v_product,v_warehouse,v_topup,v_company)
  ON CONFLICT(product_id,warehouse_id) DO UPDATE SET
    stock_qty=public.product_stocks.stock_qty+excluded.stock_qty,updated_at=clock_timestamp();
  INSERT INTO public.product_batches(id,product_id,warehouse_id,qty_purchased,
    qty_remaining,cogs_unit,company_id)
  SELECT v_batch,v_product,v_warehouse,v_topup,v_topup,
    GREATEST(COALESCE(product.cogs,1),1),v_company
  FROM public.products product WHERE product.company_id=v_company AND product.id=v_product;

  v_created:=public.save_backoffice_sales_order_draft(NULL,NULL,gen_random_uuid(),
    jsonb_build_object('storeId',v_store,'warehouseId',v_warehouse,
      'customerId',v_customer,'selectedPricelistId',NULL,'orderDate',v_today,
      'plannedDeliveryDate',v_today,'isTempo',false,'currencyCode','IDR',
      'globalDiscount',0,'roundingDirection','NONE','roundingIncrement',100,
      'lines',jsonb_build_array(jsonb_build_object('productUomId',v_product_uom,
        'quantity',2,'overrideUnitPrice',50000))));
  v_order:=(v_created->'data'->>'id')::uuid;
  v_confirmed:=public.confirm_backoffice_sales_order(v_order,
    (v_created->'data'->>'masterVersion')::bigint,gen_random_uuid());
  v_delivery:=(v_confirmed->'fulfillment'->>'deliveryOrderId')::uuid;
  SELECT id INTO STRICT v_delivery_line
  FROM public.backoffice_sales_delivery_order_lines
  WHERE company_id=v_company AND delivery_order_id=v_delivery;
  SELECT master_version INTO STRICT v_version FROM public.backoffice_sales_delivery_orders
  WHERE company_id=v_company AND id=v_delivery;
  v_dispatched:=public.dispatch_backoffice_sales_delivery(v_delivery,v_version,gen_random_uuid(),
    jsonb_build_array(jsonb_build_object('deliveryLineId',v_delivery_line,
      'quantityUom',2)),'Step 5.2 rollback Dispatch');
  SELECT master_version INTO STRICT v_version FROM public.backoffice_sales_delivery_orders
  WHERE company_id=v_company AND id=v_delivery;
  v_received:=public.receive_backoffice_sales_delivery(v_delivery,v_version,
    gen_random_uuid(),v_today,jsonb_build_array(jsonb_build_object(
      'deliveryLineId',v_delivery_line,'acceptedBaseQty',1,'discrepancies',
      jsonb_build_array(jsonb_build_object('discrepancyType','SHORT',
        'requestedResolution','ACCEPT_SHORT','physicalState','LOST','quantityBase',1,
        'reason','Step 5.2 rollback loss')))),'Step 5.2 mixed receipt');
  v_discrepancy:=(v_received->>'discrepancyId')::uuid;
  SELECT id INTO STRICT v_discrepancy_line
  FROM public.backoffice_sales_delivery_discrepancy_lines
  WHERE company_id=v_company AND discrepancy_id=v_discrepancy
    AND discrepancy_type='SHORT' AND physical_state='LOST';
  SELECT master_version INTO STRICT v_version
  FROM public.backoffice_sales_delivery_discrepancies
  WHERE company_id=v_company AND id=v_discrepancy;
  v_resolved:=public.resolve_backoffice_sales_shortage(v_discrepancy,v_version,
    gen_random_uuid(),NULL,'Step 5.2 Warehouse LOST resolution');
  IF v_resolved->>'status'<>'RESOLVED' THEN
    RAISE EXCEPTION 'TEST_FAILED: LOST shortage did not resolve %',v_resolved;
  END IF;
  SELECT event.id,effect.id,effect.total_cost INTO STRICT v_event,v_effect,v_cost
  FROM public.backoffice_sales_discrepancy_stock_effects effect
  JOIN public.financial_events event ON event.company_id=effect.company_id
    AND event.id=effect.financial_event_id
  WHERE effect.company_id=v_company AND effect.discrepancy_line_id=v_discrepancy_line
    AND effect.effect_type='EXPECTED_WRITE_OFF';
  IF v_cost<=0 OR NOT EXISTS(SELECT 1 FROM public.financial_events event
    WHERE event.company_id=v_company AND event.id=v_event AND event.status='HOLD'
      AND event.system_event_key='STOCK_LOSS'
      AND event.source_table='backoffice_sales_discrepancy_stock_effects'
      AND private.f4b_financial_event_supported(event)) THEN
    RAISE EXCEPTION 'TEST_FAILED: discrepancy Stock Loss HOLD Event not queue-supported';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.stock_movements movement
    WHERE movement.company_id=v_company AND movement.id=(SELECT effect.source_stock_movement_id
      FROM public.backoffice_sales_discrepancy_stock_effects effect
      WHERE effect.company_id=v_company AND effect.id=v_effect)
      AND movement.movement_type='BACKOFFICE_DISCREPANCY_LOSS'::public.stock_movement_type
      AND movement.reference_table='backoffice_sales_discrepancy_stock_effects'
      AND movement.reference_id=v_effect AND movement.source_line_id=v_discrepancy_line
      AND round(movement.qty_change,6)=-1) THEN
    RAISE EXCEPTION 'TEST_FAILED: discrepancy loss Stock Movement identity invalid';
  END IF;

  SELECT count(*) INTO v_movement_before FROM public.stock_movements;
  SELECT count(*) INTO v_invoice_before FROM public.backoffice_sales_invoices;
  SELECT count(*) INTO v_payment_before FROM public.customer_receipt_documents;
  IF v_other_company IS NOT NULL THEN
    BEGIN
      PERFORM private.post_financial_event_core(v_other_company,v_event,1,v_actor);
    EXCEPTION WHEN OTHERS THEN v_failed:=SQLERRM LIKE '%FINANCIAL_EVENT_NOT_FOUND%'; END;
    IF NOT v_failed THEN RAISE EXCEPTION 'TEST_FAILED: cross-tenant posting accepted'; END IF;
  END IF;
  v_posted:=private.post_financial_event_core(v_company,v_event,1,v_actor);
  v_journal:=(v_posted->>'journalId')::uuid;
  IF v_posted->>'status'<>'POSTED'
    OR COALESCE((v_posted->>'idempotentReplay')::boolean,true)
    OR v_posted->>'physicalState'<>'LOST' THEN
    RAISE EXCEPTION 'TEST_FAILED: first discrepancy Stock Loss posting invalid %',v_posted;
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.finance_journals journal
      WHERE journal.company_id=v_company AND journal.id=v_journal
        AND journal.financial_event_id=v_event AND journal.status='POSTED'
        AND journal.source_type='backoffice_sales_discrepancy_stock_effects'
        AND journal.source_id=v_effect AND round(journal.total_debit,4)=round(v_cost,4)
        AND round(journal.total_credit,4)=round(v_cost,4))
    OR (SELECT count(*) FROM public.finance_journal_lines line
      WHERE line.company_id=v_company AND line.journal_id=v_journal)<>2
    OR NOT EXISTS(SELECT 1 FROM public.finance_journal_lines line
      WHERE line.company_id=v_company AND line.journal_id=v_journal
        AND line.description='STOCK_LOSS_EXPENSE - LOST'
        AND round(line.debit,4)=round(v_cost,4))
    OR NOT EXISTS(SELECT 1 FROM public.finance_journal_lines line
      WHERE line.company_id=v_company AND line.journal_id=v_journal
        AND line.description='INVENTORY_ASSET - LOST'
        AND round(line.credit,4)=round(v_cost,4)) THEN
    RAISE EXCEPTION 'TEST_FAILED: discrepancy Stock Loss Journal reconciliation invalid';
  END IF;
  v_retry:=private.post_financial_event_core(v_company,v_event,1,v_actor);
  IF COALESCE((v_retry->>'idempotentReplay')::boolean,false) IS NOT TRUE
    OR v_retry->>'journalId'<>v_journal::text THEN
    RAISE EXCEPTION 'TEST_FAILED: exact retry changed discrepancy Stock Loss Journal';
  END IF;
  v_failed:=false;
  BEGIN
    PERFORM private.post_financial_event_core(v_company,v_event,2,v_actor);
  EXCEPTION WHEN OTHERS THEN v_failed:=SQLERRM LIKE '%EVENT_VERSION_CONFLICT%'; END;
  IF NOT v_failed THEN RAISE EXCEPTION 'TEST_FAILED: stale Event version accepted'; END IF;
  IF (SELECT count(*) FROM public.stock_movements)<>v_movement_before
    OR (SELECT count(*) FROM public.backoffice_sales_invoices)<>v_invoice_before
    OR (SELECT count(*) FROM public.customer_receipt_documents)<>v_payment_before THEN
    RAISE EXCEPTION 'TEST_FAILED: Finance posting created Stock, Invoice, or Payment effect';
  END IF;
  UPDATE public.warehouses SET allow_negative_stock=v_original_negative
  WHERE company_id=v_company AND id=v_warehouse;
END
$test$;
ROLLBACK;
SELECT 'backoffice_sales_discrepancy_stock_loss_finance_posting_behavior' check_name,
  'PASS' status,0::bigint violation_rows,jsonb_build_object('tested',ARRAY[
    'canonical SO Dispatch mixed receipt LOST resolution','dedicated discrepancy-loss Movement identity',
    'queue-supported HOLD Event',
    'exact FIFO cost source reconciliation','Dr STOCK_LOSS_EXPENSE','Cr Transit INVENTORY_ASSET',
    'balanced two-line Journal','cross-tenant denial','Company-timezone loss-date authority',
    'exact retry same Journal','stale Event version denial',
    'zero Stock Invoice Payment posting effect','all fixture writes rolled back']) details;
