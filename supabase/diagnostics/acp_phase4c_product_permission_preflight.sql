-- ACP-4C preflight: inventory.products complete-cutover readiness.
-- SAFETY: one SELECT statement; aggregate metadata only.

WITH product_relations(relation_name) AS (
  VALUES('products'),('product_uoms')
), mutation_routines(routine_name) AS (
  VALUES('save_product_with_uoms'),('save_product_tax_assignment')
), product_routines AS (
  SELECT p.oid,p.proname,pg_get_function_identity_arguments(p.oid) arguments,
         pg_get_functiondef(p.oid) definition
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public'
    AND p.proname IN(SELECT routine_name FROM mutation_routines)
), import_routines AS (
  SELECT p.oid,p.proname,pg_get_function_identity_arguments(p.oid) arguments,
         pg_get_functiondef(p.oid) definition
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE p.proname IN(
    'import_products_for_company','create_master_import_job',
    'validate_master_import_job','commit_master_import_job'
  )
), checks AS (
  SELECT 'acp_phase4b_dependency'::TEXT check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('ledger_rows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260812140000'

  UNION ALL
  SELECT 'product_permission_catalog_state',
    CASE WHEN count(*)=1 AND COALESCE(bool_and(
      enforcement_status='SHADOW' AND is_customizable
    ),FALSE) THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('rows',count(*),'statuses',COALESCE(
      jsonb_agg(enforcement_status),'[]'::JSONB))
  FROM public.access_permission_catalog
  WHERE permission_key='inventory.products'

  UNION ALL
  SELECT 'product_direct_write_boundary',
    CASE WHEN count(*) FILTER(WHERE has_table_privilege(
      'authenticated',format('public.%I',relation_name),'INSERT,UPDATE,DELETE'
    ))=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('direct_write_relations',COALESCE(jsonb_agg(relation_name)
      FILTER(WHERE has_table_privilege(
        'authenticated',format('public.%I',relation_name),'INSERT,UPDATE,DELETE'
      )),'[]'::JSONB))
  FROM product_relations

  UNION ALL
  SELECT 'product_mutation_routine_state',
    CASE WHEN count(DISTINCT proname)=2 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('routine_names',count(DISTINCT proname),
      'signature_rows',count(*),'authenticated_executable_rows',count(*) FILTER(
        WHERE has_function_privilege('authenticated',oid,'EXECUTE')))
  FROM product_routines

  UNION ALL
  SELECT 'product_runtime_permission_hook_state',
    CASE WHEN count(*) FILTER(WHERE definition ILIKE '%inventory.products%')=0
      THEN 'SETUP' ELSE 'REVIEW' END,
    jsonb_build_object('hooked_rows',count(*) FILTER(
      WHERE definition ILIKE '%inventory.products%'),
      'routine_rows',count(*))
  FROM product_routines

  UNION ALL
  SELECT 'legacy_product_import_browser_execution',
    CASE WHEN count(*) FILTER(
      WHERE proname='import_products_for_company'
        AND has_function_privilege('authenticated',oid,'EXECUTE')
    )=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('authenticated_executable_rows',count(*) FILTER(
      WHERE proname='import_products_for_company'
        AND has_function_privilege('authenticated',oid,'EXECUTE')))
  FROM import_routines

  UNION ALL
  SELECT 'canonical_product_import_permission_hook_state',
    CASE WHEN count(*) FILTER(
      WHERE proname IN('create_master_import_job','commit_master_import_job')
        AND definition ILIKE '%inventory.products%'
    )=0 THEN 'SETUP' ELSE 'REVIEW' END,
    jsonb_build_object('hooked_rows',count(*) FILTER(
      WHERE proname IN('create_master_import_job','commit_master_import_job')
        AND definition ILIKE '%inventory.products%'),
      'routine_rows',count(*))
  FROM import_routines

  UNION ALL
  SELECT 'product_page_shared_reference_consumer_scope','REVIEW',
    jsonb_build_object('required_design',jsonb_build_array(
      'separate guarded Product-management read from cross-module Product reference reads',
      'do not let a client-supplied purpose bypass inventory.products',
      'keep Bundle on sales.bundles and Supplier relation on Contacts/Purchase authority'
    ))

  UNION ALL
  SELECT 'product_existing_override_scope','INFO',
    jsonb_build_object('rows',count(*),'companies',count(DISTINCT company_id),
      'users',count(DISTINCT user_id))
  FROM public.user_company_permission_overrides
  WHERE permission_key='inventory.products'

  UNION ALL
  SELECT 'product_history_inventory','INFO',jsonb_build_object(
    'products',(SELECT count(*) FROM public.products),
    'active_products',(SELECT count(*) FROM public.products WHERE is_active),
    'product_uoms',(SELECT count(*) FROM public.product_uoms),
    'products_with_stock_history',(SELECT count(DISTINCT product_id)
      FROM public.stock_movements),
    'products_with_sales_history',(SELECT count(DISTINCT product_id)
      FROM public.sales_details),
    'products_with_purchase_history',(SELECT count(DISTINCT product_id)
      FROM public.purchases_details),
    'nonterminal_import_jobs',(SELECT count(*) FROM public.master_import_jobs
      WHERE status NOT IN('COMPLETED','COMPLETED_WITH_ERRORS','FAILED','CANCELED'))
  )
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'REVIEW' THEN 2
  WHEN 'SETUP' THEN 3 WHEN 'PASS' THEN 4 ELSE 5 END,check_name;
