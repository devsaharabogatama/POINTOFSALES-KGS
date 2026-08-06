-- G4 phase 59 preflight: controlled online POS negative-stock runtime.
--
-- SAFETY:
-- - SELECT-only; no DDL, DML, TEMP table, function side effect, or grants.
-- - Does not enable entitlement/policy/Warehouse or permit negative inventory.

WITH required_versions(version) AS (
    VALUES ('20260805190000')
), online_runtime AS (
    SELECT COALESCE(string_agg(pg_get_functiondef(routine.oid),'\n'),'') body
    FROM pg_proc routine
    JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
    WHERE namespace.nspname='private'
      AND routine.proname='post_pos_sale_online_core'
), offline_runtime AS (
    SELECT COALESCE(string_agg(pg_get_functiondef(routine.oid),'\n'),'') body
    FROM pg_proc routine
    JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
    WHERE routine.proname IN (
        'submit_pos_offline_sale','process_pos_offline_sale_submission',
        'commit_master_import_job'
    )
), movement_balance_guard AS (
    SELECT count(*) guard_rows,
           COALESCE(string_agg(pg_get_constraintdef(constraint_row.oid),' '),'') body
    FROM pg_constraint constraint_row
    JOIN pg_class table_row ON table_row.oid=constraint_row.conrelid
    JOIN pg_namespace namespace ON namespace.oid=table_row.relnamespace
    WHERE namespace.nspname='public'
      AND table_row.relname='stock_movements'
      AND constraint_row.conname='stock_movements_balance_after_nonnegative'
), effective_configuration AS (
    SELECT
        company.id company_id,
        COALESCE(feature.is_enabled,FALSE) entitlement_enabled,
        COALESCE(policy.is_active,FALSE) policy_enabled,
        count(DISTINCT warehouse.id) FILTER(
            WHERE warehouse.is_active AND warehouse.is_sale_source
              AND warehouse.allow_negative_stock
        ) opted_in_warehouses,
        count(DISTINCT permission.id) FILTER(
            WHERE permission.is_active
              AND (permission.valid_until IS NULL
                   OR permission.valid_until>clock_timestamp())
        ) active_permissions
    FROM public.companies company
    LEFT JOIN public.company_features feature
      ON feature.company_id=company.id
     AND feature.feature_code='pos_negative_stock_enabled'
    LEFT JOIN public.pos_negative_stock_policies policy
      ON policy.company_id=company.id
    LEFT JOIN public.warehouses warehouse
      ON warehouse.company_id=company.id
    LEFT JOIN public.pos_negative_stock_permissions permission
      ON permission.company_id=company.id
     AND permission.warehouse_id=warehouse.id
    WHERE company.status='ACTIVE'
    GROUP BY company.id,feature.is_enabled,policy.is_active
), checks AS (
    SELECT
        'g4_phase59_dependencies'::TEXT check_name,
        CASE WHEN count(*) FILTER(WHERE migration.version IS NULL)=0
             THEN 'PASS' ELSE 'BLOCKER' END status,
        jsonb_build_object(
            'expected',count(*),
            'missing',COALESCE(
                jsonb_agg(required.version ORDER BY required.version)
                    FILTER(WHERE migration.version IS NULL),'[]'::JSONB
            )
        ) details
    FROM required_versions required
    LEFT JOIN private.kgs_schema_migrations migration
      ON migration.version=required.version

    UNION ALL

    SELECT
        'negative_stock_configuration_inventory','INFO',
        jsonb_build_object(
            'active_companies',count(*),
            'enabled_entitlements',count(*) FILTER(WHERE entitlement_enabled),
            'active_policies',count(*) FILTER(WHERE policy_enabled),
            'companies_with_opted_in_warehouse',count(*) FILTER(
                WHERE opted_in_warehouses>0
            ),
            'companies_with_active_permission',count(*) FILTER(
                WHERE active_permissions>0
            )
        )
    FROM effective_configuration

    UNION ALL

    SELECT
        'partially_enabled_negative_stock_configuration',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object('company_count',count(*))
    FROM effective_configuration
    WHERE (policy_enabled AND NOT entitlement_enabled)
       OR (opted_in_warehouses>0
           AND (NOT entitlement_enabled OR NOT policy_enabled))
       OR (active_permissions>0
           AND (NOT entitlement_enabled OR NOT policy_enabled
                OR opted_in_warehouses=0))

    UNION ALL

    SELECT
        'invalid_active_negative_stock_permission',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.pos_negative_stock_permissions permission
    JOIN public.warehouses warehouse
      ON warehouse.company_id=permission.company_id
     AND warehouse.id=permission.warehouse_id
    JOIN public.profiles profile ON profile.id=permission.user_id
    WHERE permission.is_active
      AND (
          permission.valid_until<=clock_timestamp()
          OR NOT warehouse.is_active
          OR NOT warehouse.is_sale_source
          OR NOT warehouse.allow_negative_stock
          OR (
              profile.role::TEXT<>'super_admin'
              AND NOT EXISTS(
                  SELECT 1 FROM public.company_memberships membership
                  WHERE membership.company_id=permission.company_id
                    AND membership.user_id=permission.user_id
                    AND membership.status='ACTIVE'
              )
              AND NOT EXISTS(
                  SELECT 1 FROM public.store_memberships membership
                  WHERE membership.company_id=permission.company_id
                    AND membership.user_id=permission.user_id
                    AND membership.status='ACTIVE'
              )
          )
      )

    UNION ALL

    SELECT
        'configured_product_cost_basis_readiness',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('product_warehouse_pairs',count(*))
    FROM (
        SELECT product.company_id,product.id product_id,
               warehouse.id warehouse_id
        FROM public.products product
        JOIN public.warehouses warehouse
          ON warehouse.company_id=product.company_id
         AND warehouse.is_active AND warehouse.is_sale_source
         AND warehouse.allow_negative_stock
        JOIN public.pos_negative_stock_policies policy
          ON policy.company_id=product.company_id AND policy.is_active
        JOIN public.company_features feature
          ON feature.company_id=product.company_id
         AND feature.feature_code='pos_negative_stock_enabled'
         AND feature.is_enabled
        WHERE product.is_active AND NOT product.is_bundle
          AND EXISTS(
              SELECT 1 FROM public.product_uoms product_uom
              WHERE product_uom.company_id=product.company_id
                AND product_uom.product_id=product.id
                AND product_uom.is_active AND product_uom.sales_allowed
          )
          AND COALESCE(product.cogs,-1)<0
          AND NOT EXISTS(
              SELECT 1 FROM public.product_batches batch
              WHERE batch.company_id=product.company_id
                AND batch.product_id=product.id
                AND batch.warehouse_id=warehouse.id
                AND batch.cogs_unit>=0
          )
    ) missing_cost

    UNION ALL

    SELECT
        'existing_negative_stock_runtime_history',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM (
        SELECT 1 FROM public.pos_negative_stock_authorizations
        UNION ALL SELECT 1 FROM public.negative_stock_sale_allocations
        UNION ALL SELECT 1 FROM public.negative_stock_replenishment_allocations
    ) history

    UNION ALL

    SELECT
        'current_stock_balance_fifo_reconciliation',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('pair_count',count(*))
    FROM (
        SELECT stock.company_id,stock.product_id,stock.warehouse_id
        FROM public.product_stocks stock
        LEFT JOIN public.product_batches batch
          ON batch.company_id=stock.company_id
         AND batch.product_id=stock.product_id
         AND batch.warehouse_id=stock.warehouse_id
        GROUP BY stock.company_id,stock.product_id,stock.warehouse_id,
                 stock.stock_qty
        HAVING stock.stock_qty<>COALESCE(sum(batch.qty_remaining),0)
    ) mismatch

    UNION ALL

    SELECT
        'current_stock_balance_movement_reconciliation',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('pair_count',count(*))
    FROM (
        SELECT stock.company_id,stock.product_id,stock.warehouse_id
        FROM public.product_stocks stock
        LEFT JOIN public.stock_movements movement
          ON movement.company_id=stock.company_id
         AND movement.product_id=stock.product_id
         AND movement.warehouse_id=stock.warehouse_id
         AND movement.movement_status='POSTED'
        GROUP BY stock.company_id,stock.product_id,stock.warehouse_id,
                 stock.stock_qty
        HAVING stock.stock_qty<>COALESCE(sum(movement.qty_change),0)
    ) mismatch

    UNION ALL

    SELECT
        'negative_movement_snapshot_guard_state',
        CASE WHEN guard_rows=1
             THEN 'SETUP' ELSE 'REVIEW' END,
        jsonb_build_object(
            'legacy_nonnegative_guard_present',
            guard_rows=1,
            'constraint_definition',body
        )
    FROM movement_balance_guard

    UNION ALL

    SELECT
        'canonical_online_negative_stock_runtime_state',
        CASE WHEN body~'STOCK_SHORTAGE'
                  AND body!~'pos_negative_stock_authorizations'
                  AND body!~'negative_stock_sale_allocations'
             THEN 'SETUP' ELSE 'REVIEW' END,
        jsonb_build_object(
            'shortage_guard_present',body~'STOCK_SHORTAGE',
            'authorization_write_present',
                body~'pos_negative_stock_authorizations',
            'negative_allocation_write_present',
                body~'negative_stock_sale_allocations'
        )
    FROM online_runtime

    UNION ALL

    SELECT
        'required_private_negative_stock_routines',
        CASE WHEN count(*)=3 THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object(
            'expected',3,'routine_rows',count(*),
            'missing',to_jsonb(ARRAY(
                SELECT expected.name FROM (VALUES
                    ('authorize_pos_negative_stock'),
                    ('resolve_pos_negative_stock_provisional_cost'),
                    ('reconcile_negative_stock_replenishment')
                ) expected(name)
                WHERE NOT EXISTS(
                    SELECT 1 FROM pg_proc routine
                    JOIN pg_namespace namespace
                      ON namespace.oid=routine.pronamespace
                    WHERE namespace.nspname='private'
                      AND routine.proname=expected.name
                ) ORDER BY expected.name
            ))
        )
    FROM pg_proc routine
    JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
    WHERE namespace.nspname='private'
      AND routine.proname IN (
          'authorize_pos_negative_stock',
          'resolve_pos_negative_stock_provisional_cost',
          'reconcile_negative_stock_replenishment'
      )

    UNION ALL

    SELECT
        'offline_and_import_negative_stock_boundary',
        CASE WHEN body!~'pos_negative_stock_authorizations'
                  AND body!~'negative_stock_sale_allocations'
             THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'authorization_reference_present',
                body~'pos_negative_stock_authorizations',
            'negative_allocation_reference_present',
                body~'negative_stock_sale_allocations'
        )
    FROM offline_runtime

    UNION ALL

    SELECT
        'browser_direct_negative_stock_runtime_write_boundary',
        CASE WHEN NOT has_table_privilege('authenticated',
                    'public.pos_negative_stock_authorizations',
                    'INSERT,UPDATE,DELETE')
                  AND NOT has_table_privilege('authenticated',
                    'public.negative_stock_sale_allocations',
                    'INSERT,UPDATE,DELETE')
                  AND NOT has_table_privilege('authenticated',
                    'public.negative_stock_replenishment_allocations',
                    'INSERT,UPDATE,DELETE')
                  AND NOT has_table_privilege('authenticated',
                    'public.product_stocks','UPDATE')
                  AND NOT has_table_privilege('authenticated',
                    'public.stock_movements','INSERT')
             THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'authorization_write',has_table_privilege('authenticated',
                'public.pos_negative_stock_authorizations',
                'INSERT,UPDATE,DELETE'),
            'allocation_write',has_table_privilege('authenticated',
                'public.negative_stock_sale_allocations',
                'INSERT,UPDATE,DELETE'),
            'stock_update',has_table_privilege('authenticated',
                'public.product_stocks','UPDATE'),
            'movement_insert',has_table_privilege('authenticated',
                'public.stock_movements','INSERT')
        )

    UNION ALL

    SELECT
        'cross_gate_replenishment_and_finance','DEFERRED',
        jsonb_build_object(
            'g5','Goods Receipt must consume open negative allocations before creating remaining FIFO',
            'g6','Provisional-to-actual HPP variance posting remains Finance HOLD',
            'runtime_rule','Do not enable operational negative Sale before replenishment reconciliation exists'
        )
)
SELECT check_name,status,details
FROM checks
ORDER BY CASE status
    WHEN 'BLOCKER' THEN 1 WHEN 'REVIEW' THEN 2 WHEN 'SETUP' THEN 3
    WHEN 'PASS' THEN 4 WHEN 'DEFERRED' THEN 5 ELSE 6 END,check_name;
