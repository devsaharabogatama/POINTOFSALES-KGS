-- Backoffice Purchase Return canonical Stock/FIFO/AP/Credit/Finance posting.
-- Finance allocation policy: UNINVOICED_FIRST.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260919140000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Backoffice Purchase Return Draft runtime required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260919141000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260919141000';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF to_regprocedure('public.post_purchase_return(uuid,bigint,uuid)') IS NULL
    OR to_regprocedure('public.get_finance_supplier_payments()') IS NULL
    OR to_regprocedure('public.save_supplier_payment_draft(uuid,bigint,uuid,date,text,uuid,text,text,text,text,text,text,jsonb)') IS NULL
    OR to_regprocedure('public.validate_supplier_payment(uuid,bigint,uuid)') IS NULL
    OR to_regprocedure('private.g6_require_event_snapshot_account(public.financial_events,uuid,text,boolean)') IS NULL
    OR to_regprocedure('private.resolve_opening_stock_account(uuid,uuid,text,timestamp with time zone)') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical Stock/AP/Finance runtime drift';
  END IF;
  IF to_regclass('public.purchase_return_finance_allocations') IS NOT NULL
    OR to_regclass('public.supplier_return_credit_notes') IS NOT NULL
    OR to_regprocedure('public.post_backoffice_purchase_return(uuid,bigint,uuid)') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Backoffice Purchase Return Finance collision';
  END IF;
END
$guard$;

ALTER TABLE public.purchase_return_ap_adjustments
  DROP CONSTRAINT purchase_return_ap_route_check;
ALTER TABLE public.purchase_return_ap_adjustments
  ADD CONSTRAINT purchase_return_ap_route_check CHECK(adjustment_route IN(
    'AP_PROVISIONAL','SUPPLIER_CREDIT_PENDING','BACKOFFICE_UNINVOICED_FIRST'));

CREATE SEQUENCE private.supplier_return_credit_note_no_seq AS bigint START 1;
REVOKE ALL ON SEQUENCE private.supplier_return_credit_note_no_seq
FROM PUBLIC,anon,authenticated;
GRANT USAGE,SELECT ON SEQUENCE private.supplier_return_credit_note_no_seq
TO service_role;

