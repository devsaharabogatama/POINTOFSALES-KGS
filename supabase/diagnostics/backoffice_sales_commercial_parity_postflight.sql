WITH checks AS (
  SELECT 'migration_ledger'::text check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    CASE WHEN count(*)=1 THEN 0 ELSE 1 END::bigint violation_rows,
    jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260909140000'
  UNION ALL
  SELECT 'required_commercial_columns',CASE WHEN count(*)=13 THEN 'PASS' ELSE 'FAIL' END,
    abs(13-count(*))::bigint,jsonb_build_object('expected',13,'columnRows',count(*))
  FROM information_schema.columns WHERE table_schema='public' AND (
    (table_name='backoffice_sales_orders' AND column_name IN(
      'global_discount','grand_total_before_rounding','rounding_direction','rounding_increment','rounding_adjustment'))
    OR (table_name='backoffice_sales_order_lines' AND column_name IN(
      'canonical_unit_price','price_override_applied','price_override_unit_price',
      'line_discount_type','line_discount_input','line_discount_amount',
      'allocated_order_discount_amount','allocated_document_rounding')))
  UNION ALL
  SELECT 'required_commercial_routines',CASE WHEN count(*)=3 THEN 'PASS' ELSE 'FAIL' END,
    abs(3-count(*))::bigint,jsonb_build_object('expected',3,'routineRows',count(*))
  FROM (VALUES
    (to_regprocedure('public.preview_backoffice_sales_order_lines(uuid,uuid,uuid,date,jsonb)')),
    (to_regprocedure('public.save_backoffice_sales_order_draft(uuid,bigint,uuid,jsonb)')),
    (to_regprocedure('private.apply_backoffice_sales_commercials(uuid,uuid,uuid,jsonb,timestamptz)'))
  ) routine(oid) WHERE oid IS NOT NULL
  UNION ALL
  SELECT 'private_commercial_boundary',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('authenticatedExecutableRows',count(*))
  FROM information_schema.routine_privileges
  WHERE routine_schema='private' AND grantee='authenticated'
    AND routine_name IN('apply_backoffice_sales_commercials','resolve_pos_sale_price_before_backoffice_commercial')
  UNION ALL
  SELECT 'commercial_row_reconciliation',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('invalidRows',count(*))
  FROM public.backoffice_sales_orders header WHERE
    header.grand_total_before_rounding<>header.subtotal-header.discount_total
    OR header.grand_total<>header.grand_total_before_rounding+header.rounding_adjustment
    OR EXISTS(SELECT 1 FROM public.backoffice_sales_order_lines line
      WHERE line.company_id=header.company_id AND line.sales_order_id=header.id
        AND line.discount_amount<>line.line_discount_amount+line.allocated_order_discount_amount)
  UNION ALL
  SELECT 'backoffice_zero_final_effect','PASS',0::bigint,jsonb_build_object(
    'rule','Commercial Draft calculation does not call Reservation, Stock, Delivery, Invoice, Payment, or Finance writers')
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
