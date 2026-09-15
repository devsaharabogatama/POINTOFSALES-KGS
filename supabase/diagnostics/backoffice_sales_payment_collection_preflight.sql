-- SELECT-only readiness gate for Backoffice Invoice payment collection.
-- Target: isolated Development project only. This file performs no writes.
WITH required_migrations(version) AS (
  VALUES
    ('20260827100000'::text),
    ('20260827110000'::text),
    ('20260827120000'::text),
    ('20260829120000'::text),
    ('20260909161000'::text),
    ('20260911150000'::text)
), required_relations(name) AS (
  VALUES
    ('customer_receipt_documents'::text),
    ('customer_receipt_allocations'::text),
    ('backoffice_sales_invoices'::text),
    ('backoffice_sales_invoice_receivable_schedules'::text),
    ('financial_events'::text),
    ('finance_journals'::text)
), required_routines(signature) AS (
  VALUES
    ('public.save_customer_receipt_draft_with_disposition(uuid,bigint,uuid,date,uuid,text,text,text,numeric,text,jsonb)'::text),
    ('public.post_customer_receipt_with_disposition(uuid,bigint,uuid)'::text),
    ('private.post_customer_receipt_financial_event_core(uuid,uuid,bigint,uuid)'::text),
    ('private.odr6d_dispatched_receivable_before_receipts(uuid,uuid,date)'::text),
    ('public.get_backoffice_sales_invoice_ui(uuid)'::text)
), checks AS (
  SELECT 'payment_collection_dependency_ledger'::text check_name,
    CASE WHEN count(ledger.version)=count(*) THEN 'PASS' ELSE 'BLOCKER' END status,
    count(*)-count(ledger.version) violation_rows,
    jsonb_build_object('expected',count(*),'present',count(ledger.version),
      'missing',COALESCE(jsonb_agg(required.version) FILTER(WHERE ledger.version IS NULL),'[]'::jsonb)) details
  FROM required_migrations required
  LEFT JOIN private.kgs_schema_migrations ledger ON ledger.version=required.version

  UNION ALL
  SELECT 'payment_collection_relation_contract',
    CASE WHEN count(cls.relname)=count(*) THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)-count(cls.relname),
    jsonb_build_object('expected',count(*),'present',count(cls.relname),
      'missing',COALESCE(jsonb_agg(required.name) FILTER(WHERE cls.relname IS NULL),'[]'::jsonb))
  FROM required_relations required
  LEFT JOIN pg_namespace ns ON ns.nspname='public'
  LEFT JOIN pg_class cls ON cls.relnamespace=ns.oid AND cls.relname=required.name
    AND cls.relkind IN('r','p')

  UNION ALL
  SELECT 'payment_collection_routine_contract',
    CASE WHEN count(proc.oid)=count(*) THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)-count(proc.oid),
    jsonb_build_object('expected',count(*),'present',count(proc.oid),
      'missing',COALESCE(jsonb_agg(required.signature) FILTER(WHERE proc.oid IS NULL),'[]'::jsonb))
  FROM required_routines required
  LEFT JOIN pg_proc proc ON proc.oid=to_regprocedure(required.signature)

  UNION ALL
  SELECT 'payment_collection_new_object_collision',
    CASE WHEN to_regclass('public.customer_receipt_backoffice_invoice_allocations') IS NULL
      AND to_regprocedure('public.save_customer_receipt_allocated_draft(uuid,bigint,uuid,date,uuid,text,text,text,numeric,jsonb)') IS NULL
      AND to_regprocedure('public.post_customer_receipt_allocated(uuid,bigint,uuid)') IS NULL
      THEN 'PASS' ELSE 'BLOCKER' END,
    (CASE WHEN to_regclass('public.customer_receipt_backoffice_invoice_allocations') IS NULL THEN 0 ELSE 1 END
      +CASE WHEN to_regprocedure('public.save_customer_receipt_allocated_draft(uuid,bigint,uuid,date,uuid,text,text,text,numeric,jsonb)') IS NULL THEN 0 ELSE 1 END
      +CASE WHEN to_regprocedure('public.post_customer_receipt_allocated(uuid,bigint,uuid)') IS NULL THEN 0 ELSE 1 END)::bigint,
    jsonb_build_object('allocationTableExists',
      to_regclass('public.customer_receipt_backoffice_invoice_allocations') IS NOT NULL,
      'saveRoutineExists',to_regprocedure('public.save_customer_receipt_allocated_draft(uuid,bigint,uuid,date,uuid,text,text,text,numeric,jsonb)') IS NOT NULL,
      'postRoutineExists',to_regprocedure('public.post_customer_receipt_allocated(uuid,bigint,uuid)') IS NOT NULL)

  UNION ALL
  SELECT 'payment_collection_active_finance_queue',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*),
    jsonb_build_object('runRows',count(*))
  FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')

  UNION ALL
  SELECT 'payment_collection_nonterminal_offline',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*),
    jsonb_build_object('submissionRows',count(*))
  FROM public.pos_offline_sale_submissions
  WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')

  UNION ALL
  SELECT 'payment_collection_invoice_schedule_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*),
    jsonb_build_object('invalidInvoices',count(*))
  FROM (
    SELECT invoice.company_id,invoice.id
    FROM public.backoffice_sales_invoices invoice
    LEFT JOIN public.backoffice_sales_invoice_receivable_schedules schedule
      ON schedule.company_id=invoice.company_id AND schedule.invoice_id=invoice.id
    WHERE invoice.status='POSTED' AND invoice.grand_total>0
    GROUP BY invoice.company_id,invoice.id,invoice.grand_total
    HAVING round(COALESCE(sum(schedule.amount_due),0),4)<>round(invoice.grand_total,4)
      OR bool_or(schedule.status NOT IN('OPEN','PARTIALLY_PAID','PAID'))
  ) invalid

  UNION ALL
  SELECT 'payment_collection_runtime_inventory','INFO',0,
    jsonb_build_object(
      'postedBackofficeInvoices',(SELECT count(*) FROM public.backoffice_sales_invoices WHERE status='POSTED'),
      'openBackofficeScheduleAmount',(SELECT COALESCE(sum(amount_due-allocated_payment_amount),0)
        FROM public.backoffice_sales_invoice_receivable_schedules WHERE status IN('OPEN','PARTIALLY_PAID')),
      'existingPostedReceipts',(SELECT count(*) FROM public.customer_receipt_documents WHERE status='POSTED'),
      'activeReceiptMethods',(SELECT count(*) FROM public.payment_methods
        WHERE is_active AND settlement_route IN('CASH_DRAWER','DIRECT_BANK')))

  UNION ALL
  SELECT 'preflight_environment_identity','INFO',0,
    jsonb_build_object('database',current_database(),'databaseUser',current_user,
      'serverAddress',inet_server_addr(),'serverPort',inet_server_port(),
      'revision','BACKOFFICE_PAYMENT_COLLECTION_STEP_1_OF_3_V1')
)
SELECT check_name,status,violation_rows,details
FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'FAIL' THEN 2 WHEN 'PASS' THEN 3 ELSE 4 END,
  check_name;
