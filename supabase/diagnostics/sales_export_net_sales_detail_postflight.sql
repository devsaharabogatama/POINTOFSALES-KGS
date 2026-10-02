-- Read-only verification for 20261002100000_sales_export_net_sales_detail.sql.
WITH target_company AS (
  SELECT company.id,company.company_name FROM public.companies company
  WHERE company.status='ACTIVE'
), payload AS (
  SELECT company.id,company.company_name,
    private.get_sales_export_net_detail_core(
      company.id,date '2026-08-01',current_date) body
  FROM target_company company
), invalid_row AS (
  SELECT payload.id,item FROM payload
  CROSS JOIN LATERAL jsonb_array_elements(payload.body) item
  WHERE (item->>'net_sales_base_qty')::numeric<>
      greatest((item->>'invoice_base_qty')::numeric-
        (item->>'canceled_base_qty')::numeric-
        (item->>'returned_base_qty')::numeric,0)
    OR (item->>'net_stock_out_base_qty')::numeric<>
      greatest((item->>'outbound_base_qty')::numeric-
        (item->>'reversed_base_qty')::numeric-
        (item->>'restocked_base_qty')::numeric,0)
), definitions AS (
  SELECT pg_get_functiondef(
      'private.get_sales_export_net_detail_core(uuid,date,date)'::regprocedure) core,
    pg_get_functiondef(
      'public.export_sales_documents_with_reconciliation(date,date)'::regprocedure) wrapper
)
SELECT 'sales_export_net_detail_migration_ledger' check_name,
  CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,abs(count(*)-1) violation_rows,
  jsonb_build_object('ledgerRows',count(*)) details
FROM private.kgs_schema_migrations WHERE version='20261002100000'
UNION ALL
SELECT 'sales_export_net_detail_routine_contract',
  CASE WHEN to_regprocedure(
      'private.get_sales_export_net_detail_core(uuid,date,date)') IS NOT NULL
    AND to_regprocedure(
      'public.export_sales_documents_with_reconciliation(date,date)') IS NOT NULL
    THEN 'PASS' ELSE 'FAIL' END,
  CASE WHEN to_regprocedure(
      'private.get_sales_export_net_detail_core(uuid,date,date)') IS NOT NULL
    AND to_regprocedure(
      'public.export_sales_documents_with_reconciliation(date,date)') IS NOT NULL
    THEN 0 ELSE 1 END,jsonb_build_object('present',2,'expected',2)
UNION ALL
SELECT 'sales_export_net_detail_permission_contract',
  CASE WHEN has_function_privilege('authenticated',
      'public.export_sales_documents_with_reconciliation(date,date)','EXECUTE')
    AND NOT has_function_privilege('anon',
      'public.export_sales_documents_with_reconciliation(date,date)','EXECUTE')
    AND NOT has_function_privilege('authenticated',
      'private.get_sales_export_net_detail_core(uuid,date,date)','EXECUTE')
    THEN 'PASS' ELSE 'FAIL' END,
  CASE WHEN has_function_privilege('authenticated',
      'public.export_sales_documents_with_reconciliation(date,date)','EXECUTE')
    AND NOT has_function_privilege('anon',
      'public.export_sales_documents_with_reconciliation(date,date)','EXECUTE')
    AND NOT has_function_privilege('authenticated',
      'private.get_sales_export_net_detail_core(uuid,date,date)','EXECUTE')
    THEN 0 ELSE 1 END,
  jsonb_build_object('publicAuthenticated',true,'privateAuthenticated',false)
UNION ALL
SELECT 'sales_export_net_detail_runtime_definition',
  CASE WHEN position('backoffice_sales_return_invoice_allocations' IN core)>0
    AND position('sales_return_documents' IN core)>0
    AND position('stock_movements' IN core)>0
    AND position('POSTED_INVOICE' IN core)>0
    AND position('RESTOCK' IN core)>0
    AND position('netSalesLines' IN wrapper)>0 THEN 'PASS' ELSE 'FAIL' END,
  CASE WHEN position('backoffice_sales_return_invoice_allocations' IN core)>0
    AND position('sales_return_documents' IN core)>0
    AND position('stock_movements' IN core)>0
    AND position('POSTED_INVOICE' IN core)>0
    AND position('RESTOCK' IN core)>0
    AND position('netSalesLines' IN wrapper)>0 THEN 0 ELSE 1 END,
  jsonb_build_object('required',ARRAY['exact Backoffice Invoice-line allocation',
    'exact Retail Sale lineage','posted native Return only',
    'posted Backoffice Invoice Return only','RESTOCK-only Stock reduction',
    'atomic workbook payload']) FROM definitions
UNION ALL
SELECT 'sales_export_net_detail_arithmetic',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
  jsonb_build_object('invalidRows',count(*)) FROM invalid_row
UNION ALL
SELECT 'sales_export_net_detail_company_scope',
  CASE WHEN count(*)=(SELECT count(*) FROM target_company) THEN 'PASS' ELSE 'FAIL' END,
  abs(count(*)-(SELECT count(*) FROM target_company)),
  jsonb_build_object('rows',count(*),'companies',coalesce(jsonb_agg(company_name
    ORDER BY company_name),'[]'::jsonb)) FROM payload
UNION ALL
SELECT 'sales_export_net_detail_runtime_inventory','INFO',0,
  jsonb_build_object('companies',coalesce(jsonb_agg(jsonb_build_object(
    'company',company_name,'rows',jsonb_array_length(body),
    'netSalesQty',COALESCE((SELECT sum((item->>'net_sales_base_qty')::numeric)
      FROM jsonb_array_elements(body) item),0),
    'netStockOutQty',COALESCE((SELECT sum((item->>'net_stock_out_base_qty')::numeric)
      FROM jsonb_array_elements(body) item),0)) ORDER BY company_name),'[]'::jsonb))
  FROM payload;
