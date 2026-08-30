-- Confirmed ODR Order versus editable Draft boundary postflight.
-- SAFETY: SELECT-only.
WITH routine_state AS (
  SELECT routine.proname,pg_get_functiondef(routine.oid) definition
  FROM pg_proc routine JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
  WHERE namespace.nspname='public' AND routine.proname IN(
    'save_pos_sale_draft','list_pos_sale_drafts')
),checks AS (
  SELECT 'migration_ledger'::TEXT check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,0::BIGINT violation_rows,
    jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260830100000'
  UNION ALL
  SELECT 'draft_list_confirmed_order_guard',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,0,
    jsonb_build_object('routineRows',count(*))
  FROM routine_state WHERE proname='list_pos_sale_drafts'
    AND definition~'confirmed_at IS NULL'
    AND definition~'order_runtime_status IN'
  UNION ALL
  SELECT 'draft_save_confirmed_order_guard',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,0,
    jsonb_build_object('routineRows',count(*))
  FROM routine_state WHERE proname='save_pos_sale_draft'
    AND definition~'CONFIRMED_SALES_ORDER_IMMUTABLE'
  UNION ALL
  SELECT 'pricelist_save_uses_guarded_draft_runtime',
    CASE WHEN pg_get_functiondef(
      'private.save_pos_sale_draft_before_schedule_core(jsonb)'::regprocedure)
      ~'public.save_pos_sale_draft' THEN 'PASS' ELSE 'FAIL' END,0,
    jsonb_build_object('routineRows',1)
  UNION ALL
  SELECT 'input_draft_reservation_reference',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('rowCount',count(*))
  FROM public.sales_headers sale
  JOIN public.sale_stock_requirements requirement
    ON requirement.company_id=sale.company_id AND requirement.sales_id=sale.id
  JOIN public.sales_stock_reservation_lines line
    ON line.company_id=requirement.company_id
   AND line.stock_requirement_id=requirement.id
  WHERE sale.order_runtime_status IN('DRAFT_INPUT','SCHEDULED')
    AND sale.confirmed_at IS NULL
  UNION ALL
  SELECT 'confirmed_order_reservation_preserved',
    'INFO',0,jsonb_build_object('orderCount',count(DISTINCT sale.id),
      'reservationLineCount',count(line.id))
  FROM public.sales_headers sale
  JOIN public.sale_stock_requirements requirement
    ON requirement.company_id=sale.company_id AND requirement.sales_id=sale.id
  JOIN public.sales_stock_reservation_lines line
    ON line.company_id=requirement.company_id
   AND line.stock_requirement_id=requirement.id
  WHERE sale.confirmed_at IS NOT NULL
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
