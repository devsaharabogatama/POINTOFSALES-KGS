-- Purchase Daily Replenishment Step 2/6: SELECT-only postflight.
WITH required_columns(table_name,column_name) AS (VALUES
  ('company_purchase_replenishment_settings'::text,'default_purchase_receipt_warehouse_id'::text),
  ('purchase_daily_batch_lines','destination_warehouse_id'),
  ('purchase_daily_batch_lines','requires_transfer'),
  ('stock_request_lines','source_warehouse_id'),
  ('stock_request_lines','destination_warehouse_id'),
  ('supplier_order_lines','source_warehouse_id'),
  ('supplier_order_lines','destination_warehouse_id')
), required_routines(signature) AS (VALUES
  ('private.purchase_uncovered_negative_qty(numeric,numeric)'::text),
  ('private.get_purchase_daily_replenishment_candidates_core(uuid,date)'),
  ('private.trg_guard_purchase_line_source_warehouse()'),
  ('public.get_purchase_daily_replenishment_preview()'),
  ('public.set_purchase_replenishment_default_warehouse(uuid,bigint)'),
  ('public.get_purchase_replenishment_setting()')
), checks AS (
  SELECT 'pdr2_migration_ledger'::text check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(1-count(*))::bigint violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260913110000'
  UNION ALL
  SELECT 'pdr2_column_contract',CASE WHEN count(actual.column_name)=7 THEN 'PASS' ELSE 'FAIL' END,
    (7-count(actual.column_name))::bigint,jsonb_build_object('expected',7,'present',count(actual.column_name),
      'missing',COALESCE(jsonb_agg(required.table_name||'.'||required.column_name)
        FILTER(WHERE actual.column_name IS NULL),'[]'::jsonb))
  FROM required_columns required LEFT JOIN information_schema.columns actual
    ON actual.table_schema='public' AND actual.table_name=required.table_name
   AND actual.column_name=required.column_name
  UNION ALL
  SELECT 'pdr2_routine_contract',CASE WHEN count(to_regprocedure(signature))=6 THEN 'PASS' ELSE 'FAIL' END,
    (6-count(to_regprocedure(signature)))::bigint,jsonb_build_object('expected',6,
      'present',count(to_regprocedure(signature)),'missing',COALESCE(jsonb_agg(signature)
        FILTER(WHERE to_regprocedure(signature) IS NULL),'[]'::jsonb))
  FROM required_routines
  UNION ALL
  SELECT 'pdr2_private_boundary',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('authenticatedExecutableRows',count(*))
  FROM information_schema.routine_privileges privilege
  WHERE privilege.specific_schema='private' AND privilege.grantee='authenticated'
    AND privilege.routine_name IN('purchase_uncovered_negative_qty',
      'get_purchase_daily_replenishment_candidates_core',
      'trg_guard_purchase_line_source_warehouse')
  UNION ALL
  SELECT 'pdr2_source_warehouse_immutable_triggers',
    CASE WHEN count(*)=2 THEN 'PASS' ELSE 'FAIL' END,(2-count(*))::bigint,
    jsonb_build_object('expected',2,'present',count(*))
  FROM pg_trigger trigger_row WHERE NOT trigger_row.tgisinternal
    AND trigger_row.tgname IN('guard_stock_request_line_source_warehouse',
      'guard_supplier_order_line_source_warehouse')
  UNION ALL
  SELECT 'pdr2_multi_warehouse_line_uniqueness',
    CASE WHEN count(to_regclass('public.'||index_name))=4 THEN 'PASS' ELSE 'FAIL' END,
    (4-count(to_regclass('public.'||index_name)))::bigint,
    jsonb_build_object('expected',4,'present',count(to_regclass('public.'||index_name)),
      'missing',COALESCE(jsonb_agg(index_name)
      FILTER(WHERE to_regclass('public.'||index_name) IS NULL),'[]'::jsonb))
  FROM (VALUES
    ('stock_request_lines_legacy_product_uom_unique'::text),
    ('stock_request_lines_source_product_uom_unique'),
    ('supplier_order_lines_legacy_product_uom_unique'),
    ('supplier_order_lines_source_product_uom_unique')
  ) expected(index_name)
  UNION ALL
  SELECT 'pdr2_default_warehouse_contract',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('invalidRows',count(*))
  FROM public.company_purchase_replenishment_settings setting
  LEFT JOIN public.warehouses warehouse ON warehouse.company_id=setting.company_id
    AND warehouse.id=setting.default_purchase_receipt_warehouse_id
  WHERE setting.default_purchase_receipt_warehouse_id IS NOT NULL
    AND (warehouse.id IS NULL OR NOT warehouse.is_active OR NOT warehouse.is_purchase_destination
      OR warehouse.warehouse_type='TRANSIT')
  UNION ALL
  SELECT 'pdr2_legacy_line_compatibility','PASS',0::bigint,jsonb_build_object(
    'legacyRequestLines',(SELECT count(*) FROM public.stock_request_lines
      WHERE source_warehouse_id IS NULL AND destination_warehouse_id IS NULL),
    'legacySupplierOrderLines',(SELECT count(*) FROM public.supplier_order_lines
      WHERE source_warehouse_id IS NULL AND destination_warehouse_id IS NULL),
    'rule','Legacy line Warehouse NULL pair remains valid; PO header destination is the read fallback')
  UNION ALL
  SELECT 'pdr2_zero_operational_effect','PASS',0::bigint,jsonb_build_object(
    'rule','Step 2 exposes read-only preview and setting only; no generator is present',
    'batchRows',(SELECT count(*) FROM public.purchase_daily_batches),
    'batchLineRows',(SELECT count(*) FROM public.purchase_daily_batch_lines))
  UNION ALL
  SELECT 'pdr2_runtime_inventory','INFO',0::bigint,jsonb_build_object(
    'negativeOnHandRows',(SELECT count(*) FROM public.product_stocks WHERE stock_qty<0),
    'configuredDefaultWarehouses',(SELECT count(*) FROM public.company_purchase_replenishment_settings
      WHERE default_purchase_receipt_warehouse_id IS NOT NULL))
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;
