-- Forward-fix: resolve the canonical source Order date before revision Draft
-- creation. Scheduled Orders use plannedOrderAt/planned_order_date; Immediate
-- and Backorder keep their canonical header date. No Finance guard is relaxed.
BEGIN;

DO $migration$
DECLARE v_definition TEXT;v_invoice_definition TEXT;
BEGIN
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260904140000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260904140000';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260904130000')
    OR to_regprocedure(
      'private.sales_order_revision_date_payload(jsonb,timestamptz,text)') IS NULL
    OR to_regprocedure(
      'public.start_pos_sales_order_revision(uuid,bigint,uuid,uuid,text)') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: revision Order-date preservation runtime required';
  END IF;
  IF to_regprocedure(
      'private.resolve_sales_order_revision_date_identity(jsonb,text)')
      IS NOT NULL
    OR to_regprocedure(
      'private.sales_order_revision_identity_payload(jsonb,jsonb,boolean)')
      IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: revision date resolver already exists without ledger';
  END IF;
  SELECT lower(regexp_replace(pg_get_functiondef(
    'public.start_pos_sales_order_revision(uuid,bigint,uuid,uuid,text)'::regprocedure),
    '[[:space:]]+','','g')) INTO v_definition;
  IF position('v_payload:=private.sales_order_revision_date_payload('
      IN v_definition)=0
    OR position('v_draft:=public.save_pos_sale_draft_with_pricelist(v_payload)'
      IN v_definition)=0
    OR position('transaction_date=v_source.transaction_date' IN v_definition)=0
    OR position('sales_order_revision_dispatch_started' IN v_definition)=0
    OR position('sales_order_revision_verified_payment' IN v_definition)=0 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: revision-start runtime drift';
  END IF;
  SELECT lower(regexp_replace(pg_get_functiondef(
    'private.build_confirmed_order_invoice_snapshot(uuid,uuid)'::regprocedure),
    '[[:space:]]+','','g')) INTO v_invoice_definition;
  IF v_invoice_definition!~'transactionat'
    OR v_invoice_definition!~'sale\.transaction_date'
    OR v_invoice_definition!~'snapshotprovenance'
    OR v_invoice_definition!~'order_confirm' THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: confirmed Order Invoice builder drift';
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
$migration$;

CREATE FUNCTION private.resolve_sales_order_revision_date_identity(
  p_source JSONB,
  p_timezone TEXT
) RETURNS JSONB
LANGUAGE plpgsql IMMUTABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
  v_mode TEXT:=upper(COALESCE(NULLIF(p_source->>'order_timing_mode',''),
    'IMMEDIATE'));
  v_transaction_at TIMESTAMPTZ;
  v_transaction_source TEXT;
  v_selected_by UUID;
  v_selected_at TIMESTAMPTZ;
  v_planned_date DATE;
  v_planned_at TIMESTAMPTZ;
