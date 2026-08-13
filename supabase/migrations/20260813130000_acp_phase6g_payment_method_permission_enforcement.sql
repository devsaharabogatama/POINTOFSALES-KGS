-- ACP-6G: Payment Method composed reads, effective permission enforcement,
-- separately authorized POS/Expense references, export, and audit closure.

BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260813120000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: ACP-6F required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260813130000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED';
  END IF;
  IF (SELECT count(*) FROM public.access_permission_catalog
    WHERE permission_key='finance.payment_methods'
      AND enforcement_status='SHADOW')<>1 THEN
    RAISE EXCEPTION 'PAYMENT_METHOD_PERMISSION_NOT_SHADOW';
  END IF;
  IF EXISTS(SELECT 1 FROM public.companies company
    WHERE company.status='ACTIVE' AND (SELECT count(*)
      FROM public.payment_methods method
      WHERE method.company_id=company.id AND method.is_active
        AND method.is_default)<>1) THEN
    RAISE EXCEPTION 'PAYMENT_METHOD_DEFAULT_CONTRACT_INVALID';
  END IF;
END
$guard$;

-- Legacy/provisioning rows did not have an actor. Record that truth explicitly
-- instead of attributing the historical action to an arbitrary user.
ALTER TABLE public.payment_method_master_audit
  DROP CONSTRAINT IF EXISTS payment_method_master_audit_action_check;
ALTER TABLE public.payment_method_master_audit
  ALTER COLUMN actor_id DROP NOT NULL;
ALTER TABLE public.payment_method_master_audit
  ADD CONSTRAINT payment_method_master_audit_action_check
  CHECK(action IN('CREATE','UPDATE','BACKFILL'));

INSERT INTO public.payment_method_master_audit(
  company_id,payment_method_id,action,actor_id,before_state,after_state,
  created_at)
SELECT method.company_id,method.id,'BACKFILL',NULL,NULL,
  to_jsonb(method)||jsonb_build_object('auditProvenance','ACP6G_BACKFILL'),
  COALESCE(method.created_at,clock_timestamp())
FROM public.payment_methods method
WHERE NOT EXISTS(SELECT 1 FROM public.payment_method_master_audit audit
  WHERE audit.company_id=method.company_id
    AND audit.payment_method_id=method.id);

CREATE FUNCTION private.trg_acp6g_payment_method_audit_immutable()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
BEGIN
  RAISE EXCEPTION 'PAYMENT_METHOD_AUDIT_IMMUTABLE';
END
$$;
CREATE TRIGGER acp6g_payment_method_audit_immutable
BEFORE UPDATE OR DELETE ON public.payment_method_master_audit
FOR EACH ROW EXECUTE FUNCTION private.trg_acp6g_payment_method_audit_immutable();

CREATE FUNCTION private.trg_acp6g_audit_provisioned_payment_method()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
BEGIN
  IF NEW.is_system_method OR NEW.created_by IS NULL THEN
    INSERT INTO public.payment_method_master_audit(
      company_id,payment_method_id,action,actor_id,before_state,after_state)
    VALUES(NEW.company_id,NEW.id,
      CASE WHEN NEW.created_by IS NULL THEN 'BACKFILL' ELSE 'CREATE' END,
      NEW.created_by,NULL,to_jsonb(NEW)||jsonb_build_object(
        'auditProvenance','SYSTEM_PROVISION'));
  END IF;
  RETURN NEW;
END
$$;
CREATE TRIGGER acp6g_audit_provisioned_payment_method
AFTER INSERT ON public.payment_methods FOR EACH ROW
EXECUTE FUNCTION private.trg_acp6g_audit_provisioned_payment_method();

