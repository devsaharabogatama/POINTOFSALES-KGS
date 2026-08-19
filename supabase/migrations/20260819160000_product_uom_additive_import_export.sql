-- PRD: additive Product-UOM import/export without replacing other UOM rows.

BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260819150000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Customer exchange migration required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260819160000') THEN RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED'; END IF;
  IF EXISTS(SELECT 1 FROM public.master_import_jobs
    WHERE status NOT IN('COMPLETED','COMPLETED_WITH_ERRORS','FAILED','CANCELED')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal import job';
  END IF;
END
$guard$;

ALTER TABLE public.master_import_jobs
  DROP CONSTRAINT master_import_jobs_type_check,
  ADD CONSTRAINT master_import_jobs_type_check CHECK(import_type IN(
    'PRODUCT_CATEGORY','UOM','WAREHOUSE','SUPPLIER','CUSTOMER',
    'CUSTOMER_CATEGORY','CHART_OF_ACCOUNT','TRANSACTION_CATEGORY',
    'PRODUCT','PRODUCT_UOM','PRODUCT_SUPPLIER',
    'PRODUCT_WAREHOUSE_MINIMUM_STOCK'));

DO $extend_business_trigger_dispatch$
DECLARE v_oid OID:=to_regprocedure('private.trg_g2_validate_import_business_fields()');
  v_definition TEXT;v_old TEXT:='''CUSTOMER'') THEN';
  v_new TEXT:='''CUSTOMER'',''PRODUCT_UOM'') THEN';
BEGIN
  IF v_oid IS NULL THEN RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: import trigger missing'; END IF;
  SELECT pg_get_functiondef(v_oid) INTO v_definition;
  IF strpos(v_definition,v_old)=0 OR
     (length(v_definition)-length(replace(v_definition,v_old,'')))/length(v_old)<>1 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: import trigger dispatch changed';
  END IF;
  EXECUTE replace(v_definition,v_old,v_new);
END
$extend_business_trigger_dispatch$;

CREATE FUNCTION private.prd_product_uom_import_error(p_code TEXT,p_message TEXT DEFAULT NULL)
RETURNS JSONB LANGUAGE sql IMMUTABLE SET search_path=public,pg_temp
AS $$ SELECT jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
  'code',p_code,'message',NULLIF(p_message,'')))) $$;

