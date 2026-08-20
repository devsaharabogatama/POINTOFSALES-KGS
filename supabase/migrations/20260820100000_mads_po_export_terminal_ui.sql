BEGIN;

DO $guard$
BEGIN
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260820100000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260820100000';
  END IF;
  IF to_regclass('public.access_permission_catalog') IS NULL
     OR to_regclass('public.pos_terminals') IS NULL
     OR to_regclass('public.supplier_order_documents') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: required runtime missing';
  END IF;
  IF (SELECT count(*) FROM public.access_permission_catalog
      WHERE permission_key='purchase.supplier_orders')<>1 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: purchase.supplier_orders permission missing or duplicated';
  END IF;
END
$guard$;

UPDATE public.access_permission_catalog
SET supported_capabilities=(
      SELECT array_agg(DISTINCT capability ORDER BY capability)
      FROM unnest(supported_capabilities||ARRAY['EXPORT']) capability
    ),
    catalog_version=catalog_version+1,
    updated_at=clock_timestamp()
WHERE permission_key='purchase.supplier_orders';

ALTER TABLE public.pos_terminals
  ADD COLUMN hidden_feature_keys TEXT[] NOT NULL DEFAULT '{}',
  ADD COLUMN ui_settings_master_version BIGINT NOT NULL DEFAULT 1,
  ADD COLUMN ui_settings_updated_at TIMESTAMPTZ,
  ADD COLUMN ui_settings_updated_by UUID;

ALTER TABLE public.pos_terminals
  ADD CONSTRAINT pos_terminal_hidden_feature_keys_check CHECK(
    hidden_feature_keys<@ARRAY[
      'SALES_RETURN','EXPENSE','STOCK_REQUEST','GOODS_RECEIPT',
      'PURCHASE_RETURN','CASH_DEPOSIT','OFFLINE'
    ]::TEXT[]
  ),
  ADD CONSTRAINT pos_terminal_ui_settings_version_check
    CHECK(ui_settings_master_version>0),
  ADD CONSTRAINT pos_terminal_ui_settings_actor_fk
    FOREIGN KEY(ui_settings_updated_by) REFERENCES public.profiles(id) ON DELETE RESTRICT;

CREATE TABLE public.pos_terminal_ui_setting_audit(
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id UUID NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
  terminal_id UUID NOT NULL REFERENCES public.pos_terminals(id) ON DELETE RESTRICT,
  action TEXT NOT NULL CHECK(action IN('UPDATE','BACKFILL')),
  before_state JSONB,
  after_state JSONB NOT NULL,
  actor_id UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT pos_terminal_ui_audit_tenant_fk
    FOREIGN KEY(company_id,terminal_id)
    REFERENCES public.pos_terminals(company_id,id) ON DELETE RESTRICT
);
CREATE INDEX idx_pos_terminal_ui_audit_company_terminal
  ON public.pos_terminal_ui_setting_audit(company_id,terminal_id,created_at DESC);

CREATE FUNCTION private.trg_mads_terminal_ui_audit_immutable()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path=public,pg_temp AS $$
BEGIN
  RAISE EXCEPTION 'POS_TERMINAL_UI_AUDIT_IMMUTABLE';
END
$$;
CREATE TRIGGER trg_mads_terminal_ui_audit_immutable
BEFORE UPDATE OR DELETE ON public.pos_terminal_ui_setting_audit
FOR EACH ROW EXECUTE FUNCTION private.trg_mads_terminal_ui_audit_immutable();

CREATE FUNCTION private.mads_can_manage_terminal_ui(
  p_actor UUID,p_company_id UUID,p_store_id UUID
) RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
  SELECT public.private_is_super_admin(p_actor)
    OR EXISTS(SELECT 1 FROM public.company_memberships membership
      WHERE membership.company_id=p_company_id AND membership.user_id=p_actor
        AND membership.status='ACTIVE'
        AND membership.role_code IN('COMPANY_OWNER','COMPANY_ADMIN'))
    OR EXISTS(SELECT 1 FROM public.store_memberships membership
      WHERE membership.company_id=p_company_id AND membership.store_id=p_store_id
        AND membership.user_id=p_actor AND membership.status='ACTIVE'
        AND membership.role_code='STORE_MANAGER')
$$;

