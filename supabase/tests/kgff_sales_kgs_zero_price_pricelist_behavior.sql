-- Rollback-only resolver behavior. No persistent mutation.
BEGIN;

DO $behavior$
DECLARE
  v_company constant uuid := 'a59c534b-909f-4b3f-aba0-ae9db6d90b76'::uuid;
  v_customer constant uuid := 'c24ac084-5692-4722-9413-3ed46c734af9'::uuid;
  v_pricelist uuid;
  v_store uuid;
  v_rule record;
  v_resolution jsonb;
  v_tested bigint := 0;
  v_walk_in uuid;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20261103100000') THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: migration 20261103100000 required';
  END IF;
  SELECT id INTO STRICT v_pricelist FROM public.pricelists
  WHERE company_id=v_company AND code='SAMPLE-SALES-KGS'
    AND name='Sample SALES KGS' AND scope='CUSTOMER' AND is_active;
  IF NOT EXISTS(SELECT 1 FROM public.customers WHERE company_id=v_company
      AND id=v_customer AND default_pricelist_id=v_pricelist) THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: exact SALES KGS assignment required';
  END IF;
  SELECT id INTO v_store FROM public.stores
  WHERE company_id=v_company AND status='ACTIVE' ORDER BY id LIMIT 1;
  IF v_store IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: active KGFF Store required';
  END IF;

  FOR v_rule IN SELECT rule.product_uom_id,rule.id
    FROM public.pricelist_rules rule
    WHERE rule.company_id=v_company AND rule.pricelist_id=v_pricelist
      AND rule.is_active ORDER BY rule.id
  LOOP
    v_resolution:=private.resolve_pos_sale_price(
      v_company,v_store,v_customer,v_rule.product_uom_id,1,clock_timestamp());
    IF (v_resolution->>'resolvedUnitPrice')::numeric IS DISTINCT FROM 0
       OR (v_resolution->>'pricelistId')::uuid IS DISTINCT FROM v_pricelist
       OR (v_resolution->>'pricelistRuleId')::uuid IS DISTINCT FROM v_rule.id THEN
      RAISE EXCEPTION 'TEST_FAILED: zero resolver mismatch for Product-UOM %',v_rule.product_uom_id;
    END IF;
    v_tested:=v_tested+1;
  END LOOP;
  IF v_tested=0 THEN RAISE EXCEPTION 'TEST_FAILED: no rules exercised'; END IF;
  SELECT id INTO STRICT v_walk_in FROM public.customers
  WHERE company_id=v_company AND is_system_customer AND is_active;
  SELECT rule.product_uom_id INTO STRICT v_rule FROM public.pricelist_rules rule
  WHERE rule.company_id=v_company AND rule.pricelist_id=v_pricelist
    AND rule.is_active ORDER BY rule.id LIMIT 1;
  v_resolution:=private.resolve_pos_sale_price(
    v_company,v_store,v_walk_in,v_rule.product_uom_id,1,clock_timestamp());
  IF (v_resolution->>'pricelistId')::uuid IS NOT DISTINCT FROM v_pricelist THEN
    RAISE EXCEPTION 'TEST_FAILED: Sample Pricelist leaked to Walk-In Customer';
  END IF;
  RAISE NOTICE 'kgff_sales_kgs_sample_pricelist_behavior PASS: % exact zero rules resolved; transaction rolls back',v_tested;
END
$behavior$;

ROLLBACK;
