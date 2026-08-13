-- ACP-5B: enforce Supplier management while preserving Purchase/Finance consumers.

BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260812220000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: ACP-5A required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260812230000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED';
  END IF;
  IF (SELECT count(*) FROM public.access_permission_catalog
    WHERE permission_key='contacts.suppliers'
      AND enforcement_status='SHADOW')<>1 THEN
    RAISE EXCEPTION 'SUPPLIER_PERMISSION_NOT_SHADOW';
  END IF;
  IF EXISTS(SELECT 1 FROM public.master_import_jobs
    WHERE import_type IN('SUPPLIER','PRODUCT_SUPPLIER')
      AND status NOT IN('COMPLETED','COMPLETED_WITH_ERRORS','FAILED','CANCELED')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Supplier import';
  END IF;
END
$guard$;

CREATE FUNCTION public.save_contacts_supplier(
  p_supplier_id UUID,p_master_version BIGINT,p_supplier_name TEXT,
  p_contact_name TEXT,p_phone TEXT,p_address TEXT,p_npwp TEXT,
  p_payment_term TEXT,p_bank_name TEXT,p_bank_account_number TEXT,
  p_bank_account_holder TEXT,p_is_active BOOLEAN
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'contacts.suppliers','MANAGE');
  RETURN public.save_supplier(
    p_supplier_id,p_master_version,p_supplier_name,p_contact_name,p_phone,
    p_address,p_npwp,p_payment_term,p_bank_name,p_bank_account_number,
    p_bank_account_holder,p_is_active);
END
$$;

CREATE FUNCTION public.save_contacts_product_supplier(
  p_product_supplier_id UUID,p_master_version BIGINT,p_product_id UUID,
  p_supplier_id UUID,p_purchase_uom_id UUID,p_supplier_product_code TEXT,
  p_reference_purchase_price NUMERIC,p_is_preferred_supplier BOOLEAN,
  p_is_active BOOLEAN
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'contacts.suppliers','MANAGE');
  RETURN public.save_product_supplier(
    p_product_supplier_id,p_master_version,p_product_id,p_supplier_id,
    p_purchase_uom_id,p_supplier_product_code,p_reference_purchase_price,
    p_is_preferred_supplier,p_is_active);
END
$$;

CREATE FUNCTION public.get_contacts_suppliers(
  p_include_inactive BOOLEAN DEFAULT FALSE
) RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'contacts.suppliers','VIEW');
  RETURN jsonb_build_object(
    'companyId',v_company,
    'data',(SELECT COALESCE(jsonb_agg(to_jsonb(supplier_row)
      ORDER BY supplier_row.supplier_name,supplier_row.id),'[]'::JSONB)
      FROM (SELECT supplier.id,supplier.company_id,supplier.supplier_code,
          supplier.supplier_name,supplier.contact_name,supplier.phone,
          supplier.address,supplier.npwp,supplier.payment_term,
          supplier.bank_name,supplier.bank_account_number,
          supplier.bank_account_holder,supplier.is_active,
          supplier.master_version,supplier.created_at,supplier.updated_at
        FROM public.suppliers supplier WHERE supplier.company_id=v_company
          AND (COALESCE(p_include_inactive,FALSE) OR supplier.is_active)
        LIMIT 5000) supplier_row),
    'relations',(SELECT COALESCE(jsonb_agg(to_jsonb(relation_row)
      ORDER BY relation_row.created_at,relation_row.id),'[]'::JSONB)
      FROM (SELECT relation.id,relation.company_id,relation.product_id,
          relation.supplier_id,relation.purchase_uom_id,
          relation.supplier_product_code,relation.reference_purchase_price,
          relation.last_purchase_price,relation.is_preferred_supplier,
          relation.is_active,relation.last_price_updated_at,
          relation.master_version,relation.created_at,relation.updated_at
        FROM public.product_suppliers relation
        WHERE relation.company_id=v_company
          AND (COALESCE(p_include_inactive,FALSE) OR relation.is_active)
        LIMIT 10000) relation_row),
    'supplierAudit',(SELECT COALESCE(jsonb_agg(to_jsonb(audit_row)
      ORDER BY audit_row.created_at DESC,audit_row.id DESC),'[]'::JSONB)
      FROM (SELECT audit.id,audit.supplier_id,audit.action,audit.actor_id,
          audit.created_at FROM public.supplier_master_audit audit
        WHERE audit.company_id=v_company
        ORDER BY audit.created_at DESC,audit.id DESC LIMIT 5000) audit_row),
    'relationAudit',(SELECT COALESCE(jsonb_agg(to_jsonb(audit_row)
      ORDER BY audit_row.created_at DESC,audit_row.id DESC),'[]'::JSONB)
      FROM (SELECT audit.id,audit.product_supplier_id,audit.action,
          audit.actor_id,audit.created_at
        FROM public.product_supplier_audit audit
        WHERE audit.company_id=v_company
        ORDER BY audit.created_at DESC,audit.id DESC LIMIT 5000) audit_row));
