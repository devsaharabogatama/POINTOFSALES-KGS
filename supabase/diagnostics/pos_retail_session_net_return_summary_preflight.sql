-- SELECT-only preflight for Retail POS Session Summary net Return adjustments.
-- Expected new-package state: NOT_INSTALLED.
WITH dependencies(version) AS (VALUES
  ('20260803010000'::text),
  ('20260805130000'),
  ('20260813050000'),
  ('20261102100000'),
  ('20261102120000'),
  ('20261102140000')
), installed AS (
  SELECT dependency.version,
    EXISTS(SELECT 1 FROM private.kgs_schema_migrations ledger
      WHERE ledger.version=dependency.version) installed
  FROM dependencies dependency
), state AS (
  SELECT
    EXISTS(SELECT 1 FROM private.kgs_schema_migrations ledger
      WHERE ledger.version='20261102150000') ledger,
    to_regprocedure(
      'public.get_pos_cashier_session_return_adjustments(uuid)'
    ) IS NOT NULL rpc
), required_columns(table_name,column_name) AS (VALUES
  ('sales_return_documents','company_id'),
  ('sales_return_documents','source_sales_id'),
  ('sales_return_documents','executing_session_id'),
  ('sales_return_documents','status'),
  ('sales_return_lines','document_id'),
  ('sales_return_lines','product_id'),
  ('sales_return_lines','product_sku_snapshot'),
  ('sales_return_lines','product_name_snapshot'),
  ('sales_return_lines','sale_uom_name_snapshot'),
  ('sales_return_lines','quantity_uom'),
  ('sales_return_lines','return_condition'),
  ('sales_return_refunds','document_id'),
  ('sales_return_refunds','payment_method_id'),
  ('sales_return_refunds','payment_method_name_snapshot'),
  ('sales_return_refunds','payment_method_type_snapshot'),
  ('sales_return_refunds','settlement_route_snapshot'),
  ('sales_return_refunds','amount'),
  ('sales_headers','sales_origin'),
  ('sales_headers','sales_process_mode'),
  ('company_sales_process_settings','active_mode')
), columns_state AS (
  SELECT required.table_name,required.column_name,
    EXISTS(SELECT 1 FROM information_schema.columns column_state
      WHERE column_state.table_schema='public'
        AND column_state.table_name=required.table_name
        AND column_state.column_name=required.column_name) installed
  FROM required_columns required
), close_calculator AS (
  SELECT pg_get_functiondef(
    'private.calculate_cashier_session_expected_cash(uuid,uuid)'::regprocedure
  ) definition
), process_inventory AS (
  SELECT company.company_code,setting.active_mode,
    count(DISTINCT session.id) FILTER(WHERE session.status::text='OPEN') open_sessions,
    count(DISTINCT document.id) FILTER(WHERE document.status::text='POSTED') posted_returns,
    count(DISTINCT document.id) FILTER(WHERE document.status::text='POSTED'
      AND source_sale.sales_origin='POS'
      AND source_sale.sales_process_mode='RETAIL_CONFIRM_INVOICE') posted_retail_pos_returns
  FROM public.company_sales_process_settings setting
  JOIN public.companies company ON company.id=setting.company_id
  LEFT JOIN public.cashier_sessions session
    ON session.company_id=setting.company_id
  LEFT JOIN public.sales_return_documents document
    ON document.company_id=setting.company_id
  LEFT JOIN public.sales_headers source_sale
    ON source_sale.company_id=document.company_id
   AND source_sale.id=document.source_sales_id
  GROUP BY company.company_code,setting.active_mode
), retail_documents AS (
  SELECT document.company_id,document.id,document.executing_session_id
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
), refund_inventory AS (
  SELECT count(refund.id) refund_rows,
    COALESCE(sum(refund.amount),0) refund_amount
  FROM retail_documents document
  JOIN public.sales_return_refunds refund
    ON refund.company_id=document.company_id
   AND refund.document_id=document.id
), line_inventory AS (
  SELECT count(line.id) physical_line_rows,
    COALESCE(sum(line.quantity_uom),0) physical_quantity
  FROM retail_documents document
  JOIN public.sales_return_lines line
    ON line.company_id=document.company_id
   AND line.document_id=document.id
   AND line.return_condition IN('SALEABLE','DAMAGED')
), adjustment_inventory AS (
  SELECT (SELECT count(*) FROM retail_documents) posted_retail_documents,
    refund.refund_rows,refund.refund_amount,
    line.physical_line_rows,line.physical_quantity,
    (SELECT count(DISTINCT executing_session_id)
      FROM retail_documents) executing_sessions
  FROM refund_inventory refund CROSS JOIN line_inventory line
)
SELECT 'pos_retail_session_net_return_preflight_dependency_ledger' check_name,
  CASE WHEN bool_and(installed) THEN 'PASS' ELSE 'BLOCKER' END status,
  count(*) FILTER(WHERE NOT installed) violation_rows,
  jsonb_build_object('required',jsonb_agg(version ORDER BY version),
    'missing',COALESCE(jsonb_agg(version ORDER BY version)
      FILTER(WHERE NOT installed),'[]'::jsonb)) details
FROM installed
UNION ALL
SELECT 'pos_retail_session_net_return_preflight_installation_state',
  CASE WHEN NOT ledger AND NOT rpc THEN 'PASS' ELSE 'BLOCKER' END,
  ledger::int+rpc::int,
  jsonb_build_object('classification',CASE
    WHEN NOT ledger AND NOT rpc THEN 'NOT_INSTALLED'
    WHEN ledger AND rpc THEN 'INSTALLED_CONSISTENT'
    ELSE 'PARTIAL/INCONSISTENT' END,
    'ledger',ledger,'rpc',rpc)
