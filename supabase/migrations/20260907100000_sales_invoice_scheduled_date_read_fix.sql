-- Forward-fix: one canonical displayed Invoice date across list, detail/print,
-- POS print, and date-range export. Historical snapshots remain immutable.
BEGIN;

DO $guard$
BEGIN
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260907100000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260907100000';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260904100000')
    OR NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260904140000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Invoice export and scheduled date authority required';
  END IF;
  IF to_regprocedure('public.get_sales_documents()') IS NULL
    OR to_regprocedure('public.get_sales_invoice_document(uuid)') IS NULL
    OR to_regprocedure('public.get_pos_sales_invoice_document(uuid)') IS NULL
    OR to_regprocedure('public.export_sales_documents(date,date)') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical Invoice readers required';
  END IF;
END
$guard$;

CREATE FUNCTION private.resolve_sales_invoice_display_date(
  p_snapshot JSONB,p_sale JSONB,p_invoice_created_at TIMESTAMPTZ,
  p_company_timezone TEXT
) RETURNS DATE
LANGUAGE plpgsql IMMUTABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
  v_policy TEXT:=upper(COALESCE(NULLIF(
    p_snapshot#>>'{branding,invoiceDateDisplayMode}',''),'ORDER_DATE'));
  v_timing TEXT:=upper(COALESCE(NULLIF(p_sale->>'order_timing_mode',''),'IMMEDIATE'));
  v_timezone TEXT:=COALESCE(NULLIF(p_snapshot#>>'{company,timezone}',''),
    NULLIF(p_company_timezone,''),'Asia/Jakarta');
  v_source TIMESTAMPTZ;
  v_planned DATE;
BEGIN
  IF v_policy NOT IN('ORDER_DATE','POSTED_DATE') THEN
    RAISE EXCEPTION 'SALES_INVOICE_DATE_POLICY_INVALID';
  END IF;
  IF v_policy='ORDER_DATE' AND v_timing='SCHEDULED' THEN
    BEGIN
      v_planned:=COALESCE(NULLIF(p_sale->>'planned_order_date','')::DATE,
        NULLIF(p_sale#>>'{payload_snapshot,plannedOrderDate}','')::DATE);
    EXCEPTION WHEN invalid_datetime_format THEN
      RAISE EXCEPTION 'SALES_INVOICE_PLANNED_DATE_INVALID';
    END;
    IF v_planned IS NOT NULL THEN RETURN v_planned; END IF;
  END IF;

  BEGIN
    IF v_policy='POSTED_DATE' THEN
      v_source:=COALESCE(NULLIF(p_snapshot->>'postedAt','')::TIMESTAMPTZ,
        NULLIF(p_sale->>'posted_at','')::TIMESTAMPTZ,
        NULLIF(p_sale->>'confirmed_at','')::TIMESTAMPTZ,p_invoice_created_at);
    ELSE
      v_source:=COALESCE(NULLIF(p_snapshot->>'transactionAt','')::TIMESTAMPTZ,
        NULLIF(p_sale->>'transaction_date','')::TIMESTAMPTZ,p_invoice_created_at);
    END IF;
  EXCEPTION WHEN invalid_datetime_format THEN
    RAISE EXCEPTION 'SALES_INVOICE_DATE_SOURCE_INVALID';
  END;
  IF v_source IS NULL THEN RAISE EXCEPTION 'SALES_INVOICE_DATE_SOURCE_REQUIRED'; END IF;
  RETURN (v_source AT TIME ZONE v_timezone)::DATE;
END
$$;

REVOKE ALL ON FUNCTION private.resolve_sales_invoice_display_date(
  JSONB,JSONB,TIMESTAMPTZ,TEXT) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.resolve_sales_invoice_display_date(
  JSONB,JSONB,TIMESTAMPTZ,TEXT) TO service_role;

CREATE OR REPLACE FUNCTION public.get_sales_documents()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_actor UUID:=auth.uid();
  v_order_permission JSONB;v_can_cancel BOOLEAN;v_timezone TEXT;
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'sales.sales_documents','VIEW');
  SELECT company.timezone INTO v_timezone FROM public.companies company
    WHERE company.id=v_company;
  v_order_permission:=private.acp_resolve_permission(
    v_company,v_actor,'sales.sales_orders');
  v_can_cancel:=(v_order_permission->'effectiveCapabilities') ? 'CANCEL_FINAL';
  RETURN jsonb_build_object('companyId',v_company,
    'effectiveOrderCapabilities',COALESCE(
      v_order_permission->'effectiveCapabilities','[]'::JSONB),
    'data',COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'salesId',invoice.sales_id,'invoiceSnapshotId',invoice.id,
      'invoiceNo',invoice.invoice_no,'snapshotProvenance',invoice.snapshot_provenance,
      'invoiceDate',private.resolve_sales_invoice_display_date(
        invoice.snapshot_payload,to_jsonb(sale),invoice.created_at,v_timezone),
      'postedAt',COALESCE(sale.posted_at,sale.confirmed_at,invoice.created_at),
      'total',sale.grand_total_after_rounding,'fulfillmentMode',sale.fulfillment_mode,
      'sourceChannel',sale.source_channel,
      'customerName',COALESCE(customer.name,'Walk-In Customer'),
      'storeName',COALESCE(store.store_name,'Store'),
      'invoiceStatus',CASE WHEN sale.order_runtime_status='CANCELED'
        OR sale.document_status='CANCELED' THEN 'CANCELED' ELSE 'ACTIVE' END,
      'orderRuntimeStatus',sale.order_runtime_status,
      'masterVersion',sale.master_version,'canceledAt',sale.canceled_at,
      'cancelReason',sale.cancel_reason,'canceledBy',sale.canceled_by,
      'canceledByName',cancel_actor.name,
      'canCancel',v_can_cancel AND sale.document_status='DRAFT'
        AND sale.order_runtime_status IN('CONFIRMED','RESERVED')
        AND reservation.status='OPEN' AND reservation.total_dispatched_base_qty=0
        AND NOT EXISTS(SELECT 1 FROM public.sales_payment_verification_requests request
          WHERE request.company_id=sale.company_id AND request.sales_id=sale.id
            AND (request.status='VERIFIED' OR (request.status='PENDING'
              AND request.settlement_route_snapshot='CASH_DRAWER'
              AND NOT EXISTS(SELECT 1 FROM public.cashier_sessions session
                WHERE session.company_id=request.company_id
                  AND session.status='OPEN'::public.session_status
                  AND (session.id=request.cashier_session_id OR
                    (session.cashier_id=v_actor AND session.store_id=request.store_id))))))
      ) ORDER BY invoice.created_at DESC,invoice.id)
    FROM (SELECT candidate.* FROM public.sales_invoice_snapshots candidate
      WHERE candidate.company_id=v_company
      ORDER BY candidate.created_at DESC,candidate.id LIMIT 500) invoice
    JOIN public.sales_headers sale ON sale.company_id=invoice.company_id
      AND sale.id=invoice.sales_id
    LEFT JOIN public.customers customer ON customer.company_id=sale.company_id
      AND customer.id=sale.customer_id
    LEFT JOIN public.stores store ON store.company_id=sale.company_id
      AND store.id=sale.store_id
    LEFT JOIN public.profiles cancel_actor ON cancel_actor.id=sale.canceled_by
    LEFT JOIN public.sales_stock_reservations reservation
      ON reservation.company_id=sale.company_id AND reservation.sales_id=sale.id
  ),'[]'::JSONB));
END
$$;

CREATE OR REPLACE FUNCTION public.get_sales_invoice_document(p_sales_id UUID)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_actor UUID:=auth.uid();
  v_result JSONB;v_invoice public.sales_invoice_snapshots%ROWTYPE;
  v_sale public.sales_headers%ROWTYPE;
  v_reservation public.sales_stock_reservations%ROWTYPE;v_cancel_name TEXT;
  v_permission JSONB;v_can_cancel BOOLEAN;v_timezone TEXT;
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'sales.sales_documents','VIEW');
  v_result:=private.acp5e_get_sales_invoice_document_core(p_sales_id);
  SELECT invoice.* INTO v_invoice FROM public.sales_invoice_snapshots invoice
    WHERE invoice.company_id=v_company AND invoice.sales_id=p_sales_id;
  SELECT sale.* INTO v_sale FROM public.sales_headers sale
    WHERE sale.company_id=v_company AND sale.id=p_sales_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'SALES_DOCUMENT_NOT_FOUND'; END IF;
  SELECT company.timezone INTO v_timezone FROM public.companies company
    WHERE company.id=v_company;
  SELECT reservation.* INTO v_reservation FROM public.sales_stock_reservations reservation
    WHERE reservation.company_id=v_company AND reservation.sales_id=p_sales_id;
  SELECT profile.name INTO v_cancel_name FROM public.profiles profile
    WHERE profile.id=v_sale.canceled_by;
  v_permission:=private.acp_resolve_permission(v_company,v_actor,'sales.sales_orders');
  v_can_cancel:=(v_permission->'effectiveCapabilities') ? 'CANCEL_FINAL'
    AND v_sale.document_status='DRAFT'
    AND v_sale.order_runtime_status IN('CONFIRMED','RESERVED')
    AND v_reservation.status='OPEN' AND v_reservation.total_dispatched_base_qty=0
    AND NOT EXISTS(SELECT 1 FROM public.sales_payment_verification_requests request
      WHERE request.company_id=v_company AND request.sales_id=p_sales_id
        AND (request.status='VERIFIED' OR (request.status='PENDING'
          AND request.settlement_route_snapshot='CASH_DRAWER'
          AND NOT EXISTS(SELECT 1 FROM public.cashier_sessions session
            WHERE session.company_id=request.company_id
              AND session.status='OPEN'::public.session_status
              AND (session.id=request.cashier_session_id OR
                (session.cashier_id=v_actor AND session.store_id=request.store_id))))));
  RETURN v_result||jsonb_build_object('invoiceSnapshotId',v_invoice.id,
    'invoiceDate',private.resolve_sales_invoice_display_date(
      v_invoice.snapshot_payload,to_jsonb(v_sale),v_invoice.created_at,v_timezone),
    'invoiceStatus',CASE WHEN v_sale.order_runtime_status='CANCELED'
      OR v_sale.document_status='CANCELED' THEN 'CANCELED' ELSE 'ACTIVE' END,
    'orderRuntimeStatus',v_sale.order_runtime_status,
    'masterVersion',v_sale.master_version,'canceledAt',v_sale.canceled_at,
    'cancelReason',v_sale.cancel_reason,'canceledBy',v_sale.canceled_by,
    'canceledByName',v_cancel_name,'canCancel',v_can_cancel);
