-- Guarded Backoffice Quotation/Sales Order runtime.
-- This phase has zero Reservation, Stock, Delivery, Invoice, Payment or Finance effect.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260908110000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Backoffice order foundation required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260908120000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260908120000';
  END IF;
  IF EXISTS(SELECT 1 FROM public.company_features
    WHERE feature_code='backoffice_delivered_qty_sales_enabled' AND is_enabled) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Backoffice Sales feature must remain disabled';
  END IF;
  IF EXISTS(SELECT 1 FROM public.backoffice_sales_orders)
    OR EXISTS(SELECT 1 FROM public.backoffice_sales_order_lines)
    OR EXISTS(SELECT 1 FROM public.backoffice_sales_order_operations)
    OR EXISTS(SELECT 1 FROM public.backoffice_sales_order_audit) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Backoffice order foundation must be empty';
  END IF;
  IF EXISTS(SELECT 1 FROM public.access_permission_catalog
    WHERE permission_key='sales.backoffice_orders') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: permission collision';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
    WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
END
$guard$;

ALTER TABLE public.access_permission_catalog
  DROP CONSTRAINT access_permission_features_check;
ALTER TABLE public.access_permission_catalog
  ADD CONSTRAINT access_permission_features_check CHECK(
    required_any_features <@ ARRAY[
      'expense_enabled','customer_balance_enabled','tax_sales_enabled',
      'tax_purchase_enabled','offline_pos_enabled','negative_stock_enabled',
      'backoffice_delivered_qty_sales_enabled'
    ]::text[]
  );

INSERT INTO public.access_permission_catalog(
  permission_key,module_key,permission_label,description,view_roles,
  operator_roles,approver_roles,supported_capabilities,required_any_features,
  is_customizable,enforcement_status
) VALUES(
  'sales.backoffice_orders','SALES','Quotation & Sales Order',
  'Backoffice Quotation and Sales Order before fulfillment',
  ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','FINANCE','ACCOUNTING'],
  ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER'],'{}',
  ARRAY['VIEW','CREATE_DRAFT','EDIT_DRAFT','MANAGE'],
  ARRAY['backoffice_delivered_qty_sales_enabled'],true,'ENFORCED'
);

CREATE SEQUENCE private.backoffice_quotation_no_seq AS bigint START WITH 1;
CREATE SEQUENCE private.backoffice_sales_order_no_seq AS bigint START WITH 1;
REVOKE ALL ON SEQUENCE private.backoffice_quotation_no_seq,
  private.backoffice_sales_order_no_seq FROM PUBLIC,anon,authenticated;
GRANT USAGE,SELECT ON SEQUENCE private.backoffice_quotation_no_seq,
  private.backoffice_sales_order_no_seq TO service_role;

CREATE FUNCTION private.backoffice_sales_order_snapshot(
  p_company_id uuid,p_order_id uuid
) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
  SELECT jsonb_build_object(
    'id',document.id,'quotationNo',document.quotation_no,
    'orderNo',document.order_no,'status',document.status,
    'salesOrigin',document.sales_origin,'salesProcessMode',document.sales_process_mode,
    'storeId',document.store_id,'warehouseId',document.warehouse_id,
    'customerId',document.customer_id,'pricelistId',document.pricelist_id,
    'orderDate',document.order_date,'plannedDeliveryDate',document.planned_delivery_date,
    'isTempo',document.is_tempo,'dueDate',document.due_date,
    'currencyCode',document.currency_code,'customerSnapshot',document.customer_snapshot,
    'commercialSnapshot',document.commercial_snapshot,'notes',document.notes,
    'subtotal',document.subtotal,'discountTotal',document.discount_total,
    'taxTotal',document.tax_total,'grandTotal',document.grand_total,
    'masterVersion',document.master_version,'createdAt',document.created_at,
    'updatedAt',document.updated_at,'sentAt',document.sent_at,
    'confirmedAt',document.confirmed_at,'canceledAt',document.canceled_at,
    'cancelReason',document.cancel_reason,
    'lines',COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'id',line.id,'lineNo',line.line_no,'productId',line.product_id,
      'uomId',line.uom_id,'orderedQty',line.ordered_qty,
      'baseQtyPerUom',line.base_qty_per_uom,
      'orderedBaseQty',line.ordered_base_qty,'unitPrice',line.unit_price,
      'lineSubtotal',line.line_subtotal,'discountAmount',line.discount_amount,
      'taxAmount',line.tax_amount,'lineTotal',line.line_total,
      'productCode',line.product_code_snapshot,
      'productName',line.product_name_snapshot,'uomCode',line.uom_code_snapshot,
      'uomName',line.uom_name_snapshot,'pricingSnapshot',line.pricing_snapshot,
      'masterVersion',line.master_version
    ) ORDER BY line.line_no) FROM public.backoffice_sales_order_lines line
      WHERE line.company_id=document.company_id
        AND line.sales_order_id=document.id),'[]'::jsonb)
  )
  FROM public.backoffice_sales_orders document
  WHERE document.company_id=p_company_id AND document.id=p_order_id
