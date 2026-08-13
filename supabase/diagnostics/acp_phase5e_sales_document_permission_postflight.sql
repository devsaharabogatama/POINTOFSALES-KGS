-- ACP-5E postflight: Sales Document effective permission enforcement.
-- SAFETY: SELECT-only; aggregate metadata only.

WITH expected_relations(relation_name) AS (
  VALUES ('sales_invoice_snapshots'),('sales_delivery_documents'),
    ('sales_delivery_lines'),('sales_document_audit')
), expected_routines(signature) AS (
  VALUES ('public.get_sales_documents()'),
    ('public.export_sales_documents()'),
    ('public.get_sales_invoice_document(uuid)'),
    ('public.get_sales_delivery_document(uuid)'),
    ('public.record_sales_document_print(text,uuid)'),
    ('public.update_sales_delivery_status(uuid,bigint,text,text)'),
    ('public.get_pos_sales_invoice_document(uuid)'),
    ('public.get_pos_sales_delivery_document(uuid)'),
    ('public.record_pos_sales_document_print(text,uuid)')
), guarded_routines AS (
  SELECT procedure.proname,pg_get_functiondef(procedure.oid) definition
  FROM pg_proc procedure WHERE procedure.pronamespace='public'::regnamespace
    AND procedure.proname IN('get_sales_documents','export_sales_documents',
      'get_sales_invoice_document','get_sales_delivery_document',
      'record_sales_document_print','update_sales_delivery_status')
), posted_sales AS (
  SELECT * FROM public.sales_headers WHERE document_status='POSTED'
), checks AS (
  SELECT 'migration_ledger'::TEXT check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    count(*) FILTER(WHERE version<>'20260813020000') violation_rows,
    jsonb_build_object('ledger_rows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260813020000'

  UNION ALL
  SELECT 'sales_document_permission_enforced',
    CASE WHEN count(*)=1 AND bool_and(enforcement_status='ENFORCED')
      THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE enforcement_status<>'ENFORCED'),
    jsonb_build_object('rows',count(*),'statuses',COALESCE(
      jsonb_agg(enforcement_status),'[]'::JSONB))
  FROM public.access_permission_catalog
  WHERE permission_key='sales.sales_documents'

  UNION ALL
  SELECT 'required_sales_document_routines',
    CASE WHEN count(*) FILTER(WHERE to_regprocedure(signature) IS NULL)=0
      THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE to_regprocedure(signature) IS NULL),
    jsonb_build_object('expected',count(*),'missing',COALESCE(
      jsonb_agg(signature ORDER BY signature)
        FILTER(WHERE to_regprocedure(signature) IS NULL),'[]'::JSONB))
  FROM expected_routines

  UNION ALL
  SELECT 'sales_document_runtime_permission_hooks',
    CASE WHEN count(*)=6 AND count(*) FILTER(WHERE
      definition ILIKE '%acp_require_permission_capability%'
      AND definition ILIKE '%sales.sales_documents%')=6
      THEN 'PASS' ELSE 'FAIL' END,
    6-count(*) FILTER(WHERE definition ILIKE
      '%acp_require_permission_capability%'
      AND definition ILIKE '%sales.sales_documents%'),
    jsonb_build_object('routine_rows',count(*),'hooked_rows',count(*) FILTER(
      WHERE definition ILIKE '%acp_require_permission_capability%'
        AND definition ILIKE '%sales.sales_documents%'))
  FROM guarded_routines

  UNION ALL
  SELECT 'browser_sales_document_table_boundary',
    CASE WHEN count(*) FILTER(WHERE readable OR writable)=0
      THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE readable OR writable),
    jsonb_build_object('readable',COALESCE(jsonb_agg(relation_name)
      FILTER(WHERE readable),'[]'::JSONB),'writable',COALESCE(
      jsonb_agg(relation_name) FILTER(WHERE writable),'[]'::JSONB))
  FROM (SELECT relation_name,
    has_table_privilege('authenticated',format('public.%I',relation_name),
      'SELECT') readable,
    has_table_privilege('authenticated',format('public.%I',relation_name),
      'INSERT,UPDATE,DELETE') writable FROM expected_relations) privilege_state

  UNION ALL
  SELECT 'private_sales_document_core_boundary',
    CASE WHEN count(*)=4 AND count(*) FILTER(WHERE
      has_function_privilege('authenticated',procedure.oid,'EXECUTE')
      OR has_function_privilege('anon',procedure.oid,'EXECUTE'))=0
      THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE has_function_privilege(
      'authenticated',procedure.oid,'EXECUTE')
      OR has_function_privilege('anon',procedure.oid,'EXECUTE')),
    jsonb_build_object('core_rows',count(*))
  FROM pg_proc procedure WHERE procedure.pronamespace='private'::regnamespace
    AND procedure.proname LIKE 'acp5e_%_core'

  UNION ALL
  SELECT 'public_sales_document_rpc_boundary',
    CASE WHEN count(*) FILTER(WHERE procedure.oid IS NULL)=0
      AND count(*) FILTER(WHERE procedure.oid IS NOT NULL AND
        NOT has_function_privilege('authenticated',procedure.oid,'EXECUTE'))=0
      AND count(*) FILTER(WHERE procedure.oid IS NOT NULL AND
        has_function_privilege('anon',procedure.oid,'EXECUTE'))=0
      THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE procedure.oid IS NULL OR
      NOT has_function_privilege('authenticated',procedure.oid,'EXECUTE') OR
      has_function_privilege('anon',procedure.oid,'EXECUTE')),
    jsonb_build_object('expected',count(*))
  FROM expected_routines expected
  LEFT JOIN pg_proc procedure ON procedure.oid=to_regprocedure(expected.signature)

  UNION ALL
  SELECT 'posted_sale_invoice_snapshot_coverage',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('sale_count',count(*))
  FROM posted_sales sale LEFT JOIN public.sales_invoice_snapshots invoice
    ON invoice.company_id=sale.company_id AND invoice.sales_id=sale.id
  WHERE invoice.id IS NULL

  UNION ALL
  SELECT 'delivery_sale_document_coverage',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('sale_count',count(*))
  FROM posted_sales sale LEFT JOIN public.sales_delivery_documents delivery
    ON delivery.company_id=sale.company_id AND delivery.sales_id=sale.id
  WHERE (sale.fulfillment_mode='DELIVERY' AND delivery.id IS NULL)
     OR (sale.fulfillment_mode='PICKUP' AND delivery.id IS NOT NULL)

  UNION ALL
  SELECT 'posted_sale_single_financial_event',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('sale_count',count(*))
  FROM posted_sales sale WHERE (SELECT count(*) FROM public.financial_events event
    WHERE event.company_id=sale.company_id
      AND event.source_table='sales_headers' AND event.source_id=sale.id
      AND event.event_type='SALE_POSTED'::public.event_type)<>1

  UNION ALL
  SELECT 'sales_document_runtime_inventory','INFO',0,
    jsonb_build_object('posted_sales',(SELECT count(*) FROM posted_sales),
      'invoice_snapshots',(SELECT count(*) FROM public.sales_invoice_snapshots),
      'delivery_documents',(SELECT count(*) FROM public.sales_delivery_documents),
      'audit_rows',(SELECT count(*) FROM public.sales_document_audit),
      'override_rows',(SELECT count(*)
        FROM public.user_company_permission_overrides
        WHERE permission_key='sales.sales_documents'))
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,
  check_name;
