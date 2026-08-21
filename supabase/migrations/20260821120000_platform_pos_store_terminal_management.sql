-- Platform POS setup: guarded Store and POS Terminal management.
BEGIN;

DO $guard$
BEGIN
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260821120000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260821120000';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260820100000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: terminal UI foundation required';
  END IF;
END
$guard$;

ALTER TABLE public.stores
  ADD COLUMN operational_master_version BIGINT NOT NULL DEFAULT 1,
  ADD COLUMN operational_updated_by UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
  ADD CONSTRAINT stores_operational_master_version_positive
    CHECK(operational_master_version>0);

ALTER TABLE public.pos_terminals
  ADD COLUMN operational_master_version BIGINT NOT NULL DEFAULT 1,
  ADD COLUMN operational_updated_by UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
  ADD CONSTRAINT pos_terminals_operational_master_version_positive
    CHECK(operational_master_version>0);

CREATE TABLE public.platform_pos_master_audit(
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id UUID NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
  entity_type TEXT NOT NULL CHECK(entity_type IN('STORE','TERMINAL')),
  entity_id UUID NOT NULL,
  action TEXT NOT NULL CHECK(action IN('CREATE','UPDATE')),
  actor_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  before_state JSONB,
  after_state JSONB NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX idx_platform_pos_master_audit_scope
  ON public.platform_pos_master_audit(company_id,entity_type,entity_id,created_at DESC);

CREATE FUNCTION private.trg_platform_pos_master_audit_immutable()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path=public,pg_temp AS $$
BEGIN
  RAISE EXCEPTION 'PLATFORM_POS_MASTER_AUDIT_IMMUTABLE';
END
$$;
CREATE TRIGGER trg_platform_pos_master_audit_immutable
BEFORE UPDATE OR DELETE ON public.platform_pos_master_audit
FOR EACH ROW EXECUTE FUNCTION private.trg_platform_pos_master_audit_immutable();

CREATE FUNCTION private.require_platform_pos_manager(p_company_id UUID)
RETURNS UUID LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_actor UUID:=auth.uid();
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF public.private_active_company_id() IS DISTINCT FROM p_company_id THEN
    RAISE EXCEPTION 'ACTIVE_COMPANY_CONTEXT_MISMATCH';
  END IF;
  IF NOT public.private_is_super_admin(v_actor) AND NOT EXISTS(
    SELECT 1 FROM public.company_memberships membership
    WHERE membership.company_id=p_company_id AND membership.user_id=v_actor
      AND membership.status='ACTIVE'
      AND membership.role_code IN('COMPANY_OWNER','COMPANY_ADMIN')) THEN
    RAISE EXCEPTION 'PLATFORM_POS_MANAGEMENT_ACCESS_DENIED';
  END IF;
  RETURN v_actor;
END
$$;

CREATE FUNCTION public.get_platform_pos_setup()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_actor UUID;
BEGIN
  v_actor:=private.require_platform_pos_manager(v_company);
  RETURN jsonb_build_object(
    'companyId',v_company,
    'stores',COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'id',store.id,'code',store.store_code,'name',store.store_name,
      'address',store.address,'timezone',store.timezone,'status',store.status,
      'masterVersion',store.operational_master_version,
      'activeTerminalCount',(SELECT count(*) FROM public.pos_terminals terminal
        WHERE terminal.company_id=v_company AND terminal.store_id=store.id
          AND terminal.status='ACTIVE'),
      'openSessionCount',(SELECT count(*) FROM public.cashier_sessions session
        WHERE session.company_id=v_company AND session.store_id=store.id
          AND session.status='OPEN'::public.session_status)
    ) ORDER BY store.store_name,store.id)
      FROM public.stores store WHERE store.company_id=v_company),'[]'::JSONB),
    'terminals',COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'id',terminal.id,'storeId',terminal.store_id,'code',terminal.pos_code,
      'name',terminal.pos_name,'deviceIdentifier',terminal.device_identifier,
      'status',terminal.status,'masterVersion',terminal.operational_master_version,
      'hiddenFeatureKeys',to_jsonb(terminal.hidden_feature_keys),
      'uiSettingsMasterVersion',terminal.ui_settings_master_version,
      'openSessionCount',(SELECT count(*) FROM public.cashier_sessions session
        WHERE session.company_id=v_company AND session.pos_id=terminal.id
          AND session.status='OPEN'::public.session_status)
    ) ORDER BY terminal.pos_name,terminal.id)
      FROM public.pos_terminals terminal WHERE terminal.company_id=v_company),'[]'::JSONB),
    'warehouses',COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'id',warehouse.id,'name',warehouse.name,'storeId',warehouse.store_id,
      'isSaleSource',warehouse.is_sale_source,'isActive',warehouse.is_active)
      ORDER BY warehouse.name,warehouse.id)
      FROM public.warehouses warehouse WHERE warehouse.company_id=v_company),'[]'::JSONB)
  );
