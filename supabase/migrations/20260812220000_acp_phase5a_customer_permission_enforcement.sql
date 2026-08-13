-- ACP-5A: enforce Customer management without widening POS/Sales/Finance paths.

BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260812210000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: ACP-4I required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260812220000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED';
  END IF;
  IF (SELECT count(*) FROM public.access_permission_catalog
    WHERE permission_key='contacts.customers'
      AND enforcement_status='SHADOW')<>1 THEN
    RAISE EXCEPTION 'CUSTOMER_PERMISSION_NOT_SHADOW';
  END IF;
  IF EXISTS(SELECT 1 FROM public.master_import_jobs
    WHERE import_type='CUSTOMER_CATEGORY'
      AND status NOT IN('COMPLETED','COMPLETED_WITH_ERRORS','FAILED','CANCELED')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Customer Category import';
  END IF;
END
$guard$;

-- Preserve only the browser-facing codeless Category overload and canonical
-- Customer group/Pricelist writer as private cores. Lower-level explicit-code
-- functions remain callable by their SECURITY DEFINER parents but are removed
-- from authenticated execution below.
ALTER FUNCTION public.save_customer_category(UUID,BIGINT,TEXT,BOOLEAN)
  SET SCHEMA private;
ALTER FUNCTION public.save_customer_with_pricelist(
  UUID,BIGINT,TEXT,TEXT,UUID,TEXT,TEXT,TEXT,TEXT,NUMERIC,INTEGER,TEXT,
  BOOLEAN,UUID,UUID
) SET SCHEMA private;

CREATE FUNCTION public.save_customer_category(
  p_customer_category_id UUID,p_master_version BIGINT,
  p_category_name TEXT,p_is_active BOOLEAN
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'contacts.customers','MANAGE');
  RETURN private.save_customer_category(
    p_customer_category_id,p_master_version,p_category_name,p_is_active);
END
$$;

CREATE FUNCTION public.save_customer_with_pricelist(
  p_customer_id UUID,p_master_version BIGINT,p_customer_code TEXT,
  p_customer_name TEXT,p_customer_category_id UUID,p_phone TEXT,p_email TEXT,
  p_address TEXT,p_customer_type TEXT,p_credit_limit NUMERIC,
  p_credit_term_days INTEGER,p_notes TEXT,p_is_active BOOLEAN,
  p_parent_customer_id UUID,p_default_pricelist_id UUID
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE
  v_company UUID:=public.private_active_company_id();
  v_current public.customers%ROWTYPE;
  v_contact JSONB;v_finance JSONB;
  v_identity_changed BOOLEAN;v_credit_changed BOOLEAN;
BEGIN
  v_contact:=private.acp_resolve_permission(
    v_company,auth.uid(),'contacts.customers');
  IF p_customer_id IS NULL THEN
    IF NOT ((v_contact->'effectiveCapabilities') ? 'MANAGE') THEN
      RAISE EXCEPTION 'CUSTOM_PERMISSION_DENIED';
    END IF;
  ELSE
    SELECT * INTO v_current FROM public.customers customer
    WHERE customer.company_id=v_company AND customer.id=p_customer_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'CUSTOMER_NOT_FOUND'; END IF;

    v_identity_changed:=
      upper(btrim(COALESCE(p_customer_code,''))) IS DISTINCT FROM v_current.code
      OR btrim(COALESCE(p_customer_name,'')) IS DISTINCT FROM v_current.name
      OR p_customer_category_id IS DISTINCT FROM v_current.customer_category_id
      OR NULLIF(btrim(COALESCE(p_phone,'')),'') IS DISTINCT FROM v_current.phone
      OR NULLIF(lower(btrim(COALESCE(p_email,''))),'') IS DISTINCT FROM v_current.email
      OR NULLIF(btrim(COALESCE(p_address,'')),'') IS DISTINCT FROM v_current.address
      OR upper(btrim(COALESCE(p_customer_type,''))) IS DISTINCT FROM v_current.customer_type
      OR NULLIF(btrim(COALESCE(p_notes,'')),'') IS DISTINCT FROM v_current.notes
      OR COALESCE(p_is_active,TRUE) IS DISTINCT FROM v_current.is_active
      OR p_parent_customer_id IS DISTINCT FROM v_current.parent_customer_id
      OR p_default_pricelist_id IS DISTINCT FROM v_current.default_pricelist_id;
    v_credit_changed:=COALESCE(p_credit_limit,0)
        IS DISTINCT FROM v_current.credit_limit
      OR p_credit_term_days IS DISTINCT FROM v_current.credit_term_days;

    IF v_identity_changed
       AND NOT ((v_contact->'effectiveCapabilities') ? 'MANAGE') THEN
      RAISE EXCEPTION 'CUSTOM_PERMISSION_DENIED';
    END IF;
    IF v_credit_changed
       AND NOT ((v_contact->'effectiveCapabilities') ? 'MANAGE') THEN
      v_finance:=private.acp_resolve_permission(
        v_company,auth.uid(),'finance.customer_balances');
      IF (v_finance->>'enforced')::BOOLEAN
         AND NOT ((v_finance->'effectiveCapabilities') ? 'MANAGE') THEN
        RAISE EXCEPTION 'CUSTOM_PERMISSION_DENIED';
      ELSIF NOT (v_finance->>'enforced')::BOOLEAN
         AND NOT public.private_user_has_any_company_or_store_role(v_company,
           ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE','ACCOUNTING']::TEXT[]) THEN
        RAISE EXCEPTION 'CUSTOMER_CREDIT_MANAGER_REQUIRED';
      END IF;
    END IF;
    IF NOT v_identity_changed AND NOT v_credit_changed THEN
      IF NOT ((v_contact->'effectiveCapabilities') ? 'MANAGE') THEN
        RAISE EXCEPTION 'CUSTOM_PERMISSION_DENIED';
      END IF;
    END IF;
  END IF;

  RETURN private.save_customer_with_pricelist(
    p_customer_id,p_master_version,p_customer_code,p_customer_name,
    p_customer_category_id,p_phone,p_email,p_address,p_customer_type,
    p_credit_limit,p_credit_term_days,p_notes,p_is_active,
    p_parent_customer_id,p_default_pricelist_id);
END
$$;

CREATE FUNCTION public.get_contacts_customers(p_include_inactive BOOLEAN DEFAULT FALSE)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'contacts.customers','VIEW');
  RETURN jsonb_build_object(
    'companyId',v_company,
    'data',(SELECT COALESCE(jsonb_agg(customer_row.payload
      ORDER BY customer_row.system_rank DESC,customer_row.customer_name,
        customer_row.customer_id),'[]'::JSONB)
      FROM (
        SELECT customer.id customer_id,customer.name customer_name,
          customer.is_system_customer system_rank,
          jsonb_build_object(
            'id',customer.id,'company_id',customer.company_id,
            'code',customer.code,'name',customer.name,
            'customer_category_id',customer.customer_category_id,
            'phone',customer.phone,'email',customer.email,
            'address',customer.address,'customer_type',customer.customer_type,
            'current_balance',customer.current_balance,
            'credit_limit',customer.credit_limit,
            'credit_term_days',customer.credit_term_days,
            'is_active',customer.is_active,
            'is_system_customer',customer.is_system_customer,
            'notes',customer.notes,'master_version',customer.master_version,
            'parent_customer_id',customer.parent_customer_id,
            'default_pricelist_id',customer.default_pricelist_id,
            'created_at',customer.created_at,'updated_at',customer.updated_at,
            'updated_by',customer.updated_by,
            'category',jsonb_build_object(
              'id',category.id,'category_code',category.category_code,
              'category_name',category.category_name,
              'is_system_category',category.is_system_category,
              'is_active',category.is_active)) payload
        FROM public.customers customer
        JOIN public.customer_categories category
          ON category.company_id=customer.company_id
         AND category.id=customer.customer_category_id
        WHERE customer.company_id=v_company
          AND (COALESCE(p_include_inactive,FALSE) OR customer.is_active)
        LIMIT 5000
      ) customer_row),
    'categories',(SELECT COALESCE(jsonb_agg(to_jsonb(category_row)
      ORDER BY category_row.is_system_category DESC,
        category_row.category_name,category_row.id),'[]'::JSONB)
      FROM (SELECT category.id,category.category_code,category.category_name,
          category.is_system_category,category.is_active,
          category.master_version,category.created_at,category.updated_at
        FROM public.customer_categories category
        WHERE category.company_id=v_company
          AND (COALESCE(p_include_inactive,FALSE) OR category.is_active)
        LIMIT 1000) category_row),
    'pricelists',(SELECT COALESCE(jsonb_agg(to_jsonb(pricelist_row)
      ORDER BY pricelist_row.name,pricelist_row.id),'[]'::JSONB)
      FROM (SELECT pricelist.id,pricelist.name,pricelist.scope,
          pricelist.is_active
        FROM public.pricelists pricelist
        WHERE pricelist.company_id=v_company
          AND pricelist.scope IN('GLOBAL','CUSTOMER')
          AND (COALESCE(p_include_inactive,FALSE) OR pricelist.is_active)
        LIMIT 2000) pricelist_row),
    'audit',(SELECT COALESCE(jsonb_agg(to_jsonb(audit_row)
      ORDER BY audit_row.created_at DESC,audit_row.id DESC),'[]'::JSONB)
      FROM (SELECT audit.id,audit.customer_id,audit.action,audit.actor_id,
          audit.created_at
        FROM public.customer_master_audit audit
        WHERE audit.company_id=v_company
        ORDER BY audit.created_at DESC,audit.id DESC LIMIT 5000) audit_row));
END
$$;

CREATE FUNCTION public.get_pos_customer_references()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_actor UUID:=auth.uid();
BEGIN
  IF NOT EXISTS(SELECT 1 FROM public.cashier_sessions session
    WHERE session.company_id=v_company AND session.cashier_id=v_actor
      AND session.status='OPEN'::public.session_status) THEN
    RAISE EXCEPTION 'OPEN_CASHIER_SESSION_REQUIRED';
  END IF;
  RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object(
    'id',customer.id,'code',customer.code,'name',customer.name,
    'phone',customer.phone,
    'address',customer.address,'is_system_customer',customer.is_system_customer,
    'is_active',customer.is_active,
    'default_pricelist_id',customer.default_pricelist_id,
    'current_balance',customer.current_balance)
    ORDER BY customer.is_system_customer DESC,customer.name,customer.id)
    FROM public.customers customer
    WHERE customer.company_id=v_company AND customer.is_active),'[]'::JSONB);
