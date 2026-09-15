BEGIN;

DO $test$
DECLARE v_actor uuid;v_company uuid;v_payload jsonb;v_other uuid;
  v_relation_count bigint;v_uom_count bigint;v_warehouse_count bigint;
BEGIN
  SELECT context.user_id,context.company_id INTO v_actor,v_company
  FROM public.user_active_company_contexts context
  JOIN public.profiles profile ON profile.id=context.user_id
  WHERE profile.role='super_admin' ORDER BY context.updated_at DESC LIMIT 1;
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: active Super Admin Company context required';
  END IF;
  PERFORM set_config('request.jwt.claim.sub',v_actor::text,true);
  PERFORM set_config('request.jwt.claim.role','authenticated',true);
  v_payload:=public.get_purchase_daily_replenishment_client_workspace();
  IF (v_payload->>'companyId')::uuid<>v_company
    OR (v_payload->>'clientWorkspaceVersion')::integer<>1
    OR jsonb_typeof(v_payload->'batches')<>'array'
    OR jsonb_typeof(v_payload->'lines')<>'array'
    OR jsonb_typeof(v_payload->'productSuppliers')<>'array'
    OR jsonb_typeof(v_payload->'purchaseUoms')<>'array'
    OR jsonb_typeof(v_payload->'receivingWarehouses')<>'array' THEN
    RAISE EXCEPTION 'TEST_FAILED: client workspace shape/tenant invalid';
  END IF;
  SELECT count(*) INTO v_relation_count FROM public.product_suppliers relation
  JOIN public.suppliers supplier ON supplier.company_id=relation.company_id
    AND supplier.id=relation.supplier_id AND supplier.is_active
  WHERE relation.company_id=v_company AND relation.is_active;
  SELECT count(*) INTO v_uom_count FROM public.product_uoms product_uom
  JOIN public.uoms uom ON uom.company_id=product_uom.company_id
    AND uom.id=product_uom.uom_id AND uom.is_active
  WHERE product_uom.company_id=v_company AND product_uom.is_active
    AND product_uom.purchase_allowed;
  SELECT count(*) INTO v_warehouse_count FROM public.warehouses warehouse
  WHERE warehouse.company_id=v_company AND warehouse.is_active
    AND warehouse.is_purchase_destination AND warehouse.warehouse_type<>'TRANSIT';
  IF jsonb_array_length(v_payload->'productSuppliers')<>v_relation_count
    OR jsonb_array_length(v_payload->'purchaseUoms')<>v_uom_count
    OR jsonb_array_length(v_payload->'receivingWarehouses')<>v_warehouse_count THEN
    RAISE EXCEPTION 'TEST_FAILED: client reference count mismatch';
  END IF;
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(v_payload->'productSuppliers') item
      WHERE NULLIF(item->>'id','') IS NULL OR NULLIF(item->>'productId','') IS NULL
        OR NULLIF(item->>'supplierId','') IS NULL OR NULLIF(item->>'purchaseUomId','') IS NULL)
    OR EXISTS(SELECT 1 FROM jsonb_array_elements(v_payload->'purchaseUoms') item
      WHERE NULLIF(item->>'uomId','') IS NULL OR NULLIF(item->>'uomName','') IS NULL
        OR (item->>'factorToBase')::numeric<=0) THEN
    RAISE EXCEPTION 'TEST_FAILED: exact relation/UOM identity missing';
  END IF;
  SELECT context.company_id INTO v_other FROM public.user_active_company_contexts context
  WHERE context.company_id<>v_company LIMIT 1;
  IF v_other IS NOT NULL AND (v_payload->>'companyId')::uuid=v_other THEN
    RAISE EXCEPTION 'TEST_FAILED: cross-Company workspace leak';
  END IF;
  RAISE NOTICE 'TEST_PASS: Purchase daily client workspace tenant/read contract; relationRows=%, uomRows=%, warehouseRows=%',
    v_relation_count,v_uom_count,v_warehouse_count;
END
$test$;

ROLLBACK;
