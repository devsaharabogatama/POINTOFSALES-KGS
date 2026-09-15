-- Purchase Daily Replenishment Step 2/6: SELECT-only preflight.
-- Run the complete file on isolated Development only.
WITH required_versions(version) AS (VALUES
  ('20260806010000'::text),('20260806040000'),('20260828150000'),
  ('20260828190000'),('20260913100000')
), expected_columns(table_name,column_name) AS (VALUES
  ('company_purchase_replenishment_settings'::text,'default_purchase_receipt_warehouse_id'::text),
  ('purchase_daily_batch_lines','destination_warehouse_id'),
  ('purchase_daily_batch_lines','requires_transfer'),
  ('stock_request_lines','source_warehouse_id'),
  ('stock_request_lines','destination_warehouse_id'),
  ('supplier_order_lines','source_warehouse_id'),
  ('supplier_order_lines','destination_warehouse_id')
), expected_routines(signature) AS (VALUES
  ('private.purchase_uncovered_negative_qty(numeric,numeric)'::text),
  ('private.get_purchase_daily_replenishment_candidates_core(uuid,date)'),
  ('private.trg_guard_purchase_line_source_warehouse()'),
  ('public.get_purchase_daily_replenishment_preview()'),
  ('public.set_purchase_replenishment_default_warehouse(uuid,bigint)')
), checks AS (
  SELECT 'pdr2_dependency_ledger'::text check_name,
    CASE WHEN count(ledger.version)=5 THEN 'PASS' ELSE 'BLOCKER' END status,
    (5-count(ledger.version))::bigint violation_rows,
    jsonb_build_object('expected',5,'present',count(ledger.version),
      'missing',COALESCE(jsonb_agg(required.version) FILTER(WHERE ledger.version IS NULL),'[]'::jsonb)) details
  FROM required_versions required LEFT JOIN private.kgs_schema_migrations ledger USING(version)
  UNION ALL
  SELECT 'pdr2_column_collision',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('existing',COALESCE(jsonb_agg(
      columns.table_name||'.'||columns.column_name ORDER BY columns.table_name,columns.column_name),'[]'::jsonb))
  FROM expected_columns columns JOIN information_schema.columns actual
    ON actual.table_schema='public' AND actual.table_name=columns.table_name
   AND actual.column_name=columns.column_name
  UNION ALL
  SELECT 'pdr2_routine_collision',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('existing',COALESCE(jsonb_agg(signature ORDER BY signature),'[]'::jsonb))
  FROM expected_routines WHERE to_regprocedure(signature) IS NOT NULL
  UNION ALL
  SELECT 'pdr2_purchase_line_uniqueness_contract',
    CASE WHEN count(*)=2 THEN 'PASS' ELSE 'BLOCKER' END,(2-count(*))::bigint,
    jsonb_build_object('expected',2,'present',count(*))
  FROM pg_constraint constraint_row WHERE
    (constraint_row.conrelid='public.stock_request_lines'::regclass
      AND constraint_row.conname='stock_request_lines_document_product_uom_unique')
    OR (constraint_row.conrelid='public.supplier_order_lines'::regclass
      AND constraint_row.conname='supplier_order_lines_document_product_uom_unique')
  UNION ALL
  SELECT 'pdr2_active_finance_queue',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('runRows',count(*))
  FROM public.finance_posting_queue_runs WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'pdr2_nonterminal_offline',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('submissionRows',count(*))
  FROM public.pos_offline_sale_submissions WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
  UNION ALL
  SELECT 'pdr2_open_cutover_plan',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('openPlans',count(*))
  FROM public.sales_process_cutover_plans WHERE status IN('DRAFT','PREVIEWED','APPLYING')
  UNION ALL
  SELECT 'pdr2_base_uom_contract',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('negativeRowsWithoutBaseUom',count(*))
  FROM public.product_stocks stock
  JOIN public.products product ON product.company_id=stock.company_id AND product.id=stock.product_id
  LEFT JOIN public.uoms uom ON uom.company_id=product.company_id AND uom.id=product.uom_id
  WHERE stock.stock_qty<0 AND uom.id IS NULL
  UNION ALL
  SELECT 'pdr2_open_request_warehouse_inventory','INFO',0::bigint,jsonb_build_object(
    'exactManagedLines',count(*) FILTER(WHERE demand.warehouse_id IS NOT NULL),
    'legacyLinesWithoutExactWarehouse',count(*) FILTER(WHERE demand.warehouse_id IS NULL))
  FROM public.stock_request_lines line
  JOIN public.stock_request_documents document ON document.company_id=line.company_id
    AND document.id=line.document_id
  LEFT JOIN public.sales_order_procurement_demand_lines demand ON demand.company_id=line.company_id
    AND demand.stock_request_line_id=line.id
  WHERE line.is_active AND document.status IN('DRAFT','SUBMITTED','ORDERED','PARTIALLY_RECEIVED')
  UNION ALL
  SELECT 'pdr2_runtime_inventory','INFO',0::bigint,jsonb_build_object(
    'negativeOnHandRows',(SELECT count(*) FROM public.product_stocks WHERE stock_qty<0),
    'purchaseReceivingWarehouses',(SELECT count(*) FROM public.warehouses
      WHERE is_active AND is_purchase_destination AND warehouse_type IS DISTINCT FROM 'TRANSIT'),
    'openSupplierOrders',(SELECT count(*) FROM public.supplier_order_documents
      WHERE status IN('DRAFT','CONFIRMED','PARTIALLY_RECEIVED')),
    'requiredProjectRef','fkywtxucmyjvpwdiqpix')
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;
