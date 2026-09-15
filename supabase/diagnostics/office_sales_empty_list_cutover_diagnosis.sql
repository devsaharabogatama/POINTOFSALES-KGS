-- SELECT-only diagnosis: Office list is backoffice_sales_orders, not Retail sales_headers.
-- Impact: no writers/RPC, tenant setting, stock/reservation/FIFO/payment/Finance mutation.
-- INFO inventories are not behavioral readiness PASS.
SELECT company.id company_id,company.company_name company_name,'INFO'::text status,
 jsonb_build_object(
 'activeMode',setting.active_mode,'effectiveAt',setting.mode_effective_at,
 'officeQuotationCount',(SELECT count(*) FROM public.backoffice_sales_orders document
 WHERE document.company_id=company.id AND document.order_no IS NULL),
 'officeSOCount',(SELECT count(*) FROM public.backoffice_sales_orders document
 WHERE document.company_id=company.id AND document.order_no IS NOT NULL),
 'officeStatuses',COALESCE((SELECT jsonb_agg(grouped) FROM (
 SELECT document.status,document.fulfillment_status,count(*) rows
 FROM public.backoffice_sales_orders document WHERE document.company_id=company.id
 GROUP BY document.status,document.fulfillment_status) grouped),'[]'::jsonb),
 'retailStatuses',COALESCE((SELECT jsonb_agg(grouped) FROM (
 SELECT sale.sales_process_mode,sale.document_status,sale.order_runtime_status,count(*) rows
 FROM public.sales_headers sale WHERE sale.company_id=company.id
 GROUP BY sale.sales_process_mode,sale.document_status,sale.order_runtime_status) grouped),'[]'::jsonb),
 'lastPlan', (SELECT jsonb_build_object('id',plan.id,'status',plan.status,
 'createdAt',plan.created_at,'appliedAt',plan.applied_at,
 'sourceMode',plan.source_mode,'targetMode',plan.target_mode,
 'items',COALESCE((SELECT jsonb_agg(grouped) FROM (
 SELECT item.decision,item.item_status,count(*) rows,
 jsonb_agg(jsonb_build_object('source',item.source_document_no,
 'target',item.target_document_no,'targetId',item.target_document_id,
 'blockerCodes',to_jsonb(item)->'blocker_codes')) documents
 FROM public.sales_process_cutover_items item
 WHERE item.company_id=company.id AND item.cutover_plan_id=plan.id
 GROUP BY item.decision,item.item_status) grouped),'[]'::jsonb))
 FROM public.sales_process_cutover_plans plan WHERE plan.company_id=company.id
 ORDER BY plan.created_at DESC,plan.id DESC LIMIT 1)
 ) details
FROM public.companies company
LEFT JOIN public.company_sales_process_settings setting ON setting.company_id=company.id
ORDER BY company.id;

