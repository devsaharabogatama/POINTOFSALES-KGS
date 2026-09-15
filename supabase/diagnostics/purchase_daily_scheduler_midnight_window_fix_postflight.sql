-- SELECT-only postflight for the Purchase scheduler midnight-window forward fix.
WITH state AS (
  SELECT
    (SELECT count(*) FROM private.kgs_schema_migrations
      WHERE version='20260914141000') ledger_rows,
    pg_get_functiondef(to_regprocedure(
      'private.run_purchase_daily_replenishment_scheduler(timestamptz)')) body,
    (SELECT count(*) FROM cron.job
      WHERE jobname='kgs-purchase-daily-replenishment') cron_jobs
), checks AS (
  SELECT 'midnight_window_fix_migration_ledger' check_name,
    CASE WHEN ledger_rows=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(1-ledger_rows) violation_rows,
    jsonb_build_object('ledgerRows',ledger_rows) details FROM state
  UNION ALL
  SELECT 'midnight_window_timestamp_comparison_contract',
    CASE WHEN body ~ '::date[[:space:]]*\+[[:space:]]*setting.cutoff_local_time'
      AND (body ~ 'setting.cutoff_local_time[[:space:]]*\+[[:space:]]*interval[[:space:]]+''1 minute'''
        OR body ~ 'setting.cutoff_local_time[[:space:]]*\+[[:space:]]*''00:01:00''::interval')
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN body ~ '::date[[:space:]]*\+[[:space:]]*setting.cutoff_local_time'
      AND (body ~ 'setting.cutoff_local_time[[:space:]]*\+[[:space:]]*interval[[:space:]]+''1 minute'''
        OR body ~ 'setting.cutoff_local_time[[:space:]]*\+[[:space:]]*''00:01:00''::interval')
      THEN 0 ELSE 1 END,
    jsonb_build_object('usesCompanyLocalDate',
      body ~ '::date[[:space:]]*\+[[:space:]]*setting.cutoff_local_time',
      'usesOneMinuteTimestampWindow',
      body ~ 'setting.cutoff_local_time[[:space:]]*\+[[:space:]]*interval[[:space:]]+''1 minute'''
        OR body ~ 'setting.cutoff_local_time[[:space:]]*\+[[:space:]]*''00:01:00''::interval')
  FROM state
  UNION ALL
  SELECT 'midnight_window_cron_identity',
    CASE WHEN cron_jobs=1 THEN 'PASS' ELSE 'FAIL' END,abs(1-cron_jobs),
    jsonb_build_object('jobs',cron_jobs) FROM state
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 0 ELSE 1 END,check_name;
