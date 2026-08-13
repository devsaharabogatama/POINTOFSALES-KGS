-- ACP-5H: enforce Sales Return review/posting without widening Cashier scope.

BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260813040000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: ACP-5G required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260813050000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED';
  END IF;
  IF (SELECT count(*) FROM public.access_permission_catalog
    WHERE permission_key='sales.sales_returns'
      AND enforcement_status='SHADOW')<>1 THEN
    RAISE EXCEPTION 'SALES_RETURN_PERMISSION_NOT_SHADOW';
  END IF;
  IF to_regprocedure('public.list_returnable_sales(text,integer)') IS NULL
    OR to_regprocedure('public.post_sales_return(uuid,bigint,uuid)') IS NULL
    OR to_regprocedure('public.cancel_sales_return_draft(uuid,bigint,text)') IS NULL
    OR to_regprocedure('public.save_sales_return_draft_with_delivery_fee(uuid,bigint,uuid,uuid,text,text,jsonb,jsonb,boolean)') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Sales Return runtime incomplete';
  END IF;
END
$guard$;

CREATE FUNCTION public.get_sales_returns(
  p_status TEXT DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
  v_company UUID:=public.private_active_company_id();
  v_status TEXT:=NULLIF(upper(btrim(p_status)),'');
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'sales.sales_returns','VIEW');
  IF v_status IS NOT NULL AND v_status NOT IN('DRAFT','POSTED','CANCELED') THEN
    RAISE EXCEPTION 'SALES_RETURN_STATUS_INVALID';
  END IF;

  RETURN jsonb_build_object(
    'companyId',v_company,
    'data',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',document.id,'company_id',document.company_id,
      'return_no',document.return_no,'source_sales_id',document.source_sales_id,
      'source_invoice_no_snapshot',document.source_invoice_no_snapshot,
      'store_id',document.store_id,'source_session_id',document.source_session_id,
      'executing_session_id',document.executing_session_id,
      'customer_id',document.customer_id,'status',document.status,
      'approval_mode_snapshot',document.approval_mode_snapshot,
      'notes',document.notes,'refund_before_rounding',document.refund_before_rounding,
      'rounding_direction',document.rounding_direction,
      'rounding_adjustment',document.rounding_adjustment,
      'refund_total',document.refund_total,'master_version',document.master_version,
      'created_by',document.created_by,'created_at',document.created_at,
      'updated_at',document.updated_at,'posted_by',document.posted_by,
      'posted_at',document.posted_at,'canceled_by',document.canceled_by,
      'canceled_at',document.canceled_at,'cancel_reason',document.cancel_reason,
      'financial_event_id',document.financial_event_id,
      'source_delivery_fee_amount_snapshot',
        document.source_delivery_fee_amount_snapshot,
      'delivery_fee_refund_requested',document.delivery_fee_refund_requested,
      'delivery_fee_refund_amount',document.delivery_fee_refund_amount,
      'delivery_fee_refund_decided_by',document.delivery_fee_refund_decided_by,
      'delivery_fee_refund_decided_at',document.delivery_fee_refund_decided_at)
      ORDER BY document.created_at DESC,document.id DESC),'[]'::JSONB)
      FROM (SELECT candidate.* FROM public.sales_return_documents candidate
        WHERE candidate.company_id=v_company
          AND (v_status IS NULL OR candidate.status::TEXT=v_status)
        ORDER BY candidate.created_at DESC,candidate.id DESC LIMIT 500) document),
    'lines',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',line.id,'document_id',line.document_id,
      'source_sales_detail_id',line.source_sales_detail_id,
      'product_sku_snapshot',line.product_sku_snapshot,
      'product_name_snapshot',line.product_name_snapshot,
      'sale_uom_name_snapshot',line.sale_uom_name_snapshot,
      'quantity_uom',line.quantity_uom,'quantity_base',line.quantity_base,
      'return_condition',line.return_condition,
      'destination_warehouse_id',line.destination_warehouse_id,
      'refund_before_rounding',line.refund_before_rounding,
      'tax_refund_amount',line.tax_refund_amount,
      'fifo_cost_restored',line.fifo_cost_restored)
      ORDER BY line.product_name_snapshot,line.id),'[]'::JSONB)
      FROM public.sales_return_lines line
      WHERE line.company_id=v_company AND EXISTS(SELECT 1
        FROM public.sales_return_documents document
        WHERE document.company_id=v_company AND document.id=line.document_id
          AND (v_status IS NULL OR document.status::TEXT=v_status))),
    'refunds',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',refund.id,'document_id',refund.document_id,
      'payment_method_name_snapshot',refund.payment_method_name_snapshot,
      'payment_method_type_snapshot',refund.payment_method_type_snapshot,
      'amount',refund.amount,'transfer_destination',refund.transfer_destination,
      'transfer_reference',refund.transfer_reference,'proof_url',refund.proof_url)
      ORDER BY refund.created_at,refund.id),'[]'::JSONB)
      FROM public.sales_return_refunds refund
      WHERE refund.company_id=v_company AND EXISTS(SELECT 1
        FROM public.sales_return_documents document
        WHERE document.company_id=v_company AND document.id=refund.document_id
          AND (v_status IS NULL OR document.status::TEXT=v_status))),
    'customers',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',customer.id,'name',customer.name) ORDER BY customer.name,customer.id),
      '[]'::JSONB) FROM public.customers customer
      WHERE customer.company_id=v_company AND EXISTS(SELECT 1
        FROM public.sales_return_documents document
        WHERE document.company_id=v_company AND document.customer_id=customer.id
          AND (v_status IS NULL OR document.status::TEXT=v_status))),
    'stores',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',store.id,'store_name',store.store_name)
      ORDER BY store.store_name,store.id),'[]'::JSONB) FROM public.stores store
      WHERE store.company_id=v_company AND EXISTS(SELECT 1
        FROM public.sales_return_documents document
        WHERE document.company_id=v_company AND document.store_id=store.id
          AND (v_status IS NULL OR document.status::TEXT=v_status))),
    'sessions',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',session.id,'session_code',session.session_code,
      'status',session.status) ORDER BY session.session_code,session.id),
      '[]'::JSONB) FROM public.cashier_sessions session
      WHERE session.company_id=v_company AND EXISTS(SELECT 1
        FROM public.sales_return_documents document
        WHERE document.company_id=v_company
          AND (document.source_session_id=session.id
            OR document.executing_session_id=session.id)
          AND (v_status IS NULL OR document.status::TEXT=v_status))),
    'actors',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',profile.id,'name',profile.name) ORDER BY profile.name,profile.id),
      '[]'::JSONB) FROM public.profiles profile WHERE EXISTS(SELECT 1
        FROM public.sales_return_documents document
        WHERE document.company_id=v_company
          AND profile.id IN(document.created_by,document.posted_by,
            document.canceled_by,document.delivery_fee_refund_decided_by)
          AND (v_status IS NULL OR document.status::TEXT=v_status))),
    'warehouses',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',warehouse.id,'name',warehouse.name,
      'warehouse_type',warehouse.warehouse_type)
      ORDER BY warehouse.name,warehouse.id),'[]'::JSONB)
      FROM public.warehouses warehouse WHERE warehouse.company_id=v_company
        AND EXISTS(SELECT 1 FROM public.sales_return_lines line
          JOIN public.sales_return_documents document
            ON document.company_id=line.company_id
           AND document.id=line.document_id
          WHERE line.company_id=v_company
            AND line.destination_warehouse_id=warehouse.id
            AND (v_status IS NULL OR document.status::TEXT=v_status))));
