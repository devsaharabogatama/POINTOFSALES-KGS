-- ACP-4A: close browser write boundary for simple Inventory masters.
-- UOM/Warehouse writes move to guarded RPC; Store/Terminal remain read-only.

BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260812120000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: ACP-2 required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260812130000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED';
  END IF;
END
$guard$;

CREATE TABLE public.inventory_master_write_audit(
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id UUID NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
  master_type TEXT NOT NULL,
  master_id UUID NOT NULL,
  actor_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  action TEXT NOT NULL,
  before_state JSONB,
  after_state JSONB NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT inventory_master_audit_type_check
    CHECK(master_type IN('UOM','WAREHOUSE')),
  CONSTRAINT inventory_master_audit_action_check
    CHECK(action IN('CREATE','UPDATE'))
);
CREATE INDEX idx_inventory_master_write_audit_scope
  ON public.inventory_master_write_audit(company_id,master_type,master_id,created_at DESC);

CREATE FUNCTION private.trg_acp_guard_inventory_master_audit()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp
AS $$ BEGIN RAISE EXCEPTION 'INVENTORY_MASTER_WRITE_AUDIT_IMMUTABLE'; END $$;
CREATE TRIGGER trg_acp_guard_inventory_master_audit
BEFORE UPDATE OR DELETE ON public.inventory_master_write_audit
FOR EACH ROW EXECUTE FUNCTION private.trg_acp_guard_inventory_master_audit();

CREATE FUNCTION private.acp_require_inventory_master_actor(p_company_id UUID)
RETURNS UUID LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp
AS $$
DECLARE v_actor UUID:=auth.uid();
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF NOT public.private_request_company_matches(p_company_id) THEN
    RAISE EXCEPTION 'ACTIVE_COMPANY_CONTEXT_MISMATCH';
  END IF;
  IF NOT public.private_user_has_any_company_or_store_role(
    p_company_id,
    ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','WAREHOUSE_ADMIN']::TEXT[]
  ) THEN RAISE EXCEPTION 'INVENTORY_MASTER_ACCESS_DENIED'; END IF;
  RETURN v_actor;
END;
$$;

