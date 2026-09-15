-- SELECT-only verification for Purchase Step 5/6B.
WITH definitions AS (
  SELECT
    pg_get_functiondef(to_regprocedure(
      'private.get_purchase_daily_automatic_candidates_core(uuid,date)')) candidate_definition,
    pg_get_functiondef(to_regprocedure(
      'private.generate_purchase_daily_auto_po_core(uuid,date,uuid,uuid,timestamptz)')) generator_definition,
    pg_get_functiondef(to_regprocedure(
      'public.save_purchase_daily_goods_receipt(uuid,bigint,uuid,uuid,text,text,jsonb)')) receipt_definition
), checks AS (
  SELECT 'migration_ledger' check_name,CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(1-count(*)) violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260914110000'
  UNION ALL
  SELECT 'auto_po_missing_destination_policy',
    CASE WHEN position($old$'PRODUCT_INACTIVE','SOURCE_WAREHOUSE_INACTIVE')$old$
        in candidate_definition)>0
      AND position($old$'SOURCE_WAREHOUSE_INACTIVE','WAREHOUSE_SETUP_REQUIRED')$old$
        in candidate_definition)=0 THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN position($old$'PRODUCT_INACTIVE','SOURCE_WAREHOUSE_INACTIVE')$old$
        in candidate_definition)>0
      AND position($old$'SOURCE_WAREHOUSE_INACTIVE','WAREHOUSE_SETUP_REQUIRED')$old$
        in candidate_definition)=0 THEN 0 ELSE 1 END,
    jsonb_build_object('inactiveMasterExclusionPreserved',
      position($old$'PRODUCT_INACTIVE','SOURCE_WAREHOUSE_INACTIVE')$old$
        in candidate_definition)>0,'warehouseSetupBlocksPo',
      position($old$'SOURCE_WAREHOUSE_INACTIVE','WAREHOUSE_SETUP_REQUIRED')$old$
        in candidate_definition)>0)
  FROM definitions
  UNION ALL
  SELECT 'auto_po_generator_destination_boundary',
    CASE WHEN position($marker$v_candidate->>'status','WAREHOUSE_SETUP_REQUIRED'$marker$ in generator_definition)=0
      AND position('AND line.destination_warehouse_id IS NOT NULL' in generator_definition)=0
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN position($marker$v_candidate->>'status','WAREHOUSE_SETUP_REQUIRED'$marker$ in generator_definition)=0
      AND position('AND line.destination_warehouse_id IS NOT NULL' in generator_definition)=0
      THEN 0 ELSE 1 END,
    jsonb_build_object('warehouseReblockAbsent',
      position($marker$v_candidate->>'status','WAREHOUSE_SETUP_REQUIRED'$marker$ in generator_definition)=0,
      'destinationFilterAbsent',
      position('AND line.destination_warehouse_id IS NOT NULL' in generator_definition)=0)
  FROM definitions
  UNION ALL
  SELECT 'daily_receipt_destination_selection_boundary',
    CASE WHEN position('line.destination_warehouse_id IS NULL OR line.destination_warehouse_id=v_warehouse.id'
      in receipt_definition)>0 THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN position('line.destination_warehouse_id IS NULL OR line.destination_warehouse_id=v_warehouse.id'
      in receipt_definition)>0 THEN 0 ELSE 1 END,
    jsonb_build_object('unsetLineDestinationAcceptedAtSave',
      position('line.destination_warehouse_id IS NULL OR line.destination_warehouse_id=v_warehouse.id'
        in receipt_definition)>0,
      'selectedWarehouseStillValidated',position('PURCHASE_RECEIPT_WAREHOUSE_INVALID'
        in receipt_definition)>0)
  FROM definitions
  UNION ALL
  SELECT 'inactive_master_runtime_contract',
    CASE WHEN position('PRODUCT_INACTIVE' in candidate_definition)>0
      AND position('SOURCE_WAREHOUSE_INACTIVE' in candidate_definition)>0
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN position('PRODUCT_INACTIVE' in candidate_definition)>0
      AND position('SOURCE_WAREHOUSE_INACTIVE' in candidate_definition)>0
      THEN 0 ELSE 1 END,
    jsonb_build_object('productInactiveExcluded',position('PRODUCT_INACTIVE'
      in candidate_definition)>0,'sourceWarehouseInactiveExcluded',
      position('SOURCE_WAREHOUSE_INACTIVE' in candidate_definition)>0)
  FROM definitions
  UNION ALL
  SELECT 'warehouse_boundary_runtime_inventory','INFO',0,jsonb_build_object(
    'unsetDestinationDailyOrderLines',(SELECT count(*) FROM public.supplier_order_lines line
      JOIN public.supplier_order_documents document ON document.company_id=line.company_id
        AND document.id=line.document_id
      WHERE document.order_source='DAILY_REPLENISHMENT'
        AND line.destination_warehouse_id IS NULL),
    'inactiveProductNegativeStocks',(SELECT count(*) FROM public.product_stocks stock
      JOIN public.products product ON product.company_id=stock.company_id
        AND product.id=stock.product_id WHERE stock.stock_qty<0 AND NOT product.is_active),
    'inactiveSourceNegativeStocks',(SELECT count(*) FROM public.product_stocks stock
      JOIN public.warehouses warehouse ON warehouse.company_id=stock.company_id
        AND warehouse.id=stock.warehouse_id WHERE stock.stock_qty<0 AND NOT warehouse.is_active))
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 0 WHEN 'BLOCKER' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,
  check_name;
