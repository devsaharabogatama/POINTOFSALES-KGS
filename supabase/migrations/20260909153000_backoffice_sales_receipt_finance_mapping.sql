-- Deterministic Finance mapping for Backoffice Customer receipt COGS.
-- No Customer receipt, Stock Movement, Financial Event, Journal, Invoice,
-- Revenue/AR, Payment, or historical transaction is created by this migration.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260909152000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Customer receipt foundation required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260909153000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260909153000';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
    WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.profiles profile
    WHERE profile.role::text='super_admin') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: linked Super Admin profile required';
  END IF;
  IF EXISTS(SELECT 1 FROM public.system_events
    WHERE system_key='BACKOFFICE_CUSTOMER_RECEIPT') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: receipt system event collision';
  END IF;
  IF EXISTS(SELECT 1 FROM public.transaction_categories category
    WHERE upper(regexp_replace(btrim(category.category_code),'\s+',' ','g'))='BO-SALE-RECEIPT'
      OR lower(regexp_replace(btrim(category.category_name),'\s+',' ','g'))=
        'backoffice penerimaan customer') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: receipt category identity collision';
  END IF;
END
$guard$;

INSERT INTO public.system_events(system_key,event_group,event_name,
  required_account_functions,conditional_account_functions,optional_account_functions)
VALUES('BACKOFFICE_CUSTOMER_RECEIPT','SALES','Backoffice Penerimaan Customer',
  ARRAY['COGS','INVENTORY_ASSET']::text[],ARRAY[]::text[],ARRAY[]::text[]);

