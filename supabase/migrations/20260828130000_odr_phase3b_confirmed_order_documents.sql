-- ODR-3B: confirmed Sales Order immutable Invoice/SJ snapshots and legacy
-- Dispatch bypass quarantine. Stock/FIFO/Movement/Finance remain unchanged.
BEGIN;

DO $guard$
DECLARE v_definition TEXT;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260828120000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: ODR-3A required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260828130000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260828130000';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
    WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
  IF EXISTS(SELECT 1 FROM public.sales_stock_reservations) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: existing reservation requires reviewed document backfill';
  END IF;
  SELECT pg_get_functiondef(
    'private.acp5e_update_sales_delivery_status_core(uuid,bigint,text,text)'::regprocedure)
  INTO v_definition;
  IF v_definition IS NULL OR v_definition!~'UPDATE public.sales_delivery_documents' THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Delivery status core changed';
  END IF;
END
$guard$;

ALTER TABLE public.sales_invoice_snapshots
  DROP CONSTRAINT sales_invoice_snapshot_provenance_check,
  ADD CONSTRAINT sales_invoice_snapshot_provenance_check
    CHECK(snapshot_provenance IN('LIVE_POST','LEGACY_CUTOVER','ORDER_CONFIRM'));

CREATE FUNCTION private.build_confirmed_order_invoice_snapshot(
  p_company_id UUID,p_sales_id UUID
) RETURNS JSONB LANGUAGE sql VOLATILE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
  SELECT jsonb_build_object(
    'snapshotVersion',1,'snapshotProvenance','ORDER_CONFIRM',
    'capturedAt',clock_timestamp(),'invoiceNo',sale.invoice_no,'saleId',sale.id,
    'company',jsonb_build_object('name',company.company_name,
      'legalName',company.legal_name,'taxId',company.tax_id,
      'timezone',company.timezone,'currencyCode',company.currency_code,
      'bankName',company.bank_name,'bankAccountNumber',company.bank_account_number,
      'bankAccountHolder',company.bank_account_holder),
    'branding',jsonb_build_object('logoObjectPath',branding.logo_object_path,
      'logoPublicUrl',branding.logo_public_url,'logoVersion',branding.logo_version,
      'logoChecksumSha256',branding.logo_checksum_sha256,
      'showLogoOnDocuments',COALESCE(branding.show_logo_on_documents,TRUE),
      'showStampOnDocuments',COALESCE(branding.show_stamp_on_documents,FALSE),
      'showBankAccountOnInvoice',COALESCE(branding.show_bank_account_on_invoice,FALSE),
      'invoiceDateDisplayMode',COALESCE(branding.invoice_date_display_mode,'ORDER_DATE'),
      'deliverySignatureTemplate',COALESCE(branding.delivery_signature_template,'WAREHOUSE')),
    'store',jsonb_build_object('name',store.store_name,'address',store.address,
      'timezone',store.timezone),'warehouse',jsonb_build_object('name',warehouse.name),
    'customer',CASE WHEN customer.id IS NULL THEN NULL ELSE jsonb_build_object(
      'code',customer.code,'name',customer.name,'phone',customer.phone,
      'address',customer.address,'parentCode',parent_customer.code,
      'parentName',parent_customer.name) END,
    'transactionAt',sale.transaction_date,'orderConfirmedAt',sale.confirmed_at,
    'postedAt',NULL,'sourceChannel',sale.source_channel,'isTempo',sale.is_tempo,
    'dueDate',sale.due_date,'fulfillmentMode',sale.fulfillment_mode,
    'lines',COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'lineKey',line.client_line_key,'sku',line.product_sku_snapshot,
      'productName',line.product_name_snapshot,'uomName',line.sale_uom_name_snapshot,
      'quantity',line.qty,'factorToBase',line.uom_factor_to_base_snapshot,
      'quantityBase',line.quantity_base,'unitPrice',line.resolved_unit_price,
      'discount',line.line_discount_amount+line.allocated_order_discount_amount,
      'taxCode',line.tax_code_snapshot,'taxName',line.tax_name_snapshot,
      'taxRatePercent',line.tax_rate_percent_snapshot,
      'taxPriceMode',line.tax_price_mode_snapshot,'taxAmount',line.tax_amount,
      'lineTotal',line.line_total) ORDER BY line.id)
      FROM public.sales_details line WHERE line.company_id=sale.company_id
        AND line.sales_id=sale.id),'[]'::JSONB),
    'payments',COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'clientPaymentKey',payment.client_payment_key,
      'methodName',payment.payment_method_name_snapshot,
      'methodType',payment.payment_method_type_snapshot,
      'settlementRoute',payment.settlement_route_snapshot,'amount',payment.amount,
      'configuredFee',payment.configured_fee_amount,
      'customerSurcharge',payment.customer_surcharge_amount,
      'tenderedAmount',payment.tendered_amount,'changeAmount',payment.change_amount,
      'overpaymentDisposition',payment.overpayment_disposition,
      'customerBalanceCreditAmount',payment.customer_balance_credit_amount,
      'customerBalanceUsageAmount',payment.customer_balance_usage_amount,
      'proofUrl',payment.proof_url,
      'offlineVerificationStatus',payment.offline_verification_status)
      ORDER BY payment.payment_no) FROM public.sales_payments payment
      WHERE payment.company_id=sale.company_id AND payment.sales_id=sale.id
        AND NOT payment.is_reversal),'[]'::JSONB),
    'totals',jsonb_build_object('subtotal',sale.subtotal,
      'itemDiscount',sale.item_discount,'orderDiscount',sale.global_discount,
      'totalBeforeRounding',sale.grand_total_before_rounding,
      'roundingDirection',sale.rounding_direction,
      'roundingAdjustment',sale.rounding_adjustment,
      'deliveryFee',COALESCE(sale.delivery_fee_amount,0),
      'deliveryFeeInvoiceDisplayMode',COALESCE(sale.delivery_fee_invoice_display_mode,'SHOW_SEPARATE'),
      'grandTotal',sale.grand_total_after_rounding,'paidAmount',sale.paid_amount,
      'receivable',sale.sisa_piutang))
  FROM public.sales_headers sale
  JOIN public.companies company ON company.id=sale.company_id
  JOIN public.stores store ON store.company_id=sale.company_id AND store.id=sale.store_id
  JOIN public.warehouses warehouse ON warehouse.company_id=sale.company_id
    AND warehouse.id=sale.sales_warehouse_id
  LEFT JOIN public.customers customer ON customer.company_id=sale.company_id
    AND customer.id=sale.customer_id
  LEFT JOIN public.customers parent_customer ON parent_customer.company_id=customer.company_id
    AND parent_customer.id=customer.parent_customer_id
  LEFT JOIN public.company_branding_profiles branding ON branding.company_id=sale.company_id
  WHERE sale.company_id=p_company_id AND sale.id=p_sales_id
    AND sale.document_status='DRAFT'
    AND sale.order_runtime_status IN('CONFIRMED','RESERVED');
