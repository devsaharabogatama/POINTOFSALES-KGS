WITH runtime AS (
  SELECT to_regprocedure(
    'public.save_customer_receipt_allocated_draft(uuid,bigint,uuid,date,uuid,text,text,text,numeric,jsonb)') AS saver
), definition AS (
  SELECT md5(pg_get_functiondef(saver)) AS definition_md5,
    (length(pg_get_functiondef(saver))-length(replace(pg_get_functiondef(saver),
      'IF p_receipt_date>current_date THEN RAISE EXCEPTION ''CUSTOMER_RECEIPT_DATE_FUTURE''; END IF;','')))
      /length('IF p_receipt_date>current_date THEN RAISE EXCEPTION ''CUSTOMER_RECEIPT_DATE_FUTURE''; END IF;')
      AS utc_guard_count,
    pg_get_functiondef(saver) ILIKE '%v_company_today%' AS company_aware
  FROM runtime WHERE saver IS NOT NULL
), boundary AS (
  SELECT (SELECT count(*) FROM public.finance_posting_queue_runs
      WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) AS active_finance_queue,
    (SELECT count(*) FROM public.pos_offline_sale_submissions
      WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) AS nonterminal_offline
)
SELECT 'backoffice_customer_receipt_company_date_preflight_dependency_ledger' AS check_name,
  CASE WHEN count(*)=2 THEN 'PASS' ELSE 'BLOCKER' END AS status,
  (2-count(*))::bigint AS violation_rows,
  jsonb_build_object('required',ARRAY['20261105110000','20261110100000'],
    'installed',COALESCE(jsonb_agg(version ORDER BY version),'[]'::jsonb)) AS details
FROM private.kgs_schema_migrations WHERE version IN('20261105110000','20261110100000')
UNION ALL
SELECT 'backoffice_customer_receipt_company_date_preflight_installation_state',
  CASE WHEN NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20261110110000') THEN 'PASS' ELSE 'BLOCKER' END,
  CASE WHEN EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20261110110000') THEN 1 ELSE 0 END,
  jsonb_build_object('classification',CASE WHEN EXISTS(SELECT 1
    FROM private.kgs_schema_migrations WHERE version='20261110110000')
    THEN 'INSTALLED' ELSE 'NOT_INSTALLED' END)
UNION ALL
SELECT 'backoffice_customer_receipt_company_date_preflight_runtime_anchor',
  CASE WHEN definition_md5='f77bd1009a5c15f063748981ad48e77d'
      AND utc_guard_count=1 AND NOT company_aware THEN 'PASS' ELSE 'BLOCKER' END,
  CASE WHEN definition_md5='f77bd1009a5c15f063748981ad48e77d'
      AND utc_guard_count=1 AND NOT company_aware THEN 0 ELSE 1 END,
  jsonb_build_object('definitionMd5',definition_md5,'utcGuardCount',utc_guard_count,
    'companyAware',company_aware)
FROM definition
UNION ALL
SELECT 'backoffice_customer_receipt_company_date_preflight_observed_clock','INFO',0,
  jsonb_build_object('postgresCurrentDate',current_date,'companies',COALESCE((SELECT jsonb_agg(
    jsonb_build_object('code',company.company_code,'timezone',company.timezone,
      'companyDate',(clock_timestamp() AT TIME ZONE company.timezone)::date)
    ORDER BY company.company_code)
    FROM public.companies company JOIN public.company_sales_process_settings setting
      ON setting.company_id=company.id
    WHERE setting.active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE'),'[]'::jsonb))
UNION ALL
SELECT 'backoffice_customer_receipt_company_date_preflight_runtime_boundary',
  CASE WHEN active_finance_queue=0 AND nonterminal_offline=0 THEN 'PASS' ELSE 'BLOCKER' END,
  active_finance_queue+nonterminal_offline,
  jsonb_build_object('activeFinanceQueue',active_finance_queue,
    'nonterminalOffline',nonterminal_offline) FROM boundary
UNION ALL
SELECT 'backoffice_customer_receipt_company_date_preflight_business_boundary','INFO',0,
  jsonb_build_object('mutation','NONE','changed',jsonb_build_array(
    'Customer Receipt future-date authority uses active Company timezone'),
    'preserved',jsonb_build_array('Receipt amount and allocation','Journal','permissions',
      'idempotency','POS direct payment','Stock/FIFO','historical rows'));
