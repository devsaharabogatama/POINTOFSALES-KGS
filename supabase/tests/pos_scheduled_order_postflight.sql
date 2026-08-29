-- POS scheduled TEMPO order postflight.
-- SAFETY: SELECT-only.
WITH checks AS (
  SELECT 'migration_ledger'::TEXT check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    CASE WHEN count(*)=1 THEN 0 ELSE 1 END::BIGINT violation_rows,
    jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260827154000'
  UNION ALL
  SELECT 'required_scheduled_order_columns',CASE WHEN count(*)=5 THEN 'PASS' ELSE 'FAIL' END,
    (5-count(*))::BIGINT,jsonb_build_object('expected',5,'columnRows',count(*))
  FROM information_schema.columns WHERE table_schema='public' AND table_name='sales_headers'
    AND column_name IN('planned_order_date','order_timing_mode',
      'planned_order_selected_by','planned_order_selected_at','scheduled_activated_at')
  UNION ALL
  SELECT 'required_scheduled_order_routines',CASE WHEN count(*)=5 THEN 'PASS' ELSE 'FAIL' END,
    (5-count(*))::BIGINT,jsonb_build_object('expected',5,'routineRows',count(*))
  FROM pg_proc procedure JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
  WHERE (namespace.nspname,procedure.proname) IN(
    ('public','save_pos_sale_draft_with_pricelist'),('public','list_pos_sale_drafts'),
    ('public','post_pos_sale'),('private','validate_pos_scheduled_order_dates'),
    ('private','post_pos_sale_before_schedule_core'))
  UNION ALL
  SELECT 'scheduled_order_final_effect_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::BIGINT,
    jsonb_build_object('rowCount',count(*))
  FROM public.sales_headers sale WHERE sale.document_status='DRAFT'
    AND sale.order_timing_mode='SCHEDULED' AND (EXISTS(SELECT 1 FROM public.financial_events event
      WHERE event.company_id=sale.company_id AND event.source_id=sale.id)
      OR EXISTS(SELECT 1 FROM public.stock_movements movement
      WHERE movement.company_id=sale.company_id AND movement.reference_id=sale.id))
  UNION ALL
  SELECT 'scheduled_order_contract',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::BIGINT,jsonb_build_object('invalidRows',count(*))
  FROM public.sales_headers sale WHERE
    (sale.order_timing_mode='SCHEDULED' AND (NOT sale.is_tempo OR sale.planned_order_date IS NULL))
    OR (sale.order_timing_mode='IMMEDIATE' AND sale.planned_order_date IS NOT NULL)
  UNION ALL
  SELECT 'scheduled_order_runtime_inventory','INFO',0,jsonb_build_object(
    'scheduledDrafts',count(*) FILTER(WHERE document_status='DRAFT' AND order_timing_mode='SCHEDULED'),
    'activeScheduledDrafts',count(*) FILTER(WHERE document_status='DRAFT'
      AND order_timing_mode='SCHEDULED' AND planned_order_date<=CURRENT_DATE),
    'postedScheduledOrders',count(*) FILTER(WHERE document_status='POSTED'
      AND order_timing_mode='SCHEDULED'))
  FROM public.sales_headers
)
SELECT check_name,status,violation_rows,details FROM checks ORDER BY
  CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
