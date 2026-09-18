-- Physical receipt bridge for approved Returns whose source is retained Retail.
-- Native Backoffice sources continue through the original exact-FIFO core.
-- Rollback note: any error before COMMIT rolls the whole migration back. After a
-- successful commit and before runtime rows exist, remove only this bridge in a
-- separately reviewed migration. Once receipt rows exist, use forward-fix only;
-- immutable Stock/cost/audit history must never be deleted or rewritten.
BEGIN;
SET LOCAL lock_timeout='5s';
DO $guard$ BEGIN
 IF (SELECT count(*) FROM private.kgs_schema_migrations WHERE version IN(
  '20260917110000','20260917120000','20260917121000','20260917122000',
  '20260917140000','20260918100000','20260918110000','20260918120000'))<>8 THEN
  RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: retained Return dependency chain incomplete'; END IF;
 IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260918130000') THEN
  RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260918130000'; END IF;
 IF to_regprocedure('private.post_retained_retail_return_receipt_core(uuid,bigint,uuid,date,jsonb,text)') IS NOT NULL THEN
  RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: retained receipt bridge collision'; END IF;
 IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
  RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue'; END IF;
 IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
  WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
  RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal offline submission'; END IF;
END $guard$;

ALTER TABLE public.backoffice_sales_return_receipt_fifo_restorations
 ADD COLUMN cost_lineage text NOT NULL DEFAULT 'EXACT_FIFO',
 ADD COLUMN source_retail_sales_detail_id uuid,
 ADD COLUMN source_stock_requirement_id uuid,
 ADD COLUMN source_line_base_qty numeric(24,6),
 ADD COLUMN source_line_cost_total numeric(24,4);
ALTER TABLE public.backoffice_sales_return_receipt_fifo_restorations
 ALTER COLUMN source_customer_receipt_fifo_allocation_id DROP NOT NULL,
 ALTER COLUMN source_transit_batch_id DROP NOT NULL;
ALTER TABLE public.backoffice_sales_return_receipt_fifo_restorations
 DROP CONSTRAINT backoffice_sales_return_receipt_fifo_shape_check,
 ADD CONSTRAINT backoffice_sales_return_receipt_fifo_retail_detail_fk
  FOREIGN KEY(company_id,source_retail_sales_detail_id)
  REFERENCES public.sales_details(company_id,id) ON DELETE RESTRICT,
 ADD CONSTRAINT backoffice_sales_return_receipt_fifo_requirement_fk
  FOREIGN KEY(company_id,source_stock_requirement_id)
  REFERENCES public.sale_stock_requirements(company_id,id) ON DELETE RESTRICT,
 ADD CONSTRAINT backoffice_sales_return_receipt_fifo_shape_check CHECK(
  disposition IN('RESTOCK','DESTROY') AND quantity_base>0 AND unit_cost>=0 AND total_cost>=0
  AND ((disposition='RESTOCK' AND restored_product_batch_id IS NOT NULL)
    OR (disposition='DESTROY' AND restored_product_batch_id IS NULL))
  AND ((cost_lineage='EXACT_FIFO'
    AND source_customer_receipt_fifo_allocation_id IS NOT NULL
    AND source_transit_batch_id IS NOT NULL AND source_retail_sales_detail_id IS NULL
    AND source_stock_requirement_id IS NULL AND source_line_base_qty IS NULL
    AND source_line_cost_total IS NULL AND total_cost=round(quantity_base*unit_cost,4))
   OR (cost_lineage='LEGACY_AGGREGATE_COST'
    AND source_customer_receipt_fifo_allocation_id IS NULL AND source_transit_batch_id IS NULL
    AND source_retail_sales_detail_id IS NOT NULL AND source_stock_requirement_id IS NOT NULL
    AND source_line_base_qty>0 AND source_line_cost_total>=0
    AND total_cost=round(source_line_cost_total*quantity_base/source_line_base_qty,4))));
CREATE INDEX backoffice_sales_return_receipt_fifo_retail_source
 ON public.backoffice_sales_return_receipt_fifo_restorations(
  company_id,source_retail_sales_detail_id,created_at,id)
 WHERE source_retail_sales_detail_id IS NOT NULL;

