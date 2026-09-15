-- SELECT-only preflight. Run the entire file on isolated Development only.
WITH required_migrations(version) AS (VALUES
  ('20260831130000'),('20260909151000'),('20260909154000'),('20260910153000')
), checks AS (
  SELECT 'negative_dispatch_dependency_ledger'::text check_name,
    CASE WHEN count(ledger.version)=4 THEN 'PASS' ELSE 'BLOCKER' END status,
    (4-count(ledger.version))::bigint violation_rows,
    jsonb_build_object('expected',4,'present',count(ledger.version),
      'missing',COALESCE(jsonb_agg(required.version) FILTER(WHERE ledger.version IS NULL),'[]')) details
  FROM required_migrations required LEFT JOIN private.kgs_schema_migrations ledger
    ON ledger.version=required.version
  UNION ALL
  SELECT 'negative_dispatch_relation_collision',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('existing',COALESCE(jsonb_agg(table_name),'[]'))
  FROM information_schema.tables WHERE table_schema='public'
    AND table_name IN('backoffice_negative_stock_allocations',
      'backoffice_negative_stock_replenishments')
  UNION ALL
  SELECT 'negative_dispatch_column_collision',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('existing',COALESCE(jsonb_agg(column_name),'[]'))
  FROM information_schema.columns WHERE table_schema='public'
    AND table_name='product_batches' AND column_name='backoffice_negative_allocation_id'
  UNION ALL
  SELECT 'negative_dispatch_routine_collision',
    CASE WHEN to_regprocedure(
      'private.post_backoffice_sales_stock_transfer(uuid,bigint,uuid,uuid)') IS NULL
      THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN to_regprocedure(
      'private.post_backoffice_sales_stock_transfer(uuid,bigint,uuid,uuid)') IS NULL
      THEN 0 ELSE 1 END,
    jsonb_build_object('existing',to_regprocedure(
      'private.post_backoffice_sales_stock_transfer(uuid,bigint,uuid,uuid)') IS NOT NULL)
  UNION ALL
  SELECT 'negative_dispatch_active_finance_queue',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('activeRuns',count(*)) FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'negative_dispatch_nonterminal_offline',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('submissions',count(*)) FROM public.pos_offline_sale_submissions
    WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
  UNION ALL
  SELECT 'negative_dispatch_stock_constraint_contract',
    CASE WHEN count(*)=2 THEN 'PASS' ELSE 'BLOCKER' END,(2-count(*))::bigint,
    jsonb_build_object('present',count(*),'expected',2)
  FROM pg_constraint WHERE (conrelid,conname) IN(
    ('public.product_batches'::regclass,'product_batches_source_lineage_check'),
    ('public.stock_movements'::regclass,'stock_movements_balance_after_controlled'))
  UNION ALL
  SELECT 'negative_dispatch_call_chain_contract',
    CASE WHEN definition~'post_stock_transfer' AND definition!~'post_backoffice_sales_stock_transfer'
      THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN definition~'post_stock_transfer' AND definition!~'post_backoffice_sales_stock_transfer'
      THEN 0 ELSE 1 END,
    jsonb_build_object('legacyPostCall',definition~'post_stock_transfer',
      'alreadyPatched',definition~'post_backoffice_sales_stock_transfer')
  FROM (SELECT pg_get_functiondef(
    'private.dispatch_backoffice_sales_delivery_to_transit(uuid,bigint,uuid,jsonb,text)'::regprocedure)
    definition) source
), inventory AS (
  SELECT 'negative_dispatch_runtime_inventory'::text check_name,'INFO'::text status,
    0::bigint violation_rows,jsonb_build_object(
      'dispatchableDeliveries',(SELECT count(*) FROM public.backoffice_sales_delivery_orders
        WHERE status IN('READY','PARTIALLY_SHIPPED')),
      'warehouseEnabledDispatchable',(SELECT count(*)
        FROM public.backoffice_sales_delivery_orders delivery
        JOIN public.backoffice_sales_reservations reservation
          ON reservation.company_id=delivery.company_id AND reservation.id=delivery.reservation_id
        JOIN public.warehouses warehouse ON warehouse.company_id=reservation.company_id
          AND warehouse.id=reservation.warehouse_id
        WHERE delivery.status IN('READY','PARTIALLY_SHIPPED')
          AND warehouse.allow_negative_stock),
      'currentOpenBackofficeShortages',(SELECT count(*)
        FROM public.backoffice_sales_reservation_lines line
        LEFT JOIN public.product_stocks stock ON stock.company_id=line.company_id
          AND stock.product_id=line.product_id AND stock.warehouse_id=line.warehouse_id
        WHERE line.released_base_qty+line.completed_base_qty<line.reserved_base_qty
          AND COALESCE(stock.stock_qty,0)<line.reserved_base_qty-line.released_base_qty
            -line.completed_base_qty-line.in_transit_base_qty),
      'rule','Warehouse flag is read again at Dispatch; existing ready DO is not mutated') details
)
SELECT * FROM (SELECT * FROM checks UNION ALL SELECT * FROM inventory) result
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;

