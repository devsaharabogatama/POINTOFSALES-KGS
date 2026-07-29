-- G4 phase 10 preflight: online checkout E2E and true-concurrency readiness.
--
-- SAFETY:
-- - SELECT-only; no DDL, DML, TEMP table, function side effect, or grants.
-- - Returns aggregate counts and runtime contract metadata only.
-- - This does not post a Sale or change stock.

WITH required_versions(version) AS (
    VALUES
        ('20260729070000'),
        ('20260729100000'),
        ('20260729120000'),
        ('20260729150000')
), post_runtime AS (
    SELECT
        pg_get_functiondef(
            to_regprocedure('public.post_pos_sale(uuid,bigint,uuid)')
        ) AS wrapper_definition,
        pg_get_functiondef(
            to_regprocedure('private.post_pos_sale_core(uuid,bigint,uuid)')
        ) AS core_definition
), eligible_store_users AS (
    SELECT
        sm.company_id,
        sm.store_id,
        sm.user_id
    FROM public.store_memberships sm
    JOIN auth.users au ON au.id = sm.user_id
    WHERE sm.status = 'ACTIVE'
      AND sm.role_code IN ('CASHIER','STORE_MANAGER')

    UNION

    SELECT
        s.company_id,
        s.id AS store_id,
        cm.user_id
    FROM public.stores s
    JOIN public.company_memberships cm
      ON cm.company_id = s.company_id
     AND cm.status = 'ACTIVE'
     AND cm.role_code IN ('COMPANY_OWNER','COMPANY_ADMIN')
    JOIN auth.users au ON au.id = cm.user_id
    WHERE s.status = 'ACTIVE'

    UNION

    SELECT
        s.company_id,
        s.id AS store_id,
        p.id AS user_id
    FROM public.stores s
    JOIN public.profiles p
      ON p.role = 'super_admin'::public.user_role
    JOIN auth.users au ON au.id = p.id
    WHERE s.status = 'ACTIVE'
), store_readiness AS (
    SELECT
        s.company_id,
        s.id AS store_id,
        count(DISTINCT eu.user_id) AS eligible_users,
        count(DISTINCT pt.id) FILTER (
            WHERE pt.status = 'ACTIVE'
        ) AS active_terminals,
        EXISTS (
            SELECT 1
            FROM public.warehouses w
            JOIN public.product_stocks ps
              ON ps.company_id = w.company_id
             AND ps.warehouse_id = w.id
             AND ps.stock_qty > 0
            WHERE w.company_id = s.company_id
              AND (w.store_id IS NULL OR w.store_id = s.id)
              AND w.is_active
              AND w.is_sale_source
              AND EXISTS (
                  SELECT 1
                  FROM public.product_batches pb
                  WHERE pb.company_id = ps.company_id
                    AND pb.warehouse_id = ps.warehouse_id
                    AND pb.product_id = ps.product_id
                    AND pb.qty_remaining > 0
              )
        ) AS has_positive_stock_fifo,
        EXISTS (
            SELECT 1
            FROM public.payment_methods pm
            WHERE pm.company_id = s.company_id
              AND pm.is_active
              AND pm.method_type NOT IN (
                  'CUSTOMER_BALANCE','KETUL_OFFSET','TEMPO'
              )
              AND (
                  pm.available_all_stores
                  OR EXISTS (
                      SELECT 1
                      FROM public.payment_method_store_assignments pmsa
                      WHERE pmsa.company_id = pm.company_id
                        AND pmsa.payment_method_id = pm.id
                        AND pmsa.store_id = s.id
                  )
              )
        ) AS has_payment_method
    FROM public.stores s
    LEFT JOIN eligible_store_users eu
      ON eu.company_id = s.company_id
     AND eu.store_id = s.id
    LEFT JOIN public.pos_terminals pt
      ON pt.company_id = s.company_id
     AND pt.store_id = s.id
    WHERE s.status = 'ACTIVE'
    GROUP BY s.company_id,s.id
), sale_requirement_totals AS (
    SELECT
        r.company_id,
        r.sales_id,
        r.stock_product_id,
        sum(r.quantity_base) AS required_base_qty
    FROM public.sale_stock_requirements r
    JOIN public.sales_headers sh
      ON sh.company_id = r.company_id
     AND sh.id = r.sales_id
     AND sh.document_status = 'POSTED'
    GROUP BY r.company_id,r.sales_id,r.stock_product_id
), sale_movement_totals AS (
    SELECT
        sm.company_id,
        sm.reference_id AS sales_id,
        sm.product_id,
        -sum(sm.qty_change) AS moved_base_qty
    FROM public.stock_movements sm
    WHERE sm.reference_table = 'sales_headers'
      AND sm.movement_type = 'SALE'::public.stock_movement_type
      AND sm.movement_status = 'POSTED'
    GROUP BY sm.company_id,sm.reference_id,sm.product_id
), balance_movement AS (
    SELECT
        ps.company_id,
        ps.product_id,
        ps.warehouse_id,
        ps.stock_qty,
        COALESCE(sum(sm.qty_change),0) AS movement_qty
    FROM public.product_stocks ps
    LEFT JOIN public.stock_movements sm
      ON sm.company_id = ps.company_id
     AND sm.product_id = ps.product_id
     AND sm.warehouse_id = ps.warehouse_id
     AND sm.movement_status = 'POSTED'
    GROUP BY ps.company_id,ps.product_id,ps.warehouse_id,ps.stock_qty
), balance_fifo AS (
    SELECT
        ps.company_id,
        ps.product_id,
        ps.warehouse_id,
        ps.stock_qty,
        COALESCE(sum(pb.qty_remaining),0) AS fifo_qty
    FROM public.product_stocks ps
    LEFT JOIN public.product_batches pb
      ON pb.company_id = ps.company_id
     AND pb.product_id = ps.product_id
     AND pb.warehouse_id = ps.warehouse_id
     AND pb.qty_remaining > 0
    GROUP BY ps.company_id,ps.product_id,ps.warehouse_id,ps.stock_qty
), checks AS (
    SELECT
        'g4_phase10_dependencies'::text AS check_name,
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
        'sale_post_locking_contract',
        CASE WHEN
            wrapper_definition IS NOT NULL
            AND core_definition IS NOT NULL
            AND position('FOR UPDATE' IN upper(wrapper_definition)) > 0
            AND position('PUBLIC.PRODUCT_STOCKS' IN upper(core_definition)) > 0
            AND position('PUBLIC.PRODUCT_BATCHES' IN upper(core_definition)) > 0
            AND position(
                'STOCK_QTY >= V_REQUIREMENT.QUANTITY_BASE'
                IN upper(core_definition)
            ) > 0
            AND position('IDEMPOTENTREPLAY' IN upper(core_definition)) > 0
            THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'wrapper_exists',wrapper_definition IS NOT NULL,
            'core_exists',core_definition IS NOT NULL,
            'sale_row_lock',
                position(
                    'FOR UPDATE'
                    IN upper(COALESCE(wrapper_definition,''))
                ) > 0,
            'stock_guard',
                position(
                    'STOCK_QTY >= V_REQUIREMENT.QUANTITY_BASE'
                    IN upper(COALESCE(core_definition,''))
                ) > 0,
            'fifo_reference',
                position(
                    'PUBLIC.PRODUCT_BATCHES'
                    IN upper(COALESCE(core_definition,''))
                ) > 0,
            'idempotent_replay',
                position(
                    'IDEMPOTENTREPLAY'
                    IN upper(COALESCE(core_definition,''))
                ) > 0
        )
    FROM post_runtime

    UNION ALL

    SELECT
        'required_sale_identity_indexes',
        CASE WHEN count(*) = 4 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('index_rows',count(*),'expected',4)
    FROM pg_indexes
    WHERE schemaname = 'public'
      AND indexname IN (
          'uq_sales_headers_company_client_transaction',
          'uq_sales_headers_company_posting_idempotency',
          'uq_stock_movements_canonical_source_line',
          'uq_sales_payments_company_sale_client_key'
      )

    UNION ALL

    SELECT
        'concurrent_checkout_fixture_readiness',
        CASE WHEN count(*) FILTER (
            WHERE eligible_users >= 2
              AND active_terminals >= 1
              AND has_positive_stock_fifo
              AND has_payment_method
        ) > 0 THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object(
            'active_stores',count(*),
            'ready_stores',count(*) FILTER (
                WHERE eligible_users >= 2
                  AND active_terminals >= 1
                  AND has_positive_stock_fifo
                  AND has_payment_method
            ),
            'stores_with_two_users',count(*) FILTER (
                WHERE eligible_users >= 2
            ),
            'stores_with_terminal',count(*) FILTER (
                WHERE active_terminals >= 1
            ),
            'stores_with_stock_fifo',count(*) FILTER (
                WHERE has_positive_stock_fifo
            ),
            'stores_with_payment',count(*) FILTER (
                WHERE has_payment_method
            )
        )
    FROM store_readiness

    UNION ALL

    SELECT
        'duplicate_posting_idempotency_key',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('duplicate_groups',count(*))
    FROM (
        SELECT company_id,posting_idempotency_key
        FROM public.sales_headers
        WHERE posting_idempotency_key IS NOT NULL
        GROUP BY company_id,posting_idempotency_key
        HAVING count(*) > 1
    ) duplicates

    UNION ALL

    SELECT
        'duplicate_client_transaction_id',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('duplicate_groups',count(*))
    FROM (
        SELECT company_id,client_transaction_id
        FROM public.sales_headers
        GROUP BY company_id,client_transaction_id
        HAVING count(*) > 1
    ) duplicates

    UNION ALL

    SELECT
        'duplicate_payment_leg_identity',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('duplicate_groups',count(*))
    FROM (
        SELECT company_id,sales_id,client_payment_key
        FROM public.sales_payments
        GROUP BY company_id,sales_id,client_payment_key
        HAVING count(*) > 1
    ) duplicates

    UNION ALL

    SELECT
        'posted_sale_stock_movement_coverage',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('pair_count',count(*))
    FROM sale_requirement_totals r
    FULL JOIN sale_movement_totals m
      ON m.company_id = r.company_id
     AND m.sales_id = r.sales_id
     AND m.product_id = r.stock_product_id
    WHERE r.company_id IS NULL
       OR m.company_id IS NULL
       OR r.required_base_qty IS DISTINCT FROM m.moved_base_qty

    UNION ALL

    SELECT
        'posted_sale_fifo_allocation_coverage',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('requirement_count',count(*))
    FROM public.sale_stock_requirements r
    JOIN public.sales_headers sh
      ON sh.company_id = r.company_id
     AND sh.id = r.sales_id
     AND sh.document_status = 'POSTED'
    LEFT JOIN (
        SELECT
            company_id,
            stock_requirement_id,
            sum(quantity_base) AS allocated_base_qty
        FROM public.sale_fifo_allocations
        GROUP BY company_id,stock_requirement_id
    ) a
      ON a.company_id = r.company_id
     AND a.stock_requirement_id = r.id
    WHERE COALESCE(a.allocated_base_qty,0) <> r.quantity_base

    UNION ALL

    SELECT
        'posted_sale_payment_base_total',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('sale_count',count(*))
    FROM (
        SELECT
            sh.company_id,
            sh.id,
            sh.grand_total_after_rounding,
            COALESCE(
                sum(sp.amount - COALESCE(sp.customer_surcharge_amount,0)),
                0
            ) AS payment_base_total
        FROM public.sales_headers sh
        LEFT JOIN public.sales_payments sp
          ON sp.company_id = sh.company_id
         AND sp.sales_id = sh.id
         AND NOT sp.is_reversal
        WHERE sh.document_status = 'POSTED'
          AND NOT COALESCE(
              (sh.payload_snapshot->>'isTempo')::boolean,
              false
          )
        GROUP BY sh.company_id,sh.id,sh.grand_total_after_rounding
        HAVING COALESCE(
            sum(sp.amount - COALESCE(sp.customer_surcharge_amount,0)),
            0
        ) <> sh.grand_total_after_rounding
    ) invalid_sales

    UNION ALL

    SELECT
        'posted_sale_single_final_effect',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('sale_count',count(*))
    FROM (
        SELECT sh.company_id,sh.id
        FROM public.sales_headers sh
        WHERE sh.document_status = 'POSTED'
          AND (
              (
                  SELECT count(*)
                  FROM public.sale_master_audit a
                  WHERE a.company_id = sh.company_id
                    AND a.sales_id = sh.id
                    AND a.action = 'POST'
              ) <> 1
              OR (
                  SELECT count(*)
                  FROM public.financial_events fe
                  WHERE fe.company_id = sh.company_id
                    AND fe.source_table = 'sales_headers'
                    AND fe.source_id = sh.id
                    AND fe.event_type = 'SALE_POSTED'::public.event_type
              ) <> 1
          )
    ) invalid_sales

    UNION ALL

    SELECT
        'stock_balance_movement_reconciliation',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('pair_count',count(*))
    FROM balance_movement
    WHERE stock_qty <> movement_qty

    UNION ALL

    SELECT
        'stock_balance_fifo_reconciliation',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('pair_count',count(*))
    FROM balance_fifo
    WHERE stock_qty <> fifo_qty

    UNION ALL

    SELECT
        'negative_stock_or_fifo',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM (
        SELECT company_id,product_id,warehouse_id
        FROM public.product_stocks
        WHERE stock_qty < 0
        UNION ALL
        SELECT company_id,product_id,warehouse_id
        FROM public.product_batches
        WHERE qty_remaining < 0
    ) invalid_rows

    UNION ALL

    SELECT
        'browser_direct_final_write_boundary',
        'INFO',
        jsonb_build_object(
            'sales_headers_write',has_table_privilege(
                'authenticated','public.sales_headers',
                'INSERT,UPDATE,DELETE'
            ),
            'sales_payments_write',has_table_privilege(
                'authenticated','public.sales_payments',
                'INSERT,UPDATE,DELETE'
            ),
            'stock_movements_write',has_table_privilege(
                'authenticated','public.stock_movements',
                'INSERT,UPDATE,DELETE'
            ),
            'product_stocks_write',has_table_privilege(
                'authenticated','public.product_stocks',
                'INSERT,UPDATE,DELETE'
            ),
            'product_batches_write',has_table_privilege(
                'authenticated','public.product_batches',
                'INSERT,UPDATE,DELETE'
            )
        )

    UNION ALL

    SELECT
        'online_checkout_runtime_inventory',
        'INFO',
        jsonb_build_object(
            'draft_sales',(
                SELECT count(*) FROM public.sales_headers
                WHERE document_status = 'DRAFT'
            ),
            'posted_sales',(
                SELECT count(*) FROM public.sales_headers
                WHERE document_status = 'POSTED'
            ),
            'payment_legs',(SELECT count(*) FROM public.sales_payments),
            'sale_movements',(
                SELECT count(*) FROM public.stock_movements
                WHERE movement_type = 'SALE'::public.stock_movement_type
            ),
            'sale_fifo_allocations',(
                SELECT count(*) FROM public.sale_fifo_allocations
            ),
            'open_sessions',(
                SELECT count(*) FROM public.cashier_sessions
                WHERE status = 'OPEN'::public.session_status
            )
        )
)
SELECT check_name,status,details
FROM checks
ORDER BY
    CASE status
        WHEN 'BLOCKER' THEN 1
        WHEN 'SETUP' THEN 2
        WHEN 'PASS' THEN 3
        ELSE 4
    END,
    check_name;
