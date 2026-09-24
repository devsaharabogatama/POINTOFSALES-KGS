-- Read-only preflight for 20260924100000. Stop on BLOCKER.
WITH dependency(version) AS (VALUES ('20260923110000')),
lsm AS (
  SELECT company.id,company.company_name,company.status
  FROM public.companies company
  WHERE company.id='07bdffb9-8c56-444c-a49b-81ac86745674'::uuid
), collision AS (
  SELECT 'settings.auto_ro_stock_match_enabled' name
  WHERE EXISTS(SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='company_purchase_replenishment_settings'
      AND column_name='auto_ro_stock_match_enabled')
  UNION ALL SELECT 'batches.stock_match_fingerprint'
  WHERE EXISTS(SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='purchase_daily_batches'
      AND column_name='stock_match_fingerprint')
  UNION ALL SELECT 'batches.stock_matched_at'
  WHERE EXISTS(SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='purchase_daily_batches'
      AND column_name='stock_matched_at')
  UNION ALL SELECT 'batches.stock_match_operation_id'
  WHERE EXISTS(SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='purchase_daily_batches'
      AND column_name='stock_match_operation_id')
  UNION ALL SELECT 'private preview core' WHERE to_regprocedure(
    'private.get_purchase_daily_auto_ro_stock_match_core(uuid,uuid)') IS NOT NULL
  UNION ALL SELECT 'private reconcile core' WHERE to_regprocedure(
    'private.reconcile_purchase_daily_auto_ro_stock_core(uuid,uuid,bigint,uuid,uuid,timestamptz)') IS NOT NULL
  UNION ALL SELECT 'public preview' WHERE to_regprocedure(
    'public.get_purchase_daily_auto_ro_stock_match(uuid)') IS NOT NULL
  UNION ALL SELECT 'public reconcile' WHERE to_regprocedure(
    'public.reconcile_purchase_daily_auto_ro_stock(uuid,bigint,uuid)') IS NOT NULL
  UNION ALL SELECT 'public matched confirm' WHERE to_regprocedure(
    'public.confirm_purchase_daily_auto_ro_matched(uuid,bigint,uuid,uuid,boolean,jsonb)') IS NOT NULL
), lsm_draft AS (
  SELECT batch.id,batch.batch_no,batch.business_date,batch.master_version,
    batch.requested_total_base_qty
  FROM public.purchase_daily_batches batch
  WHERE batch.company_id='07bdffb9-8c56-444c-a49b-81ac86745674'::uuid
    AND batch.mode_snapshot='AUTO_RO' AND batch.status='DRAFT'
)
SELECT 'auto_ro_stock_match_dependency_ledger' check_name,
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END status,
  count(*)::bigint violation_rows,
  jsonb_build_object('missing',coalesce(jsonb_agg(dependency.version)
    FILTER(WHERE migration.version IS NULL),'[]'::jsonb)) details
FROM dependency LEFT JOIN private.kgs_schema_migrations migration
  ON migration.version=dependency.version WHERE migration.version IS NULL
UNION ALL
SELECT 'auto_ro_stock_match_object_collision',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
  jsonb_build_object('existing',coalesce(jsonb_agg(name),'[]'::jsonb))
FROM collision
UNION ALL
SELECT 'auto_ro_stock_match_lsm_identity',
  CASE WHEN count(*)=1 AND min(company_name)='Latorti Sari Median'
      AND min(status)='ACTIVE' THEN 'PASS' ELSE 'BLOCKER' END,
  CASE WHEN count(*)=1 AND min(company_name)='Latorti Sari Median'
      AND min(status)='ACTIVE' THEN 0 ELSE 1 END::bigint,
  jsonb_build_object('rows',count(*),'companies',coalesce(jsonb_agg(to_jsonb(lsm)),'[]'::jsonb))
FROM lsm
UNION ALL
SELECT 'auto_ro_stock_match_lsm_policy_anchor',
  CASE WHEN count(*)=1 AND bool_and(replenishment_mode='AUTO_RO')
      AND bool_and(auto_ro_draft_roll_forward_enabled) THEN 'PASS' ELSE 'BLOCKER' END,
  CASE WHEN count(*)=1 AND bool_and(replenishment_mode='AUTO_RO')
      AND bool_and(auto_ro_draft_roll_forward_enabled) THEN 0 ELSE 1 END::bigint,
  jsonb_build_object('rows',count(*),'mode',min(replenishment_mode),
    'rollForwardEnabled',bool_and(auto_ro_draft_roll_forward_enabled))
FROM public.company_purchase_replenishment_settings
WHERE company_id='07bdffb9-8c56-444c-a49b-81ac86745674'::uuid
UNION ALL
SELECT 'auto_ro_stock_match_runtime_anchor',
  CASE WHEN count(*)=6 THEN 'PASS' ELSE 'BLOCKER' END,abs(count(*)-6)::bigint,
  jsonb_build_object('present',count(*),'expected',6)
FROM (VALUES
  (to_regprocedure('private.get_purchase_daily_replenishment_candidates_core(uuid,date)')),
  (to_regprocedure('private.purchase_uncovered_negative_qty(numeric,numeric)')),
  (to_regprocedure('private.purchase_daily_batch_snapshot(uuid,uuid)')),
  (to_regprocedure('private.confirm_purchase_daily_auto_ro_core(uuid,uuid,bigint,uuid,uuid,jsonb,timestamptz)')),
  (to_regprocedure('public.confirm_purchase_daily_auto_ro(uuid,bigint,uuid,jsonb)')),
  (to_regprocedure('private.trg_guard_purchase_daily_batch_line()'))
) routine(oid) WHERE oid IS NOT NULL
UNION ALL
SELECT 'auto_ro_stock_match_constraint_anchor',
  CASE WHEN count(*)=3 THEN 'PASS' ELSE 'BLOCKER' END,abs(count(*)-3)::bigint,
  jsonb_build_object('present',count(*),'expected',3)
FROM pg_constraint constraint_row
WHERE (constraint_row.conrelid,constraint_row.conname) IN (
  ('public.purchase_daily_batch_operations'::regclass,
    'purchase_daily_batch_operations_operation_type_check'),
  ('public.purchase_daily_batch_audit'::regclass,
    'purchase_daily_batch_audit_action_check'),
  ('public.company_purchase_replenishment_setting_audit'::regclass,
    'company_purchase_replenishment_setting_audit_action_check'))
UNION ALL
SELECT 'auto_ro_stock_match_active_finance_queue',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
  jsonb_build_object('rows',count(*))
FROM public.finance_posting_queue_runs run
WHERE run.status IN('PREVIEWED','APPROVED','PROCESSING')
UNION ALL
SELECT 'auto_ro_stock_match_lsm_draft_inventory','INFO',0,
  jsonb_build_object('rows',count(*),
    'quantity',coalesce(sum(requested_total_base_qty),0),
    'drafts',coalesce(jsonb_agg(to_jsonb(lsm_draft)
      ORDER BY business_date,batch_no),'[]'::jsonb))
FROM lsm_draft;
