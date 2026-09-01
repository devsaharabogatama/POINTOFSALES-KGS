-- ODR Dispatch runtime schema-compatibility behavior.
-- No business row is mutated.
BEGIN;

DO $test$
DECLARE
  v_definition TEXT;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260901100000') THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: 20260901100000 required';
  END IF;
  SELECT pg_get_functiondef(
    'private.dispatch_sales_delivery_stock_core_odr3c(uuid,bigint,uuid,jsonb,text)'::regprocedure
  ) INTO v_definition;
  IF v_definition NOT LIKE '%extensions.digest(v_request::TEXT%'
    OR v_definition LIKE '%requirement.stock_sku%'
    OR v_definition LIKE '%requirement.stock_name%'
    OR v_definition NOT LIKE '%stock_product.sku AS stock_sku%'
    OR v_definition NOT LIKE '%stock_product.name AS stock_name%'
    OR v_definition NOT LIKE '%JOIN public.products stock_product%'
    OR v_definition NOT LIKE '%stock_product.id=requirement.stock_product_id%' THEN
    RAISE EXCEPTION 'TEST_FAILED: Dispatch runtime schema compatibility invalid';
  END IF;
  IF v_definition NOT LIKE '%pg_advisory_xact_lock%'
    OR v_definition NOT LIKE '%UPDATE public.product_batches%'
    OR v_definition NOT LIKE '%INSERT INTO public.product_stocks%'
    OR v_definition NOT LIKE '%INSERT INTO public.stock_movements%'
    OR v_definition NOT LIKE '%IDEMPOTENCY_PAYLOAD_CONFLICT%' THEN
    RAISE EXCEPTION 'TEST_FAILED: canonical Dispatch invariant changed';
  END IF;
END
$test$;

SELECT 'odr_dispatch_runtime_schema_forward_fix_behavior' check_name,
  'PASS' status,jsonb_build_object('tested',ARRAY[
    'schema-qualified pgcrypto digest','Product snapshot reference join',
    'canonical stock/FIFO/Movement contract preserved']) details;

ROLLBACK;
