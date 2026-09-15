-- SELECT-only developer audit of exact active functions used by recovery.
SELECT function.oid::regprocedure::text signature,pg_get_functiondef(function.oid) definition
FROM pg_proc function WHERE function.oid IN (
  to_regprocedure('private.convert_retail_sale_to_backoffice_order(uuid,uuid,uuid,uuid)'),
  to_regprocedure('private.refresh_sales_order_procurement_demand(uuid,uuid,uuid,uuid,text)'),
  to_regprocedure('private.get_sales_process_cutover_preview_core(uuid,text)'),
  to_regprocedure('private.get_purchase_daily_replenishment_candidates_core(uuid,date)'),
  to_regprocedure('public.save_backoffice_sales_order_draft(uuid,bigint,uuid,jsonb)'),
  to_regprocedure('public.cancel_backoffice_sales_order(uuid,bigint,uuid,text)'),
  to_regprocedure('private.transition_backoffice_sales_order(uuid,bigint,uuid,text,text)'),
  to_regprocedure('public.save_backoffice_sales_order_draft_before_pricelist_header(uuid,bigint,uuid,jsonb)'),
  to_regprocedure('private.compose_backoffice_sales_confirm_fulfillment(uuid,uuid)')
) ORDER BY signature;
