-- SELECT-only closing audit. This does not prove an authenticated UI smoke.
WITH scope AS (
  SELECT
    (SELECT count(*) FROM private.kgs_schema_migrations
      WHERE version='20261030120000') AS ledger_rows,
    to_regprocedure('private.trg_pos_retail_direct_post_order_runtime_bridge()') AS bridge_function,
    (SELECT count(*) FROM pg_trigger trigger_row
      WHERE trigger_row.tgrelid='public.sales_headers'::regclass
        AND trigger_row.tgname='pos_retail_direct_post_order_runtime_bridge'
        AND NOT trigger_row.tgisinternal) AS trigger_rows,
    COALESCE((SELECT pg_get_functiondef(
      'private.trg_pos_retail_direct_post_order_runtime_bridge()'::regprocedure)),'') AS definition
), invalid_sales AS (
  SELECT sale.id,sale.company_id,sale.draft_no,sale.invoice_no,
    sale.document_status,sale.order_runtime_status,sale.sales_origin,
    sale.sales_process_mode
  FROM public.sales_headers sale
  WHERE (sale.document_status='POSTED' AND sale.order_runtime_status<>'LEGACY_POSTED')
     OR (sale.order_runtime_status='LEGACY_POSTED' AND sale.document_status<>'POSTED')
), checks AS (
  SELECT 10 seq,'pos_retail_direct_post_bridge_migration_ledger'::text check_name,
    CASE WHEN ledger_rows=1 THEN 'PASS' ELSE 'BLOCKER' END status,
    abs(ledger_rows-1)::int violation_rows,
    jsonb_build_object('ledgerRows',ledger_rows) details FROM scope
  UNION ALL
  SELECT 20,'pos_retail_direct_post_bridge_runtime_contract',
    CASE WHEN bridge_function IS NOT NULL AND trigger_rows=1
      AND definition LIKE '%OLD.sales_origin NOT IN(''POS'',''BACKOFFICE_CUTOVER'')%'
      AND definition LIKE '%OLD.sales_process_mode<>''RETAIL_CONFIRM_INVOICE''%'
      AND definition LIKE '%RETURN NEW;%'
      AND definition LIKE '%RETAIL_DIRECT_POST_CUTOVER_ADOPTION_REQUIRED%'
      AND definition LIKE '%sales_process_retail_identity_is_valid%'
      AND definition LIKE '%NEW.order_runtime_status:=''LEGACY_POSTED''%'
      AND definition LIKE '%sales_stock_reservations%' THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN bridge_function IS NOT NULL AND trigger_rows=1
      AND definition LIKE '%OLD.sales_origin NOT IN(''POS'',''BACKOFFICE_CUTOVER'')%'
      AND definition LIKE '%OLD.sales_process_mode<>''RETAIL_CONFIRM_INVOICE''%'
      AND definition LIKE '%RETURN NEW;%'
      AND definition LIKE '%RETAIL_DIRECT_POST_CUTOVER_ADOPTION_REQUIRED%'
      AND definition LIKE '%sales_process_retail_identity_is_valid%'
      AND definition LIKE '%NEW.order_runtime_status:=''LEGACY_POSTED''%'
      AND definition LIKE '%sales_stock_reservations%' THEN 0 ELSE 1 END,
    jsonb_build_object('function',bridge_function::text,'triggerRows',trigger_rows)
    FROM scope
  UNION ALL
  SELECT 30,'pos_retail_direct_post_bridge_lifecycle_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::int,
    jsonb_build_object('invalid',COALESCE(jsonb_agg(to_jsonb(invalid_sales))
      FILTER(WHERE invalid_sales.id IS NOT NULL),'[]'::jsonb)) FROM invalid_sales
  UNION ALL
  SELECT 40,'pos_retail_direct_post_bridge_company_modes','INFO',0,
    jsonb_build_object('companies',COALESCE(jsonb_agg(jsonb_build_object(
      'code',company.company_code,'mode',setting.active_mode)
      ORDER BY company.company_code),'[]'::jsonb))
    FROM public.companies company
    JOIN public.company_sales_process_settings setting ON setting.company_id=company.id
    WHERE company.status='ACTIVE'
  UNION ALL
  SELECT 50,'pos_retail_direct_post_bridge_business_boundary','INFO',0,
    jsonb_build_object('included',jsonb_build_array('direct POS Retail Draft-to-Posted',
        'already-adopted BACKOFFICE_CUTOVER Retail Draft-to-Posted'),
      'unchanged',jsonb_build_array('Backoffice tables and RPCs','reserved Orders',
        'historical Posted Sales','Stock/FIFO/Payment/Finance finalizer',
        'other document statuses'))
)
SELECT check_name,status,violation_rows,details FROM checks ORDER BY seq;
