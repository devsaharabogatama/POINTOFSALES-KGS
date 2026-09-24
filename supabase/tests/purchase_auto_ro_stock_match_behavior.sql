-- Rollback-only LSM behavior test for Draft-RO/PO coverage de-duplication.
-- It creates transient RO/PO documents but no Stock/FIFO/Finance mutation.
BEGIN;

DO $setup$
DECLARE v_company constant uuid:='07bdffb9-8c56-444c-a49b-81ac86745674'::uuid;
  v_actor uuid;v_coverage_date date;v_target_date date;v_candidate jsonb;
  v_target uuid:=gen_random_uuid();
  v_coverage uuid:=gen_random_uuid();v_target_line uuid:=gen_random_uuid();
  v_raw numeric;v_stock_hash text;v_fifo_hash text;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260924100000') THEN
    RAISE EXCEPTION 'TEST_PHASE_FAILED [DEPENDENCY]: migration 20260924100000 missing';
  END IF;
  SELECT setting.updated_by INTO v_actor
  FROM public.company_purchase_replenishment_settings setting
  WHERE setting.company_id=v_company AND setting.replenishment_mode='AUTO_RO';
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'TEST_PHASE_FAILED [FIXTURE]: LSM actor unavailable';
  END IF;

  -- Existing production Drafts are only hidden inside this transaction so the
  -- fixture has a deterministic coverage boundary. ROLLBACK restores them.
  UPDATE public.purchase_daily_batches SET status='CANCELED',
    master_version=master_version+1,updated_at=clock_timestamp()
  WHERE company_id=v_company AND mode_snapshot='AUTO_RO' AND status='DRAFT';
  UPDATE public.company_purchase_replenishment_settings
  SET auto_ro_stock_match_enabled=true WHERE company_id=v_company;

  SELECT coalesce(max(batch.business_date),
      (clock_timestamp() AT TIME ZONE company.timezone)::date)+1
  INTO v_coverage_date FROM public.companies company
  LEFT JOIN public.purchase_daily_batches batch ON batch.company_id=company.id
  WHERE company.id=v_company GROUP BY company.timezone;
  v_target_date:=v_coverage_date+1;
  SELECT item INTO v_candidate
  FROM jsonb_array_elements(private.get_purchase_daily_replenishment_candidates_core(
    v_company,v_target_date)->'candidates') item
  WHERE (item->>'requestedBaseQty')::numeric>2
    AND item->>'status' IN('READY','SUPPLIER_PENDING')
    AND NULLIF(item->>'destinationWarehouseId','') IS NOT NULL
  ORDER BY (item->>'requestedBaseQty')::numeric DESC,item->>'productId' LIMIT 1;
  IF v_candidate IS NULL THEN
    RAISE EXCEPTION 'TEST_PHASE_FAILED [FIXTURE]: no actionable LSM negative Stock row > 2 base';
  END IF;
  v_raw:=(v_candidate->>'requestedBaseQty')::numeric;

  INSERT INTO public.purchase_daily_batches(id,company_id,batch_no,business_date,
    mode_snapshot,status,cutoff_at,generated_by,line_count,requested_total_base_qty)
  VALUES
    (v_coverage,v_company,'TEST-COVERAGE-'||left(replace(v_coverage::text,'-',''),12),
      v_coverage_date,'AUTO_RO','DRAFT',clock_timestamp(),v_actor,1,1),
    (v_target,v_company,'TEST-TARGET-'||left(replace(v_target::text,'-',''),12),
      v_target_date,'AUTO_RO','DRAFT',clock_timestamp(),v_actor,1,v_raw);
  INSERT INTO public.purchase_daily_batch_lines(id,company_id,batch_id,line_no,
    product_id,warehouse_id,base_uom_id,on_hand_snapshot,
    open_purchase_base_qty_snapshot,requested_base_qty,
    suggested_product_supplier_id,suggested_supplier_id,
    supplier_assignment_status,product_sku_snapshot,product_name_snapshot,
    warehouse_code_snapshot,warehouse_name_snapshot,base_uom_name_snapshot,
    destination_warehouse_id,requires_transfer,destination_warehouse_code_snapshot,
    destination_warehouse_name_snapshot,readiness_status)
  VALUES
    (gen_random_uuid(),v_company,v_coverage,1,(v_candidate->>'productId')::uuid,
      (v_candidate->>'sourceWarehouseId')::uuid,(v_candidate->>'baseUomId')::uuid,
      (v_candidate->>'onHandBaseQty')::numeric,
      (v_candidate->>'openPurchaseBaseQty')::numeric,1,
      NULLIF(v_candidate->>'suggestedProductSupplierId','')::uuid,
      NULLIF(v_candidate->>'suggestedSupplierId','')::uuid,
      v_candidate->>'supplierAssignmentStatus',v_candidate->>'productSku',
      v_candidate->>'productName',v_candidate->>'sourceWarehouseCode',
      v_candidate->>'sourceWarehouseName',v_candidate->>'baseUomName',
      NULLIF(v_candidate->>'destinationWarehouseId','')::uuid,
      coalesce((v_candidate->>'requiresTransfer')::boolean,false),
      NULLIF(v_candidate->>'destinationWarehouseCode',''),
      NULLIF(v_candidate->>'destinationWarehouseName',''),v_candidate->>'status'),
    (v_target_line,v_company,v_target,1,(v_candidate->>'productId')::uuid,
      (v_candidate->>'sourceWarehouseId')::uuid,(v_candidate->>'baseUomId')::uuid,
      (v_candidate->>'onHandBaseQty')::numeric,
      (v_candidate->>'openPurchaseBaseQty')::numeric,v_raw,
      NULLIF(v_candidate->>'suggestedProductSupplierId','')::uuid,
      NULLIF(v_candidate->>'suggestedSupplierId','')::uuid,
      v_candidate->>'supplierAssignmentStatus',v_candidate->>'productSku',
      v_candidate->>'productName',v_candidate->>'sourceWarehouseCode',
      v_candidate->>'sourceWarehouseName',v_candidate->>'baseUomName',
      NULLIF(v_candidate->>'destinationWarehouseId','')::uuid,
      coalesce((v_candidate->>'requiresTransfer')::boolean,false),
      NULLIF(v_candidate->>'destinationWarehouseCode',''),
      NULLIF(v_candidate->>'destinationWarehouseName',''),v_candidate->>'status');

  SELECT md5(coalesce(string_agg(stock.product_id::text||'|'||stock.warehouse_id::text||
    '|'||stock.stock_qty::text,';' ORDER BY stock.product_id,stock.warehouse_id),''))
  INTO v_stock_hash FROM public.product_stocks stock WHERE stock.company_id=v_company;
  SELECT md5(coalesce(string_agg(batch.id::text||'|'||batch.qty_purchased::text||
    '|'||batch.qty_remaining::text||'|'||batch.cogs_unit::text,';' ORDER BY batch.id),''))
  INTO v_fifo_hash FROM public.product_batches batch WHERE batch.company_id=v_company;

  PERFORM set_config('kgs.stock_match_company',v_company::text,true);
  PERFORM set_config('kgs.stock_match_actor',v_actor::text,true);
  PERFORM set_config('kgs.stock_match_target',v_target::text,true);
  PERFORM set_config('kgs.stock_match_coverage',v_coverage::text,true);
  PERFORM set_config('kgs.stock_match_product',v_candidate->>'productId',true);
  PERFORM set_config('kgs.stock_match_warehouse',v_candidate->>'sourceWarehouseId',true);
  PERFORM set_config('kgs.stock_match_raw',v_raw::text,true);
  PERFORM set_config('kgs.stock_match_stock_hash',v_stock_hash,true);
  PERFORM set_config('kgs.stock_match_fifo_hash',v_fifo_hash,true);
  PERFORM set_config('kgs.stock_match_movement_count',(
    SELECT count(*) FROM public.stock_movements WHERE company_id=v_company)::text,true);
  PERFORM set_config('kgs.stock_match_finance_count',(
    SELECT count(*) FROM public.financial_events WHERE company_id=v_company)::text,true);
  PERFORM set_config('kgs.stock_match_journal_count',(
    SELECT count(*) FROM public.journal_entries WHERE company_id=v_company)::text,true);
  PERFORM set_config('request.jwt.claim.sub',v_actor::text,true);
  PERFORM set_config('request.jwt.claim.role','authenticated',true);
  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub',v_actor,'role','authenticated')::text,true);
