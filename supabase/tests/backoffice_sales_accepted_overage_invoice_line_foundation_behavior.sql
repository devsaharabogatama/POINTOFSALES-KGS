-- Rollback-only constraint behavior for Step 4/6.5C2A.
BEGIN;
DO $test$
DECLARE v_failed boolean:=false; a uuid;c uuid;s uuid;w uuid;cu uuid;pu uuid;
 p uuid;u uuid;f numeric;d date;r jsonb;o uuid;ol uuid;delivery uuid;dl uuid;
 case_id uuid:=gen_random_uuid();source_id uuid:=gen_random_uuid();constraint_name text;
 inv uuid:=gen_random_uuid();il uuid:=gen_random_uuid();al uuid:=gen_random_uuid();
BEGIN
 IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260912123000') THEN
  RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: C2A foundation required';
 END IF;
 IF EXISTS(SELECT 1 FROM public.backoffice_sales_invoice_lines
   WHERE source_kind<>'SALES_ORDER' OR discrepancy_line_id IS NOT NULL)
 OR EXISTS(SELECT 1 FROM public.backoffice_sales_invoice_quantity_allocations
   WHERE source_kind<>'SALES_ORDER' OR discrepancy_line_id IS NOT NULL) THEN
  RAISE EXCEPTION 'TEST_FAILED: legacy Invoice rows were reclassified';
 END IF;
 SELECT profile.id INTO STRICT a FROM public.profiles profile JOIN auth.users actor ON actor.id=profile.id
 WHERE profile.role='super_admin' ORDER BY profile.id LIMIT 1;
 SELECT company.id,store.id,warehouse.id,customer.id,mapping.id,mapping.product_id,
 mapping.uom_id,mapping.factor_to_base,(clock_timestamp() AT TIME ZONE company.timezone)::date
 INTO STRICT c,s,w,cu,pu,p,u,f,d FROM public.companies company
 JOIN public.stores store ON store.company_id=company.id AND store.status='ACTIVE'
 JOIN public.warehouses warehouse ON warehouse.company_id=company.id AND warehouse.is_active
 AND warehouse.is_sale_source AND (warehouse.store_id IS NULL OR warehouse.store_id=store.id)
 JOIN public.customers customer ON customer.company_id=company.id AND customer.is_active
 JOIN public.product_uoms mapping ON mapping.company_id=company.id AND mapping.is_active
 AND mapping.sales_allowed AND mapping.factor_to_base>0
 JOIN public.products product ON product.company_id=company.id AND product.id=mapping.product_id
 AND product.is_active AND NOT product.is_bundle
 WHERE company.status='ACTIVE' ORDER BY company.id,store.id,warehouse.id,customer.id,mapping.id LIMIT 1;
 PERFORM set_config('request.jwt.claim.sub',a::text,true);
 INSERT INTO public.user_active_company_contexts(user_id,company_id) VALUES(a,c)
 ON CONFLICT(user_id) DO UPDATE SET company_id=excluded.company_id;
 INSERT INTO public.company_features(company_id,feature_code,is_enabled,config,updated_by)
 VALUES(c,'backoffice_delivered_qty_sales_enabled',true,'{}',a)
 ON CONFLICT(company_id,feature_code) DO UPDATE SET is_enabled=true,updated_by=a;
 PERFORM pg_advisory_xact_lock(hashtextextended(c::text,20260911130000));
 PERFORM set_config('kgs.sales_process_cutover_mutation','1',true);
 UPDATE public.company_sales_process_settings SET active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE',
 mode_effective_at='-infinity',master_version=master_version+1,updated_by=a,updated_at=clock_timestamp()
 WHERE company_id=c;
 IF NOT FOUND THEN RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: Company mode setting missing'; END IF;
 PERFORM set_config('kgs.sales_process_cutover_mutation','',true);
 PERFORM private.assert_sales_process_root_creation_allowed(c,'BACKOFFICE_DELIVERED_QTY_INVOICE');
 UPDATE public.warehouses SET allow_negative_stock=true WHERE company_id=c AND id=w;
 r:=public.save_backoffice_sales_order_draft(NULL,NULL,gen_random_uuid(),jsonb_build_object(
 'storeId',s,'warehouseId',w,'customerId',cu,'orderDate',d,'plannedDeliveryDate',d,
 'isTempo',false,'currencyCode','IDR','globalDiscount',0,'roundingDirection','NONE',
 'roundingIncrement',100,'lines',jsonb_build_array(jsonb_build_object(
 'productUomId',pu,'quantity',1,'overrideUnitPrice',10000))));
 o:=(r->'data'->>'id')::uuid;
 r:=public.confirm_backoffice_sales_order(o,(r->'data'->>'masterVersion')::bigint,gen_random_uuid());
 delivery:=(r->'fulfillment'->>'deliveryOrderId')::uuid;
 SELECT id,sales_order_line_id INTO STRICT dl,ol FROM public.backoffice_sales_delivery_order_lines
 WHERE company_id=c AND delivery_order_id=delivery;
 -- Synthetic rows test foundation constraints only, not physical Warehouse resolution.
 INSERT INTO public.backoffice_sales_delivery_discrepancies(id,company_id,discrepancy_no,
 delivery_order_id,sales_order_id,status,total_discrepancy_base_qty,
 requires_sales_approval,requires_warehouse_resolution,created_by,updated_by)
 VALUES(case_id,c,'C2A-'||case_id,delivery,o,'PENDING_WAREHOUSE_RESOLUTION',2*f,true,true,a,a);
 INSERT INTO public.backoffice_sales_delivery_discrepancy_lines(id,company_id,discrepancy_id,
 delivery_order_id,sales_order_id,delivery_order_line_id,sales_order_line_id,
 expected_product_id,uom_id,discrepancy_type,requested_resolution,quantity_uom,quantity_base,
 commercial_approval_status,warehouse_resolution_status,approved_unit_price,
 approved_discount_amount,approved_tax_amount,approved_line_total,commercial_snapshot,
 commercial_approved_by,commercial_approved_at)
 VALUES(source_id,c,case_id,delivery,o,dl,ol,p,u,'OVERAGE','ACCEPT_OVERAGE',2,2*f,
 'APPROVED','PENDING',10000,0,0,20000,'{}',a,clock_timestamp());
 BEGIN
 UPDATE public.backoffice_sales_delivery_discrepancy_lines SET accepted_overage_base_qty=2*f WHERE id=source_id;
 EXCEPTION WHEN check_violation THEN
 GET STACKED DIAGNOSTICS constraint_name=CONSTRAINT_NAME;
 v_failed:=constraint_name='bo_sales_discrepancy_overage_invoiceable_check'; END;
 IF NOT v_failed THEN RAISE EXCEPTION 'TEST_FAILED: pending Warehouse accepted qty allowed'; END IF;
 UPDATE public.backoffice_sales_delivery_discrepancy_lines SET warehouse_resolution_status='RESOLVED',
 accepted_overage_base_qty=2*f,draft_overage_invoice_allocated_base_qty=f WHERE id=source_id;
 IF NOT EXISTS(SELECT 1 FROM public.backoffice_sales_delivery_discrepancy_lines WHERE id=source_id
 AND overage_to_invoice_base_qty=f) THEN RAISE EXCEPTION 'TEST_FAILED: generated qty invalid'; END IF;
 v_failed:=false;
 BEGIN
 UPDATE public.backoffice_sales_delivery_discrepancy_lines SET invoiced_overage_base_qty=2*f WHERE id=source_id;
 EXCEPTION WHEN check_violation THEN
 GET STACKED DIAGNOSTICS constraint_name=CONSTRAINT_NAME;
 v_failed:=constraint_name='bo_sales_discrepancy_overage_invoiceable_check'; END;
 IF NOT v_failed THEN RAISE EXCEPTION 'TEST_FAILED: counter over-allocation accepted'; END IF;
 v_failed:=false;
 BEGIN
 UPDATE public.backoffice_sales_delivery_discrepancy_lines SET accepted_overage_base_qty=3*f WHERE id=source_id;
 EXCEPTION WHEN check_violation THEN
 GET STACKED DIAGNOSTICS constraint_name=CONSTRAINT_NAME;
 v_failed:=constraint_name='bo_sales_discrepancy_overage_invoiceable_check'; END;
 IF NOT v_failed THEN RAISE EXCEPTION 'TEST_FAILED: accepted exceeds discrepancy qty'; END IF;
 -- Direct Draft inserts exercise foundation constraints, not Invoice generation/posting.
 INSERT INTO public.backoffice_sales_invoices(id,company_id,sales_order_id,customer_id,store_id,
 warehouse_id,draft_no,invoice_sequence,invoice_type,invoice_date,currency_code,
 customer_snapshot,created_by,updated_by)
 VALUES(inv,c,o,cu,s,w,'C2A-INV-'||inv,1,'REGULAR',d,'IDR','{}',a,a);
 INSERT INTO public.backoffice_sales_invoice_lines(id,company_id,invoice_id,sales_order_id,
 sales_order_line_id,line_no,line_type,effect_type,product_id,uom_id,quantity_uom,
 base_qty_per_uom,quantity_base,unit_price,line_amount,description,source_kind,discrepancy_line_id)
 VALUES(il,c,inv,o,ol,1,'PRODUCT','CHARGE',p,u,1,f,f,10000,10000,'C2A fixture','ACCEPTED_OVERAGE',source_id);
 v_failed:=false;
 BEGIN
 INSERT INTO public.backoffice_sales_invoice_quantity_allocations(company_id,invoice_id,invoice_line_id,
 sales_order_id,sales_order_line_id,allocated_base_qty,source_kind,discrepancy_line_id)
 VALUES(c,inv,il,o,ol,2*f,'ACCEPTED_OVERAGE',source_id);
 EXCEPTION WHEN raise_exception THEN
 v_failed:=SQLERRM='BACKOFFICE_ACCEPTED_OVERAGE_INVOICE_SOURCE_INVALID'; END;
 IF NOT v_failed THEN RAISE EXCEPTION 'TEST_FAILED: mismatch/over-allocation accepted by trigger'; END IF;
 INSERT INTO public.backoffice_sales_invoice_quantity_allocations(id,company_id,invoice_id,invoice_line_id,
 sales_order_id,sales_order_line_id,allocated_base_qty,source_kind,discrepancy_line_id)
 VALUES(al,c,inv,il,o,ol,f,'ACCEPTED_OVERAGE',source_id);
 IF NOT EXISTS(SELECT 1 FROM public.backoffice_sales_invoice_quantity_allocations WHERE id=al
 AND allocated_base_qty=f AND source_kind='ACCEPTED_OVERAGE') THEN
 RAISE EXCEPTION 'TEST_FAILED: valid allocation missing'; END IF;
 v_failed:=false;
 BEGIN
 INSERT INTO public.backoffice_sales_invoice_quantity_allocations(company_id,invoice_id,invoice_line_id,
 sales_order_id,sales_order_line_id,allocated_base_qty,source_kind,discrepancy_line_id)
 VALUES(c,inv,il,o,ol,f,'ACCEPTED_OVERAGE',source_id);
 EXCEPTION WHEN unique_violation THEN v_failed:=true; END;
 IF NOT v_failed THEN RAISE EXCEPTION 'TEST_FAILED: duplicate allocation accepted'; END IF;
 v_failed:=false;
 BEGIN
 UPDATE public.backoffice_sales_invoice_lines SET source_kind='SALES_ORDER' WHERE id=il;
 EXCEPTION WHEN check_violation THEN
 GET STACKED DIAGNOSTICS constraint_name=CONSTRAINT_NAME;
 v_failed:=constraint_name='bo_sales_invoice_lines_source_check'; END;
 IF NOT v_failed THEN RAISE EXCEPTION 'TEST_FAILED: invalid source identity accepted'; END IF;
 IF to_regprocedure('private.validate_backoffice_sales_invoice_overage_source()') IS NULL THEN
  RAISE EXCEPTION 'TEST_FAILED: overage source validator missing';
 END IF;
END
$test$;
ROLLBACK;
SELECT 'backoffice_sales_accepted_overage_invoice_line_foundation_behavior' check_name,
 'PASS' status,0::bigint violation_rows,jsonb_build_object('tested',ARRAY[
 'legacy rows remain SALES_ORDER','canonical SO/DO fixture','pending Warehouse acceptance rejected',
 'real resolved-source counter write','generated Qty To Invoice','counter over-allocation rejected',
 'accepted exceeds discrepancy quantity rejected','valid allocation trigger','mismatch/over-allocation trigger rejection',
 'duplicate allocation rejected','invalid source identity rejected',
 'all writes rolled back; synthetic constraint fixture not physical receipt']) details;
