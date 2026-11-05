-- Backoffice AR Task 3: future Invoice/Receipt open-item registration,
-- manual allocation, and customer-scoped Receipt residual credit.
BEGIN;

DO $guard$
DECLARE v_queue bigint;v_offline bigint;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20261105100000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: AR open-item foundation required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20261105110000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20261105110000';
  END IF;
  IF md5(pg_get_functiondef(
      'public.post_backoffice_sales_invoice(uuid,bigint,uuid)'::regprocedure))
      <>'1db55a961aa431842a873ca0ede4bafc'
    OR md5(pg_get_functiondef(
      'public.save_customer_receipt_allocated_draft(uuid,bigint,uuid,date,uuid,text,text,text,numeric,jsonb)'::regprocedure))
      <>'f77bd1009a5c15f063748981ad48e77d'
    OR md5(pg_get_functiondef(
      'public.post_customer_receipt_allocated(uuid,bigint,uuid)'::regprocedure))
      <>'38a4231b1a5b74df20c9dd37ce4fa31d'
    OR md5(pg_get_functiondef(
      'public.post_customer_receipt_unified(uuid,bigint,uuid)'::regprocedure))
      <>'4ba2b068f42dfcf4e9962fc5fff28e93'
    OR md5(pg_get_functiondef(
      'private.trg_ar_open_item_validate_allocation()'::regprocedure))
      <>'723f2b86473839304cc42a41a06f89b5'
    OR md5(pg_get_functiondef(
      'public.get_finance_ar_open_items(uuid,boolean)'::regprocedure))
      <>'ad88b8163b60e452cace8f4821a5ded9' THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active AR runtime anchor changed';
  END IF;
  IF to_regprocedure('private.ar3_post_backoffice_sales_invoice_core(uuid,bigint,uuid)') IS NOT NULL
    OR to_regprocedure('private.ar3_post_customer_receipt_allocated_core(uuid,bigint,uuid)') IS NOT NULL
    OR to_regprocedure('private.ar3_post_customer_receipt_unified_core(uuid,bigint,uuid)') IS NOT NULL
    OR to_regprocedure('public.save_customer_receipt_open_credit_draft(uuid,bigint,uuid,date,uuid,text,text,text,numeric,jsonb)') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Task 3 runtime collision';
  END IF;
  IF to_regprocedure('public.register_backoffice_sales_invoice_payment(uuid,uuid,date,uuid,numeric,text,text,text)') IS NULL
    OR to_regprocedure('private.f2_post_customer_receipt_hold_core(uuid,bigint,uuid)') IS NULL
    OR to_regprocedure('private.resolve_financial_event_account(public.financial_events,text)') IS NULL
    OR position('public.post_customer_receipt_allocated' in pg_get_functiondef(
      'public.register_backoffice_sales_invoice_payment(uuid,uuid,date,uuid,numeric,text,text,text)'::regprocedure))=0 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical payment dependency missing';
  END IF;
  SELECT count(*) INTO v_queue FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING');
  SELECT count(*) INTO v_offline FROM public.pos_offline_sale_submissions
  WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION');
  IF v_queue<>0 OR v_offline<>0 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance/Offline runtime';
  END IF;
  IF EXISTS(SELECT 1 FROM public.customer_receipt_documents receipt
    JOIN public.company_sales_process_settings setting
      ON setting.company_id=receipt.company_id
      AND setting.active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE'
    WHERE receipt.status='DRAFT') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Backoffice Customer Receipt Draft exists';
  END IF;
END
$guard$;

-- Freeze source writes while wrappers and any cutover delta are installed.
LOCK TABLE public.backoffice_sales_invoices IN SHARE ROW EXCLUSIVE MODE;
LOCK TABLE public.customer_receipt_documents IN SHARE ROW EXCLUSIVE MODE;
LOCK TABLE public.customer_receipt_backoffice_invoice_allocations IN SHARE ROW EXCLUSIVE MODE;
LOCK TABLE public.customer_receipt_allocations IN SHARE ROW EXCLUSIVE MODE;

ALTER TABLE public.ar_open_item_operations
  DROP CONSTRAINT ar_open_item_operations_shape,
  ADD CONSTRAINT ar_open_item_operations_shape CHECK(
    operation_kind IN('BACKFILL_RECEIPT','BACKFILL_CREDIT_NOTE',
      'BACKFILL_PRICE_CORRECTION','POST_RECEIPT')
    AND nullif(btrim(idempotency_key),'') IS NOT NULL
    AND request_hash~'^[0-9a-f]{32}$'
    AND jsonb_typeof(operation_snapshot)='object');

CREATE OR REPLACE FUNCTION private.trg_ar_open_item_validate_allocation()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_debit public.ar_open_item_registry%rowtype;
  v_credit public.ar_open_item_registry%rowtype;v_debit_used numeric;
  v_credit_used numeric;v_operation_kind text;
BEGIN
  SELECT * INTO STRICT v_debit FROM public.ar_open_item_registry item
  WHERE item.company_id=NEW.company_id AND item.id=NEW.debit_item_id FOR UPDATE;
  SELECT * INTO STRICT v_credit FROM public.ar_open_item_registry item
  WHERE item.company_id=NEW.company_id AND item.id=NEW.credit_item_id FOR UPDATE;
  IF v_debit.direction<>'DEBIT' OR v_credit.direction<>'CREDIT'
    OR v_debit.customer_id<>v_credit.customer_id THEN
    RAISE EXCEPTION 'AR_OPEN_ITEM_ALLOCATION_IDENTITY_INVALID';
  END IF;
  SELECT operation.operation_kind INTO STRICT v_operation_kind
  FROM public.ar_open_item_operations operation
  WHERE operation.company_id=NEW.company_id AND operation.id=NEW.operation_id;
  IF (NEW.source_kind='RECEIPT_ALLOCATION'
      AND v_operation_kind NOT IN('BACKFILL_RECEIPT','POST_RECEIPT'))
    OR (NEW.source_kind='CREDIT_NOTE' AND v_operation_kind<>'BACKFILL_CREDIT_NOTE')
    OR (NEW.source_kind='PRICE_CORRECTION'
      AND v_operation_kind<>'BACKFILL_PRICE_CORRECTION') THEN
    RAISE EXCEPTION 'AR_OPEN_ITEM_ALLOCATION_OPERATION_INVALID';
  END IF;
  SELECT COALESCE(sum(allocation.allocated_amount),0) INTO v_debit_used
  FROM public.ar_open_item_allocations allocation
  WHERE allocation.company_id=NEW.company_id
    AND allocation.debit_item_id=NEW.debit_item_id;
  SELECT COALESCE(sum(allocation.allocated_amount),0) INTO v_credit_used
  FROM public.ar_open_item_allocations allocation
  WHERE allocation.company_id=NEW.company_id
    AND allocation.credit_item_id=NEW.credit_item_id;
  IF v_debit_used+NEW.allocated_amount>v_debit.original_amount
    OR v_credit_used+NEW.allocated_amount>v_credit.original_amount THEN
    RAISE EXCEPTION 'AR_OPEN_ITEM_ALLOCATION_EXCEEDS_RESIDUAL';
  END IF;
  RETURN NEW;
