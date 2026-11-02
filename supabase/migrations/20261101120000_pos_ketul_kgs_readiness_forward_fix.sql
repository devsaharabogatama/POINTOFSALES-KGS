-- Forward fix: provision the approved Ketul payable contract for KGS and
-- expose one fail-closed Company-scoped POS readiness authority.

BEGIN;

DO $guard$
DECLARE
  v_company CONSTANT UUID := 'd290f1ee-6c54-4b01-90e6-d701748f0851';
  v_category UUID;
BEGIN
  IF (SELECT count(*) FROM private.kgs_schema_migrations
      WHERE version='20261031110000')<>1 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: installed Ketul runtime missing';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20261101120000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20261101120000';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.companies company
      WHERE company.id=v_company AND company.company_code='KGS'
        AND company.company_name='KGS Company' AND company.status='ACTIVE') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: exact KGS identity';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.company_features feature
      WHERE feature.company_id=v_company AND feature.feature_code='ketul_enabled'
        AND feature.is_enabled) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: KGS Ketul entitlement';
  END IF;
  IF (SELECT count(*) FROM public.product_categories category
      WHERE category.company_id=v_company AND category.is_active
        AND upper(btrim(category.category_name))='KETUL')<>1
    OR (SELECT count(*) FROM public.products product
      JOIN public.product_categories category
        ON category.company_id=product.company_id AND category.id=product.category_id
      WHERE product.company_id=v_company AND product.is_active
        AND NOT product.is_bundle AND category.is_active
        AND upper(btrim(category.category_name))='KETUL')<>4 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: exact KGS Ketul catalog';
  END IF;
  SELECT category.id INTO STRICT v_category
  FROM public.transaction_categories category
  WHERE category.company_id=v_company AND category.is_active
    AND category.system_key='KETUL_CUSTOMER_INTAKE';
  IF (SELECT count(*) FROM public.transaction_account_rules rule
      JOIN public.chart_of_accounts account
        ON account.company_id=rule.company_id AND account.id=rule.account_id
      WHERE rule.company_id=v_company AND rule.transaction_category_id=v_category
        AND rule.account_function_key='INVENTORY_ASSET'
        AND rule.status='ACTIVE' AND rule.effective_from<=clock_timestamp()
        AND (rule.effective_to IS NULL OR rule.effective_to>clock_timestamp())
        AND account.account_code='1030100-4'
        AND account.account_name='PERSEDIAAN KETUL'
        AND account.account_type='ASSET' AND account.normal_balance='DEBIT'
        AND account.is_active AND account.is_postable
        AND NOT account.is_system_account)<>1 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: current KGS Ketul inventory authority';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.chart_of_accounts account
      WHERE account.company_id=v_company AND account.account_code='2010105'
        AND account.account_name='HUTANG LAIN-LAINNYA'
        AND account.account_type='LIABILITY' AND account.normal_balance='CREDIT'
        AND account.is_active AND account.is_postable
        AND NOT account.is_system_account) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: KGS liability authority';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.account_functions function_state
      WHERE function_state.function_key='CUSTOMER_KETUL_PAYABLE'
        AND function_state.default_normal_balance='CREDIT'
        AND 'LIABILITY'=ANY(function_state.compatible_account_types))
    OR to_regprocedure('public.save_pos_sale_draft_with_ketul(jsonb)') IS NULL
    OR to_regprocedure('public.post_pos_sale_with_ketul(uuid,bigint,uuid)') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: installed generic Ketul contract';
  END IF;
  IF EXISTS(SELECT 1 FROM public.chart_of_accounts account
      WHERE account.company_id=v_company AND (account.account_code='2010105-1'
        OR lower(btrim(account.account_name))=lower('HUTANG KETUL CUSTOMER')))
    OR EXISTS(SELECT 1 FROM public.transaction_account_rules rule
      WHERE rule.company_id=v_company AND rule.transaction_category_id=v_category
        AND rule.account_function_key='CUSTOMER_KETUL_PAYABLE'
        AND rule.status='ACTIVE' AND rule.effective_to IS NULL)
    OR EXISTS(SELECT 1 FROM public.company_account_function_fallbacks fallback
      WHERE fallback.company_id=v_company
        AND fallback.account_function_key='CUSTOMER_KETUL_PAYABLE'
        AND fallback.status='ACTIVE' AND fallback.effective_to IS NULL)
    OR EXISTS(SELECT 1 FROM public.payment_methods method
      WHERE method.company_id=v_company AND method.method_type='KETUL_OFFSET'
        AND method.is_active)
    OR to_regprocedure('public.get_pos_ketul_readiness()') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: partial KGS Ketul payable configuration';
  END IF;