CREATE TABLE public.supplier_return_credit_notes(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL,
  credit_note_no text NOT NULL,
  purchase_return_id uuid NOT NULL,
  supplier_id uuid NOT NULL,
  credit_note_date date NOT NULL,
  provisional_value numeric(20,4) NOT NULL DEFAULT 0,
  actual_value numeric(20,4) NOT NULL DEFAULT 0,
  recoverable_tax_value numeric(20,4) NOT NULL DEFAULT 0,
  nonrecoverable_tax_value numeric(20,4) NOT NULL DEFAULT 0,
  ap_final_reduction numeric(20,4) NOT NULL DEFAULT 0,
  supplier_refund_receivable numeric(20,4) NOT NULL DEFAULT 0,
  status text NOT NULL DEFAULT 'POSTED',
  financial_event_id uuid REFERENCES public.financial_events(id) ON DELETE RESTRICT,
  posted_by uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  posted_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT supplier_return_credit_note_company_id_id_unique UNIQUE(company_id,id),
  CONSTRAINT supplier_return_credit_note_no_unique UNIQUE(company_id,credit_note_no),
  CONSTRAINT supplier_return_credit_note_return_unique UNIQUE(company_id,purchase_return_id),
  CONSTRAINT fk_supplier_return_credit_note_return FOREIGN KEY(company_id,purchase_return_id)
    REFERENCES public.purchase_return_documents(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT fk_supplier_return_credit_note_supplier FOREIGN KEY(company_id,supplier_id)
    REFERENCES public.suppliers(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT supplier_return_credit_note_status_check CHECK(status='POSTED'),
  CONSTRAINT supplier_return_credit_note_values_check CHECK(
    provisional_value>=0 AND actual_value>=0 AND recoverable_tax_value>=0
    AND nonrecoverable_tax_value>=0 AND ap_final_reduction>=0
    AND supplier_refund_receivable>=0
    AND round(ap_final_reduction+supplier_refund_receivable,4)
      =round(actual_value+recoverable_tax_value+nonrecoverable_tax_value,4))
);

CREATE TABLE public.purchase_return_finance_allocations(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL,
  document_id uuid NOT NULL,
  return_line_id uuid NOT NULL,
  source_ap_provisional_id uuid NOT NULL,
  allocation_kind text NOT NULL,
  source_supplier_invoice_id uuid,
  source_supplier_invoice_allocation_id uuid,
  quantity_base numeric(24,6) NOT NULL,
  provisional_value numeric(20,4) NOT NULL,
  actual_value numeric(20,4) NOT NULL,
  recoverable_tax_value numeric(20,4) NOT NULL DEFAULT 0,
  nonrecoverable_tax_value numeric(20,4) NOT NULL DEFAULT 0,
  ap_provisional_reduction numeric(20,4) NOT NULL DEFAULT 0,
  ap_final_reduction numeric(20,4) NOT NULL DEFAULT 0,
  supplier_refund_receivable numeric(20,4) NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT purchase_return_finance_allocation_company_id_id_unique
    UNIQUE(company_id,id),
  CONSTRAINT fk_purchase_return_finance_document FOREIGN KEY(company_id,document_id)
    REFERENCES public.purchase_return_documents(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT fk_purchase_return_finance_line FOREIGN KEY(company_id,return_line_id)
    REFERENCES public.purchase_return_lines(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT fk_purchase_return_finance_provisional
    FOREIGN KEY(company_id,source_ap_provisional_id)
    REFERENCES public.goods_receipt_ap_provisionals(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT fk_purchase_return_finance_invoice
    FOREIGN KEY(company_id,source_supplier_invoice_id)
    REFERENCES public.supplier_invoice_documents(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT fk_purchase_return_finance_invoice_allocation
    FOREIGN KEY(company_id,source_supplier_invoice_allocation_id)
    REFERENCES public.supplier_invoice_allocations(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT purchase_return_finance_kind_check
    CHECK(allocation_kind IN('UNINVOICED','INVOICED')),
  CONSTRAINT purchase_return_finance_source_shape CHECK(
    (allocation_kind='UNINVOICED' AND source_supplier_invoice_id IS NULL
      AND source_supplier_invoice_allocation_id IS NULL)
    OR (allocation_kind='INVOICED' AND source_supplier_invoice_id IS NOT NULL
      AND source_supplier_invoice_allocation_id IS NOT NULL)),
  CONSTRAINT purchase_return_finance_value_check CHECK(
    quantity_base>0 AND provisional_value>=0 AND actual_value>=0
    AND recoverable_tax_value>=0 AND nonrecoverable_tax_value>=0
    AND ap_provisional_reduction>=0 AND ap_final_reduction>=0
    AND supplier_refund_receivable>=0
    AND round(ap_provisional_reduction+ap_final_reduction
      +supplier_refund_receivable,4)=round(actual_value
      +recoverable_tax_value+nonrecoverable_tax_value,4)),
  CONSTRAINT purchase_return_finance_uninvoiced_shape CHECK(
    allocation_kind<>'UNINVOICED' OR (
      actual_value=provisional_value AND recoverable_tax_value=0
      AND nonrecoverable_tax_value=0
      AND ap_provisional_reduction=provisional_value
      AND ap_final_reduction=0 AND supplier_refund_receivable=0))
);
CREATE INDEX idx_purchase_return_finance_source
  ON public.purchase_return_finance_allocations(
    company_id,source_ap_provisional_id,source_supplier_invoice_allocation_id);
CREATE INDEX idx_purchase_return_finance_invoice
  ON public.purchase_return_finance_allocations(
    company_id,source_supplier_invoice_id);

CREATE FUNCTION private.trg_purchase_return_finance_allocation_guard()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_status text;
BEGIN
  SELECT document.status INTO v_status
  FROM public.purchase_return_documents document
  WHERE document.company_id=COALESCE(NEW.company_id,OLD.company_id)
    AND document.id=COALESCE(NEW.document_id,OLD.document_id);
  IF TG_OP='INSERT' AND v_status='DRAFT' THEN RETURN NEW; END IF;
  RAISE EXCEPTION 'PURCHASE_RETURN_FINANCE_ALLOCATION_IMMUTABLE';
END
$$;

CREATE FUNCTION public.get_backoffice_purchase_return_finance()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'purchase.purchase_returns','VIEW');
  RETURN jsonb_build_object(
    'allocationPolicy','UNINVOICED_FIRST',
    'allocations',(SELECT COALESCE(jsonb_agg(to_jsonb(finance)
      ORDER BY finance.document_id,finance.return_line_id,finance.created_at,
        finance.id),'[]'::jsonb)
      FROM public.purchase_return_finance_allocations finance
      WHERE finance.company_id=v_company),
    'creditNotes',(SELECT COALESCE(jsonb_agg(to_jsonb(note)
      ORDER BY note.credit_note_date DESC,note.credit_note_no DESC),'[]'::jsonb)
      FROM public.supplier_return_credit_notes note
      WHERE note.company_id=v_company),
    'journals',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'documentId',document.id,'financialEventId',document.financial_event_id,
        'journalId',journal.id,'journalNo',journal.journal_no,
        'accountingDate',journal.accounting_date,'status',journal.status,
        'totalDebit',journal.total_debit,'totalCredit',journal.total_credit)
      ORDER BY journal.accounting_date DESC,journal.journal_no DESC),'[]'::jsonb)
      FROM public.purchase_return_documents document
      LEFT JOIN public.finance_journals journal
        ON journal.company_id=document.company_id
       AND journal.financial_event_id=document.financial_event_id
      WHERE document.company_id=v_company AND document.status='POSTED'));
END
$$;
CREATE TRIGGER purchase_return_finance_allocation_guard
BEFORE INSERT OR UPDATE OR DELETE ON public.purchase_return_finance_allocations
FOR EACH ROW EXECUTE FUNCTION private.trg_purchase_return_finance_allocation_guard();

CREATE FUNCTION private.trg_supplier_return_credit_note_immutable()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
  IF TG_OP='INSERT' THEN RETURN NEW; END IF;
  IF TG_OP='UPDATE' AND NEW.company_id=OLD.company_id AND NEW.id=OLD.id
    AND NEW.credit_note_no=OLD.credit_note_no
    AND NEW.purchase_return_id=OLD.purchase_return_id
    AND NEW.supplier_id=OLD.supplier_id AND NEW.credit_note_date=OLD.credit_note_date
    AND NEW.provisional_value=OLD.provisional_value
    AND NEW.actual_value=OLD.actual_value
    AND NEW.recoverable_tax_value=OLD.recoverable_tax_value
    AND NEW.nonrecoverable_tax_value=OLD.nonrecoverable_tax_value
    AND NEW.ap_final_reduction=OLD.ap_final_reduction
    AND NEW.supplier_refund_receivable=OLD.supplier_refund_receivable
    AND NEW.status=OLD.status AND NEW.posted_by=OLD.posted_by
    AND NEW.posted_at=OLD.posted_at AND NEW.created_at=OLD.created_at
    AND OLD.financial_event_id IS NULL AND NEW.financial_event_id IS NOT NULL
    THEN RETURN NEW; END IF;
  RAISE EXCEPTION 'SUPPLIER_RETURN_CREDIT_NOTE_IMMUTABLE';
END
$$;
CREATE TRIGGER supplier_return_credit_note_immutable
BEFORE UPDATE OR DELETE ON public.supplier_return_credit_notes
FOR EACH ROW EXECUTE FUNCTION private.trg_supplier_return_credit_note_immutable();

-- Keep POS behavior unchanged: partial-invoice blocking remains for POS Returns,
-- while Backoffice Returns use the new explicit finance allocation table.
CREATE OR REPLACE FUNCTION private.trg_g5_guard_partial_invoice_purchase_return()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_channel text;
BEGIN
  SELECT document.source_channel INTO v_channel
  FROM public.purchase_return_documents document
  WHERE document.company_id=NEW.company_id AND document.id=NEW.document_id;
  IF v_channel='BACKOFFICE' THEN RETURN NEW; END IF;
  IF EXISTS(SELECT 1 FROM public.supplier_invoice_allocations allocation
    JOIN public.supplier_invoice_documents document
      ON document.company_id=allocation.company_id
     AND document.id=allocation.document_id AND document.status='VALIDATED'
    JOIN public.goods_receipt_ap_provisionals provisional
      ON provisional.company_id=allocation.company_id
     AND provisional.id=allocation.source_ap_provisional_id
     AND provisional.status='OPEN'
    WHERE allocation.company_id=NEW.company_id
      AND allocation.source_ap_provisional_id=NEW.source_ap_provisional_id) THEN
    RAISE EXCEPTION 'PURCHASE_RETURN_AFTER_PARTIAL_INVOICE_REQUIRES_FINANCE_SPLIT';
  END IF;
  RETURN NEW;
END
$$;

-- Supplier Payment must consume the net Bill balance after posted Supplier
-- Credit Notes. Existing validated payments remain immutable.
ALTER FUNCTION public.save_supplier_payment_draft(
  uuid,bigint,uuid,date,text,uuid,text,text,text,text,text,text,jsonb)
  RENAME TO purchase_return_previous_save_supplier_payment_draft;
ALTER FUNCTION public.purchase_return_previous_save_supplier_payment_draft(
  uuid,bigint,uuid,date,text,uuid,text,text,text,text,text,text,jsonb)
  SET SCHEMA private;

CREATE FUNCTION public.save_supplier_payment_draft(
  p_document_id uuid,p_master_version bigint,p_supplier_id uuid,
  p_payment_date date,p_payment_method text,p_source_account_id uuid,
  p_supplier_bank_name text,p_supplier_bank_account_no text,
  p_supplier_bank_account_holder text,p_reference_no text,p_notes text,
  p_evidence_url text,p_allocations jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_input record;
  v_invoice public.supplier_invoice_documents%rowtype;v_paid numeric(20,4);
  v_credit numeric(20,4);v_amount numeric(20,4);
BEGIN
  IF p_allocations IS NULL OR jsonb_typeof(p_allocations)<>'array' THEN
    RAISE EXCEPTION 'SUPPLIER_PAYMENT_ALLOCATIONS_REQUIRED'; END IF;
  FOR v_input IN SELECT * FROM jsonb_to_recordset(p_allocations) AS input(
    "clientAllocationKey" uuid,"invoiceId" uuid,"allocatedAmount" numeric)
  LOOP
    IF v_input."clientAllocationKey" IS NULL THEN
      RAISE EXCEPTION 'CLIENT_ALLOCATION_KEY_REQUIRED'; END IF;
    IF v_input."invoiceId" IS NULL THEN
      RAISE EXCEPTION 'INVOICE_ID_REQUIRED'; END IF;
    IF COALESCE(v_input."allocatedAmount",0)<=0 THEN
      RAISE EXCEPTION 'SUPPLIER_PAYMENT_ALLOCATION_AMOUNT_INVALID'; END IF;
    SELECT * INTO v_invoice FROM public.supplier_invoice_documents invoice
    WHERE invoice.company_id=v_company AND invoice.id=v_input."invoiceId";
    IF NOT FOUND THEN RAISE EXCEPTION 'SUPPLIER_INVOICE_NOT_FOUND'; END IF;
    SELECT round(COALESCE(sum(allocation.allocated_amount),0),4) INTO v_paid
    FROM public.supplier_payment_allocations allocation
    JOIN public.supplier_payment_documents payment
      ON payment.company_id=allocation.company_id
     AND payment.id=allocation.document_id AND payment.status='VALIDATED'
    WHERE allocation.company_id=v_company AND allocation.invoice_id=v_invoice.id;
    SELECT round(COALESCE(sum(finance.ap_final_reduction),0),4) INTO v_credit
    FROM public.purchase_return_finance_allocations finance
    JOIN public.purchase_return_documents return_document
      ON return_document.company_id=finance.company_id
     AND return_document.id=finance.document_id AND return_document.status='POSTED'
    WHERE finance.company_id=v_company
      AND finance.source_supplier_invoice_id=v_invoice.id;
    v_amount:=round(COALESCE(v_input."allocatedAmount",0),4);
    IF v_paid+v_credit+v_amount>v_invoice.grand_total+0.01 THEN
      RAISE EXCEPTION 'SUPPLIER_PAYMENT_EXCEEDS_NET_INVOICE_BALANCE'; END IF;
  END LOOP;
  RETURN private.purchase_return_previous_save_supplier_payment_draft(
    p_document_id,p_master_version,p_supplier_id,p_payment_date,p_payment_method,
    p_source_account_id,p_supplier_bank_name,p_supplier_bank_account_no,
    p_supplier_bank_account_holder,p_reference_no,p_notes,p_evidence_url,p_allocations);
END
$$;

-- Recheck the same net Bill boundary while holding the Payment Draft row.
-- This closes the race where a valid Payment Draft was saved before a
-- Supplier Credit Note, then validated after the Return had reduced AP.
ALTER FUNCTION public.validate_supplier_payment(uuid,bigint,uuid)
  RENAME TO purchase_return_previous_validate_supplier_payment;
ALTER FUNCTION public.purchase_return_previous_validate_supplier_payment(
  uuid,bigint,uuid) SET SCHEMA private;

CREATE FUNCTION public.validate_supplier_payment(
  p_document_id uuid,p_master_version bigint,p_idempotency_key uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_allocation record;
  v_paid numeric(20,4);v_credit numeric(20,4);
BEGIN
  -- Lock the exact Draft before reading its allocations. The delegated
  -- canonical validator locks it again in the same transaction.
  PERFORM 1 FROM public.supplier_payment_documents payment
  WHERE payment.company_id=v_company AND payment.id=p_document_id
  FOR UPDATE;
  FOR v_allocation IN
    SELECT allocation.invoice_id,allocation.allocated_amount,invoice.grand_total
    FROM public.supplier_payment_allocations allocation
    JOIN public.supplier_payment_documents payment
      ON payment.company_id=allocation.company_id
     AND payment.id=allocation.document_id
    JOIN public.supplier_invoice_documents invoice
      ON invoice.company_id=allocation.company_id
     AND invoice.id=allocation.invoice_id
    WHERE allocation.company_id=v_company
      AND allocation.document_id=p_document_id
      AND payment.status='DRAFT'
    ORDER BY allocation.invoice_id,allocation.id
  LOOP
    PERFORM 1 FROM public.supplier_invoice_documents invoice
    WHERE invoice.company_id=v_company AND invoice.id=v_allocation.invoice_id
    FOR UPDATE;
    SELECT round(COALESCE(sum(allocation.allocated_amount),0),4) INTO v_paid
    FROM public.supplier_payment_allocations allocation
    JOIN public.supplier_payment_documents payment
      ON payment.company_id=allocation.company_id
     AND payment.id=allocation.document_id AND payment.status='VALIDATED'
    WHERE allocation.company_id=v_company
      AND allocation.invoice_id=v_allocation.invoice_id;
    SELECT round(COALESCE(sum(finance.ap_final_reduction),0),4) INTO v_credit
    FROM public.purchase_return_finance_allocations finance
    JOIN public.purchase_return_documents return_document
      ON return_document.company_id=finance.company_id
     AND return_document.id=finance.document_id
     AND return_document.status='POSTED'
    WHERE finance.company_id=v_company
      AND finance.source_supplier_invoice_id=v_allocation.invoice_id;
    IF v_paid+v_credit+v_allocation.allocated_amount>
        v_allocation.grand_total+0.01 THEN
      RAISE EXCEPTION 'SUPPLIER_PAYMENT_EXCEEDS_NET_INVOICE_BALANCE'; END IF;
  END LOOP;
  RETURN private.purchase_return_previous_validate_supplier_payment(
    p_document_id,p_master_version,p_idempotency_key);
END
$$;

CREATE OR REPLACE FUNCTION public.get_finance_supplier_payments()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_permission jsonb;
BEGIN
  v_permission:=private.acp_require_permission_capability(
    v_company,'finance.supplier_payments','VIEW');
  RETURN jsonb_build_object(
    'companyId',v_company,'currentUserId',auth.uid(),
    'effectiveCapabilities',COALESCE(v_permission->'effectiveCapabilities','[]'::jsonb),
    'documents',(SELECT COALESCE(jsonb_agg(to_jsonb(document)
      ORDER BY document.created_at DESC,document.id DESC),'[]'::jsonb)
      FROM (SELECT candidate.* FROM public.supplier_payment_documents candidate
        WHERE candidate.company_id=v_company ORDER BY candidate.created_at DESC,
          candidate.id DESC LIMIT 500) document),
    'allocations',(SELECT COALESCE(jsonb_agg(to_jsonb(allocation)
      ORDER BY allocation.document_id,allocation.created_at,allocation.id),'[]'::jsonb)
      FROM public.supplier_payment_allocations allocation
      WHERE allocation.company_id=v_company AND EXISTS(SELECT 1 FROM
        (SELECT candidate.id FROM public.supplier_payment_documents candidate
         WHERE candidate.company_id=v_company ORDER BY candidate.created_at DESC,
           candidate.id DESC LIMIT 500) document
        WHERE document.id=allocation.document_id)),
    'validatedInvoices',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',invoice.id,'invoice_no',invoice.invoice_no,
      'supplier_id',invoice.supplier_id,'supplier_invoice_no',invoice.supplier_invoice_no,
      'invoice_date',invoice.invoice_date,'due_date',invoice.due_date,
      'grand_total',invoice.grand_total,'status',invoice.status,
      'matching_status',invoice.matching_status,'created_at',invoice.created_at,
      'paid_amount',COALESCE(paid.amount,0),
      'supplier_credit_amount',COALESCE(credit.amount,0),
      'remaining_balance',GREATEST(invoice.grand_total-COALESCE(paid.amount,0)
        -COALESCE(credit.amount,0),0))
      ORDER BY invoice.created_at DESC,invoice.id DESC),'[]'::jsonb)
      FROM public.supplier_invoice_documents invoice
      LEFT JOIN LATERAL(SELECT sum(allocation.allocated_amount) amount
        FROM public.supplier_payment_allocations allocation
        JOIN public.supplier_payment_documents payment
          ON payment.company_id=allocation.company_id
         AND payment.id=allocation.document_id AND payment.status='VALIDATED'
        WHERE allocation.company_id=invoice.company_id
          AND allocation.invoice_id=invoice.id) paid ON TRUE
      LEFT JOIN LATERAL(SELECT sum(finance.ap_final_reduction) amount
        FROM public.purchase_return_finance_allocations finance
        JOIN public.purchase_return_documents return_document
          ON return_document.company_id=finance.company_id
         AND return_document.id=finance.document_id AND return_document.status='POSTED'
        WHERE finance.company_id=invoice.company_id
          AND finance.source_supplier_invoice_id=invoice.id) credit ON TRUE
      WHERE invoice.company_id=v_company AND invoice.status='VALIDATED'),
    'suppliers',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',supplier.id,'supplier_code',supplier.supplier_code,
      'supplier_name',supplier.supplier_name,'is_active',supplier.is_active,
      'bank_name',supplier.bank_name,
      'bank_account_number',supplier.bank_account_number,
      'bank_account_holder',supplier.bank_account_holder)
      ORDER BY supplier.supplier_name,supplier.id),'[]'::jsonb)
      FROM public.suppliers supplier WHERE supplier.company_id=v_company AND supplier.is_active),
    'accounts',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',account.id,'account_code',account.account_code,
      'account_name',account.account_name,'account_type',account.account_type,
      'is_active',account.is_active) ORDER BY account.account_code,account.id),'[]'::jsonb)
      FROM public.chart_of_accounts account WHERE account.company_id=v_company
        AND account.is_active AND account.is_postable AND account.account_type='ASSET'
        AND (private.acp6f_source_account_allowed(v_company,account.id,'CASH')
          OR private.acp6f_source_account_allowed(v_company,account.id,'BANK_TRANSFER'))),
    'profiles',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',profile.id,'full_name',profile.name,'username',profile.name)
      ORDER BY profile.name,profile.id),'[]'::jsonb)
      FROM public.profiles profile WHERE EXISTS(SELECT 1
        FROM public.supplier_payment_documents document
        WHERE document.company_id=v_company AND profile.id IN(
          document.created_by,document.validated_by,document.canceled_by)))
  );
