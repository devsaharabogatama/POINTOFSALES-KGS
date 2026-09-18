-- Forward fix: permit source-owned Customer Refund reversal journals while
-- preserving the canonical manual/opening-balance reversal boundary.
BEGIN;

DO $guard$
DECLARE v_definition text;v_normalized text;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260917150000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Customer Refund Step 4 required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260917151000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260917151000';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  SELECT pg_get_functiondef(to_regprocedure(
    'private.trg_g6_guard_finance_journal_line()')) INTO STRICT v_definition;
  v_normalized:=regexp_replace(lower(v_definition),'\s+','','g');
  IF position('ifv_journal_type=''reversal''then' IN v_normalized)=0
    OR position('original_journal.journal_typein(''manual'',''opening_balance'')'
      IN v_normalized)=0 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical Finance Journal line guard drift';
  END IF;
  IF position('backoffice_customer_refund' IN v_normalized)>0 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Customer Refund reversal guard already patched without ledger';
  END IF;
END
$guard$;

CREATE OR REPLACE FUNCTION private.trg_g6_guard_finance_journal_line()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE
  v_company uuid;
  v_journal uuid;
  v_status text;
  v_journal_type text;
  v_reversal_of uuid;
  v_system_event_key text;
  v_account public.chart_of_accounts%rowtype;
  v_original_line public.finance_journal_lines%rowtype;
BEGIN
  IF TG_OP='DELETE' THEN
    v_company:=OLD.company_id;
    v_journal:=OLD.journal_id;
  ELSE
    v_company:=NEW.company_id;
    v_journal:=NEW.journal_id;
  END IF;
  IF TG_OP='UPDATE' AND (
    NEW.id IS DISTINCT FROM OLD.id
    OR NEW.company_id IS DISTINCT FROM OLD.company_id
    OR NEW.journal_id IS DISTINCT FROM OLD.journal_id
  ) THEN
    RAISE EXCEPTION 'FINANCE_JOURNAL_LINE_IDENTITY_IMMUTABLE';
  END IF;

  SELECT journal.status,journal.journal_type,journal.reversal_of_journal_id,
    journal.system_event_key
  INTO v_status,v_journal_type,v_reversal_of,v_system_event_key
  FROM public.finance_journals journal
  WHERE journal.company_id=v_company AND journal.id=v_journal
  FOR UPDATE;
  IF v_status IS NULL THEN RAISE EXCEPTION 'FINANCE_JOURNAL_NOT_FOUND'; END IF;
  IF v_status<>'DRAFT' THEN RAISE EXCEPTION 'POSTED_JOURNAL_IMMUTABLE'; END IF;
  IF TG_OP='DELETE' THEN RETURN OLD; END IF;

  IF v_journal_type='REVERSAL' THEN
    SELECT original_line.* INTO v_original_line
    FROM public.finance_journal_lines original_line
    JOIN public.finance_journals original_journal
      ON original_journal.company_id=original_line.company_id
     AND original_journal.id=original_line.journal_id
    WHERE original_line.company_id=NEW.company_id
      AND original_line.journal_id=v_reversal_of
      AND original_line.line_no=NEW.line_no
      AND original_line.account_id=NEW.account_id
      AND original_journal.status='POSTED'
      AND (
        original_journal.journal_type IN('MANUAL','OPENING_BALANCE')
        OR (
          v_system_event_key='BACKOFFICE_CUSTOMER_REFUND'
          AND original_journal.system_event_key='BACKOFFICE_CUSTOMER_REFUND'
          AND original_journal.journal_type IN('AUTOMATIC','PRIOR_PERIOD_ADJUSTMENT')
        )
      );
    IF NOT FOUND THEN
      RAISE EXCEPTION 'REVERSAL_LINE_SOURCE_MISMATCH';
    END IF;
    NEW.account_code_snapshot:=v_original_line.account_code_snapshot;
    NEW.account_name_snapshot:=v_original_line.account_name_snapshot;
    NEW.account_function_key_snapshot:=v_original_line.account_function_key_snapshot;
    NEW.normal_balance_snapshot:=v_original_line.normal_balance_snapshot;
    NEW.debit:=v_original_line.credit;
    NEW.credit:=v_original_line.debit;
    NEW.store_id:=v_original_line.store_id;
    NEW.warehouse_id:=v_original_line.warehouse_id;
    NEW.customer_id:=v_original_line.customer_id;
    NEW.supplier_id:=v_original_line.supplier_id;
    RETURN NEW;
  END IF;

  SELECT * INTO v_account FROM public.chart_of_accounts account
  WHERE account.company_id=NEW.company_id AND account.id=NEW.account_id;
  IF NOT FOUND OR NOT v_account.is_active OR NOT v_account.is_postable THEN
    RAISE EXCEPTION 'ACTIVE_POSTABLE_ACCOUNT_REQUIRED';
  END IF;
  NEW.account_code_snapshot:=v_account.account_code;
  NEW.account_name_snapshot:=v_account.account_name;
  NEW.account_function_key_snapshot:=v_account.system_function_key;
  NEW.normal_balance_snapshot:=v_account.normal_balance;
  RETURN NEW;
END
$$;

REVOKE ALL ON FUNCTION private.trg_g6_guard_finance_journal_line()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.trg_g6_guard_finance_journal_line()
TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260917151000','backoffice_sales_customer_refund_reversal_guard_fix',
  'Allow exact source-linked Finance reversal only for Backoffice Customer Refund automatic/prior-period Journal; preserve all canonical manual/opening and non-Refund boundaries');

COMMIT;