END
$setup$;

SET LOCAL ROLE authenticated;
SELECT public.set_active_company_context(
  '07bdffb9-8c56-444c-a49b-81ac86745674'::uuid,'AUTO_RO_STOCK_MATCH_TEST');

DO $first_match$
DECLARE v_target uuid:=current_setting('kgs.stock_match_target')::uuid;
  v_raw numeric:=current_setting('kgs.stock_match_raw')::numeric;
  v_preview jsonb;v_result jsonb;v_operation uuid:=gen_random_uuid();
  v_need jsonb;v_target_qty numeric;
BEGIN
  v_preview:=public.get_purchase_daily_auto_ro_stock_match(v_target);
  SELECT item INTO v_need FROM jsonb_array_elements(v_preview->'needs') item
  WHERE (item->>'productId')::uuid=current_setting('kgs.stock_match_product')::uuid
    AND (item->>'sourceWarehouseId')::uuid=
      current_setting('kgs.stock_match_warehouse')::uuid;
  IF v_need IS NULL OR (v_need->>'requestedBaseQty')::numeric<>v_raw-1
    OR (v_need->>'otherDraftRoBaseQty')::numeric<>1 THEN
    RAISE EXCEPTION 'TEST_PHASE_FAILED [DRAFT_COVERAGE]: expected raw-1 and one Draft coverage for target, got %',coalesce(v_need,'{}'::jsonb);
  END IF;
  v_result:=public.reconcile_purchase_daily_auto_ro_stock(
    v_target,(v_preview->>'batchVersion')::bigint,v_operation);
  SELECT line.requested_base_qty INTO v_target_qty
  FROM public.purchase_daily_batch_lines line
  WHERE line.company_id=current_setting('kgs.stock_match_company')::uuid
    AND line.batch_id=v_target
    AND line.product_id=current_setting('kgs.stock_match_product')::uuid
    AND line.warehouse_id=current_setting('kgs.stock_match_warehouse')::uuid;
  IF v_target_qty IS DISTINCT FROM v_raw-1 THEN
    RAISE EXCEPTION 'TEST_PHASE_FAILED [FIRST_MATCH]: unexpected result %',v_result;
  END IF;
  PERFORM set_config('kgs.stock_match_first_operation',v_operation::text,true);
  PERFORM set_config('kgs.stock_match_first_version',(v_result->>'masterVersion'),true);