END
$$;

CREATE OR REPLACE FUNCTION public.get_pos_sales_invoice_document(p_sales_id UUID)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_result JSONB;
  v_invoice public.sales_invoice_snapshots%ROWTYPE;
  v_sale public.sales_headers%ROWTYPE;v_timezone TEXT;
BEGIN
  IF NOT public.private_sales_document_visible(p_sales_id) THEN
    RAISE EXCEPTION 'SALES_DOCUMENT_NOT_FOUND';
  END IF;
  v_result:=private.acp5e_get_sales_invoice_document_core(p_sales_id);
  SELECT invoice.* INTO v_invoice FROM public.sales_invoice_snapshots invoice
    WHERE invoice.company_id=v_company AND invoice.sales_id=p_sales_id;
  SELECT sale.* INTO v_sale FROM public.sales_headers sale
    WHERE sale.company_id=v_company AND sale.id=p_sales_id;
  SELECT company.timezone INTO v_timezone FROM public.companies company
    WHERE company.id=v_company;
  RETURN v_result||jsonb_build_object('invoiceSnapshotId',v_invoice.id,
    'invoiceDate',private.resolve_sales_invoice_display_date(
      v_invoice.snapshot_payload,to_jsonb(v_sale),v_invoice.created_at,v_timezone));
