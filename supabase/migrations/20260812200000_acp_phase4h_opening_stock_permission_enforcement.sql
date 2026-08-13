-- ACP-4H: enforce Opening Stock capability and composed read boundary.

BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260812190000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: ACP-4G required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260812200000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED';
  END IF;
  IF (SELECT count(*) FROM public.access_permission_catalog
    WHERE permission_key='inventory.opening_stock'
      AND enforcement_status='SHADOW')<>1 THEN
    RAISE EXCEPTION 'OPENING_STOCK_PERMISSION_NOT_SHADOW';
  END IF;
  IF to_regprocedure('public.save_opening_stock_document(uuid,bigint,uuid,date,text,jsonb)') IS NULL
     OR to_regprocedure('public.post_opening_stock(uuid,bigint,uuid)') IS NULL THEN
    RAISE EXCEPTION 'OPENING_STOCK_RUNTIME_REQUIRED';
  END IF;
END
$guard$;

-- Approved authority: Finance/Store Manager prepare; only Owner/Admin Post.
UPDATE public.access_permission_catalog SET
  operator_roles=ARRAY[
    'COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','FINANCE']::TEXT[],
  approver_roles=ARRAY['COMPANY_OWNER','COMPANY_ADMIN']::TEXT[],
  catalog_version=catalog_version+1,updated_at=clock_timestamp()
WHERE permission_key='inventory.opening_stock';

-- Store Manager is limited to an assigned Store warehouse. Accounting is
-- report-only; Finance retains Company-wide preparation authority.
CREATE OR REPLACE FUNCTION public.private_opening_stock_prepare_allowed(
  p_company_id UUID,p_warehouse_id UUID
) RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
  SELECT public.private_request_company_matches(p_company_id)
    AND (
      public.private_is_super_admin(auth.uid())
      OR public.private_user_has_any_company_role(
        p_company_id,ARRAY[
          'COMPANY_OWNER','COMPANY_ADMIN','FINANCE']::TEXT[])
      OR EXISTS(
        SELECT 1 FROM public.warehouses warehouse
        WHERE warehouse.company_id=p_company_id
          AND warehouse.id=p_warehouse_id AND warehouse.store_id IS NOT NULL
          AND public.private_user_has_any_store_role(
            warehouse.store_id,ARRAY['STORE_MANAGER']::TEXT[])
      )
    );
$$;

ALTER FUNCTION public.save_opening_stock_document(
  UUID,BIGINT,UUID,DATE,TEXT,JSONB
) SET SCHEMA private;
ALTER FUNCTION public.post_opening_stock(UUID,BIGINT,UUID) SET SCHEMA private;

CREATE FUNCTION public.save_opening_stock_document(
  p_document_id UUID,p_master_version BIGINT,p_warehouse_id UUID,
  p_effective_date DATE,p_notes TEXT,p_lines JSONB
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'inventory.opening_stock',
    CASE WHEN p_document_id IS NULL THEN 'CREATE_DRAFT' ELSE 'EDIT_DRAFT' END);
  IF NOT public.private_opening_stock_prepare_allowed(
    v_company,p_warehouse_id) THEN
    RAISE EXCEPTION 'OPENING_STOCK_PREPARER_REQUIRED';
  END IF;
  RETURN private.save_opening_stock_document(
    p_document_id,p_master_version,p_warehouse_id,p_effective_date,
    p_notes,p_lines);
END
$$;

CREATE FUNCTION public.post_opening_stock(
  p_document_id UUID,p_master_version BIGINT,p_idempotency_key UUID
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'inventory.opening_stock','POST');
  RETURN private.post_opening_stock(
    p_document_id,p_master_version,p_idempotency_key);
END
$$;

CREATE FUNCTION public.get_inventory_opening_stock()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE
  v_company UUID:=public.private_active_company_id();v_resolution JSONB;
  v_role TEXT;v_documents JSONB;v_lines JSONB;v_products JSONB;
  v_warehouses JSONB;v_balances JSONB;v_movements JSONB;v_batches JSONB;
  v_movement_pairs JSONB;v_events JSONB;v_audit JSONB;
