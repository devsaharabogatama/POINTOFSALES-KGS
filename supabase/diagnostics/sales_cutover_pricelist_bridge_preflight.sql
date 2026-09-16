-- SELECT-only preflight. Run the entire file and retain its single result set.
WITH definition AS (
  SELECT pg_get_functiondef(
    'private.convert_retail_sale_to_backoffice_order(uuid,uuid,uuid,uuid)'::regprocedure) body
), checks(check_name,status,violation_rows,details) AS (
  SELECT 'pricelist_bridge_dependency_ledger',
    CASE WHEN count(*)=2 THEN 'PASS' ELSE 'BLOCKER' END,
    2-count(*),jsonb_build_object('expected',2,'present',count(*))
  FROM private.kgs_schema_migrations
  WHERE version IN('20260911100000','20260916100000')
  UNION ALL
  SELECT 'pricelist_bridge_migration_collision',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*),
    jsonb_build_object('installed',count(*)>0)
  FROM private.kgs_schema_migrations WHERE version='20260916120000'
  UNION ALL
  SELECT 'pricelist_bridge_runtime_contract',
    CASE WHEN position('v_pricelist uuid;v_pricelist_count bigint;' IN body)>0
      AND position('''selectedPricelistId'',NULL' IN body)>0
      AND position('pricelist_id=v_pricelist,' IN body)>0
      AND position('COALESCE(to_jsonb(request_line),''null''::jsonb)' IN body)>0
      AND position('COALESCE(to_jsonb(request_document),''null''::jsonb)' IN body)>0
      THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN position('v_pricelist uuid;v_pricelist_count bigint;' IN body)>0
      AND position('''selectedPricelistId'',NULL' IN body)>0
      AND position('pricelist_id=v_pricelist,' IN body)>0
      AND position('COALESCE(to_jsonb(request_line),''null''::jsonb)' IN body)>0
      AND position('COALESCE(to_jsonb(request_document),''null''::jsonb)' IN body)>0
      THEN 0 ELSE 1 END,
    jsonb_build_object('legacyPayloadNull',position('''selectedPricelistId'',NULL' IN body)>0,
      'sourcePricelistRestore',position('pricelist_id=v_pricelist,' IN body)>0,
      'procurementNullFix',position('COALESCE(to_jsonb(request_line),''null''::jsonb)' IN body)>0)
  FROM definition
  UNION ALL
  SELECT 'pricelist_bridge_active_finance_queue',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*),jsonb_build_object('runRows',count(*))
  FROM public.finance_posting_queue_runs WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'pricelist_bridge_nonterminal_offline',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*),jsonb_build_object('submissionRows',count(*))
  FROM public.pos_offline_sale_submissions WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
  UNION ALL
  SELECT 'pricelist_bridge_open_plan_inventory','INFO',0,
    jsonb_build_object('plans',count(*),'rule','Open plans are retained; migration changes runtime only')
  FROM public.sales_process_cutover_plans WHERE status IN('DRAFT','PREVIEWED','APPLYING')
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;
