-- ACP-6E preflight: Supplier Invoice permission cutover readiness.
-- SAFETY: SELECT-only; aggregate metadata only. No Supplier identity, invoice
-- number, evidence URL, or other business payload is returned.

WITH expected_relations(relation_name) AS (VALUES
  ('supplier_invoice_tolerance_policies'),
  ('supplier_invoice_documents'),('supplier_invoice_lines'),
  ('supplier_invoice_allocations'),('supplier_invoice_tolerance_results'),
  ('supplier_invoice_audit')
), expected_routines(signature) AS (VALUES
  ('public.save_supplier_invoice_tolerance_policy(uuid,bigint,uuid,numeric,numeric,numeric,numeric,date,boolean)'),
  ('public.save_supplier_invoice_draft(uuid,bigint,uuid,text,date,date,text,text,text,jsonb)'),
  ('public.validate_supplier_invoice(uuid,bigint,uuid)'),
  ('public.cancel_supplier_invoice(uuid,bigint,text)')
), mutation_routines AS (
  SELECT procedure.proname,pg_get_function_identity_arguments(procedure.oid) arguments,
    pg_get_functiondef(procedure.oid) definition
  FROM pg_proc procedure
  WHERE procedure.oid IN(
    to_regprocedure('public.save_supplier_invoice_tolerance_policy(uuid,bigint,uuid,numeric,numeric,numeric,numeric,date,boolean)'),
    to_regprocedure('public.save_supplier_invoice_draft(uuid,bigint,uuid,text,date,date,text,text,text,jsonb)'),
    to_regprocedure('public.validate_supplier_invoice(uuid,bigint,uuid)'),
    to_regprocedure('public.cancel_supplier_invoice(uuid,bigint,text)'))
), relation_privileges AS (
  SELECT relation_name,
    has_table_privilege('authenticated',format('public.%I',relation_name),
      'SELECT') readable,
    has_table_privilege('authenticated',format('public.%I',relation_name),
      'INSERT,UPDATE,DELETE') writable
  FROM expected_relations
), checks AS (
  SELECT 'acp_phase6e_dependencies'::TEXT check_name,
    CASE WHEN count(ledger.version)=2 THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('expected',2,'missing',COALESCE(jsonb_agg(required.version)
      FILTER(WHERE ledger.version IS NULL),'[]'::JSONB)) details
  FROM (VALUES('20260813090000'),('20260813100000')) required(version)
  LEFT JOIN private.kgs_schema_migrations ledger USING(version)

  UNION ALL SELECT 'supplier_invoice_permission_catalog_state',
    CASE WHEN count(*)=1 AND bool_and(enforcement_status='SHADOW')
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('rows',count(*),'statuses',COALESCE(
      jsonb_agg(enforcement_status),'[]'::JSONB),'capabilities',COALESCE(
      jsonb_agg(supported_capabilities),'[]'::JSONB))
  FROM public.access_permission_catalog
  WHERE permission_key='finance.supplier_invoices'

  UNION ALL SELECT 'canonical_supplier_invoice_schema_state',
    CASE WHEN count(*) FILTER(WHERE to_regclass(
      format('public.%I',relation_name)) IS NULL)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('expected',count(*),'missing',COALESCE(
      jsonb_agg(relation_name) FILTER(WHERE to_regclass(
        format('public.%I',relation_name)) IS NULL),'[]'::JSONB))
  FROM expected_relations

  UNION ALL SELECT 'canonical_supplier_invoice_routine_state',
    CASE WHEN count(*) FILTER(WHERE to_regprocedure(signature) IS NULL)=0
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('expected',count(*),'missing',COALESCE(
      jsonb_agg(signature) FILTER(WHERE to_regprocedure(signature) IS NULL),
      '[]'::JSONB))
  FROM expected_routines

  UNION ALL SELECT 'supplier_invoice_runtime_permission_hook_state','SETUP',
    jsonb_build_object('routine_rows',count(*),'hooked_rows',count(*) FILTER(
      WHERE definition ILIKE '%acp_require_permission_capability%'),
      'routine_names',COALESCE(jsonb_agg(proname ORDER BY proname),'[]'::JSONB))
  FROM mutation_routines

  UNION ALL SELECT 'canonical_supplier_invoice_composed_read_state','SETUP',
    jsonb_build_object('rpc_exists',to_regprocedure(
      'public.get_finance_supplier_invoices()') IS NOT NULL,
      'required_design',jsonb_build_array(
        'guard Backoffice list/detail with finance.supplier_invoices VIEW',
        'return Invoice, matching, tolerance, allocation and actor proof only',
        'include narrow Supplier, Product/UOM and Receipt references',
        'do not expose unrelated AP Payment, Stock, FIFO or Journal ledgers'))

  UNION ALL SELECT 'supplier_invoice_direct_read_cutover_scope','REVIEW',
    jsonb_build_object('authenticated_read_relations',COALESCE(jsonb_agg(
      relation_name ORDER BY relation_name) FILTER(WHERE readable),'[]'::JSONB),
      'required_design',jsonb_build_array(
        'replace Backoffice direct reads with one VIEW-guarded composed RPC',
        'retain document-scoped evidence for matching and validation',
        'revoke direct SELECT only after all active consumers migrate'))
  FROM relation_privileges

  UNION ALL SELECT 'supplier_invoice_direct_write_boundary',
    CASE WHEN count(*) FILTER(WHERE writable)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('direct_write_relations',COALESCE(jsonb_agg(
      relation_name ORDER BY relation_name) FILTER(WHERE writable),'[]'::JSONB))
  FROM relation_privileges

  UNION ALL SELECT 'supplier_invoice_authority_split','REVIEW',
    jsonb_build_object(
      'view_roles',jsonb_build_array('COMPANY_OWNER','COMPANY_ADMIN','FINANCE','ACCOUNTING'),
      'operator_roles',jsonb_build_array('COMPANY_OWNER','COMPANY_ADMIN','FINANCE'),
      'required_design',jsonb_build_array(
        'CREATE_DRAFT and EDIT_DRAFT guard draft matching input',
        'POST guards atomic validation and immutable AP Final effect',
        'draft or HOLD cancellation must not grant final reversal authority',
        'tolerance policy mutation needs an explicit supported capability decision',
        'custom restriction may reduce but never widen Company or Finance role scope'))

  UNION ALL SELECT 'supplier_invoice_tolerance_capability_decision','REVIEW',
    jsonb_build_object('current_capabilities',(SELECT supported_capabilities
      FROM public.access_permission_catalog
      WHERE permission_key='finance.supplier_invoices'),
      'required_decision',
        'map policy save to an existing protected capability or add MANAGE before enforcement; never infer it from VIEW',
      'tolerance_contract','NULL absolute thresholds mean unrestricted extra tolerance; percent remains optional Company/Supplier policy')

  UNION ALL SELECT 'supplier_invoice_shared_consumer_scope','REVIEW',
    jsonb_build_object('consumer_paths',jsonb_build_array(
      'Supplier Payment selects VALIDATED open Invoice',
      'Purchase Return preserves linked AP adjustment evidence',
      'Finance pending analysis and Journal use Financial Event snapshots',
      'Global Data Exchange export'),
      'required_design',jsonb_build_array(
        'each consumer authorizes its own permission key',
        'Supplier Payment must receive a narrow payable-Invoice reference RPC',
        'client-supplied purpose never bypasses Supplier Invoice authority'))

  UNION ALL SELECT 'duplicate_active_supplier_invoice_identity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('duplicate_groups',count(*))
  FROM (SELECT company_id,supplier_id,upper(regexp_replace(
      btrim(supplier_invoice_no),'\s+',' ','g')) identity
    FROM public.supplier_invoice_documents WHERE status<>'CANCELED'
    GROUP BY company_id,supplier_id,upper(regexp_replace(
      btrim(supplier_invoice_no),'\s+',' ','g')) HAVING count(*)>1) duplicate

  UNION ALL SELECT 'invalid_supplier_invoice_lifecycle',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('row_count',count(*))
  FROM public.supplier_invoice_documents document
  WHERE (document.status IN('DRAFT','HOLD') AND (
      document.validated_by IS NOT NULL OR document.validated_at IS NOT NULL
      OR document.financial_event_id IS NOT NULL))
    OR (document.status='VALIDATED' AND (
      document.validated_by IS NULL OR document.validated_at IS NULL
      OR document.validation_idempotency_key IS NULL
      OR document.financial_event_id IS NULL))
    OR (document.status='CANCELED' AND (
      document.canceled_by IS NULL OR document.canceled_at IS NULL
      OR btrim(COALESCE(document.cancel_reason,''))=''))

  UNION ALL SELECT 'supplier_invoice_header_line_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('document_count',count(*))
  FROM public.supplier_invoice_documents document
  WHERE document.line_count<>(SELECT count(*)
      FROM public.supplier_invoice_lines line
      WHERE line.company_id=document.company_id
        AND line.document_id=document.id)
    OR document.invoice_total_base_qty<>COALESCE((SELECT sum(line.invoice_base_qty)
      FROM public.supplier_invoice_lines line
      WHERE line.company_id=document.company_id
        AND line.document_id=document.id),0)
    OR document.allocated_total_base_qty<>COALESCE((SELECT sum(line.allocated_base_qty)
      FROM public.supplier_invoice_lines line
      WHERE line.company_id=document.company_id
        AND line.document_id=document.id),0)
    OR document.grand_total<>COALESCE((SELECT sum(line.line_total)
      FROM public.supplier_invoice_lines line
      WHERE line.company_id=document.company_id
        AND line.document_id=document.id),0)

  UNION ALL SELECT 'supplier_invoice_line_allocation_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('line_count',count(*))
  FROM public.supplier_invoice_lines line
  WHERE line.allocated_base_qty<>COALESCE((SELECT sum(allocation.allocated_base_qty)
    FROM public.supplier_invoice_allocations allocation
    WHERE allocation.company_id=line.company_id
      AND allocation.invoice_line_id=line.id),0)

  UNION ALL SELECT 'supplier_invoice_tenant_reference_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('orphan_or_cross_tenant_rows',count(*))
  FROM public.supplier_invoice_documents document
  LEFT JOIN public.suppliers supplier ON supplier.company_id=document.company_id
    AND supplier.id=document.supplier_id
  LEFT JOIN public.supplier_invoice_tolerance_policies policy
    ON policy.company_id=document.company_id
    AND policy.id=document.tolerance_policy_id
  WHERE supplier.id IS NULL OR (document.tolerance_policy_id IS NOT NULL
    AND policy.id IS NULL)

  UNION ALL SELECT 'validated_supplier_invoice_event_coverage',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('document_count',count(*))
  FROM public.supplier_invoice_documents document
  LEFT JOIN public.financial_events event
    ON event.company_id=document.company_id
   AND event.id=document.financial_event_id
  WHERE document.status='VALIDATED' AND (
    event.id IS NULL OR event.source_table<>'supplier_invoice_documents'
    OR event.source_id<>document.id
    OR event.event_type<>'SUPPLIER_INVOICE_VALIDATED'::public.event_type)

  UNION ALL SELECT 'supplier_invoice_finance_hold_boundary','REVIEW',
    jsonb_build_object('hold_events',count(*) FILTER(WHERE event.status='HOLD'),
      'posted_events',count(*) FILTER(WHERE event.status='POSTED'),
      'required_design',jsonb_build_array(
        'ACP preserves current Financial Event status and never posts Journal',
        'validated Invoice snapshots stay immutable',
        'queue, period, posting and reversal remain finance.journals_reports authority'))
  FROM public.financial_events event
  WHERE event.source_table='supplier_invoice_documents'

  UNION ALL SELECT 'supplier_invoice_tolerance_policy_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('row_count',count(*))
  FROM public.supplier_invoice_tolerance_policies policy
  WHERE policy.quantity_tolerance_percent NOT BETWEEN 0 AND 100
    OR policy.value_tolerance_percent NOT BETWEEN 0 AND 100
    OR policy.quantity_tolerance_base_qty<0 OR policy.value_tolerance_amount<0
    OR (policy.supplier_id IS NOT NULL AND NOT EXISTS(SELECT 1
      FROM public.suppliers supplier WHERE supplier.company_id=policy.company_id
        AND supplier.id=policy.supplier_id))

  UNION ALL SELECT 'supplier_invoice_override_tenant_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('row_count',count(*))
  FROM public.user_company_permission_overrides override_row
  LEFT JOIN public.company_memberships membership
    ON membership.company_id=override_row.company_id
   AND membership.user_id=override_row.user_id
   AND membership.status='ACTIVE'
  WHERE override_row.permission_key='finance.supplier_invoices'
    AND membership.user_id IS NULL

  UNION ALL SELECT 'supplier_invoice_runtime_inventory','INFO',
    jsonb_build_object(
      'companies',count(DISTINCT document.company_id),
      'documents',count(*),'drafts',count(*) FILTER(WHERE status='DRAFT'),
      'holds',count(*) FILTER(WHERE status='HOLD'),
      'validated',count(*) FILTER(WHERE status='VALIDATED'),
      'canceled',count(*) FILTER(WHERE status='CANCELED'),
      'lines',(SELECT count(*) FROM public.supplier_invoice_lines),
      'allocations',(SELECT count(*) FROM public.supplier_invoice_allocations),
      'tolerance_policies',(SELECT count(*)
        FROM public.supplier_invoice_tolerance_policies),
      'override_rows',(SELECT count(*)
        FROM public.user_company_permission_overrides
        WHERE permission_key='finance.supplier_invoices'))
  FROM public.supplier_invoice_documents document
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'BACKFILL' THEN 2
  WHEN 'REVIEW' THEN 3 WHEN 'SETUP' THEN 4 WHEN 'PASS' THEN 5 ELSE 6 END,
  check_name;
