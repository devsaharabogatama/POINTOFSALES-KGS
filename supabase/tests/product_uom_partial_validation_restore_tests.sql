-- Rollback-safe behavior: an invalid Product-UOM row remains previewable.
BEGIN;
DO $test$
DECLARE v_actor UUID;v_company UUID;v_created JSONB;v_staged JSONB;
  v_result JSONB;v_job UUID;
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

  v_created:=public.create_master_import_job(gen_random_uuid(),'PRODUCT_UOM',
    'REFERENCE_BY_NAME','CREATE_AND_UPDATE','partial-product-uom.csv',
    repeat('d',64),',');
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
     OR COALESCE((v_result->>'errorCount')::INTEGER,0)<>1
     OR NOT EXISTS(SELECT 1 FROM public.master_import_jobs job
       WHERE job.company_id=v_company AND job.id=v_job
         AND job.status='VALIDATED' AND job.error_rows=1)
     OR EXISTS(SELECT 1 FROM public.master_import_job_events event
       WHERE event.company_id=v_company AND event.job_id=v_job
         AND event.event_type='CANCEL') THEN
    RAISE EXCEPTION 'TEST_FAILED: invalid row did not remain in partial preview';
  END IF;
END
$test$;
ROLLBACK;
