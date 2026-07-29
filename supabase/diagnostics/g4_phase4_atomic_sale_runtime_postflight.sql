-- G4 phase 4 postflight: atomic Sale Draft/Post runtime.
-- SAFETY: SELECT-only; returns one row per invariant.

WITH required_columns(table_name,column_name) AS (
    VALUES
        ('sales_headers','document_status'),
        ('sales_headers','client_transaction_id'),
        ('sales_headers','posting_idempotency_key'),
        ('sales_headers','sales_warehouse_id'),
        ('sales_headers','posted_session_id'),
        ('sales_headers','grand_total_before_rounding'),
        ('sales_headers','rounding_direction'),
        ('sales_headers','rounding_increment'),
        ('sales_headers','rounding_adjustment'),
        ('sales_headers','grand_total_after_rounding'),
        ('sales_headers','receipt_snapshot'),
        ('sales_headers','master_version'),
        ('sales_headers','updated_at'),
        ('sales_headers','posted_at'),
        ('sales_headers','posted_by'),
        ('sales_details','product_uom_id'),
        ('sales_details','sale_uom_id'),
        ('sales_details','sale_uom_name_snapshot'),
        ('sales_details','uom_factor_to_base_snapshot'),
        ('sales_details','quantity_base'),
        ('sales_details','product_sku_snapshot'),
        ('sales_details','product_name_snapshot'),
        ('sales_details','fifo_cost_total'),
        ('sales_payments','tendered_amount'),
        ('sales_payments','change_amount'),
        ('sales_payments','proof_url')
), required_tables(table_name) AS (
    VALUES
        ('sale_stock_requirements'),
        ('bundle_sale_allocations'),
        ('sale_fifo_allocations'),
        ('sale_master_audit')
), required_routines(signature) AS (
    VALUES
        ('private.resolve_pos_sale_price(uuid,uuid,uuid,uuid,numeric,timestamp with time zone)'),
        ('private.reprice_pos_sale_draft(uuid,uuid,uuid,jsonb,timestamp with time zone)'),
        ('public.save_pos_sale_draft(jsonb)'),
        ('public.post_pos_sale(uuid,bigint,uuid)'),
        ('public.private_sale_visible(uuid)')
), movement_totals AS (
    SELECT company_id,product_id,warehouse_id,sum(qty_change) AS qty
    FROM public.stock_movements
    WHERE movement_status = 'POSTED'
    GROUP BY company_id,product_id,warehouse_id
), fifo_totals AS (
    SELECT company_id,product_id,warehouse_id,sum(qty_remaining) AS qty
    FROM public.product_batches
    GROUP BY company_id,product_id,warehouse_id
), checks AS (
    SELECT
        'migration_ledger'::TEXT AS check_name,
        CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'FAIL' END AS status,
        count(*)::BIGINT AS violation_rows,
        jsonb_build_object('ledger_rows',count(*)) AS details
    FROM private.kgs_schema_migrations
    WHERE version = '20260729070000'

    UNION ALL

    SELECT
        'required_sale_columns',
        CASE WHEN count(*) FILTER (WHERE c.column_name IS NULL) = 0
             THEN 'PASS' ELSE 'FAIL' END,
        count(*) FILTER (WHERE c.column_name IS NULL),
        jsonb_build_object(
            'column_rows',count(*) FILTER (WHERE c.column_name IS NOT NULL),
            'expected',count(*),
            'missing',COALESCE(
                jsonb_agg(r.table_name || '.' || r.column_name
                    ORDER BY r.table_name,r.column_name)
                    FILTER (WHERE c.column_name IS NULL),
                '[]'::JSONB
            )
        )
    FROM required_columns r
    LEFT JOIN information_schema.columns c
      ON c.table_schema = 'public'
     AND c.table_name = r.table_name
     AND c.column_name = r.column_name

    UNION ALL

    SELECT
        'required_sale_tables',
        CASE WHEN count(*) FILTER (
            WHERE to_regclass('public.' || table_name) IS NULL
        ) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*) FILTER (
            WHERE to_regclass('public.' || table_name) IS NULL
        ),
        jsonb_build_object(
            'table_rows',count(*) FILTER (
                WHERE to_regclass('public.' || table_name) IS NOT NULL
            ),
            'expected',count(*)
        )
    FROM required_tables

    UNION ALL

    SELECT
        'required_sale_routines',
        CASE WHEN count(*) FILTER (
            WHERE to_regprocedure(signature) IS NULL
        ) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*) FILTER (WHERE to_regprocedure(signature) IS NULL),
        jsonb_build_object(
            'routine_rows',count(*) FILTER (
                WHERE to_regprocedure(signature) IS NOT NULL
            ),
            'expected',count(*)
        )
    FROM required_routines

    UNION ALL

    SELECT
        'legacy_checkout_browser_retired',
        CASE WHEN
            NOT has_function_privilege(
                'authenticated',
                'public.create_sales_transaction(text,uuid,uuid,boolean,timestamp with time zone,boolean,text,numeric,numeric,numeric,numeric,numeric,numeric,public.payment_status,uuid,jsonb,jsonb,jsonb)',
                'EXECUTE'
            )
        THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN has_function_privilege(
            'authenticated',
            'public.create_sales_transaction(text,uuid,uuid,boolean,timestamp with time zone,boolean,text,numeric,numeric,numeric,numeric,numeric,numeric,public.payment_status,uuid,jsonb,jsonb,jsonb)',
            'EXECUTE'
        ) THEN 1 ELSE 0 END,
        jsonb_build_object(
            'authenticated_execute',has_function_privilege(
                'authenticated',
                'public.create_sales_transaction(text,uuid,uuid,boolean,timestamp with time zone,boolean,text,numeric,numeric,numeric,numeric,numeric,numeric,public.payment_status,uuid,jsonb,jsonb,jsonb)',
                'EXECUTE'
            )
        )

    UNION ALL

    SELECT
        'canonical_sale_rpc_boundary',
        CASE WHEN
            has_function_privilege(
                'authenticated','public.save_pos_sale_draft(jsonb)','EXECUTE'
            )
            AND has_function_privilege(
                'authenticated',
                'public.post_pos_sale(uuid,bigint,uuid)','EXECUTE'
            )
            AND NOT has_function_privilege(
                'authenticated',
                'private.resolve_pos_sale_price(uuid,uuid,uuid,uuid,numeric,timestamp with time zone)',
                'EXECUTE'
            )
        THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN
            has_function_privilege(
                'authenticated','public.save_pos_sale_draft(jsonb)','EXECUTE'
            )
            AND has_function_privilege(
                'authenticated',
                'public.post_pos_sale(uuid,bigint,uuid)','EXECUTE'
            )
            AND NOT has_function_privilege(
                'authenticated',
                'private.resolve_pos_sale_price(uuid,uuid,uuid,uuid,numeric,timestamp with time zone)',
                'EXECUTE'
            )
        THEN 0 ELSE 1 END,
        jsonb_build_object(
            'save_draft_execute',has_function_privilege(
                'authenticated','public.save_pos_sale_draft(jsonb)','EXECUTE'
            ),
            'post_sale_execute',has_function_privilege(
                'authenticated',
                'public.post_pos_sale(uuid,bigint,uuid)','EXECUTE'
            ),
            'private_price_execute',has_function_privilege(
                'authenticated',
                'private.resolve_pos_sale_price(uuid,uuid,uuid,uuid,numeric,timestamp with time zone)',
                'EXECUTE'
            )
        )

    UNION ALL

    SELECT
        'browser_direct_sale_stock_write_boundary',
        CASE WHEN
            NOT has_table_privilege(
                'authenticated','public.sales_headers',
                'INSERT,UPDATE,DELETE'
            )
            AND NOT has_table_privilege(
                'authenticated','public.sales_details',
                'INSERT,UPDATE,DELETE'
            )
            AND NOT has_table_privilege(
                'authenticated','public.sales_payments',
                'INSERT,UPDATE,DELETE'
            )
            AND NOT has_table_privilege(
                'authenticated','public.sale_stock_requirements',
                'INSERT,UPDATE,DELETE'
            )
            AND NOT has_table_privilege(
                'authenticated','public.product_stocks',
                'INSERT,UPDATE,DELETE'
            )
            AND NOT has_table_privilege(
                'authenticated','public.product_batches',
                'INSERT,UPDATE,DELETE'
            )
            AND NOT has_table_privilege(
                'authenticated','public.stock_movements',
                'INSERT,UPDATE,DELETE'
            )
        THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN
            has_table_privilege(
                'authenticated','public.sales_headers',
                'INSERT,UPDATE,DELETE'
            )
            OR has_table_privilege(
                'authenticated','public.sales_details',
                'INSERT,UPDATE,DELETE'
            )
            OR has_table_privilege(
                'authenticated','public.sales_payments',
                'INSERT,UPDATE,DELETE'
            )
            OR has_table_privilege(
                'authenticated','public.sale_stock_requirements',
                'INSERT,UPDATE,DELETE'
            )
            OR has_table_privilege(
                'authenticated','public.product_stocks',
                'INSERT,UPDATE,DELETE'
            )
            OR has_table_privilege(
                'authenticated','public.product_batches',
                'INSERT,UPDATE,DELETE'
            )
            OR has_table_privilege(
                'authenticated','public.stock_movements',
                'INSERT,UPDATE,DELETE'
            )
        THEN 1 ELSE 0 END,
        '{}'::JSONB

    UNION ALL

    SELECT
        'posted_sale_runtime_contract',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),
        jsonb_build_object('row_count',count(*))
    FROM public.sales_headers sh
    WHERE sh.document_status = 'POSTED'
      AND (
          sh.posting_idempotency_key IS NULL
          OR sh.sales_warehouse_id IS NULL
          OR sh.posted_session_id IS NULL
          OR sh.posted_at IS NULL
          OR sh.posted_by IS NULL
          OR sh.receipt_snapshot IS NULL
          OR sh.invoice_status <> 'GENERATED'::public.invoice_status
          OR sh.grand_total_after_rounding < 0
      )

    UNION ALL

    SELECT
        'posted_sale_detail_snapshot_contract',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),
        jsonb_build_object('detail_count',count(*))
    FROM public.sales_details sd
    JOIN public.sales_headers sh
      ON sh.company_id = sd.company_id AND sh.id = sd.sales_id
    WHERE sh.document_status = 'POSTED'
      AND (
          sd.client_line_key IS NULL
          OR sd.product_uom_id IS NULL
          OR sd.sale_uom_id IS NULL
          OR sd.sale_uom_name_snapshot IS NULL
          OR sd.uom_factor_to_base_snapshot IS NULL
          OR sd.quantity_base IS NULL
          OR sd.product_sku_snapshot IS NULL
          OR sd.product_name_snapshot IS NULL
          OR sd.pricing_resolved_at IS NULL
      )

    UNION ALL

    SELECT
        'draft_sale_has_no_final_effect',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),
        jsonb_build_object('sale_count',count(*))
    FROM public.sales_headers sh
    WHERE sh.document_status = 'DRAFT'
      AND (
          EXISTS (
              SELECT 1 FROM public.stock_movements sm
              WHERE sm.company_id = sh.company_id
                AND sm.reference_table = 'sales_headers'
                AND sm.reference_id = sh.id
          )
          OR EXISTS (
              SELECT 1 FROM public.sales_payments sp
              WHERE sp.company_id = sh.company_id
                AND sp.sales_id = sh.id
          )
          OR EXISTS (
              SELECT 1 FROM public.financial_events fe
              WHERE fe.company_id = sh.company_id
                AND fe.source_table = 'sales_headers'
                AND fe.source_id = sh.id
          )
      )

    UNION ALL

    SELECT
        'posted_stock_sale_effect_coverage',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),
        jsonb_build_object('requirement_count',count(*))
    FROM public.sale_stock_requirements r
    JOIN public.sales_headers sh
      ON sh.company_id = r.company_id AND sh.id = r.sales_id
    WHERE sh.document_status = 'POSTED'
      AND NOT EXISTS (
          SELECT 1 FROM public.sale_fifo_allocations fa
          WHERE fa.company_id = r.company_id
            AND fa.stock_requirement_id = r.id
      )

    UNION ALL

    SELECT
        'posted_sale_movement_coverage',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),
        jsonb_build_object('product_count',count(*))
    FROM (
        SELECT r.company_id,r.sales_id,r.stock_product_id
        FROM public.sale_stock_requirements r
        JOIN public.sales_headers sh
          ON sh.company_id = r.company_id AND sh.id = r.sales_id
        WHERE sh.document_status = 'POSTED'
        GROUP BY r.company_id,r.sales_id,r.stock_product_id
    ) requirement
    WHERE NOT EXISTS (
        SELECT 1 FROM public.stock_movements sm
        WHERE sm.company_id = requirement.company_id
          AND sm.reference_table = 'sales_headers'
          AND sm.reference_id = requirement.sales_id
          AND sm.product_id = requirement.stock_product_id
          AND sm.movement_type = 'SALE'::public.stock_movement_type
          AND sm.movement_status = 'POSTED'
    )

    UNION ALL

    SELECT
        'posted_sale_financial_event_coverage',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),
        jsonb_build_object('sale_count',count(*))
    FROM public.sales_headers sh
    WHERE sh.document_status = 'POSTED'
      AND NOT EXISTS (
          SELECT 1 FROM public.financial_events fe
          WHERE fe.company_id = sh.company_id
            AND fe.source_table = 'sales_headers'
            AND fe.source_id = sh.id
            AND fe.event_type = 'SALE_POSTED'::public.event_type
            AND fe.status = 'HOLD'::public.event_status
      )

    UNION ALL

    SELECT
        'stock_balance_movement_reconciliation',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),
        jsonb_build_object('pair_count',count(*))
    FROM public.product_stocks ps
    FULL JOIN movement_totals mt
      ON mt.company_id = ps.company_id
     AND mt.product_id = ps.product_id
     AND mt.warehouse_id = ps.warehouse_id
    WHERE ps.product_id IS NULL
       OR mt.product_id IS NULL
       OR ps.stock_qty IS DISTINCT FROM mt.qty

    UNION ALL

    SELECT
        'stock_balance_fifo_reconciliation',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),
        jsonb_build_object('pair_count',count(*))
    FROM public.product_stocks ps
    LEFT JOIN fifo_totals ft
      ON ft.company_id = ps.company_id
     AND ft.product_id = ps.product_id
     AND ft.warehouse_id = ps.warehouse_id
    WHERE ps.stock_qty < 0
       OR (
           ps.stock_qty > 0
           AND ps.stock_qty IS DISTINCT FROM COALESCE(ft.qty,0)
       )

    UNION ALL

    SELECT
        'bundle_allocation_conservation',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),
        jsonb_build_object('bundle_line_count',count(*))
    FROM (
        SELECT
            sd.id,
            sd.resolved_unit_price * sd.qty AS gross,
            sd.line_discount_amount + sd.allocated_order_discount_amount
                AS discount,
            sd.tax_amount,
            sd.allocated_document_rounding,
            sd.line_total + sd.allocated_document_rounding AS net,
            sum(ba.allocated_gross) AS allocated_gross,
            sum(ba.allocated_discount) AS allocated_discount,
            sum(ba.allocated_tax) AS allocated_tax,
            sum(ba.allocated_rounding) AS allocated_rounding,
            sum(ba.allocated_net) AS allocated_net
        FROM public.sales_details sd
        JOIN public.sales_headers sh
          ON sh.company_id = sd.company_id AND sh.id = sd.sales_id
        JOIN public.products p
          ON p.company_id = sd.company_id
         AND p.id = sd.product_id
         AND p.is_bundle
        LEFT JOIN public.bundle_sale_allocations ba
          ON ba.company_id = sd.company_id
         AND ba.sales_detail_id = sd.id
        WHERE sh.document_status = 'POSTED'
        GROUP BY sd.id
    ) allocation
    WHERE gross IS DISTINCT FROM allocated_gross
       OR discount IS DISTINCT FROM allocated_discount
       OR tax_amount IS DISTINCT FROM allocated_tax
       OR allocated_document_rounding IS DISTINCT FROM allocated_rounding
       OR net IS DISTINCT FROM allocated_net

    UNION ALL

    SELECT
        'sale_runtime_inventory',
        'PASS',
        0,
        jsonb_build_object(
            'draft_sales',count(*) FILTER (WHERE document_status = 'DRAFT'),
            'posted_sales',count(*) FILTER (WHERE document_status = 'POSTED'),
            'shortage_drafts',count(*) FILTER (
                WHERE document_status = 'DRAFT'
                  AND draft_reason = 'STOCK_SHORTAGE'
            ),
            'fifo_allocations',(
                SELECT count(*) FROM public.sale_fifo_allocations
            ),
            'bundle_allocations',(
                SELECT count(*) FROM public.bundle_sale_allocations
            )
        )
    FROM public.sales_headers
)
SELECT check_name,status,violation_rows,details
FROM checks
ORDER BY
    CASE status WHEN 'FAIL' THEN 1 ELSE 2 END,
    check_name;
