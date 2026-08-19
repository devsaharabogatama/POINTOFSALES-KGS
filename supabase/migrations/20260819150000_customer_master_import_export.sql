-- PRD: guarded Customer master CSV import/export through Global Data Exchange.

BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260812220000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: ACP-5A required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260819150000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED';
  END IF;
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
    'PRODUCT','PRODUCT_SUPPLIER','PRODUCT_WAREHOUSE_MINIMUM_STOCK'
  ));

-- The old simple-master trigger must not reinterpret the complete Customer
-- preview produced by this migration as a code/name-only master.
DO $extend_business_trigger_dispatch$
DECLARE
  v_oid OID:=to_regprocedure('private.trg_g2_validate_import_business_fields()');
  v_definition TEXT;
  v_old TEXT:='''PRODUCT_WAREHOUSE_MINIMUM_STOCK'') THEN';
  v_new TEXT:='''PRODUCT_WAREHOUSE_MINIMUM_STOCK'',''CUSTOMER'') THEN';
BEGIN
  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: import business trigger missing';
  END IF;
  SELECT pg_get_functiondef(v_oid) INTO v_definition;
  IF strpos(v_definition,v_old)=0 OR
     (length(v_definition)-length(replace(v_definition,v_old,'')))/length(v_old)<>1 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: import trigger dispatch changed';
  END IF;
  EXECUTE replace(v_definition,v_old,v_new);
END
$extend_business_trigger_dispatch$;

CREATE FUNCTION private.prd_customer_import_error(p_code TEXT,p_message TEXT DEFAULT NULL)
RETURNS JSONB LANGUAGE sql IMMUTABLE SET search_path=public,pg_temp
AS $$
  SELECT jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
    'code',p_code,'message',NULLIF(p_message,''))))
$$;

CREATE FUNCTION private.create_customer_import_job(
  p_client_request_id UUID,p_reference_mode TEXT,p_operation_mode TEXT,
  p_file_name TEXT,p_file_checksum TEXT,p_delimiter TEXT DEFAULT ','
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp
AS $$
DECLARE
  v_actor UUID:=auth.uid();v_company UUID:=public.private_active_company_id();
  v_reference_mode TEXT:=upper(btrim(COALESCE(p_reference_mode,'')));
  v_operation_mode TEXT:=upper(btrim(COALESCE(p_operation_mode,'')));
  v_file_name TEXT:=btrim(COALESCE(p_file_name,''));
  v_checksum TEXT:=lower(btrim(COALESCE(p_file_checksum,'')));
  v_delimiter TEXT:=COALESCE(p_delimiter,',');
  v_existing public.master_import_jobs%ROWTYPE;v_job_id UUID;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
  IF NOT public.private_user_has_any_company_or_store_role(v_company,
    ARRAY['COMPANY_OWNER','COMPANY_ADMIN']::TEXT[]) THEN
    RAISE EXCEPTION 'MASTER_IMPORT_ADMIN_REQUIRED';
  END IF;
  IF p_client_request_id IS NULL THEN RAISE EXCEPTION 'IMPORT_CLIENT_REQUEST_ID_REQUIRED'; END IF;
  IF v_reference_mode NOT IN('REFERENCE_BY_ID','REFERENCE_BY_NAME') THEN
    RAISE EXCEPTION 'INVALID_IMPORT_REFERENCE_MODE';
  END IF;
  IF v_operation_mode NOT IN('CREATE_ONLY','UPDATE_ONLY','CREATE_AND_UPDATE') THEN
    RAISE EXCEPTION 'INVALID_IMPORT_OPERATION_MODE';
  END IF;
  IF v_file_name='' THEN RAISE EXCEPTION 'IMPORT_FILE_NAME_REQUIRED'; END IF;
  IF v_checksum !~ '^[0-9a-f]{64}$' THEN RAISE EXCEPTION 'INVALID_IMPORT_FILE_CHECKSUM'; END IF;
  IF v_delimiter NOT IN(',', ';', E'\t', '|') THEN RAISE EXCEPTION 'INVALID_IMPORT_DELIMITER'; END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(
    v_company::TEXT||':'||p_client_request_id::TEXT,0));
  SELECT * INTO v_existing FROM public.master_import_jobs
  WHERE company_id=v_company AND client_request_id=p_client_request_id;
  IF FOUND THEN
    IF v_existing.import_type<>'CUSTOMER'
       OR v_existing.reference_mode<>v_reference_mode
       OR v_existing.operation_mode<>v_operation_mode
       OR v_existing.file_name<>v_file_name
       OR v_existing.file_checksum<>v_checksum
       OR v_existing.delimiter<>v_delimiter THEN
      RAISE EXCEPTION 'IMPORT_IDEMPOTENCY_CONFLICT';
    END IF;
    RETURN jsonb_build_object('jobId',v_existing.id,
      'masterVersion',v_existing.master_version,'status',v_existing.status,
      'action','EXISTING');
  END IF;

  INSERT INTO public.master_import_jobs(company_id,client_request_id,import_type,
    reference_mode,operation_mode,file_name,file_checksum,delimiter,uploaded_by)
  VALUES(v_company,p_client_request_id,'CUSTOMER',v_reference_mode,
    v_operation_mode,v_file_name,v_checksum,v_delimiter,v_actor)
  RETURNING id INTO v_job_id;
  INSERT INTO public.master_import_job_events(company_id,job_id,event_type,
    actor_id,after_state) VALUES(v_company,v_job_id,'CREATE',v_actor,
    jsonb_build_object('status','UPLOADED','importType','CUSTOMER',
      'referenceMode',v_reference_mode,'operationMode',v_operation_mode,
      'masterVersion',1));
  RETURN jsonb_build_object('jobId',v_job_id,'masterVersion',1,
    'status','UPLOADED','action','CREATE');