END
$guard$;

DO $finance$
DECLARE
  v_company CONSTANT UUID := 'd290f1ee-6c54-4b01-90e6-d701748f0851';
  v_actor UUID;
  v_account UUID;
  v_category UUID;
  v_now TIMESTAMPTZ := clock_timestamp();
  v_rule_version BIGINT;
  v_fallback_version BIGINT;
BEGIN
  SELECT profile.id INTO STRICT v_actor
  FROM public.profiles profile
  WHERE public.private_is_super_admin(profile.id)
  ORDER BY profile.id LIMIT 1;

  INSERT INTO public.chart_of_accounts(
    company_id,account_code,account_name,account_type,normal_balance,
    parent_account_id,system_function_key,is_system_account,is_postable,
    allow_manual_posting,allow_reconciliation,is_active,created_by,updated_by
  ) VALUES (
    v_company,'2010105-1','HUTANG KETUL CUSTOMER','LIABILITY','CREDIT',
    NULL,NULL,false,true,false,true,true,v_actor,v_actor
  ) RETURNING id INTO v_account;

  INSERT INTO public.finance_master_audit(
    company_id,entity_type,entity_id,action,actor_id,after_state
  )
  SELECT v_company,'ACCOUNT',account.id,'CREATE',v_actor,to_jsonb(account)
  FROM public.chart_of_accounts account WHERE account.id=v_account;

  SELECT category.id INTO STRICT v_category
  FROM public.transaction_categories category
  WHERE category.company_id=v_company AND category.is_active
    AND category.system_key='KETUL_CUSTOMER_INTAKE';

  SELECT coalesce(max(rule.rule_version),0)+1 INTO v_rule_version
  FROM public.transaction_account_rules rule
  WHERE rule.company_id=v_company AND rule.transaction_category_id=v_category
    AND rule.account_function_key='CUSTOMER_KETUL_PAYABLE';
  INSERT INTO public.transaction_account_rules(
    company_id,transaction_category_id,system_key,account_function_key,
    account_id,effective_from,rule_version,status,approved_by,approved_at,
    created_by,updated_by
  ) VALUES (
    v_company,v_category,'KETUL_CUSTOMER_INTAKE','CUSTOMER_KETUL_PAYABLE',
    v_account,v_now,v_rule_version,'ACTIVE',v_actor,v_now,v_actor,v_actor
  );

  SELECT coalesce(max(fallback.fallback_version),0)+1 INTO v_fallback_version
  FROM public.company_account_function_fallbacks fallback
  WHERE fallback.company_id=v_company
    AND fallback.account_function_key='CUSTOMER_KETUL_PAYABLE';
  INSERT INTO public.company_account_function_fallbacks(
    company_id,account_function_key,account_id,effective_from,
    fallback_version,status,approved_by,approved_at,created_by,updated_by
  ) VALUES (
    v_company,'CUSTOMER_KETUL_PAYABLE',v_account,v_now,v_fallback_version,
    'ACTIVE',v_actor,v_now,v_actor,v_actor
  );

  INSERT INTO public.payment_methods(
    company_id,payment_method_code,payment_method_name,method_type,
    settlement_route,is_default,available_all_stores,proof_mode,fee_enabled,
    is_active,is_system_method,created_by,updated_by
  ) VALUES (
    v_company,'','Potongan Ketul','KETUL_OFFSET','INTERNAL_LIABILITY',
    false,true,'OPTIONAL',false,true,true,v_actor,v_actor
  );
END
$finance$;