CREATE FUNCTION public.get_finance_payment_methods()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_permission JSONB;
BEGIN
  v_permission:=private.acp_require_permission_capability(
    v_company,'finance.payment_methods','VIEW');
  RETURN jsonb_build_object(
    'companyId',v_company,'effectiveCapabilities',COALESCE(
      v_permission->'effectiveCapabilities','[]'::JSONB),
    'data',(SELECT COALESCE(jsonb_agg(to_jsonb(method_row)||
      jsonb_build_object('store_assignments',COALESCE((SELECT jsonb_agg(
        jsonb_build_object('id',assignment.id,
          'payment_method_id',assignment.payment_method_id,
          'store_id',assignment.store_id) ORDER BY assignment.store_id)
        FROM public.payment_method_store_assignments assignment
        WHERE assignment.company_id=v_company
          AND assignment.payment_method_id=method_row.id),'[]'::JSONB))
      ORDER BY method_row.is_default DESC,method_row.payment_method_name,
        method_row.id),'[]'::JSONB)
      FROM (SELECT method.id,method.company_id,method.payment_method_code,
        method.payment_method_name,method.method_type,method.settlement_route,
        method.is_default,method.available_all_stores,method.proof_mode,
        method.fee_enabled,method.fee_bearer,method.fee_type,
        method.fee_percent,method.fee_fixed_amount,
        method.clearing_account_function,method.bank_account_function,
        method.effective_from,method.effective_to,method.is_active,
        method.is_system_method,method.master_version,method.created_at,
        method.updated_at FROM public.payment_methods method
        WHERE method.company_id=v_company ORDER BY method.is_default DESC,
          method.payment_method_name,method.id LIMIT 300) method_row),
    'stores',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',store.id,'store_code',store.store_code,
      'store_name',store.store_name,'status',store.status)
      ORDER BY store.store_name,store.id),'[]'::JSONB)
      FROM public.stores store WHERE store.company_id=v_company
        AND store.status='ACTIVE'),
    'accountFunctions',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'function_key',function_row.function_key,
      'function_name',function_row.function_name,
      'is_active',function_row.is_active) ORDER BY function_row.function_name,
      function_row.function_key),'[]'::JSONB)
      FROM public.account_functions function_row WHERE function_row.is_active
        AND EXISTS(SELECT 1 FROM public.payment_methods method
          WHERE method.company_id=v_company AND (
            method.clearing_account_function=function_row.function_key OR
            method.bank_account_function=function_row.function_key))),
    'audit',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',audit.id,'payment_method_id',audit.payment_method_id,
      'action',audit.action,'actor_id',audit.actor_id,
      'created_at',audit.created_at) ORDER BY audit.created_at DESC,audit.id DESC),
      '[]'::JSONB) FROM (SELECT candidate.*
        FROM public.payment_method_master_audit candidate
        WHERE candidate.company_id=v_company ORDER BY candidate.created_at DESC,
          candidate.id DESC LIMIT 1000) audit));
END
$$;

CREATE FUNCTION public.get_pos_payment_method_references(p_store_id UUID)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_actor UUID:=auth.uid();
BEGIN
  IF NOT EXISTS(SELECT 1 FROM public.cashier_sessions session
    WHERE session.company_id=v_company AND session.cashier_id=v_actor
      AND session.store_id=p_store_id
      AND session.status='OPEN'::public.session_status) THEN
    RAISE EXCEPTION 'OPEN_CASHIER_SESSION_REQUIRED';
  END IF;
  RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object(
    'id',method.id,'payment_method_name',method.payment_method_name,
    'method_type',method.method_type,'proof_mode',method.proof_mode,
    'is_default',method.is_default,
    'fee_bearer',method.fee_bearer,'fee_enabled',method.fee_enabled,
    'fee_type',method.fee_type,'fee_percent',method.fee_percent,
    'fee_fixed_amount',method.fee_fixed_amount)
    ORDER BY method.is_default DESC,method.payment_method_name,method.id)
    FROM public.payment_methods method WHERE method.company_id=v_company
      AND method.is_active AND method.method_type NOT IN('KETUL_OFFSET','TEMPO')
      AND method.effective_from<=clock_timestamp()
      AND (method.effective_to IS NULL OR method.effective_to>=clock_timestamp())
      AND (method.available_all_stores OR EXISTS(SELECT 1
        FROM public.payment_method_store_assignments assignment
        WHERE assignment.company_id=v_company
          AND assignment.payment_method_id=method.id
          AND assignment.store_id=p_store_id))),'[]'::JSONB);
END
$$;

CREATE FUNCTION public.get_finance_expense_payment_method_references()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'finance.expenses','POST');
  RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object(
    'id',method.id,'payment_method_name',method.payment_method_name,
    'method_type',method.method_type,'settlement_route',method.settlement_route,
    'proof_mode',method.proof_mode,'is_active',method.is_active)
    ORDER BY method.is_default DESC,method.payment_method_name,method.id)
    FROM public.payment_methods method WHERE method.company_id=v_company
      AND method.is_active AND method.method_type NOT IN('CUSTOMER_BALANCE','KETUL_OFFSET','TEMPO')
      AND method.effective_from<=clock_timestamp()
      AND (method.effective_to IS NULL OR method.effective_to>=clock_timestamp())),
    '[]'::JSONB);