$$;

CREATE FUNCTION private.backoffice_operation_retry(
  p_company_id uuid,p_operation_id uuid,p_operation_type text,p_request_hash text
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_operation public.backoffice_sales_order_operations%rowtype;
BEGIN
  SELECT * INTO v_operation FROM public.backoffice_sales_order_operations
  WHERE company_id=p_company_id AND operation_id=p_operation_id;
  IF NOT FOUND THEN RETURN NULL; END IF;
  IF v_operation.operation_type<>p_operation_type
    OR v_operation.request_hash<>p_request_hash THEN
    RAISE EXCEPTION 'IDEMPOTENCY_PAYLOAD_CONFLICT';
  END IF;
  RETURN v_operation.response_snapshot||jsonb_build_object('exactRetry',true);
END
$$;

CREATE FUNCTION public.get_backoffice_sales_order_workspace()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'sales.backoffice_orders','VIEW');
  RETURN jsonb_build_object(
    'companyId',v_company,
    'stores',COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'id',store.id,'code',store.store_code,'name',store.store_name)
      ORDER BY store.store_name) FROM public.stores store
      WHERE store.company_id=v_company AND store.status='ACTIVE'),'[]'::jsonb),
    'warehouses',COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'id',warehouse.id,'code',warehouse.code,'name',warehouse.name,
      'storeId',warehouse.store_id) ORDER BY warehouse.name)
      FROM public.warehouses warehouse WHERE warehouse.company_id=v_company
        AND warehouse.is_active),'[]'::jsonb),
    'customers',COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'id',customer.id,'code',customer.code,'name',customer.name,
      'creditTermDays',customer.credit_term_days)
      ORDER BY customer.name) FROM public.customers customer
      WHERE customer.company_id=v_company AND customer.is_active),'[]'::jsonb),
    'products',COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'productUomId',product_uom.id,'productId',product.id,
      'sku',product.sku,'productName',product.name,'uomId',uom.id,
      'uomCode',uom.code,'uomName',uom.name,
      'factorToBase',product_uom.factor_to_base,'salePrice',product_uom.sale_price)
      ORDER BY product.name,uom.name) FROM public.product_uoms product_uom
      JOIN public.products product ON product.company_id=product_uom.company_id
        AND product.id=product_uom.product_id AND product.is_active
      JOIN public.uoms uom ON uom.company_id=product_uom.company_id
        AND uom.id=product_uom.uom_id AND uom.is_active
      WHERE product_uom.company_id=v_company AND product_uom.is_active
        AND product_uom.sales_allowed),'[]'::jsonb)
  );
END
$$;

