-- Additive NULL representation fix. No data mutation/backfill.
BEGIN;
DO $guard$
DECLARE v_definition text;v_old text;
BEGIN
 IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260915142000')
 OR EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260916100000')
 THEN RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: absent-request fix ledger'; END IF;
 v_definition:=pg_get_functiondef('private.convert_retail_sale_to_backoffice_order(uuid,uuid,uuid,uuid)'::regprocedure);
 FOREACH v_old IN ARRAY ARRAY['to_jsonb(request_line)','to_jsonb(request_document)'] LOOP
  IF position('IS DISTINCT FROM '||v_old IN v_definition)=0 THEN
   RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: preservation NULL marker drift'; END IF;
  v_definition:=replace(v_definition,'IS DISTINCT FROM '||v_old,
   'IS DISTINCT FROM COALESCE('||v_old||',''null''::jsonb)');
 END LOOP;
 EXECUTE v_definition;
END $guard$;
INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260916100000','cutover_absent_request_snapshot_fix',
 'Represent absent request LEFT JOIN rows as JSON null; preserve whole-row comparisons. No backfill.');
NOTIFY pgrst,'reload schema';
COMMIT;