BEGIN
  v_resolution:=private.acp_require_permission_capability(
    v_company,'inventory.opening_stock','VIEW');
  v_role:=v_resolution->>'roleCode';

  SELECT COALESCE(jsonb_agg(to_jsonb(document_row)
    ORDER BY document_row.created_at DESC,document_row.id),'[]'::JSONB)
  INTO v_documents FROM (
    SELECT document.id,document.company_id,document.document_no,
      document.warehouse_id,document.effective_date,document.status,
      document.notes,document.line_count,document.total_quantity_base,
      document.total_cost,document.posting_idempotency_key,
      document.financial_event_id,document.master_version,
      document.created_by,document.updated_by,document.posted_by,
      document.posted_at,document.created_at,document.updated_at
    FROM public.opening_stock_documents document
    WHERE document.company_id=v_company AND (
      v_role<>'STORE_MANAGER' OR public.private_opening_stock_prepare_allowed(
        v_company,document.warehouse_id))
    ORDER BY document.created_at DESC,document.id LIMIT 200
  ) document_row;

  SELECT COALESCE(jsonb_agg(to_jsonb(line_row)
    ORDER BY line_row.document_id,line_row.line_no),'[]'::JSONB)
  INTO v_lines FROM (
    SELECT line.id,line.company_id,line.document_id,line.line_no,
      line.product_id,line.base_uom_id,line.quantity_base,line.unit_cost_base,
      line.total_cost,line.product_sku_snapshot,line.product_name_snapshot,
      line.base_uom_code_snapshot,line.base_uom_name_snapshot,
      line.zero_cost_reason,line.notes
    FROM public.opening_stock_lines line
    WHERE line.company_id=v_company AND line.document_id IN(
      SELECT document.id FROM public.opening_stock_documents document
      WHERE document.company_id=v_company AND (
        v_role<>'STORE_MANAGER' OR public.private_opening_stock_prepare_allowed(
          v_company,document.warehouse_id))
      ORDER BY document.created_at DESC,document.id LIMIT 200)
    ORDER BY line.document_id,line.line_no LIMIT 5000
  ) line_row;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',product.id,'sku',product.sku,'name',product.name,
    'uom_id',product.uom_id,'is_bundle',product.is_bundle,
    'is_active',product.is_active,'product_uoms',jsonb_build_array(
      jsonb_build_object('uom_id',product_uom.uom_id,
        'factor_to_base',product_uom.factor_to_base,
        'is_active',product_uom.is_active,'uom',jsonb_build_object(
          'id',uom.id,'name',uom.name,'allow_decimal',uom.allow_decimal,
          'decimal_precision',uom.decimal_precision,
          'is_active',uom.is_active)))
    ) ORDER BY product.name,product.id),'[]'::JSONB)
  INTO v_products
  FROM public.products product
  JOIN public.product_uoms product_uom
    ON product_uom.company_id=product.company_id
   AND product_uom.product_id=product.id AND product_uom.uom_id=product.uom_id
   AND product_uom.factor_to_base=1 AND product_uom.is_active
  JOIN public.uoms uom ON uom.company_id=product_uom.company_id
    AND uom.id=product_uom.uom_id AND uom.is_active
  WHERE product.company_id=v_company AND product.is_active
    AND NOT product.is_bundle;

  SELECT COALESCE(jsonb_agg(to_jsonb(warehouse_row)
    ORDER BY warehouse_row.name,warehouse_row.id),'[]'::JSONB)
  INTO v_warehouses FROM (
    SELECT warehouse.id,warehouse.name,warehouse.warehouse_type,
      warehouse.location,warehouse.is_active
    FROM public.warehouses warehouse
    WHERE warehouse.company_id=v_company AND (
      (warehouse.is_active AND (v_role<>'STORE_MANAGER'
        OR public.private_opening_stock_prepare_allowed(v_company,warehouse.id)))
      OR EXISTS(SELECT 1 FROM public.opening_stock_documents document
        WHERE document.company_id=v_company
          AND document.warehouse_id=warehouse.id
          AND (v_role<>'STORE_MANAGER'
            OR public.private_opening_stock_prepare_allowed(
              v_company,warehouse.id))))
    ORDER BY warehouse.name,warehouse.id LIMIT 2000
  ) warehouse_row;

  SELECT COALESCE(jsonb_agg(to_jsonb(balance_row)),'[]'::JSONB)
  INTO v_balances FROM (
    SELECT stock.product_id,stock.warehouse_id,stock.stock_qty
    FROM public.product_stocks stock
    WHERE stock.company_id=v_company AND EXISTS(
      SELECT 1 FROM public.opening_stock_lines line
      JOIN public.opening_stock_documents document
        ON document.company_id=line.company_id AND document.id=line.document_id
      WHERE line.company_id=v_company AND line.product_id=stock.product_id
        AND document.warehouse_id=stock.warehouse_id
        AND (v_role<>'STORE_MANAGER'
          OR public.private_opening_stock_prepare_allowed(
            v_company,document.warehouse_id)))
  ) balance_row;

  SELECT COALESCE(jsonb_agg(to_jsonb(movement_row)
    ORDER BY movement_row.posted_at DESC,movement_row.id),'[]'::JSONB)
  INTO v_movements FROM (
    SELECT movement.id,movement.product_id,movement.warehouse_id,
      movement.qty_change,movement.movement_type,movement.reference_table,
      movement.reference_id,movement.posted_at
    FROM public.stock_movements movement
    WHERE movement.company_id=v_company
      AND movement.movement_type='OPENING_BALANCE'
      AND movement.reference_table='opening_stock_documents'
      AND movement.reference_id IN(SELECT document.id
        FROM public.opening_stock_documents document
        WHERE document.company_id=v_company AND (
          v_role<>'STORE_MANAGER' OR public.private_opening_stock_prepare_allowed(
            v_company,document.warehouse_id)))
  ) movement_row;

  SELECT COALESCE(jsonb_agg(to_jsonb(batch_row)),'[]'::JSONB)
  INTO v_batches FROM (
    SELECT batch.id,batch.product_id,batch.warehouse_id,batch.qty_purchased,
      batch.qty_remaining,batch.cogs_unit,batch.opening_stock_line_id
    FROM public.product_batches batch
    WHERE batch.company_id=v_company AND batch.opening_stock_line_id IN(
      SELECT line.id FROM public.opening_stock_lines line
      JOIN public.opening_stock_documents document
        ON document.company_id=line.company_id AND document.id=line.document_id
      WHERE line.company_id=v_company AND (v_role<>'STORE_MANAGER'
        OR public.private_opening_stock_prepare_allowed(
          v_company,document.warehouse_id)))
  ) batch_row;

  SELECT COALESCE(jsonb_agg(to_jsonb(pair_row)),'[]'::JSONB)
  INTO v_movement_pairs FROM (
    SELECT DISTINCT movement.product_id,movement.warehouse_id
    FROM public.stock_movements movement
    JOIN public.warehouses warehouse ON warehouse.company_id=movement.company_id
      AND warehouse.id=movement.warehouse_id
    WHERE movement.company_id=v_company AND (v_role<>'STORE_MANAGER'
      OR public.private_opening_stock_prepare_allowed(v_company,warehouse.id))
  ) pair_row;

  SELECT COALESCE(jsonb_agg(to_jsonb(event_row)),'[]'::JSONB)
  INTO v_events FROM (
    SELECT event.id,event.source_id,event.status,event.system_event_key,
      event.event_date,event.amounts
    FROM public.financial_events event
    WHERE event.company_id=v_company AND event.source_table='opening_stock_documents'
      AND event.source_id IN(SELECT document.id
        FROM public.opening_stock_documents document
        WHERE document.company_id=v_company AND (v_role<>'STORE_MANAGER'
          OR public.private_opening_stock_prepare_allowed(
            v_company,document.warehouse_id)))
  ) event_row;

  SELECT COALESCE(jsonb_agg(to_jsonb(audit_row)
    ORDER BY audit_row.created_at,audit_row.id),'[]'::JSONB)
  INTO v_audit FROM (
    SELECT audit.id,audit.document_id,audit.action,audit.actor_id,
      audit.created_at
    FROM public.opening_stock_audit audit
    WHERE audit.company_id=v_company AND audit.document_id IN(
      SELECT document.id FROM public.opening_stock_documents document
      WHERE document.company_id=v_company AND (v_role<>'STORE_MANAGER'
        OR public.private_opening_stock_prepare_allowed(
          v_company,document.warehouse_id)))
  ) audit_row;

  RETURN jsonb_build_object('companyId',v_company,'data',v_documents,
    'lines',v_lines,'products',v_products,'warehouses',v_warehouses,
    'balances',v_balances,'movements',v_movements,'batches',v_batches,
    'movementPairs',v_movement_pairs,'financialEvents',v_events,
    'audit',v_audit);
