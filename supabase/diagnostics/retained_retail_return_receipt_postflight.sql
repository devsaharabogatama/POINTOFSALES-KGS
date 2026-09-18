-- Read-only postflight for 20260918130000.
WITH checks AS (
 SELECT 'retained_receipt_migration_ledger' check_name,
  CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END status,abs(1-count(*))::bigint violation_rows,
  jsonb_build_object('ledgerRows',count(*)) details FROM private.kgs_schema_migrations
  WHERE version='20260918130000'
 UNION ALL
 SELECT 'retained_receipt_column_contract',CASE WHEN count(*)=5 THEN 'PASS' ELSE 'BLOCKER' END,
  (5-count(*))::bigint,jsonb_build_object('present',count(*),'expected',5)
 FROM information_schema.columns WHERE table_schema='public'
  AND table_name='backoffice_sales_return_receipt_fifo_restorations'
  AND column_name IN('cost_lineage','source_retail_sales_detail_id','source_stock_requirement_id',
   'source_line_base_qty','source_line_cost_total')
 UNION ALL
 SELECT 'retained_receipt_routine_contract',CASE WHEN count(*)=2 THEN 'PASS' ELSE 'BLOCKER' END,
  (2-count(*))::bigint,jsonb_build_object('present',count(*),'expected',2)
 FROM (SELECT unnest(ARRAY[
  to_regprocedure('private.post_retained_retail_return_receipt_core(uuid,bigint,uuid,date,jsonb,text)'),
  to_regprocedure('public.post_backoffice_sales_return_receipt(uuid,bigint,uuid,date,jsonb,text)')]) routine) found
 WHERE routine IS NOT NULL
 UNION ALL
 SELECT 'retained_receipt_dispatch_contract',CASE WHEN
   pg_get_functiondef(to_regprocedure(
    'public.post_backoffice_sales_return_receipt(uuid,bigint,uuid,date,jsonb,text)'))
      LIKE '%private.post_retained_retail_return_receipt_core%'
   AND pg_get_functiondef(to_regprocedure(
    'public.post_backoffice_sales_return_receipt(uuid,bigint,uuid,date,jsonb,text)'))
      LIKE '%private.post_backoffice_sales_return_receipt_core%'
  THEN 'PASS' ELSE 'BLOCKER' END,
  CASE WHEN pg_get_functiondef(to_regprocedure(
    'public.post_backoffice_sales_return_receipt(uuid,bigint,uuid,date,jsonb,text)'))
      LIKE '%private.post_retained_retail_return_receipt_core%'
   AND pg_get_functiondef(to_regprocedure(
    'public.post_backoffice_sales_return_receipt(uuid,bigint,uuid,date,jsonb,text)'))
      LIKE '%private.post_backoffice_sales_return_receipt_core%'
   THEN 0 ELSE 1 END,
  jsonb_build_object('required',ARRAY[
   'retained Retail dispatches to legacy aggregate-cost core',
   'native Backoffice dispatches to unchanged exact-FIFO core'])
 UNION ALL
 SELECT 'retained_receipt_permission_contract',CASE WHEN
   has_function_privilege('authenticated',
    'public.post_backoffice_sales_return_receipt(uuid,bigint,uuid,date,jsonb,text)','EXECUTE')
   AND NOT has_function_privilege('authenticated',
    'private.post_retained_retail_return_receipt_core(uuid,bigint,uuid,date,jsonb,text)','EXECUTE')
   AND has_function_privilege('service_role',
    'private.post_retained_retail_return_receipt_core(uuid,bigint,uuid,date,jsonb,text)','EXECUTE')
  THEN 'PASS' ELSE 'BLOCKER' END,
  CASE WHEN has_function_privilege('authenticated',
    'public.post_backoffice_sales_return_receipt(uuid,bigint,uuid,date,jsonb,text)','EXECUTE')
   AND NOT has_function_privilege('authenticated',
    'private.post_retained_retail_return_receipt_core(uuid,bigint,uuid,date,jsonb,text)','EXECUTE')
   AND has_function_privilege('service_role',
    'private.post_retained_retail_return_receipt_core(uuid,bigint,uuid,date,jsonb,text)','EXECUTE')
   THEN 0 ELSE 1 END,jsonb_build_object('required',ARRAY[
    'public wrapper executable by authenticated','private core denied to authenticated',
    'private core executable by service_role'])
 UNION ALL
 SELECT 'retained_receipt_lineage_reconciliation',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
  count(*)::bigint,jsonb_build_object('invalidRows',count(*))
 FROM public.backoffice_sales_return_receipt_fifo_restorations restoration
 WHERE NOT ((restoration.cost_lineage='EXACT_FIFO'
   AND restoration.source_customer_receipt_fifo_allocation_id IS NOT NULL
   AND restoration.source_transit_batch_id IS NOT NULL
   AND restoration.source_retail_sales_detail_id IS NULL)
  OR (restoration.cost_lineage='LEGACY_AGGREGATE_COST'
   AND restoration.source_customer_receipt_fifo_allocation_id IS NULL
   AND restoration.source_transit_batch_id IS NULL
   AND restoration.source_retail_sales_detail_id IS NOT NULL
   AND restoration.source_stock_requirement_id IS NOT NULL
   AND restoration.total_cost=round(restoration.source_line_cost_total
    *restoration.quantity_base/restoration.source_line_base_qty,4)))
 UNION ALL
 SELECT 'retained_receipt_stock_movement_reconciliation',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
  jsonb_build_object('invalidRows',count(*))
 FROM public.backoffice_sales_return_receipt_lines line
 JOIN public.backoffice_sales_returns document ON document.company_id=line.company_id
  AND document.id=line.return_id AND document.source_kind='RETAINED_RETAIL'
 LEFT JOIN public.stock_movements movement ON movement.company_id=line.company_id
  AND movement.id=line.stock_movement_id
 WHERE (line.disposition='RESTOCK' AND (movement.id IS NULL
    OR movement.qty_change<>line.received_base_qty OR movement.movement_status<>'POSTED'))
  OR (line.disposition='DESTROY' AND movement.id IS NOT NULL)
 UNION ALL
 SELECT 'retained_receipt_runtime_inventory','INFO',0,jsonb_build_object(
  'legacyRestorations',count(*) FILTER(WHERE cost_lineage='LEGACY_AGGREGATE_COST'),
  'exactFifoRestorations',count(*) FILTER(WHERE cost_lineage='EXACT_FIFO'))
 FROM public.backoffice_sales_return_receipt_fifo_restorations
)
SELECT * FROM checks ORDER BY CASE status WHEN 'BLOCKER' THEN 0 WHEN 'FAIL' THEN 1
 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
