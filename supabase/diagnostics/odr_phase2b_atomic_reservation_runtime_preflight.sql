-- ODR-2B atomic Sales Order reservation runtime preflight.
-- SAFETY: SELECT-only.
WITH draft_requirement AS (
  SELECT sale.company_id,sale.id sales_id,session.cashier_id actor_id,
    sale.session_id,session.sales_warehouse_id warehouse_id,
    requirement.stock_product_id,commercial.is_bundle,
    sum(requirement.quantity_base) requested_qty
  FROM public.sales_headers sale
  JOIN public.cashier_sessions session ON session.company_id=sale.company_id
    AND session.id=sale.session_id
  JOIN public.sale_stock_requirements requirement
    ON requirement.company_id=sale.company_id AND requirement.sales_id=sale.id
  JOIN public.products commercial ON commercial.company_id=requirement.company_id
    AND commercial.id=requirement.commercial_product_id
  WHERE sale.document_status='DRAFT'
    AND sale.order_runtime_status IN('DRAFT_INPUT','SCHEDULED')
  GROUP BY sale.company_id,sale.id,session.cashier_id,sale.session_id,
    session.sales_warehouse_id,requirement.stock_product_id,commercial.is_bundle
), open_reserved AS (
  SELECT line.company_id,line.warehouse_id,line.stock_product_id,
    sum(line.reserved_base_qty-line.released_base_qty-line.dispatched_base_qty) qty
  FROM public.sales_stock_reservation_lines line
  JOIN public.sales_stock_reservations reservation
    ON reservation.company_id=line.company_id AND reservation.id=line.reservation_id
  WHERE reservation.status IN('OPEN','PARTIALLY_DISPATCHED')
  GROUP BY line.company_id,line.warehouse_id,line.stock_product_id
), availability AS (
  SELECT requirement.*,
    COALESCE(stock.stock_qty,0) on_hand,
    COALESCE(reserved.qty,0) reserved_out,
    COALESCE(stock.stock_qty,0)-COALESCE(reserved.qty,0) available_to_sell,
    GREATEST(requirement.requested_qty-
      GREATEST(COALESCE(stock.stock_qty,0)-COALESCE(reserved.qty,0),0),0) shortage,
    abs(LEAST(COALESCE(stock.stock_qty,0)-COALESCE(reserved.qty,0)
      -requirement.requested_qty,0)) projected_negative_qty
  FROM draft_requirement requirement
  LEFT JOIN public.product_stocks stock ON stock.company_id=requirement.company_id
    AND stock.product_id=requirement.stock_product_id
    AND stock.warehouse_id=requirement.warehouse_id
  LEFT JOIN open_reserved reserved ON reserved.company_id=requirement.company_id
    AND reserved.stock_product_id=requirement.stock_product_id
    AND reserved.warehouse_id=requirement.warehouse_id
), checks AS (
  SELECT 'odr_phase2a_dependency'::TEXT check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260828100000'
  UNION ALL
  SELECT 'existing_reservation_integrity',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('invalidRows',count(*))
  FROM public.sales_stock_reservation_lines line
  JOIN public.sales_stock_reservations reservation
    ON reservation.company_id=line.company_id AND reservation.id=line.reservation_id
  WHERE line.released_base_qty+line.dispatched_base_qty>line.reserved_base_qty
     OR reservation.status IN('RELEASED','CONSUMED')
       AND line.released_base_qty+line.dispatched_base_qty<>line.reserved_base_qty
  UNION ALL
  SELECT 'draft_session_warehouse_readiness',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('saleCount',count(*))
  FROM public.sales_headers sale
  LEFT JOIN public.cashier_sessions session ON session.company_id=sale.company_id
    AND session.id=sale.session_id
  LEFT JOIN public.warehouses warehouse ON warehouse.company_id=session.company_id
    AND warehouse.id=session.sales_warehouse_id
  WHERE sale.document_status='DRAFT' AND sale.order_runtime_status IN('DRAFT_INPUT','SCHEDULED')
    AND (session.id IS NULL OR warehouse.id IS NULL OR NOT warehouse.is_active
      OR NOT warehouse.is_sale_source)
  UNION ALL
  SELECT 'draft_requirement_coverage',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('saleCount',count(*))
  FROM public.sales_headers sale
  WHERE sale.document_status='DRAFT' AND sale.order_runtime_status IN('DRAFT_INPUT','SCHEDULED')
    AND NOT EXISTS(SELECT 1 FROM public.sale_stock_requirements requirement
      WHERE requirement.company_id=sale.company_id AND requirement.sales_id=sale.id)
  UNION ALL
  SELECT 'shortage_negative_stock_readiness',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('requirementRows',count(*),'sales',count(DISTINCT availability.sales_id))
  FROM availability
  LEFT JOIN public.pos_negative_stock_policies policy
    ON policy.company_id=availability.company_id AND policy.is_active
  LEFT JOIN public.company_features feature
    ON feature.company_id=availability.company_id
   AND feature.feature_code='pos_negative_stock_enabled' AND feature.is_enabled
  LEFT JOIN public.pos_negative_stock_permissions permission
    ON permission.company_id=availability.company_id
   AND permission.warehouse_id=availability.warehouse_id
   AND permission.user_id=availability.actor_id AND permission.is_active
   AND (permission.valid_until IS NULL OR permission.valid_until>clock_timestamp())
  LEFT JOIN public.warehouses warehouse ON warehouse.company_id=availability.company_id
    AND warehouse.id=availability.warehouse_id
  WHERE availability.shortage>0 AND (
    availability.is_bundle OR feature.company_id IS NULL
    OR policy.id IS NULL OR permission.id IS NULL
    OR NOT COALESCE(warehouse.allow_negative_stock,FALSE)
    OR policy.company_negative_limit_base_qty IS NOT NULL
      AND availability.projected_negative_qty>policy.company_negative_limit_base_qty
    OR permission.max_negative_base_qty IS NOT NULL
      AND availability.projected_negative_qty>permission.max_negative_base_qty)
  UNION ALL
  SELECT 'active_finance_posting_queue',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('runCount',count(*)) FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'nonterminal_offline_submission',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('submissionCount',count(*)) FROM public.pos_offline_sale_submissions
  WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
  UNION ALL
  SELECT 'reservation_runtime_state','SETUP',jsonb_build_object(
    'missing',COALESCE(jsonb_agg(name ORDER BY name)
      FILTER(WHERE to_regprocedure(signature) IS NULL),'[]'::JSONB),'expected',count(*))
  FROM (VALUES
    ('public.confirm_pos_sales_order','public.confirm_pos_sales_order(uuid,bigint,uuid,text)'),
    ('public.cancel_pos_sales_order','public.cancel_pos_sales_order(uuid,bigint,uuid,text)'),
    ('public.get_pos_sales_orders','public.get_pos_sales_orders(uuid)')
  ) routine(name,signature)
  UNION ALL
  SELECT 'draft_reservation_inventory','INFO',jsonb_build_object(
    'requirementRows',count(*),'sales',count(DISTINCT sales_id),
    'shortageRows',count(*) FILTER(WHERE shortage>0),
    'requestedBaseQty',COALESCE(sum(requested_qty),0),
    'shortageBaseQty',COALESCE(sum(shortage),0),
    'maximumProjectedNegativeBaseQty',COALESCE(max(projected_negative_qty),0),
    'onHand',COALESCE(sum(on_hand),0),'reservedOut',COALESCE(sum(reserved_out),0))
  FROM availability
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 0 WHEN 'PASS' THEN 1
  WHEN 'SETUP' THEN 2 ELSE 3 END,check_name;
