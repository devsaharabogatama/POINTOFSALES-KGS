-- ACP-5H postflight: Sales Return effective permission and channel split.
-- SAFETY: SELECT-only; aggregate metadata only.

WITH expected_relations(relation_name) AS (VALUES
  ('sales_return_audit'),('sales_return_documents'),
  ('sales_return_fifo_restorations'),('sales_return_lines'),
  ('sales_return_refunds')
), expected_routines(signature) AS (VALUES
  ('public.get_sales_returns(text)'),
  ('public.get_pos_returnable_sales(text,integer)'),
  ('public.post_sales_return(uuid,bigint,uuid)'),
  ('public.cancel_sales_return_draft(uuid,bigint,text)')
), guarded_routines AS (
  SELECT procedure.proname,pg_get_functiondef(procedure.oid) definition
  FROM pg_proc procedure WHERE procedure.oid IN(
    to_regprocedure('public.get_sales_returns(text)'),
    to_regprocedure('public.post_sales_return(uuid,bigint,uuid)'),
    to_regprocedure('public.cancel_sales_return_draft(uuid,bigint,text)'))
), checks AS (
  SELECT 'migration_ledger'::TEXT check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    count(*) FILTER(WHERE version<>'20260813050000') violation_rows,
    jsonb_build_object('ledger_rows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260813050000'

  UNION ALL SELECT 'sales_return_permission_enforced',
    CASE WHEN count(*)=1 AND bool_and(enforcement_status='ENFORCED')
      THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE enforcement_status<>'ENFORCED'),
    jsonb_build_object('rows',count(*),'statuses',COALESCE(
      jsonb_agg(enforcement_status),'[]'::JSONB))
  FROM public.access_permission_catalog WHERE permission_key='sales.sales_returns'

  UNION ALL SELECT 'required_sales_return_routines',
    CASE WHEN count(*) FILTER(WHERE to_regprocedure(signature) IS NULL)=0
      THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE to_regprocedure(signature) IS NULL),
    jsonb_build_object('expected',count(*),'missing',COALESCE(jsonb_agg(signature)
      FILTER(WHERE to_regprocedure(signature) IS NULL),'[]'::JSONB))
  FROM expected_routines

  UNION ALL SELECT 'sales_return_runtime_permission_hooks',
    CASE WHEN count(*)=3 AND count(*) FILTER(WHERE
      definition ILIKE '%acp_require_permission_capability%'
      AND definition ILIKE '%sales.sales_returns%')=3
      THEN 'PASS' ELSE 'FAIL' END,
    3-count(*) FILTER(WHERE definition ILIKE
      '%acp_require_permission_capability%'
      AND definition ILIKE '%sales.sales_returns%'),
    jsonb_build_object('routine_rows',count(*),'hooked_rows',count(*) FILTER(
      WHERE definition ILIKE '%acp_require_permission_capability%'
        AND definition ILIKE '%sales.sales_returns%'))
  FROM guarded_routines

  UNION ALL SELECT 'cashier_return_source_contract',
    CASE WHEN count(*)=1 AND bool_and(definition ILIKE '%cashier_sessions%'
      AND definition ILIKE '%OPEN%'
      AND definition NOT ILIKE '%sales.sales_returns%') THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE definition NOT ILIKE '%cashier_sessions%'
      OR definition NOT ILIKE '%OPEN%'
      OR definition ILIKE '%sales.sales_returns%'),
    jsonb_build_object('routine_rows',count(*))
  FROM (SELECT pg_get_functiondef(procedure.oid) definition FROM pg_proc procedure
    WHERE procedure.oid=to_regprocedure(
      'public.get_pos_returnable_sales(text,integer)')) source

  UNION ALL SELECT 'browser_sales_return_table_boundary',
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

  UNION ALL SELECT 'private_sales_return_core_boundary',
    CASE WHEN count(*)=2 AND count(*) FILTER(WHERE
      has_function_privilege('authenticated',procedure.oid,'EXECUTE')
      OR has_function_privilege('anon',procedure.oid,'EXECUTE'))=0
      THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE has_function_privilege(
      'authenticated',procedure.oid,'EXECUTE')
      OR has_function_privilege('anon',procedure.oid,'EXECUTE')),
    jsonb_build_object('core_rows',count(*))
  FROM pg_proc procedure WHERE procedure.pronamespace='private'::regnamespace
    AND procedure.proname IN('acp5h_post_sales_return_core',
      'acp5h_cancel_sales_return_draft_core')

  UNION ALL SELECT 'public_sales_return_rpc_boundary',
    CASE WHEN count(*) FILTER(WHERE procedure.oid IS NULL)=0
      AND count(*) FILTER(WHERE procedure.oid IS NOT NULL AND NOT
        has_function_privilege('authenticated',procedure.oid,'EXECUTE'))=0
      AND count(*) FILTER(WHERE procedure.oid IS NOT NULL AND
        has_function_privilege('anon',procedure.oid,'EXECUTE'))=0
      THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE procedure.oid IS NULL OR NOT
      has_function_privilege('authenticated',procedure.oid,'EXECUTE') OR
      has_function_privilege('anon',procedure.oid,'EXECUTE')),
    jsonb_build_object('expected',count(*))
  FROM expected_routines expected LEFT JOIN pg_proc procedure
    ON procedure.oid=to_regprocedure(expected.signature)

  UNION ALL SELECT 'invalid_sales_return_lifecycle',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('row_count',count(*))
  FROM public.sales_return_documents document WHERE
    (document.status='POSTED' AND (document.posted_at IS NULL
      OR document.posted_by IS NULL OR document.financial_event_id IS NULL))
    OR (document.status='CANCELED' AND (document.canceled_at IS NULL
      OR document.canceled_by IS NULL))

  UNION ALL SELECT 'sales_return_header_line_refund_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('document_count',count(*)) FROM (
      SELECT document.id FROM public.sales_return_documents document
      LEFT JOIN public.sales_return_refunds refund
        ON refund.company_id=document.company_id AND refund.document_id=document.id
      GROUP BY document.id,document.refund_total
      HAVING abs(document.refund_total-COALESCE(sum(refund.amount),0))>0.0001
    ) mismatch

  UNION ALL SELECT 'posted_sales_return_final_effect_coverage',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('document_count',count(*))
  FROM public.sales_return_documents document
  LEFT JOIN public.financial_events event ON event.company_id=document.company_id
    AND event.id=document.financial_event_id AND event.source_id=document.id
  WHERE document.status='POSTED' AND event.id IS NULL

  UNION ALL SELECT 'sales_return_runtime_inventory','INFO',0,
    jsonb_build_object('documents',(SELECT count(*) FROM public.sales_return_documents),
      'drafts',(SELECT count(*) FROM public.sales_return_documents WHERE status='DRAFT'),
      'posted',(SELECT count(*) FROM public.sales_return_documents WHERE status='POSTED'),
      'canceled',(SELECT count(*) FROM public.sales_return_documents WHERE status='CANCELED'),
      'override_rows',(SELECT count(*) FROM public.user_company_permission_overrides
        WHERE permission_key='sales.sales_returns'),
      'finance_hold_events',(SELECT count(*) FROM public.financial_events
        WHERE event_type='SALES_REFUND' AND status='HOLD'))
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;

