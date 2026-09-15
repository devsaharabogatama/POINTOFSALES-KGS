-- SELECT-only runtime contracts; zero inventory is not behavioral proof.
WITH required(signature) AS(VALUES
 ('private.sync_office_cutover_procurement(uuid,uuid,uuid,uuid)'),
 ('private.refresh_procurement_before_cutover_retention(uuid,uuid,uuid,uuid,text)'),
 ('private.save_office_order_before_procurement_retention(uuid,bigint,uuid,jsonb)'),
 ('private.cancel_office_order_before_procurement_retention(uuid,bigint,uuid,text)')),
checks AS(
 SELECT 'retention_ledger' check_name,CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,jsonb_build_object('rows',count(*)) details
 FROM private.kgs_schema_migrations WHERE version='20260915141000'
 UNION ALL SELECT 'retention_private_routines',CASE WHEN bool_and(to_regprocedure(signature) IS NOT NULL) THEN 'PASS' ELSE 'FAIL' END,jsonb_build_object('required',count(*)) FROM required
 UNION ALL SELECT 'retention_private_acl',CASE WHEN NOT bool_or(COALESCE(has_function_privilege('authenticated',to_regprocedure(signature),'EXECUTE'),true)
 OR COALESCE(has_function_privilege('anon',to_regprocedure(signature),'EXECUTE'),true)) THEN 'PASS' ELSE 'FAIL' END,jsonb_build_object('checked',count(*)) FROM required
 UNION ALL SELECT 'procurement_classifier',CASE WHEN private.classify_sales_process_conversion_candidate('RETAIL_CONFIRM_INVOICE','BACKOFFICE_DELIVERED_QTY_INVOICE',false,false,false,false,false,true,false,true)->>'decision'='CONVERT' THEN 'PASS' ELSE 'FAIL' END,
 private.classify_sales_process_conversion_candidate('RETAIL_CONFIRM_INVOICE','BACKOFFICE_DELIVERED_QTY_INVOICE',false,false,false,false,false,true,false,true)
 UNION ALL SELECT 'converter_preservation_contract',CASE WHEN position('link_sales_cutover_procurement' IN pg_get_functiondef(to_regprocedure('private.convert_retail_sale_to_backoffice_order(uuid,uuid,uuid,uuid)')))>0
 AND position('CUTOVER_PROCUREMENT_PRESERVATION_FAILED' IN pg_get_functiondef(to_regprocedure('private.convert_retail_sale_to_backoffice_order(uuid,uuid,uuid,uuid)')))>0 THEN 'PASS' ELSE 'FAIL' END,'{}'::jsonb
 UNION ALL SELECT 'procurement_link_inventory','INFO',jsonb_build_object('links',count(*),'notBehavioralProof',true) FROM public.sales_cutover_procurement_links
)SELECT * FROM checks ORDER BY check_name;

