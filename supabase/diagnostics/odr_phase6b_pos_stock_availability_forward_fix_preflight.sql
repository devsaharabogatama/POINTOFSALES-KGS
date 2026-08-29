-- ODR-6B.1 POS Available to Sell forward-fix preflight.
-- SAFETY: SELECT-only.
WITH checks AS (
  SELECT 'stock_real_dependency'::TEXT check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('ledgerRows',count(*),
      'requiredVersion','20260829090000') details
  FROM private.kgs_schema_migrations WHERE version='20260829090000'

  UNION ALL
  SELECT 'pos_reservation_schema',
    CASE WHEN count(*)=17 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('expected',17,'columnRows',count(*))
  FROM information_schema.columns
  WHERE table_schema='public' AND (
    (table_name='cashier_sessions' AND column_name IN(
      'id','company_id','cashier_id','store_id','sales_warehouse_id',
      'status','opened_at')) OR
    (table_name='sales_stock_reservations' AND column_name IN(
      'id','company_id','status')) OR
    (table_name='sales_stock_reservation_lines' AND column_name IN(
      'company_id','reservation_id','stock_product_id','warehouse_id',
      'reserved_base_qty','released_base_qty','dispatched_base_qty')))

  UNION ALL
  SELECT 'pos_stock_availability_runtime',
    CASE WHEN to_regprocedure(
      'public.get_pos_stock_availability(uuid,uuid)') IS NULL
      THEN 'SETUP' ELSE 'PASS' END,
    jsonb_build_object('routineExists',to_regprocedure(
      'public.get_pos_stock_availability(uuid,uuid)') IS NOT NULL)

  UNION ALL
  SELECT 'browser_reservation_table_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('privilegeRows',count(*))
  FROM information_schema.role_table_grants privilege
  WHERE privilege.table_schema='public'
    AND privilege.table_name IN('sales_stock_reservations',
      'sales_stock_reservation_lines','sales_stock_reservation_audit')
    AND privilege.grantee IN('anon','authenticated','PUBLIC')
),inventory AS (
  SELECT 'pos_stock_availability_scope'::TEXT check_name,'INFO'::TEXT status,
    jsonb_build_object(
      'openCashierSessions',(SELECT count(*) FROM public.cashier_sessions
        WHERE status='OPEN'::public.session_status),
      'openReservations',(SELECT count(*) FROM public.sales_stock_reservations
        WHERE status='OPEN'),
      'partialReservations',(SELECT count(*) FROM public.sales_stock_reservations
        WHERE status='PARTIALLY_DISPATCHED')) details
)
SELECT * FROM (SELECT * FROM checks UNION ALL SELECT * FROM inventory) result
ORDER BY check_name;
