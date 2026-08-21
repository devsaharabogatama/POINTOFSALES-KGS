-- Product-UOM contextual template and terminal lifecycle for invalid/stale jobs.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260820130000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: 20260820130000 required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260821100000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260821100000';
  END IF;
  IF to_regprocedure('private.validate_product_uom_import_job(uuid,bigint)') IS NULL
     OR to_regprocedure('public.validate_master_import_job(uuid,bigint)') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Product-UOM import runtime missing';
  END IF;
END
$guard$;

CREATE FUNCTION private.prd_product_uom_exchange_rows(p_company_id UUID)
RETURNS JSONB LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
  WITH exchange_rows AS (
    SELECT product.id product_id,product.name product_name,product.sku product_sku,
      'REFERENCE'::TEXT row_mode,uom.name uom_name,
      product_uom.factor_to_base,product_uom.purchase_allowed,
      product_uom.sales_allowed,product_uom.purchase_price,
      product_uom.sale_price,product_uom.barcode,
      CASE WHEN product.weight_reference_uom_id=product_uom.uom_id
        THEN product.weight_per_uom_kg END weight_if_largest_kg,
      0 row_order,product_uom.factor_to_base factor_order
    FROM public.products product
    JOIN public.product_uoms product_uom
      ON product_uom.company_id=product.company_id
      AND product_uom.product_id=product.id AND product_uom.is_active
    JOIN public.uoms uom ON uom.company_id=product_uom.company_id
      AND uom.id=product_uom.uom_id
    WHERE product.company_id=p_company_id AND product.is_active
      AND NOT product.is_bundle
    UNION ALL
    SELECT product.id,product.name,product.sku,'INPUT',NULL,NULL,NULL,NULL,NULL,
      NULL,NULL,NULL,1,NULL
    FROM public.products product
    WHERE product.company_id=p_company_id AND product.is_active
      AND NOT product.is_bundle
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'row_mode',row_mode,'product_sku',product_sku,
    'product_name',product_name,'uom_name',uom_name,
    'factor_to_base',factor_to_base,'purchase_allowed',purchase_allowed,
    'sales_allowed',sales_allowed,'purchase_price',purchase_price,
    'sale_price',sale_price,'barcode',barcode,
    'weight_if_largest_kg',weight_if_largest_kg)
    ORDER BY product_name,product_sku,product_id,row_order,
      factor_order NULLS LAST,uom_name),'[]'::JSONB)
  FROM exchange_rows
$$;

CREATE OR REPLACE FUNCTION public.export_inventory_product_uom_placeholders()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'inventory.products','EXPORT');
  RETURN private.prd_product_uom_exchange_rows(v_company);
END
$$;

CREATE OR REPLACE FUNCTION public.get_inventory_product_uom_import_template()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'inventory.products','IMPORT');
  RETURN private.prd_product_uom_exchange_rows(v_company);
END
$$;

