-- Read-only: distinguish line-ending/hash rendering from actual missing routines.
SELECT procedure.oid::regprocedure::text signature,
 md5(pg_get_functiondef(procedure.oid)) raw_digest,
 md5(replace(pg_get_functiondef(procedure.oid),chr(13)||chr(10),chr(10))) lf_digest,
 length(pg_get_functiondef(procedure.oid))-length(replace(pg_get_functiondef(procedure.oid),chr(13),'')) cr_count,
 current_setting('search_path') session_search_path
FROM pg_proc procedure JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
WHERE namespace.nspname IN('private','public') AND procedure.proname IN(
 'convert_retail_sale_to_backoffice_order','convert_backoffice_order_to_retail_sale',
 'get_sales_process_cutover_preview_core','get_sales_process_cutover_plan_core',
 'recover_retained_sales_process_order','get_retained_sales_process_recovery_candidates',
 'save_backoffice_sales_order_draft','cancel_backoffice_sales_order',
 'validate_office_untouched_fulfillment','recompose_office_pre_dispatch_fulfillment',
 'release_office_untouched_fulfillment','sync_office_cutover_procurement',
 'refresh_sales_order_procurement_demand','backoffice_sales_order_snapshot','get_sales_document_activity');
