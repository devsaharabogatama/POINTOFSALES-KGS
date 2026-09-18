-- Read-only postflight for 20260918120000.
WITH required_columns(table_name,column_name) AS (VALUES
  ('backoffice_sales_returns','source_kind'),
  ('backoffice_sales_returns','retail_sales_id'),
  ('backoffice_sales_returns','source_document_snapshot'),
  ('backoffice_sales_return_lines','source_kind'),
  ('backoffice_sales_return_lines','retail_sales_detail_id')
), required_routines(signature) AS (VALUES
  ('public.get_retained_retail_backoffice_return_source(uuid)'),
  ('public.save_retained_retail_backoffice_return_draft(uuid,bigint,uuid,uuid,jsonb)')
), checks AS (
  SELECT 'retained_return_commercial_migration_ledger' check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END status,
    abs(1-count(*))::bigint violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260918120000'
  UNION ALL
  SELECT 'retained_return_commercial_column_contract',
    CASE WHEN count(actual.column_name)=5 THEN 'PASS' ELSE 'BLOCKER' END,
    (5-count(actual.column_name))::bigint,
    jsonb_build_object('present',count(actual.column_name),'expected',5,
      'missing',COALESCE(jsonb_agg(required.column_name) FILTER(
        WHERE actual.column_name IS NULL),'[]'::jsonb))
  FROM required_columns required LEFT JOIN information_schema.columns actual
    ON actual.table_schema='public' AND actual.table_name=required.table_name
   AND actual.column_name=required.column_name
  UNION ALL
  SELECT 'retained_return_commercial_routine_contract',
    CASE WHEN count(*) FILTER(WHERE to_regprocedure(signature) IS NOT NULL)=2
      THEN 'PASS' ELSE 'BLOCKER' END,
    (2-count(*) FILTER(WHERE to_regprocedure(signature) IS NOT NULL))::bigint,
    jsonb_build_object('present',count(*) FILTER(WHERE to_regprocedure(signature) IS NOT NULL),
      'expected',2,'missing',COALESCE(jsonb_agg(signature) FILTER(
        WHERE to_regprocedure(signature) IS NULL),'[]'::jsonb))
  FROM required_routines
  UNION ALL
  SELECT 'retained_return_commercial_source_shape',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('invalidRows',count(*))
  FROM public.backoffice_sales_returns document
  WHERE NOT ((document.source_kind='BACKOFFICE' AND document.sales_order_id IS NOT NULL
      AND document.retail_sales_id IS NULL AND document.source_document_snapshot IS NULL)
    OR (document.source_kind='RETAINED_RETAIL' AND document.sales_order_id IS NULL
      AND document.retail_sales_id IS NOT NULL
      AND jsonb_typeof(document.source_document_snapshot)='object'))
  UNION ALL
  SELECT 'retained_return_commercial_line_shape',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('invalidRows',count(*))
  FROM public.backoffice_sales_return_lines line
  JOIN public.backoffice_sales_returns document
    ON document.company_id=line.company_id AND document.id=line.return_id
  WHERE line.source_kind<>document.source_kind OR NOT (
    (line.source_kind='BACKOFFICE' AND line.sales_order_line_id IS NOT NULL
      AND line.retail_sales_detail_id IS NULL)
    OR (line.source_kind='RETAINED_RETAIL' AND line.sales_order_line_id IS NULL
      AND line.retail_sales_detail_id IS NOT NULL))
  UNION ALL
  SELECT 'retained_return_commercial_legacy_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('invalidLegacyRows',count(*))
  FROM public.backoffice_sales_returns document
  WHERE document.created_at<(SELECT applied_at FROM private.kgs_schema_migrations
      WHERE version='20260918120000')
    AND document.source_kind<>'BACKOFFICE'
  UNION ALL
  SELECT 'retained_return_commercial_runtime_inventory','INFO',0,
    jsonb_build_object('backofficeReturns',count(*) FILTER(WHERE source_kind='BACKOFFICE'),
      'retainedRetailReturns',count(*) FILTER(WHERE source_kind='RETAINED_RETAIL'))
  FROM public.backoffice_sales_returns
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 0 WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,
  check_name;
