-- Forward-fix C3 Finance catalog/category/rule dependency for accepted-overage COGS.
-- Target: isolated Development only. Applied migrations 130000/131000 stay immutable.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260912131000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: C3 Delivery-kind fix 20260912131000 required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260912132000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260912132000';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
    WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
  IF EXISTS(SELECT 1 FROM public.system_events
    WHERE system_key='BACKOFFICE_ACCEPTED_OVERAGE_COGS') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: accepted-overage system event collision';
  END IF;
  IF EXISTS(SELECT 1 FROM public.transaction_categories category
    WHERE upper(regexp_replace(btrim(category.category_code),'\s+',' ','g'))='BO-OVERAGE-COGS'
      OR lower(regexp_replace(btrim(category.category_name),'\s+',' ','g'))=
        'backoffice hpp kelebihan diterima') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: accepted-overage category identity collision';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.profiles profile
    WHERE profile.role::text='super_admin') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: linked Super Admin profile required';
  END IF;
END
$guard$;

INSERT INTO public.system_events(system_key,event_group,event_name,
  required_account_functions,conditional_account_functions,optional_account_functions)
VALUES('BACKOFFICE_ACCEPTED_OVERAGE_COGS','SALES','Backoffice HPP Kelebihan Diterima',
  ARRAY['COGS','INVENTORY_ASSET']::text[],ARRAY[]::text[],ARRAY[]::text[]);

