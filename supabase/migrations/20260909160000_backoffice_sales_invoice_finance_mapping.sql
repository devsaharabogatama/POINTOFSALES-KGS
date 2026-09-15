-- Finance mapping foundation for Backoffice Regular and Down Payment Invoice.
-- No Invoice posting, Financial Event, Journal, Stock, FIFO, Payment, or POS effect.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260909159000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Invoice tax breakdown required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260909160000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260909160000';
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
    JOIN auth.users auth_user ON auth_user.id=profile.id
    WHERE profile.role::text='super_admin') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: linked Super Admin profile required';
  END IF;
  IF EXISTS(SELECT 1 FROM public.system_events event
    WHERE event.system_key IN('BACKOFFICE_SALES_INVOICE','BACKOFFICE_SALES_DOWN_PAYMENT')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Invoice system event collision';
  END IF;
  IF EXISTS(SELECT 1 FROM public.transaction_categories category
    WHERE upper(regexp_replace(btrim(category.category_code),'\s+',' ','g'))
      IN('BO-SALE-INVOICE','BO-SALE-DOWN-PAYMENT')
      OR lower(regexp_replace(btrim(category.category_name),'\s+',' ','g'))
      IN('backoffice invoice penjualan','backoffice uang muka penjualan')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Invoice category identity collision';
  END IF;
  IF EXISTS(SELECT 1 FROM public.backoffice_sales_invoices
    WHERE status IN('POSTED','REVERSED') OR invoice_no IS NOT NULL
      OR financial_event_id IS NOT NULL OR posted_at IS NOT NULL
      OR posted_by IS NOT NULL) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: unexpected posted Invoice state';
  END IF;
  IF EXISTS(SELECT 1
    FROM public.backoffice_sales_invoice_tax_breakdowns breakdown
    JOIN public.tax_rule_versions version ON version.company_id=breakdown.company_id
      AND version.tax_rule_id=breakdown.tax_rule_id
      AND version.rule_version=breakdown.tax_rule_version
    JOIN public.chart_of_accounts account ON account.company_id=breakdown.company_id
      AND account.id=breakdown.tax_account_id
    LEFT JOIN public.account_functions function_state
      ON function_state.function_key=version.account_function_key
    WHERE version.account_id<>breakdown.tax_account_id
      OR version.account_function_key<>'OUTPUT_TAX'
      OR function_state.function_key IS NULL OR NOT function_state.is_active
      OR NOT account.is_active OR NOT account.is_postable
      OR NOT account.account_type=ANY(function_state.compatible_account_types)) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Invoice tax account snapshot invalid';
  END IF;
END
$guard$;

INSERT INTO public.system_events(system_key,event_group,event_name,
  required_account_functions,conditional_account_functions,optional_account_functions)
VALUES
  ('BACKOFFICE_SALES_INVOICE','SALES','Backoffice Invoice Penjualan',
    ARRAY['CUSTOMER_RECEIVABLE','SALES_REVENUE']::text[],
    ARRAY['OUTPUT_TAX','CUSTOMER_ADVANCE_LIABILITY']::text[],ARRAY[]::text[]),
  ('BACKOFFICE_SALES_DOWN_PAYMENT','SALES','Backoffice Uang Muka Penjualan',
    ARRAY['CUSTOMER_RECEIVABLE','CUSTOMER_ADVANCE_LIABILITY']::text[],
    ARRAY['OUTPUT_TAX']::text[],ARRAY[]::text[]);

CREATE FUNCTION private.resolve_backoffice_invoice_reusable_account(
  p_company_id uuid,p_function_key text
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_source text;v_count bigint;v_account uuid;
BEGIN
  FOREACH v_source IN ARRAY ARRAY['SALE_POSTED','SALE_DISPATCHED']::text[] LOOP
    SELECT count(DISTINCT rule.account_id),
      (array_agg(DISTINCT rule.account_id ORDER BY rule.account_id))[1]
    INTO v_count,v_account
    FROM public.transaction_account_rules rule
    JOIN public.transaction_categories category ON category.company_id=rule.company_id
      AND category.id=rule.transaction_category_id AND category.is_active
    JOIN public.chart_of_accounts account ON account.company_id=rule.company_id
      AND account.id=rule.account_id
    JOIN public.account_functions function_state
      ON function_state.function_key=p_function_key AND function_state.is_active
    WHERE rule.company_id=p_company_id AND rule.system_key=v_source
      AND category.system_key=v_source AND rule.account_function_key=p_function_key
      AND rule.status='ACTIVE' AND rule.effective_from<=clock_timestamp()
      AND (rule.effective_to IS NULL OR rule.effective_to>clock_timestamp())
      AND account.is_active AND account.is_postable
      AND account.account_type=ANY(function_state.compatible_account_types);
    IF v_count=1 THEN RETURN v_account; END IF;
    IF v_count>1 THEN RAISE EXCEPTION
      'MIGRATION_PRECONDITION_FAILED: ambiguous source rule %.% %',
      p_company_id,v_source,p_function_key; END IF;
  END LOOP;

  SELECT count(DISTINCT fallback.account_id),
    (array_agg(DISTINCT fallback.account_id ORDER BY fallback.account_id))[1]
  INTO v_count,v_account
  FROM public.company_account_function_fallbacks fallback
  JOIN public.chart_of_accounts account ON account.company_id=fallback.company_id
    AND account.id=fallback.account_id
  JOIN public.account_functions function_state
    ON function_state.function_key=p_function_key AND function_state.is_active
  WHERE fallback.company_id=p_company_id
    AND fallback.account_function_key=p_function_key AND fallback.status='ACTIVE'
    AND fallback.effective_from<=clock_timestamp()
    AND (fallback.effective_to IS NULL OR fallback.effective_to>clock_timestamp())
    AND account.is_active AND account.is_postable
    AND account.account_type=ANY(function_state.compatible_account_types);
  IF v_count=1 THEN RETURN v_account; END IF;
  IF v_count>1 THEN RAISE EXCEPTION
    'MIGRATION_PRECONDITION_FAILED: ambiguous fallback %.%',p_company_id,p_function_key; END IF;

  SELECT count(*),(array_agg(account.id ORDER BY account.id))[1] INTO v_count,v_account
  FROM public.chart_of_accounts account
  JOIN public.account_functions function_state
    ON function_state.function_key=p_function_key AND function_state.is_active
  WHERE account.company_id=p_company_id AND account.system_function_key=p_function_key
    AND account.is_system_account AND account.is_active AND account.is_postable
    AND account.account_type=ANY(function_state.compatible_account_types);
  IF v_count=1 THEN RETURN v_account; END IF;
  IF v_count>1 THEN RAISE EXCEPTION
    'MIGRATION_PRECONDITION_FAILED: ambiguous system account %.%',p_company_id,p_function_key; END IF;
  RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: mapping source missing %.%',
    p_company_id,p_function_key;
END
$$;

DO $provision$
DECLARE
  v_actor uuid;v_company record;v_event text;v_category uuid;v_function text;
  v_account uuid;v_rule uuid;v_set uuid;v_now timestamptz:=clock_timestamp();
  v_effective_from timestamptz:='-infinity'::timestamptz;
  v_functions text[];
BEGIN
  SELECT profile.id INTO v_actor FROM public.profiles profile
  JOIN auth.users auth_user ON auth_user.id=profile.id
  WHERE profile.role::text='super_admin' ORDER BY profile.id LIMIT 1;
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: linked Super Admin profile required';
  END IF;
  FOR v_company IN SELECT company.id FROM public.companies company
    WHERE company.status='ACTIVE' ORDER BY company.id
  LOOP
    FOREACH v_event IN ARRAY ARRAY[
      'BACKOFFICE_SALES_INVOICE','BACKOFFICE_SALES_DOWN_PAYMENT']::text[]
    LOOP
      IF v_event='BACKOFFICE_SALES_INVOICE' THEN
        v_functions:=ARRAY['CUSTOMER_RECEIVABLE','SALES_REVENUE',
          'OUTPUT_TAX','CUSTOMER_ADVANCE_LIABILITY']::text[];
        INSERT INTO public.transaction_categories(company_id,category_code,category_name,
          system_key,description,is_active,created_by,updated_by)
        VALUES(v_company.id,'BO-SALE-INVOICE','Backoffice Invoice Penjualan',v_event,
          'Pengakuan piutang, pendapatan, pajak keluaran, dan aplikasi uang muka',
          true,v_actor,v_actor) RETURNING id INTO v_category;
      ELSE
        v_functions:=ARRAY['CUSTOMER_RECEIVABLE','CUSTOMER_ADVANCE_LIABILITY',
          'OUTPUT_TAX']::text[];
        INSERT INTO public.transaction_categories(company_id,category_code,category_name,
          system_key,description,is_active,created_by,updated_by)
        VALUES(v_company.id,'BO-SALE-DOWN-PAYMENT','Backoffice Uang Muka Penjualan',v_event,
          'Pengakuan piutang uang muka, liabilitas uang muka Customer, dan pajak proporsional',
          true,v_actor,v_actor) RETURNING id INTO v_category;
      END IF;
      INSERT INTO public.finance_master_audit(company_id,entity_type,entity_id,
        action,actor_id,after_state)
      SELECT category.company_id,'CATEGORY',category.id,'CREATE',v_actor,to_jsonb(category)
      FROM public.transaction_categories category WHERE category.id=v_category;

      FOREACH v_function IN ARRAY v_functions LOOP
        v_account:=private.resolve_backoffice_invoice_reusable_account(
          v_company.id,v_function);
        INSERT INTO public.transaction_account_rules(company_id,transaction_category_id,
          system_key,account_function_key,account_id,effective_from,rule_version,status,
          approved_by,approved_at,created_by,updated_by)
        VALUES(v_company.id,v_category,v_event,v_function,v_account,v_effective_from,1,'ACTIVE',
          v_actor,v_now,v_actor,v_actor) RETURNING id INTO v_rule;
        INSERT INTO public.finance_master_audit(company_id,entity_type,entity_id,
          action,actor_id,after_state)
        SELECT rule.company_id,'RULE',rule.id,'CREATE',v_actor,to_jsonb(rule)
        FROM public.transaction_account_rules rule WHERE rule.id=v_rule;
      END LOOP;

      INSERT INTO public.posting_rule_sets(company_id,transaction_category_id,
        system_key,rule_set_version,effective_from,status,description,
        approved_by,approved_at,created_by,updated_by)
      VALUES(v_company.id,v_category,v_event,1,v_effective_from,'DRAFT',
        CASE v_event WHEN 'BACKOFFICE_SALES_INVOICE' THEN
          'Regular Invoice: AR plus applied DP basis equals Revenue plus remaining tax'
        ELSE 'DP Invoice: AR equals Customer Advance basis plus proportional tax' END,
        NULL,NULL,v_actor,v_actor) RETURNING id INTO v_set;
      IF v_event='BACKOFFICE_SALES_INVOICE' THEN
        INSERT INTO public.posting_rule_lines(company_id,rule_set_id,line_no,
          account_function_key,entry_side,amount_expression_key,condition_key,
          is_required,created_by) VALUES
        (v_company.id,v_set,10,'CUSTOMER_RECEIVABLE','DEBIT',
          'BACKOFFICE_INVOICE_RECEIVABLE',NULL,true,v_actor),
        (v_company.id,v_set,20,'CUSTOMER_ADVANCE_LIABILITY','DEBIT',
          'BACKOFFICE_INVOICE_DP_BASIS_APPLIED','BACKOFFICE_INVOICE_HAS_DP',false,v_actor),
        (v_company.id,v_set,30,'SALES_REVENUE','CREDIT',
          'BACKOFFICE_INVOICE_REVENUE_DPP',NULL,true,v_actor),
        (v_company.id,v_set,40,'OUTPUT_TAX','CREDIT',
          'BACKOFFICE_INVOICE_REMAINING_OUTPUT_TAX','BACKOFFICE_INVOICE_HAS_TAX',false,v_actor);
      ELSE
        INSERT INTO public.posting_rule_lines(company_id,rule_set_id,line_no,
          account_function_key,entry_side,amount_expression_key,condition_key,
          is_required,created_by) VALUES
        (v_company.id,v_set,10,'CUSTOMER_RECEIVABLE','DEBIT',
          'BACKOFFICE_DP_RECEIVABLE',NULL,true,v_actor),
        (v_company.id,v_set,20,'CUSTOMER_ADVANCE_LIABILITY','CREDIT',
          'BACKOFFICE_DP_BASIS',NULL,true,v_actor),
        (v_company.id,v_set,30,'OUTPUT_TAX','CREDIT',
          'BACKOFFICE_DP_OUTPUT_TAX','BACKOFFICE_DP_HAS_TAX',false,v_actor);
      END IF;
      INSERT INTO public.posting_rule_set_audit(company_id,rule_set_id,action,
        actor_id,after_state,reason)
      SELECT rule_set.company_id,rule_set.id,'CREATE',v_actor,
        to_jsonb(rule_set)||jsonb_build_object('lines',(SELECT jsonb_agg(to_jsonb(line)
          ORDER BY line.line_no) FROM public.posting_rule_lines line
          WHERE line.company_id=rule_set.company_id AND line.rule_set_id=rule_set.id)),
        'Backoffice Invoice deterministic Finance mapping foundation'
      FROM public.posting_rule_sets rule_set WHERE rule_set.id=v_set;
      UPDATE public.posting_rule_sets SET status='APPROVED',approved_by=v_actor,
        approved_at=v_now,updated_by=v_actor WHERE company_id=v_company.id AND id=v_set;
      INSERT INTO public.posting_rule_set_audit(company_id,rule_set_id,action,
        actor_id,after_state,reason)
      SELECT rule_set.company_id,rule_set.id,'APPROVE',v_actor,
        to_jsonb(rule_set)||jsonb_build_object('lines',(SELECT jsonb_agg(to_jsonb(line)
          ORDER BY line.line_no) FROM public.posting_rule_lines line
          WHERE line.company_id=rule_set.company_id AND line.rule_set_id=rule_set.id)),
        'Backoffice Invoice Finance mapping approval'
      FROM public.posting_rule_sets rule_set WHERE rule_set.id=v_set;
    END LOOP;
  END LOOP;
END
$provision$;

DROP FUNCTION private.resolve_backoffice_invoice_reusable_account(uuid,text);

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260909160000','backoffice_sales_invoice_finance_mapping',
  'Regular and DP Invoice categories, canonical accounts and approved posting definitions; tax runtime must use immutable per-group account snapshots; zero Event/Journal effect');

NOTIFY pgrst,'reload schema';
COMMIT;
