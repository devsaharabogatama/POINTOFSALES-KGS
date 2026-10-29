-- SELECT-only postflight for migration 20261029100000.
WITH objects AS (
  SELECT jsonb_build_object(
    'documents',to_regclass('public.opening_balance_documents') IS NOT NULL,
    'lines',to_regclass('public.opening_balance_lines') IS NOT NULL,
    'audit',to_regclass('public.opening_balance_audit') IS NOT NULL,
    'workspace',to_regprocedure('public.get_opening_balance_workspace()') IS NOT NULL,
    'save',to_regprocedure('public.save_opening_balance_draft(uuid,bigint,uuid,date,text,text,jsonb)') IS NOT NULL,
    'submit',to_regprocedure('public.submit_opening_balance(uuid,bigint)') IS NOT NULL,
    'post',to_regprocedure('public.post_opening_balance(uuid,bigint,uuid)') IS NOT NULL,
    'cancel',to_regprocedure('public.cancel_opening_balance(uuid,bigint,text)') IS NOT NULL
  ) details
), ledger AS (
  SELECT count(*)::bigint rows FROM private.kgs_schema_migrations WHERE version='20261029100000'
), invalid AS (
  SELECT count(*)::bigint rows
  FROM public.opening_balance_documents document
  LEFT JOIN public.finance_journals journal
    ON journal.company_id=document.company_id AND journal.id=document.journal_id
  WHERE (document.status='POSTED' AND (journal.id IS NULL OR journal.status<>'POSTED'
      OR journal.journal_type<>'OPENING_BALANCE' OR journal.source_id<>document.id
      OR journal.total_debit<>document.total_debit OR journal.total_credit<>document.total_credit))
    OR (document.status<>'POSTED' AND document.journal_id IS NOT NULL)
), business_effect AS (
  SELECT count(*)::bigint rows
  FROM public.opening_balance_documents document
  JOIN public.stock_movements movement ON movement.company_id=document.company_id
    AND movement.reference_id=document.id
)
SELECT 'opening_balance_direct_entry_migration_ledger' check_name,
  CASE WHEN rows=1 THEN 'PASS' ELSE 'FAIL' END status,abs(rows-1) violation_rows,
  jsonb_build_object('ledgerRows',rows) details FROM ledger
UNION ALL
SELECT 'opening_balance_direct_entry_object_contract',
  CASE WHEN details @> '{"documents":true,"lines":true,"audit":true,"workspace":true,"save":true,"submit":true,"post":true,"cancel":true}'::jsonb THEN 'PASS' ELSE 'FAIL' END,
  CASE WHEN details @> '{"documents":true,"lines":true,"audit":true,"workspace":true,"save":true,"submit":true,"post":true,"cancel":true}'::jsonb THEN 0 ELSE 1 END,details FROM objects
UNION ALL
SELECT 'opening_balance_direct_entry_journal_contract',CASE WHEN rows=0 THEN 'PASS' ELSE 'FAIL' END,rows,
  jsonb_build_object('invalidRows',rows) FROM invalid
UNION ALL
SELECT 'opening_balance_direct_entry_stock_boundary',CASE WHEN rows=0 THEN 'PASS' ELSE 'FAIL' END,rows,
  jsonb_build_object('effectRows',rows,'rule','Opening Balance Finance must not create Stock/FIFO movement') FROM business_effect
ORDER BY check_name;