END
$$;

CREATE FUNCTION public.get_pos_returnable_sales(
  p_search TEXT DEFAULT NULL,p_limit INTEGER DEFAULT 50
) RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
  v_company UUID:=public.private_active_company_id();
  v_payload JSONB;v_sale JSONB;v_line JSONB;
  v_sales JSONB:='[]'::JSONB;v_lines JSONB;
  v_sale_id UUID;v_detail_id UUID;
  v_prior NUMERIC(20,4);v_delivery NUMERIC(20,4);
  v_delivery_refunded NUMERIC(20,4);v_line_amount NUMERIC(20,4);
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.cashier_sessions session
    WHERE session.company_id=v_company AND session.cashier_id=auth.uid()
      AND session.status='OPEN'::public.session_status) THEN
    RAISE EXCEPTION 'OPEN_CASHIER_SESSION_REQUIRED';
  END IF;
  WITH candidates AS (
    SELECT sale.id,sale.invoice_no,sale.transaction_date,sale.store_id,
      sale.customer_id,sale.grand_total_after_rounding,
      COALESCE(jsonb_agg(jsonb_build_object(
        'sourceSalesDetailId',detail.id,'productId',detail.product_id,
        'productName',detail.product_name_snapshot,
        'uomName',detail.sale_uom_name_snapshot,'soldQuantity',detail.qty,
        'returnedQuantity',COALESCE(returned.quantity,0),
        'remainingQuantity',detail.qty-COALESCE(returned.quantity,0))
        ORDER BY detail.id) FILTER(WHERE detail.qty>COALESCE(returned.quantity,0)),
        '[]'::JSONB) lines
    FROM public.sales_headers sale
    JOIN public.sales_details detail ON detail.company_id=sale.company_id
      AND detail.sales_id=sale.id
    LEFT JOIN LATERAL(SELECT COALESCE(sum(line.quantity_uom),0) quantity
      FROM public.sales_return_lines line
      JOIN public.sales_return_documents document
        ON document.company_id=line.company_id AND document.id=line.document_id
       AND document.status='POSTED'
      WHERE line.company_id=detail.company_id
        AND line.source_sales_detail_id=detail.id) returned ON TRUE
    WHERE sale.company_id=v_company AND sale.document_status='POSTED'
      AND EXISTS(SELECT 1 FROM public.cashier_sessions session
        WHERE session.company_id=v_company AND session.cashier_id=auth.uid()
          AND session.store_id=sale.store_id
          AND session.status='OPEN'::public.session_status)
      AND (NULLIF(btrim(p_search),'') IS NULL
        OR sale.invoice_no ILIKE '%'||btrim(p_search)||'%')
    GROUP BY sale.id,sale.invoice_no,sale.transaction_date,sale.store_id,
      sale.customer_id,sale.grand_total_after_rounding
    HAVING bool_or(detail.qty>COALESCE(returned.quantity,0))
    ORDER BY sale.transaction_date DESC,sale.id DESC
    LIMIT LEAST(GREATEST(COALESCE(p_limit,50),1),100)
  ) SELECT jsonb_build_object('sales',COALESCE(jsonb_agg(to_jsonb(candidates)),
      '[]'::JSONB)) INTO v_payload FROM candidates;
  FOR v_sale IN SELECT value FROM jsonb_array_elements(
      COALESCE(v_payload->'sales','[]'::JSONB)) LOOP
    v_sale_id:=(v_sale->>'id')::UUID;
    SELECT COALESCE(sum(document.refund_total),0),
      COALESCE(sum(document.delivery_fee_refund_amount),0)
      INTO v_prior,v_delivery_refunded
    FROM public.sales_return_documents document
    WHERE document.company_id=v_company AND document.source_sales_id=v_sale_id
      AND document.status='POSTED';
    SELECT COALESCE(header.delivery_fee_amount,0) INTO v_delivery
    FROM public.sales_headers header
    WHERE header.company_id=v_company AND header.id=v_sale_id;
    v_lines:='[]'::JSONB;
    FOR v_line IN SELECT value FROM jsonb_array_elements(
        COALESCE(v_sale->'lines','[]'::JSONB)) LOOP
      v_detail_id:=(v_line->>'sourceSalesDetailId')::UUID;
      SELECT COALESCE(detail.line_total,0)
        +COALESCE(detail.allocated_document_rounding,0)
        INTO v_line_amount FROM public.sales_details detail
      WHERE detail.company_id=v_company AND detail.id=v_detail_id;
      v_lines:=v_lines||jsonb_build_array(v_line||jsonb_build_object(
        'refundableLineAmount',COALESCE(v_line_amount,0)));
    END LOOP;
    v_sales:=v_sales||jsonb_build_array(
      (v_sale-'lines')||jsonb_build_object('lines',v_lines,
        'priorRefundTotal',COALESCE(v_prior,0),
        'deliveryFeeAmount',COALESCE(v_delivery,0),
        'deliveryFeeRefunded',COALESCE(v_delivery_refunded,0)));
  END LOOP;
  RETURN jsonb_build_object('companyId',v_company,'sales',v_sales,
    'damagedWarehouses',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',warehouse.id,'name',warehouse.name) ORDER BY warehouse.name,
      warehouse.id),'[]'::JSONB) FROM public.warehouses warehouse
      WHERE warehouse.company_id=v_company AND warehouse.is_active
        AND warehouse.warehouse_type='DAMAGED'));
