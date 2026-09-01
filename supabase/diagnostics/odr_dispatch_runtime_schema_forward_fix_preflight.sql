-- ODR Dispatch runtime schema-compatibility forward-fix preflight.
-- SAFETY: SELECT-only.
WITH routine AS (
  SELECT to_regprocedure(
    'private.dispatch_sales_delivery_stock_core_odr3c(uuid,bigint,uuid,jsonb,text)'
  ) signature
),definition AS (
  SELECT CASE WHEN signature IS NULL THEN NULL
    ELSE pg_get_functiondef(signature) END body
  FROM routine
),checks AS (
  SELECT 'dispatch_runtime_dependency'::TEXT check_name,
    CASE WHEN count(*)=4 THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('expected',4,'ledgerRows',count(*),'requiredVersions',
      ARRAY['20260828140000','20260828230000','20260828240000','20260828250000']) details
  FROM private.kgs_schema_migrations
  WHERE version=ANY(ARRAY[
    '20260828140000','20260828230000','20260828240000','20260828250000'])

  UNION ALL
  SELECT 'dispatch_stock_core_state',
    CASE WHEN signature IS NOT NULL THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('routineExists',signature IS NOT NULL)
  FROM routine

  UNION ALL
  SELECT 'dispatch_digest_extension_contract',
    CASE WHEN to_regprocedure('extensions.digest(text,text)') IS NOT NULL
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('digestExists',
      to_regprocedure('extensions.digest(text,text)') IS NOT NULL)

  UNION ALL
  SELECT 'dispatch_requirement_schema_contract',
    CASE WHEN count(*)=5 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('expected',5,'columnRows',count(*))
  FROM information_schema.columns
  WHERE table_schema='public' AND table_name='sale_stock_requirements'
    AND column_name=ANY(ARRAY['commercial_product_id','stock_product_id',
      'stock_uom_id','stock_uom_name_snapshot','quantity_uom'])

  UNION ALL
  SELECT 'dispatch_runtime_schema_compatibility',
    CASE WHEN body IS NULL THEN 'BLOCKER'
      WHEN body LIKE '%extensions.digest(v_request::TEXT%'
        AND body NOT LIKE '%requirement.stock_sku%'
        AND body NOT LIKE '%requirement.stock_name%'
        AND body LIKE '%JOIN public.products stock_product%'
      THEN 'PASS' ELSE 'BACKFILL' END,
    jsonb_build_object(
      'digestQualified',body LIKE '%extensions.digest(v_request::TEXT%',
      'invalidRequirementSkuReference',body LIKE '%requirement.stock_sku%',
      'invalidRequirementNameReference',body LIKE '%requirement.stock_name%',
      'stockProductReferenceJoin',body LIKE '%JOIN public.products stock_product%')
  FROM definition
),inventory AS (
  SELECT 'dispatch_forward_fix_inventory'::TEXT check_name,'INFO'::TEXT status,
    jsonb_build_object(
      'deliveryReservationColumn',EXISTS(SELECT 1
        FROM information_schema.columns WHERE table_schema='public'
          AND table_name='sales_delivery_documents'
          AND column_name='reservation_id'),
      'reservationRelationExists',
        to_regclass('public.sales_stock_reservations') IS NOT NULL,
      'activeFinanceQueues',(SELECT count(*) FROM public.finance_posting_queue_runs
        WHERE status IN('PREVIEWED','APPROVED','PROCESSING'))) details
)
SELECT * FROM (SELECT * FROM checks UNION ALL SELECT * FROM inventory) result
ORDER BY check_name;
