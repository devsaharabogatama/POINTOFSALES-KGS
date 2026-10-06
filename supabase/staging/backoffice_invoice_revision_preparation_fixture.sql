-- STAGING ROLLBACK-ONLY fixture for the revision preparation behavior test.
-- Creates three additional unpaid Regular Invoices for the same Customer as
-- the canonical DP-backed target. All rows are removed by the outer rollback.
CREATE TEMP TABLE staging_revision_invoice_fixture(
  ordinal integer PRIMARY KEY CHECK(ordinal BETWEEN 1 AND 4),
  invoice_id uuid NOT NULL UNIQUE,
  fixture_role text NOT NULL UNIQUE
) ON COMMIT DROP;

DO $fixture$
DECLARE
  c constant uuid:='4eedbf12-3c60-40e0-b2b7-1a48ca62b6f8'::uuid;
  actor uuid:=auth.uid();target public.backoffice_sales_invoices%rowtype;
  v_store uuid;v_warehouse uuid;v_product_uom uuid;v_product uuid;
  v_order uuid;v_order_line uuid;v_delivery uuid;v_delivery_line uuid;
  v_version bigint;v_today date;v_created jsonb;v_confirmed jsonb;v_received jsonb;
  v_invoice jsonb;v_posted jsonb;v_invoice_id uuid;v_batch uuid:=gen_random_uuid();
  v_movement uuid:=gen_random_uuid();v_stock numeric;v_topup numeric;
  v_iteration integer;v_phase text:='fixture_start';
