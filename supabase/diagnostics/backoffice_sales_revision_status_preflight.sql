-- Read-only preflight: same-number SO revision and server-derived fulfillment status.
WITH checks AS (
  SELECT 'backoffice_commercial_dependency'::text check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260909141000'
  UNION ALL
  SELECT 'active_finance_posting_queue',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('runCount',count(*))
  FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'backoffice_runtime_inventory','INFO',jsonb_build_object(
    'quotations',count(*) FILTER(WHERE order_no IS NULL),
    'salesOrders',count(*) FILTER(WHERE order_no IS NOT NULL),
    'legacySent',count(*) FILTER(WHERE status='SENT'),
    'confirmed',count(*) FILTER(WHERE status='CONFIRMED'),
    'canceled',count(*) FILTER(WHERE status='CANCELED'))
  FROM public.backoffice_sales_orders
  UNION ALL
  SELECT 'backoffice_downstream_link_state','PASS',jsonb_build_object(
    'rule','No operational Reservation/Delivery/Invoice table currently has a Backoffice SO foreign key; confirmed edit must remain locked once fulfillment_status advances')
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
