WITH checks AS (
  SELECT 'migration_ledger'::text check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    CASE WHEN count(*)=1 THEN 0 ELSE 1 END::bigint violation_rows,
    jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260909145000'
  UNION ALL
  SELECT 'required_fulfillment_relations',
    CASE WHEN count(*)=5 THEN 'PASS' ELSE 'FAIL' END,
    abs(5-count(*))::bigint,
    jsonb_build_object('expected',5,'relationRows',count(*))
  FROM information_schema.tables WHERE table_schema='public' AND table_name IN(
    'backoffice_sales_reservations','backoffice_sales_reservation_lines',
    'backoffice_sales_delivery_orders','backoffice_sales_delivery_order_lines',
    'backoffice_sales_fulfillment_audit')
  UNION ALL
  SELECT 'fulfillment_rls_state',
    CASE WHEN count(*)=5 THEN 'PASS' ELSE 'FAIL' END,
    abs(5-count(*))::bigint,
    jsonb_build_object('enabledRelations',count(*))
  FROM pg_class relation JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
  WHERE namespace.nspname='public' AND relation.relname IN(
    'backoffice_sales_reservations','backoffice_sales_reservation_lines',
    'backoffice_sales_delivery_orders','backoffice_sales_delivery_order_lines',
    'backoffice_sales_fulfillment_audit') AND relation.relrowsecurity
  UNION ALL
  SELECT 'browser_fulfillment_table_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('privilegeRows',count(*))
  FROM information_schema.role_table_grants
  WHERE table_schema='public' AND grantee IN('anon','authenticated')
    AND table_name IN('backoffice_sales_reservations',
      'backoffice_sales_reservation_lines','backoffice_sales_delivery_orders',
      'backoffice_sales_delivery_order_lines','backoffice_sales_fulfillment_audit')
  UNION ALL
  SELECT 'fulfillment_audit_immutable_trigger',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1 THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('enabledTriggerRows',count(*))
  FROM pg_trigger WHERE tgrelid='public.backoffice_sales_fulfillment_audit'::regclass
    AND tgname='backoffice_sales_fulfillment_audit_immutable'
    AND tgenabled<>'D' AND NOT tgisinternal
  UNION ALL
  SELECT 'retail_delivery_contract_preserved',
    CASE WHEN count(*)=2 THEN 'PASS' ELSE 'FAIL' END,
    abs(2-count(*))::bigint,jsonb_build_object('requiredColumns',count(*))
  FROM information_schema.columns WHERE table_schema='public'
    AND table_name='sales_delivery_documents'
    AND column_name IN('sales_id','invoice_snapshot_id') AND is_nullable='NO'
  UNION ALL
  SELECT 'foundation_zero_backfill',
    CASE WHEN reservations+reservation_lines+deliveries+delivery_lines+audits=0
      THEN 'PASS' ELSE 'FAIL' END,
    (reservations+reservation_lines+deliveries+delivery_lines+audits)::bigint,
    jsonb_build_object('reservations',reservations,'reservationLines',reservation_lines,
      'deliveryOrders',deliveries,'deliveryLines',delivery_lines,'auditRows',audits)
  FROM (SELECT
    (SELECT count(*) FROM public.backoffice_sales_reservations) reservations,
    (SELECT count(*) FROM public.backoffice_sales_reservation_lines) reservation_lines,
    (SELECT count(*) FROM public.backoffice_sales_delivery_orders) deliveries,
    (SELECT count(*) FROM public.backoffice_sales_delivery_order_lines) delivery_lines,
    (SELECT count(*) FROM public.backoffice_sales_fulfillment_audit) audits) inventory
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
