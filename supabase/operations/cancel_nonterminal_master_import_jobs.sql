-- Controlled operation: close abandoned, non-processing Master Import jobs.
--
-- Run from Supabase SQL Editor with the database-owner role before a migration
-- that changes the Master Import contract. This operation preserves jobs, rows,
-- and audit history; it only moves idle nonterminal jobs to CANCELED.

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '30s';

LOCK TABLE public.master_import_jobs IN SHARE ROW EXCLUSIVE MODE;

DO $guard$
DECLARE
  v_processing JSONB;
BEGIN
  SELECT jsonb_agg(jsonb_build_object(
    'jobId',job.id,
    'companyId',job.company_id,
    'importType',job.import_type,
    'fileName',job.file_name,
    'updatedAt',job.updated_at
  ) ORDER BY job.updated_at)
  INTO v_processing
  FROM public.master_import_jobs job
  WHERE job.status='PROCESSING';

  IF v_processing IS NOT NULL THEN
    RAISE EXCEPTION
      'ACTIVE_IMPORT_PROCESSING: do not cancel automatically; jobs=%',
      v_processing;
  END IF;
END
$guard$;

DO $cancel$
DECLARE
  v_job public.master_import_jobs%ROWTYPE;
BEGIN
  FOR v_job IN
    SELECT job.*
    FROM public.master_import_jobs job
    WHERE job.status IN ('UPLOADED','MAPPED','VALIDATED','READY')
    ORDER BY job.created_at,job.id
    FOR UPDATE
  LOOP
    UPDATE public.master_import_jobs
    SET
      status='CANCELED',
      master_version=v_job.master_version+1,
      updated_at=clock_timestamp()
    WHERE id=v_job.id
      AND company_id=v_job.company_id
      AND status=v_job.status
      AND master_version=v_job.master_version;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'IMPORT_JOB_CHANGED_DURING_CLOSURE: %',v_job.id;
    END IF;

    INSERT INTO public.master_import_job_events(
      company_id,job_id,event_type,actor_id,before_state,after_state
    ) VALUES (
      v_job.company_id,
      v_job.id,
      'CANCEL',
      v_job.uploaded_by,
      jsonb_build_object(
        'status',v_job.status,
        'masterVersion',v_job.master_version,
        'totalRows',v_job.total_rows,
        'createdRows',v_job.created_rows,
        'updatedRows',v_job.updated_rows,
        'skippedRows',v_job.skipped_rows,
        'errorRows',v_job.error_rows
      ),
      jsonb_build_object(
        'status','CANCELED',
        'masterVersion',v_job.master_version+1,
        'reason','PRE_MIGRATION_NONTERMINAL_JOB_CLOSURE'
      )
    );

    RAISE NOTICE 'Canceled import job % (% / %, previous status %)',
      v_job.id,v_job.import_type,v_job.file_name,v_job.status;
  END LOOP;
END
$cancel$;

SELECT
  count(*) AS remaining_nonterminal_jobs,
  COALESCE(jsonb_agg(jsonb_build_object(
    'jobId',job.id,
    'importType',job.import_type,
    'fileName',job.file_name,
    'status',job.status
  ) ORDER BY job.updated_at),'[]'::JSONB) AS remaining_jobs
FROM public.master_import_jobs job
WHERE job.status NOT IN (
  'COMPLETED','COMPLETED_WITH_ERRORS','FAILED','CANCELED'
);

COMMIT;