CREATE FUNCTION public.save_inventory_uom(
  p_uom_id UUID,p_expected_version BIGINT,p_name TEXT,p_uom_type TEXT,
  p_allow_decimal BOOLEAN,p_decimal_precision SMALLINT,p_is_active BOOLEAN
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp
AS $$
DECLARE
  v_company UUID:=public.private_active_company_id();
  v_actor UUID;v_current public.uoms%ROWTYPE;v_saved public.uoms%ROWTYPE;
  v_name TEXT:=btrim(COALESCE(p_name,''));
  v_type TEXT:=upper(btrim(COALESCE(p_uom_type,'')));
  v_allow BOOLEAN:=COALESCE(p_allow_decimal,FALSE);
  v_precision SMALLINT:=COALESCE(p_decimal_precision,0);
  v_active BOOLEAN:=COALESCE(p_is_active,TRUE);v_before JSONB;
BEGIN
  v_actor:=private.acp_require_inventory_master_actor(v_company);
  IF v_name='' OR length(v_name)>100 THEN RAISE EXCEPTION 'MASTER_NAME_INVALID'; END IF;
  IF v_type NOT IN('UNIT','PACKAGING','WEIGHT','VOLUME','LENGTH','OTHER') THEN
    RAISE EXCEPTION 'UOM_TYPE_INVALID';
  END IF;
  IF (NOT v_allow AND v_precision<>0) OR (v_allow AND v_precision NOT BETWEEN 1 AND 6) THEN
    RAISE EXCEPTION 'DECIMAL_PRECISION_INVALID';
  END IF;
  IF p_uom_id IS NULL THEN
    IF p_expected_version IS NOT NULL THEN RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
    SELECT * INTO v_current FROM public.uoms
    WHERE company_id=v_company
      AND lower(regexp_replace(btrim(name),'\s+',' ','g'))=
          lower(regexp_replace(v_name,'\s+',' ','g'))
    FOR UPDATE;
    IF FOUND THEN
      IF v_current.uom_type=v_type AND v_current.allow_decimal=v_allow
         AND v_current.decimal_precision=v_precision
         AND v_current.is_active=v_active THEN
        RETURN jsonb_build_object('success',TRUE,'action','EXACT_RETRY','data',to_jsonb(v_current));
      END IF;
      RAISE EXCEPTION 'MASTER_NAME_ALREADY_EXISTS';
    END IF;
    INSERT INTO public.uoms(company_id,code,name,uom_type,allow_decimal,decimal_precision,is_active)
    VALUES(v_company,NULL,v_name,v_type,v_allow,v_precision,v_active)
    RETURNING * INTO v_saved;
    INSERT INTO public.inventory_master_write_audit(
      company_id,master_type,master_id,actor_id,action,after_state
    ) VALUES(v_company,'UOM',v_saved.id,v_actor,'CREATE',to_jsonb(v_saved));
  ELSE
    SELECT * INTO v_current FROM public.uoms
    WHERE company_id=v_company AND id=p_uom_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'MASTER_NOT_FOUND'; END IF;
    IF v_current.name=v_name AND v_current.uom_type=v_type
       AND v_current.allow_decimal=v_allow
       AND v_current.decimal_precision=v_precision
       AND v_current.is_active=v_active THEN
      RETURN jsonb_build_object('success',TRUE,'action','EXACT_RETRY','data',to_jsonb(v_current));
    END IF;
    IF p_expected_version IS DISTINCT FROM v_current.master_version THEN
      RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
    END IF;
    v_before:=to_jsonb(v_current);
    UPDATE public.uoms SET name=v_name,uom_type=v_type,allow_decimal=v_allow,
      decimal_precision=v_precision,is_active=v_active
    WHERE company_id=v_company AND id=p_uom_id
    RETURNING * INTO v_saved;
    INSERT INTO public.inventory_master_write_audit(
      company_id,master_type,master_id,actor_id,action,before_state,after_state
    ) VALUES(v_company,'UOM',v_saved.id,v_actor,'UPDATE',v_before,to_jsonb(v_saved));
  END IF;
  RETURN jsonb_build_object('success',TRUE,'action',CASE WHEN p_uom_id IS NULL THEN 'CREATE' ELSE 'UPDATE' END,'data',to_jsonb(v_saved));
END;
$$;

CREATE FUNCTION public.save_inventory_warehouse(
  p_warehouse_id UUID,p_expected_version BIGINT,p_name TEXT,
  p_warehouse_type TEXT,p_store_id UUID,p_location TEXT,
  p_is_sale_source BOOLEAN,p_is_purchase_destination BOOLEAN,p_is_active BOOLEAN
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp
AS $$
DECLARE
  v_company UUID:=public.private_active_company_id();v_actor UUID;
  v_current public.warehouses%ROWTYPE;v_saved public.warehouses%ROWTYPE;
  v_name TEXT:=btrim(COALESCE(p_name,''));
  v_type TEXT:=upper(btrim(COALESCE(p_warehouse_type,'')));
  v_location TEXT:=NULLIF(btrim(COALESCE(p_location,'')),'');
  v_sale BOOLEAN:=COALESCE(p_is_sale_source,FALSE);
  v_purchase BOOLEAN:=COALESCE(p_is_purchase_destination,FALSE);
  v_active BOOLEAN:=COALESCE(p_is_active,TRUE);v_before JSONB;
BEGIN
  v_actor:=private.acp_require_inventory_master_actor(v_company);
  IF v_name='' OR length(v_name)>150 THEN RAISE EXCEPTION 'MASTER_NAME_INVALID'; END IF;
  IF v_type NOT IN('CENTRAL','STORE','DAMAGED','TRANSIT') THEN
    RAISE EXCEPTION 'WAREHOUSE_TYPE_INVALID';
  END IF;
  IF v_location IS NOT NULL AND length(v_location)>500 THEN RAISE EXCEPTION 'LOCATION_INVALID'; END IF;
  IF v_type='STORE' AND p_store_id IS NULL THEN RAISE EXCEPTION 'STORE_WAREHOUSE_REQUIRES_STORE'; END IF;
  IF p_store_id IS NOT NULL AND NOT EXISTS(
    SELECT 1 FROM public.stores store
    WHERE store.company_id=v_company AND store.id=p_store_id AND store.status='ACTIVE'
  ) THEN RAISE EXCEPTION 'ACTIVE_STORE_NOT_FOUND'; END IF;
  IF p_warehouse_id IS NULL THEN
    IF p_expected_version IS NOT NULL THEN RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
    SELECT * INTO v_current FROM public.warehouses
    WHERE company_id=v_company
      AND lower(regexp_replace(btrim(name),'\s+',' ','g'))=
          lower(regexp_replace(v_name,'\s+',' ','g'))
    FOR UPDATE;
    IF FOUND THEN
      IF v_current.warehouse_type=v_type
         AND v_current.store_id IS NOT DISTINCT FROM p_store_id
         AND v_current.location IS NOT DISTINCT FROM v_location
         AND v_current.is_sale_source=v_sale
         AND v_current.is_purchase_destination=v_purchase
         AND v_current.is_active=v_active THEN
        RETURN jsonb_build_object('success',TRUE,'action','EXACT_RETRY','data',to_jsonb(v_current));
      END IF;
      RAISE EXCEPTION 'MASTER_NAME_ALREADY_EXISTS';
    END IF;
    INSERT INTO public.warehouses(
      company_id,code,name,warehouse_type,store_id,location,is_sale_source,
      is_purchase_destination,allow_negative_stock,is_active
    ) VALUES(v_company,NULL,v_name,v_type,p_store_id,v_location,v_sale,v_purchase,FALSE,v_active)
    RETURNING * INTO v_saved;
    INSERT INTO public.inventory_master_write_audit(
      company_id,master_type,master_id,actor_id,action,after_state
    ) VALUES(v_company,'WAREHOUSE',v_saved.id,v_actor,'CREATE',to_jsonb(v_saved));
  ELSE
    SELECT * INTO v_current FROM public.warehouses
    WHERE company_id=v_company AND id=p_warehouse_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'MASTER_NOT_FOUND'; END IF;
    IF v_current.name=v_name AND v_current.warehouse_type=v_type
       AND v_current.store_id IS NOT DISTINCT FROM p_store_id
       AND v_current.location IS NOT DISTINCT FROM v_location
       AND v_current.is_sale_source=v_sale
       AND v_current.is_purchase_destination=v_purchase
       AND v_current.is_active=v_active THEN
      RETURN jsonb_build_object('success',TRUE,'action','EXACT_RETRY','data',to_jsonb(v_current));
    END IF;
    IF p_expected_version IS DISTINCT FROM v_current.master_version THEN
      RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
    END IF;
    v_before:=to_jsonb(v_current);
    UPDATE public.warehouses SET name=v_name,warehouse_type=v_type,
      store_id=p_store_id,location=v_location,is_sale_source=v_sale,
      is_purchase_destination=v_purchase,is_active=v_active
    WHERE company_id=v_company AND id=p_warehouse_id RETURNING * INTO v_saved;
    INSERT INTO public.inventory_master_write_audit(
      company_id,master_type,master_id,actor_id,action,before_state,after_state
    ) VALUES(v_company,'WAREHOUSE',v_saved.id,v_actor,'UPDATE',v_before,to_jsonb(v_saved));
  END IF;
  RETURN jsonb_build_object('success',TRUE,'action',CASE WHEN p_warehouse_id IS NULL THEN 'CREATE' ELSE 'UPDATE' END,'data',to_jsonb(v_saved));
END;
$$;

ALTER TABLE public.inventory_master_write_audit ENABLE ROW LEVEL SECURITY;
CREATE POLICY inventory_master_write_audit_company_read
ON public.inventory_master_write_audit FOR SELECT TO authenticated
USING(public.private_request_company_matches(company_id));

REVOKE INSERT,UPDATE,DELETE ON public.uoms,public.warehouses,
  public.stores,public.pos_terminals FROM authenticated;
REVOKE ALL ON public.inventory_master_write_audit FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.inventory_master_write_audit TO authenticated;
GRANT ALL ON public.inventory_master_write_audit TO service_role;

REVOKE ALL ON FUNCTION private.acp_require_inventory_master_actor(UUID),
  private.trg_acp_guard_inventory_master_audit(),
  public.save_inventory_uom(UUID,BIGINT,TEXT,TEXT,BOOLEAN,SMALLINT,BOOLEAN),
  public.save_inventory_warehouse(UUID,BIGINT,TEXT,TEXT,UUID,TEXT,BOOLEAN,BOOLEAN,BOOLEAN)
FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION private.acp_require_inventory_master_actor(UUID),
  private.trg_acp_guard_inventory_master_audit() FROM authenticated;
GRANT EXECUTE ON FUNCTION public.save_inventory_uom(
  UUID,BIGINT,TEXT,TEXT,BOOLEAN,SMALLINT,BOOLEAN
) TO authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.save_inventory_warehouse(
  UUID,BIGINT,TEXT,TEXT,UUID,TEXT,BOOLEAN,BOOLEAN,BOOLEAN
) TO authenticated,service_role;
GRANT EXECUTE ON FUNCTION private.acp_require_inventory_master_actor(UUID),
  private.trg_acp_guard_inventory_master_audit() TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260812130000','acp_phase4a_guarded_inventory_master_boundary',
  'Guarded audited UOM/Warehouse RPC and read-only browser Store/Terminal boundary');

COMMIT;
