-- SELECT-only postflight: Product-UOM partial validation restore.
WITH resolved AS (
  SELECT routine.oid,COALESCE(lower(routine.prosrc),'') definition
  FROM (SELECT to_regprocedure(
    'public.validate_master_import_job(uuid,bigint)') signature) target
  LEFT JOIN pg_proc routine ON routine.oid=target.signature
), checks AS (
  SELECT 'product_uom_partial_validation_dispatch' check_name,
    CASE WHEN oid IS NOT NULL
      AND definition LIKE '%private.validate_product_uom_import_job%'
      AND definition NOT LIKE '%auto_validation_failed%'
      AND definition NOT LIKE '%cancel_master_import_job_core%'
      THEN 'PASS' ELSE 'FAIL' END status,
    jsonb_build_object('routineRows',CASE WHEN oid IS NULL THEN 0 ELSE 1 END) details
  FROM resolved
  UNION ALL
  SELECT 'manual_and_stale_cancel_preserved',
    CASE WHEN to_regprocedure(
      'public.cancel_master_import_job(uuid,bigint,text)') IS NOT NULL
      AND to_regprocedure(
      'public.cleanup_stale_master_import_jobs()') IS NOT NULL
      THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('expected',2,'routineRows',
      (CASE WHEN to_regprocedure(
        'public.cancel_master_import_job(uuid,bigint,text)') IS NULL THEN 0 ELSE 1 END)+
      (CASE WHEN to_regprocedure(
        'public.cleanup_stale_master_import_jobs()') IS NULL THEN 0 ELSE 1 END))
  UNION ALL
  SELECT 'migration_ledger',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('ledgerRows',count(*))
  FROM private.kgs_schema_migrations WHERE version='20260821110000'
), inventory AS (
  SELECT 'product_uom_canceled_job_inventory' check_name,'INFO' status,
    jsonb_build_object('canceledJobs',count(*)) details
  FROM public.master_import_jobs
  WHERE import_type='PRODUCT_UOM' AND status='CANCELED'
)
SELECT check_name,status,details FROM (
  SELECT * FROM checks UNION ALL SELECT * FROM inventory
) result ORDER BY CASE status WHEN 'FAIL' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,
  check_name;
