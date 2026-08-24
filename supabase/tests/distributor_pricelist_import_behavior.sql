-- Rollback-safe behavior for Preview, Apply, UOM derivation and exact replay.
BEGIN;

DO $fixture$
DECLARE v_actor UUID;v_company UUID;v_product_id UUID;v_sku TEXT;v_name TEXT;
  v_cogs NUMERIC;v_retail NUMERIC;
BEGIN
  SELECT profile.id INTO v_actor FROM public.profiles profile
  JOIN auth.users auth_user ON auth_user.id=profile.id
  WHERE public.private_is_super_admin(profile.id)
  ORDER BY profile.id LIMIT 1;
  SELECT company.id INTO v_company FROM public.companies company
  WHERE company.status='ACTIVE'
    AND EXISTS(SELECT 1 FROM public.pricelists pricelist
      WHERE pricelist.company_id=company.id AND pricelist.scope='GLOBAL'
        AND pricelist.is_active AND pricelist.is_default)
    AND EXISTS(SELECT 1 FROM public.products product
      JOIN public.product_uoms product_uom ON product_uom.company_id=product.company_id
        AND product_uom.product_id=product.id AND product_uom.is_active
        AND product_uom.sales_allowed
      JOIN public.uoms uom ON uom.company_id=product_uom.company_id
        AND uom.id=product_uom.uom_id
      WHERE product.company_id=company.id AND product.is_active AND NOT product.is_bundle
        AND (upper(btrim(uom.name))='PACK' OR upper(btrim(uom.code))='PACK'))
  ORDER BY company.id LIMIT 1;
  IF v_actor IS NULL OR v_company IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: linked Super Admin and Company with PACK Product required';
  END IF;
  SELECT product.id,product.sku,product.name,COALESCE(pack.purchase_price,100)+1,
    COALESCE(pack.sale_price,200)+1
  INTO v_product_id,v_sku,v_name,v_cogs,v_retail
  FROM public.products product
  JOIN LATERAL(SELECT product_uom.purchase_price,product_uom.sale_price
    FROM public.product_uoms product_uom
    JOIN public.uoms uom ON uom.company_id=product_uom.company_id
      AND uom.id=product_uom.uom_id
    WHERE product_uom.company_id=v_company AND product_uom.product_id=product.id
      AND product_uom.is_active AND product_uom.sales_allowed
      AND (upper(btrim(uom.name))='PACK' OR upper(btrim(uom.code))='PACK')
    ORDER BY product_uom.factor_to_base,product_uom.id LIMIT 1) pack ON TRUE
  WHERE product.company_id=v_company AND product.is_active AND NOT product.is_bundle
  ORDER BY product.id LIMIT 1;
  CREATE TEMP TABLE distributor_pricelist_test_context(
    actor_id UUID,company_id UUID,product_id UUID,sku TEXT,product_name TEXT,
    test_cogs NUMERIC,test_retail NUMERIC
  ) ON COMMIT DROP;
  INSERT INTO distributor_pricelist_test_context
  VALUES(v_actor,v_company,v_product_id,v_sku,v_name,v_cogs,v_retail);
  GRANT SELECT ON distributor_pricelist_test_context TO authenticated;
  INSERT INTO public.user_active_company_contexts(user_id,company_id,selection_source)
  VALUES(v_actor,v_company,'BACKOFFICE') ON CONFLICT(user_id) DO UPDATE SET
    company_id=EXCLUDED.company_id,selection_source=EXCLUDED.selection_source;
  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub',v_actor,'role','authenticated')::TEXT,TRUE);
END
$fixture$;

SET LOCAL ROLE authenticated;

DO $behavior$
DECLARE v_company UUID:=public.private_active_company_id();v_product RECORD;
  v_rows JSONB;v_preview JSONB;v_applied JSONB;v_replay JSONB;v_request UUID:=gen_random_uuid();
BEGIN
  SELECT product_id AS id,sku,product_name AS name,test_cogs,test_retail INTO v_product
  FROM distributor_pricelist_test_context;
  v_rows:=jsonb_build_array(jsonb_build_object(
    'rowNumber',3,'sku',v_product.sku,'productName',v_product.name,
    'cogs',v_product.test_cogs,'retail',v_product.test_retail,'agentPrice',18000,
    'specialPrice',17500,'customPrice',17000,'min60Price',19500,
    'min100Price',19000,'min150Price',18500),jsonb_build_object(
    'rowNumber',4,'sku','SKU-TIDAK-ADA-UNTUK-TEST','productName','Skipped fixture',
    'cogs',100,'retail',200));
  v_preview:=public.process_distributor_pricelist_import(
    v_rows,'behavior.xlsx',repeat('a',64),NULL,FALSE,NULL);
  IF v_preview->>'mode'<>'PREVIEW' OR (v_preview->>'validRowCount')::INTEGER<>1
    OR (v_preview->>'skippedRowCount')::INTEGER<>1
    OR (v_preview->>'errorRowCount')::INTEGER<>0 THEN
    RAISE EXCEPTION 'TEST_FAILED: preview contract invalid';
  END IF;
  v_applied:=public.process_distributor_pricelist_import(
    v_rows,'behavior.xlsx',repeat('a',64),v_request,TRUE,
    'IMPORT_DISTRIBUTOR_PRICELIST');
  IF v_applied->>'mode'<>'APPLY' OR COALESCE((v_applied->>'appliedProductCount')::INTEGER,0)<1
    OR COALESCE((v_applied->>'appliedPricelistCount')::INTEGER,0)<1 THEN
    RAISE EXCEPTION 'TEST_FAILED: apply contract invalid';
  END IF;
  v_replay:=public.process_distributor_pricelist_import(
    v_rows,'behavior.xlsx',repeat('a',64),v_request,TRUE,
    'IMPORT_DISTRIBUTOR_PRICELIST');
  IF NOT COALESCE((v_replay->>'replayed')::BOOLEAN,FALSE) THEN
    RAISE EXCEPTION 'TEST_FAILED: exact replay missing';
  END IF;
END
$behavior$;

RESET ROLE;

DO $assert$
DECLARE v_actor UUID;v_company UUID;v_run UUID;
BEGIN
  SELECT actor_id,company_id INTO v_actor,v_company
  FROM distributor_pricelist_test_context;
  SELECT id INTO v_run FROM public.pricelist_import_runs
  WHERE company_id=v_company AND source_file_name='behavior.xlsx'
  ORDER BY created_at DESC LIMIT 1;
  IF v_run IS NULL THEN RAISE EXCEPTION 'TEST_FAILED: immutable run evidence missing'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.pricelists pricelist
    WHERE pricelist.company_id=v_company AND pricelist.name='Harga Agen / SM'
      AND pricelist.scope='CUSTOMER') THEN
    RAISE EXCEPTION 'TEST_FAILED: Customer Pricelist missing';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.pricelist_rules rule
    JOIN public.pricelists pricelist ON pricelist.company_id=rule.company_id
      AND pricelist.id=rule.pricelist_id
    WHERE rule.company_id=v_company AND pricelist.scope='GLOBAL'
      AND pricelist.is_default AND rule.is_active
      AND rule.tier_qty_basis='BASE_UOM_EQUIVALENT') THEN
    RAISE EXCEPTION 'TEST_FAILED: Global tier missing';
  END IF;
END
$assert$;

ROLLBACK;

SELECT 'distributor_pricelist_import_behavior' AS check_name,'PASS' AS status,
  jsonb_build_object('rolledBack',TRUE) AS details;