END
$$;

ALTER FUNCTION public.post_sales_return(UUID,BIGINT,UUID)
  RENAME TO acp5h_post_sales_return_core;
ALTER FUNCTION public.acp5h_post_sales_return_core(UUID,BIGINT,UUID)
  SET SCHEMA private;
CREATE FUNCTION public.post_sales_return(
  p_document_id UUID,p_master_version BIGINT,p_idempotency_key UUID
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'sales.sales_returns','POST');
  RETURN private.acp5h_post_sales_return_core(
    p_document_id,p_master_version,p_idempotency_key);
END
$$;

ALTER FUNCTION public.cancel_sales_return_draft(UUID,BIGINT,TEXT)
  RENAME TO acp5h_cancel_sales_return_draft_core;
ALTER FUNCTION public.acp5h_cancel_sales_return_draft_core(UUID,BIGINT,TEXT)
  SET SCHEMA private;
CREATE FUNCTION public.cancel_sales_return_draft(
  p_document_id UUID,p_master_version BIGINT,p_reason TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'sales.sales_returns','CANCEL_FINAL');
  RETURN private.acp5h_cancel_sales_return_draft_core(
    p_document_id,p_master_version,p_reason);
END
$$;

DO $enforce$
DECLARE v_rows BIGINT;
BEGIN
  UPDATE public.access_permission_catalog SET
    enforcement_status='ENFORCED',catalog_version=catalog_version+1,
    updated_at=clock_timestamp()
  WHERE permission_key='sales.sales_returns' AND enforcement_status='SHADOW';
  GET DIAGNOSTICS v_rows=ROW_COUNT;
  IF v_rows<>1 THEN RAISE EXCEPTION 'SALES_RETURN_PERMISSION_CUTOVER_FAILED'; END IF;
