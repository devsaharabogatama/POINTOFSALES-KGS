-- G3 phase 4 canonical Stock Movement postflight.
-- Expected result: every row PASS with violation_rows = 0.

WITH required_columns(column_name) AS (
    VALUES
        ('base_uom_id'),('base_uom_name_snapshot'),
        ('balance_after_base_qty'),('actor_id'),('posted_at'),
        ('movement_status'),('source_line_id'),('notes')
), required_types(label) AS (
    VALUES
        ('OPENING_BALANCE'),('SALE'),('PURCHASE'),('ADJUSTMENT'),
        ('TRANSFER_IN'),('TRANSFER_OUT'),('SALES_RETURN'),
        ('PURCHASE_RETURN'),('OPNAME_GAIN'),('OPNAME_LOSS'),('REVERSAL')
), checks AS (
    SELECT
        'migration_ledger'::text AS check_name,
        CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'FAIL' END AS status,
        abs(1-count(*))::bigint AS violation_rows,
        jsonb_build_object('ledger_rows',count(*)) AS details
    FROM private.kgs_schema_migrations
    WHERE version = '20260728150000'

    UNION ALL

    SELECT
        'required_movement_columns',
        CASE WHEN count(*) FILTER (WHERE c.column_name IS NULL) = 0
             THEN 'PASS' ELSE 'FAIL' END,
        count(*) FILTER (WHERE c.column_name IS NULL),
        jsonb_build_object(
            'column_rows',count(*) FILTER (WHERE c.column_name IS NOT NULL),
            'missing',COALESCE(
                jsonb_agg(e.column_name ORDER BY e.column_name)
                    FILTER (WHERE c.column_name IS NULL),
                '[]'::jsonb
            )
        )
    FROM required_columns e
    LEFT JOIN information_schema.columns c
      ON c.table_schema = 'public'
     AND c.table_name = 'stock_movements'
     AND c.column_name = e.column_name

    UNION ALL

    SELECT
        'required_movement_types',
        CASE WHEN count(*) FILTER (WHERE live.enumlabel IS NULL) = 0
             THEN 'PASS' ELSE 'FAIL' END,
        count(*) FILTER (WHERE live.enumlabel IS NULL),
        jsonb_build_object(
            'enum_rows',count(*) FILTER (WHERE live.enumlabel IS NOT NULL)
        )
    FROM required_types e
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
        'opening_movement_snapshot_complete',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),
        jsonb_build_object('row_count',count(*))
    FROM public.stock_movements
    WHERE movement_type = 'OPENING_BALANCE'::stock_movement_type
      AND (
          base_uom_id IS NULL
          OR NULLIF(btrim(base_uom_name_snapshot),'') IS NULL
          OR balance_after_base_qty IS NULL
          OR actor_id IS NULL
          OR posted_at IS NULL
          OR movement_status <> 'POSTED'
          OR source_line_id IS NULL
      )

    UNION ALL

    SELECT
        'opening_balance_after_matches_line',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),
        jsonb_build_object('row_count',count(*))
    FROM public.stock_movements sm
    JOIN public.opening_stock_lines l
      ON l.company_id = sm.company_id
     AND l.id = sm.source_line_id
    WHERE sm.movement_type =
            'OPENING_BALANCE'::stock_movement_type
      AND (
          sm.base_uom_id IS DISTINCT FROM l.base_uom_id
          OR sm.base_uom_name_snapshot IS DISTINCT FROM
              l.base_uom_name_snapshot
          OR sm.balance_after_base_qty IS DISTINCT FROM l.quantity_base
      )

    UNION ALL

    SELECT
        'canonical_movement_constraints',
        CASE WHEN count(*) = 5 THEN 'PASS' ELSE 'FAIL' END,
        abs(5-count(*))::bigint,
        jsonb_build_object('constraint_rows',count(*))
    FROM pg_constraint con
    JOIN pg_class rel ON rel.oid = con.conrelid
    JOIN pg_namespace n ON n.oid = rel.relnamespace
    WHERE n.nspname = 'public'
      AND rel.relname = 'stock_movements'
      AND con.conname IN (
          'fk_stock_movements_company_base_uom',
          'fk_stock_movements_actor',
          'stock_movements_quantity_nonzero',
          'stock_movements_status_check',
          'stock_movements_opening_snapshot_complete'
      )

    UNION ALL

    SELECT
        'canonical_movement_indexes',
        CASE WHEN count(*) = 2 THEN 'PASS' ELSE 'FAIL' END,
        abs(2-count(*))::bigint,
        jsonb_build_object('index_rows',count(*))
    FROM pg_indexes
    WHERE schemaname = 'public'
      AND tablename = 'stock_movements'
      AND indexname IN (
          'uq_stock_movements_canonical_source_line',
          'idx_stock_movements_company_posted_card'
      )

    UNION ALL

    SELECT
        'canonical_movement_triggers',
        CASE WHEN count(*) = 2 THEN 'PASS' ELSE 'FAIL' END,
        abs(2-count(*))::bigint,
        jsonb_build_object('trigger_rows',count(*))
    FROM pg_trigger t
    JOIN pg_class rel ON rel.oid = t.tgrelid
    JOIN pg_namespace n ON n.oid = rel.relnamespace
    WHERE n.nspname = 'public'
      AND rel.relname = 'stock_movements'
      AND NOT t.tgisinternal
      AND t.tgname IN (
          'g3_canonical_opening_movement',
          'g3_stock_movement_immutable'
      )

    UNION ALL

    SELECT
        'required_private_trigger_routines',
        CASE WHEN count(*) = 2 THEN 'PASS' ELSE 'FAIL' END,
        abs(2-count(*))::bigint,
        jsonb_build_object('routine_rows',count(*))
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'private'
      AND p.proname IN (
          'trg_g3_canonical_opening_movement',
          'trg_g3_stock_movement_immutable'
      )
      AND p.prosecdef
      AND COALESCE(p.proconfig,ARRAY[]::text[])::text[]
          @> ARRAY['search_path=public, pg_temp']::text[]

    UNION ALL

    SELECT
        'stock_balance_movement_reconciliation',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),
        jsonb_build_object('pair_count',count(*))
    FROM public.product_stocks ps
    FULL JOIN (
        SELECT company_id,product_id,warehouse_id,sum(qty_change) AS qty
        FROM public.stock_movements
        GROUP BY company_id,product_id,warehouse_id
    ) mt
      ON mt.company_id = ps.company_id
     AND mt.product_id = ps.product_id
     AND mt.warehouse_id = ps.warehouse_id
    WHERE ps.product_id IS NULL
       OR mt.product_id IS NULL
       OR ps.stock_qty IS DISTINCT FROM mt.qty

    UNION ALL

    SELECT
        'browser_movement_write_boundary',
        CASE WHEN (
            has_table_privilege(
                'authenticated','public.stock_movements','INSERT'
            )
            OR has_table_privilege(
                'authenticated','public.stock_movements','UPDATE'
            )
            OR has_table_privilege(
                'authenticated','public.stock_movements','DELETE'
            )
        ) THEN 'FAIL' ELSE 'PASS' END,
        CASE WHEN (
            has_table_privilege(
                'authenticated','public.stock_movements','INSERT'
            )
            OR has_table_privilege(
                'authenticated','public.stock_movements','UPDATE'
            )
            OR has_table_privilege(
                'authenticated','public.stock_movements','DELETE'
            )
        ) THEN 1 ELSE 0 END,
        jsonb_build_object(
            'direct_write',has_table_privilege(
                'authenticated',
                'public.stock_movements',
                'INSERT,UPDATE,DELETE'
            )
        )
)
SELECT check_name,status,violation_rows,details
FROM checks
ORDER BY CASE WHEN violation_rows > 0 THEN 1 ELSE 2 END,check_name;