END
$$;

CREATE FUNCTION private.validate_customer_import_job(p_job_id UUID,p_master_version BIGINT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp
AS $$
DECLARE
  v_actor UUID:=auth.uid();v_company UUID:=public.private_active_company_id();
  v_job public.master_import_jobs%ROWTYPE;v_row public.master_import_rows%ROWTYPE;
  v_existing public.customers%ROWTYPE;v_source JSONB;v_errors JSONB;
  v_column TEXT;v_text TEXT;v_internal_id UUID;v_internal_text TEXT;
  v_existing_id UUID;v_category_id UUID;v_parent_id UUID;v_pricelist_id UUID;
  v_match_count BIGINT;v_code TEXT;v_name TEXT;v_category_name TEXT;
  v_parent_name TEXT;v_pricelist_name TEXT;v_phone TEXT;v_email TEXT;
  v_address TEXT;v_customer_type TEXT;v_credit_limit NUMERIC;
  v_credit_term_days INTEGER;v_notes TEXT;v_is_active BOOLEAN;
  v_before JSONB;v_after JSONB;v_operation TEXT;
  v_created INTEGER;v_updated INTEGER;v_skipped INTEGER;v_error_rows INTEGER;
  v_new_version BIGINT;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
  IF NOT public.private_user_has_any_company_or_store_role(v_company,
    ARRAY['COMPANY_OWNER','COMPANY_ADMIN']::TEXT[]) THEN
    RAISE EXCEPTION 'MASTER_IMPORT_ADMIN_REQUIRED';
  END IF;
  SELECT * INTO v_job FROM public.master_import_jobs
  WHERE company_id=v_company AND id=p_job_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'IMPORT_JOB_NOT_FOUND'; END IF;
  IF v_job.import_type<>'CUSTOMER' THEN RAISE EXCEPTION 'INVALID_CUSTOMER_IMPORT_JOB'; END IF;
  IF p_master_version IS NOT NULL AND p_master_version+1=v_job.master_version
     AND v_job.status='VALIDATED' THEN
    RETURN jsonb_build_object('jobId',v_job.id,'masterVersion',v_job.master_version,
      'status',v_job.status,'createCount',v_job.created_rows,
      'updateCount',v_job.updated_rows,'skipCount',v_job.skipped_rows,
      'errorCount',v_job.error_rows,'action','EXISTING');
  END IF;
  IF p_master_version IS NULL OR p_master_version<>v_job.master_version THEN
    RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
  END IF;
  IF v_job.status<>'MAPPED' THEN RAISE EXCEPTION 'IMPORT_JOB_NOT_VALIDATABLE'; END IF;
  FOREACH v_column IN ARRAY ARRAY['customerName','categoryName'] LOOP
    IF NULLIF(btrim(v_job.mapping->>v_column),'') IS NULL THEN
      RAISE EXCEPTION 'IMPORT_CUSTOMER_MAPPING_REQUIRED: %',v_column;
    END IF;
  END LOOP;
  IF v_job.reference_mode='REFERENCE_BY_ID'
     AND NULLIF(btrim(v_job.mapping->>'internalId'),'') IS NULL THEN
    RAISE EXCEPTION 'IMPORT_INTERNAL_ID_MAPPING_REQUIRED';
  END IF;

  UPDATE public.master_import_rows SET normalized_data=NULL,operation='PENDING',
    row_status='STAGED',matched_record_id=NULL,matched_master_version=NULL,
    warnings='[]'::JSONB,errors='[]'::JSONB,before_state=NULL,after_state=NULL,
    committed_at=NULL,updated_at=clock_timestamp()
  WHERE company_id=v_company AND job_id=p_job_id;

  FOR v_row IN SELECT * FROM public.master_import_rows
    WHERE company_id=v_company AND job_id=p_job_id ORDER BY row_number FOR UPDATE
  LOOP
    v_source:=v_row.source_data;v_errors:='[]'::JSONB;v_existing:=NULL;
    v_credit_limit:=0;v_credit_term_days:=NULL;v_is_active:=TRUE;
    v_internal_id:=NULL;
    v_internal_text:=NULL;v_existing_id:=NULL;v_category_id:=NULL;
    v_parent_id:=NULL;v_pricelist_id:=NULL;v_before:=NULL;v_operation:='ERROR';
    v_code:=upper(regexp_replace(btrim(COALESCE(
      v_source->>(v_job.mapping->>'customerCode'),'')),'\s+',' ','g'));
    v_name:=regexp_replace(btrim(COALESCE(
      v_source->>(v_job.mapping->>'customerName'),'')),'\s+',' ','g');
    v_category_name:=regexp_replace(btrim(COALESCE(
      v_source->>(v_job.mapping->>'categoryName'),'')),'\s+',' ','g');

    IF v_name='' OR char_length(v_name)>200 THEN
      v_errors:=v_errors||private.prd_customer_import_error('INVALID_CUSTOMER_NAME');
    END IF;
    IF v_code<>'' AND (char_length(v_code)>100 OR v_code='WALK-IN') THEN
      v_errors:=v_errors||private.prd_customer_import_error('INVALID_CUSTOMER_CODE');
    END IF;
    IF v_category_name='' OR char_length(v_category_name)>200 THEN
      v_errors:=v_errors||private.prd_customer_import_error('INVALID_CUSTOMER_CATEGORY_NAME');
    ELSE
      SELECT count(*),min(category.id::TEXT)::UUID INTO v_match_count,v_category_id
      FROM public.customer_categories category
      WHERE category.company_id=v_company AND category.is_active
        AND lower(regexp_replace(btrim(category.category_name),'\s+',' ','g'))=
            lower(v_category_name);
      IF v_match_count=0 THEN
        v_errors:=v_errors||private.prd_customer_import_error('ACTIVE_CUSTOMER_CATEGORY_NOT_FOUND');
      ELSIF v_match_count>1 THEN
        v_errors:=v_errors||private.prd_customer_import_error('AMBIGUOUS_CUSTOMER_CATEGORY');
        v_category_id:=NULL;
      END IF;
    END IF;

    IF v_job.reference_mode='REFERENCE_BY_ID' THEN
      v_internal_text:=NULLIF(btrim(COALESCE(
        v_source->>(v_job.mapping->>'internalId'),'')), '');
      IF v_internal_text IS NOT NULL THEN
        BEGIN
          v_internal_id:=v_internal_text::UUID;
          SELECT customer.id INTO v_existing_id FROM public.customers customer
          WHERE customer.company_id=v_company AND customer.id=v_internal_id;
          IF NOT FOUND THEN
            v_errors:=v_errors||private.prd_customer_import_error('CUSTOMER_ID_NOT_FOUND');
          END IF;
        EXCEPTION WHEN invalid_text_representation THEN
          v_errors:=v_errors||private.prd_customer_import_error('INVALID_INTERNAL_ID');
        END;
      END IF;
    END IF;
    IF v_existing_id IS NULL AND v_name<>'' THEN
      SELECT customer.id INTO v_existing_id FROM public.customers customer
      WHERE customer.company_id=v_company
        AND lower(regexp_replace(btrim(customer.name),'\s+',' ','g'))=lower(v_name);
    END IF;
    IF v_job.reference_mode='REFERENCE_BY_ID' AND v_internal_text IS NULL
       AND v_existing_id IS NOT NULL THEN
      v_errors:=v_errors||private.prd_customer_import_error(
        'IMPORT_INTERNAL_ID_REQUIRED_FOR_UPDATE');
    END IF;
    IF v_existing_id IS NOT NULL THEN
      SELECT * INTO v_existing FROM public.customers customer
      WHERE customer.company_id=v_company AND customer.id=v_existing_id;
      IF v_existing.is_system_customer THEN
        v_errors:=v_errors||private.prd_customer_import_error('SYSTEM_CUSTOMER_IMMUTABLE');
      END IF;
      IF v_job.reference_mode='REFERENCE_BY_ID'
         AND lower(regexp_replace(btrim(v_existing.name),'\s+',' ','g'))<>lower(v_name) THEN
        v_errors:=v_errors||private.prd_customer_import_error('CUSTOMER_IDENTITY_MISMATCH');
      END IF;
      IF v_code='' THEN v_code:=v_existing.code; END IF;
    END IF;

    v_parent_name:=NULLIF(regexp_replace(btrim(COALESCE(
      v_source->>(v_job.mapping->>'parentCustomerName'),'')),'\s+',' ','g'),'');
    IF v_parent_name IS NOT NULL THEN
      SELECT count(*),min(parent.id::TEXT)::UUID INTO v_match_count,v_parent_id
      FROM public.customers parent
      WHERE parent.company_id=v_company AND parent.is_active
        AND NOT parent.is_system_customer AND parent.parent_customer_id IS NULL
        AND lower(regexp_replace(btrim(parent.name),'\s+',' ','g'))=lower(v_parent_name);
      IF v_match_count=0 THEN
        v_errors:=v_errors||private.prd_customer_import_error(
          'ACTIVE_ROOT_PARENT_CUSTOMER_NOT_FOUND',
          'Customer induk harus sudah tersimpan sebelum batch import ini.');
      ELSIF v_match_count>1 THEN
        v_errors:=v_errors||private.prd_customer_import_error('AMBIGUOUS_PARENT_CUSTOMER');
        v_parent_id:=NULL;
      ELSIF v_parent_id=v_existing_id THEN
        v_errors:=v_errors||private.prd_customer_import_error('CUSTOMER_CANNOT_PARENT_ITSELF');
      END IF;
    END IF;

    v_pricelist_name:=NULLIF(regexp_replace(btrim(COALESCE(
      v_source->>(v_job.mapping->>'defaultPricelistName'),'')),'\s+',' ','g'),'');
    IF v_pricelist_name IS NOT NULL THEN
      SELECT count(*),min(pricelist.id::TEXT)::UUID INTO v_match_count,v_pricelist_id
      FROM public.pricelists pricelist
      WHERE pricelist.company_id=v_company AND pricelist.is_active
        AND pricelist.scope='CUSTOMER'
        AND lower(regexp_replace(btrim(pricelist.name),'\s+',' ','g'))=
            lower(v_pricelist_name);
      IF v_match_count=0 THEN
        v_errors:=v_errors||private.prd_customer_import_error(
          'ACTIVE_CUSTOMER_PRICELIST_NOT_FOUND');
      ELSIF v_match_count>1 THEN
        v_errors:=v_errors||private.prd_customer_import_error('AMBIGUOUS_CUSTOMER_PRICELIST');
        v_pricelist_id:=NULL;
      END IF;
    END IF;

    v_phone:=NULLIF(regexp_replace(btrim(COALESCE(
      v_source->>(v_job.mapping->>'phone'),'')),'\s+',' ','g'),'');
    v_email:=NULLIF(lower(btrim(COALESCE(
      v_source->>(v_job.mapping->>'email'),''))),'');
    v_address:=NULLIF(regexp_replace(btrim(COALESCE(
      v_source->>(v_job.mapping->>'address'),'')),'\s+',' ','g'),'');
    v_notes:=NULLIF(regexp_replace(btrim(COALESCE(
      v_source->>(v_job.mapping->>'notes'),'')),'\s+',' ','g'),'');
    v_customer_type:=upper(NULLIF(btrim(COALESCE(
      v_source->>(v_job.mapping->>'customerType'),'')),''));
    IF v_customer_type IS NULL THEN
      v_customer_type:=COALESCE(v_existing.customer_type,'INDIVIDUAL');
    END IF;
    BEGIN
      v_credit_limit:=COALESCE(NULLIF(btrim(COALESCE(
        v_source->>(v_job.mapping->>'creditLimit'),'')),'')::NUMERIC,
        COALESCE(v_existing.credit_limit,0));
      v_text:=NULLIF(btrim(COALESCE(
        v_source->>(v_job.mapping->>'creditTermDays'),'')),'');
      v_credit_term_days:=CASE WHEN v_text IS NULL THEN v_existing.credit_term_days
        ELSE v_text::INTEGER END;
      v_is_active:=private.g2_phase40_import_boolean(
        v_source->>(v_job.mapping->>'isActive'),COALESCE(v_existing.is_active,TRUE));
    EXCEPTION WHEN OTHERS THEN
      v_errors:=v_errors||private.prd_customer_import_error('INVALID_CUSTOMER_VALUE',SQLERRM);
    END;
    IF v_customer_type NOT IN('INDIVIDUAL','BUSINESS') THEN
      v_errors:=v_errors||private.prd_customer_import_error('INVALID_CUSTOMER_TYPE');
    END IF;
    IF v_credit_limit<0 THEN
      v_errors:=v_errors||private.prd_customer_import_error('INVALID_CUSTOMER_CREDIT_LIMIT');
    END IF;
    IF v_credit_term_days IS NOT NULL AND v_credit_term_days NOT BETWEEN 0 AND 3650 THEN
      v_errors:=v_errors||private.prd_customer_import_error('INVALID_CUSTOMER_CREDIT_TERM');
    END IF;
    IF char_length(v_phone)>100 OR char_length(v_email)>320
       OR char_length(v_address)>1000 OR char_length(v_notes)>1000 THEN
      v_errors:=v_errors||private.prd_customer_import_error('CUSTOMER_TEXT_TOO_LONG');
    END IF;

    IF jsonb_array_length(v_errors)=0 THEN
      IF v_existing_id IS NULL THEN
        v_operation:='CREATE';
        IF v_job.operation_mode='UPDATE_ONLY' THEN
          v_errors:=v_errors||private.prd_customer_import_error('IMPORT_UPDATE_TARGET_NOT_FOUND');
        END IF;
      ELSE
        v_operation:='UPDATE';
        IF v_job.operation_mode='CREATE_ONLY' THEN
          v_errors:=v_errors||private.prd_customer_import_error('IMPORT_CREATE_ONLY_MATCHED_EXISTING');
        END IF;
      END IF;
    END IF;
    v_after:=jsonb_build_object('customerCode',NULLIF(v_code,''),
      'customerName',v_name,'customerCategoryId',v_category_id,'phone',v_phone,
      'email',v_email,'address',v_address,'customerType',v_customer_type,
      'creditLimit',v_credit_limit,'creditTermDays',v_credit_term_days,
      'notes',v_notes,'isActive',v_is_active,'parentCustomerId',v_parent_id,
      'defaultPricelistId',v_pricelist_id);
    IF v_existing_id IS NOT NULL THEN
      v_before:=jsonb_build_object('customerCode',v_existing.code,
        'customerName',v_existing.name,'customerCategoryId',v_existing.customer_category_id,
        'phone',v_existing.phone,'email',v_existing.email,'address',v_existing.address,
        'customerType',v_existing.customer_type,'creditLimit',v_existing.credit_limit,
        'creditTermDays',v_existing.credit_term_days,'notes',v_existing.notes,
        'isActive',v_existing.is_active,'parentCustomerId',v_existing.parent_customer_id,
        'defaultPricelistId',v_existing.default_pricelist_id);
      IF v_before=v_after AND jsonb_array_length(v_errors)=0 THEN v_operation:='SKIP'; END IF;
    END IF;

    UPDATE public.master_import_rows SET group_key=lower(v_name),
      normalized_data=jsonb_build_object('customerName',v_name,
        'categoryName',v_category_name,'parentCustomerName',v_parent_name,
        'defaultPricelistName',v_pricelist_name),
      operation=CASE WHEN jsonb_array_length(v_errors)>0 THEN 'ERROR' ELSE v_operation END,
      row_status=CASE WHEN jsonb_array_length(v_errors)>0 THEN 'ERROR' ELSE 'VALIDATED' END,
      matched_record_id=CASE WHEN jsonb_array_length(v_errors)>0 THEN NULL ELSE v_existing_id END,
      warnings=CASE WHEN v_operation='UPDATE' AND jsonb_array_length(v_errors)=0
        THEN jsonb_build_array(jsonb_build_object('code','IMPORT_WILL_UPDATE_EXISTING'))
        ELSE '[]'::JSONB END,errors=v_errors,
      before_state=CASE WHEN jsonb_array_length(v_errors)>0 THEN NULL ELSE v_before END,
      after_state=CASE WHEN jsonb_array_length(v_errors)>0 THEN NULL ELSE v_after END,
      updated_at=clock_timestamp()
    WHERE company_id=v_company AND job_id=p_job_id AND id=v_row.id;
    IF jsonb_array_length(v_errors)=0 AND v_existing_id IS NOT NULL THEN
      UPDATE public.master_import_rows SET matched_master_version=v_existing.master_version
      WHERE company_id=v_company AND job_id=p_job_id AND id=v_row.id;
    END IF;
  END LOOP;

  UPDATE public.master_import_rows row SET operation='ERROR',row_status='ERROR',
    matched_record_id=NULL,matched_master_version=NULL,
    errors=errors||private.prd_customer_import_error('DUPLICATE_CUSTOMER_IN_FILE'),
    before_state=NULL,after_state=NULL,updated_at=clock_timestamp()
  WHERE row.company_id=v_company AND row.job_id=p_job_id AND row.group_key IN(
    SELECT group_key FROM public.master_import_rows
    WHERE company_id=v_company AND job_id=p_job_id GROUP BY group_key HAVING count(*)>1);

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

CREATE FUNCTION private.commit_customer_import_job(
  p_job_id UUID,p_master_version BIGINT,p_confirm_update_count INTEGER
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp
AS $$
DECLARE
  v_actor UUID:=auth.uid();v_company UUID:=public.private_active_company_id();
  v_job public.master_import_jobs%ROWTYPE;v_row public.master_import_rows%ROWTYPE;
  v_result JSONB;v_after JSONB;v_record_id UUID;v_result_version BIGINT;
  v_error TEXT;v_created INTEGER;v_updated INTEGER;v_skipped INTEGER;
  v_errors INTEGER;v_status TEXT;v_new_version BIGINT;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
  IF NOT public.private_user_has_any_company_or_store_role(v_company,
    ARRAY['COMPANY_OWNER','COMPANY_ADMIN']::TEXT[]) THEN
    RAISE EXCEPTION 'MASTER_IMPORT_ADMIN_REQUIRED';
  END IF;
  SELECT * INTO v_job FROM public.master_import_jobs
  WHERE company_id=v_company AND id=p_job_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'IMPORT_JOB_NOT_FOUND'; END IF;
  IF v_job.import_type<>'CUSTOMER' THEN RAISE EXCEPTION 'INVALID_CUSTOMER_IMPORT_JOB'; END IF;
  IF p_master_version IS NOT NULL AND p_master_version+1=v_job.master_version
     AND v_job.status IN('COMPLETED','COMPLETED_WITH_ERRORS') THEN
    IF p_confirm_update_count IS DISTINCT FROM v_job.confirmed_update_count THEN
      RAISE EXCEPTION 'IMPORT_IDEMPOTENCY_CONFLICT';
    END IF;
    RETURN jsonb_build_object('jobId',v_job.id,'masterVersion',v_job.master_version,
      'status',v_job.status,'createCount',v_job.created_rows,
      'updateCount',v_job.updated_rows,'skipCount',v_job.skipped_rows,
      'errorCount',v_job.error_rows,'action','EXISTING');
  END IF;
  IF p_master_version IS NULL OR p_master_version<>v_job.master_version THEN
    RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
  END IF;
  IF v_job.status<>'VALIDATED' THEN RAISE EXCEPTION 'IMPORT_JOB_NOT_COMMITTABLE'; END IF;
  IF p_confirm_update_count IS NULL OR p_confirm_update_count<>v_job.updated_rows THEN
    RAISE EXCEPTION 'IMPORT_UPDATE_CONFIRMATION_REQUIRED';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(
    v_company::TEXT||':MASTER_IMPORT_COMMIT:CUSTOMER',0));
  FOR v_row IN SELECT * FROM public.master_import_rows
    WHERE company_id=v_company AND job_id=p_job_id
      AND operation IN('CREATE','UPDATE','SKIP') AND row_status='VALIDATED'
    ORDER BY row_number FOR UPDATE
  LOOP
    IF v_row.operation='SKIP' THEN
      UPDATE public.master_import_rows SET row_status='COMMITTED',
        committed_at=clock_timestamp(),updated_at=clock_timestamp()
      WHERE company_id=v_company AND job_id=p_job_id AND id=v_row.id;
      CONTINUE;
    END IF;
    BEGIN
      IF v_row.operation='UPDATE' AND NOT EXISTS(SELECT 1 FROM public.customers
        WHERE company_id=v_company AND id=v_row.matched_record_id
          AND master_version=v_row.matched_master_version AND NOT is_system_customer) THEN
        RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
      END IF;
      v_after:=v_row.after_state;
      v_result:=public.save_customer_with_pricelist(
        CASE WHEN v_row.operation='CREATE' THEN NULL ELSE v_row.matched_record_id END,
        CASE WHEN v_row.operation='CREATE' THEN NULL ELSE v_row.matched_master_version END,
        v_after->>'customerCode',v_after->>'customerName',
        (v_after->>'customerCategoryId')::UUID,v_after->>'phone',v_after->>'email',
        v_after->>'address',v_after->>'customerType',
        (v_after->>'creditLimit')::NUMERIC,
        NULLIF(v_after->>'creditTermDays','')::INTEGER,v_after->>'notes',
        (v_after->>'isActive')::BOOLEAN,
        NULLIF(v_after->>'parentCustomerId','')::UUID,
        NULLIF(v_after->>'defaultPricelistId','')::UUID);
      v_record_id:=(v_result->>'customerId')::UUID;
      v_result_version:=(v_result->>'masterVersion')::BIGINT;
      UPDATE public.master_import_rows SET row_status='COMMITTED',
        matched_record_id=v_record_id,matched_master_version=v_result_version,
        after_state=after_state||jsonb_build_object('customerId',v_record_id,
          'masterVersion',v_result_version),committed_at=clock_timestamp(),
        updated_at=clock_timestamp()
      WHERE company_id=v_company AND job_id=p_job_id AND id=v_row.id;
    EXCEPTION WHEN OTHERS THEN
      v_error:=SQLERRM;
      UPDATE public.master_import_rows SET operation='ERROR',row_status='ERROR',
        errors=errors||private.prd_customer_import_error(
          'CUSTOMER_COMMIT_FAILED',v_error),committed_at=NULL,
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

CREATE FUNCTION public.export_contacts_customers()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp
AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'contacts.customers','EXPORT');
  RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object(
    'id',customer.id,'customer_code',customer.code,'customer_name',customer.name,
    'customer_category_name',category.category_name,
    'parent_customer_name',parent.name,'default_pricelist_name',pricelist.name,
    'phone',customer.phone,'email',customer.email,'address',customer.address,
    'customer_type',customer.customer_type,'credit_limit',customer.credit_limit,
    'credit_term_days',customer.credit_term_days,'notes',customer.notes,
    'is_active',customer.is_active) ORDER BY customer.name,customer.id)
    FROM public.customers customer
    JOIN public.customer_categories category ON category.company_id=customer.company_id
      AND category.id=customer.customer_category_id
    LEFT JOIN public.customers parent ON parent.company_id=customer.company_id
      AND parent.id=customer.parent_customer_id
    LEFT JOIN public.pricelists pricelist ON pricelist.company_id=customer.company_id
      AND pricelist.id=customer.default_pricelist_id
    WHERE customer.company_id=v_company AND NOT customer.is_system_customer),
    '[]'::JSONB);
