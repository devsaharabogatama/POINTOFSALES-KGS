-- Run entire file. Read-only, before or after this additive migration.
WITH checks AS (
 SELECT 'history_dependencies' check_name,
 count(*) FILTER(WHERE to_regclass(name) IS NULL) violation_rows
 FROM unnest(ARRAY['public.sales_headers','public.sales_details','public.sales_invoice_snapshots',
 'public.sales_process_cutover_items','public.sales_process_cutover_audit','public.companies']) name
 UNION ALL SELECT 'history_office_reader_dependency',
 CASE WHEN to_regprocedure('public.get_backoffice_sales_orders_v3(text,text,text,text,date,date,text,integer)') IS NULL THEN 1 ELSE 0 END
 UNION ALL SELECT 'history_permission_dependency',
 CASE WHEN to_regprocedure('private.acp_require_permission_capability(uuid,text,text)') IS NULL THEN 1 ELSE 0 END
)
SELECT check_name,CASE WHEN violation_rows=0 THEN 'PASS' ELSE 'BLOCKER' END status,violation_rows
FROM checks ORDER BY check_name;
