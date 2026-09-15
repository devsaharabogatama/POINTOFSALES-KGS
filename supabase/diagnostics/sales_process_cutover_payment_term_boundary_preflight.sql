-- Step 1E-B2/6: one-result, SELECT-only Payment Term cutover audit.
-- Run only on isolated Development. This statement performs no write.

WITH
dependency_versions(version) AS (
  VALUES ('20260909156000'::text),('20260909157000'),('20260909162000'),
    ('20260909163000'),('20260910110000'),('20260910120000'),
    ('20260910130000'),('20260910140000'),('20260910150000'),
    ('20260910151000')
),
dependency_state AS (
  SELECT count(ledger.version)::bigint present
  FROM dependency_versions expected
  LEFT JOIN private.kgs_schema_migrations ledger USING(version)
),
office_open AS MATERIALIZED (
  SELECT document.company_id,document.id,
    COALESCE(document.order_no,document.quotation_no) document_no,
    document.is_tempo,document.due_date,document.payment_term_id,
    COALESCE((SELECT count(*) FROM public.backoffice_sales_payment_term_lines line
      WHERE line.company_id=document.company_id
        AND line.payment_term_id=document.payment_term_id),0)::bigint header_term_lines,
    COALESCE((SELECT max(schedule_count) FROM (
      SELECT count(schedule.id)::bigint schedule_count
      FROM public.backoffice_sales_invoices invoice
      LEFT JOIN public.backoffice_sales_invoice_receivable_schedules schedule
        ON schedule.company_id=invoice.company_id AND schedule.invoice_id=invoice.id
      WHERE invoice.company_id=document.company_id
        AND invoice.sales_order_id=document.id AND invoice.status='DRAFT'
      GROUP BY invoice.id
    ) counted),0)::bigint draft_schedule_max,
    COALESCE((SELECT max(term_line_count) FROM (
      SELECT count(term_line.id)::bigint term_line_count
      FROM public.backoffice_sales_invoices invoice
      LEFT JOIN public.backoffice_sales_payment_term_lines term_line
        ON term_line.company_id=invoice.company_id
       AND term_line.payment_term_id=invoice.payment_term_id
      WHERE invoice.company_id=document.company_id
        AND invoice.sales_order_id=document.id AND invoice.status='DRAFT'
      GROUP BY invoice.id
    ) counted),0)::bigint draft_invoice_term_line_max
  FROM public.backoffice_sales_orders document
  JOIN public.company_sales_process_settings setting
    ON setting.company_id=document.company_id
   AND setting.active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE'
  WHERE document.sales_process_mode='BACKOFFICE_DELIVERED_QTY_INVOICE'
    AND document.status IN('DRAFT','SENT','CONFIRMED')
    AND document.fulfillment_status NOT IN('COMPLETED','CANCELED')
),
retail_open AS MATERIALIZED (
  SELECT sale.company_id,sale.id,COALESCE(sale.draft_no,sale.invoice_no) document_no,
    sale.is_tempo,sale.due_date
  FROM public.sales_headers sale
  JOIN public.company_sales_process_settings setting
    ON setting.company_id=sale.company_id
   AND setting.active_mode='RETAIL_CONFIRM_INVOICE'
  WHERE sale.sales_process_mode='RETAIL_CONFIRM_INVOICE'
    AND sale.order_runtime_status IN('DRAFT_INPUT','SCHEDULED','CONFIRMED','RESERVED',
      'PARTIALLY_DISPATCHED','DISPATCHED')
),
checks AS (
  SELECT 'payment_term_boundary_dependency_ledger'::text check_name,
    CASE WHEN present=10 THEN 'PASS' ELSE 'BLOCKER' END status,
    (10-present)::bigint violation_rows,
    jsonb_build_object('expected',10,'present',present) details
  FROM dependency_state
  UNION ALL
  SELECT 'payment_term_boundary_relation_contract',
    CASE WHEN count(*)=6 THEN 'PASS' ELSE 'BLOCKER' END,
    abs(6-count(*))::bigint,
    jsonb_build_object('expected',6,'present',count(*))
  FROM information_schema.tables
  WHERE table_schema='public' AND table_name IN('sales_headers',
    'backoffice_sales_orders','backoffice_sales_payment_term_lines',
    'backoffice_sales_invoices','backoffice_sales_invoice_receivable_schedules',
    'sales_process_cutover_plans')
  UNION ALL
  SELECT 'payment_term_boundary_routine_contract',
    CASE WHEN count(routine_oid)=2 THEN 'PASS' ELSE 'BLOCKER' END,
    (2-count(routine_oid))::bigint,
    jsonb_build_object('expected',2,'present',count(routine_oid))
  FROM (VALUES
    (to_regprocedure('private.classify_sales_process_conversion_candidate(text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean)')),
    (to_regprocedure('private.get_sales_process_cutover_preview_core(uuid,text)'))
  ) required(routine_oid)
  UNION ALL
  SELECT 'payment_term_classifier_overload_collision',
    CASE WHEN to_regprocedure('private.classify_sales_process_conversion_candidate(text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean)') IS NULL
      THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN to_regprocedure('private.classify_sales_process_conversion_candidate(text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean)') IS NULL
      THEN 0 ELSE 1 END,
    jsonb_build_object('existing',to_regprocedure('private.classify_sales_process_conversion_candidate(text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean)')::text)
  UNION ALL
  SELECT 'open_cutover_plan_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('openPlans',count(*),'required','Cancel and recreate after preview classifier upgrade')
  FROM public.sales_process_cutover_plans WHERE status IN('DRAFT','PREVIEWED','APPLYING')
  UNION ALL
  SELECT 'active_finance_queue_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('activeRuns',count(*))
  FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'nonterminal_offline_submission_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('submissionRows',count(*))
  FROM public.pos_offline_sale_submissions
  WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
  UNION ALL
  SELECT 'office_multi_installment_candidate_inventory','INFO',0::bigint,
    jsonb_build_object('rows',count(*),'documents',COALESCE(jsonb_agg(
      jsonb_build_object('companyId',company_id,'documentNo',document_no,
        'headerTermLines',header_term_lines,'draftInvoiceTermLines',draft_invoice_term_line_max,
        'draftScheduleLines',draft_schedule_max) ORDER BY document_no),'[]'::jsonb))
  FROM office_open
  WHERE greatest(header_term_lines,draft_invoice_term_line_max,draft_schedule_max)>1
  UNION ALL
  SELECT 'office_single_due_date_inventory','INFO',0::bigint,
    jsonb_build_object('openDocuments',count(*),'tempoDocuments',count(*) FILTER(WHERE is_tempo),
      'tempoWithoutDueDate',count(*) FILTER(WHERE is_tempo AND due_date IS NULL))
  FROM office_open
  UNION ALL
  SELECT 'retail_single_due_date_inventory','INFO',0::bigint,
    jsonb_build_object('openDocuments',count(*),'tempoDocuments',count(*) FILTER(WHERE is_tempo),
      'tempoWithoutDueDate',count(*) FILTER(WHERE is_tempo AND due_date IS NULL))
  FROM retail_open
  UNION ALL
  SELECT 'preflight_environment_identity','INFO',0::bigint,
    jsonb_build_object('database',current_database(),'databaseUser',current_user,
      'serverAddress',inet_server_addr()::text,'serverPort',inet_server_port(),
      'requiredProjectRef','fkywtxucmyjvpwdiqpix')
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;