END
$$;

CREATE FUNCTION public.get_finance_customer_balance_references()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE
  v_company UUID:=public.private_active_company_id();
  v_resolution JSONB;
BEGIN
  v_resolution:=private.acp_resolve_permission(
    v_company,auth.uid(),'finance.customer_balances');
  IF (v_resolution->>'enforced')::BOOLEAN THEN
    IF NOT ((v_resolution->'effectiveCapabilities') ? 'VIEW') THEN
      RAISE EXCEPTION 'CUSTOM_PERMISSION_DENIED';
    END IF;
  ELSIF NOT public.private_user_has_any_company_or_store_role(v_company,
    ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE','ACCOUNTING']::TEXT[]) THEN
    RAISE EXCEPTION 'CUSTOMER_BALANCE_VIEWER_REQUIRED';
  END IF;
  RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object(
    'id',customer.id,'name',customer.name,
    'current_balance',customer.current_balance,'is_active',customer.is_active,
    'is_system_customer',customer.is_system_customer)
    ORDER BY customer.name,customer.id)
    FROM public.customers customer WHERE customer.company_id=v_company
      AND NOT customer.is_system_customer),'[]'::JSONB);
END
$$;

CREATE FUNCTION public.export_contacts_customer_categories()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'contacts.customers','EXPORT');
  RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object(
    'id',category.id,'category_name',category.category_name,
    'is_active',category.is_active)
    ORDER BY category.category_name,category.id)
    FROM public.customer_categories category
    WHERE category.company_id=v_company),'[]'::JSONB);
