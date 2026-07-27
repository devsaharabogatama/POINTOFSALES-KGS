-- KGS POS G2 phase 40 forward fix: COA parent UUID aggregate.
--
-- The Phase-40 migration was applied successfully, but its behavioral test
-- reached one PostgreSQL-incompatible expression: min(uuid). PostgreSQL has no
-- built-in min(UUID) aggregate. Preserve the applied migration and replace only
-- that validator expression with min(id::text)::uuid.

BEGIN;

DO $migration_guard$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260727090000'
    ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: phase 40 import migration required';
    END IF;
    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260727100000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260727100000';
    END IF;
END
$migration_guard$;

DO $validator_forward_fix$
DECLARE
    v_oid OID := to_regprocedure(
        'public.validate_master_import_job(uuid,bigint)'
    );
    v_definition TEXT;
    v_old_expression TEXT :=
        'SELECT min(x.id) INTO v_parent_id';
    v_new_expression TEXT :=
        'SELECT min(x.id::TEXT)::UUID INTO v_parent_id';
BEGIN
    IF v_oid IS NULL THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: phase 40 validator missing';
    END IF;
    SELECT pg_get_functiondef(v_oid) INTO v_definition;
    IF strpos(v_definition,v_old_expression) = 0 THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: COA parent lookup contract changed';
    END IF;
    IF strpos(v_definition,v_new_expression) > 0 THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: COA parent fix already present';
    END IF;
    EXECUTE replace(v_definition,v_old_expression,v_new_expression);
END
$validator_forward_fix$;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES (
    '20260727100000',
    'g2_phase40_coa_parent_uuid_aggregate_fix',
    'Forward-only replacement of unsupported min(uuid) in Phase-40 COA parent preview lookup with deterministic min(id::text)::uuid'
);

COMMIT;

-- If this transaction fails it rolls back completely. After apply, use another
-- forward fix; never edit either applied Phase-40 migration.