END
$$;

CREATE FUNCTION private.acp_require_supplier_consumer_view(
  p_company_id UUID,p_permission_key TEXT
) RETURNS VOID LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE v_resolution JSONB;v_roles TEXT[];
BEGIN
  IF p_permission_key='purchase.supplier_orders' THEN
    v_roles:=ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER']::TEXT[];
  ELSIF p_permission_key='purchase.purchase_returns' THEN
    v_roles:=ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER']::TEXT[];
  ELSIF p_permission_key IN(
    'finance.supplier_invoices','finance.supplier_payments') THEN
    v_roles:=ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE','ACCOUNTING']::TEXT[];
  ELSE
    RAISE EXCEPTION 'SUPPLIER_REFERENCE_PURPOSE_INVALID';
  END IF;
  v_resolution:=private.acp_resolve_permission(
    p_company_id,auth.uid(),p_permission_key);
  IF (v_resolution->>'enforced')::BOOLEAN THEN
    IF NOT ((v_resolution->'effectiveCapabilities') ? 'VIEW') THEN
      RAISE EXCEPTION 'CUSTOM_PERMISSION_DENIED';
    END IF;
  ELSIF NOT public.private_user_has_any_company_or_store_role(
    p_company_id,v_roles) THEN
    RAISE EXCEPTION 'SUPPLIER_REFERENCE_VIEWER_REQUIRED';
  END IF;
END
$$;

CREATE FUNCTION public.get_supplier_order_supplier_references()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_supplier_consumer_view(
    v_company,'purchase.supplier_orders');
  RETURN jsonb_build_object(
    'suppliers',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',supplier.id,'supplier_name',supplier.supplier_name,
      'is_active',supplier.is_active)
      ORDER BY supplier.supplier_name,supplier.id),'[]'::JSONB)
      FROM public.suppliers supplier WHERE supplier.company_id=v_company
        AND supplier.is_active),
    'productSuppliers',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'product_id',relation.product_id,'supplier_id',relation.supplier_id,
      'purchase_uom_id',relation.purchase_uom_id,
      'reference_purchase_price',relation.reference_purchase_price,
      'last_purchase_price',relation.last_purchase_price,
      'is_preferred_supplier',relation.is_preferred_supplier,
      'is_active',relation.is_active)),'[]'::JSONB)
      FROM public.product_suppliers relation
      WHERE relation.company_id=v_company AND relation.is_active));
END
$$;

CREATE FUNCTION public.get_purchase_return_supplier_references(
  p_supplier_ids UUID[]
) RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_supplier_consumer_view(
    v_company,'purchase.purchase_returns');
  IF COALESCE(cardinality(p_supplier_ids),0)>1000 THEN
    RAISE EXCEPTION 'SUPPLIER_REFERENCE_LIMIT_EXCEEDED';
  END IF;
  RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object(
    'id',supplier.id,'supplier_name',supplier.supplier_name)
    ORDER BY supplier.supplier_name,supplier.id)
    FROM public.suppliers supplier WHERE supplier.company_id=v_company
      AND supplier.id=ANY(COALESCE(p_supplier_ids,'{}'::UUID[]))),
    '[]'::JSONB);
END
$$;

CREATE FUNCTION public.get_goods_receipt_supplier_references(
  p_supplier_order_ids UUID[]
) RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_actor UUID:=auth.uid();
BEGIN
  IF COALESCE(cardinality(p_supplier_order_ids),0)>1000 THEN
    RAISE EXCEPTION 'SUPPLIER_REFERENCE_LIMIT_EXCEEDED';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.cashier_sessions session
    WHERE session.company_id=v_company AND session.cashier_id=v_actor
      AND session.status='OPEN'::public.session_status) THEN
    RAISE EXCEPTION 'OPEN_CASHIER_SESSION_REQUIRED';
  END IF;
  RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object(
    'id',supplier.id,'supplier_name',supplier.supplier_name)
    ORDER BY supplier.supplier_name,supplier.id)
    FROM public.suppliers supplier
    WHERE supplier.company_id=v_company AND EXISTS(
      SELECT 1 FROM public.supplier_order_documents document
      JOIN public.cashier_sessions session
        ON session.company_id=document.company_id
       AND session.store_id=document.store_id
       AND session.cashier_id=v_actor
       AND session.status='OPEN'::public.session_status
      WHERE document.company_id=v_company
        AND document.id=ANY(COALESCE(p_supplier_order_ids,'{}'::UUID[]))
        AND document.supplier_id=supplier.id
        AND document.status IN('CONFIRMED','PARTIALLY_RECEIVED'))),
    '[]'::JSONB);
