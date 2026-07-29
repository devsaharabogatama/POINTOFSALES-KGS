-- G3 phase 12 postflight: canonical Bundle foundation.
-- SAFETY: SELECT-only aggregate verification.

WITH expected_columns(column_name) AS (
    VALUES
        ('component_uom_id'),('component_qty'),('line_no'),
        ('master_version'),('created_by'),('updated_by'),
        ('created_at'),('updated_at')
), expected_constraints(constraint_name) AS (
    VALUES
        ('product_bundle_items_component_qty_positive'),
        ('product_bundle_items_line_no_positive'),
        ('product_bundle_items_version_positive'),
        ('product_bundle_items_not_self'),
        ('fk_bundle_items_company_item_uom')
), expected_indexes(index_name) AS (
    VALUES
        ('uq_bundle_items_company_bundle_line'),
        ('uq_bundle_items_company_bundle_item_uom')
), expected_triggers(trigger_name) AS (
    VALUES
        ('g3_guard_product_type'),
        ('g3_guard_bundle_component'),
        ('g3_touch_bundle_component'),
        ('g3_reject_bundle_product_stock'),
        ('g3_reject_bundle_stock_movement'),
        ('g3_reject_bundle_fifo_batch')
), checks AS (
    SELECT
        'migration_ledger'::text AS check_name,
        CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'FAIL' END AS status,
        abs(count(*) - 1)::BIGINT AS violation_rows,
        jsonb_build_object('ledger_rows',count(*)) AS details
    FROM private.kgs_schema_migrations
    WHERE version = '20260729010000'

    UNION ALL

    SELECT
        'required_bundle_columns',
        CASE WHEN count(*) FILTER (WHERE c.column_name IS NULL) = 0
             THEN 'PASS' ELSE 'FAIL' END,
        count(*) FILTER (WHERE c.column_name IS NULL),
        jsonb_build_object(
            'column_rows',count(c.column_name),
            'missing',COALESCE(
                jsonb_agg(e.column_name ORDER BY e.column_name)
                    FILTER (WHERE c.column_name IS NULL),
                '[]'::jsonb
            )
        )
    FROM expected_columns e
    LEFT JOIN information_schema.columns c
      ON c.table_schema = 'public'
     AND c.table_name = 'product_bundle_items'
     AND c.column_name = e.column_name

    UNION ALL

    SELECT
        'required_bundle_constraints',
        CASE WHEN count(*) FILTER (WHERE con.conname IS NULL) = 0
             THEN 'PASS' ELSE 'FAIL' END,
        count(*) FILTER (WHERE con.conname IS NULL),
        jsonb_build_object(
            'constraint_rows',count(con.conname),
            'missing',COALESCE(
                jsonb_agg(e.constraint_name ORDER BY e.constraint_name)
                    FILTER (WHERE con.conname IS NULL),
                '[]'::jsonb
            )
        )
    FROM expected_constraints e
    LEFT JOIN pg_constraint con
      ON con.conrelid = 'public.product_bundle_items'::REGCLASS
     AND con.conname = e.constraint_name

    UNION ALL

    SELECT
        'required_bundle_indexes',
        CASE WHEN count(*) FILTER (WHERE i.indexname IS NULL) = 0
             THEN 'PASS' ELSE 'FAIL' END,
        count(*) FILTER (WHERE i.indexname IS NULL),
        jsonb_build_object(
            'index_rows',count(i.indexname),
            'missing',COALESCE(
                jsonb_agg(e.index_name ORDER BY e.index_name)
                    FILTER (WHERE i.indexname IS NULL),
                '[]'::jsonb
            )
        )
    FROM expected_indexes e
    LEFT JOIN pg_indexes i
      ON i.schemaname = 'public'
     AND i.tablename = 'product_bundle_items'
     AND i.indexname = e.index_name

    UNION ALL

    SELECT
        'required_bundle_triggers',
        CASE WHEN count(*) FILTER (WHERE t.tgname IS NULL) = 0
             THEN 'PASS' ELSE 'FAIL' END,
        count(*) FILTER (WHERE t.tgname IS NULL),
        jsonb_build_object(
            'trigger_rows',count(t.tgname),
            'missing',COALESCE(
                jsonb_agg(e.trigger_name ORDER BY e.trigger_name)
                    FILTER (WHERE t.tgname IS NULL),
                '[]'::jsonb
            )
        )
    FROM expected_triggers e
    LEFT JOIN pg_trigger t
      ON t.tgrelid IN (
          'public.products'::REGCLASS,
          'public.product_bundle_items'::REGCLASS,
          'public.product_stocks'::REGCLASS,
          'public.stock_movements'::REGCLASS,
          'public.product_batches'::REGCLASS
      )
     AND t.tgname = e.trigger_name
     AND NOT t.tgisinternal

    UNION ALL

    SELECT
        'required_bundle_routines',
        CASE WHEN count(*) = 3 THEN 'PASS' ELSE 'FAIL' END,
        abs(count(*) - 3)::BIGINT,
        jsonb_build_object('routine_rows',count(*))
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE (n.nspname,p.proname) IN (
        ('public','save_bundle_with_components'),
        ('public','get_bundle_availability'),
        ('private','resolve_bundle_components')
    )

    UNION ALL

    SELECT
        'bundle_browser_privilege_boundary',
        CASE WHEN
            NOT has_table_privilege(
                'authenticated','public.product_bundle_items',
                'INSERT,UPDATE,DELETE'
            )
            AND has_function_privilege(
                'authenticated',
                'public.save_bundle_with_components(uuid,bigint,text,text,uuid,uuid,numeric,text,text,boolean,jsonb)',
                'EXECUTE'
            )
            AND has_function_privilege(
                'authenticated',
                'public.get_bundle_availability(uuid,uuid)',
                'EXECUTE'
            )
            AND NOT has_function_privilege(
                'anon',
                'public.save_bundle_with_components(uuid,bigint,text,text,uuid,uuid,numeric,text,text,boolean,jsonb)',
                'EXECUTE'
            )
            AND NOT has_function_privilege(
                'authenticated',
                'private.resolve_bundle_components(uuid,uuid,numeric)',
                'EXECUTE'
            )
        THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN
            NOT has_table_privilege(
                'authenticated','public.product_bundle_items',
                'INSERT,UPDATE,DELETE'
            )
            AND has_function_privilege(
                'authenticated',
                'public.save_bundle_with_components(uuid,bigint,text,text,uuid,uuid,numeric,text,text,boolean,jsonb)',
                'EXECUTE'
            )
            AND has_function_privilege(
                'authenticated',
                'public.get_bundle_availability(uuid,uuid)',
                'EXECUTE'
            )
            AND NOT has_function_privilege(
                'anon',
                'public.save_bundle_with_components(uuid,bigint,text,text,uuid,uuid,numeric,text,text,boolean,jsonb)',
                'EXECUTE'
            )
            AND NOT has_function_privilege(
                'authenticated',
                'private.resolve_bundle_components(uuid,uuid,numeric)',
                'EXECUTE'
            )
        THEN 0 ELSE 1 END,
        jsonb_build_object(
            'direct_write',has_table_privilege(
                'authenticated','public.product_bundle_items',
                'INSERT,UPDATE,DELETE'
            ),
            'authenticated_save',has_function_privilege(
                'authenticated',
                'public.save_bundle_with_components(uuid,bigint,text,text,uuid,uuid,numeric,text,text,boolean,jsonb)',
                'EXECUTE'
            ),
            'authenticated_availability',has_function_privilege(
                'authenticated',
                'public.get_bundle_availability(uuid,uuid)',
                'EXECUTE'
            )
        )

    UNION ALL

    SELECT
        'bundle_audit_rls',
        CASE WHEN c.relrowsecurity
                  AND count(pol.policyname) = 1
             THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN c.relrowsecurity
                  AND count(pol.policyname) = 1
             THEN 0 ELSE 1 END,
        jsonb_build_object(
            'rls_enabled',c.relrowsecurity,
            'policy_rows',count(pol.policyname)
        )
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    LEFT JOIN pg_policies pol
      ON pol.schemaname = n.nspname
     AND pol.tablename = c.relname
    WHERE n.nspname = 'public'
      AND c.relname = 'product_bundle_master_audit'
    GROUP BY c.relrowsecurity

    UNION ALL

    SELECT
        'invalid_bundle_component_shape',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),
        jsonb_build_object('row_count',count(*))
    FROM public.product_bundle_items bi
    JOIN public.products bundle
      ON bundle.company_id = bi.company_id
     AND bundle.id = bi.bundle_id
    JOIN public.products item
      ON item.company_id = bi.company_id
     AND item.id = bi.item_id
    LEFT JOIN public.product_uoms pu
      ON pu.company_id = bi.company_id
     AND pu.product_id = bi.item_id
     AND pu.uom_id = bi.component_uom_id
    WHERE NOT bundle.is_bundle
       OR item.is_bundle
       OR bi.bundle_id = bi.item_id
       OR bi.component_qty <= 0
       OR bi.qty IS DISTINCT FROM bi.component_qty
       OR pu.id IS NULL

    UNION ALL

    SELECT
        'duplicate_bundle_component_or_line',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),
        jsonb_build_object('duplicate_groups',count(*))
    FROM (
        SELECT company_id,bundle_id,item_id,component_uom_id
        FROM public.product_bundle_items
        GROUP BY company_id,bundle_id,item_id,component_uom_id
        HAVING count(*) > 1
        UNION ALL
        SELECT company_id,bundle_id,NULL::UUID,NULL::UUID
        FROM public.product_bundle_items
        GROUP BY company_id,bundle_id,line_no
        HAVING count(*) > 1
    ) duplicates

    UNION ALL

    SELECT
        'active_bundle_composition_coverage',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),
        jsonb_build_object('bundle_count',count(*))
    FROM public.products p
    WHERE p.is_bundle
      AND p.is_active
      AND NOT EXISTS (
          SELECT 1 FROM public.product_bundle_items bi
          WHERE bi.company_id = p.company_id
            AND bi.bundle_id = p.id
      )

    UNION ALL

    SELECT
        'bundle_virtual_stock_invariant',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),
        jsonb_build_object('physical_rows',count(*))
    FROM (
        SELECT ps.company_id,ps.product_id
        FROM public.product_stocks ps
        JOIN public.products p
          ON p.company_id = ps.company_id AND p.id = ps.product_id
        WHERE p.is_bundle
        UNION ALL
        SELECT sm.company_id,sm.product_id
        FROM public.stock_movements sm
        JOIN public.products p
          ON p.company_id = sm.company_id AND p.id = sm.product_id
        WHERE p.is_bundle
        UNION ALL
        SELECT pb.company_id,pb.product_id
        FROM public.product_batches pb
        JOIN public.products p
          ON p.company_id = pb.company_id AND p.id = pb.product_id
        WHERE p.is_bundle
    ) physical

    UNION ALL

    SELECT
        'bundle_uom_contract',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),
        jsonb_build_object('invalid_rows',count(*))
    FROM public.product_uoms pu
    JOIN public.products p
      ON p.company_id = pu.company_id AND p.id = pu.product_id
    WHERE p.is_bundle
      AND pu.is_active
      AND (
          pu.purchase_allowed
          OR NOT pu.sales_allowed
          OR pu.factor_to_base <> 1
          OR pu.sale_price IS NULL
      )

    UNION ALL

    SELECT
        'bundle_audit_inventory',
        'PASS',
        0,
        jsonb_build_object(
            'bundle_products',(SELECT count(*) FROM public.products WHERE is_bundle),
            'component_rows',(SELECT count(*) FROM public.product_bundle_items),
            'audit_rows',(SELECT count(*) FROM public.product_bundle_master_audit)
        )
)
SELECT check_name,status,violation_rows,details
FROM checks
ORDER BY
    CASE status WHEN 'FAIL' THEN 1 ELSE 2 END,
    check_name;