CREATE FUNCTION private.provision_backoffice_accepted_overage_finance(
  p_company_id uuid,p_actor_id uuid DEFAULT NULL
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='30s' AS $$
DECLARE
  v_actor uuid;v_category uuid;v_category_count bigint;v_rule_count bigint;
  v_rule_set uuid;v_set_count bigint;v_function text;v_account uuid;
  v_source_count bigint;v_rule uuid;v_now timestamptz:=clock_timestamp();
BEGIN
  IF NOT EXISTS(SELECT 1 FROM public.companies company
    WHERE company.id=p_company_id AND company.status='ACTIVE') THEN RETURN; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(
    p_company_id::text||':BACKOFFICE_ACCEPTED_OVERAGE_FINANCE',0));
  SELECT profile.id INTO v_actor FROM public.profiles profile
  WHERE profile.id=p_actor_id;
  IF v_actor IS NULL THEN
    SELECT profile.id INTO v_actor FROM public.profiles profile
    WHERE profile.role::text='super_admin' ORDER BY profile.id LIMIT 1;
  END IF;
  IF v_actor IS NULL THEN RAISE EXCEPTION 'LINKED_SUPER_ADMIN_REQUIRED'; END IF;

  SELECT count(*),(array_agg(category.id ORDER BY category.id))[1]
  INTO v_category_count,v_category
  FROM public.transaction_categories category
  WHERE category.company_id=p_company_id
    AND category.system_key='BACKOFFICE_ACCEPTED_OVERAGE_COGS' AND category.is_active;
  IF v_category_count=0 THEN
    INSERT INTO public.transaction_categories(company_id,category_code,category_name,
      system_key,description,is_active,created_by,updated_by)
    VALUES(p_company_id,'BO-OVERAGE-COGS','Backoffice HPP Kelebihan Diterima',
      'BACKOFFICE_ACCEPTED_OVERAGE_COGS',
      'HPP dan pelepasan persediaan untuk quantity lebih yang diterima Customer',
      true,v_actor,v_actor) RETURNING id INTO v_category;
    INSERT INTO public.finance_master_audit(company_id,entity_type,entity_id,
      action,actor_id,after_state)
    SELECT category.company_id,'CATEGORY',category.id,'CREATE',v_actor,to_jsonb(category)
    FROM public.transaction_categories category WHERE category.id=v_category;
  ELSIF v_category_count<>1 THEN
    RAISE EXCEPTION 'ACCEPTED_OVERAGE_CATEGORY_MISSING_OR_AMBIGUOUS';
  END IF;

  FOREACH v_function IN ARRAY ARRAY['COGS','INVENTORY_ASSET']::text[] LOOP
    SELECT count(*),(array_agg(rule.account_id ORDER BY rule.id))[1]
    INTO v_rule_count,v_account FROM public.transaction_account_rules rule
    WHERE rule.company_id=p_company_id AND rule.transaction_category_id=v_category
      AND rule.system_key='BACKOFFICE_ACCEPTED_OVERAGE_COGS'
      AND rule.account_function_key=v_function AND rule.status='ACTIVE'
      AND rule.effective_from<=v_now
      AND (rule.effective_to IS NULL OR rule.effective_to>v_now);
    IF v_rule_count>1 THEN RAISE EXCEPTION
      'ACCEPTED_OVERAGE_ACCOUNT_MAPPING_AMBIGUOUS: %',v_function; END IF;
    IF v_rule_count=0 THEN
      SELECT count(DISTINCT source_rule.account_id),
        (array_agg(DISTINCT source_rule.account_id ORDER BY source_rule.account_id))[1]
      INTO v_source_count,v_account
      FROM public.transaction_account_rules source_rule
      JOIN public.transaction_categories source_category
        ON source_category.company_id=source_rule.company_id
       AND source_category.id=source_rule.transaction_category_id
      WHERE source_rule.company_id=p_company_id
        AND source_rule.system_key='BACKOFFICE_CUSTOMER_RECEIPT'
        AND source_category.system_key='BACKOFFICE_CUSTOMER_RECEIPT'
        AND source_category.is_active AND source_rule.account_function_key=v_function
        AND source_rule.status='ACTIVE' AND source_rule.effective_from<=v_now
        AND (source_rule.effective_to IS NULL OR source_rule.effective_to>v_now);
      IF v_source_count=0 THEN
        SELECT count(*),(array_agg(account.id ORDER BY account.id))[1]
        INTO v_source_count,v_account FROM public.chart_of_accounts account
        JOIN public.account_functions function_state
          ON function_state.function_key=v_function AND function_state.is_active
        WHERE account.company_id=p_company_id AND account.system_function_key=v_function
          AND account.is_system_account AND account.is_active AND account.is_postable
          AND account.account_type=ANY(function_state.compatible_account_types);
      END IF;
      IF v_source_count<>1 OR v_account IS NULL THEN RAISE EXCEPTION
        'ACCEPTED_OVERAGE_ACCOUNT_MAPPING_MISSING_OR_AMBIGUOUS: %',v_function; END IF;
      INSERT INTO public.transaction_account_rules(company_id,transaction_category_id,
        system_key,account_function_key,account_id,effective_from,rule_version,status,
        approved_by,approved_at,created_by,updated_by)
      VALUES(p_company_id,v_category,'BACKOFFICE_ACCEPTED_OVERAGE_COGS',v_function,
        v_account,'-infinity'::timestamptz,1,'ACTIVE',v_actor,v_now,v_actor,v_actor)
      RETURNING id INTO v_rule;
      INSERT INTO public.finance_master_audit(company_id,entity_type,entity_id,
        action,actor_id,after_state)
      SELECT rule.company_id,'RULE',rule.id,'CREATE',v_actor,to_jsonb(rule)
      FROM public.transaction_account_rules rule WHERE rule.id=v_rule;
    END IF;
  END LOOP;

  SELECT count(*),(array_agg(rule_set.id ORDER BY rule_set.id))[1]
  INTO v_set_count,v_rule_set FROM public.posting_rule_sets rule_set
  WHERE rule_set.company_id=p_company_id
    AND rule_set.transaction_category_id=v_category
    AND rule_set.system_key='BACKOFFICE_ACCEPTED_OVERAGE_COGS'
    AND rule_set.status='APPROVED' AND rule_set.effective_from<=v_now
    AND (rule_set.effective_to IS NULL OR rule_set.effective_to>v_now);
  IF v_set_count>1 THEN RAISE EXCEPTION 'ACCEPTED_OVERAGE_POSTING_RULE_AMBIGUOUS'; END IF;
  IF v_set_count=0 THEN
    IF EXISTS(SELECT 1 FROM public.posting_rule_sets rule_set
      WHERE rule_set.company_id=p_company_id
        AND rule_set.transaction_category_id=v_category) THEN
      RAISE EXCEPTION 'ACCEPTED_OVERAGE_NONAPPROVED_POSTING_RULE_COLLISION';
    END IF;
    INSERT INTO public.posting_rule_sets(company_id,transaction_category_id,system_key,
      rule_set_version,effective_from,status,description,approved_by,approved_at,
      created_by,updated_by)
    VALUES(p_company_id,v_category,'BACKOFFICE_ACCEPTED_OVERAGE_COGS',1,
      '-infinity'::timestamptz,'DRAFT',
      'Accepted overage: actual Transit FIFO cost only',NULL,NULL,v_actor,v_actor)
    RETURNING id INTO v_rule_set;
    INSERT INTO public.posting_rule_lines(company_id,rule_set_id,line_no,
      account_function_key,entry_side,amount_expression_key,condition_key,
      is_required,created_by) VALUES
      (p_company_id,v_rule_set,10,'COGS','DEBIT',
        'BACKOFFICE_ACCEPTED_OVERAGE_FIFO_COST',NULL,true,v_actor),
      (p_company_id,v_rule_set,20,'INVENTORY_ASSET','CREDIT',
        'BACKOFFICE_ACCEPTED_OVERAGE_FIFO_COST',NULL,true,v_actor);
    INSERT INTO public.posting_rule_set_audit(company_id,rule_set_id,action,
      actor_id,after_state,reason)
    SELECT rule_set.company_id,rule_set.id,'CREATE',v_actor,
      to_jsonb(rule_set)||jsonb_build_object('lines',(SELECT jsonb_agg(
        to_jsonb(line) ORDER BY line.line_no) FROM public.posting_rule_lines line
        WHERE line.company_id=rule_set.company_id AND line.rule_set_id=rule_set.id)),
      'Accepted-overage COGS mapping foundation'
    FROM public.posting_rule_sets rule_set WHERE rule_set.id=v_rule_set;
    UPDATE public.posting_rule_sets SET status='APPROVED',approved_by=v_actor,
      approved_at=v_now,updated_by=v_actor WHERE company_id=p_company_id AND id=v_rule_set;
    INSERT INTO public.posting_rule_set_audit(company_id,rule_set_id,action,
      actor_id,after_state,reason)
    SELECT rule_set.company_id,rule_set.id,'APPROVE',v_actor,
      to_jsonb(rule_set)||jsonb_build_object('lines',(SELECT jsonb_agg(
        to_jsonb(line) ORDER BY line.line_no) FROM public.posting_rule_lines line
        WHERE line.company_id=rule_set.company_id AND line.rule_set_id=rule_set.id)),
      'Accepted-overage COGS mapping approval'
    FROM public.posting_rule_sets rule_set WHERE rule_set.id=v_rule_set;
  END IF;