END
$$;

CREATE FUNCTION public.export_finance_payment_methods()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'finance.payment_methods','EXPORT');
  RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object(
    'methodName',method.payment_method_name,'methodType',method.method_type,
    'settlementRoute',method.settlement_route,'isDefault',method.is_default,
    'storeScope',CASE WHEN method.available_all_stores THEN 'SEMUA TOKO'
      ELSE COALESCE((SELECT string_agg(store.store_name,', '
        ORDER BY store.store_name) FROM public.payment_method_store_assignments assignment
        JOIN public.stores store ON store.company_id=assignment.company_id
          AND store.id=assignment.store_id WHERE assignment.company_id=v_company
          AND assignment.payment_method_id=method.id),'') END,
    'proofMode',method.proof_mode,'feeEnabled',method.fee_enabled,
    'feeBearer',method.fee_bearer,'feeType',method.fee_type,
    'feePercent',method.fee_percent,'feeFixedAmount',method.fee_fixed_amount,
    'effectiveFrom',method.effective_from,'effectiveTo',method.effective_to,
    'isActive',method.is_active,'systemOwned',method.is_system_method)
    ORDER BY method.payment_method_name,method.id)
    FROM public.payment_methods method WHERE method.company_id=v_company),
    '[]'::JSONB);
END
$$;

ALTER FUNCTION public.save_payment_method(
  UUID,BIGINT,TEXT,TEXT,TEXT,TEXT,BOOLEAN,BOOLEAN,UUID[],TEXT,BOOLEAN,
  TEXT,TEXT,NUMERIC,NUMERIC,TEXT,TEXT,TIMESTAMPTZ,TIMESTAMPTZ,BOOLEAN)
  SET SCHEMA private;
ALTER FUNCTION private.save_payment_method(
  UUID,BIGINT,TEXT,TEXT,TEXT,TEXT,BOOLEAN,BOOLEAN,UUID[],TEXT,BOOLEAN,
  TEXT,TEXT,NUMERIC,NUMERIC,TEXT,TEXT,TIMESTAMPTZ,TIMESTAMPTZ,BOOLEAN)
  RENAME TO acp6g_save_payment_method_core;

CREATE FUNCTION public.save_payment_method(
  p_payment_method_id UUID,p_master_version BIGINT,p_payment_method_code TEXT,
  p_payment_method_name TEXT,p_method_type TEXT,p_settlement_route TEXT,
  p_is_default BOOLEAN,p_available_all_stores BOOLEAN,p_store_ids UUID[],
  p_proof_mode TEXT,p_fee_enabled BOOLEAN,p_fee_bearer TEXT,p_fee_type TEXT,
  p_fee_percent NUMERIC,p_fee_fixed_amount NUMERIC,
  p_clearing_account_function TEXT,p_bank_account_function TEXT,
  p_effective_from TIMESTAMPTZ,p_effective_to TIMESTAMPTZ,p_is_active BOOLEAN
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'finance.payment_methods','MANAGE');
  RETURN private.acp6g_save_payment_method_core(p_payment_method_id,
    p_master_version,p_payment_method_code,p_payment_method_name,p_method_type,
    p_settlement_route,p_is_default,p_available_all_stores,p_store_ids,
    p_proof_mode,p_fee_enabled,p_fee_bearer,p_fee_type,p_fee_percent,
    p_fee_fixed_amount,p_clearing_account_function,p_bank_account_function,
    p_effective_from,p_effective_to,p_is_active);
END
$$;

CREATE OR REPLACE FUNCTION public.save_payment_method(
  p_payment_method_id UUID,p_master_version BIGINT,p_payment_method_name TEXT,
  p_method_type TEXT,p_settlement_route TEXT,p_is_default BOOLEAN,
  p_available_all_stores BOOLEAN,p_store_ids UUID[],p_proof_mode TEXT,
  p_fee_enabled BOOLEAN,p_fee_bearer TEXT,p_fee_type TEXT,p_fee_percent NUMERIC,
  p_fee_fixed_amount NUMERIC,p_clearing_account_function TEXT,
  p_bank_account_function TEXT,p_effective_from TIMESTAMPTZ,
  p_effective_to TIMESTAMPTZ,p_is_active BOOLEAN
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'finance.payment_methods','MANAGE');
  RETURN private.acp6g_save_payment_method_core(p_payment_method_id,
    p_master_version,private.resolve_or_allocate_master_code(
      'PAYMENT_METHOD',p_payment_method_id,'PAYMENT_METHOD_NOT_FOUND'),
    p_payment_method_name,p_method_type,p_settlement_route,p_is_default,
    p_available_all_stores,p_store_ids,p_proof_mode,p_fee_enabled,p_fee_bearer,
    p_fee_type,p_fee_percent,p_fee_fixed_amount,p_clearing_account_function,
    p_bank_account_function,p_effective_from,p_effective_to,p_is_active);