END
$$;

CREATE OR REPLACE FUNCTION public.export_sales_documents(
  p_date_from DATE,p_date_to DATE
) RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp
SET statement_timeout='30s' AS $$
DECLARE v_company UUID:=public.private_active_company_id();
  v_company_row public.companies%ROWTYPE;
BEGIN
  IF p_date_from IS NULL OR p_date_to IS NULL OR p_date_from>p_date_to THEN
    RAISE EXCEPTION 'SALES_DOCUMENT_EXPORT_DATE_RANGE_INVALID';
  END IF;
  PERFORM private.acp_require_permission_capability(
    v_company,'sales.sales_documents','EXPORT');
  SELECT company.* INTO v_company_row
  FROM public.companies company WHERE company.id=v_company;

  RETURN (
    WITH invoice_base AS (
      SELECT invoice.id invoice_id,invoice.sales_id,invoice.invoice_no,
        invoice.snapshot_provenance,invoice.created_at,
        invoice.snapshot_payload payload,sale.document_status,
        sale.order_runtime_status,sale.source_channel,sale.fulfillment_mode,
        sale.is_tempo,sale.due_date,sale.grand_total_after_rounding,
        sale.delivery_fee_amount,sale.paid_amount,sale.sisa_piutang,
        sale.canceled_at,sale.cancel_reason,cancel_actor.name canceled_by_name,
        private.resolve_sales_invoice_display_date(invoice.snapshot_payload,
          to_jsonb(sale),invoice.created_at,v_company_row.timezone) invoice_date,
        COALESCE(NULLIF(invoice.snapshot_payload#>>'{customer,code}',''),customer.code,'') customer_code,
        COALESCE(NULLIF(invoice.snapshot_payload#>>'{customer,name}',''),customer.name,'Walk-In Customer') customer_name,
        COALESCE(NULLIF(invoice.snapshot_payload#>>'{store,name}',''),store.store_name,'Store') store_name
      FROM public.sales_invoice_snapshots invoice
      JOIN public.sales_headers sale ON sale.company_id=invoice.company_id
        AND sale.id=invoice.sales_id
      LEFT JOIN public.customers customer ON customer.company_id=sale.company_id
        AND customer.id=sale.customer_id
      LEFT JOIN public.stores store ON store.company_id=sale.company_id
        AND store.id=sale.store_id
      LEFT JOIN public.profiles cancel_actor ON cancel_actor.id=sale.canceled_by
      WHERE invoice.company_id=v_company
    ), scoped_invoice AS (
      SELECT * FROM invoice_base WHERE invoice_date BETWEEN p_date_from AND p_date_to
    ), invoice_rows AS (
      SELECT scoped.invoice_id,scoped.sales_id,scoped.invoice_no,scoped.invoice_date,
        CASE WHEN scoped.order_runtime_status='CANCELED'
          OR scoped.document_status='CANCELED' THEN 'CANCELED' ELSE 'ACTIVE' END invoice_status,
        scoped.customer_code,scoped.customer_name,scoped.store_name,
        scoped.source_channel,scoped.fulfillment_mode,
        COALESCE((scoped.payload->>'isTempo')::BOOLEAN,scoped.is_tempo,FALSE) is_tempo,
        COALESCE(NULLIF(scoped.payload->>'dueDate','')::TIMESTAMPTZ,scoped.due_date) due_date,
        COALESCE((scoped.payload#>>'{totals,subtotal}')::NUMERIC,0) subtotal,
        COALESCE((scoped.payload#>>'{totals,itemDiscount}')::NUMERIC,0) item_discount,
        COALESCE((scoped.payload#>>'{totals,orderDiscount}')::NUMERIC,0) order_discount,
        COALESCE((scoped.payload#>>'{totals,itemDiscount}')::NUMERIC,0)
          +COALESCE((scoped.payload#>>'{totals,orderDiscount}')::NUMERIC,0) total_discount,
        COALESCE((SELECT sum(COALESCE(NULLIF(line.value->>'taxAmount','')::NUMERIC,0))
          FROM jsonb_array_elements(COALESCE(scoped.payload->'lines','[]'::JSONB)) line),0) tax_total,
        COALESCE((scoped.payload#>>'{totals,deliveryFee}')::NUMERIC,
          scoped.delivery_fee_amount,0) delivery_fee,
        COALESCE((scoped.payload#>>'{totals,roundingAdjustment}')::NUMERIC,0) rounding_adjustment,
        COALESCE((scoped.payload#>>'{totals,grandTotal}')::NUMERIC,
          scoped.grand_total_after_rounding,0) grand_total,
        COALESCE((scoped.payload#>>'{totals,paidAmount}')::NUMERIC,scoped.paid_amount,0) paid_amount,
        COALESCE((scoped.payload#>>'{totals,receivable}')::NUMERIC,scoped.sisa_piutang,0) receivable,
        scoped.canceled_at,scoped.cancel_reason,scoped.canceled_by_name,
        scoped.snapshot_provenance,scoped.created_at
      FROM scoped_invoice scoped
    ), line_rows AS (
      SELECT scoped.invoice_id,scoped.invoice_no,scoped.invoice_date,
        scoped.customer_code,scoped.customer_name,element.ordinality::BIGINT line_no,
        COALESCE(element.value->>'sku','') sku,
        COALESCE(element.value->>'productName','') product_name,
        COALESCE(element.value->>'uomName','') uom_name,
        COALESCE(NULLIF(element.value->>'quantity','')::NUMERIC,0) quantity,
        COALESCE(NULLIF(element.value->>'factorToBase','')::NUMERIC,0) factor_to_base,
        COALESCE(NULLIF(element.value->>'quantityBase','')::NUMERIC,0) quantity_base,
        COALESCE(NULLIF(element.value->>'unitPrice','')::NUMERIC,0) unit_price,
        COALESCE(NULLIF(element.value->>'discount','')::NUMERIC,0) discount,
        COALESCE(element.value->>'taxCode','') tax_code,
        COALESCE(element.value->>'taxName','') tax_name,
        COALESCE(NULLIF(element.value->>'taxRatePercent','')::NUMERIC,0) tax_rate_percent,
        COALESCE(NULLIF(element.value->>'taxAmount','')::NUMERIC,0) tax_amount,
        COALESCE(NULLIF(element.value->>'lineTotal','')::NUMERIC,0) line_total
      FROM scoped_invoice scoped
      CROSS JOIN LATERAL jsonb_array_elements(COALESCE(scoped.payload->'lines','[]'::JSONB))
        WITH ORDINALITY AS element(value,ordinality)
    )
    SELECT jsonb_build_object(
      'companyId',v_company,'companyCode',v_company_row.company_code,
      'companyName',v_company_row.company_name,'dateFrom',p_date_from,
      'dateTo',p_date_to,'generatedAt',statement_timestamp(),
      'invoices',COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'invoiceId',row_data.invoice_id,'salesId',row_data.sales_id,
        'invoiceNo',row_data.invoice_no,'invoiceDate',row_data.invoice_date,
        'invoiceStatus',row_data.invoice_status,'customerCode',row_data.customer_code,
        'customerName',row_data.customer_name,'storeName',row_data.store_name,
        'sourceChannel',row_data.source_channel,'fulfillmentMode',row_data.fulfillment_mode,
        'isTempo',row_data.is_tempo,'dueDate',row_data.due_date,
        'subtotal',row_data.subtotal,'itemDiscount',row_data.item_discount,
        'orderDiscount',row_data.order_discount,'totalDiscount',row_data.total_discount,
        'taxTotal',row_data.tax_total,'deliveryFee',row_data.delivery_fee,
        'roundingAdjustment',row_data.rounding_adjustment,
        'grandTotal',row_data.grand_total,'paidAmount',row_data.paid_amount,
        'receivable',row_data.receivable,'canceledAt',row_data.canceled_at,
        'cancelReason',row_data.cancel_reason,'canceledByName',row_data.canceled_by_name,
        'snapshotProvenance',row_data.snapshot_provenance)
        ORDER BY row_data.invoice_date DESC,row_data.created_at DESC,row_data.invoice_id)
        FROM invoice_rows row_data),'[]'::JSONB),
      'lines',COALESCE((SELECT jsonb_agg(to_jsonb(row_data)
        ORDER BY row_data.invoice_date DESC,row_data.invoice_no,row_data.line_no)
        FROM line_rows row_data),'[]'::JSONB)
    )
  );
END
$$;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260907100000','sales_invoice_scheduled_date_read_fix',
  'Resolve Scheduled ORDER_DATE from planned_order_date consistently across Backoffice list/detail, POS print, and range export without mutating immutable Invoice snapshots or operational/Finance data');

NOTIFY pgrst,'reload schema';
COMMIT;