CREATE FUNCTION private.upsert_inventory_product_uom_core(
  p_product_id UUID,p_product_master_version BIGINT,p_uom_id UUID,
  p_factor_to_base NUMERIC,p_purchase_allowed BOOLEAN,p_sales_allowed BOOLEAN,
  p_purchase_price NUMERIC,p_sale_price NUMERIC,p_barcode TEXT,
  p_weight_if_largest_kg NUMERIC
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp
AS $$
DECLARE
  v_actor UUID:=auth.uid();v_company UUID:=public.private_active_company_id();
  v_product public.products%ROWTYPE;v_existing public.product_uoms%ROWTYPE;
  v_other_max NUMERIC;v_before JSONB;v_after JSONB;v_uom_version BIGINT;
  v_product_version BIGINT;v_barcode TEXT:=NULLIF(regexp_replace(
    btrim(COALESCE(p_barcode,'')),'\s+','','g'),'');
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  SELECT * INTO v_product FROM public.products product
  WHERE product.company_id=v_company AND product.id=p_product_id FOR UPDATE;
  IF NOT FOUND OR NOT v_product.is_active OR v_product.is_bundle THEN
    RAISE EXCEPTION 'ACTIVE_STOCK_PRODUCT_NOT_FOUND';
  END IF;
  IF p_product_master_version IS NULL
     OR p_product_master_version<>v_product.master_version THEN
    RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
  END IF;
  IF p_uom_id=v_product.uom_id OR p_factor_to_base IS NULL
     OR p_factor_to_base<=1 THEN
    RAISE EXCEPTION 'PRODUCT_UOM_FACTOR_MUST_EXCEED_BASE';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.uoms uom WHERE uom.company_id=v_company
    AND uom.id=p_uom_id AND uom.is_active) THEN
    RAISE EXCEPTION 'ACTIVE_PRODUCT_UOM_NOT_FOUND';
  END IF;
  IF p_purchase_price<0 OR p_sale_price<0 THEN
    RAISE EXCEPTION 'PRODUCT_UOM_PRICE_NEGATIVE';
  END IF;
  IF COALESCE(p_purchase_allowed,FALSE) AND p_purchase_price IS NULL THEN
    RAISE EXCEPTION 'PURCHASE_PRICE_REQUIRED';
  END IF;
  IF COALESCE(p_sales_allowed,FALSE) AND p_sale_price IS NULL THEN
    RAISE EXCEPTION 'SALE_PRICE_REQUIRED';
  END IF;
  SELECT * INTO v_existing FROM public.product_uoms product_uom
  WHERE product_uom.company_id=v_company AND product_uom.product_id=p_product_id
    AND product_uom.uom_id=p_uom_id FOR UPDATE;
  IF FOUND AND v_existing.factor_to_base IS DISTINCT FROM p_factor_to_base
     AND EXISTS(SELECT 1 FROM public.stock_movements movement
       WHERE movement.company_id=v_company AND movement.product_id=p_product_id) THEN
    RAISE EXCEPTION 'PRODUCT_UOM_CONVERSION_LOCKED_BY_MOVEMENT';
  END IF;
  SELECT COALESCE(max(product_uom.factor_to_base),1) INTO v_other_max
  FROM public.product_uoms product_uom WHERE product_uom.company_id=v_company
    AND product_uom.product_id=p_product_id AND product_uom.is_active
    AND product_uom.uom_id<>p_uom_id;
  IF p_factor_to_base=v_other_max THEN
    RAISE EXCEPTION 'LARGEST_PRODUCT_UOM_FACTOR_NOT_UNIQUE';
  END IF;
  IF p_factor_to_base>v_other_max THEN
    IF COALESCE(p_weight_if_largest_kg,
      CASE WHEN v_product.weight_reference_uom_id=p_uom_id
        THEN v_product.weight_per_uom_kg END,0)<=0 THEN
      RAISE EXCEPTION 'PRODUCT_UOM_LARGEST_WEIGHT_REQUIRED';
    END IF;
  ELSIF p_weight_if_largest_kg IS NOT NULL THEN
    RAISE EXCEPTION 'PRODUCT_UOM_NOT_LARGEST';
  ELSIF v_product.weight_reference_uom_id=p_uom_id THEN
    RAISE EXCEPTION 'PRODUCT_UOM_RESELECTION_REQUIRED';
  END IF;

  SELECT jsonb_build_object('product',to_jsonb(product),
    'uoms',COALESCE((SELECT jsonb_agg(to_jsonb(product_uom)
      ORDER BY product_uom.factor_to_base,product_uom.id)
      FROM public.product_uoms product_uom
      WHERE product_uom.company_id=v_company
        AND product_uom.product_id=p_product_id),'[]'::JSONB))
  INTO v_before FROM public.products product
  WHERE product.company_id=v_company AND product.id=p_product_id;

  INSERT INTO public.product_uoms(company_id,product_id,uom_id,factor_to_base,
    purchase_allowed,sales_allowed,purchase_price,sale_price,barcode,is_active,
    created_by,updated_by) VALUES(v_company,p_product_id,p_uom_id,p_factor_to_base,
    COALESCE(p_purchase_allowed,FALSE),COALESCE(p_sales_allowed,FALSE),
    p_purchase_price,p_sale_price,v_barcode,TRUE,v_actor,v_actor)
  ON CONFLICT ON CONSTRAINT product_uoms_company_product_uom_unique DO UPDATE SET
    factor_to_base=EXCLUDED.factor_to_base,
    purchase_allowed=EXCLUDED.purchase_allowed,sales_allowed=EXCLUDED.sales_allowed,
    purchase_price=EXCLUDED.purchase_price,sale_price=EXCLUDED.sale_price,
    barcode=EXCLUDED.barcode,is_active=TRUE,
    effective_from=CASE WHEN public.product_uoms.factor_to_base
      IS DISTINCT FROM EXCLUDED.factor_to_base THEN clock_timestamp()
      ELSE public.product_uoms.effective_from END,updated_by=v_actor
  RETURNING master_version INTO v_uom_version;

  UPDATE public.products SET
    weight_reference_uom_id=CASE WHEN p_factor_to_base>v_other_max
      THEN p_uom_id ELSE weight_reference_uom_id END,
    weight_per_uom_kg=CASE WHEN p_factor_to_base>v_other_max
      THEN COALESCE(p_weight_if_largest_kg,weight_per_uom_kg)
      ELSE weight_per_uom_kg END,updated_by=v_actor
  WHERE company_id=v_company AND id=p_product_id
  RETURNING master_version INTO v_product_version;

  SELECT jsonb_build_object('product',to_jsonb(product),
    'uoms',COALESCE((SELECT jsonb_agg(to_jsonb(product_uom)
      ORDER BY product_uom.factor_to_base,product_uom.id)
      FROM public.product_uoms product_uom
      WHERE product_uom.company_id=v_company
        AND product_uom.product_id=p_product_id),'[]'::JSONB))
  INTO v_after FROM public.products product
  WHERE product.company_id=v_company AND product.id=p_product_id;
  INSERT INTO public.product_master_audit(company_id,product_id,action,actor_id,
    before_snapshot,after_snapshot) VALUES(
    v_company,p_product_id,'UPDATE',v_actor,v_before,v_after);
  RETURN jsonb_build_object('productId',p_product_id,
    'productMasterVersion',v_product_version,'productUomMasterVersion',v_uom_version,
    'action',CASE WHEN v_existing.id IS NULL THEN 'CREATE' ELSE 'UPDATE' END);
EXCEPTION WHEN unique_violation THEN
  RAISE EXCEPTION 'DUPLICATE_PRODUCT_OR_BARCODE';
END
$$;

