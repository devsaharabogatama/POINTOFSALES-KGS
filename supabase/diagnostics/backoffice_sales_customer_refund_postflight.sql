-- SELECT-only verification for Backoffice Sales Return Step 4/5.
WITH checks AS (
  SELECT 'refund_migration_ledger' check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(1-count(*))::bigint violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260917150000'
  UNION ALL
  SELECT 'refund_reversal_guard_fix_ledger',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    abs(1-count(*))::bigint,jsonb_build_object('ledgerRows',count(*))
  FROM private.kgs_schema_migrations WHERE version='20260917151000'
  UNION ALL
  SELECT 'refund_required_relations',CASE WHEN count(*)=3 THEN 'PASS' ELSE 'FAIL' END,
    (3-count(*))::bigint,jsonb_build_object('expected',3,'present',count(*))
  FROM (VALUES('backoffice_sales_customer_refunds'),
      ('backoffice_sales_customer_refund_operations'),
      ('backoffice_sales_customer_refund_audit')) required(name)
  WHERE to_regclass('public.'||name) IS NOT NULL
  UNION ALL
  SELECT 'refund_required_routines',
    CASE WHEN count(*) FILTER(WHERE procedure IS NOT NULL)=9 THEN 'PASS' ELSE 'FAIL' END,
    (9-count(*) FILTER(WHERE procedure IS NOT NULL))::bigint,
    jsonb_build_object('expected',9,
      'present',count(*) FILTER(WHERE procedure IS NOT NULL),'missing',
      COALESCE(jsonb_agg(signature) FILTER(WHERE procedure IS NULL),'[]'::jsonb))
  FROM (SELECT signature,to_regprocedure(signature) procedure FROM (VALUES
    ('private.backoffice_sales_customer_refund_snapshot(uuid,uuid)'),
    ('private.backoffice_sales_customer_refund_operation_retry(uuid,uuid,text,text)'),
    ('private.backoffice_sales_credit_note_refunded_amount(uuid,uuid)'),
    ('private.refresh_backoffice_sales_return_refund_status(uuid,uuid)'),
    ('private.trg_guard_backoffice_sales_customer_refund_history()'),
    ('private.trg_provision_backoffice_customer_refund_category()'),
    ('public.post_backoffice_sales_customer_refund(uuid,bigint,uuid,date,numeric,uuid,text,text,text)'),
    ('public.reverse_backoffice_sales_customer_refund(uuid,bigint,uuid,date,text)'),
    ('public.get_backoffice_sales_credit_note_refunds(uuid)')) item(signature)) scope
  UNION ALL
  SELECT 'refund_permission_contract',CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    abs(1-count(*))::bigint,jsonb_build_object('permissionRows',count(*))
  FROM public.access_permission_catalog WHERE permission_key='finance.customer_refunds'
    AND enforcement_status='ENFORCED' AND ARRAY['VIEW','POST','REVERSE']::text[]<@supported_capabilities
    AND operator_roles=ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE']::text[]
  UNION ALL
  SELECT 'refund_finance_catalog_contract',CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    abs(1-count(*))::bigint,jsonb_build_object('eventRows',count(*))
  FROM public.system_events WHERE system_key='BACKOFFICE_CUSTOMER_REFUND'
    AND required_account_functions@>ARRAY['CUSTOMER_REFUND_LIABILITY']::text[]
    AND conditional_account_functions@>ARRAY['CASH_DRAWER','BANK_RECEIPT']::text[]
  UNION ALL
  SELECT 'refund_company_category_contract',
    CASE WHEN count(*) FILTER(WHERE category_rows<>1)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE category_rows<>1),jsonb_build_object('invalidCompanies',
      COALESCE(jsonb_agg(company_id ORDER BY company_id) FILTER(WHERE category_rows<>1),'[]'::jsonb))
  FROM (SELECT company.id company_id,(SELECT count(*) FROM public.transaction_categories category
      WHERE category.company_id=company.id AND category.system_key='BACKOFFICE_CUSTOMER_REFUND'
        AND category.is_active) category_rows
    FROM public.companies company WHERE company.status='ACTIVE') scope
  UNION ALL
  SELECT 'refund_security_contract',
    CASE WHEN count(*) FILTER(WHERE relrowsecurity)=3 THEN 'PASS' ELSE 'FAIL' END,
    (3-count(*) FILTER(WHERE relrowsecurity))::bigint,
    jsonb_build_object('expectedRlsTables',3,'rlsTables',count(*) FILTER(WHERE relrowsecurity))
  FROM pg_class relation JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
  WHERE namespace.nspname='public' AND relation.relname IN(
    'backoffice_sales_customer_refunds','backoffice_sales_customer_refund_operations',
    'backoffice_sales_customer_refund_audit')
  UNION ALL
  SELECT 'refund_immutable_trigger_contract',
    CASE WHEN count(*)=3 AND count(*) FILTER(WHERE trigger.tgenabled='A')=3
      THEN 'PASS' ELSE 'FAIL' END,
    (3-count(*) FILTER(WHERE trigger.tgenabled='A'))::bigint,
    jsonb_build_object('expected',3,'present',count(*),
      'enabledAlways',count(*) FILTER(WHERE trigger.tgenabled='A'))
  FROM pg_trigger trigger JOIN pg_class relation ON relation.oid=trigger.tgrelid
  JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
  WHERE namespace.nspname='public' AND NOT trigger.tgisinternal
    AND trigger.tgname IN('backoffice_sales_customer_refunds_immutable',
      'backoffice_sales_customer_refund_operations_immutable',
      'backoffice_sales_customer_refund_audit_immutable')
  UNION ALL
  SELECT 'refund_company_provisioning_trigger_contract',
    CASE WHEN count(*)=1 AND count(*) FILTER(WHERE trigger.tgenabled='O')=1
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1 AND count(*) FILTER(WHERE trigger.tgenabled='O')=1
      THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('triggerRows',count(*),
      'enabledOrigin',count(*) FILTER(WHERE trigger.tgenabled='O'))
  FROM pg_trigger trigger JOIN pg_class relation ON relation.oid=trigger.tgrelid
  JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
  WHERE namespace.nspname='public' AND relation.relname='companies'
    AND NOT trigger.tgisinternal
    AND trigger.tgname='zz_provision_backoffice_customer_refund_category'
  UNION ALL
  SELECT 'refund_private_boundary',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*),jsonb_build_object('authenticatedExecutableRows',count(*))
  FROM information_schema.routine_privileges privilege
  WHERE privilege.grantee='authenticated' AND privilege.privilege_type='EXECUTE'
    AND privilege.routine_schema='private'
    AND privilege.routine_name IN('backoffice_sales_customer_refund_snapshot',
      'backoffice_sales_customer_refund_operation_retry',
      'backoffice_sales_credit_note_refunded_amount',
      'refresh_backoffice_sales_return_refund_status',
      'trg_guard_backoffice_sales_customer_refund_history')
  UNION ALL
  SELECT 'refund_liability_cap_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('overRefundedCreditNotes',count(*))
  FROM (SELECT note.id FROM public.backoffice_sales_credit_notes note
    LEFT JOIN public.backoffice_sales_customer_refunds refund
      ON refund.company_id=note.company_id AND refund.credit_note_id=note.id
     AND refund.status='POSTED'
    WHERE note.status='POSTED' GROUP BY note.company_id,note.id,note.refund_liability_amount
    HAVING round(COALESCE(sum(CASE refund.document_kind WHEN 'REFUND' THEN refund.amount
      WHEN 'REVERSAL' THEN -refund.amount ELSE 0 END),0),4)<0
      OR round(COALESCE(sum(CASE refund.document_kind WHEN 'REFUND' THEN refund.amount
        WHEN 'REVERSAL' THEN -refund.amount ELSE 0 END),0),4)>note.refund_liability_amount) invalid
  UNION ALL
  SELECT 'refund_journal_reconciliation',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*),jsonb_build_object('invalidRows',count(*))
  FROM public.backoffice_sales_customer_refunds refund
  LEFT JOIN public.finance_journals journal
    ON journal.company_id=refund.company_id AND journal.financial_event_id=refund.financial_event_id
  WHERE journal.id IS NULL OR journal.status<>'POSTED'
    OR journal.total_debit<>refund.amount OR journal.total_credit<>refund.amount
    OR (refund.document_kind='REVERSAL' AND journal.reversal_of_journal_id IS NULL)
      OR (refund.document_kind='REFUND' AND journal.reversal_of_journal_id IS NOT NULL)
  UNION ALL
  SELECT 'refund_event_source_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('invalidRows',count(*))
  FROM public.backoffice_sales_customer_refunds refund
  LEFT JOIN public.financial_events event
    ON event.company_id=refund.company_id AND event.id=refund.financial_event_id
  WHERE event.id IS NULL OR event.status<>'POSTED'
    OR event.system_event_key<>'BACKOFFICE_CUSTOMER_REFUND'
    OR event.source_table<>'backoffice_sales_customer_refunds'
    OR event.source_id<>refund.id
  UNION ALL
  SELECT 'refund_operation_audit_coverage',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('invalidRows',count(*))
  FROM (SELECT refund.company_id,refund.id,
      (SELECT count(*) FROM public.backoffice_sales_customer_refund_operations operation
        WHERE operation.company_id=refund.company_id AND operation.refund_id=refund.id
          AND operation.operation_type=CASE refund.document_kind
            WHEN 'REFUND' THEN 'POST' ELSE 'REVERSE' END) operation_rows,
      (SELECT count(*) FROM public.backoffice_sales_customer_refund_audit audit
        WHERE audit.company_id=refund.company_id AND audit.refund_id=refund.id
          AND audit.action=CASE refund.document_kind
            WHEN 'REFUND' THEN 'POST' ELSE 'REVERSE' END) audit_rows
    FROM public.backoffice_sales_customer_refunds refund) coverage
  WHERE operation_rows<>1 OR audit_rows<>1
  UNION ALL
  SELECT 'refund_cashier_session_boundary',
    CASE WHEN position('cashier_sessions' IN lower(pg_get_functiondef(
      to_regprocedure('public.post_backoffice_sales_customer_refund(uuid,bigint,uuid,date,numeric,uuid,text,text,text)'))))=0
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN position('cashier_sessions' IN lower(pg_get_functiondef(
      to_regprocedure('public.post_backoffice_sales_customer_refund(uuid,bigint,uuid,date,numeric,uuid,text,text,text)'))))=0
      THEN 0 ELSE 1 END,
    jsonb_build_object('cashierSessionIndependent',position('cashier_sessions' IN lower(
      pg_get_functiondef(to_regprocedure('public.post_backoffice_sales_customer_refund(uuid,bigint,uuid,date,numeric,uuid,text,text,text)'))))=0)
  UNION ALL
  SELECT 'refund_runtime_inventory','INFO',0,jsonb_build_object(
    'refundRows',count(*) FILTER(WHERE document_kind='REFUND'),
    'reversalRows',count(*) FILTER(WHERE document_kind='REVERSAL'),
    'netRefunded',COALESCE(sum(CASE document_kind WHEN 'REFUND' THEN amount ELSE -amount END),0))
  FROM public.backoffice_sales_customer_refunds
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 0 WHEN 'BLOCKER' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,
  check_name;
