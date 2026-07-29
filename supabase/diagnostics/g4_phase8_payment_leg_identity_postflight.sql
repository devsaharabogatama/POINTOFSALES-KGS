-- G4 phase 8 postflight: payment-leg identity and validation.
-- SAFETY: SELECT-only.

WITH checks AS (
    SELECT
        'migration_ledger'::text AS check_name,
        CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'FAIL' END AS status,
        count(*)::BIGINT AS violation_rows,
        jsonb_build_object('ledger_rows',count(*)) AS details
    FROM private.kgs_schema_migrations
    WHERE version = '20260729150000'

    UNION ALL

    SELECT
        'payment_leg_identity_column',
        CASE WHEN count(*) = 1
                  AND bool_and(c.is_nullable = 'NO')
                  AND bool_and(c.column_default IS NOT NULL)
             THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN count(*) = 1
                  AND bool_and(c.is_nullable = 'NO')
                  AND bool_and(c.column_default IS NOT NULL)
             THEN 0 ELSE 1 END,
        jsonb_build_object(
            'column_rows',count(*),
            'not_null',COALESCE(bool_and(c.is_nullable = 'NO'),FALSE),
            'has_default',COALESCE(
                bool_and(c.column_default IS NOT NULL),FALSE
            )
        )
    FROM information_schema.columns c
    WHERE c.table_schema = 'public'
      AND c.table_name = 'sales_payments'
      AND c.column_name = 'client_payment_key'

    UNION ALL

    SELECT
        'payment_leg_identity_unique_index',
        CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN count(*) = 1 THEN 0 ELSE 1 END,
        jsonb_build_object('index_rows',count(*))
    FROM pg_indexes i
    WHERE i.schemaname = 'public'
      AND i.tablename = 'sales_payments'
      AND i.indexname =
          'uq_sales_payments_company_sale_client_key'

    UNION ALL

    SELECT
        'payment_payload_normalization_trigger',
        CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN count(*) = 1 THEN 0 ELSE 1 END,
        jsonb_build_object('trigger_rows',count(*))
    FROM pg_trigger t
    JOIN pg_class c ON c.oid = t.tgrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname = 'sales_headers'
      AND t.tgname = 'g4_normalize_sale_payment_legs'
      AND NOT t.tgisinternal

    UNION ALL

    SELECT
        'required_payment_leg_routines',
        CASE WHEN count(*) = 2 THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN count(*) = 2 THEN 0 ELSE 1 END,
        jsonb_build_object('routine_rows',count(*))
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE (
        n.nspname = 'private'
        AND p.proname = 'trg_g4_normalize_sale_payment_legs'
    ) OR (
        n.nspname = 'public'
        AND p.proname = 'post_pos_sale'
        AND pg_get_function_identity_arguments(p.oid) =
            'p_sales_id uuid, p_master_version bigint, p_posting_idempotency_key uuid'
    )

    UNION ALL

    SELECT
        'draft_payment_leg_identity',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),
        jsonb_build_object('draft_count',count(*))
    FROM public.sales_headers sh
    WHERE sh.document_status = 'DRAFT'
      AND EXISTS (
          SELECT 1
          FROM jsonb_array_elements(
              CASE
                  WHEN jsonb_typeof(sh.payload_snapshot->'payments') = 'array'
                      THEN sh.payload_snapshot->'payments'
                  ELSE '[]'::JSONB
              END
          ) payment
          WHERE NULLIF(payment->>'clientPaymentKey','') IS NULL
      )

    UNION ALL

    SELECT
        'duplicate_draft_payment_leg_key_or_method',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),
        jsonb_build_object('duplicate_groups',count(*))
    FROM (
        SELECT
            sh.company_id,sh.id,
            payment->>'clientPaymentKey' AS identity,
            'KEY'::TEXT AS identity_type
        FROM public.sales_headers sh
        CROSS JOIN LATERAL jsonb_array_elements(
            CASE
                WHEN jsonb_typeof(sh.payload_snapshot->'payments') = 'array'
                    THEN sh.payload_snapshot->'payments'
                ELSE '[]'::JSONB
            END
        ) payment
        WHERE sh.document_status = 'DRAFT'
        GROUP BY sh.company_id,sh.id,payment->>'clientPaymentKey'
        HAVING count(*) > 1

        UNION ALL

        SELECT
            sh.company_id,sh.id,
            payment->>'paymentMethodId',
            'METHOD'
        FROM public.sales_headers sh
        CROSS JOIN LATERAL jsonb_array_elements(
            CASE
                WHEN jsonb_typeof(sh.payload_snapshot->'payments') = 'array'
                    THEN sh.payload_snapshot->'payments'
                ELSE '[]'::JSONB
            END
        ) payment
        WHERE sh.document_status = 'DRAFT'
        GROUP BY sh.company_id,sh.id,payment->>'paymentMethodId'
        HAVING count(*) > 1
    ) duplicate_groups

    UNION ALL

    SELECT
        'posted_payment_leg_identity',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),
        jsonb_build_object('row_count',count(*))
    FROM public.sales_payments
    WHERE client_payment_key IS NULL

    UNION ALL

    SELECT
        'posted_receipt_payment_leg_traceability',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),
        jsonb_build_object('sale_count',count(*))
    FROM public.sales_headers sh
    WHERE sh.document_status = 'POSTED'
      AND sh.receipt_snapshot IS NOT NULL
      AND (
          jsonb_typeof(sh.receipt_snapshot->'payments') <> 'array'
          OR jsonb_array_length(
              CASE
                  WHEN jsonb_typeof(
                      sh.receipt_snapshot->'payments'
                  ) = 'array'
                      THEN sh.receipt_snapshot->'payments'
                  ELSE '[]'::JSONB
              END
          ) <> (
              SELECT count(*)
              FROM public.sales_payments sp
              WHERE sp.company_id = sh.company_id
                AND sp.sales_id = sh.id
                AND NOT sp.is_reversal
          )
          OR EXISTS (
              SELECT 1
              FROM jsonb_array_elements(
                  CASE
                      WHEN jsonb_typeof(
                          sh.receipt_snapshot->'payments'
                      ) = 'array'
                          THEN sh.receipt_snapshot->'payments'
                      ELSE '[]'::JSONB
                  END
              ) payment
              WHERE NULLIF(payment->>'clientPaymentKey','') IS NULL
          )
      )

    UNION ALL

    SELECT
        'browser_sales_payment_write_boundary',
        CASE WHEN NOT has_table_privilege(
                        'authenticated','public.sales_payments',
                        'INSERT,UPDATE,DELETE'
                   )
             THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN has_table_privilege(
                       'authenticated','public.sales_payments',
                       'INSERT,UPDATE,DELETE'
                  )
             THEN 1 ELSE 0 END,
        jsonb_build_object(
            'direct_write',has_table_privilege(
                'authenticated','public.sales_payments',
                'INSERT,UPDATE,DELETE'
            )
        )
)
SELECT check_name,status,violation_rows,details
FROM checks
ORDER BY
    CASE status WHEN 'FAIL' THEN 1 ELSE 2 END,
    check_name;