CREATE FUNCTION public.get_pos_ketul_readiness()
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_company UUID := public.private_active_company_id();
  v_now TIMESTAMPTZ := clock_timestamp();
  v_enabled BOOLEAN := false;
  v_category_count INTEGER := 0;
  v_product_count INTEGER := 0;
  v_event_category_count INTEGER := 0;
  v_inventory_rule_count INTEGER := 0;
  v_payable_rule_count INTEGER := 0;
  v_fallback_count INTEGER := 0;
  v_method_count INTEGER := 0;
  v_ready BOOLEAN;
  v_blocker TEXT;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;

  SELECT EXISTS(SELECT 1 FROM public.company_features feature
    WHERE feature.company_id=v_company AND feature.feature_code='ketul_enabled'
      AND feature.is_enabled) INTO v_enabled;
  SELECT count(*) INTO v_category_count
  FROM public.product_categories category
  WHERE category.company_id=v_company AND category.is_active
    AND upper(btrim(category.category_name))='KETUL';
  SELECT count(*) INTO v_product_count
  FROM public.products product
  JOIN public.product_categories category
    ON category.company_id=product.company_id AND category.id=product.category_id
  JOIN public.uoms uom
    ON uom.company_id=product.company_id AND uom.id=product.uom_id
  WHERE product.company_id=v_company AND product.is_active
    AND NOT product.is_bundle AND category.is_active
    AND upper(btrim(category.category_name))='KETUL';
  SELECT count(*) INTO v_event_category_count
  FROM public.transaction_categories category
  WHERE category.company_id=v_company AND category.is_active
    AND category.system_key='KETUL_CUSTOMER_INTAKE';
  SELECT count(*) FILTER (WHERE rule.account_function_key='INVENTORY_ASSET'),
    count(*) FILTER (WHERE rule.account_function_key='CUSTOMER_KETUL_PAYABLE')
  INTO v_inventory_rule_count,v_payable_rule_count
  FROM public.transaction_account_rules rule
  JOIN public.transaction_categories category
    ON category.company_id=rule.company_id AND category.id=rule.transaction_category_id
  JOIN public.chart_of_accounts account
    ON account.company_id=rule.company_id AND account.id=rule.account_id
  WHERE rule.company_id=v_company AND category.is_active
    AND category.system_key='KETUL_CUSTOMER_INTAKE'
    AND rule.account_function_key IN('INVENTORY_ASSET','CUSTOMER_KETUL_PAYABLE')
    AND rule.status='ACTIVE' AND rule.effective_from<=v_now
    AND (rule.effective_to IS NULL OR rule.effective_to>v_now)
    AND account.is_active AND account.is_postable AND NOT account.is_system_account
    AND ((rule.account_function_key='INVENTORY_ASSET'
          AND account.account_type='ASSET' AND account.normal_balance='DEBIT')
      OR (rule.account_function_key='CUSTOMER_KETUL_PAYABLE'
          AND account.account_type='LIABILITY' AND account.normal_balance='CREDIT'));
  SELECT count(*) INTO v_fallback_count
  FROM public.company_account_function_fallbacks fallback
  JOIN public.chart_of_accounts account
    ON account.company_id=fallback.company_id AND account.id=fallback.account_id
  WHERE fallback.company_id=v_company
    AND fallback.account_function_key='CUSTOMER_KETUL_PAYABLE'
    AND fallback.status='ACTIVE' AND fallback.effective_from<=v_now
    AND (fallback.effective_to IS NULL OR fallback.effective_to>v_now)
    AND account.is_active AND account.is_postable AND NOT account.is_system_account
    AND account.account_type='LIABILITY' AND account.normal_balance='CREDIT';
  SELECT count(*) INTO v_method_count
  FROM public.payment_methods method
  WHERE method.company_id=v_company AND method.is_active
    AND method.method_type='KETUL_OFFSET'
    AND method.settlement_route='INTERNAL_LIABILITY'
    AND method.is_system_method;

  v_ready:=v_enabled AND v_category_count=1 AND v_product_count>0
    AND v_event_category_count=1 AND v_inventory_rule_count=1
    AND v_payable_rule_count=1 AND v_fallback_count=1 AND v_method_count=1;
  v_blocker:=CASE
    WHEN NOT v_enabled THEN 'KETUL_FEATURE_DISABLED'
    WHEN v_category_count<>1 THEN 'KETUL_CATEGORY_NOT_READY'
    WHEN v_product_count=0 THEN 'KETUL_PRODUCT_NOT_READY'
    WHEN v_event_category_count<>1 THEN 'KETUL_EVENT_CATEGORY_NOT_READY'
    WHEN v_inventory_rule_count<>1 THEN 'KETUL_INVENTORY_MAPPING_NOT_READY'
    WHEN v_payable_rule_count<>1 THEN 'KETUL_PAYABLE_MAPPING_NOT_READY'
    WHEN v_fallback_count<>1 THEN 'KETUL_PAYABLE_FALLBACK_NOT_READY'
    WHEN v_method_count<>1 THEN 'KETUL_INTERNAL_METHOD_NOT_READY'
    ELSE NULL END;
  RETURN jsonb_build_object(
    'enabled',v_enabled,'ready',v_ready,'blockerCode',v_blocker,
    'onlineOnly',true,'productCount',v_product_count
  );
END
$$;

REVOKE ALL ON FUNCTION public.get_pos_ketul_readiness()
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_pos_ketul_readiness()
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20261101120000','pos_ketul_kgs_readiness_forward_fix',
  'Provision approved KGS Ketul payable authority and add fail-closed Company-scoped POS readiness; no business rows or other Company activation');

COMMIT;
