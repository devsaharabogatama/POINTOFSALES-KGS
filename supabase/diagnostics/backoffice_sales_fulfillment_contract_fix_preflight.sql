WITH checks AS (
  SELECT 'foundation_dependency'::text check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('ledgerRows',count(*),'expected',1) details
  FROM private.kgs_schema_migrations WHERE version='20260909145000'
  UNION ALL
  SELECT 'foundation_business_rows',
    CASE WHEN reservations+deliveries=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('reservations',reservations,'deliveryOrders',deliveries)
  FROM (SELECT
    (SELECT count(*) FROM public.backoffice_sales_reservations) reservations,
    (SELECT count(*) FROM public.backoffice_sales_delivery_orders) deliveries) rows
  UNION ALL
  SELECT 'active_finance_posting_queue',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('runCount',count(*))
  FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'nonterminal_offline_submission',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('submissionCount',count(*))
  FROM public.pos_offline_sale_submissions
  WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
  UNION ALL
  SELECT 'current_delivery_contract','REVIEW',jsonb_build_object(
    'statusDefault',(SELECT column_default FROM information_schema.columns
      WHERE table_schema='public' AND table_name='backoffice_sales_delivery_orders'
        AND column_name='status'),
    'kindConstraint',(SELECT pg_get_constraintdef(oid)
      FROM pg_constraint WHERE conrelid='public.backoffice_sales_delivery_orders'::regclass
        AND conname='backoffice_sales_delivery_orders_kind_check'))
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
