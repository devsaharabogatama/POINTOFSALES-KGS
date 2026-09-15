-- Cutover Step 4B/6: trusted Retail -> Backoffice converter kernel.
-- No public Apply RPC and no Company mode switch are introduced here.
BEGIN;

DO $guard$
BEGIN
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260911100000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260911100000';
  END IF;
  IF (SELECT count(*) FROM private.kgs_schema_migrations WHERE version IN(
      '20260909162000','20260909163000','20260910110000','20260910120000',
      '20260910130000','20260910140000','20260910150000','20260910151000',
      '20260910152000','20260910153000'))<>10 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Step 4B dependency chain incomplete';
  END IF;
  IF to_regprocedure('private.convert_retail_sale_to_backoffice_order(uuid,uuid,uuid,uuid)')
      IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Retail converter collision';
  END IF;
  IF to_regprocedure('public.save_backoffice_sales_order_draft(uuid,bigint,uuid,jsonb)') IS NULL
    OR to_regprocedure('public.confirm_backoffice_sales_order(uuid,bigint,uuid)') IS NULL
    OR to_regprocedure('public.cancel_pos_sales_order(uuid,bigint,uuid,text)') IS NULL
    OR to_regprocedure('private.backoffice_sales_order_snapshot(uuid,uuid)') IS NULL
    OR to_regprocedure('private.resolve_sales_order_revision_date_identity(jsonb,text)') IS NULL
    OR to_regclass('public.backoffice_sales_order_operations') IS NULL
    OR to_regclass('public.backoffice_sales_order_audit') IS NULL
    OR to_regclass('public.sales_invoice_snapshots') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active conversion call chain missing';
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