FROM state
UNION ALL
SELECT 'pos_retail_session_net_return_preflight_identifier_contract',
  CASE WHEN bool_and(installed) THEN 'PASS' ELSE 'BLOCKER' END,
  count(*) FILTER(WHERE NOT installed),
  jsonb_build_object('missing',COALESCE(jsonb_agg(
    table_name||'.'||column_name ORDER BY table_name,column_name)
    FILTER(WHERE NOT installed),'[]'::jsonb))
FROM columns_state
UNION ALL
SELECT 'pos_retail_session_net_return_preflight_close_cash_contract',
  CASE WHEN definition LIKE '%sales_return_refunds%'
      AND definition LIKE '%document.executing_session_id=session.id%'
      AND definition LIKE '%refund.payment_method_type_snapshot=''CASH''%'
    THEN 'PASS' ELSE 'BLOCKER' END,
  CASE WHEN definition LIKE '%sales_return_refunds%'
      AND definition LIKE '%document.executing_session_id=session.id%'
      AND definition LIKE '%refund.payment_method_type_snapshot=''CASH''%'
    THEN 0 ELSE 1 END,
  jsonb_build_object('definitionMd5',md5(definition),
    'returnRefundSubtractsCash',definition LIKE '%sales_return_refunds%',
    'executingSessionOwned',definition LIKE
      '%document.executing_session_id=session.id%',
    'cashOnly',definition LIKE
      '%refund.payment_method_type_snapshot=''CASH''%')
FROM close_calculator
UNION ALL
SELECT 'pos_retail_session_net_return_preflight_privilege_boundary',
  CASE WHEN NOT has_table_privilege('authenticated',
        'public.sales_return_documents','SELECT')
      AND NOT has_table_privilege('authenticated',
        'public.sales_return_lines','SELECT')
      AND NOT has_table_privilege('authenticated',
        'public.sales_return_refunds','SELECT')
    THEN 'PASS' ELSE 'BLOCKER' END,
  has_table_privilege('authenticated','public.sales_return_documents','SELECT')::int
    +has_table_privilege('authenticated','public.sales_return_lines','SELECT')::int
    +has_table_privilege('authenticated','public.sales_return_refunds','SELECT')::int,
  jsonb_build_object(
    'authenticatedDocumentsSelect',has_table_privilege('authenticated',
      'public.sales_return_documents','SELECT'),
    'authenticatedLinesSelect',has_table_privilege('authenticated',
      'public.sales_return_lines','SELECT'),
    'authenticatedRefundsSelect',has_table_privilege('authenticated',
      'public.sales_return_refunds','SELECT'),
    'meaning','A scoped SECURITY DEFINER read RPC is required; client direct reads stay forbidden')
UNION ALL
SELECT 'pos_retail_session_net_return_preflight_process_boundary','INFO',0,
  jsonb_build_object('companies',COALESCE(jsonb_agg(jsonb_build_object(
    'companyCode',company_code,'activeMode',active_mode,
    'openSessions',open_sessions,'postedReturns',posted_returns,
    'postedRetailPosReturns',posted_retail_pos_returns)
    ORDER BY company_code),'[]'::jsonb))
FROM process_inventory
UNION ALL
SELECT 'pos_retail_session_net_return_preflight_adjustment_inventory','INFO',0,
  jsonb_build_object('postedRetailDocuments',posted_retail_documents,
    'refundRows',refund_rows,'refundAmount',refund_amount,
    'physicalLineRows',physical_line_rows,
    'physicalQuantity',physical_quantity,
    'executingSessions',executing_sessions,
    'meaning','Inventory only; zero rows is not behavioral proof')
FROM adjustment_inventory
UNION ALL
SELECT 'pos_retail_session_net_return_preflight_runtime_boundary',
  CASE WHEN NOT EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
      WHERE status IN('PREVIEWED','APPROVED','PROCESSING'))
    AND NOT EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
      WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION'))
    THEN 'PASS' ELSE 'BLOCKER' END,
  (SELECT count(*) FROM public.finance_posting_queue_runs
      WHERE status IN('PREVIEWED','APPROVED','PROCESSING'))
   +(SELECT count(*) FROM public.pos_offline_sale_submissions
      WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')),
  jsonb_build_object(
    'activeFinanceQueue',(SELECT count(*)
      FROM public.finance_posting_queue_runs
      WHERE status IN('PREVIEWED','APPROVED','PROCESSING')),
    'nonterminalOffline',(SELECT count(*)
      FROM public.pos_offline_sale_submissions
      WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')))
UNION ALL
SELECT 'pos_retail_session_net_return_preflight_business_boundary','INFO',0,
  jsonb_build_object('mutation','NONE','included',jsonb_build_array(
    'Retail POS Posted Return refund display','Retail POS physical Return display',
    'selected executing Cashier Session'),
    'preserved',jsonb_build_array('Backoffice Sales Order',
      'Backoffice Sales Return approval','Return posting','Stock/FIFO/HPP',
      'Payment verification','Finance Event/Journal','close-session mutation',
      'historical rows','other Companies'),
    'next','Only after every mandatory row PASS: Phase B additive Retail read RPC and PWA net presentation');