$$;

CREATE FUNCTION private.ensure_confirmed_order_documents(
  p_company_id UUID,p_sales_id UUID
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_sale public.sales_headers%ROWTYPE;v_reservation UUID;v_payload JSONB;
  v_invoice UUID;v_delivery UUID;v_delivery_no TEXT;v_actor UUID;v_at TIMESTAMPTZ;
  v_branding public.company_branding_profiles%ROWTYPE;v_recipient_name TEXT;
  v_recipient_phone TEXT;v_address TEXT;
BEGIN
  SELECT sale.* INTO v_sale FROM public.sales_headers sale
  WHERE sale.company_id=p_company_id AND sale.id=p_sales_id FOR UPDATE;
  IF NOT FOUND OR v_sale.document_status<>'DRAFT'
    OR v_sale.order_runtime_status NOT IN('CONFIRMED','RESERVED') THEN
    RAISE EXCEPTION 'SALES_ORDER_NOT_CONFIRMED';
  END IF;
  SELECT reservation.id INTO STRICT v_reservation
  FROM public.sales_stock_reservations reservation
  WHERE reservation.company_id=p_company_id AND reservation.sales_id=p_sales_id;
  v_actor:=v_sale.confirmed_by;v_at:=v_sale.confirmed_at;
  IF v_actor IS NULL OR v_at IS NULL THEN RAISE EXCEPTION 'SALES_ORDER_CONFIRMATION_INCOMPLETE'; END IF;
  IF COALESCE(btrim(v_sale.invoice_no),'')='' THEN RAISE EXCEPTION 'SALES_ORDER_INVOICE_IDENTITY_MISSING'; END IF;

  SELECT invoice.id INTO v_invoice FROM public.sales_invoice_snapshots invoice
  WHERE invoice.company_id=p_company_id AND invoice.sales_id=p_sales_id;
  IF v_invoice IS NULL THEN
    v_payload:=private.build_confirmed_order_invoice_snapshot(p_company_id,p_sales_id);
    IF v_payload IS NULL THEN RAISE EXCEPTION 'SALES_ORDER_DOCUMENT_SOURCE_INCOMPLETE'; END IF;
    SELECT branding.* INTO v_branding FROM public.company_branding_profiles branding
    WHERE branding.company_id=p_company_id;
    INSERT INTO public.sales_invoice_snapshots(company_id,sales_id,invoice_no,
      snapshot_version,snapshot_provenance,snapshot_payload,
      branding_logo_object_path,branding_logo_version,
      branding_logo_checksum_sha256,created_by,created_at)
    VALUES(p_company_id,p_sales_id,v_sale.invoice_no,1,'ORDER_CONFIRM',v_payload,
      v_branding.logo_object_path,v_branding.logo_version,
      v_branding.logo_checksum_sha256,v_actor,v_at) RETURNING id INTO v_invoice;
    INSERT INTO public.sales_document_audit(company_id,document_type,document_id,
      sales_id,action,actor_id,after_state,created_at)
    VALUES(p_company_id,'SALES_INVOICE',v_invoice,p_sales_id,'CREATE',v_actor,
      jsonb_build_object('invoiceNo',v_sale.invoice_no,
        'provenance','ORDER_CONFIRM','orderRuntimeStatus',v_sale.order_runtime_status),v_at);
  ELSE
    SELECT invoice.snapshot_payload INTO v_payload FROM public.sales_invoice_snapshots invoice
    WHERE invoice.company_id=p_company_id AND invoice.id=v_invoice;
  END IF;

  SELECT delivery.id INTO v_delivery FROM public.sales_delivery_documents delivery
  WHERE delivery.company_id=p_company_id AND delivery.sales_id=p_sales_id;
  IF v_delivery IS NULL THEN
    v_recipient_name:=CASE WHEN v_sale.fulfillment_mode='DELIVERY'
      THEN private.require_delivery_recipient_name(v_sale.delivery_recipient_name)
      ELSE COALESCE(NULLIF(btrim(v_payload#>>'{customer,name}'),''),'Pelanggan Umum') END;
    v_recipient_phone:=CASE WHEN v_sale.fulfillment_mode='DELIVERY'
      THEN NULLIF(btrim(v_sale.delivery_recipient_phone),'')
      ELSE NULLIF(btrim(v_payload#>>'{customer,phone}'),'') END;
    v_address:=CASE WHEN v_sale.fulfillment_mode='DELIVERY'
      THEN NULLIF(btrim(v_sale.delivery_address),'')
      ELSE NULLIF(btrim(v_payload#>>'{customer,address}'),'') END;
    v_delivery_no:=private.next_sales_delivery_no(p_company_id,v_at);
    INSERT INTO public.sales_delivery_documents(company_id,delivery_no,sales_id,
      invoice_snapshot_id,store_id,warehouse_id,customer_id,recipient_name,
      recipient_phone,delivery_address,scheduled_at,delivery_notes,status,
      snapshot_payload,branding_logo_object_path,created_by,created_at,
      fulfillment_mode,reservation_id)
    VALUES(p_company_id,v_delivery_no,p_sales_id,v_invoice,v_sale.store_id,
      v_sale.sales_warehouse_id,v_sale.customer_id,v_recipient_name,
      v_recipient_phone,v_address,v_sale.delivery_scheduled_at,
      NULLIF(btrim(v_sale.delivery_notes),''),'READY',jsonb_build_object(
        'snapshotVersion',1,'snapshotProvenance','ORDER_CONFIRM',
        'deliveryNo',v_delivery_no,'invoiceNo',v_sale.invoice_no,
        'saleId',p_sales_id,'reservationId',v_reservation,
        'fulfillmentMode',v_sale.fulfillment_mode,'company',v_payload->'company',
        'branding',v_payload->'branding','store',v_payload->'store',
        'warehouse',v_payload->'warehouse','customer',v_payload->'customer',
        'recipient',jsonb_build_object('name',v_recipient_name,
          'phone',v_recipient_phone,'address',v_address),
        'scheduledAt',v_sale.delivery_scheduled_at,'notes',v_sale.delivery_notes,
        'lines',v_payload->'lines'),v_branding.logo_object_path,v_actor,v_at,
      v_sale.fulfillment_mode,v_reservation) RETURNING id INTO v_delivery;
    INSERT INTO public.sales_delivery_lines(company_id,delivery_document_id,
      sales_detail_id,line_no,product_id,product_sku_snapshot,product_name_snapshot,
      sale_uom_id,sale_uom_name_snapshot,quantity_uom,factor_to_base_snapshot,
      quantity_base)
    SELECT line.company_id,v_delivery,line.id,
      (row_number() OVER(ORDER BY line.id))::INTEGER,line.product_id,line.product_sku_snapshot,
      line.product_name_snapshot,line.sale_uom_id,line.sale_uom_name_snapshot,
      line.qty,line.uom_factor_to_base_snapshot,line.quantity_base
    FROM public.sales_details line WHERE line.company_id=p_company_id
      AND line.sales_id=p_sales_id;
    INSERT INTO public.sales_document_audit(company_id,document_type,document_id,
      sales_id,action,actor_id,after_state,created_at)
    VALUES(p_company_id,'SALES_DELIVERY',v_delivery,p_sales_id,'CREATE',v_actor,
      jsonb_build_object('deliveryNo',v_delivery_no,'status','READY',
        'reservationId',v_reservation,'provenance','ORDER_CONFIRM'),v_at);
    UPDATE public.sales_headers SET sj_required=TRUE,sj_no=v_delivery_no,
      sj_status='PENDING'::public.sj_status
    WHERE company_id=p_company_id AND id=p_sales_id;
  ELSE
    IF NOT EXISTS(SELECT 1 FROM public.sales_delivery_documents delivery
      WHERE delivery.company_id=p_company_id AND delivery.id=v_delivery
        AND delivery.reservation_id=v_reservation) THEN
      RAISE EXCEPTION 'SALES_ORDER_DOCUMENT_IDEMPOTENCY_CONFLICT';
    END IF;
  END IF;
  RETURN jsonb_build_object('invoiceSnapshotId',v_invoice,
    'deliveryDocumentId',v_delivery,'reservationId',v_reservation);
END
$$;

CREATE FUNCTION private.cancel_confirmed_order_delivery(
  p_company_id UUID,p_sales_id UUID,p_reason TEXT
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_delivery public.sales_delivery_documents%ROWTYPE;v_actor UUID:=auth.uid();
BEGIN
  SELECT delivery.* INTO v_delivery FROM public.sales_delivery_documents delivery
  WHERE delivery.company_id=p_company_id AND delivery.sales_id=p_sales_id FOR UPDATE;
  IF NOT FOUND THEN RETURN; END IF;
  IF v_delivery.reservation_id IS NULL THEN RAISE EXCEPTION 'LEGACY_DELIVERY_CANCEL_BOUNDARY'; END IF;
  IF v_delivery.status='CANCELED' THEN RETURN; END IF;
  IF v_delivery.status<>'READY' OR v_delivery.total_dispatched_base_qty<>0 THEN
    RAISE EXCEPTION 'SALES_ORDER_DISPATCH_STARTED';
  END IF;
  PERFORM set_config('kgs.sld_delivery_status_mutation','1',TRUE);
  UPDATE public.sales_delivery_documents SET status='CANCELED',
    master_version=master_version+1,canceled_by=v_actor,
    canceled_at=clock_timestamp(),cancel_reason=btrim(p_reason)
  WHERE company_id=p_company_id AND id=v_delivery.id;
  PERFORM set_config('kgs.sld_delivery_status_mutation','',TRUE);
  INSERT INTO public.sales_document_audit(company_id,document_type,document_id,
    sales_id,action,actor_id,before_state,after_state)
  VALUES(p_company_id,'SALES_DELIVERY',v_delivery.id,p_sales_id,'CANCEL',v_actor,
    jsonb_build_object('status',v_delivery.status,'masterVersion',v_delivery.master_version),
    jsonb_build_object('status','CANCELED','reason',btrim(p_reason),
      'masterVersion',v_delivery.master_version+1));
END
$$;

CREATE OR REPLACE FUNCTION public.confirm_pos_sales_order(
  p_sales_id UUID,p_master_version BIGINT,p_idempotency_key UUID,
  p_negative_stock_reason TEXT DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_result JSONB;v_documents JSONB;v_company UUID:=public.private_active_company_id();
BEGIN
  v_result:=private.confirm_pos_sales_order_core(p_sales_id,p_master_version,
    p_idempotency_key,p_negative_stock_reason);
  v_documents:=private.ensure_confirmed_order_documents(v_company,p_sales_id);
  RETURN v_result||jsonb_build_object('documents',v_documents);
END
$$;

CREATE OR REPLACE FUNCTION public.cancel_pos_sales_order(
  p_sales_id UUID,p_master_version BIGINT,p_idempotency_key UUID,p_reason TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_result JSONB;v_company UUID:=public.private_active_company_id();
BEGIN
  v_result:=private.cancel_pos_sales_order_core(p_sales_id,p_master_version,
    p_idempotency_key,p_reason);
  PERFORM private.cancel_confirmed_order_delivery(v_company,p_sales_id,p_reason);
  RETURN v_result;
END
$$;

ALTER FUNCTION private.acp5e_update_sales_delivery_status_core(UUID,BIGINT,TEXT,TEXT)
  RENAME TO acp5e_update_sales_delivery_status_odr3_legacy;

CREATE FUNCTION private.acp5e_update_sales_delivery_status_core(
  p_delivery_document_id UUID,p_master_version BIGINT,
  p_action TEXT,p_reason TEXT DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_reservation UUID;
BEGIN
  SELECT delivery.reservation_id INTO v_reservation
  FROM public.sales_delivery_documents delivery
  WHERE delivery.company_id=v_company AND delivery.id=p_delivery_document_id;
  IF upper(btrim(COALESCE(p_action,'')))='DISPATCH' AND v_reservation IS NOT NULL THEN
    RAISE EXCEPTION 'USE_CANONICAL_DISPATCH_RUNTIME';
  END IF;
  RETURN private.acp5e_update_sales_delivery_status_odr3_legacy(
    p_delivery_document_id,p_master_version,p_action,p_reason);
END
$$;

CREATE OR REPLACE FUNCTION public.update_sales_delivery_status(
  p_delivery_document_id UUID,p_master_version BIGINT,
  p_action TEXT,p_reason TEXT DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'inventory.delivery_documents','MANAGE');
  RETURN private.acp5e_update_sales_delivery_status_core(
    p_delivery_document_id,p_master_version,p_action,p_reason);
END
$$;

REVOKE ALL ON FUNCTION private.build_confirmed_order_invoice_snapshot(UUID,UUID),
  private.ensure_confirmed_order_documents(UUID,UUID),
  private.cancel_confirmed_order_delivery(UUID,UUID,TEXT),
  private.acp5e_update_sales_delivery_status_core(UUID,BIGINT,TEXT,TEXT),
  private.acp5e_update_sales_delivery_status_odr3_legacy(UUID,BIGINT,TEXT,TEXT)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.build_confirmed_order_invoice_snapshot(UUID,UUID),
  private.ensure_confirmed_order_documents(UUID,UUID),
  private.cancel_confirmed_order_delivery(UUID,UUID,TEXT),
  private.acp5e_update_sales_delivery_status_core(UUID,BIGINT,TEXT,TEXT),
  private.acp5e_update_sales_delivery_status_odr3_legacy(UUID,BIGINT,TEXT,TEXT)
TO service_role;
REVOKE ALL ON FUNCTION public.confirm_pos_sales_order(UUID,BIGINT,UUID,TEXT),
  public.cancel_pos_sales_order(UUID,BIGINT,UUID,TEXT),
  public.update_sales_delivery_status(UUID,BIGINT,TEXT,TEXT)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.confirm_pos_sales_order(UUID,BIGINT,UUID,TEXT),
  public.cancel_pos_sales_order(UUID,BIGINT,UUID,TEXT),
  public.update_sales_delivery_status(UUID,BIGINT,TEXT,TEXT)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260828130000','odr_phase3b_confirmed_order_documents',
  'Confirmed Sales Order atomically creates immutable ORDER_CONFIRM Invoice/SJ snapshots linked to Reservation; cancellation closes only READY linked SJ and legacy status RPC cannot Dispatch linked documents without canonical stock runtime');

NOTIFY pgrst,'reload schema';
COMMIT;
