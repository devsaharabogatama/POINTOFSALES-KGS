-- ACP-4I: enforce Minimum Stock capability and composed read/import boundary.

BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260812200000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: ACP-4H required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260812210000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED';
  END IF;
  IF (SELECT count(*) FROM public.access_permission_catalog
    WHERE permission_key='inventory.minimum_stock'
      AND enforcement_status='SHADOW')<>1 THEN
    RAISE EXCEPTION 'MINIMUM_STOCK_PERMISSION_NOT_SHADOW';
  END IF;
  IF EXISTS(SELECT 1 FROM public.master_import_jobs
    WHERE status NOT IN('COMPLETED','COMPLETED_WITH_ERRORS','FAILED','CANCELED')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal import job';
  END IF;
END
$guard$;

-- Owner/Admin/Warehouse Admin retain Company-wide authority. Store Manager is
-- limited to warehouses belonging to an actively assigned Store.
CREATE FUNCTION private.acp_minimum_stock_warehouse_allowed(
  p_company_id UUID,p_warehouse_id UUID
) RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
  SELECT public.private_request_company_matches(p_company_id)
    AND EXISTS(SELECT 1 FROM public.warehouses warehouse
      WHERE warehouse.company_id=p_company_id AND warehouse.id=p_warehouse_id)
    AND (
      public.private_is_super_admin(auth.uid())
      OR public.private_user_has_any_company_role(
        p_company_id,ARRAY[
          'COMPANY_OWNER','COMPANY_ADMIN','WAREHOUSE_ADMIN']::TEXT[])
      OR EXISTS(
        SELECT 1 FROM public.warehouses warehouse
        WHERE warehouse.company_id=p_company_id AND warehouse.id=p_warehouse_id
          AND warehouse.store_id IS NOT NULL
          AND public.private_user_has_any_store_role(
            warehouse.store_id,ARRAY['STORE_MANAGER']::TEXT[])
      )
    );
$$;

ALTER FUNCTION public.save_product_warehouse_stock_setting(
  UUID,BIGINT,UUID,UUID,NUMERIC,BOOLEAN
) SET SCHEMA private;

CREATE FUNCTION public.save_product_warehouse_stock_setting(
  p_setting_id UUID,p_master_version BIGINT,p_product_id UUID,
  p_warehouse_id UUID,p_minimum_stock_base_qty NUMERIC,
  p_low_stock_alert_enabled BOOLEAN
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'inventory.minimum_stock','MANAGE');
  IF NOT private.acp_minimum_stock_warehouse_allowed(
    v_company,p_warehouse_id) THEN
    RAISE EXCEPTION 'MINIMUM_STOCK_WAREHOUSE_ACCESS_DENIED';
  END IF;
  RETURN private.save_product_warehouse_stock_setting(
    p_setting_id,p_master_version,p_product_id,p_warehouse_id,
    p_minimum_stock_base_qty,p_low_stock_alert_enabled);
END
$$;

CREATE FUNCTION public.get_inventory_minimum_stock()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE
  v_company UUID:=public.private_active_company_id();
  v_settings JSONB;v_products JSONB;v_warehouses JSONB;
  v_balances JSONB;v_audit JSONB;
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'inventory.minimum_stock','VIEW');

  SELECT COALESCE(jsonb_agg(to_jsonb(setting_row)
    ORDER BY setting_row.updated_at DESC,setting_row.id),'[]'::JSONB)
  INTO v_settings FROM (
    SELECT setting.id,setting.product_id,setting.warehouse_id,
      setting.minimum_stock_base_qty,setting.low_stock_alert_enabled,
      setting.master_version,setting.created_at,setting.updated_at
    FROM public.product_warehouse_stock_settings setting
    WHERE setting.company_id=v_company
      AND private.acp_minimum_stock_warehouse_allowed(
        v_company,setting.warehouse_id)
    ORDER BY setting.updated_at DESC,setting.id LIMIT 5000
  ) setting_row;

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
   AND product_uom.factor_to_base=1
  JOIN public.uoms uom ON uom.company_id=product_uom.company_id
    AND uom.id=product_uom.uom_id
  WHERE product.company_id=v_company AND (
    (product.is_active AND NOT product.is_bundle
      AND product_uom.is_active AND uom.is_active)
    OR EXISTS(SELECT 1 FROM public.product_warehouse_stock_settings setting
      WHERE setting.company_id=v_company AND setting.product_id=product.id
        AND private.acp_minimum_stock_warehouse_allowed(
          v_company,setting.warehouse_id)));

  SELECT COALESCE(jsonb_agg(to_jsonb(warehouse_row)
    ORDER BY warehouse_row.name,warehouse_row.id),'[]'::JSONB)
  INTO v_warehouses FROM (
    SELECT warehouse.id,warehouse.name,warehouse.warehouse_type,
      warehouse.location,warehouse.is_active
    FROM public.warehouses warehouse
    WHERE warehouse.company_id=v_company
      AND private.acp_minimum_stock_warehouse_allowed(v_company,warehouse.id)
      AND (warehouse.is_active OR EXISTS(
        SELECT 1 FROM public.product_warehouse_stock_settings setting
        WHERE setting.company_id=v_company
          AND setting.warehouse_id=warehouse.id))
    ORDER BY warehouse.name,warehouse.id LIMIT 5000
  ) warehouse_row;

  SELECT COALESCE(jsonb_agg(to_jsonb(balance_row)),'[]'::JSONB)
  INTO v_balances FROM (
    SELECT setting.product_id,setting.warehouse_id,
      COALESCE(stock.stock_qty,0)::NUMERIC stock_qty
    FROM public.product_warehouse_stock_settings setting
    LEFT JOIN public.product_stocks stock
      ON stock.company_id=setting.company_id
     AND stock.product_id=setting.product_id
     AND stock.warehouse_id=setting.warehouse_id
    WHERE setting.company_id=v_company
      AND private.acp_minimum_stock_warehouse_allowed(
        v_company,setting.warehouse_id)
  ) balance_row;

  SELECT COALESCE(jsonb_agg(to_jsonb(audit_row)
    ORDER BY audit_row.created_at DESC,audit_row.id DESC),'[]'::JSONB)
  INTO v_audit FROM (
    SELECT audit.id,audit.setting_id,audit.action,audit.actor_id,
      audit.created_at
    FROM public.product_warehouse_stock_setting_audit audit
    JOIN public.product_warehouse_stock_settings setting
      ON setting.company_id=audit.company_id AND setting.id=audit.setting_id
    WHERE audit.company_id=v_company
      AND private.acp_minimum_stock_warehouse_allowed(
        v_company,setting.warehouse_id)
    ORDER BY audit.created_at DESC,audit.id DESC LIMIT 10000
  ) audit_row;

  RETURN jsonb_build_object('companyId',v_company,'data',v_settings,
    'products',v_products,'warehouses',v_warehouses,
    'balances',v_balances,'audit',v_audit);