CREATE FUNCTION public.get_pos_terminal_ui_settings()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_actor UUID:=auth.uid();v_company UUID:=public.private_active_company_id();
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.pos_terminals terminal
    WHERE terminal.company_id=v_company
      AND private.mads_can_manage_terminal_ui(v_actor,v_company,terminal.store_id)) THEN
    RAISE EXCEPTION 'TERMINAL_UI_SETTINGS_ACCESS_DENIED';
  END IF;
  RETURN jsonb_build_object('companyId',v_company,'terminals',COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'terminalId',terminal.id,'terminalCode',terminal.pos_code,
      'terminalName',terminal.pos_name,'terminalStatus',terminal.status,
      'storeId',terminal.store_id,'storeName',store.store_name,
      'hiddenFeatureKeys',to_jsonb(terminal.hidden_feature_keys),
      'masterVersion',terminal.ui_settings_master_version,
      'updatedAt',terminal.ui_settings_updated_at)
      ORDER BY store.store_name,terminal.pos_name,terminal.id)
    FROM public.pos_terminals terminal
    JOIN public.stores store ON store.company_id=terminal.company_id
      AND store.id=terminal.store_id
    WHERE terminal.company_id=v_company
      AND private.mads_can_manage_terminal_ui(v_actor,v_company,terminal.store_id)
  ),'[]'::JSONB));
END
$$;

