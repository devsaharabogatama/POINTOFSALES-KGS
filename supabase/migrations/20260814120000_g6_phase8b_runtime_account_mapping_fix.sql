-- G6 phase 8B forward fix: complete every account function used by the
-- Sale/Return runtime. No Event or Journal is processed by this migration.

BEGIN;
DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260814110000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Phase 8B runtime required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260814120000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260814120000';
  END IF;
END
$guard$;

DO $provision$
DECLARE
  v_actor UUID; v_scope RECORD; v_account UUID; v_count BIGINT; v_id UUID;
BEGIN
  SELECT profile.id INTO v_actor FROM public.profiles profile
  WHERE profile.role::TEXT='super_admin' ORDER BY profile.id LIMIT 1;
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: linked Super Admin profile required';
  END IF;

  FOR v_scope IN
    WITH runtime_functions(function_key,canonical_key) AS (VALUES
      ('SALES_REVENUE'::TEXT,'SALES_REVENUE'::TEXT),
      ('SALES_RETURN_DISCOUNT','SALES_RETURN_DISCOUNT'),
      ('OUTPUT_TAX','OUTPUT_TAX'),
      ('DELIVERY_FEE_REVENUE','DELIVERY_FEE_REVENUE'),
      ('PAYMENT_SURCHARGE_INCOME','PAYMENT_SURCHARGE_INCOME'),
      ('ROUNDING_GAIN','ROUNDING_GAIN'),('ROUNDING_LOSS','ROUNDING_LOSS'),
      ('COGS','COGS'),('INVENTORY_ASSET','INVENTORY_ASSET')
    )
    SELECT company.id company_id,runtime_functions.*
    FROM public.companies company CROSS JOIN runtime_functions
    WHERE company.status='ACTIVE'
    ORDER BY company.id,runtime_functions.function_key
  LOOP
    IF EXISTS(SELECT 1 FROM public.company_account_function_fallbacks fallback
      WHERE fallback.company_id=v_scope.company_id
        AND fallback.account_function_key=v_scope.function_key
        AND fallback.status='ACTIVE'
        AND fallback.effective_from<=TIMESTAMPTZ '2000-01-01 00:00:00+00'
        AND fallback.effective_to IS NULL) THEN CONTINUE; END IF;
    IF EXISTS(SELECT 1 FROM public.company_account_function_fallbacks fallback
      WHERE fallback.company_id=v_scope.company_id
        AND fallback.account_function_key=v_scope.function_key
        AND fallback.status='ACTIVE') THEN
      RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: partial active fallback for %',
        v_scope.function_key;
    END IF;

    SELECT count(*),(array_agg(account.id ORDER BY account.id))[1]
      INTO v_count,v_account FROM public.chart_of_accounts account
    JOIN public.account_functions function_state
      ON function_state.function_key=v_scope.function_key AND function_state.is_active
    WHERE account.company_id=v_scope.company_id
      AND account.system_function_key=v_scope.canonical_key
      AND account.is_system_account AND account.is_active AND account.is_postable
      AND account.account_type=ANY(function_state.compatible_account_types);
    IF v_count<>1 OR v_account IS NULL THEN
      RAISE EXCEPTION
        'MIGRATION_PRECONDITION_FAILED: runtime function % requires exactly one canonical % account; found %',
        v_scope.function_key,v_scope.canonical_key,v_count;
    END IF;

    INSERT INTO public.company_account_function_fallbacks(
      company_id,account_function_key,account_id,effective_from,fallback_version,
      status,approved_by,approved_at,created_by,updated_by)
    VALUES(v_scope.company_id,v_scope.function_key,v_account,
      TIMESTAMPTZ '2000-01-01 00:00:00+00',
      COALESCE((SELECT max(existing.fallback_version)+1
        FROM public.company_account_function_fallbacks existing
        WHERE existing.company_id=v_scope.company_id
          AND existing.account_function_key=v_scope.function_key),1),
      'ACTIVE',v_actor,clock_timestamp(),v_actor,v_actor)
    RETURNING id INTO v_id;
    INSERT INTO public.finance_master_audit(
      company_id,entity_type,entity_id,action,actor_id,after_state)
    SELECT fallback.company_id,'FALLBACK',fallback.id,'CREATE',v_actor,to_jsonb(fallback)
    FROM public.company_account_function_fallbacks fallback WHERE fallback.id=v_id;
  END LOOP;
END
$provision$;

DO $verify$
DECLARE v_missing BIGINT;
BEGIN
  WITH event_functions AS (
    SELECT event.company_id,event.transaction_category_id,event.system_event_key,
      event.event_date,function_key
    FROM public.financial_events event
    CROSS JOIN LATERAL unnest(CASE event.system_event_key
      WHEN 'SALE_POSTED' THEN ARRAY['SALES_REVENUE','COGS','INVENTORY_ASSET']::TEXT[]
      WHEN 'SALES_RETURN' THEN ARRAY['SALES_RETURN_DISCOUNT','COGS','INVENTORY_ASSET']::TEXT[]
    END) function_key
    WHERE event.status='HOLD'::public.event_status
      AND event.system_event_key IN('SALE_POSTED','SALES_RETURN')
  ), resolution AS (
    SELECT scope.*,
      (SELECT count(*) FROM public.transaction_account_rules rule
       WHERE rule.company_id=scope.company_id
         AND rule.transaction_category_id=scope.transaction_category_id
         AND rule.system_key=scope.system_event_key
         AND rule.account_function_key=scope.function_key AND rule.status='ACTIVE'
         AND rule.effective_from<=scope.event_date
         AND (rule.effective_to IS NULL OR rule.effective_to>scope.event_date)) exact_count,
      (SELECT count(*) FROM public.company_account_function_fallbacks fallback
       WHERE fallback.company_id=scope.company_id
         AND fallback.account_function_key=scope.function_key AND fallback.status='ACTIVE'
         AND fallback.effective_from<=scope.event_date
         AND (fallback.effective_to IS NULL OR fallback.effective_to>scope.event_date)) fallback_count
    FROM event_functions scope
  )
  SELECT count(*) INTO v_missing FROM resolution
  WHERE NOT(exact_count=1 OR (exact_count=0 AND fallback_count=1));
  IF v_missing<>0 THEN
    RAISE EXCEPTION 'PHASE8B_RUNTIME_ACCOUNT_MAPPING_UNRESOLVED: % rows',v_missing;
  END IF;
END
$verify$;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260814120000','g6_phase8b_runtime_account_mapping_fix',
  'Completes audited effective-dated fallback mappings for every canonical Sale and Sales Return GL component, including Return COGS and Inventory reversal');
COMMIT;