BEGIN
  IF actor IS NULL THEN RAISE EXCEPTION 'TEST_PRECONDITION: auth context required'; END IF;
  v_phase:='select_dp_target';
  SELECT i.* INTO STRICT target FROM public.backoffice_sales_invoices i
  WHERE i.company_id=c AND i.status='POSTED' AND i.invoice_type='REGULAR'
    AND EXISTS(SELECT 1 FROM public.backoffice_sales_down_payment_applications a
      WHERE a.company_id=c AND a.regular_invoice_id=i.id AND a.status='POSTED')
  ORDER BY i.posted_at,i.id LIMIT 1;
  INSERT INTO staging_revision_invoice_fixture VALUES(1,target.id,'DP_TARGET');

  v_phase:='select_sales_masters';
  SELECT s.id,w.id,pu.id,pu.product_id,
    (clock_timestamp() AT TIME ZONE company.timezone)::date
  INTO STRICT v_store,v_warehouse,v_product_uom,v_product,v_today
  FROM public.companies company
  JOIN public.stores s ON s.company_id=company.id AND s.id=target.store_id
    AND s.status='ACTIVE'
  JOIN public.warehouses w ON w.company_id=company.id AND w.id=target.warehouse_id
    AND w.is_active AND w.is_sale_source
  JOIN public.product_uoms pu ON pu.company_id=company.id AND pu.is_active
    AND pu.sales_allowed AND pu.factor_to_base=1
  JOIN public.products p ON p.company_id=pu.company_id AND p.id=pu.product_id
    AND p.is_active AND NOT p.is_bundle AND p.uom_id=pu.uom_id
  WHERE company.id=c AND company.status='ACTIVE'
  ORDER BY pu.id LIMIT 1;

  SELECT COALESCE(stock.stock_qty,0) INTO v_stock FROM public.product_stocks stock
  WHERE stock.company_id=c AND stock.warehouse_id=v_warehouse AND stock.product_id=v_product;
  v_topup:=CASE WHEN COALESCE(v_stock,0)<6 THEN 6-COALESCE(v_stock,0) ELSE 3 END;
  INSERT INTO public.product_stocks(product_id,warehouse_id,stock_qty,company_id)
  VALUES(v_product,v_warehouse,v_topup,c)
  ON CONFLICT(product_id,warehouse_id) DO UPDATE
    SET stock_qty=public.product_stocks.stock_qty+excluded.stock_qty,
      updated_at=clock_timestamp();
  INSERT INTO public.product_batches(id,product_id,warehouse_id,qty_purchased,
    qty_remaining,cogs_unit,company_id)
  SELECT v_batch,v_product,v_warehouse,v_topup,v_topup,
    GREATEST(COALESCE(p.cogs,1),1),c FROM public.products p
  WHERE p.company_id=c AND p.id=v_product;
  SELECT stock.stock_qty INTO STRICT v_stock FROM public.product_stocks stock
  WHERE stock.company_id=c AND stock.warehouse_id=v_warehouse AND stock.product_id=v_product;
  INSERT INTO public.stock_movements(id,product_id,warehouse_id,qty_change,
    movement_type,reference_table,reference_id,company_id,base_uom_id,
    base_uom_name_snapshot,balance_after_base_qty,actor_id,posted_at,
    movement_status,source_line_id,notes)
  SELECT v_movement,v_product,v_warehouse,v_topup,
    'PURCHASE'::public.stock_movement_type,'BACKOFFICE_INVOICE_REVISION_PREPARATION_TEST',v_batch,
    c,p.uom_id,u.name,v_stock,actor,clock_timestamp(),'POSTED',v_batch,
    'Rollback-only Invoice revision preparation fixture'
  FROM public.products p JOIN public.uoms u ON u.company_id=p.company_id AND u.id=p.uom_id
  WHERE p.company_id=c AND p.id=v_product;

  FOR v_iteration IN 2..4 LOOP
    v_phase:='save_so_'||v_iteration;
    v_created:=public.save_backoffice_sales_order_draft(NULL,NULL,gen_random_uuid(),
      jsonb_build_object('storeId',v_store,'warehouseId',v_warehouse,
        'customerId',target.customer_id,'selectedPricelistId',NULL,
        'orderDate',v_today,'plannedDeliveryDate',v_today,'isTempo',true,
        'dueDate',v_today+14,'currencyCode','IDR','globalDiscount',0,
        'deliveryFeeAmount',0,'roundingDirection','NONE','roundingIncrement',100,
        'lines',jsonb_build_array(jsonb_build_object('productUomId',v_product_uom,
          'quantity',1,'overrideUnitPrice',100000))));
    v_order:=(v_created->'data'->>'id')::uuid;
    v_phase:='confirm_so_'||v_iteration;
    v_confirmed:=public.confirm_backoffice_sales_order(v_order,
      (v_created->'data'->>'masterVersion')::bigint,gen_random_uuid());
    v_phase:='select_so_line_'||v_iteration;
    SELECT line.id INTO STRICT v_order_line FROM public.backoffice_sales_order_lines line
    WHERE line.company_id=c AND line.sales_order_id=v_order;
    v_delivery:=(v_confirmed->'fulfillment'->>'deliveryOrderId')::uuid;
    v_phase:='select_delivery_line_'||v_iteration;
    SELECT line.id INTO STRICT v_delivery_line FROM public.backoffice_sales_delivery_order_lines line
    WHERE line.company_id=c AND line.delivery_order_id=v_delivery;
    SELECT document.master_version INTO STRICT v_version FROM public.backoffice_sales_delivery_orders document
    WHERE document.company_id=c AND document.id=v_delivery;
    v_phase:='dispatch_'||v_iteration;
    PERFORM public.dispatch_backoffice_sales_delivery(v_delivery,v_version,gen_random_uuid(),
      jsonb_build_array(jsonb_build_object('deliveryLineId',v_delivery_line,'quantityUom',1)),
      'Invoice revision preparation rollback fixture');
    SELECT document.master_version INTO STRICT v_version FROM public.backoffice_sales_delivery_orders document
    WHERE document.company_id=c AND document.id=v_delivery;
    v_phase:='receive_'||v_iteration;
    v_received:=public.receive_backoffice_sales_delivery(v_delivery,v_version,gen_random_uuid(),
      v_today,'Invoice revision preparation rollback fixture');
    IF v_received->>'deliveryStatus' IS DISTINCT FROM 'COMPLETED' THEN
      RAISE EXCEPTION 'TEST_FAILED: preparation fixture delivery did not complete';
    END IF;
    v_phase:='save_invoice_'||v_iteration;
    v_invoice:=public.save_backoffice_sales_invoice_draft(NULL,NULL,gen_random_uuid(),v_order,
      jsonb_build_object('invoiceType','REGULAR','invoiceDate',v_today,'dueDate',v_today+14,
        'paymentTermId',NULL,'deliveryFeeAmount',0,
        'lines',jsonb_build_array(jsonb_build_object('salesOrderLineId',v_order_line,
          'quantityUom',1,'unitPrice',100000,'discountAmount',0,'taxApplied',false))));
    v_invoice_id:=(v_invoice->'data'->>'id')::uuid;
    v_phase:='post_invoice_'||v_iteration;
    v_posted:=public.post_backoffice_sales_invoice(v_invoice_id,
      (v_invoice->'data'->>'masterVersion')::bigint,gen_random_uuid());
    IF v_posted->'data'->>'status' IS DISTINCT FROM 'POSTED'
      OR v_posted->'finance'->>'status' IS DISTINCT FROM 'POSTED' THEN
      RAISE EXCEPTION 'TEST_FAILED: preparation fixture Invoice did not post';
    END IF;
    INSERT INTO staging_revision_invoice_fixture
    VALUES(v_iteration,v_invoice_id,'UNPAID_SHARED_'||v_iteration);
  END LOOP;
EXCEPTION WHEN OTHERS THEN
  RAISE EXCEPTION 'REVISION_PREPARATION_FIXTURE_FAILED[%]: %',v_phase,SQLERRM
    USING ERRCODE=SQLSTATE;
END
$fixture$;