END
$$;

CREATE FUNCTION private.acp_require_minimum_stock_import_if_needed(
  p_company_id UUID,p_import_type TEXT
) RETURNS VOID LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
BEGIN
  IF upper(btrim(COALESCE(p_import_type,'')))=
     'PRODUCT_WAREHOUSE_MINIMUM_STOCK' THEN
    PERFORM private.acp_require_permission_capability(
      p_company_id,'inventory.minimum_stock','IMPORT');
  END IF;
END
$$;

CREATE OR REPLACE FUNCTION public.create_master_import_job(
  p_client_request_id UUID,p_import_type TEXT,p_reference_mode TEXT,
  p_operation_mode TEXT,p_file_name TEXT,p_file_checksum TEXT,
  p_delimiter TEXT DEFAULT ','
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp
AS $$ DECLARE v_company UUID:=public.private_active_company_id(); BEGIN
  PERFORM private.acp_require_product_import_if_needed(v_company,p_import_type);
  PERFORM private.acp_require_minimum_stock_import_if_needed(
    v_company,p_import_type);
  RETURN private.create_master_import_job(
    p_client_request_id,p_import_type,p_reference_mode,p_operation_mode,
    p_file_name,p_file_checksum,p_delimiter);
END $$;

CREATE OR REPLACE FUNCTION public.stage_master_import_rows(
  p_job_id UUID,p_master_version BIGINT,p_mapping JSONB,p_rows JSONB
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp
AS $$ DECLARE v_company UUID:=public.private_active_company_id();v_type TEXT; BEGIN
  SELECT import_type INTO v_type FROM public.master_import_jobs
  WHERE company_id=v_company AND id=p_job_id;
  PERFORM private.acp_require_product_import_if_needed(v_company,v_type);
  PERFORM private.acp_require_minimum_stock_import_if_needed(v_company,v_type);
  RETURN private.stage_master_import_rows(
    p_job_id,p_master_version,p_mapping,p_rows);
END $$;

CREATE OR REPLACE FUNCTION public.validate_master_import_job(
  p_job_id UUID,p_master_version BIGINT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp
AS $$ DECLARE v_company UUID:=public.private_active_company_id();v_type TEXT; BEGIN
  SELECT import_type INTO v_type FROM public.master_import_jobs
  WHERE company_id=v_company AND id=p_job_id;
  PERFORM private.acp_require_product_import_if_needed(v_company,v_type);
  PERFORM private.acp_require_minimum_stock_import_if_needed(v_company,v_type);
  RETURN private.validate_master_import_job(p_job_id,p_master_version);
END $$;

CREATE OR REPLACE FUNCTION public.commit_master_import_job(
  p_job_id UUID,p_master_version BIGINT,p_confirm_update_count INTEGER
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp
AS $$ DECLARE v_company UUID:=public.private_active_company_id();v_type TEXT; BEGIN
  SELECT import_type INTO v_type FROM public.master_import_jobs
  WHERE company_id=v_company AND id=p_job_id;
  PERFORM private.acp_require_product_import_if_needed(v_company,v_type);
  PERFORM private.acp_require_minimum_stock_import_if_needed(v_company,v_type);
  RETURN private.commit_master_import_job(
    p_job_id,p_master_version,p_confirm_update_count);
END $$;

DO $enforce$
DECLARE v_rows BIGINT;
BEGIN
  UPDATE public.access_permission_catalog SET
    enforcement_status='ENFORCED',catalog_version=catalog_version+1,
    updated_at=clock_timestamp()
  WHERE permission_key='inventory.minimum_stock'
    AND enforcement_status='SHADOW';
  GET DIAGNOSTICS v_rows=ROW_COUNT;
  IF v_rows<>1 THEN
    RAISE EXCEPTION 'MINIMUM_STOCK_PERMISSION_CUTOVER_FAILED';
  END IF;
END
$enforce$;

REVOKE SELECT ON public.product_warehouse_stock_settings,
  public.product_warehouse_stock_setting_audit FROM authenticated;

REVOKE ALL ON FUNCTION
  private.save_product_warehouse_stock_setting(
    UUID,BIGINT,UUID,UUID,NUMERIC,BOOLEAN),
  private.acp_minimum_stock_warehouse_allowed(UUID,UUID),
  private.acp_require_minimum_stock_import_if_needed(UUID,TEXT)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.save_product_warehouse_stock_setting(
    UUID,BIGINT,UUID,UUID,NUMERIC,BOOLEAN),
  private.acp_minimum_stock_warehouse_allowed(UUID,UUID),
  private.acp_require_minimum_stock_import_if_needed(UUID,TEXT)
TO service_role;

REVOKE ALL ON FUNCTION
  public.save_product_warehouse_stock_setting(
    UUID,BIGINT,UUID,UUID,NUMERIC,BOOLEAN),
  public.get_inventory_minimum_stock()
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION
  public.save_product_warehouse_stock_setting(
    UUID,BIGINT,UUID,UUID,NUMERIC,BOOLEAN),
  public.get_inventory_minimum_stock()
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260812210000','acp_phase4i_minimum_stock_permission_enforcement',
  'Enforced Minimum Stock composed read, Store-scoped management, type-aware import/export, and direct browser read closure');

NOTIFY pgrst,'reload schema';
COMMIT;
