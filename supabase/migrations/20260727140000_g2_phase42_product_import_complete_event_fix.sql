-- KGS POS G2 phase 42 forward fix: canonical Product import completion event.
--
-- The Phase-42 Product commit wrote event_type COMMIT while the canonical
-- master_import_job_events vocabulary uses COMPLETE. The original behavioral
-- test rolled back every fixture/write. This forward fix changes only that
-- audit literal; public signatures, validation, commit semantics, and data are
-- otherwise unchanged.

BEGIN;

DO $migration_guard$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260727130000'
    ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: phase 42 migration is required';
    END IF;
    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260727140000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260727140000';
    END IF;
END
$migration_guard$;

DO $replace_completion_event$
DECLARE
    v_oid OID := to_regprocedure(
        'private.commit_master_import_product_job(uuid,bigint,integer)'
    );
    v_definition TEXT;
    v_old TEXT := 'v_company,p_job_id,''COMMIT'',v_actor,';
    v_new TEXT := 'v_company,p_job_id,''COMPLETE'',v_actor,';
BEGIN
    IF v_oid IS NULL THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: Product import commit missing';
    END IF;

    SELECT pg_get_functiondef(v_oid) INTO v_definition;
    IF strpos(v_definition,v_old) = 0 THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: completion event contract changed';
    END IF;
    IF (
        length(v_definition) - length(replace(v_definition,v_old,''))
    ) / length(v_old) <> 1 THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: completion event is ambiguous';
    END IF;

    EXECUTE replace(v_definition,v_old,v_new);
END
$replace_completion_event$;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES (
    '20260727140000',
    'g2_phase42_product_import_complete_event_fix',
    'Forward-only COMMIT to canonical COMPLETE master import audit event correction'
);

COMMIT;
