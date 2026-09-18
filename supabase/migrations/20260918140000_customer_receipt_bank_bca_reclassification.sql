-- Make BANK BCA the exact SALE_PAYMENT/BANK account for KMS, SMS, and LSM
-- across the complete Customer Receipt history, then reclassify already-posted
-- DIRECT_BANK receipts without mutating their immutable source journals.
BEGIN;

DO $guard$
DECLARE v_invalid bigint;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260911163000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: 20260911163000 required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260918140000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260918140000';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance posting queue';
  END IF;

  SELECT count(*) INTO v_invalid
  FROM (VALUES
    ('4eedbf12-3c60-40e0-b2b7-1a48ca62b6f8'::uuid,'Khadijah Muda Sejahtera'),
    ('809abdd9-d05f-4525-9726-1951a0ae1a81'::uuid,'Smart Muda Solusi'),
    ('07bdffb9-8c56-444c-a49b-81ac86745674'::uuid,'Latorti Sari Median')
  ) target(company_id,company_name)
  WHERE (SELECT count(*) FROM public.companies company
    WHERE company.id=target.company_id AND company.status='ACTIVE')<>1
    OR (SELECT count(*) FROM public.chart_of_accounts account
      WHERE account.company_id=target.company_id
        AND account.account_code='1010100-1' AND account.account_name='BANK BCA'
        AND account.account_type='ASSET' AND account.is_active AND account.is_postable)<>1
    OR (SELECT count(*) FROM public.transaction_categories category
      WHERE category.company_id=target.company_id AND category.system_key='SALE_PAYMENT'
        AND category.is_active)<>1;
  IF v_invalid<>0 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: target Company, BANK BCA, or SALE_PAYMENT category invalid';
  END IF;

  SELECT count(*) INTO v_invalid
  FROM (VALUES
    ('4eedbf12-3c60-40e0-b2b7-1a48ca62b6f8'::uuid),
    ('809abdd9-d05f-4525-9726-1951a0ae1a81'::uuid),
    ('07bdffb9-8c56-444c-a49b-81ac86745674'::uuid)
  ) target(company_id)
  WHERE (SELECT count(*)
    FROM public.transaction_account_rules rule
    JOIN public.transaction_categories category
      ON category.company_id=rule.company_id AND category.id=rule.transaction_category_id
    JOIN public.chart_of_accounts account
      ON account.company_id=rule.company_id AND account.id=rule.account_id
    WHERE rule.company_id=target.company_id AND category.system_key='SALE_PAYMENT'
      AND rule.account_function_key='BANK' AND rule.status='ACTIVE'
      AND rule.effective_to IS NULL AND account.account_code='1010100-1'
      AND account.account_name='BANK BCA')<>1;
  IF v_invalid<>0 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: exact open-ended BANK BCA rule required';
  END IF;

  SELECT count(*) INTO v_invalid
  FROM public.customer_receipt_documents receipt
  JOIN (VALUES
    ('4eedbf12-3c60-40e0-b2b7-1a48ca62b6f8'::uuid),
    ('809abdd9-d05f-4525-9726-1951a0ae1a81'::uuid),
    ('07bdffb9-8c56-444c-a49b-81ac86745674'::uuid)
  ) target(company_id) ON target.company_id=receipt.company_id
  JOIN public.chart_of_accounts bca ON bca.company_id=receipt.company_id
    AND bca.account_code='1010100-1' AND bca.account_name='BANK BCA'
    AND bca.is_active AND bca.is_postable
  WHERE receipt.status='POSTED' AND receipt.settlement_route_snapshot='DIRECT_BANK'
    AND receipt.receipt_account_id_snapshot IS DISTINCT FROM bca.id
    AND ((SELECT count(*) FROM public.finance_journals journal
      WHERE journal.company_id=receipt.company_id
        AND journal.source_type='customer_receipt_documents'
        AND journal.source_id=receipt.id AND journal.system_event_key='SALE_PAYMENT'
        AND journal.status='POSTED')<>1
      OR (SELECT count(*) FROM public.finance_journals journal
        JOIN public.finance_journal_lines line ON line.company_id=journal.company_id
          AND line.journal_id=journal.id
        WHERE journal.company_id=receipt.company_id
          AND journal.source_type='customer_receipt_documents'
          AND journal.source_id=receipt.id AND journal.system_event_key='SALE_PAYMENT'
          AND journal.status='POSTED' AND line.account_id=receipt.receipt_account_id_snapshot
          AND line.debit=receipt.total_amount AND line.credit=0)<>1
      OR (SELECT count(*) FROM public.chart_of_accounts account
        WHERE account.company_id=receipt.company_id
          AND account.id=receipt.receipt_account_id_snapshot
          AND account.is_active AND account.is_postable)<>1
      OR (SELECT count(*) FROM public.accounting_periods period
        WHERE period.company_id=receipt.company_id
          AND receipt.receipt_date BETWEEN period.start_date AND period.end_date
          AND period.status IN('OPEN','REOPENED'))<>1);
  IF v_invalid<>0 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Customer Receipt source journal or open period invalid';
  END IF;
