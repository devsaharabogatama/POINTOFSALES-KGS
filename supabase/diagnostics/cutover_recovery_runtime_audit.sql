-- SELECT-only actual recovery consumers and guard contracts.
SELECT procedure.oid::regprocedure::text signature,pg_get_functiondef(procedure.oid) definition
FROM pg_proc procedure JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
WHERE namespace.nspname IN('public','private') AND procedure.proname IN(
 'get_sales_process_cutover_plan_core','get_sales_process_cutover_preview_core',
 'convert_backoffice_order_to_retail_sale','trg_guard_sales_process_history',
 'get_document_activity','get_document_history','get_document_activity_log');
