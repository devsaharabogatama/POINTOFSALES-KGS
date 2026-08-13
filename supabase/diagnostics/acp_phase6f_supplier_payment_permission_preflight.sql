-- ACP-6F preflight: Supplier Payment permission cutover readiness.
-- SAFETY: SELECT-only; aggregate metadata only. No Supplier bank identity,
-- payment reference, evidence URL, invoice number, or business payload returned.

WITH expected_relations(relation_name) AS (VALUES
  ('supplier_payment_documents'),('supplier_payment_allocations'),
  ('supplier_payment_audit')
), expected_routines(signature) AS (VALUES
  ('public.save_supplier_payment_draft(uuid,bigint,uuid,date,text,uuid,text,text,text,text,text,text,jsonb)'),
  ('public.validate_supplier_payment(uuid,bigint,uuid)'),
  ('public.cancel_supplier_payment(uuid,bigint,text)')
), mutation_routines AS (
  SELECT procedure.proname,
    pg_get_function_identity_arguments(procedure.oid) arguments,
    pg_get_functiondef(procedure.oid) definition
  FROM pg_proc procedure
  WHERE procedure.oid IN(
    to_regprocedure('public.save_supplier_payment_draft(uuid,bigint,uuid,date,text,uuid,text,text,text,text,text,text,jsonb)'),
    to_regprocedure('public.validate_supplier_payment(uuid,bigint,uuid)'),
    to_regprocedure('public.cancel_supplier_payment(uuid,bigint,text)'))
), relation_privileges AS (
  SELECT relation_name,
    has_table_privilege('authenticated',format('public.%I',relation_name),
      'SELECT') readable,
    has_table_privilege('authenticated',format('public.%I',relation_name),
      'INSERT,UPDATE,DELETE') writable
  FROM expected_relations
), checks AS (
  SELECT 'acp_phase6f_dependencies'::TEXT check_name,
    CASE WHEN count(ledger.version)=1 THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('expected',1,'missing',COALESCE(jsonb_agg(required.version)
      FILTER(WHERE ledger.version IS NULL),'[]'::JSONB)) details
  FROM (VALUES('20260813110000')) required(version)
  LEFT JOIN private.kgs_schema_migrations ledger USING(version)

  UNION ALL SELECT 'supplier_payment_permission_catalog_state',
    CASE WHEN count(*)=1 AND bool_and(enforcement_status='SHADOW')
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('rows',count(*),'statuses',COALESCE(
      jsonb_agg(enforcement_status),'[]'::JSONB),'capabilities',COALESCE(
      jsonb_agg(supported_capabilities),'[]'::JSONB))
  FROM public.access_permission_catalog
  WHERE permission_key='finance.supplier_payments'

  UNION ALL SELECT 'canonical_supplier_payment_schema_state',
    CASE WHEN count(*) FILTER(WHERE to_regclass(
      format('public.%I',relation_name)) IS NULL)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('expected',count(*),'missing',COALESCE(
      jsonb_agg(relation_name) FILTER(WHERE to_regclass(
        format('public.%I',relation_name)) IS NULL),'[]'::JSONB))
  FROM expected_relations

  UNION ALL SELECT 'canonical_supplier_payment_routine_state',
    CASE WHEN count(*) FILTER(WHERE to_regprocedure(signature) IS NULL)=0
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('expected',count(*),'missing',COALESCE(
      jsonb_agg(signature) FILTER(WHERE to_regprocedure(signature) IS NULL),
      '[]'::JSONB))
  FROM expected_routines

  UNION ALL SELECT 'supplier_payment_runtime_permission_hook_state','SETUP',
    jsonb_build_object('routine_rows',count(*),'hooked_rows',count(*) FILTER(
      WHERE definition ILIKE '%acp_require_permission_capability%'),
      'routine_names',COALESCE(jsonb_agg(proname ORDER BY proname),'[]'::JSONB))
  FROM mutation_routines

  UNION ALL SELECT 'canonical_supplier_payment_composed_read_state','SETUP',
    jsonb_build_object('rpc_exists',to_regprocedure(
      'public.get_finance_supplier_payments()') IS NOT NULL,
      'required_design',jsonb_build_array(
        'guard Backoffice list/detail with finance.supplier_payments VIEW',
        'return Payment, allocation, actor and immutable AP evidence only',
        'include narrow Supplier, payable-Invoice and eligible source-account references',
        'do not expose unrelated Invoice matching, Stock, drawer or Journal ledgers'))

  UNION ALL SELECT 'supplier_payment_direct_read_cutover_scope','REVIEW',
    jsonb_build_object('authenticated_read_relations',COALESCE(jsonb_agg(
      relation_name ORDER BY relation_name) FILTER(WHERE readable),'[]'::JSONB),
      'required_design',jsonb_build_array(
        'replace Backoffice dedicated-table reads with one VIEW-guarded composed RPC',
        'retain immutable allocation and validation proof for returned documents only',
        'revoke direct SELECT only after the active Backoffice consumer migrates'))
  FROM relation_privileges

  UNION ALL SELECT 'supplier_payment_direct_write_boundary',
    CASE WHEN count(*) FILTER(WHERE writable)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('direct_write_relations',COALESCE(jsonb_agg(
      relation_name ORDER BY relation_name) FILTER(WHERE writable),'[]'::JSONB))
  FROM relation_privileges

  UNION ALL SELECT 'supplier_payment_authority_split','REVIEW',
    jsonb_build_object(
      'view_roles',jsonb_build_array('COMPANY_OWNER','COMPANY_ADMIN','FINANCE','ACCOUNTING'),
      'operator_roles',jsonb_build_array('COMPANY_OWNER','COMPANY_ADMIN','FINANCE'),
      'required_design',jsonb_build_array(
        'CREATE_DRAFT and EDIT_DRAFT guard payment preparation',
        'POST guards atomic validation and immutable AP settlement effect',
        'CANCEL_FINAL compatibility applies only to Draft cancellation',
        'the current lifecycle has no separate review state; REVIEW or APPROVE must not invent one',
        'custom restriction may reduce but never widen Company or Finance role scope'))

  UNION ALL SELECT 'supplier_payment_final_cancellation_contract','REVIEW',
    jsonb_build_object('current_cancel_routine_rows',(SELECT count(*)
      FROM mutation_routines WHERE proname='cancel_supplier_payment'),
      'required_design',jsonb_build_array(
        'only Draft payment may be canceled through Supplier Payment',
        'VALIDATED payment is immutable and requires Finance journal reversal authority',
        'canceling a final payment must never leave a hidden Financial Event effect'))

  UNION ALL SELECT 'supplier_payment_shared_consumer_scope','REVIEW',
    jsonb_build_object('consumer_paths',jsonb_build_array(
      'Supplier Invoice exposes only VALIDATED payable-Invoice references',
      'Supplier master exposes only narrow active Supplier references',
      'Finance pending analysis and Journal consume immutable Financial Event snapshots',
      'Global Data Exchange export'),
      'required_design',jsonb_build_array(
        'each consumer authorizes its own permission key',
        'Supplier Payment never inherits Supplier Invoice or Supplier management authority',
        'client-supplied purpose never bypasses effective permission'))

  UNION ALL SELECT 'supplier_payment_reference_rpc_state',
    CASE WHEN to_regprocedure('public.get_supplier_payment_invoice_references()')
          IS NOT NULL
       AND to_regprocedure('public.get_supplier_payment_supplier_references()')
          IS NOT NULL THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object(
      'invoice_reference_rpc',to_regprocedure(
        'public.get_supplier_payment_invoice_references()') IS NOT NULL,
      'supplier_reference_rpc',to_regprocedure(
        'public.get_supplier_payment_supplier_references()') IS NOT NULL)

  UNION ALL SELECT 'supplier_payment_source_account_contract','REVIEW',
    jsonb_build_object('required_design',jsonb_build_array(
      'source account picker returns only active postable Company cash/bank accounts',
      'server revalidates explicit source account tenant, activity, posting and payment-method compatibility',
      'NULL source account keeps canonical MAIN_CASH or BANK fallback resolution',
      'Supplier Payment authority never grants Finance master-data mutation'))

  UNION ALL SELECT 'supplier_payment_export_contract','SETUP',
    jsonb_build_object('required_design',jsonb_build_array(
      'monthly Supplier Payment export requires finance.supplier_payments EXPORT',
      'export uses immutable document and allocation snapshots only',
      'no generic import exists for final Supplier Payment history'))

  UNION ALL SELECT 'duplicate_active_supplier_payment_identity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('duplicate_groups',count(*))
  FROM (SELECT company_id,payment_no FROM public.supplier_payment_documents
    GROUP BY company_id,payment_no HAVING count(*)>1) duplicate

  UNION ALL SELECT 'invalid_supplier_payment_lifecycle',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('row_count',count(*))
  FROM public.supplier_payment_documents document
  WHERE (document.status='DRAFT' AND (
      document.validated_by IS NOT NULL OR document.validated_at IS NOT NULL
      OR document.financial_event_id IS NOT NULL
      OR document.validation_idempotency_key IS NOT NULL))
    OR (document.status='VALIDATED' AND (
      document.validated_by IS NULL OR document.validated_at IS NULL
      OR document.validation_idempotency_key IS NULL
      OR document.financial_event_id IS NULL))
    OR (document.status='CANCELED' AND (
      document.canceled_by IS NULL OR document.canceled_at IS NULL
      OR btrim(COALESCE(document.cancel_reason,''))=''))

  UNION ALL SELECT 'canceled_supplier_payment_with_final_effect',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('document_count',count(*))
  FROM public.supplier_payment_documents document
  WHERE document.status='CANCELED'
    AND (document.financial_event_id IS NOT NULL
      OR document.validated_at IS NOT NULL
      OR document.validation_idempotency_key IS NOT NULL)

  UNION ALL SELECT 'supplier_payment_header_allocation_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('document_count',count(*))
  FROM public.supplier_payment_documents document
  WHERE document.total_amount<>COALESCE((SELECT sum(allocation.allocated_amount)
    FROM public.supplier_payment_allocations allocation
    WHERE allocation.company_id=document.company_id
      AND allocation.document_id=document.id),0)

  UNION ALL SELECT 'supplier_payment_invoice_balance_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('invoice_count',count(*))
  FROM public.supplier_invoice_documents invoice
  WHERE COALESCE((SELECT sum(allocation.allocated_amount)
    FROM public.supplier_payment_allocations allocation
    JOIN public.supplier_payment_documents payment
      ON payment.company_id=allocation.company_id
     AND payment.id=allocation.document_id
     AND payment.status='VALIDATED'
    WHERE allocation.company_id=invoice.company_id
      AND allocation.invoice_id=invoice.id),0)>invoice.grand_total+0.01

  UNION ALL SELECT 'supplier_payment_tenant_reference_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('orphan_or_cross_tenant_rows',count(*))
  FROM public.supplier_payment_documents document
  LEFT JOIN public.suppliers supplier ON supplier.company_id=document.company_id
    AND supplier.id=document.supplier_id
  WHERE supplier.id IS NULL OR EXISTS(SELECT 1
    FROM public.supplier_payment_allocations allocation
    LEFT JOIN public.supplier_invoice_documents invoice
      ON invoice.company_id=allocation.company_id
     AND invoice.id=allocation.invoice_id
    WHERE allocation.company_id=document.company_id
      AND allocation.document_id=document.id
      AND (invoice.id IS NULL OR invoice.supplier_id<>document.supplier_id))

  UNION ALL SELECT 'supplier_payment_source_account_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('row_count',count(*))
  FROM public.supplier_payment_documents document
  LEFT JOIN public.chart_of_accounts account
    ON account.company_id=document.company_id
   AND account.id=document.source_account_id
  WHERE document.source_account_id IS NOT NULL AND (
    account.id IS NULL OR NOT account.is_active OR NOT account.is_postable
    OR account.account_type<>'ASSET')

  UNION ALL SELECT 'supplier_payment_audit_coverage',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('document_count',count(*))
  FROM public.supplier_payment_documents document
  WHERE NOT EXISTS(SELECT 1 FROM public.supplier_payment_audit audit
    WHERE audit.company_id=document.company_id
      AND audit.document_id=document.id)

  UNION ALL SELECT 'validated_supplier_payment_event_coverage',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('document_count',count(*))
  FROM public.supplier_payment_documents document
  LEFT JOIN public.financial_events event
    ON event.company_id=document.company_id
   AND event.id=document.financial_event_id
  WHERE document.status='VALIDATED' AND (
    event.id IS NULL OR event.source_table<>'supplier_payment_documents'
    OR event.source_id<>document.id
    OR event.event_type<>'SUPPLIER_PAYMENT_VALIDATED'::public.event_type)

  UNION ALL SELECT 'supplier_payment_finance_hold_boundary','REVIEW',
    jsonb_build_object('hold_events',count(*) FILTER(WHERE event.status='HOLD'),
      'posted_events',count(*) FILTER(WHERE event.status='POSTED'),
      'required_design',jsonb_build_array(
        'ACP preserves current Financial Event status and never posts Journal',
        'validated AP settlement and source-account snapshots remain immutable',
        'queue, period, posting and reversal remain finance.journals_reports authority'))
  FROM public.financial_events event
  WHERE event.source_table='supplier_payment_documents'

  UNION ALL SELECT 'supplier_payment_override_tenant_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('row_count',count(*))
  FROM public.user_company_permission_overrides override_row
  LEFT JOIN public.company_memberships membership
    ON membership.company_id=override_row.company_id
   AND membership.user_id=override_row.user_id
   AND membership.status='ACTIVE'
  WHERE override_row.permission_key='finance.supplier_payments'
    AND membership.user_id IS NULL

  UNION ALL SELECT 'supplier_payment_runtime_inventory','INFO',
    jsonb_build_object(
      'companies',count(DISTINCT document.company_id),
      'documents',count(*),'drafts',count(*) FILTER(WHERE status='DRAFT'),
      'validated',count(*) FILTER(WHERE status='VALIDATED'),
      'canceled',count(*) FILTER(WHERE status='CANCELED'),
      'allocation_rows',(SELECT count(*)
        FROM public.supplier_payment_allocations),
      'documents_with_explicit_source_account',count(*) FILTER(
        WHERE source_account_id IS NOT NULL),
      'hold_events',(SELECT count(*) FROM public.financial_events
        WHERE source_table='supplier_payment_documents' AND status='HOLD'),
      'override_rows',(SELECT count(*)
        FROM public.user_company_permission_overrides
        WHERE permission_key='finance.supplier_payments'))
  FROM public.supplier_payment_documents document
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'BACKFILL' THEN 2
  WHEN 'REVIEW' THEN 3 WHEN 'SETUP' THEN 4 WHEN 'PASS' THEN 5 ELSE 6 END,
  check_name;