CREATE FUNCTION public.get_backoffice_sales_orders(
  p_status text DEFAULT NULL,p_search text DEFAULT NULL,p_limit integer DEFAULT 100
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_status text;
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'sales.backoffice_orders','VIEW');
  v_status:=nullif(upper(btrim(COALESCE(p_status,''))), '');
  IF v_status IS NOT NULL AND v_status NOT IN('DRAFT','SENT','CONFIRMED','CANCELED') THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_ORDER_STATUS_INVALID';
  END IF;
  IF p_limit IS NULL OR p_limit<1 OR p_limit>500 THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_ORDER_LIMIT_INVALID';
  END IF;
  RETURN jsonb_build_object('companyId',v_company,'data',COALESCE((
    SELECT jsonb_agg(private.backoffice_sales_order_snapshot(v_company,row_data.id)
      ORDER BY row_data.updated_at DESC,row_data.id)
    FROM (SELECT document.id,document.updated_at
      FROM public.backoffice_sales_orders document
      WHERE document.company_id=v_company
        AND (v_status IS NULL OR document.status=v_status)
        AND (nullif(btrim(COALESCE(p_search,'')),'') IS NULL
          OR document.quotation_no ILIKE '%'||btrim(p_search)||'%'
          OR COALESCE(document.order_no,'') ILIKE '%'||btrim(p_search)||'%'
          OR document.customer_snapshot->>'name' ILIKE '%'||btrim(p_search)||'%'
          OR document.customer_snapshot->>'code' ILIKE '%'||btrim(p_search)||'%')
      ORDER BY document.updated_at DESC,document.id LIMIT p_limit) row_data
  ),'[]'::jsonb));
END
$$;

CREATE FUNCTION public.get_backoffice_sales_order(p_order_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_result jsonb;
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'sales.backoffice_orders','VIEW');
  v_result:=private.backoffice_sales_order_snapshot(v_company,p_order_id);
  IF v_result IS NULL THEN RAISE EXCEPTION 'BACKOFFICE_SALES_ORDER_NOT_FOUND'; END IF;
  RETURN jsonb_build_object('companyId',v_company,'data',v_result);
END
$$;

