-- SELECT-only preflight for 20260911163000. Run the entire file.
WITH checks AS (
  SELECT 'dependency_ledger' check_name,
    CASE WHEN count(*)=4 THEN 'PASS' ELSE 'BLOCKER' END status,
    (4-count(*))::bigint violation_rows,
    jsonb_build_object('expected',4,'present',count(*)) details
  FROM private.kgs_schema_migrations
  WHERE version IN('20260829120000','20260911160000','20260911161000','20260911162000')
  UNION ALL
  SELECT 'required_relation_contract',
    CASE WHEN count(*)=5 THEN 'PASS' ELSE 'BLOCKER' END,(5-count(*))::bigint,
    jsonb_build_object('expected',5,'present',count(*))
  FROM (VALUES
    (to_regclass('public.customer_receipt_documents')),
    (to_regclass('public.customer_receipt_allocations')),
    (to_regclass('public.customer_receipt_backoffice_invoice_allocations')),
    (to_regclass('public.backoffice_sales_invoices')),
    (to_regclass('public.backoffice_sales_invoice_receivable_schedules'))
  ) required(value) WHERE value IS NOT NULL
  UNION ALL
  SELECT 'canonical_reader_contract',
    CASE WHEN count(*)=3 THEN 'PASS' ELSE 'BLOCKER' END,(3-count(*))::bigint,
    jsonb_build_object('expected',3,'present',count(*))
  FROM (VALUES
    (to_regprocedure('public.get_finance_customer_receipts()')),
    (to_regprocedure('public.get_finance_ar_aging(date,uuid,uuid)')),
    (to_regprocedure('public.get_finance_customer_statement(uuid,date,date,uuid)'))
  ) required(value) WHERE value IS NOT NULL
  UNION ALL
  SELECT 'source_neutral_receipt_contract',
    CASE WHEN count(*)=2 THEN 'PASS' ELSE 'BLOCKER' END,(2-count(*))::bigint,
    jsonb_build_object('expected',2,'present',count(*))
  FROM (VALUES
    (to_regprocedure('public.save_customer_receipt_allocated_draft(uuid,bigint,uuid,date,uuid,text,text,text,numeric,jsonb)')),
    (to_regprocedure('public.post_customer_receipt_allocated(uuid,bigint,uuid)'))
  ) required(value) WHERE value IS NOT NULL
  UNION ALL
  SELECT 'unified_post_collision',
    CASE WHEN to_regprocedure('public.post_customer_receipt_unified(uuid,bigint,uuid)') IS NULL
      THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN to_regprocedure('public.post_customer_receipt_unified(uuid,bigint,uuid)') IS NULL
      THEN 0 ELSE 1 END,
    jsonb_build_object('existing',to_regprocedure('public.post_customer_receipt_unified(uuid,bigint,uuid)') IS NOT NULL)
  UNION ALL
  SELECT 'active_finance_queue_boundary',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('activeRuns',count(*))
  FROM public.finance_posting_queue_runs WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'nonterminal_offline_boundary',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('submissions',count(*))
  FROM public.pos_offline_sale_submissions WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
)
SELECT * FROM checks ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'FAIL' THEN 2 ELSE 3 END,check_name;

