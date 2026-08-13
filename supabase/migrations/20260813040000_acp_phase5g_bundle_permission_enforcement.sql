-- ACP-5G: enforce Bundle management without widening Product, Stock, or POS.

BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260813030000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: ACP-5F required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260813040000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED';
  END IF;
  IF (SELECT count(*) FROM public.access_permission_catalog
    WHERE permission_key='sales.bundles'
      AND enforcement_status='SHADOW')<>1 THEN
    RAISE EXCEPTION 'BUNDLE_PERMISSION_NOT_SHADOW';
  END IF;
  IF EXISTS(SELECT 1 FROM public.products bundle
    WHERE bundle.is_active AND bundle.is_bundle AND (
      NOT EXISTS(SELECT 1 FROM public.product_bundle_items item
        WHERE item.company_id=bundle.company_id AND item.bundle_id=bundle.id)
      OR EXISTS(SELECT 1 FROM public.product_stocks stock
        WHERE stock.company_id=bundle.company_id AND stock.product_id=bundle.id)
      OR EXISTS(SELECT 1 FROM public.product_batches batch
        WHERE batch.company_id=bundle.company_id AND batch.product_id=bundle.id)
      OR EXISTS(SELECT 1 FROM public.stock_movements movement
        WHERE movement.company_id=bundle.company_id
          AND movement.product_id=bundle.id))) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: invalid Bundle state';
  END IF;
END
$guard$;

CREATE FUNCTION public.get_sales_bundles(
  p_include_inactive BOOLEAN DEFAULT FALSE
) RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'sales.bundles','VIEW');

  RETURN jsonb_build_object(
    'companyId',v_company,
    'data',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',bundle.id,'company_id',bundle.company_id,'sku',bundle.sku,
      'name',bundle.name,'category_id',bundle.category_id,
      'uom_id',bundle.uom_id,
      'weight_reference_uom_id',bundle.weight_reference_uom_id,
      'weight_per_uom_kg',bundle.weight_per_uom_kg,
      'image_url',bundle.image_url,'is_active',bundle.is_active,
      'master_version',bundle.master_version,'created_at',bundle.created_at,
      'updated_at',bundle.updated_at) ORDER BY bundle.name,bundle.id),
      '[]'::JSONB) FROM (SELECT product.* FROM public.products product
        WHERE product.company_id=v_company AND product.is_bundle
          AND (COALESCE(p_include_inactive,FALSE) OR product.is_active)
        ORDER BY product.name,product.id LIMIT 200) bundle),
    'components',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',item.id,'bundle_id',item.bundle_id,'item_id',item.item_id,
      'component_uom_id',item.component_uom_id,
      'component_qty',item.component_qty,'line_no',item.line_no,
      'master_version',item.master_version)
      ORDER BY item.bundle_id,item.line_no,item.id),'[]'::JSONB)
      FROM public.product_bundle_items item
      JOIN public.products bundle ON bundle.company_id=item.company_id
        AND bundle.id=item.bundle_id
      WHERE item.company_id=v_company AND bundle.is_bundle
        AND (COALESCE(p_include_inactive,FALSE) OR bundle.is_active)),
    'salesUoms',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',product_uom.id,'product_id',product_uom.product_id,
      'uom_id',product_uom.uom_id,
      'factor_to_base',product_uom.factor_to_base,
      'sales_allowed',product_uom.sales_allowed,
      'sale_price',product_uom.sale_price,'barcode',product_uom.barcode,
      'is_active',product_uom.is_active)
      ORDER BY product_uom.product_id,product_uom.id),'[]'::JSONB)
      FROM public.product_uoms product_uom
      JOIN public.products bundle ON bundle.company_id=product_uom.company_id
        AND bundle.id=product_uom.product_id
      WHERE product_uom.company_id=v_company AND bundle.is_bundle
        AND (COALESCE(p_include_inactive,FALSE) OR (
          bundle.is_active AND product_uom.is_active))),
    'products',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',product.id,'sku',product.sku,'name',product.name,
      'is_bundle',product.is_bundle,'is_active',product.is_active,
      'weight_reference_uom_id',product.weight_reference_uom_id,
      'weight_per_uom_kg',product.weight_per_uom_kg,
      'product_uoms',COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'uom_id',product_uom.uom_id,
        'factor_to_base',product_uom.factor_to_base,
        'is_active',product_uom.is_active,
        'uom',jsonb_build_object('id',uom.id,'name',uom.name,
          'is_active',uom.is_active)) ORDER BY uom.name,product_uom.id)
        FROM public.product_uoms product_uom
        JOIN public.uoms uom ON uom.company_id=product_uom.company_id
          AND uom.id=product_uom.uom_id
        WHERE product_uom.company_id=v_company
          AND product_uom.product_id=product.id
          AND (COALESCE(p_include_inactive,FALSE) OR product_uom.is_active)),
        '[]'::JSONB)) ORDER BY product.name,product.id),'[]'::JSONB)
      FROM (SELECT candidate.* FROM public.products candidate
        WHERE candidate.company_id=v_company AND NOT candidate.is_bundle
          AND (COALESCE(p_include_inactive,FALSE) OR candidate.is_active)
        ORDER BY candidate.name,candidate.id LIMIT 500) product),
    'categories',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',category.id,'category_name',category.category_name,
      'is_active',category.is_active) ORDER BY category.category_name,
      category.id),'[]'::JSONB) FROM public.product_categories category
      WHERE category.company_id=v_company
        AND (COALESCE(p_include_inactive,FALSE) OR category.is_active)),
    'uoms',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',uom.id,'name',uom.name,'is_active',uom.is_active)
      ORDER BY uom.name,uom.id),'[]'::JSONB) FROM public.uoms uom
      WHERE uom.company_id=v_company
        AND (COALESCE(p_include_inactive,FALSE) OR uom.is_active)),
    'warehouses',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',warehouse.id,'name',warehouse.name,
      'is_active',warehouse.is_active) ORDER BY warehouse.name,warehouse.id),
      '[]'::JSONB) FROM public.warehouses warehouse
      WHERE warehouse.company_id=v_company
        AND (COALESCE(p_include_inactive,FALSE) OR warehouse.is_active)));
