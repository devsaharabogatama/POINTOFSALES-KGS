-- Forward-fix ODR Dispatch runtime against the applied Product requirement
-- schema and the extensions-owned pgcrypto digest function.
BEGIN;

DO $guard$
DECLARE
  v_definition TEXT;
BEGIN
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260901100000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260901100000';
  END IF;
  IF (SELECT count(*) FROM private.kgs_schema_migrations
      WHERE version=ANY(ARRAY[
        '20260828140000','20260828230000','20260828240000','20260828250000']))<>4 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: ODR Dispatch/Finance chain incomplete';
  END IF;
  IF to_regprocedure('extensions.digest(text,text)') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: extensions.digest(text,text) missing';
  END IF;
  IF to_regprocedure(
      'private.dispatch_sales_delivery_stock_core_odr3c(uuid,bigint,uuid,jsonb,text)'
    ) IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Dispatch stock core missing';
  END IF;
  IF (SELECT count(*) FROM information_schema.columns
      WHERE table_schema='public' AND table_name='sale_stock_requirements'
        AND column_name=ANY(ARRAY['commercial_product_id','stock_product_id',
          'stock_uom_id','stock_uom_name_snapshot','quantity_uom']))<>5 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Sale Stock Requirement schema changed';
  END IF;
  SELECT pg_get_functiondef(
    'private.dispatch_sales_delivery_stock_core_odr3c(uuid,bigint,uuid,jsonb,text)'::regprocedure
  ) INTO v_definition;
  IF v_definition NOT LIKE '%digest(v_request::TEXT,''sha256'')%'
    OR v_definition LIKE '%extensions.digest(v_request::TEXT%'
    OR v_definition NOT LIKE '%requirement.stock_sku%'
    OR v_definition NOT LIKE '%requirement.stock_name%'
    OR v_definition LIKE '%JOIN public.products stock_product%' THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Dispatch stock core drift';
  END IF;
END
$guard$;

DO $patch$
DECLARE
  v_definition TEXT;
BEGIN
  SELECT pg_get_functiondef(
    'private.dispatch_sales_delivery_stock_core_odr3c(uuid,bigint,uuid,jsonb,text)'::regprocedure
  ) INTO v_definition;
  v_definition:=replace(v_definition,
    'digest(v_request::TEXT,''sha256'')',
    'extensions.digest(v_request::TEXT,''sha256'')');
  v_definition:=replace(v_definition,
    'requirement.stock_sku','stock_product.sku AS stock_sku');
  v_definition:=replace(v_definition,
    'requirement.stock_name','stock_product.name AS stock_name');
  v_definition:=replace(v_definition,
    'AND product.id=requirement.commercial_product_id',
    'AND product.id=requirement.commercial_product_id
       JOIN public.products stock_product
         ON stock_product.company_id=requirement.company_id
        AND stock_product.id=requirement.stock_product_id');
  IF v_definition NOT LIKE '%extensions.digest(v_request::TEXT%'
    OR v_definition LIKE '%requirement.stock_sku%'
    OR v_definition LIKE '%requirement.stock_name%'
    OR v_definition NOT LIKE '%stock_product.sku AS stock_sku%'
    OR v_definition NOT LIKE '%stock_product.name AS stock_name%'
    OR v_definition NOT LIKE '%JOIN public.products stock_product%' THEN
    RAISE EXCEPTION 'MIGRATION_PATCH_FAILED: Dispatch stock core compatibility';
  END IF;
  EXECUTE v_definition;
END
$patch$;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260901100000','odr_dispatch_runtime_schema_forward_fix',
  'Schema-qualify pgcrypto digest and resolve Product SKU/name snapshots from products instead of non-existent Sale Stock Requirement columns; no operational row backfill');

COMMIT;
