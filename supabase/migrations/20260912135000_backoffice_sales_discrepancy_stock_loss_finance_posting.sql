-- Step 5/6.2: controlled Finance posting for Backoffice delivery Stock Loss.
-- Warehouse resolution already owns Stock/FIFO; the Finance queue only posts its HOLD event.
BEGIN;

DO $guard$
DECLARE v_post text;v_supported text;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260912134000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Step 5/6.1 required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260912135000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260912135000';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
    WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
  IF to_regprocedure('private.post_backoffice_discrepancy_stock_loss_financial_event_core(uuid,uuid,bigint,uuid)') IS NOT NULL
    OR to_regprocedure('private.post_financial_event_core_pre_backoffice_discrepancy_stock_loss(uuid,uuid,bigint,uuid)') IS NOT NULL
    OR to_regprocedure('private.f4b_financial_event_supported_pre_backoffice_discrepancy_stock_loss(public.financial_events)') IS NOT NULL
    OR to_regprocedure('private.provision_backoffice_discrepancy_stock_loss_finance(uuid,uuid)') IS NOT NULL
    OR to_regprocedure('private.trg_provision_backoffice_discrepancy_stock_loss_finance()') IS NOT NULL
    OR EXISTS(SELECT 1 FROM pg_trigger WHERE tgname='zz_provision_backoffice_discrepancy_stock_loss_finance'
      AND NOT tgisinternal) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: discrepancy Stock Loss wrapper collision';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.profiles profile
    WHERE profile.role::text='super_admin') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: linked Super Admin profile required';
  END IF;
  SELECT pg_get_functiondef('private.post_financial_event_core(uuid,uuid,bigint,uuid)'::regprocedure)
    INTO STRICT v_post;
  IF position('BACKOFFICE_ACCEPTED_OVERAGE_COGS' in v_post)=0
    OR position('post_backoffice_accepted_overage_financial_event_core' in v_post)=0
    OR position('post_financial_event_core_pre_backoffice_accepted_overage' in v_post)=0 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical Finance post chain drift';
  END IF;
  SELECT pg_get_functiondef('private.f4b_financial_event_supported(public.financial_events)'::regprocedure)
    INTO STRICT v_supported;
  IF position('BACKOFFICE_ACCEPTED_OVERAGE_COGS' in v_supported)=0
    OR position('f4b_financial_event_supported_pre_backoffice_accepted_overage' in v_supported)=0 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical Finance support chain drift';
  END IF;
  IF EXISTS(
    SELECT 1 FROM public.financial_events event
    LEFT JOIN public.backoffice_sales_discrepancy_stock_effects effect
      ON effect.company_id=event.company_id AND effect.id=event.source_id
      AND effect.financial_event_id=event.id
    LEFT JOIN public.backoffice_sales_delivery_discrepancy_lines line
      ON line.company_id=effect.company_id AND line.id=effect.discrepancy_line_id
    WHERE event.system_event_key='STOCK_LOSS'
      AND event.source_table='backoffice_sales_discrepancy_stock_effects'
      AND (event.event_type::text<>'STOCK_LOSS' OR effect.id IS NULL
        OR effect.effect_type<>'EXPECTED_WRITE_OFF' OR line.id IS NULL
        OR line.physical_state NOT IN('LOST','DAMAGED')
        OR jsonb_typeof(event.amounts) IS DISTINCT FROM 'object'
        OR jsonb_typeof(event.amounts->'stockLossDebit') IS DISTINCT FROM 'number'
        OR jsonb_typeof(event.amounts->'inventoryCredit') IS DISTINCT FROM 'number'
        OR event.transaction_category_id IS NULL)
  ) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: discrepancy Stock Loss Event source drift';
  END IF;
  IF EXISTS(
    SELECT 1 FROM public.financial_events event
    JOIN public.backoffice_sales_discrepancy_stock_effects effect
      ON effect.company_id=event.company_id AND effect.id=event.source_id
      AND effect.financial_event_id=event.id
    WHERE event.system_event_key='STOCK_LOSS'
      AND event.source_table='backoffice_sales_discrepancy_stock_effects'
      AND (round((event.amounts->>'stockLossDebit')::numeric,4)<>round(effect.total_cost,4)
        OR round((event.amounts->>'inventoryCredit')::numeric,4)<>round(effect.total_cost,4)
        OR round(effect.quantity_base,6)<>(SELECT round(COALESCE(sum(allocation.quantity_base),0),6)
          FROM public.backoffice_sales_discrepancy_fifo_allocations allocation
          WHERE allocation.company_id=effect.company_id AND allocation.stock_effect_id=effect.id)
        OR round(effect.total_cost,4)<>(SELECT round(COALESCE(sum(allocation.total_cost),0),4)
          FROM public.backoffice_sales_discrepancy_fifo_allocations allocation
          WHERE allocation.company_id=effect.company_id AND allocation.stock_effect_id=effect.id)
        OR NOT EXISTS(SELECT 1 FROM public.stock_movements movement
          WHERE movement.company_id=effect.company_id
            AND movement.id=effect.source_stock_movement_id
            AND movement.reference_table='backoffice_sales_discrepancy_stock_effects'
            AND movement.reference_id=effect.id AND movement.product_id=effect.product_id
            AND movement.warehouse_id=effect.source_warehouse_id
            AND movement.movement_status='POSTED'
            AND round(movement.qty_change,6)=-round(effect.quantity_base,6)))
  ) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: discrepancy Stock Loss lineage drift';
  END IF;
