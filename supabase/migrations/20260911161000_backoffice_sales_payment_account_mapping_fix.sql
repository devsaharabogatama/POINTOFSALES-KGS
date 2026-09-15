-- Forward fix: make canonical Customer Receipt posting resolvable for every
-- active Company, including Companies created after the original Finance migrations.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260911160000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Payment Collection runtime required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260911161000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260911161000';
  END IF;
  IF to_regprocedure(
    'private.provision_customer_receipt_account_fallbacks(uuid,uuid)') IS NOT NULL
    OR to_regprocedure(
      'private.trg_provision_customer_receipt_account_fallbacks()') IS NOT NULL
    OR EXISTS(SELECT 1 FROM pg_trigger trigger_row
      WHERE trigger_row.tgrelid='public.companies'::regclass
        AND trigger_row.tgname='payment_provision_customer_receipt_fallbacks'
        AND NOT trigger_row.tgisinternal) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: provisioning routine collision';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance posting queue';
  END IF;
END
$guard$;

CREATE FUNCTION private.provision_customer_receipt_account_fallbacks(
  p_company_id uuid,p_actor_id uuid DEFAULT NULL
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_actor uuid:=p_actor_id;v_mapping record;v_account uuid;
  v_candidate_count bigint;v_active_count bigint;v_current_count bigint;
  v_version bigint;v_fallback uuid;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM public.companies company
    WHERE company.id=p_company_id AND company.status='ACTIVE') THEN RETURN; END IF;
  IF v_actor IS NULL OR NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=v_actor) THEN
    SELECT id INTO v_actor FROM public.profiles
    WHERE role::text='super_admin' ORDER BY id LIMIT 1;
  END IF;
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'CUSTOMER_RECEIPT_MAPPING_ACTOR_REQUIRED';
  END IF;

  FOR v_mapping IN SELECT * FROM (VALUES
    ('CASH_DRAWER'::text,'CASH_DRAWER'::text),
    ('BANK'::text,'BANK'::text),
    ('CUSTOMER_RECEIVABLE'::text,'CUSTOMER_RECEIVABLE'::text)
  ) mapping(function_key,account_function_key)
  LOOP
    SELECT count(*),count(*) FILTER(WHERE fallback.effective_from<=clock_timestamp()
      AND (fallback.effective_to IS NULL OR fallback.effective_to>clock_timestamp()))
    INTO v_active_count,v_current_count
    FROM public.company_account_function_fallbacks fallback
    WHERE fallback.company_id=p_company_id
      AND fallback.account_function_key=v_mapping.function_key
      AND fallback.status='ACTIVE';
    IF v_current_count=1 THEN CONTINUE; END IF;
    IF v_active_count<>0 THEN
      RAISE EXCEPTION 'CUSTOMER_RECEIPT_MAPPING_EXISTING_PERIOD_CONFLICT: %',
        v_mapping.function_key;
    END IF;

    SELECT count(*),(array_agg(account.id ORDER BY account.id))[1]
    INTO v_candidate_count,v_account
    FROM public.chart_of_accounts account
    JOIN public.account_functions function_state
      ON function_state.function_key=v_mapping.account_function_key
     AND function_state.is_active
    WHERE account.company_id=p_company_id
      AND account.system_function_key=v_mapping.account_function_key
      AND account.is_system_account AND account.is_active AND account.is_postable
      AND account.account_type=ANY(function_state.compatible_account_types);
    IF v_candidate_count<>1 OR v_account IS NULL THEN
      RAISE EXCEPTION 'CUSTOMER_RECEIPT_CANONICAL_ACCOUNT_INVALID: % found %',
        v_mapping.account_function_key,v_candidate_count;
    END IF;
    SELECT COALESCE(max(fallback.fallback_version),0)+1 INTO v_version
    FROM public.company_account_function_fallbacks fallback
    WHERE fallback.company_id=p_company_id
      AND fallback.account_function_key=v_mapping.function_key;
    INSERT INTO public.company_account_function_fallbacks(
      company_id,account_function_key,account_id,effective_from,effective_to,
      fallback_version,status,approved_by,approved_at,created_by,updated_by)
    VALUES(p_company_id,v_mapping.function_key,v_account,
      timestamptz '2000-01-01 00:00:00+00',NULL,v_version,'ACTIVE',
      v_actor,clock_timestamp(),v_actor,v_actor)
    RETURNING id INTO v_fallback;
    INSERT INTO public.finance_master_audit(
      company_id,entity_type,entity_id,action,actor_id,after_state)
    SELECT fallback.company_id,'FALLBACK',fallback.id,'CREATE',v_actor,to_jsonb(fallback)
    FROM public.company_account_function_fallbacks fallback
    WHERE fallback.company_id=p_company_id AND fallback.id=v_fallback;
  END LOOP;
END
$$;

REVOKE ALL ON FUNCTION
  private.provision_customer_receipt_account_fallbacks(uuid,uuid)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.provision_customer_receipt_account_fallbacks(uuid,uuid)
TO service_role;

DO $backfill$
DECLARE v_actor uuid;v_company record;
BEGIN
  SELECT id INTO v_actor FROM public.profiles
  WHERE role::text='super_admin' ORDER BY id LIMIT 1;
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: linked Super Admin profile required';
  END IF;
  FOR v_company IN SELECT id FROM public.companies
    WHERE status='ACTIVE' ORDER BY id
  LOOP
    PERFORM private.provision_customer_receipt_account_fallbacks(v_company.id,v_actor);
  END LOOP;
END
$backfill$;

CREATE FUNCTION private.trg_provision_customer_receipt_account_fallbacks()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
BEGIN
  IF NEW.status='ACTIVE'
    AND (TG_OP='INSERT' OR OLD.status IS DISTINCT FROM NEW.status) THEN
    PERFORM private.provision_customer_receipt_account_fallbacks(NEW.id,auth.uid());
  END IF;
  RETURN NEW;
END
$$;

REVOKE ALL ON FUNCTION
  private.trg_provision_customer_receipt_account_fallbacks()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.trg_provision_customer_receipt_account_fallbacks()
TO service_role;

CREATE TRIGGER payment_provision_customer_receipt_fallbacks
AFTER INSERT OR UPDATE OF status ON public.companies
FOR EACH ROW EXECUTE FUNCTION
  private.trg_provision_customer_receipt_account_fallbacks();

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260911161000','backoffice_sales_payment_account_mapping_fix',
  'Provision canonical CASH_DRAWER, BANK, and CUSTOMER_RECEIVABLE fallbacks for Customer Receipt posting on existing and future active Companies');
COMMIT;
