-- Default Warehouse contract for the Odoo-style Backoffice Quotation/SO form.
-- Additive and feature-scoped; no Reservation, Stock, Delivery, Invoice, Payment or Finance effect.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260908121000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Backoffice Sales runtime required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260909100000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260909100000';
  END IF;
  IF EXISTS(
    SELECT 1 FROM public.backoffice_sales_orders document
    LEFT JOIN public.warehouses warehouse ON warehouse.company_id=document.company_id
      AND warehouse.id=document.warehouse_id AND warehouse.is_active
      AND warehouse.is_sale_source
      AND (warehouse.store_id IS NULL OR warehouse.store_id=document.store_id)
    WHERE warehouse.id IS NULL
  ) THEN RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: invalid existing order Warehouse scope'; END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
    WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
END
$guard$;

CREATE FUNCTION public.set_backoffice_sales_default_warehouse(p_warehouse_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
  v_feature public.company_features%rowtype;v_config jsonb;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF NOT public.private_is_super_admin(v_actor) THEN RAISE EXCEPTION 'SUPER_ADMIN_REQUIRED'; END IF;
  SELECT * INTO v_feature FROM public.company_features
  WHERE company_id=v_company AND feature_code='backoffice_delivered_qty_sales_enabled'
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'BACKOFFICE_SALES_FEATURE_NOT_FOUND'; END IF;
  IF p_warehouse_id IS NOT NULL AND NOT EXISTS(
    SELECT 1 FROM public.warehouses warehouse WHERE warehouse.company_id=v_company
      AND warehouse.id=p_warehouse_id AND warehouse.is_active AND warehouse.is_sale_source
  ) THEN RAISE EXCEPTION 'BACKOFFICE_DEFAULT_WAREHOUSE_INVALID'; END IF;
  v_config:=COALESCE(v_feature.config,'{}'::jsonb)-'defaultWarehouseId';
  IF p_warehouse_id IS NOT NULL THEN
    v_config:=v_config||jsonb_build_object('defaultWarehouseId',p_warehouse_id);
  END IF;
  PERFORM public.set_company_feature(v_company,
    'backoffice_delivered_qty_sales_enabled',v_feature.is_enabled,v_config);
  RETURN jsonb_build_object('companyId',v_company,
    'defaultWarehouseId',p_warehouse_id,'config',v_config);
END
$$;

CREATE OR REPLACE FUNCTION public.get_backoffice_sales_order_workspace()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_default uuid;
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'sales.backoffice_orders','VIEW');
  SELECT CASE WHEN feature.config->>'defaultWarehouseId' ~
      '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$'
    THEN (feature.config->>'defaultWarehouseId')::uuid END INTO v_default
  FROM public.company_features feature
  WHERE feature.company_id=v_company
    AND feature.feature_code='backoffice_delivered_qty_sales_enabled'
    AND feature.is_enabled;
  IF NOT EXISTS(SELECT 1 FROM public.warehouses warehouse
    WHERE warehouse.company_id=v_company AND warehouse.id=v_default
      AND warehouse.is_active AND warehouse.is_sale_source) THEN v_default:=NULL; END IF;
  RETURN jsonb_build_object(
    'companyId',v_company,'defaultWarehouseId',v_default,
    'stores',COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'id',store.id,'code',store.store_code,'name',store.store_name)
      ORDER BY store.store_name) FROM public.stores store
      WHERE store.company_id=v_company AND store.status='ACTIVE'),'[]'::jsonb),
    'warehouses',COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'id',warehouse.id,'code',warehouse.code,'name',warehouse.name,
      'storeId',warehouse.store_id) ORDER BY warehouse.name)
      FROM public.warehouses warehouse WHERE warehouse.company_id=v_company
        AND warehouse.is_active AND warehouse.is_sale_source),'[]'::jsonb),
    'customers',COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'id',customer.id,'code',customer.code,'name',customer.name,
      'creditTermDays',customer.credit_term_days,'phone',customer.phone,
      'email',customer.email,'address',customer.address)
      ORDER BY customer.name) FROM public.customers customer
      WHERE customer.company_id=v_company AND customer.is_active),'[]'::jsonb),
    'products',COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'productUomId',product_uom.id,'productId',product.id,
      'sku',product.sku,'productName',product.name,'uomId',uom.id,
      'uomCode',uom.code,'uomName',uom.name,
      'factorToBase',product_uom.factor_to_base,'salePrice',product_uom.sale_price)
      ORDER BY product.name,uom.name) FROM public.product_uoms product_uom
      JOIN public.products product ON product.company_id=product_uom.company_id
        AND product.id=product_uom.product_id AND product.is_active
      JOIN public.uoms uom ON uom.company_id=product_uom.company_id
        AND uom.id=product_uom.uom_id AND uom.is_active
      WHERE product_uom.company_id=v_company AND product_uom.is_active
        AND product_uom.sales_allowed),'[]'::jsonb)
  );
END
$$;

CREATE FUNCTION private.trg_guard_backoffice_sales_order_warehouse()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM public.warehouses warehouse
    WHERE warehouse.company_id=NEW.company_id AND warehouse.id=NEW.warehouse_id
      AND warehouse.is_active AND warehouse.is_sale_source
      AND (warehouse.store_id IS NULL OR warehouse.store_id=NEW.store_id)) THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_WAREHOUSE_SCOPE_INVALID';
  END IF;
  RETURN NEW;
END
$$;
CREATE TRIGGER backoffice_sales_order_warehouse_guard
BEFORE INSERT OR UPDATE OF company_id,store_id,warehouse_id
ON public.backoffice_sales_orders FOR EACH ROW
EXECUTE FUNCTION private.trg_guard_backoffice_sales_order_warehouse();

REVOKE ALL ON FUNCTION public.set_backoffice_sales_default_warehouse(uuid)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.set_backoffice_sales_default_warehouse(uuid)
TO authenticated,service_role;
REVOKE ALL ON FUNCTION private.trg_guard_backoffice_sales_order_warehouse()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.trg_guard_backoffice_sales_order_warehouse()
TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260909100000','backoffice_sales_odoo_form_default_warehouse',
  'Feature config default Warehouse, sale-source/store guard and Odoo-style workspace metadata; zero downstream effect');
COMMIT;
