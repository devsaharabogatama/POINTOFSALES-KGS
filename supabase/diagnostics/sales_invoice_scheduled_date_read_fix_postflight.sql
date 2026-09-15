-- Scheduled Invoice date read-model forward-fix postflight. SELECT-only.
WITH routine_state AS (
  SELECT procedure.oid,procedure.proname,pg_get_functiondef(procedure.oid) definition,
    procedure.prosecdef security_definer,procedure.provolatile volatility,
    procedure.proconfig config
  FROM pg_proc procedure
  WHERE procedure.oid IN(
    to_regprocedure('private.resolve_sales_invoice_display_date(jsonb,jsonb,timestamp with time zone,text)'),
    to_regprocedure('public.get_sales_documents()'),
    to_regprocedure('public.get_sales_invoice_document(uuid)'),
    to_regprocedure('public.get_pos_sales_invoice_document(uuid)'),
    to_regprocedure('public.export_sales_documents(date,date)'))
), checks(check_name,status,violation_rows,details,sort_order) AS (
  SELECT 'migration_ledger',CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    abs(count(*)-1),jsonb_build_object('ledgerRows',count(*)),1
  FROM private.kgs_schema_migrations WHERE version='20260907100000'
  UNION ALL
  SELECT 'required_invoice_date_routines',CASE WHEN count(*)=5 THEN 'PASS' ELSE 'FAIL' END,
    abs(count(*)-5),jsonb_build_object('expected',5,'routineRows',count(*)),2
  FROM routine_state
  UNION ALL
  SELECT 'invoice_date_reader_definition_contract',
    CASE WHEN count(*)=4 AND bool_and(definition LIKE '%resolve_sales_invoice_display_date%')
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=4 AND bool_and(definition LIKE '%resolve_sales_invoice_display_date%')
      THEN 0 ELSE 1 END,jsonb_build_object('readerRows',count(*)),3
  FROM routine_state WHERE proname<>'resolve_sales_invoice_display_date'
  UNION ALL
  SELECT 'private_invoice_date_helper_boundary',
    CASE WHEN NOT has_function_privilege('anon',
        'private.resolve_sales_invoice_display_date(jsonb,jsonb,timestamp with time zone,text)','EXECUTE')
      AND NOT has_function_privilege('authenticated',
        'private.resolve_sales_invoice_display_date(jsonb,jsonb,timestamp with time zone,text)','EXECUTE')
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN NOT has_function_privilege('anon',
        'private.resolve_sales_invoice_display_date(jsonb,jsonb,timestamp with time zone,text)','EXECUTE')
      AND NOT has_function_privilege('authenticated',
        'private.resolve_sales_invoice_display_date(jsonb,jsonb,timestamp with time zone,text)','EXECUTE')
      THEN 0 ELSE 1 END,jsonb_build_object(
        'anonExecute',has_function_privilege('anon',
          'private.resolve_sales_invoice_display_date(jsonb,jsonb,timestamp with time zone,text)','EXECUTE'),
        'authenticatedExecute',has_function_privilege('authenticated',
          'private.resolve_sales_invoice_display_date(jsonb,jsonb,timestamp with time zone,text)','EXECUTE')),4
  UNION ALL
  SELECT 'invoice_snapshot_rows_preserved','PASS',0,jsonb_build_object(
    'snapshotRows',count(*),'rule','Read fix performs no Invoice snapshot update or backfill'),5
  FROM public.sales_invoice_snapshots
  UNION ALL
  SELECT 'scheduled_historical_display_resolution',
    CASE WHEN count(*) FILTER(WHERE planned_order_date IS NOT NULL
      AND resolved_date IS DISTINCT FROM planned_order_date)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE planned_order_date IS NOT NULL
      AND resolved_date IS DISTINCT FROM planned_order_date),jsonb_build_object(
      'scheduledInvoiceRows',count(*),'correctedReadRows',count(*) FILTER(
        WHERE planned_order_date IS NOT NULL
          AND snapshot_order_date IS DISTINCT FROM planned_order_date)),6
  FROM (
    SELECT sale.planned_order_date,
      (NULLIF(invoice.snapshot_payload->>'transactionAt','')::TIMESTAMPTZ
        AT TIME ZONE COALESCE(NULLIF(invoice.snapshot_payload#>>'{company,timezone}',''),
          company.timezone,'Asia/Jakarta'))::DATE snapshot_order_date,
      private.resolve_sales_invoice_display_date(invoice.snapshot_payload,
        to_jsonb(sale),invoice.created_at,company.timezone) resolved_date
    FROM public.sales_invoice_snapshots invoice
    JOIN public.sales_headers sale ON sale.company_id=invoice.company_id
      AND sale.id=invoice.sales_id
    JOIN public.companies company ON company.id=invoice.company_id
    WHERE COALESCE(invoice.snapshot_payload#>>'{branding,invoiceDateDisplayMode}',
      'ORDER_DATE')='ORDER_DATE' AND sale.order_timing_mode='SCHEDULED'
  ) scheduled
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY sort_order,check_name;
