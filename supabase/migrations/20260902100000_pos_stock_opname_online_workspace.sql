-- POS online Stock Opname workspace and terminal visibility option.

BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260812190000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: ACP-4G Stock Opname required';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260825120000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Terminal UI runtime required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260902100000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED';
  END IF;
  IF to_regprocedure('public.get_pos_stock_opname_workspace()') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: workspace RPC already exists';
  END IF;
END
$guard$;

ALTER TABLE public.pos_terminals
  DROP CONSTRAINT pos_terminal_hidden_feature_keys_check;
ALTER TABLE public.pos_terminals
  ADD CONSTRAINT pos_terminal_hidden_feature_keys_check CHECK(
    hidden_feature_keys<@ARRAY[
      'SALES_RETURN','EXPENSE','STOCK_REQUEST','GOODS_RECEIPT',
      'PURCHASE_RETURN','CASH_DEPOSIT','STOCK_OPNAME','OFFLINE'
    ]::TEXT[]
  );

CREATE OR REPLACE FUNCTION public.save_pos_terminal_ui_settings(
  p_terminal_id UUID,p_expected_version BIGINT,p_hidden_feature_keys TEXT[],
  p_allow_price_override BOOLEAN
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_actor UUID:=auth.uid();v_company UUID:=public.private_active_company_id();
  v_terminal public.pos_terminals%ROWTYPE;v_hidden TEXT[];v_next BIGINT;
  v_allow BOOLEAN:=COALESCE(p_allow_price_override,FALSE);
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  SELECT ARRAY(SELECT DISTINCT upper(btrim(value))
    FROM unnest(COALESCE(p_hidden_feature_keys,'{}'::TEXT[])) value
    WHERE btrim(value)<>'' ORDER BY 1) INTO v_hidden;
  IF NOT v_hidden<@ARRAY['SALES_RETURN','EXPENSE','STOCK_REQUEST','GOODS_RECEIPT',
    'PURCHASE_RETURN','CASH_DEPOSIT','STOCK_OPNAME','OFFLINE']::TEXT[] THEN
    RAISE EXCEPTION 'INVALID_POS_TERMINAL_UI_FEATURE';
  END IF;
  SELECT * INTO v_terminal FROM public.pos_terminals terminal
  WHERE terminal.company_id=v_company AND terminal.id=p_terminal_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'POS_TERMINAL_NOT_FOUND'; END IF;
  IF NOT private.mads_can_manage_terminal_ui(v_actor,v_company,v_terminal.store_id) THEN
    RAISE EXCEPTION 'TERMINAL_UI_SETTINGS_ACCESS_DENIED';
  END IF;
  IF v_terminal.hidden_feature_keys=v_hidden
     AND v_terminal.allow_price_override=v_allow THEN
    RETURN jsonb_build_object('success',TRUE,'action','EXACT_RETRY',
      'terminalId',v_terminal.id,'hiddenFeatureKeys',to_jsonb(v_hidden),
      'allowPriceOverride',v_allow,'masterVersion',v_terminal.ui_settings_master_version);
  END IF;
  IF p_expected_version IS DISTINCT FROM v_terminal.ui_settings_master_version THEN
    RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
  END IF;
  v_next:=v_terminal.ui_settings_master_version+1;
  UPDATE public.pos_terminals SET hidden_feature_keys=v_hidden,
    allow_price_override=v_allow,ui_settings_master_version=v_next,
    ui_settings_updated_at=clock_timestamp(),ui_settings_updated_by=v_actor
  WHERE id=v_terminal.id;
  INSERT INTO public.pos_terminal_ui_setting_audit(
    company_id,terminal_id,action,before_state,after_state,actor_id
  ) VALUES(v_company,v_terminal.id,'UPDATE',jsonb_build_object(
      'hiddenFeatureKeys',to_jsonb(v_terminal.hidden_feature_keys),
      'allowPriceOverride',v_terminal.allow_price_override,
      'masterVersion',v_terminal.ui_settings_master_version),jsonb_build_object(
      'hiddenFeatureKeys',to_jsonb(v_hidden),'allowPriceOverride',v_allow,
      'masterVersion',v_next),v_actor);
  RETURN jsonb_build_object('success',TRUE,'action','UPDATE',
    'terminalId',v_terminal.id,'hiddenFeatureKeys',to_jsonb(v_hidden),
    'allowPriceOverride',v_allow,'masterVersion',v_next);
END
$$;

CREATE FUNCTION public.get_pos_stock_opname_workspace()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
  v_actor UUID:=auth.uid();
  v_company UUID:=public.private_active_company_id();
  v_resolution JSONB;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;

  v_resolution:=private.acp_resolve_permission(
    v_company,v_actor,'inventory.stock_opnames');
  IF (v_resolution->>'enforced')::BOOLEAN
     AND v_resolution->>'restrictionPreset' IN('LIHAT_SAJA','TANPA_AKSES') THEN
    RAISE EXCEPTION 'CUSTOM_PERMISSION_DENIED';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.warehouses warehouse
    WHERE warehouse.company_id=v_company AND warehouse.is_active
      AND public.private_stock_opname_counter_allowed(v_company,warehouse.id)) THEN
    RAISE EXCEPTION 'STOCK_OPNAME_COUNTER_REQUIRED';
  END IF;

  RETURN jsonb_build_object(
    'companyId',v_company,
    'warehouses',COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'id',warehouse.id,'name',warehouse.name,'storeId',warehouse.store_id)
      ORDER BY warehouse.name,warehouse.id)
      FROM public.warehouses warehouse
      WHERE warehouse.company_id=v_company AND warehouse.is_active
        AND public.private_stock_opname_counter_allowed(v_company,warehouse.id)),
      '[]'::JSONB),
    'categories',COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'id',category.id,'name',category.category_name)
      ORDER BY category.category_name,category.id)
      FROM public.product_categories category
      WHERE category.company_id=v_company AND category.is_active
        AND EXISTS(SELECT 1 FROM public.products product
          JOIN public.product_uoms product_uom
            ON product_uom.company_id=product.company_id
           AND product_uom.product_id=product.id
           AND product_uom.uom_id=product.uom_id
           AND product_uom.factor_to_base=1 AND product_uom.is_active
          WHERE product.company_id=v_company AND product.category_id=category.id
            AND product.is_active AND NOT product.is_bundle)),
      '[]'::JSONB),
    'products',COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'id',product.id,'sku',product.sku,'name',product.name,
        'categoryId',product.category_id,'uomName',uom.name,
        'allowDecimal',uom.allow_decimal,
        'decimalPrecision',uom.decimal_precision)
      ORDER BY product.name,product.sku,product.id)
      FROM public.products product
      JOIN public.product_uoms product_uom
        ON product_uom.company_id=product.company_id
       AND product_uom.product_id=product.id
       AND product_uom.uom_id=product.uom_id
       AND product_uom.factor_to_base=1 AND product_uom.is_active
      JOIN public.uoms uom ON uom.company_id=product.company_id
        AND uom.id=product.uom_id AND uom.is_active
      WHERE product.company_id=v_company AND product.is_active
        AND NOT product.is_bundle),'[]'::JSONB),
    'sessions',COALESCE((SELECT jsonb_agg(to_jsonb(session_row)
      ORDER BY session_row.created_at DESC,session_row.id)
      FROM (SELECT opname.id,opname.opname_no,opname.warehouse_id,
          warehouse.name warehouse_name,opname.status,opname.scope_type,
          opname.category_id,opname.notes,opname.master_version,
          opname.created_at,opname.updated_at,
          count(*) FILTER(WHERE line.line_status<>'SUPERSEDED') line_count,
          count(*) FILTER(WHERE line.line_status='PENDING') pending_count,
          count(*) FILTER(WHERE line.line_status='COUNTED') counted_count,
          count(*) FILTER(WHERE line.line_status='RECOUNT_REQUIRED')
            recount_required_count
        FROM public.stock_opnames opname
        JOIN public.warehouses warehouse
          ON warehouse.company_id=opname.company_id
         AND warehouse.id=opname.warehouse_id
        LEFT JOIN public.stock_opname_details line
          ON line.company_id=opname.company_id AND line.opname_id=opname.id
        WHERE opname.company_id=v_company AND opname.created_by=v_actor
          AND public.private_stock_opname_counter_allowed(
            v_company,opname.warehouse_id)
        GROUP BY opname.id,opname.opname_no,opname.warehouse_id,
          warehouse.name,opname.status,opname.scope_type,opname.category_id,
          opname.notes,opname.master_version,opname.created_at,opname.updated_at
        ORDER BY opname.created_at DESC,opname.id LIMIT 100) session_row),
      '[]'::JSONB)
  );
END
$$;

REVOKE ALL ON FUNCTION public.get_pos_stock_opname_workspace()
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_pos_stock_opname_workspace()
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260902100000','pos_stock_opname_online_workspace',
  'Added blind-safe online POS Stock Opname workspace and terminal visibility option without changing count or posting runtime');

NOTIFY pgrst,'reload schema';
COMMIT;