END
$$;

CREATE FUNCTION private.trg_provision_backoffice_accepted_overage_finance()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
  IF TG_OP='INSERT' AND NEW.status='ACTIVE' THEN
    PERFORM private.provision_backoffice_accepted_overage_finance(NEW.id,auth.uid());
  ELSIF TG_OP='UPDATE' AND NEW.status='ACTIVE'
    AND OLD.status IS DISTINCT FROM NEW.status THEN
    PERFORM private.provision_backoffice_accepted_overage_finance(NEW.id,auth.uid());
  END IF;
  RETURN NEW;
END
$$;

CREATE TRIGGER zz_provision_backoffice_accepted_overage_finance
AFTER INSERT OR UPDATE OF status ON public.companies
FOR EACH ROW EXECUTE FUNCTION private.trg_provision_backoffice_accepted_overage_finance();

DO $provision$
DECLARE v_company record;v_actor uuid;
BEGIN
  SELECT profile.id INTO STRICT v_actor FROM public.profiles profile
  WHERE profile.role::text='super_admin' ORDER BY profile.id LIMIT 1;
  FOR v_company IN SELECT company.id FROM public.companies company
    WHERE company.status='ACTIVE' ORDER BY company.id
  LOOP
    PERFORM private.provision_backoffice_accepted_overage_finance(v_company.id,v_actor);
  END LOOP;
END
$provision$;

DO $patch$
DECLARE
  v_definition text;v_old text;v_new text;v_count integer;
