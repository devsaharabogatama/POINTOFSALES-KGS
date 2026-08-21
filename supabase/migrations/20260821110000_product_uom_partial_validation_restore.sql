-- Restore the approved partial-preview contract for Product-UOM imports.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260821100000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: 20260821100000 required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260821110000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260821110000';
  END IF;
END
$guard$;

CREATE OR REPLACE FUNCTION public.validate_master_import_job(
  p_job_id UUID,p_master_version BIGINT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_type TEXT;
BEGIN
  SELECT import_type INTO v_type FROM public.master_import_jobs
  WHERE company_id=v_company AND id=p_job_id;
  PERFORM private.acp_require_product_import_if_needed(v_company,v_type);
  PERFORM private.acp_require_minimum_stock_import_if_needed(v_company,v_type);
  PERFORM private.acp_require_customer_import_if_needed(v_company,v_type);
  PERFORM private.acp_require_supplier_import_if_needed(v_company,v_type);
  IF v_type='CUSTOMER' THEN RETURN private.validate_customer_import_job(
    p_job_id,p_master_version); END IF;
  IF v_type='PRODUCT_UOM' THEN RETURN private.validate_product_uom_import_job(
    p_job_id,p_master_version); END IF;
  RETURN private.validate_master_import_job(p_job_id,p_master_version);
END
$$;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260821110000','product_uom_partial_validation_restore',
  'Restores Product-UOM partial preview and commit: valid rows remain committable while invalid rows remain downloadable errors; stale unvalidated and manual cancellation remain active');

NOTIFY pgrst,'reload schema';
COMMIT;
