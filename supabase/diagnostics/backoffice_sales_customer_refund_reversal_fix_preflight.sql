-- SELECT-only preflight for Customer Refund automatic Journal reversal guard.
WITH runtime AS (
  SELECT pg_get_functiondef(to_regprocedure(
    'private.trg_g6_guard_finance_journal_line()')) definition
), normalized AS (
  SELECT regexp_replace(lower(definition),'\s+','','g') definition FROM runtime
), checks AS (
  SELECT 'refund_reversal_fix_dependency' check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END status,
    abs(1-count(*))::bigint violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260917150000'
  UNION ALL
  SELECT 'refund_reversal_fix_ledger_collision',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*),
    jsonb_build_object('ledgerRows',count(*))
  FROM private.kgs_schema_migrations WHERE version='20260917151000'
  UNION ALL
  SELECT 'refund_reversal_fix_active_finance_queue',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*),
    jsonb_build_object('runRows',count(*))
  FROM public.finance_posting_queue_runs WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'refund_reversal_fix_guard_contract',
    CASE WHEN position('ifv_journal_type=''reversal''then' IN definition)>0
      AND position('original_journal.journal_typein(''manual'',''opening_balance'')'
        IN definition)>0
      AND position('backoffice_customer_refund' IN definition)=0
      THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN position('ifv_journal_type=''reversal''then' IN definition)>0
      AND position('original_journal.journal_typein(''manual'',''opening_balance'')'
        IN definition)>0
      AND position('backoffice_customer_refund' IN definition)=0
      THEN 0 ELSE 1 END,
    jsonb_build_object('canonicalReversalGuard',
      position('ifv_journal_type=''reversal''then' IN definition)>0,
      'manualOpeningBoundary',position(
        'original_journal.journal_typein(''manual'',''opening_balance'')' IN definition)>0,
      'alreadyPatched',position('backoffice_customer_refund' IN definition)>0)
  FROM normalized
  UNION ALL
  SELECT 'refund_reversal_fix_runtime_inventory','INFO',0,
    jsonb_build_object('refundRows',count(*) FILTER(WHERE document_kind='REFUND'),
      'reversalRows',count(*) FILTER(WHERE document_kind='REVERSAL'))
  FROM public.backoffice_sales_customer_refunds
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 0 WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,
  check_name;
