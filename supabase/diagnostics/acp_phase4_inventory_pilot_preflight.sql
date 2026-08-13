-- ACP-4 preflight: Inventory custom-permission pilot cutover readiness.
-- SAFETY: one SELECT statement; aggregate metadata only; no business identity.

WITH expected_keys(permission_key,expected_status) AS (
    VALUES
      ('inventory.master_data','ENFORCED'),('inventory.products','ENFORCED'),
      ('inventory.stock_real','ENFORCED'),('inventory.stock_movements','ENFORCED'),
      ('inventory.stock_transfers','ENFORCED'),('inventory.stock_adjustments','ENFORCED'),
      ('inventory.stock_opnames','ENFORCED'),('inventory.opening_stock','ENFORCED'),
      ('inventory.minimum_stock','ENFORCED')
), expected_routines(routine_name) AS (
    VALUES
      ('save_product_with_uoms'),
      ('save_product_warehouse_stock_setting'),
      ('save_stock_transfer_document'),('post_stock_transfer'),
      ('cancel_stock_transfer'),
      ('save_stock_adjustment_document'),('post_stock_adjustment'),
      ('cancel_stock_adjustment'),
      ('request_stock_opname_recount'),('post_stock_opname'),
      ('cancel_stock_opname'),
      ('save_opening_stock_document'),('post_opening_stock')
), protected_relations(relation_name) AS (
    VALUES
      ('products'),('product_uoms'),('product_stocks'),('product_batches'),
      ('stock_movements'),('stock_transfer_documents'),
      ('stock_transfer_lines'),('stock_adjustment_documents'),
      ('stock_adjustment_lines'),('stock_opnames'),
      ('stock_opname_details'),('opening_stock_documents'),
      ('opening_stock_lines'),('product_warehouse_stock_settings')
), simple_master_relations(relation_name) AS (
    VALUES ('product_categories'),('uoms'),('warehouses'),('stores'),
           ('pos_terminals')
), inventory_routines AS (
    SELECT procedure.oid,procedure.proname,
           pg_get_functiondef(procedure.oid) AS definition
    FROM pg_catalog.pg_proc procedure
    JOIN pg_catalog.pg_namespace namespace
      ON namespace.oid=procedure.pronamespace
    WHERE namespace.nspname IN('public','private')
      AND procedure.proname IN(SELECT routine_name FROM expected_routines)
), enforced_master_routines AS (
    SELECT procedure.oid,procedure.proname,
           pg_get_functiondef(procedure.oid) AS definition
    FROM pg_catalog.pg_proc procedure
    JOIN pg_catalog.pg_namespace namespace
      ON namespace.oid=procedure.pronamespace
    WHERE namespace.nspname='public'
      AND procedure.proname IN(
        'save_inventory_product_category','save_inventory_uom',
        'save_inventory_warehouse','save_product_category_tax_assignment'
      )
), enforced_product_routines AS (
    SELECT procedure.oid,procedure.proname,
           pg_get_functiondef(procedure.oid) AS definition
    FROM pg_catalog.pg_proc procedure
    JOIN pg_catalog.pg_namespace namespace
      ON namespace.oid=procedure.pronamespace
    WHERE namespace.nspname='public'
      AND procedure.proname IN(
        'save_product_with_uoms','save_product_tax_assignment'
      )
), enforced_product_import_routines AS (
    SELECT procedure.oid,procedure.proname,
           pg_get_functiondef(procedure.oid) AS definition
    FROM pg_catalog.pg_proc procedure
    JOIN pg_catalog.pg_namespace namespace
      ON namespace.oid=procedure.pronamespace
    WHERE namespace.nspname='public'
      AND procedure.proname IN(
        'create_master_import_job','stage_master_import_rows',
        'validate_master_import_job','commit_master_import_job'
      )
), enforced_stock_read_routines AS (
    SELECT procedure.oid,procedure.proname,
           pg_get_functiondef(procedure.oid) AS definition
    FROM pg_catalog.pg_proc procedure
    JOIN pg_catalog.pg_namespace namespace
      ON namespace.oid=procedure.pronamespace
    WHERE namespace.nspname='public'
      AND procedure.proname IN(
        'get_inventory_stock_overview','get_inventory_stock_movements'
      )
), enforced_stock_transfer_routines AS (
    SELECT procedure.oid,procedure.proname,
           pg_get_functiondef(procedure.oid) AS definition
    FROM pg_catalog.pg_proc procedure
    JOIN pg_catalog.pg_namespace namespace
      ON namespace.oid=procedure.pronamespace
    WHERE namespace.nspname='public'
      AND procedure.proname IN(
        'get_inventory_stock_transfers','save_stock_transfer_document',
        'post_stock_transfer','cancel_stock_transfer'
      )
), enforced_stock_adjustment_routines AS (
    SELECT procedure.oid,procedure.proname,
           pg_get_functiondef(procedure.oid) AS definition
    FROM pg_catalog.pg_proc procedure
    JOIN pg_catalog.pg_namespace namespace
      ON namespace.oid=procedure.pronamespace
    WHERE namespace.nspname='public'
      AND procedure.proname IN(
        'get_inventory_stock_adjustments','save_stock_adjustment_reason',
        'save_stock_adjustment_document','post_stock_adjustment',
        'cancel_stock_adjustment'
      )
), enforced_stock_opname_routines AS (
    SELECT procedure.oid,procedure.proname,
           pg_get_functiondef(procedure.oid) AS definition
    FROM pg_catalog.pg_proc procedure
    JOIN pg_catalog.pg_namespace namespace
      ON namespace.oid=procedure.pronamespace
    WHERE namespace.nspname='public'
      AND procedure.proname IN(
        'get_inventory_stock_opnames','save_stock_opname_session',
        'start_stock_opname','record_stock_opname_count',
        'complete_stock_opname','request_stock_opname_recount',
        'post_stock_opname','cancel_stock_opname',
        'get_stock_opname_blind_session'
      )
), enforced_opening_stock_routines AS (
    SELECT procedure.oid,procedure.proname,
           pg_get_functiondef(procedure.oid) AS definition
    FROM pg_catalog.pg_proc procedure
    JOIN pg_catalog.pg_namespace namespace
      ON namespace.oid=procedure.pronamespace
    WHERE namespace.nspname='public'
      AND procedure.proname IN(
        'get_inventory_opening_stock','save_opening_stock_document',
        'post_opening_stock'
      )
), enforced_minimum_stock_routines AS (
    SELECT procedure.oid,procedure.proname,
           pg_get_functiondef(procedure.oid) AS definition
    FROM pg_catalog.pg_proc procedure
    JOIN pg_catalog.pg_namespace namespace
      ON namespace.oid=procedure.pronamespace
    WHERE namespace.nspname='public'
      AND procedure.proname IN(
        'get_inventory_minimum_stock',
        'save_product_warehouse_stock_setting'
      )
), inventory_override_counts AS (
    SELECT restriction_preset,count(*) AS row_count
    FROM public.user_company_permission_overrides override_row
    JOIN expected_keys expected
      ON expected.permission_key=override_row.permission_key
    GROUP BY restriction_preset
), checks AS (
    SELECT 'acp_phase2_dependency'::TEXT check_name,
      CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END status,
      jsonb_build_object('ledger_rows',count(*)) details
    FROM private.kgs_schema_migrations
    WHERE version='20260812120000'

    UNION ALL
    SELECT 'inventory_permission_catalog_contract',
      CASE WHEN count(*)=9
             AND count(*) FILTER(WHERE catalog.permission_key IS NULL)=0
             AND count(*) FILTER(
               WHERE catalog.enforcement_status<>expected.expected_status
             )=0
             AND count(*) FILTER(WHERE NOT catalog.is_customizable)=0
           THEN 'PASS' ELSE 'BLOCKER' END,
      jsonb_build_object(
        'expected',count(*),
        'missing',count(*) FILTER(WHERE catalog.permission_key IS NULL),
        'unexpected_status',count(*) FILTER(
          WHERE catalog.permission_key IS NOT NULL
            AND catalog.enforcement_status<>expected.expected_status
        ),
        'enforced',count(*) FILTER(
          WHERE catalog.enforcement_status='ENFORCED'
        ),
        'non_customizable',count(*) FILTER(
          WHERE catalog.permission_key IS NOT NULL
            AND NOT catalog.is_customizable
        )
      )
    FROM expected_keys expected
    LEFT JOIN public.access_permission_catalog catalog
      ON catalog.permission_key=expected.permission_key

    UNION ALL
    SELECT 'inventory_override_tenant_integrity',
      CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
      jsonb_build_object('row_count',count(*))
    FROM public.user_company_permission_overrides override_row
    JOIN expected_keys expected
      ON expected.permission_key=override_row.permission_key
    LEFT JOIN public.company_memberships membership
      ON membership.company_id=override_row.company_id
     AND membership.user_id=override_row.user_id
     AND membership.status='ACTIVE'
    WHERE membership.id IS NULL

    UNION ALL
    SELECT 'inventory_protected_direct_write_boundary',
      CASE WHEN count(*) FILTER(
        WHERE to_regclass('public.'||relation_name) IS NOT NULL
          AND has_table_privilege(
            'authenticated','public.'||relation_name,'INSERT,UPDATE,DELETE'
          )
      )=0 THEN 'PASS' ELSE 'BLOCKER' END,
      jsonb_build_object(
        'expected_relations',count(*),
        'missing_relations',count(*) FILTER(
          WHERE to_regclass('public.'||relation_name) IS NULL
        ),
        'direct_write_relations',count(*) FILTER(
          WHERE to_regclass('public.'||relation_name) IS NOT NULL
            AND has_table_privilege(
              'authenticated','public.'||relation_name,'INSERT,UPDATE,DELETE'
            )
        )
      )
    FROM protected_relations

    UNION ALL
    SELECT 'inventory_simple_master_direct_write_boundary',
      CASE WHEN count(*) FILTER(
        WHERE to_regclass('public.'||relation_name) IS NOT NULL
          AND has_table_privilege(
            'authenticated','public.'||relation_name,'INSERT,UPDATE,DELETE'
          )
      )=0 THEN 'PASS' ELSE 'BLOCKER' END,
      jsonb_build_object(
        'relation_rows',count(*) FILTER(
          WHERE to_regclass('public.'||relation_name) IS NOT NULL
        ),
        'direct_write_relations',COALESCE(
          jsonb_agg(relation_name ORDER BY relation_name) FILTER(
            WHERE to_regclass('public.'||relation_name) IS NOT NULL
              AND has_table_privilege(
                'authenticated','public.'||relation_name,'INSERT,UPDATE,DELETE'
              )
          ),'[]'::JSONB
        )
      )
    FROM simple_master_relations

    UNION ALL
    SELECT 'inventory_required_routine_state',
      CASE WHEN count(*) FILTER(WHERE found.routine_name IS NULL)=0
           THEN 'PASS' ELSE 'BLOCKER' END,
      jsonb_build_object(
        'expected',count(*),
        'missing',COALESCE(
          jsonb_agg(expected.routine_name ORDER BY expected.routine_name)
            FILTER(WHERE found.routine_name IS NULL),'[]'::JSONB
        )
      )
    FROM expected_routines expected
    LEFT JOIN (
      SELECT DISTINCT proname AS routine_name FROM inventory_routines
    ) found ON found.routine_name=expected.routine_name

    UNION ALL
    SELECT 'inventory_runtime_permission_hook_state',
      CASE WHEN count(*)=4 AND count(*) FILTER(
        WHERE definition ILIKE '%acp_require_permission_capability%'
          AND definition ILIKE '%inventory.master_data%'
      )=4 THEN 'PASS' ELSE 'BLOCKER' END,
      jsonb_build_object(
        'expected',4,
        'routines_with_acp_reference',count(*) FILTER(
          WHERE definition ILIKE '%acp_require_permission_capability%'
            AND definition ILIKE '%inventory.master_data%'
        ),
        'routine_names',COALESCE(
          jsonb_agg(DISTINCT proname ORDER BY proname),'[]'::JSONB
        )
      )
    FROM enforced_master_routines

    UNION ALL
    SELECT 'product_runtime_permission_hook_state',
      CASE WHEN count(*)=3 AND count(*) FILTER(
        WHERE definition ILIKE '%acp_require_permission_capability%'
          AND definition ILIKE '%inventory.products%'
      )=3 THEN 'PASS' ELSE 'BLOCKER' END,
      jsonb_build_object(
        'expected',3,
        'routines_with_acp_reference',count(*) FILTER(
          WHERE definition ILIKE '%acp_require_permission_capability%'
            AND definition ILIKE '%inventory.products%'
        ),
        'routine_names',COALESCE(
          jsonb_agg(DISTINCT proname ORDER BY proname),'[]'::JSONB
        )
      )
    FROM enforced_product_routines

    UNION ALL
    SELECT 'product_import_permission_hook_state',
      CASE WHEN count(*)=4 AND count(*) FILTER(
        WHERE definition ILIKE '%acp_require_product_import_if_needed%'
      )=4 THEN 'PASS' ELSE 'BLOCKER' END,
      jsonb_build_object(
        'expected',4,
        'routines_with_product_import_guard',count(*) FILTER(
          WHERE definition ILIKE '%acp_require_product_import_if_needed%'
        ),
        'routine_names',COALESCE(
          jsonb_agg(DISTINCT proname ORDER BY proname),'[]'::JSONB
        )
      )
    FROM enforced_product_import_routines

    UNION ALL
    SELECT 'stock_read_permission_hook_state',
      CASE WHEN count(*)=2 AND count(*) FILTER(
        WHERE definition ILIKE '%acp_require_permission_capability%'
          AND definition ILIKE '%VIEW%'
          AND (definition ILIKE '%inventory.stock_real%'
            OR definition ILIKE '%inventory.stock_movements%')
      )=2 THEN 'PASS' ELSE 'BLOCKER' END,
      jsonb_build_object(
        'expected',2,
        'routines_with_acp_reference',count(*) FILTER(
          WHERE definition ILIKE '%acp_require_permission_capability%'
            AND definition ILIKE '%VIEW%'
            AND (definition ILIKE '%inventory.stock_real%'
              OR definition ILIKE '%inventory.stock_movements%')
        ),
        'routine_names',COALESCE(
          jsonb_agg(DISTINCT proname ORDER BY proname),'[]'::JSONB
        )
      )
    FROM enforced_stock_read_routines

    UNION ALL
    SELECT 'stock_transfer_runtime_permission_hook_state',
      CASE WHEN count(*)=4 AND count(*) FILTER(
        WHERE definition ILIKE '%acp_require_permission_capability%'
          AND definition ILIKE '%inventory.stock_transfers%'
      )=4 THEN 'PASS' ELSE 'BLOCKER' END,
      jsonb_build_object(
        'expected',4,
        'routines_with_acp_reference',count(*) FILTER(
          WHERE definition ILIKE '%acp_require_permission_capability%'
            AND definition ILIKE '%inventory.stock_transfers%'
        ),
        'routine_names',COALESCE(
          jsonb_agg(DISTINCT proname ORDER BY proname),'[]'::JSONB
        )
      )
    FROM enforced_stock_transfer_routines

    UNION ALL
    SELECT 'stock_adjustment_runtime_permission_hook_state',
      CASE WHEN count(*)=5 AND count(*) FILTER(
        WHERE definition ILIKE '%acp_require_permission_capability%'
          AND definition ILIKE '%inventory.stock_adjustments%'
      )=5 THEN 'PASS' ELSE 'BLOCKER' END,
      jsonb_build_object(
        'expected',5,
        'routines_with_acp_reference',count(*) FILTER(
          WHERE definition ILIKE '%acp_require_permission_capability%'
            AND definition ILIKE '%inventory.stock_adjustments%'
        ),
        'routine_names',COALESCE(
          jsonb_agg(DISTINCT proname ORDER BY proname),'[]'::JSONB
        )
      )
    FROM enforced_stock_adjustment_routines

    UNION ALL
    SELECT 'stock_opname_runtime_permission_hook_state',
      CASE WHEN count(*)=9 AND count(*) FILTER(
        WHERE definition ILIKE '%acp_require_stock_opname_counter%'
          OR (definition ILIKE '%acp_require_permission_capability%'
            AND definition ILIKE '%inventory.stock_opnames%')
      )=9 THEN 'PASS' ELSE 'BLOCKER' END,
      jsonb_build_object(
        'expected',9,
        'routines_with_acp_reference',count(*) FILTER(
          WHERE definition ILIKE '%acp_require_stock_opname_counter%'
            OR (definition ILIKE '%acp_require_permission_capability%'
              AND definition ILIKE '%inventory.stock_opnames%')
        ),
        'routine_names',COALESCE(
          jsonb_agg(DISTINCT proname ORDER BY proname),'[]'::JSONB
        )
      )
    FROM enforced_stock_opname_routines

    UNION ALL
    SELECT 'opening_stock_runtime_permission_hook_state',
      CASE WHEN count(*)=3 AND count(*) FILTER(
        WHERE definition ILIKE '%acp_require_permission_capability%'
          AND definition ILIKE '%inventory.opening_stock%'
      )=3 THEN 'PASS' ELSE 'BLOCKER' END,
      jsonb_build_object(
        'expected',3,
        'routines_with_acp_reference',count(*) FILTER(
          WHERE definition ILIKE '%acp_require_permission_capability%'
            AND definition ILIKE '%inventory.opening_stock%'
        ),
        'routine_names',COALESCE(
          jsonb_agg(DISTINCT proname ORDER BY proname),'[]'::JSONB
        )
      )
    FROM enforced_opening_stock_routines

    UNION ALL
    SELECT 'minimum_stock_runtime_permission_hook_state',
      CASE WHEN count(*)=2 AND count(*) FILTER(
        WHERE definition ILIKE '%acp_require_permission_capability%'
          AND definition ILIKE '%inventory.minimum_stock%'
      )=2 THEN 'PASS' ELSE 'BLOCKER' END,
      jsonb_build_object(
        'expected',2,
        'routines_with_acp_reference',count(*) FILTER(
          WHERE definition ILIKE '%acp_require_permission_capability%'
            AND definition ILIKE '%inventory.minimum_stock%'
        ),
        'routine_names',COALESCE(
          jsonb_agg(DISTINCT proname ORDER BY proname),'[]'::JSONB
        )
      )
    FROM enforced_minimum_stock_routines

    UNION ALL
    SELECT 'inventory_browser_rpc_execution_inventory','INFO',
      jsonb_build_object(
        'routine_names',count(DISTINCT routine.proname),
        'authenticated_executable_signatures',count(*) FILTER(
          WHERE has_function_privilege(
            'authenticated',routine.oid,'EXECUTE'
          )
        )
      )
    FROM inventory_routines routine

    UNION ALL
    SELECT 'inventory_active_document_scope','INFO',
      jsonb_build_object(
        'transfer_nonfinal',(
          SELECT count(*) FROM public.stock_transfer_documents
          WHERE status NOT IN('POSTED','CANCELED')
        ),
        'adjustment_nonfinal',(
          SELECT count(*) FROM public.stock_adjustment_documents
          WHERE status NOT IN('POSTED','CANCELED')
        ),
        'opname_nonfinal',(
          SELECT count(*) FROM public.stock_opnames
          WHERE status NOT IN('POSTED','CANCELED')
        ),
        'opening_nonfinal',(
          SELECT count(*) FROM public.opening_stock_documents
          WHERE status<>'POSTED'
        )
      )

    UNION ALL
    SELECT 'inventory_override_inventory','INFO',
      jsonb_build_object(
        'companies',(
          SELECT count(DISTINCT override_row.company_id)
          FROM public.user_company_permission_overrides override_row
          JOIN expected_keys expected
            ON expected.permission_key=override_row.permission_key
        ),
        'users',(
          SELECT count(DISTINCT override_row.user_id)
          FROM public.user_company_permission_overrides override_row
          JOIN expected_keys expected
            ON expected.permission_key=override_row.permission_key
        ),
        'override_rows',(
          SELECT COALESCE(sum(row_count),0) FROM inventory_override_counts
        ),
        'by_preset',COALESCE((
          SELECT jsonb_object_agg(restriction_preset,row_count)
          FROM inventory_override_counts
        ),'{}'::JSONB)
      )
)
SELECT check_name,status,details
FROM checks
ORDER BY CASE status
  WHEN 'BLOCKER' THEN 1 WHEN 'REVIEW' THEN 2 WHEN 'SETUP' THEN 3
  WHEN 'PASS' THEN 4 ELSE 5 END,check_name;