CREATE FUNCTION private.resolve_backoffice_receipt_reusable_account(
  p_company_id uuid,p_function_key text
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_source text;v_count bigint;v_account uuid;
BEGIN
  FOREACH v_source IN ARRAY ARRAY['SALE_POSTED','SALE_DISPATCHED']::text[] LOOP
    SELECT count(DISTINCT rule.account_id),
      (array_agg(DISTINCT rule.account_id ORDER BY rule.account_id))[1]
    INTO v_count,v_account
    FROM public.transaction_account_rules rule
    JOIN public.transaction_categories category
      ON category.company_id=rule.company_id AND category.id=rule.transaction_category_id
    JOIN public.chart_of_accounts account
      ON account.company_id=rule.company_id AND account.id=rule.account_id
    JOIN public.account_functions function_state
      ON function_state.function_key=p_function_key AND function_state.is_active
    WHERE rule.company_id=p_company_id AND rule.system_key=v_source
      AND category.system_key=v_source AND category.is_active
      AND rule.account_function_key=p_function_key AND rule.status='ACTIVE'
      AND rule.effective_from<=clock_timestamp()
      AND (rule.effective_to IS NULL OR rule.effective_to>clock_timestamp())
      AND account.is_active AND account.is_postable
      AND account.account_type=ANY(function_state.compatible_account_types);
    IF v_count=1 THEN RETURN v_account; END IF;
    IF v_count>1 THEN
      RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: ambiguous source rule %.% %',
        p_company_id,v_source,p_function_key;
    END IF;
  END LOOP;

  SELECT count(DISTINCT fallback.account_id),
    (array_agg(DISTINCT fallback.account_id ORDER BY fallback.account_id))[1]
  INTO v_count,v_account
  FROM public.company_account_function_fallbacks fallback
  JOIN public.chart_of_accounts account
    ON account.company_id=fallback.company_id AND account.id=fallback.account_id
  JOIN public.account_functions function_state
    ON function_state.function_key=p_function_key AND function_state.is_active
  WHERE fallback.company_id=p_company_id
    AND fallback.account_function_key=p_function_key
    AND fallback.status='ACTIVE' AND fallback.effective_from<=clock_timestamp()
    AND (fallback.effective_to IS NULL OR fallback.effective_to>clock_timestamp())
    AND account.is_active AND account.is_postable
    AND account.account_type=ANY(function_state.compatible_account_types);
  IF v_count=1 THEN RETURN v_account; END IF;
  IF v_count>1 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: ambiguous fallback %.%',
      p_company_id,p_function_key;
  END IF;

  SELECT count(*),(array_agg(account.id ORDER BY account.id))[1]
  INTO v_count,v_account FROM public.chart_of_accounts account
  JOIN public.account_functions function_state
    ON function_state.function_key=p_function_key AND function_state.is_active
  WHERE account.company_id=p_company_id
    AND account.system_function_key=p_function_key
    AND account.is_system_account AND account.is_active AND account.is_postable
    AND account.account_type=ANY(function_state.compatible_account_types);
  IF v_count=1 THEN RETURN v_account; END IF;
  IF v_count>1 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: ambiguous system account %.%',
      p_company_id,p_function_key;
  END IF;
  RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: mapping source missing %.%',
    p_company_id,p_function_key;
END
$$;

DO $provision$
DECLARE
  v_actor uuid;v_company record;v_category uuid;v_account uuid;
  v_function text;v_rule uuid;v_set uuid;v_now timestamptz:=clock_timestamp();
BEGIN
  SELECT profile.id INTO STRICT v_actor FROM public.profiles profile
  WHERE profile.role::text='super_admin' ORDER BY profile.id LIMIT 1;
  FOR v_company IN SELECT company.id FROM public.companies company
    WHERE company.status='ACTIVE' ORDER BY company.id
  LOOP
    INSERT INTO public.transaction_categories(company_id,category_code,
      category_name,system_key,description,is_active,created_by,updated_by)
    VALUES(v_company.id,'BO-SALE-RECEIPT','Backoffice Penerimaan Customer',
      'BACKOFFICE_CUSTOMER_RECEIPT',
      'Pengakuan HPP dan pelepasan persediaan saat Customer menerima DO Backoffice',
      true,v_actor,v_actor) RETURNING id INTO v_category;
    INSERT INTO public.finance_master_audit(company_id,entity_type,entity_id,
      action,actor_id,after_state)
    SELECT category.company_id,'CATEGORY',category.id,'CREATE',v_actor,to_jsonb(category)
    FROM public.transaction_categories category WHERE category.id=v_category;

    FOREACH v_function IN ARRAY ARRAY['COGS','INVENTORY_ASSET']::text[] LOOP
      v_account:=private.resolve_backoffice_receipt_reusable_account(
        v_company.id,v_function);
      INSERT INTO public.transaction_account_rules(company_id,
        transaction_category_id,system_key,account_function_key,account_id,
        effective_from,rule_version,status,approved_by,approved_at,
        created_by,updated_by)
      VALUES(v_company.id,v_category,'BACKOFFICE_CUSTOMER_RECEIPT',v_function,
        v_account,v_now,1,'ACTIVE',v_actor,v_now,v_actor,v_actor)
      RETURNING id INTO v_rule;
      INSERT INTO public.finance_master_audit(company_id,entity_type,entity_id,
        action,actor_id,after_state)
      SELECT rule.company_id,'RULE',rule.id,'CREATE',v_actor,to_jsonb(rule)
      FROM public.transaction_account_rules rule WHERE rule.id=v_rule;
    END LOOP;

    INSERT INTO public.posting_rule_sets(company_id,transaction_category_id,
      system_key,rule_set_version,effective_from,status,description,
      approved_by,approved_at,created_by,updated_by)
    VALUES(v_company.id,v_category,'BACKOFFICE_CUSTOMER_RECEIPT',1,v_now,'DRAFT',
      'Backoffice Customer receipt: actual Transit FIFO cost only',
      NULL,NULL,v_actor,v_actor) RETURNING id INTO v_set;
    INSERT INTO public.posting_rule_lines(company_id,rule_set_id,line_no,
      account_function_key,entry_side,amount_expression_key,condition_key,
      is_required,created_by) VALUES
    (v_company.id,v_set,10,'COGS','DEBIT','BACKOFFICE_RECEIPT_FIFO_COST',NULL,true,v_actor),
    (v_company.id,v_set,20,'INVENTORY_ASSET','CREDIT',
      'BACKOFFICE_RECEIPT_FIFO_COST',NULL,true,v_actor);
    INSERT INTO public.posting_rule_set_audit(company_id,rule_set_id,action,
      actor_id,after_state,reason)
    SELECT rule_set.company_id,rule_set.id,'CREATE',v_actor,
      to_jsonb(rule_set)||jsonb_build_object('lines',(SELECT jsonb_agg(
        to_jsonb(line) ORDER BY line.line_no) FROM public.posting_rule_lines line
        WHERE line.company_id=rule_set.company_id AND line.rule_set_id=rule_set.id)),
      'Backoffice receipt deterministic COGS mapping foundation'
    FROM public.posting_rule_sets rule_set WHERE rule_set.id=v_set;
    UPDATE public.posting_rule_sets SET status='APPROVED',approved_by=v_actor,
      approved_at=v_now,updated_by=v_actor WHERE company_id=v_company.id AND id=v_set;
    INSERT INTO public.posting_rule_set_audit(company_id,rule_set_id,action,
      actor_id,after_state,reason)
    SELECT rule_set.company_id,rule_set.id,'APPROVE',v_actor,
      to_jsonb(rule_set)||jsonb_build_object('lines',(SELECT jsonb_agg(
        to_jsonb(line) ORDER BY line.line_no) FROM public.posting_rule_lines line
        WHERE line.company_id=rule_set.company_id AND line.rule_set_id=rule_set.id)),
      'Backoffice receipt COGS mapping approval'
    FROM public.posting_rule_sets rule_set WHERE rule_set.id=v_set;
  END LOOP;
END
$provision$;

DROP FUNCTION private.resolve_backoffice_receipt_reusable_account(uuid,text);

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260909153000','backoffice_sales_receipt_finance_mapping',
  'Audited deterministic COGS and Inventory Asset mappings for Backoffice Customer receipt; no runtime Event, Journal, Stock or Invoice effect');

NOTIFY pgrst,'reload schema';
COMMIT;