END
$$;

CREATE FUNCTION private.acp_sales_customer_references(
  p_permission_key TEXT,p_customer_ids UUID[]
) RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE
  v_company UUID:=public.private_active_company_id();
  v_resolution JSONB;
BEGIN
  IF p_permission_key NOT IN('sales.sales_documents','sales.sales_returns') THEN
    RAISE EXCEPTION 'CUSTOMER_REFERENCE_PURPOSE_INVALID';
  END IF;
  v_resolution:=private.acp_resolve_permission(
    v_company,auth.uid(),p_permission_key);
  IF (v_resolution->>'enforced')::BOOLEAN THEN
    IF NOT ((v_resolution->'effectiveCapabilities') ? 'VIEW') THEN
      RAISE EXCEPTION 'CUSTOM_PERMISSION_DENIED';
    END IF;
  ELSIF p_permission_key='sales.sales_documents' AND NOT
    public.private_user_has_any_company_or_store_role(v_company,
      ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','FINANCE','ACCOUNTING']::TEXT[]) THEN
    RAISE EXCEPTION 'SALES_DOCUMENT_VIEWER_REQUIRED';
  ELSIF p_permission_key='sales.sales_returns' AND NOT
    public.private_user_has_any_company_or_store_role(v_company,
      ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER']::TEXT[]) THEN
    RAISE EXCEPTION 'SALES_RETURN_VIEWER_REQUIRED';
  END IF;
  IF COALESCE(cardinality(p_customer_ids),0)>1000 THEN
    RAISE EXCEPTION 'CUSTOMER_REFERENCE_LIMIT_EXCEEDED';
  END IF;
  RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object(
    'id',customer.id,'name',customer.name) ORDER BY customer.name,customer.id)
    FROM public.customers customer WHERE customer.company_id=v_company
      AND customer.id=ANY(COALESCE(p_customer_ids,'{}'::UUID[]))),'[]'::JSONB);