CREATE FUNCTION private.create_product_uom_import_job(
  p_client_request_id UUID,p_reference_mode TEXT,p_operation_mode TEXT,
  p_file_name TEXT,p_file_checksum TEXT,p_delimiter TEXT DEFAULT ','
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp
AS $$
DECLARE v_actor UUID:=auth.uid();v_company UUID:=public.private_active_company_id();
  v_reference TEXT:=upper(btrim(COALESCE(p_reference_mode,'')));
  v_operation TEXT:=upper(btrim(COALESCE(p_operation_mode,'')));
  v_name TEXT:=btrim(COALESCE(p_file_name,''));
  v_checksum TEXT:=lower(btrim(COALESCE(p_file_checksum,'')));
  v_delimiter TEXT:=COALESCE(p_delimiter,',');
  v_existing public.master_import_jobs%ROWTYPE;v_id UUID;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF NOT public.private_user_has_any_company_or_store_role(v_company,
    ARRAY['COMPANY_OWNER','COMPANY_ADMIN']::TEXT[]) THEN
    RAISE EXCEPTION 'MASTER_IMPORT_ADMIN_REQUIRED';
  END IF;
  IF p_client_request_id IS NULL THEN RAISE EXCEPTION 'IMPORT_CLIENT_REQUEST_ID_REQUIRED'; END IF;
  IF v_reference NOT IN('REFERENCE_BY_ID','REFERENCE_BY_NAME') THEN
    RAISE EXCEPTION 'INVALID_IMPORT_REFERENCE_MODE'; END IF;
  IF v_operation NOT IN('CREATE_ONLY','UPDATE_ONLY','CREATE_AND_UPDATE') THEN
    RAISE EXCEPTION 'INVALID_IMPORT_OPERATION_MODE'; END IF;
  IF v_name='' OR v_checksum !~ '^[0-9a-f]{64}$'
     OR v_delimiter NOT IN(',', ';', E'\t', '|') THEN
    RAISE EXCEPTION 'INVALID_IMPORT_FILE';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(
    v_company::TEXT||':'||p_client_request_id::TEXT,0));
  SELECT * INTO v_existing FROM public.master_import_jobs
  WHERE company_id=v_company AND client_request_id=p_client_request_id;
  IF FOUND THEN
    IF v_existing.import_type<>'PRODUCT_UOM' OR v_existing.reference_mode<>v_reference
       OR v_existing.operation_mode<>v_operation OR v_existing.file_name<>v_name
       OR v_existing.file_checksum<>v_checksum OR v_existing.delimiter<>v_delimiter THEN
      RAISE EXCEPTION 'IMPORT_IDEMPOTENCY_CONFLICT'; END IF;
    RETURN jsonb_build_object('jobId',v_existing.id,
      'masterVersion',v_existing.master_version,'status',v_existing.status,
      'action','EXISTING');
  END IF;
  INSERT INTO public.master_import_jobs(company_id,client_request_id,import_type,
    reference_mode,operation_mode,file_name,file_checksum,delimiter,uploaded_by)
  VALUES(v_company,p_client_request_id,'PRODUCT_UOM',v_reference,v_operation,
    v_name,v_checksum,v_delimiter,v_actor) RETURNING id INTO v_id;
  INSERT INTO public.master_import_job_events(company_id,job_id,event_type,actor_id,
    after_state) VALUES(v_company,v_id,'CREATE',v_actor,jsonb_build_object(
      'status','UPLOADED','importType','PRODUCT_UOM','referenceMode',v_reference,
      'operationMode',v_operation,'masterVersion',1));
  RETURN jsonb_build_object('jobId',v_id,'masterVersion',1,
    'status','UPLOADED','action','CREATE');
END
$$;

