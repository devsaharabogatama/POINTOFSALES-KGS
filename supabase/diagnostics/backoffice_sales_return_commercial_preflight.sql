-- Read-only preflight for 20260917110000.
-- Run the entire file. BLOCKER means stop before migration.
WITH state AS (
  SELECT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260917110000') migration_applied
), checks AS (
  SELECT 'return_commercial_dependency_ledger' check_name,
    CASE WHEN count(*)=2 THEN 'PASS' ELSE 'BLOCKER' END status,
    2-count(*) violation_rows,
    jsonb_build_object('present',array_agg(version ORDER BY version),
      'expected',ARRAY['20260909152000','20260912140000']) details
  FROM private.kgs_schema_migrations
  WHERE version IN('20260909152000','20260912140000')
  UNION ALL
  SELECT 'return_commercial_relation_collision',
    CASE WHEN state.migration_applied AND count(*) FILTER(WHERE to_regclass('public.'||object_name) IS NOT NULL)=4 THEN 'PASS'
      WHEN NOT state.migration_applied AND count(*) FILTER(WHERE to_regclass('public.'||object_name) IS NOT NULL)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN state.migration_applied THEN abs(4-count(*) FILTER(WHERE to_regclass('public.'||object_name) IS NOT NULL))
      ELSE count(*) FILTER(WHERE to_regclass('public.'||object_name) IS NOT NULL) END,
    jsonb_build_object('migrationApplied',state.migration_applied,
      'existing',COALESCE(jsonb_agg(object_name ORDER BY object_name)
        FILTER(WHERE to_regclass('public.'||object_name) IS NOT NULL),'[]'::jsonb),
      'expected',CASE WHEN state.migration_applied THEN 4 ELSE 0 END)
  FROM state CROSS JOIN LATERAL (SELECT unnest(ARRAY[
    'backoffice_sales_returns','backoffice_sales_return_lines',
    'backoffice_sales_return_operations','backoffice_sales_return_audit']) object_name) expected
  GROUP BY state.migration_applied
  UNION ALL
  SELECT 'return_commercial_routine_collision',
    CASE WHEN state.migration_applied AND count(*) FILTER(WHERE to_regprocedure(signature) IS NOT NULL)=12 THEN 'PASS'
      WHEN NOT state.migration_applied AND count(*) FILTER(WHERE to_regprocedure(signature) IS NOT NULL)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN state.migration_applied THEN abs(12-count(*) FILTER(WHERE to_regprocedure(signature) IS NOT NULL))
      ELSE count(*) FILTER(WHERE to_regprocedure(signature) IS NOT NULL) END,
    jsonb_build_object('migrationApplied',state.migration_applied,
      'present',count(*) FILTER(WHERE to_regprocedure(signature) IS NOT NULL),
      'expected',CASE WHEN state.migration_applied THEN 12 ELSE 0 END)
  FROM state CROSS JOIN LATERAL (SELECT unnest(ARRAY[
    'private.trg_guard_backoffice_sales_return_history()',
    'private.backoffice_sales_return_snapshot(uuid,uuid)',
    'private.backoffice_sales_return_operation_retry(uuid,uuid,text,text)',
    'private.assert_backoffice_sales_return_quantities(uuid,uuid,uuid)',
    'private.transition_backoffice_sales_return(uuid,bigint,uuid,text,text)',
    'public.get_backoffice_sales_returns(text,text,integer)',
    'public.get_backoffice_sales_return(uuid)',
    'public.get_backoffice_sales_return_source(uuid)',
    'public.save_backoffice_sales_return_draft(uuid,bigint,uuid,uuid,jsonb)',
    'public.submit_backoffice_sales_return(uuid,bigint,uuid)',
    'public.approve_backoffice_sales_return(uuid,bigint,uuid)',
    'public.cancel_backoffice_sales_return(uuid,bigint,uuid,text)']) signature) expected
  GROUP BY state.migration_applied
  UNION ALL
  SELECT 'return_commercial_permission_collision',
    CASE WHEN state.migration_applied AND count(permission.permission_key)=1 THEN 'PASS'
      WHEN NOT state.migration_applied AND count(permission.permission_key)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN state.migration_applied THEN abs(1-count(permission.permission_key))
      ELSE count(permission.permission_key) END,
    jsonb_build_object('migrationApplied',state.migration_applied,
      'permissionRows',count(permission.permission_key))
  FROM state LEFT JOIN public.access_permission_catalog permission
    ON permission.permission_key='sales.backoffice_returns'
  GROUP BY state.migration_applied
  UNION ALL
  SELECT 'return_commercial_active_finance_queue',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*),
    jsonb_build_object('runRows',count(*)) FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'return_commercial_nonterminal_offline',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*),
    jsonb_build_object('submissionRows',count(*)) FROM public.pos_offline_sale_submissions
    WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
  UNION ALL
  SELECT 'return_commercial_behavior_fixture_contract',
    CASE WHEN EXISTS(SELECT 1 FROM public.profiles profile
        JOIN auth.users auth_user ON auth_user.id=profile.id
        WHERE profile.role='super_admin'::public.user_role)
      AND EXISTS(SELECT 1 FROM public.companies company
        WHERE company.status='ACTIVE'
          AND EXISTS(SELECT 1 FROM public.company_sales_process_settings setting
            WHERE setting.company_id=company.id)
          AND EXISTS(SELECT 1 FROM public.stores store
            JOIN public.warehouses warehouse ON warehouse.company_id=store.company_id
              AND warehouse.is_active AND warehouse.is_sale_source
              AND (warehouse.store_id IS NULL OR warehouse.store_id=store.id)
            WHERE store.company_id=company.id AND store.status='ACTIVE')
          AND EXISTS(SELECT 1 FROM public.customers customer
            WHERE customer.company_id=company.id AND customer.is_active)
          AND EXISTS(SELECT 1 FROM public.product_uoms product_uom
            JOIN public.products product ON product.company_id=product_uom.company_id
              AND product.id=product_uom.product_id AND product.is_active AND NOT product.is_bundle
            WHERE product_uom.company_id=company.id AND product_uom.is_active
              AND product_uom.sales_allowed AND product_uom.factor_to_base>0))
      THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN EXISTS(SELECT 1 FROM public.profiles profile
        JOIN auth.users auth_user ON auth_user.id=profile.id
        WHERE profile.role='super_admin'::public.user_role)
      AND EXISTS(SELECT 1 FROM public.companies company
        WHERE company.status='ACTIVE'
          AND EXISTS(SELECT 1 FROM public.company_sales_process_settings setting
            WHERE setting.company_id=company.id)
          AND EXISTS(SELECT 1 FROM public.stores store
            JOIN public.warehouses warehouse ON warehouse.company_id=store.company_id
              AND warehouse.is_active AND warehouse.is_sale_source
              AND (warehouse.store_id IS NULL OR warehouse.store_id=store.id)
            WHERE store.company_id=company.id AND store.status='ACTIVE')
          AND EXISTS(SELECT 1 FROM public.customers customer
            WHERE customer.company_id=company.id AND customer.is_active)
          AND EXISTS(SELECT 1 FROM public.product_uoms product_uom
            JOIN public.products product ON product.company_id=product_uom.company_id
              AND product.id=product_uom.product_id AND product.is_active AND NOT product.is_bundle
            WHERE product_uom.company_id=company.id AND product_uom.is_active
              AND product_uom.sales_allowed AND product_uom.factor_to_base>0))
      THEN 0 ELSE 1 END,
    jsonb_build_object('required',ARRAY['super_admin','active Company + sales process setting',
      'compatible active Store/Warehouse','active Customer','active Sales Product-UOM'])
  UNION ALL
  SELECT 'return_commercial_runtime_inventory','INFO',0,
    jsonb_build_object('confirmedOrdersWithAcceptedQty',count(DISTINCT sales_order.id),
      'acceptedLines',count(line.id))
  FROM public.backoffice_sales_orders sales_order
  JOIN public.backoffice_sales_order_lines line ON line.company_id=sales_order.company_id
    AND line.sales_order_id=sales_order.id AND line.accepted_base_qty>line.returned_before_invoice_base_qty
  WHERE sales_order.status='CONFIRMED'
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 0 WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
