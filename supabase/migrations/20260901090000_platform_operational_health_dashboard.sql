-- Super Admin global operational-health read model.
-- This migration adds one read-only RPC. It installs no transaction trigger,
-- performs no business-data backfill, and exposes no mutation or auto-fix.

BEGIN;

SET LOCAL lock_timeout='2s';
SET LOCAL statement_timeout='20s';

DO $guard$
DECLARE v_missing TEXT[];
BEGIN
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260901090000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260901090000';
  END IF;
  IF to_regprocedure('public.get_platform_operational_health()') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: platform health RPC exists';
  END IF;
  SELECT array_agg(required.version ORDER BY required.version) INTO v_missing
  FROM (VALUES('20260810210000'),('20260828100000'),('20260828120000'),
    ('20260828150000'),('20260828240000'),('20260831120000')) required(version)
  WHERE NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations migration
    WHERE migration.version=required.version);
  IF cardinality(COALESCE(v_missing,ARRAY[]::TEXT[]))>0 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: dependencies missing %',
      v_missing;
  END IF;
END
$guard$;

CREATE FUNCTION public.get_platform_operational_health()
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path=public,pg_temp
SET statement_timeout TO '8s'
AS $function$
DECLARE v_now TIMESTAMPTZ:=statement_timestamp();
  v_schema_version TEXT;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF NOT public.private_is_super_admin(auth.uid()) THEN
    RAISE EXCEPTION 'SUPER_ADMIN_REQUIRED';
  END IF;

  SELECT max(migration.version) INTO v_schema_version
  FROM private.kgs_schema_migrations migration;

  RETURN (
    WITH company_health AS (
      SELECT company.id company_id,company.company_code,company.company_name,
        company.status company_status,
        (SELECT count(*) FROM public.cashier_sessions session
          WHERE session.company_id=company.id AND session.status='OPEN')
          open_cashier_sessions,
        (SELECT count(*) FROM public.cashier_sessions session
          WHERE session.company_id=company.id AND session.status='OPEN'
            AND session.opened_at<v_now-INTERVAL '18 hours')
          stale_cashier_sessions,
        (SELECT min(session.opened_at) FROM public.cashier_sessions session
          WHERE session.company_id=company.id AND session.status='OPEN'
            AND session.opened_at<v_now-INTERVAL '18 hours')
          oldest_stale_session_at,
        (SELECT count(*) FROM public.finance_posting_queue_runs queue_run
          WHERE queue_run.company_id=company.id
            AND queue_run.status IN('PREVIEWED','APPROVED','PROCESSING'))
          active_finance_queues,
        (SELECT count(*) FROM public.finance_posting_queue_runs queue_run
          WHERE queue_run.company_id=company.id
            AND queue_run.status IN('PREVIEWED','APPROVED','PROCESSING')
            AND queue_run.updated_at<v_now-INTERVAL '30 minutes')
          stale_finance_queues,
        (SELECT min(queue_run.updated_at)
          FROM public.finance_posting_queue_runs queue_run
          WHERE queue_run.company_id=company.id
            AND queue_run.status IN('PREVIEWED','APPROVED','PROCESSING')
            AND queue_run.updated_at<v_now-INTERVAL '30 minutes')
          oldest_stale_finance_queue_at,
        (SELECT count(*) FROM public.finance_posting_exceptions exception_state
          WHERE exception_state.company_id=company.id
            AND exception_state.status<>'RESOLVED') open_finance_exceptions,
        (SELECT min(exception_state.created_at)
          FROM public.finance_posting_exceptions exception_state
          WHERE exception_state.company_id=company.id
            AND exception_state.status<>'RESOLVED') oldest_finance_exception_at,
        (SELECT count(*) FROM public.financial_events event_state
          WHERE event_state.company_id=company.id AND event_state.status='HOLD')
          hold_financial_events,
        (SELECT count(*) FROM public.master_import_jobs import_job
          WHERE import_job.company_id=company.id
            AND import_job.status IN('UPLOADED','MAPPED','VALIDATED','READY','PROCESSING')
            AND import_job.updated_at<v_now-INTERVAL '30 minutes') stuck_import_jobs,
        (SELECT min(import_job.updated_at) FROM public.master_import_jobs import_job
          WHERE import_job.company_id=company.id
            AND import_job.status IN('UPLOADED','MAPPED','VALIDATED','READY','PROCESSING')
            AND import_job.updated_at<v_now-INTERVAL '30 minutes')
          oldest_stuck_import_at,
        (SELECT count(*) FROM public.master_import_jobs import_job
          WHERE import_job.company_id=company.id
            AND import_job.status IN('FAILED','COMPLETED_WITH_ERRORS')
            AND import_job.updated_at>=v_now-INTERVAL '7 days')
          recent_import_failures,
        (SELECT count(*) FROM public.pos_offline_sale_submissions submission
          WHERE submission.company_id=company.id
            AND submission.status IN('QUEUED','SYNCING')
            AND submission.updated_at<v_now-INTERVAL '15 minutes')
          stuck_offline_submissions,
        (SELECT min(submission.updated_at)
          FROM public.pos_offline_sale_submissions submission
          WHERE submission.company_id=company.id
            AND submission.status IN('QUEUED','SYNCING')
            AND submission.updated_at<v_now-INTERVAL '15 minutes')
          oldest_stuck_offline_at,
        (SELECT count(*) FROM public.pos_offline_sale_submissions submission
          WHERE submission.company_id=company.id
            AND submission.status IN('NEEDS_CONFIRMATION','FAILED'))
          offline_submissions_needing_attention,
        (SELECT count(*) FROM public.sales_stock_reservations reservation
          WHERE reservation.company_id=company.id
            AND reservation.status IN('OPEN','PARTIALLY_DISPATCHED'))
          open_reservations,
        (SELECT count(*) FROM public.sales_stock_reservations reservation
          WHERE reservation.company_id=company.id
            AND reservation.status IN('OPEN','PARTIALLY_DISPATCHED')
            AND reservation.updated_at<v_now-INTERVAL '24 hours')
          stale_reservations,
        (SELECT min(reservation.updated_at)
          FROM public.sales_stock_reservations reservation
          WHERE reservation.company_id=company.id
            AND reservation.status IN('OPEN','PARTIALLY_DISPATCHED')
            AND reservation.updated_at<v_now-INTERVAL '24 hours')
          oldest_stale_reservation_at,
        (SELECT count(*) FROM public.sales_delivery_documents delivery
          WHERE delivery.company_id=company.id AND delivery.reservation_id IS NOT NULL
            AND delivery.status IN('READY','PARTIALLY_DISPATCHED','DISPATCHED'))
          open_deliveries,
        (SELECT count(*) FROM public.sales_delivery_documents delivery
          WHERE delivery.company_id=company.id AND delivery.reservation_id IS NOT NULL
            AND delivery.status IN('READY','PARTIALLY_DISPATCHED','DISPATCHED')
            AND COALESCE(delivery.dispatched_at,delivery.created_at)
              <v_now-INTERVAL '24 hours') stale_deliveries,
        (SELECT min(COALESCE(delivery.dispatched_at,delivery.created_at))
          FROM public.sales_delivery_documents delivery
          WHERE delivery.company_id=company.id AND delivery.reservation_id IS NOT NULL
            AND delivery.status IN('READY','PARTIALLY_DISPATCHED','DISPATCHED')
            AND COALESCE(delivery.dispatched_at,delivery.created_at)
              <v_now-INTERVAL '24 hours') oldest_stale_delivery_at,
        (SELECT count(*) FROM public.sales_order_procurement_demands demand
          WHERE demand.company_id=company.id AND demand.status IN('OPEN','FROZEN'))
          open_procurement_demands,
        (SELECT count(*) FROM public.sales_order_procurement_demands demand
          WHERE demand.company_id=company.id AND demand.status IN('OPEN','FROZEN')
            AND demand.updated_at<v_now-INTERVAL '24 hours')
          stale_procurement_demands,
        (SELECT min(demand.updated_at)
          FROM public.sales_order_procurement_demands demand
          WHERE demand.company_id=company.id AND demand.status IN('OPEN','FROZEN')
            AND demand.updated_at<v_now-INTERVAL '24 hours')
          oldest_stale_procurement_at,
        (SELECT count(*) FROM public.sales_payment_verification_requests request_state
          WHERE request_state.company_id=company.id AND request_state.status='PENDING')
          pending_payment_verifications,
        (SELECT count(*) FROM public.sales_payment_verification_requests request_state
          WHERE request_state.company_id=company.id AND request_state.status='PENDING'
            AND request_state.requested_at<v_now-INTERVAL '24 hours')
          stale_payment_verifications,
        (SELECT min(request_state.requested_at)
          FROM public.sales_payment_verification_requests request_state
          WHERE request_state.company_id=company.id AND request_state.status='PENDING'
            AND request_state.requested_at<v_now-INTERVAL '24 hours')
          oldest_stale_payment_at,
        (SELECT count(*) FROM public.negative_stock_sale_allocations allocation
          WHERE allocation.company_id=company.id AND allocation.reconciled_at IS NULL)
          open_negative_allocations,
        (SELECT COALESCE(sum(allocation.shortage_base_qty-
            allocation.replenished_base_qty),0)
          FROM public.negative_stock_sale_allocations allocation
          WHERE allocation.company_id=company.id AND allocation.reconciled_at IS NULL)
          open_negative_base_qty,
        (SELECT count(*) FROM public.inventory_cost_adjustment_sources source_state
          WHERE source_state.company_id=company.id
            AND source_state.status IN('PLANNED','APPLIED')) pending_cost_adjustments
      FROM public.companies company
    ), classified AS (
      SELECT company_health.*,
        CASE
          WHEN open_finance_exceptions>0
            OR offline_submissions_needing_attention>0 THEN 'CRITICAL'
          WHEN stale_cashier_sessions+stale_finance_queues+stuck_import_jobs
            +recent_import_failures+stuck_offline_submissions+stale_reservations
            +stale_deliveries+stale_procurement_demands
            +stale_payment_verifications+hold_financial_events
            +open_negative_allocations+pending_cost_adjustments>0 THEN 'WARNING'
          ELSE 'HEALTHY' END health_status
      FROM company_health
    ), issues AS (
      SELECT company_id,company_code,company_name,'CRITICAL'::TEXT severity,
        'FINANCE'::TEXT module_code,'OPEN_FINANCE_EXCEPTION'::TEXT issue_code,
        open_finance_exceptions issue_count,oldest_finance_exception_at oldest_at,
        'Buka Finance > Jurnal Keuangan dan periksa exception posting.'::TEXT next_action
      FROM classified WHERE open_finance_exceptions>0
      UNION ALL
      SELECT company_id,company_code,company_name,'CRITICAL','POS',
        'OFFLINE_SUBMISSION_NEEDS_ATTENTION',
        offline_submissions_needing_attention,NULL::TIMESTAMPTZ,
        'Periksa submission Offline FAILED atau NEEDS_CONFIRMATION sebelum retry.'
      FROM classified WHERE offline_submissions_needing_attention>0
      UNION ALL
      SELECT company_id,company_code,company_name,'WARNING','FINANCE',
        'STALE_FINANCE_QUEUE',stale_finance_queues,
        oldest_stale_finance_queue_at,
        'Pastikan tidak ada processor aktif sebelum memproses atau membatalkan queue.'
      FROM classified WHERE stale_finance_queues>0
      UNION ALL
      SELECT company_id,company_code,company_name,'WARNING','POS',
        'STALE_CASHIER_SESSION',stale_cashier_sessions,oldest_stale_session_at,
        'Konfirmasi aktivitas kasir dan tutup sesi melalui alur resmi bila selesai.'
      FROM classified WHERE stale_cashier_sessions>0
      UNION ALL
      SELECT company_id,company_code,company_name,'WARNING','DATA',
        'STUCK_IMPORT_JOB',stuck_import_jobs,oldest_stuck_import_at,
        'Buka Data Exchange dan cancel atau lanjutkan job melalui RPC resmi.'
      FROM classified WHERE stuck_import_jobs>0
      UNION ALL
      SELECT company_id,company_code,company_name,'WARNING','DATA',
        'RECENT_IMPORT_FAILURE',recent_import_failures,NULL::TIMESTAMPTZ,
        'Periksa error baris dan status job import tujuh hari terakhir.'
      FROM classified WHERE recent_import_failures>0
      UNION ALL
      SELECT company_id,company_code,company_name,'WARNING','POS',
        'STUCK_OFFLINE_SUBMISSION',stuck_offline_submissions,
        oldest_stuck_offline_at,
        'Periksa koneksi dan status replay; jangan posting ulang manual.'
      FROM classified WHERE stuck_offline_submissions>0
      UNION ALL
      SELECT company_id,company_code,company_name,'WARNING','INVENTORY',
        'STALE_RESERVATION',stale_reservations,oldest_stale_reservation_at,
        'Periksa Order aktif dan Dispatch; jangan mengubah reserved quantity langsung.'
      FROM classified WHERE stale_reservations>0
      UNION ALL
      SELECT company_id,company_code,company_name,'WARNING','INVENTORY',
        'STALE_DELIVERY',stale_deliveries,oldest_stale_delivery_at,
        'Periksa Surat Jalan READY/PARTIAL/DISPATCHED dan konfirmasi status lapangan.'
      FROM classified WHERE stale_deliveries>0
      UNION ALL
      SELECT company_id,company_code,company_name,'WARNING','PURCHASE',
        'STALE_PROCUREMENT_DEMAND',stale_procurement_demands,
        oldest_stale_procurement_at,
        'Periksa Demand, Stock Request, Draft PO, atau amendment yang belum selesai.'
      FROM classified WHERE stale_procurement_demands>0
      UNION ALL
      SELECT company_id,company_code,company_name,'WARNING','FINANCE',
        'STALE_PAYMENT_VERIFICATION',stale_payment_verifications,
        oldest_stale_payment_at,
        'Periksa pembayaran pending; verifikasi tetap asynchronous dan maker-checker.'
      FROM classified WHERE stale_payment_verifications>0
      UNION ALL
      SELECT company_id,company_code,company_name,'WARNING','FINANCE',
        'HOLD_FINANCIAL_EVENT',hold_financial_events,NULL::TIMESTAMPTZ,
        'Buat preview controlled queue setelah source dan mapping tervalidasi.'
      FROM classified WHERE hold_financial_events>0
      UNION ALL
      SELECT company_id,company_code,company_name,'WARNING','INVENTORY',
        'OPEN_NEGATIVE_STOCK_COST',open_negative_allocations,NULL::TIMESTAMPTZ,
        'Selesaikan replenishment dan uji settlement biaya aktual sebelum rekonsiliasi.'
      FROM classified WHERE open_negative_allocations>0
      UNION ALL
      SELECT company_id,company_code,company_name,'WARNING','FINANCE',
        'PENDING_COST_ADJUSTMENT',pending_cost_adjustments,NULL::TIMESTAMPTZ,
        'Periksa source cost adjustment dan posting append-only melalui queue resmi.'
      FROM classified WHERE pending_cost_adjustments>0
    )
    SELECT jsonb_build_object(
      'contractVersion',1,
      'generatedAt',v_now,
      'databaseMigrationVersion',v_schema_version,
      'refreshMode','MANUAL',
      'readOnly',TRUE,
      'thresholds',jsonb_build_object(
        'cashierSessionHours',18,'financeQueueMinutes',30,
        'importJobMinutes',30,'offlineSubmissionMinutes',15,
        'reservationHours',24,'deliveryHours',24,
        'procurementDemandHours',24,'paymentVerificationHours',24),
      'summary',jsonb_build_object(
        'companies',count(*),
        'activeCompanies',count(*) FILTER(WHERE company_status='ACTIVE'),
        'healthyCompanies',count(*) FILTER(WHERE health_status='HEALTHY'),
        'warningCompanies',count(*) FILTER(WHERE health_status='WARNING'),
        'criticalCompanies',count(*) FILTER(WHERE health_status='CRITICAL'),
        'totalIssues',(SELECT COALESCE(sum(issue_count),0) FROM issues)),
      'companies',COALESCE(jsonb_agg(jsonb_build_object(
        'companyId',company_id,'companyCode',company_code,
        'companyName',company_name,'companyStatus',company_status,
        'healthStatus',health_status,
        'metrics',jsonb_build_object(
          'openCashierSessions',open_cashier_sessions,
          'staleCashierSessions',stale_cashier_sessions,
          'activeFinanceQueues',active_finance_queues,
          'staleFinanceQueues',stale_finance_queues,
          'openFinanceExceptions',open_finance_exceptions,
          'holdFinancialEvents',hold_financial_events,
          'stuckImportJobs',stuck_import_jobs,
          'recentImportFailures',recent_import_failures,
          'stuckOfflineSubmissions',stuck_offline_submissions,
          'offlineSubmissionsNeedingAttention',offline_submissions_needing_attention,
          'openReservations',open_reservations,
          'staleReservations',stale_reservations,
          'openDeliveries',open_deliveries,'staleDeliveries',stale_deliveries,
          'openProcurementDemands',open_procurement_demands,
          'staleProcurementDemands',stale_procurement_demands,
          'pendingPaymentVerifications',pending_payment_verifications,
          'stalePaymentVerifications',stale_payment_verifications,
          'openNegativeAllocations',open_negative_allocations,
          'openNegativeBaseQty',open_negative_base_qty,
          'pendingCostAdjustments',pending_cost_adjustments))
        ORDER BY CASE health_status WHEN 'CRITICAL' THEN 1
          WHEN 'WARNING' THEN 2 ELSE 3 END,company_name),'[]'::JSONB),
      'issues',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'companyId',company_id,'companyCode',company_code,
        'companyName',company_name,'severity',severity,
        'moduleCode',module_code,'issueCode',issue_code,
        'count',issue_count,'oldestAt',oldest_at,'nextAction',next_action)
        ORDER BY CASE severity WHEN 'CRITICAL' THEN 1 ELSE 2 END,
          company_name,module_code,issue_code),'[]'::JSONB) FROM issues))
    FROM classified
  );
END
$function$;

REVOKE ALL ON FUNCTION public.get_platform_operational_health()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.get_platform_operational_health()
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260901090000','platform_operational_health_dashboard',
  'Super Admin global read-only operational health aggregate; manual refresh, no trigger, no auto-fix, no business-data backfill');

COMMIT;