CREATE FUNCTION public.save_pos_terminal_ui_settings(
  p_terminal_id UUID,p_expected_version BIGINT,p_hidden_feature_keys TEXT[]
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_actor UUID:=auth.uid();v_company UUID:=public.private_active_company_id();
  v_terminal public.pos_terminals%ROWTYPE;v_hidden TEXT[];v_next BIGINT;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  SELECT ARRAY(SELECT DISTINCT upper(btrim(value))
    FROM unnest(COALESCE(p_hidden_feature_keys,'{}'::TEXT[])) value
    WHERE btrim(value)<>'' ORDER BY 1) INTO v_hidden;
  IF NOT v_hidden<@ARRAY[
    'SALES_RETURN','EXPENSE','STOCK_REQUEST','GOODS_RECEIPT',
    'PURCHASE_RETURN','CASH_DEPOSIT','OFFLINE'
  ]::TEXT[] THEN RAISE EXCEPTION 'INVALID_POS_TERMINAL_UI_FEATURE'; END IF;
  SELECT * INTO v_terminal FROM public.pos_terminals terminal
  WHERE terminal.company_id=v_company AND terminal.id=p_terminal_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'POS_TERMINAL_NOT_FOUND'; END IF;
  IF NOT private.mads_can_manage_terminal_ui(
      v_actor,v_company,v_terminal.store_id) THEN
    RAISE EXCEPTION 'TERMINAL_UI_SETTINGS_ACCESS_DENIED';
  END IF;
  IF v_terminal.hidden_feature_keys=v_hidden THEN
    RETURN jsonb_build_object('success',TRUE,'action','EXACT_RETRY',
      'terminalId',v_terminal.id,'hiddenFeatureKeys',to_jsonb(v_hidden),
      'masterVersion',v_terminal.ui_settings_master_version);
  END IF;
  IF p_expected_version IS DISTINCT FROM v_terminal.ui_settings_master_version THEN
    RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
  END IF;
  v_next:=v_terminal.ui_settings_master_version+1;
  UPDATE public.pos_terminals SET hidden_feature_keys=v_hidden,
    ui_settings_master_version=v_next,ui_settings_updated_at=clock_timestamp(),
    ui_settings_updated_by=v_actor
  WHERE id=v_terminal.id;
  INSERT INTO public.pos_terminal_ui_setting_audit(
    company_id,terminal_id,action,before_state,after_state,actor_id
  ) VALUES(v_company,v_terminal.id,'UPDATE',jsonb_build_object(
      'hiddenFeatureKeys',to_jsonb(v_terminal.hidden_feature_keys),
      'masterVersion',v_terminal.ui_settings_master_version),jsonb_build_object(
      'hiddenFeatureKeys',to_jsonb(v_hidden),'masterVersion',v_next),v_actor);
  RETURN jsonb_build_object('success',TRUE,'action','UPDATE',
    'terminalId',v_terminal.id,'hiddenFeatureKeys',to_jsonb(v_hidden),
    'masterVersion',v_next);
END
$$;

CREATE FUNCTION public.export_purchase_supplier_orders()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'purchase.supplier_orders','EXPORT');
  RETURN jsonb_build_object(
    'companyId',v_company,
    'companyName',(SELECT company.company_name FROM public.companies company WHERE company.id=v_company),
    'companyCode',(SELECT company.company_code FROM public.companies company WHERE company.id=v_company),
    'orders',COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'orderId',document.id,'orderNo',document.order_no,'orderDate',document.order_date,
      'expectedDate',document.expected_date,'supplierId',document.supplier_id,
      'supplierName',supplier.supplier_name,'storeId',document.store_id,
      'storeName',store.store_name,'warehouseId',document.destination_warehouse_id,
      'warehouseName',warehouse.name,'status',document.status,'notes',document.notes,
      'lineCount',document.line_count,'totalOrderedBaseQty',document.total_ordered_base_qty,
      'estimatedTotal',document.estimated_total)
      ORDER BY document.order_date DESC,document.order_no DESC)
      FROM public.supplier_order_documents document
      JOIN public.suppliers supplier ON supplier.company_id=document.company_id
        AND supplier.id=document.supplier_id
      JOIN public.stores store ON store.company_id=document.company_id
        AND store.id=document.store_id
      JOIN public.warehouses warehouse ON warehouse.company_id=document.company_id
        AND warehouse.id=document.destination_warehouse_id
      WHERE document.company_id=v_company),'[]'::JSONB),
    'lines',COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'orderId',document.id,'orderNo',document.order_no,'orderDate',document.order_date,
      'supplierId',document.supplier_id,'supplierName',supplier.supplier_name,
      'storeId',document.store_id,'storeName',store.store_name,
      'warehouseName',warehouse.name,'status',document.status,'lineNo',line.line_no,
      'sku',line.product_sku_snapshot,'productName',line.product_name_snapshot,
      'uomName',line.ordered_uom_name_snapshot,'orderedQty',line.ordered_qty,
      'orderedBaseQty',line.ordered_base_qty,'estimatedUnitPrice',line.estimated_unit_price,
      'estimatedSubtotal',line.estimated_subtotal)
      ORDER BY document.order_date DESC,document.order_no DESC,line.line_no)
      FROM public.supplier_order_lines line
      JOIN public.supplier_order_documents document ON document.company_id=line.company_id
        AND document.id=line.document_id
      JOIN public.suppliers supplier ON supplier.company_id=document.company_id
        AND supplier.id=document.supplier_id
      JOIN public.stores store ON store.company_id=document.company_id
        AND store.id=document.store_id
      JOIN public.warehouses warehouse ON warehouse.company_id=document.company_id
        AND warehouse.id=document.destination_warehouse_id
      WHERE line.company_id=v_company),'[]'::JSONB));
END
$$;

ALTER TABLE public.pos_terminal_ui_setting_audit ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.pos_terminal_ui_setting_audit FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.pos_terminal_ui_setting_audit TO service_role;
REVOKE UPDATE(hidden_feature_keys,ui_settings_master_version,ui_settings_updated_at,ui_settings_updated_by)
  ON public.pos_terminals FROM authenticated;
REVOKE ALL ON FUNCTION private.mads_can_manage_terminal_ui(UUID,UUID,UUID),
  private.trg_mads_terminal_ui_audit_immutable() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.mads_can_manage_terminal_ui(UUID,UUID,UUID),
  private.trg_mads_terminal_ui_audit_immutable() TO service_role;
REVOKE ALL ON FUNCTION public.get_pos_terminal_ui_settings(),
  public.save_pos_terminal_ui_settings(UUID,BIGINT,TEXT[]),
  public.export_purchase_supplier_orders() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_pos_terminal_ui_settings(),
  public.save_pos_terminal_ui_settings(UUID,BIGINT,TEXT[]),
  public.export_purchase_supplier_orders() TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260820100000','mads_po_export_terminal_ui',
  'Adds guarded Supplier Order XLSX export and audited terminal-specific POS UI visibility; existing terminals default to all features visible');
NOTIFY pgrst,'reload schema';
COMMIT;