END
$$;

CREATE FUNCTION private.ar3_register_backoffice_invoice_open_item(
  p_company_id uuid,p_invoice_id uuid,p_actor_id uuid
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_invoice public.backoffice_sales_invoices%rowtype;
  v_event public.financial_events%rowtype;v_journal_id uuid;
  v_journal_line_id uuid;v_account uuid;v_item uuid;
  v_count bigint;
BEGIN
  SELECT * INTO v_invoice FROM public.backoffice_sales_invoices invoice
  WHERE invoice.company_id=p_company_id AND invoice.id=p_invoice_id
    AND invoice.status='POSTED' FOR SHARE;
  IF NOT FOUND OR v_invoice.grand_total<=0 THEN RETURN NULL; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.company_sales_process_settings setting
    WHERE setting.company_id=p_company_id
      AND setting.active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE') THEN
    RETURN NULL;
  END IF;
  SELECT item.id INTO v_item FROM public.ar_open_item_registry item
  WHERE item.company_id=p_company_id AND item.scope_kind='BACKOFFICE'
    AND item.item_kind='INVOICE' AND item.source_id=p_invoice_id;
  IF FOUND THEN
    PERFORM 1 FROM public.ar_open_item_registry item
    WHERE item.company_id=p_company_id AND item.id=v_item
      AND item.customer_id=v_invoice.customer_id AND item.direction='DEBIT'
      AND item.original_amount=v_invoice.grand_total
      AND item.document_no=v_invoice.invoice_no;
    IF NOT FOUND THEN RAISE EXCEPTION 'AR_OPEN_ITEM_INVOICE_IDENTITY_CONFLICT'; END IF;
    RETURN v_item;
  END IF;
  SELECT * INTO STRICT v_event FROM public.financial_events event
  WHERE event.company_id=p_company_id AND event.id=v_invoice.financial_event_id
    AND event.status='POSTED'::public.event_status;
  v_account:=private.resolve_financial_event_account(v_event,'CUSTOMER_RECEIVABLE');
  SELECT count(*) INTO v_count FROM public.finance_journals journal
  JOIN public.finance_journal_lines line ON line.company_id=journal.company_id
    AND line.journal_id=journal.id
  WHERE journal.company_id=p_company_id
    AND journal.financial_event_id=v_invoice.financial_event_id
    AND journal.status='POSTED' AND line.account_id=v_account
    AND line.customer_id=v_invoice.customer_id
    AND line.debit=v_invoice.grand_total AND line.credit=0;
  IF v_count<>1 THEN RAISE EXCEPTION 'AR_OPEN_ITEM_INVOICE_JOURNAL_LINE_INVALID'; END IF;
  SELECT journal.id,line.id INTO STRICT v_journal_id,v_journal_line_id
  FROM public.finance_journals journal
  JOIN public.finance_journal_lines line ON line.company_id=journal.company_id
    AND line.journal_id=journal.id
  WHERE journal.company_id=p_company_id
    AND journal.financial_event_id=v_invoice.financial_event_id
    AND journal.status='POSTED' AND line.account_id=v_account
    AND line.customer_id=v_invoice.customer_id
    AND line.debit=v_invoice.grand_total AND line.credit=0;
  INSERT INTO public.ar_open_item_registry(company_id,item_kind,source_id,
    financial_event_id,journal_id,journal_line_id,customer_id,account_id,direction,
    document_no,document_date,original_amount,source_snapshot,created_by)
  VALUES(p_company_id,'INVOICE',v_invoice.id,v_invoice.financial_event_id,
    v_journal_id,v_journal_line_id,v_invoice.customer_id,v_account,'DEBIT',
    v_invoice.invoice_no,v_invoice.invoice_date,v_invoice.grand_total,
    jsonb_build_object('sourceTable','backoffice_sales_invoices',
      'invoiceType',v_invoice.invoice_type,'masterVersion',v_invoice.master_version,
      'runtime','TASK3'),COALESCE(p_actor_id,v_invoice.posted_by,v_invoice.created_by))
  RETURNING id INTO v_item;
  RETURN v_item;
END
$$;

CREATE FUNCTION private.ar3_register_backoffice_receipt_open_item(
  p_company_id uuid,p_document_id uuid,p_actor_id uuid
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_receipt public.customer_receipt_documents%rowtype;
  v_journal_id uuid;v_journal_line_id uuid;
  v_item uuid;v_operation uuid;v_operation_key text;v_hash text;
  v_backoffice numeric(24,4);v_retail numeric(24,4);v_item_amount numeric(24,4);
  v_missing bigint;v_count bigint;v_snapshot jsonb;
BEGIN
  SELECT * INTO v_receipt FROM public.customer_receipt_documents receipt
  WHERE receipt.company_id=p_company_id AND receipt.id=p_document_id
    AND receipt.status='POSTED' FOR SHARE;
  IF NOT FOUND THEN RETURN NULL; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.company_sales_process_settings setting
    WHERE setting.company_id=p_company_id
      AND setting.active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE') THEN
    RETURN NULL;
  END IF;
  SELECT round(COALESCE(sum(allocation.allocated_amount),0),4)
    INTO v_backoffice
  FROM public.customer_receipt_backoffice_invoice_allocations allocation
  WHERE allocation.company_id=p_company_id AND allocation.document_id=p_document_id;
  SELECT round(COALESCE(sum(allocation.allocated_amount),0),4) INTO v_retail
  FROM public.customer_receipt_allocations allocation
  WHERE allocation.company_id=p_company_id AND allocation.document_id=p_document_id;
  IF v_backoffice<=0 THEN RETURN NULL; END IF;
  IF v_retail>0 THEN
    IF round(v_receipt.total_amount,4)<>v_backoffice+v_retail THEN
      RAISE EXCEPTION 'AR_OPEN_ITEM_MIXED_RECEIPT_TOTAL_INVALID';
    END IF;
    v_item_amount:=v_backoffice;
  ELSE
    IF round(v_receipt.total_amount,4)<v_backoffice THEN
      RAISE EXCEPTION 'AR_OPEN_ITEM_RECEIPT_TOTAL_INVALID';
    END IF;
    v_item_amount:=round(v_receipt.total_amount,4);
  END IF;
  SELECT item.id INTO v_item FROM public.ar_open_item_registry item
  WHERE item.company_id=p_company_id AND item.scope_kind='BACKOFFICE'
    AND item.item_kind='RECEIPT' AND item.source_id=p_document_id;
  IF FOUND THEN
    PERFORM 1 FROM public.ar_open_item_registry item
    WHERE item.company_id=p_company_id AND item.id=v_item
      AND item.customer_id=v_receipt.customer_id AND item.direction='CREDIT'
      AND item.original_amount=v_item_amount AND item.document_no=v_receipt.receipt_no;
    IF NOT FOUND THEN RAISE EXCEPTION 'AR_OPEN_ITEM_RECEIPT_IDENTITY_CONFLICT'; END IF;
  ELSE
    SELECT count(*) INTO v_count FROM public.finance_journals journal
    JOIN public.finance_journal_lines line ON line.company_id=journal.company_id
      AND line.journal_id=journal.id
    WHERE journal.company_id=p_company_id
      AND journal.financial_event_id=v_receipt.financial_event_id
      AND journal.status='POSTED'
      AND line.account_id=v_receipt.receivable_account_id_snapshot
      AND line.customer_id=v_receipt.customer_id AND line.debit=0
      AND line.credit=v_receipt.total_amount;
    IF v_count<>1 THEN RAISE EXCEPTION 'AR_OPEN_ITEM_RECEIPT_JOURNAL_LINE_INVALID'; END IF;
    SELECT journal.id,line.id INTO STRICT v_journal_id,v_journal_line_id
    FROM public.finance_journals journal
    JOIN public.finance_journal_lines line ON line.company_id=journal.company_id
      AND line.journal_id=journal.id
    WHERE journal.company_id=p_company_id
      AND journal.financial_event_id=v_receipt.financial_event_id
      AND journal.status='POSTED'
      AND line.account_id=v_receipt.receivable_account_id_snapshot
      AND line.customer_id=v_receipt.customer_id AND line.debit=0
      AND line.credit=v_receipt.total_amount;
    INSERT INTO public.ar_open_item_registry(company_id,item_kind,source_id,
      financial_event_id,journal_id,journal_line_id,customer_id,account_id,direction,
      document_no,document_date,original_amount,source_snapshot,created_by)
    VALUES(p_company_id,'RECEIPT',v_receipt.id,v_receipt.financial_event_id,
      v_journal_id,v_journal_line_id,v_receipt.customer_id,
      v_receipt.receivable_account_id_snapshot,'CREDIT',v_receipt.receipt_no,
      v_receipt.receipt_date,v_item_amount,
      jsonb_build_object('sourceTable','customer_receipt_documents',
        'backofficeSliceAmount',v_backoffice,'retailSliceAmount',v_retail,
        'receiptTotalAmount',v_receipt.total_amount,
        'masterVersion',v_receipt.master_version,'runtime','TASK3'),
      COALESCE(p_actor_id,v_receipt.posted_by,v_receipt.created_by))
    RETURNING id INTO v_item;
  END IF;
  SELECT count(*) INTO v_missing
  FROM public.customer_receipt_backoffice_invoice_allocations source
  LEFT JOIN public.ar_open_item_allocations target
    ON target.company_id=source.company_id
    AND target.source_kind='RECEIPT_ALLOCATION' AND target.source_id=source.id
  WHERE source.company_id=p_company_id AND source.document_id=p_document_id
    AND target.id IS NULL;
  IF v_missing=0 THEN RETURN v_item; END IF;
  SELECT md5(concat_ws('|',p_company_id,p_document_id,v_receipt.total_amount,
    string_agg(source.id::text||':'||source.allocated_amount::text,','
      ORDER BY source.id))) INTO v_hash
  FROM public.customer_receipt_backoffice_invoice_allocations source
  WHERE source.company_id=p_company_id AND source.document_id=p_document_id;
  v_operation_key:='POST_RECEIPT|'||p_document_id;
  v_snapshot:=jsonb_build_object('sourceTable','customer_receipt_documents',
    'sourceId',p_document_id,'receiptTotalAmount',v_receipt.total_amount,
    'backofficeSliceAmount',v_backoffice,'retailSliceAmount',v_retail);
  SELECT operation.id INTO v_operation FROM public.ar_open_item_operations operation
  WHERE operation.company_id=p_company_id
    AND operation.idempotency_key=v_operation_key FOR SHARE;
  IF FOUND THEN
    PERFORM 1 FROM public.ar_open_item_operations operation
    WHERE operation.company_id=p_company_id AND operation.id=v_operation
      AND operation.operation_kind='POST_RECEIPT' AND operation.request_hash=v_hash;
    IF NOT FOUND THEN RAISE EXCEPTION 'AR_OPEN_ITEM_OPERATION_IDEMPOTENCY_CONFLICT'; END IF;
  ELSE
    INSERT INTO public.ar_open_item_operations(company_id,operation_kind,
      idempotency_key,request_hash,actor_id,operation_snapshot)
    VALUES(p_company_id,'POST_RECEIPT',v_operation_key,v_hash,
      COALESCE(p_actor_id,v_receipt.posted_by,v_receipt.created_by),v_snapshot)
    RETURNING id INTO v_operation;
  END IF;
  INSERT INTO public.ar_open_item_allocations(company_id,operation_id,
    debit_item_id,credit_item_id,allocated_amount,source_kind,source_id,created_by)
  SELECT source.company_id,v_operation,debit.id,v_item,source.allocated_amount,
    'RECEIPT_ALLOCATION',source.id,
    COALESCE(p_actor_id,v_receipt.posted_by,v_receipt.created_by)
  FROM public.customer_receipt_backoffice_invoice_allocations source
  JOIN public.ar_open_item_registry debit ON debit.company_id=source.company_id
    AND debit.scope_kind='BACKOFFICE' AND debit.item_kind='INVOICE'
    AND debit.source_id=source.invoice_id
  LEFT JOIN public.ar_open_item_allocations existing
    ON existing.company_id=source.company_id
    AND existing.source_kind='RECEIPT_ALLOCATION' AND existing.source_id=source.id
  WHERE source.company_id=p_company_id AND source.document_id=p_document_id
    AND existing.id IS NULL ORDER BY source.invoice_id,source.id;
  IF EXISTS(SELECT 1 FROM public.customer_receipt_backoffice_invoice_allocations source
    LEFT JOIN public.ar_open_item_allocations target
      ON target.company_id=source.company_id
      AND target.source_kind='RECEIPT_ALLOCATION' AND target.source_id=source.id
    WHERE source.company_id=p_company_id AND source.document_id=p_document_id
      AND target.id IS NULL) THEN
    RAISE EXCEPTION 'AR_OPEN_ITEM_RECEIPT_ALLOCATION_INCOMPLETE';
  END IF;
  RETURN v_item;
END
$$;

CREATE FUNCTION public.save_customer_receipt_open_credit_draft(
  p_document_id uuid,p_master_version bigint,p_customer_id uuid,p_receipt_date date,
  p_payment_method_id uuid,p_reference_no text,p_evidence_url text,p_notes text,
  p_received_amount numeric,p_allocations jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='15s' AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
  v_item jsonb;v_allocated numeric(20,4):=0;v_amount numeric(20,4);
  v_saved jsonb;v_document public.customer_receipt_documents%rowtype;v_before jsonb;
BEGIN
  IF jsonb_typeof(p_allocations)<>'array' OR jsonb_array_length(p_allocations)=0 THEN
    RAISE EXCEPTION 'CUSTOMER_RECEIPT_ALLOCATION_REQUIRED';
  END IF;
  FOR v_item IN SELECT value FROM jsonb_array_elements(p_allocations) LOOP
    IF upper(NULLIF(btrim(v_item->>'sourceType'),''))<>'BACKOFFICE_SALES_INVOICE' THEN
      RAISE EXCEPTION 'CUSTOMER_RECEIPT_OPEN_CREDIT_BACKOFFICE_ONLY';
    END IF;
    BEGIN v_amount:=round((v_item->>'allocatedAmount')::numeric,4);
    EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'CUSTOMER_RECEIPT_ALLOCATION_INVALID'; END;
    IF v_amount<=0 THEN RAISE EXCEPTION 'CUSTOMER_RECEIPT_ALLOCATION_INVALID'; END IF;
    v_allocated:=v_allocated+v_amount;
  END LOOP;
  IF round(COALESCE(p_received_amount,0),4)<=v_allocated THEN
    RAISE EXCEPTION 'CUSTOMER_RECEIPT_OPEN_CREDIT_AMOUNT_INVALID';
  END IF;
  v_saved:=public.save_customer_receipt_allocated_draft(p_document_id,p_master_version,
    p_customer_id,p_receipt_date,p_payment_method_id,p_reference_no,p_evidence_url,
    p_notes,v_allocated,p_allocations);
  SELECT * INTO v_document FROM public.customer_receipt_documents document
  WHERE document.company_id=v_company AND document.id=(v_saved->>'documentId')::uuid
    AND document.status='DRAFT' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'CUSTOMER_RECEIPT_NOT_FOUND'; END IF;
  v_before:=to_jsonb(v_document);
  UPDATE public.customer_receipt_documents SET
    total_amount=round(p_received_amount,4),received_amount=round(p_received_amount,4),
    updated_at=clock_timestamp()
  WHERE company_id=v_company AND id=v_document.id RETURNING * INTO v_document;
  INSERT INTO public.customer_receipt_audit(company_id,document_id,action,actor_id,
    before_state,after_state) VALUES(v_company,v_document.id,'UPDATE',v_actor,
      v_before,to_jsonb(v_document));
  RETURN jsonb_build_object('documentId',v_document.id,'receiptNo',v_document.receipt_no,
    'status',v_document.status,'totalAmount',v_document.total_amount,
    'receivedAmount',v_document.received_amount,'allocatedAmount',v_allocated,
    'openCreditAmount',v_document.total_amount-v_allocated,
    'unappliedDisposition','NONE','masterVersion',v_document.master_version);
END
$$;

CREATE FUNCTION private.ar3_post_customer_receipt_financial_event_core(
  p_company_id uuid,p_event_id uuid,p_expected_event_version bigint,p_actor_id uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_event public.financial_events%rowtype;
  v_document public.customer_receipt_documents%rowtype;
  v_period public.accounting_periods%rowtype;v_journal public.finance_journals%rowtype;
  v_receipt_account public.chart_of_accounts%rowtype;
  v_ar_account public.chart_of_accounts%rowtype;v_accounting_date date;
  v_journal_type text:='AUTOMATIC';v_backoffice numeric(20,4);
  v_retail numeric(20,4);v_amount numeric(20,4);v_now timestamptz:=clock_timestamp();
BEGIN
  IF p_actor_id IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  SELECT * INTO v_event FROM public.financial_events event
  WHERE event.company_id=p_company_id AND event.id=p_event_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'FINANCIAL_EVENT_NOT_FOUND'; END IF;
  IF p_expected_event_version IS DISTINCT FROM v_event.event_version THEN
    RAISE EXCEPTION 'EVENT_VERSION_CONFLICT';
  END IF;
  IF v_event.status::text='POSTED' THEN
    SELECT * INTO STRICT v_journal FROM public.finance_journals journal
    WHERE journal.company_id=p_company_id AND journal.financial_event_id=v_event.id
      AND journal.status='POSTED';
    RETURN jsonb_build_object('financialEventId',v_event.id,'journalId',v_journal.id,
      'journalNo',v_journal.journal_no,'status','POSTED','idempotentReplay',true);
  END IF;
  IF v_event.status::text<>'HOLD' OR v_event.system_event_key<>'SALE_PAYMENT'
    OR v_event.event_type::text<>'PAYMENT_RECEIVED'
    OR v_event.source_table<>'customer_receipt_documents' THEN
    RAISE EXCEPTION 'UNSUPPORTED_FINANCIAL_EVENT_CONTRACT';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(
    'G6_FINANCIAL_EVENT|'||p_company_id||'|'||p_event_id,0));
  IF EXISTS(SELECT 1 FROM public.finance_journals journal
    WHERE journal.company_id=p_company_id AND journal.financial_event_id=v_event.id) THEN
    RAISE EXCEPTION 'FINANCIAL_EVENT_JOURNAL_IDENTITY_CONFLICT';
  END IF;
  SELECT * INTO v_document FROM public.customer_receipt_documents document
  WHERE document.company_id=p_company_id AND document.id=v_event.source_id
    AND document.status='POSTED' AND document.financial_event_id=v_event.id FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'FINANCIAL_EVENT_SOURCE_NOT_FINAL'; END IF;
  SELECT round(COALESCE(sum(allocation.allocated_amount),0),4) INTO v_backoffice
  FROM public.customer_receipt_backoffice_invoice_allocations allocation
  WHERE allocation.company_id=p_company_id AND allocation.document_id=v_document.id;
  SELECT round(COALESCE(sum(allocation.allocated_amount),0),4) INTO v_retail
  FROM public.customer_receipt_allocations allocation
  WHERE allocation.company_id=p_company_id AND allocation.document_id=v_document.id;
  v_amount:=round(v_document.total_amount,4);
  IF v_amount<=0 OR v_backoffice<=0 OR v_retail<>0 OR v_amount<=v_backoffice
    OR v_amount<>round(v_document.received_amount,4)
    OR v_amount<>round((v_event.amounts->>'receiptAmount')::numeric,4)
    OR v_document.customer_id IS DISTINCT FROM NULLIF(v_event.amounts->>'customerId','')::uuid
    OR v_document.receipt_account_id_snapshot IS DISTINCT FROM NULLIF(v_event.amounts->>'receiptAccountId','')::uuid
    OR v_document.receivable_account_id_snapshot IS DISTINCT FROM NULLIF(v_event.amounts->>'receivableAccountId','')::uuid THEN
    RAISE EXCEPTION 'FINANCIAL_EVENT_AMOUNT_SOURCE_MISMATCH';
  END IF;
  SELECT * INTO v_receipt_account FROM public.chart_of_accounts account
  WHERE account.company_id=p_company_id AND account.id=v_document.receipt_account_id_snapshot
    AND account.is_active AND account.is_postable;
  IF NOT FOUND THEN RAISE EXCEPTION 'EVENT_ACCOUNT_SNAPSHOT_INVALID'; END IF;
  SELECT * INTO v_ar_account FROM public.chart_of_accounts account
  WHERE account.company_id=p_company_id AND account.id=v_document.receivable_account_id_snapshot
    AND account.is_active AND account.is_postable;
  IF NOT FOUND THEN RAISE EXCEPTION 'EVENT_ACCOUNT_SNAPSHOT_INVALID'; END IF;
  SELECT * INTO v_period FROM public.accounting_periods period
  WHERE period.company_id=p_company_id
    AND v_event.event_date::date BETWEEN period.start_date AND period.end_date
    AND period.status IN('OPEN','REOPENED') ORDER BY period.start_date LIMIT 1 FOR SHARE;
  IF NOT FOUND THEN
    SELECT * INTO v_period FROM public.accounting_periods period
    WHERE period.company_id=p_company_id AND period.start_date>v_event.event_date::date
      AND period.status IN('OPEN','REOPENED') ORDER BY period.start_date LIMIT 1 FOR SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION 'POSTABLE_ACCOUNTING_PERIOD_NOT_FOUND'; END IF;
    v_journal_type:='PRIOR_PERIOD_ADJUSTMENT';v_accounting_date:=v_period.start_date;
  ELSE v_accounting_date:=v_event.event_date::date; END IF;
  INSERT INTO public.finance_journals(company_id,journal_no,journal_type,
    accounting_period_id,accounting_date,original_event_date,source_type,source_id,
    source_version,financial_event_id,idempotency_key,system_event_key,
    transaction_category_id,transaction_rule_version,description,status,created_by)
  VALUES(p_company_id,'G6-'||replace(v_event.id::text,'-',''),v_journal_type,
    v_period.id,v_accounting_date,v_event.event_date::date,v_event.source_table,
    v_event.source_id,v_event.event_version,v_event.id,
    'G6_EVENT|'||p_company_id||'|'||v_event.id||'|'||v_event.event_version,
    v_event.system_event_key,v_event.transaction_category_id,20261105110000,
    'Penerimaan Customer: '||v_document.receipt_no,'DRAFT',p_actor_id)
  RETURNING * INTO v_journal;
  INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,account_id,
    debit,credit,customer_id,description) VALUES
    (p_company_id,v_journal.id,1,v_receipt_account.id,v_amount,0,v_document.customer_id,
      'PENERIMAAN_CUSTOMER_'||v_document.settlement_route_snapshot),
    (p_company_id,v_journal.id,2,v_ar_account.id,0,v_amount,v_document.customer_id,
      'PELUNASAN_DAN_OPEN_CREDIT_CUSTOMER');
  UPDATE public.finance_journals SET status='POSTED',posted_by=p_actor_id,posted_at=v_now
  WHERE company_id=p_company_id AND id=v_journal.id RETURNING * INTO v_journal;
  UPDATE public.financial_events SET status='POSTED'::public.event_status,
    processed_at=v_now,error_message=NULL,transaction_rule_version=20261105110000
  WHERE company_id=p_company_id AND id=v_event.id;
  RETURN jsonb_build_object('financialEventId',v_event.id,'journalId',v_journal.id,
    'journalNo',v_journal.journal_no,'status','POSTED','idempotentReplay',false);
END
$$;

CREATE FUNCTION private.ar3_post_customer_receipt_open_credit_core(
  p_document_id uuid,p_master_version bigint,p_idempotency_key uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='20s' AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
  v_document public.customer_receipt_documents%rowtype;v_allocation record;
  v_paid numeric(20,4);v_backoffice numeric(20,4);v_retail numeric(20,4);
  v_result jsonb;v_event public.financial_events%rowtype;v_posting jsonb;
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'finance.customer_receipts','POST');
  SELECT * INTO v_document FROM public.customer_receipt_documents document
  WHERE document.company_id=v_company AND document.id=p_document_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'CUSTOMER_RECEIPT_NOT_FOUND'; END IF;
  IF v_document.status='POSTED' AND v_document.posting_idempotency_key=p_idempotency_key THEN
    v_result:=private.f2_post_customer_receipt_hold_core(
      p_document_id,p_master_version,p_idempotency_key);
    SELECT * INTO STRICT v_event FROM public.financial_events event
    WHERE event.company_id=v_company AND event.id=(v_result->>'financialEventId')::uuid;
    v_posting:=private.ar3_post_customer_receipt_financial_event_core(
      v_company,v_event.id,v_event.event_version,v_actor);
    RETURN v_result||jsonb_build_object('journalId',v_posting->>'journalId',
      'journalNo',v_posting->>'journalNo','financeStatus',v_posting->>'status');
  END IF;
  IF v_document.status<>'DRAFT' OR v_document.unapplied_disposition<>'NONE' THEN
    RAISE EXCEPTION 'FINAL_CUSTOMER_RECEIPT_IMMUTABLE';
  END IF;
  IF p_master_version IS DISTINCT FROM v_document.master_version THEN
    RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
  END IF;
  IF p_idempotency_key IS NULL THEN RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED'; END IF;
  SELECT round(COALESCE(sum(allocated_amount),0),4) INTO v_backoffice
  FROM public.customer_receipt_backoffice_invoice_allocations
  WHERE company_id=v_company AND document_id=v_document.id;
  SELECT round(COALESCE(sum(allocated_amount),0),4) INTO v_retail
  FROM public.customer_receipt_allocations
  WHERE company_id=v_company AND document_id=v_document.id;
  IF v_backoffice<=0 OR v_retail<>0 OR round(v_document.total_amount,4)<=v_backoffice
    OR round(v_document.received_amount,4)<>round(v_document.total_amount,4) THEN
    RAISE EXCEPTION 'CUSTOMER_RECEIPT_OPEN_CREDIT_AMOUNT_INVALID';
  END IF;
  FOR v_allocation IN
    SELECT allocation.invoice_id,allocation.allocated_amount
    FROM public.customer_receipt_backoffice_invoice_allocations allocation
    WHERE allocation.company_id=v_company AND allocation.document_id=v_document.id
    ORDER BY allocation.invoice_id
  LOOP
    PERFORM 1 FROM public.backoffice_sales_invoices invoice
    WHERE invoice.company_id=v_company AND invoice.id=v_allocation.invoice_id
      AND invoice.status='POSTED' AND invoice.customer_id=v_document.customer_id
      AND invoice.invoice_date<=v_document.receipt_date FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_NOT_PAYMENT_ELIGIBLE'; END IF;
    SELECT COALESCE(sum(allocation.allocated_amount),0) INTO v_paid
    FROM public.customer_receipt_backoffice_invoice_allocations allocation
    JOIN public.customer_receipt_documents receipt
      ON receipt.company_id=allocation.company_id AND receipt.id=allocation.document_id
      AND receipt.status='POSTED'
    WHERE allocation.company_id=v_company AND allocation.invoice_id=v_allocation.invoice_id;
    IF v_allocation.allocated_amount>
      private.backoffice_invoice_receivable_before_receipts(
        v_company,v_allocation.invoice_id,v_document.receipt_date)-v_paid THEN
      RAISE EXCEPTION 'CUSTOMER_RECEIPT_OUTSTANDING_CHANGED';
    END IF;
  END LOOP;
  v_result:=private.f2_post_customer_receipt_hold_core(
    p_document_id,p_master_version,p_idempotency_key);
  SELECT * INTO STRICT v_event FROM public.financial_events event
  WHERE event.company_id=v_company AND event.id=(v_result->>'financialEventId')::uuid;
  v_posting:=private.ar3_post_customer_receipt_financial_event_core(
    v_company,v_event.id,v_event.event_version,v_actor);
  FOR v_allocation IN
    SELECT DISTINCT allocation.invoice_id
    FROM public.customer_receipt_backoffice_invoice_allocations allocation
    WHERE allocation.company_id=v_company AND allocation.document_id=v_document.id
    ORDER BY allocation.invoice_id
  LOOP
    PERFORM private.reconcile_backoffice_invoice_receivable_schedule(
      v_company,v_allocation.invoice_id);
  END LOOP;
  RETURN v_result||jsonb_build_object('journalId',v_posting->>'journalId',
    'journalNo',v_posting->>'journalNo','financeStatus',v_posting->>'status');
END
$$;

ALTER FUNCTION public.post_backoffice_sales_invoice(uuid,bigint,uuid)
  SET SCHEMA private;
ALTER FUNCTION private.post_backoffice_sales_invoice(uuid,bigint,uuid)
  RENAME TO ar3_post_backoffice_sales_invoice_core;

CREATE FUNCTION public.post_backoffice_sales_invoice(
  p_invoice_id uuid,p_expected_version bigint,p_operation_id uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='12s' AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
  v_result jsonb;
BEGIN
  v_result:=private.ar3_post_backoffice_sales_invoice_core(
    p_invoice_id,p_expected_version,p_operation_id);
  PERFORM private.ar3_register_backoffice_invoice_open_item(
    v_company,p_invoice_id,v_actor);
  RETURN v_result;
END
$$;

ALTER FUNCTION public.post_customer_receipt_allocated(uuid,bigint,uuid)
  SET SCHEMA private;
ALTER FUNCTION private.post_customer_receipt_allocated(uuid,bigint,uuid)
  RENAME TO ar3_post_customer_receipt_allocated_core;

CREATE FUNCTION public.post_customer_receipt_allocated(
  p_document_id uuid,p_master_version bigint,p_idempotency_key uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='20s' AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
  v_result jsonb;
BEGIN
  v_result:=private.ar3_post_customer_receipt_allocated_core(
    p_document_id,p_master_version,p_idempotency_key);
  PERFORM private.ar3_register_backoffice_receipt_open_item(
    v_company,p_document_id,v_actor);
  RETURN v_result;
END
$$;

ALTER FUNCTION public.post_customer_receipt_unified(uuid,bigint,uuid)
  SET SCHEMA private;
ALTER FUNCTION private.post_customer_receipt_unified(uuid,bigint,uuid)
  RENAME TO ar3_post_customer_receipt_unified_core;

CREATE FUNCTION public.post_customer_receipt_unified(
  p_document_id uuid,p_master_version bigint,p_idempotency_key uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='20s' AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
  v_document public.customer_receipt_documents%rowtype;v_allocated numeric(20,4);
  v_result jsonb;
BEGIN
  SELECT * INTO v_document FROM public.customer_receipt_documents document
  WHERE document.company_id=v_company AND document.id=p_document_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'CUSTOMER_RECEIPT_NOT_FOUND'; END IF;
  SELECT round(COALESCE((SELECT sum(allocated_amount)
      FROM public.customer_receipt_allocations
      WHERE company_id=v_company AND document_id=p_document_id),0)
    +COALESCE((SELECT sum(allocated_amount)
      FROM public.customer_receipt_backoffice_invoice_allocations
      WHERE company_id=v_company AND document_id=p_document_id),0),4)
  INTO v_allocated;
  IF v_document.unapplied_disposition='NONE'
      AND round(v_document.total_amount,4)>v_allocated THEN
    v_result:=private.ar3_post_customer_receipt_open_credit_core(
      p_document_id,p_master_version,p_idempotency_key);
  ELSE
    v_result:=private.ar3_post_customer_receipt_unified_core(
      p_document_id,p_master_version,p_idempotency_key);
  END IF;
  PERFORM private.ar3_register_backoffice_receipt_open_item(
    v_company,p_document_id,v_actor);
  RETURN v_result;
END
$$;

-- PostgreSQL binds function dependencies by OID. Recreate the Invoice payment
-- entry point after installing the public Receipt wrapper so it cannot retain a
-- dependency on the renamed private core and bypass open-item registration.
CREATE OR REPLACE FUNCTION public.register_backoffice_sales_invoice_payment(
  p_invoice_id uuid,p_operation_id uuid,p_receipt_date date,p_payment_method_id uuid,
  p_amount numeric,p_reference_no text,p_evidence_url text,p_notes text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='20s' AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
  v_invoice public.backoffice_sales_invoices%rowtype;v_operation record;
  v_request jsonb;v_saved jsonb;v_posted jsonb;v_response jsonb;v_receipt_id uuid;
  v_amount numeric(20,4):=round(COALESCE(p_amount,0),4);
BEGIN
  PERFORM private.acp_require_permission_capability(v_company,'sales.backoffice_orders','VIEW');
  PERFORM private.acp_require_permission_capability(v_company,'finance.customer_receipts','CREATE_DRAFT');
  PERFORM private.acp_require_permission_capability(v_company,'finance.customer_receipts','POST');
  IF p_operation_id IS NULL THEN RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED'; END IF;
  v_request:=jsonb_build_object('invoiceId',p_invoice_id,'receiptDate',p_receipt_date,
    'paymentMethodId',p_payment_method_id,'amount',v_amount,
    'referenceNo',NULLIF(btrim(p_reference_no),''),'evidenceUrl',NULLIF(btrim(p_evidence_url),''),
    'notes',NULLIF(btrim(p_notes),''));
  PERFORM pg_advisory_xact_lock(hashtextextended(
    'BACKOFFICE_INVOICE_PAYMENT|'||v_company||'|'||p_operation_id,0));
  SELECT * INTO v_operation FROM public.backoffice_sales_invoice_payment_operations operation
  WHERE operation.company_id=v_company AND operation.operation_id=p_operation_id;
  IF FOUND THEN
    IF v_operation.invoice_id IS DISTINCT FROM p_invoice_id
      OR v_operation.request_snapshot IS DISTINCT FROM v_request THEN
      RAISE EXCEPTION 'IDEMPOTENCY_PAYLOAD_CONFLICT';
    END IF;
    IF v_operation.response_snapshot IS NULL THEN
      RAISE EXCEPTION 'BACKOFFICE_INVOICE_PAYMENT_OPERATION_INCOMPLETE';
    END IF;
    RETURN v_operation.response_snapshot||jsonb_build_object('exactRetry',true);
  END IF;
  IF p_invoice_id IS NULL OR p_receipt_date IS NULL OR p_payment_method_id IS NULL
      OR v_amount<=0 THEN
    RAISE EXCEPTION 'BACKOFFICE_INVOICE_PAYMENT_REQUIRED_FIELD_INVALID';
  END IF;
  IF EXISTS(SELECT 1 FROM public.payment_methods method
    WHERE method.company_id=v_company AND method.id=p_payment_method_id
      AND method.is_active AND method.proof_mode='REQUIRED')
    AND NULLIF(btrim(p_evidence_url),'') IS NULL THEN
    RAISE EXCEPTION 'CUSTOMER_RECEIPT_EVIDENCE_REQUIRED';
  END IF;
  SELECT * INTO v_invoice FROM public.backoffice_sales_invoices invoice
  WHERE invoice.company_id=v_company AND invoice.id=p_invoice_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_NOT_FOUND'; END IF;
  IF v_invoice.status<>'POSTED' THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_NOT_PAYMENT_ELIGIBLE';
  END IF;
  INSERT INTO public.backoffice_sales_invoice_payment_operations(
    company_id,operation_id,invoice_id,actor_id,request_snapshot)
  VALUES(v_company,p_operation_id,p_invoice_id,v_actor,v_request);
  v_saved:=public.save_customer_receipt_allocated_draft(NULL,NULL,v_invoice.customer_id,
    p_receipt_date,p_payment_method_id,NULLIF(btrim(p_reference_no),''),
    NULLIF(btrim(p_evidence_url),''),NULLIF(btrim(p_notes),''),v_amount,
    jsonb_build_array(jsonb_build_object('sourceType','BACKOFFICE_SALES_INVOICE',
      'sourceId',p_invoice_id,'clientAllocationKey',p_operation_id,
      'allocatedAmount',v_amount)));
  v_receipt_id:=(v_saved->>'documentId')::uuid;
  v_posted:=public.post_customer_receipt_allocated(v_receipt_id,
    (v_saved->>'masterVersion')::bigint,p_operation_id);
  SELECT jsonb_build_object('payment',jsonb_build_object(
      'receiptId',receipt.id,'receiptNo',receipt.receipt_no,'status',receipt.status,
      'receiptDate',receipt.receipt_date,'amount',v_amount,
      'paymentMethodName',receipt.payment_method_name_snapshot,
      'referenceNo',receipt.reference_no,'postedAt',receipt.posted_at,
      'journalNo',v_posted->>'journalNo'),
    'paymentContext',public.get_backoffice_sales_invoice_payment_context(p_invoice_id),
    'exactRetry',false)
  INTO STRICT v_response
  FROM public.customer_receipt_documents receipt
  WHERE receipt.company_id=v_company AND receipt.id=v_receipt_id;
  UPDATE public.backoffice_sales_invoice_payment_operations
  SET receipt_id=v_receipt_id,response_snapshot=v_response,completed_at=clock_timestamp()
  WHERE company_id=v_company AND operation_id=p_operation_id;
  RETURN v_response;
END
$$;

-- Close any zero-row cutover delta atomically. The preflight proved zero, but
-- these loops protect the interval between preflight and migration execution.
DO $cutover$
DECLARE v_row record;
BEGIN
  FOR v_row IN
    SELECT invoice.company_id,invoice.id,
      COALESCE(invoice.posted_by,invoice.created_by) actor_id
    FROM public.backoffice_sales_invoices invoice
    JOIN public.company_sales_process_settings setting
      ON setting.company_id=invoice.company_id
      AND setting.active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE'
    LEFT JOIN public.ar_open_item_registry item ON item.company_id=invoice.company_id
      AND item.scope_kind='BACKOFFICE' AND item.item_kind='INVOICE'
      AND item.source_id=invoice.id
    WHERE invoice.status='POSTED' AND invoice.grand_total>0 AND item.id IS NULL
    ORDER BY invoice.company_id,invoice.id
  LOOP
    PERFORM private.ar3_register_backoffice_invoice_open_item(
      v_row.company_id,v_row.id,v_row.actor_id);
  END LOOP;
  FOR v_row IN
    SELECT DISTINCT receipt.company_id,receipt.id,
      COALESCE(receipt.posted_by,receipt.created_by) actor_id
    FROM public.customer_receipt_documents receipt
    JOIN public.company_sales_process_settings setting
      ON setting.company_id=receipt.company_id
      AND setting.active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE'
    JOIN public.customer_receipt_backoffice_invoice_allocations allocation
      ON allocation.company_id=receipt.company_id AND allocation.document_id=receipt.id
    LEFT JOIN public.ar_open_item_registry item ON item.company_id=receipt.company_id
      AND item.scope_kind='BACKOFFICE' AND item.item_kind='RECEIPT'
      AND item.source_id=receipt.id
    WHERE receipt.status='POSTED' AND item.id IS NULL
    ORDER BY receipt.company_id,receipt.id
  LOOP
    PERFORM private.ar3_register_backoffice_receipt_open_item(
      v_row.company_id,v_row.id,v_row.actor_id);
  END LOOP;
  IF EXISTS(SELECT 1 FROM public.backoffice_sales_invoices invoice
    JOIN public.company_sales_process_settings setting
      ON setting.company_id=invoice.company_id
      AND setting.active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE'
    LEFT JOIN public.ar_open_item_registry item ON item.company_id=invoice.company_id
      AND item.scope_kind='BACKOFFICE' AND item.item_kind='INVOICE'
      AND item.source_id=invoice.id
    WHERE invoice.status='POSTED' AND invoice.grand_total>0 AND item.id IS NULL)
    OR EXISTS(SELECT 1 FROM public.customer_receipt_documents receipt
      JOIN public.company_sales_process_settings setting
        ON setting.company_id=receipt.company_id
        AND setting.active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE'
      JOIN public.customer_receipt_backoffice_invoice_allocations allocation
        ON allocation.company_id=receipt.company_id AND allocation.document_id=receipt.id
      LEFT JOIN public.ar_open_item_registry item ON item.company_id=receipt.company_id
        AND item.scope_kind='BACKOFFICE' AND item.item_kind='RECEIPT'
        AND item.source_id=receipt.id
      WHERE receipt.status='POSTED' AND item.id IS NULL) THEN
    RAISE EXCEPTION 'MIGRATION_POSTCONDITION_FAILED: cutover delta remains';
  END IF;
END
$cutover$;

REVOKE ALL ON FUNCTION
  private.ar3_register_backoffice_invoice_open_item(uuid,uuid,uuid),
  private.ar3_register_backoffice_receipt_open_item(uuid,uuid,uuid),
  private.ar3_post_customer_receipt_financial_event_core(uuid,uuid,bigint,uuid),
  private.ar3_post_customer_receipt_open_credit_core(uuid,bigint,uuid),
  private.ar3_post_backoffice_sales_invoice_core(uuid,bigint,uuid),
  private.ar3_post_customer_receipt_allocated_core(uuid,bigint,uuid),
  private.ar3_post_customer_receipt_unified_core(uuid,bigint,uuid)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.ar3_register_backoffice_invoice_open_item(uuid,uuid,uuid),
  private.ar3_register_backoffice_receipt_open_item(uuid,uuid,uuid),
  private.ar3_post_customer_receipt_financial_event_core(uuid,uuid,bigint,uuid),
  private.ar3_post_customer_receipt_open_credit_core(uuid,bigint,uuid),
  private.ar3_post_backoffice_sales_invoice_core(uuid,bigint,uuid),
  private.ar3_post_customer_receipt_allocated_core(uuid,bigint,uuid),
  private.ar3_post_customer_receipt_unified_core(uuid,bigint,uuid)
  TO service_role;
REVOKE ALL ON FUNCTION
  public.save_customer_receipt_open_credit_draft(uuid,bigint,uuid,date,uuid,text,text,text,numeric,jsonb),
  public.post_backoffice_sales_invoice(uuid,bigint,uuid),
  public.post_customer_receipt_allocated(uuid,bigint,uuid),
  public.post_customer_receipt_unified(uuid,bigint,uuid)
  FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION
  public.save_customer_receipt_open_credit_draft(uuid,bigint,uuid,date,uuid,text,text,text,numeric,jsonb),
  public.post_backoffice_sales_invoice(uuid,bigint,uuid),
  public.post_customer_receipt_allocated(uuid,bigint,uuid),
  public.post_customer_receipt_unified(uuid,bigint,uuid)
  TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20261105110000','backoffice_ar_invoice_receipt_allocation_runtime',
  'Atomic Backoffice Invoice/Receipt open-item registration, canonical manual partial/full allocation, customer-scoped Receipt residual AR credit, and compatibility wrappers for Finance workspace plus Invoice payment modal; one Cash/Bank-to-AR Journal preserved; Retail/POS, Customer Balance, Return/Credit Note, Stock/FIFO unchanged');

NOTIFY pgrst,'reload schema';
COMMIT;