END
$$;

CREATE FUNCTION public.save_platform_pos_store(
  p_store_id UUID,p_expected_version BIGINT,p_store_code TEXT,p_store_name TEXT,
  p_address TEXT,p_timezone TEXT,p_status TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_actor UUID;
  v_current public.stores%ROWTYPE;v_saved public.stores%ROWTYPE;
  v_code TEXT:=upper(btrim(COALESCE(p_store_code,'')));
  v_name TEXT:=btrim(COALESCE(p_store_name,''));
  v_address TEXT:=NULLIF(btrim(COALESCE(p_address,'')),'');
  v_timezone TEXT:=btrim(COALESCE(p_timezone,'Asia/Jakarta'));
  v_status TEXT:=upper(btrim(COALESCE(p_status,'')));
BEGIN
  v_actor:=private.require_platform_pos_manager(v_company);
  IF v_code='' OR char_length(v_code)>50 THEN RAISE EXCEPTION 'INVALID_STORE_CODE'; END IF;
  IF v_name='' OR char_length(v_name)>150 THEN RAISE EXCEPTION 'INVALID_STORE_NAME'; END IF;
  IF v_address IS NOT NULL AND char_length(v_address)>1000 THEN RAISE EXCEPTION 'INVALID_STORE_ADDRESS'; END IF;
  IF v_status NOT IN('ACTIVE','INACTIVE') THEN RAISE EXCEPTION 'INVALID_STORE_STATUS'; END IF;
  IF NOT EXISTS(SELECT 1 FROM pg_timezone_names zone WHERE zone.name=v_timezone) THEN
    RAISE EXCEPTION 'INVALID_STORE_TIMEZONE';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('PLATFORM_POS_STORE|'||v_company::TEXT,0));
  IF p_store_id IS NULL THEN
    IF EXISTS(SELECT 1 FROM public.stores store WHERE store.company_id=v_company AND
      upper(regexp_replace(btrim(store.store_code),'\s+',' ','g'))=
      upper(regexp_replace(v_code,'\s+',' ','g'))) THEN RAISE EXCEPTION 'DUPLICATE_STORE_CODE'; END IF;
    INSERT INTO public.stores(company_id,store_code,store_name,address,timezone,status,
      operational_master_version,operational_updated_by)
    VALUES(v_company,v_code,v_name,v_address,v_timezone,v_status,1,v_actor)
    RETURNING * INTO v_saved;
    INSERT INTO public.platform_pos_master_audit(
      company_id,entity_type,entity_id,action,actor_id,after_state)
    VALUES(v_company,'STORE',v_saved.id,'CREATE',v_actor,to_jsonb(v_saved));
    RETURN jsonb_build_object('action','CREATE','storeId',v_saved.id,
      'masterVersion',v_saved.operational_master_version);
  END IF;
  SELECT * INTO v_current FROM public.stores store
  WHERE store.company_id=v_company AND store.id=p_store_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'STORE_NOT_FOUND'; END IF;
  IF v_code IS DISTINCT FROM v_current.store_code THEN RAISE EXCEPTION 'STORE_CODE_IMMUTABLE'; END IF;
  IF (v_current.store_name,v_current.address,v_current.timezone,v_current.status)
     IS NOT DISTINCT FROM (v_name,v_address,v_timezone,v_status) THEN
    RETURN jsonb_build_object('action','EXACT_RETRY','storeId',v_current.id,
      'masterVersion',v_current.operational_master_version);
  END IF;
  IF p_expected_version IS DISTINCT FROM v_current.operational_master_version THEN
    RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
  END IF;
  IF v_status='INACTIVE' AND v_current.status='ACTIVE' AND (
    EXISTS(SELECT 1 FROM public.cashier_sessions session
      WHERE session.company_id=v_company AND session.store_id=v_current.id
        AND session.status='OPEN'::public.session_status)
    OR EXISTS(SELECT 1 FROM public.pos_terminals terminal
      WHERE terminal.company_id=v_company AND terminal.store_id=v_current.id
        AND terminal.status='ACTIVE')
    OR EXISTS(SELECT 1 FROM public.warehouses warehouse
      WHERE warehouse.company_id=v_company AND warehouse.store_id=v_current.id
        AND warehouse.is_active)) THEN RAISE EXCEPTION 'STORE_HAS_ACTIVE_OPERATIONAL_DEPENDENCY'; END IF;
  UPDATE public.stores SET store_name=v_name,address=v_address,timezone=v_timezone,
    status=v_status,operational_master_version=v_current.operational_master_version+1,
    operational_updated_by=v_actor,updated_at=clock_timestamp()
  WHERE id=v_current.id RETURNING * INTO v_saved;
  INSERT INTO public.platform_pos_master_audit(
    company_id,entity_type,entity_id,action,actor_id,before_state,after_state)
  VALUES(v_company,'STORE',v_saved.id,'UPDATE',v_actor,to_jsonb(v_current),to_jsonb(v_saved));
  RETURN jsonb_build_object('action','UPDATE','storeId',v_saved.id,
    'masterVersion',v_saved.operational_master_version);
