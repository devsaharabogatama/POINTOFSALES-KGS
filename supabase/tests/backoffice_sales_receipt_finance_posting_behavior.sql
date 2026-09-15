-- Authenticated rollback-only behavior for Backoffice Customer receipt Finance posting.
BEGIN;
DO $test$
DECLARE
  v_actor uuid;v_company uuid;v_other_company uuid;v_store uuid;v_warehouse uuid;
  v_customer uuid;v_product_uom uuid;v_product uuid;v_today date;
  v_original_negative boolean;v_stock numeric;v_topup numeric;
  v_batch uuid:=gen_random_uuid();v_fixture_movement uuid:=gen_random_uuid();
  v_created jsonb;v_confirmed jsonb;v_dispatched jsonb;v_received jsonb;
  v_posted jsonb;v_retry jsonb;v_payload jsonb;
  v_order uuid;v_delivery uuid;v_delivery_line uuid;v_event uuid;v_version bigint;
  v_journal uuid;v_cost numeric;v_operation uuid:=gen_random_uuid();
  v_failed boolean:=false;v_invoice_before bigint;v_payment_before bigint;
  v_period uuid;v_period_start date;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260909155000') THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: receipt Finance posting required';
  END IF;
  SELECT profile.id INTO v_actor
  FROM auth.users user_row
  JOIN public.profiles profile ON profile.id=user_row.id
    AND profile.role='super_admin'::public.user_role
  ORDER BY profile.id LIMIT 1;
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: linked Super Admin profile missing';
  END IF;
  SELECT company.id,store.id,warehouse.id,warehouse.allow_negative_stock,
    customer.id,product_uom.id,product_uom.product_id,
    (clock_timestamp() AT TIME ZONE company.timezone)::date
  INTO v_company,v_store,v_warehouse,v_original_negative,v_customer,
    v_product_uom,v_product,v_today
  FROM public.companies company
  JOIN public.stores store ON store.company_id=company.id AND store.status='ACTIVE'
  JOIN public.warehouses warehouse ON warehouse.company_id=company.id
    AND warehouse.is_active AND warehouse.is_sale_source
    AND (warehouse.store_id IS NULL OR warehouse.store_id=store.id)
  JOIN public.customers customer ON customer.company_id=company.id AND customer.is_active
  JOIN public.product_uoms product_uom ON product_uom.company_id=company.id
    AND product_uom.is_active AND product_uom.sales_allowed AND product_uom.factor_to_base=1
  JOIN public.products product ON product.company_id=product_uom.company_id
    AND product.id=product_uom.product_id AND product.is_active AND NOT product.is_bundle
    AND product.uom_id=product_uom.uom_id
  WHERE company.status='ACTIVE'
    AND EXISTS(SELECT 1 FROM public.transaction_categories category
      WHERE category.company_id=company.id AND category.system_key='STOCK_TRANSFER'
        AND category.is_active AND category.is_system_default)
    AND (SELECT count(DISTINCT rule.account_function_key)
      FROM public.transaction_categories category
      JOIN public.transaction_account_rules rule ON rule.company_id=category.company_id
       AND rule.transaction_category_id=category.id AND rule.status='ACTIVE'
      WHERE category.company_id=company.id
        AND category.system_key='BACKOFFICE_CUSTOMER_RECEIPT' AND category.is_active
        AND rule.account_function_key IN('COGS','INVENTORY_ASSET'))=2
  ORDER BY company.id,store.id,warehouse.id,customer.is_system_customer DESC,
    customer.id,product_uom.id LIMIT 1;
  IF v_company IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: canonical receipt fixture candidate missing';
  END IF;
  SELECT id INTO v_other_company FROM public.companies
  WHERE status='ACTIVE' AND id<>v_company ORDER BY id LIMIT 1;

  PERFORM set_config('request.jwt.claim.sub',v_actor::text,true);
  INSERT INTO public.user_active_company_contexts(user_id,company_id)
  VALUES(v_actor,v_company) ON CONFLICT(user_id) DO UPDATE
    SET company_id=excluded.company_id,selected_at=clock_timestamp(),updated_at=clock_timestamp();
  INSERT INTO public.company_features(company_id,feature_code,is_enabled,config,updated_by)
  VALUES(v_company,'backoffice_delivered_qty_sales_enabled',true,'{}',v_actor)
  ON CONFLICT(company_id,feature_code) DO UPDATE SET is_enabled=true,updated_by=excluded.updated_by;
  UPDATE public.warehouses SET allow_negative_stock=true
  WHERE company_id=v_company AND id=v_warehouse;

  SELECT period.id INTO v_period FROM public.accounting_periods period
  WHERE period.company_id=v_company AND period.status IN('OPEN','REOPENED')
    AND period.end_date>=v_today
  ORDER BY period.start_date LIMIT 1;
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

  SELECT COALESCE(stock.stock_qty,0) INTO v_stock FROM public.product_stocks stock
  WHERE stock.company_id=v_company AND stock.warehouse_id=v_warehouse
    AND stock.product_id=v_product;
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
  SELECT stock.stock_qty INTO STRICT v_stock FROM public.product_stocks stock
  WHERE stock.company_id=v_company AND stock.warehouse_id=v_warehouse
    AND stock.product_id=v_product;
  INSERT INTO public.stock_movements(id,product_id,warehouse_id,qty_change,
    movement_type,reference_table,reference_id,company_id,base_uom_id,
    base_uom_name_snapshot,balance_after_base_qty,actor_id,posted_at,
    movement_status,source_line_id,notes)
  SELECT v_fixture_movement,v_product,v_warehouse,v_topup,
    'PURCHASE'::public.stock_movement_type,'BACKOFFICE_RECEIPT_FINANCE_TEST',v_batch,
    v_company,product.uom_id,uom.name,v_stock,v_actor,clock_timestamp(),
    'POSTED',v_batch,'Rollback-only receipt Finance fixture'
  FROM public.products product JOIN public.uoms uom
    ON uom.company_id=product.company_id AND uom.id=product.uom_id
  WHERE product.company_id=v_company AND product.id=v_product;

  SELECT count(*) INTO v_invoice_before FROM public.sales_invoice_snapshots;
  SELECT count(*) INTO v_payment_before FROM public.sales_payment_verification_requests;
  v_payload:=jsonb_build_object('storeId',v_store,'warehouseId',v_warehouse,
    'customerId',v_customer,'selectedPricelistId',NULL,'orderDate',v_today,
    'plannedDeliveryDate',v_today,'isTempo',false,'currencyCode','IDR',
    'globalDiscount',0,'roundingDirection','NONE','roundingIncrement',100,
    'lines',jsonb_build_array(jsonb_build_object('productUomId',v_product_uom,'quantity',4)));
  v_created:=public.save_backoffice_sales_order_draft(NULL,NULL,gen_random_uuid(),v_payload);
  v_order:=(v_created->'data'->>'id')::uuid;
  v_confirmed:=public.confirm_backoffice_sales_order(v_order,
    (v_created->'data'->>'masterVersion')::bigint,gen_random_uuid());
  v_delivery:=(v_confirmed->'fulfillment'->>'deliveryOrderId')::uuid;
  SELECT line.id INTO STRICT v_delivery_line
  FROM public.backoffice_sales_delivery_order_lines line
  WHERE line.company_id=v_company AND line.delivery_order_id=v_delivery;
  SELECT delivery.master_version INTO STRICT v_version
  FROM public.backoffice_sales_delivery_orders delivery
  WHERE delivery.company_id=v_company AND delivery.id=v_delivery;
  v_dispatched:=public.dispatch_backoffice_sales_delivery(v_delivery,v_version,
    gen_random_uuid(),jsonb_build_array(jsonb_build_object(
      'deliveryLineId',v_delivery_line,'quantityUom',4)),'Finance posting fixture');
  SELECT delivery.master_version INTO STRICT v_version
  FROM public.backoffice_sales_delivery_orders delivery
  WHERE delivery.company_id=v_company AND delivery.id=v_delivery;
  v_received:=public.receive_backoffice_sales_delivery(v_delivery,v_version,
    v_operation,v_today,'Finance posting fixture');
  v_event:=(v_received->>'financialEventId')::uuid;
  v_cost:=(v_received->>'fifoCostTotal')::numeric;
  IF v_cost<=0 OR NOT EXISTS(SELECT 1 FROM public.financial_events event
    WHERE event.company_id=v_company AND event.id=v_event AND event.status='HOLD'
      AND private.f4b_financial_event_supported(event)) THEN
    RAISE EXCEPTION 'TEST_FAILED: positive receipt Event not queue-supported';
  END IF;

  IF v_other_company IS NOT NULL THEN
    BEGIN
      PERFORM private.post_financial_event_core(v_other_company,v_event,1,v_actor);
    EXCEPTION WHEN OTHERS THEN v_failed:=SQLERRM LIKE '%FINANCIAL_EVENT_NOT_FOUND%'; END;
    IF NOT v_failed THEN RAISE EXCEPTION 'TEST_FAILED: cross-tenant posting accepted'; END IF;
  END IF;
  v_posted:=private.post_financial_event_core(v_company,v_event,1,v_actor);
  v_journal:=(v_posted->>'journalId')::uuid;
  IF v_posted->>'status'<>'POSTED' OR COALESCE((v_posted->>'idempotentReplay')::boolean,true)
    OR (v_posted->>'originalEventDate')::date<>v_today THEN
    RAISE EXCEPTION 'TEST_FAILED: first posting result invalid %',v_posted;
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.finance_journals journal
      WHERE journal.company_id=v_company AND journal.id=v_journal
        AND journal.status='POSTED' AND journal.financial_event_id=v_event
        AND journal.source_type='backoffice_sales_delivery_receipts'
        AND journal.original_event_date=v_today
        AND round(journal.total_debit,4)=round(v_cost,4)
        AND round(journal.total_credit,4)=round(v_cost,4))
    OR (SELECT count(*) FROM public.finance_journal_lines line
      WHERE line.company_id=v_company AND line.journal_id=v_journal)<>2
    OR NOT EXISTS(SELECT 1 FROM public.finance_journal_lines line
      WHERE line.company_id=v_company AND line.journal_id=v_journal
        AND line.description='COGS' AND round(line.debit,4)=round(v_cost,4))
    OR NOT EXISTS(SELECT 1 FROM public.finance_journal_lines line
      WHERE line.company_id=v_company AND line.journal_id=v_journal
        AND line.description='INVENTORY_ASSET' AND round(line.credit,4)=round(v_cost,4)) THEN
    RAISE EXCEPTION 'TEST_FAILED: receipt Journal reconciliation invalid';
  END IF;
  v_retry:=private.post_financial_event_core(v_company,v_event,1,v_actor);
  IF COALESCE((v_retry->>'idempotentReplay')::boolean,false) IS NOT TRUE
    OR v_retry->>'journalId'<>v_journal::text THEN
    RAISE EXCEPTION 'TEST_FAILED: exact retry changed Journal identity';
  END IF;
  v_failed:=false;
  BEGIN
    PERFORM private.post_financial_event_core(v_company,v_event,2,v_actor);
  EXCEPTION WHEN OTHERS THEN v_failed:=SQLERRM LIKE '%EVENT_VERSION_CONFLICT%'; END;
  IF NOT v_failed THEN RAISE EXCEPTION 'TEST_FAILED: stale Event version accepted'; END IF;
  IF (SELECT count(*) FROM public.sales_invoice_snapshots)<>v_invoice_before
    OR (SELECT count(*) FROM public.sales_payment_verification_requests)<>v_payment_before THEN
    RAISE EXCEPTION 'TEST_FAILED: Finance posting created Invoice or Payment effect';
  END IF;
  UPDATE public.warehouses SET allow_negative_stock=v_original_negative
  WHERE company_id=v_company AND id=v_warehouse;
END
$test$;
ROLLBACK;
SELECT 'backoffice_sales_receipt_finance_posting_behavior' check_name,'PASS' status,
  0::bigint violation_rows,jsonb_build_object('tested',ARRAY[
    'canonical Backoffice SO through Customer receipt','queue support on HOLD Event',
    'cross-tenant denial','accepted-date accounting authority','Dr COGS',
    'Cr Transit Inventory','balanced two-line Journal','exact retry same Journal',
    'stale version denial','zero Invoice and Payment effect','all fixture writes rolled back']) details;
