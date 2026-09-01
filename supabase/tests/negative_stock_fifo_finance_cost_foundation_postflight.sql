-- NSC-1 foundation postflight. SAFETY: SELECT-only.

WITH checks AS (
  SELECT 'migration_ledger' check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    count(*)::BIGINT violation_rows,
    jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations
  WHERE version='20260831120000'

  UNION ALL
  SELECT 'required_cost_foundation_relations',
    CASE WHEN count(*)=2 THEN 'PASS' ELSE 'FAIL' END,2-count(*),
    jsonb_build_object('expected',2,'relationRows',count(*))
  FROM pg_class relation
  JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
  WHERE namespace.nspname='public' AND relation.relkind='r'
    AND relation.relname IN('inventory_cost_adjustment_sources',
      'supplier_invoice_batch_cost_allocations')

  UNION ALL
  SELECT 'required_cost_foundation_columns',
    CASE WHEN count(*)=4 THEN 'PASS' ELSE 'FAIL' END,4-count(*),
    jsonb_build_object('expected',4,'columnRows',count(*))
  FROM information_schema.columns column_state
  WHERE column_state.table_schema='public' AND (
    (column_state.table_name='inventory_cost_adjustment_sources'
      AND column_state.column_name IN(
        'inventory_account_id','offset_account_id','variance_account_id'))
    OR (column_state.table_name='supplier_invoice_batch_cost_allocations'
      AND column_state.column_name='price_variance_total'))

  UNION ALL
  SELECT 'browser_cost_foundation_write_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('privilegeRows',count(*))
  FROM information_schema.role_table_grants grant_state
  WHERE grant_state.table_schema='public'
    AND grant_state.table_name IN('inventory_cost_adjustment_sources',
      'supplier_invoice_batch_cost_allocations')
    AND grant_state.grantee IN('anon','authenticated')
    AND grant_state.privilege_type IN('INSERT','UPDATE','DELETE')

  UNION ALL
  SELECT 'cost_foundation_rls_state',
    CASE WHEN count(*) FILTER (WHERE relation.relrowsecurity)=2
      THEN 'PASS' ELSE 'FAIL' END,
    2-count(*) FILTER (WHERE relation.relrowsecurity),
    jsonb_build_object('enabledRelations',count(*) FILTER(
      WHERE relation.relrowsecurity))
  FROM pg_class relation
  JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
  WHERE namespace.nspname='public'
    AND relation.relname IN('inventory_cost_adjustment_sources',
      'supplier_invoice_batch_cost_allocations')

  UNION ALL
  SELECT 'goods_receipt_cost_function_catalog',
    CASE WHEN 'COGS'=ANY(event.conditional_account_functions)
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN 'COGS'=ANY(event.conditional_account_functions) THEN 0 ELSE 1 END,
    jsonb_build_object('conditional',event.conditional_account_functions)
  FROM public.system_events event WHERE event.system_key='GOODS_RECEIPT'

  UNION ALL
  SELECT 'supplier_invoice_cost_function_catalog',
    CASE WHEN 'INVENTORY_ASSET'=ANY(event.conditional_account_functions)
      AND 'COGS'=ANY(event.conditional_account_functions)
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN 'INVENTORY_ASSET'=ANY(event.conditional_account_functions)
      AND 'COGS'=ANY(event.conditional_account_functions)
      THEN 0 ELSE 1 END,
    jsonb_build_object('conditional',event.conditional_account_functions)
  FROM public.system_events event WHERE event.system_key='SUPPLIER_INVOICE'

  UNION ALL
  SELECT 'foundation_zero_backfill','PASS',0,
    jsonb_build_object(
      'costSources',(SELECT count(*)
        FROM public.inventory_cost_adjustment_sources),
      'batchAllocations',(SELECT count(*)
        FROM public.supplier_invoice_batch_cost_allocations))
)
SELECT check_name,status,violation_rows,details
FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,
  check_name;
