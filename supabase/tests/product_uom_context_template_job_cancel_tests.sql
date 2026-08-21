-- Rollback-safe behavior: contextual Product-UOM rows and terminal job cancel.
BEGIN;
DO $test$
DECLARE v_actor UUID;v_company UUID;v_created JSONB;v_staged JSONB;
  v_result JSONB;v_manual JSONB;v_job UUID;v_manual_job UUID;
  v_stale_job UUID;v_cleanup JSONB;
  v_template JSONB;v_reference_count INTEGER;v_input_count INTEGER;
BEGIN
  SELECT profile.id INTO v_actor FROM public.profiles profile
  JOIN auth.users auth_user ON auth_user.id=profile.id
  WHERE profile.role='super_admin'::public.user_role
  ORDER BY profile.id LIMIT 1;
  SELECT company.id INTO v_company FROM public.companies company
  WHERE company.status='ACTIVE' ORDER BY company.created_at,company.id LIMIT 1;
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: linked Super Admin required';
  END IF;
  IF v_company IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: active Company required';
  END IF;
  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub',v_actor,'role','authenticated')::TEXT,TRUE);
  INSERT INTO public.user_active_company_contexts(user_id,company_id,selection_source)
  VALUES(v_actor,v_company,'BACKOFFICE') ON CONFLICT(user_id) DO UPDATE SET
    company_id=EXCLUDED.company_id,selection_source=EXCLUDED.selection_source;

  v_template:=public.get_inventory_product_uom_import_template();
  SELECT count(*) FILTER(WHERE entry.value->>'row_mode'='REFERENCE'),
    count(*) FILTER(WHERE entry.value->>'row_mode'='INPUT')
  INTO v_reference_count,v_input_count
  FROM jsonb_array_elements(v_template) entry(value);
  IF v_input_count<>(SELECT count(*) FROM public.products product
    WHERE product.company_id=v_company AND product.is_active AND NOT product.is_bundle)
     OR v_reference_count<>(SELECT count(*) FROM public.product_uoms product_uom
       JOIN public.products product ON product.company_id=product_uom.company_id
         AND product.id=product_uom.product_id
       WHERE product_uom.company_id=v_company AND product_uom.is_active
         AND product.is_active AND NOT product.is_bundle) THEN
    RAISE EXCEPTION 'TEST_FAILED: contextual template row counts invalid';
  END IF;

  v_created:=public.create_master_import_job(gen_random_uuid(),'PRODUCT_UOM',
    'REFERENCE_BY_NAME','CREATE_AND_UPDATE','invalid-product-uom.csv',
    repeat('a',64),',');
  v_job:=(v_created->>'jobId')::UUID;
  v_staged:=public.stage_master_import_rows(v_job,
    (v_created->>'masterVersion')::BIGINT,
    jsonb_build_object('productSku','product_sku','productName','product_name',
      'uomName','uom_name','factorToBase','factor_to_base',
      'purchaseAllowed','purchase_allowed','salesAllowed','sales_allowed',
      'purchasePrice','purchase_price','salePrice','sale_price',
      'barcode','barcode','weightIfLargestKg','weight_if_largest_kg'),
    jsonb_build_array(jsonb_build_object('rowNumber',2,'sourceData',
      jsonb_build_object('product_sku','DOES-NOT-EXIST',
        'product_name','Invalid Product','uom_name','DUS',
        'factor_to_base','10','purchase_allowed','FALSE',
        'sales_allowed','FALSE'))));
  v_result:=public.validate_master_import_job(v_job,
    (v_staged->>'masterVersion')::BIGINT);
  IF v_result->>'status'<>'VALIDATED'
     OR NOT EXISTS(SELECT 1 FROM public.master_import_jobs job
       WHERE job.company_id=v_company AND job.id=v_job
         AND job.status='VALIDATED' AND job.error_rows>0)
     OR EXISTS(SELECT 1 FROM public.master_import_job_events event
       WHERE event.company_id=v_company AND event.job_id=v_job
         AND event.event_type='CANCEL') THEN
    RAISE EXCEPTION 'TEST_FAILED: invalid Product-UOM row did not remain previewable';
  END IF;
  PERFORM public.cancel_master_import_job(v_job,
    (v_result->>'masterVersion')::BIGINT,'TEST_CLEANUP');

  v_created:=public.create_master_import_job(gen_random_uuid(),'PRODUCT_UOM',
    'REFERENCE_BY_NAME','CREATE_AND_UPDATE','manual-cancel-product-uom.csv',
    repeat('b',64),',');
  v_manual_job:=(v_created->>'jobId')::UUID;
  v_manual:=public.cancel_master_import_job(v_manual_job,
    (v_created->>'masterVersion')::BIGINT,'USER_CANCELED');
  IF v_manual->>'status'<>'CANCELED'
     OR NOT EXISTS(SELECT 1 FROM public.master_import_jobs job
       WHERE job.company_id=v_company AND job.id=v_manual_job
         AND job.status='CANCELED') THEN
    RAISE EXCEPTION 'TEST_FAILED: manual import cancellation invalid';
  END IF;

  v_created:=public.create_master_import_job(gen_random_uuid(),'PRODUCT_UOM',
    'REFERENCE_BY_NAME','CREATE_AND_UPDATE','stale-product-uom.csv',
    repeat('c',64),',');
  v_stale_job:=(v_created->>'jobId')::UUID;
  UPDATE public.master_import_jobs SET
    updated_at=clock_timestamp()-INTERVAL '16 minutes'
  WHERE company_id=v_company AND id=v_stale_job;
  v_cleanup:=public.cleanup_stale_master_import_jobs();
  IF COALESCE((v_cleanup->>'canceledCount')::INTEGER,0)<1
     OR NOT EXISTS(SELECT 1 FROM public.master_import_jobs job
       WHERE job.company_id=v_company AND job.id=v_stale_job
         AND job.status='CANCELED')
     OR NOT EXISTS(SELECT 1 FROM public.master_import_job_events event
       WHERE event.company_id=v_company AND event.job_id=v_stale_job
         AND event.event_type='CANCEL'
         AND event.after_state->>'reason'='AUTO_STALE_UNVALIDATED') THEN
    RAISE EXCEPTION 'TEST_FAILED: stale unvalidated import was not auto-canceled';
  END IF;
END
$test$;
ROLLBACK;
