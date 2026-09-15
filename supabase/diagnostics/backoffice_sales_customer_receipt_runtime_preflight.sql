-- Read-only preflight for 20260909154000. Run on isolated Development only.
WITH checks AS (
  SELECT 'migration_dependency' check_name,
    CASE WHEN EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260909153000') THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('required','20260909153000') details
  UNION ALL
  SELECT 'active_finance_queue',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('rowCount',count(*)) FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'nonterminal_offline_submission',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('rowCount',count(*)) FROM public.pos_offline_sale_submissions
    WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
  UNION ALL
  SELECT 'receipt_runtime_collision',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('routineRows',count(*)) FROM pg_proc proc
    JOIN pg_namespace ns ON ns.oid=proc.pronamespace
    WHERE ns.nspname IN('public','private') AND proc.proname IN(
      'receive_backoffice_sales_delivery','receive_backoffice_sales_delivery_core')
  UNION ALL
  SELECT 'receipt_finance_mapping_inventory','INFO',
    jsonb_build_object('mappingRows',count(*)) FROM (
      SELECT category.company_id,rule.account_function_key
      FROM public.transaction_categories category
      JOIN public.transaction_account_rules rule ON rule.company_id=category.company_id
       AND rule.transaction_category_id=category.id AND rule.status='ACTIVE'
      WHERE category.system_key='BACKOFFICE_CUSTOMER_RECEIPT' AND category.is_active
        AND rule.account_function_key IN('COGS','INVENTORY_ASSET')
    ) mapped
  UNION ALL
  SELECT 'receipt_mapping_company_completeness',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('invalidCompanies',count(*))
  FROM (SELECT company.id FROM public.companies company WHERE company.status='ACTIVE'
    AND (SELECT count(DISTINCT rule.account_function_key)
      FROM public.transaction_categories category
      JOIN public.transaction_account_rules rule ON rule.company_id=category.company_id
       AND rule.transaction_category_id=category.id AND rule.status='ACTIVE'
      WHERE category.company_id=company.id
        AND category.system_key='BACKOFFICE_CUSTOMER_RECEIPT' AND category.is_active
        AND rule.account_function_key IN('COGS','INVENTORY_ASSET'))<>2) invalid
  UNION ALL
  SELECT 'in_transit_delivery_inventory','INFO',jsonb_build_object('rowCount',count(*))
  FROM public.backoffice_sales_delivery_orders WHERE status='IN_TRANSIT'
)
SELECT check_name,status,CASE WHEN status='BLOCKER' THEN 1 ELSE 0 END violation_rows,details
FROM checks ORDER BY check_name;
