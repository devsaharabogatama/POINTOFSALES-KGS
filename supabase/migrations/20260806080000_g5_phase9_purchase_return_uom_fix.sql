-- G5 phase 9 forward fix: Purchase Return may use any active Product-UOM.
-- Example: Goods Receipt 1 Dus (10 Ketul), return 3 Ketul.
BEGIN;

DO $guard$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260806070000'
    ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: Purchase Return foundation missing';
    END IF;
    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260806080000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260806080000';
    END IF;
END
$guard$;

-- Preserve the already-applied Phase-8 function body and change only the
-- accidental purchase_allowed restriction. Product ownership, active status,
-- precision, direct base conversion, source FIFO, and quantity guards remain.
DO $replace_contract$
DECLARE
    v_function REGPROCEDURE := to_regprocedure(
        'public.save_purchase_return_draft(uuid,bigint,uuid,uuid,uuid,date,text,text,text,jsonb)'
    );
    v_definition TEXT;
    v_occurrences INTEGER;
BEGIN
    IF v_function IS NULL THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: save_purchase_return_draft missing';
    END IF;
    SELECT pg_get_functiondef(v_function) INTO v_definition;
    v_occurrences := (
        length(v_definition)
        - length(replace(v_definition,'AND product_uom.purchase_allowed',''))
    ) / length('AND product_uom.purchase_allowed');
    IF v_occurrences <> 1 THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: return UOM guard changed; occurrences %',
            v_occurrences;
    END IF;
    v_definition := replace(
        v_definition,
        'AND product_uom.purchase_allowed',
        'AND TRUE /* all active Product-UOMs are valid return units */'
    );
    EXECUTE v_definition;
END
$replace_contract$;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES (
    '20260806080000',
    'g5_phase9_purchase_return_uom_fix',
    'Allows an active Product-UOM for Purchase Return quantity conversion even when the UOM is not purchase_allowed; all source FIFO, precision, tenant, and quantity guards remain unchanged'
);

COMMIT;
