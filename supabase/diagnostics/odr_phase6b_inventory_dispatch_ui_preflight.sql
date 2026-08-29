-- ODR-6B.2 Inventory Dispatch/Received UI cutover preflight.
-- SAFETY: SELECT-only.
WITH dependency_versions(version) AS (
  VALUES('20260828140000'::TEXT),('20260828230000'),('20260828250000'),
    ('20260828260000'),('20260828270000'),('20260828280000'),
    ('20260829090000'),('20260829100000')
),required_routines(signature) AS (
  VALUES
    ('public.dispatch_sales_delivery(uuid,bigint,uuid,jsonb,text)'::TEXT),
    ('public.confirm_sales_delivery_received(uuid,bigint,text,text)'),
    ('public.get_inventory_delivery_dispatch_workspace(date,date)')
),checks AS (
  SELECT 'odr6b2_dependencies'::TEXT check_name,
    CASE WHEN count(*) FILTER(WHERE migration.version IS NULL)=0
      THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('expected',count(*),'missing',COALESCE(jsonb_agg(
      dependency.version ORDER BY dependency.version)
      FILTER(WHERE migration.version IS NULL),'[]'::JSONB)) details
  FROM dependency_versions dependency
  LEFT JOIN private.kgs_schema_migrations migration
    ON migration.version=dependency.version

  UNION ALL
  SELECT 'canonical_dispatch_browser_routines',
    CASE WHEN count(*) FILTER(WHERE to_regprocedure(signature) IS NULL)=0
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('expected',count(*),'missing',COALESCE(jsonb_agg(signature)
      FILTER(WHERE to_regprocedure(signature) IS NULL),'[]'::JSONB))
  FROM required_routines

  UNION ALL
  SELECT 'canonical_dispatch_rpc_boundary',
    CASE WHEN count(*)=3
      AND count(*) FILTER(WHERE has_function_privilege(
        'authenticated',to_regprocedure(signature),'EXECUTE'))=3
      AND count(*) FILTER(WHERE has_function_privilege(
        'anon',to_regprocedure(signature),'EXECUTE'))=0
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('routineRows',count(*))
  FROM required_routines WHERE to_regprocedure(signature) IS NOT NULL

  UNION ALL
  SELECT 'inventory_delivery_permission_state',
    CASE WHEN count(*)=1 AND min(enforcement_status)='ENFORCED'
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('rows',count(*),'statuses',COALESCE(
      jsonb_agg(DISTINCT enforcement_status),'[]'::JSONB))
  FROM public.access_permission_catalog
  WHERE permission_key='inventory.delivery_documents'

  UNION ALL
  SELECT 'active_finance_posting_queue',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('runCount',count(*))
  FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')

  UNION ALL
  SELECT 'open_finance_posting_exception',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('exceptionRows',count(*))
  FROM public.finance_posting_exceptions WHERE status<>'RESOLVED'

  UNION ALL
  SELECT 'nonterminal_offline_submission',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('submissionCount',count(*))
  FROM public.pos_offline_sale_submissions
  WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')

  UNION ALL
  SELECT 'reservation_header_line_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('reservationCount',count(*))
  FROM (SELECT reservation.id
    FROM public.sales_stock_reservations reservation
    LEFT JOIN public.sales_stock_reservation_lines line
      ON line.company_id=reservation.company_id
     AND line.reservation_id=reservation.id
    GROUP BY reservation.id,reservation.total_reserved_base_qty,
      reservation.total_released_base_qty,reservation.total_dispatched_base_qty
    HAVING round(COALESCE(sum(line.reserved_base_qty),0),6)<>
        round(reservation.total_reserved_base_qty,6)
      OR round(COALESCE(sum(line.released_base_qty),0),6)<>
        round(reservation.total_released_base_qty,6)
      OR round(COALESCE(sum(line.dispatched_base_qty),0),6)<>
        round(reservation.total_dispatched_base_qty,6)) invalid

  UNION ALL
  SELECT 'linked_delivery_runtime_shape',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('rowCount',count(*))
  FROM public.sales_delivery_documents delivery
  JOIN public.sales_stock_reservations reservation
    ON reservation.company_id=delivery.company_id
   AND reservation.id=delivery.reservation_id
  WHERE (delivery.status='READY' AND reservation.status<>'OPEN')
    OR (delivery.status='PARTIALLY_DISPATCHED'
      AND reservation.status<>'PARTIALLY_DISPATCHED')
    OR (delivery.status IN('DISPATCHED','DELIVERED')
      AND reservation.status<>'CONSUMED')

  UNION ALL
  SELECT 'legacy_dispatch_bypass_quarantined',
    CASE WHEN definition~'USE_CANONICAL_DISPATCH_RUNTIME'
      AND definition~'DISPATCH' AND definition~'DELIVER'
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('routineRows',1)
  FROM (SELECT pg_get_functiondef(
    'private.acp5e_update_sales_delivery_status_core(uuid,bigint,text,text)'::regprocedure
  ) definition) runtime

  UNION ALL
  SELECT 'received_zero_second_stock_effect',
    CASE WHEN definition~'acp5e_update_sales_delivery_status_odr3_legacy'
      AND definition!~'product_stocks' AND definition!~'product_batches'
      AND definition!~'stock_movements'
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('routineRows',1)
  FROM (SELECT pg_get_functiondef(
    'public.confirm_sales_delivery_received(uuid,bigint,text,text)'::regprocedure
  ) definition) runtime
),inventory AS (
  SELECT 'inventory_dispatch_cutover_scope'::TEXT check_name,'INFO'::TEXT status,
    jsonb_build_object(
      'linkedReady',(SELECT count(*) FROM public.sales_delivery_documents
        WHERE reservation_id IS NOT NULL AND status='READY'),
      'linkedPartial',(SELECT count(*) FROM public.sales_delivery_documents
        WHERE reservation_id IS NOT NULL AND status='PARTIALLY_DISPATCHED'),
      'linkedDispatched',(SELECT count(*) FROM public.sales_delivery_documents
        WHERE reservation_id IS NOT NULL AND status='DISPATCHED'),
      'linkedDelivered',(SELECT count(*) FROM public.sales_delivery_documents
        WHERE reservation_id IS NOT NULL AND status='DELIVERED'),
      'openReservations',(SELECT count(*) FROM public.sales_stock_reservations
        WHERE status IN('OPEN','PARTIALLY_DISPATCHED')),
      'dispatchAllocations',(SELECT count(*) FROM public.sales_dispatch_allocations),
      'dispatchHoldEvents',(SELECT count(*) FROM public.financial_events
        WHERE system_event_key='SALE_DISPATCHED' AND status::TEXT='HOLD')) details
)
SELECT * FROM (SELECT * FROM checks UNION ALL SELECT * FROM inventory) result
ORDER BY check_name;
