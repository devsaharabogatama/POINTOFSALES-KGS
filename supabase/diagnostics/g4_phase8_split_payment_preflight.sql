-- G4 phase 8 preflight: online split-payment readiness.
--
-- SAFETY:
-- - SELECT-only; no DDL, DML, TEMP table, function side effect, or grants.
-- - Returns aggregate counts and schema/routine state only.

WITH required_versions(version) AS (
    VALUES
        ('20260729070000'),
        ('20260729100000'),
        ('20260729120000')
), eligible_store_methods AS (
    SELECT
        s.company_id,
        s.id AS store_id,
        count(DISTINCT pm.id) AS eligible_methods,
        count(DISTINCT pm.method_type) AS eligible_method_types
    FROM public.stores s
    LEFT JOIN public.payment_methods pm
      ON pm.company_id = s.company_id
     AND pm.is_active
     AND pm.method_type NOT IN (
        'TEMPO','CUSTOMER_BALANCE','KETUL_OFFSET'
     )
     AND pm.effective_from <= clock_timestamp()
     AND (
        pm.effective_to IS NULL
        OR pm.effective_to >= clock_timestamp()
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
    WHERE s.status = 'ACTIVE'
    GROUP BY s.company_id,s.id
), posted_payment_summary AS (
    SELECT
        sh.company_id,
        sh.id AS sales_id,
        sh.is_tempo,
        sh.grand_total_after_rounding,
        count(sp.id) FILTER (WHERE NOT sp.is_reversal) AS payment_legs,
        COALESCE(sum(
            sp.amount - sp.customer_surcharge_amount
        ) FILTER (WHERE NOT sp.is_reversal),0) AS payment_base_total
    FROM public.sales_headers sh
    LEFT JOIN public.sales_payments sp
      ON sp.company_id = sh.company_id
     AND sp.sales_id = sh.id
    WHERE sh.document_status = 'POSTED'
    GROUP BY
        sh.company_id,sh.id,sh.is_tempo,
        sh.grand_total_after_rounding
), checks AS (
    SELECT
        'g4_phase8_dependencies'::text AS check_name,
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
        'server_split_payment_runtime',
        CASE WHEN count(*) = 1
                  AND bool_and(p.prosrc LIKE '%jsonb_array_elements%')
                  AND bool_and(p.prosrc LIKE '%configured_fee_amount%')
                  AND bool_and(p.prosrc LIKE '%v_payment_base_total%')
             THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'routine_rows',count(*),
            'array_payment_loop',COALESCE(
                bool_and(p.prosrc LIKE '%jsonb_array_elements%'),FALSE
            ),
            'per_leg_fee_snapshot',COALESCE(
                bool_and(p.prosrc LIKE '%configured_fee_amount%'),FALSE
            ),
            'base_total_validation',COALESCE(
                bool_and(p.prosrc LIKE '%v_payment_base_total%'),FALSE
            )
        )
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'private'
      AND p.proname = 'post_pos_sale_core'

    UNION ALL

    SELECT
        'active_store_split_method_readiness',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BACKFILL' END,
        jsonb_build_object(
            'active_stores',(SELECT count(*) FROM eligible_store_methods),
            'stores_with_fewer_than_two_methods',count(*),
            'stores_with_fewer_than_two_method_types',
                count(*) FILTER (WHERE eligible_method_types < 2)
        )
    FROM eligible_store_methods
    WHERE eligible_methods < 2 OR eligible_method_types < 2

    UNION ALL

    SELECT
        'invalid_active_payment_method_fee_contract',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.payment_methods pm
    WHERE pm.is_active
      AND (
          btrim(pm.payment_method_name) = ''
          OR (
              pm.fee_enabled
              AND (
                  pm.fee_bearer NOT IN ('COMPANY','CUSTOMER')
                  OR pm.fee_type NOT IN (
                      'PERCENT','FIXED','PERCENT_PLUS_FIXED'
                  )
                  OR (
                      pm.fee_type IN ('PERCENT','PERCENT_PLUS_FIXED')
                      AND pm.fee_percent IS NULL
                  )
                  OR (
                      pm.fee_type IN ('FIXED','PERCENT_PLUS_FIXED')
                      AND pm.fee_fixed_amount IS NULL
                  )
              )
          )
      )

    UNION ALL

    SELECT
        'posted_sale_payment_base_total',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('sale_count',count(*))
    FROM posted_payment_summary
    WHERE (
        NOT is_tempo
        AND (
            payment_legs = 0
            OR payment_base_total <> grand_total_after_rounding
        )
    )
    OR (
        is_tempo
        AND payment_base_total > grand_total_after_rounding
    )

    UNION ALL

    SELECT
        'incomplete_posted_payment_snapshot',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.sales_payments sp
    JOIN public.sales_headers sh
      ON sh.company_id = sp.company_id
     AND sh.id = sp.sales_id
    WHERE sh.document_status = 'POSTED'
      AND NOT sp.is_reversal
      AND (
          sp.payment_method_id IS NULL
          OR NULLIF(btrim(sp.payment_method_code_snapshot),'') IS NULL
          OR NULLIF(btrim(sp.payment_method_name_snapshot),'') IS NULL
          OR NULLIF(btrim(sp.payment_method_type_snapshot),'') IS NULL
          OR NULLIF(btrim(sp.settlement_route_snapshot),'') IS NULL
          OR sp.configured_fee_amount < 0
          OR sp.customer_surcharge_amount < 0
          OR sp.amount <= 0
      )

    UNION ALL

    SELECT
        'duplicate_method_in_posted_sale',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object('sale_count',count(*))
    FROM (
        SELECT sp.company_id,sp.sales_id,sp.payment_method_id
        FROM public.sales_payments sp
        JOIN public.sales_headers sh
          ON sh.company_id = sp.company_id
         AND sh.id = sp.sales_id
        WHERE sh.document_status = 'POSTED'
          AND NOT sp.is_reversal
          AND sp.payment_method_id IS NOT NULL
        GROUP BY sp.company_id,sp.sales_id,sp.payment_method_id
        HAVING count(*) > 1
    ) duplicate_methods

    UNION ALL

    SELECT
        'invalid_payment_tender_change_snapshot',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.sales_payments sp
    JOIN public.sales_headers sh
      ON sh.company_id = sp.company_id
     AND sh.id = sp.sales_id
    WHERE sh.document_status = 'POSTED'
      AND NOT sp.is_reversal
      AND (
          sp.tendered_amount IS NULL
          OR sp.tendered_amount < sp.amount
          OR sp.change_amount <> sp.tendered_amount - sp.amount
          OR (
              sp.payment_method_type_snapshot <> 'CASH'
              AND sp.change_amount <> 0
          )
      )

    UNION ALL

    SELECT
        'payment_leg_identity_schema_state',
        CASE WHEN EXISTS (
                SELECT 1
                FROM information_schema.columns c
                WHERE c.table_schema = 'public'
                  AND c.table_name = 'sales_payments'
                  AND c.column_name = 'client_payment_key'
             )
             AND COALESCE(bool_or(
                 p.prosrc LIKE '%clientPaymentKey%'
             ),FALSE)
             THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object(
            'client_payment_key_exists',EXISTS (
                SELECT 1
                FROM information_schema.columns c
                WHERE c.table_schema = 'public'
                  AND c.table_name = 'sales_payments'
                  AND c.column_name = 'client_payment_key'
            ),
            'payload_payment_key_guarded',
                COALESCE(bool_or(
                    p.prosrc LIKE '%clientPaymentKey%'
                ),FALSE)
        )
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'private'
      AND p.proname = 'post_pos_sale_core'

    UNION ALL

    SELECT
        'direct_sales_payment_write_privilege',
        'INFO',
        jsonb_build_object(
            'authenticated_insert',has_table_privilege(
                'authenticated','public.sales_payments','INSERT'
            ),
            'authenticated_update',has_table_privilege(
                'authenticated','public.sales_payments','UPDATE'
            ),
            'authenticated_delete',has_table_privilege(
                'authenticated','public.sales_payments','DELETE'
            )
        )

    UNION ALL

    SELECT
        'split_payment_runtime_inventory',
        'INFO',
        jsonb_build_object(
            'posted_sales',(SELECT count(*) FROM posted_payment_summary),
            'posted_sales_with_multiple_legs',(
                SELECT count(*) FROM posted_payment_summary
                WHERE payment_legs > 1
            ),
            'payment_rows',(SELECT count(*) FROM public.sales_payments),
            'active_payment_methods',(
                SELECT count(*) FROM public.payment_methods
                WHERE is_active
            ),
            'active_stores',(SELECT count(*) FROM eligible_store_methods)
        )
)
SELECT check_name,status,details
FROM checks
ORDER BY
    CASE status
        WHEN 'BLOCKER' THEN 1
        WHEN 'REVIEW' THEN 2
        WHEN 'BACKFILL' THEN 3
        WHEN 'SETUP' THEN 4
        WHEN 'PASS' THEN 5
        ELSE 6
    END,
    check_name;
