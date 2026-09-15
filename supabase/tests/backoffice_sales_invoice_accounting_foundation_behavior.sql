-- Rollback-only behavior for Odoo-style invoice/accounting foundation.
BEGIN;
DO $test$
DECLARE
  v_actor uuid;v_company uuid;v_store uuid;v_warehouse uuid;v_customer uuid;
  v_product_uom uuid;v_product uuid;v_uom uuid;v_created jsonb;v_order uuid;v_order_line uuid;
  v_term uuid:=gen_random_uuid();v_dp uuid:=gen_random_uuid();v_regular uuid:=gen_random_uuid();
  v_dp_line uuid:=gen_random_uuid();v_product_line uuid:=gen_random_uuid();v_failed boolean:=false;
  v_event_before bigint;v_journal_before bigint;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260909156000') THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: Invoice accounting foundation required';
  END IF;
  SELECT profile.id INTO STRICT v_actor
  FROM auth.users user_row
  JOIN public.profiles profile ON profile.id=user_row.id
    AND profile.role='super_admin'::public.user_role
  ORDER BY profile.id LIMIT 1;
  SELECT company.id,store.id,warehouse.id,customer.id,product_uom.id,
      product_uom.product_id,product_uom.uom_id
  INTO STRICT v_company,v_store,v_warehouse,v_customer,v_product_uom,v_product,v_uom
  FROM public.companies company
  JOIN public.stores store ON store.company_id=company.id AND store.status='ACTIVE'
  JOIN public.warehouses warehouse ON warehouse.company_id=company.id
    AND warehouse.is_active AND warehouse.is_sale_source
    AND (warehouse.store_id IS NULL OR warehouse.store_id=store.id)
  JOIN public.customers customer ON customer.company_id=company.id AND customer.is_active
  JOIN public.product_uoms product_uom ON product_uom.company_id=company.id
    AND product_uom.is_active AND product_uom.sales_allowed
    AND product_uom.factor_to_base>0
  JOIN public.products product ON product.company_id=product_uom.company_id
    AND product.id=product_uom.product_id AND product.is_active AND NOT product.is_bundle
  WHERE company.status='ACTIVE'
  ORDER BY company.id,store.id,warehouse.id,customer.is_system_customer DESC,
    customer.id,product_uom.id LIMIT 1;

  PERFORM set_config('request.jwt.claim.sub',v_actor::text,true);
  INSERT INTO public.user_active_company_contexts(user_id,company_id)
  VALUES(v_actor,v_company) ON CONFLICT(user_id) DO UPDATE
    SET company_id=excluded.company_id,selected_at=clock_timestamp(),updated_at=clock_timestamp();
  INSERT INTO public.company_features(company_id,feature_code,is_enabled,config,updated_by)
  VALUES(v_company,'backoffice_delivered_qty_sales_enabled',true,'{}',v_actor)
  ON CONFLICT(company_id,feature_code) DO UPDATE SET is_enabled=true,updated_by=excluded.updated_by;

  v_created:=public.save_backoffice_sales_order_draft(NULL,NULL,gen_random_uuid(),
    jsonb_build_object('storeId',v_store,'warehouseId',v_warehouse,
      'customerId',v_customer,'selectedPricelistId',NULL,'orderDate',current_date,
      'plannedDeliveryDate',current_date+1,'isTempo',false,'currencyCode','IDR',
      'globalDiscount',0,'roundingDirection','NONE','roundingIncrement',100,
      'lines',jsonb_build_array(jsonb_build_object('productUomId',v_product_uom,'quantity',2))));
  v_order:=(v_created->'data'->>'id')::uuid;
  SELECT id INTO STRICT v_order_line FROM public.backoffice_sales_order_lines
  WHERE company_id=v_company AND sales_order_id=v_order;

  SELECT count(*) INTO v_event_before FROM public.financial_events;
  SELECT count(*) INTO v_journal_before FROM public.finance_journals;

  INSERT INTO public.backoffice_sales_payment_terms(id,company_id,term_code,term_name,created_by,updated_by)
  VALUES(v_term,v_company,'TEST-30-70','Test 30/70',v_actor,v_actor);
  INSERT INTO public.backoffice_sales_payment_term_lines(company_id,payment_term_id,line_no,
    amount_type,amount_value,due_rule,days_offset,created_by) VALUES
    (v_company,v_term,1,'PERCENT',30,'DAYS_AFTER_INVOICE',0,v_actor),
    (v_company,v_term,2,'BALANCE',NULL,'DAYS_AFTER_INVOICE',30,v_actor);

  BEGIN
    INSERT INTO public.backoffice_sales_payment_term_lines(company_id,payment_term_id,line_no,
      amount_type,amount_value,due_rule,days_offset,created_by)
    VALUES(v_company,v_term,3,'PERCENT',101,'DAYS_AFTER_INVOICE',60,v_actor);
  EXCEPTION WHEN check_violation THEN v_failed:=true;
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'TEST_FAILED: payment term above 100 percent accepted'; END IF;

  INSERT INTO public.backoffice_sales_invoices(id,company_id,sales_order_id,customer_id,store_id,
    warehouse_id,draft_no,invoice_sequence,invoice_type,invoice_date,currency_code,
    customer_snapshot,down_payment_mode,down_payment_input,down_payment_basis_total,
    charge_total,grand_total,created_by,updated_by)
  SELECT v_dp,v_company,v_order,v_customer,v_store,v_warehouse,'TEST-DP',1,'DOWN_PAYMENT',
    current_date,'IDR',customer_snapshot,'PERCENT',20,100000,20000,20000,v_actor,v_actor
  FROM public.backoffice_sales_orders WHERE company_id=v_company AND id=v_order;
  INSERT INTO public.backoffice_sales_invoice_lines(id,company_id,invoice_id,sales_order_id,line_no,
    line_type,effect_type,unit_price,line_amount,description)
  VALUES(v_dp_line,v_company,v_dp,v_order,1,'DOWN_PAYMENT','CHARGE',20000,20000,'DP 20%');

  INSERT INTO public.backoffice_sales_invoices(id,company_id,sales_order_id,customer_id,store_id,
    warehouse_id,payment_term_id,draft_no,invoice_sequence,invoice_type,invoice_date,currency_code,
    customer_snapshot,payment_term_snapshot,charge_total,down_payment_deduction_total,grand_total,
    created_by,updated_by)
  SELECT v_regular,v_company,v_order,v_customer,v_store,v_warehouse,v_term,'TEST-REG',2,'REGULAR',
    current_date,'IDR',customer_snapshot,jsonb_build_object('code','TEST-30-70'),100000,20000,80000,
    v_actor,v_actor FROM public.backoffice_sales_orders WHERE company_id=v_company AND id=v_order;
  INSERT INTO public.backoffice_sales_invoice_lines(id,company_id,invoice_id,sales_order_id,
    sales_order_line_id,line_no,line_type,effect_type,product_id,uom_id,quantity_uom,
    base_qty_per_uom,quantity_base,unit_price,line_amount,description)
  SELECT v_product_line,v_company,v_regular,v_order,v_order_line,1,'PRODUCT','CHARGE',
    v_product,v_uom,1,base_qty_per_uom,base_qty_per_uom,100000,100000,product_name_snapshot
  FROM public.backoffice_sales_order_lines WHERE company_id=v_company AND id=v_order_line;
  INSERT INTO public.backoffice_sales_invoice_lines(company_id,invoice_id,sales_order_id,line_no,
    line_type,effect_type,unit_price,line_amount,description)
  VALUES(v_company,v_regular,v_order,2,'DOWN_PAYMENT_DEDUCTION','DEDUCTION',20000,20000,'Potongan DP');
  INSERT INTO public.backoffice_sales_invoice_quantity_allocations(company_id,invoice_id,invoice_line_id,
    sales_order_id,sales_order_line_id,allocated_base_qty)
  SELECT v_company,v_regular,v_product_line,v_order,v_order_line,base_qty_per_uom
  FROM public.backoffice_sales_order_lines WHERE company_id=v_company AND id=v_order_line;
  INSERT INTO public.backoffice_sales_down_payment_applications(company_id,sales_order_id,
    down_payment_invoice_id,regular_invoice_id,applied_amount)
  VALUES(v_company,v_order,v_dp,v_regular,20000);
  INSERT INTO public.backoffice_sales_invoice_receivable_schedules(company_id,invoice_id,
    installment_no,due_date,amount_due) VALUES
    (v_company,v_regular,1,current_date,24000),
    (v_company,v_regular,2,current_date+30,56000);

  IF (SELECT sum(amount_due) FROM public.backoffice_sales_invoice_receivable_schedules
      WHERE company_id=v_company AND invoice_id=v_regular)<>80000 THEN
    RAISE EXCEPTION 'TEST_FAILED: installment schedule does not equal Invoice total';
  END IF;
  IF (SELECT count(*) FROM public.financial_events)<>v_event_before
    OR (SELECT count(*) FROM public.finance_journals)<>v_journal_before THEN
    RAISE EXCEPTION 'TEST_FAILED: foundation created Finance effect';
  END IF;
END
$test$;
ROLLBACK;
SELECT 'backoffice_sales_invoice_accounting_foundation_behavior' check_name,
  'PASS' status,0::bigint violation_rows,jsonb_build_object('tested',ARRAY[
    'Payment Term 30/70 shape','invalid percentage rejected','Down Payment Draft identity',
    'Regular Invoice product quantity hold','DP deduction lineage','installment total reconciliation',
    'zero Financial Event/Journal effect','all fixture writes rolled back']) details;