CREATE FUNCTION private.cancel_master_import_job_core(
  p_job_id UUID,p_master_version BIGINT,p_reason TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_actor UUID:=auth.uid();v_company UUID:=public.private_active_company_id();
  v_job public.master_import_jobs%ROWTYPE;v_version BIGINT;
  v_reason TEXT:=left(NULLIF(btrim(COALESCE(p_reason,'')),''),240);
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF NOT public.private_user_has_any_company_or_store_role(v_company,
    ARRAY['COMPANY_OWNER','COMPANY_ADMIN']::TEXT[]) THEN
    RAISE EXCEPTION 'MASTER_IMPORT_ADMIN_REQUIRED';
  END IF;
  SELECT * INTO v_job FROM public.master_import_jobs job
  WHERE job.company_id=v_company AND job.id=p_job_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'IMPORT_JOB_NOT_FOUND'; END IF;
  IF v_job.status='CANCELED' AND (p_master_version=v_job.master_version
     OR p_master_version+1=v_job.master_version) THEN
    RETURN jsonb_build_object('jobId',v_job.id,
      'masterVersion',v_job.master_version,'status','CANCELED','action','EXISTING');
  END IF;
  IF p_master_version IS NULL OR p_master_version<>v_job.master_version THEN
    RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
  END IF;
  IF v_job.status NOT IN('UPLOADED','MAPPED','VALIDATED','READY') THEN
    RAISE EXCEPTION 'IMPORT_JOB_NOT_CANCELABLE';
  END IF;
  UPDATE public.master_import_jobs SET status='CANCELED',
    master_version=master_version+1,updated_at=clock_timestamp()
  WHERE company_id=v_company AND id=v_job.id
  RETURNING master_version INTO v_version;
  INSERT INTO public.master_import_job_events(company_id,job_id,event_type,
    actor_id,before_state,after_state) VALUES(v_company,v_job.id,'CANCEL',v_actor,
    jsonb_build_object('status',v_job.status,
      'masterVersion',v_job.master_version),
    jsonb_strip_nulls(jsonb_build_object('status','CANCELED',
      'masterVersion',v_version,'reason',v_reason)));
  RETURN jsonb_build_object('jobId',v_job.id,'masterVersion',v_version,
    'status','CANCELED','action','CANCEL');
END
$$;

CREATE FUNCTION public.cancel_master_import_job(
  p_job_id UUID,p_master_version BIGINT,p_reason TEXT DEFAULT NULL
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
  RETURN private.cancel_master_import_job_core(
    p_job_id,p_master_version,p_reason);
END
$$;

CREATE FUNCTION public.cleanup_stale_master_import_jobs()
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_actor UUID:=auth.uid();v_company UUID:=public.private_active_company_id();
  v_job public.master_import_jobs%ROWTYPE;v_version BIGINT;v_count INTEGER:=0;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF NOT public.private_user_has_any_company_or_store_role(v_company,
    ARRAY['COMPANY_OWNER','COMPANY_ADMIN']::TEXT[]) THEN
    RAISE EXCEPTION 'MASTER_IMPORT_ADMIN_REQUIRED';
  END IF;
  FOR v_job IN SELECT * FROM public.master_import_jobs job
    WHERE job.company_id=v_company AND job.uploaded_by=v_actor
      AND job.status IN('UPLOADED','MAPPED')
      AND job.updated_at<clock_timestamp()-INTERVAL '15 minutes'
    ORDER BY job.id FOR UPDATE
  LOOP
    BEGIN
      PERFORM private.acp_require_product_import_if_needed(
        v_company,v_job.import_type);
      PERFORM private.acp_require_minimum_stock_import_if_needed(
        v_company,v_job.import_type);
      PERFORM private.acp_require_customer_import_if_needed(
        v_company,v_job.import_type);
      PERFORM private.acp_require_supplier_import_if_needed(
        v_company,v_job.import_type);
    EXCEPTION WHEN raise_exception THEN
      CONTINUE;
    END;
    UPDATE public.master_import_jobs SET status='CANCELED',
      master_version=master_version+1,updated_at=clock_timestamp()
    WHERE company_id=v_company AND id=v_job.id
    RETURNING master_version INTO v_version;
    INSERT INTO public.master_import_job_events(company_id,job_id,event_type,
      actor_id,before_state,after_state) VALUES(v_company,v_job.id,'CANCEL',v_actor,
      jsonb_build_object('status',v_job.status,
        'masterVersion',v_job.master_version),
      jsonb_build_object('status','CANCELED','masterVersion',v_version,
        'reason','AUTO_STALE_UNVALIDATED'));
    v_count:=v_count+1;
  END LOOP;
  RETURN jsonb_build_object('canceledCount',v_count,'status','COMPLETED');
END
$$;

CREATE OR REPLACE FUNCTION public.validate_master_import_job(
  p_job_id UUID,p_master_version BIGINT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_type TEXT;
  v_result JSONB;
BEGIN
  SELECT import_type INTO v_type FROM public.master_import_jobs
  WHERE company_id=v_company AND id=p_job_id;
  PERFORM private.acp_require_product_import_if_needed(v_company,v_type);
  PERFORM private.acp_require_minimum_stock_import_if_needed(v_company,v_type);
  PERFORM private.acp_require_customer_import_if_needed(v_company,v_type);
  PERFORM private.acp_require_supplier_import_if_needed(v_company,v_type);
  IF v_type='CUSTOMER' THEN RETURN private.validate_customer_import_job(
    p_job_id,p_master_version); END IF;
  IF v_type='PRODUCT_UOM' THEN
    v_result:=private.validate_product_uom_import_job(
      p_job_id,p_master_version);
    IF COALESCE((v_result->>'errorCount')::INTEGER,0)>0 THEN
      RETURN private.cancel_master_import_job_core(p_job_id,
        (v_result->>'masterVersion')::BIGINT,'AUTO_VALIDATION_FAILED');
    END IF;
    RETURN v_result;
  END IF;
  RETURN private.validate_master_import_job(p_job_id,p_master_version);
END
$$;

REVOKE ALL ON FUNCTION private.prd_product_uom_exchange_rows(UUID),
  private.cancel_master_import_job_core(UUID,BIGINT,TEXT)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.prd_product_uom_exchange_rows(UUID),
  private.cancel_master_import_job_core(UUID,BIGINT,TEXT) TO service_role;
REVOKE ALL ON FUNCTION public.cancel_master_import_job(UUID,BIGINT,TEXT)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.cancel_master_import_job(UUID,BIGINT,TEXT)
TO authenticated,service_role;
REVOKE ALL ON FUNCTION public.cleanup_stale_master_import_jobs()
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.cleanup_stale_master_import_jobs()
TO authenticated,service_role;

-- Close Product-UOM trials that were left nonterminal before CANCEL existed.
WITH candidates AS (
  SELECT job.company_id,job.id,job.status,job.master_version,job.uploaded_by
  FROM public.master_import_jobs job WHERE job.import_type='PRODUCT_UOM'
    AND job.status IN('UPLOADED','MAPPED','VALIDATED','READY') FOR UPDATE
), canceled AS (
  UPDATE public.master_import_jobs job SET status='CANCELED',
    master_version=job.master_version+1,updated_at=clock_timestamp()
  FROM candidates candidate WHERE job.company_id=candidate.company_id
    AND job.id=candidate.id
  RETURNING job.company_id,job.id,job.master_version
)
INSERT INTO public.master_import_job_events(company_id,job_id,event_type,
  actor_id,before_state,after_state)
SELECT candidate.company_id,candidate.id,'CANCEL',candidate.uploaded_by,
  jsonb_build_object('status',candidate.status,
    'masterVersion',candidate.master_version),
  jsonb_build_object('status','CANCELED',
    'masterVersion',canceled.master_version,
    'reason','MIGRATION_CLEANUP_NONTERMINAL_PRODUCT_UOM')
FROM candidates candidate JOIN canceled ON canceled.company_id=candidate.company_id
  AND canceled.id=candidate.id;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260821100000','product_uom_context_template_job_cancel',
  'Shows existing Product UOM reference rows plus one blank input row, auto-cancels invalid Product-UOM validation, adds guarded manual cancellation, and closes actor-owned stale unvalidated jobs');
NOTIFY pgrst,'reload schema';
COMMIT;