END
$$;

CREATE FUNCTION public.post_backoffice_purchase_return(
  p_document_id uuid,p_master_version bigint,p_idempotency_key uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE
  v_actor uuid:=auth.uid();v_company uuid:=public.private_active_company_id();
  v_document public.purchase_return_documents%rowtype;
  v_line public.purchase_return_lines%rowtype;v_batch public.product_batches%rowtype;
  v_source_ap public.goods_receipt_ap_provisionals%rowtype;
  v_invoice_source record;v_prior_return numeric(24,6);v_prior_ap numeric(20,4);
  v_stock_after numeric(24,6);v_fifo_id uuid;v_category uuid;v_event uuid;
  v_version bigint;v_before jsonb;v_now timestamptz:=clock_timestamp();
  v_received_base numeric(24,6);v_billed_base numeric(24,6);
  v_prior_uninvoiced numeric(24,6);v_uninvoiced_qty numeric(24,6);
  v_remaining_qty numeric(24,6);v_available_qty numeric(24,6);v_alloc_qty numeric(24,6);
  v_provisional numeric(20,4);v_actual numeric(20,4);v_recoverable_tax numeric(20,4);
  v_nonrecoverable_tax numeric(20,4);v_gross numeric(20,4);v_invoice_outstanding numeric(20,4);
  v_ap_final numeric(20,4);v_refund_receivable numeric(20,4);
  v_inventory_total numeric(20,4):=0;v_ap_provisional_total numeric(20,4):=0;
  v_ap_final_total numeric(20,4):=0;v_refund_total numeric(20,4):=0;
  v_actual_total numeric(20,4):=0;v_recoverable_tax_total numeric(20,4):=0;
  v_nonrecoverable_tax_total numeric(20,4):=0;v_billed_provisional_total numeric(20,4):=0;
  v_variance_total numeric(20,4);v_inventory_account uuid;v_ap_provisional_account uuid;
  v_ap_final_account uuid;v_refund_account uuid;v_variance_account uuid;v_tax_account uuid;
  v_period public.accounting_periods%rowtype;v_journal public.finance_journals%rowtype;
  v_journal_line integer:=0;v_debit numeric(20,4):=0;v_credit numeric(20,4):=0;
  v_note uuid;v_note_no text;v_paid numeric(20,4);v_prior_credit numeric(20,4);
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF p_idempotency_key IS NULL THEN RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED'; END IF;
  PERFORM private.acp_require_permission_capability(
    v_company,'purchase.purchase_returns','POST');
  SELECT * INTO v_document FROM public.purchase_return_documents document
  WHERE document.company_id=v_company AND document.id=p_document_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'PURCHASE_RETURN_NOT_FOUND'; END IF;
  IF v_document.source_channel<>'BACKOFFICE' THEN
    RAISE EXCEPTION 'PURCHASE_RETURN_CHANNEL_INVALID'; END IF;
  IF v_document.status='POSTED' THEN
    IF v_document.posting_idempotency_key=p_idempotency_key THEN
      RETURN jsonb_build_object('documentId',v_document.id,
        'returnNo',v_document.return_no,'status','POSTED',
        'masterVersion',v_document.master_version,
        'financialEventId',v_document.financial_event_id,
        'idempotentReplay',true); END IF;
    RAISE EXCEPTION 'PURCHASE_RETURN_ALREADY_POSTED';
  END IF;
  IF v_document.status<>'DRAFT' OR v_document.review_status<>'APPROVED' THEN
    RAISE EXCEPTION 'APPROVED_PURCHASE_RETURN_REQUIRED'; END IF;
  IF p_master_version IS DISTINCT FROM v_document.master_version THEN
    RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
  IF NOT public.private_purchase_manager_allowed(v_company,v_document.store_id) THEN
    RAISE EXCEPTION 'PURCHASE_RETURN_APPROVER_REQUIRED'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.goods_receipt_documents receipt
    WHERE receipt.company_id=v_company AND receipt.id=v_document.source_receipt_id
      AND receipt.status='POSTED') THEN RAISE EXCEPTION 'POSTED_GOODS_RECEIPT_NOT_FOUND'; END IF;
  SELECT category.id INTO v_category FROM public.transaction_categories category
  WHERE category.company_id=v_company AND category.system_key='PURCHASE_RETURN'
    AND category.is_active ORDER BY category.id LIMIT 1;
  IF v_category IS NULL THEN RAISE EXCEPTION 'PURCHASE_RETURN_TRANSACTION_CATEGORY_NOT_FOUND'; END IF;
  v_before:=to_jsonb(v_document);

  FOR v_line IN SELECT * FROM public.purchase_return_lines return_line
    WHERE return_line.company_id=v_company AND return_line.document_id=v_document.id
    ORDER BY return_line.product_id,return_line.id
  LOOP
    PERFORM pg_advisory_xact_lock(hashtextextended(v_company::text||':STOCK:'
      ||v_line.product_id::text||':'||v_document.source_warehouse_id::text,0));
    PERFORM 1 FROM public.goods_receipt_condition_allocations allocation
    WHERE allocation.company_id=v_company
      AND allocation.id=v_line.source_condition_allocation_id FOR UPDATE;
    SELECT COALESCE(sum(return_line.return_base_qty),0) INTO v_prior_return
    FROM public.purchase_return_lines return_line
    JOIN public.purchase_return_documents return_document
      ON return_document.company_id=return_line.company_id
     AND return_document.id=return_line.document_id
     AND return_document.status='POSTED'
    WHERE return_line.company_id=v_company
      AND return_line.source_condition_allocation_id=v_line.source_condition_allocation_id;
    IF v_prior_return+v_line.return_base_qty>(SELECT allocation.quantity_base
      FROM public.goods_receipt_condition_allocations allocation
      WHERE allocation.company_id=v_company
        AND allocation.id=v_line.source_condition_allocation_id) THEN
      RAISE EXCEPTION 'PURCHASE_RETURN_QUANTITY_CHANGED_DURING_POST'; END IF;
    SELECT * INTO v_batch FROM public.product_batches batch
    WHERE batch.company_id=v_company AND batch.id=v_line.source_product_batch_id
      AND batch.product_id=v_line.product_id
      AND batch.warehouse_id=v_document.source_warehouse_id FOR UPDATE;
    IF NOT FOUND OR v_batch.qty_remaining<v_line.return_base_qty THEN
      RAISE EXCEPTION 'PURCHASE_RETURN_FIFO_NOT_AVAILABLE'; END IF;
    UPDATE public.product_batches SET qty_remaining=qty_remaining-v_line.return_base_qty
    WHERE company_id=v_company AND id=v_batch.id;
    UPDATE public.product_stocks SET stock_qty=stock_qty-v_line.return_base_qty,
      updated_at=v_now WHERE company_id=v_company AND product_id=v_line.product_id
      AND warehouse_id=v_document.source_warehouse_id
      AND stock_qty>=v_line.return_base_qty RETURNING stock_qty INTO v_stock_after;
    IF NOT FOUND THEN RAISE EXCEPTION 'PURCHASE_RETURN_STOCK_NOT_AVAILABLE'; END IF;
    INSERT INTO public.purchase_return_fifo_allocations(company_id,document_id,
      return_line_id,source_product_batch_id,product_id,warehouse_id,
      quantity_base,fifo_unit_cost,fifo_cost_total)
    VALUES(v_company,v_document.id,v_line.id,v_batch.id,v_line.product_id,
      v_document.source_warehouse_id,v_line.return_base_qty,v_batch.cogs_unit,
      round(v_line.return_base_qty*v_batch.cogs_unit,4)) RETURNING id INTO v_fifo_id;
    INSERT INTO public.stock_movements(product_id,warehouse_id,qty_change,
      movement_type,reference_table,reference_id,company_id,base_uom_id,
      base_uom_name_snapshot,balance_after_base_qty,actor_id,posted_at,
      movement_status,source_line_id,notes)
    VALUES(v_line.product_id,v_document.source_warehouse_id,-v_line.return_base_qty,
      'PURCHASE_RETURN'::public.stock_movement_type,'purchase_return_documents',
      v_document.id,v_company,v_line.base_uom_id,v_line.base_uom_name_snapshot,
      v_stock_after,v_actor,v_now,'POSTED',v_fifo_id,
      'Backoffice Supplier Return from exact Goods Receipt FIFO');
    v_inventory_total:=v_inventory_total+round(v_line.return_base_qty*v_batch.cogs_unit,4);

    SELECT * INTO v_source_ap FROM public.goods_receipt_ap_provisionals provisional
    WHERE provisional.company_id=v_company
      AND provisional.receipt_line_id=v_line.source_receipt_line_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'SOURCE_AP_PROVISIONAL_NOT_FOUND'; END IF;
    SELECT COALESCE(sum(adjustment.amount),0) INTO v_prior_ap
    FROM public.purchase_return_ap_adjustments adjustment
    JOIN public.purchase_return_documents return_document
      ON return_document.company_id=adjustment.company_id
     AND return_document.id=adjustment.document_id
     AND return_document.status='POSTED'
    WHERE adjustment.company_id=v_company
      AND adjustment.source_ap_provisional_id=v_source_ap.id;
    IF v_prior_ap+v_line.provisional_return_value>v_source_ap.amount+0.01 THEN
      RAISE EXCEPTION 'PURCHASE_RETURN_AP_ADJUSTMENT_EXCEEDS_SOURCE'; END IF;
    INSERT INTO public.purchase_return_ap_adjustments(company_id,document_id,
      return_line_id,source_ap_provisional_id,supplier_id,adjustment_route,
      amount,status)
    VALUES(v_company,v_document.id,v_line.id,v_source_ap.id,
      v_document.supplier_id,'BACKOFFICE_UNINVOICED_FIRST',
      v_line.provisional_return_value,'POSTED');

    SELECT receipt_line.accepted_good_base_qty+receipt_line.damaged_base_qty
      INTO v_received_base FROM public.goods_receipt_lines receipt_line
    WHERE receipt_line.company_id=v_company AND receipt_line.id=v_line.source_receipt_line_id;
    SELECT COALESCE(sum(allocation.allocated_base_qty),0) INTO v_billed_base
    FROM public.supplier_invoice_allocations allocation
    JOIN public.supplier_invoice_documents invoice
      ON invoice.company_id=allocation.company_id
     AND invoice.id=allocation.document_id AND invoice.status='VALIDATED'
    WHERE allocation.company_id=v_company
      AND allocation.source_ap_provisional_id=v_source_ap.id;
    SELECT COALESCE(sum(finance.quantity_base),0) INTO v_prior_uninvoiced
    FROM public.purchase_return_finance_allocations finance
    JOIN public.purchase_return_documents return_document
      ON return_document.company_id=finance.company_id
     AND return_document.id=finance.document_id
     AND return_document.status='POSTED'
    WHERE finance.company_id=v_company
      AND finance.source_ap_provisional_id=v_source_ap.id
      AND finance.allocation_kind='UNINVOICED';
    v_uninvoiced_qty:=LEAST(v_line.return_base_qty,
      GREATEST(v_received_base-v_billed_base-v_prior_uninvoiced,0));
    IF v_uninvoiced_qty>0 THEN
      v_provisional:=round(v_uninvoiced_qty
        *v_line.provisional_base_unit_cost_snapshot,4);
      INSERT INTO public.purchase_return_finance_allocations(company_id,
        document_id,return_line_id,source_ap_provisional_id,allocation_kind,
        quantity_base,provisional_value,actual_value,ap_provisional_reduction)
      VALUES(v_company,v_document.id,v_line.id,v_source_ap.id,'UNINVOICED',
        v_uninvoiced_qty,v_provisional,v_provisional,v_provisional);
      v_ap_provisional_total:=v_ap_provisional_total+v_provisional;
    END IF;
    v_remaining_qty:=v_line.return_base_qty-v_uninvoiced_qty;
    FOR v_invoice_source IN
      SELECT allocation.*,invoice.invoice_date,invoice.grand_total,
        invoice_line.tax_amount,invoice_line.tax_is_recoverable_snapshot,
        COALESCE((SELECT sum(peer.actual_value)
          FROM public.supplier_invoice_allocations peer
          WHERE peer.company_id=allocation.company_id
            AND peer.invoice_line_id=allocation.invoice_line_id),0) line_actual_total
      FROM public.supplier_invoice_allocations allocation
      JOIN public.supplier_invoice_documents invoice
        ON invoice.company_id=allocation.company_id
       AND invoice.id=allocation.document_id AND invoice.status='VALIDATED'
      JOIN public.supplier_invoice_lines invoice_line
        ON invoice_line.company_id=allocation.company_id
       AND invoice_line.id=allocation.invoice_line_id
      WHERE allocation.company_id=v_company
        AND allocation.source_ap_provisional_id=v_source_ap.id
      ORDER BY invoice.invoice_date,invoice.id,allocation.id
    LOOP
      EXIT WHEN v_remaining_qty<=0;
      -- Serialize Supplier Credit calculation with Supplier Payment validation.
      -- Both paths lock the same Invoice before deriving its net AP balance.
      PERFORM 1 FROM public.supplier_invoice_documents invoice
      WHERE invoice.company_id=v_company
        AND invoice.id=v_invoice_source.document_id
      FOR UPDATE;
      SELECT v_invoice_source.allocated_base_qty-COALESCE(sum(finance.quantity_base),0)
        INTO v_available_qty
      FROM public.purchase_return_finance_allocations finance
      JOIN public.purchase_return_documents return_document
        ON return_document.company_id=finance.company_id
       AND return_document.id=finance.document_id
       AND (return_document.status='POSTED' OR return_document.id=v_document.id)
      WHERE finance.company_id=v_company
        AND finance.source_supplier_invoice_allocation_id=v_invoice_source.id;
      v_available_qty:=COALESCE(v_available_qty,v_invoice_source.allocated_base_qty);
      v_alloc_qty:=LEAST(v_remaining_qty,GREATEST(v_available_qty,0));
      IF v_alloc_qty<=0 THEN CONTINUE; END IF;
      v_provisional:=round(v_alloc_qty*v_invoice_source.provisional_value
        /v_invoice_source.allocated_base_qty,4);
      v_actual:=round(v_alloc_qty*v_invoice_source.actual_value
        /v_invoice_source.allocated_base_qty,4);
      IF v_invoice_source.line_actual_total>0 THEN
        IF v_invoice_source.tax_is_recoverable_snapshot THEN
          v_recoverable_tax:=round(v_alloc_qty*v_invoice_source.tax_amount
            *v_invoice_source.actual_value/v_invoice_source.line_actual_total
            /v_invoice_source.allocated_base_qty,4);
          v_nonrecoverable_tax:=0;
        ELSE
          v_recoverable_tax:=0;
          v_nonrecoverable_tax:=round(v_alloc_qty*v_invoice_source.tax_amount
            *v_invoice_source.actual_value/v_invoice_source.line_actual_total
            /v_invoice_source.allocated_base_qty,4);
        END IF;
      ELSE v_recoverable_tax:=0;v_nonrecoverable_tax:=0; END IF;
      v_gross:=round(v_actual+v_recoverable_tax+v_nonrecoverable_tax,4);
      SELECT round(COALESCE(sum(allocation.allocated_amount),0),4) INTO v_paid
      FROM public.supplier_payment_allocations allocation
      JOIN public.supplier_payment_documents payment
        ON payment.company_id=allocation.company_id
       AND payment.id=allocation.document_id AND payment.status='VALIDATED'
      WHERE allocation.company_id=v_company
        AND allocation.invoice_id=v_invoice_source.document_id;
      SELECT round(COALESCE(sum(finance.actual_value+finance.recoverable_tax_value
        +finance.nonrecoverable_tax_value),0),4) INTO v_prior_credit
      FROM public.purchase_return_finance_allocations finance
      JOIN public.purchase_return_documents return_document
        ON return_document.company_id=finance.company_id
       AND return_document.id=finance.document_id
       AND (return_document.status='POSTED' OR return_document.id=v_document.id)
      WHERE finance.company_id=v_company
        AND finance.source_supplier_invoice_id=v_invoice_source.document_id;
      v_invoice_outstanding:=GREATEST(round(v_invoice_source.grand_total
        -v_paid-v_prior_credit,4),0);
      v_ap_final:=LEAST(v_gross,v_invoice_outstanding);
      v_refund_receivable:=v_gross-v_ap_final;
      INSERT INTO public.purchase_return_finance_allocations(company_id,
        document_id,return_line_id,source_ap_provisional_id,allocation_kind,
        source_supplier_invoice_id,source_supplier_invoice_allocation_id,
        quantity_base,provisional_value,actual_value,recoverable_tax_value,
        nonrecoverable_tax_value,ap_final_reduction,supplier_refund_receivable)
      VALUES(v_company,v_document.id,v_line.id,v_source_ap.id,'INVOICED',
        v_invoice_source.document_id,v_invoice_source.id,v_alloc_qty,v_provisional,
        v_actual,v_recoverable_tax,v_nonrecoverable_tax,v_ap_final,v_refund_receivable);
      v_billed_provisional_total:=v_billed_provisional_total+v_provisional;
      v_actual_total:=v_actual_total+v_actual;
      v_recoverable_tax_total:=v_recoverable_tax_total+v_recoverable_tax;
      v_nonrecoverable_tax_total:=v_nonrecoverable_tax_total+v_nonrecoverable_tax;
      v_ap_final_total:=v_ap_final_total+v_ap_final;
      v_refund_total:=v_refund_total+v_refund_receivable;
      v_remaining_qty:=v_remaining_qty-v_alloc_qty;
    END LOOP;
    IF v_remaining_qty>0.000001 THEN
      RAISE EXCEPTION 'PURCHASE_RETURN_INVOICE_ALLOCATION_GAP'; END IF;
  END LOOP;
  IF NOT FOUND THEN RAISE EXCEPTION 'PURCHASE_RETURN_LINES_REQUIRED'; END IF;
  IF round(v_inventory_total,4)<>round(v_ap_provisional_total+v_billed_provisional_total,4) THEN
    RAISE EXCEPTION 'PURCHASE_RETURN_PROVISIONAL_VALUE_RECONCILIATION_FAILED'; END IF;

  v_inventory_account:=private.resolve_opening_stock_account(
    v_company,v_category,'INVENTORY_ASSET',v_now);
  v_ap_provisional_account:=private.resolve_opening_stock_account(
    v_company,v_category,'SUPPLIER_AP_PROVISIONAL',v_now);
  IF v_ap_final_total>0 THEN v_ap_final_account:=private.resolve_opening_stock_account(
    v_company,v_category,'SUPPLIER_AP_FINAL',v_now); END IF;
  IF v_refund_total>0 THEN v_refund_account:=private.resolve_opening_stock_account(
    v_company,v_category,'SUPPLIER_REFUND_RECEIVABLE',v_now); END IF;
  v_variance_total:=round(v_actual_total+v_nonrecoverable_tax_total
    -v_billed_provisional_total,4);
  IF v_variance_total<>0 THEN v_variance_account:=private.resolve_opening_stock_account(
    v_company,v_category,'PURCHASE_PRICE_VARIANCE',v_now); END IF;
  IF v_recoverable_tax_total>0 THEN v_tax_account:=private.resolve_opening_stock_account(
    v_company,v_category,'INPUT_TAX',v_now); END IF;

  INSERT INTO public.financial_events(event_code,event_type,source_table,source_id,
    root_sales_id,event_date,event_version,idempotency_key,amounts,status,
    error_message,created_by,company_id,store_id,system_event_key,
    transaction_category_id)
  VALUES('PR-'||replace(v_document.id::text,'-',''),
    'PURCHASE_RETURN_POSTED'::public.event_type,'purchase_return_documents',
    v_document.id,NULL,v_now,1,'BACKOFFICE_PURCHASE_RETURN|'||v_company||'|'
      ||p_idempotency_key,jsonb_build_object(
      'allocationPolicy','UNINVOICED_FIRST','inventoryCredit',v_inventory_total,
      'apProvisionalDebit',v_ap_provisional_total,'apFinalDebit',v_ap_final_total,
      'supplierRefundReceivableDebit',v_refund_total,
      'recoverableInputTaxCredit',v_recoverable_tax_total,
      'purchaseVarianceReversal',v_variance_total,
      'inventoryAccountId',v_inventory_account,
      'apProvisionalAccountId',v_ap_provisional_account,
      'apFinalAccountId',v_ap_final_account,'supplierRefundReceivableAccountId',v_refund_account,
      'purchasePriceVarianceAccountId',v_variance_account,
      'inputTaxAccountId',v_tax_account,'financePostingState','POSTED'),
    'HOLD'::public.event_status,NULL,v_actor,v_company,v_document.store_id,
    'PURCHASE_RETURN',v_category) RETURNING id INTO v_event;

  SELECT * INTO v_period FROM public.accounting_periods period
  WHERE period.company_id=v_company AND v_document.return_date
    BETWEEN period.start_date AND period.end_date
    AND period.status IN('OPEN','REOPENED') ORDER BY period.start_date LIMIT 1 FOR SHARE;
  IF NOT FOUND THEN
    SELECT * INTO v_period FROM public.accounting_periods period
    WHERE period.company_id=v_company AND period.start_date>v_document.return_date
      AND period.status IN('OPEN','REOPENED') ORDER BY period.start_date LIMIT 1 FOR SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION 'POSTABLE_ACCOUNTING_PERIOD_NOT_FOUND'; END IF;
  END IF;
  INSERT INTO public.finance_journals(company_id,journal_no,journal_type,
    accounting_period_id,accounting_date,original_event_date,source_type,source_id,
    source_version,financial_event_id,idempotency_key,system_event_key,
    transaction_category_id,transaction_rule_version,store_id,warehouse_id,
    description,status,created_by)
  VALUES(v_company,'PRJ-'||replace(v_document.id::text,'-',''),
    CASE WHEN v_period.start_date>v_document.return_date
      THEN 'PRIOR_PERIOD_ADJUSTMENT' ELSE 'AUTOMATIC' END,v_period.id,
    greatest(v_document.return_date,v_period.start_date),v_document.return_date,
    'purchase_return_documents',v_document.id,v_document.master_version,v_event,
    'BACKOFFICE_PURCHASE_RETURN_JOURNAL|'||v_company||'|'||v_document.id,
    'PURCHASE_RETURN',v_category,20260919141000,v_document.store_id,
    v_document.source_warehouse_id,'Retur Supplier '||v_document.return_no,
    'DRAFT',v_actor) RETURNING * INTO v_journal;
  IF v_ap_provisional_total>0 THEN
    v_journal_line:=v_journal_line+1;
    INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,
      account_id,debit,credit,store_id,warehouse_id,supplier_id,description)
    VALUES(v_company,v_journal.id,v_journal_line,v_ap_provisional_account,
      v_ap_provisional_total,0,v_document.store_id,v_document.source_warehouse_id,
      v_document.supplier_id,'Pengurang AP provisional retur Supplier');
    v_debit:=v_debit+v_ap_provisional_total;
  END IF;
  IF v_ap_final_total>0 THEN
    v_journal_line:=v_journal_line+1;
    INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,
      account_id,debit,credit,store_id,warehouse_id,supplier_id,description)
    VALUES(v_company,v_journal.id,v_journal_line,v_ap_final_account,
      v_ap_final_total,0,v_document.store_id,v_document.source_warehouse_id,
      v_document.supplier_id,'Pengurang utang Supplier dari Credit Note');
    v_debit:=v_debit+v_ap_final_total;
  END IF;
  IF v_refund_total>0 THEN
    v_journal_line:=v_journal_line+1;
    INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,
      account_id,debit,credit,store_id,warehouse_id,supplier_id,description)
    VALUES(v_company,v_journal.id,v_journal_line,v_refund_account,
      v_refund_total,0,v_document.store_id,v_document.source_warehouse_id,
      v_document.supplier_id,'Piutang refund ke Supplier');
    v_debit:=v_debit+v_refund_total;
  END IF;
  IF v_variance_total<0 THEN
    v_journal_line:=v_journal_line+1;
    INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,
      account_id,debit,credit,store_id,warehouse_id,supplier_id,description)
    VALUES(v_company,v_journal.id,v_journal_line,v_variance_account,
      abs(v_variance_total),0,v_document.store_id,v_document.source_warehouse_id,
      v_document.supplier_id,'Reversal PPV dan pajak non-recoverable');
    v_debit:=v_debit+abs(v_variance_total);
  END IF;
  v_journal_line:=v_journal_line+1;
  INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,
    account_id,debit,credit,store_id,warehouse_id,supplier_id,description)
  VALUES(v_company,v_journal.id,v_journal_line,v_inventory_account,0,
    v_inventory_total,v_document.store_id,v_document.source_warehouse_id,
    v_document.supplier_id,'Pengeluaran Inventory retur Supplier');
  v_credit:=v_credit+v_inventory_total;
  IF v_recoverable_tax_total>0 THEN
    v_journal_line:=v_journal_line+1;
    INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,
      account_id,debit,credit,store_id,warehouse_id,supplier_id,description)
    VALUES(v_company,v_journal.id,v_journal_line,v_tax_account,0,
      v_recoverable_tax_total,v_document.store_id,v_document.source_warehouse_id,
      v_document.supplier_id,'Reversal pajak masukan retur Supplier');
    v_credit:=v_credit+v_recoverable_tax_total;
  END IF;
  IF v_variance_total>0 THEN
    v_journal_line:=v_journal_line+1;
    INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,
      account_id,debit,credit,store_id,warehouse_id,supplier_id,description)
    VALUES(v_company,v_journal.id,v_journal_line,v_variance_account,0,
      v_variance_total,v_document.store_id,v_document.source_warehouse_id,
      v_document.supplier_id,'Reversal PPV dan pajak non-recoverable');
    v_credit:=v_credit+v_variance_total;
  END IF;
  IF v_journal_line<2 OR round(v_debit,4)<>round(v_credit,4) THEN
    RAISE EXCEPTION 'PURCHASE_RETURN_JOURNAL_UNBALANCED'; END IF;
  UPDATE public.finance_journals SET status='POSTED',posted_by=v_actor,
    posted_at=v_now WHERE company_id=v_company AND id=v_journal.id
    RETURNING * INTO v_journal;
  IF round(v_journal.total_debit,4)<>round(v_debit,4)
    OR round(v_journal.total_credit,4)<>round(v_credit,4) THEN
    RAISE EXCEPTION 'PURCHASE_RETURN_JOURNAL_RECONCILIATION_FAILED'; END IF;

  IF v_actual_total+v_recoverable_tax_total+v_nonrecoverable_tax_total>0 THEN
    v_note:=gen_random_uuid();
    v_note_no:='SCN-'||to_char(v_document.return_date,'YYYYMMDD')||'-'
      ||lpad(nextval('private.supplier_return_credit_note_no_seq')::text,10,'0');
    INSERT INTO public.supplier_return_credit_notes(id,company_id,credit_note_no,
      purchase_return_id,supplier_id,credit_note_date,provisional_value,
      actual_value,recoverable_tax_value,nonrecoverable_tax_value,
      ap_final_reduction,supplier_refund_receivable,status,posted_by,posted_at)
    VALUES(v_note,v_company,v_note_no,v_document.id,v_document.supplier_id,
      v_document.return_date,v_billed_provisional_total,v_actual_total,
      v_recoverable_tax_total,v_nonrecoverable_tax_total,v_ap_final_total,
      v_refund_total,'POSTED',v_actor,v_now);
    UPDATE public.supplier_return_credit_notes SET financial_event_id=v_event
    WHERE company_id=v_company AND id=v_note;
  END IF;
  UPDATE public.financial_events SET status='POSTED'::public.event_status,
    processed_at=v_now,error_message=NULL,transaction_rule_version=20260919141000
  WHERE company_id=v_company AND id=v_event;
  UPDATE public.purchase_return_documents SET status='POSTED',handed_over_at=v_now,
    posting_idempotency_key=p_idempotency_key,financial_event_id=v_event,
    posted_by=v_actor,posted_at=v_now,master_version=master_version+1,
    updated_at=v_now WHERE company_id=v_company AND id=v_document.id
    RETURNING master_version INTO v_version;
  INSERT INTO public.purchase_return_audit(company_id,document_id,action,actor_id,
    before_state,after_state) SELECT v_company,v_document.id,'POST',v_actor,
      v_before,to_jsonb(document) FROM public.purchase_return_documents document
    WHERE document.company_id=v_company AND document.id=v_document.id;
  RETURN jsonb_build_object('documentId',v_document.id,'returnNo',v_document.return_no,
    'status','POSTED','masterVersion',v_version,'financialEventId',v_event,
    'journalId',v_journal.id,'journalNo',v_journal.journal_no,
    'supplierCreditNoteId',v_note,'supplierCreditNoteNo',v_note_no,
    'apProvisionalReduction',v_ap_provisional_total,
    'apFinalReduction',v_ap_final_total,
    'supplierRefundReceivable',v_refund_total,'idempotentReplay',false);
