BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260918160000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: 20260918160000 required';
  END IF;
  IF to_regprocedure('public.get_sales_return_commercial_adjustments()') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: sales return commercial adjustment read model collision';
  END IF;
END
$guard$;

CREATE FUNCTION public.get_sales_return_commercial_adjustments()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='8s' AS $$
DECLARE
  v_company uuid:=public.private_active_company_id();
  v_actor uuid:=auth.uid();
  v_retail_permission jsonb;
  v_backoffice_permission jsonb;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF NOT public.private_request_company_matches(v_company) THEN
    RAISE EXCEPTION 'ACTIVE_COMPANY_CONTEXT_MISMATCH';
  END IF;
  v_retail_permission:=private.acp_resolve_permission(
    v_company,v_actor,'sales.sales_documents');
  v_backoffice_permission:=private.acp_resolve_permission(
    v_company,v_actor,'sales.backoffice_orders');
  IF (v_retail_permission->>'enforced')::boolean
      AND NOT ((v_retail_permission->'effectiveCapabilities') ? 'VIEW')
    AND (v_backoffice_permission->>'enforced')::boolean
      AND NOT ((v_backoffice_permission->'effectiveCapabilities') ? 'VIEW') THEN
    RAISE EXCEPTION 'CUSTOM_PERMISSION_DENIED';
  END IF;

  RETURN jsonb_build_object('companyId',v_company,'data',COALESCE((
    WITH received AS (
      SELECT document.source_kind,
        CASE WHEN document.source_kind='BACKOFFICE'
          THEN document.sales_order_id ELSE document.retail_sales_id END source_id,
        CASE WHEN document.source_kind='BACKOFFICE'
          THEN return_line.sales_order_line_id ELSE return_line.retail_sales_detail_id END source_line_id,
        max(return_line.product_code_snapshot) product_code,
        max(return_line.product_name_snapshot) product_name,
        max(return_line.uom_code_snapshot) uom_code,
        max(return_line.uom_name_snapshot) uom_name,
        max(return_line.base_qty_per_uom) base_qty_per_uom,
        sum(receipt_line.received_base_qty) received_base_qty,
        sum(receipt_line.received_base_qty) FILTER(
          WHERE receipt_line.disposition='RESTOCK') restocked_base_qty,
        sum(receipt_line.received_base_qty) FILTER(
          WHERE receipt_line.disposition='DESTROY') destroyed_base_qty
      FROM public.backoffice_sales_returns document
      JOIN public.backoffice_sales_return_lines return_line
        ON return_line.company_id=document.company_id
       AND return_line.return_id=document.id
      JOIN public.backoffice_sales_return_receipt_lines receipt_line
        ON receipt_line.company_id=return_line.company_id
       AND receipt_line.return_line_id=return_line.id
      WHERE document.company_id=v_company AND document.status<>'CANCELED'
      GROUP BY document.source_kind,
        CASE WHEN document.source_kind='BACKOFFICE'
          THEN document.sales_order_id ELSE document.retail_sales_id END,
        CASE WHEN document.source_kind='BACKOFFICE'
          THEN return_line.sales_order_line_id ELSE return_line.retail_sales_detail_id END
    ), credited_line AS (
      SELECT note.source_kind,
        CASE WHEN note.source_kind='BACKOFFICE'
          THEN invoice.sales_order_id ELSE note.source_retail_sales_id END source_id,
        CASE WHEN note.source_kind='BACKOFFICE'
          THEN line.sales_order_line_id ELSE line.source_retail_sales_detail_id END source_line_id,
        sum(line.quantity_base) credited_base_qty,
        round(sum(line.line_amount+line.tax_amount),4) credited_amount
      FROM public.backoffice_sales_credit_notes note
      JOIN public.backoffice_sales_credit_note_lines line
        ON line.company_id=note.company_id AND line.credit_note_id=note.id
      LEFT JOIN public.backoffice_sales_invoices invoice
        ON invoice.company_id=note.company_id AND invoice.id=note.source_invoice_id
      WHERE note.company_id=v_company AND note.status='POSTED'
      GROUP BY note.source_kind,
        CASE WHEN note.source_kind='BACKOFFICE'
          THEN invoice.sales_order_id ELSE note.source_retail_sales_id END,
        CASE WHEN note.source_kind='BACKOFFICE'
          THEN line.sales_order_line_id ELSE line.source_retail_sales_detail_id END
    ), credited_header AS (
      SELECT note.source_kind,
        CASE WHEN note.source_kind='BACKOFFICE'
          THEN invoice.sales_order_id ELSE note.source_retail_sales_id END source_id,
        round(sum(note.grand_total),4) credited_amount
      FROM public.backoffice_sales_credit_notes note
      LEFT JOIN public.backoffice_sales_invoices invoice
        ON invoice.company_id=note.company_id AND invoice.id=note.source_invoice_id
      WHERE note.company_id=v_company AND note.status='POSTED'
      GROUP BY note.source_kind,
        CASE WHEN note.source_kind='BACKOFFICE'
          THEN invoice.sales_order_id ELSE note.source_retail_sales_id END
    ), line_keys AS (
      SELECT source_kind,source_id,source_line_id FROM received
      UNION
      SELECT source_kind,source_id,source_line_id FROM credited_line
    ), line_payload AS (
      SELECT key.source_kind,key.source_id,key.source_line_id,
        jsonb_build_object(
          'sourceLineId',key.source_line_id,
          'productCode',received.product_code,
          'productName',received.product_name,
          'uomCode',received.uom_code,
          'uomName',received.uom_name,
          'baseQtyPerUom',COALESCE(received.base_qty_per_uom,1),
          'fulfilledBaseQty',CASE WHEN key.source_kind='BACKOFFICE'
            THEN COALESCE(office_source.accepted_base_qty,0)
            ELSE COALESCE(retail_source.quantity_base,0) END,
          'fulfilledQtyUom',round((CASE WHEN key.source_kind='BACKOFFICE'
            THEN COALESCE(office_source.accepted_base_qty,0)
            ELSE COALESCE(retail_source.quantity_base,0) END)
            /NULLIF(COALESCE(received.base_qty_per_uom,
              office_source.base_qty_per_uom,retail_source.uom_factor_to_base_snapshot,1),0),6),
          'receivedBaseQty',COALESCE(received.received_base_qty,0),
          'receivedQtyUom',round(COALESCE(received.received_base_qty,0)
            /NULLIF(COALESCE(received.base_qty_per_uom,1),0),6),
          'restockedBaseQty',COALESCE(received.restocked_base_qty,0),
          'destroyedBaseQty',COALESCE(received.destroyed_base_qty,0),
          'creditedBaseQty',COALESCE(credited_line.credited_base_qty,0),
          'creditedAmount',COALESCE(credited_line.credited_amount,0)
        ) payload
      FROM line_keys key
      LEFT JOIN received USING(source_kind,source_id,source_line_id)
      LEFT JOIN credited_line USING(source_kind,source_id,source_line_id)
      LEFT JOIN public.backoffice_sales_order_lines office_source
        ON key.source_kind='BACKOFFICE' AND office_source.company_id=v_company
       AND office_source.id=key.source_line_id
      LEFT JOIN public.sales_details retail_source
        ON key.source_kind='RETAINED_RETAIL' AND retail_source.company_id=v_company
       AND retail_source.id=key.source_line_id
    ), sources AS (
      SELECT source_kind,source_id FROM line_keys
      UNION
      SELECT source_kind,source_id FROM credited_header
    )
    SELECT jsonb_agg(jsonb_build_object(
      'sourceKind',source.source_kind,'sourceId',source.source_id,
      'receivedBaseQty',COALESCE((SELECT sum((line.payload->>'receivedBaseQty')::numeric)
        FROM line_payload line WHERE line.source_kind=source.source_kind
          AND line.source_id=source.source_id),0),
      'restockedBaseQty',COALESCE((SELECT sum((line.payload->>'restockedBaseQty')::numeric)
        FROM line_payload line WHERE line.source_kind=source.source_kind
          AND line.source_id=source.source_id),0),
      'destroyedBaseQty',COALESCE((SELECT sum((line.payload->>'destroyedBaseQty')::numeric)
        FROM line_payload line WHERE line.source_kind=source.source_kind
          AND line.source_id=source.source_id),0),
      'creditedAmount',COALESCE(header.credited_amount,0),
      'lines',COALESCE((SELECT jsonb_agg(line.payload ORDER BY line.source_line_id)
        FROM line_payload line WHERE line.source_kind=source.source_kind
          AND line.source_id=source.source_id),'[]'::jsonb)
    ) ORDER BY source.source_kind,source.source_id)
    FROM sources source
    LEFT JOIN credited_header header USING(source_kind,source_id)
  ),'[]'::jsonb));
END
$$;

REVOKE ALL ON FUNCTION public.get_sales_return_commercial_adjustments()
  FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_sales_return_commercial_adjustments()
  TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260919100000','sales_return_net_commercial_read_model',
  'Read-only returned quantity, disposition, posted Credit Note and net-commercial presentation for immutable Retail and Backoffice sources');

NOTIFY pgrst,'reload schema';
COMMIT;
