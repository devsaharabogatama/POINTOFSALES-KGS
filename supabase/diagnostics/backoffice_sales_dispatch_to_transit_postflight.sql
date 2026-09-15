-- Read-only structural and runtime reconciliation after gate 20260909151000.
WITH results AS (
  SELECT 'migration_ledger'::text check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(count(*)-1)::bigint violation_rows,
    jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260909151000'
  UNION ALL
  SELECT 'required_dispatch_relations',CASE WHEN count(*)=2 THEN 'PASS' ELSE 'FAIL' END,
    abs(count(*)-2)::bigint,jsonb_build_object('expected',2,'relationRows',count(*))
  FROM information_schema.tables WHERE table_schema='public'
    AND table_name IN('backoffice_sales_delivery_dispatches',
      'backoffice_sales_delivery_dispatch_lines')
  UNION ALL
  SELECT 'required_dispatch_routines',CASE WHEN count(*)=3 THEN 'PASS' ELSE 'FAIL' END,
    abs(count(*)-3)::bigint,jsonb_build_object('expected',3,'routineRows',count(*))
  FROM pg_proc procedure JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
  WHERE (namespace.nspname,procedure.proname) IN(
    ('private','trg_guard_backoffice_sales_delivery_dispatch'),
    ('private','dispatch_backoffice_sales_delivery_to_transit'),
    ('public','dispatch_backoffice_sales_delivery'))
  UNION ALL
  SELECT 'dispatch_rpc_boundary',
    CASE WHEN NOT has_function_privilege('anon',
        'public.dispatch_backoffice_sales_delivery(uuid,bigint,uuid,jsonb,text)','EXECUTE')
      AND has_function_privilege('authenticated',
        'public.dispatch_backoffice_sales_delivery(uuid,bigint,uuid,jsonb,text)','EXECUTE')
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN NOT has_function_privilege('anon',
        'public.dispatch_backoffice_sales_delivery(uuid,bigint,uuid,jsonb,text)','EXECUTE')
      AND has_function_privilege('authenticated',
        'public.dispatch_backoffice_sales_delivery(uuid,bigint,uuid,jsonb,text)','EXECUTE')
      THEN 0 ELSE 1 END,
    jsonb_build_object('anonExecute',has_function_privilege('anon',
        'public.dispatch_backoffice_sales_delivery(uuid,bigint,uuid,jsonb,text)','EXECUTE'),
      'authenticatedExecute',has_function_privilege('authenticated',
        'public.dispatch_backoffice_sales_delivery(uuid,bigint,uuid,jsonb,text)','EXECUTE'))
  UNION ALL
  SELECT 'browser_dispatch_table_boundary',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('privilegeRows',count(*))
  FROM information_schema.role_table_grants WHERE grantee IN('anon','authenticated')
    AND table_schema='public' AND table_name IN(
      'backoffice_sales_delivery_dispatches','backoffice_sales_delivery_dispatch_lines')
  UNION ALL
  SELECT 'dispatch_transfer_lineage_reconciliation',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('rowCount',count(*))
  FROM public.backoffice_sales_delivery_dispatches dispatch
  LEFT JOIN public.stock_transfer_documents transfer
    ON transfer.company_id=dispatch.company_id
   AND transfer.id=dispatch.stock_transfer_document_id
  LEFT JOIN public.warehouses transit ON transit.company_id=dispatch.company_id
   AND transit.id=dispatch.transit_warehouse_id
  WHERE transfer.id IS NULL OR transfer.status<>'POSTED'
    OR transfer.source_warehouse_id<>dispatch.source_warehouse_id
    OR transfer.destination_warehouse_id<>dispatch.transit_warehouse_id
    OR transit.transit_parent_warehouse_id<>dispatch.source_warehouse_id
    OR transit.transit_operation<>'SALES_DELIVERY_OUTBOUND'
    OR transfer.total_quantity_base<>dispatch.total_base_qty
    OR transfer.total_cost<>dispatch.total_cost
  UNION ALL
  SELECT 'dispatch_line_total_reconciliation',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('dispatchRows',count(*))
  FROM (SELECT dispatch.id,dispatch.total_base_qty,
      COALESCE(sum(line.quantity_base),0) line_total
    FROM public.backoffice_sales_delivery_dispatches dispatch
    LEFT JOIN public.backoffice_sales_delivery_dispatch_lines line
      ON line.company_id=dispatch.company_id AND line.dispatch_id=dispatch.id
    GROUP BY dispatch.id,dispatch.total_base_qty) invalid
  WHERE invalid.total_base_qty<>invalid.line_total
  UNION ALL
  SELECT 'delivery_shipped_quantity_reconciliation',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('deliveryRows',count(*))
  FROM (SELECT delivery.id,delivery.status,delivery.total_planned_base_qty,
      delivery.total_shipped_base_qty,COALESCE(sum(line.shipped_base_qty),0) line_total
    FROM public.backoffice_sales_delivery_orders delivery
    JOIN public.backoffice_sales_delivery_order_lines line
      ON line.company_id=delivery.company_id AND line.delivery_order_id=delivery.id
    GROUP BY delivery.id,delivery.status,delivery.total_planned_base_qty,
      delivery.total_shipped_base_qty) invalid
  WHERE invalid.total_shipped_base_qty<>invalid.line_total
    OR (invalid.status='PARTIALLY_SHIPPED' AND NOT(
      invalid.total_shipped_base_qty>0
      AND invalid.total_shipped_base_qty<invalid.total_planned_base_qty))
    OR (invalid.status='IN_TRANSIT'
      AND invalid.total_shipped_base_qty<>invalid.total_planned_base_qty)
  UNION ALL
  SELECT 'reservation_in_transit_reconciliation',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('reservationRows',count(*))
  FROM (SELECT reservation.id,reservation.total_in_transit_base_qty,
      COALESCE(sum(line.in_transit_base_qty),0) line_total
    FROM public.backoffice_sales_reservations reservation
    JOIN public.backoffice_sales_reservation_lines line
      ON line.company_id=reservation.company_id AND line.reservation_id=reservation.id
    GROUP BY reservation.id,reservation.total_in_transit_base_qty) invalid
  WHERE invalid.total_in_transit_base_qty<>invalid.line_total
  UNION ALL
  SELECT 'dispatch_company_stock_movement_balance',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('transferRows',count(*))
  FROM (SELECT dispatch.id,COALESCE(sum(movement.qty_change),0) net_qty
    FROM public.backoffice_sales_delivery_dispatches dispatch
    JOIN public.stock_movements movement ON movement.company_id=dispatch.company_id
      AND movement.reference_table='stock_transfer_documents'
      AND movement.reference_id=dispatch.stock_transfer_document_id
    GROUP BY dispatch.id) invalid WHERE invalid.net_qty<>0
  UNION ALL
  SELECT 'dispatch_zero_final_accounting_definition',
    CASE WHEN definition !~ 'sales_invoice_snapshots|financial_events|journal_entries|payment_requests'
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN definition !~ 'sales_invoice_snapshots|financial_events|journal_entries|payment_requests'
      THEN 0 ELSE 1 END,
    jsonb_build_object('forbiddenFinalAccountingReference',
      definition ~ 'sales_invoice_snapshots|financial_events|journal_entries|payment_requests')
  FROM (SELECT pg_get_functiondef(
    'private.dispatch_backoffice_sales_delivery_to_transit(uuid,bigint,uuid,jsonb,text)'::regprocedure)
    definition) source
), inventory AS (
  SELECT 'dispatch_to_transit_runtime_inventory'::text check_name,'INFO'::text status,
    0::bigint violation_rows,jsonb_build_object(
      'dispatches',(SELECT count(*) FROM public.backoffice_sales_delivery_dispatches),
      'dispatchLines',(SELECT count(*) FROM public.backoffice_sales_delivery_dispatch_lines),
      'partialDeliveries',(SELECT count(*) FROM public.backoffice_sales_delivery_orders
        WHERE status='PARTIALLY_SHIPPED'),
      'inTransitDeliveries',(SELECT count(*) FROM public.backoffice_sales_delivery_orders
        WHERE status='IN_TRANSIT')) details
)
SELECT * FROM (SELECT * FROM results UNION ALL SELECT * FROM inventory) output
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;

