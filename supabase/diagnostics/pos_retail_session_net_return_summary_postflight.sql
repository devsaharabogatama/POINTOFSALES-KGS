-- SELECT-only postflight for Retail POS Session Summary net Return read model.
WITH runtime AS (
  SELECT procedure.oid,
    pg_get_functiondef(procedure.oid) definition,
    procedure.prosecdef security_definer,
    procedure.provolatile volatility
  FROM pg_proc procedure
  JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname='public'
    AND procedure.oid=to_regprocedure(
      'public.get_pos_cashier_session_return_adjustments(uuid)')
), adjustment_inventory AS (
  SELECT count(DISTINCT document.id) posted_retail_documents,
    count(DISTINCT document.executing_session_id) executing_sessions
  FROM public.sales_return_documents document
  JOIN public.sales_headers source_sale
    ON source_sale.company_id=document.company_id
   AND source_sale.id=document.source_sales_id
  JOIN public.company_sales_process_settings setting
    ON setting.company_id=document.company_id
   AND setting.active_mode='RETAIL_CONFIRM_INVOICE'
  WHERE document.status::text='POSTED'
    AND source_sale.sales_origin='POS'
    AND source_sale.sales_process_mode='RETAIL_CONFIRM_INVOICE'
)
SELECT 'pos_retail_session_net_return_postflight_migration_ledger' check_name,
  CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
  abs(1-count(*)) violation_rows,
  jsonb_build_object('ledgerRows',count(*)) details
FROM private.kgs_schema_migrations ledger
WHERE ledger.version='20261102150000'
UNION ALL
SELECT 'pos_retail_session_net_return_postflight_runtime_contract',
  CASE WHEN count(*)=1
      AND bool_and(security_definer AND volatility='s')
      AND bool_and(definition LIKE '%CASHIER_SESSION_NOT_OWNED%')
      AND bool_and(definition LIKE '%''applicable'',false%')
      AND bool_and(definition LIKE '%source_sale.sales_origin=''POS''%')
      AND bool_and(definition LIKE
        '%source_sale.sales_process_mode=''RETAIL_CONFIRM_INVOICE''%')
      AND bool_and(definition LIKE '%document.executing_session_id=v_session.id%')
      AND bool_and(definition LIKE '%document.status=''POSTED''%')
    THEN 'PASS' ELSE 'FAIL' END,
  CASE WHEN count(*)=1
      AND bool_and(security_definer AND volatility='s')
      AND bool_and(definition LIKE '%CASHIER_SESSION_NOT_OWNED%')
      AND bool_and(definition LIKE '%''applicable'',false%')
      AND bool_and(definition LIKE '%source_sale.sales_origin=''POS''%')
      AND bool_and(definition LIKE
        '%source_sale.sales_process_mode=''RETAIL_CONFIRM_INVOICE''%')
      AND bool_and(definition LIKE '%document.executing_session_id=v_session.id%')
      AND bool_and(definition LIKE '%document.status=''POSTED''%')
    THEN 0 ELSE 1 END,
  jsonb_build_object('rows',count(*),
    'definitionMd5',min(md5(definition)),
    'securityDefiner',COALESCE(bool_and(security_definer),false),
    'stable',COALESCE(bool_and(volatility='s'),false),
    'retailModeGuard',COALESCE(bool_and(definition LIKE
      '%''applicable'',false%'),false),
    'posSourceGuard',COALESCE(bool_and(definition LIKE
      '%source_sale.sales_origin=''POS''%'),false))
FROM runtime
UNION ALL
SELECT 'pos_retail_session_net_return_postflight_privilege_contract',
  CASE WHEN has_function_privilege('authenticated',
        'public.get_pos_cashier_session_return_adjustments(uuid)','EXECUTE')
      AND NOT has_table_privilege('authenticated',
        'public.sales_return_documents','SELECT')
      AND NOT has_table_privilege('authenticated',
        'public.sales_return_lines','SELECT')
      AND NOT has_table_privilege('authenticated',
        'public.sales_return_refunds','SELECT')
    THEN 'PASS' ELSE 'FAIL' END,
  CASE WHEN has_function_privilege('authenticated',
        'public.get_pos_cashier_session_return_adjustments(uuid)','EXECUTE')
      AND NOT has_table_privilege('authenticated',
        'public.sales_return_documents','SELECT')
      AND NOT has_table_privilege('authenticated',
        'public.sales_return_lines','SELECT')
      AND NOT has_table_privilege('authenticated',
        'public.sales_return_refunds','SELECT')
    THEN 0 ELSE 1 END,
  jsonb_build_object('rpcExecute',has_function_privilege('authenticated',
      'public.get_pos_cashier_session_return_adjustments(uuid)','EXECUTE'),
    'documentsDirectSelect',has_table_privilege('authenticated',
      'public.sales_return_documents','SELECT'),
    'linesDirectSelect',has_table_privilege('authenticated',
      'public.sales_return_lines','SELECT'),
    'refundsDirectSelect',has_table_privilege('authenticated',
      'public.sales_return_refunds','SELECT'))
UNION ALL
SELECT 'pos_retail_session_net_return_postflight_data_inventory','INFO',0,
  jsonb_build_object('postedRetailDocuments',posted_retail_documents,
    'executingSessions',executing_sessions,
    'meaning','Inventory only; rollback behavior and authenticated smoke remain required')
FROM adjustment_inventory
UNION ALL
SELECT 'pos_retail_session_net_return_postflight_business_boundary','INFO',0,
  jsonb_build_object('changed',jsonb_build_array(
      'Retail POS Session Summary Return/refund read model'),
    'preserved',jsonb_build_array('BACKOFFICE_DELIVERED_QTY_INVOICE',
      'Backoffice Return approval','Return posting','Stock/FIFO/HPP',
      'Payment verification','Finance Event/Journal','close-session mutation',
      'historical rows','other Companies'),
    'next','Run rollback-only behavior before client deployment');
