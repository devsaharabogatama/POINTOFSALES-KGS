-- ACP-5D: enforce Purchase Return without widening Cashier/source authority.

BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260813000000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: ACP-5C required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260813010000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED';
  END IF;
  IF (SELECT count(*) FROM public.access_permission_catalog
    WHERE permission_key='purchase.purchase_returns'
      AND enforcement_status='SHADOW')<>1 THEN
    RAISE EXCEPTION 'PURCHASE_RETURN_PERMISSION_NOT_SHADOW';
  END IF;
  IF EXISTS(SELECT 1 FROM public.purchase_return_documents document
    LEFT JOIN public.purchase_return_lines line
      ON line.company_id=document.company_id AND line.document_id=document.id
    GROUP BY document.id,document.line_count,document.total_return_base_qty,
      document.provisional_ap_adjustment_total
    HAVING document.line_count<>count(line.id)
      OR document.total_return_base_qty<>COALESCE(sum(line.return_base_qty),0)
      OR document.provisional_ap_adjustment_total<>
        COALESCE(sum(line.provisional_return_value),0)) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: return totals mismatch';
  END IF;
END
$guard$;

CREATE FUNCTION public.get_purchase_returns()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'purchase.purchase_returns','VIEW');
  RETURN jsonb_build_object(
    'companyId',v_company,
    'data',(SELECT COALESCE(jsonb_agg(to_jsonb(row_value)
      ORDER BY row_value.created_at DESC,row_value.id),'[]'::JSONB)
      FROM (SELECT document.id,document.return_no,
          document.source_receipt_id,document.supplier_order_id,
          document.supplier_id,document.store_id,
          document.source_warehouse_id,document.return_date,
          document.return_reason,document.supplier_document_no,document.notes,
          document.status,document.review_status,document.line_count,
          document.total_return_base_qty,
          document.provisional_ap_adjustment_total,document.created_by,
          document.reviewed_by,document.reviewed_at,document.review_reason,
          document.posted_by,document.posted_at,document.canceled_by,
          document.canceled_at,document.cancel_reason,document.master_version,
          document.created_at,document.financial_event_id
        FROM public.purchase_return_documents document
        WHERE document.company_id=v_company
        ORDER BY document.created_at DESC,document.id LIMIT 500) row_value),
    'lines',(SELECT COALESCE(jsonb_agg(to_jsonb(row_value)
      ORDER BY row_value.document_id,row_value.line_no),'[]'::JSONB)
      FROM (SELECT line.id,line.document_id,line.line_no,
          line.product_sku_snapshot,line.product_name_snapshot,
          line.return_uom_name_snapshot,line.return_qty,line.return_base_qty,
          line.source_condition_snapshot,line.base_uom_name_snapshot,
          line.provisional_base_unit_cost_snapshot,
          line.provisional_return_value
        FROM public.purchase_return_lines line
        WHERE line.company_id=v_company
        ORDER BY line.document_id,line.line_no LIMIT 10000) row_value),
    'receipts',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',receipt.id,'receipt_no',receipt.receipt_no,
      'supplier_delivery_no',receipt.supplier_delivery_no,
      'received_at',receipt.received_at) ORDER BY receipt.receipt_no),
      '[]'::JSONB) FROM public.goods_receipt_documents receipt
      WHERE receipt.company_id=v_company AND EXISTS(
        SELECT 1 FROM public.purchase_return_documents document
        WHERE document.company_id=v_company
          AND document.source_receipt_id=receipt.id)),
    'suppliers',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',supplier.id,'supplier_name',supplier.supplier_name)
      ORDER BY supplier.supplier_name),'[]'::JSONB)
      FROM public.suppliers supplier WHERE supplier.company_id=v_company
        AND EXISTS(SELECT 1 FROM public.purchase_return_documents document
          WHERE document.company_id=v_company
            AND document.supplier_id=supplier.id)),
    'stores',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',store.id,'store_name',store.store_name) ORDER BY store.store_name),
      '[]'::JSONB) FROM public.stores store WHERE store.company_id=v_company
        AND EXISTS(SELECT 1 FROM public.purchase_return_documents document
          WHERE document.company_id=v_company AND document.store_id=store.id)),
    'warehouses',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',warehouse.id,'name',warehouse.name) ORDER BY warehouse.name),
      '[]'::JSONB) FROM public.warehouses warehouse
      WHERE warehouse.company_id=v_company AND EXISTS(
        SELECT 1 FROM public.purchase_return_documents document
        WHERE document.company_id=v_company
          AND document.source_warehouse_id=warehouse.id)),
    'actors',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',profile.id,'name',profile.name) ORDER BY profile.name),'[]'::JSONB)
      FROM public.profiles profile WHERE EXISTS(
        SELECT 1 FROM public.purchase_return_documents document
        WHERE document.company_id=v_company AND profile.id IN(
          document.created_by,document.reviewed_by,document.posted_by,
          document.canceled_by))));