END
$$;

CREATE FUNCTION public.save_platform_pos_terminal(
  p_terminal_id UUID,p_expected_version BIGINT,p_store_id UUID,p_pos_code TEXT,
  p_pos_name TEXT,p_device_identifier TEXT,p_status TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_actor UUID;
  v_current public.pos_terminals%ROWTYPE;v_saved public.pos_terminals%ROWTYPE;
  v_code TEXT:=upper(btrim(COALESCE(p_pos_code,'')));
  v_name TEXT:=btrim(COALESCE(p_pos_name,''));
  v_device TEXT:=NULLIF(btrim(COALESCE(p_device_identifier,'')),'');
  v_status TEXT:=upper(btrim(COALESCE(p_status,'')));
BEGIN
  v_actor:=private.require_platform_pos_manager(v_company);
  IF p_store_id IS NULL OR NOT EXISTS(SELECT 1 FROM public.stores store
    WHERE store.company_id=v_company AND store.id=p_store_id AND store.status='ACTIVE') THEN
    RAISE EXCEPTION 'ACTIVE_STORE_NOT_FOUND';
  END IF;
  IF v_code='' OR char_length(v_code)>50 THEN RAISE EXCEPTION 'INVALID_POS_CODE'; END IF;
  IF v_name='' OR char_length(v_name)>150 THEN RAISE EXCEPTION 'INVALID_POS_NAME'; END IF;
  IF v_device IS NOT NULL AND char_length(v_device)>200 THEN RAISE EXCEPTION 'INVALID_DEVICE_IDENTIFIER'; END IF;
  IF v_status NOT IN('ACTIVE','INACTIVE') THEN RAISE EXCEPTION 'INVALID_POS_STATUS'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('PLATFORM_POS_TERMINAL|'||v_company::TEXT,0));
  IF p_terminal_id IS NULL THEN
    IF EXISTS(SELECT 1 FROM public.pos_terminals terminal WHERE terminal.company_id=v_company
      AND terminal.store_id=p_store_id AND upper(regexp_replace(btrim(terminal.pos_code),'\s+',' ','g'))=
      upper(regexp_replace(v_code,'\s+',' ','g'))) THEN RAISE EXCEPTION 'DUPLICATE_POS_CODE'; END IF;
    INSERT INTO public.pos_terminals(company_id,store_id,pos_code,pos_name,
      device_identifier,status,operational_master_version,operational_updated_by)
    VALUES(v_company,p_store_id,v_code,v_name,v_device,v_status,1,v_actor)
    RETURNING * INTO v_saved;
    INSERT INTO public.platform_pos_master_audit(
      company_id,entity_type,entity_id,action,actor_id,after_state)
    VALUES(v_company,'TERMINAL',v_saved.id,'CREATE',v_actor,to_jsonb(v_saved));
    RETURN jsonb_build_object('action','CREATE','terminalId',v_saved.id,
      'masterVersion',v_saved.operational_master_version);
  END IF;
  SELECT * INTO v_current FROM public.pos_terminals terminal
  WHERE terminal.company_id=v_company AND terminal.id=p_terminal_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'POS_TERMINAL_NOT_FOUND'; END IF;
  IF v_code IS DISTINCT FROM v_current.pos_code THEN RAISE EXCEPTION 'POS_CODE_IMMUTABLE'; END IF;
  IF (v_current.store_id,v_current.pos_name,v_current.device_identifier,v_current.status)
     IS NOT DISTINCT FROM (p_store_id,v_name,v_device,v_status) THEN
    RETURN jsonb_build_object('action','EXACT_RETRY','terminalId',v_current.id,
      'masterVersion',v_current.operational_master_version);
  END IF;
  IF p_expected_version IS DISTINCT FROM v_current.operational_master_version THEN
    RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
  END IF;
  IF EXISTS(SELECT 1 FROM public.cashier_sessions session
    WHERE session.company_id=v_company AND session.pos_id=v_current.id
      AND session.status='OPEN'::public.session_status) THEN
    RAISE EXCEPTION 'TERMINAL_HAS_OPEN_SESSION';
  END IF;
  IF p_store_id IS DISTINCT FROM v_current.store_id AND EXISTS(
    SELECT 1 FROM public.cashier_sessions session
    WHERE session.company_id=v_company AND session.pos_id=v_current.id) THEN
    RAISE EXCEPTION 'TERMINAL_STORE_LOCKED_BY_HISTORY';
  END IF;
  UPDATE public.pos_terminals SET store_id=p_store_id,pos_name=v_name,
    device_identifier=v_device,status=v_status,
    operational_master_version=v_current.operational_master_version+1,
    operational_updated_by=v_actor,updated_at=clock_timestamp()
  WHERE id=v_current.id RETURNING * INTO v_saved;
  INSERT INTO public.platform_pos_master_audit(
    company_id,entity_type,entity_id,action,actor_id,before_state,after_state)
  VALUES(v_company,'TERMINAL',v_saved.id,'UPDATE',v_actor,to_jsonb(v_current),to_jsonb(v_saved));
  RETURN jsonb_build_object('action','UPDATE','terminalId',v_saved.id,
    'masterVersion',v_saved.operational_master_version);