CREATE FUNCTION private.convert_retail_sale_to_backoffice_order(
  p_company_id uuid,p_source_sales_id uuid,p_actor_id uuid,p_operation_id uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='15s' AS $$
DECLARE
  v_source public.sales_headers%rowtype;v_timezone text;v_identity jsonb;
  v_target_id uuid;v_target_version bigint;v_payload jsonb;v_lines jsonb;
  v_save jsonb;v_confirm jsonb;v_cancel jsonb;v_before jsonb;v_after jsonb;
  v_order_date date;v_delivery_date date;v_due_date date;v_is_confirmed boolean;
  v_source_line_count bigint;v_target_line_count bigint;v_source_total numeric;
  v_target_total numeric;v_reason text;
  v_pricelist uuid;v_pricelist_count bigint;
BEGIN
  IF COALESCE(current_setting('kgs.sales_process_cutover_mutation',true),'')<>'1' THEN
    RAISE EXCEPTION 'SALES_PROCESS_CUTOVER_RUNTIME_REQUIRED';
  END IF;
  IF p_company_id IS NULL OR p_source_sales_id IS NULL OR p_actor_id IS NULL
    OR p_operation_id IS NULL OR auth.uid() IS DISTINCT FROM p_actor_id
    OR public.private_active_company_id() IS DISTINCT FROM p_company_id THEN
    RAISE EXCEPTION 'SALES_PROCESS_CUTOVER_CONTEXT_INVALID';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.profiles profile
    WHERE profile.id=p_actor_id AND profile.role::text='super_admin') THEN
    RAISE EXCEPTION 'SALES_PROCESS_CUTOVER_SUPER_ADMIN_REQUIRED';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.company_features feature
    WHERE feature.company_id=p_company_id
      AND feature.feature_code='backoffice_delivered_qty_sales_enabled'
      AND feature.is_enabled) THEN
    RAISE EXCEPTION 'BACKOFFICE_ENTITLEMENT_ENABLEMENT_REQUIRED';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(
    p_company_id::text||':sales-process-cutover',0));
  SELECT operation.sales_order_id INTO v_target_id
  FROM public.backoffice_sales_order_operations operation
  WHERE operation.company_id=p_company_id
    AND operation.operation_id=p_operation_id
    AND operation.operation_type='SAVE_DRAFT'
    AND operation.actor_id=p_actor_id;
  IF v_target_id IS NOT NULL THEN
    v_after:=private.backoffice_sales_order_snapshot(p_company_id,v_target_id);
    IF v_after IS NULL
      OR v_after#>>'{commercialSnapshot,cutoverSourceDocumentId}'
        IS DISTINCT FROM p_source_sales_id::text THEN
      RAISE EXCEPTION 'IDEMPOTENCY_PAYLOAD_CONFLICT';
    END IF;
    SELECT EXISTS(SELECT 1 FROM public.backoffice_sales_reservations reservation
      WHERE reservation.company_id=p_company_id
        AND reservation.sales_order_id=v_target_id)
    INTO v_is_confirmed;
    RETURN jsonb_build_object('sourceDocumentType','RETAIL_SALE',
      'sourceDocumentId',p_source_sales_id,'sourceClosed',true,
      'targetDocumentType','BACKOFFICE_SALES_ORDER',
      'targetDocumentId',v_target_id,
      'targetDocumentNo',COALESCE(v_after->>'orderNo',v_after->>'quotationNo'),
      'targetStatus',v_after->>'status','commercialSnapshotPreserved',true,
      'reservationTransferred',v_is_confirmed,'exactRetry',true);
  END IF;
  SELECT sale.* INTO v_source FROM public.sales_headers sale
  WHERE sale.company_id=p_company_id AND sale.id=p_source_sales_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'CUTOVER_SOURCE_RETAIL_NOT_FOUND'; END IF;
  IF v_source.sales_origin<>'POS'
    OR v_source.sales_process_mode<>'RETAIL_CONFIRM_INVOICE'
    OR v_source.document_status<>'DRAFT'
    OR v_source.order_runtime_status NOT IN(
      'DRAFT_INPUT','SCHEDULED','CONFIRMED','RESERVED') THEN
    RAISE EXCEPTION 'CUTOVER_SOURCE_RETAIL_STATE_INVALID';
  END IF;
  -- The canonical Backoffice Save/Confirm chain only accepts currently active
  -- operational masters. Revalidate the same boundary here so conversion
  -- eligibility cannot depend on a later, less descriptive resolver failure.
  IF NOT EXISTS(SELECT 1 FROM public.stores store
      WHERE store.company_id=p_company_id AND store.id=v_source.store_id
        AND store.status='ACTIVE')
    OR NOT EXISTS(SELECT 1 FROM public.customers customer
      WHERE customer.company_id=p_company_id AND customer.id=v_source.customer_id
        AND customer.is_active)
    OR NOT EXISTS(SELECT 1 FROM public.warehouses warehouse
      WHERE warehouse.company_id=p_company_id
        AND warehouse.id=v_source.sales_warehouse_id
        AND warehouse.is_active AND warehouse.is_sale_source) THEN
    RAISE EXCEPTION 'CUTOVER_SOURCE_RETAIL_MASTER_DATA_INACTIVE';
  END IF;
  IF EXISTS(SELECT 1 FROM public.sales_order_revisions revision
      WHERE revision.company_id=p_company_id
        AND (revision.source_sales_id=v_source.id
          OR revision.replacement_sales_id=v_source.id)
        AND revision.status='PENDING')
    OR EXISTS(SELECT 1 FROM public.sales_order_procurement_demand_lines demand
      WHERE demand.company_id=p_company_id AND demand.sales_id=v_source.id
        AND demand.status IN('OPEN','REQUESTED','ORDERED','AMENDMENT_REQUIRED'))
    OR EXISTS(SELECT 1 FROM public.sales_stock_reservations reservation
      WHERE reservation.company_id=p_company_id AND reservation.sales_id=v_source.id
        AND reservation.total_dispatched_base_qty>0)
    OR EXISTS(SELECT 1 FROM public.sales_dispatch_financial_effects effect
      WHERE effect.company_id=p_company_id AND effect.sales_id=v_source.id)
    OR EXISTS(SELECT 1 FROM public.sales_payments payment
      WHERE payment.company_id=p_company_id AND payment.sales_id=v_source.id
        AND NOT payment.is_reversal)
    OR EXISTS(SELECT 1 FROM public.sales_payment_verification_requests request
      WHERE request.company_id=p_company_id AND request.sales_id=v_source.id
        AND request.status IN('PENDING','VERIFIED')) THEN
    RAISE EXCEPTION 'CUTOVER_SOURCE_RETAIL_REVALIDATION_BLOCKED';
  END IF;

  SELECT company.timezone INTO STRICT v_timezone FROM public.companies company
  WHERE company.id=p_company_id AND company.status='ACTIVE';
  v_identity:=private.resolve_sales_order_revision_date_identity(
    to_jsonb(v_source),v_timezone);
  v_order_date:=((v_identity->>'transactionAt')::timestamptz
    AT TIME ZONE v_timezone)::date;
  v_delivery_date:=COALESCE((v_source.delivery_scheduled_at
    AT TIME ZONE v_timezone)::date,v_source.planned_order_date,v_order_date);
  v_due_date:=CASE WHEN v_source.is_tempo THEN
    (v_source.due_date AT TIME ZONE v_timezone)::date END;
  IF v_delivery_date<v_order_date OR (v_source.is_tempo AND v_due_date IS NULL)
    OR (v_due_date IS NOT NULL AND v_due_date<v_order_date) THEN
    RAISE EXCEPTION 'CUTOVER_SOURCE_RETAIL_DATE_INVALID';
  END IF;

  SELECT count(*),jsonb_agg(jsonb_build_object(
      'productUomId',detail.product_uom_id,'quantity',detail.qty,
      'overrideUnitPrice',detail.price,
      'lineDiscountType',detail.line_discount_type,
      'lineDiscountInput',detail.line_discount_input)
      ORDER BY detail.id)
  INTO v_source_line_count,v_lines
  FROM public.sales_details detail
  WHERE detail.company_id=p_company_id AND detail.sales_id=v_source.id;
  IF v_source_line_count=0 OR EXISTS(
    SELECT 1 FROM public.sales_details detail
    WHERE detail.company_id=p_company_id AND detail.sales_id=v_source.id
    GROUP BY detail.product_uom_id HAVING count(*)<>1)
    OR EXISTS(SELECT 1 FROM public.sales_details detail
      LEFT JOIN public.product_uoms product_uom
        ON product_uom.company_id=detail.company_id
       AND product_uom.id=detail.product_uom_id
       AND product_uom.product_id=detail.product_id
      LEFT JOIN public.products product ON product.company_id=product_uom.company_id
        AND product.id=product_uom.product_id
      LEFT JOIN public.uoms uom ON uom.company_id=product_uom.company_id
        AND uom.id=product_uom.uom_id
      WHERE detail.company_id=p_company_id AND detail.sales_id=v_source.id
        AND (detail.product_uom_id IS NULL OR product_uom.id IS NULL
          OR NOT product_uom.is_active OR NOT product_uom.sales_allowed
          OR NOT product.is_active OR NOT uom.is_active
          OR detail.qty<=0 OR detail.quantity_base<=0
          OR detail.uom_factor_to_base_snapshot<=0)) THEN
    RAISE EXCEPTION 'CUTOVER_SOURCE_RETAIL_LINE_MAPPING_INVALID';
  END IF;
  SELECT count(DISTINCT detail.pricelist_id),
    (array_agg(DISTINCT detail.pricelist_id ORDER BY detail.pricelist_id))[1]
  INTO v_pricelist_count,v_pricelist FROM public.sales_details detail
  WHERE detail.company_id=p_company_id AND detail.sales_id=v_source.id
    AND detail.pricelist_id IS NOT NULL;
  IF v_pricelist_count>1 THEN
    RAISE EXCEPTION 'CUTOVER_SOURCE_RETAIL_PRICELIST_MIXED';
  END IF;

  v_payload:=jsonb_build_object(
    'storeId',v_source.store_id,'warehouseId',v_source.sales_warehouse_id,
    'customerId',v_source.customer_id,'orderDate',v_order_date,
    'plannedDeliveryDate',v_delivery_date,'isTempo',v_source.is_tempo,
    'dueDate',v_due_date,'currencyCode','IDR','selectedPricelistId',NULL,
    'lines',v_lines,'globalDiscount',v_source.global_discount,
    'roundingDirection',v_source.rounding_direction,
    'roundingIncrement',v_source.rounding_increment,
    'deliveryFeeAmount',v_source.delivery_fee_amount,
    'deliveryFeeInvoiceDisplayMode',v_source.delivery_fee_invoice_display_mode,
    'notes',COALESCE(v_source.draft_notes,v_source.draft_label));
  v_save:=public.save_backoffice_sales_order_draft(
    NULL,NULL,p_operation_id,v_payload);
  v_target_id:=(v_save->'data'->>'id')::uuid;
  IF v_target_id IS NULL THEN RAISE EXCEPTION 'CUTOVER_TARGET_BACKOFFICE_CREATE_FAILED'; END IF;
  v_before:=private.backoffice_sales_order_snapshot(p_company_id,v_target_id);

  UPDATE public.backoffice_sales_order_lines target SET
    canonical_unit_price=COALESCE(source.canonical_resolved_unit_price,
      source.resolved_unit_price,source.price),
    unit_price=source.price,
    price_override_applied=source.price_override_applied,
    price_override_unit_price=CASE WHEN source.price_override_applied
      THEN source.price END,
    line_discount_type=source.line_discount_type,
    line_discount_input=source.line_discount_input,
    line_discount_amount=source.line_discount_amount,
    allocated_order_discount_amount=source.allocated_order_discount_amount,
    discount_amount=source.line_discount_amount+source.allocated_order_discount_amount,
    tax_rule_id=source.tax_rule_id,tax_rule_version=source.tax_rule_version,
    tax_code_snapshot=source.tax_code_snapshot,
    tax_name_snapshot=source.tax_name_snapshot,
    tax_rate_percent_snapshot=source.tax_rate_percent_snapshot,
    tax_price_mode_snapshot=source.tax_price_mode_snapshot,
    tax_calculation_scope_snapshot=source.tax_calculation_scope_snapshot,
    tax_base=source.tax_base,tax_amount=source.tax_amount,
    tax_rounding=source.tax_rounding,tax_account_id=source.tax_account_id,
    tax_account_code_snapshot=source.tax_account_code_snapshot,
    tax_account_name_snapshot=source.tax_account_name_snapshot,
    allocated_document_rounding=source.allocated_document_rounding,
    pricing_snapshot=target.pricing_snapshot||jsonb_build_object(
      'baseUnitPrice',source.base_unit_price,
      'pricelistId',source.pricelist_id,
      'pricelistRuleId',source.pricelist_rule_id,
      'resolvedUnitPrice',source.resolved_unit_price,
      'canonicalResolvedUnitPrice',COALESCE(source.canonical_resolved_unit_price,
        source.resolved_unit_price,source.price),
      'priceOverrideApplied',source.price_override_applied,
      'cutoverSource','RETAIL_SALE','cutoverSourceLineId',source.id,
      'snapshotPreserved',true),updated_by=p_actor_id,updated_at=clock_timestamp()
  FROM public.sales_details source
  WHERE source.company_id=p_company_id AND source.sales_id=v_source.id
    AND target.company_id=p_company_id AND target.sales_order_id=v_target_id
    AND target.product_id=source.product_id
    AND target.pricing_snapshot->>'productUomId'=source.product_uom_id::text;
  GET DIAGNOSTICS v_target_line_count=ROW_COUNT;
  IF v_target_line_count<>v_source_line_count THEN
    RAISE EXCEPTION 'CUTOVER_TARGET_BACKOFFICE_LINE_COUNT_MISMATCH';
  END IF;

  PERFORM set_config('kgs.backoffice_delivery_fee_amount',
    v_source.delivery_fee_amount::text,true);
  PERFORM set_config('kgs.backoffice_delivery_fee_display_mode',
    v_source.delivery_fee_invoice_display_mode,true);
  UPDATE public.backoffice_sales_orders target SET
    pricelist_id=v_pricelist,
    customer_snapshot=jsonb_build_object('id',customer.id,'code',customer.code,
      'name',customer.name,'phone',customer.phone,'email',customer.email,
      'address',customer.address,'creditTermDays',customer.credit_term_days),
    commercial_snapshot=COALESCE(v_source.payload_snapshot,'{}'::jsonb)
      ||jsonb_build_object('cutoverSource','RETAIL_SALE',
        'cutoverSourceDocumentId',v_source.id,
        'cutoverSourceDocumentNo',COALESCE(v_source.draft_no,v_source.invoice_no),
        'snapshotPreserved',true),
    subtotal=v_source.subtotal,discount_total=v_source.item_discount+v_source.global_discount,
    global_discount=v_source.global_discount,tax_total=COALESCE((SELECT sum(detail.tax_amount)
      FROM public.sales_details detail WHERE detail.company_id=p_company_id
        AND detail.sales_id=v_source.id),0),
    -- Retail stores delivery fee inside both grand_total_before/after_rounding;
    -- Backoffice stores it separately and its trigger adds it to grand_total.
    grand_total_before_rounding=v_source.grand_total_before_rounding-
      v_source.delivery_fee_amount,
    rounding_direction=v_source.rounding_direction,
    rounding_increment=v_source.rounding_increment,
    rounding_adjustment=v_source.rounding_adjustment,
    delivery_fee_amount=v_source.delivery_fee_amount,
    delivery_fee_invoice_display_mode=v_source.delivery_fee_invoice_display_mode,
    updated_by=p_actor_id,updated_at=clock_timestamp()
  FROM public.customers customer
  WHERE target.company_id=p_company_id AND target.id=v_target_id
    AND customer.company_id=p_company_id AND customer.id=v_source.customer_id;
  PERFORM set_config('kgs.backoffice_delivery_fee_amount','',true);
  PERFORM set_config('kgs.backoffice_delivery_fee_display_mode','',true);

  SELECT round(sale.grand_total_after_rounding,4),round(document.grand_total,4)
  INTO v_source_total,v_target_total FROM public.sales_headers sale
  JOIN public.backoffice_sales_orders document ON document.company_id=sale.company_id
  WHERE sale.company_id=p_company_id AND sale.id=v_source.id
    AND document.id=v_target_id;
  IF v_target_total IS DISTINCT FROM v_source_total THEN
    RAISE EXCEPTION 'CUTOVER_TARGET_BACKOFFICE_COMMERCIAL_MISMATCH';
  END IF;
  v_after:=private.backoffice_sales_order_snapshot(p_company_id,v_target_id);
  INSERT INTO public.backoffice_sales_order_audit(company_id,sales_order_id,
    operation_id,action,actor_id,reason,before_state,after_state)
  VALUES(p_company_id,v_target_id,p_operation_id,'UPDATE',p_actor_id,
    'Snapshot Retail dipertahankan saat cutover',v_before,v_after);

  v_is_confirmed:=v_source.order_runtime_status IN('SCHEDULED','CONFIRMED','RESERVED');
  v_reason:='Dikonversi ke Backoffice melalui cutover; target '||
    COALESCE(v_after->>'quotationNo',v_target_id::text);
  IF EXISTS(SELECT 1 FROM public.sales_stock_reservations reservation
      WHERE reservation.company_id=p_company_id AND reservation.sales_id=v_source.id)
    OR v_source.order_runtime_status IN('CONFIRMED','RESERVED') THEN
    v_cancel:=public.cancel_pos_sales_order(v_source.id,v_source.master_version,
      gen_random_uuid(),v_reason);
  ELSE
    UPDATE public.sales_headers SET document_status='CANCELED',
      order_runtime_status='CANCELED',canceled_at=clock_timestamp(),
      canceled_by=p_actor_id,cancel_reason=v_reason,master_version=master_version+1,
      edit_lock_owner_id=NULL,edit_lock_session_id=NULL,
      edit_lock_acquired_at=NULL,edit_lock_heartbeat_at=NULL,
      updated_at=clock_timestamp() WHERE company_id=p_company_id AND id=v_source.id;
    INSERT INTO public.sale_master_audit(company_id,sales_id,action,actor_id,
      before_state,after_state) VALUES(p_company_id,v_source.id,'CANCEL_DRAFT',
      p_actor_id,to_jsonb(v_source),jsonb_build_object('documentStatus','CANCELED',
        'orderRuntimeStatus','CANCELED','reason',v_reason,'cutoverTargetId',v_target_id));
  END IF;
  IF v_is_confirmed THEN
    SELECT master_version INTO STRICT v_target_version
    FROM public.backoffice_sales_orders WHERE company_id=p_company_id AND id=v_target_id;
    v_confirm:=public.confirm_backoffice_sales_order(
      v_target_id,v_target_version,gen_random_uuid());
    v_after:=private.backoffice_sales_order_snapshot(p_company_id,v_target_id);
  END IF;
  RETURN jsonb_build_object('sourceDocumentType','RETAIL_SALE',
    'sourceDocumentId',v_source.id,'sourceDocumentNo',COALESCE(v_source.draft_no,v_source.invoice_no),
    'sourceClosed',true,'targetDocumentType','BACKOFFICE_SALES_ORDER',
    'targetDocumentId',v_target_id,'targetDocumentNo',COALESCE(v_after->>'orderNo',v_after->>'quotationNo'),
    'targetStatus',v_after->>'status','commercialSnapshotPreserved',true,
    'reservationTransferred',v_is_confirmed,'exactRetry',false);
END
$$;

REVOKE ALL ON FUNCTION private.convert_retail_sale_to_backoffice_order(
  uuid,uuid,uuid,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.convert_retail_sale_to_backoffice_order(
  uuid,uuid,uuid,uuid) TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260911100000','sales_process_cutover_retail_to_backoffice_converter',
  'Trusted Retail-to-Backoffice converter kernel preserving commercial/date/payment-term snapshot, mapping Draft to Quotation and Scheduled/Confirmed/Reserved to confirmed SO with canonical Reservation/initial DO; no public Apply or Company mode switch');

NOTIFY pgrst,'reload schema';
COMMIT;