END
$guard$;

CREATE FUNCTION private.provision_backoffice_discrepancy_stock_loss_finance(
  p_company_id uuid,p_actor_id uuid DEFAULT NULL
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='30s' AS $$
DECLARE
  v_actor uuid;v_category uuid;v_category_count bigint;v_rule_count bigint;
  v_fallback_count bigint;v_system_count bigint;v_account uuid;v_rule uuid;
  v_rule_set uuid;v_set_count bigint;v_function text;v_version bigint;
  v_now timestamptz:=clock_timestamp();
BEGIN
  IF NOT EXISTS(SELECT 1 FROM public.companies company
    WHERE company.id=p_company_id AND company.status='ACTIVE') THEN RETURN; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(
    p_company_id::text||':BACKOFFICE_DISCREPANCY_STOCK_LOSS_FINANCE',0));
  SELECT profile.id INTO v_actor FROM public.profiles profile WHERE profile.id=p_actor_id;
  IF v_actor IS NULL THEN
    SELECT profile.id INTO v_actor FROM public.profiles profile
    WHERE profile.role::text='super_admin' ORDER BY profile.id LIMIT 1;
  END IF;
  IF v_actor IS NULL THEN RAISE EXCEPTION 'LINKED_SUPER_ADMIN_REQUIRED'; END IF;

  SELECT count(*),(array_agg(category.id ORDER BY category.id))[1]
  INTO v_category_count,v_category FROM public.transaction_categories category
  WHERE category.company_id=p_company_id AND category.system_key='STOCK_LOSS'
    AND category.is_active;
  IF v_category_count<>1 THEN
    RAISE EXCEPTION 'STOCK_LOSS_CATEGORY_MISSING_OR_AMBIGUOUS';
  END IF;

  FOREACH v_function IN ARRAY ARRAY['STOCK_LOSS_EXPENSE','INVENTORY_ASSET']::text[] LOOP
    SELECT count(*),(array_agg(rule.account_id ORDER BY rule.rule_version DESC,rule.id))[1],
      COALESCE(max(rule.rule_version),0)
    INTO v_rule_count,v_account,v_version FROM public.transaction_account_rules rule
    WHERE rule.company_id=p_company_id AND rule.transaction_category_id=v_category
      AND rule.system_key='STOCK_LOSS' AND rule.account_function_key=v_function
      AND rule.status='ACTIVE' AND rule.effective_from<=v_now
      AND (rule.effective_to IS NULL OR rule.effective_to>v_now);
    IF v_rule_count>1 THEN RAISE EXCEPTION
      'STOCK_LOSS_ACCOUNT_MAPPING_AMBIGUOUS: %',v_function; END IF;
    IF v_rule_count=1 AND NOT EXISTS(
      SELECT 1 FROM public.chart_of_accounts account
      JOIN public.account_functions function_state
        ON function_state.function_key=v_function AND function_state.is_active
      WHERE account.company_id=p_company_id AND account.id=v_account
        AND account.is_active AND account.is_postable
        AND account.account_type=ANY(function_state.compatible_account_types)
    ) THEN RAISE EXCEPTION 'STOCK_LOSS_ACCOUNT_MAPPING_INVALID: %',v_function; END IF;
    IF v_rule_count=0 THEN
      SELECT count(*),(array_agg(fallback.account_id ORDER BY fallback.fallback_version DESC,fallback.id))[1]
      INTO v_fallback_count,v_account FROM public.company_account_function_fallbacks fallback
      WHERE fallback.company_id=p_company_id AND fallback.account_function_key=v_function
        AND fallback.status='ACTIVE' AND fallback.effective_from<=v_now
        AND (fallback.effective_to IS NULL OR fallback.effective_to>v_now);
      IF v_fallback_count>1 THEN RAISE EXCEPTION
        'STOCK_LOSS_ACCOUNT_FALLBACK_AMBIGUOUS: %',v_function; END IF;
      IF v_fallback_count=1 AND NOT EXISTS(
        SELECT 1 FROM public.chart_of_accounts account
        JOIN public.account_functions function_state
          ON function_state.function_key=v_function AND function_state.is_active
        WHERE account.company_id=p_company_id AND account.id=v_account
          AND account.is_active AND account.is_postable
          AND account.account_type=ANY(function_state.compatible_account_types)
      ) THEN RAISE EXCEPTION 'STOCK_LOSS_ACCOUNT_FALLBACK_INVALID: %',v_function; END IF;
      IF v_fallback_count=0 THEN
        SELECT count(*),(array_agg(account.id ORDER BY account.id))[1]
        INTO v_system_count,v_account FROM public.chart_of_accounts account
        JOIN public.account_functions function_state
          ON function_state.function_key=v_function AND function_state.is_active
        WHERE account.company_id=p_company_id AND account.system_function_key=v_function
          AND account.is_system_account AND account.is_active AND account.is_postable
          AND account.account_type=ANY(function_state.compatible_account_types);
        IF v_system_count<>1 THEN RAISE EXCEPTION
          'STOCK_LOSS_ACCOUNT_SOURCE_MISSING_OR_AMBIGUOUS: %',v_function; END IF;
      END IF;
      SELECT COALESCE(max(rule.rule_version),0)+1 INTO v_version
      FROM public.transaction_account_rules rule
      WHERE rule.company_id=p_company_id AND rule.transaction_category_id=v_category
        AND rule.account_function_key=v_function;
      INSERT INTO public.transaction_account_rules(company_id,transaction_category_id,
        system_key,account_function_key,account_id,effective_from,rule_version,status,
        approved_by,approved_at,created_by,updated_by)
      VALUES(p_company_id,v_category,'STOCK_LOSS',v_function,v_account,
        '-infinity'::timestamptz,v_version,'ACTIVE',v_actor,v_now,v_actor,v_actor)
      RETURNING id INTO v_rule;
      INSERT INTO public.finance_master_audit(company_id,entity_type,entity_id,
        action,actor_id,after_state)
      SELECT rule.company_id,'RULE',rule.id,'CREATE',v_actor,to_jsonb(rule)
      FROM public.transaction_account_rules rule WHERE rule.id=v_rule;
    END IF;
  END LOOP;

  SELECT count(*),(array_agg(rule_set.id ORDER BY rule_set.rule_set_version DESC,rule_set.id))[1]
  INTO v_set_count,v_rule_set FROM public.posting_rule_sets rule_set
  WHERE rule_set.company_id=p_company_id AND rule_set.transaction_category_id=v_category
    AND rule_set.system_key='STOCK_LOSS' AND rule_set.status='APPROVED'
    AND rule_set.effective_from<=v_now
    AND (rule_set.effective_to IS NULL OR rule_set.effective_to>v_now);
  IF v_set_count>1 THEN RAISE EXCEPTION 'STOCK_LOSS_POSTING_RULE_AMBIGUOUS'; END IF;
  IF v_set_count=0 THEN
    IF EXISTS(SELECT 1 FROM public.posting_rule_sets rule_set
      WHERE rule_set.company_id=p_company_id AND rule_set.transaction_category_id=v_category) THEN
      RAISE EXCEPTION 'STOCK_LOSS_NONAPPROVED_POSTING_RULE_COLLISION';
    END IF;
    SELECT COALESCE(max(rule_set.rule_set_version),0)+1 INTO v_version
    FROM public.posting_rule_sets rule_set
    WHERE rule_set.company_id=p_company_id AND rule_set.transaction_category_id=v_category;
    INSERT INTO public.posting_rule_sets(company_id,transaction_category_id,system_key,
      rule_set_version,effective_from,status,description,created_by,updated_by)
    VALUES(p_company_id,v_category,'STOCK_LOSS',v_version,'-infinity'::timestamptz,
      'DRAFT','Delivery discrepancy LOST/DAMAGED: exact Transit FIFO write-off',
      v_actor,v_actor) RETURNING id INTO v_rule_set;
    INSERT INTO public.posting_rule_lines(company_id,rule_set_id,line_no,
      account_function_key,entry_side,amount_expression_key,condition_key,
      is_required,created_by) VALUES
      (p_company_id,v_rule_set,10,'STOCK_LOSS_EXPENSE','DEBIT',
        'BACKOFFICE_DISCREPANCY_FIFO_COST',NULL,true,v_actor),
      (p_company_id,v_rule_set,20,'INVENTORY_ASSET','CREDIT',
        'BACKOFFICE_DISCREPANCY_FIFO_COST',NULL,true,v_actor);
    INSERT INTO public.posting_rule_set_audit(company_id,rule_set_id,action,
      actor_id,after_state,reason)
    SELECT rule_set.company_id,rule_set.id,'CREATE',v_actor,
      to_jsonb(rule_set)||jsonb_build_object('lines',(SELECT jsonb_agg(
        to_jsonb(line) ORDER BY line.line_no) FROM public.posting_rule_lines line
        WHERE line.company_id=rule_set.company_id AND line.rule_set_id=rule_set.id)),
      'Backoffice discrepancy Stock Loss mapping foundation'
    FROM public.posting_rule_sets rule_set WHERE rule_set.id=v_rule_set;
    UPDATE public.posting_rule_sets SET status='APPROVED',approved_by=v_actor,
      approved_at=v_now,updated_by=v_actor
    WHERE company_id=p_company_id AND id=v_rule_set;
    INSERT INTO public.posting_rule_set_audit(company_id,rule_set_id,action,
      actor_id,after_state,reason)
    SELECT rule_set.company_id,rule_set.id,'APPROVE',v_actor,
      to_jsonb(rule_set)||jsonb_build_object('lines',(SELECT jsonb_agg(
        to_jsonb(line) ORDER BY line.line_no) FROM public.posting_rule_lines line
        WHERE line.company_id=rule_set.company_id AND line.rule_set_id=rule_set.id)),
      'Backoffice discrepancy Stock Loss mapping approval'
    FROM public.posting_rule_sets rule_set WHERE rule_set.id=v_rule_set;
  ELSIF (SELECT count(*) FROM public.posting_rule_lines line
    WHERE line.company_id=p_company_id AND line.rule_set_id=v_rule_set)<>2
    OR NOT EXISTS(SELECT 1 FROM public.posting_rule_lines line
      WHERE line.company_id=p_company_id AND line.rule_set_id=v_rule_set
        AND line.account_function_key='STOCK_LOSS_EXPENSE' AND line.entry_side='DEBIT'
        AND line.amount_expression_key='BACKOFFICE_DISCREPANCY_FIFO_COST'
        AND line.is_required)
    OR NOT EXISTS(SELECT 1 FROM public.posting_rule_lines line
      WHERE line.company_id=p_company_id AND line.rule_set_id=v_rule_set
        AND line.account_function_key='INVENTORY_ASSET' AND line.entry_side='CREDIT'
        AND line.amount_expression_key='BACKOFFICE_DISCREPANCY_FIFO_COST'
        AND line.is_required) THEN
    RAISE EXCEPTION 'STOCK_LOSS_POSTING_RULE_SHAPE_INVALID';
  END IF;
