-- ACP-6B preflight: Cash Deposit permission and channel split readiness.
-- SAFETY: SELECT-only; aggregate metadata only.

WITH expected_relations(relation_name) AS (VALUES
  ('cash_deposit_policies'),('cash_deposit_documents'),
  ('cash_deposit_session_lines'),('cash_deposit_audit')
), expected_routines(signature) AS (VALUES
  ('public.list_cash_deposit_eligible_sessions(uuid)'),
  ('public.save_cash_deposit_draft(uuid,bigint,uuid,text,text,numeric,timestamp with time zone,text,text,uuid,jsonb)'),
  ('public.submit_cash_deposit(uuid,bigint,uuid)'),
  ('public.review_cash_deposit(uuid,bigint,text,text,uuid)'),
  ('public.cancel_cash_deposit(uuid,bigint,text)')
), runtime_routines AS (
  SELECT procedure.proname,pg_get_functiondef(procedure.oid) definition
  FROM pg_proc procedure JOIN expected_routines expected
    ON procedure.oid=to_regprocedure(expected.signature)
), relation_privileges AS (
  SELECT relation_name,
    has_table_privilege('authenticated',format('public.%I',relation_name),
      'SELECT') readable,
    has_table_privilege('authenticated',format('public.%I',relation_name),
      'INSERT,UPDATE,DELETE') writable
  FROM expected_relations
), checks AS (
  SELECT 'acp_phase6a_dependency'::TEXT check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('ledger_rows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260813060000'

  UNION ALL SELECT 'cash_deposit_permission_catalog_state',
    CASE WHEN count(*)=1 AND bool_and(enforcement_status='SHADOW')
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('rows',count(*),'statuses',COALESCE(
      jsonb_agg(enforcement_status),'[]'::JSONB),
      'capabilities',COALESCE(jsonb_agg(supported_capabilities),'[]'::JSONB))
  FROM public.access_permission_catalog
  WHERE permission_key='finance.cash_deposits'

  UNION ALL SELECT 'canonical_cash_deposit_schema_state',
    CASE WHEN count(*) FILTER(WHERE to_regclass(
      format('public.%I',relation_name)) IS NULL)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('expected',count(*),'missing',COALESCE(
      jsonb_agg(relation_name) FILTER(WHERE to_regclass(
        format('public.%I',relation_name)) IS NULL),'[]'::JSONB))
  FROM expected_relations

  UNION ALL SELECT 'canonical_cash_deposit_routine_state',
    CASE WHEN count(*) FILTER(WHERE to_regprocedure(signature) IS NULL)=0
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('expected',count(*),'missing',COALESCE(
      jsonb_agg(signature) FILTER(WHERE to_regprocedure(signature) IS NULL),
      '[]'::JSONB))
  FROM expected_routines

  UNION ALL SELECT 'cash_deposit_runtime_permission_hook_state','SETUP',
    jsonb_build_object('routine_rows',count(*),'hooked_rows',count(*) FILTER(
      WHERE definition ILIKE '%finance.cash_deposits%'
        AND definition ILIKE '%acp_require_permission_capability%'))
  FROM runtime_routines

  UNION ALL SELECT 'canonical_cash_deposit_composed_read_state','SETUP',
    jsonb_build_object('rpc_exists',to_regprocedure(
      'public.get_finance_cash_deposits(text)') IS NOT NULL,
      'required_design',jsonb_build_array(
        'guard Backoffice list/detail with finance.cash_deposits VIEW',
        'return Deposit, Session allocation, Store and actor labels only',
        'preserve a separate Cashier-owned eligible-session workspace',
        'do not expose unrelated drawer, variance, journal or account ledgers'))

  UNION ALL SELECT 'cash_deposit_direct_read_cutover_scope','REVIEW',
    jsonb_build_object('authenticated_read_relations',COALESCE(
      jsonb_agg(relation_name ORDER BY relation_name) FILTER(WHERE readable),
      '[]'::JSONB),'required_design',jsonb_build_array(
        'replace Backoffice Deposit table reads with one VIEW-guarded RPC',
        'keep PWA Draft/Submit reads inside Cashier-specific RPCs',
        'revoke direct SELECT only after Backoffice, PWA and Variance consumers migrate'))
  FROM relation_privileges

  UNION ALL SELECT 'cash_deposit_channel_authority_split','REVIEW',
    jsonb_build_object(
      'cashier_routines',jsonb_build_array('list_cash_deposit_eligible_sessions',
        'save_cash_deposit_draft','submit_cash_deposit','cancel_cash_deposit'),
      'management_routines',jsonb_build_array('review_cash_deposit'),
      'required_design',jsonb_build_array(
        'Cashier prepares only eligible CLOSED sessions within Store scope',
        'Backoffice VIEW never grants Cashier session or Deposit creation authority',
        'APPROVE/REJECT remains Finance or Company approver maker-checker action',
        'custom permission may restrict but never widen Company or Store scope'))

  UNION ALL SELECT 'cash_deposit_variance_consumer_scope','REVIEW',
    jsonb_build_object('required_design',jsonb_build_array(
      'Deposit Variance uses its own finance.deposit_variances VIEW authority',
      'Variance receives only linked Deposit number, amount, Store and status',
      'Cash Deposit restriction must not grant or break Variance resolution',
      'client-supplied purpose never bypasses either permission key'))

  UNION ALL SELECT 'cash_deposit_policy_authority_decision','REVIEW',
    jsonb_build_object('current_runtime','Company/Store proof policy is system-provisioned and has no public save RPC',
      'required_design',jsonb_build_array(
        'do not infer policy mutation from Cash Deposit VIEW or APPROVE',
        'future proof-policy mutation belongs to guarded module settings or explicit MANAGE capability',
        'feature entitlement remains Super Admin authority'))

  UNION ALL SELECT 'cash_deposit_direct_write_boundary',
    CASE WHEN count(*) FILTER(WHERE writable)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('direct_write_relations',COALESCE(
      jsonb_agg(relation_name ORDER BY relation_name) FILTER(WHERE writable),
      '[]'::JSONB))
  FROM relation_privileges

  UNION ALL SELECT 'invalid_cash_deposit_lifecycle',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('row_count',count(*))
  FROM public.cash_deposit_documents document WHERE
    (document.status='DRAFT' AND (document.submitted_at IS NOT NULL
      OR document.approved_at IS NOT NULL OR document.rejected_at IS NOT NULL
      OR document.canceled_at IS NOT NULL OR document.financial_event_id IS NOT NULL))
    OR (document.status='SUBMITTED' AND (document.submitted_at IS NULL
      OR document.submitted_by IS NULL OR document.financial_event_id IS NOT NULL))
    OR (document.status='APPROVED' AND (document.approved_at IS NULL
      OR document.approved_by IS NULL OR document.financial_event_id IS NULL))
    OR (document.status='REJECTED' AND (document.rejected_at IS NULL
      OR document.rejected_by IS NULL OR NULLIF(btrim(document.rejection_reason),'') IS NULL
      OR document.financial_event_id IS NOT NULL))
    OR (document.status='CANCELED' AND (document.canceled_at IS NULL
      OR document.canceled_by IS NULL OR document.financial_event_id IS NOT NULL))

  UNION ALL SELECT 'cash_deposit_header_line_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('document_count',count(*)) FROM (
      SELECT document.id FROM public.cash_deposit_documents document
      LEFT JOIN public.cash_deposit_session_lines line
        ON line.company_id=document.company_id
       AND line.deposit_document_id=document.id
      GROUP BY document.id,document.total_expected_deposit
      HAVING abs(document.total_expected_deposit-
        COALESCE(sum(line.expected_deposit_amount),0))>0.0001
    ) mismatch

  UNION ALL SELECT 'cash_deposit_session_allocation_lifecycle',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('row_count',count(*))
  FROM public.cash_deposit_session_lines line
  JOIN public.cash_deposit_documents document
    ON document.company_id=line.company_id
   AND document.id=line.deposit_document_id
  WHERE (document.status='SUBMITTED' AND line.allocation_status<>'LOCKED')
     OR (document.status='APPROVED' AND line.allocation_status<>'POSTED')
     OR (document.status IN('REJECTED','CANCELED')
       AND line.allocation_status<>'RELEASED')
     OR (document.status='DRAFT' AND line.allocation_status<>'DRAFT')

  UNION ALL SELECT 'duplicate_locked_or_posted_cashier_session',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('duplicate_groups',count(*)) FROM (
      SELECT company_id,cashier_session_id
      FROM public.cash_deposit_session_lines
      WHERE allocation_status IN('LOCKED','POSTED')
      GROUP BY company_id,cashier_session_id HAVING count(*)>1
    ) duplicate_groups

  UNION ALL SELECT 'cash_deposit_tenant_reference_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('orphan_or_cross_tenant_rows',count(*))
  FROM public.cash_deposit_session_lines line
  LEFT JOIN public.cash_deposit_documents document
    ON document.company_id=line.company_id AND document.id=line.deposit_document_id
  LEFT JOIN public.cashier_sessions session
    ON session.company_id=line.company_id AND session.store_id=line.store_id
   AND session.id=line.cashier_session_id
  WHERE document.id IS NULL OR session.id IS NULL
    OR document.store_id<>line.store_id

  UNION ALL SELECT 'approved_cash_deposit_financial_event_coverage',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('document_count',count(*))
  FROM public.cash_deposit_documents document
  LEFT JOIN public.financial_events event
    ON event.company_id=document.company_id
   AND event.id=document.financial_event_id
   AND event.source_table='cash_deposit_documents'
   AND event.source_id=document.id
   AND event.event_type='BANK_DEPOSIT'
  WHERE document.status='APPROVED'
    AND (event.id IS NULL OR event.status<>'HOLD')

  UNION ALL SELECT 'nonapproved_cash_deposit_zero_final_effect',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('document_count',count(*))
  FROM public.cash_deposit_documents document
  WHERE document.status<>'APPROVED' AND (document.financial_event_id IS NOT NULL
    OR EXISTS(SELECT 1 FROM public.deposit_variance_exceptions exception
      WHERE exception.company_id=document.company_id
        AND exception.cash_deposit_document_id=document.id))

  UNION ALL SELECT 'approved_cash_deposit_variance_exception_coverage',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('document_count',count(*)) FROM (
      SELECT document.id,document.deposit_variance,count(exception.id) rows
      FROM public.cash_deposit_documents document
      LEFT JOIN public.deposit_variance_exceptions exception
        ON exception.company_id=document.company_id
       AND exception.cash_deposit_document_id=document.id
      WHERE document.status='APPROVED'
      GROUP BY document.id,document.deposit_variance
      HAVING (document.deposit_variance=0 AND count(exception.id)<>0)
        OR (document.deposit_variance<>0 AND count(exception.id)<>1)
    ) mismatch

  UNION ALL SELECT 'cash_deposit_runtime_inventory','INFO',
    jsonb_build_object(
      'documents',(SELECT count(*) FROM public.cash_deposit_documents),
      'drafts',(SELECT count(*) FROM public.cash_deposit_documents WHERE status='DRAFT'),
      'submitted',(SELECT count(*) FROM public.cash_deposit_documents WHERE status='SUBMITTED'),
      'approved',(SELECT count(*) FROM public.cash_deposit_documents WHERE status='APPROVED'),
      'rejected',(SELECT count(*) FROM public.cash_deposit_documents WHERE status='REJECTED'),
      'canceled',(SELECT count(*) FROM public.cash_deposit_documents WHERE status='CANCELED'),
      'session_lines',(SELECT count(*) FROM public.cash_deposit_session_lines),
      'variance_documents',(SELECT count(*) FROM public.cash_deposit_documents
        WHERE status='APPROVED' AND deposit_variance<>0),
      'hold_events',(SELECT count(*) FROM public.financial_events
        WHERE event_type='BANK_DEPOSIT' AND status='HOLD'),
      'override_rows',(SELECT count(*) FROM public.user_company_permission_overrides
        WHERE permission_key='finance.cash_deposits'))
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'BACKFILL' THEN 2
  WHEN 'REVIEW' THEN 3 WHEN 'SETUP' THEN 4 WHEN 'PASS' THEN 5 ELSE 6 END,
  check_name;

