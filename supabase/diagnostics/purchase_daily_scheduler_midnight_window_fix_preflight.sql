-- SELECT-only preflight for the Purchase scheduler midnight-window forward fix.
WITH state AS (
  SELECT
    EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260914140000') base_applied,
    EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260914141000') fix_applied,
    to_regprocedure(
      'private.run_purchase_daily_replenishment_scheduler(timestamptz)') scheduler,
    (SELECT count(*) FROM cron.job
      WHERE jobname='kgs-purchase-daily-replenishment') cron_jobs
), checks AS (
  SELECT 'midnight_window_base_migration' check_name,
    CASE WHEN base_applied THEN 'PASS' ELSE 'BLOCKER' END status,
    CASE WHEN base_applied THEN 0 ELSE 1 END violation_rows,
    jsonb_build_object('requiredVersion','20260914140000','present',base_applied) details
  FROM state
  UNION ALL
  SELECT 'midnight_window_forward_fix_collision',
    CASE WHEN NOT fix_applied THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN NOT fix_applied THEN 0 ELSE 1 END,
    jsonb_build_object('migrationApplied',fix_applied,'forwardFixVersion','20260914141000')
  FROM state
  UNION ALL
  SELECT 'midnight_window_scheduler_runtime',
    CASE WHEN scheduler IS NOT NULL AND cron_jobs=1 THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN scheduler IS NULL THEN 1 ELSE 0 END+abs(1-cron_jobs),
    jsonb_build_object('schedulerExists',scheduler IS NOT NULL,'cronJobs',cron_jobs)
  FROM state
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 0 ELSE 1 END,check_name;

