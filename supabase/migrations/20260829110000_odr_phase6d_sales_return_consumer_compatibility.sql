BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260828280000')
    OR NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260828230000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: ODR invoice and Dispatch runtime required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260829110000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED';
  END IF;
END
$guard$;

CREATE FUNCTION private.odr6d_returnable_sales_detail_quantity(
  p_company_id UUID,p_sales_detail_id UUID
) RETURNS NUMERIC LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
  SELECT CASE
    WHEN sale.document_status='POSTED' THEN detail.qty
    ELSE detail.qty*LEAST(GREATEST(COALESCE((
      SELECT min(COALESCE((SELECT sum(allocation.dispatched_base_qty)
          FROM public.sales_dispatch_allocations allocation
          WHERE allocation.company_id=reservation_line.company_id
            AND allocation.reservation_line_id=reservation_line.id),0)/
        NULLIF(reservation_line.reserved_base_qty,0))
      FROM public.sales_stock_reservation_lines reservation_line
      WHERE reservation_line.company_id=detail.company_id
        AND reservation_line.sales_detail_id=detail.id
    ),0),0),1)
  END
  FROM public.sales_details detail
  JOIN public.sales_headers sale ON sale.company_id=detail.company_id
    AND sale.id=detail.sales_id
  WHERE detail.company_id=p_company_id AND detail.id=p_sales_detail_id;
$$;

CREATE FUNCTION private.odr6d_sales_return_source_eligible(
  p_company_id UUID,p_sales_id UUID
) RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
  SELECT COALESCE((SELECT sale.document_status='POSTED' OR EXISTS(
      SELECT 1 FROM public.sales_dispatch_allocations allocation
      JOIN public.sales_stock_reservation_lines reservation_line
        ON reservation_line.company_id=allocation.company_id
       AND reservation_line.id=allocation.reservation_line_id
      WHERE allocation.company_id=sale.company_id
        AND reservation_line.sales_id=sale.id)
    FROM public.sales_headers sale
    WHERE sale.company_id=p_company_id AND sale.id=p_sales_id),FALSE);
$$;

-- Patch only the reviewed predicates in the retained legacy-compatible cores.
-- Every replacement is count-guarded so an unexpected upstream definition aborts
-- the whole transaction instead of installing a partial cutover.
DO $patch$
DECLARE v_definition TEXT;v_before TEXT;
BEGIN
  SELECT pg_get_functiondef(
    'private.save_sales_return_draft_sld_r4(uuid,bigint,uuid,uuid,text,text,jsonb,jsonb,boolean)'::regprocedure)
    INTO v_definition;
  v_before:=v_definition;
  v_definition:=replace(v_definition,
    'AND sale.document_status=''POSTED'';',
    'AND private.odr6d_sales_return_source_eligible(v_company,sale.id);');
  v_definition:=replace(v_definition,
    'detail.qty-COALESCE((',
    'private.odr6d_returnable_sales_detail_quantity(v_company,detail.id)-COALESCE((');
  IF v_definition=v_before OR v_definition NOT LIKE '%odr6d_returnable_sales_detail_quantity%' THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Sales Return fee wrapper definition changed';
  END IF;
  EXECUTE v_definition;

  SELECT pg_get_functiondef(
    'private.trg_sld_r4_validate_delivery_fee_refund_post()'::regprocedure)
    INTO v_definition;
  v_before:=v_definition;
  v_definition:=replace(v_definition,
    'SELECT detail.id,detail.qty,',
    'SELECT detail.id,private.odr6d_returnable_sales_detail_quantity(
          detail.company_id,detail.id) qty,');
  IF v_definition=v_before OR v_definition NOT LIKE '%odr6d_returnable_sales_detail_quantity%' THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Delivery-fee Return guard definition changed';
  END IF;
  EXECUTE v_definition;

  SELECT pg_get_functiondef(
    'private.save_sales_return_draft_sld_r4_core(uuid,bigint,uuid,uuid,text,text,jsonb,jsonb)'::regprocedure)
    INTO v_definition;
  v_before:=v_definition;
  v_definition:=replace(v_definition,
    'AND document_status = ''POSTED'';',
    'AND private.odr6d_sales_return_source_eligible(v_company,id);');
  v_definition:=replace(v_definition,
    'IF v_prior_quantity + v_quantity > v_detail.qty THEN',
    'IF v_prior_quantity + v_quantity > private.odr6d_returnable_sales_detail_quantity(v_company,v_detail.id) THEN');
  v_definition:=replace(v_definition,
    'AND detail.qty > COALESCE((',
    'AND private.odr6d_returnable_sales_detail_quantity(v_company,detail.id) > COALESCE((');
  IF v_definition=v_before OR v_definition NOT LIKE '%odr6d_returnable_sales_detail_quantity%' THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Sales Return Draft core definition changed';
  END IF;
  EXECUTE v_definition;

  SELECT pg_get_functiondef(
    'private.acp5h_post_sales_return_core(uuid,bigint,uuid)'::regprocedure)
    INTO v_definition;
  v_before:=v_definition;
  v_definition:=replace(v_definition,
    'AND document_status=''POSTED'' FOR UPDATE;',
    'AND (document_status=''POSTED'' OR EXISTS(SELECT 1
        FROM public.sales_dispatch_allocations dispatch_allocation
        JOIN public.sales_stock_reservation_lines dispatch_reservation_line
          ON dispatch_reservation_line.company_id=dispatch_allocation.company_id
         AND dispatch_reservation_line.id=dispatch_allocation.reservation_line_id
        WHERE dispatch_allocation.company_id=v_company
          AND dispatch_reservation_line.sales_id=public.sales_headers.id)) FOR UPDATE;');
  v_definition:=replace(v_definition,
    'SELECT qty FROM public.sales_details
            WHERE company_id=v_company AND id=v_line.source_sales_detail_id',
    'SELECT private.odr6d_returnable_sales_detail_quantity(v_company,v_line.source_sales_detail_id)');
  IF v_definition=v_before OR v_definition NOT LIKE '%sales_dispatch_allocations%' OR
     v_definition NOT LIKE '%odr6d_returnable_sales_detail_quantity%' THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Sales Return Post core definition changed';
  END IF;
  EXECUTE v_definition;