BEGIN
  IF NULLIF(btrim(p_timezone),'') IS NULL
    OR v_mode NOT IN('IMMEDIATE','BACKORDER','SCHEDULED') THEN
    RAISE EXCEPTION 'SALES_ORDER_REVISION_DATE_IDENTITY_INVALID';
  END IF;

  BEGIN
    v_transaction_at:=(p_source->>'transaction_date')::TIMESTAMPTZ;
    v_transaction_source:=p_source->>'transaction_date_source';
    v_selected_by:=NULLIF(p_source->>'transaction_date_selected_by','')::UUID;
    v_selected_at:=NULLIF(p_source->>'transaction_date_selected_at','')::TIMESTAMPTZ;
    v_planned_date:=NULLIF(p_source->>'planned_order_date','')::DATE;
  EXCEPTION WHEN invalid_datetime_format OR invalid_text_representation THEN
    RAISE EXCEPTION 'SALES_ORDER_REVISION_DATE_IDENTITY_INVALID';
  END;

  IF v_mode='SCHEDULED' THEN
    IF v_planned_date IS NULL
      OR NULLIF(p_source->>'planned_order_selected_by','') IS NULL
      OR NULLIF(p_source->>'planned_order_selected_at','') IS NULL THEN
      RAISE EXCEPTION 'SALES_ORDER_REVISION_SCHEDULED_DATE_IDENTITY_INVALID';
    END IF;
    BEGIN
      v_planned_at:=COALESCE(
        NULLIF(p_source#>>'{payload_snapshot,plannedOrderAt}','')::TIMESTAMPTZ,
        (v_planned_date::TEXT||' 12:00:00')::TIMESTAMP AT TIME ZONE p_timezone);
      v_selected_by:=(p_source->>'planned_order_selected_by')::UUID;
      v_selected_at:=(p_source->>'planned_order_selected_at')::TIMESTAMPTZ;
    EXCEPTION WHEN invalid_datetime_format OR invalid_text_representation THEN
      RAISE EXCEPTION 'SALES_ORDER_REVISION_SCHEDULED_DATE_IDENTITY_INVALID';
    END;
    IF (v_planned_at AT TIME ZONE p_timezone)::DATE IS DISTINCT FROM v_planned_date THEN
      RAISE EXCEPTION 'SALES_ORDER_REVISION_SCHEDULED_DATE_MISMATCH';
    END IF;
    v_transaction_at:=v_planned_at;
    v_transaction_source:='CASHIER_SELECTED';
  ELSIF v_transaction_at IS NULL
    OR v_transaction_source NOT IN('SERVER_CREATED','CASHIER_SELECTED')
    OR (v_transaction_source='SERVER_CREATED'
      AND (v_selected_by IS NOT NULL OR v_selected_at IS NOT NULL))
    OR (v_transaction_source='CASHIER_SELECTED'
      AND (v_selected_by IS NULL OR v_selected_at IS NULL)) THEN
    RAISE EXCEPTION 'SALES_ORDER_REVISION_DATE_IDENTITY_INVALID';
  END IF;

  IF v_mode='BACKORDER' AND (v_planned_date IS NULL
    OR v_transaction_source<>'CASHIER_SELECTED'
    OR (v_transaction_at AT TIME ZONE p_timezone)::DATE IS DISTINCT FROM
      v_planned_date) THEN
    RAISE EXCEPTION 'SALES_ORDER_REVISION_BACKORDER_DATE_IDENTITY_INVALID';
  END IF;

  RETURN jsonb_build_object(
    'orderTimingMode',v_mode,
    'plannedOrderDate',v_planned_date,
    'transactionAt',v_transaction_at,
    'transactionDateSource',v_transaction_source,
    'transactionDateSelectedBy',v_selected_by,
    'transactionDateSelectedAt',v_selected_at);
END
$$;

CREATE FUNCTION private.sales_order_revision_identity_payload(
  p_payload JSONB,
  p_identity JSONB,
  p_for_save BOOLEAN
) RETURNS JSONB
LANGUAGE plpgsql IMMUTABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
  v_mode TEXT:=p_identity->>'orderTimingMode';
  v_payload JSONB:=COALESCE(p_payload,'{}'::JSONB)
    -'plannedOrderDate'-'plannedOrderAt'-'orderTimingMode';
BEGIN
  IF v_mode NOT IN('IMMEDIATE','BACKORDER','SCHEDULED')
    OR NULLIF(p_identity->>'transactionAt','') IS NULL
    OR p_identity->>'transactionDateSource' NOT IN(
      'SERVER_CREATED','CASHIER_SELECTED') THEN
    RAISE EXCEPTION 'SALES_ORDER_REVISION_DATE_IDENTITY_INVALID';
  END IF;
  v_payload:=v_payload||jsonb_build_object(
    'transactionAt',(p_identity->>'transactionAt')::TIMESTAMPTZ,
    'transactionDateIntent',CASE WHEN p_for_save THEN 'CASHIER_SELECTED'
      WHEN p_identity->>'transactionDateSource'='CASHIER_SELECTED'
        THEN 'CASHIER_SELECTED' ELSE 'PRESERVE' END);
  IF v_mode IN('BACKORDER','SCHEDULED') THEN
    v_payload:=v_payload||jsonb_build_object(
      'plannedOrderDate',(p_identity->>'plannedOrderDate')::DATE,
      'orderTimingMode',v_mode);
  END IF;
  IF v_mode='SCHEDULED' THEN
    v_payload:=v_payload||jsonb_build_object(
      'plannedOrderAt',(p_identity->>'transactionAt')::TIMESTAMPTZ);
  END IF;
  RETURN v_payload;
END
$$;

CREATE OR REPLACE FUNCTION private.build_confirmed_order_invoice_snapshot(
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
    'transactionAt',(private.resolve_sales_order_revision_date_identity(
      to_jsonb(sale),company.timezone)->>'transactionAt')::TIMESTAMPTZ,
    'orderConfirmedAt',sale.confirmed_at,
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

CREATE OR REPLACE FUNCTION public.start_pos_sales_order_revision(
  p_source_sales_id UUID,
  p_source_master_version BIGINT,
  p_cashier_session_id UUID,
  p_idempotency_key UUID,
  p_reason TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_actor UUID:=auth.uid();
  v_source public.sales_headers%ROWTYPE;
  v_reservation public.sales_stock_reservations%ROWTYPE;
  v_revision public.sales_order_revisions%ROWTYPE;
  v_payload JSONB;v_draft JSONB;v_replacement public.sales_headers%ROWTYPE;
  v_date_identity JSONB;v_timezone TEXT;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
  IF p_source_sales_id IS NULL OR p_source_master_version IS NULL
    OR p_cashier_session_id IS NULL OR p_idempotency_key IS NULL THEN
    RAISE EXCEPTION 'SALES_ORDER_REVISION_CONTEXT_REQUIRED';
  END IF;
  IF NULLIF(btrim(p_reason),'') IS NULL OR length(btrim(p_reason))>500 THEN
    RAISE EXCEPTION 'SALES_ORDER_REVISION_REASON_REQUIRED';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(
    v_company::TEXT||':sales-order-revision:'||p_idempotency_key::TEXT,0));

  SELECT revision.* INTO v_revision
  FROM public.sales_order_revisions revision
  WHERE revision.company_id=v_company
    AND revision.start_idempotency_key=p_idempotency_key;
  IF FOUND THEN
    IF v_revision.source_sales_id IS DISTINCT FROM p_source_sales_id
      OR v_revision.source_master_version_at_start IS DISTINCT FROM
        p_source_master_version
      OR v_revision.reason IS DISTINCT FROM btrim(p_reason)
      OR NOT EXISTS(SELECT 1 FROM public.sales_headers sale
        WHERE sale.company_id=v_company
          AND sale.id=v_revision.replacement_sales_id
          AND sale.created_session_id=p_cashier_session_id) THEN
      RAISE EXCEPTION 'IDEMPOTENCY_PAYLOAD_CONFLICT';
    END IF;
    SELECT sale.* INTO v_replacement FROM public.sales_headers sale
    WHERE sale.company_id=v_company AND sale.id=v_revision.replacement_sales_id;
    RETURN jsonb_build_object('revisionId',v_revision.id,
      'sourceSalesId',v_revision.source_sales_id,
      'replacementSalesId',v_revision.replacement_sales_id,
      'replacementDraftNo',v_replacement.draft_no,
      'replacementMasterVersion',v_replacement.master_version,
      'status',v_revision.status,'idempotentReplay',TRUE);
  END IF;

  SELECT sale.* INTO v_source FROM public.sales_headers sale
  WHERE sale.company_id=v_company AND sale.id=p_source_sales_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'SALES_ORDER_NOT_FOUND'; END IF;
  IF v_source.master_version IS DISTINCT FROM p_source_master_version THEN
    RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
  END IF;
  IF v_source.document_status<>'DRAFT'
    OR v_source.order_runtime_status NOT IN('CONFIRMED','RESERVED') THEN
    RAISE EXCEPTION 'SALES_ORDER_REVISION_NOT_ELIGIBLE';
  END IF;
  SELECT reservation.* INTO v_reservation
  FROM public.sales_stock_reservations reservation
  WHERE reservation.company_id=v_company
    AND reservation.sales_id=p_source_sales_id FOR UPDATE;
  IF NOT FOUND OR v_reservation.status<>'OPEN'
    OR v_reservation.total_dispatched_base_qty<>0 THEN
    RAISE EXCEPTION 'SALES_ORDER_REVISION_DISPATCH_STARTED';
  END IF;
  IF EXISTS(SELECT 1 FROM public.sales_payment_verification_requests request
    WHERE request.company_id=v_company AND request.sales_id=p_source_sales_id
      AND request.status='VERIFIED') THEN
    RAISE EXCEPTION 'SALES_ORDER_REVISION_VERIFIED_PAYMENT';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.cashier_sessions session
    WHERE session.company_id=v_company AND session.id=p_cashier_session_id
      AND session.cashier_id=v_actor
      AND session.status='OPEN'::public.session_status
      AND session.store_id=v_source.store_id) THEN
    RAISE EXCEPTION 'OPEN_CASHIER_SESSION_REQUIRED';
  END IF;
  IF EXISTS(SELECT 1 FROM public.sales_order_revisions revision
    WHERE revision.company_id=v_company
      AND revision.source_sales_id=p_source_sales_id
      AND revision.status='PENDING') THEN
    RAISE EXCEPTION 'SALES_ORDER_REVISION_ALREADY_PENDING';
  END IF;

  SELECT company.timezone INTO v_timezone FROM public.companies company
  WHERE company.id=v_company AND company.status='ACTIVE';
  IF v_timezone IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_NOT_FOUND'; END IF;
  v_date_identity:=private.resolve_sales_order_revision_date_identity(
    to_jsonb(v_source),v_timezone);

  v_payload:=private.sales_order_revision_identity_payload(
    (COALESCE(v_source.payload_snapshot,'{}'::JSONB)
        -'saleId'-'masterVersion'-'payments'-'draftLabel'-'draftNotes'
        -'revisionId'-'revisionSourceSalesId'-'revisionSourceOrderNo')
      ||jsonb_build_object('clientTransactionId',p_idempotency_key,
        'cashierSessionId',p_cashier_session_id,'payments','[]'::JSONB,
        'draftLabel','Revisi '||v_source.draft_no,
        'draftNotes',btrim(p_reason),
        'revisionSourceSalesId',v_source.id,
        'revisionSourceOrderNo',v_source.draft_no),
    v_date_identity,TRUE);
  v_draft:=public.save_pos_sale_draft_with_pricelist(v_payload);

  UPDATE public.sales_headers SET is_revision=TRUE,
    original_invoice_no=v_source.invoice_no,
    transaction_date=(v_date_identity->>'transactionAt')::TIMESTAMPTZ,
    transaction_date_source=v_date_identity->>'transactionDateSource',
    transaction_date_selected_by=
      NULLIF(v_date_identity->>'transactionDateSelectedBy','')::UUID,
    transaction_date_selected_at=
      NULLIF(v_date_identity->>'transactionDateSelectedAt','')::TIMESTAMPTZ,
    planned_order_date=v_source.planned_order_date,
    order_timing_mode=v_source.order_timing_mode,
    planned_order_selected_by=v_source.planned_order_selected_by,
    planned_order_selected_at=v_source.planned_order_selected_at,
    scheduled_activated_at=v_source.scheduled_activated_at,
    payload_snapshot=private.sales_order_revision_identity_payload(
      COALESCE(payload_snapshot,'{}'::JSONB)||jsonb_build_object(
        'revisionSourceSalesId',v_source.id,
        'revisionSourceOrderNo',v_source.draft_no),
      v_date_identity,FALSE),
    master_version=master_version+1,updated_at=clock_timestamp()
  WHERE company_id=v_company AND id=(v_draft->>'salesId')::UUID
  RETURNING * INTO v_replacement;
  IF NOT FOUND THEN RAISE EXCEPTION 'SALES_ORDER_REVISION_DRAFT_NOT_FOUND'; END IF;

  INSERT INTO public.sales_order_revisions(company_id,source_sales_id,
    replacement_sales_id,reason,source_master_version_at_start,
    start_idempotency_key,started_by)
  VALUES(v_company,v_source.id,v_replacement.id,btrim(p_reason),
    v_source.master_version,p_idempotency_key,v_actor)
  RETURNING * INTO v_revision;
  INSERT INTO public.sales_order_revision_audit(company_id,revision_id,action,
    actor_id,idempotency_key,after_state)
  VALUES(v_company,v_revision.id,'START',v_actor,p_idempotency_key,
    jsonb_build_object('sourceSalesId',v_source.id,
      'sourceOrderNo',v_source.draft_no,
      'replacementSalesId',v_replacement.id,
      'replacementDraftNo',v_replacement.draft_no,
      'sourceMasterVersion',v_source.master_version,
      'replacementMasterVersion',v_replacement.master_version,
      'transactionDate',v_replacement.transaction_date,
      'transactionDateSource',v_replacement.transaction_date_source,
      'transactionDateSelectedBy',v_replacement.transaction_date_selected_by,
      'transactionDateSelectedAt',v_replacement.transaction_date_selected_at,
      'reason',v_revision.reason));
  RETURN v_draft||jsonb_build_object('revisionId',v_revision.id,
    'sourceSalesId',v_source.id,'sourceOrderNo',v_source.draft_no,
    'replacementSalesId',v_replacement.id,
    'replacementDraftNo',v_replacement.draft_no,
    'replacementMasterVersion',v_replacement.master_version,
    'transactionAt',v_replacement.transaction_date,
    'transactionDateSource',v_replacement.transaction_date_source,
    'status','PENDING','idempotentReplay',FALSE);
END
$$;

REVOKE ALL ON FUNCTION private.resolve_sales_order_revision_date_identity(
  JSONB,TEXT),private.sales_order_revision_identity_payload(JSONB,JSONB,BOOLEAN)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.resolve_sales_order_revision_date_identity(
  JSONB,TEXT),private.sales_order_revision_identity_payload(JSONB,JSONB,BOOLEAN)
TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260904140000','sales_order_revision_transient_date_validation_fix',
  'Resolves authoritative Order date for Immediate, Backorder and Scheduled revision sources; validates that exact date and preserves timing identity for the replacement Invoice without relaxing ordinary TEMPO period guards');

NOTIFY pgrst,'reload schema';
COMMIT;