END $guard$;

DO $migration$
DECLARE
  v_target record;v_category uuid;v_bca public.chart_of_accounts%rowtype;
  v_future_rule public.transaction_account_rules%rowtype;v_history_rule_id uuid;
  v_history_version bigint;v_receipt record;v_period uuid;v_journal_id uuid;
BEGIN
  FOR v_target IN SELECT * FROM (VALUES
    ('4eedbf12-3c60-40e0-b2b7-1a48ca62b6f8'::uuid,'Khadijah Muda Sejahtera'),
    ('809abdd9-d05f-4525-9726-1951a0ae1a81'::uuid,'Smart Muda Solusi'),
    ('07bdffb9-8c56-444c-a49b-81ac86745674'::uuid,'Latorti Sari Median')
  ) target(company_id,company_name)
  LOOP
    PERFORM pg_advisory_xact_lock(hashtextextended(
      'CUSTOMER_RECEIPT_BANK_BCA_RECLASS|'||v_target.company_id,0));
    SELECT * INTO STRICT v_bca FROM public.chart_of_accounts account
    WHERE account.company_id=v_target.company_id AND account.account_code='1010100-1'
      AND account.account_name='BANK BCA' AND account.account_type='ASSET'
      AND account.is_active AND account.is_postable;
    SELECT category.id INTO STRICT v_category FROM public.transaction_categories category
    WHERE category.company_id=v_target.company_id AND category.system_key='SALE_PAYMENT'
      AND category.is_active;
    SELECT rule.* INTO STRICT v_future_rule
    FROM public.transaction_account_rules rule
    WHERE rule.company_id=v_target.company_id AND rule.transaction_category_id=v_category
      AND rule.account_function_key='BANK' AND rule.account_id=v_bca.id
      AND rule.status='ACTIVE' AND rule.effective_to IS NULL;

    IF EXISTS(SELECT 1 FROM public.transaction_account_rules rule
      WHERE rule.company_id=v_target.company_id AND rule.transaction_category_id=v_category
        AND rule.account_function_key='BANK' AND rule.status='ACTIVE'
        AND rule.id<>v_future_rule.id
        AND tstzrange(rule.effective_from,rule.effective_to,'[)')
          && tstzrange('-infinity'::timestamptz,v_future_rule.effective_from,'[)')) THEN
      RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: historical SALE_PAYMENT/BANK rule overlap for %',
        v_target.company_name;
    END IF;
    SELECT COALESCE(max(rule.rule_version),0)+1 INTO v_history_version
    FROM public.transaction_account_rules rule
    WHERE rule.company_id=v_target.company_id AND rule.transaction_category_id=v_category
      AND rule.account_function_key='BANK';
    INSERT INTO public.transaction_account_rules(company_id,transaction_category_id,
      system_key,account_function_key,account_id,effective_from,effective_to,
      rule_version,status,approved_by,approved_at,created_by,updated_by)
    VALUES(v_target.company_id,v_category,'SALE_PAYMENT','BANK',v_bca.id,
      '-infinity'::timestamptz,v_future_rule.effective_from,v_history_version,'ACTIVE',
      v_future_rule.approved_by,clock_timestamp(),v_future_rule.approved_by,
      v_future_rule.approved_by)
    RETURNING id INTO v_history_rule_id;
    INSERT INTO public.finance_master_audit(company_id,entity_type,entity_id,action,
      actor_id,before_state,after_state)
    SELECT v_target.company_id,'RULE',v_history_rule_id,'CREATE',
      v_future_rule.approved_by,NULL,to_jsonb(rule)
    FROM public.transaction_account_rules rule
    WHERE rule.company_id=v_target.company_id AND rule.id=v_history_rule_id;

    FOR v_receipt IN
      SELECT receipt.id,receipt.receipt_no,receipt.receipt_date,receipt.total_amount,
        receipt.customer_id,receipt.master_version,receipt.posted_by,
        receipt.receipt_account_id_snapshot old_account_id,
        source_journal.posted_by source_actor
      FROM public.customer_receipt_documents receipt
      JOIN public.finance_journals source_journal
        ON source_journal.company_id=receipt.company_id
       AND source_journal.source_type='customer_receipt_documents'
       AND source_journal.source_id=receipt.id
       AND source_journal.system_event_key='SALE_PAYMENT'
       AND source_journal.status='POSTED'
      WHERE receipt.company_id=v_target.company_id AND receipt.status='POSTED'
        AND receipt.settlement_route_snapshot='DIRECT_BANK'
        AND receipt.receipt_account_id_snapshot IS DISTINCT FROM v_bca.id
        AND NOT EXISTS(SELECT 1 FROM public.finance_journals correction
          WHERE correction.company_id=receipt.company_id
            AND correction.source_type='CUSTOMER_RECEIPT_BANK_RECLASSIFICATION'
            AND correction.source_id=receipt.id)
      ORDER BY receipt.receipt_date,receipt.id
    LOOP
      SELECT period.id INTO STRICT v_period FROM public.accounting_periods period
      WHERE period.company_id=v_target.company_id
        AND v_receipt.receipt_date BETWEEN period.start_date AND period.end_date
        AND period.status IN('OPEN','REOPENED');
      v_journal_id:=gen_random_uuid();
      INSERT INTO public.finance_journals(id,company_id,journal_no,journal_type,
        accounting_period_id,accounting_date,original_event_date,source_type,source_id,
        source_version,idempotency_key,system_event_key,transaction_category_id,
        transaction_rule_version,description,status,created_by)
      VALUES(v_journal_id,v_target.company_id,
        'RCB-'||upper(replace(v_receipt.id::text,'-','')),'PRIOR_PERIOD_ADJUSTMENT',
        v_period,v_receipt.receipt_date,v_receipt.receipt_date,
        'CUSTOMER_RECEIPT_BANK_RECLASSIFICATION',v_receipt.id,v_receipt.master_version,
        'CUSTOMER_RECEIPT_BANK_RECLASS|'||v_target.company_id||'|'||v_receipt.id,
        'SALE_PAYMENT',v_category,v_history_version,
        'Reklasifikasi Penerimaan Customer '||v_receipt.receipt_no||
          ' dari akun Bank lama ke BANK BCA','DRAFT',
        COALESCE(v_receipt.source_actor,v_receipt.posted_by));
      INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,account_id,
        debit,credit,customer_id,description) VALUES
        (v_target.company_id,v_journal_id,1,v_bca.id,v_receipt.total_amount,0,
          v_receipt.customer_id,'REKLASIFIKASI_PENERIMAAN_CUSTOMER_KE_BANK_BCA'),
        (v_target.company_id,v_journal_id,2,v_receipt.old_account_id,0,
          v_receipt.total_amount,v_receipt.customer_id,
          'REKLASIFIKASI_PENERIMAAN_CUSTOMER_DARI_BANK_LAMA');
      UPDATE public.finance_journals SET status='POSTED',
        posted_by=COALESCE(v_receipt.source_actor,v_receipt.posted_by)
      WHERE company_id=v_target.company_id AND id=v_journal_id;
    END LOOP;
  END LOOP;
END $migration$;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260918140000','customer_receipt_bank_bca_reclassification',
  'Exact SALE_PAYMENT/BANK historical coverage and append-only per-receipt Bank-to-BANK-BCA reclassification for KMS, SMS, and LSM; Cash and source journals remain unchanged.');
COMMIT;