END
$$;

ALTER TABLE public.platform_pos_master_audit ENABLE ROW LEVEL SECURITY;
CREATE POLICY platform_pos_master_audit_read ON public.platform_pos_master_audit
FOR SELECT TO authenticated USING(
  public.private_request_company_matches(company_id)
  AND (public.private_is_super_admin(auth.uid()) OR public.private_user_has_any_company_role(
    company_id,ARRAY['COMPANY_OWNER','COMPANY_ADMIN']::TEXT[])));

REVOKE ALL ON public.platform_pos_master_audit FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.platform_pos_master_audit TO authenticated;
GRANT ALL ON public.platform_pos_master_audit TO service_role;
REVOKE INSERT,UPDATE,DELETE ON public.stores,public.pos_terminals FROM authenticated;
REVOKE ALL ON FUNCTION private.require_platform_pos_manager(UUID),
  private.trg_platform_pos_master_audit_immutable() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.require_platform_pos_manager(UUID),
  private.trg_platform_pos_master_audit_immutable() TO service_role;
REVOKE ALL ON FUNCTION public.get_platform_pos_setup(),
  public.save_platform_pos_store(UUID,BIGINT,TEXT,TEXT,TEXT,TEXT,TEXT),
  public.save_platform_pos_terminal(UUID,BIGINT,UUID,TEXT,TEXT,TEXT,TEXT)
  FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_platform_pos_setup(),
  public.save_platform_pos_store(UUID,BIGINT,TEXT,TEXT,TEXT,TEXT,TEXT),
  public.save_platform_pos_terminal(UUID,BIGINT,UUID,TEXT,TEXT,TEXT,TEXT)
  TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260821120000','platform_pos_store_terminal_management',
  'Adds guarded audited Store and POS Terminal management under Platform; PWA company and terminal selection remains session-locked');
NOTIFY pgrst,'reload schema';
COMMIT;
