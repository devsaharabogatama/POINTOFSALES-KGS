-- ODR-2 Sales Order and reservation foundation preflight.
-- SAFETY: SELECT-only. No schema or business-data mutation.

WITH required_versions(version) AS (
  VALUES ('20260827152000'),('20260827153000'),('20260827154000')
), required_routines(schema_name,routine_name,identity_arguments) AS (
  VALUES
    ('public','save_pos_sale_draft_with_pricelist','p_payload jsonb'),
    ('public','list_pos_sale_drafts','p_store_id uuid'),
    ('public','post_pos_sale',
      'p_sales_id uuid, p_master_version bigint, p_posting_idempotency_key uuid')
), candidate_relations(relation_name) AS (
  VALUES ('sales_stock_reservations'),('sales_stock_reservation_lines')
), candidate_columns(column_name) AS (
  VALUES
    ('order_runtime_status'),('confirmed_at'),('confirmed_by'),
    ('confirmation_idempotency_key'),('reservation_version')
), movement_totals AS (
  SELECT company_id,product_id,warehouse_id,COALESCE(sum(qty_change),0) qty
  FROM public.stock_movements GROUP BY company_id,product_id,warehouse_id
), fifo_totals AS (
  SELECT company_id,product_id,warehouse_id,COALESCE(sum(qty_remaining),0) qty
  FROM public.product_batches GROUP BY company_id,product_id,warehouse_id
), draft_effects AS (
  SELECT sale.company_id,sale.id,
    EXISTS(SELECT 1 FROM public.sales_payments payment
      WHERE payment.company_id=sale.company_id AND payment.sales_id=sale.id)
      has_payment,
    EXISTS(SELECT 1 FROM public.sale_stock_requirements requirement
      WHERE requirement.company_id=sale.company_id
        AND requirement.sales_id=sale.id) has_requirement,
    EXISTS(SELECT 1 FROM public.stock_movements movement
      WHERE movement.company_id=sale.company_id
        AND movement.reference_id=sale.id) has_movement,
    (EXISTS(SELECT 1 FROM public.sale_fifo_allocations allocation
      WHERE allocation.company_id=sale.company_id
        AND allocation.sales_id=sale.id)
     OR EXISTS(SELECT 1 FROM public.sales_fifo_allocations allocation
      JOIN public.sales_details detail ON detail.company_id=sale.company_id
       AND detail.id=allocation.sales_detail_id
      WHERE detail.sales_id=sale.id)) has_fifo,
    EXISTS(SELECT 1 FROM public.financial_events event
      WHERE event.company_id=sale.company_id
        AND (event.source_id=sale.id OR event.root_sales_id=sale.id)) has_event,
    EXISTS(SELECT 1 FROM public.sales_invoice_snapshots invoice
      WHERE invoice.company_id=sale.company_id AND invoice.sales_id=sale.id)
      has_invoice,
    EXISTS(SELECT 1 FROM public.sales_delivery_documents delivery
      WHERE delivery.company_id=sale.company_id AND delivery.sales_id=sale.id)
      has_delivery
  FROM public.sales_headers sale WHERE sale.document_status='DRAFT'
), checks AS (
  SELECT 'odr_phase2_dependencies'::TEXT check_name,
    CASE WHEN count(*) FILTER(WHERE migration.version IS NULL)=0
      THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('expected',count(*),'missing',COALESCE(
      jsonb_agg(required.version ORDER BY required.version)
        FILTER(WHERE migration.version IS NULL),'[]'::JSONB)) details
  FROM required_versions required
  LEFT JOIN private.kgs_schema_migrations migration
    ON migration.version=required.version

  UNION ALL
  SELECT 'canonical_pos_runtime',
    CASE WHEN count(procedure.oid)=count(*) THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('expected',count(*),'routineRows',count(procedure.oid),
      'missing',COALESCE(jsonb_agg(required.routine_name
        ORDER BY required.routine_name) FILTER(WHERE procedure.oid IS NULL),
        '[]'::JSONB))
  FROM required_routines required
  LEFT JOIN pg_namespace namespace ON namespace.nspname=required.schema_name
  LEFT JOIN pg_proc procedure ON procedure.pronamespace=namespace.oid
    AND procedure.proname=required.routine_name
    AND pg_get_function_identity_arguments(procedure.oid)
      =required.identity_arguments

  UNION ALL
  SELECT 'active_finance_posting_queue',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('runCount',count(*))
  FROM public.finance_posting_queue_runs run
  WHERE run.status IN('PREVIEWED','APPROVED','PROCESSING')

  UNION ALL
  SELECT 'nonterminal_offline_submission',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('submissionCount',count(*))
  FROM public.pos_offline_sale_submissions submission
  WHERE submission.status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')

  UNION ALL
  SELECT 'draft_sale_zero_final_effect',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('saleCount',count(*),'byEffect',COALESCE(
      jsonb_build_object(
        'payment',count(*) FILTER(WHERE has_payment),
        'movement',count(*) FILTER(WHERE has_movement),
        'fifo',count(*) FILTER(WHERE has_fifo),
        'financialEvent',count(*) FILTER(WHERE has_event),
        'invoice',count(*) FILTER(WHERE has_invoice),
        'delivery',count(*) FILTER(WHERE has_delivery)),'{}'::JSONB))
  FROM draft_effects
  WHERE has_payment OR has_movement OR has_fifo
     OR has_event OR has_invoice OR has_delivery

  UNION ALL
  SELECT 'draft_stock_requirement_snapshot','PASS',
    jsonb_build_object(
      'saleCount',count(*) FILTER(WHERE has_requirement),
      'requirementRows',(SELECT count(*)
        FROM public.sale_stock_requirements requirement
        JOIN public.sales_headers sale ON sale.company_id=requirement.company_id
         AND sale.id=requirement.sales_id
        WHERE sale.document_status='DRAFT'),
      'contract','Draft Stock Requirement is derived planning evidence; it does not mutate On Hand, FIFO, Movement, or Finance')
  FROM draft_effects

  UNION ALL
  SELECT 'draft_line_snapshot_readiness',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BACKFILL' END,
    jsonb_build_object('lineCount',count(*),'saleCount',count(DISTINCT sale.id))
  FROM public.sales_headers sale
  JOIN public.sales_details detail
    ON detail.company_id=sale.company_id AND detail.sales_id=sale.id
  WHERE sale.document_status='DRAFT' AND (
    detail.client_line_key IS NULL OR detail.product_uom_id IS NULL
    OR detail.sale_uom_id IS NULL OR detail.quantity_base IS NULL
    OR detail.quantity_base<=0 OR detail.uom_factor_to_base_snapshot IS NULL
    OR detail.uom_factor_to_base_snapshot<=0
    OR COALESCE(btrim(detail.product_sku_snapshot),'')=''
    OR COALESCE(btrim(detail.product_name_snapshot),'')='')

  UNION ALL
  SELECT 'draft_header_operational_identity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BACKFILL' END,
    jsonb_build_object('saleCount',count(*))
  FROM public.sales_headers sale
  LEFT JOIN public.stores store ON store.company_id=sale.company_id
    AND store.id=sale.store_id
  LEFT JOIN public.customers customer ON customer.company_id=sale.company_id
    AND customer.id=sale.customer_id
  WHERE sale.document_status='DRAFT'
    AND (store.id IS NULL OR customer.id IS NULL OR sale.session_id IS NULL)

  UNION ALL
  SELECT 'scheduled_draft_contract',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('saleCount',count(*))
  FROM public.sales_headers sale
  WHERE sale.document_status='DRAFT' AND sale.order_timing_mode='SCHEDULED'
    AND (NOT sale.is_tempo OR sale.planned_order_date IS NULL
      OR sale.planned_order_selected_by IS NULL
      OR sale.planned_order_selected_at IS NULL)

  UNION ALL
  SELECT 'historical_posted_sale_reservation_boundary','PASS',
    jsonb_build_object('postedSales',count(*),
      'rule','Historical POSTED Sale remains final and receives no ODR reservation backfill')
  FROM public.sales_headers sale
  WHERE sale.document_status='POSTED'

  UNION ALL
  SELECT 'stock_balance_movement_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('pairCount',count(*))
  FROM (SELECT COALESCE(stock.company_id,movement.company_id)
    FROM public.product_stocks stock FULL JOIN movement_totals movement
      ON movement.company_id=stock.company_id
     AND movement.product_id=stock.product_id
     AND movement.warehouse_id=stock.warehouse_id
    WHERE COALESCE(stock.stock_qty,0)<>COALESCE(movement.qty,0)) invalid_pair

  UNION ALL
  SELECT 'positive_stock_fifo_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('pairCount',count(*))
  FROM public.product_stocks stock LEFT JOIN fifo_totals fifo
    ON fifo.company_id=stock.company_id AND fifo.product_id=stock.product_id
   AND fifo.warehouse_id=stock.warehouse_id
  WHERE stock.stock_qty>0 AND stock.stock_qty<>COALESCE(fifo.qty,0)

  UNION ALL
  SELECT 'negative_stock_open_allocation_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('rowCount',count(*))
  FROM public.negative_stock_sale_allocations allocation
  WHERE allocation.replenished_base_qty<0
     OR allocation.replenished_base_qty>allocation.shortage_base_qty
     OR (allocation.reconciled_at IS NULL
       AND allocation.replenished_base_qty>=allocation.shortage_base_qty)

  UNION ALL
  SELECT 'browser_sale_write_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('directWriteRelations',COALESCE(
      jsonb_agg(relation_name ORDER BY relation_name),'[]'::JSONB))
  FROM (SELECT relation_name FROM (VALUES ('sales_headers'),('sales_details'),
      ('sales_payments'),('sale_stock_requirements'),
      ('sale_fifo_allocations'),('sales_fifo_allocations')) relation(relation_name)
    WHERE has_table_privilege('authenticated','public.'||relation_name,
      'INSERT,UPDATE,DELETE')) writable

  UNION ALL
  SELECT 'sales_order_permission_catalog_state',
    CASE WHEN count(*)=0 THEN 'SETUP' ELSE 'REVIEW' END,
    jsonb_build_object('rows',count(*),'expectedKey','sales.sales_orders')
  FROM public.access_permission_catalog catalog
  WHERE catalog.permission_key='sales.sales_orders'

  UNION ALL
  SELECT 'reservation_schema_state','SETUP',jsonb_build_object(
    'missingRelations',COALESCE(jsonb_agg(relation_name ORDER BY relation_name)
      FILTER(WHERE to_regclass('public.'||relation_name) IS NULL),'[]'::JSONB),
    'existingRelations',COALESCE(jsonb_agg(relation_name ORDER BY relation_name)
      FILTER(WHERE to_regclass('public.'||relation_name) IS NOT NULL),'[]'::JSONB))
  FROM candidate_relations

  UNION ALL
  SELECT 'sales_order_header_schema_state','SETUP',jsonb_build_object(
    'missingColumns',COALESCE(jsonb_agg(candidate.column_name
      ORDER BY candidate.column_name) FILTER(WHERE column_state.column_name IS NULL),
      '[]'::JSONB),'existingColumns',COALESCE(jsonb_agg(candidate.column_name
      ORDER BY candidate.column_name) FILTER(WHERE column_state.column_name IS NOT NULL),
      '[]'::JSONB))
  FROM candidate_columns candidate
  LEFT JOIN information_schema.columns column_state
    ON column_state.table_schema='public'
   AND column_state.table_name='sales_headers'
   AND column_state.column_name=candidate.column_name

  UNION ALL
  SELECT 'draft_cutover_inventory','INFO',jsonb_build_object(
    'companies',count(DISTINCT company_id),'draftSales',count(*),
    'immediate',count(*) FILTER(WHERE order_timing_mode='IMMEDIATE'),
    'backorder',count(*) FILTER(WHERE order_timing_mode='BACKORDER'),
    'scheduled',count(*) FILTER(WHERE order_timing_mode='SCHEDULED'),
    'tempo',count(*) FILTER(WHERE is_tempo),
    'delivery',count(*) FILTER(WHERE fulfillment_mode='DELIVERY'),
    'pickup',count(*) FILTER(WHERE fulfillment_mode='PICKUP'))
  FROM public.sales_headers WHERE document_status='DRAFT'

  UNION ALL
  SELECT 'reservation_source_inventory','INFO',jsonb_build_object(
    'stockPairs',(SELECT count(*) FROM public.product_stocks),
    'positiveFifoLayers',(SELECT count(*) FROM public.product_batches
      WHERE qty_remaining>0),
    'openNegativeAllocations',(SELECT count(*)
      FROM public.negative_stock_sale_allocations WHERE reconciled_at IS NULL),
    'activeNegativePolicies',(SELECT count(*)
      FROM public.pos_negative_stock_policies WHERE is_active),
    'activeWarehouses',(SELECT count(*) FROM public.warehouses WHERE is_active))
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 0 WHEN 'PASS' THEN 1
  WHEN 'BACKFILL' THEN 2 WHEN 'REVIEW' THEN 3 WHEN 'SETUP' THEN 4 ELSE 5 END,
  check_name;
