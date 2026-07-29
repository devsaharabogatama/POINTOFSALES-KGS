-- G3 phase 4 preflight: canonical Stock Movement / Kartu Stok readiness.
--
-- SAFETY:
-- - SELECT-only; no DDL, DML, TEMP table, function side effect, or grants.
-- - Returns aggregate counts only and never exposes Product/business rows.

WITH required_versions(version) AS (
    VALUES
        ('20260728090000'),
        ('20260728120000')
), expected_movement_columns(column_name) AS (
    VALUES
        ('base_uom_id'),
        ('base_uom_name_snapshot'),
        ('balance_after_base_qty'),
        ('actor_id'),
        ('posted_at'),
        ('movement_status'),
        ('source_line_id'),
        ('notes')
), expected_movement_types(label) AS (
    VALUES
        ('OPENING_BALANCE'),
        ('SALE'),
        ('PURCHASE'),
        ('ADJUSTMENT'),
        ('TRANSFER_IN'),
        ('TRANSFER_OUT'),
        ('SALES_RETURN'),
        ('PURCHASE_RETURN'),
        ('OPNAME_GAIN'),
        ('OPNAME_LOSS'),
        ('REVERSAL')
), movement_totals AS (
    SELECT
        company_id,
        product_id,
        warehouse_id,
        sum(qty_change) AS movement_qty
    FROM public.stock_movements
    GROUP BY company_id,product_id,warehouse_id
), checks AS (
    SELECT
        'g3_stock_movement_dependencies'::text AS check_name,
        CASE WHEN count(*) FILTER (WHERE m.version IS NULL) = 0
             THEN 'PASS' ELSE 'BLOCKER' END AS status,
        jsonb_build_object(
            'expected',count(*),
            'missing',COALESCE(
                jsonb_agg(r.version ORDER BY r.version)
                    FILTER (WHERE m.version IS NULL),
                '[]'::jsonb
            )
        ) AS details
    FROM required_versions r
    LEFT JOIN private.kgs_schema_migrations m ON m.version = r.version

    UNION ALL

    SELECT
        'invalid_stock_movement_shape',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.stock_movements
    WHERE qty_change = 0
       OR btrim(reference_table) = ''
       OR reference_id IS NULL

    UNION ALL

    SELECT
        'stock_movement_tenant_reference_integrity',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('orphan_rows',count(*))
    FROM public.stock_movements sm
    LEFT JOIN public.products p
      ON p.company_id = sm.company_id
     AND p.id = sm.product_id
    LEFT JOIN public.warehouses w
      ON w.company_id = sm.company_id
     AND w.id = sm.warehouse_id
    WHERE p.id IS NULL OR w.id IS NULL

    UNION ALL

    SELECT
        'duplicate_stock_movement_source',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('duplicate_groups',count(*))
    FROM (
        SELECT
            company_id,product_id,warehouse_id,movement_type,
            reference_table,reference_id
        FROM public.stock_movements
        GROUP BY
            company_id,product_id,warehouse_id,movement_type,
            reference_table,reference_id
        HAVING count(*) > 1
    ) duplicate_groups

    UNION ALL

    SELECT
        'stock_balance_without_movement',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('pair_count',count(*))
    FROM public.product_stocks ps
    LEFT JOIN movement_totals mt
      ON mt.company_id = ps.company_id
     AND mt.product_id = ps.product_id
     AND mt.warehouse_id = ps.warehouse_id
    WHERE mt.product_id IS NULL

    UNION ALL

    SELECT
        'movement_without_stock_balance',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('pair_count',count(*))
    FROM movement_totals mt
    LEFT JOIN public.product_stocks ps
      ON ps.company_id = mt.company_id
     AND ps.product_id = mt.product_id
     AND ps.warehouse_id = mt.warehouse_id
    WHERE ps.product_id IS NULL

    UNION ALL

    SELECT
        'stock_balance_movement_mismatch',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('pair_count',count(*))
    FROM public.product_stocks ps
    JOIN movement_totals mt
      ON mt.company_id = ps.company_id
     AND mt.product_id = ps.product_id
     AND mt.warehouse_id = ps.warehouse_id
    WHERE ps.stock_qty IS DISTINCT FROM mt.movement_qty

    UNION ALL

    SELECT
        'negative_stock_balance',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.product_stocks
    WHERE stock_qty < 0

    UNION ALL

    SELECT
        'movement_without_canonical_base_uom',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('product_count',count(*))
    FROM (
        SELECT DISTINCT sm.company_id,sm.product_id
        FROM public.stock_movements sm
        JOIN public.products p
          ON p.company_id = sm.company_id
         AND p.id = sm.product_id
        LEFT JOIN public.uoms u
          ON u.company_id = p.company_id
         AND u.id = p.uom_id
        WHERE p.uom_id IS NULL OR u.id IS NULL
    ) affected_products

    UNION ALL

    SELECT
        'opening_movement_without_posted_document',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.stock_movements sm
    LEFT JOIN public.opening_stock_documents d
      ON d.company_id = sm.company_id
     AND d.id = sm.reference_id
    WHERE sm.movement_type = 'OPENING_BALANCE'::stock_movement_type
      AND (
          sm.reference_table <> 'opening_stock_documents'
          OR d.id IS NULL
          OR d.status <> 'POSTED'
      )

    UNION ALL

    SELECT
        'posted_opening_line_without_movement',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('line_count',count(*))
    FROM public.opening_stock_lines l
    JOIN public.opening_stock_documents d
      ON d.company_id = l.company_id
     AND d.id = l.document_id
    WHERE d.status = 'POSTED'
      AND NOT EXISTS (
          SELECT 1
          FROM public.stock_movements sm
          WHERE sm.company_id = l.company_id
            AND sm.product_id = l.product_id
            AND sm.warehouse_id = d.warehouse_id
            AND sm.movement_type =
                'OPENING_BALANCE'::stock_movement_type
            AND sm.reference_table = 'opening_stock_documents'
            AND sm.reference_id = d.id
      )

    UNION ALL

    SELECT
        'canonical_stock_movement_schema_state',
        'INFO',
        jsonb_build_object(
            'missing_columns',COALESCE(
                jsonb_agg(e.column_name ORDER BY e.column_name)
                    FILTER (WHERE c.column_name IS NULL),
                '[]'::jsonb
            )
        )
    FROM expected_movement_columns e
    LEFT JOIN information_schema.columns c
      ON c.table_schema = 'public'
     AND c.table_name = 'stock_movements'
     AND c.column_name = e.column_name

    UNION ALL

    SELECT
        'canonical_stock_movement_type_state',
        'INFO',
        jsonb_build_object(
            'missing_labels',COALESCE(
                jsonb_agg(e.label ORDER BY e.label)
                    FILTER (WHERE live.enumlabel IS NULL),
                '[]'::jsonb
            ),
            'current_labels',(
                SELECT COALESCE(
                    jsonb_agg(x.enumlabel ORDER BY x.enumsortorder),
                    '[]'::jsonb
                )
                FROM pg_type t
                JOIN pg_enum x ON x.enumtypid = t.oid
                JOIN pg_namespace n ON n.oid = t.typnamespace
                WHERE n.nspname = 'public'
                  AND t.typname = 'stock_movement_type'
            )
        )
    FROM expected_movement_types e
    LEFT JOIN (
        SELECT x.enumlabel
        FROM pg_type t
        JOIN pg_enum x ON x.enumtypid = t.oid
        JOIN pg_namespace n ON n.oid = t.typnamespace
        WHERE n.nspname = 'public'
          AND t.typname = 'stock_movement_type'
    ) live ON live.enumlabel = e.label

    UNION ALL

    SELECT
        'stock_movement_inventory',
        'INFO',
        jsonb_build_object(
            'movement_rows',count(*),
            'companies',count(DISTINCT company_id),
            'product_warehouse_pairs',
                count(DISTINCT (company_id,product_id,warehouse_id)),
            'source_documents',
                count(DISTINCT (company_id,reference_table,reference_id)),
            'opening_rows',count(*) FILTER (
                WHERE movement_type =
                    'OPENING_BALANCE'::stock_movement_type
            )
        )
    FROM public.stock_movements

    UNION ALL

    SELECT
        'direct_stock_movement_write_privilege',
        'INFO',
        jsonb_build_object(
            'authenticated_insert',has_table_privilege(
                'authenticated','public.stock_movements','INSERT'
            ),
            'authenticated_update',has_table_privilege(
                'authenticated','public.stock_movements','UPDATE'
            ),
            'authenticated_delete',has_table_privilege(
                'authenticated','public.stock_movements','DELETE'
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
