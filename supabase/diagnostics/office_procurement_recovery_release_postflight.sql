-- SELECT-only ONE result set. Entire file; INFO/zero inventory is not behavioral proof.
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
required(signature,authenticated_execute) AS (VALUES
('public.get_retained_sales_process_recovery_candidates()',true),
('public.recover_retained_sales_process_order(uuid,bigint,bigint,bigint,uuid)',true),
('public.get_sales_document_activity()',true),
('private.office_snapshot_before_recovery_activity(uuid,uuid)',false),
('private.retail_activity_before_recovery()',false),
('private.backoffice_sales_order_snapshot(uuid,uuid)',false),
('private.sync_office_cutover_procurement(uuid,uuid,uuid,uuid)',false)),
checks AS (
SELECT 'runtime:'||signature check_name,CASE WHEN oid IS NOT NULL AND md5(replace(pg_get_functiondef(oid),chr(13)||chr(10),chr(10)))=digest THEN 'PASS' ELSE 'FAIL' END status,
jsonb_build_object('expectedDigest',digest,'actualDigest',CASE WHEN oid IS NOT NULL THEN md5(replace(pg_get_functiondef(oid),chr(13)||chr(10),chr(10))) END,'rawDigest',CASE WHEN oid IS NOT NULL THEN md5(pg_get_functiondef(oid)) END,'comparison','CRLF_TO_LF_ONLY') details FROM actual
UNION ALL SELECT 'release_ledger',CASE WHEN count(*)=6 THEN 'PASS' ELSE 'FAIL' END,
jsonb_build_object('installed',count(*),'expected',6) FROM private.kgs_schema_migrations WHERE version IN ('20260915140000','20260915141000','20260915142000','20260916100000','20260916101000','20260916102000')
UNION ALL SELECT 'acl:'||signature,CASE WHEN to_regprocedure(signature) IS NOT NULL
AND NOT COALESCE(has_function_privilege('anon',to_regprocedure(signature),'EXECUTE'),true)
AND COALESCE(has_function_privilege('authenticated',to_regprocedure(signature),'EXECUTE'),NOT authenticated_execute)=authenticated_execute
THEN 'PASS' ELSE 'FAIL' END,'{}'::jsonb FROM required
UNION ALL SELECT 'lineage_table_boundary',CASE WHEN relrowsecurity
AND NOT has_table_privilege('anon',oid,'SELECT,INSERT,UPDATE,DELETE')
AND NOT has_table_privilege('authenticated',oid,'SELECT,INSERT,UPDATE,DELETE') THEN 'PASS' ELSE 'FAIL' END,'{}'::jsonb
FROM pg_class WHERE oid='public.sales_cutover_procurement_links'::regclass
UNION ALL SELECT 'recovery_target_reconciliation',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
jsonb_build_object('invalidRows',count(*),'zeroRowsNotBehaviorProof',true)
FROM public.sales_process_cutover_audit audit LEFT JOIN public.backoffice_sales_orders target
ON target.company_id=audit.company_id AND target.id=(audit.after_state->'converterResult'->>'targetDocumentId')::uuid
WHERE audit.action='APPLY_ITEM' AND audit.after_state->>'recovery'='true' AND target.id IS NULL
) SELECT * FROM checks ORDER BY check_name;