END
$$;

CREATE OR REPLACE FUNCTION private.acp_require_customer_import_if_needed(
  p_company_id UUID,p_import_type TEXT
) RETURNS VOID LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp
AS $$
BEGIN
  IF upper(btrim(COALESCE(p_import_type,''))) IN('CUSTOMER','CUSTOMER_CATEGORY') THEN
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
AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_type TEXT:=upper(btrim(COALESCE(p_import_type,'')));
BEGIN
  PERFORM private.acp_require_product_import_if_needed(v_company,v_type);
  PERFORM private.acp_require_minimum_stock_import_if_needed(v_company,v_type);
  PERFORM private.acp_require_customer_import_if_needed(v_company,v_type);
  PERFORM private.acp_require_supplier_import_if_needed(v_company,v_type);
  IF v_type='CUSTOMER' THEN
    RETURN private.create_customer_import_job(p_client_request_id,
      p_reference_mode,p_operation_mode,p_file_name,p_file_checksum,p_delimiter);
  END IF;
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
  IF v_type='CUSTOMER' THEN
    RETURN private.validate_customer_import_job(p_job_id,p_master_version);
  END IF;
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
  IF v_type='CUSTOMER' THEN
    RETURN private.commit_customer_import_job(
      p_job_id,p_master_version,p_confirm_update_count);
  END IF;
  RETURN private.commit_master_import_job(
    p_job_id,p_master_version,p_confirm_update_count);
END
$$;

REVOKE ALL ON FUNCTION
  private.prd_customer_import_error(TEXT,TEXT),
  private.create_customer_import_job(UUID,TEXT,TEXT,TEXT,TEXT,TEXT),
  private.validate_customer_import_job(UUID,BIGINT),
  private.commit_customer_import_job(UUID,BIGINT,INTEGER)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.prd_customer_import_error(TEXT,TEXT),
  private.create_customer_import_job(UUID,TEXT,TEXT,TEXT,TEXT,TEXT),
  private.validate_customer_import_job(UUID,BIGINT),
  private.commit_customer_import_job(UUID,BIGINT,INTEGER)
TO service_role;
REVOKE ALL ON FUNCTION public.export_contacts_customers() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.export_contacts_customers()
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260819150000','customer_master_import_export',
  'Adds tenant-scoped Customer CSV import/export with staged validation, optimistic commit, immutable audit, and Walk-In/balance protection');

NOTIFY pgrst,'reload schema';
COMMIT;
