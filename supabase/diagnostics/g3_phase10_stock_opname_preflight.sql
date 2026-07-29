-- G3 phase 10 preflight: canonical non-blocking Stock Opname readiness.
--
-- SAFETY:
-- - SELECT-only; no DDL, DML, TEMP table, function side effect, or grants.
-- - Returns aggregate counts only; no Product, user, or business row details.
--
-- PURPOSE:
-- - audit the legacy DRAFT/SUBMITTED/APPROVED Opname surface;
-- - prepare blind count in POS and review/post in Backoffice;
-- - preserve non-blocking sales through movement-window reconciliation;
-- - ensure posted variance can use canonical Stock Adjustment atomically.

WITH required_versions(version) AS (
    VALUES ('20260728210000')
), normalized_legacy_opnames AS (
    SELECT o.*
    FROM public.stock_opnames o
), normalized_legacy_details AS (
    SELECT d.*
    FROM public.stock_opname_details d
), movement_totals AS (
    SELECT company_id,product_id,warehouse_id,sum(qty_change) AS movement_qty
    FROM public.stock_movements
    GROUP BY company_id,product_id,warehouse_id
), fifo_totals AS (
    SELECT
        company_id,product_id,warehouse_id,
        sum(qty_remaining) AS remaining_qty
    FROM public.product_batches
    GROUP BY company_id,product_id,warehouse_id
), expected_header_columns(column_name) AS (
    VALUES
        ('scope_type'),('category_id'),('count_started_at'),
        ('movement_watermark_at'),('completed_by'),('completed_at'),
        ('reviewed_by'),('reviewed_at'),('posted_by'),('posted_at'),
        ('canceled_by'),('canceled_at'),('master_version'),('updated_at')
), expected_detail_columns(column_name) AS (
    VALUES
        ('line_status'),('base_uom_id'),('system_qty_at_start'),
        ('expected_qty_at_count'),('variance_at_count'),
        ('count_started_at'),('counted_at'),('counter_id'),
        ('movement_watermark_at'),('superseded_by_line_id'),
        ('recount_requested_by'),('recount_requested_at'),
        ('adjustment_line_id'),('product_sku_snapshot'),
        ('product_name_snapshot'),('base_uom_name_snapshot')
), expected_tables(table_name) AS (
    VALUES ('stock_opname_count_attempts'),('stock_opname_audit')
), adjustment_links AS (
    SELECT
        a.company_id,a.opname_detail_id,a.product_id,a.warehouse_id,
        'LEGACY'::TEXT AS source_type
    FROM public.stock_adjustments a
    WHERE a.opname_detail_id IS NOT NULL

    UNION ALL

    SELECT
        l.company_id,l.opname_detail_id,l.product_id,d.warehouse_id,
        'CANONICAL'
    FROM public.stock_adjustment_lines l
    JOIN public.stock_adjustment_documents d
      ON d.company_id = l.company_id AND d.id = l.document_id
    WHERE l.opname_detail_id IS NOT NULL
), checks AS (
    SELECT
        'g3_stock_opname_dependency'::TEXT AS check_name,
        CASE WHEN count(*) FILTER(WHERE m.version IS NULL) = 0
             THEN 'PASS' ELSE 'BLOCKER' END AS status,
        jsonb_build_object(
            'expected',count(*),
            'missing',COALESCE(
                jsonb_agg(r.version ORDER BY r.version)
                    FILTER(WHERE m.version IS NULL),
                '[]'::jsonb
            )
        ) AS details
    FROM required_versions r
    LEFT JOIN private.kgs_schema_migrations m ON m.version = r.version

    UNION ALL

    SELECT
        'legacy_opname_inventory','INFO',
        jsonb_build_object(
            'sessions',count(*),
            'companies',count(DISTINCT company_id),
            'warehouses',count(DISTINCT warehouse_id),
            'draft_rows',count(*) FILTER(
                WHERE status = 'DRAFT'::public.opname_status
            ),
            'submitted_rows',count(*) FILTER(
                WHERE status = 'SUBMITTED'::public.opname_status
            ),
            'approved_rows',count(*) FILTER(
                WHERE status = 'APPROVED'::public.opname_status
            )
        )
    FROM normalized_legacy_opnames

    UNION ALL

    SELECT
        'legacy_opname_detail_inventory','INFO',
        jsonb_build_object(
            'detail_rows',count(*),
            'products',count(DISTINCT product_id),
            'sessions',count(DISTINCT opname_id),
            'nonzero_variance_rows',count(*) FILTER(WHERE difference <> 0)
        )
    FROM normalized_legacy_details

    UNION ALL

    SELECT
        'legacy_opname_tenant_reference_integrity',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('orphan_or_cross_tenant_rows',count(*))
    FROM (
        SELECT o.id
        FROM public.stock_opnames o
        LEFT JOIN public.warehouses w
          ON w.company_id = o.company_id AND w.id = o.warehouse_id
        WHERE w.id IS NULL

        UNION ALL

        SELECT d.id
        FROM public.stock_opname_details d
        LEFT JOIN public.stock_opnames o
          ON o.company_id = d.company_id AND o.id = d.opname_id
        LEFT JOIN public.products p
          ON p.company_id = d.company_id AND p.id = d.product_id
        WHERE o.id IS NULL OR p.id IS NULL
    ) invalid_rows

    UNION ALL

    SELECT
        'invalid_legacy_opname_quantity',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM normalized_legacy_details
    WHERE system_qty < 0 OR physical_qty < 0
       OR difference IS DISTINCT FROM physical_qty - system_qty

    UNION ALL

    SELECT
        'duplicate_product_in_legacy_session',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('duplicate_groups',count(*))
    FROM (
        SELECT company_id,opname_id,product_id
        FROM public.stock_opname_details
        GROUP BY company_id,opname_id,product_id
        HAVING count(*) > 1
    ) duplicate_groups

    UNION ALL

    SELECT
        'overlapping_nonfinal_legacy_product_count',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object('overlap_groups',count(*))
    FROM (
        SELECT
            a.company_id,a.warehouse_id,da.product_id
        FROM public.stock_opnames a
        JOIN public.stock_opname_details da
          ON da.company_id = a.company_id AND da.opname_id = a.id
        JOIN public.stock_opnames b
          ON b.company_id = a.company_id
         AND b.warehouse_id = a.warehouse_id
         AND b.id::TEXT > a.id::TEXT
        JOIN public.stock_opname_details db
          ON db.company_id = b.company_id
         AND db.opname_id = b.id
         AND db.product_id = da.product_id
        WHERE a.status <> 'APPROVED'::public.opname_status
          AND b.status <> 'APPROVED'::public.opname_status
        GROUP BY a.company_id,a.warehouse_id,da.product_id
    ) overlap_groups

    UNION ALL

    SELECT
        'approved_legacy_line_without_adjustment',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BACKFILL' END,
        jsonb_build_object('line_count',count(*))
    FROM public.stock_opnames o
    JOIN public.stock_opname_details d
      ON d.company_id = o.company_id AND d.opname_id = o.id
    LEFT JOIN adjustment_links a
      ON a.company_id = d.company_id AND a.opname_detail_id = d.id
    WHERE o.status = 'APPROVED'::public.opname_status
      AND d.difference <> 0
      AND a.opname_detail_id IS NULL

    UNION ALL

    SELECT
        'invalid_existing_opname_adjustment_link',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM adjustment_links a
    LEFT JOIN public.stock_opname_details d
      ON d.company_id = a.company_id AND d.id = a.opname_detail_id
    LEFT JOIN public.stock_opnames o
      ON o.company_id = d.company_id AND o.id = d.opname_id
    WHERE d.id IS NULL OR o.id IS NULL
       OR d.product_id IS DISTINCT FROM a.product_id
       OR o.warehouse_id IS DISTINCT FROM a.warehouse_id

    UNION ALL

    SELECT
        'multiple_adjustments_for_one_opname_line',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('duplicate_lines',count(*))
    FROM (
        SELECT company_id,opname_detail_id
        FROM adjustment_links
        GROUP BY company_id,opname_detail_id
        HAVING count(*) > 1
    ) duplicate_lines

    UNION ALL

    SELECT
        'stock_balance_movement_mismatch',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('pair_count',count(*))
    FROM (
        SELECT COALESCE(ps.company_id,m.company_id) AS company_id
        FROM public.product_stocks ps
        FULL JOIN movement_totals m
          ON m.company_id = ps.company_id
         AND m.product_id = ps.product_id
         AND m.warehouse_id = ps.warehouse_id
        WHERE ps.product_id IS NULL OR m.product_id IS NULL
           OR ps.stock_qty IS DISTINCT FROM m.movement_qty
    ) invalid_pairs

    UNION ALL

    SELECT
        'fifo_remaining_balance_mismatch',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('pair_count',count(*))
    FROM (
        SELECT ps.company_id
        FROM public.product_stocks ps
        LEFT JOIN fifo_totals f
          ON f.company_id = ps.company_id
         AND f.product_id = ps.product_id
         AND f.warehouse_id = ps.warehouse_id
        WHERE ps.stock_qty > 0
          AND ps.stock_qty IS DISTINCT FROM COALESCE(f.remaining_qty,0)
    ) invalid_pairs

    UNION ALL

    SELECT
        'active_stock_product_without_valid_base_uom',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('product_count',count(*))
    FROM public.products p
    LEFT JOIN public.uoms u
      ON u.company_id = p.company_id AND u.id = p.uom_id
    LEFT JOIN public.product_uoms pu
      ON pu.company_id = p.company_id
     AND pu.product_id = p.id
     AND pu.uom_id = p.uom_id
     AND pu.factor_to_base = 1
     AND pu.is_active
    WHERE p.is_active AND NOT p.is_bundle
      AND (
          p.uom_id IS NULL OR u.id IS NULL
          OR NOT u.is_active OR pu.id IS NULL
      )

    UNION ALL

    SELECT
        'canonical_movement_watermark_readiness',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.stock_movements
    WHERE movement_status = 'POSTED'
      AND (
          posted_at IS NULL
          OR base_uom_id IS NULL OR balance_after_base_qty IS NULL
      )

    UNION ALL

    SELECT
        'active_company_opname_reason_readiness',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('company_count',count(*))
    FROM public.companies c
    WHERE c.status = 'ACTIVE'
      AND NOT EXISTS (
          SELECT 1
          FROM public.stock_adjustment_reasons r
          WHERE r.company_id = c.id
            AND lower(regexp_replace(
                btrim(r.reason_name),'\s+',' ','g'
            )) = 'selisih stok'
            AND r.direction_allowed = 'BOTH'
            AND r.is_active
      )

    UNION ALL

    SELECT
        'canonical_adjustment_rpc_readiness',
        CASE WHEN count(*) = 3 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('routine_rows',count(*))
    FROM (
        SELECT DISTINCT p.proname
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname IN (
              'save_stock_adjustment_document',
              'post_stock_adjustment',
              'private_stock_adjustment_operator_allowed'
          )
    ) required_routines

    UNION ALL

    SELECT
        'store_opname_channel_inventory','INFO',
        jsonb_build_object(
            'active_stores',(
                SELECT count(*) FROM public.stores WHERE status = 'ACTIVE'
            ),
            'active_pos_terminals',(
                SELECT count(*) FROM public.pos_terminals
                WHERE status = 'ACTIVE'
            ),
            'active_store_warehouses',(
                SELECT count(*) FROM public.warehouses
                WHERE is_active AND store_id IS NOT NULL
            ),
            'active_cashier_store_memberships',(
                SELECT count(*) FROM public.store_memberships
                WHERE status = 'ACTIVE' AND role_code = 'CASHIER'
            )
        )

    UNION ALL

    SELECT
        'legacy_opname_enum_state','INFO',
        jsonb_build_object(
            'labels',COALESCE(
                jsonb_agg(e.enumlabel ORDER BY e.enumsortorder),
                '[]'::jsonb
            ),
            'missing_target_labels',ARRAY(
                SELECT target.label
                FROM unnest(ARRAY[
                    'COUNTING','COMPLETED','POSTED','CANCELED'
                ]) AS target(label)
                WHERE NOT EXISTS (
                    SELECT 1
                    FROM pg_enum x
                    JOIN pg_type t ON t.oid = x.enumtypid
                    JOIN pg_namespace n ON n.oid = t.typnamespace
                    WHERE n.nspname = 'public'
                      AND t.typname = 'opname_status'
                      AND x.enumlabel = target.label
                )
            )
        )
    FROM pg_enum e
    JOIN pg_type t ON t.oid = e.enumtypid
    JOIN pg_namespace n ON n.oid = t.typnamespace
    WHERE n.nspname = 'public' AND t.typname = 'opname_status'

    UNION ALL

    SELECT
        'canonical_stock_opname_schema_state','INFO',
        jsonb_build_object(
            'missing_header_columns',(
                SELECT COALESCE(
                    jsonb_agg(e.column_name ORDER BY e.column_name)
                        FILTER(WHERE c.column_name IS NULL),
                    '[]'::jsonb
                )
                FROM expected_header_columns e
                LEFT JOIN information_schema.columns c
                  ON c.table_schema = 'public'
                 AND c.table_name = 'stock_opnames'
                 AND c.column_name = e.column_name
            ),
            'missing_detail_columns',(
                SELECT COALESCE(
                    jsonb_agg(e.column_name ORDER BY e.column_name)
                        FILTER(WHERE c.column_name IS NULL),
                    '[]'::jsonb
                )
                FROM expected_detail_columns e
                LEFT JOIN information_schema.columns c
                  ON c.table_schema = 'public'
                 AND c.table_name = 'stock_opname_details'
                 AND c.column_name = e.column_name
            ),
            'missing_tables',(
                SELECT COALESCE(
                    jsonb_agg(table_name ORDER BY table_name)
                        FILTER(WHERE to_regclass(
                            'public.' || table_name
                        ) IS NULL),
                    '[]'::jsonb
                )
                FROM expected_tables
            ),
            'canonical_save_rpc_exists',EXISTS(
                SELECT 1 FROM pg_proc p
                JOIN pg_namespace n ON n.oid = p.pronamespace
                WHERE n.nspname = 'public'
                  AND p.proname = 'save_stock_opname_session'
            ),
            'canonical_post_rpc_exists',EXISTS(
                SELECT 1 FROM pg_proc p
                JOIN pg_namespace n ON n.oid = p.pronamespace
                WHERE n.nspname = 'public'
                  AND p.proname = 'post_stock_opname'
            )
        )

    UNION ALL

    SELECT
        'direct_opname_write_privilege','INFO',
        jsonb_build_object(
            'stock_opnames_insert',has_table_privilege(
                'authenticated','public.stock_opnames','INSERT'
            ),
            'stock_opnames_update',has_table_privilege(
                'authenticated','public.stock_opnames','UPDATE'
            ),
            'stock_opname_details_insert',has_table_privilege(
                'authenticated','public.stock_opname_details','INSERT'
            ),
            'stock_opname_details_update',has_table_privilege(
                'authenticated','public.stock_opname_details','UPDATE'
            )
        )
)
SELECT check_name,status,details
FROM checks
ORDER BY
    CASE status
        WHEN 'BLOCKER' THEN 1
        WHEN 'REVIEW' THEN 2
        WHEN 'BACKFILL' THEN 3
        WHEN 'PASS' THEN 4
        ELSE 5
    END,
    check_name;