END
$patch$;

CREATE OR REPLACE FUNCTION public.get_pos_returnable_sales(
  p_search TEXT DEFAULT NULL,p_limit INTEGER DEFAULT 50
) RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.cashier_sessions session
    WHERE session.company_id=v_company AND session.cashier_id=auth.uid()
      AND session.status='OPEN'::public.session_status) THEN
    RAISE EXCEPTION 'OPEN_CASHIER_SESSION_REQUIRED';
  END IF;
  RETURN (WITH candidates AS (
    SELECT sale.id,sale.invoice_no,sale.transaction_date,sale.store_id,
      sale.customer_id,sale.grand_total_after_rounding,
      COALESCE(jsonb_agg(jsonb_build_object(
        'sourceSalesDetailId',detail.id,'productId',detail.product_id,
        'productName',detail.product_name_snapshot,
        'uomName',detail.sale_uom_name_snapshot,
        'soldQuantity',private.odr6d_returnable_sales_detail_quantity(
          detail.company_id,detail.id),
        'returnedQuantity',COALESCE(returned.quantity,0),
        'remainingQuantity',private.odr6d_returnable_sales_detail_quantity(
          detail.company_id,detail.id)-COALESCE(returned.quantity,0),
        'refundableLineAmount',round((detail.line_total+
          detail.allocated_document_rounding)*
          private.odr6d_returnable_sales_detail_quantity(detail.company_id,detail.id)/
          NULLIF(detail.qty,0),4)) ORDER BY detail.id)
        FILTER(WHERE private.odr6d_returnable_sales_detail_quantity(
          detail.company_id,detail.id)>COALESCE(returned.quantity,0)),'[]'::JSONB) lines
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
    WHERE sale.company_id=v_company
      AND (sale.document_status='POSTED' OR EXISTS(
        SELECT 1 FROM public.sales_dispatch_allocations allocation
        JOIN public.sales_stock_reservation_lines reservation_line
          ON reservation_line.company_id=allocation.company_id
         AND reservation_line.id=allocation.reservation_line_id
        WHERE allocation.company_id=sale.company_id
          AND reservation_line.sales_id=sale.id))
      AND EXISTS(SELECT 1 FROM public.cashier_sessions session
        WHERE session.company_id=v_company AND session.cashier_id=auth.uid()
          AND session.store_id=sale.store_id AND session.status='OPEN'::public.session_status)
      AND (NULLIF(btrim(p_search),'') IS NULL OR sale.invoice_no ILIKE
        '%'||btrim(p_search)||'%')
    GROUP BY sale.id,sale.invoice_no,sale.transaction_date,sale.store_id,
      sale.customer_id,sale.grand_total_after_rounding
    HAVING bool_or(private.odr6d_returnable_sales_detail_quantity(
      detail.company_id,detail.id)>COALESCE(returned.quantity,0))
    ORDER BY sale.transaction_date DESC,sale.id DESC
    LIMIT LEAST(GREATEST(COALESCE(p_limit,50),1),100)
  ) SELECT jsonb_build_object('companyId',v_company,
      'sales',COALESCE(jsonb_agg(to_jsonb(candidates)),'[]'::JSONB),
      'damagedWarehouses',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'id',warehouse.id,'name',warehouse.name) ORDER BY warehouse.name,
        warehouse.id),'[]'::JSONB) FROM public.warehouses warehouse
        WHERE warehouse.company_id=v_company AND warehouse.is_active
          AND warehouse.warehouse_type='DAMAGED')) FROM candidates);