CREATE FUNCTION public.save_backoffice_sales_order_draft(
  p_order_id uuid,p_expected_version bigint,p_operation_id uuid,p_payload jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
  v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
  v_document public.backoffice_sales_orders%rowtype;v_before jsonb;v_after jsonb;
  v_hash text;v_retry jsonb;v_line jsonb;v_price jsonb;v_customer jsonb;
  v_store uuid;v_warehouse uuid;v_customer_id uuid;v_order_date date;
  v_delivery_date date;v_due_date date;v_is_tempo boolean;v_currency text;
  v_timezone text;v_resolved_at timestamptz;v_product_uom uuid;v_qty numeric;
  v_uom_id uuid;v_product_id uuid;v_sku text;v_product_name text;
  v_uom_code text;v_uom_name text;v_factor numeric;v_unit_price numeric;
  v_pricelist uuid;v_header_pricelist uuid;v_line_no integer:=0;
  v_subtotal numeric:=0;v_ids uuid[]:='{}';v_response jsonb;
BEGIN
  PERFORM private.acp_require_permission_capability(v_company,
    'sales.backoffice_orders',CASE WHEN p_order_id IS NULL THEN 'CREATE_DRAFT' ELSE 'EDIT_DRAFT' END);
  IF p_operation_id IS NULL OR p_payload IS NULL OR jsonb_typeof(p_payload)<>'object' THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_ORDER_PAYLOAD_INVALID';
  END IF;
  v_hash:=encode(digest(convert_to(jsonb_build_object(
    'orderId',p_order_id,'expectedVersion',p_expected_version,'payload',p_payload
  )::text,'UTF8'),'sha256'),'hex');
  PERFORM pg_advisory_xact_lock(hashtextextended(
    v_company::text||':'||p_operation_id::text,0));
  v_retry:=private.backoffice_operation_retry(v_company,p_operation_id,'SAVE_DRAFT',v_hash);
  IF v_retry IS NOT NULL THEN RETURN v_retry; END IF;

  BEGIN
    v_store:=(p_payload->>'storeId')::uuid;
    v_warehouse:=(p_payload->>'warehouseId')::uuid;
    v_customer_id:=(p_payload->>'customerId')::uuid;
    v_order_date:=(p_payload->>'orderDate')::date;
    v_delivery_date:=(p_payload->>'plannedDeliveryDate')::date;
    v_is_tempo:=COALESCE((p_payload->>'isTempo')::boolean,false);
    v_due_date:=NULLIF(p_payload->>'dueDate','')::date;
  EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'BACKOFFICE_SALES_ORDER_PAYLOAD_INVALID';
  END;
  v_currency:=upper(btrim(COALESCE(p_payload->>'currencyCode','IDR')));
  IF v_order_date IS NULL OR v_delivery_date IS NULL
    OR v_delivery_date<v_order_date OR (v_is_tempo AND v_due_date IS NULL)
    OR (v_due_date IS NOT NULL AND v_due_date<v_order_date)
    OR jsonb_typeof(p_payload->'lines')<>'array'
    OR jsonb_array_length(p_payload->'lines')=0 THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_ORDER_BUSINESS_DATE_OR_LINE_INVALID';
  END IF;
  SELECT company.timezone INTO v_timezone FROM public.companies company
  WHERE company.id=v_company AND company.status='ACTIVE';
  IF v_timezone IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_NOT_FOUND'; END IF;
  v_resolved_at:=(v_order_date::text||' 12:00:00')::timestamp AT TIME ZONE v_timezone;
  IF NOT EXISTS(SELECT 1 FROM public.stores store WHERE store.company_id=v_company
    AND store.id=v_store AND store.status='ACTIVE') THEN RAISE EXCEPTION 'ACTIVE_STORE_NOT_FOUND'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.warehouses warehouse WHERE warehouse.company_id=v_company
    AND warehouse.id=v_warehouse AND warehouse.is_active) THEN RAISE EXCEPTION 'ACTIVE_WAREHOUSE_NOT_FOUND'; END IF;
  SELECT jsonb_build_object('id',customer.id,'code',customer.code,
    'name',customer.name,'phone',customer.phone,'email',customer.email,
    'address',customer.address,'creditTermDays',customer.credit_term_days)
  INTO v_customer FROM public.customers customer WHERE customer.company_id=v_company
    AND customer.id=v_customer_id AND customer.is_active;
  IF v_customer IS NULL THEN RAISE EXCEPTION 'ACTIVE_CUSTOMER_NOT_FOUND'; END IF;

  IF p_order_id IS NULL THEN
    IF p_expected_version IS NOT NULL THEN RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
    INSERT INTO public.backoffice_sales_orders(company_id,store_id,warehouse_id,
      customer_id,quotation_no,order_date,planned_delivery_date,is_tempo,due_date,
      currency_code,customer_snapshot,notes,created_by,updated_by)
    VALUES(v_company,v_store,v_warehouse,v_customer_id,
      'QTN-'||to_char(v_order_date,'YYYYMMDD')||'-'||lpad(nextval(
        'private.backoffice_quotation_no_seq')::text,10,'0'),
      v_order_date,v_delivery_date,v_is_tempo,v_due_date,v_currency,v_customer,
      nullif(btrim(p_payload->>'notes'),''),v_actor,v_actor) RETURNING * INTO v_document;
  ELSE
    SELECT * INTO v_document FROM public.backoffice_sales_orders
    WHERE company_id=v_company AND id=p_order_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'BACKOFFICE_SALES_ORDER_NOT_FOUND'; END IF;
    IF v_document.status<>'DRAFT' THEN RAISE EXCEPTION 'BACKOFFICE_SALES_ORDER_NOT_DRAFT'; END IF;
    IF p_expected_version IS DISTINCT FROM v_document.master_version THEN
      RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
    END IF;
    v_before:=private.backoffice_sales_order_snapshot(v_company,v_document.id);
    DELETE FROM public.backoffice_sales_order_lines
    WHERE company_id=v_company AND sales_order_id=v_document.id;
    UPDATE public.backoffice_sales_orders SET store_id=v_store,warehouse_id=v_warehouse,
      customer_id=v_customer_id,pricelist_id=NULL,order_date=v_order_date,
      planned_delivery_date=v_delivery_date,is_tempo=v_is_tempo,due_date=v_due_date,
      currency_code=v_currency,customer_snapshot=v_customer,
      commercial_snapshot='{}',notes=nullif(btrim(p_payload->>'notes'),''),
      subtotal=0,discount_total=0,tax_total=0,grand_total=0,
      master_version=master_version+1,updated_by=v_actor,updated_at=clock_timestamp()
    WHERE company_id=v_company AND id=v_document.id RETURNING * INTO v_document;
  END IF;

  FOR v_line IN SELECT value FROM jsonb_array_elements(p_payload->'lines') LOOP
    v_line_no:=v_line_no+1;
    BEGIN v_product_uom:=(v_line->>'productUomId')::uuid;
      v_qty:=(v_line->>'quantity')::numeric;
    EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'BACKOFFICE_SALES_ORDER_LINE_INVALID'; END;
    IF v_product_uom IS NULL OR v_qty IS NULL OR v_qty<=0
      OR v_product_uom=ANY(v_ids) THEN RAISE EXCEPTION 'BACKOFFICE_SALES_ORDER_LINE_INVALID'; END IF;
    v_ids:=array_append(v_ids,v_product_uom);
    v_price:=private.resolve_pos_sale_price(v_company,v_store,v_customer_id,
      v_product_uom,v_qty,v_resolved_at);
    SELECT product_uom.product_id,product_uom.uom_id,product_uom.factor_to_base,
      product.sku,product.name,uom.code,uom.name
    INTO v_product_id,v_uom_id,v_factor,v_sku,v_product_name,v_uom_code,v_uom_name
    FROM public.product_uoms product_uom
    JOIN public.products product ON product.company_id=product_uom.company_id
      AND product.id=product_uom.product_id
    JOIN public.uoms uom ON uom.company_id=product_uom.company_id
      AND uom.id=product_uom.uom_id
    WHERE product_uom.company_id=v_company AND product_uom.id=v_product_uom;
    v_unit_price:=(v_price->>'resolvedUnitPrice')::numeric;
    v_pricelist:=NULLIF(v_price->>'pricelistId','')::uuid;
    IF v_line_no=1 THEN v_header_pricelist:=v_pricelist;
    ELSIF v_pricelist IS DISTINCT FROM v_header_pricelist THEN
      RAISE EXCEPTION 'BACKOFFICE_SALES_PRICELIST_MIXED';
    END IF;
    INSERT INTO public.backoffice_sales_order_lines(company_id,sales_order_id,line_no,
      product_id,uom_id,ordered_qty,base_qty_per_uom,unit_price,
      product_code_snapshot,product_name_snapshot,uom_code_snapshot,uom_name_snapshot,
      pricing_snapshot,created_by,updated_by)
    VALUES(v_company,v_document.id,v_line_no,v_product_id,v_uom_id,v_qty,v_factor,
      v_unit_price,v_sku,v_product_name,v_uom_code,v_uom_name,v_price,v_actor,v_actor);
    v_subtotal:=v_subtotal+round(v_qty*v_unit_price,4);
  END LOOP;
  UPDATE public.backoffice_sales_orders SET pricelist_id=v_header_pricelist,
    commercial_snapshot=jsonb_build_object('pricedAt',v_resolved_at,
      'pricingAuthority','CANONICAL_SERVER_PRICE','taxScope','DEFERRED_ZERO'),
    subtotal=v_subtotal,discount_total=0,tax_total=0,grand_total=v_subtotal,
    updated_by=v_actor,updated_at=clock_timestamp()
  WHERE company_id=v_company AND id=v_document.id RETURNING * INTO v_document;
  v_after:=private.backoffice_sales_order_snapshot(v_company,v_document.id);
  v_response:=jsonb_build_object('companyId',v_company,'data',v_after,'exactRetry',false);
  INSERT INTO public.backoffice_sales_order_operations(company_id,operation_id,
    operation_type,sales_order_id,expected_version,request_hash,response_snapshot,actor_id)
  VALUES(v_company,p_operation_id,'SAVE_DRAFT',v_document.id,p_expected_version,
    v_hash,v_response,v_actor);
  INSERT INTO public.backoffice_sales_order_audit(company_id,sales_order_id,
    operation_id,action,actor_id,before_state,after_state)
  VALUES(v_company,v_document.id,p_operation_id,
    CASE WHEN v_before IS NULL THEN 'CREATE' ELSE 'UPDATE' END,
    v_actor,v_before,v_after);
  RETURN v_response;
