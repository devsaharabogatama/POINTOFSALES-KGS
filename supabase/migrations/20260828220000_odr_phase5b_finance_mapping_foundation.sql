-- ODR-5B: deterministic Finance mapping foundation for Dispatch and verified Payment.
-- Provisions master configuration only. No Financial Event or Journal is created.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260828210000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: ODR-5A required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260828220000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260828220000';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
    WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
  IF EXISTS(SELECT 1 FROM public.sales_dispatch_financial_effects)
    OR EXISTS(SELECT 1 FROM public.sales_payment_verification_requests) THEN
    RAISE EXCEPTION
      'MIGRATION_PRECONDITION_FAILED: ODR Finance source must remain empty';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.profiles profile
    WHERE profile.role::TEXT='super_admin') THEN
    RAISE EXCEPTION
      'MIGRATION_PRECONDITION_FAILED: linked Super Admin profile required';
  END IF;
  IF EXISTS(
    SELECT 1 FROM public.companies company
    JOIN public.chart_of_accounts account ON account.company_id=company.id
    WHERE company.status='ACTIVE'
      AND (upper(regexp_replace(btrim(account.account_code),'\s+',' ','g'))='2190'
        OR lower(regexp_replace(btrim(account.account_name),'\s+',' ','g'))=
          'uang muka customer')
      AND NOT (account.system_function_key='CUSTOMER_ADVANCE_LIABILITY'
        AND account.account_type='LIABILITY' AND account.normal_balance='CREDIT'
        AND account.is_system_account AND account.is_postable
        AND account.allow_reconciliation)
  ) THEN
    RAISE EXCEPTION
      'MIGRATION_PRECONDITION_FAILED: Customer Advance COA identity collision';
  END IF;
  IF EXISTS(
    SELECT 1 FROM public.companies company
    JOIN public.transaction_categories category ON category.company_id=company.id
    WHERE company.status='ACTIVE'
      AND (upper(regexp_replace(btrim(category.category_code),'\s+',' ','g')) IN
          ('ODR-SALE-DISPATCHED','ODR-SALE-PAYMENT-VERIFIED')
        OR lower(regexp_replace(btrim(category.category_name),'\s+',' ','g')) IN
          ('odr dispatch penjualan','odr verifikasi pembayaran penjualan'))
  ) THEN
    RAISE EXCEPTION
      'MIGRATION_PRECONDITION_FAILED: ODR Transaction Category identity collision';
  END IF;
END
$guard$;

-- A verified pre-dispatch receipt is held as Customer Advance. Dispatch must
-- therefore be allowed to debit that liability when commercial value becomes
-- recognizable. ODR-5A had not yet opened this conditional function.
UPDATE public.system_events
SET conditional_account_functions=ARRAY['CUSTOMER_RECEIVABLE','PAYMENT_CLEARING',
  'CUSTOMER_ADVANCE_LIABILITY','OUTPUT_TAX','DELIVERY_FEE_REVENUE',
  'PAYMENT_SURCHARGE_INCOME','ROUNDING_GAIN','ROUNDING_LOSS']::TEXT[],
  updated_at=clock_timestamp()
WHERE system_key='SALE_DISPATCHED';

DO $event_contract$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM public.system_events system_event
    WHERE system_event.system_key='SALE_DISPATCHED' AND system_event.is_active
      AND system_event.conditional_account_functions=ARRAY[
        'CUSTOMER_RECEIVABLE','PAYMENT_CLEARING','CUSTOMER_ADVANCE_LIABILITY',
        'OUTPUT_TAX','DELIVERY_FEE_REVENUE','PAYMENT_SURCHARGE_INCOME',
        'ROUNDING_GAIN','ROUNDING_LOSS']::TEXT[]) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: ODR Dispatch event contract';
  END IF;
END
$event_contract$;

