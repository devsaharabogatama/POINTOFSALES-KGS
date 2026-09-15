-- Cutover Step 4C/6: trusted Backoffice -> Retail Draft converter.
-- No public Apply and no Company mode switch are introduced here.
BEGIN;

DO $guard$
BEGIN
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260911110000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260911110000';
  END IF;
  IF (SELECT count(*) FROM private.kgs_schema_migrations WHERE version IN(
      '20260909162000','20260909163000','20260910110000','20260910120000',
      '20260910130000','20260910140000','20260910150000','20260910151000',
      '20260910152000','20260910153000','20260911100000'))<>11 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Step 4C dependency chain incomplete';
  END IF;
  IF to_regprocedure('private.convert_backoffice_order_to_retail_sale(uuid,uuid,uuid,uuid)')
      IS NOT NULL
    OR to_regprocedure('private.get_sales_process_cutover_preview_before_step_4c(uuid,text)')
      IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Step 4C routine collision';
  END IF;
  IF to_regprocedure('private.get_sales_process_cutover_preview_core(uuid,text)') IS NULL
    OR to_regprocedure('private.backoffice_sales_stock_requirements(uuid,uuid)') IS NULL
    OR to_regprocedure('private.backoffice_sales_order_snapshot(uuid,uuid)') IS NULL
    OR to_regprocedure('public.cancel_backoffice_sales_order(uuid,bigint,uuid,text)') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Step 4C runtime dependency missing';
  END IF;
  IF EXISTS(SELECT 1 FROM public.sales_process_cutover_plans
    WHERE status IN('DRAFT','PREVIEWED','APPLYING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: open cutover plan';
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

ALTER FUNCTION private.get_sales_process_cutover_preview_core(uuid,text)
  RENAME TO get_sales_process_cutover_preview_before_step_4c;

CREATE FUNCTION private.get_sales_process_cutover_preview_core(
  p_company_id uuid,p_target_mode text
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='8s' AS $$
DECLARE v_result jsonb;v_candidate jsonb;v_candidates jsonb:='[]'::jsonb;
  v_document public.backoffice_sales_orders%rowtype;v_today date;
  v_blockers jsonb;v_convert bigint:=0;v_blocked bigint:=0;v_keep bigint:=0;
  v_shape_valid boolean;
BEGIN
  v_result:=private.get_sales_process_cutover_preview_before_step_4c(
    p_company_id,p_target_mode);
  IF p_target_mode<>'RETAIL_CONFIRM_INVOICE' THEN RETURN v_result; END IF;
  SELECT (clock_timestamp() AT TIME ZONE company.timezone)::date INTO STRICT v_today
  FROM public.companies company WHERE company.id=p_company_id;
  FOR v_candidate IN SELECT value FROM jsonb_array_elements(v_result->'candidates')
  LOOP
    IF v_candidate->>'sourceDocumentType'='BACKOFFICE_SALES_ORDER' THEN
      SELECT document.* INTO STRICT v_document
      FROM public.backoffice_sales_orders document
      WHERE document.company_id=p_company_id
        AND document.id=(v_candidate->>'sourceDocumentId')::uuid;
      v_blockers:=COALESCE(v_candidate->'blockerCodes','[]'::jsonb);
      IF NOT v_document.is_tempo AND v_document.order_date>v_today THEN
        IF NOT (v_blockers ? 'FUTURE_NON_TEMPO_MUST_FINISH_IN_BACKOFFICE') THEN
          v_blockers:=v_blockers||jsonb_build_array(
            'FUTURE_NON_TEMPO_MUST_FINISH_IN_BACKOFFICE');
        END IF;
      END IF;
      IF EXISTS(SELECT 1 FROM public.backoffice_sales_invoices invoice
        WHERE invoice.company_id=p_company_id
          AND invoice.sales_order_id=v_document.id
          AND invoice.status IN('DRAFT','POSTED','REVERSED')) THEN
        IF NOT (v_blockers ? 'INVOICE_MUST_FINISH_IN_BACKOFFICE') THEN
          v_blockers:=v_blockers||jsonb_build_array('INVOICE_MUST_FINISH_IN_BACKOFFICE');
        END IF;
      END IF;
      IF v_document.status='CONFIRMED' THEN
        SELECT (SELECT count(*) FROM public.backoffice_sales_reservations reservation
          WHERE reservation.company_id=p_company_id
            AND reservation.sales_order_id=v_document.id
            AND reservation.status IN('OPEN','PARTIALLY_ALLOCATED','ALLOCATED')
            AND reservation.total_released_base_qty=0
            AND reservation.total_in_transit_base_qty=0
            AND reservation.total_completed_base_qty=0)=1
          AND (SELECT count(*) FROM public.backoffice_sales_reservations reservation
            WHERE reservation.company_id=p_company_id
              AND reservation.sales_order_id=v_document.id)=1
          AND (SELECT count(*) FROM public.backoffice_sales_delivery_orders delivery
          WHERE delivery.company_id=p_company_id
            AND delivery.sales_order_id=v_document.id
            AND delivery.delivery_kind='INITIAL'
            AND delivery.status IN('PREPARING','READY')
            AND delivery.total_shipped_base_qty=0
            AND delivery.total_received_base_qty=0)=1
          AND (SELECT count(*) FROM public.backoffice_sales_delivery_orders delivery
            WHERE delivery.company_id=p_company_id
              AND delivery.sales_order_id=v_document.id)=1 INTO v_shape_valid;
        IF NOT v_shape_valid AND NOT (v_blockers ? 'FULFILLMENT_SHAPE_MUST_REPAIR') THEN
          v_blockers:=v_blockers||jsonb_build_array('FULFILLMENT_SHAPE_MUST_REPAIR');
        END IF;
      END IF;
      IF jsonb_array_length(v_blockers)>0 THEN
        v_candidate:=jsonb_set(jsonb_set(v_candidate,'{decision}','"BLOCKED"'::jsonb),
          '{blockerCodes}',v_blockers);
      END IF;
    END IF;
    v_candidates:=v_candidates||jsonb_build_array(v_candidate);
    IF v_candidate->>'decision'='CONVERT' THEN v_convert:=v_convert+1;
    ELSIF v_candidate->>'decision'='BLOCKED' THEN v_blocked:=v_blocked+1;
    ELSE v_keep:=v_keep+1; END IF;
  END LOOP;
  RETURN jsonb_set(jsonb_set(v_result,'{candidates}',v_candidates),'{summary}',
    (v_result->'summary')||jsonb_build_object('convertible',v_convert,
      'blocked',v_blocked,'keepSource',v_keep))
    ||jsonb_build_object('previewVersion',3);
END
$$;

CREATE FUNCTION private.convert_backoffice_order_to_retail_sale(
  p_company_id uuid,p_source_order_id uuid,p_actor_id uuid,p_operation_id uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='15s' AS $$
DECLARE v_source public.backoffice_sales_orders%rowtype;v_target_id uuid;
  v_target public.sales_headers%rowtype;v_timezone text;v_today date;
  v_now timestamptz:=clock_timestamp();v_transaction_at timestamptz;
  v_delivery_at timestamptz;v_due_at timestamptz;v_timing text:='IMMEDIATE';
  v_product_uom_id uuid;v_detail_id uuid;v_line record;v_requirement record;
  v_line_count bigint:=0;v_requirement_count bigint:=0;v_reason text;
  v_cancel jsonb;v_reservation public.backoffice_sales_reservations%rowtype;
  v_delivery public.backoffice_sales_delivery_orders%rowtype;v_before jsonb;
  v_source_no text;v_item_discount numeric;v_payload jsonb;
BEGIN
  IF COALESCE(current_setting('kgs.sales_process_cutover_mutation',true),'')<>'1' THEN
    RAISE EXCEPTION 'SALES_PROCESS_CUTOVER_RUNTIME_REQUIRED';
  END IF;
  IF p_company_id IS NULL OR p_source_order_id IS NULL OR p_actor_id IS NULL
    OR p_operation_id IS NULL OR auth.uid() IS DISTINCT FROM p_actor_id
    OR public.private_active_company_id() IS DISTINCT FROM p_company_id THEN
    RAISE EXCEPTION 'SALES_PROCESS_CUTOVER_CONTEXT_INVALID';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.profiles profile
    WHERE profile.id=p_actor_id AND profile.role::text='super_admin') THEN
    RAISE EXCEPTION 'SALES_PROCESS_CUTOVER_SUPER_ADMIN_REQUIRED';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(
    p_company_id::text||':sales-process-cutover',0));

  SELECT sale.* INTO v_target FROM public.sales_headers sale
  WHERE sale.company_id=p_company_id AND sale.client_transaction_id=p_operation_id
    AND sale.sales_origin='BACKOFFICE_CUTOVER';
  IF FOUND THEN
    IF v_target.payload_snapshot#>>'{cutoverSourceDocumentId}' IS DISTINCT FROM
        p_source_order_id::text THEN
      RAISE EXCEPTION 'IDEMPOTENCY_PAYLOAD_CONFLICT';
    END IF;
    RETURN jsonb_build_object('sourceDocumentType','BACKOFFICE_SALES_ORDER',
      'sourceDocumentId',p_source_order_id,'sourceClosed',true,
      'targetDocumentType','RETAIL_SALE','targetDocumentId',v_target.id,
      'targetDocumentNo',v_target.draft_no,'targetStatus',v_target.order_runtime_status,
      'requiresRetailConfirmation',true,'exactRetry',true);
  END IF;

  SELECT document.* INTO v_source FROM public.backoffice_sales_orders document
  WHERE document.company_id=p_company_id AND document.id=p_source_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'CUTOVER_SOURCE_BACKOFFICE_NOT_FOUND'; END IF;
  IF v_source.sales_origin<>'BACKOFFICE_SALES'
    OR v_source.sales_process_mode<>'BACKOFFICE_DELIVERED_QTY_INVOICE'
    OR v_source.status NOT IN('DRAFT','SENT','CONFIRMED')
    OR v_source.fulfillment_status IN('COMPLETED','CANCELED') THEN
    RAISE EXCEPTION 'CUTOVER_SOURCE_BACKOFFICE_STATE_INVALID';
  END IF;
  SELECT company.timezone,(v_now AT TIME ZONE company.timezone)::date
    INTO STRICT v_timezone,v_today FROM public.companies company
  WHERE company.id=p_company_id AND company.status='ACTIVE';
  IF NOT v_source.is_tempo AND v_source.order_date>v_today THEN
    RAISE EXCEPTION 'CUTOVER_SOURCE_FUTURE_NON_TEMPO_BLOCKED';
  END IF;
  IF EXISTS(SELECT 1 FROM public.backoffice_sales_invoices invoice
      WHERE invoice.company_id=p_company_id AND invoice.sales_order_id=v_source.id
        AND invoice.status IN('DRAFT','POSTED','REVERSED'))
    OR EXISTS(SELECT 1 FROM public.backoffice_sales_delivery_receipts receipt
      WHERE receipt.company_id=p_company_id AND receipt.sales_order_id=v_source.id) THEN
    RAISE EXCEPTION 'CUTOVER_SOURCE_BACKOFFICE_FINAL_EFFECT_BLOCKED';
  END IF;
  IF v_source.payment_term_id IS NOT NULL AND (SELECT count(*)
      FROM public.backoffice_sales_payment_term_lines term_line
      WHERE term_line.company_id=p_company_id
        AND term_line.payment_term_id=v_source.payment_term_id)>1 THEN
    RAISE EXCEPTION 'MULTI_INSTALLMENT_MUST_FINISH_IN_BACKOFFICE';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.stores store WHERE store.company_id=p_company_id
      AND store.id=v_source.store_id AND store.status='ACTIVE')
    OR NOT EXISTS(SELECT 1 FROM public.customers customer WHERE customer.company_id=p_company_id
      AND customer.id=v_source.customer_id AND customer.is_active)
    OR NOT EXISTS(SELECT 1 FROM public.warehouses warehouse WHERE warehouse.company_id=p_company_id
      AND warehouse.id=v_source.warehouse_id AND warehouse.is_active
      AND warehouse.is_sale_source) THEN
    RAISE EXCEPTION 'CUTOVER_SOURCE_BACKOFFICE_MASTER_DATA_INACTIVE';
  END IF;
  SELECT count(*) INTO v_line_count FROM public.backoffice_sales_order_lines line
  WHERE line.company_id=p_company_id AND line.sales_order_id=v_source.id;
  IF v_line_count=0 OR EXISTS(SELECT 1 FROM public.backoffice_sales_order_lines line
    WHERE line.company_id=p_company_id AND line.sales_order_id=v_source.id
      AND (SELECT count(*) FROM public.product_uoms product_uom
        JOIN public.products product ON product.company_id=product_uom.company_id
          AND product.id=product_uom.product_id AND product.is_active
        JOIN public.uoms uom ON uom.company_id=product_uom.company_id
          AND uom.id=product_uom.uom_id AND uom.is_active
        WHERE product_uom.company_id=line.company_id
          AND product_uom.product_id=line.product_id AND product_uom.uom_id=line.uom_id
          AND product_uom.is_active AND product_uom.sales_allowed)<>1) THEN
    RAISE EXCEPTION 'CUTOVER_SOURCE_BACKOFFICE_LINE_MAPPING_INVALID';
  END IF;
  IF v_source.status='CONFIRMED' THEN
    SELECT reservation.* INTO v_reservation FROM public.backoffice_sales_reservations reservation
    WHERE reservation.company_id=p_company_id AND reservation.sales_order_id=v_source.id
      AND reservation.status IN('OPEN','PARTIALLY_ALLOCATED','ALLOCATED')
      AND reservation.total_released_base_qty=0
      AND reservation.total_in_transit_base_qty=0
      AND reservation.total_completed_base_qty=0;
    IF NOT FOUND OR (SELECT count(*) FROM public.backoffice_sales_reservations reservation
        WHERE reservation.company_id=p_company_id AND reservation.sales_order_id=v_source.id)<>1
      OR EXISTS(SELECT 1 FROM public.backoffice_sales_reservation_lines line
        WHERE line.company_id=p_company_id AND line.reservation_id=v_reservation.id
          AND (line.released_base_qty<>0 OR line.in_transit_base_qty<>0
            OR line.completed_base_qty<>0)) THEN
      RAISE EXCEPTION 'CUTOVER_SOURCE_BACKOFFICE_FULFILLMENT_INVALID';
    END IF;
    SELECT delivery.* INTO v_delivery FROM public.backoffice_sales_delivery_orders delivery
    WHERE delivery.company_id=p_company_id AND delivery.sales_order_id=v_source.id
      AND delivery.delivery_kind='INITIAL' AND delivery.status IN('PREPARING','READY')
      AND delivery.total_shipped_base_qty=0 AND delivery.total_received_base_qty=0;
    IF NOT FOUND OR (SELECT count(*) FROM public.backoffice_sales_delivery_orders delivery
        WHERE delivery.company_id=p_company_id
          AND delivery.sales_order_id=v_source.id)<>1 THEN
      RAISE EXCEPTION 'CUTOVER_SOURCE_BACKOFFICE_FULFILLMENT_INVALID';
    END IF;
  END IF;

  v_target_id:=gen_random_uuid();v_source_no:=COALESCE(v_source.order_no,v_source.quotation_no);
  v_transaction_at:=(v_source.order_date::text||' 12:00:00')::timestamp AT TIME ZONE v_timezone;
  v_delivery_at:=(v_source.planned_delivery_date::text||' 12:00:00')::timestamp AT TIME ZONE v_timezone;
  v_due_at:=CASE WHEN v_source.due_date IS NOT NULL THEN
    (v_source.due_date::text||' 12:00:00')::timestamp AT TIME ZONE v_timezone END;
  IF v_source.is_tempo AND v_source.order_date>v_today THEN v_timing:='SCHEDULED';
  ELSIF v_source.is_tempo AND v_source.order_date<v_today THEN v_timing:='BACKORDER'; END IF;
  v_payload:=COALESCE(v_source.commercial_snapshot,'{}'::jsonb)||jsonb_build_object(
    'cutoverSource','BACKOFFICE_SALES_ORDER','cutoverSourceDocumentId',v_source.id,
    'cutoverSourceDocumentNo',v_source_no,'snapshotPreserved',true,
    'requiresRetailConfirmation',true,'sourcePaymentTermSnapshot',v_source.payment_term_snapshot);

  INSERT INTO public.sales_headers(id,invoice_no,session_id,customer_id,transaction_date,
    is_tempo,due_date,sj_required,sj_status,so_confirm_status,invoice_status,
    subtotal,item_discount,global_discount,grand_total,paid_amount,sisa_piutang,
    payment_status,financial_status,recon_status,created_by,payload_snapshot,
    company_id,store_id,pos_id,document_status,client_transaction_id,
    sales_warehouse_id,grand_total_before_rounding,rounding_direction,
    rounding_increment,rounding_adjustment,grand_total_after_rounding,
    created_session_id,fulfillment_mode,delivery_recipient_name,
    delivery_recipient_phone,delivery_address,delivery_scheduled_at,delivery_notes,
    delivery_fee_amount,delivery_fee_invoice_display_mode,transaction_date_source,
    transaction_date_selected_by,transaction_date_selected_at,planned_order_date,
    order_timing_mode,planned_order_selected_by,planned_order_selected_at,
    order_runtime_status,reservation_version,sales_origin,sales_process_mode,
    draft_label,draft_notes)
  VALUES(v_target_id,'DRAFT-'||replace(v_target_id::text,'-',''),NULL,v_source.customer_id,
    v_transaction_at,v_source.is_tempo,v_due_at,true,'NONE','DRAFT','DRAFT',0,0,0,0,
    0,0,'DRAFT','PENDING','UNRECONCILED',p_actor_id,v_payload,p_company_id,
    v_source.store_id,NULL,'DRAFT',p_operation_id,v_source.warehouse_id,0,
    v_source.rounding_direction,v_source.rounding_increment,0,0,NULL,'DELIVERY',
    NULLIF(v_source.customer_snapshot->>'name',''),
    NULLIF(v_source.customer_snapshot->>'phone',''),
    NULLIF(v_source.customer_snapshot->>'address',''),v_delivery_at,v_source.notes,
    v_source.delivery_fee_amount,v_source.delivery_fee_invoice_display_mode,
    CASE WHEN v_source.is_tempo AND v_source.order_date<>v_today
      THEN 'CASHIER_SELECTED' ELSE 'SERVER_CREATED' END,
    CASE WHEN v_source.is_tempo AND v_source.order_date<>v_today THEN p_actor_id END,
    CASE WHEN v_source.is_tempo AND v_source.order_date<>v_today THEN v_now END,
    CASE WHEN v_timing IN('SCHEDULED','BACKORDER') THEN v_source.order_date END,
    v_timing,CASE WHEN v_timing IN('SCHEDULED','BACKORDER') THEN p_actor_id END,
    CASE WHEN v_timing IN('SCHEDULED','BACKORDER') THEN v_now END,
    'DRAFT_INPUT',0,'BACKOFFICE_CUTOVER','RETAIL_CONFIRM_INVOICE',
    'Cutover '||v_source_no,v_source.notes);

  FOR v_line IN SELECT line.* FROM public.backoffice_sales_order_lines line
    WHERE line.company_id=p_company_id AND line.sales_order_id=v_source.id
    ORDER BY line.line_no,line.id
  LOOP
    SELECT product_uom.id INTO STRICT v_product_uom_id FROM public.product_uoms product_uom
    JOIN public.products product ON product.company_id=product_uom.company_id
      AND product.id=product_uom.product_id AND product.is_active
    JOIN public.uoms uom ON uom.company_id=product_uom.company_id
      AND uom.id=product_uom.uom_id AND uom.is_active
    WHERE product_uom.company_id=p_company_id AND product_uom.product_id=v_line.product_id
      AND product_uom.uom_id=v_line.uom_id AND product_uom.is_active
      AND product_uom.sales_allowed;
    v_detail_id:=gen_random_uuid();
    INSERT INTO public.sales_details(id,sales_id,product_id,warehouse_id,qty,price,
      discount_amount,subtotal,cogs_unit,cogs_total,company_id,base_unit_price,
      pricelist_id,pricelist_rule_id,resolved_unit_price,line_discount_type,
      line_discount_input,line_discount_amount,allocated_order_discount_amount,
      unit_price_after_discount,line_total,pricing_resolved_at,tax_rule_id,
      tax_rule_version,tax_code_snapshot,tax_name_snapshot,tax_scope_snapshot,
      tax_rate_percent_snapshot,tax_price_mode_snapshot,tax_calculation_scope_snapshot,
      tax_base,tax_amount,tax_rounding,tax_account_id,tax_account_code_snapshot,
      tax_account_name_snapshot,client_line_key,product_uom_id,sale_uom_id,
      sale_uom_name_snapshot,uom_factor_to_base_snapshot,quantity_base,
      product_sku_snapshot,product_name_snapshot,allocated_document_rounding,
      fifo_cost_total,canonical_resolved_unit_price,price_override_applied)
    VALUES(v_detail_id,v_target_id,v_line.product_id,v_source.warehouse_id,
      v_line.ordered_qty,v_line.unit_price,v_line.discount_amount,v_line.line_total,0,0,
      p_company_id,v_line.canonical_unit_price,NULL,NULL,v_line.unit_price,
      v_line.line_discount_type,v_line.line_discount_input,v_line.line_discount_amount,
      v_line.allocated_order_discount_amount,
      CASE WHEN v_line.ordered_qty>0 THEN round((v_line.line_total-v_line.tax_amount)
        /v_line.ordered_qty,4) ELSE 0 END,v_line.line_total,v_now,v_line.tax_rule_id,
      v_line.tax_rule_version,v_line.tax_code_snapshot,v_line.tax_name_snapshot,
      CASE WHEN v_line.tax_rule_id IS NULL THEN NULL ELSE 'SALES' END,
      v_line.tax_rate_percent_snapshot,v_line.tax_price_mode_snapshot,
      v_line.tax_calculation_scope_snapshot,v_line.tax_base,v_line.tax_amount,
      v_line.tax_rounding,v_line.tax_account_id,v_line.tax_account_code_snapshot,
      v_line.tax_account_name_snapshot,'CUTOVER-'||v_line.line_no,v_product_uom_id,
      v_line.uom_id,v_line.uom_name_snapshot,v_line.base_qty_per_uom,
      v_line.ordered_base_qty,v_line.product_code_snapshot,v_line.product_name_snapshot,
      v_line.allocated_document_rounding,0,v_line.unit_price,false);
    FOR v_requirement IN SELECT requirement.*
      FROM private.backoffice_sales_stock_requirements(p_company_id,v_source.id) requirement
      WHERE requirement.sales_order_line_id=v_line.id
    LOOP
      INSERT INTO public.sale_stock_requirements(company_id,sales_id,sales_detail_id,
        commercial_product_id,stock_product_id,stock_uom_id,stock_uom_name_snapshot,
        quantity_uom,factor_to_base,quantity_base,bundle_component_line_no)
      VALUES(p_company_id,v_target_id,v_detail_id,v_requirement.commercial_product_id,
        v_requirement.stock_product_id,v_requirement.stock_uom_id,
        v_requirement.stock_uom_name,v_requirement.quantity_uom,
        v_requirement.factor_to_base,v_requirement.quantity_base,
        v_requirement.bundle_component_line_no);
      v_requirement_count:=v_requirement_count+1;
    END LOOP;
  END LOOP;
  IF v_requirement_count=0 THEN RAISE EXCEPTION 'CUTOVER_TARGET_RETAIL_REQUIREMENT_MISSING'; END IF;
  SELECT COALESCE(sum(line.line_discount_amount),0) INTO v_item_discount
  FROM public.backoffice_sales_order_lines line
  WHERE line.company_id=p_company_id AND line.sales_order_id=v_source.id;
  UPDATE public.sales_headers SET subtotal=v_source.subtotal,item_discount=v_item_discount,
    global_discount=v_source.global_discount,grand_total=v_source.grand_total,
    grand_total_before_rounding=v_source.grand_total_before_rounding+
      v_source.delivery_fee_amount,rounding_adjustment=v_source.rounding_adjustment,
    grand_total_after_rounding=v_source.grand_total,updated_at=v_now
  WHERE company_id=p_company_id AND id=v_target_id;
  INSERT INTO public.sale_master_audit(company_id,sales_id,action,actor_id,
    before_state,after_state) VALUES(p_company_id,v_target_id,'CREATE_DRAFT',p_actor_id,
    NULL,jsonb_build_object('salesOrigin','BACKOFFICE_CUTOVER','cutoverSourceId',v_source.id,
      'requiresRetailConfirmation',true,'lineCount',v_line_count,
      'stockRequirementCount',v_requirement_count));

  v_reason:='Dikonversi ke Draft Retail melalui cutover; target '
    ||(SELECT draft_no FROM public.sales_headers WHERE id=v_target_id);
  IF v_source.status IN('DRAFT','SENT') THEN
    v_cancel:=public.cancel_backoffice_sales_order(v_source.id,v_source.master_version,
      gen_random_uuid(),v_reason);
  ELSE
    v_before:=private.backoffice_sales_order_snapshot(p_company_id,v_source.id);
    UPDATE public.backoffice_sales_delivery_orders SET status='CANCELED',
      canceled_by=p_actor_id,canceled_at=v_now,cancel_reason=v_reason,
      master_version=master_version+1,updated_by=p_actor_id,updated_at=v_now
    WHERE company_id=p_company_id AND id=v_delivery.id;
    INSERT INTO public.backoffice_sales_fulfillment_audit(company_id,sales_order_id,
      delivery_order_id,operation_id,action,actor_id,reason,before_state,after_state)
    VALUES(p_company_id,v_source.id,v_delivery.id,gen_random_uuid(),'CANCEL',p_actor_id,
      v_reason,jsonb_build_object('status',v_delivery.status),
      jsonb_build_object('status','CANCELED','cutoverTargetId',v_target_id));
    UPDATE public.backoffice_sales_reservation_lines SET
      released_base_qty=reserved_base_qty,in_transit_base_qty=0,
      updated_at=v_now WHERE company_id=p_company_id AND reservation_id=v_reservation.id;
    UPDATE public.backoffice_sales_reservations SET status='RELEASED',
      total_released_base_qty=total_reserved_base_qty,total_in_transit_base_qty=0,
      released_by=p_actor_id,released_at=v_now,release_reason=v_reason,
      master_version=master_version+1,updated_by=p_actor_id,updated_at=v_now
    WHERE company_id=p_company_id AND id=v_reservation.id;
    INSERT INTO public.backoffice_sales_fulfillment_audit(company_id,sales_order_id,
      reservation_id,operation_id,action,actor_id,reason,before_state,after_state)
    VALUES(p_company_id,v_source.id,v_reservation.id,gen_random_uuid(),'RELEASE',p_actor_id,
      v_reason,jsonb_build_object('status',v_reservation.status),
      jsonb_build_object('status','RELEASED','cutoverTargetId',v_target_id));
    UPDATE public.backoffice_sales_orders SET status='CANCELED',canceled_by=p_actor_id,
      canceled_at=v_now,cancel_reason=v_reason,master_version=master_version+1,
      updated_by=p_actor_id,updated_at=v_now WHERE company_id=p_company_id AND id=v_source.id;
    INSERT INTO public.backoffice_sales_order_audit(company_id,sales_order_id,
      operation_id,action,actor_id,reason,before_state,after_state)
    VALUES(p_company_id,v_source.id,gen_random_uuid(),'CANCEL',p_actor_id,v_reason,v_before,
      private.backoffice_sales_order_snapshot(p_company_id,v_source.id));
  END IF;
  SELECT * INTO STRICT v_target FROM public.sales_headers sale
  WHERE sale.company_id=p_company_id AND sale.id=v_target_id;
  RETURN jsonb_build_object('sourceDocumentType','BACKOFFICE_SALES_ORDER',
    'sourceDocumentId',v_source.id,'sourceDocumentNo',v_source_no,'sourceClosed',true,
    'targetDocumentType','RETAIL_SALE','targetDocumentId',v_target.id,
    'targetDocumentNo',v_target.draft_no,'targetStatus',v_target.order_runtime_status,
    'orderTimingMode',v_target.order_timing_mode,'requiresRetailConfirmation',true,
    'commercialSnapshotPreserved',true,'reservationReleased',v_source.status='CONFIRMED',
    'exactRetry',false);
END
$$;

REVOKE ALL ON FUNCTION
  private.get_sales_process_cutover_preview_before_step_4c(uuid,text),
  private.get_sales_process_cutover_preview_core(uuid,text),
  private.convert_backoffice_order_to_retail_sale(uuid,uuid,uuid,uuid)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.get_sales_process_cutover_preview_before_step_4c(uuid,text),
  private.get_sales_process_cutover_preview_core(uuid,text),
  private.convert_backoffice_order_to_retail_sale(uuid,uuid,uuid,uuid)
TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260911110000','sales_process_cutover_backoffice_to_retail_converter',
  'Add preview blockers and trusted Backoffice-to-Retail Draft converter; release untouched Backoffice Reservation/DO atomically; no public Apply, mode switch, Stock/FIFO, Payment, Invoice posting or Finance effect');

NOTIFY pgrst,'reload schema';
COMMIT;