END
$$;

CREATE FUNCTION public.get_pos_purchase_return_supplier_references(
  p_supplier_ids UUID[]
) RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_actor UUID:=auth.uid();
BEGIN
  IF COALESCE(cardinality(p_supplier_ids),0)>1000 THEN
    RAISE EXCEPTION 'SUPPLIER_REFERENCE_LIMIT_EXCEEDED';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.cashier_sessions session
    WHERE session.company_id=v_company AND session.cashier_id=v_actor
      AND session.status='OPEN'::public.session_status) THEN
    RAISE EXCEPTION 'OPEN_CASHIER_SESSION_REQUIRED';
  END IF;
  RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object(
    'id',supplier.id,'supplier_name',supplier.supplier_name)
    ORDER BY supplier.supplier_name,supplier.id)
    FROM public.suppliers supplier
    WHERE supplier.company_id=v_company
      AND supplier.id=ANY(COALESCE(p_supplier_ids,'{}'::UUID[]))
      AND EXISTS(SELECT 1 FROM public.goods_receipt_documents receipt
        JOIN public.supplier_order_documents document
          ON document.company_id=receipt.company_id
         AND document.id=receipt.supplier_order_id
        JOIN public.cashier_sessions session
          ON session.company_id=receipt.company_id
         AND session.store_id=receipt.store_id
         AND session.cashier_id=v_actor
         AND session.status='OPEN'::public.session_status
        WHERE receipt.company_id=v_company AND receipt.status='POSTED'
          AND document.supplier_id=supplier.id)),
    '[]'::JSONB);
END
$$;

CREATE FUNCTION private.acp_finance_supplier_references(p_permission_key TEXT)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_supplier_consumer_view(
    v_company,p_permission_key);
  RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object(
    'id',supplier.id,'supplier_code',supplier.supplier_code,
    'supplier_name',supplier.supplier_name,'is_active',supplier.is_active)
    ORDER BY supplier.supplier_name,supplier.id)
    FROM public.suppliers supplier WHERE supplier.company_id=v_company),
    '[]'::JSONB);
END
$$;

CREATE FUNCTION public.get_supplier_invoice_supplier_references()
RETURNS JSONB LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=public,pg_temp
AS $$ SELECT private.acp_finance_supplier_references(
  'finance.supplier_invoices') $$;

CREATE FUNCTION public.get_supplier_payment_supplier_references()
RETURNS JSONB LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=public,pg_temp
AS $$ SELECT private.acp_finance_supplier_references(
  'finance.supplier_payments') $$;

CREATE FUNCTION public.export_contacts_suppliers()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'contacts.suppliers','EXPORT');
  RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object(
    'id',supplier.id,'supplier_name',supplier.supplier_name,
    'contact_name',supplier.contact_name,'phone',supplier.phone,
    'address',supplier.address,'npwp',supplier.npwp,
    'payment_term',supplier.payment_term,'bank_name',supplier.bank_name,
    'bank_account_number',supplier.bank_account_number,
    'bank_account_holder',supplier.bank_account_holder,
    'is_active',supplier.is_active)
    ORDER BY supplier.supplier_name,supplier.id)
    FROM public.suppliers supplier WHERE supplier.company_id=v_company),
    '[]'::JSONB);
END
$$;

CREATE FUNCTION public.export_contacts_product_suppliers()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'contacts.suppliers','EXPORT');
  RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object(
    'id',relation.id,'product_sku',product.sku,
    'supplier_name',supplier.supplier_name,'purchase_uom_name',uom.name,
    'supplier_product_code',relation.supplier_product_code,
    'reference_purchase_price',relation.reference_purchase_price,
    'is_preferred_supplier',relation.is_preferred_supplier,
    'is_active',relation.is_active)
    ORDER BY product.sku,supplier.supplier_name,relation.id)
    FROM public.product_suppliers relation
    JOIN public.products product ON product.company_id=relation.company_id
      AND product.id=relation.product_id
    JOIN public.suppliers supplier ON supplier.company_id=relation.company_id
      AND supplier.id=relation.supplier_id
    JOIN public.uoms uom ON uom.company_id=relation.company_id
      AND uom.id=relation.purchase_uom_id
    WHERE relation.company_id=v_company),'[]'::JSONB);