END
$first_match$;

RESET ROLE;

-- Removing the other Draft coverage makes the just-matched target stale.
UPDATE public.purchase_daily_batches SET status='CANCELED',
  master_version=master_version+1,updated_at=clock_timestamp()
WHERE company_id=current_setting('kgs.stock_match_company')::uuid
  AND id=current_setting('kgs.stock_match_coverage')::uuid;

SET LOCAL ROLE authenticated;
SELECT public.set_active_company_context(
  '07bdffb9-8c56-444c-a49b-81ac86745674'::uuid,'AUTO_RO_STOCK_MATCH_TEST');

DO $confirm_and_retry$
DECLARE v_target uuid:=current_setting('kgs.stock_match_target')::uuid;
  v_first_operation uuid:=current_setting('kgs.stock_match_first_operation')::uuid;
  v_first_version bigint:=current_setting('kgs.stock_match_first_version')::bigint;
  v_match_operation uuid:=gen_random_uuid();v_confirm_operation uuid:=gen_random_uuid();
  v_variance_operation uuid:=gen_random_uuid();v_result jsonb;v_retry jsonb;
  v_allocation jsonb;v_target_qty numeric;
  v_matched_version bigint;
BEGIN
  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'batchLineId',line.id,'batchLineVersion',line.master_version,
    'destinationWarehouseId',line.destination_warehouse_id,
    'orderedQty',line.requested_base_qty,'purchaseUomId',line.base_uom_id,
    'productSupplierId',NULL,'estimatedUnitPrice',0) ORDER BY line.line_no),'[]'::jsonb)
  INTO v_allocation FROM public.purchase_daily_batch_lines line
  WHERE line.company_id=current_setting('kgs.stock_match_company')::uuid
    AND line.batch_id=v_target;
  BEGIN
    PERFORM public.confirm_purchase_daily_auto_ro_matched(v_target,v_first_version,
      gen_random_uuid(),v_first_operation,false,v_allocation);
    RAISE EXCEPTION 'TEST_PHASE_FAILED [STALE]: changed Draft coverage was accepted';
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    IF SQLERRM NOT LIKE '%PURCHASE_AUTO_RO_REFRESH_REQUIRED%' THEN RAISE; END IF;
  END;

  v_result:=public.reconcile_purchase_daily_auto_ro_stock(
    v_target,v_first_version,v_match_operation);
  v_retry:=public.reconcile_purchase_daily_auto_ro_stock(
    v_target,v_first_version,v_match_operation);
  IF NOT coalesce((v_retry->>'exactRetry')::boolean,false)
    THEN
    RAISE EXCEPTION 'TEST_PHASE_FAILED [REMATCH_RETRY]: % / %',v_result,v_retry;
  END IF;
  v_matched_version:=(v_result->>'masterVersion')::bigint;
  SELECT line.requested_base_qty INTO v_target_qty
  FROM public.purchase_daily_batch_lines line
  WHERE line.company_id=current_setting('kgs.stock_match_company')::uuid
    AND line.batch_id=v_target
    AND line.product_id=current_setting('kgs.stock_match_product')::uuid
    AND line.warehouse_id=current_setting('kgs.stock_match_warehouse')::uuid;
  IF v_target_qty IS DISTINCT FROM current_setting('kgs.stock_match_raw')::numeric THEN
    RAISE EXCEPTION 'TEST_PHASE_FAILED [REMATCH]: target quantity did not restore to raw need';
  END IF;
  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'batchLineId',line.id,'batchLineVersion',line.master_version,
    'destinationWarehouseId',line.destination_warehouse_id,
    'orderedQty',line.requested_base_qty+CASE WHEN
      line.product_id=current_setting('kgs.stock_match_product')::uuid
      AND line.warehouse_id=current_setting('kgs.stock_match_warehouse')::uuid
      THEN 1 ELSE 0 END,
    'purchaseUomId',line.base_uom_id,'productSupplierId',NULL,
    'estimatedUnitPrice',0) ORDER BY line.line_no),'[]'::jsonb)
  INTO v_allocation FROM public.purchase_daily_batch_lines line
  WHERE line.company_id=current_setting('kgs.stock_match_company')::uuid
    AND line.batch_id=v_target;
  BEGIN
    PERFORM public.confirm_purchase_daily_auto_ro_matched(v_target,
      v_matched_version,v_variance_operation,v_match_operation,
      false,v_allocation);
    RAISE EXCEPTION 'TEST_PHASE_FAILED [VARIANCE]: unacknowledged variance accepted';
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    IF SQLERRM NOT LIKE '%PURCHASE_AUTO_RO_VARIANCE_CONFIRMATION_REQUIRED%' THEN RAISE; END IF;
  END;
  v_result:=public.confirm_purchase_daily_auto_ro_matched(v_target,
    v_matched_version,v_confirm_operation,v_match_operation,
    true,v_allocation);
  v_retry:=public.confirm_purchase_daily_auto_ro_matched(v_target,
    v_matched_version,v_confirm_operation,v_match_operation,
    true,v_allocation);
  IF (v_result->>'supplierOrderCount')::integer<>1
    OR NOT coalesce((v_retry->>'exactRetry')::boolean,false) THEN
    RAISE EXCEPTION 'TEST_PHASE_FAILED [CONFIRM_RETRY]: % / %',v_result,v_retry;
  END IF;
  PERFORM set_config('kgs.stock_match_confirmed_target',v_target::text,true);