END
$$;

CREATE FUNCTION public.get_pos_purchase_return_workspace(
  p_cashier_session_id UUID
) RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_actor UUID:=auth.uid();
  v_store UUID;
BEGIN
  SELECT session.store_id INTO v_store FROM public.cashier_sessions session
  WHERE session.company_id=v_company AND session.id=p_cashier_session_id
    AND session.cashier_id=v_actor AND session.status='OPEN'::public.session_status;
  IF v_store IS NULL THEN RAISE EXCEPTION 'OPEN_CASHIER_SESSION_REQUIRED'; END IF;
  RETURN jsonb_build_object(
    'receipts',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',receipt.id,'receipt_no',receipt.receipt_no,
      'supplier_order_id',receipt.supplier_order_id,
      'received_at',receipt.received_at) ORDER BY receipt.received_at DESC),
      '[]'::JSONB) FROM public.goods_receipt_documents receipt
      WHERE receipt.company_id=v_company AND receipt.store_id=v_store
        AND receipt.status='POSTED'),
    'drafts',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',document.id,'return_no',document.return_no,
      'source_receipt_id',document.source_receipt_id,
      'source_warehouse_id',document.source_warehouse_id,
      'return_date',document.return_date,'return_reason',document.return_reason,
      'supplier_document_no',document.supplier_document_no,
      'notes',document.notes,'review_status',document.review_status,
      'master_version',document.master_version) ORDER BY document.created_at DESC),
      '[]'::JSONB) FROM public.purchase_return_documents document
      WHERE document.company_id=v_company AND document.store_id=v_store
        AND document.created_session_id=p_cashier_session_id
        AND document.created_by=v_actor AND document.status='DRAFT'),
    'receiptLines',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',line.id,'document_id',line.document_id,'product_id',line.product_id,
      'product_name_snapshot',line.product_name_snapshot,
      'base_uom_name_snapshot',line.base_uom_name_snapshot)),'[]'::JSONB)
      FROM public.goods_receipt_lines line JOIN public.goods_receipt_documents receipt
        ON receipt.company_id=line.company_id AND receipt.id=line.document_id
      WHERE line.company_id=v_company AND receipt.store_id=v_store
        AND receipt.status='POSTED'),
    'allocations',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',allocation.id,'receipt_line_id',allocation.receipt_line_id,
      'condition_type',allocation.condition_type,
      'warehouse_id',allocation.warehouse_id,
      'quantity_base',allocation.quantity_base,
      'product_batch_id',allocation.product_batch_id)),'[]'::JSONB)
      FROM public.goods_receipt_condition_allocations allocation
      JOIN public.goods_receipt_lines line ON line.company_id=allocation.company_id
        AND line.id=allocation.receipt_line_id
      JOIN public.goods_receipt_documents receipt ON receipt.company_id=line.company_id
        AND receipt.id=line.document_id
      WHERE allocation.company_id=v_company AND receipt.store_id=v_store
        AND receipt.status='POSTED'
        AND allocation.condition_type IN('GOOD','DAMAGED')),
    'batches',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',batch.id,'qty_remaining',batch.qty_remaining)),'[]'::JSONB)
      FROM public.product_batches batch WHERE batch.company_id=v_company
        AND EXISTS(SELECT 1 FROM public.goods_receipt_condition_allocations allocation
          JOIN public.goods_receipt_lines line
            ON line.company_id=allocation.company_id
           AND line.id=allocation.receipt_line_id
          JOIN public.goods_receipt_documents receipt
            ON receipt.company_id=line.company_id AND receipt.id=line.document_id
          WHERE allocation.company_id=v_company AND receipt.store_id=v_store
            AND allocation.product_batch_id=batch.id)),
    'returnLines',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'document_id',line.document_id,
      'source_condition_allocation_id',line.source_condition_allocation_id,
      'return_base_qty',line.return_base_qty,'client_line_key',line.client_line_key,
      'return_uom_id',line.return_uom_id,'return_qty',line.return_qty,
      'document_status',document.status)),'[]'::JSONB)
      FROM public.purchase_return_lines line
      JOIN public.purchase_return_documents document
        ON document.company_id=line.company_id AND document.id=line.document_id
      WHERE line.company_id=v_company AND document.store_id=v_store
        AND (document.status='POSTED' OR
          (document.status='DRAFT' AND document.created_by=v_actor
           AND document.created_session_id=p_cashier_session_id))),
    'productUoms',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'product_id',product_uom.product_id,'uom_id',product_uom.uom_id,
      'factor_to_base',product_uom.factor_to_base,'uom_name',uom.name,
      'allow_decimal',uom.allow_decimal,
      'decimal_precision',uom.decimal_precision)),'[]'::JSONB)
      FROM public.product_uoms product_uom JOIN public.uoms uom
        ON uom.company_id=product_uom.company_id AND uom.id=product_uom.uom_id
      WHERE product_uom.company_id=v_company AND product_uom.is_active
        AND uom.is_active AND EXISTS(SELECT 1 FROM public.goods_receipt_lines line
          JOIN public.goods_receipt_documents receipt
            ON receipt.company_id=line.company_id AND receipt.id=line.document_id
          WHERE line.company_id=v_company AND receipt.store_id=v_store
            AND receipt.status='POSTED'
            AND line.product_id=product_uom.product_id)),
    'orders',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',document.id,'order_no',document.order_no,
      'supplier_id',document.supplier_id)),'[]'::JSONB)
      FROM public.supplier_order_documents document
      WHERE document.company_id=v_company AND EXISTS(
        SELECT 1 FROM public.goods_receipt_documents receipt
        WHERE receipt.company_id=v_company AND receipt.store_id=v_store
          AND receipt.status='POSTED' AND receipt.supplier_order_id=document.id)),
    'suppliers',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',supplier.id,'supplier_name',supplier.supplier_name)),'[]'::JSONB)
      FROM public.suppliers supplier WHERE supplier.company_id=v_company
        AND EXISTS(SELECT 1 FROM public.supplier_order_documents document
          JOIN public.goods_receipt_documents receipt
            ON receipt.company_id=document.company_id
           AND receipt.supplier_order_id=document.id
          WHERE document.company_id=v_company AND receipt.store_id=v_store
            AND receipt.status='POSTED' AND document.supplier_id=supplier.id)),
    'warehouses',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',warehouse.id,'name',warehouse.name)),'[]'::JSONB)
      FROM public.warehouses warehouse WHERE warehouse.company_id=v_company
        AND EXISTS(SELECT 1 FROM public.goods_receipt_condition_allocations allocation
          JOIN public.goods_receipt_lines line
            ON line.company_id=allocation.company_id
           AND line.id=allocation.receipt_line_id
          JOIN public.goods_receipt_documents receipt
            ON receipt.company_id=line.company_id AND receipt.id=line.document_id
          WHERE allocation.company_id=v_company AND receipt.store_id=v_store
            AND allocation.warehouse_id=warehouse.id)));
