-- SELECT-only verification for Customer Refund reversal guard forward fix.
WITH runtime AS (
  SELECT pg_get_functiondef(to_regprocedure(
    'private.trg_g6_guard_finance_journal_line()')) definition
), normalized AS (
  SELECT regexp_replace(lower(definition),'\s+','','g') definition FROM runtime
), checks AS (
  SELECT 'refund_reversal_fix_ledger' check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(1-count(*))::bigint violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260917151000'
  UNION ALL
  SELECT 'refund_reversal_fix_guard_contract',
    CASE WHEN position('ifv_journal_type=''reversal''then' IN definition)>0
      AND position('original_journal.journal_typein(''manual'',''opening_balance'')'
        IN definition)>0
      AND position('v_system_event_key=''backoffice_customer_refund'''
        IN definition)>0
      AND position('original_journal.system_event_key=''backoffice_customer_refund'''
        IN definition)>0
      AND position('original_journal.journal_typein(''automatic'',''prior_period_adjustment'')'
        IN definition)>0
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN position('ifv_journal_type=''reversal''then' IN definition)>0
      AND position('original_journal.journal_typein(''manual'',''opening_balance'')'
        IN definition)>0
      AND position('v_system_event_key=''backoffice_customer_refund'''
        IN definition)>0
      AND position('original_journal.system_event_key=''backoffice_customer_refund'''
        IN definition)>0
      AND position('original_journal.journal_typein(''automatic'',''prior_period_adjustment'')'
        IN definition)>0
      THEN 0 ELSE 1 END,
    jsonb_build_object('manualOpeningPreserved',position(
        'original_journal.journal_typein(''manual'',''opening_balance'')' IN definition)>0,
      'refundEventScoped',position(
        'v_system_event_key=''backoffice_customer_refund''' IN definition)>0
        AND position('original_journal.system_event_key=''backoffice_customer_refund'''
          IN definition)>0,
      'automaticPriorPeriodScoped',position(
        'original_journal.journal_typein(''automatic'',''prior_period_adjustment'')'
          IN definition)>0)
  FROM normalized
  UNION ALL
  SELECT 'refund_reversal_fix_private_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('authenticatedExecutableRows',count(*))
  FROM information_schema.routine_privileges privilege
  WHERE privilege.grantee='authenticated' AND privilege.privilege_type='EXECUTE'
    AND privilege.routine_schema='private'
    AND privilege.routine_name='trg_g6_guard_finance_journal_line'
  UNION ALL
  SELECT 'refund_reversal_source_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('invalidRows',count(*))
  FROM public.backoffice_sales_customer_refunds refund
  JOIN public.finance_journals reversal
    ON reversal.company_id=refund.company_id
   AND reversal.financial_event_id=refund.financial_event_id
  LEFT JOIN public.backoffice_sales_customer_refunds source_refund
    ON source_refund.company_id=refund.company_id
   AND source_refund.id=refund.reversal_of_refund_id
  LEFT JOIN public.finance_journals source_journal
    ON source_journal.company_id=source_refund.company_id
   AND source_journal.financial_event_id=source_refund.financial_event_id
  WHERE refund.document_kind='REVERSAL' AND (
    reversal.status<>'POSTED' OR reversal.journal_type<>'REVERSAL'
    OR reversal.reversal_of_journal_id IS DISTINCT FROM source_journal.id
    OR source_journal.status<>'POSTED'
    OR source_journal.journal_type NOT IN('AUTOMATIC','PRIOR_PERIOD_ADJUSTMENT')
    OR reversal.total_debit<>source_journal.total_credit
    OR reversal.total_credit<>source_journal.total_debit)
  UNION ALL
  SELECT 'refund_reversal_fix_runtime_inventory','INFO',0,
    jsonb_build_object('reversalRows',count(*))
  FROM public.backoffice_sales_customer_refunds WHERE document_kind='REVERSAL'
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 0 WHEN 'BLOCKER' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,
  check_name;
