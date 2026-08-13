-- ACP-6A preflight: Expense lifecycle effective-permission readiness.
-- SAFETY: SELECT-only; aggregate metadata only.

WITH expected_relations(relation_name) AS (VALUES
  ('expense_categories'),('expense_approval_policies'),('expense_documents'),
  ('expense_disbursements'),('expense_settlements'),('expense_returns'),
  ('expense_settlement_requests'),
  ('expense_additional_disbursement_requests'),('expense_audit'),
  ('cash_drawer_movements'),('cash_in_documents')
), expected_routines(routine_name) AS (VALUES
  ('save_expense_category'),('save_expense_approval_policy'),
  ('save_expense_draft'),('submit_expense_request'),
  ('review_expense_request'),('cancel_expense_request'),
  ('disburse_expense'),('save_expense_settlement'),
  ('review_expense_settlement'),('return_expense_funds'),
  ('request_additional_expense_disbursement'),
  ('review_additional_expense_disbursement'),
  ('disburse_additional_expense')
), routine_state AS (
  SELECT expected.routine_name,procedure.oid,
    CASE WHEN procedure.oid IS NULL THEN NULL
      ELSE pg_get_functiondef(procedure.oid) END definition
  FROM expected_routines expected LEFT JOIN pg_proc procedure
    ON procedure.pronamespace='public'::regnamespace
   AND procedure.proname=expected.routine_name
), relation_privileges AS (
  SELECT relation_name,
    has_table_privilege('authenticated',format('public.%I',relation_name),
      'SELECT') readable,
    has_table_privilege('authenticated',format('public.%I',relation_name),
      'INSERT,UPDATE,DELETE') writable
  FROM expected_relations
), checks AS (
  SELECT 'acp_phase5h_dependency'::TEXT check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('ledger_rows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260813050000'

  UNION ALL SELECT 'expense_permission_catalog_state',
    CASE WHEN count(*)=1 AND bool_and(enforcement_status='SHADOW')
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('rows',count(*),'statuses',COALESCE(
      jsonb_agg(enforcement_status),'[]'::JSONB),'capabilities',COALESCE(
      jsonb_agg(supported_capabilities),'[]'::JSONB))
  FROM public.access_permission_catalog WHERE permission_key='finance.expenses'

  UNION ALL SELECT 'canonical_expense_schema_state','INFO',
    jsonb_build_object('missing',COALESCE(jsonb_agg(relation_name)
      FILTER(WHERE to_regclass(format('public.%I',relation_name)) IS NULL),
      '[]'::JSONB),'expected',count(*))
  FROM expected_relations

  UNION ALL SELECT 'canonical_expense_routine_state',
    CASE WHEN count(*) FILTER(WHERE oid IS NULL)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('missing',COALESCE(jsonb_agg(DISTINCT routine_name)
      FILTER(WHERE oid IS NULL),'[]'::JSONB),'expected_names',
      (SELECT count(*) FROM expected_routines),
      'signature_rows',count(oid))
  FROM routine_state

  UNION ALL SELECT 'expense_runtime_permission_hook_state','SETUP',
    jsonb_build_object('routine_names',COALESCE(jsonb_agg(routine_name ORDER BY routine_name)
      FILTER(WHERE definition ILIKE '%acp_require_permission_capability%'),
      '[]'::JSONB),'routine_rows',count(*) FILTER(WHERE oid IS NOT NULL),
      'hooked_rows',count(*) FILTER(WHERE definition ILIKE
        '%acp_require_permission_capability%'))
  FROM routine_state

  UNION ALL SELECT 'expense_direct_read_cutover_scope','REVIEW',
    jsonb_build_object('authenticated_read_relations',COALESCE(
      jsonb_agg(relation_name ORDER BY relation_name) FILTER(WHERE readable),
      '[]'::JSONB),'required_design',jsonb_build_array(
      'replace Backoffice Expense reads with one VIEW-guarded composed RPC',
      'replace PWA operational reads with open-session scoped RPCs',
      'revoke direct SELECT only after every active consumer migrates'))
  FROM relation_privileges

  UNION ALL SELECT 'expense_direct_write_boundary',
    CASE WHEN count(*) FILTER(WHERE writable)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('direct_write_relations',COALESCE(
      jsonb_agg(relation_name ORDER BY relation_name) FILTER(WHERE writable),
      '[]'::JSONB)) FROM relation_privileges

  UNION ALL SELECT 'expense_channel_authority_split','REVIEW',
    jsonb_build_object('required_design',jsonb_build_array(
      'Cashier create/submit/disburse/settle/return remains open-session and Store scoped',
      'Backoffice VIEW never grants Cashier drawer authority',
      'approval, non-Cash disbursement, settlement review and additional approval use distinct capabilities',
      'custom permission may restrict but never widen Company, Store, Session or payment scope'),
      'maker_roles',jsonb_build_array('CASHIER','STORE_MANAGER','FINANCE',
        'COMPANY_ADMIN','COMPANY_OWNER'),
      'approval_roles',jsonb_build_array('STORE_MANAGER','FINANCE',
        'COMPANY_ADMIN','COMPANY_OWNER'))

  UNION ALL SELECT 'expense_master_authority_decision','REVIEW',
    jsonb_build_object('required_design',jsonb_build_array(
      'Expense Category and approval policy mutation require finance.expenses MANAGE',
      'Store Manager policy mutation remains Store-scoped',
      'feature entitlement remains Super Admin authority',
      'category/account snapshots on history remain immutable'))

  UNION ALL SELECT 'expense_pwa_direct_consumer_scope','REVIEW',
    jsonb_build_object('current_direct_reads',jsonb_build_array(
      'expense_documents','expense_settlement_requests',
      'expense_additional_disbursement_requests','expense_categories'),
      'required_design',jsonb_build_array(
      'approved Cash disbursement list requires own open Session and Store',
      'outstanding and additional requests expose only actionable Store rows',
      'client-supplied purpose never bypasses session or effective authority'))

  UNION ALL SELECT 'invalid_expense_totals',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('row_count',count(*))
  FROM public.expense_documents document WHERE document.requested_amount<=0
    OR document.disbursed_amount<0 OR document.actual_expense_amount<0
    OR document.returned_amount<0 OR document.outstanding_amount<0
    OR abs(document.outstanding_amount-(document.disbursed_amount
      -document.actual_expense_amount-document.returned_amount))>0.0001

  UNION ALL SELECT 'invalid_expense_lifecycle_shape',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('row_count',count(*))
  FROM public.expense_documents document WHERE
    (document.status='SUBMITTED' AND document.submitted_at IS NULL)
    OR (document.status='APPROVED' AND (document.approved_at IS NULL
      OR document.approved_by IS NULL))
    OR (document.status='REJECTED' AND (document.rejected_at IS NULL
      OR document.rejected_by IS NULL))
    OR (document.status='CANCELED' AND (document.canceled_at IS NULL
      OR document.canceled_by IS NULL))
    OR (document.status IN('DISBURSED','PARTIALLY_SETTLED','SETTLED',
      'SETTLED_NO_EXPENSE') AND document.disbursed_amount<=0)

  UNION ALL SELECT 'duplicate_open_expense_settlement_request',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('duplicate_groups',count(*)) FROM (
      SELECT company_id,document_id FROM public.expense_settlement_requests
      WHERE status='SUBMITTED' GROUP BY company_id,document_id HAVING count(*)>1
    ) duplicate_groups

  UNION ALL SELECT 'duplicate_open_additional_disbursement_request',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('duplicate_groups',count(*)) FROM (
      SELECT company_id,document_id
      FROM public.expense_additional_disbursement_requests
      WHERE status IN('SUBMITTED','APPROVED')
      GROUP BY company_id,document_id HAVING count(*)>1
    ) duplicate_groups

  UNION ALL SELECT 'cash_disbursement_drawer_coverage',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('row_count',count(*))
  FROM public.expense_disbursements disbursement
  LEFT JOIN public.cash_drawer_movements movement
    ON movement.company_id=disbursement.company_id
   AND movement.source_table='expense_disbursements'
   AND movement.source_id=disbursement.id AND movement.direction='OUT'
  WHERE disbursement.payment_method_type_snapshot='CASH' AND movement.id IS NULL

  UNION ALL SELECT 'cash_return_drawer_coverage',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('row_count',count(*))
  FROM public.expense_returns expense_return
  LEFT JOIN public.cash_drawer_movements movement
    ON movement.company_id=expense_return.company_id
   AND movement.source_table='expense_returns'
   AND movement.source_id=expense_return.id AND movement.direction='IN'
  WHERE expense_return.payment_method_type_snapshot='CASH' AND movement.id IS NULL

  UNION ALL SELECT 'noncash_expense_drawer_effect',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('row_count',count(*)) FROM (
      SELECT disbursement.id FROM public.expense_disbursements disbursement
      JOIN public.cash_drawer_movements movement
        ON movement.company_id=disbursement.company_id
       AND movement.source_id=disbursement.id
       AND movement.source_table='expense_disbursements'
      WHERE disbursement.payment_method_type_snapshot<>'CASH'
      UNION ALL
      SELECT expense_return.id FROM public.expense_returns expense_return
      JOIN public.cash_drawer_movements movement
        ON movement.company_id=expense_return.company_id
       AND movement.source_id=expense_return.id
       AND movement.source_table='expense_returns'
      WHERE expense_return.payment_method_type_snapshot<>'CASH'
    ) invalid_rows

  UNION ALL SELECT 'expense_tenant_reference_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('orphan_or_cross_tenant_rows',count(*))
  FROM public.expense_documents document
  LEFT JOIN public.stores store ON store.company_id=document.company_id
    AND store.id=document.store_id
  LEFT JOIN public.expense_categories category
    ON category.company_id=document.company_id AND category.id=document.category_id
  WHERE store.id IS NULL OR category.id IS NULL

  UNION ALL SELECT 'expense_finance_hold_boundary','REVIEW',
    jsonb_build_object('required_design',jsonb_build_array(
      'ACP does not release Finance HOLD or create Journal entries',
      'disbursement, settlement, return and additional events retain source snapshots',
      'reversal remains Finance journal authority'),
      'hold_events',(SELECT count(*) FROM public.financial_events
        WHERE status='HOLD' AND event_type::TEXT LIKE 'EXPENSE%'))

  UNION ALL SELECT 'expense_runtime_inventory','INFO',
    jsonb_build_object('documents',(SELECT count(*) FROM public.expense_documents),
      'drafts',(SELECT count(*) FROM public.expense_documents WHERE status='DRAFT'),
      'submitted',(SELECT count(*) FROM public.expense_documents WHERE status='SUBMITTED'),
      'approved',(SELECT count(*) FROM public.expense_documents WHERE status='APPROVED'),
      'open_outstanding',(SELECT count(*) FROM public.expense_documents
        WHERE outstanding_amount>0),
      'disbursement_rows',(SELECT count(*) FROM public.expense_disbursements),
      'settlement_request_rows',(SELECT count(*) FROM public.expense_settlement_requests),
      'additional_request_rows',(SELECT count(*)
        FROM public.expense_additional_disbursement_requests),
      'return_rows',(SELECT count(*) FROM public.expense_returns),
      'active_feature_companies',(SELECT count(DISTINCT company_id)
        FROM public.company_features WHERE feature_code='expense_enabled'
          AND is_enabled))
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'REVIEW' THEN 2
  WHEN 'SETUP' THEN 3 WHEN 'PASS' THEN 4 ELSE 5 END,check_name;
