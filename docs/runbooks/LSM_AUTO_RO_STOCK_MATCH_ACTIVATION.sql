-- Enable only the LSM stock-match trial after migration/postflight/behavior PASS.
BEGIN;
DO $activation$
DECLARE v_company constant uuid:='07bdffb9-8c56-444c-a49b-81ac86745674'::uuid;
  v_before public.company_purchase_replenishment_settings%rowtype;
  v_after public.company_purchase_replenishment_settings%rowtype;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260924100000') THEN
    RAISE EXCEPTION 'LSM_AUTO_RO_STOCK_MATCH_ACTIVATION_BLOCKED: migration missing';
  END IF;
  IF (SELECT count(*) FROM public.companies company WHERE company.id=v_company
      AND company.company_name='Latorti Sari Median' AND company.status='ACTIVE')<>1 THEN
    RAISE EXCEPTION 'LSM_AUTO_RO_STOCK_MATCH_ACTIVATION_BLOCKED: Company identity mismatch';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs run
      WHERE run.status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'LSM_AUTO_RO_STOCK_MATCH_ACTIVATION_BLOCKED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.company_purchase_replenishment_settings setting
      WHERE setting.company_id<>v_company AND setting.auto_ro_stock_match_enabled) THEN
    RAISE EXCEPTION 'LSM_AUTO_RO_STOCK_MATCH_ACTIVATION_BLOCKED: non-LSM Company already enabled';
  END IF;
  SELECT * INTO v_before FROM public.company_purchase_replenishment_settings setting
  WHERE setting.company_id=v_company AND setting.replenishment_mode='AUTO_RO'
    AND setting.auto_ro_draft_roll_forward_enabled FOR UPDATE;
  IF NOT FOUND OR v_before.updated_by IS NULL THEN
    RAISE EXCEPTION 'LSM_AUTO_RO_STOCK_MATCH_ACTIVATION_BLOCKED: LSM AUTO_RO policy unavailable';
  END IF;
  IF NOT v_before.auto_ro_stock_match_enabled THEN
    UPDATE public.company_purchase_replenishment_settings
    SET auto_ro_stock_match_enabled=true,master_version=master_version+1,
      updated_at=clock_timestamp()
    WHERE company_id=v_company RETURNING * INTO v_after;
    INSERT INTO public.company_purchase_replenishment_setting_audit(
      company_id,action,actor_id,before_state,after_state)
    VALUES(v_company,'STOCK_MATCH_POLICY_CHANGE',v_before.updated_by,
      to_jsonb(v_before),to_jsonb(v_after));
  END IF;
END
$activation$;
SELECT 'lsm_auto_ro_stock_match_activation' check_name,
  CASE WHEN setting.auto_ro_stock_match_enabled THEN 'PASS' ELSE 'FAIL' END status,
  CASE WHEN setting.auto_ro_stock_match_enabled THEN 0 ELSE 1 END::bigint violation_rows,
  jsonb_build_object('companyId',setting.company_id,'mode',setting.replenishment_mode,
    'enabled',setting.auto_ro_stock_match_enabled,
    'effect','LSM Draft AUTO_RO must be matched before PO confirmation') details
FROM public.company_purchase_replenishment_settings setting
WHERE setting.company_id='07bdffb9-8c56-444c-a49b-81ac86745674'::uuid;
COMMIT;