END
$$;

ALTER FUNCTION public.save_purchase_return_draft(
  UUID,BIGINT,UUID,UUID,UUID,DATE,TEXT,TEXT,TEXT,JSONB)
  RENAME TO acp5d_save_purchase_return_draft_core;
ALTER FUNCTION public.acp5d_save_purchase_return_draft_core(
  UUID,BIGINT,UUID,UUID,UUID,DATE,TEXT,TEXT,TEXT,JSONB) SET SCHEMA private;
ALTER FUNCTION public.review_purchase_return(UUID,BIGINT,TEXT,TEXT)
  RENAME TO acp5d_review_purchase_return_core;
ALTER FUNCTION public.acp5d_review_purchase_return_core(UUID,BIGINT,TEXT,TEXT)
  SET SCHEMA private;
ALTER FUNCTION public.post_purchase_return(UUID,BIGINT,UUID)
  RENAME TO acp5d_post_purchase_return_core;
ALTER FUNCTION public.acp5d_post_purchase_return_core(UUID,BIGINT,UUID)
  SET SCHEMA private;
ALTER FUNCTION public.cancel_purchase_return_draft(UUID,BIGINT,TEXT)
  RENAME TO acp5d_cancel_purchase_return_draft_core;
ALTER FUNCTION public.acp5d_cancel_purchase_return_draft_core(UUID,BIGINT,TEXT)
  SET SCHEMA private;