END
$enforce$;

REVOKE SELECT ON public.sales_return_audit,public.sales_return_documents,
  public.sales_return_fifo_restorations,public.sales_return_lines,
  public.sales_return_refunds FROM authenticated;

REVOKE ALL ON FUNCTION private.acp5h_post_sales_return_core(UUID,BIGINT,UUID),
  private.acp5h_cancel_sales_return_draft_core(UUID,BIGINT,TEXT)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.acp5h_post_sales_return_core(UUID,BIGINT,UUID),
  private.acp5h_cancel_sales_return_draft_core(UUID,BIGINT,TEXT)
TO service_role;

REVOKE ALL ON FUNCTION public.get_sales_returns(TEXT),
  public.get_pos_returnable_sales(TEXT,INTEGER),
  public.post_sales_return(UUID,BIGINT,UUID),
  public.cancel_sales_return_draft(UUID,BIGINT,TEXT) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_sales_returns(TEXT),
  public.get_pos_returnable_sales(TEXT,INTEGER),
  public.post_sales_return(UUID,BIGINT,UUID),
  public.cancel_sales_return_draft(UUID,BIGINT,TEXT)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260813050000','acp_phase5h_sales_return_permission_enforcement',
  'Enforced Backoffice Sales Return VIEW/POST/CANCEL with independent open-session Cashier source and Draft authority');

COMMIT;