CREATE FUNCTION private.post_retained_retail_return_receipt_core(
 p_return_id uuid,p_expected_version bigint,p_operation_id uuid,
 p_receipt_date date,p_lines jsonb,p_notes text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
 v_document public.backoffice_sales_returns%rowtype;v_return_line public.backoffice_sales_return_lines%rowtype;
 v_detail public.sales_details%rowtype;v_requirement public.sale_stock_requirements%rowtype;
 v_item jsonb;v_receipt uuid:=gen_random_uuid();v_receipt_line uuid;v_receipt_no text;
 v_line_no int:=0;v_qty_uom numeric;v_qty_base numeric;v_received numeric;
 v_disposition text;v_warehouse uuid;v_warehouse_name text;v_notes text;
 v_hash text;v_retry jsonb;v_before jsonb;v_after jsonb;v_response jsonb;
 v_total numeric:=0;v_restock numeric:=0;v_destroy numeric:=0;v_cost numeric:=0;
 v_destroy_cost numeric:=0;v_line_cost numeric;v_unit_cost numeric;v_batch uuid;v_movement uuid;
 v_stock numeric;v_base_uom uuid;v_base_name text;v_today date;
 v_requirement_count bigint;
BEGIN
 PERFORM private.acp_require_permission_capability(v_company,'inventory.customer_return_receipts','POST');
 IF p_return_id IS NULL OR p_expected_version IS NULL OR p_operation_id IS NULL
  OR p_receipt_date IS NULL OR jsonb_typeof(p_lines)<>'array' OR jsonb_array_length(p_lines)=0 THEN
  RAISE EXCEPTION 'BACKOFFICE_SALES_RETURN_RECEIPT_INPUT_REQUIRED'; END IF;
 IF p_notes IS NOT NULL AND length(p_notes)>2000 THEN
  RAISE EXCEPTION 'BACKOFFICE_SALES_RETURN_RECEIPT_NOTES_TOO_LONG'; END IF;
 SELECT (clock_timestamp() AT TIME ZONE timezone)::date INTO v_today FROM public.companies
  WHERE id=v_company AND status='ACTIVE';
 IF v_today IS NULL OR p_receipt_date>v_today THEN
  RAISE EXCEPTION 'BACKOFFICE_SALES_RETURN_RECEIPT_DATE_FUTURE'; END IF;
 v_hash:=encode(extensions.digest(convert_to(jsonb_build_object('returnId',p_return_id,
  'expectedVersion',p_expected_version,'receiptDate',p_receipt_date,'lines',p_lines,
  'notes',nullif(btrim(COALESCE(p_notes,'')),''))::text,'UTF8'),'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(v_company::text||':'||p_operation_id::text,0));
 v_retry:=private.backoffice_sales_return_receipt_operation_retry(v_company,p_operation_id,v_hash);
 IF v_retry IS NOT NULL THEN RETURN v_retry; END IF;
 SELECT * INTO v_document FROM public.backoffice_sales_returns
  WHERE company_id=v_company AND id=p_return_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'BACKOFFICE_SALES_RETURN_NOT_FOUND'; END IF;
 IF v_document.source_kind<>'RETAINED_RETAIL' THEN
  RAISE EXCEPTION 'RETAINED_RETAIL_RETURN_SOURCE_REQUIRED'; END IF;
 IF p_expected_version IS DISTINCT FROM v_document.master_version THEN
  RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
 IF v_document.status NOT IN('APPROVED','PARTIALLY_RECEIVED','RECEIVED')
  OR v_document.approved_at IS NULL THEN
  RAISE EXCEPTION 'BACKOFFICE_SALES_RETURN_RECEIPT_STATE_INVALID'; END IF;
 IF v_document.total_received_base_qty>=v_document.total_requested_base_qty THEN
  RAISE EXCEPTION 'BACKOFFICE_SALES_RETURN_ALREADY_FULLY_RECEIVED'; END IF;
 v_before:=private.backoffice_sales_return_snapshot(v_company,p_return_id);
 FOR v_item IN SELECT value FROM jsonb_array_elements(p_lines) LOOP
  v_line_no:=v_line_no+1;
  BEGIN
   SELECT * INTO STRICT v_return_line FROM public.backoffice_sales_return_lines
    WHERE company_id=v_company AND id=(v_item->>'returnLineId')::uuid
     AND return_id=p_return_id AND source_kind='RETAINED_RETAIL';
   v_qty_uom:=(v_item->>'quantityUom')::numeric;v_warehouse:=(v_item->>'warehouseId')::uuid;
  EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'BACKOFFICE_SALES_RETURN_RECEIPT_LINE_INVALID'; END;
  v_disposition:=upper(btrim(COALESCE(v_item->>'disposition','')));
  v_notes:=nullif(btrim(COALESCE(v_item->>'notes','')),'');
  IF v_qty_uom IS NULL OR v_qty_uom<=0 OR v_disposition NOT IN('RESTOCK','DESTROY')
   OR (v_disposition='DESTROY' AND v_notes IS NULL) THEN
   RAISE EXCEPTION 'BACKOFFICE_SALES_RETURN_RECEIPT_LINE_INVALID'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.warehouses WHERE company_id=v_company
   AND id=v_warehouse AND is_active) THEN
   RAISE EXCEPTION 'BACKOFFICE_SALES_RETURN_RECEIPT_WAREHOUSE_INVALID'; END IF;
  v_qty_base:=v_qty_uom*v_return_line.base_qty_per_uom;
  SELECT COALESCE(sum(received_base_qty),0) INTO v_received
   FROM public.backoffice_sales_return_receipt_lines
   WHERE company_id=v_company AND return_line_id=v_return_line.id;
  SELECT v_received+COALESCE(sum((entry.value->>'quantityUom')::numeric
   *v_return_line.base_qty_per_uom),0) INTO v_received
   FROM jsonb_array_elements(p_lines) WITH ORDINALITY entry(value,ordinality)
   WHERE entry.ordinality<v_line_no AND entry.value->>'returnLineId'=v_return_line.id::text;
  IF v_received+v_qty_base>v_return_line.requested_base_qty THEN
   RAISE EXCEPTION 'BACKOFFICE_SALES_RETURN_RECEIPT_QUANTITY_EXCEEDS_APPROVED'; END IF;
  v_total:=v_total+v_qty_base;
  IF v_disposition='RESTOCK' THEN v_restock:=v_restock+v_qty_base;
  ELSE v_destroy:=v_destroy+v_qty_base; END IF;
 END LOOP;
 IF v_document.total_received_base_qty+v_total>v_document.total_requested_base_qty THEN
  RAISE EXCEPTION 'BACKOFFICE_SALES_RETURN_RECEIPT_QUANTITY_EXCEEDS_APPROVED'; END IF;
 v_receipt_no:='CRR-'||to_char(p_receipt_date,'YYYYMMDD')||'-'||
  lpad(nextval('private.backoffice_sales_return_receipt_no_seq')::text,10,'0');
 INSERT INTO public.backoffice_sales_return_receipts(id,company_id,receipt_no,return_id,
  receipt_date,total_received_base_qty,total_restocked_base_qty,total_destroyed_base_qty,
  total_fifo_cost,total_destroyed_fifo_cost,notes,posted_by)
 VALUES(v_receipt,v_company,v_receipt_no,p_return_id,p_receipt_date,v_total,v_restock,
  v_destroy,0,0,nullif(btrim(COALESCE(p_notes,'')),''),v_actor);
 v_line_no:=0;
 FOR v_item IN SELECT value FROM jsonb_array_elements(p_lines) LOOP
  v_line_no:=v_line_no+1;
  SELECT * INTO STRICT v_return_line FROM public.backoffice_sales_return_lines
   WHERE company_id=v_company AND id=(v_item->>'returnLineId')::uuid AND return_id=p_return_id;
  SELECT * INTO STRICT v_detail FROM public.sales_details WHERE company_id=v_company
   AND id=v_return_line.retail_sales_detail_id AND sales_id=v_document.retail_sales_id;
  SELECT count(*) INTO v_requirement_count FROM public.sale_stock_requirements
   WHERE company_id=v_company AND sales_detail_id=v_detail.id;
  IF v_requirement_count<>1 OR v_detail.quantity_base<=0 OR v_detail.fifo_cost_total<0 THEN
   RAISE EXCEPTION 'RETAINED_RETAIL_RETURN_LEGACY_COST_LINEAGE_INVALID'; END IF;
  SELECT * INTO STRICT v_requirement FROM public.sale_stock_requirements
   WHERE company_id=v_company AND sales_detail_id=v_detail.id;
  IF v_requirement.commercial_product_id IS DISTINCT FROM v_detail.product_id
   OR v_requirement.stock_product_id IS DISTINCT FROM v_return_line.product_id THEN
   RAISE EXCEPTION 'RETAINED_RETAIL_RETURN_PHYSICAL_PRODUCT_MISMATCH'; END IF;
  v_qty_uom:=(v_item->>'quantityUom')::numeric;
  v_qty_base:=v_qty_uom*v_return_line.base_qty_per_uom;
  v_warehouse:=(v_item->>'warehouseId')::uuid;
  v_disposition:=upper(btrim(v_item->>'disposition'));
  v_notes:=nullif(btrim(COALESCE(v_item->>'notes','')),'');
  SELECT name INTO STRICT v_warehouse_name FROM public.warehouses
   WHERE company_id=v_company AND id=v_warehouse AND is_active;
  SELECT product.uom_id,uom.name INTO STRICT v_base_uom,v_base_name
   FROM public.products product JOIN public.uoms uom
    ON uom.company_id=product.company_id AND uom.id=product.uom_id
   WHERE product.company_id=v_company AND product.id=v_return_line.product_id;
  v_line_cost:=round(v_detail.fifo_cost_total*v_qty_base/v_detail.quantity_base,4);
  v_unit_cost:=CASE WHEN v_detail.quantity_base=0 THEN 0
   ELSE v_detail.fifo_cost_total/v_detail.quantity_base END;
  v_receipt_line:=gen_random_uuid();v_batch:=NULL;
  IF v_disposition='RESTOCK' THEN
   INSERT INTO public.product_batches(product_id,warehouse_id,purchase_detail_id,
    qty_purchased,qty_remaining,cogs_unit,company_id)
   VALUES(v_return_line.product_id,v_warehouse,NULL,v_qty_base,v_qty_base,v_unit_cost,v_company)
   RETURNING id INTO v_batch;
  END IF;
  INSERT INTO public.backoffice_sales_return_receipt_fifo_restorations(company_id,
   receipt_id,receipt_line_id,cost_lineage,source_retail_sales_detail_id,
   source_stock_requirement_id,source_line_base_qty,source_line_cost_total,
   restored_product_batch_id,disposition,quantity_base,unit_cost,total_cost)
  VALUES(v_company,v_receipt,v_receipt_line,'LEGACY_AGGREGATE_COST',v_detail.id,
   v_requirement.id,v_detail.quantity_base,v_detail.fifo_cost_total,v_batch,
   v_disposition,v_qty_base,v_unit_cost,v_line_cost);
  v_movement:=NULL;
  IF v_disposition='RESTOCK' THEN
   v_movement:=gen_random_uuid();
   INSERT INTO public.product_stocks(product_id,warehouse_id,stock_qty,company_id)
   VALUES(v_return_line.product_id,v_warehouse,v_qty_base,v_company)
   ON CONFLICT(product_id,warehouse_id) DO UPDATE SET
    stock_qty=public.product_stocks.stock_qty+excluded.stock_qty,updated_at=clock_timestamp()
   RETURNING stock_qty INTO v_stock;
   INSERT INTO public.stock_movements(id,product_id,warehouse_id,qty_change,movement_type,
    reference_table,reference_id,company_id,base_uom_id,base_uom_name_snapshot,
    balance_after_base_qty,actor_id,posted_at,movement_status,source_line_id,notes)
   VALUES(v_movement,v_return_line.product_id,v_warehouse,v_qty_base,
    'SALES_RETURN'::public.stock_movement_type,'backoffice_sales_return_receipts',v_receipt,
    v_company,v_base_uom,v_base_name,v_stock,v_actor,clock_timestamp(),'POSTED',v_receipt_line,
    COALESCE(v_notes,'Retur Customer asal Retail - LEGACY_AGGREGATE_COST'));
  END IF;
  INSERT INTO public.backoffice_sales_return_receipt_lines(id,company_id,receipt_id,
   return_id,return_line_id,line_no,product_id,uom_id,warehouse_id,disposition,
   received_qty_uom,base_qty_per_uom,received_base_qty,fifo_cost_total,stock_movement_id,
   notes,product_code_snapshot,product_name_snapshot,uom_code_snapshot,uom_name_snapshot,
   warehouse_name_snapshot)
  VALUES(v_receipt_line,v_company,v_receipt,p_return_id,v_return_line.id,v_line_no,
   v_return_line.product_id,v_return_line.uom_id,v_warehouse,v_disposition,v_qty_uom,
   v_return_line.base_qty_per_uom,v_qty_base,v_line_cost,v_movement,v_notes,
   v_return_line.product_code_snapshot,v_return_line.product_name_snapshot,
   v_return_line.uom_code_snapshot,v_return_line.uom_name_snapshot,v_warehouse_name);
  v_cost:=v_cost+v_line_cost;
  IF v_disposition='DESTROY' THEN v_destroy_cost:=v_destroy_cost+v_line_cost; END IF;
 END LOOP;
 PERFORM set_config('kgs.backoffice_return_receipt_finalize','1',true);
 UPDATE public.backoffice_sales_return_receipts SET total_fifo_cost=v_cost,
  total_destroyed_fifo_cost=v_destroy_cost WHERE company_id=v_company AND id=v_receipt;
 PERFORM set_config('kgs.backoffice_return_receipt_finalize','',true);
 UPDATE public.backoffice_sales_returns SET total_received_base_qty=total_received_base_qty+v_total,
  total_restocked_base_qty=total_restocked_base_qty+v_restock,
  total_destroyed_base_qty=total_destroyed_base_qty+v_destroy,
  status=CASE WHEN total_received_base_qty+v_total=total_requested_base_qty
   THEN 'RECEIVED' ELSE 'PARTIALLY_RECEIVED' END,master_version=master_version+1,
  updated_by=v_actor,updated_at=clock_timestamp()
 WHERE company_id=v_company AND id=p_return_id;
 v_after:=private.backoffice_sales_return_snapshot(v_company,p_return_id);
 v_response:=jsonb_build_object('companyId',v_company,'returnId',p_return_id,
  'receiptId',v_receipt,'receiptNo',v_receipt_no,'data',v_after,'exactRetry',false,
  'costLineage','LEGACY_AGGREGATE_COST');
 INSERT INTO public.backoffice_sales_return_receipt_operations(company_id,operation_id,
  return_id,receipt_id,expected_version,request_hash,response_snapshot,actor_id)
 VALUES(v_company,p_operation_id,p_return_id,v_receipt,p_expected_version,v_hash,v_response,v_actor);
 INSERT INTO public.backoffice_sales_return_receipt_audit(company_id,return_id,receipt_id,
  operation_id,actor_id,before_state,after_state)
 VALUES(v_company,p_return_id,v_receipt,p_operation_id,v_actor,v_before,v_after);
 RETURN v_response;
END $$;

CREATE OR REPLACE FUNCTION public.post_backoffice_sales_return_receipt(
 p_return_id uuid,p_expected_version bigint,p_operation_id uuid,
 p_receipt_date date,p_lines jsonb,p_notes text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_kind text;
BEGIN
 SELECT source_kind INTO v_kind FROM public.backoffice_sales_returns
  WHERE company_id=public.private_active_company_id() AND id=p_return_id;
 IF v_kind='RETAINED_RETAIL' THEN
  RETURN private.post_retained_retail_return_receipt_core(p_return_id,p_expected_version,
   p_operation_id,p_receipt_date,p_lines,p_notes);
 END IF;
 RETURN private.post_backoffice_sales_return_receipt_core(p_return_id,p_expected_version,
  p_operation_id,p_receipt_date,p_lines,p_notes);
END $$;
REVOKE ALL ON FUNCTION private.post_retained_retail_return_receipt_core(
 uuid,bigint,uuid,date,jsonb,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.post_retained_retail_return_receipt_core(
 uuid,bigint,uuid,date,jsonb,text) TO service_role;
INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260918130000','retained_retail_return_receipt_bridge',
 'Retained Retail physical Return receipt using explicit LEGACY_AGGREGATE_COST; native Backoffice exact FIFO core unchanged');
NOTIFY pgrst,'reload schema';
COMMIT;
