-- READ ONLY. One complete result. Does not install/recover/mutate anything.
WITH expected(signature,digest) AS (VALUES
('public.cancel_backoffice_sales_order(uuid,bigint,uuid,text)','baa03a4d590294eceaffd282e18c338e'),
('public.get_retained_sales_process_recovery_candidates()','6d5754be9bb39ceb349fffd3314175b3'),
('public.get_sales_document_activity()','e0d3679a32b286fa8bbbbff38b6b29e5'),
('public.recover_retained_sales_process_order(uuid,bigint,bigint,bigint,uuid)','23b49a323c689b20a379ea7c6cd3c51a'),
('public.save_backoffice_sales_order_draft(uuid,bigint,uuid,jsonb)','f893bd8e378d7bb39672f22e5c019bcc'),
('private.backoffice_sales_order_snapshot(uuid,uuid)','9119cadd4d7fb31657d5017fe1985730'),
('private.convert_backoffice_order_to_retail_sale(uuid,uuid,uuid,uuid)','a98149d9d85d6573098aab3b2bdbcbb5'),
('private.convert_retail_sale_to_backoffice_order(uuid,uuid,uuid,uuid)','bf98042e7da5544a31b9f286cad3b5d6'),
('private.get_sales_process_cutover_plan_core(uuid,uuid)','f504b314061d39351f5484d99b771916'),
('private.get_sales_process_cutover_preview_core(uuid,text)','070abe6ff3564930c88d54c7296c5a2b'),
('private.recompose_office_pre_dispatch_fulfillment(uuid,uuid)','54d23f9ddde0599a228cd18d2a5ddaa0'),
('private.refresh_sales_order_procurement_demand(uuid,uuid,uuid,uuid,text)','1c89a0804fd4d396c9ec02b861d1c894'),
('private.release_office_untouched_fulfillment(uuid,uuid,uuid,text)','5593afcf08ddf21998bdbd15f19fe3e5'),
('private.sync_office_cutover_procurement(uuid,uuid,uuid,uuid)','aec5e7d0fbcf47428afafc89ff3ff146'),
('private.validate_office_untouched_fulfillment(uuid,uuid)','fc76c9d2bc6724e2376b1ecef1be3b81')
), actual AS (SELECT expected.*,to_regprocedure(signature) oid FROM expected),
checks AS (
SELECT 'function:'||signature check_name,
CASE WHEN oid IS NULL THEN 'MISSING' WHEN md5(pg_get_functiondef(oid))=digest THEN 'MATCH' ELSE 'DIFFERENT' END status,
jsonb_build_object('expectedDigest',digest,'actualDigest',CASE WHEN oid IS NOT NULL THEN md5(pg_get_functiondef(oid)) END,
'lfDigest',CASE WHEN oid IS NOT NULL THEN md5(replace(pg_get_functiondef(oid),chr(13)||chr(10),chr(10))) END,
'crCount',CASE WHEN oid IS NOT NULL THEN length(pg_get_functiondef(oid))-length(replace(pg_get_functiondef(oid),chr(13),'')) END) details
FROM actual
UNION ALL SELECT 'installation_ledger','INFO',jsonb_build_object('installedVersions',
COALESCE(jsonb_agg(version ORDER BY version),'[]'::jsonb),'expectedCount',6)
FROM private.kgs_schema_migrations WHERE version IN
('20260915140000','20260915141000','20260915142000','20260916100000','20260916101000','20260916102000')
UNION ALL SELECT 'execution_environment','INFO',jsonb_build_object('searchPath',current_setting('search_path'),
'user',current_user,'database',current_database(),'server',inet_server_addr(),'time',clock_timestamp())
) SELECT * FROM checks ORDER BY check_name;

