WITH contract AS (
  SELECT
    (SELECT column_default FROM information_schema.columns
      WHERE table_schema='public' AND table_name='backoffice_sales_delivery_orders'
        AND column_name='status') status_default,
    (SELECT pg_get_constraintdef(oid) FROM pg_constraint
      WHERE conrelid='public.backoffice_sales_delivery_orders'::regclass
        AND conname='backoffice_sales_delivery_orders_kind_check') kind_constraint
), checks AS (
  SELECT 'migration_ledger'::text check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    CASE WHEN count(*)=1 THEN 0 ELSE 1 END::bigint violation_rows,
    jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260909146000'
  UNION ALL
  SELECT 'initial_delivery_default_contract',
    CASE WHEN status_default='''READY''::text' THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN status_default='''READY''::text' THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('statusDefault',status_default)
  FROM contract
  UNION ALL
  SELECT 'delivery_kind_contract',
    CASE WHEN kind_constraint LIKE '%INITIAL%'
      AND kind_constraint LIKE '%BACKORDER%'
      AND kind_constraint NOT LIKE '%CORRECTION%' THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN kind_constraint LIKE '%INITIAL%'
      AND kind_constraint LIKE '%BACKORDER%'
      AND kind_constraint NOT LIKE '%CORRECTION%' THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('kindConstraint',kind_constraint)
  FROM contract
  UNION ALL
  SELECT 'foundation_zero_business_rows',
    CASE WHEN reservations+deliveries=0 THEN 'PASS' ELSE 'FAIL' END,
    (reservations+deliveries)::bigint,
    jsonb_build_object('reservations',reservations,'deliveryOrders',deliveries)
  FROM (SELECT
    (SELECT count(*) FROM public.backoffice_sales_reservations) reservations,
    (SELECT count(*) FROM public.backoffice_sales_delivery_orders) deliveries) rows
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
