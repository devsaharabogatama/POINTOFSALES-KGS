-- ODR Dispatch runtime schema-compatibility postflight.
-- SAFETY: SELECT-only.
WITH definition AS (
  SELECT pg_get_functiondef(
    'private.dispatch_sales_delivery_stock_core_odr3c(uuid,bigint,uuid,jsonb,text)'::regprocedure
  ) body
),checks AS (
  SELECT 'migration_ledger'::TEXT check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,count(*) violation_rows,
    jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260901100000'

  UNION ALL
  SELECT 'dispatch_digest_schema_contract',
    CASE WHEN body LIKE '%extensions.digest(v_request::TEXT%'
      AND body NOT LIKE '%:=encode(digest(v_request::TEXT%' THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN body LIKE '%extensions.digest(v_request::TEXT%'
      AND body NOT LIKE '%:=encode(digest(v_request::TEXT%' THEN 0 ELSE 1 END,
    jsonb_build_object('qualifiedDigest',
      body LIKE '%extensions.digest(v_request::TEXT%')
  FROM definition

  UNION ALL
  SELECT 'dispatch_product_snapshot_reference_contract',
    CASE WHEN body NOT LIKE '%requirement.stock_sku%'
        AND body NOT LIKE '%requirement.stock_name%'
        AND body LIKE '%stock_product.sku AS stock_sku%'
        AND body LIKE '%stock_product.name AS stock_name%'
        AND body LIKE '%stock_product.id=requirement.stock_product_id%'
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN body NOT LIKE '%requirement.stock_sku%'
        AND body NOT LIKE '%requirement.stock_name%'
        AND body LIKE '%stock_product.sku AS stock_sku%'
        AND body LIKE '%stock_product.name AS stock_name%'
        AND body LIKE '%stock_product.id=requirement.stock_product_id%'
      THEN 0 ELSE 1 END,
    jsonb_build_object('invalidRequirementReferences',
      (body LIKE '%requirement.stock_sku%')::INTEGER+
      (body LIKE '%requirement.stock_name%')::INTEGER,
      'stockProductJoin',body LIKE '%JOIN public.products stock_product%')
  FROM definition

  UNION ALL
  SELECT 'active_finance_posting_queue',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('runCount',count(*))
  FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
),inventory AS (
  SELECT 'dispatch_runtime_inventory'::TEXT check_name,'INFO'::TEXT status,
    0::BIGINT violation_rows,jsonb_build_object(
      'linkedReady',(SELECT count(*) FROM public.sales_delivery_documents
        WHERE reservation_id IS NOT NULL AND status='READY'),
      'linkedPartial',(SELECT count(*) FROM public.sales_delivery_documents
        WHERE reservation_id IS NOT NULL AND status='PARTIALLY_DISPATCHED'),
      'dispatchAllocations',(SELECT count(*) FROM public.sales_dispatch_allocations),
      'dispatchEffects',(SELECT count(*) FROM public.sales_dispatch_financial_effects)) details
)
SELECT * FROM (SELECT * FROM checks UNION ALL SELECT * FROM inventory) result
ORDER BY check_name;
