-- Dedicated Transit Warehouse usage per operational Warehouse and operation.
-- Foundation only: no Stock/FIFO/Movement/Delivery mutation is activated here.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260909149000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Backoffice Delivery visibility required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260909150000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260909150000';
  END IF;
  IF to_regprocedure('private.save_inventory_warehouse(uuid,bigint,text,text,uuid,text,boolean,boolean,boolean)') IS NULL
    OR to_regprocedure('private.allocate_master_code(uuid,text)') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical Warehouse writer/code allocator missing';
  END IF;
END
$guard$;

ALTER TABLE public.warehouses
  ADD COLUMN transit_parent_warehouse_id uuid,
  ADD COLUMN transit_operation text,
  ADD CONSTRAINT warehouses_transit_parent_fk
    FOREIGN KEY(company_id,transit_parent_warehouse_id)
    REFERENCES public.warehouses(company_id,id) ON DELETE RESTRICT,
  ADD CONSTRAINT warehouses_transit_usage_shape_check CHECK(
    (transit_parent_warehouse_id IS NULL AND transit_operation IS NULL)
    OR (warehouse_type='TRANSIT' AND transit_parent_warehouse_id IS NOT NULL
      AND transit_parent_warehouse_id<>id
      AND transit_operation IN('SALES_DELIVERY_OUTBOUND',
        'WAREHOUSE_TRANSFER_OUTBOUND','CUSTOMER_RETURN_INBOUND')));

CREATE UNIQUE INDEX warehouses_active_transit_usage_unique
  ON public.warehouses(company_id,transit_parent_warehouse_id,transit_operation)
  WHERE is_active AND transit_parent_warehouse_id IS NOT NULL;

CREATE FUNCTION private.trg_guard_warehouse_transit_usage()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_parent public.warehouses%rowtype;
BEGIN
  IF NEW.transit_parent_warehouse_id IS NULL AND NEW.transit_operation IS NULL THEN
    RETURN NEW;
  END IF;
  IF NEW.warehouse_type IS DISTINCT FROM 'TRANSIT'
    OR NEW.transit_parent_warehouse_id IS NULL OR NEW.transit_operation IS NULL THEN
    RAISE EXCEPTION 'TRANSIT_USAGE_REQUIRES_TRANSIT_WAREHOUSE';
  END IF;
  SELECT * INTO v_parent FROM public.warehouses parent
  WHERE parent.company_id=NEW.company_id
    AND parent.id=NEW.transit_parent_warehouse_id FOR SHARE;
  IF NOT FOUND OR NOT v_parent.is_active OR v_parent.warehouse_type='TRANSIT' THEN
    RAISE EXCEPTION 'TRANSIT_PARENT_OPERATIONAL_WAREHOUSE_INVALID';
  END IF;
  IF NEW.is_sale_source OR NEW.is_purchase_destination OR NEW.allow_negative_stock THEN
    RAISE EXCEPTION 'TRANSIT_WAREHOUSE_OPERATION_FLAGS_INVALID';
  END IF;
  IF NEW.is_active AND EXISTS(SELECT 1 FROM public.warehouses existing
    WHERE existing.company_id=NEW.company_id AND existing.is_active
      AND existing.id<>NEW.id
      AND existing.transit_parent_warehouse_id=NEW.transit_parent_warehouse_id
      AND existing.transit_operation=NEW.transit_operation) THEN
    RAISE EXCEPTION 'TRANSIT_USAGE_ALREADY_ASSIGNED';
  END IF;
  RETURN NEW;
END
$$;

CREATE TRIGGER guard_warehouse_transit_usage
BEFORE INSERT OR UPDATE OF warehouse_type,transit_parent_warehouse_id,
  transit_operation,is_sale_source,is_purchase_destination,allow_negative_stock,
  is_active ON public.warehouses
FOR EACH ROW EXECUTE FUNCTION private.trg_guard_warehouse_transit_usage();