END
$$;

CREATE FUNCTION public.get_sales_document_customer_references(p_customer_ids UUID[])
RETURNS JSONB LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp
AS $$ SELECT private.acp_sales_customer_references(
  'sales.sales_documents',p_customer_ids) $$;

CREATE FUNCTION public.get_sales_return_customer_references(p_customer_ids UUID[])
RETURNS JSONB LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp
AS $$ SELECT private.acp_sales_customer_references(
  'sales.sales_returns',p_customer_ids) $$;

CREATE FUNCTION private.acp_require_customer_import_if_needed(
  p_company_id UUID,p_import_type TEXT
) RETURNS VOID LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
BEGIN
  IF upper(btrim(COALESCE(p_import_type,'')))='CUSTOMER_CATEGORY' THEN
    PERFORM private.acp_require_permission_capability(
      p_company_id,'contacts.customers','IMPORT');
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
  PERFORM private.acp_require_minimum_stock_import_if_needed(v_company,p_import_type);
  PERFORM private.acp_require_customer_import_if_needed(v_company,p_import_type);
  RETURN private.create_master_import_job(p_client_request_id,p_import_type,
    p_reference_mode,p_operation_mode,p_file_name,p_file_checksum,p_delimiter);
END $$;

CREATE OR REPLACE FUNCTION public.stage_master_import_rows(
  p_job_id UUID,p_master_version BIGINT,p_mapping JSONB,p_rows JSONB
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp
AS $$ DECLARE v_company UUID:=public.private_active_company_id();v_type TEXT; BEGIN
  SELECT import_type INTO v_type FROM public.master_import_jobs
  WHERE company_id=v_company AND id=p_job_id;
  PERFORM private.acp_require_product_import_if_needed(v_company,v_type);
  PERFORM private.acp_require_minimum_stock_import_if_needed(v_company,v_type);
  PERFORM private.acp_require_customer_import_if_needed(v_company,v_type);
  RETURN private.stage_master_import_rows(p_job_id,p_master_version,p_mapping,p_rows);
END $$;

CREATE OR REPLACE FUNCTION public.validate_master_import_job(
  p_job_id UUID,p_master_version BIGINT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp
AS $$ DECLARE v_company UUID:=public.private_active_company_id();v_type TEXT; BEGIN
  SELECT import_type INTO v_type FROM public.master_import_jobs
  WHERE company_id=v_company AND id=p_job_id;
  PERFORM private.acp_require_product_import_if_needed(v_company,v_type);
  PERFORM private.acp_require_minimum_stock_import_if_needed(v_company,v_type);
  PERFORM private.acp_require_customer_import_if_needed(v_company,v_type);
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
  PERFORM private.acp_require_customer_import_if_needed(v_company,v_type);
  RETURN private.commit_master_import_job(
    p_job_id,p_master_version,p_confirm_update_count);
END $$;

DO $enforce$
DECLARE v_rows BIGINT;
BEGIN
  UPDATE public.access_permission_catalog SET
    supported_capabilities=ARRAY['VIEW','MANAGE','EXPORT','IMPORT']::TEXT[],
    enforcement_status='ENFORCED',catalog_version=catalog_version+1,
    updated_at=clock_timestamp()
  WHERE permission_key='contacts.customers' AND enforcement_status='SHADOW';
  GET DIAGNOSTICS v_rows=ROW_COUNT;
  IF v_rows<>1 THEN RAISE EXCEPTION 'CUSTOMER_PERMISSION_CUTOVER_FAILED'; END IF;
END
$enforce$;

REVOKE SELECT ON public.customers,public.customer_categories,
  public.customer_master_audit,public.customer_category_audit
FROM authenticated;

REVOKE ALL ON FUNCTION
  public.save_customer_category(UUID,BIGINT,TEXT,TEXT,BOOLEAN),
  public.save_customer(UUID,BIGINT,TEXT,TEXT,UUID,TEXT,TEXT,TEXT,TEXT,
    NUMERIC,INTEGER,TEXT,BOOLEAN),
  public.save_customer_with_parent(UUID,BIGINT,TEXT,TEXT,UUID,TEXT,TEXT,TEXT,
    TEXT,NUMERIC,INTEGER,TEXT,BOOLEAN,UUID)
FROM PUBLIC,anon,authenticated;

REVOKE ALL ON FUNCTION
  private.save_customer_category(UUID,BIGINT,TEXT,BOOLEAN),
  private.save_customer_with_pricelist(UUID,BIGINT,TEXT,TEXT,UUID,TEXT,TEXT,
    TEXT,TEXT,NUMERIC,INTEGER,TEXT,BOOLEAN,UUID,UUID),
  private.acp_sales_customer_references(TEXT,UUID[]),
  private.acp_require_customer_import_if_needed(UUID,TEXT)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.save_customer_category(UUID,BIGINT,TEXT,BOOLEAN),
  private.save_customer_with_pricelist(UUID,BIGINT,TEXT,TEXT,UUID,TEXT,TEXT,
    TEXT,TEXT,NUMERIC,INTEGER,TEXT,BOOLEAN,UUID,UUID),
  private.acp_sales_customer_references(TEXT,UUID[]),
  private.acp_require_customer_import_if_needed(UUID,TEXT)
TO service_role;

REVOKE ALL ON FUNCTION
  public.save_customer_category(UUID,BIGINT,TEXT,BOOLEAN),
  public.save_customer_with_pricelist(UUID,BIGINT,TEXT,TEXT,UUID,TEXT,TEXT,
    TEXT,TEXT,NUMERIC,INTEGER,TEXT,BOOLEAN,UUID,UUID),
  public.get_contacts_customers(BOOLEAN),
  public.get_pos_customer_references(),
  public.get_finance_customer_balance_references(),
  public.export_contacts_customer_categories(),
  public.get_sales_document_customer_references(UUID[]),
  public.get_sales_return_customer_references(UUID[])
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION
  public.save_customer_category(UUID,BIGINT,TEXT,BOOLEAN),
  public.save_customer_with_pricelist(UUID,BIGINT,TEXT,TEXT,UUID,TEXT,TEXT,
    TEXT,TEXT,NUMERIC,INTEGER,TEXT,BOOLEAN,UUID,UUID),
  public.get_contacts_customers(BOOLEAN),
  public.get_pos_customer_references(),
  public.get_finance_customer_balance_references(),
  public.export_contacts_customer_categories(),
  public.get_sales_document_customer_references(UUID[]),
  public.get_sales_return_customer_references(UUID[])
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260812220000','acp_phase5a_customer_permission_enforcement',
  'Enforced Customer management with explicit Category import and isolated POS, Sales, and Finance Customer reference channels');

NOTIFY pgrst,'reload schema';
COMMIT;
