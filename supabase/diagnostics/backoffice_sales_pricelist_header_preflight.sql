-- Read-only gate for the Backoffice Quotation/SO Pricelist header cutover.
WITH dependency AS (
  SELECT
    to_regprocedure('public.get_backoffice_sales_order_workspace()') IS NOT NULL AS workspace_exists,
    to_regprocedure('public.save_backoffice_sales_order_draft(uuid,bigint,uuid,jsonb)') IS NOT NULL AS save_exists,
    to_regprocedure('private.resolve_pos_sale_price(uuid,uuid,uuid,uuid,numeric,timestamp with time zone)') IS NOT NULL AS resolver_exists
), runtime AS (
  SELECT
    (SELECT count(*) FROM public.finance_posting_queue_runs WHERE status IN ('PREVIEWED','APPROVED','PROCESSING')) AS finance_runs,
    (SELECT count(*) FROM public.pos_offline_sale_submissions WHERE status IN ('QUEUED','SYNCING','NEEDS_CONFIRMATION')) AS offline_runs,
    (SELECT count(*) FROM public.backoffice_sales_orders) AS document_count
)
SELECT 'backoffice_sales_pricelist_header_dependencies' AS check_name,
  CASE WHEN workspace_exists AND save_exists AND resolver_exists THEN 'PASS' ELSE 'BLOCKER' END AS status,
  jsonb_build_object('workspaceExists',workspace_exists,'saveExists',save_exists,'resolverExists',resolver_exists) AS details
FROM dependency
UNION ALL
SELECT 'active_finance_or_offline_queue',
  CASE WHEN finance_runs=0 AND offline_runs=0 THEN 'PASS' ELSE 'BLOCKER' END,
  jsonb_build_object('financeRuns',finance_runs,'offlineRuns',offline_runs)
FROM runtime
UNION ALL
SELECT 'backoffice_sales_pricelist_runtime_inventory','INFO',
  jsonb_build_object('documents',document_count,
    'documentsWithPricelist',(SELECT count(*) FROM public.backoffice_sales_orders WHERE pricelist_id IS NOT NULL),
    'activePricelists',(SELECT count(*) FROM public.pricelists WHERE is_active))
FROM runtime;