END
$$;

CREATE FUNCTION private.transition_backoffice_sales_order(
  p_order_id uuid,p_expected_version bigint,p_operation_id uuid,
  p_operation_type text,p_reason text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
  v_document public.backoffice_sales_orders%rowtype;v_hash text;v_retry jsonb;
  v_before jsonb;v_after jsonb;v_response jsonb;
BEGIN
  PERFORM private.acp_require_permission_capability(v_company,'sales.backoffice_orders','MANAGE');
  IF p_order_id IS NULL OR p_expected_version IS NULL OR p_operation_id IS NULL THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_ORDER_TRANSITION_INPUT_REQUIRED';
  END IF;
  v_hash:=encode(digest(convert_to(jsonb_build_object('orderId',p_order_id,
    'expectedVersion',p_expected_version,'operationType',p_operation_type,
    'reason',nullif(btrim(COALESCE(p_reason,'')),''))::text,'UTF8'),'sha256'),'hex');
  PERFORM pg_advisory_xact_lock(hashtextextended(
    v_company::text||':'||p_operation_id::text,0));
  v_retry:=private.backoffice_operation_retry(v_company,p_operation_id,p_operation_type,v_hash);
  IF v_retry IS NOT NULL THEN RETURN v_retry; END IF;
  SELECT * INTO v_document FROM public.backoffice_sales_orders
  WHERE company_id=v_company AND id=p_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'BACKOFFICE_SALES_ORDER_NOT_FOUND'; END IF;
  IF p_expected_version IS DISTINCT FROM v_document.master_version THEN
    RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
  END IF;
  v_before:=private.backoffice_sales_order_snapshot(v_company,p_order_id);
  IF p_operation_type='SEND' THEN
    IF v_document.status<>'DRAFT' THEN RAISE EXCEPTION 'BACKOFFICE_QUOTATION_SEND_STATE_INVALID'; END IF;
    UPDATE public.backoffice_sales_orders SET status='SENT',sent_by=v_actor,
      sent_at=clock_timestamp(),master_version=master_version+1,
      updated_by=v_actor,updated_at=clock_timestamp()
    WHERE company_id=v_company AND id=p_order_id;
  ELSIF p_operation_type='CONFIRM' THEN
    IF v_document.status NOT IN('DRAFT','SENT') THEN RAISE EXCEPTION 'BACKOFFICE_SALES_CONFIRM_STATE_INVALID'; END IF;
    UPDATE public.backoffice_sales_orders SET status='CONFIRMED',
      order_no='SO-'||to_char(order_date,'YYYYMMDD')||'-'||lpad(nextval(
        'private.backoffice_sales_order_no_seq')::text,10,'0'),
      confirmed_by=v_actor,confirmed_at=clock_timestamp(),
      master_version=master_version+1,updated_by=v_actor,updated_at=clock_timestamp()
    WHERE company_id=v_company AND id=p_order_id;
  ELSIF p_operation_type='CANCEL' THEN
    IF v_document.status NOT IN('DRAFT','SENT') THEN RAISE EXCEPTION 'BACKOFFICE_SALES_CANCEL_STATE_INVALID'; END IF;
    IF nullif(btrim(COALESCE(p_reason,'')),'') IS NULL THEN RAISE EXCEPTION 'CANCEL_REASON_REQUIRED'; END IF;
    UPDATE public.backoffice_sales_orders SET status='CANCELED',
      canceled_by=v_actor,canceled_at=clock_timestamp(),cancel_reason=btrim(p_reason),
      master_version=master_version+1,updated_by=v_actor,updated_at=clock_timestamp()
    WHERE company_id=v_company AND id=p_order_id;
  ELSE RAISE EXCEPTION 'BACKOFFICE_SALES_OPERATION_INVALID'; END IF;
  v_after:=private.backoffice_sales_order_snapshot(v_company,p_order_id);
  v_response:=jsonb_build_object('companyId',v_company,'data',v_after,'exactRetry',false);
  INSERT INTO public.backoffice_sales_order_operations(company_id,operation_id,
    operation_type,sales_order_id,expected_version,request_hash,response_snapshot,actor_id)
  VALUES(v_company,p_operation_id,p_operation_type,p_order_id,p_expected_version,
    v_hash,v_response,v_actor);
  INSERT INTO public.backoffice_sales_order_audit(company_id,sales_order_id,
    operation_id,action,actor_id,reason,before_state,after_state)
  VALUES(v_company,p_order_id,p_operation_id,p_operation_type,v_actor,
    nullif(btrim(COALESCE(p_reason,'')),''),v_before,v_after);
  RETURN v_response;
END
$$;

CREATE FUNCTION public.send_backoffice_sales_quotation(
  p_order_id uuid,p_expected_version bigint,p_operation_id uuid
) RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path=public,pg_temp AS $$
  SELECT private.transition_backoffice_sales_order(
    p_order_id,p_expected_version,p_operation_id,'SEND',NULL)
$$;
CREATE FUNCTION public.confirm_backoffice_sales_order(
  p_order_id uuid,p_expected_version bigint,p_operation_id uuid
) RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path=public,pg_temp AS $$
  SELECT private.transition_backoffice_sales_order(
    p_order_id,p_expected_version,p_operation_id,'CONFIRM',NULL)
$$;
CREATE FUNCTION public.cancel_backoffice_sales_order(
  p_order_id uuid,p_expected_version bigint,p_operation_id uuid,p_reason text
) RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path=public,pg_temp AS $$
  SELECT private.transition_backoffice_sales_order(
    p_order_id,p_expected_version,p_operation_id,'CANCEL',p_reason)
$$;

REVOKE ALL ON FUNCTION private.backoffice_sales_order_snapshot(uuid,uuid),
  private.backoffice_operation_retry(uuid,uuid,text,text),
  private.transition_backoffice_sales_order(uuid,bigint,uuid,text,text)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.backoffice_sales_order_snapshot(uuid,uuid),
  private.backoffice_operation_retry(uuid,uuid,text,text),
  private.transition_backoffice_sales_order(uuid,bigint,uuid,text,text)
TO service_role;

REVOKE ALL ON FUNCTION public.get_backoffice_sales_order_workspace(),
  public.get_backoffice_sales_orders(text,text,integer),
  public.get_backoffice_sales_order(uuid),
  public.save_backoffice_sales_order_draft(uuid,bigint,uuid,jsonb),
  public.send_backoffice_sales_quotation(uuid,bigint,uuid),
  public.confirm_backoffice_sales_order(uuid,bigint,uuid),
  public.cancel_backoffice_sales_order(uuid,bigint,uuid,text)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_backoffice_sales_order_workspace(),
  public.get_backoffice_sales_orders(text,text,integer),
  public.get_backoffice_sales_order(uuid),
  public.save_backoffice_sales_order_draft(uuid,bigint,uuid,jsonb),
  public.send_backoffice_sales_quotation(uuid,bigint,uuid),
  public.confirm_backoffice_sales_order(uuid,bigint,uuid),
  public.cancel_backoffice_sales_order(uuid,bigint,uuid,text)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260908120000','backoffice_sales_order_runtime',
  'Guarded exact-retry Quotation/SO runtime and enforced feature-scoped permission; zero Reservation, Stock, Delivery, Invoice, Payment and Finance effect');

COMMIT;
