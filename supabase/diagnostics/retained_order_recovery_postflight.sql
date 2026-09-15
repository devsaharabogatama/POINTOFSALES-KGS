-- SELECT-only, INFO counts are not behavior evidence.
WITH checks AS (
 SELECT 'recovery_ledger' check_name,CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,jsonb_build_object('rows',count(*)) details
 FROM private.kgs_schema_migrations WHERE version='20260916101000'
 UNION ALL SELECT 'recovery_public_boundary',CASE WHEN
 has_function_privilege('authenticated','public.recover_retained_sales_process_order(uuid,bigint,bigint,bigint,uuid)','EXECUTE')
 AND NOT has_function_privilege('anon','public.recover_retained_sales_process_order(uuid,bigint,bigint,bigint,uuid)','EXECUTE') THEN 'PASS' ELSE 'FAIL' END,'{}'::jsonb
 UNION ALL SELECT 'recovery_private_boundary',CASE WHEN
 NOT has_function_privilege('authenticated','private.get_cutover_plan_before_retained_recovery(uuid,uuid)','EXECUTE')
 AND NOT has_function_privilege('anon','private.get_sales_process_cutover_plan_core(uuid,uuid)','EXECUTE') THEN 'PASS' ELSE 'FAIL' END,'{}'::jsonb
 UNION ALL SELECT 'recovery_target_reconciliation',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,jsonb_build_object('invalidRows',count(*))
 FROM public.sales_process_cutover_audit audit
 LEFT JOIN public.backoffice_sales_orders target ON target.company_id=audit.company_id AND target.id=(audit.after_state->'converterResult'->>'targetDocumentId')::uuid
 WHERE audit.action='APPLY_ITEM' AND audit.after_state->>'recovery'='true' AND target.id IS NULL
 UNION ALL SELECT 'recovery_inventory','INFO',jsonb_build_object('recoveredItems',count(*),'notBehavioralProof',true)
 FROM public.sales_process_cutover_audit WHERE action='APPLY_ITEM' AND after_state->>'recovery'='true'
) SELECT * FROM checks ORDER BY check_name;
