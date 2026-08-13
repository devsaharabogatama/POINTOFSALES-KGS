-- ACP-4C: enforce inventory.products across Product management and Product import.

BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260812140000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: ACP-4B required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260812150000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED';
  END IF;
  IF EXISTS(SELECT 1 FROM public.master_import_jobs
    WHERE status NOT IN('COMPLETED','COMPLETED_WITH_ERRORS','FAILED','CANCELED')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal import job';
  END IF;
END
$guard$;

-- Preserve the proven Product and generic import implementations as private cores.
ALTER FUNCTION public.save_product_with_uoms(
  UUID,BIGINT,TEXT,TEXT,UUID,UUID,UUID,NUMERIC,BOOLEAN,TEXT,BOOLEAN,JSONB
) SET SCHEMA private;
ALTER FUNCTION public.save_product_tax_assignment(UUID,BIGINT,UUID,UUID)
  SET SCHEMA private;
ALTER FUNCTION public.save_product_with_uoms(
  UUID,BIGINT,TEXT,TEXT,UUID,UUID,UUID,NUMERIC,BOOLEAN,TEXT,BOOLEAN,JSONB,UUID,UUID
) SET SCHEMA private;

ALTER FUNCTION public.create_master_import_job(UUID,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT)
  SET SCHEMA private;
ALTER FUNCTION public.stage_master_import_rows(UUID,BIGINT,JSONB,JSONB)
  SET SCHEMA private;
ALTER FUNCTION public.validate_master_import_job(UUID,BIGINT)
  SET SCHEMA private;
ALTER FUNCTION public.commit_master_import_job(UUID,BIGINT,INTEGER)
  SET SCHEMA private;

CREATE FUNCTION public.save_product_with_uoms(
  p_product_id UUID,p_master_version BIGINT,p_sku TEXT,p_name TEXT,
  p_category_id UUID,p_base_uom_id UUID,p_weight_reference_uom_id UUID,
  p_weight_per_reference_uom_kg NUMERIC,p_is_bundle BOOLEAN,p_image_url TEXT,
  p_is_active BOOLEAN,p_uoms JSONB
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp
AS $$ DECLARE v_company UUID:=public.private_active_company_id(); BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'inventory.products','MANAGE');
  RETURN private.save_product_with_uoms(
    p_product_id,p_master_version,p_sku,p_name,p_category_id,p_base_uom_id,
    p_weight_reference_uom_id,p_weight_per_reference_uom_kg,p_is_bundle,
    p_image_url,p_is_active,p_uoms);
END $$;

CREATE FUNCTION public.save_product_tax_assignment(
  p_product_id UUID,p_master_version BIGINT,
  p_sales_tax_rule_id UUID,p_purchase_tax_rule_id UUID
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp
AS $$ DECLARE v_company UUID:=public.private_active_company_id(); BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'inventory.products','MANAGE');
  RETURN private.save_product_tax_assignment(
    p_product_id,p_master_version,p_sales_tax_rule_id,p_purchase_tax_rule_id);
END $$;

CREATE FUNCTION public.save_product_with_uoms(
  p_product_id UUID,p_master_version BIGINT,p_sku TEXT,p_name TEXT,
  p_category_id UUID,p_base_uom_id UUID,p_weight_reference_uom_id UUID,
  p_weight_per_reference_uom_kg NUMERIC,p_is_bundle BOOLEAN,p_image_url TEXT,
  p_is_active BOOLEAN,p_uoms JSONB,
  p_sales_tax_rule_id UUID,p_purchase_tax_rule_id UUID
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp
AS $$ DECLARE v_company UUID:=public.private_active_company_id(); BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'inventory.products','MANAGE');
  RETURN private.save_product_with_uoms(
    p_product_id,p_master_version,p_sku,p_name,p_category_id,p_base_uom_id,
    p_weight_reference_uom_id,p_weight_per_reference_uom_kg,p_is_bundle,
    p_image_url,p_is_active,p_uoms,p_sales_tax_rule_id,p_purchase_tax_rule_id);
END $$;

CREATE FUNCTION private.acp_require_product_import_if_needed(
  p_company_id UUID,p_import_type TEXT
) RETURNS VOID LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp
AS $$ BEGIN
  IF upper(btrim(COALESCE(p_import_type,'')))='PRODUCT' THEN
    PERFORM private.acp_require_permission_capability(
      p_company_id,'inventory.products','IMPORT');
  END IF;
END $$;

CREATE FUNCTION public.create_master_import_job(
  p_client_request_id UUID,p_import_type TEXT,p_reference_mode TEXT,
  p_operation_mode TEXT,p_file_name TEXT,p_file_checksum TEXT,
  p_delimiter TEXT DEFAULT ','
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp
AS $$ DECLARE v_company UUID:=public.private_active_company_id(); BEGIN
  PERFORM private.acp_require_product_import_if_needed(v_company,p_import_type);
  RETURN private.create_master_import_job(
    p_client_request_id,p_import_type,p_reference_mode,p_operation_mode,
    p_file_name,p_file_checksum,p_delimiter);
END $$;

CREATE FUNCTION public.stage_master_import_rows(
  p_job_id UUID,p_master_version BIGINT,p_mapping JSONB,p_rows JSONB
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp
AS $$ DECLARE v_company UUID:=public.private_active_company_id();v_type TEXT; BEGIN
  SELECT import_type INTO v_type FROM public.master_import_jobs
  WHERE company_id=v_company AND id=p_job_id;
  PERFORM private.acp_require_product_import_if_needed(v_company,v_type);
  RETURN private.stage_master_import_rows(
    p_job_id,p_master_version,p_mapping,p_rows);
END $$;

CREATE FUNCTION public.validate_master_import_job(
  p_job_id UUID,p_master_version BIGINT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp
AS $$ DECLARE v_company UUID:=public.private_active_company_id();v_type TEXT; BEGIN
  SELECT import_type INTO v_type FROM public.master_import_jobs
  WHERE company_id=v_company AND id=p_job_id;
  PERFORM private.acp_require_product_import_if_needed(v_company,v_type);
  RETURN private.validate_master_import_job(p_job_id,p_master_version);
END $$;

CREATE FUNCTION public.commit_master_import_job(
  p_job_id UUID,p_master_version BIGINT,p_confirm_update_count INTEGER
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp
AS $$ DECLARE v_company UUID:=public.private_active_company_id();v_type TEXT; BEGIN
  SELECT import_type INTO v_type FROM public.master_import_jobs
  WHERE company_id=v_company AND id=p_job_id;
  PERFORM private.acp_require_product_import_if_needed(v_company,v_type);
  RETURN private.commit_master_import_job(
    p_job_id,p_master_version,p_confirm_update_count);
END $$;

DO $enforce$
DECLARE v_rows BIGINT;
BEGIN
  UPDATE public.access_permission_catalog SET
    enforcement_status='ENFORCED',catalog_version=catalog_version+1,
    updated_at=clock_timestamp()
  WHERE permission_key='inventory.products' AND enforcement_status='SHADOW';
  GET DIAGNOSTICS v_rows=ROW_COUNT;
  IF v_rows<>1 THEN RAISE EXCEPTION 'PRODUCT_PERMISSION_NOT_SHADOW'; END IF;
END
$enforce$;

REVOKE ALL ON FUNCTION
  private.save_product_with_uoms(UUID,BIGINT,TEXT,TEXT,UUID,UUID,UUID,NUMERIC,BOOLEAN,TEXT,BOOLEAN,JSONB),
  private.save_product_tax_assignment(UUID,BIGINT,UUID,UUID),
  private.save_product_with_uoms(UUID,BIGINT,TEXT,TEXT,UUID,UUID,UUID,NUMERIC,BOOLEAN,TEXT,BOOLEAN,JSONB,UUID,UUID),
  private.create_master_import_job(UUID,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT),
  private.stage_master_import_rows(UUID,BIGINT,JSONB,JSONB),
  private.validate_master_import_job(UUID,BIGINT),
  private.commit_master_import_job(UUID,BIGINT,INTEGER),
  private.acp_require_product_import_if_needed(UUID,TEXT)
FROM PUBLIC,anon,authenticated;

REVOKE ALL ON FUNCTION
  public.save_product_with_uoms(UUID,BIGINT,TEXT,TEXT,UUID,UUID,UUID,NUMERIC,BOOLEAN,TEXT,BOOLEAN,JSONB),
  public.save_product_tax_assignment(UUID,BIGINT,UUID,UUID),
  public.save_product_with_uoms(UUID,BIGINT,TEXT,TEXT,UUID,UUID,UUID,NUMERIC,BOOLEAN,TEXT,BOOLEAN,JSONB,UUID,UUID),
  public.create_master_import_job(UUID,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT),
  public.stage_master_import_rows(UUID,BIGINT,JSONB,JSONB),
  public.validate_master_import_job(UUID,BIGINT),
  public.commit_master_import_job(UUID,BIGINT,INTEGER)
FROM PUBLIC,anon;

GRANT EXECUTE ON FUNCTION
  public.save_product_with_uoms(UUID,BIGINT,TEXT,TEXT,UUID,UUID,UUID,NUMERIC,BOOLEAN,TEXT,BOOLEAN,JSONB),
  public.save_product_tax_assignment(UUID,BIGINT,UUID,UUID),
  public.save_product_with_uoms(UUID,BIGINT,TEXT,TEXT,UUID,UUID,UUID,NUMERIC,BOOLEAN,TEXT,BOOLEAN,JSONB,UUID,UUID),
  public.create_master_import_job(UUID,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT),
  public.stage_master_import_rows(UUID,BIGINT,JSONB,JSONB),
  public.validate_master_import_job(UUID,BIGINT),
  public.commit_master_import_job(UUID,BIGINT,INTEGER)
TO authenticated,service_role;

GRANT EXECUTE ON FUNCTION
  private.save_product_with_uoms(UUID,BIGINT,TEXT,TEXT,UUID,UUID,UUID,NUMERIC,BOOLEAN,TEXT,BOOLEAN,JSONB),
  private.save_product_tax_assignment(UUID,BIGINT,UUID,UUID),
  private.save_product_with_uoms(UUID,BIGINT,TEXT,TEXT,UUID,UUID,UUID,NUMERIC,BOOLEAN,TEXT,BOOLEAN,JSONB,UUID,UUID),
  private.create_master_import_job(UUID,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT),
  private.stage_master_import_rows(UUID,BIGINT,JSONB,JSONB),
  private.validate_master_import_job(UUID,BIGINT),
  private.commit_master_import_job(UUID,BIGINT,INTEGER),
  private.acp_require_product_import_if_needed(UUID,TEXT)
TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260812150000','acp_phase4c_product_permission_enforcement',
  'Enforced inventory.products across Product/UOM mutation and type-aware Product import while preserving cross-module reference reads');

COMMIT;
