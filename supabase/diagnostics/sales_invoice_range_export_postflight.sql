-- Sales Invoice date-range XLSX export postflight. SELECT-only.
WITH function_state AS (
  SELECT procedure.oid,pg_get_functiondef(procedure.oid) definition,
    procedure.prosecdef security_definer,procedure.provolatile volatility,
    procedure.proconfig config
  FROM pg_proc procedure
  WHERE procedure.oid=to_regprocedure('public.export_sales_documents(date,date)')
), checks(check_name,status,violation_rows,details,sort_order) AS (
  SELECT 'migration_ledger',CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    abs(count(*)-1),jsonb_build_object('ledgerRows',count(*)),1
  FROM private.kgs_schema_migrations WHERE version='20260904100000'
  UNION ALL
  SELECT 'required_sales_invoice_export_routines',
    CASE WHEN count(*)=2 THEN 'PASS' ELSE 'FAIL' END,abs(count(*)-2),
    jsonb_build_object('expected',2,'routineRows',count(*)),2
  FROM (VALUES(to_regprocedure('public.export_sales_documents()')),
    (to_regprocedure('public.export_sales_documents(date,date)'))) expected(oid)
  WHERE expected.oid IS NOT NULL
  UNION ALL
  SELECT 'range_export_security_contract',
    CASE WHEN count(*)=1 AND bool_and(security_definer) AND bool_and(volatility='s')
      AND bool_and(config @> ARRAY['search_path=public, pg_temp','statement_timeout=30s'])
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1 AND bool_and(security_definer) AND bool_and(volatility='s')
      AND bool_and(config @> ARRAY['search_path=public, pg_temp','statement_timeout=30s'])
      THEN 0 ELSE 1 END,
    jsonb_build_object('routineRows',count(*),'securityDefiner',COALESCE(bool_and(security_definer),FALSE),
      'volatility',COALESCE(min(volatility::TEXT),'?'),'config',COALESCE(jsonb_agg(config),'[]'::JSONB)),3
  FROM function_state
  UNION ALL
  SELECT 'range_export_definition_contract',
    CASE WHEN count(*)=1 AND bool_and(definition LIKE '%sales.sales_documents%EXPORT%')
      AND bool_and(definition LIKE '%invoice_date BETWEEN p_date_from AND p_date_to%')
      AND bool_and(definition LIKE '%jsonb_array_elements%') THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1 AND bool_and(definition LIKE '%sales.sales_documents%EXPORT%')
      AND bool_and(definition LIKE '%invoice_date BETWEEN p_date_from AND p_date_to%')
      AND bool_and(definition LIKE '%jsonb_array_elements%') THEN 0 ELSE 1 END,
    jsonb_build_object('routineRows',count(*)),4 FROM function_state
  UNION ALL
  SELECT 'range_export_rpc_boundary',
    CASE WHEN NOT has_function_privilege('anon','public.export_sales_documents(date,date)','EXECUTE')
      AND has_function_privilege('authenticated','public.export_sales_documents(date,date)','EXECUTE')
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN NOT has_function_privilege('anon','public.export_sales_documents(date,date)','EXECUTE')
      AND has_function_privilege('authenticated','public.export_sales_documents(date,date)','EXECUTE')
      THEN 0 ELSE 1 END,
    jsonb_build_object('anonExecute',has_function_privilege('anon',
      'public.export_sales_documents(date,date)','EXECUTE'),
      'authenticatedExecute',has_function_privilege('authenticated',
      'public.export_sales_documents(date,date)','EXECUTE')),5
  UNION ALL
  SELECT 'invoice_snapshot_line_shape',
    CASE WHEN count(*) FILTER(WHERE jsonb_typeof(snapshot_payload->'lines') IS DISTINCT FROM 'array')=0
      THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE jsonb_typeof(snapshot_payload->'lines') IS DISTINCT FROM 'array'),
    jsonb_build_object('invoiceCount',count(*),'invalidRows',
      count(*) FILTER(WHERE jsonb_typeof(snapshot_payload->'lines') IS DISTINCT FROM 'array')),6
  FROM public.sales_invoice_snapshots
  UNION ALL
  SELECT 'sales_invoice_export_runtime_inventory','INFO',0,jsonb_build_object(
    'companies',count(DISTINCT company_id),'invoices',count(*),
    'lineSnapshots',COALESCE(sum(CASE WHEN jsonb_typeof(snapshot_payload->'lines')='array'
      THEN jsonb_array_length(snapshot_payload->'lines') ELSE 0 END),0)),7
  FROM public.sales_invoice_snapshots
)
SELECT check_name,status,violation_rows,details FROM checks ORDER BY sort_order,check_name;
