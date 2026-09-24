-- Emergency stop. Existing matched snapshots remain audited; legacy LSM confirm resumes.
BEGIN;
DO $deactivation$
DECLARE v_company constant uuid:='07bdffb9-8c56-444c-a49b-81ac86745674'::uuid;
  v_before public.company_purchase_replenishment_settings%rowtype;
  v_after public.company_purchase_replenishment_settings%rowtype;
BEGIN
  SELECT * INTO v_before FROM public.company_purchase_replenishment_settings setting
  WHERE setting.company_id=v_company FOR UPDATE;
  IF NOT FOUND OR v_before.updated_by IS NULL THEN
    RAISE EXCEPTION 'LSM_AUTO_RO_STOCK_MATCH_DEACTIVATION_BLOCKED: setting unavailable';
  END IF;
  IF v_before.auto_ro_stock_match_enabled THEN
    UPDATE public.company_purchase_replenishment_settings
    SET auto_ro_stock_match_enabled=false,master_version=master_version+1,
      updated_at=clock_timestamp()
    WHERE company_id=v_company RETURNING * INTO v_after;
    INSERT INTO public.company_purchase_replenishment_setting_audit(
      company_id,action,actor_id,before_state,after_state)
    VALUES(v_company,'STOCK_MATCH_POLICY_CHANGE',v_before.updated_by,
      to_jsonb(v_before),to_jsonb(v_after));
  END IF;
END
$deactivation$;
COMMIT;
