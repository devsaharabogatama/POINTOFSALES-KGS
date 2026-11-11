-- Backoffice AR Task 4: native Credit Note becomes an unallocated AR open credit.
-- RETAINED_RETAIL, POS, Stock/FIFO, Customer Balance and historical rows remain unchanged.
BEGIN;

DO $guard$
DECLARE v_invalid bigint;
BEGIN
  IF (SELECT count(*) FROM private.kgs_schema_migrations
    WHERE version IN('20260722150000','20260917130000','20260917131000',
      '20260918150000','20260919110000','20260928110000','20261006140000',
      '20261105100000','20261105110000'))<>9 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Task 4 dependency chain incomplete';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20261105120000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20261105120000';
  END IF;
  IF to_regprocedure(
      'private.ar4_backoffice_invoice_allocated_credit(uuid,uuid,date)') IS NOT NULL
    OR to_regprocedure(
      'private.ar4_register_backoffice_credit_note_open_item(uuid,uuid,uuid)') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Task 4 helper collision';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
    WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
  IF EXISTS(SELECT 1 FROM public.company_sales_process_settings setting
    JOIN public.companies company ON company.id=setting.company_id
    WHERE setting.active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE'
      AND public.private_company_feature_enabled(company.id,'tax_sales_enabled')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Tax-enabled Backoffice Company is held';
  END IF;
  IF md5(pg_get_functiondef(
      'private.post_backoffice_sales_credit_note_before_retained(uuid,bigint,uuid)'::regprocedure))
        <>'795824db964e91f35ab98a1cf98a0714'
    OR md5(pg_get_functiondef(
      'public.post_backoffice_sales_credit_note(uuid,bigint,uuid)'::regprocedure))
        <>'93723ceab34fd6318088f314e976dd72'
    OR md5(pg_get_functiondef(
      'private.backoffice_invoice_receivable_before_receipts(uuid,uuid,date)'::regprocedure))
        <>'467b4f4dabed3e309bd4a7b3872d42de'
    OR md5(pg_get_functiondef(
      'private.reconcile_backoffice_invoice_receivable_schedule(uuid,uuid)'::regprocedure))
        <>'d933336fee8deb7ade36d5734dff5ea7'
    OR md5(pg_get_functiondef(
      'public.get_finance_customer_receipts()'::regprocedure))
        <>'9d3dd3f45278f0fdffa56d278469faee'
    OR md5(pg_get_functiondef(
      'public.get_backoffice_sales_invoice_payment_context_before_unified_revision(uuid)'::regprocedure))
        <>'dd29fa5efe66edc9076a1d98aac1ad69'
    OR md5(pg_get_functiondef(
      'public.get_backoffice_sales_invoice_payment_context(uuid)'::regprocedure))
        <>'dbe5b9307343bd03e6ea61a36490c692'
    OR md5(pg_get_functiondef(
      'public.get_finance_ar_aging(date,uuid,uuid)'::regprocedure))
        <>'70d757be76dd2c402c1d55e2f8992a35'
    OR md5(pg_get_functiondef(
      'private.plan_backoffice_invoice_revision_journals(uuid)'::regprocedure))
        <>'cbf0494bd20732cbffbb768494c2a241'
    OR md5(pg_get_functiondef(
      'private.trg_ar_open_item_validate_allocation()'::regprocedure))
        <>'971d226cd2e0fed0714b473e41484a04' THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Task 4 active runtime anchor changed';
  END IF;
  SELECT count(*) INTO v_invalid
  FROM public.backoffice_sales_credit_notes note
  JOIN public.company_sales_process_settings setting
    ON setting.company_id=note.company_id
    AND setting.active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE'
  LEFT JOIN public.ar_open_item_registry item
    ON item.company_id=note.company_id AND item.scope_kind='BACKOFFICE'
    AND item.item_kind='CREDIT_NOTE' AND item.source_id=note.id
  LEFT JOIN LATERAL(SELECT COALESCE(sum(allocation.allocated_amount),0) amount
    FROM public.ar_open_item_allocations allocation
    WHERE allocation.company_id=item.company_id
      AND allocation.credit_item_id=item.id) allocated ON true
  WHERE note.source_kind='BACKOFFICE' AND note.status='POSTED'
    AND (item.id IS NULL OR item.original_amount<>note.ar_reduction_amount
      OR allocated.amount<>note.ar_reduction_amount);
  IF v_invalid<>0 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: historical Credit Note open-item mismatch %',v_invalid;
  END IF;
END
$guard$;

CREATE FUNCTION private.ar4_backoffice_invoice_allocated_credit(
  p_company_id uuid,p_invoice_id uuid,p_as_of date
) RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
  SELECT round(COALESCE(sum(allocation.allocated_amount),0),4)
  FROM public.ar_open_item_registry debit_item
  JOIN public.ar_open_item_allocations allocation
    ON allocation.company_id=debit_item.company_id
    AND allocation.debit_item_id=debit_item.id
  JOIN public.ar_open_item_registry credit_item
    ON credit_item.company_id=allocation.company_id
    AND credit_item.id=allocation.credit_item_id
    AND credit_item.scope_kind='BACKOFFICE'
    AND credit_item.item_kind='CREDIT_NOTE'
    AND credit_item.direction='CREDIT'
  WHERE debit_item.company_id=p_company_id
    AND debit_item.scope_kind='BACKOFFICE'
    AND debit_item.item_kind='INVOICE'
    AND debit_item.direction='DEBIT'
    AND debit_item.source_id=p_invoice_id
    AND (p_as_of IS NULL OR credit_item.document_date<=p_as_of)
$$;

CREATE FUNCTION private.ar4_register_backoffice_credit_note_open_item(
  p_company_id uuid,p_credit_note_id uuid,p_actor_id uuid
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_note public.backoffice_sales_credit_notes%rowtype;
  v_event public.financial_events%rowtype;v_account uuid;
  v_journal_id uuid;v_journal_line_id uuid;v_item uuid;v_count bigint;
BEGIN
  SELECT * INTO v_note FROM public.backoffice_sales_credit_notes note
  WHERE note.company_id=p_company_id AND note.id=p_credit_note_id
    AND note.status='POSTED' AND note.source_kind='BACKOFFICE' FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'AR_OPEN_ITEM_CREDIT_NOTE_NOT_ELIGIBLE'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.company_sales_process_settings setting
    WHERE setting.company_id=p_company_id
      AND setting.active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE') THEN
    RAISE EXCEPTION 'AR_OPEN_ITEM_CREDIT_NOTE_PROCESS_MODE_INVALID';
  END IF;
  IF public.private_company_feature_enabled(p_company_id,'tax_sales_enabled') THEN
    RAISE EXCEPTION 'AR_OPEN_ITEM_CREDIT_NOTE_TAX_TREATMENT_PENDING';
  END IF;
  IF v_note.ar_reduction_amount<>v_note.grand_total
    OR v_note.refund_liability_amount<>0 OR v_note.grand_total<=0 THEN
    RAISE EXCEPTION 'AR_OPEN_ITEM_CREDIT_NOTE_AMOUNT_INVALID';
  END IF;
  SELECT item.id INTO v_item FROM public.ar_open_item_registry item
  WHERE item.company_id=p_company_id AND item.scope_kind='BACKOFFICE'
    AND item.item_kind='CREDIT_NOTE' AND item.source_id=p_credit_note_id;
  IF FOUND THEN
    PERFORM 1 FROM public.ar_open_item_registry item
    WHERE item.company_id=p_company_id AND item.id=v_item
      AND item.customer_id=v_note.customer_id AND item.direction='CREDIT'
      AND item.original_amount=v_note.grand_total
      AND item.document_no=v_note.credit_note_no
      AND item.document_date=v_note.credit_note_date;
    IF NOT FOUND THEN RAISE EXCEPTION 'AR_OPEN_ITEM_CREDIT_NOTE_IDENTITY_CONFLICT'; END IF;
    RETURN v_item;
  END IF;
  SELECT * INTO STRICT v_event FROM public.financial_events event
  WHERE event.company_id=p_company_id AND event.id=v_note.financial_event_id
    AND event.status='POSTED'::public.event_status;
  v_account:=private.resolve_financial_event_account(v_event,'CUSTOMER_RECEIVABLE');
  SELECT count(*) INTO v_count FROM public.finance_journals journal
  JOIN public.finance_journal_lines line ON line.company_id=journal.company_id
    AND line.journal_id=journal.id
  WHERE journal.company_id=p_company_id
    AND journal.financial_event_id=v_note.financial_event_id
    AND journal.status='POSTED' AND line.account_id=v_account
    AND line.customer_id=v_note.customer_id AND line.debit=0
    AND line.credit=v_note.grand_total;
  IF v_count<>1 THEN RAISE EXCEPTION 'AR_OPEN_ITEM_CREDIT_NOTE_JOURNAL_LINE_INVALID'; END IF;
  SELECT journal.id,line.id INTO STRICT v_journal_id,v_journal_line_id
  FROM public.finance_journals journal
  JOIN public.finance_journal_lines line ON line.company_id=journal.company_id
    AND line.journal_id=journal.id
  WHERE journal.company_id=p_company_id
    AND journal.financial_event_id=v_note.financial_event_id
    AND journal.status='POSTED' AND line.account_id=v_account
    AND line.customer_id=v_note.customer_id AND line.debit=0
    AND line.credit=v_note.grand_total;
  INSERT INTO public.ar_open_item_registry(company_id,item_kind,source_id,
    financial_event_id,journal_id,journal_line_id,customer_id,account_id,direction,
    document_no,document_date,original_amount,source_snapshot,created_by)
  VALUES(p_company_id,'CREDIT_NOTE',v_note.id,v_note.financial_event_id,
    v_journal_id,v_journal_line_id,v_note.customer_id,v_account,'CREDIT',
    v_note.credit_note_no,v_note.credit_note_date,v_note.grand_total,
    jsonb_build_object('sourceTable','backoffice_sales_credit_notes',
      'sourceInvoiceId',v_note.source_invoice_id,'returnId',v_note.return_id,
      'masterVersion',v_note.master_version,'runtime','TASK4'),
    COALESCE(p_actor_id,v_note.posted_by,v_note.created_by))
  RETURNING id INTO v_item;
  RETURN v_item;
END
$$;

CREATE OR REPLACE FUNCTION private.backoffice_invoice_receivable_before_receipts(
  p_company_id uuid,p_invoice_id uuid,p_as_of date
) RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
  SELECT CASE WHEN invoice.status='POSTED' AND invoice.invoice_date<=p_as_of
    THEN greatest(0,private.backoffice_invoice_effective_total(
      invoice.company_id,invoice.id,p_as_of)
      -private.ar4_backoffice_invoice_allocated_credit(
        invoice.company_id,invoice.id,p_as_of))
    ELSE 0::numeric END
  FROM public.backoffice_sales_invoices invoice
  WHERE invoice.company_id=p_company_id AND invoice.id=p_invoice_id
$$;

DO $patch_schedule$
DECLARE v_definition text;v_old text;v_new text;v_count integer;
BEGIN
  SELECT pg_get_functiondef(
    'private.reconcile_backoffice_invoice_receivable_schedule(uuid,uuid)'::regprocedure)
    INTO STRICT v_definition;
  v_old:=$old$SELECT round(COALESCE(sum(note.ar_reduction_amount),0),4) INTO v_credit
  FROM public.backoffice_sales_credit_notes note
  WHERE note.company_id=p_company_id AND note.source_invoice_id=p_invoice_id AND note.status='POSTED';$old$;
  v_new:=$new$SELECT private.ar4_backoffice_invoice_allocated_credit(
    p_company_id,p_invoice_id,NULL) INTO v_credit;$new$;
  v_count:=(length(v_definition)-length(replace(v_definition,v_old,'')))/length(v_old);
  IF v_count<>1 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: schedule Credit allocation anchor %',v_count;
  END IF;
  EXECUTE replace(v_definition,v_old,v_new);
END
$patch_schedule$;

DO $patch_workspace$
DECLARE v_definition text;v_old text;v_new text;v_count integer;
BEGIN
  SELECT pg_get_functiondef('public.get_finance_customer_receipts()'::regprocedure)
    INTO STRICT v_definition;
  v_old:=$old$COALESCE((SELECT sum(note.ar_reduction_amount)
          FROM public.backoffice_sales_credit_notes note
          WHERE note.company_id=invoice.company_id AND note.source_kind='BACKOFFICE'
            AND note.source_invoice_id=invoice.id AND note.status='POSTED'
            AND note.credit_note_date<=v_today),0)$old$;
  v_new:=$new$private.ar4_backoffice_invoice_allocated_credit(
          invoice.company_id,invoice.id,v_today)$new$;
  v_count:=(length(v_definition)-length(replace(v_definition,v_old,'')))/length(v_old);
  IF v_count<>1 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Receipt workspace Credit anchor %',v_count;
  END IF;
  EXECUTE replace(v_definition,v_old,v_new);
END
$patch_workspace$;

DO $patch_payment_context$
DECLARE v_definition text;v_old text;v_new text;v_count integer;
BEGIN
  SELECT pg_get_functiondef(
    'public.get_backoffice_sales_invoice_payment_context_before_unified_revision(uuid)'::regprocedure)
    INTO STRICT v_definition;
  v_old:='SELECT round(COALESCE(sum(note.grand_total),0),4),';
  v_new:='SELECT private.ar4_backoffice_invoice_allocated_credit('
    ||'v_company,p_invoice_id,NULL),';
  v_count:=(length(v_definition)-length(replace(v_definition,v_old,'')))/length(v_old);
  IF v_count<>1 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: payment context Credit anchor %',v_count;
  END IF;
  EXECUTE replace(v_definition,v_old,v_new);
END
$patch_payment_context$;

DO $patch_aging$
DECLARE v_definition text;v_old text;v_new text;v_count integer;
BEGIN
  SELECT pg_get_functiondef('public.get_finance_ar_aging(date,uuid,uuid)'::regprocedure)
    INTO STRICT v_definition;
  v_old:=$old$LEFT JOIN LATERAL(SELECT sum(note.ar_reduction_amount) credited
      FROM public.backoffice_sales_credit_notes note
      WHERE note.company_id=invoice.company_id AND note.source_invoice_id=invoice.id
        AND note.status='POSTED' AND note.credit_note_date<=v_as_of) credit ON true$old$;
  v_new:=$new$LEFT JOIN LATERAL(SELECT private.ar4_backoffice_invoice_allocated_credit(
      invoice.company_id,invoice.id,v_as_of) credited) credit ON true$new$;
  v_count:=(length(v_definition)-length(replace(v_definition,v_old,'')))/length(v_old);
  IF v_count<>1 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: AR Aging Credit anchor %',v_count;
  END IF;
  EXECUTE replace(v_definition,v_old,v_new);
END
$patch_aging$;

DO $patch_revision$
DECLARE v_definition text;v_old text;v_new text;v_count integer;
BEGIN
  SELECT pg_get_functiondef(
    'private.plan_backoffice_invoice_revision_journals(uuid)'::regprocedure)
    INTO STRICT v_definition;
  v_old:=$old$SELECT round(COALESCE(sum(n.ar_reduction_amount),0),4) INTO v_credited
  FROM public.backoffice_sales_credit_notes n
  WHERE n.company_id=v_company AND n.source_invoice_id=v_invoice.id AND n.status='POSTED';$old$;
  v_new:=$new$SELECT private.ar4_backoffice_invoice_allocated_credit(
    v_company,v_invoice.id,NULL) INTO v_credited;$new$;
  v_count:=(length(v_definition)-length(replace(v_definition,v_old,'')))/length(v_old);
  IF v_count<>1 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Invoice revision Credit anchor %',v_count;
  END IF;
  EXECUTE replace(v_definition,v_old,v_new);
END
$patch_revision$;

DO $patch_native_post$
DECLARE v_definition text;v_old text;v_new text;v_count integer;
BEGIN
  SELECT pg_get_functiondef(
    'private.post_backoffice_sales_credit_note_before_retained(uuid,bigint,uuid)'::regprocedure)
    INTO STRICT v_definition;
  v_old:=$old$IF v_note.credit_note_date>v_company_today THEN
    RAISE EXCEPTION 'CREDIT_NOTE_DATE_FUTURE: tanggal Credit Note tidak boleh melewati tanggal Company';
  END IF;$old$;
  v_new:=$new$IF v_note.credit_note_date>v_company_today THEN
    RAISE EXCEPTION 'CREDIT_NOTE_DATE_FUTURE: tanggal Credit Note tidak boleh melewati tanggal Company';
  END IF;
  IF public.private_company_feature_enabled(v_company,'tax_sales_enabled') THEN
    RAISE EXCEPTION 'AR_OPEN_ITEM_CREDIT_NOTE_TAX_TREATMENT_PENDING';
  END IF;$new$;
  v_count:=(length(v_definition)-length(replace(v_definition,v_old,'')))/length(v_old);
  IF v_count<>1 THEN RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: native Tax anchor %',v_count; END IF;
  v_definition:=replace(v_definition,v_old,v_new);

  v_old:=$old$v_outstanding:=greatest(0,round(v_effective_total-v_paid-v_prior_credit,4));
  v_ar:=least(v_note.grand_total,v_outstanding);v_refund:=v_note.grand_total-v_ar;$old$;
  v_new:=$new$v_outstanding:=greatest(0,round(v_effective_total-v_paid-v_prior_credit,4));
  v_ar:=v_note.grand_total;v_refund:=0;$new$;
  v_count:=(length(v_definition)-length(replace(v_definition,v_old,'')))/length(v_old);
  IF v_count<>1 THEN RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: native split anchor %',v_count; END IF;
  v_definition:=replace(v_definition,v_old,v_new);

  v_old:=$old$WHERE company_id=v_company AND id=v_note.id;
  PERFORM private.reconcile_backoffice_invoice_receivable_schedule(v_company,v_invoice.id);$old$;
  v_new:=$new$WHERE company_id=v_company AND id=v_note.id;
  PERFORM private.ar4_register_backoffice_credit_note_open_item(
    v_company,v_note.id,v_actor);
  PERFORM private.reconcile_backoffice_invoice_receivable_schedule(v_company,v_invoice.id);$new$;
  v_count:=(length(v_definition)-length(replace(v_definition,v_old,'')))/length(v_old);
  IF v_count<>1 THEN RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: native Registry anchor %',v_count; END IF;
  v_definition:=replace(v_definition,v_old,v_new);

  v_count:=(length(v_definition)-length(replace(v_definition,'20260917131000','')))
    /length('20260917131000');
  IF v_count<>3 THEN RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: native version anchor %',v_count; END IF;
  EXECUTE replace(v_definition,'20260917131000','20261105120000');
END
$patch_native_post$;

REVOKE ALL ON FUNCTION
  private.ar4_backoffice_invoice_allocated_credit(uuid,uuid,date),
  private.ar4_register_backoffice_credit_note_open_item(uuid,uuid,uuid)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.ar4_backoffice_invoice_allocated_credit(uuid,uuid,date),
  private.ar4_register_backoffice_credit_note_open_item(uuid,uuid,uuid)
  TO service_role;

DO $postcondition$
DECLARE v_native text;v_public text;
BEGIN
  SELECT pg_get_functiondef(
    'private.post_backoffice_sales_credit_note_before_retained(uuid,bigint,uuid)'::regprocedure)
    INTO STRICT v_native;
  SELECT pg_get_functiondef(
    'public.post_backoffice_sales_credit_note(uuid,bigint,uuid)'::regprocedure)
    INTO STRICT v_public;
  IF v_native NOT ILIKE '%v_ar:=v_note.grand_total;v_refund:=0%'
    OR v_native NOT ILIKE '%ar4_register_backoffice_credit_note_open_item%'
    OR v_native ILIKE '%v_ar:=least(v_note.grand_total,v_outstanding)%'
    OR v_native NOT ILIKE '%AR_OPEN_ITEM_CREDIT_NOTE_TAX_TREATMENT_PENDING%'
    OR md5(v_public)<>'93723ceab34fd6318088f314e976dd72'
    OR pg_get_functiondef(
      'private.backoffice_invoice_receivable_before_receipts(uuid,uuid,date)'::regprocedure)
        NOT ILIKE '%ar4_backoffice_invoice_allocated_credit%'
    OR pg_get_functiondef(
      'private.reconcile_backoffice_invoice_receivable_schedule(uuid,uuid)'::regprocedure)
        NOT ILIKE '%ar4_backoffice_invoice_allocated_credit%'
    OR pg_get_functiondef('public.get_finance_customer_receipts()'::regprocedure)
        NOT ILIKE '%ar4_backoffice_invoice_allocated_credit%'
    OR pg_get_functiondef(
      'public.get_backoffice_sales_invoice_payment_context_before_unified_revision(uuid)'::regprocedure)
        NOT ILIKE '%ar4_backoffice_invoice_allocated_credit%'
    OR pg_get_functiondef('public.get_finance_ar_aging(date,uuid,uuid)'::regprocedure)
        NOT ILIKE '%ar4_backoffice_invoice_allocated_credit%'
    OR pg_get_functiondef(
      'private.plan_backoffice_invoice_revision_journals(uuid)'::regprocedure)
        NOT ILIKE '%ar4_backoffice_invoice_allocated_credit%' THEN
    RAISE EXCEPTION 'MIGRATION_POSTCONDITION_FAILED: Task 4 runtime incomplete';
  END IF;
END
$postcondition$;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20261105120000','backoffice_ar_credit_note_open_credit_runtime',
  'Native Backoffice Credit Note credits AR in full and registers Customer-scoped open credit without automatic allocation; Invoice consumers use explicit allocation; Retail/POS and historical rows preserved');

NOTIFY pgrst,'reload schema';
COMMIT;
