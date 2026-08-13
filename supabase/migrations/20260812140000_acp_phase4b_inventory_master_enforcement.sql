-- ACP-4B: enforce inventory.master_data end-to-end without changing public RPC signatures.

BEGIN;

DO $guard$
BEGIN
  IF (SELECT count(*) FROM private.kgs_schema_migrations
      WHERE version IN('20260812120000','20260812130000'))<>2 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: ACP-2/4A required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260812140000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED';
  END IF;
  IF EXISTS(SELECT 1 FROM public.master_import_jobs
    WHERE status NOT IN('COMPLETED','COMPLETED_WITH_ERRORS','FAILED','CANCELED')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal import job';
  END IF;
END
$guard$;

CREATE FUNCTION private.acp_require_permission_capability(
  p_company_id UUID,p_permission_key TEXT,p_capability TEXT
) RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp
AS $$
DECLARE v_actor UUID:=auth.uid();v_resolution JSONB;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF NOT public.private_request_company_matches(p_company_id) THEN
    RAISE EXCEPTION 'ACTIVE_COMPANY_CONTEXT_MISMATCH';
  END IF;
  v_resolution:=private.acp_resolve_permission(p_company_id,v_actor,p_permission_key);
  IF (v_resolution->>'enforced')::BOOLEAN
     AND NOT ((v_resolution->'effectiveCapabilities') ? upper(p_capability)) THEN
    RAISE EXCEPTION 'CUSTOM_PERMISSION_DENIED';
  END IF;
  RETURN v_resolution;
END;
$$;

ALTER TABLE public.inventory_master_write_audit
  DROP CONSTRAINT inventory_master_audit_type_check;
ALTER TABLE public.inventory_master_write_audit
  ADD CONSTRAINT inventory_master_audit_type_check
  CHECK(master_type IN('PRODUCT_CATEGORY','UOM','WAREHOUSE'));

-- Preserve proven ACP-4A and G2 implementations as private cores.
ALTER FUNCTION public.save_inventory_uom(UUID,BIGINT,TEXT,TEXT,BOOLEAN,SMALLINT,BOOLEAN)
  SET SCHEMA private;
ALTER FUNCTION public.save_inventory_warehouse(UUID,BIGINT,TEXT,TEXT,UUID,TEXT,BOOLEAN,BOOLEAN,BOOLEAN)
  SET SCHEMA private;
ALTER FUNCTION public.save_product_category_tax_assignment(UUID,BIGINT,UUID,UUID)
  SET SCHEMA private;

CREATE FUNCTION public.save_inventory_uom(
  p_uom_id UUID,p_expected_version BIGINT,p_name TEXT,p_uom_type TEXT,
  p_allow_decimal BOOLEAN,p_decimal_precision SMALLINT,p_is_active BOOLEAN
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp
AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'inventory.master_data','MANAGE'
  );
  RETURN private.save_inventory_uom(
    p_uom_id,p_expected_version,p_name,p_uom_type,p_allow_decimal,
    p_decimal_precision,p_is_active
  );
END;
$$;

CREATE FUNCTION public.save_inventory_warehouse(
  p_warehouse_id UUID,p_expected_version BIGINT,p_name TEXT,
  p_warehouse_type TEXT,p_store_id UUID,p_location TEXT,
  p_is_sale_source BOOLEAN,p_is_purchase_destination BOOLEAN,p_is_active BOOLEAN
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp
AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'inventory.master_data','MANAGE'
  );
  RETURN private.save_inventory_warehouse(
    p_warehouse_id,p_expected_version,p_name,p_warehouse_type,p_store_id,
    p_location,p_is_sale_source,p_is_purchase_destination,p_is_active
  );
END;
$$;

CREATE FUNCTION public.save_product_category_tax_assignment(
  p_category_id UUID,p_master_version BIGINT,
  p_sales_tax_rule_id UUID,p_purchase_tax_rule_id UUID
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp
AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'inventory.master_data','MANAGE'
  );
  RETURN private.save_product_category_tax_assignment(
    p_category_id,p_master_version,p_sales_tax_rule_id,p_purchase_tax_rule_id
  );
END;
$$;

CREATE FUNCTION public.save_inventory_product_category(
  p_category_id UUID,p_expected_version BIGINT,p_category_name TEXT,p_is_active BOOLEAN
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp
AS $$
DECLARE
  v_company UUID:=public.private_active_company_id();v_actor UUID;
  v_name TEXT:=btrim(COALESCE(p_category_name,''));
  v_active BOOLEAN:=COALESCE(p_is_active,TRUE);
  v_current public.product_categories%ROWTYPE;
  v_saved public.product_categories%ROWTYPE;v_before JSONB;
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'inventory.master_data','MANAGE'
  );
  v_actor:=private.acp_require_inventory_master_actor(v_company);
  IF v_name='' OR length(v_name)>150 THEN RAISE EXCEPTION 'MASTER_NAME_INVALID'; END IF;

  IF p_category_id IS NULL THEN
    IF p_expected_version IS NOT NULL THEN RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
    SELECT * INTO v_current FROM public.product_categories
    WHERE company_id=v_company
      AND lower(regexp_replace(btrim(category_name),'\s+',' ','g'))=
          lower(regexp_replace(v_name,'\s+',' ','g')) FOR UPDATE;
    IF FOUND THEN
      IF v_current.is_active=v_active THEN
        RETURN jsonb_build_object('success',TRUE,'action','EXACT_RETRY','data',to_jsonb(v_current));
      END IF;
      RAISE EXCEPTION 'MASTER_NAME_ALREADY_EXISTS';
    END IF;
    INSERT INTO public.product_categories(
      company_id,category_code,category_name,is_active,created_by,updated_by
    ) VALUES(v_company,NULL,v_name,v_active,v_actor,v_actor)
    RETURNING * INTO v_saved;
    INSERT INTO public.inventory_master_write_audit(
      company_id,master_type,master_id,actor_id,action,after_state
    ) VALUES(v_company,'PRODUCT_CATEGORY',v_saved.id,v_actor,'CREATE',to_jsonb(v_saved));
  ELSE
    SELECT * INTO v_current FROM public.product_categories
    WHERE company_id=v_company AND id=p_category_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'MASTER_NOT_FOUND'; END IF;
    IF v_current.category_name=v_name AND v_current.is_active=v_active THEN
      RETURN jsonb_build_object('success',TRUE,'action','EXACT_RETRY','data',to_jsonb(v_current));
    END IF;
    IF p_expected_version IS DISTINCT FROM v_current.master_version THEN
      RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
    END IF;
    v_before:=to_jsonb(v_current);
    UPDATE public.product_categories SET category_name=v_name,is_active=v_active,
      updated_by=v_actor
    WHERE company_id=v_company AND id=p_category_id RETURNING * INTO v_saved;
    INSERT INTO public.inventory_master_write_audit(
      company_id,master_type,master_id,actor_id,action,before_state,after_state
    ) VALUES(v_company,'PRODUCT_CATEGORY',v_saved.id,v_actor,'UPDATE',v_before,to_jsonb(v_saved));
  END IF;
  RETURN jsonb_build_object('success',TRUE,
    'action',CASE WHEN p_category_id IS NULL THEN 'CREATE' ELSE 'UPDATE' END,
    'data',to_jsonb(v_saved));
END;
$$;

-- Close the legacy column-level identity write that table-level checks miss.
REVOKE INSERT,UPDATE,DELETE ON public.product_categories FROM authenticated;
REVOKE INSERT(company_id,category_code,category_name,is_active)
  ON public.product_categories FROM authenticated;
REVOKE UPDATE(category_code,category_name,is_active)
  ON public.product_categories FROM authenticated;

DO $enforce$
DECLARE v_rows BIGINT;
BEGIN
  UPDATE public.access_permission_catalog SET
    enforcement_status='ENFORCED',catalog_version=catalog_version+1,
    updated_at=clock_timestamp()
  WHERE permission_key='inventory.master_data' AND enforcement_status='SHADOW';
  GET DIAGNOSTICS v_rows=ROW_COUNT;
  IF v_rows<>1 THEN RAISE EXCEPTION 'INVENTORY_MASTER_PERMISSION_NOT_SHADOW'; END IF;
END
$enforce$;

REVOKE ALL ON FUNCTION
  private.acp_require_permission_capability(UUID,TEXT,TEXT),
  private.save_inventory_uom(UUID,BIGINT,TEXT,TEXT,BOOLEAN,SMALLINT,BOOLEAN),
  private.save_inventory_warehouse(UUID,BIGINT,TEXT,TEXT,UUID,TEXT,BOOLEAN,BOOLEAN,BOOLEAN),
  private.save_product_category_tax_assignment(UUID,BIGINT,UUID,UUID),
  public.save_inventory_uom(UUID,BIGINT,TEXT,TEXT,BOOLEAN,SMALLINT,BOOLEAN),
  public.save_inventory_warehouse(UUID,BIGINT,TEXT,TEXT,UUID,TEXT,BOOLEAN,BOOLEAN,BOOLEAN),
  public.save_product_category_tax_assignment(UUID,BIGINT,UUID,UUID),
  public.save_inventory_product_category(UUID,BIGINT,TEXT,BOOLEAN)
FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION
  private.acp_require_permission_capability(UUID,TEXT,TEXT),
  private.save_inventory_uom(UUID,BIGINT,TEXT,TEXT,BOOLEAN,SMALLINT,BOOLEAN),
  private.save_inventory_warehouse(UUID,BIGINT,TEXT,TEXT,UUID,TEXT,BOOLEAN,BOOLEAN,BOOLEAN),
  private.save_product_category_tax_assignment(UUID,BIGINT,UUID,UUID)
FROM authenticated;
GRANT EXECUTE ON FUNCTION
  public.save_inventory_uom(UUID,BIGINT,TEXT,TEXT,BOOLEAN,SMALLINT,BOOLEAN),
  public.save_inventory_warehouse(UUID,BIGINT,TEXT,TEXT,UUID,TEXT,BOOLEAN,BOOLEAN,BOOLEAN),
  public.save_product_category_tax_assignment(UUID,BIGINT,UUID,UUID),
  public.save_inventory_product_category(UUID,BIGINT,TEXT,BOOLEAN)
TO authenticated,service_role;
GRANT EXECUTE ON FUNCTION
  private.acp_require_permission_capability(UUID,TEXT,TEXT),
  private.save_inventory_uom(UUID,BIGINT,TEXT,TEXT,BOOLEAN,SMALLINT,BOOLEAN),
  private.save_inventory_warehouse(UUID,BIGINT,TEXT,TEXT,UUID,TEXT,BOOLEAN,BOOLEAN,BOOLEAN),
  private.save_product_category_tax_assignment(UUID,BIGINT,UUID,UUID)
TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260812140000','acp_phase4b_inventory_master_enforcement',
  'Enforced inventory.master_data navigation/API/RPC boundary with guarded Category identity and compatibility wrappers');

COMMIT;
