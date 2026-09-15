BEGIN;

DO $guard$
BEGIN
  IF (SELECT count(*) FROM private.kgs_schema_migrations WHERE version IN(
      '20260913100000','20260913110000','20260913120000','20260913130000',
      '20260914100000','20260914110000','20260914112000','20260914130000',
      '20260914140000','20260914141000'))<>10 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Purchase Step 1-6B chain required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260914150000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260914150000';
  END IF;
  IF to_regprocedure('public.get_purchase_daily_auto_ro_workspace()') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: daily RO workspace required';
  END IF;
  IF to_regprocedure('public.get_purchase_daily_replenishment_client_workspace()') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: client workspace collision';
  END IF;
END
$guard$;

CREATE FUNCTION public.get_purchase_daily_replenishment_client_workspace()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_base jsonb;
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'purchase.supplier_orders','VIEW');
  v_base:=public.get_purchase_daily_auto_ro_workspace();
  RETURN v_base||jsonb_build_object(
    'clientWorkspaceVersion',1,
    'batches',(SELECT COALESCE(jsonb_agg(to_jsonb(batch_row)
      ORDER BY batch_row.business_date DESC,batch_row.batch_no DESC),'[]'::jsonb)
      FROM (SELECT batch.*,profile.name generated_by_name
        FROM public.purchase_daily_batches batch
        LEFT JOIN public.profiles profile ON profile.id=batch.generated_by
        WHERE batch.company_id=v_company) batch_row),
    'suppliers',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',supplier.id,'supplierName',supplier.supplier_name)
      ORDER BY supplier.supplier_name,supplier.id),'[]'::jsonb)
      FROM public.suppliers supplier WHERE supplier.company_id=v_company
        AND supplier.is_active),
    'productSuppliers',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',relation.id,'productId',relation.product_id,
      'supplierId',relation.supplier_id,'purchaseUomId',relation.purchase_uom_id,
      'referencePurchasePrice',relation.reference_purchase_price,
      'lastPurchasePrice',relation.last_purchase_price,
      'preferred',relation.is_preferred_supplier)
      ORDER BY relation.product_id,relation.is_preferred_supplier DESC,
        relation.created_at,relation.id),'[]'::jsonb)
      FROM public.product_suppliers relation
      JOIN public.suppliers supplier ON supplier.company_id=relation.company_id
        AND supplier.id=relation.supplier_id AND supplier.is_active
      WHERE relation.company_id=v_company AND relation.is_active),
    'purchaseUoms',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'productId',product_uom.product_id,'uomId',product_uom.uom_id,
      'uomName',uom.name,'factorToBase',product_uom.factor_to_base,
      'allowDecimal',uom.allow_decimal,'decimalPrecision',uom.decimal_precision,
      'purchasePrice',product_uom.purchase_price)
      ORDER BY product_uom.product_id,product_uom.factor_to_base,product_uom.uom_id),
      '[]'::jsonb)
      FROM public.product_uoms product_uom
      JOIN public.uoms uom ON uom.company_id=product_uom.company_id
        AND uom.id=product_uom.uom_id AND uom.is_active
      WHERE product_uom.company_id=v_company AND product_uom.is_active
        AND product_uom.purchase_allowed),
    'receivingWarehouses',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',warehouse.id,'name',warehouse.name,'storeId',warehouse.store_id)
      ORDER BY warehouse.name,warehouse.id),'[]'::jsonb)
      FROM public.warehouses warehouse WHERE warehouse.company_id=v_company
        AND warehouse.is_active AND warehouse.is_purchase_destination
        AND warehouse.warehouse_type<>'TRANSIT'));
END
$$;

REVOKE ALL ON FUNCTION public.get_purchase_daily_replenishment_client_workspace()
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_purchase_daily_replenishment_client_workspace()
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260914150000','purchase_daily_client_workspace',
  'Expose exact Product-Supplier relation identity, purchase UOM conversion, and receiving Warehouse references for the approved RO/PO client without changing Purchase operations');

COMMIT;
