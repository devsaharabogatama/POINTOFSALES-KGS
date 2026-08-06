-- G4 phase 26 forward fix: allow original FIFO lineage for Return batches.
-- The legacy source_batch_id was constrained to Transfer batches only.

BEGIN;

DO $migration_guard$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version='20260803010000'
    ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: Sales Return foundation missing';
    END IF;
    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version='20260803020000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260803020000';
    END IF;
END
$migration_guard$;

ALTER TABLE public.product_batches
    DROP CONSTRAINT product_batches_transfer_lineage_check,
    ADD CONSTRAINT product_batches_source_lineage_check CHECK (
        (
            stock_transfer_line_id IS NULL
            AND sales_return_line_id IS NULL
            AND source_batch_id IS NULL
        )
        OR
        (
            stock_transfer_line_id IS NOT NULL
            AND sales_return_line_id IS NULL
            AND source_batch_id IS NOT NULL
        )
        OR
        (
            stock_transfer_line_id IS NULL
            AND sales_return_line_id IS NOT NULL
            AND source_batch_id IS NOT NULL
        )
    );

CREATE INDEX idx_product_batches_company_sales_return_line
    ON public.product_batches(company_id,sales_return_line_id)
    WHERE sales_return_line_id IS NOT NULL;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES (
    '20260803020000','g4_phase26_sales_return_batch_lineage_fix',
    'Forward fix permits mutually-exclusive Transfer or Sales Return source-batch lineage without weakening ordinary FIFO batch shape'
);

COMMIT;