CREATE FUNCTION public.save_purchase_return_draft(
  p_document_id UUID,p_master_version BIGINT,p_cashier_session_id UUID,
  p_source_receipt_id UUID,p_source_warehouse_id UUID,p_return_date DATE,
  p_return_reason TEXT,p_supplier_document_no TEXT,p_notes TEXT,p_lines JSONB
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_actor UUID:=auth.uid();
BEGIN
  IF NOT EXISTS(SELECT 1 FROM public.cashier_sessions session
    WHERE session.company_id=v_company AND session.id=p_cashier_session_id
      AND session.cashier_id=v_actor AND session.status='OPEN'::public.session_status)
  THEN RAISE EXCEPTION 'OPEN_CASHIER_SESSION_REQUIRED'; END IF;
  RETURN private.acp5d_save_purchase_return_draft_core(p_document_id,
    p_master_version,p_cashier_session_id,p_source_receipt_id,
    p_source_warehouse_id,p_return_date,p_return_reason,p_supplier_document_no,
    p_notes,p_lines);
END $$;

CREATE FUNCTION public.review_purchase_return(p_document_id UUID,
  p_master_version BIGINT,p_decision TEXT,p_reason TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'purchase.purchase_returns','REVIEW');
  RETURN private.acp5d_review_purchase_return_core(
    p_document_id,p_master_version,p_decision,p_reason);
END $$;

CREATE FUNCTION public.post_purchase_return(p_document_id UUID,
  p_master_version BIGINT,p_idempotency_key UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'purchase.purchase_returns','POST');
  RETURN private.acp5d_post_purchase_return_core(
    p_document_id,p_master_version,p_idempotency_key);
END $$;

CREATE FUNCTION public.cancel_purchase_return_draft(p_document_id UUID,
  p_master_version BIGINT,p_reason TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_actor UUID:=auth.uid();
  v_creator UUID;
BEGIN
  SELECT document.created_by INTO v_creator
  FROM public.purchase_return_documents document
  WHERE document.company_id=v_company AND document.id=p_document_id;
  IF v_creator IS NULL THEN RAISE EXCEPTION 'PURCHASE_RETURN_NOT_FOUND'; END IF;
  IF v_creator<>v_actor THEN
    PERFORM private.acp_require_permission_capability(
      v_company,'purchase.purchase_returns','CANCEL_FINAL');
  END IF;
  RETURN private.acp5d_cancel_purchase_return_draft_core(
    p_document_id,p_master_version,p_reason);
END $$;

DO $enforce$
DECLARE v_rows BIGINT;
BEGIN
  UPDATE public.access_permission_catalog SET
    enforcement_status='ENFORCED',catalog_version=catalog_version+1,
    updated_at=clock_timestamp()
  WHERE permission_key='purchase.purchase_returns'
    AND enforcement_status='SHADOW';
  GET DIAGNOSTICS v_rows=ROW_COUNT;
  IF v_rows<>1 THEN RAISE EXCEPTION 'PURCHASE_RETURN_PERMISSION_CUTOVER_FAILED'; END IF;
END $enforce$;

REVOKE SELECT ON public.purchase_return_documents,public.purchase_return_lines,
  public.purchase_return_fifo_allocations,public.purchase_return_ap_adjustments,
  public.purchase_return_audit FROM authenticated;

REVOKE ALL ON FUNCTION
  private.acp5d_save_purchase_return_draft_core(
    UUID,BIGINT,UUID,UUID,UUID,DATE,TEXT,TEXT,TEXT,JSONB),
  private.acp5d_review_purchase_return_core(UUID,BIGINT,TEXT,TEXT),
  private.acp5d_post_purchase_return_core(UUID,BIGINT,UUID),
  private.acp5d_cancel_purchase_return_draft_core(UUID,BIGINT,TEXT)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.acp5d_save_purchase_return_draft_core(
    UUID,BIGINT,UUID,UUID,UUID,DATE,TEXT,TEXT,TEXT,JSONB),
  private.acp5d_review_purchase_return_core(UUID,BIGINT,TEXT,TEXT),
  private.acp5d_post_purchase_return_core(UUID,BIGINT,UUID),
  private.acp5d_cancel_purchase_return_draft_core(UUID,BIGINT,TEXT)
TO service_role;

REVOKE ALL ON FUNCTION public.get_purchase_returns(),
  public.get_pos_purchase_return_workspace(UUID),
  public.save_purchase_return_draft(
    UUID,BIGINT,UUID,UUID,UUID,DATE,TEXT,TEXT,TEXT,JSONB),
  public.review_purchase_return(UUID,BIGINT,TEXT,TEXT),
  public.post_purchase_return(UUID,BIGINT,UUID),
  public.cancel_purchase_return_draft(UUID,BIGINT,TEXT)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_purchase_returns(),
  public.get_pos_purchase_return_workspace(UUID),
  public.save_purchase_return_draft(
    UUID,BIGINT,UUID,UUID,UUID,DATE,TEXT,TEXT,TEXT,JSONB),
  public.review_purchase_return(UUID,BIGINT,TEXT,TEXT),
  public.post_purchase_return(UUID,BIGINT,UUID),
  public.cancel_purchase_return_draft(UUID,BIGINT,TEXT)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260813010000','acp_phase5d_purchase_return_permission_enforcement',
  'Enforced Purchase Return composed Backoffice and Cashier reads plus capability-aware Review/Post/Cancel while retaining open-session Draft and atomic G5 core');

COMMIT;
