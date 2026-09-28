-- Read-only verification for 20260928100000_sales_export_ro_reconciliation.sql.
WITH target_company AS (
  SELECT company.id,company.company_name FROM public.companies company
  WHERE company.status='ACTIVE' AND company.company_name IN(
    'Khadijah Muda Sejahtera','Latorti Sari Median','Smart Muda Solusi')
), payload AS (
  SELECT company.id,company.company_name,
    private.get_sales_export_ro_reconciliation_core(
      company.id,date '2026-08-01',current_date) body
  FROM target_company company
), invalid_requirement AS (
  SELECT payload.id,item FROM payload
  CROSS JOIN LATERAL jsonb_array_elements(payload.body->'roRequirements') item
  WHERE (item->>'open_base_qty')::numeric<0
    OR (item->>'coverage_base_qty')::numeric<0
    OR (item->>'uncovered_base_qty')::numeric<0
    OR (item->>'open_base_qty')::numeric<>
      (item->>'coverage_base_qty')::numeric+(item->>'uncovered_base_qty')::numeric
), invalid_return AS (
  SELECT payload.id,item FROM payload
  CROSS JOIN LATERAL jsonb_array_elements(payload.body->'returns') item
  WHERE (item->>'returned_base_qty')::numeric<>
    (item->>'restocked_base_qty')::numeric+
    (item->>'destroyed_base_qty')::numeric+
    (item->>'no_physical_base_qty')::numeric
), definition AS (
  SELECT pg_get_functiondef(
    'private.get_sales_export_ro_reconciliation_core(uuid,date,date)'::regprocedure) body
)
SELECT 'sales_export_reconciliation_migration_ledger' check_name,
  CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,abs(count(*)-1) violation_rows,
  jsonb_build_object('ledgerRows',count(*)) details
FROM private.kgs_schema_migrations WHERE version='20260928100000'
UNION ALL
SELECT 'sales_export_reconciliation_routine_contract',
  CASE WHEN to_regprocedure(
      'private.get_sales_export_ro_reconciliation_core(uuid,date,date)') IS NOT NULL
    AND to_regprocedure('public.export_sales_stock_reconciliation(date,date)') IS NOT NULL
    AND to_regprocedure(
      'public.export_sales_documents_with_reconciliation(date,date)') IS NOT NULL
    THEN 'PASS' ELSE 'FAIL' END,
  CASE WHEN to_regprocedure(
      'private.get_sales_export_ro_reconciliation_core(uuid,date,date)') IS NOT NULL
    AND to_regprocedure('public.export_sales_stock_reconciliation(date,date)') IS NOT NULL
    AND to_regprocedure(
      'public.export_sales_documents_with_reconciliation(date,date)') IS NOT NULL
    THEN 0 ELSE 1 END,
  jsonb_build_object('present',3,'expected',3)
UNION ALL
SELECT 'sales_export_reconciliation_permission_contract',
  CASE WHEN has_function_privilege('authenticated',
      'public.export_sales_stock_reconciliation(date,date)','EXECUTE')
    AND has_function_privilege('service_role',
      'public.export_sales_stock_reconciliation(date,date)','EXECUTE')
    AND NOT has_function_privilege('anon',
      'public.export_sales_stock_reconciliation(date,date)','EXECUTE')
    AND NOT has_function_privilege('authenticated',
      'private.get_sales_export_ro_reconciliation_core(uuid,date,date)','EXECUTE')
    AND has_function_privilege('authenticated',
      'public.export_sales_documents_with_reconciliation(date,date)','EXECUTE')
    AND NOT has_function_privilege('anon',
      'public.export_sales_documents_with_reconciliation(date,date)','EXECUTE')
    THEN 'PASS' ELSE 'FAIL' END,
  CASE WHEN has_function_privilege('authenticated',
      'public.export_sales_stock_reconciliation(date,date)','EXECUTE')
    AND has_function_privilege('service_role',
      'public.export_sales_stock_reconciliation(date,date)','EXECUTE')
    AND NOT has_function_privilege('anon',
      'public.export_sales_stock_reconciliation(date,date)','EXECUTE')
    AND NOT has_function_privilege('authenticated',
      'private.get_sales_export_ro_reconciliation_core(uuid,date,date)','EXECUTE')
    AND has_function_privilege('authenticated',
      'public.export_sales_documents_with_reconciliation(date,date)','EXECUTE')
    AND NOT has_function_privilege('anon',
      'public.export_sales_documents_with_reconciliation(date,date)','EXECUTE')
    THEN 0 ELSE 1 END,
  jsonb_build_object('publicAuthenticated',true,'privateAuthenticated',false)
UNION ALL
SELECT 'sales_export_reconciliation_runtime_definition',
  CASE WHEN position('allocation.reversed_at IS NULL' IN body)>0
    AND position('batch.status=''DRAFT''' IN body)>0
    AND position('PURCHASE_ORDER' IN body)>0
    AND position('STOCK_REQUEST' IN body)>0 THEN 'PASS' ELSE 'FAIL' END,
  CASE WHEN position('allocation.reversed_at IS NULL' IN body)>0
    AND position('batch.status=''DRAFT''' IN body)>0
    AND position('PURCHASE_ORDER' IN body)>0
    AND position('STOCK_REQUEST' IN body)>0 THEN 0 ELSE 1 END,
  jsonb_build_object('required',ARRAY[
    'reversed source excluded','only Draft RO coverage',
    'active PO coverage','active Stock Request coverage']) FROM definition
UNION ALL
SELECT 'sales_export_reconciliation_company_scope',
  CASE WHEN count(*)=3 THEN 'PASS' ELSE 'FAIL' END,abs(count(*)-3),
  jsonb_build_object('rows',count(*),'companies',jsonb_agg(company_name
    ORDER BY company_name)) FROM payload
UNION ALL
SELECT 'sales_export_reconciliation_clean_requirement',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
  jsonb_build_object('invalidRows',count(*)) FROM invalid_requirement
UNION ALL
SELECT 'sales_export_reconciliation_return_classification',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
  jsonb_build_object('invalidRows',count(*)) FROM invalid_return
UNION ALL
SELECT 'sales_export_reconciliation_sms_trial_reversal_absence',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
  jsonb_build_object('rows',count(*)) FROM payload
  CROSS JOIN LATERAL jsonb_array_elements(payload.body->'roRequirements') item
  WHERE payload.company_name='Smart Muda Solusi'
    AND item->>'source_document_no'='INV-20260829-0000000140'
UNION ALL
SELECT 'sales_export_reconciliation_runtime_inventory','INFO',0,
  jsonb_build_object('companies',coalesce(jsonb_agg(jsonb_build_object(
    'company',company_name,
    'roRequirements',jsonb_array_length(body->'roRequirements'),
    'cancellations',jsonb_array_length(body->'cancellations'),
    'returns',jsonb_array_length(body->'returns')) ORDER BY company_name),'[]'::jsonb))
  FROM payload;
