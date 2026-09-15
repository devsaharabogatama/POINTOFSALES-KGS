-- Make Pricelist a first-class, server-authoritative Backoffice Quotation/SO header field.
-- Additive scope: workspace metadata and draft pricing selection only.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260909110000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical Backoffice Sales tax runtime required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260909120000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260909120000';
  END IF;
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

CREATE OR REPLACE FUNCTION public.get_backoffice_sales_order_workspace()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_default uuid;
BEGIN
  PERFORM private.acp_require_permission_capability(v_company,'sales.backoffice_orders','VIEW');
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
      'defaultPricelistId',customer.default_pricelist_id,
      'creditTermDays',customer.credit_term_days,'phone',customer.phone,
      'email',customer.email,'address',customer.address)
      ORDER BY customer.name) FROM public.customers customer
      WHERE customer.company_id=v_company AND customer.is_active),'[]'::jsonb),
    'pricelists',COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'id',pricelist.id,'name',pricelist.name,'scope',pricelist.scope,
      'isDefault',pricelist.is_default,'priority',pricelist.priority,
      'appliesAllStores',pricelist.applies_all_stores,
      'validFrom',pricelist.valid_from,'validUntil',pricelist.valid_until,
      'storeIds',COALESCE((SELECT jsonb_agg(assignment.store_id ORDER BY assignment.store_id)
        FROM public.pricelist_store_assignments assignment
        WHERE assignment.company_id=pricelist.company_id
          AND assignment.pricelist_id=pricelist.id),'[]'::jsonb))
      ORDER BY pricelist.scope,pricelist.priority DESC,pricelist.name)
      FROM public.pricelists pricelist
      WHERE pricelist.company_id=v_company AND pricelist.is_active),'[]'::jsonb),
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

ALTER FUNCTION private.resolve_pos_sale_price(uuid,uuid,uuid,uuid,numeric,timestamp with time zone)
  RENAME TO resolve_pos_sale_price_before_backoffice_header;

CREATE FUNCTION private.resolve_pos_sale_price(
  p_company_id uuid,p_store_id uuid,p_customer_id uuid,p_product_uom_id uuid,
  p_quantity numeric,p_resolved_at timestamp with time zone
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_result jsonb;v_backoffice_raw text;v_backoffice uuid;v_name text;
BEGIN
  v_result:=private.resolve_pos_sale_price_before_backoffice_header(
    p_company_id,p_store_id,p_customer_id,p_product_uom_id,p_quantity,p_resolved_at);
  v_backoffice_raw:=NULLIF(current_setting('kgs.backoffice_pricelist_id',true),'');
  IF v_backoffice_raw IS NULL THEN RETURN v_result; END IF;
  BEGIN v_backoffice:=v_backoffice_raw::uuid;
  EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'INVALID_PRICELIST_SELECTION'; END;
  SELECT pricelist.name INTO STRICT v_name FROM public.pricelists pricelist
  WHERE pricelist.company_id=p_company_id AND pricelist.id=v_backoffice;
  RETURN v_result||jsonb_build_object('pricelistId',v_backoffice,
    'pricelistName',v_name,'pricingSelectionSource','BACKOFFICE_EXPLICIT');
END
$$;

REVOKE ALL ON FUNCTION private.resolve_pos_sale_price_before_backoffice_header(uuid,uuid,uuid,uuid,numeric,timestamp with time zone),
  private.resolve_pos_sale_price(uuid,uuid,uuid,uuid,numeric,timestamp with time zone)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.resolve_pos_sale_price_before_backoffice_header(uuid,uuid,uuid,uuid,numeric,timestamp with time zone),
  private.resolve_pos_sale_price(uuid,uuid,uuid,uuid,numeric,timestamp with time zone)
TO service_role;

ALTER FUNCTION public.save_backoffice_sales_order_draft(uuid,bigint,uuid,jsonb)
  RENAME TO save_backoffice_sales_order_draft_before_pricelist_header;

REVOKE ALL ON FUNCTION public.save_backoffice_sales_order_draft_before_pricelist_header(uuid,bigint,uuid,jsonb)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.save_backoffice_sales_order_draft_before_pricelist_header(uuid,bigint,uuid,jsonb)
TO service_role;

CREATE FUNCTION public.save_backoffice_sales_order_draft(
  p_order_id uuid,p_expected_version bigint,p_operation_id uuid,p_payload jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_selected_raw text;v_selected uuid;
BEGIN
  IF p_payload IS NULL OR jsonb_typeof(p_payload)<>'object' THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_ORDER_PAYLOAD_INVALID';
  END IF;
  v_selected_raw:=NULLIF(btrim(COALESCE(p_payload->>'selectedPricelistId','')),'');
  IF v_selected_raw IS NOT NULL THEN
    BEGIN v_selected:=v_selected_raw::uuid;
    EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'INVALID_PRICELIST_SELECTION'; END;
  END IF;
  PERFORM set_config('kgs.selected_pricelist_id',COALESCE(v_selected::text,''),true);
  PERFORM set_config('kgs.backoffice_pricelist_id',COALESCE(v_selected::text,''),true);
  RETURN public.save_backoffice_sales_order_draft_before_pricelist_header(
    p_order_id,p_expected_version,p_operation_id,p_payload);
END
$$;

REVOKE ALL ON FUNCTION public.save_backoffice_sales_order_draft(uuid,bigint,uuid,jsonb)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.save_backoffice_sales_order_draft(uuid,bigint,uuid,jsonb)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260909120000','backoffice_sales_pricelist_header',
  'Expose Odoo-style Pricelist header metadata and reuse the canonical server price resolver for AUTO or explicit eligible selection; zero downstream fulfillment effect');
COMMIT;