END
$$;

DO $enforce$
DECLARE v_rows BIGINT;
BEGIN
  UPDATE public.access_permission_catalog SET enforcement_status='ENFORCED',
    catalog_version=catalog_version+1,updated_at=clock_timestamp()
  WHERE permission_key='finance.payment_methods'
    AND enforcement_status='SHADOW';
  GET DIAGNOSTICS v_rows=ROW_COUNT;
  IF v_rows<>1 THEN RAISE EXCEPTION 'PAYMENT_METHOD_PERMISSION_CUTOVER_FAILED'; END IF;
END
$enforce$;

REVOKE SELECT ON public.payment_methods,
  public.payment_method_store_assignments,public.payment_method_master_audit
FROM authenticated;

REVOKE ALL ON FUNCTION private.trg_acp6g_payment_method_audit_immutable(),
  private.trg_acp6g_audit_provisioned_payment_method(),
  private.acp6g_save_payment_method_core(
    UUID,BIGINT,TEXT,TEXT,TEXT,TEXT,BOOLEAN,BOOLEAN,UUID[],TEXT,BOOLEAN,
    TEXT,TEXT,NUMERIC,NUMERIC,TEXT,TEXT,TIMESTAMPTZ,TIMESTAMPTZ,BOOLEAN)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.trg_acp6g_payment_method_audit_immutable(),
  private.trg_acp6g_audit_provisioned_payment_method(),
  private.acp6g_save_payment_method_core(
    UUID,BIGINT,TEXT,TEXT,TEXT,TEXT,BOOLEAN,BOOLEAN,UUID[],TEXT,BOOLEAN,
    TEXT,TEXT,NUMERIC,NUMERIC,TEXT,TEXT,TIMESTAMPTZ,TIMESTAMPTZ,BOOLEAN)
TO service_role;

REVOKE ALL ON FUNCTION public.get_finance_payment_methods(),
  public.get_pos_payment_method_references(UUID),
  public.get_finance_expense_payment_method_references(),
  public.export_finance_payment_methods(),
  public.save_payment_method(
    UUID,BIGINT,TEXT,TEXT,TEXT,TEXT,BOOLEAN,BOOLEAN,UUID[],TEXT,BOOLEAN,
    TEXT,TEXT,NUMERIC,NUMERIC,TEXT,TEXT,TIMESTAMPTZ,TIMESTAMPTZ,BOOLEAN),
  public.save_payment_method(
    UUID,BIGINT,TEXT,TEXT,TEXT,BOOLEAN,BOOLEAN,UUID[],TEXT,BOOLEAN,TEXT,TEXT,
    NUMERIC,NUMERIC,TEXT,TEXT,TIMESTAMPTZ,TIMESTAMPTZ,BOOLEAN)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_finance_payment_methods(),
  public.get_pos_payment_method_references(UUID),
  public.get_finance_expense_payment_method_references(),
  public.export_finance_payment_methods(),
  public.save_payment_method(
    UUID,BIGINT,TEXT,TEXT,TEXT,TEXT,BOOLEAN,BOOLEAN,UUID[],TEXT,BOOLEAN,
    TEXT,TEXT,NUMERIC,NUMERIC,TEXT,TEXT,TIMESTAMPTZ,TIMESTAMPTZ,BOOLEAN),
  public.save_payment_method(
    UUID,BIGINT,TEXT,TEXT,TEXT,BOOLEAN,BOOLEAN,UUID[],TEXT,BOOLEAN,TEXT,TEXT,
    NUMERIC,NUMERIC,TEXT,TEXT,TIMESTAMPTZ,TIMESTAMPTZ,BOOLEAN)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260813130000','acp_phase6g_payment_method_permission_enforcement',
  'Payment Method composed read/export, effective Manage guard, separately authorized POS and Expense references, truthful legacy audit backfill, direct-read closure, and system workflow preservation');

NOTIFY pgrst,'reload schema';
COMMIT;
