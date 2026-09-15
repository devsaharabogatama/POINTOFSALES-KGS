-- Rollback-only canonical inclusive SALES tax behavior.
BEGIN;
DO $test$
DECLARE
  v_actor uuid;v_company uuid;v_store uuid;v_warehouse uuid;v_customer uuid;
  v_product uuid;v_product_uom uuid;v_account uuid;v_rule uuid:=gen_random_uuid();
  v_payload jsonb;v_result jsonb;v_line jsonb;v_before jsonb;v_after jsonb;
BEGIN
  SELECT id INTO STRICT v_actor FROM public.profiles
  WHERE role='super_admin'::public.user_role ORDER BY id LIMIT 1;
  SELECT company.id INTO STRICT v_company FROM public.companies company
  WHERE company.status='ACTIVE'
    AND EXISTS(SELECT 1 FROM public.stores store
      WHERE store.company_id=company.id AND store.status='ACTIVE')
    AND EXISTS(SELECT 1 FROM public.warehouses warehouse
      WHERE warehouse.company_id=company.id AND warehouse.is_active
        AND warehouse.is_sale_source)
    AND EXISTS(SELECT 1 FROM public.customers customer
      WHERE customer.company_id=company.id AND customer.is_active)
    AND EXISTS(SELECT 1 FROM public.product_uoms product_uom
      JOIN public.products product ON product.company_id=product_uom.company_id
        AND product.id=product_uom.product_id
      WHERE product_uom.company_id=company.id AND product_uom.is_active
        AND product_uom.sales_allowed AND product.is_active)
    AND EXISTS(SELECT 1 FROM public.chart_of_accounts account
      WHERE account.company_id=company.id AND account.is_active
        AND account.is_postable AND account.system_function_key='OUTPUT_TAX')
  ORDER BY company.id LIMIT 1;
  PERFORM set_config('request.jwt.claim.sub',v_actor::text,true);
  INSERT INTO public.user_active_company_contexts(user_id,company_id,selection_source)
  VALUES(v_actor,v_company,'BACKOFFICE_TAX_TEST')
  ON CONFLICT(user_id) DO UPDATE SET company_id=EXCLUDED.company_id,
    selection_source=EXCLUDED.selection_source;
  INSERT INTO public.company_features(company_id,feature_code,is_enabled,config,updated_by)
  VALUES(v_company,'tax_sales_enabled',true,'{}',v_actor)
  ON CONFLICT(company_id,feature_code) DO UPDATE SET is_enabled=true,updated_by=EXCLUDED.updated_by;
  INSERT INTO public.company_features(company_id,feature_code,is_enabled,config,updated_by)
  VALUES(v_company,'backoffice_delivered_qty_sales_enabled',true,'{}',v_actor)
  ON CONFLICT(company_id,feature_code) DO UPDATE SET is_enabled=true,updated_by=EXCLUDED.updated_by;

  SELECT id INTO STRICT v_store FROM public.stores
  WHERE company_id=v_company AND status='ACTIVE' ORDER BY id LIMIT 1;
  SELECT id INTO STRICT v_warehouse FROM public.warehouses
  WHERE company_id=v_company AND is_active AND is_sale_source
    AND (store_id IS NULL OR store_id=v_store) ORDER BY id LIMIT 1;
  SELECT id INTO STRICT v_customer FROM public.customers
  WHERE company_id=v_company AND is_active ORDER BY id LIMIT 1;
  SELECT pu.product_id,pu.id INTO STRICT v_product,v_product_uom
  FROM public.product_uoms pu JOIN public.products p
    ON p.company_id=pu.company_id AND p.id=pu.product_id
  WHERE pu.company_id=v_company AND pu.is_active AND pu.sales_allowed AND p.is_active
  ORDER BY pu.id LIMIT 1;
  SELECT id INTO STRICT v_account FROM public.chart_of_accounts
  WHERE company_id=v_company AND is_active AND is_postable
    AND system_function_key='OUTPUT_TAX' ORDER BY id LIMIT 1;

  INSERT INTO public.tax_rules(id,company_id,tax_code,tax_name,tax_scope,is_active,created_by,updated_by)
  VALUES(v_rule,v_company,'BO-TAX-11','Backoffice Test PPN 11%','SALES',true,v_actor,v_actor);
  INSERT INTO public.tax_rule_versions(company_id,tax_rule_id,rate_percent,
    calculation_scope,default_price_mode,account_function_key,account_id,
    is_recoverable,effective_from,rule_version,status,approved_by,approved_at,created_by,updated_by)
  VALUES(v_company,v_rule,11,'PER_DOCUMENT','INCLUSIVE','OUTPUT_TAX',v_account,
    NULL,'2026-01-01',1,'ACTIVE',v_actor,clock_timestamp(),v_actor,v_actor);
  UPDATE public.products SET sales_tax_rule_id=v_rule,updated_by=v_actor
  WHERE company_id=v_company AND id=v_product;

  SELECT jsonb_build_object('reservation',(SELECT count(*) FROM public.sales_stock_reservations),
    'delivery',(SELECT count(*) FROM public.sales_delivery_documents),
    'invoice',(SELECT count(*) FROM public.sales_invoice_snapshots),
    'movement',(SELECT count(*) FROM public.stock_movements),
    'event',(SELECT count(*) FROM public.financial_events)) INTO v_before;
  v_payload:=jsonb_build_object('storeId',v_store,'warehouseId',v_warehouse,
    'customerId',v_customer,'orderDate','2026-09-09','plannedDeliveryDate','2026-09-10',
    'isTempo',false,'currencyCode','IDR','lines',jsonb_build_array(
      jsonb_build_object('productUomId',v_product_uom,'quantity',2)));
  v_result:=public.save_backoffice_sales_order_draft(NULL,NULL,gen_random_uuid(),v_payload);
  v_line:=v_result->'data'->'lines'->0;
  IF COALESCE((v_result->'data'->>'taxTotal')::numeric,0)<=0
    OR v_line->>'taxCode'<>'BO-TAX-11'
    OR (v_line->>'taxRatePercent')::numeric<>11
    OR v_line->>'taxPriceMode'<>'INCLUSIVE'
    OR (v_line->>'lineTotal')::numeric<>(v_result->'data'->>'grandTotal')::numeric
    OR (v_line->>'taxBase')::numeric+(v_line->>'taxAmount')::numeric<>(v_line->>'lineTotal')::numeric
    OR v_result->'data'->'commercialSnapshot'->>'taxScope'<>'CANONICAL_SALES_INCLUSIVE' THEN
    RAISE EXCEPTION 'TEST_FAILED: canonical inclusive tax snapshot invalid %',v_result;
  END IF;
  SELECT jsonb_build_object('reservation',(SELECT count(*) FROM public.sales_stock_reservations),
    'delivery',(SELECT count(*) FROM public.sales_delivery_documents),
    'invoice',(SELECT count(*) FROM public.sales_invoice_snapshots),
    'movement',(SELECT count(*) FROM public.stock_movements),
    'event',(SELECT count(*) FROM public.financial_events)) INTO v_after;
  IF v_after<>v_before THEN RAISE EXCEPTION 'TEST_FAILED: downstream effect detected'; END IF;
  RAISE NOTICE 'BACKOFFICE_SALES_CANONICAL_TAX_BEHAVIOR_PASS';
END
$test$;
ROLLBACK;
