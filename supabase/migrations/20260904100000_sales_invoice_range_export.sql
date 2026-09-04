BEGIN;

DO $migration$
BEGIN
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260904100000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260830110000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: sales document cancellation/export runtime required';
  END IF;
  IF to_regprocedure('public.export_sales_documents()') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: compatible sales document export RPC required';
  END IF;
END
$migration$;

-- The no-argument RPC remains available for older clients. This overload is
-- the bounded export used by Global Data Exchange.
CREATE OR REPLACE FUNCTION public.export_sales_documents(p_date_from DATE,p_date_to DATE)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp
SET statement_timeout='30s' AS $$
DECLARE v_company UUID:=public.private_active_company_id();
  v_company_row public.companies%ROWTYPE;
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'sales.sales_documents','EXPORT');
  IF p_date_from IS NULL OR p_date_to IS NULL THEN
    RAISE EXCEPTION 'SALES_DOCUMENT_EXPORT_DATE_RANGE_REQUIRED';
  END IF;
  IF p_date_from>p_date_to THEN
    RAISE EXCEPTION 'SALES_DOCUMENT_EXPORT_DATE_RANGE_INVALID';
  END IF;
  SELECT company.* INTO STRICT v_company_row
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
        CASE
          WHEN COALESCE(invoice.snapshot_payload#>>'{branding,invoiceDateDisplayMode}',
            'ORDER_DATE')='POSTED_DATE' THEN
            (COALESCE(NULLIF(invoice.snapshot_payload->>'postedAt','')::TIMESTAMPTZ,
              sale.posted_at,sale.confirmed_at,invoice.created_at)
              AT TIME ZONE COALESCE(NULLIF(invoice.snapshot_payload#>>'{company,timezone}',''),
                v_company_row.timezone,'Asia/Jakarta'))::DATE
          ELSE
            (COALESCE(NULLIF(invoice.snapshot_payload->>'transactionAt','')::TIMESTAMPTZ,
              sale.transaction_date,invoice.created_at)
              AT TIME ZONE COALESCE(NULLIF(invoice.snapshot_payload#>>'{company,timezone}',''),
                v_company_row.timezone,'Asia/Jakarta'))::DATE
        END invoice_date,
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
        COALESCE(NULLIF(scoped.payload->>'dueDate',''),scoped.due_date::TEXT) due_date,
        COALESCE((scoped.payload#>>'{totals,subtotal}')::NUMERIC,0) subtotal,
        COALESCE((scoped.payload#>>'{totals,itemDiscount}')::NUMERIC,0) item_discount,
        COALESCE((scoped.payload#>>'{totals,orderDiscount}')::NUMERIC,0) order_discount,
        COALESCE((SELECT sum(COALESCE(NULLIF(item->>'taxAmount','')::NUMERIC,0))
          FROM jsonb_array_elements(CASE WHEN jsonb_typeof(scoped.payload->'lines')='array'
            THEN scoped.payload->'lines' ELSE '[]'::JSONB END) item),0) tax_total,
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
      CROSS JOIN LATERAL jsonb_array_elements(
        CASE WHEN jsonb_typeof(scoped.payload->'lines')='array'
          THEN scoped.payload->'lines' ELSE '[]'::JSONB END)
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
        'orderDiscount',row_data.order_discount,
        'totalDiscount',row_data.item_discount+row_data.order_discount,
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

REVOKE ALL ON FUNCTION public.export_sales_documents(DATE,DATE) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.export_sales_documents(DATE,DATE)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260904100000','sales_invoice_range_export',
  'Additive guarded date-range Invoice workbook payload; immutable snapshot lines and no-argument export compatibility preserved');

NOTIFY pgrst,'reload schema';
COMMIT;