CREATE FUNCTION public.save_inventory_transit_warehouse(
  p_warehouse_id uuid,p_expected_version bigint,p_name text,
  p_parent_warehouse_id uuid,p_transit_operation text,p_location text,
  p_is_active boolean
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
  v_operation text:=upper(btrim(COALESCE(p_transit_operation,'')));
  v_current public.warehouses%rowtype;v_saved public.warehouses%rowtype;
  v_result jsonb;v_before jsonb;
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'inventory.master_data','MANAGE');
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF p_parent_warehouse_id IS NULL OR v_operation NOT IN(
      'SALES_DELIVERY_OUTBOUND','WAREHOUSE_TRANSFER_OUTBOUND',
      'CUSTOMER_RETURN_INBOUND') THEN
    RAISE EXCEPTION 'TRANSIT_USAGE_INPUT_INVALID';
  END IF;
  IF p_warehouse_id IS NOT NULL THEN
    SELECT * INTO v_current FROM public.warehouses warehouse
    WHERE warehouse.company_id=v_company AND warehouse.id=p_warehouse_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'MASTER_NOT_FOUND'; END IF;
    IF v_current.warehouse_type<>'TRANSIT' THEN
      RAISE EXCEPTION 'TRANSIT_WAREHOUSE_TYPE_CHANGE_NOT_ALLOWED';
    END IF;
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.warehouses parent
    WHERE parent.company_id=v_company AND parent.id=p_parent_warehouse_id
      AND parent.is_active AND parent.warehouse_type IS DISTINCT FROM 'TRANSIT') THEN
    RAISE EXCEPTION 'TRANSIT_PARENT_OPERATIONAL_WAREHOUSE_INVALID';
  END IF;
  IF EXISTS(SELECT 1 FROM public.warehouses existing
    WHERE existing.company_id=v_company AND existing.is_active
      AND existing.id IS DISTINCT FROM p_warehouse_id
      AND existing.transit_parent_warehouse_id=p_parent_warehouse_id
      AND existing.transit_operation=v_operation) THEN
    RAISE EXCEPTION 'TRANSIT_USAGE_ALREADY_ASSIGNED';
  END IF;
  v_result:=private.save_inventory_warehouse(p_warehouse_id,p_expected_version,
    p_name,'TRANSIT',NULL,p_location,false,false,p_is_active);
  SELECT * INTO STRICT v_saved FROM public.warehouses warehouse
  WHERE warehouse.company_id=v_company
    AND warehouse.id=(v_result->'data'->>'id')::uuid FOR UPDATE;
  IF v_saved.transit_parent_warehouse_id IS NOT DISTINCT FROM p_parent_warehouse_id
    AND v_saved.transit_operation IS NOT DISTINCT FROM v_operation THEN
    RETURN jsonb_build_object('success',true,'action',v_result->>'action',
      'data',to_jsonb(v_saved));
  END IF;
  v_before:=to_jsonb(v_saved);
  UPDATE public.warehouses SET transit_parent_warehouse_id=p_parent_warehouse_id,
    transit_operation=v_operation,updated_by=v_actor
  WHERE company_id=v_company AND id=v_saved.id RETURNING * INTO v_saved;
  INSERT INTO public.inventory_master_write_audit(company_id,master_type,
    master_id,actor_id,action,before_state,after_state)
  VALUES(v_company,'WAREHOUSE',v_saved.id,v_actor,'UPDATE',v_before,to_jsonb(v_saved));
  RETURN jsonb_build_object('success',true,'action',v_result->>'action',
    'data',to_jsonb(v_saved));
END
$$;

CREATE FUNCTION private.resolve_or_create_warehouse_transit(
  p_company_id uuid,p_parent_warehouse_id uuid,p_transit_operation text,
  p_actor_id uuid
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_operation text:=upper(btrim(COALESCE(p_transit_operation,'')));
  v_parent public.warehouses%rowtype;v_transit public.warehouses%rowtype;
  v_label text;
BEGIN
  IF p_actor_id IS NULL OR v_operation NOT IN('SALES_DELIVERY_OUTBOUND',
      'WAREHOUSE_TRANSFER_OUTBOUND','CUSTOMER_RETURN_INBOUND') THEN
    RAISE EXCEPTION 'TRANSIT_USAGE_INPUT_INVALID';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(p_company_id::text||':'||
    p_parent_warehouse_id::text||':'||v_operation,0));
  SELECT * INTO v_transit FROM public.warehouses warehouse
  WHERE warehouse.company_id=p_company_id AND warehouse.is_active
    AND warehouse.transit_parent_warehouse_id=p_parent_warehouse_id
    AND warehouse.transit_operation=v_operation FOR UPDATE;
  IF FOUND THEN RETURN v_transit.id; END IF;
  SELECT * INTO v_parent FROM public.warehouses parent
  WHERE parent.company_id=p_company_id AND parent.id=p_parent_warehouse_id
    AND parent.is_active AND parent.warehouse_type IS DISTINCT FROM 'TRANSIT' FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'TRANSIT_PARENT_OPERATIONAL_WAREHOUSE_INVALID'; END IF;
  v_label:=CASE v_operation
    WHEN 'SALES_DELIVERY_OUTBOUND' THEN 'Transit Pengiriman'
    WHEN 'WAREHOUSE_TRANSFER_OUTBOUND' THEN 'Transit Transfer'
    WHEN 'CUSTOMER_RETURN_INBOUND' THEN 'Transit Retur Customer' END;
  INSERT INTO public.warehouses(company_id,code,name,warehouse_type,store_id,
    location,is_sale_source,is_purchase_destination,allow_negative_stock,
    is_active,created_by,updated_by,transit_parent_warehouse_id,transit_operation)
  VALUES(p_company_id,NULL,left(v_label||' - '||v_parent.name,150),'TRANSIT',NULL,
    v_parent.location,false,false,false,true,p_actor_id,p_actor_id,
    p_parent_warehouse_id,v_operation) RETURNING * INTO v_transit;
  INSERT INTO public.inventory_master_write_audit(company_id,master_type,
    master_id,actor_id,action,after_state)
  VALUES(p_company_id,'WAREHOUSE',v_transit.id,p_actor_id,'CREATE',to_jsonb(v_transit));
  RETURN v_transit.id;
END
$$;

REVOKE ALL ON FUNCTION private.trg_guard_warehouse_transit_usage(),
  private.resolve_or_create_warehouse_transit(uuid,uuid,text,uuid)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.trg_guard_warehouse_transit_usage(),
  private.resolve_or_create_warehouse_transit(uuid,uuid,text,uuid) TO service_role;
REVOKE ALL ON FUNCTION public.save_inventory_transit_warehouse(
  uuid,bigint,text,uuid,text,text,boolean) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.save_inventory_transit_warehouse(
  uuid,bigint,text,uuid,text,text,boolean) TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260909150000','warehouse_transit_usage_foundation',
  'Dedicated active Transit usage per operational Warehouse and operation; guarded audited master writer and private lazy resolver; zero Stock/FIFO/Movement/Delivery effect');

NOTIFY pgrst,'reload schema';
COMMIT;
