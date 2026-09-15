-- Step 4E/6 authenticated rollback-only behavior.
BEGIN;

INSERT INTO auth.users(id,email,instance_id,raw_app_meta_data,raw_user_meta_data,
  is_super_admin,role,aud,email_confirmed_at)
VALUES('00000000-0000-0000-0000-000000111305',
  'cutover-apply-nonadmin@example.invalid',
  '00000000-0000-0000-0000-000000000000',
  '{"provider":"email","providers":["email"]}'::jsonb,
  '{"name":"Cutover Apply Non Admin"}'::jsonb,
  false,'authenticated','authenticated',clock_timestamp())
ON CONFLICT(id) DO NOTHING;
INSERT INTO public.profiles(id,email,name,role)
VALUES('00000000-0000-0000-0000-000000111305',
  'cutover-apply-nonadmin@example.invalid','Cutover Apply Non Admin',
  'cashier'::public.user_role)
ON CONFLICT(id) DO UPDATE SET email=excluded.email,name=excluded.name,role=excluded.role;

DO $test$
DECLARE v_actor uuid;v_non_admin uuid:='00000000-0000-0000-0000-000000111305';
  v_company uuid;v_other_company uuid;v_store uuid;v_warehouse uuid;
  v_customer uuid;v_product_uom uuid;v_timezone text;v_today date;v_settings_version bigint;
  v_payload jsonb;v_created jsonb;v_edited jsonb;v_plan jsonb;v_refreshed jsonb;
  v_applied jsonb;v_retry jsonb;v_valid_source uuid;v_blocked_source uuid;v_target uuid;
  v_plan_id uuid;v_apply_operation uuid:=gen_random_uuid();v_blocked boolean:=false;
  v_before jsonb;v_after jsonb;v_valid_version bigint;v_blocked_version bigint;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260911130000') THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: 20260911130000 required';
  END IF;
  SELECT profile.id INTO v_actor FROM public.profiles profile
  WHERE profile.role::text='super_admin' ORDER BY profile.id LIMIT 1;
  IF v_actor IS NULL THEN RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: Super Admin profile required'; END IF;

  SELECT company.id,store.id,warehouse.id,customer.id,product_uom.id,company.timezone
  INTO v_company,v_store,v_warehouse,v_customer,v_product_uom,v_timezone
  FROM public.companies company
  JOIN public.company_sales_process_settings setting ON setting.company_id=company.id
  JOIN LATERAL(SELECT candidate.id FROM public.stores candidate
    WHERE candidate.company_id=company.id AND candidate.status='ACTIVE'
    ORDER BY candidate.id LIMIT 1) store ON true
  JOIN LATERAL(SELECT candidate.id FROM public.warehouses candidate
    WHERE candidate.company_id=company.id AND candidate.is_active AND candidate.is_sale_source
    ORDER BY candidate.id LIMIT 1) warehouse ON true
  JOIN LATERAL(SELECT candidate.id FROM public.customers candidate
    WHERE candidate.company_id=company.id AND candidate.is_active
    ORDER BY candidate.is_system_customer DESC,candidate.id LIMIT 1) customer ON true
  JOIN LATERAL(SELECT candidate.id FROM public.product_uoms candidate
    JOIN public.products product ON product.company_id=candidate.company_id
      AND product.id=candidate.product_id AND product.is_active AND NOT product.is_bundle
    JOIN public.uoms uom ON uom.company_id=candidate.company_id
      AND uom.id=candidate.uom_id AND uom.is_active
    WHERE candidate.company_id=company.id AND candidate.is_active
      AND candidate.sales_allowed AND candidate.sale_price>0
      AND (SELECT count(*) FROM public.product_uoms exact
        WHERE exact.company_id=candidate.company_id AND exact.product_id=candidate.product_id
          AND exact.uom_id=candidate.uom_id AND exact.is_active AND exact.sales_allowed)=1
    ORDER BY candidate.id LIMIT 1) product_uom ON true
  WHERE company.status='ACTIVE'
    AND NOT EXISTS(SELECT 1 FROM public.finance_posting_queue_runs queue
      WHERE queue.company_id=company.id AND queue.status IN('PREVIEWED','APPROVED','PROCESSING'))
    AND NOT EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions submission
      WHERE submission.company_id=company.id
        AND submission.status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION'))
    AND NOT EXISTS(SELECT 1 FROM public.sales_process_cutover_plans plan
      WHERE plan.company_id=company.id AND plan.status IN('DRAFT','PREVIEWED','APPLYING'))
  ORDER BY company.id LIMIT 1;
  IF v_company IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: canonical Backoffice Company fixture required';
  END IF;
  -- Own the tenant-isolation fixture instead of assuming Development already has
  -- a second active Company. The enclosing transaction rolls this row back.
  v_other_company:=gen_random_uuid();
  INSERT INTO public.companies(id,company_code,company_name,company_slug,status)
  VALUES(v_other_company,
    'CUT4E-'||upper(substr(replace(v_other_company::text,'-',''),1,12)),
    'Step 4E Tenant Isolation Fixture',
    'cut4e-'||lower(replace(v_other_company::text,'-','')),
    'ACTIVE');

  PERFORM set_config('request.jwt.claim.sub',v_actor::text,true);
  INSERT INTO public.user_active_company_contexts(user_id,company_id)
  VALUES(v_actor,v_company) ON CONFLICT(user_id) DO UPDATE SET
    company_id=excluded.company_id,selected_at=clock_timestamp(),updated_at=clock_timestamp();
  INSERT INTO public.company_features(company_id,feature_code,is_enabled,config,updated_by)
  VALUES(v_company,'backoffice_delivered_qty_sales_enabled',true,'{}',v_actor)
  ON CONFLICT(company_id,feature_code) DO UPDATE SET is_enabled=true,updated_by=excluded.updated_by;
  PERFORM set_config('kgs.sales_process_cutover_mutation','1',true);
  UPDATE public.company_sales_process_settings SET
    active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE',mode_effective_at='-infinity',
    master_version=master_version+1,updated_by=v_actor,updated_at=clock_timestamp()
  WHERE company_id=v_company;
  PERFORM set_config('kgs.sales_process_cutover_mutation','',true);
  SELECT master_version INTO STRICT v_settings_version
  FROM public.company_sales_process_settings WHERE company_id=v_company;
  v_today:=(clock_timestamp() AT TIME ZONE v_timezone)::date;

  v_payload:=jsonb_build_object('storeId',v_store,'warehouseId',v_warehouse,
    'customerId',v_customer,'selectedPricelistId',NULL,'orderDate',v_today,
    'plannedDeliveryDate',v_today+1,'isTempo',false,'currencyCode','IDR',
    'globalDiscount',0,'roundingDirection','NONE','roundingIncrement',100,
    'deliveryFeeAmount',0,'deliveryFeeInvoiceDisplayMode','SHOW_SEPARATE',
    'lines',jsonb_build_array(jsonb_build_object('productUomId',v_product_uom,
      'quantity',2,'lineDiscountType','PERCENT','lineDiscountInput',0)),
    'notes','Step 4E convertible fixture');
  v_created:=public.save_backoffice_sales_order_draft(NULL,NULL,gen_random_uuid(),v_payload);
  v_valid_source:=(v_created->'data'->>'id')::uuid;
  v_valid_version:=(v_created->'data'->>'masterVersion')::bigint;

  v_payload:=v_payload||jsonb_build_object('orderDate',v_today+2,
    'plannedDeliveryDate',v_today+2,'notes','Step 4E grandfathered blocker fixture');
  v_created:=public.save_backoffice_sales_order_draft(NULL,NULL,gen_random_uuid(),v_payload);
  v_blocked_source:=(v_created->'data'->>'id')::uuid;

  SELECT jsonb_build_object(
    'stock',COALESCE((SELECT sum(stock_qty) FROM public.product_stocks WHERE company_id=v_company),0),
    'movements',(SELECT count(*) FROM public.stock_movements WHERE company_id=v_company),
    'fifo',(SELECT count(*) FROM public.sale_fifo_allocations WHERE company_id=v_company),
    'events',(SELECT count(*) FROM public.financial_events WHERE company_id=v_company),
    'journals',(SELECT count(*) FROM public.journal_entries WHERE company_id=v_company),
    'payments',(SELECT count(*) FROM public.sales_payments WHERE company_id=v_company),
    'retailInvoices',(SELECT count(*) FROM public.sales_invoice_snapshots WHERE company_id=v_company),
    'backofficeInvoices',(SELECT count(*) FROM public.backoffice_sales_invoices WHERE company_id=v_company))
  INTO v_before;

  v_plan:=public.create_sales_process_cutover_plan('RETAIL_CONFIRM_INVOICE',
    clock_timestamp()-interval '1 second',v_settings_version,gen_random_uuid(),
    'Step 4E atomic Apply behavior');
  v_plan_id:=(v_plan->>'planId')::uuid;
  IF jsonb_array_length(v_plan->'items')<2
    OR NOT EXISTS(SELECT 1 FROM jsonb_array_elements(v_plan->'items') item
      WHERE item->>'sourceDocumentId'=v_valid_source::text AND item->>'decision'='CONVERT')
    OR NOT EXISTS(SELECT 1 FROM jsonb_array_elements(v_plan->'items') item
      WHERE item->>'sourceDocumentId'=v_blocked_source::text AND item->>'decision'='BLOCKED'
        AND item->'blockerCodes' ? 'FUTURE_NON_TEMPO_MUST_FINISH_IN_BACKOFFICE') THEN
    RAISE EXCEPTION 'TEST_FAILED: plan did not contain one convertible and one blocker: %',v_plan;
  END IF;

  v_payload:=jsonb_set(v_payload||jsonb_build_object('orderDate',v_today,
    'plannedDeliveryDate',v_today+1),'{notes}','"Step 4E stale preview edit"');
  v_edited:=public.save_backoffice_sales_order_draft(v_valid_source,v_valid_version,
    gen_random_uuid(),v_payload);
  BEGIN
    PERFORM public.apply_sales_process_cutover_plan(v_plan_id,
      (v_plan->>'masterVersion')::bigint,v_settings_version,v_apply_operation);
  EXCEPTION WHEN OTHERS THEN v_blocked:=SQLERRM LIKE '%SALES_PROCESS_CUTOVER_PREVIEW_STALE%'; END;
  IF NOT v_blocked THEN RAISE EXCEPTION 'TEST_FAILED: stale preview Apply accepted'; END IF;
  IF EXISTS(SELECT 1 FROM public.sales_process_cutover_items item
      WHERE item.company_id=v_company AND item.cutover_plan_id=v_plan_id
        AND item.target_document_id IS NOT NULL)
    OR (SELECT status FROM public.sales_process_cutover_plans
      WHERE company_id=v_company AND id=v_plan_id)<>'PREVIEWED'
    OR (SELECT active_mode FROM public.company_sales_process_settings
      WHERE company_id=v_company)<>'BACKOFFICE_DELIVERED_QTY_INVOICE' THEN
    RAISE EXCEPTION 'TEST_FAILED: stale Apply left partial effect';
  END IF;

  v_refreshed:=public.refresh_sales_process_cutover_plan(v_plan_id,
    (v_plan->>'masterVersion')::bigint,v_settings_version,gen_random_uuid());
  v_applied:=public.apply_sales_process_cutover_plan(v_plan_id,
    (v_refreshed->>'masterVersion')::bigint,v_settings_version,v_apply_operation);
  v_target:=(SELECT item.target_document_id FROM public.sales_process_cutover_items item
    WHERE item.company_id=v_company AND item.cutover_plan_id=v_plan_id
      AND item.source_document_id=v_valid_source);
  IF v_applied->>'status'<>'APPLIED' OR NULLIF(v_applied->>'appliedAt','') IS NULL
    OR v_applied->>'appliedBy'<>v_actor::text
    OR NOT COALESCE((v_applied->>'modeSwitched')::boolean,false)
    OR v_applied->>'activeMode'<>'RETAIL_CONFIRM_INVOICE' OR v_target IS NULL
    OR NOT EXISTS(SELECT 1 FROM public.sales_headers sale
      WHERE sale.company_id=v_company AND sale.id=v_target
        AND sale.sales_origin='BACKOFFICE_CUTOVER' AND sale.order_runtime_status='DRAFT_INPUT')
    OR NOT EXISTS(SELECT 1 FROM public.backoffice_sales_orders document
      WHERE document.company_id=v_company AND document.id=v_valid_source AND document.status='CANCELED')
    OR NOT EXISTS(SELECT 1 FROM public.backoffice_sales_orders document
      WHERE document.company_id=v_company AND document.id=v_blocked_source AND document.status='DRAFT') THEN
    RAISE EXCEPTION 'TEST_FAILED: Apply conversion/mode/grandfather contract invalid: %',v_applied;
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.sales_process_cutover_audit audit
      JOIN public.sales_process_cutover_items item ON item.company_id=audit.company_id
        AND item.id=audit.cutover_item_id
      WHERE audit.company_id=v_company AND audit.cutover_plan_id=v_plan_id
        AND audit.action='APPLY_ITEM' AND item.source_document_id=v_valid_source)
    OR NOT EXISTS(SELECT 1 FROM public.sales_process_cutover_audit audit
      JOIN public.sales_process_cutover_items item ON item.company_id=audit.company_id
        AND item.id=audit.cutover_item_id
      WHERE audit.company_id=v_company AND audit.cutover_plan_id=v_plan_id
        AND audit.action='KEEP_ITEM' AND item.source_document_id=v_blocked_source)
    OR (SELECT count(*) FROM public.sales_process_cutover_audit audit
      WHERE audit.company_id=v_company AND audit.cutover_plan_id=v_plan_id
        AND audit.action='APPLY_MODE' AND audit.operation_id=v_apply_operation)<>1
    OR NOT EXISTS(SELECT 1 FROM public.company_sales_process_mode_history history
      WHERE history.company_id=v_company AND history.cutover_plan_id=v_plan_id
        AND history.source_mode='BACKOFFICE_DELIVERED_QTY_INVOICE'
        AND history.target_mode='RETAIL_CONFIRM_INVOICE') THEN
    RAISE EXCEPTION 'TEST_FAILED: immutable item/mode audit missing';
  END IF;
  v_blocked:=false;
  BEGIN
    UPDATE public.sales_headers SET sales_warehouse_id=NULL
    WHERE company_id=v_company AND id=v_target;
  EXCEPTION WHEN OTHERS THEN
    v_blocked:=SQLERRM LIKE '%BACKOFFICE_CUTOVER_SCOPE_IMMUTABLE%';
  END;
  IF NOT v_blocked THEN
    RAISE EXCEPTION 'TEST_FAILED: converted Retail Warehouse scope was mutable';
  END IF;

  v_retry:=public.apply_sales_process_cutover_plan(v_plan_id,
    (v_refreshed->>'masterVersion')::bigint,v_settings_version,v_apply_operation);
  IF v_retry->>'planId'<>v_plan_id::text OR
    (SELECT count(*) FROM public.sales_headers sale
      WHERE sale.company_id=v_company AND sale.id=v_target)<>1 THEN
    RAISE EXCEPTION 'TEST_FAILED: exact Apply retry duplicated target';
  END IF;
  v_blocked:=false;
  BEGIN
    PERFORM public.apply_sales_process_cutover_plan(v_plan_id,
      (v_refreshed->>'masterVersion')::bigint+1,v_settings_version,v_apply_operation);
  EXCEPTION WHEN OTHERS THEN
    v_blocked:=SQLERRM LIKE '%SALES_PROCESS_CUTOVER_IDEMPOTENCY_PAYLOAD_CONFLICT%';
  END;
  IF NOT v_blocked THEN RAISE EXCEPTION 'TEST_FAILED: Apply payload conflict accepted'; END IF;

  -- The retained blocker stays editable through its source runtime, while a
  -- new Backoffice root is rejected after Retail becomes active.
  SELECT master_version INTO STRICT v_blocked_version FROM public.backoffice_sales_orders
  WHERE company_id=v_company AND id=v_blocked_source;
  v_payload:=v_payload||jsonb_build_object('orderDate',v_today+2,
    'plannedDeliveryDate',v_today+2,'notes','Step 4E retained source edit');
  PERFORM public.save_backoffice_sales_order_draft(v_blocked_source,v_blocked_version,
    gen_random_uuid(),v_payload);
  v_blocked:=false;
  BEGIN
    PERFORM public.save_backoffice_sales_order_draft(NULL,NULL,gen_random_uuid(),v_payload);
  EXCEPTION WHEN OTHERS THEN
    v_blocked:=SQLERRM LIKE '%SALES_PROCESS_ROOT_CREATION_MODE_BLOCKED%';
  END;
  IF NOT v_blocked THEN RAISE EXCEPTION 'TEST_FAILED: inactive Backoffice root creation accepted'; END IF;
  PERFORM private.assert_sales_process_root_creation_allowed(v_company,'RETAIL_CONFIRM_INVOICE');

  UPDATE public.user_active_company_contexts SET company_id=v_other_company,
    selected_at=clock_timestamp(),updated_at=clock_timestamp() WHERE user_id=v_actor;
  v_blocked:=false;
  BEGIN
    PERFORM public.apply_sales_process_cutover_plan(v_plan_id,
      (v_refreshed->>'masterVersion')::bigint,v_settings_version,gen_random_uuid());
  EXCEPTION WHEN OTHERS THEN v_blocked:=SQLERRM LIKE '%SALES_PROCESS_CUTOVER_PLAN_NOT_FOUND%'; END;
  IF NOT v_blocked THEN RAISE EXCEPTION 'TEST_FAILED: cross-Company Apply accepted'; END IF;
  UPDATE public.user_active_company_contexts SET company_id=v_company,
    selected_at=clock_timestamp(),updated_at=clock_timestamp() WHERE user_id=v_actor;

  PERFORM set_config('request.jwt.claim.sub',v_non_admin::text,true);
  v_blocked:=false;
  BEGIN
    PERFORM public.apply_sales_process_cutover_plan(v_plan_id,
      (v_refreshed->>'masterVersion')::bigint,v_settings_version,gen_random_uuid());
  EXCEPTION WHEN OTHERS THEN
    v_blocked:=SQLERRM LIKE '%SALES_PROCESS_CUTOVER_SUPER_ADMIN_REQUIRED%';
  END;
  IF NOT v_blocked THEN RAISE EXCEPTION 'TEST_FAILED: non-Super-Admin Apply accepted'; END IF;
  PERFORM set_config('request.jwt.claim.sub','',true);
  v_blocked:=false;
  BEGIN
    PERFORM public.apply_sales_process_cutover_plan(v_plan_id,
      (v_refreshed->>'masterVersion')::bigint,v_settings_version,gen_random_uuid());
  EXCEPTION WHEN OTHERS THEN v_blocked:=SQLERRM LIKE '%AUTHENTICATION_REQUIRED%'; END;
  IF NOT v_blocked THEN RAISE EXCEPTION 'TEST_FAILED: anonymous Apply accepted'; END IF;

  SELECT jsonb_build_object(
    'stock',COALESCE((SELECT sum(stock_qty) FROM public.product_stocks WHERE company_id=v_company),0),
    'movements',(SELECT count(*) FROM public.stock_movements WHERE company_id=v_company),
    'fifo',(SELECT count(*) FROM public.sale_fifo_allocations WHERE company_id=v_company),
    'events',(SELECT count(*) FROM public.financial_events WHERE company_id=v_company),
    'journals',(SELECT count(*) FROM public.journal_entries WHERE company_id=v_company),
    'payments',(SELECT count(*) FROM public.sales_payments WHERE company_id=v_company),
    'retailInvoices',(SELECT count(*) FROM public.sales_invoice_snapshots WHERE company_id=v_company),
    'backofficeInvoices',(SELECT count(*) FROM public.backoffice_sales_invoices WHERE company_id=v_company))
  INTO v_after;
  IF v_after<>v_before THEN
    RAISE EXCEPTION 'TEST_FAILED: Apply produced Stock/Payment/Invoice/Finance effect before=% after=%',v_before,v_after;
  END IF;
END
$test$;
ROLLBACK;
SELECT 'sales_process_cutover_atomic_apply_behavior' check_name,'PASS' status,
  0::bigint violation_rows,jsonb_build_object('tested',ARRAY[
    'one convertible plus one blocked source','stale preview rejects with zero partial effect',
    'refresh then atomic conversion and mode switch','blocked source retained and editable',
    'inactive-mode root creation rejected','exact retry and payload conflict',
    'cross-Company non-Super-Admin and anonymous Apply rejected','immutable item and mode lineage',
    'converted Retail Company Store Warehouse scope immutable',
    'zero Stock FIFO Payment Invoice and Finance effect','all fixtures rolled back']) details;