BEGIN
  IF to_regprocedure(
    'private.resolve_backoffice_sales_overage_wrong_item_core(uuid,bigint,uuid,date,text)') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: C3 private resolver missing';
  END IF;
  SELECT pg_get_functiondef(to_regprocedure(
    'private.resolve_backoffice_sales_overage_wrong_item_core(uuid,bigint,uuid,date,text)'))
  INTO v_definition;

  v_old:='v_effect uuid;v_movement uuid;v_event uuid;v_category uuid;';
  v_new:='v_effect uuid;v_movement uuid;v_event uuid;v_category uuid;v_rule_version bigint;v_rule_count bigint;';
  v_count:=(length(v_definition)-length(replace(v_definition,v_old,'')))/length(v_old);
  IF v_count<>1 OR position(v_new in v_definition)>0 THEN RAISE EXCEPTION
    'MIGRATION_PRECONDITION_FAILED: C3 Finance declaration anchor drift'; END IF;
  v_definition:=replace(v_definition,v_old,v_new);

  v_old:=$old$SELECT category.id INTO v_category FROM public.transaction_categories category
      WHERE category.company_id=v_company AND category.system_key='SALE_POSTED'
        AND category.is_active ORDER BY category.is_system_default DESC,category.id LIMIT 1;
      IF v_category IS NULL THEN RAISE EXCEPTION 'SALE_POSTED_TRANSACTION_CATEGORY_REQUIRED'; END IF;$old$;
  v_new:=$new$SELECT count(*) INTO v_rule_count
      FROM public.transaction_categories category
      JOIN public.posting_rule_sets rule_set ON rule_set.company_id=category.company_id
        AND rule_set.transaction_category_id=category.id
      WHERE category.company_id=v_company
        AND category.system_key='BACKOFFICE_ACCEPTED_OVERAGE_COGS'
        AND category.is_active AND rule_set.system_key='BACKOFFICE_ACCEPTED_OVERAGE_COGS'
        AND rule_set.status='APPROVED' AND rule_set.effective_from<=v_now
        AND (rule_set.effective_to IS NULL OR rule_set.effective_to>v_now);
      IF v_rule_count<>1 THEN
        RAISE EXCEPTION 'ACCEPTED_OVERAGE_POSTING_RULE_MISSING_OR_AMBIGUOUS';
      END IF;
      SELECT category.id,rule_set.rule_set_version INTO v_category,v_rule_version
      FROM public.transaction_categories category
      JOIN public.posting_rule_sets rule_set ON rule_set.company_id=category.company_id
        AND rule_set.transaction_category_id=category.id
      WHERE category.company_id=v_company
        AND category.system_key='BACKOFFICE_ACCEPTED_OVERAGE_COGS'
        AND category.is_active AND rule_set.system_key='BACKOFFICE_ACCEPTED_OVERAGE_COGS'
        AND rule_set.status='APPROVED' AND rule_set.effective_from<=v_now
        AND (rule_set.effective_to IS NULL OR rule_set.effective_to>v_now);$new$;
  v_count:=(length(v_definition)-length(replace(v_definition,v_old,'')))/length(v_old);
  IF v_count<>1 THEN RAISE EXCEPTION
    'MIGRATION_PRECONDITION_FAILED: C3 Finance category anchor drift'; END IF;
  v_definition:=replace(v_definition,v_old,v_new);

  v_old:=$old$company_id,store_id,system_event_key,transaction_category_id)
      VALUES(v_event$old$;
  v_new:=$new$company_id,store_id,system_event_key,transaction_category_id,
        transaction_rule_version)
      VALUES(v_event$new$;
  v_count:=(length(v_definition)-length(replace(v_definition,v_old,'')))/length(v_old);
  IF v_count<>1 THEN RAISE EXCEPTION
    'MIGRATION_PRECONDITION_FAILED: C3 Finance Event column anchor drift'; END IF;
  v_definition:=replace(v_definition,v_old,v_new);

  v_old:=$old$v_actor,v_company,v_order.store_id,'BACKOFFICE_ACCEPTED_OVERAGE_COGS',v_category);$old$;
  v_new:=$new$v_actor,v_company,v_order.store_id,'BACKOFFICE_ACCEPTED_OVERAGE_COGS',v_category,
        v_rule_version);$new$;
  v_count:=(length(v_definition)-length(replace(v_definition,v_old,'')))/length(v_old);
  IF v_count<>1 THEN RAISE EXCEPTION
    'MIGRATION_PRECONDITION_FAILED: C3 Finance Event value anchor drift'; END IF;
  v_definition:=replace(v_definition,v_old,v_new);

  EXECUTE v_definition;
END
$patch$;

REVOKE ALL ON FUNCTION
  private.provision_backoffice_accepted_overage_finance(uuid,uuid),
  private.trg_provision_backoffice_accepted_overage_finance()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.provision_backoffice_accepted_overage_finance(uuid,uuid),
  private.trg_provision_backoffice_accepted_overage_finance()
TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260912132000','backoffice_sales_accepted_overage_finance_catalog_fix',
  'Provisions separate accepted-overage COGS Finance catalog/category/account/rule contracts for existing and future Companies and routes C3 HOLD Events to that exact versioned mapping');
NOTIFY pgrst,'reload schema';
COMMIT;