EXCEPTION WHEN unique_violation THEN
  RAISE EXCEPTION 'PURCHASE_RETURN_IDEMPOTENCY_CONFLICT';
END
$$;

ALTER TABLE public.purchase_return_finance_allocations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.supplier_return_credit_notes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.purchase_return_finance_allocations,
  public.supplier_return_credit_notes FROM PUBLIC,anon,authenticated;
GRANT SELECT,INSERT ON public.purchase_return_finance_allocations,
  public.supplier_return_credit_notes TO service_role;
REVOKE ALL ON FUNCTION public.post_backoffice_purchase_return(uuid,bigint,uuid)
  ,public.get_backoffice_purchase_return_finance(),
  public.save_supplier_payment_draft(uuid,bigint,uuid,date,text,uuid,text,text,text,text,text,text,jsonb),
  public.validate_supplier_payment(uuid,bigint,uuid)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.post_backoffice_purchase_return(uuid,bigint,uuid),
  public.get_backoffice_purchase_return_finance(),
  public.save_supplier_payment_draft(uuid,bigint,uuid,date,text,uuid,text,text,text,text,text,text,jsonb),
  public.validate_supplier_payment(uuid,bigint,uuid)
TO authenticated,service_role;
REVOKE ALL ON FUNCTION private.trg_purchase_return_finance_allocation_guard(),
  private.trg_supplier_return_credit_note_immutable(),
  private.purchase_return_previous_save_supplier_payment_draft(uuid,bigint,uuid,date,text,uuid,text,text,text,text,text,text,jsonb),
  private.purchase_return_previous_validate_supplier_payment(uuid,bigint,uuid)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.trg_purchase_return_finance_allocation_guard(),
  private.trg_supplier_return_credit_note_immutable(),
  private.purchase_return_previous_save_supplier_payment_draft(uuid,bigint,uuid,date,text,uuid,text,text,text,text,text,text,jsonb),
  private.purchase_return_previous_validate_supplier_payment(uuid,bigint,uuid)
TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260919141000','backoffice_purchase_return_finance_runtime',
  'Posts Backoffice Supplier Returns against exact Receipt FIFO with UNINVOICED_FIRST AP allocation, source-linked Supplier Credit, paid-excess Supplier Refund Receivable, balanced Finance Journal, retry safety, and no change to POS Return behavior');
NOTIFY pgrst,'reload schema';
COMMIT;