END
$$;

CREATE FUNCTION private.trg_provision_backoffice_discrepancy_stock_loss_finance()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
  IF TG_OP='INSERT' AND NEW.status='ACTIVE' THEN
    PERFORM private.provision_backoffice_discrepancy_stock_loss_finance(NEW.id,auth.uid());
  ELSIF TG_OP='UPDATE' AND NEW.status='ACTIVE'
    AND OLD.status IS DISTINCT FROM NEW.status THEN
    PERFORM private.provision_backoffice_discrepancy_stock_loss_finance(NEW.id,auth.uid());
  END IF;
  RETURN NEW;
END
$$;

CREATE TRIGGER zz_provision_backoffice_discrepancy_stock_loss_finance
AFTER INSERT OR UPDATE OF status ON public.companies
FOR EACH ROW EXECUTE FUNCTION private.trg_provision_backoffice_discrepancy_stock_loss_finance();

DO $provision$
DECLARE v_company record;v_actor uuid;
BEGIN
  SELECT profile.id INTO STRICT v_actor FROM public.profiles profile
  WHERE profile.role::text='super_admin' ORDER BY profile.id LIMIT 1;
  FOR v_company IN SELECT company.id FROM public.companies company
    WHERE company.status='ACTIVE' ORDER BY company.id LOOP
    PERFORM private.provision_backoffice_discrepancy_stock_loss_finance(v_company.id,v_actor);
  END LOOP;
