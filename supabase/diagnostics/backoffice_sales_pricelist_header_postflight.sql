WITH routine AS (
  SELECT p.oid,p.proname,pg_get_functiondef(p.oid) AS definition,
    p.prosecdef,coalesce(p.proconfig,'{}'::text[]) AS config
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname IN(
    'get_backoffice_sales_order_workspace','save_backoffice_sales_order_draft',
    'save_backoffice_sales_order_draft_before_pricelist_header')
), checks AS (
  SELECT 'migration_ledger' check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(count(*)-1) violation_rows,
    jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260909120000'
  UNION ALL
  SELECT 'backoffice_sales_pricelist_workspace_contract',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,CASE WHEN count(*)=1 THEN 0 ELSE 1 END,
    jsonb_build_object('routineRows',count(*))
  FROM routine WHERE proname='get_backoffice_sales_order_workspace'
    AND definition LIKE '%''pricelists''%' AND definition LIKE '%''defaultPricelistId''%'
  UNION ALL
  SELECT 'backoffice_sales_pricelist_save_contract',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,CASE WHEN count(*)=1 THEN 0 ELSE 1 END,
    jsonb_build_object('routineRows',count(*))
  FROM routine WHERE proname='save_backoffice_sales_order_draft'
    AND definition LIKE '%kgs.selected_pricelist_id%'
    AND definition LIKE '%kgs.backoffice_pricelist_id%'
    AND definition LIKE '%save_backoffice_sales_order_draft_before_pricelist_header%'
  UNION ALL
  SELECT 'canonical_pos_pricing_compatibility_wrapper',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,CASE WHEN count(*)=1 THEN 0 ELSE 1 END,
    jsonb_build_object('routineRows',count(*))
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='private' AND p.proname='resolve_pos_sale_price'
    AND pg_get_functiondef(p.oid) LIKE '%resolve_pos_sale_price_before_backoffice_header%'
    AND pg_get_functiondef(p.oid) LIKE '%kgs.backoffice_pricelist_id%'
  UNION ALL
  SELECT 'legacy_backoffice_save_browser_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('authenticatedExecutableRows',count(*))
  FROM routine WHERE proname='save_backoffice_sales_order_draft_before_pricelist_header'
    AND has_function_privilege('authenticated',oid,'EXECUTE')
  UNION ALL
  SELECT 'backoffice_sales_pricelist_runtime_inventory','INFO',0,
    jsonb_build_object('documents',(SELECT count(*) FROM public.backoffice_sales_orders),
      'documentsWithPricelist',(SELECT count(*) FROM public.backoffice_sales_orders WHERE pricelist_id IS NOT NULL),
      'activePricelists',(SELECT count(*) FROM public.pricelists WHERE is_active))
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
