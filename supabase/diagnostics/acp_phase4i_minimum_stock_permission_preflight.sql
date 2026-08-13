-- ACP-4I preflight: Minimum Stock permission and read/import/export boundary.
-- SAFETY: one SELECT statement; aggregate metadata only; no business identity.

WITH required_versions(version) AS (
  VALUES ('20260812200000')
), expected_relations(relation_name) AS (
  VALUES ('product_warehouse_stock_settings'),
    ('product_warehouse_stock_setting_audit')
), expected_columns(relation_name,column_name) AS (
  VALUES
    ('product_warehouse_stock_settings','id'),
    ('product_warehouse_stock_settings','company_id'),
    ('product_warehouse_stock_settings','product_id'),
    ('product_warehouse_stock_settings','warehouse_id'),
    ('product_warehouse_stock_settings','minimum_stock_base_qty'),
    ('product_warehouse_stock_settings','low_stock_alert_enabled'),
    ('product_warehouse_stock_settings','master_version'),
    ('product_warehouse_stock_setting_audit','setting_id'),
    ('product_warehouse_stock_setting_audit','action'),
    ('product_warehouse_stock_setting_audit','actor_id'),
    ('product_warehouse_stock_setting_audit','before_state'),
    ('product_warehouse_stock_setting_audit','after_state')
), mutation_routines AS (
  SELECT procedure.oid,procedure.proname,
    pg_get_functiondef(procedure.oid) definition
  FROM pg_proc procedure JOIN pg_namespace namespace
    ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname='public'
    AND procedure.proname='save_product_warehouse_stock_setting'
), import_routine_names(routine_name) AS (
  VALUES ('create_master_import_job'),('stage_master_import_rows'),
    ('validate_master_import_job'),('commit_master_import_job')
), import_routines AS (
  SELECT procedure.oid,procedure.proname,
    pg_get_functiondef(procedure.oid) definition
  FROM pg_proc procedure JOIN pg_namespace namespace
    ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname='public'
    AND procedure.proname IN(SELECT routine_name FROM import_routine_names)
), valid_base_uom_product AS (
  SELECT product.company_id,product.id product_id,uom.allow_decimal,
    uom.decimal_precision
  FROM public.products product
  JOIN public.product_uoms product_uom
    ON product_uom.company_id=product.company_id
   AND product_uom.product_id=product.id
   AND product_uom.uom_id=product.uom_id
   AND product_uom.factor_to_base=1 AND product_uom.is_active
  JOIN public.uoms uom ON uom.company_id=product_uom.company_id
    AND uom.id=product_uom.uom_id AND uom.is_active
  WHERE product.is_active AND NOT product.is_bundle
), checks AS (
  SELECT 'acp_phase4h_dependency'::TEXT check_name,
    CASE WHEN count(*) FILTER(WHERE ledger.version IS NULL)=0
      THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('expected',count(*),'missing',COALESCE(
      jsonb_agg(required.version ORDER BY required.version)
        FILTER(WHERE ledger.version IS NULL),'[]'::JSONB)) details
  FROM required_versions required LEFT JOIN private.kgs_schema_migrations ledger
    ON ledger.version=required.version

  UNION ALL
  SELECT 'minimum_stock_permission_catalog_state',
    CASE WHEN count(*)=1 AND count(*) FILTER(WHERE
      enforcement_status='SHADOW' AND is_customizable
      AND view_roles=ARRAY[
        'COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','WAREHOUSE_ADMIN']::TEXT[]
      AND operator_roles=ARRAY[
        'COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','WAREHOUSE_ADMIN']::TEXT[]
      AND supported_capabilities @> ARRAY[
        'VIEW','MANAGE','EXPORT','IMPORT']::TEXT[])=1
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('rows',count(*),'statuses',COALESCE(
      jsonb_agg(enforcement_status),'[]'::JSONB),'capabilities',COALESCE(
      (SELECT to_jsonb(supported_capabilities)
       FROM public.access_permission_catalog
       WHERE permission_key='inventory.minimum_stock'),'[]'::JSONB))
  FROM public.access_permission_catalog
  WHERE permission_key='inventory.minimum_stock'

  UNION ALL
  SELECT 'canonical_minimum_stock_schema_state',
    CASE WHEN count(*) FILTER(WHERE relation.oid IS NULL)=0
      AND count(*) FILTER(WHERE column_state.column_name IS NULL)=0
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('missing_relations',COALESCE(jsonb_agg(DISTINCT
      expected.relation_name) FILTER(WHERE relation.oid IS NULL),'[]'::JSONB),
      'missing_columns',COALESCE(jsonb_agg(
        expected.relation_name||'.'||expected.column_name
        ORDER BY expected.relation_name,expected.column_name)
        FILTER(WHERE column_state.column_name IS NULL),'[]'::JSONB))
  FROM expected_columns expected
  LEFT JOIN pg_class relation ON relation.oid=to_regclass(
    'public.'||expected.relation_name)
  LEFT JOIN information_schema.columns column_state
    ON column_state.table_schema='public'
   AND column_state.table_name=expected.relation_name
   AND column_state.column_name=expected.column_name

  UNION ALL
  SELECT 'canonical_minimum_stock_read_rpc_state',
    CASE WHEN to_regprocedure('public.get_inventory_minimum_stock()') IS NULL
      THEN 'SETUP' ELSE 'PASS' END,
    jsonb_build_object('rpc_exists',to_regprocedure(
      'public.get_inventory_minimum_stock()') IS NOT NULL,
      'required_design',jsonb_build_array(
        'guard the composed read with inventory.minimum_stock VIEW',
        'return settings, narrow Product/Base-UOM and Warehouse references, and current balance only',
        'do not require inventory.stock_real or inventory.master_data VIEW'))

  UNION ALL
  SELECT 'minimum_stock_runtime_permission_hook_state',
    CASE WHEN count(*)=1 AND count(*) FILTER(WHERE
      definition ILIKE '%acp_require_permission_capability%'
      AND definition ILIKE '%inventory.minimum_stock%')=1
      THEN 'PASS' ELSE 'SETUP' END,
    jsonb_build_object('routine_rows',count(*),'hooked_rows',count(*) FILTER(
      WHERE definition ILIKE '%acp_require_permission_capability%'
        AND definition ILIKE '%inventory.minimum_stock%'))
  FROM mutation_routines

  UNION ALL
  SELECT 'minimum_stock_import_permission_hook_state',
    CASE WHEN count(DISTINCT proname)=4 AND count(*) FILTER(WHERE
      definition ILIKE '%PRODUCT_WAREHOUSE_MINIMUM_STOCK%'
      AND definition ILIKE '%inventory.minimum_stock%')=4
      THEN 'PASS' ELSE 'SETUP' END,
    jsonb_build_object('routine_rows',count(*),'hooked_rows',count(*) FILTER(
      WHERE definition ILIKE '%PRODUCT_WAREHOUSE_MINIMUM_STOCK%'
        AND definition ILIKE '%inventory.minimum_stock%'))
  FROM import_routines

  UNION ALL
  SELECT 'minimum_stock_direct_read_cutover_scope','REVIEW',
    jsonb_build_object('authenticated_read_relations',COALESCE(
      jsonb_agg(relation_name ORDER BY relation_name) FILTER(WHERE
        has_table_privilege('authenticated',
          format('public.%I',relation_name),'SELECT')),'[]'::JSONB),
      'required_design',jsonb_build_array(
        'replace browser setting/audit reads with a VIEW-guarded composed RPC',
        'revoke direct SELECT only after active UI and export consumers migrate'))
  FROM expected_relations

  UNION ALL
  SELECT 'minimum_stock_shared_consumer_scope','REVIEW',
    jsonb_build_object('current_dependencies',jsonb_build_array(
      'Minimum Stock page reads Product references',
      'Minimum Stock page reads Master Warehouse endpoint',
      'Minimum Stock page requires Stock Real overview for current balance',
      'Global Data Exchange uses role-only Minimum Stock export/import'),
      'required_design',jsonb_build_array(
        'Minimum Stock capability must authorize its own narrow references and balances',
        'Stock Real and Master Data restriction must not break Minimum Stock VIEW',
        'Export and type-aware import must enforce inventory.minimum_stock capability',
        'a client-supplied purpose must never bypass another permission'))

  UNION ALL
  SELECT 'minimum_stock_store_scope_decision','REVIEW',
    jsonb_build_object('current_runtime',
      'Store Manager and Warehouse Admin can configure any active Company Warehouse',
      'decision_required',
      'preserve reviewed Company-wide baseline or restrict Store Manager to assigned Store Warehouse before enforcement')

  UNION ALL
  SELECT 'minimum_stock_direct_write_boundary',
    CASE WHEN count(*) FILTER(WHERE has_table_privilege('authenticated',
      format('public.%I',relation_name),'INSERT,UPDATE,DELETE'))=0
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('direct_write_relations',COALESCE(
      jsonb_agg(relation_name ORDER BY relation_name) FILTER(WHERE
        has_table_privilege('authenticated',format('public.%I',relation_name),
          'INSERT,UPDATE,DELETE')),'[]'::JSONB))
  FROM expected_relations

  UNION ALL
  SELECT 'guarded_minimum_stock_mutation_routine',
    CASE WHEN count(*)=1
      AND count(*) FILTER(WHERE has_function_privilege(
        'authenticated',oid,'EXECUTE'))=1
      AND count(*) FILTER(WHERE has_function_privilege('anon',oid,'EXECUTE'))=0
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('routine_rows',count(*),'authenticated_rows',count(*)
      FILTER(WHERE has_function_privilege('authenticated',oid,'EXECUTE')))
  FROM mutation_routines

  UNION ALL
  SELECT 'duplicate_product_warehouse_minimum_stock',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('duplicate_groups',count(*))
  FROM (SELECT company_id,product_id,warehouse_id
    FROM public.product_warehouse_stock_settings
    GROUP BY company_id,product_id,warehouse_id HAVING count(*)>1) duplicate_pair

  UNION ALL
  SELECT 'invalid_minimum_stock_value',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('row_count',count(*))
  FROM public.product_warehouse_stock_settings setting
  LEFT JOIN valid_base_uom_product product
    ON product.company_id=setting.company_id
   AND product.product_id=setting.product_id
  WHERE setting.minimum_stock_base_qty<0
    OR (setting.low_stock_alert_enabled
      AND setting.minimum_stock_base_qty IS NULL)
    OR (setting.minimum_stock_base_qty IS NOT NULL AND product.product_id IS NOT NULL
      AND ((NOT product.allow_decimal
          AND setting.minimum_stock_base_qty<>trunc(setting.minimum_stock_base_qty))
        OR (product.allow_decimal AND setting.minimum_stock_base_qty<>
          round(setting.minimum_stock_base_qty,product.decimal_precision))))

  UNION ALL
  SELECT 'minimum_stock_tenant_reference_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('orphan_or_cross_tenant_rows',count(*))
  FROM public.product_warehouse_stock_settings setting
  LEFT JOIN public.companies company ON company.id=setting.company_id
  LEFT JOIN public.products product ON product.company_id=setting.company_id
    AND product.id=setting.product_id
  LEFT JOIN public.warehouses warehouse
    ON warehouse.company_id=setting.company_id
   AND warehouse.id=setting.warehouse_id
  WHERE company.id IS NULL OR product.id IS NULL OR warehouse.id IS NULL

  UNION ALL
  SELECT 'active_minimum_stock_invalid_operational_reference',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('row_count',count(*))
  FROM public.product_warehouse_stock_settings setting
  LEFT JOIN valid_base_uom_product product
    ON product.company_id=setting.company_id
   AND product.product_id=setting.product_id
  LEFT JOIN public.warehouses warehouse
    ON warehouse.company_id=setting.company_id
   AND warehouse.id=setting.warehouse_id
   AND warehouse.is_active
  WHERE setting.low_stock_alert_enabled
    AND (product.product_id IS NULL OR warehouse.id IS NULL)

  UNION ALL
  SELECT 'minimum_stock_audit_coverage',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('setting_count',count(*))
  FROM public.product_warehouse_stock_settings setting
  WHERE NOT EXISTS(SELECT 1
    FROM public.product_warehouse_stock_setting_audit audit
    WHERE audit.company_id=setting.company_id AND audit.setting_id=setting.id
      AND audit.action='CREATE')

  UNION ALL
  SELECT 'nonterminal_minimum_stock_import_jobs',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('companies',count(DISTINCT company_id),
      'job_count',count(*))
  FROM public.master_import_jobs
  WHERE import_type='PRODUCT_WAREHOUSE_MINIMUM_STOCK'
    AND status NOT IN('COMPLETED','COMPLETED_WITH_ERRORS','FAILED','CANCELED')

  UNION ALL
  SELECT 'minimum_stock_runtime_inventory','INFO',jsonb_build_object(
    'settings',count(*),'companies',count(DISTINCT company_id),
    'alerts_enabled',count(*) FILTER(WHERE low_stock_alert_enabled),
    'settings_with_threshold',count(*) FILTER(
      WHERE minimum_stock_base_qty IS NOT NULL),
    'audit_rows',(SELECT count(*)
      FROM public.product_warehouse_stock_setting_audit),
    'import_jobs',(SELECT count(*) FROM public.master_import_jobs
      WHERE import_type='PRODUCT_WAREHOUSE_MINIMUM_STOCK'))
  FROM public.product_warehouse_stock_settings
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'REVIEW' THEN 2
  WHEN 'SETUP' THEN 3 WHEN 'PASS' THEN 4 ELSE 5 END,check_name;