END
$provision$;

CREATE FUNCTION private.post_backoffice_discrepancy_stock_loss_financial_event_core(
  p_company_id uuid,p_event_id uuid,p_expected_event_version bigint,p_actor_id uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
  v_event public.financial_events%rowtype;
  v_effect public.backoffice_sales_discrepancy_stock_effects%rowtype;
  v_case public.backoffice_sales_delivery_discrepancies%rowtype;
  v_line public.backoffice_sales_delivery_discrepancy_lines%rowtype;
  v_order public.backoffice_sales_orders%rowtype;
  v_period public.accounting_periods%rowtype;
  v_journal public.finance_journals%rowtype;
  v_account uuid;v_rule_count bigint;v_rule_version bigint;
  v_alloc_qty numeric(24,6);v_alloc_cost numeric(24,4);v_cost numeric(24,4);
  v_loss_date date;v_accounting_date date;v_journal_type text:='AUTOMATIC';
  v_timezone text;v_now timestamptz:=clock_timestamp();
BEGIN
  IF p_actor_id IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  SELECT event.* INTO v_event FROM public.financial_events event
  WHERE event.company_id=p_company_id AND event.id=p_event_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'FINANCIAL_EVENT_NOT_FOUND'; END IF;
  IF p_expected_event_version IS DISTINCT FROM v_event.event_version THEN
    RAISE EXCEPTION 'EVENT_VERSION_CONFLICT';
  END IF;
  IF v_event.status::text='POSTED' THEN
    SELECT journal.* INTO STRICT v_journal FROM public.finance_journals journal
    WHERE journal.company_id=p_company_id AND journal.financial_event_id=v_event.id
      AND journal.status='POSTED';
    RETURN jsonb_build_object('financialEventId',v_event.id,'journalId',v_journal.id,
      'journalNo',v_journal.journal_no,'status','POSTED','idempotentReplay',true);
  END IF;
  IF v_event.status::text='CANCELED' AND v_event.error_message='NO_FINANCIAL_EFFECT' THEN
    RETURN jsonb_build_object('financialEventId',v_event.id,'journalId',NULL,
      'journalNo',NULL,'status','CANCELED','reason','NO_FINANCIAL_EFFECT',
      'idempotentReplay',true);
  END IF;
  IF v_event.status::text<>'HOLD' OR v_event.event_type::text<>'STOCK_LOSS'
    OR v_event.system_event_key<>'STOCK_LOSS'
    OR v_event.source_table<>'backoffice_sales_discrepancy_stock_effects' THEN
    RAISE EXCEPTION 'UNSUPPORTED_FINANCIAL_EVENT_CONTRACT';
  END IF;

  SELECT effect.* INTO v_effect
  FROM public.backoffice_sales_discrepancy_stock_effects effect
  WHERE effect.company_id=p_company_id AND effect.id=v_event.source_id
    AND effect.financial_event_id=v_event.id AND effect.effect_type='EXPECTED_WRITE_OFF'
  FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'FINANCIAL_EVENT_SOURCE_NOT_FOUND'; END IF;
  SELECT discrepancy.* INTO STRICT v_case
  FROM public.backoffice_sales_delivery_discrepancies discrepancy
  WHERE discrepancy.company_id=p_company_id AND discrepancy.id=v_effect.discrepancy_id
  FOR SHARE;
  SELECT line.* INTO STRICT v_line
  FROM public.backoffice_sales_delivery_discrepancy_lines line
  WHERE line.company_id=p_company_id AND line.id=v_effect.discrepancy_line_id
    AND line.discrepancy_id=v_effect.discrepancy_id FOR SHARE;
  SELECT document.* INTO STRICT v_order FROM public.backoffice_sales_orders document
  WHERE document.company_id=p_company_id AND document.id=v_case.sales_order_id FOR SHARE;

  IF v_line.discrepancy_type<>'SHORT'
    OR v_line.physical_state NOT IN('LOST','DAMAGED')
    OR v_line.warehouse_resolution_status<>'RESOLVED'
    OR jsonb_typeof(v_event.amounts) IS DISTINCT FROM 'object'
    OR NOT (v_event.amounts ?& ARRAY['stockLossDebit','inventoryCredit',
      'discrepancyId','discrepancyLineId'])
    OR jsonb_typeof(v_event.amounts->'stockLossDebit') IS DISTINCT FROM 'number'
    OR jsonb_typeof(v_event.amounts->'inventoryCredit') IS DISTINCT FROM 'number'
    OR v_event.amounts->>'discrepancyId' IS DISTINCT FROM v_case.id::text
    OR v_event.amounts->>'discrepancyLineId' IS DISTINCT FROM v_line.id::text THEN
    RAISE EXCEPTION 'FINANCIAL_EVENT_SOURCE_IDENTITY_MISMATCH';
  END IF;
  BEGIN
    v_cost:=round((v_event.amounts->>'stockLossDebit')::numeric,4);
    IF v_cost<>round((v_event.amounts->>'inventoryCredit')::numeric,4) THEN
      RAISE EXCEPTION 'FINANCIAL_EVENT_AMOUNT_SOURCE_MISMATCH';
    END IF;
  EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN
    RAISE EXCEPTION 'FINANCIAL_EVENT_AMOUNT_SOURCE_MISMATCH';
  END;
  SELECT round(COALESCE(sum(allocation.quantity_base),0),6),
    round(COALESCE(sum(allocation.total_cost),0),4)
  INTO v_alloc_qty,v_alloc_cost
  FROM public.backoffice_sales_discrepancy_fifo_allocations allocation
  WHERE allocation.company_id=p_company_id AND allocation.stock_effect_id=v_effect.id;
  IF v_cost<>round(v_effect.total_cost,4) OR v_cost<>v_alloc_cost
    OR round(v_effect.quantity_base,6)<>v_alloc_qty
    OR NOT EXISTS(SELECT 1 FROM public.stock_movements movement
      WHERE movement.company_id=p_company_id
        AND movement.id=v_effect.source_stock_movement_id
        AND movement.reference_table='backoffice_sales_discrepancy_stock_effects'
        AND movement.reference_id=v_effect.id AND movement.product_id=v_effect.product_id
        AND movement.warehouse_id=v_effect.source_warehouse_id
        AND movement.movement_status='POSTED'
        AND round(movement.qty_change,6)=-round(v_effect.quantity_base,6)) THEN
    RAISE EXCEPTION 'FINANCIAL_EVENT_AMOUNT_SOURCE_MISMATCH';
  END IF;

  IF v_cost=0 THEN
    UPDATE public.financial_events SET status='CANCELED'::public.event_status,
      processed_at=v_now,error_message='NO_FINANCIAL_EFFECT'
    WHERE company_id=p_company_id AND id=v_event.id;
    RETURN jsonb_build_object('financialEventId',v_event.id,'journalId',NULL,
      'journalNo',NULL,'status','CANCELED','reason','NO_FINANCIAL_EFFECT',
      'idempotentReplay',false);
  END IF;
  IF v_cost<0 THEN RAISE EXCEPTION 'FINANCIAL_EVENT_AMOUNT_SOURCE_MISMATCH'; END IF;

  SELECT company.timezone INTO STRICT v_timezone FROM public.companies company
  WHERE company.id=p_company_id;
  v_loss_date:=(v_event.event_date AT TIME ZONE v_timezone)::date;
  SELECT period.* INTO v_period FROM public.accounting_periods period
  WHERE period.company_id=p_company_id
    AND v_loss_date BETWEEN period.start_date AND period.end_date
    AND period.status IN('OPEN','REOPENED')
  ORDER BY period.start_date LIMIT 1 FOR SHARE;
  IF NOT FOUND THEN
    SELECT period.* INTO v_period FROM public.accounting_periods period
    WHERE period.company_id=p_company_id AND period.start_date>v_loss_date
      AND period.status IN('OPEN','REOPENED')
    ORDER BY period.start_date LIMIT 1 FOR SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION 'POSTABLE_ACCOUNTING_PERIOD_NOT_FOUND'; END IF;
    v_journal_type:='PRIOR_PERIOD_ADJUSTMENT';v_accounting_date:=v_period.start_date;
  ELSE
    v_accounting_date:=v_loss_date;
  END IF;
  SELECT count(*),max(rule_set.rule_set_version) INTO v_rule_count,v_rule_version
  FROM public.posting_rule_sets rule_set
  WHERE rule_set.company_id=p_company_id
    AND rule_set.transaction_category_id=v_event.transaction_category_id
    AND rule_set.system_key='STOCK_LOSS' AND rule_set.status='APPROVED'
    AND rule_set.effective_from<=v_event.event_date
    AND (rule_set.effective_to IS NULL OR rule_set.effective_to>v_event.event_date);
  IF v_rule_count<>1 OR v_rule_version IS NULL
    OR (v_event.transaction_rule_version IS NOT NULL
      AND v_event.transaction_rule_version IS DISTINCT FROM v_rule_version) THEN
    RAISE EXCEPTION 'POSTING_RULE_SET_MISSING_OR_AMBIGUOUS';
  END IF;

  INSERT INTO public.finance_journals(company_id,journal_no,journal_type,
    accounting_period_id,accounting_date,original_event_date,source_type,source_id,
    source_version,financial_event_id,idempotency_key,system_event_key,
    transaction_category_id,transaction_rule_version,store_id,warehouse_id,
    currency_code,description,status,created_by)
  VALUES(p_company_id,'BSL-'||replace(v_event.id::text,'-',''),v_journal_type,
    v_period.id,v_accounting_date,v_loss_date,v_event.source_table,v_effect.id,
    v_event.event_version,v_event.id,
    'BACKOFFICE_DISCREPANCY_STOCK_LOSS_EVENT|'||p_company_id||'|'||v_event.id||'|'||v_event.event_version,
    v_event.system_event_key,v_event.transaction_category_id,v_rule_version,
    v_order.store_id,v_effect.source_warehouse_id,v_order.currency_code,
    'Selisih pengiriman '||v_line.physical_state||' - '||v_case.discrepancy_no,
    'DRAFT',p_actor_id)
  RETURNING * INTO v_journal;
  v_account:=private.resolve_financial_event_account(v_event,'STOCK_LOSS_EXPENSE');
  INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,account_id,
    debit,credit,store_id,warehouse_id,customer_id,description)
  VALUES(p_company_id,v_journal.id,10,v_account,v_cost,0,v_order.store_id,
    v_effect.source_warehouse_id,v_order.customer_id,
    'STOCK_LOSS_EXPENSE - '||v_line.physical_state);
  v_account:=private.resolve_financial_event_account(v_event,'INVENTORY_ASSET');
  INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,account_id,
    debit,credit,store_id,warehouse_id,customer_id,description)
  VALUES(p_company_id,v_journal.id,20,v_account,0,v_cost,v_order.store_id,
    v_effect.source_warehouse_id,v_order.customer_id,
    'INVENTORY_ASSET - '||v_line.physical_state);
  UPDATE public.finance_journals SET status='POSTED',posted_by=p_actor_id,posted_at=v_now
  WHERE company_id=p_company_id AND id=v_journal.id RETURNING * INTO v_journal;
  IF round(v_journal.total_debit,4)<>v_cost OR round(v_journal.total_credit,4)<>v_cost THEN
    RAISE EXCEPTION 'JOURNAL_UNBALANCED';
  END IF;
  UPDATE public.financial_events SET status='POSTED'::public.event_status,
    processed_at=v_now,error_message=NULL,transaction_rule_version=v_rule_version
  WHERE company_id=p_company_id AND id=v_event.id;
  RETURN jsonb_build_object('financialEventId',v_event.id,'journalId',v_journal.id,
    'journalNo',v_journal.journal_no,'status','POSTED','journalType',v_journal.journal_type,
    'accountingDate',v_journal.accounting_date,'originalEventDate',v_journal.original_event_date,
    'physicalState',v_line.physical_state,'totalDebit',v_journal.total_debit,
    'totalCredit',v_journal.total_credit,'idempotentReplay',false);