END
$$;

DO $enforce$
DECLARE v_rows BIGINT;
BEGIN
  UPDATE public.access_permission_catalog SET
    enforcement_status='ENFORCED',catalog_version=catalog_version+1,
    updated_at=clock_timestamp()
  WHERE permission_key='inventory.opening_stock'
    AND enforcement_status='SHADOW';
  GET DIAGNOSTICS v_rows=ROW_COUNT;
  IF v_rows<>1 THEN RAISE EXCEPTION 'OPENING_STOCK_PERMISSION_CUTOVER_FAILED'; END IF;
END
$enforce$;

REVOKE SELECT ON public.opening_stock_documents,public.opening_stock_lines,
  public.opening_stock_audit FROM authenticated;

REVOKE ALL ON FUNCTION
  private.save_opening_stock_document(UUID,BIGINT,UUID,DATE,TEXT,JSONB),
  private.post_opening_stock(UUID,BIGINT,UUID)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.save_opening_stock_document(UUID,BIGINT,UUID,DATE,TEXT,JSONB),
  private.post_opening_stock(UUID,BIGINT,UUID)
TO service_role;

REVOKE ALL ON FUNCTION
  public.private_opening_stock_prepare_allowed(UUID,UUID),
  public.save_opening_stock_document(UUID,BIGINT,UUID,DATE,TEXT,JSONB),
  public.post_opening_stock(UUID,BIGINT,UUID),
  public.get_inventory_opening_stock()
FROM PUBLIC,anon;
REVOKE EXECUTE ON FUNCTION
  public.private_opening_stock_prepare_allowed(UUID,UUID)
FROM authenticated;
GRANT EXECUTE ON FUNCTION
  public.save_opening_stock_document(UUID,BIGINT,UUID,DATE,TEXT,JSONB),
  public.post_opening_stock(UUID,BIGINT,UUID),
  public.get_inventory_opening_stock()
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260812200000','acp_phase4h_opening_stock_permission_enforcement',
  'Enforced approved Opening Stock Draft/Post authority, Store-scoped preparation, composed proof/reference read, and direct browser read closure');

NOTIFY pgrst,'reload schema';
COMMIT;