CREATE FUNCTION private.validate_product_uom_import_job(
  p_job_id UUID,p_master_version BIGINT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp
AS $$
DECLARE v_actor UUID:=auth.uid();v_company UUID:=public.private_active_company_id();
  v_job public.master_import_jobs%ROWTYPE;v_row public.master_import_rows%ROWTYPE;
  v_source JSONB;v_errors JSONB;v_product public.products%ROWTYPE;
  v_existing public.product_uoms%ROWTYPE;v_sku TEXT;v_name TEXT;v_uom_name TEXT;
  v_uom_id UUID;v_factor NUMERIC;v_purchase BOOLEAN;v_sales BOOLEAN;
  v_purchase_price NUMERIC;v_sale_price NUMERIC;v_barcode TEXT;v_weight NUMERIC;
  v_other_max NUMERIC;v_operation TEXT;v_before JSONB;v_after JSONB;
  v_created INTEGER;v_updated INTEGER;v_skipped INTEGER;v_error_rows INTEGER;
  v_new_version BIGINT;v_text TEXT;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF NOT public.private_user_has_any_company_or_store_role(v_company,
    ARRAY['COMPANY_OWNER','COMPANY_ADMIN']::TEXT[]) THEN
    RAISE EXCEPTION 'MASTER_IMPORT_ADMIN_REQUIRED'; END IF;
  SELECT * INTO v_job FROM public.master_import_jobs
  WHERE company_id=v_company AND id=p_job_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'IMPORT_JOB_NOT_FOUND'; END IF;
  IF v_job.import_type<>'PRODUCT_UOM' THEN RAISE EXCEPTION 'INVALID_PRODUCT_UOM_IMPORT_JOB'; END IF;
  IF p_master_version IS NOT NULL AND p_master_version+1=v_job.master_version
     AND v_job.status='VALIDATED' THEN
    RETURN jsonb_build_object('jobId',v_job.id,'masterVersion',v_job.master_version,
      'status',v_job.status,'createCount',v_job.created_rows,
      'updateCount',v_job.updated_rows,'skipCount',v_job.skipped_rows,
      'errorCount',v_job.error_rows,'action','EXISTING'); END IF;
  IF p_master_version IS NULL OR p_master_version<>v_job.master_version THEN
    RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
  IF v_job.status<>'MAPPED' THEN RAISE EXCEPTION 'IMPORT_JOB_NOT_VALIDATABLE'; END IF;
  IF NULLIF(btrim(v_job.mapping->>'productSku'),'') IS NULL
     OR NULLIF(btrim(v_job.mapping->>'productName'),'') IS NULL THEN
    RAISE EXCEPTION 'IMPORT_PRODUCT_UOM_MAPPING_REQUIRED'; END IF;
  UPDATE public.master_import_rows SET normalized_data=NULL,operation='PENDING',
    row_status='STAGED',matched_record_id=NULL,matched_master_version=NULL,
    warnings='[]'::JSONB,errors='[]'::JSONB,before_state=NULL,after_state=NULL,
    committed_at=NULL,updated_at=clock_timestamp()
  WHERE company_id=v_company AND job_id=p_job_id;

  FOR v_row IN SELECT * FROM public.master_import_rows WHERE company_id=v_company
    AND job_id=p_job_id ORDER BY row_number FOR UPDATE
  LOOP
    v_source:=v_row.source_data;v_errors:='[]'::JSONB;v_product:=NULL;
    v_existing:=NULL;v_uom_id:=NULL;v_operation:='ERROR';v_before:=NULL;
    v_factor:=NULL;v_purchase:=FALSE;v_sales:=FALSE;v_purchase_price:=NULL;
    v_sale_price:=NULL;v_barcode:=NULL;v_weight:=NULL;v_other_max:=1;
    v_sku:=upper(regexp_replace(btrim(COALESCE(
      v_source->>(v_job.mapping->>'productSku'),'')),'\s+',' ','g'));
    v_name:=regexp_replace(btrim(COALESCE(
      v_source->>(v_job.mapping->>'productName'),'')),'\s+',' ','g');
    v_uom_name:=NULLIF(regexp_replace(btrim(COALESCE(
      v_source->>(v_job.mapping->>'uomName'),'')),'\s+',' ','g'),'');
    SELECT * INTO v_product FROM public.products product
    WHERE product.company_id=v_company AND product.is_active AND NOT product.is_bundle
      AND upper(regexp_replace(btrim(product.sku),'\s+',' ','g'))=v_sku;
    IF NOT FOUND THEN
      v_errors:=v_errors||private.prd_product_uom_import_error(
        'ACTIVE_STOCK_PRODUCT_NOT_FOUND');
    ELSIF lower(regexp_replace(btrim(v_product.name),'\s+',' ','g'))<>lower(v_name) THEN
      v_errors:=v_errors||private.prd_product_uom_import_error(
        'PRODUCT_IDENTITY_MISMATCH');
    END IF;

    IF v_uom_name IS NULL THEN
      UPDATE public.master_import_rows SET group_key='ROW:'||v_row.row_number,
        normalized_data=jsonb_build_object('productSku',v_sku,'productName',v_name),
        operation=CASE WHEN jsonb_array_length(v_errors)=0 THEN 'SKIP' ELSE 'ERROR' END,
        row_status=CASE WHEN jsonb_array_length(v_errors)=0 THEN 'VALIDATED' ELSE 'ERROR' END,
        errors=v_errors,updated_at=clock_timestamp()
      WHERE company_id=v_company AND job_id=p_job_id AND id=v_row.id;
      CONTINUE;
    END IF;
    SELECT uom.id INTO v_uom_id FROM public.uoms uom
    WHERE uom.company_id=v_company AND uom.is_active
      AND lower(regexp_replace(btrim(uom.name),'\s+',' ','g'))=lower(v_uom_name);
    IF v_uom_id IS NULL THEN
      v_errors:=v_errors||private.prd_product_uom_import_error('ACTIVE_PRODUCT_UOM_NOT_FOUND');
    END IF;
    IF v_product.id IS NOT NULL AND v_uom_id IS NOT NULL THEN
      SELECT * INTO v_existing FROM public.product_uoms product_uom
      WHERE product_uom.company_id=v_company AND product_uom.product_id=v_product.id
        AND product_uom.uom_id=v_uom_id;
      IF v_uom_id=v_product.uom_id THEN
        v_errors:=v_errors||private.prd_product_uom_import_error(
          'PRODUCT_UOM_FACTOR_MUST_EXCEED_BASE');
      END IF;
    END IF;
    BEGIN
      v_factor:=NULLIF(btrim(COALESCE(v_source->>(v_job.mapping->>'factorToBase'),'')),'')::NUMERIC;
      v_purchase:=private.g2_phase40_import_boolean(
        v_source->>(v_job.mapping->>'purchaseAllowed'),
        COALESCE(v_existing.purchase_allowed,FALSE));
      v_sales:=private.g2_phase40_import_boolean(
        v_source->>(v_job.mapping->>'salesAllowed'),
        COALESCE(v_existing.sales_allowed,FALSE));
      v_purchase_price:=COALESCE(NULLIF(btrim(COALESCE(
        v_source->>(v_job.mapping->>'purchasePrice'),'')),'')::NUMERIC,
        v_existing.purchase_price);
      v_sale_price:=COALESCE(NULLIF(btrim(COALESCE(
        v_source->>(v_job.mapping->>'salePrice'),'')),'')::NUMERIC,
        v_existing.sale_price);
      v_barcode:=COALESCE(NULLIF(regexp_replace(btrim(COALESCE(
        v_source->>(v_job.mapping->>'barcode'),'')),'\s+','','g'),''),
        v_existing.barcode);
      v_weight:=NULLIF(btrim(COALESCE(
        v_source->>(v_job.mapping->>'weightIfLargestKg'),'')),'')::NUMERIC;
    EXCEPTION WHEN OTHERS THEN
      v_errors:=v_errors||private.prd_product_uom_import_error('INVALID_PRODUCT_UOM_VALUE',SQLERRM);
    END;
    IF v_factor IS NULL OR v_factor<=1 THEN
      v_errors:=v_errors||private.prd_product_uom_import_error(
        'PRODUCT_UOM_FACTOR_MUST_EXCEED_BASE'); END IF;
    IF v_purchase_price<0 OR v_sale_price<0 THEN
      v_errors:=v_errors||private.prd_product_uom_import_error('PRODUCT_UOM_PRICE_NEGATIVE'); END IF;
    IF v_purchase AND v_purchase_price IS NULL THEN
      v_errors:=v_errors||private.prd_product_uom_import_error('PURCHASE_PRICE_REQUIRED'); END IF;
    IF v_sales AND v_sale_price IS NULL THEN
      v_errors:=v_errors||private.prd_product_uom_import_error('SALE_PRICE_REQUIRED'); END IF;
    IF v_product.id IS NOT NULL AND v_uom_id IS NOT NULL THEN
      SELECT COALESCE(max(product_uom.factor_to_base),1) INTO v_other_max
      FROM public.product_uoms product_uom WHERE product_uom.company_id=v_company
        AND product_uom.product_id=v_product.id AND product_uom.is_active
        AND product_uom.uom_id<>v_uom_id;
      IF v_factor=v_other_max THEN
        v_errors:=v_errors||private.prd_product_uom_import_error(
          'LARGEST_PRODUCT_UOM_FACTOR_NOT_UNIQUE');
      ELSIF v_factor>v_other_max AND COALESCE(v_weight,
        CASE WHEN v_product.weight_reference_uom_id=v_uom_id
          THEN v_product.weight_per_uom_kg END,0)<=0 THEN
        v_errors:=v_errors||private.prd_product_uom_import_error(
          'PRODUCT_UOM_LARGEST_WEIGHT_REQUIRED');
      ELSIF v_factor<v_other_max AND v_weight IS NOT NULL THEN
        v_errors:=v_errors||private.prd_product_uom_import_error('PRODUCT_UOM_NOT_LARGEST');
      ELSIF v_factor<v_other_max AND v_product.weight_reference_uom_id=v_uom_id THEN
        v_errors:=v_errors||private.prd_product_uom_import_error(
          'PRODUCT_UOM_RESELECTION_REQUIRED');
      END IF;
      IF v_existing.id IS NOT NULL
         AND v_existing.factor_to_base IS DISTINCT FROM v_factor
         AND EXISTS(SELECT 1 FROM public.stock_movements movement
           WHERE movement.company_id=v_company AND movement.product_id=v_product.id) THEN
        v_errors:=v_errors||private.prd_product_uom_import_error(
          'PRODUCT_UOM_CONVERSION_LOCKED_BY_MOVEMENT');
      END IF;
    END IF;
    IF jsonb_array_length(v_errors)=0 THEN
      v_operation:=CASE WHEN v_existing.id IS NULL THEN 'CREATE' ELSE 'UPDATE' END;
      IF v_operation='CREATE' AND v_job.operation_mode='UPDATE_ONLY' THEN
        v_errors:=v_errors||private.prd_product_uom_import_error('IMPORT_UPDATE_TARGET_NOT_FOUND');
      ELSIF v_operation='UPDATE' AND v_job.operation_mode='CREATE_ONLY' THEN
        v_errors:=v_errors||private.prd_product_uom_import_error('IMPORT_CREATE_ONLY_MATCHED_EXISTING');
      END IF;
    END IF;
    v_after:=jsonb_build_object('productId',v_product.id,
      'productMasterVersion',v_product.master_version,'uomId',v_uom_id,
      'factorToBase',v_factor,'purchaseAllowed',v_purchase,'salesAllowed',v_sales,
      'purchasePrice',v_purchase_price,'salePrice',v_sale_price,'barcode',v_barcode,
      'weightIfLargestKg',v_weight);
    IF v_existing.id IS NOT NULL THEN
      v_before:=jsonb_build_object('productId',v_existing.product_id,
        'uomId',v_existing.uom_id,'factorToBase',v_existing.factor_to_base,
        'purchaseAllowed',v_existing.purchase_allowed,
        'salesAllowed',v_existing.sales_allowed,'purchasePrice',v_existing.purchase_price,
        'salePrice',v_existing.sale_price,'barcode',v_existing.barcode,
        'weightIfLargestKg',CASE WHEN v_product.weight_reference_uom_id=v_uom_id
          THEN v_product.weight_per_uom_kg END);
      IF (v_before-'weightIfLargestKg')=(v_after-'productMasterVersion'-'weightIfLargestKg')
         AND (v_weight IS NULL OR v_weight=v_product.weight_per_uom_kg)
         AND jsonb_array_length(v_errors)=0 THEN v_operation:='SKIP'; END IF;
    END IF;
    UPDATE public.master_import_rows SET
      group_key=COALESCE(v_product.id::TEXT,'?')||':'||COALESCE(v_uom_id::TEXT,'?'),
      normalized_data=jsonb_build_object('productSku',v_sku,'productName',v_name,
        'uomName',v_uom_name),
      operation=CASE WHEN jsonb_array_length(v_errors)>0 THEN 'ERROR' ELSE v_operation END,
      row_status=CASE WHEN jsonb_array_length(v_errors)>0 THEN 'ERROR' ELSE 'VALIDATED' END,
      matched_record_id=CASE WHEN jsonb_array_length(v_errors)>0 THEN NULL ELSE v_existing.id END,
      errors=v_errors,before_state=CASE WHEN jsonb_array_length(v_errors)>0 THEN NULL ELSE v_before END,
      after_state=CASE WHEN jsonb_array_length(v_errors)>0 THEN NULL ELSE v_after END,
      warnings=CASE WHEN v_operation='UPDATE' AND jsonb_array_length(v_errors)=0
        THEN jsonb_build_array(jsonb_build_object('code','IMPORT_WILL_UPDATE_EXISTING'))
        ELSE '[]'::JSONB END,updated_at=clock_timestamp()
    WHERE company_id=v_company AND job_id=p_job_id AND id=v_row.id;
    IF jsonb_array_length(v_errors)=0 AND v_existing.id IS NOT NULL THEN
      UPDATE public.master_import_rows SET matched_master_version=v_existing.master_version
      WHERE company_id=v_company AND job_id=p_job_id AND id=v_row.id;
    END IF;
  END LOOP;
  UPDATE public.master_import_rows row SET operation='ERROR',row_status='ERROR',
    errors=errors||private.prd_product_uom_import_error('DUPLICATE_PRODUCT_UOM_IN_FILE'),
    before_state=NULL,after_state=NULL,matched_record_id=NULL,
    matched_master_version=NULL,updated_at=clock_timestamp()
  WHERE row.company_id=v_company AND row.job_id=p_job_id
    AND row.group_key NOT LIKE 'ROW:%' AND row.group_key IN(
      SELECT group_key FROM public.master_import_rows WHERE company_id=v_company
        AND job_id=p_job_id AND group_key NOT LIKE 'ROW:%'
      GROUP BY group_key HAVING count(*)>1);
  SELECT count(*) FILTER(WHERE operation='CREATE' AND row_status='VALIDATED'),
    count(*) FILTER(WHERE operation='UPDATE' AND row_status='VALIDATED'),
    count(*) FILTER(WHERE operation='SKIP' AND row_status='VALIDATED'),
    count(*) FILTER(WHERE row_status='ERROR')
  INTO v_created,v_updated,v_skipped,v_error_rows FROM public.master_import_rows
  WHERE company_id=v_company AND job_id=p_job_id;
  UPDATE public.master_import_jobs SET status='VALIDATED',created_rows=v_created,
    updated_rows=v_updated,skipped_rows=v_skipped,error_rows=v_error_rows,
    validated_by=v_actor,validated_at=clock_timestamp(),master_version=master_version+1,
    updated_at=clock_timestamp() WHERE company_id=v_company AND id=p_job_id
  RETURNING master_version INTO v_new_version;
  INSERT INTO public.master_import_job_events(company_id,job_id,event_type,actor_id,
    before_state,after_state) VALUES(v_company,p_job_id,'VALIDATE',v_actor,
    jsonb_build_object('status',v_job.status,'masterVersion',v_job.master_version),
    jsonb_build_object('status','VALIDATED','masterVersion',v_new_version,
      'createCount',v_created,'updateCount',v_updated,'skipCount',v_skipped,
      'errorCount',v_error_rows));
  RETURN jsonb_build_object('jobId',p_job_id,'masterVersion',v_new_version,
    'status','VALIDATED','createCount',v_created,'updateCount',v_updated,
    'skipCount',v_skipped,'errorCount',v_error_rows,'action','VALIDATE');
END
$$;

CREATE FUNCTION private.commit_product_uom_import_job(
  p_job_id UUID,p_master_version BIGINT,p_confirm_update_count INTEGER
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp
AS $$
DECLARE v_actor UUID:=auth.uid();v_company UUID:=public.private_active_company_id();
  v_job public.master_import_jobs%ROWTYPE;v_row public.master_import_rows%ROWTYPE;
  v_after JSONB;v_result JSONB;v_error TEXT;v_current_version BIGINT;
  v_created INTEGER;v_updated INTEGER;v_skipped INTEGER;v_errors INTEGER;
  v_status TEXT;v_new_version BIGINT;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF NOT public.private_user_has_any_company_or_store_role(v_company,
    ARRAY['COMPANY_OWNER','COMPANY_ADMIN']::TEXT[]) THEN
    RAISE EXCEPTION 'MASTER_IMPORT_ADMIN_REQUIRED'; END IF;
  SELECT * INTO v_job FROM public.master_import_jobs
  WHERE company_id=v_company AND id=p_job_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'IMPORT_JOB_NOT_FOUND'; END IF;
  IF v_job.import_type<>'PRODUCT_UOM' THEN RAISE EXCEPTION 'INVALID_PRODUCT_UOM_IMPORT_JOB'; END IF;
  IF p_master_version IS NOT NULL AND p_master_version+1=v_job.master_version
     AND v_job.status IN('COMPLETED','COMPLETED_WITH_ERRORS') THEN
    IF p_confirm_update_count IS DISTINCT FROM v_job.confirmed_update_count THEN
      RAISE EXCEPTION 'IMPORT_IDEMPOTENCY_CONFLICT'; END IF;
    RETURN jsonb_build_object('jobId',v_job.id,'masterVersion',v_job.master_version,
      'status',v_job.status,'createCount',v_job.created_rows,
      'updateCount',v_job.updated_rows,'skipCount',v_job.skipped_rows,
      'errorCount',v_job.error_rows,'action','EXISTING'); END IF;
  IF p_master_version IS NULL OR p_master_version<>v_job.master_version THEN
    RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
  IF v_job.status<>'VALIDATED' THEN RAISE EXCEPTION 'IMPORT_JOB_NOT_COMMITTABLE'; END IF;
  IF p_confirm_update_count IS NULL OR p_confirm_update_count<>v_job.updated_rows THEN
    RAISE EXCEPTION 'IMPORT_UPDATE_CONFIRMATION_REQUIRED'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(
    v_company::TEXT||':MASTER_IMPORT_COMMIT:PRODUCT_UOM',0));
  -- Lock and verify every affected Product before the first mutation.
  PERFORM product.id FROM public.products product WHERE product.company_id=v_company
    AND product.id IN(SELECT (row.after_state->>'productId')::UUID
      FROM public.master_import_rows row WHERE row.company_id=v_company
        AND row.job_id=p_job_id AND row.operation IN('CREATE','UPDATE')
        AND row.row_status='VALIDATED') ORDER BY product.id FOR UPDATE;
  IF EXISTS(SELECT 1 FROM public.master_import_rows row
    JOIN public.products product ON product.company_id=row.company_id
      AND product.id=(row.after_state->>'productId')::UUID
    WHERE row.company_id=v_company AND row.job_id=p_job_id
      AND row.operation IN('CREATE','UPDATE') AND row.row_status='VALIDATED'
      AND product.master_version<>(row.after_state->>'productMasterVersion')::BIGINT) THEN
    RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;

  FOR v_row IN SELECT * FROM public.master_import_rows WHERE company_id=v_company
    AND job_id=p_job_id AND operation IN('CREATE','UPDATE','SKIP')
    AND row_status='VALIDATED' ORDER BY row_number FOR UPDATE
  LOOP
    IF v_row.operation='SKIP' THEN
      UPDATE public.master_import_rows SET row_status='COMMITTED',
        committed_at=clock_timestamp(),updated_at=clock_timestamp()
      WHERE company_id=v_company AND job_id=p_job_id AND id=v_row.id;
      CONTINUE; END IF;
    BEGIN
      v_after:=v_row.after_state;
      SELECT master_version INTO v_current_version FROM public.products
      WHERE company_id=v_company AND id=(v_after->>'productId')::UUID;
      v_result:=private.upsert_inventory_product_uom_core(
        (v_after->>'productId')::UUID,v_current_version,
        (v_after->>'uomId')::UUID,(v_after->>'factorToBase')::NUMERIC,
        (v_after->>'purchaseAllowed')::BOOLEAN,(v_after->>'salesAllowed')::BOOLEAN,
        NULLIF(v_after->>'purchasePrice','')::NUMERIC,
        NULLIF(v_after->>'salePrice','')::NUMERIC,v_after->>'barcode',
        NULLIF(v_after->>'weightIfLargestKg','')::NUMERIC);
      UPDATE public.master_import_rows SET row_status='COMMITTED',
        matched_master_version=(v_result->>'productUomMasterVersion')::BIGINT,
        after_state=after_state||v_result,committed_at=clock_timestamp(),
        updated_at=clock_timestamp()
      WHERE company_id=v_company AND job_id=p_job_id AND id=v_row.id;
    EXCEPTION WHEN OTHERS THEN
      v_error:=SQLERRM;
      UPDATE public.master_import_rows SET operation='ERROR',row_status='ERROR',
        errors=errors||private.prd_product_uom_import_error(
          'PRODUCT_UOM_COMMIT_FAILED',v_error),committed_at=NULL,
        updated_at=clock_timestamp()
      WHERE company_id=v_company AND job_id=p_job_id AND id=v_row.id;
    END;
  END LOOP;
  SELECT count(*) FILTER(WHERE operation='CREATE' AND row_status='COMMITTED'),
    count(*) FILTER(WHERE operation='UPDATE' AND row_status='COMMITTED'),
    count(*) FILTER(WHERE operation='SKIP' AND row_status='COMMITTED'),
    count(*) FILTER(WHERE row_status='ERROR')
  INTO v_created,v_updated,v_skipped,v_errors FROM public.master_import_rows
  WHERE company_id=v_company AND job_id=p_job_id;
  v_status:=CASE WHEN v_errors>0 THEN 'COMPLETED_WITH_ERRORS' ELSE 'COMPLETED' END;
  UPDATE public.master_import_jobs SET status=v_status,created_rows=v_created,
    updated_rows=v_updated,skipped_rows=v_skipped,error_rows=v_errors,
    confirmed_update_count=p_confirm_update_count,committed_by=v_actor,
    committed_at=clock_timestamp(),master_version=master_version+1,
    updated_at=clock_timestamp() WHERE company_id=v_company AND id=p_job_id
  RETURNING master_version INTO v_new_version;
  INSERT INTO public.master_import_job_events(company_id,job_id,event_type,actor_id,
    before_state,after_state) VALUES(v_company,p_job_id,'COMPLETE',v_actor,
    jsonb_build_object('status',v_job.status,'masterVersion',v_job.master_version),
    jsonb_build_object('status',v_status,'masterVersion',v_new_version,
      'createCount',v_created,'updateCount',v_updated,'skipCount',v_skipped,
      'errorCount',v_errors));
  RETURN jsonb_build_object('jobId',p_job_id,'masterVersion',v_new_version,
    'status',v_status,'createCount',v_created,'updateCount',v_updated,
    'skipCount',v_skipped,'errorCount',v_errors,'action','COMMIT');
END
$$;

CREATE FUNCTION public.export_inventory_product_uom_placeholders()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp
AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'inventory.products','EXPORT');
  RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object(
    'product_sku',product.sku,'product_name',product.name)
    ORDER BY product.name,product.sku,product.id)
    FROM public.products product WHERE product.company_id=v_company
      AND product.is_active AND NOT product.is_bundle),'[]'::JSONB);
