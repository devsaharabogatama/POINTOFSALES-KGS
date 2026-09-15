-- Read-only preflight for Backoffice Confirm -> Reservation + INITIAL/READY DO.
WITH dependency AS (
  SELECT
    to_regprocedure('public.confirm_backoffice_sales_order(uuid,bigint,uuid)') IS NOT NULL confirm_exists,
    to_regprocedure('private.resolve_bundle_components(uuid,uuid,numeric)') IS NOT NULL bundle_resolver_exists,
    to_regprocedure('private.next_sales_delivery_no(uuid,timestamp with time zone)') IS NOT NULL delivery_number_exists,
    EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260909146000') foundation_contract_exists
), runtime AS (
  SELECT
    (SELECT count(*) FROM public.backoffice_sales_reservations) reservations,
    (SELECT count(*) FROM public.backoffice_sales_delivery_orders) deliveries,
    (SELECT count(*) FROM public.backoffice_sales_fulfillment_audit) audits,
    (SELECT count(*) FROM public.backoffice_sales_orders WHERE status='CONFIRMED') historical_confirmed,
    (SELECT count(*) FROM public.backoffice_sales_order_lines line
      JOIN public.products product ON product.company_id=line.company_id AND product.id=line.product_id
      WHERE product.is_bundle) bundle_lines,
    (SELECT count(*) FROM public.finance_posting_queue_runs WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) active_finance,
    (SELECT count(*) FROM public.pos_offline_sale_submissions WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) offline_pending
), checks AS (
  SELECT 'confirm_fulfillment_dependencies'::text check_name,
    CASE WHEN confirm_exists AND bundle_resolver_exists AND delivery_number_exists AND foundation_contract_exists THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('confirmExists',confirm_exists,'bundleResolverExists',bundle_resolver_exists,
      'deliveryNumberExists',delivery_number_exists,'foundationContractExists',foundation_contract_exists) details
  FROM dependency
  UNION ALL
  SELECT 'confirm_fulfillment_empty_runtime',CASE WHEN reservations=0 AND deliveries=0 AND audits=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('reservations',reservations,'deliveries',deliveries,'audits',audits) FROM runtime
  UNION ALL
  SELECT 'confirm_fulfillment_operational_boundary',CASE WHEN active_finance=0 AND offline_pending=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('activeFinanceQueues',active_finance,'nonterminalOfflineSubmissions',offline_pending) FROM runtime
  UNION ALL
  SELECT 'confirm_fulfillment_compatibility_inventory','INFO',
    jsonb_build_object('historicalConfirmedOrders',historical_confirmed,'bundleOrderLines',bundle_lines,
      'rule','Historical confirmed SO is not backfilled; only new Confirm uses composition') FROM runtime
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
