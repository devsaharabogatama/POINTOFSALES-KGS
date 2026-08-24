-- SELECT-only postflight for distributor Pricelist import.
WITH checks AS(
  SELECT 'migration_ledger' AS check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END AS status,
    jsonb_build_object('ledgerRows',count(*)) AS details
  FROM private.kgs_schema_migrations WHERE version='20260824110000'
  UNION ALL
  SELECT 'required_import_runtime',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('routineRows',count(*))
  FROM pg_proc routine JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
  WHERE namespace.nspname='public' AND routine.proname='process_distributor_pricelist_import'
    AND pg_get_function_identity_arguments(routine.oid)=
      'p_rows jsonb, p_source_file_name text, p_source_file_checksum text, p_client_request_id uuid, p_apply boolean, p_confirmation text'
  UNION ALL
  SELECT 'pricelist_import_permission',
    CASE WHEN count(*)=1 AND bool_and('IMPORT'=ANY(supported_capabilities))
      THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('catalogRows',count(*),'supportsImport',
      COALESCE(bool_and('IMPORT'=ANY(supported_capabilities)),FALSE))
  FROM public.access_permission_catalog WHERE permission_key='sales.pricelists'
  UNION ALL
  SELECT 'import_history_boundary',
    CASE WHEN to_regclass('public.pricelist_import_runs') IS NOT NULL
      AND NOT has_table_privilege('authenticated','public.pricelist_import_runs','SELECT')
      AND NOT has_table_privilege('authenticated','public.pricelist_import_runs','INSERT')
      AND NOT has_table_privilege('authenticated','public.pricelist_import_runs','UPDATE')
      AND NOT has_table_privilege('authenticated','public.pricelist_import_runs','DELETE')
      THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('tableExists',to_regclass('public.pricelist_import_runs') IS NOT NULL,
      'authenticatedReadable',has_table_privilege('authenticated','public.pricelist_import_runs','SELECT'),
      'authenticatedWritable',has_table_privilege('authenticated','public.pricelist_import_runs','INSERT,UPDATE,DELETE'))
  UNION ALL
  SELECT 'import_history_immutable_trigger',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('triggerRows',count(*))
  FROM pg_trigger trigger
  WHERE trigger.tgrelid='public.pricelist_import_runs'::regclass
    AND trigger.tgname='trg_guard_pricelist_import_history' AND trigger.tgenabled<>'D'
  UNION ALL
  SELECT 'import_runtime_contract',
    CASE WHEN count(*)=1 AND bool_and(routine.prosecdef)
      AND bool_and(lower(routine.prosrc) LIKE '%active_pack_sales_uom_not_found%')
      AND bool_and(lower(routine.prosrc) LIKE '%base_uom_equivalent%')
      AND bool_and(lower(routine.prosrc) LIKE '%pricelist_import_idempotency_conflict%')
      AND bool_and(lower(routine.prosrc) LIKE '%active_product_sku_not_found_skipped%')
      AND bool_and(lower(routine.prosrc) LIKE '%skippedrowcount%')
      AND bool_and(lower(routine.prosrc) LIKE '%inventory.products%' )
      AND bool_and(lower(routine.prosrc) LIKE '%sales.pricelists%')
      THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('routineRows',count(*))
  FROM pg_proc routine JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
  WHERE namespace.nspname='public' AND routine.proname='process_distributor_pricelist_import'
  UNION ALL
  SELECT 'product_price_precision',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('invalidRows',count(*))
  FROM public.product_uoms product_uom
  WHERE product_uom.purchase_price IS NOT NULL
      AND product_uom.purchase_price<>round(product_uom.purchase_price,4)
     OR product_uom.sale_price IS NOT NULL
      AND product_uom.sale_price<>round(product_uom.sale_price,4)
  UNION ALL
  SELECT 'pricelist_import_runtime_inventory','INFO',jsonb_build_object(
    'runs',count(*),'companies',count(DISTINCT company_id),
    'productsApplied',COALESCE(sum(applied_product_count),0),
    'pricelistsApplied',COALESCE(sum(applied_pricelist_count),0))
  FROM public.pricelist_import_runs
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;
