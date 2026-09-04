-- Revision Order-date authority and transient validation preflight. SELECT-only.
WITH runtime AS (
  SELECT lower(regexp_replace(COALESCE(pg_get_functiondef(to_regprocedure(
    'public.start_pos_sales_order_revision(uuid,bigint,uuid,uuid,text)')),''),
    '[[:space:]]+','','g')) definition
), checks AS (
  SELECT 'revision_date_fix_dependency'::TEXT check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('requiredVersion','20260904130000','ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260904130000'
  UNION ALL
  SELECT 'revision_transient_date_runtime_state',
    CASE WHEN position('v_payload:=private.sales_order_revision_date_payload('
      IN definition)>0 THEN 'SETUP' ELSE 'REVIEW' END,
    jsonb_build_object('sourcePayloadUsesPreserveHelper',
      position('v_payload:=private.sales_order_revision_date_payload('
        IN definition)>0)
  FROM runtime
  UNION ALL
  SELECT 'revisable_order_date_authority_inventory',
    CASE WHEN count(*) FILTER(WHERE NOT EXISTS(
      SELECT 1 FROM public.accounting_periods period
      WHERE period.company_id=source.company_id
        AND CASE WHEN source.order_timing_mode='SCHEDULED'
            THEN source.planned_order_date
            ELSE (source.transaction_date AT TIME ZONE company.timezone)::DATE
          END BETWEEN period.start_date AND period.end_date
        AND period.status IN('OPEN','REOPENED')))<>0
      THEN 'REVIEW' ELSE 'PASS' END,
    jsonb_build_object(
      'eligibleOrders',count(*),
      'scheduledOrders',count(*) FILTER(
        WHERE source.order_timing_mode='SCHEDULED'),
      'scheduledHeaderDateDiffers',count(*) FILTER(
        WHERE source.order_timing_mode='SCHEDULED'
          AND source.planned_order_date IS DISTINCT FROM
            (source.transaction_date AT TIME ZONE company.timezone)::DATE),
      'ordersWithoutOpenEffectivePeriod',count(*) FILTER(WHERE NOT EXISTS(
        SELECT 1 FROM public.accounting_periods period
        WHERE period.company_id=source.company_id
          AND CASE WHEN source.order_timing_mode='SCHEDULED'
              THEN source.planned_order_date
              ELSE (source.transaction_date AT TIME ZONE company.timezone)::DATE
            END BETWEEN period.start_date AND period.end_date
          AND period.status IN('OPEN','REOPENED'))),
      'companyCodesWithoutOpenEffectivePeriod',COALESCE(jsonb_agg(DISTINCT
        company.company_code) FILTER(WHERE NOT EXISTS(
          SELECT 1 FROM public.accounting_periods period
          WHERE period.company_id=source.company_id
            AND CASE WHEN source.order_timing_mode='SCHEDULED'
                THEN source.planned_order_date
                ELSE (source.transaction_date AT TIME ZONE company.timezone)::DATE
              END BETWEEN period.start_date AND period.end_date
            AND period.status IN('OPEN','REOPENED'))),'[]'::JSONB))
  FROM public.sales_headers source
  JOIN public.companies company ON company.id=source.company_id
  JOIN public.sales_stock_reservations reservation
    ON reservation.company_id=source.company_id
   AND reservation.sales_id=source.id
   AND reservation.status='OPEN'
   AND reservation.total_dispatched_base_qty=0
  WHERE source.document_status='DRAFT'
    AND source.order_runtime_status IN('CONFIRMED','RESERVED')
  UNION ALL
  SELECT 'active_finance_posting_queue',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('runCount',count(*))
  FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'nonterminal_offline_submission',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('submissionCount',count(*))
  FROM public.pos_offline_sale_submissions
  WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
  UNION ALL
  SELECT 'company_period_inventory','INFO',jsonb_build_object(
    'companies',count(*),'manualCompanies',count(*) FILTER(
      WHERE policy.period_creation_mode='MANUAL'),
    'companiesWithoutCurrentOpenPeriod',count(*) FILTER(WHERE NOT EXISTS(
      SELECT 1 FROM public.accounting_periods period
      WHERE period.company_id=company.id
        AND (clock_timestamp() AT TIME ZONE company.timezone)::DATE
          BETWEEN period.start_date AND period.end_date
        AND period.status IN('OPEN','REOPENED'))))
  FROM public.companies company
  LEFT JOIN public.finance_company_policies policy ON policy.company_id=company.id
  WHERE company.status='ACTIVE'
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'SETUP' THEN 2
  WHEN 'PASS' THEN 3 ELSE 4 END,check_name;
