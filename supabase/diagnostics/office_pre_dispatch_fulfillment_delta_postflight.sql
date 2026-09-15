-- SELECT-only: runtime/security/referential reconciliation, not behavioral proof.
WITH required(signature) AS(VALUES
 ('private.validate_office_untouched_fulfillment(uuid,uuid)'),
 ('private.recompose_office_pre_dispatch_fulfillment(uuid,uuid)'),
 ('private.release_office_untouched_fulfillment(uuid,uuid,uuid,text)'),
 ('private.save_office_order_before_pre_dispatch_delta(uuid,bigint,uuid,jsonb)')),
 checks AS(
 SELECT 'delta_ledger' check_name,CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,jsonb_build_object('rows',count(*)) details FROM private.kgs_schema_migrations WHERE version='20260915142000'
 UNION ALL SELECT 'delta_private_contract',CASE WHEN bool_and(to_regprocedure(signature) IS NOT NULL AND
 NOT COALESCE(has_function_privilege('authenticated',to_regprocedure(signature),'EXECUTE'),true) AND
 NOT COALESCE(has_function_privilege('anon',to_regprocedure(signature),'EXECUTE'),true)) THEN 'PASS' ELSE 'FAIL' END,jsonb_build_object('required',count(*)) FROM required
 UNION ALL SELECT 'delta_canonical_save_hook',CASE WHEN position('recompose_office_pre_dispatch_fulfillment' IN pg_get_functiondef(to_regprocedure('public.save_backoffice_sales_order_draft_before_pricelist_header(uuid,bigint,uuid,jsonb)')))>0 THEN 'PASS' ELSE 'FAIL' END,'{}'::jsonb
 UNION ALL SELECT 'delta_canonical_cancel_hook',CASE WHEN position('release_office_untouched_fulfillment' IN pg_get_functiondef(to_regprocedure('private.transition_backoffice_sales_order(uuid,bigint,uuid,text,text)')))>0 THEN 'PASS' ELSE 'FAIL' END,'{}'::jsonb
 UNION ALL SELECT 'delta_mutable_line_reconciliation',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,jsonb_build_object('invalidRows',count(*))
 FROM public.backoffice_sales_delivery_order_lines delivery
 JOIN public.backoffice_sales_delivery_orders header ON header.company_id=delivery.company_id AND header.id=delivery.delivery_order_id
 JOIN public.backoffice_sales_reservation_lines reservation ON reservation.company_id=delivery.company_id AND reservation.id=delivery.reservation_line_id
 WHERE header.status IN('PREPARING','READY') AND (delivery.planned_base_qty<>reservation.ordered_base_qty OR delivery.sales_order_line_id<>reservation.sales_order_line_id)
 UNION ALL SELECT 'delta_inventory','INFO',jsonb_build_object('revisionAudits',count(*),'notBehavioralProof',true) FROM public.backoffice_sales_fulfillment_audit WHERE action='UPDATE_PLAN' AND reason='Revisi SO sebelum pengiriman'
)SELECT * FROM checks ORDER BY check_name;

