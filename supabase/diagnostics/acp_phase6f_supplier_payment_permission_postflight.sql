-- ACP-6F postflight: Supplier Payment permission and browser boundary closure.
-- SAFETY: SELECT-only; aggregate metadata only.

WITH expected_relations(relation_name) AS (VALUES
  ('supplier_payment_documents'),('supplier_payment_allocations'),
  ('supplier_payment_audit')
), expected_routines(signature) AS (VALUES
  ('public.get_finance_supplier_payments()'),
  ('public.export_finance_supplier_payments(timestamp with time zone,timestamp with time zone)'),
  ('public.save_supplier_payment_draft(uuid,bigint,uuid,date,text,uuid,text,text,text,text,text,text,jsonb)'),
  ('public.validate_supplier_payment(uuid,bigint,uuid)'),
  ('public.cancel_supplier_payment(uuid,bigint,text)')
), mutation_routines AS (
  SELECT procedure.proname,pg_get_functiondef(procedure.oid) definition
  FROM pg_proc procedure WHERE procedure.oid IN(
    to_regprocedure('public.save_supplier_payment_draft(uuid,bigint,uuid,date,text,uuid,text,text,text,text,text,text,jsonb)'),
    to_regprocedure('public.validate_supplier_payment(uuid,bigint,uuid)'),
    to_regprocedure('public.cancel_supplier_payment(uuid,bigint,text)'))
), checks AS (
  SELECT 'migration_ledger'::TEXT check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(1-count(*)) violation_rows,jsonb_build_object('ledger_rows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260813120000'

  UNION ALL SELECT 'supplier_payment_permission_enforced',
    CASE WHEN count(*)=1 AND bool_and(enforcement_status='ENFORCED')
      THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE enforcement_status<>'ENFORCED'),
    jsonb_build_object('rows',count(*),'statuses',COALESCE(
      jsonb_agg(enforcement_status),'[]'::JSONB))
  FROM public.access_permission_catalog
  WHERE permission_key='finance.supplier_payments'

  UNION ALL SELECT 'required_supplier_payment_routines',
    CASE WHEN count(*) FILTER(WHERE to_regprocedure(signature) IS NULL)=0
      THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE to_regprocedure(signature) IS NULL),
    jsonb_build_object('expected',count(*),'missing',COALESCE(jsonb_agg(signature)
      FILTER(WHERE to_regprocedure(signature) IS NULL),'[]'::JSONB))
  FROM expected_routines

  UNION ALL SELECT 'supplier_payment_runtime_permission_hooks',
    CASE WHEN count(*)=3 AND count(*) FILTER(WHERE
      definition ILIKE '%acp_require_permission_capability%')=3
      THEN 'PASS' ELSE 'FAIL' END,
    3-count(*) FILTER(WHERE definition ILIKE
      '%acp_require_permission_capability%'),
    jsonb_build_object('routine_rows',count(*),'hooked_rows',count(*) FILTER(
      WHERE definition ILIKE '%acp_require_permission_capability%'))
  FROM mutation_routines

  UNION ALL SELECT 'draft_only_supplier_payment_cancel_guard',
    CASE WHEN count(*)=1 AND bool_and(definition ILIKE
      '%FINAL_SUPPLIER_PAYMENT_IMMUTABLE%') THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE definition NOT ILIKE
      '%FINAL_SUPPLIER_PAYMENT_IMMUTABLE%'),
    jsonb_build_object('routine_rows',count(*))
  FROM mutation_routines WHERE proname='cancel_supplier_payment'

  UNION ALL SELECT 'supplier_payment_source_account_guard',
    CASE WHEN count(*)=2 AND bool_and(definition ILIKE
      '%acp6f_source_account_allowed%') THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE definition NOT ILIKE
      '%acp6f_source_account_allowed%'),
    jsonb_build_object('guarded_rows',count(*) FILTER(WHERE definition ILIKE
      '%acp6f_source_account_allowed%'))
  FROM mutation_routines WHERE proname IN(
    'save_supplier_payment_draft','validate_supplier_payment')

  UNION ALL SELECT 'browser_supplier_payment_table_boundary',
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

  UNION ALL SELECT 'private_supplier_payment_core_boundary',
    CASE WHEN count(*)=3 AND count(*) FILTER(WHERE
      has_function_privilege('authenticated',procedure.oid,'EXECUTE')
      OR has_function_privilege('anon',procedure.oid,'EXECUTE'))=0
      THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE has_function_privilege(
      'authenticated',procedure.oid,'EXECUTE')
      OR has_function_privilege('anon',procedure.oid,'EXECUTE')),
    jsonb_build_object('core_rows',count(*))
  FROM pg_proc procedure WHERE procedure.pronamespace='private'::regnamespace
    AND procedure.proname LIKE 'acp6f_%_core'

  UNION ALL SELECT 'supplier_payment_header_allocation_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('document_count',count(*))
  FROM public.supplier_payment_documents document
  WHERE document.total_amount<>COALESCE((SELECT sum(allocation.allocated_amount)
    FROM public.supplier_payment_allocations allocation
    WHERE allocation.company_id=document.company_id
      AND allocation.document_id=document.id),0)

  UNION ALL SELECT 'validated_supplier_payment_financial_event_coverage',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('document_count',count(*))
  FROM public.supplier_payment_documents document
  LEFT JOIN public.financial_events event ON event.company_id=document.company_id
    AND event.id=document.financial_event_id
  WHERE document.status='VALIDATED' AND (event.id IS NULL
    OR event.source_table<>'supplier_payment_documents'
    OR event.source_id<>document.id
    OR event.event_type<>'SUPPLIER_PAYMENT_VALIDATED'::public.event_type)

  UNION ALL SELECT 'supplier_payment_finance_hold_preserved',
    CASE WHEN count(*) FILTER(WHERE status<>'HOLD')=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE status<>'HOLD'),
    jsonb_build_object('hold_events',count(*) FILTER(WHERE status='HOLD'))
  FROM public.financial_events WHERE source_table='supplier_payment_documents'

  UNION ALL SELECT 'supplier_payment_runtime_inventory','INFO',0,
    jsonb_build_object(
      'documents',(SELECT count(*) FROM public.supplier_payment_documents),
      'validated',(SELECT count(*) FROM public.supplier_payment_documents
        WHERE status='VALIDATED'),
      'allocations',(SELECT count(*) FROM public.supplier_payment_allocations),
      'override_rows',(SELECT count(*)
        FROM public.user_company_permission_overrides
        WHERE permission_key='finance.supplier_payments'))
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
