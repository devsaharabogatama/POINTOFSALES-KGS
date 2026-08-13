-- ACP-6E postflight: Supplier Invoice capability and browser boundary closure.
-- SAFETY: SELECT-only; aggregate metadata only.

WITH expected_relations(relation_name) AS (VALUES
  ('supplier_invoice_tolerance_policies'),('supplier_invoice_documents'),
  ('supplier_invoice_lines'),('supplier_invoice_allocations'),
  ('supplier_invoice_tolerance_results'),('supplier_invoice_audit')
), expected_routines(signature) AS (VALUES
  ('public.get_finance_supplier_invoices()'),
  ('public.get_supplier_payment_invoice_references()'),
  ('public.get_purchase_return_invoice_references()'),
  ('public.export_finance_supplier_invoices(timestamp with time zone,timestamp with time zone)'),
  ('public.save_supplier_invoice_tolerance_policy(uuid,bigint,uuid,numeric,numeric,numeric,numeric,date,boolean)'),
  ('public.save_supplier_invoice_draft(uuid,bigint,uuid,text,date,date,text,text,text,jsonb)'),
  ('public.validate_supplier_invoice(uuid,bigint,uuid)'),
  ('public.cancel_supplier_invoice(uuid,bigint,text)')
), mutation_routines AS (
  SELECT procedure.proname,pg_get_functiondef(procedure.oid) definition
  FROM pg_proc procedure WHERE procedure.oid IN(
    to_regprocedure('public.save_supplier_invoice_tolerance_policy(uuid,bigint,uuid,numeric,numeric,numeric,numeric,date,boolean)'),
    to_regprocedure('public.save_supplier_invoice_draft(uuid,bigint,uuid,text,date,date,text,text,text,jsonb)'),
    to_regprocedure('public.validate_supplier_invoice(uuid,bigint,uuid)'),
    to_regprocedure('public.cancel_supplier_invoice(uuid,bigint,text)'))
), checks AS (
  SELECT 'migration_ledger'::TEXT check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(1-count(*)) violation_rows,jsonb_build_object('ledger_rows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260813110000'

  UNION ALL SELECT 'supplier_invoice_permission_enforced',
    CASE WHEN count(*)=1 AND bool_and(enforcement_status='ENFORCED')
      THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE enforcement_status<>'ENFORCED'),
    jsonb_build_object('rows',count(*),'statuses',COALESCE(
      jsonb_agg(enforcement_status),'[]'::JSONB))
  FROM public.access_permission_catalog
  WHERE permission_key='finance.supplier_invoices'

  UNION ALL SELECT 'required_supplier_invoice_routines',
    CASE WHEN count(*) FILTER(WHERE to_regprocedure(signature) IS NULL)=0
      THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE to_regprocedure(signature) IS NULL),
    jsonb_build_object('expected',count(*),'missing',COALESCE(jsonb_agg(signature)
      FILTER(WHERE to_regprocedure(signature) IS NULL),'[]'::JSONB))
  FROM expected_routines

  UNION ALL SELECT 'supplier_invoice_runtime_permission_hooks',
    CASE WHEN count(*)=4 AND count(*) FILTER(WHERE
      definition ILIKE '%acp_require_permission_capability%')=4
      THEN 'PASS' ELSE 'FAIL' END,
    4-count(*) FILTER(WHERE definition ILIKE
      '%acp_require_permission_capability%'),
    jsonb_build_object('routine_rows',count(*),'hooked_rows',count(*) FILTER(
      WHERE definition ILIKE '%acp_require_permission_capability%'))
  FROM mutation_routines

  UNION ALL SELECT 'browser_supplier_invoice_table_boundary',
    CASE WHEN count(*) FILTER(WHERE readable OR writable)=0
      THEN 'PASS' ELSE 'FAIL' END,count(*) FILTER(WHERE readable OR writable),
    jsonb_build_object('readable',COALESCE(jsonb_agg(relation_name)
      FILTER(WHERE readable),'[]'::JSONB),'writable',COALESCE(
      jsonb_agg(relation_name) FILTER(WHERE writable),'[]'::JSONB))
  FROM (SELECT relation_name,
    has_table_privilege('authenticated',format('public.%I',relation_name),
      'SELECT') readable,
    has_table_privilege('authenticated',format('public.%I',relation_name),
      'INSERT,UPDATE,DELETE') writable FROM expected_relations) privilege_state

  UNION ALL SELECT 'private_supplier_invoice_core_boundary',
    CASE WHEN count(*)=4 AND count(*) FILTER(WHERE
      has_function_privilege('authenticated',procedure.oid,'EXECUTE')
      OR has_function_privilege('anon',procedure.oid,'EXECUTE'))=0
      THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE has_function_privilege(
      'authenticated',procedure.oid,'EXECUTE')
      OR has_function_privilege('anon',procedure.oid,'EXECUTE')),
    jsonb_build_object('core_rows',count(*))
  FROM pg_proc procedure WHERE procedure.pronamespace='private'::regnamespace
    AND procedure.proname LIKE 'acp6e_%_core'

  UNION ALL SELECT 'supplier_invoice_header_line_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('document_count',count(*))
  FROM public.supplier_invoice_documents document
  WHERE document.line_count<>(SELECT count(*)
      FROM public.supplier_invoice_lines line
      WHERE line.company_id=document.company_id AND line.document_id=document.id)
    OR document.grand_total<>COALESCE((SELECT sum(line.line_total)
      FROM public.supplier_invoice_lines line
      WHERE line.company_id=document.company_id AND line.document_id=document.id),0)

  UNION ALL SELECT 'supplier_invoice_line_allocation_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('line_count',count(*))
  FROM public.supplier_invoice_lines line
  WHERE line.allocated_base_qty<>COALESCE((SELECT sum(allocation.allocated_base_qty)
    FROM public.supplier_invoice_allocations allocation
    WHERE allocation.company_id=line.company_id
      AND allocation.invoice_line_id=line.id),0)

  UNION ALL SELECT 'validated_supplier_invoice_financial_event_coverage',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('document_count',count(*))
  FROM public.supplier_invoice_documents document
  LEFT JOIN public.financial_events event
    ON event.company_id=document.company_id AND event.id=document.financial_event_id
  WHERE document.status='VALIDATED' AND (event.id IS NULL
    OR event.source_table<>'supplier_invoice_documents'
    OR event.source_id<>document.id
    OR event.event_type<>'SUPPLIER_INVOICE_VALIDATED'::public.event_type)

  UNION ALL SELECT 'supplier_invoice_finance_hold_preserved',
    CASE WHEN count(*) FILTER(WHERE status<>'HOLD')=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE status<>'HOLD'),
    jsonb_build_object('hold_events',count(*) FILTER(WHERE status='HOLD'))
  FROM public.financial_events WHERE source_table='supplier_invoice_documents'

  UNION ALL SELECT 'supplier_invoice_runtime_inventory','INFO',0,
    jsonb_build_object(
      'documents',(SELECT count(*) FROM public.supplier_invoice_documents),
      'validated',(SELECT count(*) FROM public.supplier_invoice_documents
        WHERE status='VALIDATED'),
      'holds',(SELECT count(*) FROM public.supplier_invoice_documents
        WHERE status='HOLD'),
      'lines',(SELECT count(*) FROM public.supplier_invoice_lines),
      'allocations',(SELECT count(*) FROM public.supplier_invoice_allocations),
      'override_rows',(SELECT count(*)
        FROM public.user_company_permission_overrides
        WHERE permission_key='finance.supplier_invoices'))
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