-- Migration-only resolver. Reuse one proven economic account in this order:
-- exact source-event rule, Company fallback, then a sole system-owned account.
CREATE FUNCTION private.odr5b_resolve_reusable_account(
  p_company_id UUID,p_source_system_key TEXT,p_function_key TEXT
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE
  v_count BIGINT;
  v_account UUID;
  v_lookup_function TEXT:=p_function_key;
BEGIN
  SELECT count(DISTINCT rule.account_id),
      (array_agg(DISTINCT rule.account_id ORDER BY rule.account_id))[1]
    INTO v_count,v_account
  FROM public.transaction_account_rules rule
  JOIN public.transaction_categories category
    ON category.company_id=rule.company_id
   AND category.id=rule.transaction_category_id
  JOIN public.chart_of_accounts account
    ON account.company_id=rule.company_id AND account.id=rule.account_id
  WHERE rule.company_id=p_company_id
    AND rule.system_key=p_source_system_key
    AND category.system_key=p_source_system_key
    AND rule.account_function_key=v_lookup_function
    AND rule.status='ACTIVE' AND category.is_active
    AND rule.effective_from<=clock_timestamp()
    AND (rule.effective_to IS NULL OR rule.effective_to>clock_timestamp())
    AND account.is_active AND account.is_postable;
  IF v_count=1 THEN RETURN v_account; END IF;
  IF v_count>1 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: ambiguous source rule %.% %',
      p_company_id,p_source_system_key,v_lookup_function;
  END IF;

  SELECT count(DISTINCT fallback.account_id),
      (array_agg(DISTINCT fallback.account_id ORDER BY fallback.account_id))[1]
    INTO v_count,v_account
  FROM public.company_account_function_fallbacks fallback
  JOIN public.chart_of_accounts account
    ON account.company_id=fallback.company_id AND account.id=fallback.account_id
  WHERE fallback.company_id=p_company_id
    AND fallback.account_function_key=v_lookup_function
    AND fallback.status='ACTIVE'
    AND fallback.effective_from<=clock_timestamp()
    AND (fallback.effective_to IS NULL OR fallback.effective_to>clock_timestamp())
    AND account.is_active AND account.is_postable;
  IF v_count=1 THEN RETURN v_account; END IF;
  IF v_count>1 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: ambiguous fallback %.% ',
      p_company_id,v_lookup_function;
  END IF;

  SELECT count(*),(array_agg(account.id ORDER BY account.id))[1]
    INTO v_count,v_account
  FROM public.chart_of_accounts account
  WHERE account.company_id=p_company_id
    AND account.system_function_key=v_lookup_function
    AND account.is_system_account AND account.is_active AND account.is_postable;
  IF v_count=1 THEN RETURN v_account; END IF;
  IF v_count>1 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: ambiguous system account %.%',
      p_company_id,v_lookup_function;
  END IF;

  -- Existing canonical Sale/Return mapping treats BANK_RECEIPT as BANK.
  IF v_lookup_function='BANK_RECEIPT' THEN
    RETURN private.odr5b_resolve_reusable_account(
      p_company_id,p_source_system_key,'BANK');
  END IF;
  RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: mapping source missing %.% %',
    p_company_id,p_source_system_key,v_lookup_function;
END;
$$;

DO $provision$
DECLARE
  v_actor UUID;
  v_now TIMESTAMPTZ:=clock_timestamp();
  v_company RECORD;
  v_category RECORD;
  v_category_id UUID;
  v_requirement RECORD;
  v_account UUID;
  v_advance UUID;
  v_rule UUID;
  v_set UUID;
BEGIN
  SELECT profile.id INTO v_actor FROM public.profiles profile
  WHERE profile.role::TEXT='super_admin' ORDER BY profile.id LIMIT 1;

  FOR v_company IN SELECT company.id FROM public.companies company
    WHERE company.status='ACTIVE' ORDER BY company.id
  LOOP
    SELECT account.id INTO v_advance FROM public.chart_of_accounts account
    WHERE account.company_id=v_company.id
      AND account.system_function_key='CUSTOMER_ADVANCE_LIABILITY'
      AND account.is_system_account AND account.is_active AND account.is_postable;
    IF v_advance IS NULL THEN
      INSERT INTO public.chart_of_accounts(company_id,account_code,account_name,
        account_type,normal_balance,system_function_key,is_system_account,
        is_postable,allow_manual_posting,allow_reconciliation,is_active,
        created_by,updated_by)
      VALUES(v_company.id,'2190','Uang Muka Customer','LIABILITY','CREDIT',
        'CUSTOMER_ADVANCE_LIABILITY',TRUE,TRUE,FALSE,TRUE,TRUE,v_actor,v_actor)
      RETURNING id INTO v_advance;
      INSERT INTO public.finance_master_audit(company_id,entity_type,entity_id,
        action,actor_id,after_state)
      SELECT account.company_id,'ACCOUNT',account.id,'CREATE',v_actor,to_jsonb(account)
      FROM public.chart_of_accounts account WHERE account.id=v_advance;
    END IF;

    FOR v_category IN SELECT * FROM (VALUES
      ('SALE_DISPATCHED'::TEXT,'ODR-SALE-DISPATCHED'::TEXT,
        'ODR Dispatch Penjualan'::TEXT,
        'Pendapatan, HPP, persediaan dan piutang saat Dispatch ODR'::TEXT),
      ('SALE_PAYMENT_VERIFIED','ODR-SALE-PAYMENT-VERIFIED',
        'ODR Verifikasi Pembayaran Penjualan',
        'Settlement pembayaran ODR yang telah diverifikasi Finance')
    ) category(system_key,category_code,category_name,description)
    LOOP
      INSERT INTO public.transaction_categories(company_id,category_code,
        category_name,system_key,description,is_active,created_by,updated_by)
      VALUES(v_company.id,v_category.category_code,v_category.category_name,
        v_category.system_key,v_category.description,TRUE,v_actor,v_actor)
      RETURNING id INTO v_category_id;
      INSERT INTO public.finance_master_audit(company_id,entity_type,entity_id,
        action,actor_id,after_state)
      SELECT category.company_id,'CATEGORY',category.id,'CREATE',v_actor,
        to_jsonb(category) FROM public.transaction_categories category
      WHERE category.id=v_category_id;

      FOR v_requirement IN
        SELECT * FROM (VALUES
          ('SALE_DISPATCHED'::TEXT,'SALE_POSTED'::TEXT,'SALES_REVENUE'::TEXT),
          ('SALE_DISPATCHED','SALE_POSTED','OUTPUT_TAX'),
          ('SALE_DISPATCHED','SALE_POSTED','DELIVERY_FEE_REVENUE'),
          ('SALE_DISPATCHED','SALE_POSTED','PAYMENT_SURCHARGE_INCOME'),
          ('SALE_DISPATCHED','SALE_POSTED','ROUNDING_GAIN'),
          ('SALE_DISPATCHED','SALE_POSTED','ROUNDING_LOSS'),
          ('SALE_DISPATCHED','SALE_POSTED','COGS'),
          ('SALE_DISPATCHED','SALE_POSTED','INVENTORY_ASSET'),
          ('SALE_DISPATCHED','SALE_POSTED','CUSTOMER_RECEIVABLE'),
          ('SALE_DISPATCHED','SALE_POSTED','PAYMENT_CLEARING'),
          ('SALE_DISPATCHED','SALE_POSTED','CUSTOMER_ADVANCE_LIABILITY'),
          ('SALE_PAYMENT_VERIFIED','SALE_PAYMENT','CASH_DRAWER'),
          ('SALE_PAYMENT_VERIFIED','SALE_PAYMENT','BANK'),
          ('SALE_PAYMENT_VERIFIED','SALE_PAYMENT','BANK_RECEIPT'),
          ('SALE_PAYMENT_VERIFIED','SALE_PAYMENT','PAYMENT_CLEARING'),
          ('SALE_PAYMENT_VERIFIED','SALE_PAYMENT','CUSTOMER_RECEIVABLE'),
          ('SALE_PAYMENT_VERIFIED','SALE_PAYMENT','CUSTOMER_ADVANCE_LIABILITY')
        ) requirement(target_system_key,source_system_key,function_key)
        WHERE requirement.target_system_key=v_category.system_key
      LOOP
        IF v_requirement.function_key='CUSTOMER_ADVANCE_LIABILITY' THEN
          v_account:=v_advance;
        ELSE
          v_account:=private.odr5b_resolve_reusable_account(v_company.id,
            v_requirement.source_system_key,v_requirement.function_key);
        END IF;
        INSERT INTO public.transaction_account_rules(company_id,
          transaction_category_id,system_key,account_function_key,account_id,
          effective_from,rule_version,status,approved_by,approved_at,
          created_by,updated_by)
        VALUES(v_company.id,v_category_id,v_category.system_key,
          v_requirement.function_key,v_account,v_now,1,'ACTIVE',v_actor,v_now,
          v_actor,v_actor) RETURNING id INTO v_rule;
        INSERT INTO public.finance_master_audit(company_id,entity_type,entity_id,
          action,actor_id,after_state)
        SELECT rule.company_id,'RULE',rule.id,'CREATE',v_actor,to_jsonb(rule)
        FROM public.transaction_account_rules rule WHERE rule.id=v_rule;
      END LOOP;

      INSERT INTO public.posting_rule_sets(company_id,transaction_category_id,
        system_key,rule_set_version,effective_from,status,description,
        approved_by,approved_at,created_by,updated_by)
      VALUES(v_company.id,v_category_id,v_category.system_key,1,v_now,'DRAFT',
        CASE v_category.system_key
          WHEN 'SALE_DISPATCHED' THEN
            'ODR Dispatch: proportional commercial value and actual FIFO cost'
          ELSE 'ODR verified payment: Cash/Bank/Clearing to AR or Customer Advance'
        END,NULL,NULL,v_actor,v_actor)
      RETURNING id INTO v_set;

      IF v_category.system_key='SALE_DISPATCHED' THEN
        INSERT INTO public.posting_rule_lines(company_id,rule_set_id,line_no,
          account_function_key,entry_side,amount_expression_key,condition_key,
          is_required,created_by) VALUES
        (v_company.id,v_set,10,'CUSTOMER_RECEIVABLE','DEBIT',
          'ODR_DISPATCH_RECEIVABLE','AMOUNT_POSITIVE',FALSE,v_actor),
        (v_company.id,v_set,20,'PAYMENT_CLEARING','DEBIT',
          'ODR_DISPATCH_CLEARING','AMOUNT_POSITIVE',FALSE,v_actor),
        (v_company.id,v_set,30,'CUSTOMER_ADVANCE_LIABILITY','DEBIT',
          'ODR_DISPATCH_ADVANCE_APPLIED','AMOUNT_POSITIVE',FALSE,v_actor),
        (v_company.id,v_set,40,'SALES_REVENUE','CREDIT',
          'ODR_DISPATCH_NET_SALES',NULL,TRUE,v_actor),
        (v_company.id,v_set,50,'OUTPUT_TAX','CREDIT',
          'ODR_DISPATCH_OUTPUT_TAX','AMOUNT_POSITIVE',FALSE,v_actor),
        (v_company.id,v_set,60,'DELIVERY_FEE_REVENUE','CREDIT',
          'ODR_DISPATCH_DELIVERY_FEE','AMOUNT_POSITIVE',FALSE,v_actor),
        (v_company.id,v_set,70,'PAYMENT_SURCHARGE_INCOME','CREDIT',
          'ODR_DISPATCH_SURCHARGE','AMOUNT_POSITIVE',FALSE,v_actor),
        (v_company.id,v_set,80,'ROUNDING_GAIN','CREDIT',
          'ODR_DISPATCH_ROUNDING_GAIN','AMOUNT_POSITIVE',FALSE,v_actor),
        (v_company.id,v_set,90,'ROUNDING_LOSS','DEBIT',
          'ODR_DISPATCH_ROUNDING_LOSS','AMOUNT_POSITIVE',FALSE,v_actor),
        (v_company.id,v_set,100,'COGS','DEBIT',
          'ODR_DISPATCH_FIFO_COST',NULL,TRUE,v_actor),
        (v_company.id,v_set,110,'INVENTORY_ASSET','CREDIT',
          'ODR_DISPATCH_FIFO_COST',NULL,TRUE,v_actor);
      ELSE
        INSERT INTO public.posting_rule_lines(company_id,rule_set_id,line_no,
          account_function_key,entry_side,amount_expression_key,condition_key,
          is_required,created_by) VALUES
        (v_company.id,v_set,10,'CASH_DRAWER','DEBIT',
          'ODR_PAYMENT_VERIFIED_CASH','AMOUNT_POSITIVE',FALSE,v_actor),
        (v_company.id,v_set,20,'BANK','DEBIT',
          'ODR_PAYMENT_VERIFIED_BANK','AMOUNT_POSITIVE',FALSE,v_actor),
        (v_company.id,v_set,30,'BANK_RECEIPT','DEBIT',
          'ODR_PAYMENT_VERIFIED_BANK_RECEIPT','AMOUNT_POSITIVE',FALSE,v_actor),
        (v_company.id,v_set,40,'PAYMENT_CLEARING','DEBIT',
          'ODR_PAYMENT_VERIFIED_CLEARING','AMOUNT_POSITIVE',FALSE,v_actor),
        (v_company.id,v_set,50,'CUSTOMER_RECEIVABLE','CREDIT',
          'ODR_PAYMENT_VERIFIED_RECEIVABLE','AMOUNT_POSITIVE',FALSE,v_actor),
        (v_company.id,v_set,60,'CUSTOMER_ADVANCE_LIABILITY','CREDIT',
          'ODR_PAYMENT_VERIFIED_ADVANCE','AMOUNT_POSITIVE',FALSE,v_actor),
        (v_company.id,v_set,70,'PAYMENT_CLEARING','CREDIT',
          'ODR_PAYMENT_VERIFIED_CLEARING_SETTLEMENT','AMOUNT_POSITIVE',FALSE,v_actor);
      END IF;
      INSERT INTO public.posting_rule_set_audit(company_id,rule_set_id,action,
        actor_id,after_state,reason)
      SELECT rule_set.company_id,rule_set.id,'CREATE',v_actor,
        to_jsonb(rule_set)||jsonb_build_object('lines',(SELECT jsonb_agg(
          to_jsonb(line) ORDER BY line.line_no) FROM public.posting_rule_lines line
          WHERE line.company_id=rule_set.company_id AND line.rule_set_id=rule_set.id)),
        'ODR-5B deterministic mapping foundation Draft'
      FROM public.posting_rule_sets rule_set WHERE rule_set.id=v_set;

      UPDATE public.posting_rule_sets
      SET status='APPROVED',approved_by=v_actor,approved_at=v_now,
        updated_by=v_actor
      WHERE company_id=v_company.id AND id=v_set;

      INSERT INTO public.posting_rule_set_audit(company_id,rule_set_id,action,
        actor_id,after_state,reason)
      SELECT rule_set.company_id,rule_set.id,'APPROVE',v_actor,
        to_jsonb(rule_set)||jsonb_build_object('lines',(SELECT jsonb_agg(
          to_jsonb(line) ORDER BY line.line_no) FROM public.posting_rule_lines line
          WHERE line.company_id=rule_set.company_id AND line.rule_set_id=rule_set.id)),
        'ODR-5B deterministic mapping foundation approval'
      FROM public.posting_rule_sets rule_set WHERE rule_set.id=v_set;
    END LOOP;
  END LOOP;
END
$provision$;

DROP FUNCTION private.odr5b_resolve_reusable_account(UUID,TEXT,TEXT);

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260828220000','odr_phase5b_finance_mapping_foundation',
  'Provision audited Customer Advance COA, exact ODR Dispatch/Payment transaction categories and account mappings, and approved versioned posting rule definitions; no Financial Event or Journal mutation');

NOTIFY pgrst,'reload schema';
COMMIT;
