-- Allow signed system snapshots in Stock Opname while physical count remains
-- nonnegative. Negative stock is a valid operational state; physical quantity
-- entered by a counter is never allowed to be negative.

BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260902100000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: POS Stock Opname workspace required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260902110000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM pg_constraint
    WHERE conrelid='public.stock_opname_details'::regclass
      AND conname='stock_opname_details_quantity_nonnegative') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: legacy Opname quantity constraint missing';
  END IF;
  IF EXISTS(SELECT 1 FROM public.stock_opname_details
    WHERE physical_qty<0) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: negative physical Opname quantity';
  END IF;
END
$guard$;

ALTER TABLE public.stock_opname_details
  DROP CONSTRAINT stock_opname_details_quantity_nonnegative;

ALTER TABLE public.stock_opname_details
  ADD CONSTRAINT stock_opname_details_physical_qty_nonnegative
  CHECK(physical_qty>=0);

COMMENT ON CONSTRAINT stock_opname_details_physical_qty_nonnegative
ON public.stock_opname_details IS
  'Physical blind count is nonnegative; system and expected snapshots are signed to support authorized negative stock.';

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260902110000','stock_opname_negative_stock_compatibility',
  'Allowed signed system and expected Stock Opname snapshots while retaining nonnegative physical blind count');

NOTIFY pgrst,'reload schema';
COMMIT;
