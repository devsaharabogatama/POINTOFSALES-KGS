-- G4 phase 26 Return-batch lineage forward-fix postflight.
-- SELECT-only.

WITH checks AS (
    SELECT 'migration_ledger'::TEXT check_name,
        CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
        count(*)::BIGINT violation_rows,
        jsonb_build_object('ledger_rows',count(*)) details
    FROM private.kgs_schema_migrations
    WHERE version='20260803020000'

    UNION ALL
    SELECT 'return_lineage_constraint',
        CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN count(*)=1 THEN 0 ELSE 1 END,
        jsonb_build_object('constraint_rows',count(*))
    FROM pg_constraint
    WHERE conrelid='public.product_batches'::regclass
      AND conname='product_batches_source_lineage_check'
      AND contype='c'

    UNION ALL
    SELECT 'legacy_transfer_lineage_constraint_removed',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('legacy_constraint_rows',count(*))
    FROM pg_constraint
    WHERE conrelid='public.product_batches'::regclass
      AND conname='product_batches_transfer_lineage_check'

    UNION ALL
    SELECT 'invalid_product_batch_source_lineage',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('row_count',count(*))
    FROM public.product_batches batch
    WHERE NOT (
        (batch.stock_transfer_line_id IS NULL
         AND batch.sales_return_line_id IS NULL
         AND batch.source_batch_id IS NULL)
        OR
        (batch.stock_transfer_line_id IS NOT NULL
         AND batch.sales_return_line_id IS NULL
         AND batch.source_batch_id IS NOT NULL)
        OR
        (batch.stock_transfer_line_id IS NULL
         AND batch.sales_return_line_id IS NOT NULL
         AND batch.source_batch_id IS NOT NULL)
    )

    UNION ALL
    SELECT 'return_lineage_index',
        CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN count(*)=1 THEN 0 ELSE 1 END,
        jsonb_build_object('index_rows',count(*))
    FROM pg_indexes
    WHERE schemaname='public' AND tablename='product_batches'
      AND indexname='idx_product_batches_company_sales_return_line'
)
SELECT check_name,status,violation_rows,details
FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 ELSE 2 END,check_name;