END
$confirm_and_retry$;

RESET ROLE;

DO $boundary$
DECLARE v_company uuid:=current_setting('kgs.stock_match_company')::uuid;
  v_target uuid:=current_setting('kgs.stock_match_confirmed_target')::uuid;
  v_probe uuid:=gen_random_uuid();v_source public.purchase_daily_batch_lines%rowtype;
  v_preview jsonb;v_stock_hash text;v_fifo_hash text;
BEGIN
  SELECT * INTO v_source FROM public.purchase_daily_batch_lines line
  WHERE line.company_id=v_company AND line.batch_id=v_target
    AND line.product_id=current_setting('kgs.stock_match_product')::uuid
    AND line.warehouse_id=current_setting('kgs.stock_match_warehouse')::uuid;
  INSERT INTO public.purchase_daily_batches(id,company_id,batch_no,business_date,
    mode_snapshot,status,cutoff_at,generated_by,line_count,requested_total_base_qty)
  SELECT v_probe,v_company,'TEST-PROBE-'||left(replace(v_probe::text,'-',''),12),
    batch.business_date+1,'AUTO_RO','DRAFT',clock_timestamp(),
    current_setting('kgs.stock_match_actor')::uuid,1,1
  FROM public.purchase_daily_batches batch WHERE batch.company_id=v_company AND batch.id=v_target;
  INSERT INTO public.purchase_daily_batch_lines(company_id,batch_id,line_no,
    product_id,warehouse_id,base_uom_id,on_hand_snapshot,
    open_purchase_base_qty_snapshot,requested_base_qty,
    supplier_assignment_status,product_sku_snapshot,product_name_snapshot,
    warehouse_code_snapshot,warehouse_name_snapshot,base_uom_name_snapshot,
    destination_warehouse_id,requires_transfer,destination_warehouse_code_snapshot,
    destination_warehouse_name_snapshot,readiness_status)
  SELECT v_company,v_probe,1,product_id,warehouse_id,base_uom_id,on_hand_snapshot,
    open_purchase_base_qty_snapshot,1,supplier_assignment_status,
    product_sku_snapshot,product_name_snapshot,warehouse_code_snapshot,
    warehouse_name_snapshot,base_uom_name_snapshot,destination_warehouse_id,
    requires_transfer,destination_warehouse_code_snapshot,
    destination_warehouse_name_snapshot,'SUPPLIER_PENDING'
  FROM public.purchase_daily_batch_lines line
  WHERE line.company_id=v_company AND line.id=v_source.id;
  v_preview:=private.get_purchase_daily_auto_ro_stock_match_core(v_company,v_probe);
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(v_preview->'needs') item
      WHERE (item->>'productId')::uuid=v_source.product_id
        AND (item->>'sourceWarehouseId')::uuid=v_source.warehouse_id) THEN
    RAISE EXCEPTION 'TEST_PHASE_FAILED [RO_PO_DEDUP]: confirmed RO and remaining PO were double counted';
  END IF;
  IF EXISTS(SELECT 1 FROM public.purchase_daily_batch_lines line
      JOIN public.purchase_daily_batches batch ON batch.company_id=line.company_id
        AND batch.id=line.batch_id
      WHERE line.company_id=v_company AND line.product_id=v_source.product_id
        AND line.warehouse_id=v_source.warehouse_id AND batch.id=v_target
        AND batch.status='DRAFT') THEN
    RAISE EXCEPTION 'TEST_PHASE_FAILED [RO_PO_DEDUP]: confirmed RO remained Draft coverage';
  END IF;

  SELECT md5(coalesce(string_agg(stock.product_id::text||'|'||stock.warehouse_id::text||
    '|'||stock.stock_qty::text,';' ORDER BY stock.product_id,stock.warehouse_id),''))
  INTO v_stock_hash FROM public.product_stocks stock WHERE stock.company_id=v_company;
  SELECT md5(coalesce(string_agg(batch.id::text||'|'||batch.qty_purchased::text||
    '|'||batch.qty_remaining::text||'|'||batch.cogs_unit::text,';' ORDER BY batch.id),''))
  INTO v_fifo_hash FROM public.product_batches batch WHERE batch.company_id=v_company;
  IF v_stock_hash<>current_setting('kgs.stock_match_stock_hash')
    OR v_fifo_hash<>current_setting('kgs.stock_match_fifo_hash')
    OR (SELECT count(*) FROM public.stock_movements WHERE company_id=v_company)<>
      current_setting('kgs.stock_match_movement_count')::bigint
    OR (SELECT count(*) FROM public.financial_events WHERE company_id=v_company)<>
      current_setting('kgs.stock_match_finance_count')::bigint
    OR (SELECT count(*) FROM public.journal_entries WHERE company_id=v_company)<>
      current_setting('kgs.stock_match_journal_count')::bigint THEN
    RAISE EXCEPTION 'TEST_PHASE_FAILED [BOUNDARY]: Stock/FIFO/Finance changed';
  END IF;
END
$boundary$;

SELECT 'purchase_auto_ro_stock_match_behavior' check_name,'PASS' status,
  0::bigint violation_rows,jsonb_build_object('tested',ARRAY[
    'self-created LSM Draft fixtures','current RO excluded from its own coverage',
    'only other DRAFT RO contributes RO coverage',
    'coverage change after match rejected as stale','in-place audited rematch',
    'reconcile exact retry','unacknowledged quantity variance rejected',
    'acknowledged variance creates PO','confirmation exact retry',
    'confirmed RO ignored while remaining PO supplies coverage',
    'no Stock/FIFO/Finance mutation','all transactional business rows rolled back; document sequences may skip']) details;

ROLLBACK;