END
$$;

CREATE OR REPLACE FUNCTION public.save_sales_return_draft(
  p_document_id UUID,p_master_version BIGINT,p_source_sales_id UUID,
  p_executing_session_id UUID,p_rounding_direction TEXT,p_notes TEXT,
  p_lines JSONB,p_refunds JSONB
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
  PERFORM 1 FROM public.sales_dispatch_allocations allocation
    JOIN public.sales_stock_reservation_lines reservation_line
      ON reservation_line.company_id=allocation.company_id
     AND reservation_line.id=allocation.reservation_line_id
    WHERE reservation_line.sales_id=p_source_sales_id LIMIT 1;
  RETURN private.save_sales_return_draft_sld_r4(p_document_id,p_master_version,
    p_source_sales_id,p_executing_session_id,p_rounding_direction,p_notes,
    p_lines,p_refunds,FALSE);
END
$$;

CREATE OR REPLACE FUNCTION public.save_sales_return_draft_with_delivery_fee(
  p_document_id UUID,p_master_version BIGINT,p_source_sales_id UUID,
  p_executing_session_id UUID,p_rounding_direction TEXT,p_notes TEXT,
  p_lines JSONB,p_refunds JSONB,p_refund_delivery_fee BOOLEAN
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
  PERFORM 1 FROM public.sales_dispatch_allocations allocation
    JOIN public.sales_stock_reservation_lines reservation_line
      ON reservation_line.company_id=allocation.company_id
     AND reservation_line.id=allocation.reservation_line_id
    WHERE reservation_line.sales_id=p_source_sales_id LIMIT 1;
  RETURN private.save_sales_return_draft_sld_r4(p_document_id,p_master_version,
    p_source_sales_id,p_executing_session_id,p_rounding_direction,p_notes,
    p_lines,p_refunds,COALESCE(p_refund_delivery_fee,FALSE));
END
$$;

REVOKE ALL ON FUNCTION private.odr6d_returnable_sales_detail_quantity(UUID,UUID),
  private.odr6d_sales_return_source_eligible(UUID,UUID) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.odr6d_returnable_sales_detail_quantity(UUID,UUID),
  private.odr6d_sales_return_source_eligible(UUID,UUID) TO service_role;
REVOKE ALL ON FUNCTION public.get_pos_returnable_sales(TEXT,INTEGER),
  public.save_sales_return_draft(UUID,BIGINT,UUID,UUID,TEXT,TEXT,JSONB,JSONB),
  public.save_sales_return_draft_with_delivery_fee(UUID,BIGINT,UUID,UUID,TEXT,TEXT,JSONB,JSONB,BOOLEAN)
  FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_pos_returnable_sales(TEXT,INTEGER),
  public.save_sales_return_draft(UUID,BIGINT,UUID,UUID,TEXT,TEXT,JSONB,JSONB),
  public.save_sales_return_draft_with_delivery_fee(UUID,BIGINT,UUID,UUID,TEXT,TEXT,JSONB,JSONB,BOOLEAN)
  TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260829110000','odr_phase6d_sales_return_consumer_compatibility',
  'Bound POS Sales Return search, Draft validation and Post validation to actual immutable ODR Dispatch quantity while preserving legacy POSTED Sale compatibility');

COMMIT;