END
$$;

CREATE FUNCTION public.get_inventory_product_uom_import_template()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp
AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'inventory.products','IMPORT');
  RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object(
    'product_sku',product.sku,'product_name',product.name)
    ORDER BY product.name,product.sku,product.id)
    FROM public.products product WHERE product.company_id=v_company
      AND product.is_active AND NOT product.is_bundle),'[]'::JSONB);
END
$$;

CREATE OR REPLACE FUNCTION private.acp_require_product_import_if_needed(
  p_company_id UUID,p_import_type TEXT
) RETURNS VOID LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp
AS $$ BEGIN
  IF upper(btrim(COALESCE(p_import_type,''))) IN('PRODUCT','PRODUCT_UOM') THEN
    PERFORM private.acp_require_permission_capability(
      p_company_id,'inventory.products','IMPORT'); END IF;
END $$;

CREATE OR REPLACE FUNCTION public.create_master_import_job(
  p_client_request_id UUID,p_import_type TEXT,p_reference_mode TEXT,
  p_operation_mode TEXT,p_file_name TEXT,p_file_checksum TEXT,
  p_delimiter TEXT DEFAULT ','
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp
AS $$
DECLARE v_company UUID:=public.private_active_company_id();
  v_type TEXT:=upper(btrim(COALESCE(p_import_type,'')));
BEGIN
  PERFORM private.acp_require_product_import_if_needed(v_company,v_type);
  PERFORM private.acp_require_minimum_stock_import_if_needed(v_company,v_type);
  PERFORM private.acp_require_customer_import_if_needed(v_company,v_type);
  PERFORM private.acp_require_supplier_import_if_needed(v_company,v_type);
  IF v_type='CUSTOMER' THEN RETURN private.create_customer_import_job(
    p_client_request_id,p_reference_mode,p_operation_mode,p_file_name,
    p_file_checksum,p_delimiter); END IF;
  IF v_type='PRODUCT_UOM' THEN RETURN private.create_product_uom_import_job(
    p_client_request_id,p_reference_mode,p_operation_mode,p_file_name,
    p_file_checksum,p_delimiter); END IF;
  RETURN private.create_master_import_job(p_client_request_id,v_type,
    p_reference_mode,p_operation_mode,p_file_name,p_file_checksum,p_delimiter);
END
$$;

CREATE OR REPLACE FUNCTION public.validate_master_import_job(
  p_job_id UUID,p_master_version BIGINT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp
AS $$
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

CREATE OR REPLACE FUNCTION public.commit_master_import_job(
  p_job_id UUID,p_master_version BIGINT,p_confirm_update_count INTEGER
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp
AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_type TEXT;
BEGIN
  SELECT import_type INTO v_type FROM public.master_import_jobs
  WHERE company_id=v_company AND id=p_job_id;
  PERFORM private.acp_require_product_import_if_needed(v_company,v_type);
  PERFORM private.acp_require_minimum_stock_import_if_needed(v_company,v_type);
  PERFORM private.acp_require_customer_import_if_needed(v_company,v_type);
  PERFORM private.acp_require_supplier_import_if_needed(v_company,v_type);
  IF v_type='CUSTOMER' THEN RETURN private.commit_customer_import_job(
    p_job_id,p_master_version,p_confirm_update_count); END IF;
  IF v_type='PRODUCT_UOM' THEN RETURN private.commit_product_uom_import_job(
    p_job_id,p_master_version,p_confirm_update_count); END IF;
  RETURN private.commit_master_import_job(
    p_job_id,p_master_version,p_confirm_update_count);
END
$$;

REVOKE ALL ON FUNCTION
  private.prd_product_uom_import_error(TEXT,TEXT),
  private.upsert_inventory_product_uom_core(
    UUID,BIGINT,UUID,NUMERIC,BOOLEAN,BOOLEAN,NUMERIC,NUMERIC,TEXT,NUMERIC),
  private.create_product_uom_import_job(UUID,TEXT,TEXT,TEXT,TEXT,TEXT),
  private.validate_product_uom_import_job(UUID,BIGINT),
  private.commit_product_uom_import_job(UUID,BIGINT,INTEGER)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.prd_product_uom_import_error(TEXT,TEXT),
  private.upsert_inventory_product_uom_core(
    UUID,BIGINT,UUID,NUMERIC,BOOLEAN,BOOLEAN,NUMERIC,NUMERIC,TEXT,NUMERIC),
  private.create_product_uom_import_job(UUID,TEXT,TEXT,TEXT,TEXT,TEXT),
  private.validate_product_uom_import_job(UUID,BIGINT),
  private.commit_product_uom_import_job(UUID,BIGINT,INTEGER)
TO service_role;
REVOKE ALL ON FUNCTION public.export_inventory_product_uom_placeholders(),
  public.get_inventory_product_uom_import_template() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.export_inventory_product_uom_placeholders(),
  public.get_inventory_product_uom_import_template()
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260819160000','product_uom_additive_import_export',
  'Adds additive Product-UOM CSV import/export with blank Product placeholders, guarded upsert, conversion history protection, optimistic locking and audit');
NOTIFY pgrst,'reload schema';
COMMIT;