END
$$;

ALTER FUNCTION public.save_bundle_with_components(
  UUID,BIGINT,TEXT,TEXT,UUID,UUID,NUMERIC,TEXT,TEXT,BOOLEAN,JSONB)
  RENAME TO acp5g_save_bundle_with_components_core;
ALTER FUNCTION public.acp5g_save_bundle_with_components_core(
  UUID,BIGINT,TEXT,TEXT,UUID,UUID,NUMERIC,TEXT,TEXT,BOOLEAN,JSONB)
  SET SCHEMA private;

CREATE FUNCTION public.save_bundle_with_components(
  p_bundle_id UUID,p_master_version BIGINT,p_sku TEXT,p_name TEXT,
  p_category_id UUID,p_sales_uom_id UUID,p_sale_price NUMERIC,p_barcode TEXT,
  p_image_url TEXT,p_is_active BOOLEAN,p_components JSONB
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'sales.bundles','MANAGE');
  RETURN private.acp5g_save_bundle_with_components_core(
    p_bundle_id,p_master_version,p_sku,p_name,p_category_id,p_sales_uom_id,
    p_sale_price,p_barcode,p_image_url,p_is_active,p_components);
END
$$;

ALTER FUNCTION public.get_bundle_availability(UUID,UUID)
  RENAME TO acp5g_get_bundle_availability_core;
ALTER FUNCTION public.acp5g_get_bundle_availability_core(UUID,UUID)
  SET SCHEMA private;

CREATE FUNCTION public.get_bundle_availability(
  p_bundle_id UUID,p_warehouse_id UUID
) RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'sales.bundles','VIEW');
  RETURN private.acp5g_get_bundle_availability_core(
    p_bundle_id,p_warehouse_id);
END
$$;

DO $enforce$
DECLARE v_rows BIGINT;
BEGIN
  UPDATE public.access_permission_catalog SET
    enforcement_status='ENFORCED',catalog_version=catalog_version+1,
    updated_at=clock_timestamp()
  WHERE permission_key='sales.bundles' AND enforcement_status='SHADOW';
  GET DIAGNOSTICS v_rows=ROW_COUNT;
  IF v_rows<>1 THEN RAISE EXCEPTION 'BUNDLE_PERMISSION_CUTOVER_FAILED'; END IF;
END
$enforce$;

REVOKE SELECT ON public.product_bundle_items,
  public.product_bundle_master_audit FROM authenticated;

REVOKE ALL ON FUNCTION private.acp5g_save_bundle_with_components_core(
  UUID,BIGINT,TEXT,TEXT,UUID,UUID,NUMERIC,TEXT,TEXT,BOOLEAN,JSONB),
  private.acp5g_get_bundle_availability_core(UUID,UUID)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.acp5g_save_bundle_with_components_core(
  UUID,BIGINT,TEXT,TEXT,UUID,UUID,NUMERIC,TEXT,TEXT,BOOLEAN,JSONB),
  private.acp5g_get_bundle_availability_core(UUID,UUID) TO service_role;

REVOKE ALL ON FUNCTION public.get_sales_bundles(BOOLEAN),
  public.save_bundle_with_components(
    UUID,BIGINT,TEXT,TEXT,UUID,UUID,NUMERIC,TEXT,TEXT,BOOLEAN,JSONB),
  public.get_bundle_availability(UUID,UUID) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_sales_bundles(BOOLEAN),
  public.save_bundle_with_components(
    UUID,BIGINT,TEXT,TEXT,UUID,UUID,NUMERIC,TEXT,TEXT,BOOLEAN,JSONB),
  public.get_bundle_availability(UUID,UUID) TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260813040000','acp_phase5g_bundle_permission_enforcement',
  'Enforced Bundle VIEW/MANAGE with atomic composition, narrow availability, and independent POS authority');

COMMIT;
