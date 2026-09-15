-- Step 4C forward-fix: create the canonical parent operation before CANCEL audit.
BEGIN;

DO $guard$
DECLARE v_definition text;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260911110000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Step 4C converter required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260911111000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260911111000';
  END IF;
  IF to_regprocedure('extensions.digest(bytea,text)') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: extensions.digest(bytea,text) missing';
  END IF;
  IF EXISTS(SELECT 1 FROM public.sales_process_cutover_plans
      WHERE status IN('DRAFT','PREVIEWED','APPLYING'))
    OR EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
      WHERE status IN('PREVIEWED','APPROVED','PROCESSING'))
    OR EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
      WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active cutover/Finance/Offline work';
  END IF;
  SELECT pg_get_functiondef(
    'private.convert_backoffice_order_to_retail_sale(uuid,uuid,uuid,uuid)'::regprocedure)
    INTO v_definition;
  IF v_definition NOT LIKE
      '%VALUES(p_company_id,v_source.id,gen_random_uuid(),''CANCEL'',p_actor_id,v_reason,v_before,%'
    OR v_definition LIKE
      '%VALUES(p_company_id,p_operation_id,''CANCEL'',v_source.id,%' THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Step 4C converter definition drift';
  END IF;
END
$guard$;

DO $fix$
DECLARE v_before text;v_after text;v_needle text;v_replacement text;
BEGIN
  SELECT pg_get_functiondef(
    'private.convert_backoffice_order_to_retail_sale(uuid,uuid,uuid,uuid)'::regprocedure)
    INTO STRICT v_before;
  v_needle:=$needle$    INSERT INTO public.backoffice_sales_order_audit(company_id,sales_order_id,
      operation_id,action,actor_id,reason,before_state,after_state)
    VALUES(p_company_id,v_source.id,gen_random_uuid(),'CANCEL',p_actor_id,v_reason,v_before,
      private.backoffice_sales_order_snapshot(p_company_id,v_source.id));$needle$;
  v_replacement:=$replacement$    INSERT INTO public.backoffice_sales_order_operations(company_id,operation_id,
      operation_type,sales_order_id,expected_version,request_hash,response_snapshot,actor_id)
    VALUES(p_company_id,p_operation_id,'CANCEL',v_source.id,v_source.master_version,
      encode(extensions.digest(convert_to(jsonb_build_object(
        'operation','BACKOFFICE_TO_RETAIL_CUTOVER_CANCEL','sourceOrderId',v_source.id,
        'targetRetailSaleId',v_target_id)::text,'UTF8'),'sha256'),'hex'),
      jsonb_build_object('companyId',p_company_id,
        'data',private.backoffice_sales_order_snapshot(p_company_id,v_source.id),
        'cutoverTargetId',v_target_id,'exactRetry',false),p_actor_id);
    INSERT INTO public.backoffice_sales_order_audit(company_id,sales_order_id,
      operation_id,action,actor_id,reason,before_state,after_state)
    VALUES(p_company_id,v_source.id,p_operation_id,'CANCEL',p_actor_id,v_reason,v_before,
      private.backoffice_sales_order_snapshot(p_company_id,v_source.id));$replacement$;
  IF (length(v_before)-length(replace(v_before,v_needle,'')))
      / length(v_needle)<>1 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: defective audit anchor count is not one';
  END IF;
  v_after:=replace(v_before,v_needle,v_replacement);
  EXECUTE v_after;
END
$fix$;

REVOKE ALL ON FUNCTION
  private.convert_backoffice_order_to_retail_sale(uuid,uuid,uuid,uuid)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.convert_backoffice_order_to_retail_sale(uuid,uuid,uuid,uuid)
TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260911111000','sales_process_cutover_backoffice_to_retail_operation_audit_fix',
  'Forward-fix confirmed Backoffice source retirement: insert immutable CANCEL operation with the cutover operation UUID before the FK-bound order audit; no Stock/FIFO/Payment/Invoice/Finance or process-mode change');

NOTIFY pgrst,'reload schema';
COMMIT;
