-- SELECT only; run whole file on clone first.
WITH checks AS(
 SELECT 'delta_dependency' check_name,CASE WHEN EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260915141000') THEN 'PASS' ELSE 'BLOCKER' END status,jsonb_build_object('required','20260915141000') details
 UNION ALL SELECT 'delta_collision',CASE WHEN to_regprocedure('private.validate_office_untouched_fulfillment(uuid,uuid)') IS NULL THEN 'SETUP'
 WHEN EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260915142000') THEN 'INFO' ELSE 'BLOCKER' END,jsonb_build_object('version','20260915142000')
 UNION ALL SELECT 'active_finance',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,jsonb_build_object('rows',count(*)) FROM public.finance_posting_queue_runs WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
 UNION ALL SELECT 'nonterminal_offline',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,jsonb_build_object('rows',count(*)) FROM public.pos_offline_sale_submissions WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
 UNION ALL SELECT 'mutable_fulfillment_inventory','INFO',jsonb_build_object('orders',count(*),'notBehavioralProof',true) FROM public.backoffice_sales_orders WHERE status='CONFIRMED' AND fulfillment_status='PREPARING'
)SELECT * FROM checks ORDER BY check_name;

