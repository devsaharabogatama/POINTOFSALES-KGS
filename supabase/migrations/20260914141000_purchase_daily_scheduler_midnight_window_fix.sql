-- Forward fix: compare a full Company-local timestamp across the 23:59-00:00 boundary.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260914140000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Purchase scheduler runtime required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260914141000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED';
  END IF;
  IF to_regprocedure(
      'private.run_purchase_daily_replenishment_scheduler(timestamptz)') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Purchase scheduler routine missing';
  END IF;
  IF (SELECT count(*) FROM cron.job
      WHERE jobname='kgs-purchase-daily-replenishment')<>1 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical Purchase scheduler job missing or ambiguous';
  END IF;
END
$guard$;

CREATE OR REPLACE FUNCTION private.run_purchase_daily_replenishment_scheduler(
  p_effective_at timestamptz DEFAULT clock_timestamp()
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_row record;v_prior public.purchase_daily_scheduler_runs%rowtype;
  v_date date;v_operation uuid;v_result jsonb;
  v_status text;v_generated integer:=0;v_no_demand integer:=0;v_failed integer:=0;
  v_error text;
BEGIN
  FOR v_row IN SELECT setting.*,company.timezone
    FROM public.company_purchase_replenishment_settings setting
    JOIN public.companies company ON company.id=setting.company_id AND company.status='ACTIVE'
    WHERE setting.replenishment_mode IN('AUTO_RO','AUTO_PO')
      AND setting.updated_by IS NOT NULL
      -- Compare full local timestamps. A time-only upper bound wraps 23:59 + 1 minute
      -- to 00:00 and incorrectly excludes every execution inside the cutoff minute.
      AND (p_effective_at AT TIME ZONE company.timezone)>=
        ((p_effective_at AT TIME ZONE company.timezone)::date+setting.cutoff_local_time)
      AND (p_effective_at AT TIME ZONE company.timezone)<
        ((p_effective_at AT TIME ZONE company.timezone)::date+setting.cutoff_local_time+
          interval '1 minute')
    ORDER BY setting.company_id
  LOOP
    v_date:=(p_effective_at AT TIME ZONE v_row.timezone)::date;
    SELECT * INTO v_prior FROM public.purchase_daily_scheduler_runs run
    WHERE run.company_id=v_row.company_id AND run.business_date=v_date FOR UPDATE;
    IF FOUND AND v_prior.status IN('GENERATED','NO_DEMAND') THEN
      UPDATE public.purchase_daily_scheduler_runs SET attempt_count=attempt_count+1,
        last_attempted_at=clock_timestamp()
      WHERE company_id=v_row.company_id AND business_date=v_date;
      INSERT INTO public.purchase_daily_scheduler_attempts(company_id,business_date,
        effective_at,mode_snapshot,technical_sponsor_id,operation_id,status,result_snapshot)
      VALUES(v_row.company_id,v_date,p_effective_at,v_prior.mode_snapshot,
        v_prior.technical_sponsor_id,v_prior.operation_id,'REUSED',v_prior.result_snapshot);
      IF v_prior.status='NO_DEMAND' THEN v_no_demand:=v_no_demand+1;
      ELSE v_generated:=v_generated+1; END IF;
      CONTINUE;
    END IF;
    v_operation:=md5('PURCHASE_DAILY_SCHEDULER|'||v_row.company_id||'|'||v_date||'|'||
      v_row.replenishment_mode)::uuid;
    BEGIN
      IF v_row.replenishment_mode='AUTO_RO' THEN
        v_result:=private.generate_purchase_daily_auto_ro_core(v_row.company_id,v_date,
          v_row.updated_by,v_operation,p_effective_at);
      ELSE
        v_result:=private.generate_purchase_daily_auto_po_core(v_row.company_id,v_date,
          v_row.updated_by,v_operation,p_effective_at);
      END IF;
      v_status:=CASE WHEN COALESCE((v_result->>'noDemand')::boolean,false)
        THEN 'NO_DEMAND' ELSE 'GENERATED' END;
      INSERT INTO public.purchase_daily_scheduler_runs(company_id,business_date,
        mode_snapshot,technical_sponsor_id,operation_id,status,result_snapshot)
      VALUES(v_row.company_id,v_date,v_row.replenishment_mode,v_row.updated_by,
        v_operation,v_status,v_result)
      ON CONFLICT(company_id,business_date) DO UPDATE SET
        attempt_count=purchase_daily_scheduler_runs.attempt_count+1,
        mode_snapshot=excluded.mode_snapshot,
        technical_sponsor_id=excluded.technical_sponsor_id,
        operation_id=excluded.operation_id,
        status=excluded.status,result_snapshot=excluded.result_snapshot,error_code=NULL,
        last_attempted_at=clock_timestamp();
      INSERT INTO public.purchase_daily_scheduler_attempts(company_id,business_date,
        effective_at,mode_snapshot,technical_sponsor_id,operation_id,status,result_snapshot)
      VALUES(v_row.company_id,v_date,p_effective_at,v_row.replenishment_mode,
        v_row.updated_by,v_operation,v_status,v_result);
      IF v_status='NO_DEMAND' THEN v_no_demand:=v_no_demand+1;
      ELSE v_generated:=v_generated+1; END IF;
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_error=MESSAGE_TEXT;
      INSERT INTO public.purchase_daily_scheduler_runs(company_id,business_date,
        mode_snapshot,technical_sponsor_id,operation_id,status,error_code)
      VALUES(v_row.company_id,v_date,v_row.replenishment_mode,v_row.updated_by,
        v_operation,'FAILED',left(v_error,500))
      ON CONFLICT(company_id,business_date) DO UPDATE SET
        attempt_count=purchase_daily_scheduler_runs.attempt_count+1,
        mode_snapshot=excluded.mode_snapshot,
        technical_sponsor_id=excluded.technical_sponsor_id,
        operation_id=excluded.operation_id,status='FAILED',
        result_snapshot=NULL,error_code=excluded.error_code,
        last_attempted_at=clock_timestamp();
      INSERT INTO public.purchase_daily_scheduler_attempts(company_id,business_date,
        effective_at,mode_snapshot,technical_sponsor_id,operation_id,status,error_code)
      VALUES(v_row.company_id,v_date,p_effective_at,v_row.replenishment_mode,
        v_row.updated_by,v_operation,'FAILED',left(v_error,500));
      v_failed:=v_failed+1;
    END;
  END LOOP;
  RETURN jsonb_build_object('executionActor','SYSTEM_AUTOMATION',
    'actorDisplayName','Sistem Otomatis','generatedCompanies',v_generated,
    'noDemandCompanies',v_no_demand,'failedCompanies',v_failed,
    'effectiveAt',p_effective_at);
END
$$;

REVOKE ALL ON FUNCTION private.run_purchase_daily_replenishment_scheduler(timestamptz)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.run_purchase_daily_replenishment_scheduler(timestamptz)
TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260914141000','purchase_daily_scheduler_midnight_window_fix',
  'Forward-fixes the 23:59 scheduler selection window by comparing complete Company-local timestamps instead of a wrapping time-only upper bound');

COMMIT;

