-- Inventory Surat Jalan ODR read/print compatibility postflight.
-- SAFETY: SELECT-only.
WITH definitions AS (
  SELECT pg_get_functiondef(
    'public.get_inventory_delivery_document(uuid)'::regprocedure) read_definition,
    pg_get_functiondef(
    'public.record_inventory_delivery_print(uuid)'::regprocedure) print_definition
), checks AS (
  SELECT 'migration_ledger'::TEXT check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    count(*)::BIGINT violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260901110000'
  UNION ALL
  SELECT 'inventory_delivery_odr_read_contract',
    CASE WHEN read_definition LIKE '%FROM public.sales_delivery_documents delivery%'
      AND read_definition NOT LIKE '%acp5e_get_sales_delivery_document_core%'
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN read_definition LIKE '%FROM public.sales_delivery_documents delivery%'
      AND read_definition NOT LIKE '%acp5e_get_sales_delivery_document_core%'
      THEN 0 ELSE 1 END,jsonb_build_object('routineRows',1)
  FROM definitions
  UNION ALL
  SELECT 'inventory_delivery_print_audit_contract',
    CASE WHEN print_definition LIKE '%INSERT INTO public.sales_document_audit%'
      AND print_definition NOT LIKE '%acp5e_record_sales_document_print_core%'
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN print_definition LIKE '%INSERT INTO public.sales_document_audit%'
      AND print_definition NOT LIKE '%acp5e_record_sales_document_print_core%'
      THEN 0 ELSE 1 END,jsonb_build_object('routineRows',1)
  FROM definitions
  UNION ALL
  SELECT 'inventory_delivery_permission_guard',
    CASE WHEN read_definition LIKE '%inventory.delivery_documents%VIEW%'
      AND print_definition LIKE '%inventory.delivery_documents%VIEW%'
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN read_definition LIKE '%inventory.delivery_documents%VIEW%'
      AND print_definition LIKE '%inventory.delivery_documents%VIEW%'
      THEN 0 ELSE 1 END,jsonb_build_object('guardedRoutines',2)
  FROM definitions
  UNION ALL
  SELECT 'odr_delivery_snapshot_shape',
    CASE WHEN count(*) FILTER(WHERE jsonb_typeof(snapshot_payload)<>'object')=0
      THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE jsonb_typeof(snapshot_payload)<>'object'),
    jsonb_build_object('linkedDocuments',count(*))
  FROM public.sales_delivery_documents WHERE reservation_id IS NOT NULL
  UNION ALL
  SELECT 'inventory_delivery_runtime_inventory','INFO',0,jsonb_build_object(
    'documents',count(*),'linkedDocuments',count(*) FILTER(WHERE reservation_id IS NOT NULL),
    'printAuditRows',(SELECT count(*) FROM public.sales_document_audit
      WHERE document_type='SALES_DELIVERY' AND action='PRINT'))
  FROM public.sales_delivery_documents
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
