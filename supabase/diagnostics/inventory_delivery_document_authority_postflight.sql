-- Closing checks for Inventory-owned Surat Jalan authority.
WITH required_routines(name) AS (VALUES
  ('get_inventory_delivery_documents'),('get_inventory_delivery_document'),
  ('record_inventory_delivery_print'),('update_sales_delivery_status')
), checks AS (
  SELECT 'migration_ledger'::TEXT check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    count(*)::BIGINT violation_rows,jsonb_build_object('ledger_rows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260813150000'
  UNION ALL
  SELECT 'delivery_permission_enforced',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    abs(1-count(*)),jsonb_build_object('rows',count(*))
  FROM public.access_permission_catalog
  WHERE permission_key='inventory.delivery_documents'
    AND module_key='INVENTORY' AND enforcement_status='ENFORCED'
    AND supported_capabilities=ARRAY['VIEW','MANAGE']
  UNION ALL
  SELECT 'sales_invoice_permission_narrowed',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    abs(1-count(*)),jsonb_build_object('rows',count(*))
  FROM public.access_permission_catalog
  WHERE permission_key='sales.sales_documents'
    AND supported_capabilities=ARRAY['VIEW','EXPORT']
    AND cardinality(operator_roles)=0
  UNION ALL
  SELECT 'required_delivery_routines',
    CASE WHEN count(*) FILTER(WHERE routine.oid IS NULL)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE routine.oid IS NULL),jsonb_build_object('missing',COALESCE(
      jsonb_agg(required.name ORDER BY required.name) FILTER(WHERE routine.oid IS NULL),
      '[]'::JSONB))
  FROM required_routines required LEFT JOIN pg_proc routine
    ON routine.pronamespace='public'::regnamespace AND routine.proname=required.name
  UNION ALL
  SELECT 'browser_delivery_table_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('readable_relations',COALESCE(jsonb_agg(relation_name),'[]'::JSONB))
  FROM (SELECT relation_name FROM (VALUES('sales_delivery_documents'),
      ('sales_delivery_lines'),('sales_document_audit')) relation(relation_name)
    WHERE has_table_privilege('authenticated','public.'||relation_name,'SELECT')) readable
  UNION ALL
  SELECT 'delivery_tenant_integrity',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*),jsonb_build_object('row_count',count(*))
  FROM public.sales_delivery_documents delivery
  LEFT JOIN public.sales_headers sale ON sale.company_id=delivery.company_id
    AND sale.id=delivery.sales_id WHERE sale.id IS NULL
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