END
$$;

ALTER FUNCTION private.post_financial_event_core(uuid,uuid,bigint,uuid)
  RENAME TO post_financial_event_core_pre_backoffice_discrepancy_stock_loss;
CREATE FUNCTION private.post_financial_event_core(
  p_company_id uuid,p_event_id uuid,p_expected_event_version bigint,p_actor_id uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_key text;v_source text;
BEGIN
  SELECT event.system_event_key,event.source_table INTO v_key,v_source
  FROM public.financial_events event
  WHERE event.company_id=p_company_id AND event.id=p_event_id;
  IF v_key='STOCK_LOSS'
    AND v_source='backoffice_sales_discrepancy_stock_effects' THEN
    RETURN private.post_backoffice_discrepancy_stock_loss_financial_event_core(
      p_company_id,p_event_id,p_expected_event_version,p_actor_id);
  END IF;
  RETURN private.post_financial_event_core_pre_backoffice_discrepancy_stock_loss(
    p_company_id,p_event_id,p_expected_event_version,p_actor_id);
END
$$;

ALTER FUNCTION private.f4b_financial_event_supported(public.financial_events)
  RENAME TO f4b_financial_event_supported_pre_backoffice_discrepancy_stock_loss;
CREATE FUNCTION private.f4b_financial_event_supported(
  p_event public.financial_events
) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
  SELECT CASE WHEN p_event.status::text='HOLD'
    AND p_event.system_event_key='STOCK_LOSS'
    AND p_event.source_table='backoffice_sales_discrepancy_stock_effects' THEN true
    ELSE private.f4b_financial_event_supported_pre_backoffice_discrepancy_stock_loss(p_event) END
$$;

REVOKE ALL ON FUNCTION
  private.provision_backoffice_discrepancy_stock_loss_finance(uuid,uuid),
  private.trg_provision_backoffice_discrepancy_stock_loss_finance(),
  private.post_backoffice_discrepancy_stock_loss_financial_event_core(uuid,uuid,bigint,uuid),
  private.post_financial_event_core_pre_backoffice_discrepancy_stock_loss(uuid,uuid,bigint,uuid),
  private.post_financial_event_core(uuid,uuid,bigint,uuid),
  private.f4b_financial_event_supported_pre_backoffice_discrepancy_stock_loss(public.financial_events),
  private.f4b_financial_event_supported(public.financial_events)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.provision_backoffice_discrepancy_stock_loss_finance(uuid,uuid),
  private.trg_provision_backoffice_discrepancy_stock_loss_finance(),
  private.post_backoffice_discrepancy_stock_loss_financial_event_core(uuid,uuid,bigint,uuid),
  private.post_financial_event_core_pre_backoffice_discrepancy_stock_loss(uuid,uuid,bigint,uuid),
  private.post_financial_event_core(uuid,uuid,bigint,uuid),
  private.f4b_financial_event_supported_pre_backoffice_discrepancy_stock_loss(public.financial_events),
  private.f4b_financial_event_supported(public.financial_events)
TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260912135000','backoffice_sales_discrepancy_stock_loss_finance_posting',
  'Step 5/6.2 provisions missing canonical Stock Loss account/rule mappings and routes Backoffice delivery LOST/DAMAGED Stock Loss HOLD through the Finance queue to balanced Dr Stock Loss Expense / Cr Transit Inventory without repeating Stock or FIFO mutation');
NOTIFY pgrst,'reload schema';
COMMIT;