END
$$;

CREATE FUNCTION private.acp_require_supplier_import_if_needed(
  p_company_id UUID,p_import_type TEXT
) RETURNS VOID LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
BEGIN
  IF upper(btrim(COALESCE(p_import_type,''))) IN(
    'SUPPLIER','PRODUCT_SUPPLIER') THEN
    PERFORM private.acp_require_permission_capability(
      p_company_id,'contacts.suppliers','IMPORT');
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
  PERFORM private.acp_require_supplier_import_if_needed(v_company,p_import_type);
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
  PERFORM private.acp_require_supplier_import_if_needed(v_company,v_type);
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
  PERFORM private.acp_require_supplier_import_if_needed(v_company,v_type);
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
  PERFORM private.acp_require_supplier_import_if_needed(v_company,v_type);
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
  WHERE permission_key='contacts.suppliers' AND enforcement_status='SHADOW';
  GET DIAGNOSTICS v_rows=ROW_COUNT;
  IF v_rows<>1 THEN RAISE EXCEPTION 'SUPPLIER_PERMISSION_CUTOVER_FAILED'; END IF;
END
$enforce$;

REVOKE SELECT ON public.suppliers,public.product_suppliers,
  public.supplier_master_audit,public.product_supplier_audit
FROM authenticated;

REVOKE ALL ON FUNCTION
  public.save_supplier(UUID,BIGINT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,BOOLEAN),
  public.save_supplier(UUID,BIGINT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,BOOLEAN),
  public.save_product_supplier(UUID,BIGINT,UUID,UUID,UUID,TEXT,NUMERIC,BOOLEAN,BOOLEAN)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  public.save_supplier(UUID,BIGINT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,BOOLEAN),
  public.save_supplier(UUID,BIGINT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,BOOLEAN),
  public.save_product_supplier(UUID,BIGINT,UUID,UUID,UUID,TEXT,NUMERIC,BOOLEAN,BOOLEAN)
TO service_role;

REVOKE ALL ON FUNCTION
  private.acp_require_supplier_consumer_view(UUID,TEXT),
  private.acp_finance_supplier_references(TEXT),
  private.acp_require_supplier_import_if_needed(UUID,TEXT)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.acp_require_supplier_consumer_view(UUID,TEXT),
  private.acp_finance_supplier_references(TEXT),
  private.acp_require_supplier_import_if_needed(UUID,TEXT)
TO service_role;

REVOKE ALL ON FUNCTION
  public.save_contacts_supplier(UUID,BIGINT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,BOOLEAN),
  public.save_contacts_product_supplier(UUID,BIGINT,UUID,UUID,UUID,TEXT,NUMERIC,BOOLEAN,BOOLEAN),
  public.get_contacts_suppliers(BOOLEAN),
  public.get_supplier_order_supplier_references(),
  public.get_purchase_return_supplier_references(UUID[]),
  public.get_goods_receipt_supplier_references(UUID[]),
  public.get_pos_purchase_return_supplier_references(UUID[]),
  public.get_supplier_invoice_supplier_references(),
  public.get_supplier_payment_supplier_references(),
  public.export_contacts_suppliers(),
  public.export_contacts_product_suppliers()
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION
  public.save_contacts_supplier(UUID,BIGINT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,BOOLEAN),
  public.save_contacts_product_supplier(UUID,BIGINT,UUID,UUID,UUID,TEXT,NUMERIC,BOOLEAN,BOOLEAN),
  public.get_contacts_suppliers(BOOLEAN),
  public.get_supplier_order_supplier_references(),
  public.get_purchase_return_supplier_references(UUID[]),
  public.get_goods_receipt_supplier_references(UUID[]),
  public.get_pos_purchase_return_supplier_references(UUID[]),
  public.get_supplier_invoice_supplier_references(),
  public.get_supplier_payment_supplier_references(),
  public.export_contacts_suppliers(),
  public.export_contacts_product_suppliers()
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260812230000','acp_phase5b_supplier_permission_enforcement',
  'Enforced Supplier and Product-Supplier management/import/export while preserving Purchase, Product, and Finance reference authority');

NOTIFY pgrst,'reload schema';
COMMIT;
