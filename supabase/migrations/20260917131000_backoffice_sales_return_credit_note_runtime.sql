-- Backoffice Sales Return Step 3/5 runtime.
-- Finance explicitly classifies each physically received quantity as
-- UNINVOICED, DRAFT_INVOICE, or POSTED_INVOICE. The server never guesses an
-- Invoice. Posted allocations create one Draft Credit Note per source Invoice.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260917130000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Return Credit Note foundation required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260917131000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260917131000';
  END IF;
  IF to_regprocedure('public.allocate_backoffice_sales_return_invoices(uuid,bigint,uuid,jsonb)') IS NOT NULL
    OR to_regprocedure('public.update_backoffice_sales_credit_note_draft(uuid,bigint,uuid,date,numeric,text)') IS NOT NULL
    OR to_regprocedure('public.post_backoffice_sales_credit_note(uuid,bigint,uuid)') IS NOT NULL
    OR to_regprocedure('private.backoffice_sales_invoice_snapshot_before_return_credit(uuid,uuid)') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Return Credit Note runtime collision';
  END IF;
END
$guard$;

ALTER FUNCTION private.backoffice_sales_invoice_snapshot(uuid,uuid)
  RENAME TO backoffice_sales_invoice_snapshot_before_return_credit;
CREATE FUNCTION private.backoffice_sales_invoice_snapshot(
  p_company_id uuid,p_invoice_id uuid
) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
  SELECT private.backoffice_sales_invoice_snapshot_before_return_credit(
      p_company_id,p_invoice_id)
    ||jsonb_build_object(
      'returnAdjustmentPendingConfirmation',invoice.return_adjustment_pending_confirmation,
      'returnAdjustedAt',invoice.return_adjusted_at)
  FROM public.backoffice_sales_invoices invoice
  WHERE invoice.company_id=p_company_id AND invoice.id=p_invoice_id
$$;

UPDATE public.system_events SET conditional_account_functions=(
  SELECT ARRAY(SELECT DISTINCT value FROM unnest(
    conditional_account_functions||ARRAY['CUSTOMER_REFUND_LIABILITY','DELIVERY_FEE_REVENUE']) value
    ORDER BY value))
WHERE system_key='CUSTOMER_CREDIT_NOTE';

CREATE FUNCTION private.provision_backoffice_credit_note_account_fallbacks(
  p_company_id uuid,p_actor_id uuid DEFAULT NULL
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_actor uuid:=p_actor_id;v_key text;v_account uuid;v_count bigint;v_version bigint;
  v_active_count bigint;v_current_count bigint;v_fallback uuid;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM public.companies WHERE id=p_company_id AND status='ACTIVE') THEN RETURN; END IF;
  IF v_actor IS NULL OR NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=v_actor) THEN
    SELECT id INTO v_actor FROM public.profiles WHERE role::text='super_admin' ORDER BY id LIMIT 1;
  END IF;
  IF v_actor IS NULL THEN RAISE EXCEPTION 'CREDIT_NOTE_MAPPING_ACTOR_REQUIRED'; END IF;
  FOREACH v_key IN ARRAY ARRAY['CUSTOMER_RECEIVABLE','CUSTOMER_REFUND_LIABILITY',
    'SALES_RETURN_DISCOUNT','DELIVERY_FEE_REVENUE'] LOOP
    SELECT count(*),count(*) FILTER(WHERE fallback.effective_from<=clock_timestamp()
      AND (fallback.effective_to IS NULL OR fallback.effective_to>clock_timestamp()))
    INTO v_active_count,v_current_count
    FROM public.company_account_function_fallbacks fallback
    WHERE fallback.company_id=p_company_id AND fallback.account_function_key=v_key
      AND fallback.status='ACTIVE';
    IF v_current_count=1 THEN CONTINUE; END IF;
    IF v_active_count<>0 THEN RAISE EXCEPTION 'CREDIT_NOTE_ACCOUNT_MAPPING_AMBIGUOUS: %',v_key; END IF;
    SELECT count(*),(array_agg(account.id ORDER BY account.id))[1] INTO v_count,v_account
    FROM public.chart_of_accounts account JOIN public.account_functions function_state
      ON function_state.function_key=v_key AND function_state.is_active
    WHERE account.company_id=p_company_id AND account.system_function_key=v_key
      AND account.is_system_account AND account.is_active AND account.is_postable
      AND account.account_type=ANY(function_state.compatible_account_types);
    IF v_count<>1 THEN RAISE EXCEPTION 'CREDIT_NOTE_CANONICAL_ACCOUNT_INVALID: % found %',v_key,v_count; END IF;
    SELECT COALESCE(max(fallback_version),0)+1 INTO v_version
    FROM public.company_account_function_fallbacks
    WHERE company_id=p_company_id AND account_function_key=v_key;
    INSERT INTO public.company_account_function_fallbacks(company_id,account_function_key,
      account_id,effective_from,fallback_version,status,approved_by,approved_at,
      created_by,updated_by)
    VALUES(p_company_id,v_key,v_account,timestamptz '2000-01-01 00:00:00+00',
      v_version,'ACTIVE',v_actor,clock_timestamp(),v_actor,v_actor)
    RETURNING id INTO v_fallback;
    INSERT INTO public.finance_master_audit(
      company_id,entity_type,entity_id,action,actor_id,after_state)
    SELECT fallback.company_id,'FALLBACK',fallback.id,'CREATE',v_actor,to_jsonb(fallback)
    FROM public.company_account_function_fallbacks fallback
    WHERE fallback.company_id=p_company_id AND fallback.id=v_fallback;
  END LOOP;
END
$$;

DO $backfill$
DECLARE v_actor uuid;v_company record;
BEGIN
  SELECT id INTO v_actor FROM public.profiles WHERE role::text='super_admin' ORDER BY id LIMIT 1;
  IF v_actor IS NULL THEN RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: linked Super Admin profile required'; END IF;
  FOR v_company IN SELECT id FROM public.companies WHERE status='ACTIVE' ORDER BY id LOOP
    PERFORM private.provision_backoffice_credit_note_account_fallbacks(v_company.id,v_actor);
  END LOOP;
END
$backfill$;

CREATE FUNCTION private.trg_provision_backoffice_credit_note_account_fallbacks()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
  PERFORM private.provision_backoffice_credit_note_account_fallbacks(NEW.id,auth.uid());
  RETURN NEW;
END
$$;
CREATE TRIGGER zz_provision_backoffice_credit_note_account_fallbacks
AFTER INSERT ON public.companies FOR EACH ROW
EXECUTE FUNCTION private.trg_provision_backoffice_credit_note_account_fallbacks();

CREATE FUNCTION private.backoffice_sales_credit_note_snapshot(
  p_company_id uuid,p_credit_note_id uuid
) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
  SELECT jsonb_build_object(
    'id',note.id,'returnId',note.return_id,'sourceInvoiceId',note.source_invoice_id,
    'creditNoteNo',note.credit_note_no,'status',note.status,
    'creditNoteDate',note.credit_note_date,'currencyCode',note.currency_code,
    'reason',note.reason,'chargeTotal',note.charge_total,
    'discountTotal',note.discount_total,'taxTotal',note.tax_total,
    'deliveryFeeAmount',note.delivery_fee_amount,'grandTotal',note.grand_total,
    'arReductionAmount',note.ar_reduction_amount,
    'refundLiabilityAmount',note.refund_liability_amount,
    'sourceInvoiceSnapshot',note.source_invoice_snapshot,
    'masterVersion',note.master_version,'createdAt',note.created_at,
    'updatedAt',note.updated_at,'postedAt',note.posted_at,
    'lines',COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'id',line.id,'lineNo',line.line_no,
      'returnReceiptLineId',line.return_receipt_line_id,
      'salesOrderLineId',line.sales_order_line_id,
      'sourceInvoiceLineId',line.source_invoice_line_id,
      'productId',line.product_id,'uomId',line.uom_id,
      'quantityUom',line.quantity_uom,'quantityBase',line.quantity_base,
      'unitPrice',line.unit_price,'discountAmount',line.discount_amount,
      'taxAmount',line.tax_amount,'lineAmount',line.line_amount,
      'sourceSnapshot',line.source_snapshot
    ) ORDER BY line.line_no)
    FROM public.backoffice_sales_credit_note_lines line
    WHERE line.company_id=note.company_id AND line.credit_note_id=note.id),'[]'::jsonb)
  ) FROM public.backoffice_sales_credit_notes note
  WHERE note.company_id=p_company_id AND note.id=p_credit_note_id
$$;

CREATE FUNCTION private.backoffice_sales_credit_note_operation_retry(
  p_company_id uuid,p_operation_id uuid,p_operation_type text,p_request_hash text
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_operation public.backoffice_sales_credit_note_operations%rowtype;
BEGIN
  SELECT * INTO v_operation FROM public.backoffice_sales_credit_note_operations
  WHERE company_id=p_company_id AND operation_id=p_operation_id;
  IF NOT FOUND THEN RETURN NULL; END IF;
  IF v_operation.operation_type<>p_operation_type
    OR v_operation.request_hash<>p_request_hash THEN
    RAISE EXCEPTION 'IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_REQUEST';
  END IF;
  RETURN v_operation.response_snapshot||jsonb_build_object('exactRetry',true);
END
$$;

CREATE FUNCTION private.recalculate_backoffice_sales_credit_note(
  p_company_id uuid,p_credit_note_id uuid,p_actor_id uuid
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_charge numeric(24,4);v_discount numeric(24,4);v_tax numeric(24,4);
BEGIN
  SELECT round(COALESCE(sum(line.line_amount+line.discount_amount),0),4),
    round(COALESCE(sum(line.discount_amount),0),4),
    round(COALESCE(sum(line.tax_amount),0),4)
  INTO v_charge,v_discount,v_tax
  FROM public.backoffice_sales_credit_note_lines line
  WHERE line.company_id=p_company_id AND line.credit_note_id=p_credit_note_id;
  UPDATE public.backoffice_sales_credit_notes SET charge_total=v_charge,
    discount_total=v_discount,tax_total=v_tax,
    grand_total=round(v_charge-v_discount+v_tax+delivery_fee_amount,4),
    updated_by=p_actor_id,updated_at=clock_timestamp()
  WHERE company_id=p_company_id AND id=p_credit_note_id AND status='DRAFT';
  IF NOT FOUND THEN RAISE EXCEPTION 'BACKOFFICE_SALES_CREDIT_NOTE_NOT_EDITABLE'; END IF;
END
$$;

CREATE OR REPLACE FUNCTION private.reconcile_backoffice_invoice_receivable_schedule(
  p_company_id uuid,p_invoice_id uuid
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_invoice public.backoffice_sales_invoices%rowtype;
  v_paid numeric(24,4);v_credited numeric(24,4);v_remaining numeric(24,4);
  v_apply numeric(24,4);v_schedule record;
BEGIN
  SELECT * INTO v_invoice FROM public.backoffice_sales_invoices invoice
  WHERE invoice.company_id=p_company_id AND invoice.id=p_invoice_id FOR UPDATE;
  IF NOT FOUND OR v_invoice.status<>'POSTED' THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_NOT_PAYMENT_ELIGIBLE';
  END IF;
  SELECT round(COALESCE(sum(allocation.allocated_amount),0),4) INTO v_paid
  FROM public.customer_receipt_backoffice_invoice_allocations allocation
  JOIN public.customer_receipt_documents receipt
    ON receipt.company_id=allocation.company_id AND receipt.id=allocation.document_id
   AND receipt.status='POSTED'
  WHERE allocation.company_id=p_company_id AND allocation.invoice_id=p_invoice_id;
  SELECT round(COALESCE(sum(note.ar_reduction_amount),0),4) INTO v_credited
  FROM public.backoffice_sales_credit_notes note
  WHERE note.company_id=p_company_id AND note.source_invoice_id=p_invoice_id
    AND note.status='POSTED';
  IF v_paid<0 OR v_paid>round(v_invoice.grand_total,4)
    OR v_credited<0 OR v_credited>round(v_invoice.grand_total-v_paid,4) THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_SETTLEMENT_RECONCILIATION_FAILED';
  END IF;
  UPDATE public.backoffice_sales_invoice_receivable_schedules
  SET allocated_payment_amount=0,credited_amount=0,status='OPEN',updated_at=clock_timestamp()
  WHERE company_id=p_company_id AND invoice_id=p_invoice_id;
  v_remaining:=v_paid;
  FOR v_schedule IN SELECT schedule.id,schedule.amount_due
    FROM public.backoffice_sales_invoice_receivable_schedules schedule
    WHERE schedule.company_id=p_company_id AND schedule.invoice_id=p_invoice_id
    ORDER BY schedule.due_date,schedule.installment_no FOR UPDATE
  LOOP
    v_apply:=least(v_remaining,v_schedule.amount_due);
    UPDATE public.backoffice_sales_invoice_receivable_schedules
    SET allocated_payment_amount=v_apply,updated_at=clock_timestamp()
    WHERE company_id=p_company_id AND id=v_schedule.id;
    v_remaining:=v_remaining-v_apply;
  END LOOP;
  IF v_remaining<>0 THEN RAISE EXCEPTION 'CUSTOMER_RECEIPT_OVER_ALLOCATION'; END IF;
  v_remaining:=v_credited;
  FOR v_schedule IN SELECT schedule.id,schedule.amount_due,schedule.allocated_payment_amount
    FROM public.backoffice_sales_invoice_receivable_schedules schedule
    WHERE schedule.company_id=p_company_id AND schedule.invoice_id=p_invoice_id
    ORDER BY schedule.due_date,schedule.installment_no FOR UPDATE
  LOOP
    v_apply:=least(v_remaining,v_schedule.amount_due-v_schedule.allocated_payment_amount);
    UPDATE public.backoffice_sales_invoice_receivable_schedules
    SET credited_amount=v_apply,updated_at=clock_timestamp()
    WHERE company_id=p_company_id AND id=v_schedule.id;
    v_remaining:=v_remaining-v_apply;
  END LOOP;
  IF v_remaining<>0 THEN RAISE EXCEPTION 'CREDIT_NOTE_AR_OVER_ALLOCATION'; END IF;
  UPDATE public.backoffice_sales_invoice_receivable_schedules
  SET status=CASE
      WHEN allocated_payment_amount+credited_amount=amount_due THEN 'PAID'
      WHEN allocated_payment_amount+credited_amount>0 THEN 'PARTIALLY_PAID'
      ELSE 'OPEN' END,
    updated_at=clock_timestamp()
  WHERE company_id=p_company_id AND invoice_id=p_invoice_id;
END
$$;

CREATE OR REPLACE FUNCTION private.backoffice_invoice_receivable_before_receipts(
  p_company_id uuid,p_invoice_id uuid,p_as_of date
) RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
  SELECT CASE WHEN invoice.status='POSTED' AND invoice.invoice_date<=p_as_of
    THEN greatest(0,invoice.grand_total-COALESCE((SELECT sum(note.grand_total)
      FROM public.backoffice_sales_credit_notes note
      WHERE note.company_id=invoice.company_id AND note.source_invoice_id=invoice.id
        AND note.status='POSTED' AND note.credit_note_date<=p_as_of),0))
    ELSE 0::numeric END
  FROM public.backoffice_sales_invoices invoice
  WHERE invoice.company_id=p_company_id AND invoice.id=p_invoice_id
$$;

CREATE OR REPLACE FUNCTION public.get_backoffice_sales_invoice_payment_context(p_invoice_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='8s' AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_permission jsonb;
  v_invoice public.backoffice_sales_invoices%rowtype;v_paid numeric(20,4);
  v_credit numeric(20,4);v_refund_liability numeric(20,4);v_result jsonb;
BEGIN
  PERFORM private.acp_require_permission_capability(v_company,'sales.backoffice_orders','VIEW');
  v_permission:=private.acp_require_permission_capability(v_company,'finance.customer_receipts','VIEW');
  SELECT * INTO v_invoice FROM public.backoffice_sales_invoices invoice
  WHERE invoice.company_id=v_company AND invoice.id=p_invoice_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_NOT_FOUND'; END IF;
  SELECT round(COALESCE(sum(allocation.allocated_amount),0),4) INTO v_paid
  FROM public.customer_receipt_backoffice_invoice_allocations allocation
  JOIN public.customer_receipt_documents receipt
    ON receipt.company_id=allocation.company_id AND receipt.id=allocation.document_id
   AND receipt.status='POSTED'
  WHERE allocation.company_id=v_company AND allocation.invoice_id=p_invoice_id;
  SELECT round(COALESCE(sum(note.grand_total),0),4),
    round(COALESCE(sum(note.refund_liability_amount),0),4)
  INTO v_credit,v_refund_liability
  FROM public.backoffice_sales_credit_notes note
  WHERE note.company_id=v_company AND note.source_invoice_id=p_invoice_id
    AND note.status='POSTED';
  SELECT jsonb_build_object(
    'companyDate',(clock_timestamp() AT TIME ZONE company.timezone)::date,
    'effectiveCapabilities',v_permission->'effectiveCapabilities',
    'summary',jsonb_build_object(
      'originalAmount',v_invoice.grand_total,'creditNoteAmount',v_credit,
      'netInvoiceAmount',greatest(0,v_invoice.grand_total-v_credit),
      'paidAmount',v_paid,'outstandingAmount',greatest(0,v_invoice.grand_total-v_credit-v_paid),
      'refundLiabilityAmount',v_refund_liability,
      'status',CASE WHEN v_invoice.status<>'POSTED' THEN 'NOT_APPLICABLE'
        WHEN v_paid=0 AND v_credit=0 THEN 'NOT_PAID'
        WHEN v_invoice.grand_total-v_credit-v_paid>0 THEN 'PARTIALLY_PAID'
        WHEN v_refund_liability>0 THEN 'REFUND_PENDING' ELSE 'PAID' END),
    'payments',COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'receiptId',receipt.id,'receiptNo',receipt.receipt_no,
      'receiptDate',receipt.receipt_date,'paymentMethodName',receipt.payment_method_name_snapshot,
      'settlementRoute',receipt.settlement_route_snapshot,'referenceNo',receipt.reference_no,
      'evidenceUrl',receipt.evidence_url,'notes',receipt.notes,
      'amount',allocation.allocated_amount,'postedAt',receipt.posted_at,
      'journalNo',(SELECT journal.journal_no FROM public.finance_journals journal
        WHERE journal.company_id=receipt.company_id
          AND journal.financial_event_id=receipt.financial_event_id
          AND journal.status='POSTED' ORDER BY journal.id LIMIT 1))
      ORDER BY receipt.receipt_date,receipt.posted_at,receipt.id)
      FROM public.customer_receipt_backoffice_invoice_allocations allocation
      JOIN public.customer_receipt_documents receipt
        ON receipt.company_id=allocation.company_id AND receipt.id=allocation.document_id
       AND receipt.status='POSTED'
      WHERE allocation.company_id=v_company AND allocation.invoice_id=p_invoice_id),'[]'::jsonb),
    'creditNotes',COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'id',note.id,'creditNoteNo',note.credit_note_no,'creditNoteDate',note.credit_note_date,
      'grandTotal',note.grand_total,'arReductionAmount',note.ar_reduction_amount,
      'refundLiabilityAmount',note.refund_liability_amount,'status',note.status)
      ORDER BY note.credit_note_date,note.created_at,note.id)
      FROM public.backoffice_sales_credit_notes note
      WHERE note.company_id=v_company AND note.source_invoice_id=p_invoice_id
        AND note.status='POSTED'),'[]'::jsonb),
    'paymentMethods',COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'id',method.id,'name',method.payment_method_name,'type',method.method_type,
      'settlementRoute',method.settlement_route,'proofMode',method.proof_mode)
      ORDER BY method.is_default DESC,method.payment_method_name,method.id)
      FROM public.payment_methods method WHERE method.company_id=v_company AND method.is_active
        AND method.settlement_route IN('CASH_DRAWER','DIRECT_BANK')),'[]'::jsonb))
  INTO STRICT v_result FROM public.companies company WHERE company.id=v_company;
  RETURN v_result;
END
$$;

-- Preserve the existing Retail + Backoffice AR report and change only the
-- Backoffice installment allocation expression. Credit Notes are filtered by
-- their own business date, so an as-of report never applies a future Note.
DO $patch_ar$
DECLARE v_definition text;v_old text;v_new text;v_count integer;
BEGIN
  SELECT pg_get_functiondef(to_regprocedure('public.get_finance_ar_aging(date,uuid,uuid)'))
    INTO STRICT v_definition;
  v_old:='GREATEST(LEAST(COALESCE(receipt.paid,0)-COALESCE(sum(schedule.amount_due) OVER(
        PARTITION BY schedule.company_id,schedule.invoice_id ORDER BY schedule.installment_no
        ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING),0),schedule.amount_due),0)';
  v_new:='GREATEST(LEAST(COALESCE(receipt.paid,0)+COALESCE(credit.credited,0)-COALESCE(sum(schedule.amount_due) OVER(
        PARTITION BY schedule.company_id,schedule.invoice_id ORDER BY schedule.installment_no
        ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING),0),schedule.amount_due),0)';
  v_count:=(length(v_definition)-length(replace(v_definition,v_old,'')))/length(v_old);
  IF v_count<>1 THEN RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Finance AR Backoffice allocation anchor drift'; END IF;
  v_definition:=replace(v_definition,v_old,v_new);
  v_old:='WHERE allocation.company_id=invoice.company_id AND allocation.invoice_id=invoice.id) receipt ON true
    WHERE invoice.company_id=v_company';
  v_new:='WHERE allocation.company_id=invoice.company_id AND allocation.invoice_id=invoice.id) receipt ON true
    LEFT JOIN LATERAL(SELECT sum(note.ar_reduction_amount) credited
      FROM public.backoffice_sales_credit_notes note
      WHERE note.company_id=invoice.company_id AND note.source_invoice_id=invoice.id
        AND note.status=''POSTED'' AND note.credit_note_date<=v_as_of) credit ON true
    WHERE invoice.company_id=v_company';
  v_count:=(length(v_definition)-length(replace(v_definition,v_old,'')))/length(v_old);
  IF v_count<>1 THEN RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Finance AR Backoffice credit join anchor drift'; END IF;
  EXECUTE replace(v_definition,v_old,v_new);
END
$patch_ar$;

-- Customer Statement keeps the original Invoice and Payment history, then adds
-- the posted Credit Note as its own credit row. This preserves a negative
-- ending balance when the Company owes a refund to the Customer.
DO $patch_statement$
DECLARE v_definition text;v_old text;v_new text;v_count integer;
BEGIN
  SELECT pg_get_functiondef(to_regprocedure(
    'public.get_finance_customer_statement(uuid,date,date,uuid)'))
  INTO STRICT v_definition;
  v_old:='WHERE allocation.company_id=v_company AND receipt.customer_id=p_customer_id
      AND receipt.receipt_date<=v_as_of AND (p_store_id IS NULL OR invoice.store_id=p_store_id)
  ),all_rows AS (SELECT * FROM invoice_rows UNION ALL SELECT * FROM receipt_rows)';
  v_new:='WHERE allocation.company_id=v_company AND receipt.customer_id=p_customer_id
      AND receipt.receipt_date<=v_as_of AND (p_store_id IS NULL OR invoice.store_id=p_store_id)
    UNION ALL
    SELECT note.id,''CREDIT_NOTE'',''BACKOFFICE'',note.credit_note_no,note.credit_note_date,
      NULL::date,note.store_id,store.store_name,0::numeric,note.grand_total,
      (''Credit Note Retur Customer untuk ''||source.invoice_no)::text
    FROM public.backoffice_sales_credit_notes note
    JOIN public.backoffice_sales_invoices source
      ON source.company_id=note.company_id AND source.id=note.source_invoice_id
      AND source.customer_id=p_customer_id
    LEFT JOIN public.stores store ON store.company_id=note.company_id AND store.id=note.store_id
    WHERE note.company_id=v_company AND note.customer_id=p_customer_id
      AND note.status=''POSTED'' AND note.credit_note_date<=v_as_of
      AND (p_store_id IS NULL OR note.store_id=p_store_id)
  ),all_rows AS (SELECT * FROM invoice_rows UNION ALL SELECT * FROM receipt_rows)';
  v_count:=(length(v_definition)-length(replace(v_definition,v_old,'')))/length(v_old);
  IF v_count<>1 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Customer Statement Credit Note anchor drift';
  END IF;
  EXECUTE replace(v_definition,v_old,v_new);
END
$patch_statement$;

CREATE FUNCTION public.allocate_backoffice_sales_return_invoices(
  p_return_id uuid,p_expected_version bigint,p_operation_id uuid,p_allocations jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='15s' AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
  v_return public.backoffice_sales_returns%rowtype;v_item jsonb;v_type text;
  v_receipt_line public.backoffice_sales_return_receipt_lines%rowtype;
  v_order_line public.backoffice_sales_order_lines%rowtype;
  v_invoice public.backoffice_sales_invoices%rowtype;
  v_invoice_line public.backoffice_sales_invoice_lines%rowtype;
  v_qty_uom numeric(24,6);v_qty_base numeric(24,6);v_used numeric(24,6);
  v_alloc public.backoffice_sales_invoice_quantity_allocations%rowtype;
  v_note public.backoffice_sales_credit_notes%rowtype;v_note_id uuid;v_line_no integer;
  v_ratio numeric;v_charge numeric(24,4);v_discount numeric(24,4);
  v_tax numeric(24,4);v_line_amount numeric(24,4);v_prior numeric(24,4);
  v_hash text;v_retry jsonb;v_response jsonb;v_invoice_op uuid;
  v_before jsonb;v_after jsonb;v_all_received boolean;v_has_draft_notes boolean;
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'finance.customer_credit_notes','CREATE_DRAFT');
  IF p_return_id IS NULL OR p_expected_version IS NULL OR p_operation_id IS NULL
    OR jsonb_typeof(p_allocations)<>'array' OR jsonb_array_length(p_allocations)=0 THEN
    RAISE EXCEPTION 'RETURN_INVOICE_ALLOCATION_REQUIRED: pilih tujuan untuk setiap qty Retur yang sudah diterima';
  END IF;
  v_hash:=encode(extensions.digest(convert_to(jsonb_build_object(
    'returnId',p_return_id,'expectedVersion',p_expected_version,
    'allocations',p_allocations)::text,'UTF8'),'sha256'),'hex');
  PERFORM pg_advisory_xact_lock(hashtextextended(
    v_company::text||':RETURN_CREDIT:'||p_operation_id::text,0));
  v_retry:=private.backoffice_sales_credit_note_operation_retry(
    v_company,p_operation_id,'ALLOCATE_RETURN',v_hash);
  IF v_retry IS NOT NULL THEN RETURN v_retry; END IF;
  SELECT * INTO v_return FROM public.backoffice_sales_returns document
  WHERE document.company_id=v_company AND document.id=p_return_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'RETURN_NOT_FOUND: dokumen Retur tidak ditemukan pada Company aktif'; END IF;
  IF v_return.master_version<>p_expected_version THEN
    RAISE EXCEPTION 'MASTER_VERSION_CONFLICT: dokumen Retur sudah berubah, muat ulang sebelum melanjutkan';
  END IF;
  IF v_return.status NOT IN('APPROVED','PARTIALLY_RECEIVED','RECEIVED','CREDIT_PENDING')
    OR v_return.total_received_base_qty<=0 THEN
    RAISE EXCEPTION 'RETURN_NOT_READY_FOR_INVOICE_RECONCILIATION: Gudang harus mem-posting penerimaan Retur terlebih dahulu';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(
    v_company::text||':BACKOFFICE_INVOICE_ORDER:'||v_return.sales_order_id::text,0));
  PERFORM 1 FROM public.backoffice_sales_order_lines line
  WHERE line.company_id=v_company AND line.sales_order_id=v_return.sales_order_id
  ORDER BY line.line_no FOR UPDATE;

  FOR v_item IN SELECT value FROM jsonb_array_elements(p_allocations) LOOP
    BEGIN
      v_type:=upper(btrim(v_item->>'allocationType'));
      v_qty_uom:=round((v_item->>'quantityUom')::numeric,6);
      SELECT * INTO STRICT v_receipt_line
      FROM public.backoffice_sales_return_receipt_lines line
      WHERE line.company_id=v_company AND line.id=(v_item->>'returnReceiptLineId')::uuid
        AND line.return_id=p_return_id;
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'RETURN_INVOICE_ALLOCATION_LINE_INVALID: pilih baris penerimaan Retur dan qty yang valid';
    END;
    IF v_type NOT IN('UNINVOICED','DRAFT_INVOICE','POSTED_INVOICE')
      OR v_qty_uom<=0 THEN
      RAISE EXCEPTION 'RETURN_INVOICE_ALLOCATION_TYPE_INVALID: pilih Belum Ditagih, Draft Invoice, atau Posted Invoice';
    END IF;
    v_qty_base:=round(v_qty_uom*v_receipt_line.base_qty_per_uom,6);
    SELECT COALESCE(sum(allocation.allocated_base_qty),0) INTO v_used
    FROM public.backoffice_sales_return_invoice_allocations allocation
    WHERE allocation.company_id=v_company
      AND allocation.return_receipt_line_id=v_receipt_line.id;
    IF v_used+v_qty_base>v_receipt_line.received_base_qty THEN
      RAISE EXCEPTION 'RETURN_RECEIPT_QUANTITY_ALREADY_ALLOCATED: jumlah pembagian melebihi qty yang diterima Gudang';
    END IF;
    -- receipt.return_line_id points to Return line, resolve canonical SO line.
    SELECT source.* INTO STRICT v_order_line
    FROM public.backoffice_sales_return_lines return_line
    JOIN public.backoffice_sales_order_lines source
      ON source.company_id=return_line.company_id AND source.id=return_line.sales_order_line_id
    WHERE return_line.company_id=v_company AND return_line.id=v_receipt_line.return_line_id;

    IF v_type='UNINVOICED' THEN
      IF v_qty_base>v_order_line.to_invoice_base_qty THEN
        RAISE EXCEPTION 'UNINVOICED_RETURN_QUANTITY_NOT_AVAILABLE: qty belum ditagih tidak mencukupi';
      END IF;
      UPDATE public.backoffice_sales_order_lines SET
        returned_before_invoice_base_qty=returned_before_invoice_base_qty+v_qty_base,
        updated_at=clock_timestamp()
      WHERE company_id=v_company AND id=v_order_line.id;
      INSERT INTO public.backoffice_sales_return_invoice_allocations(company_id,return_id,
        return_receipt_line_id,sales_order_line_id,allocation_type,allocated_base_qty,
        operation_id,actor_id)
      VALUES(v_company,p_return_id,v_receipt_line.id,v_order_line.id,v_type,
        v_qty_base,p_operation_id,v_actor);
      CONTINUE;
    END IF;

    BEGIN
      SELECT invoice.* INTO STRICT v_invoice
      FROM public.backoffice_sales_invoices invoice
      WHERE invoice.company_id=v_company AND invoice.id=(v_item->>'invoiceId')::uuid
        AND invoice.sales_order_id=v_return.sales_order_id FOR UPDATE;
      SELECT line.* INTO STRICT v_invoice_line
      FROM public.backoffice_sales_invoice_lines line
      WHERE line.company_id=v_company AND line.id=(v_item->>'invoiceLineId')::uuid
        AND line.invoice_id=v_invoice.id AND line.sales_order_line_id=v_order_line.id
        AND line.line_type='PRODUCT' AND line.source_kind='SALES_ORDER';
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'RETURN_SOURCE_INVOICE_LINE_INVALID: Invoice dan baris Product harus berasal dari SO Retur yang sama';
    END;
    IF v_type='DRAFT_INVOICE' THEN
      IF v_invoice.status<>'DRAFT' THEN
        RAISE EXCEPTION 'DRAFT_INVOICE_REQUIRED: tujuan yang dipilih bukan Draft Invoice';
      END IF;
      SELECT * INTO v_alloc FROM public.backoffice_sales_invoice_quantity_allocations allocation
      WHERE allocation.company_id=v_company AND allocation.invoice_line_id=v_invoice_line.id
        AND allocation.status='HELD' FOR UPDATE;
      IF NOT FOUND OR v_qty_base>v_alloc.allocated_base_qty THEN
        RAISE EXCEPTION 'DRAFT_INVOICE_RETURN_QUANTITY_EXCEEDS_LINE: qty Retur melebihi qty Draft Invoice';
      END IF;
      v_before:=private.backoffice_sales_invoice_snapshot(v_company,v_invoice.id);
      v_ratio:=v_qty_base/v_invoice_line.quantity_base;
      v_discount:=CASE WHEN v_qty_base=v_invoice_line.quantity_base
        THEN v_invoice_line.discount_amount ELSE round(v_invoice_line.discount_amount*v_ratio,4) END;
      v_tax:=CASE WHEN v_qty_base=v_invoice_line.quantity_base
        THEN v_invoice_line.tax_amount ELSE round(v_invoice_line.tax_amount*v_ratio,4) END;
      v_line_amount:=CASE WHEN v_qty_base=v_invoice_line.quantity_base
        THEN v_invoice_line.line_amount ELSE round(v_invoice_line.line_amount*v_ratio,4) END;
      IF v_qty_base=v_invoice_line.quantity_base THEN
        DELETE FROM public.backoffice_sales_invoice_quantity_allocations
        WHERE company_id=v_company AND id=v_alloc.id;
        DELETE FROM public.backoffice_sales_invoice_lines
        WHERE company_id=v_company AND id=v_invoice_line.id;
      ELSE
        UPDATE public.backoffice_sales_invoice_lines SET
          quantity_uom=round((quantity_base-v_qty_base)/base_qty_per_uom,6),
          quantity_base=quantity_base-v_qty_base,
          discount_amount=discount_amount-v_discount,
          tax_amount=tax_amount-v_tax,line_amount=line_amount-v_line_amount,
          source_snapshot=source_snapshot||jsonb_build_object(
            'returnAdjusted',true,'lastReturnId',p_return_id)
        WHERE company_id=v_company AND id=v_invoice_line.id;
        UPDATE public.backoffice_sales_invoice_quantity_allocations
        SET allocated_base_qty=allocated_base_qty-v_qty_base,updated_at=clock_timestamp()
        WHERE company_id=v_company AND id=v_alloc.id;
      END IF;
      UPDATE public.backoffice_sales_order_lines SET
        draft_invoice_allocated_base_qty=draft_invoice_allocated_base_qty-v_qty_base,
        returned_before_invoice_base_qty=returned_before_invoice_base_qty+v_qty_base,
        updated_at=clock_timestamp()
      WHERE company_id=v_company AND id=v_order_line.id;
      UPDATE public.backoffice_sales_invoices invoice SET
        charge_total=COALESCE((SELECT round(sum(line.line_amount+line.discount_amount),4)
          FROM public.backoffice_sales_invoice_lines line
          WHERE line.company_id=v_company AND line.invoice_id=invoice.id
            AND line.effect_type='CHARGE'),0),
        discount_total=COALESCE((SELECT round(sum(line.discount_amount),4)
          FROM public.backoffice_sales_invoice_lines line
          WHERE line.company_id=v_company AND line.invoice_id=invoice.id
            AND line.effect_type='CHARGE'),0),
        tax_total=COALESCE((SELECT round(sum(line.tax_amount),4)
          FROM public.backoffice_sales_invoice_lines line
          WHERE line.company_id=v_company AND line.invoice_id=invoice.id
            AND line.effect_type='CHARGE'),0),
        return_adjustment_pending_confirmation=true,return_adjusted_at=clock_timestamp(),
        master_version=master_version+1,updated_by=v_actor,updated_at=clock_timestamp()
      WHERE invoice.company_id=v_company AND invoice.id=v_invoice.id;
      DELETE FROM public.backoffice_sales_invoice_receivable_schedules
      WHERE company_id=v_company AND invoice_id=v_invoice.id;
      IF (SELECT grand_total FROM public.backoffice_sales_invoices
          WHERE company_id=v_company AND id=v_invoice.id)>0 THEN
        PERFORM private.rebuild_backoffice_sales_invoice_schedules(v_company,v_invoice.id,v_actor);
      END IF;
      v_after:=private.backoffice_sales_invoice_snapshot(v_company,v_invoice.id);
      v_invoice_op:=gen_random_uuid();
      INSERT INTO public.backoffice_sales_invoice_operations(company_id,operation_id,
        operation_type,invoice_id,expected_version,request_hash,response_snapshot,actor_id)
      VALUES(v_company,v_invoice_op,'RETURN_ADJUST_DRAFT',v_invoice.id,
        v_invoice.master_version,
        encode(extensions.digest(convert_to(jsonb_build_object('returnId',p_return_id,
          'returnOperationId',p_operation_id,'invoiceLineId',v_invoice_line.id,
          'quantityBase',v_qty_base)::text,'UTF8'),'sha256'),'hex'),
        jsonb_build_object('data',v_after,'returnId',p_return_id),v_actor);
      INSERT INTO public.backoffice_sales_invoice_audit(company_id,invoice_id,action,
        operation_id,actor_id,reason,before_state,after_state)
      VALUES(v_company,v_invoice.id,'RETURN_ADJUST_DRAFT',v_invoice_op,v_actor,
        'Qty disesuaikan dari Retur Customer '||v_return.return_no,v_before,v_after);
      INSERT INTO public.backoffice_sales_return_invoice_allocations(company_id,return_id,
        return_receipt_line_id,sales_order_line_id,allocation_type,invoice_id,
        invoice_line_id,allocated_base_qty,invoice_line_snapshot,operation_id,actor_id)
      VALUES(v_company,p_return_id,v_receipt_line.id,v_order_line.id,v_type,v_invoice.id,
        v_invoice_line.id,v_qty_base,to_jsonb(v_invoice_line),p_operation_id,v_actor);
      CONTINUE;
    END IF;

    IF v_invoice.status<>'POSTED' THEN
      RAISE EXCEPTION 'POSTED_INVOICE_REQUIRED: tujuan yang dipilih belum menjadi Posted Invoice';
    END IF;
    SELECT COALESCE(sum(allocation.allocated_base_qty),0) INTO v_used
    FROM public.backoffice_sales_return_invoice_allocations allocation
    WHERE allocation.company_id=v_company AND allocation.invoice_line_id=v_invoice_line.id
      AND allocation.allocation_type='POSTED_INVOICE';
    IF v_used+v_qty_base>v_invoice_line.quantity_base THEN
      RAISE EXCEPTION 'POSTED_INVOICE_RETURN_QUANTITY_EXCEEDS_LINE: koreksi kumulatif melebihi qty Invoice';
    END IF;
    SELECT * INTO v_note FROM public.backoffice_sales_credit_notes note
    WHERE note.company_id=v_company AND note.return_id=p_return_id
      AND note.source_invoice_id=v_invoice.id AND note.status='DRAFT' FOR UPDATE;
    IF NOT FOUND THEN
      v_note_id:=gen_random_uuid();
      INSERT INTO public.backoffice_sales_credit_notes(id,company_id,return_id,
        source_invoice_id,customer_id,store_id,warehouse_id,credit_note_no,
        credit_note_date,currency_code,reason,source_invoice_snapshot,created_by,updated_by,
        charge_total,discount_total,tax_total,delivery_fee_amount,grand_total)
      VALUES(v_note_id,v_company,p_return_id,v_invoice.id,v_invoice.customer_id,
        v_invoice.store_id,v_invoice.warehouse_id,
        'CN-'||to_char((clock_timestamp() AT TIME ZONE (SELECT timezone FROM public.companies
          WHERE id=v_company))::date,'YYYYMMDD')||'-'||
          lpad(nextval('private.backoffice_sales_credit_note_no_seq')::text,10,'0'),
        (clock_timestamp() AT TIME ZONE (SELECT timezone FROM public.companies
          WHERE id=v_company))::date,v_invoice.currency_code,
        'Retur Customer '||v_return.return_no,
        private.backoffice_sales_invoice_snapshot(v_company,v_invoice.id),v_actor,v_actor,
        0,0,0,0,0);
      SELECT * INTO v_note FROM public.backoffice_sales_credit_notes note
      WHERE note.company_id=v_company AND note.id=v_note_id FOR UPDATE;
    ELSE
      v_note_id:=v_note.id;
      UPDATE public.backoffice_sales_credit_notes SET
        master_version=master_version+1,updated_by=v_actor,updated_at=clock_timestamp()
      WHERE company_id=v_company AND id=v_note_id
      RETURNING * INTO v_note;
    END IF;
    SELECT COALESCE(max(line_no),0)+1 INTO v_line_no
    FROM public.backoffice_sales_credit_note_lines
    WHERE company_id=v_company AND credit_note_id=v_note_id;
    v_ratio:=v_qty_base/v_invoice_line.quantity_base;
    SELECT round(COALESCE(sum(line.line_amount+line.discount_amount),0),4),
      round(COALESCE(sum(line.discount_amount),0),4),
      round(COALESCE(sum(line.tax_amount),0),4),
      round(COALESCE(sum(line.line_amount),0),4)
    INTO v_prior,v_discount,v_tax,v_line_amount
    FROM public.backoffice_sales_credit_note_lines line
    WHERE line.company_id=v_company AND line.source_invoice_line_id=v_invoice_line.id;
    v_charge:=CASE WHEN v_used+v_qty_base=v_invoice_line.quantity_base
      THEN v_invoice_line.line_amount+v_invoice_line.discount_amount-v_prior
      ELSE round((v_invoice_line.line_amount+v_invoice_line.discount_amount)*v_ratio,4) END;
    v_discount:=CASE WHEN v_used+v_qty_base=v_invoice_line.quantity_base
      THEN v_invoice_line.discount_amount-v_discount
      ELSE round(v_invoice_line.discount_amount*v_ratio,4) END;
    v_tax:=CASE WHEN v_used+v_qty_base=v_invoice_line.quantity_base
      THEN v_invoice_line.tax_amount-v_tax
      ELSE round(v_invoice_line.tax_amount*v_ratio,4) END;
    v_line_amount:=v_charge-v_discount;
    INSERT INTO public.backoffice_sales_credit_note_lines(company_id,credit_note_id,
      return_id,return_receipt_line_id,sales_order_line_id,source_invoice_line_id,
      line_no,product_id,uom_id,quantity_uom,base_qty_per_uom,quantity_base,
      unit_price,discount_amount,tax_amount,line_amount,source_snapshot)
    VALUES(v_company,v_note_id,p_return_id,v_receipt_line.id,v_order_line.id,
      v_invoice_line.id,v_line_no,v_invoice_line.product_id,v_invoice_line.uom_id,
      v_qty_uom,v_invoice_line.base_qty_per_uom,v_qty_base,v_invoice_line.unit_price,
      v_discount,v_tax,v_line_amount,
      v_invoice_line.source_snapshot||jsonb_build_object('sourceInvoiceId',v_invoice.id,
        'sourceInvoiceNo',v_invoice.invoice_no,'sourceInvoiceLineId',v_invoice_line.id));
    PERFORM private.recalculate_backoffice_sales_credit_note(v_company,v_note_id,v_actor);
    UPDATE public.backoffice_sales_order_lines SET
      returned_after_invoice_base_qty=returned_after_invoice_base_qty+v_qty_base,
      updated_at=clock_timestamp()
    WHERE company_id=v_company AND id=v_order_line.id;
    INSERT INTO public.backoffice_sales_return_invoice_allocations(company_id,return_id,
      return_receipt_line_id,sales_order_line_id,allocation_type,invoice_id,
      invoice_line_id,credit_note_id,allocated_base_qty,invoice_line_snapshot,
      operation_id,actor_id)
    VALUES(v_company,p_return_id,v_receipt_line.id,v_order_line.id,v_type,v_invoice.id,
      v_invoice_line.id,v_note_id,v_qty_base,to_jsonb(v_invoice_line),p_operation_id,v_actor);
  END LOOP;

  SELECT NOT EXISTS(
    SELECT 1 FROM public.backoffice_sales_return_receipt_lines receipt_line
    WHERE receipt_line.company_id=v_company AND receipt_line.return_id=p_return_id
      AND receipt_line.received_base_qty>COALESCE((SELECT sum(allocation.allocated_base_qty)
        FROM public.backoffice_sales_return_invoice_allocations allocation
        WHERE allocation.company_id=receipt_line.company_id
          AND allocation.return_receipt_line_id=receipt_line.id),0)
  ) INTO v_all_received;
  SELECT EXISTS(SELECT 1 FROM public.backoffice_sales_credit_notes note
    WHERE note.company_id=v_company AND note.return_id=p_return_id AND note.status='DRAFT')
  INTO v_has_draft_notes;
  UPDATE public.backoffice_sales_returns SET
    status=CASE WHEN v_all_received AND v_has_draft_notes THEN 'CREDIT_PENDING'
      WHEN v_all_received THEN 'COMPLETED' ELSE status END,
    master_version=master_version+1,updated_at=clock_timestamp()
  WHERE company_id=v_company AND id=p_return_id RETURNING * INTO v_return;
  v_response:=jsonb_build_object('companyId',v_company,'returnId',p_return_id,
    'returnStatus',v_return.status,'masterVersion',v_return.master_version,
    'allReceivedQuantityAllocated',v_all_received,
    'creditNotes',COALESCE((SELECT jsonb_agg(
      private.backoffice_sales_credit_note_snapshot(v_company,note.id)
      ORDER BY note.created_at,note.id)
      FROM public.backoffice_sales_credit_notes note
      WHERE note.company_id=v_company AND note.return_id=p_return_id),'[]'::jsonb),
    'exactRetry',false);
  INSERT INTO public.backoffice_sales_credit_note_operations(company_id,operation_id,
    operation_type,return_id,request_hash,response_snapshot,actor_id)
  VALUES(v_company,p_operation_id,'ALLOCATE_RETURN',p_return_id,v_hash,v_response,v_actor);
  INSERT INTO public.backoffice_sales_credit_note_audit(company_id,return_id,
    credit_note_id,operation_id,action,actor_id,after_state)
  VALUES(v_company,p_return_id,NULL,p_operation_id,'ALLOCATE_RETURN',v_actor,
    jsonb_build_object('returnId',p_return_id,'returnStatus',v_return.status,
      'masterVersion',v_return.master_version,'allocationCount',jsonb_array_length(p_allocations),
      'allReceivedQuantityAllocated',v_all_received));
  INSERT INTO public.backoffice_sales_credit_note_audit(company_id,return_id,
    credit_note_id,operation_id,action,actor_id,after_state)
  SELECT v_company,p_return_id,note.id,p_operation_id,'ALLOCATE_RETURN',v_actor,
    private.backoffice_sales_credit_note_snapshot(v_company,note.id)
  FROM public.backoffice_sales_credit_notes note
  WHERE note.company_id=v_company AND note.return_id=p_return_id AND note.status='DRAFT';
  RETURN v_response;
END
$$;

CREATE FUNCTION public.update_backoffice_sales_credit_note_draft(
  p_credit_note_id uuid,p_expected_version bigint,p_operation_id uuid,
  p_credit_note_date date,p_delivery_fee_amount numeric,p_reason text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='8s' AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
  v_note public.backoffice_sales_credit_notes%rowtype;v_hash text;v_retry jsonb;
  v_before jsonb;v_after jsonb;v_response jsonb;v_other_fee numeric(24,4);
  v_company_today date;
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'finance.customer_credit_notes','EDIT_DRAFT');
  IF p_credit_note_id IS NULL OR p_expected_version IS NULL OR p_operation_id IS NULL
    OR p_credit_note_date IS NULL OR p_delivery_fee_amount IS NULL
    OR p_delivery_fee_amount<0 OR nullif(btrim(p_reason),'') IS NULL THEN
    RAISE EXCEPTION 'CREDIT_NOTE_DRAFT_INPUT_INVALID: tanggal, alasan, dan ongkir tidak boleh kosong atau negatif';
  END IF;
  SELECT (clock_timestamp() AT TIME ZONE company.timezone)::date INTO v_company_today
  FROM public.companies company WHERE company.id=v_company AND company.status='ACTIVE';
  IF v_company_today IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_NOT_FOUND'; END IF;
  IF p_credit_note_date>v_company_today THEN
    RAISE EXCEPTION 'CREDIT_NOTE_DATE_FUTURE: tanggal Credit Note tidak boleh melewati tanggal Company';
  END IF;
  v_hash:=encode(extensions.digest(convert_to(jsonb_build_object(
    'creditNoteId',p_credit_note_id,'expectedVersion',p_expected_version,
    'creditNoteDate',p_credit_note_date,'deliveryFeeAmount',round(p_delivery_fee_amount,4),
    'reason',btrim(p_reason))::text,'UTF8'),'sha256'),'hex');
  PERFORM pg_advisory_xact_lock(hashtextextended(
    v_company::text||':CREDIT_NOTE:'||p_operation_id::text,0));
  v_retry:=private.backoffice_sales_credit_note_operation_retry(
    v_company,p_operation_id,'EDIT_DRAFT',v_hash);
  IF v_retry IS NOT NULL THEN RETURN v_retry; END IF;
  SELECT * INTO v_note FROM public.backoffice_sales_credit_notes note
  WHERE note.company_id=v_company AND note.id=p_credit_note_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'CREDIT_NOTE_NOT_FOUND: dokumen tidak ditemukan pada Company aktif'; END IF;
  IF v_note.status<>'DRAFT' THEN RAISE EXCEPTION 'CREDIT_NOTE_NOT_EDITABLE: hanya Draft Credit Note yang dapat diubah'; END IF;
  IF v_note.master_version<>p_expected_version THEN
    RAISE EXCEPTION 'MASTER_VERSION_CONFLICT: Credit Note sudah berubah, muat ulang sebelum menyimpan';
  END IF;
  SELECT round(COALESCE(sum(other.delivery_fee_amount),0),4) INTO v_other_fee
  FROM public.backoffice_sales_credit_notes other
  WHERE other.company_id=v_company AND other.source_invoice_id=v_note.source_invoice_id
    AND other.id<>v_note.id AND other.status IN('DRAFT','POSTED');
  IF v_other_fee+round(p_delivery_fee_amount,4)>
      COALESCE((v_note.source_invoice_snapshot->>'deliveryFeeAmount')::numeric,0) THEN
    RAISE EXCEPTION 'CREDIT_NOTE_DELIVERY_FEE_EXCEEDS_SOURCE: ongkir Credit Note kumulatif melebihi ongkir Invoice sumber';
  END IF;
  v_before:=private.backoffice_sales_credit_note_snapshot(v_company,v_note.id);
  UPDATE public.backoffice_sales_credit_notes SET credit_note_date=p_credit_note_date,
    delivery_fee_amount=round(p_delivery_fee_amount,4),reason=btrim(p_reason),
    master_version=master_version+1,updated_by=v_actor,updated_at=clock_timestamp()
  WHERE company_id=v_company AND id=v_note.id;
  PERFORM private.recalculate_backoffice_sales_credit_note(v_company,v_note.id,v_actor);
  v_after:=private.backoffice_sales_credit_note_snapshot(v_company,v_note.id);
  v_response:=jsonb_build_object('companyId',v_company,'data',v_after,'exactRetry',false);
  INSERT INTO public.backoffice_sales_credit_note_operations(company_id,operation_id,
    operation_type,return_id,credit_note_id,expected_version,request_hash,
    response_snapshot,actor_id)
  VALUES(v_company,p_operation_id,'EDIT_DRAFT',v_note.return_id,v_note.id,
    p_expected_version,v_hash,v_response,v_actor);
  INSERT INTO public.backoffice_sales_credit_note_audit(company_id,return_id,
    credit_note_id,operation_id,action,actor_id,before_state,after_state)
  VALUES(v_company,v_note.return_id,v_note.id,p_operation_id,'EDIT_DRAFT',v_actor,
    v_before,v_after);
  RETURN v_response;
END
$$;

CREATE FUNCTION public.post_backoffice_sales_credit_note(
  p_credit_note_id uuid,p_expected_version bigint,p_operation_id uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='15s' AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
  v_note public.backoffice_sales_credit_notes%rowtype;
  v_invoice public.backoffice_sales_invoices%rowtype;v_event public.financial_events%rowtype;
  v_period public.accounting_periods%rowtype;v_journal public.finance_journals%rowtype;
  v_category uuid;v_hash text;v_retry jsonb;v_before jsonb;v_after jsonb;v_response jsonb;
  v_paid numeric(24,4);v_prior_credit numeric(24,4);v_outstanding numeric(24,4);
  v_ar numeric(24,4);v_refund numeric(24,4);v_net numeric(24,4);
  v_account uuid;v_tax record;v_line_no integer:=0;v_journal_type text:='AUTOMATIC';
  v_accounting_date date;v_event_at timestamptz;v_timezone text;
  v_company_today date;v_latest_payment_date date;
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'finance.customer_credit_notes','POST');
  IF p_credit_note_id IS NULL OR p_expected_version IS NULL OR p_operation_id IS NULL THEN
    RAISE EXCEPTION 'CREDIT_NOTE_POST_INPUT_INVALID: pilih Draft Credit Note yang akan diposting';
  END IF;
  v_hash:=encode(extensions.digest(convert_to(jsonb_build_object(
    'creditNoteId',p_credit_note_id,'expectedVersion',p_expected_version)::text,
    'UTF8'),'sha256'),'hex');
  PERFORM pg_advisory_xact_lock(hashtextextended(
    v_company::text||':CREDIT_NOTE:'||p_operation_id::text,0));
  v_retry:=private.backoffice_sales_credit_note_operation_retry(
    v_company,p_operation_id,'POST',v_hash);
  IF v_retry IS NOT NULL THEN RETURN v_retry; END IF;
  SELECT * INTO v_note FROM public.backoffice_sales_credit_notes note
  WHERE note.company_id=v_company AND note.id=p_credit_note_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'CREDIT_NOTE_NOT_FOUND: dokumen tidak ditemukan pada Company aktif'; END IF;
  IF v_note.status<>'DRAFT' THEN RAISE EXCEPTION 'CREDIT_NOTE_NOT_POSTABLE: hanya Draft Credit Note yang dapat diposting'; END IF;
  IF v_note.master_version<>p_expected_version THEN
    RAISE EXCEPTION 'MASTER_VERSION_CONFLICT: Credit Note sudah berubah, muat ulang sebelum posting';
  END IF;
  SELECT * INTO STRICT v_invoice FROM public.backoffice_sales_invoices invoice
  WHERE invoice.company_id=v_company AND invoice.id=v_note.source_invoice_id
    AND invoice.status='POSTED' FOR UPDATE;
  IF NOT EXISTS(SELECT 1 FROM public.backoffice_sales_credit_note_lines line
    WHERE line.company_id=v_company AND line.credit_note_id=v_note.id) THEN
    RAISE EXCEPTION 'CREDIT_NOTE_LINES_REQUIRED: Credit Note belum mempunyai alokasi Product';
  END IF;
  SELECT company.timezone,(clock_timestamp() AT TIME ZONE company.timezone)::date
  INTO v_timezone,v_company_today FROM public.companies company
  WHERE company.id=v_company AND company.status='ACTIVE';
  IF v_timezone IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_NOT_FOUND'; END IF;
  IF v_note.credit_note_date>v_company_today THEN
    RAISE EXCEPTION 'CREDIT_NOTE_DATE_FUTURE: tanggal Credit Note tidak boleh melewati tanggal Company';
  END IF;
  SELECT round(COALESCE(sum(allocation.allocated_amount),0),4),max(receipt.receipt_date)
  INTO v_paid,v_latest_payment_date
  FROM public.customer_receipt_backoffice_invoice_allocations allocation
  JOIN public.customer_receipt_documents receipt
    ON receipt.company_id=allocation.company_id AND receipt.id=allocation.document_id
   AND receipt.status='POSTED'
  WHERE allocation.company_id=v_company AND allocation.invoice_id=v_invoice.id;
  IF v_latest_payment_date IS NOT NULL AND v_latest_payment_date>v_note.credit_note_date THEN
    RAISE EXCEPTION 'CREDIT_NOTE_DATE_BEFORE_PAYMENT: tanggal Credit Note harus sama atau setelah pembayaran terakhir Invoice';
  END IF;
  SELECT round(COALESCE(sum(other.grand_total),0),4) INTO v_prior_credit
  FROM public.backoffice_sales_credit_notes other
  WHERE other.company_id=v_company AND other.source_invoice_id=v_invoice.id
    AND other.status='POSTED';
  IF v_prior_credit+v_note.grand_total>v_invoice.grand_total THEN
    RAISE EXCEPTION 'CREDIT_NOTE_AMOUNT_EXCEEDS_INVOICE: koreksi kumulatif melebihi nilai Invoice sumber';
  END IF;
  v_outstanding:=greatest(0,round(v_invoice.grand_total-v_paid-v_prior_credit,4));
  v_ar:=least(v_note.grand_total,v_outstanding);v_refund:=v_note.grand_total-v_ar;
  v_event_at:=(v_note.credit_note_date::text||' 12:00:00')::timestamp AT TIME ZONE v_timezone;
  SELECT * INTO v_period FROM public.accounting_periods period
  WHERE period.company_id=v_company AND v_note.credit_note_date
    BETWEEN period.start_date AND period.end_date
    AND period.status IN('OPEN','REOPENED') ORDER BY period.start_date LIMIT 1 FOR SHARE;
  IF NOT FOUND THEN
    SELECT * INTO v_period FROM public.accounting_periods period
    WHERE period.company_id=v_company AND period.start_date>v_note.credit_note_date
      AND period.status IN('OPEN','REOPENED') ORDER BY period.start_date LIMIT 1 FOR SHARE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'POSTABLE_ACCOUNTING_PERIOD_NOT_FOUND: buka periode Credit Note atau periode penyesuaian berikutnya';
    END IF;
    v_journal_type:='PRIOR_PERIOD_ADJUSTMENT';v_accounting_date:=v_period.start_date;
  ELSE v_accounting_date:=v_note.credit_note_date; END IF;
  SELECT category.id INTO v_category FROM public.transaction_categories category
  WHERE category.company_id=v_company AND category.system_key='CUSTOMER_CREDIT_NOTE'
    AND category.is_active ORDER BY category.is_system_default DESC,category.id LIMIT 1;
  IF v_category IS NULL THEN
    RAISE EXCEPTION 'CUSTOMER_CREDIT_NOTE_CATEGORY_REQUIRED: aktifkan kategori transaksi Credit Note Customer';
  END IF;
  v_before:=private.backoffice_sales_credit_note_snapshot(v_company,v_note.id);
  INSERT INTO public.financial_events(event_code,event_type,source_table,source_id,event_date,
    event_version,idempotency_key,amounts,status,error_message,created_by,company_id,
    store_id,system_event_key,transaction_category_id,transaction_rule_version)
  VALUES('BO-CN-'||replace(v_note.id::text,'-',''),'SALE_REVISED'::public.event_type,
    'backoffice_sales_credit_notes',v_note.id,v_event_at,1,
    'BACKOFFICE_CREDIT_NOTE|'||v_company||'|'||v_note.id||'|'||p_operation_id,
    jsonb_build_object('creditNoteId',v_note.id,'returnId',v_note.return_id,
      'sourceInvoiceId',v_invoice.id,'grandTotal',v_note.grand_total,
      'arReductionAmount',v_ar,'refundLiabilityAmount',v_refund,
      'financePostingState','HOLD'),
    'HOLD'::public.event_status,'CANONICAL_FINANCE_POSTING_PENDING',v_actor,
    v_company,v_note.store_id,'CUSTOMER_CREDIT_NOTE',v_category,20260917131000)
  RETURNING * INTO v_event;
  INSERT INTO public.finance_journals(company_id,journal_no,journal_type,
    accounting_period_id,accounting_date,original_event_date,source_type,source_id,
    source_version,financial_event_id,idempotency_key,system_event_key,
    transaction_category_id,transaction_rule_version,store_id,warehouse_id,
    description,status,created_by)
  VALUES(v_company,'CNJ-'||replace(v_note.id::text,'-',''),v_journal_type,
    v_period.id,v_accounting_date,v_note.credit_note_date,
    'backoffice_sales_credit_notes',v_note.id,v_note.master_version,v_event.id,
    'BACKOFFICE_CREDIT_NOTE_JOURNAL|'||v_company||'|'||v_note.id,
    'CUSTOMER_CREDIT_NOTE',v_category,20260917131000,v_note.store_id,
    v_note.warehouse_id,'Credit Note Customer '||v_note.credit_note_no,'DRAFT',v_actor)
  RETURNING * INTO v_journal;
  v_net:=round(v_note.charge_total-v_note.discount_total,4);
  IF v_net>0 THEN
    v_account:=private.resolve_financial_event_account(v_event,'SALES_RETURN_DISCOUNT');
    v_line_no:=v_line_no+10;
    INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,account_id,
      debit,credit,store_id,warehouse_id,customer_id,description)
    VALUES(v_company,v_journal.id,v_line_no,v_account,v_net,0,v_note.store_id,
      v_note.warehouse_id,v_note.customer_id,'Retur dan potongan penjualan');
  END IF;
  FOR v_tax IN SELECT (line.source_snapshot->>'taxAccountId')::uuid account_id,
      sum(line.tax_amount) amount
    FROM public.backoffice_sales_credit_note_lines line
    WHERE line.company_id=v_company AND line.credit_note_id=v_note.id
      AND line.tax_amount>0
    GROUP BY (line.source_snapshot->>'taxAccountId')::uuid
  LOOP
    IF v_tax.account_id IS NULL OR NOT EXISTS(SELECT 1 FROM public.chart_of_accounts account
      WHERE account.company_id=v_company AND account.id=v_tax.account_id
        AND account.is_active AND account.is_postable) THEN
      RAISE EXCEPTION 'CREDIT_NOTE_SOURCE_TAX_ACCOUNT_INVALID: snapshot Pajak Invoice tidak dapat diposting';
    END IF;
    v_line_no:=v_line_no+10;
    INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,account_id,
      debit,credit,store_id,warehouse_id,customer_id,description)
    VALUES(v_company,v_journal.id,v_line_no,v_tax.account_id,v_tax.amount,0,
      v_note.store_id,v_note.warehouse_id,v_note.customer_id,'Pembalik Pajak Keluaran');
  END LOOP;
  IF v_note.delivery_fee_amount>0 THEN
    v_account:=private.resolve_financial_event_account(v_event,'DELIVERY_FEE_REVENUE');
    v_line_no:=v_line_no+10;
    INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,account_id,
      debit,credit,store_id,warehouse_id,customer_id,description)
    VALUES(v_company,v_journal.id,v_line_no,v_account,v_note.delivery_fee_amount,0,
      v_note.store_id,v_note.warehouse_id,v_note.customer_id,'Koreksi ongkir');
  END IF;
  IF v_ar>0 THEN
    v_account:=private.resolve_financial_event_account(v_event,'CUSTOMER_RECEIVABLE');
    v_line_no:=v_line_no+10;
    INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,account_id,
      debit,credit,store_id,warehouse_id,customer_id,description)
    VALUES(v_company,v_journal.id,v_line_no,v_account,0,v_ar,v_note.store_id,
      v_note.warehouse_id,v_note.customer_id,'Pengurang Piutang Customer');
  END IF;
  IF v_refund>0 THEN
    v_account:=private.resolve_financial_event_account(v_event,'CUSTOMER_REFUND_LIABILITY');
    v_line_no:=v_line_no+10;
    INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,account_id,
      debit,credit,store_id,warehouse_id,customer_id,description)
    VALUES(v_company,v_journal.id,v_line_no,v_account,0,v_refund,v_note.store_id,
      v_note.warehouse_id,v_note.customer_id,'Utang Refund Customer');
  END IF;
  UPDATE public.finance_journals SET status='POSTED',posted_by=v_actor,
    posted_at=clock_timestamp() WHERE company_id=v_company AND id=v_journal.id
    RETURNING * INTO v_journal;
  IF round(v_journal.total_debit,4)<>round(v_note.grand_total,4)
    OR round(v_journal.total_credit,4)<>round(v_note.grand_total,4) THEN
    RAISE EXCEPTION 'JOURNAL_UNBALANCED: nilai debit dan kredit Credit Note tidak seimbang';
  END IF;
  UPDATE public.financial_events SET status='POSTED'::public.event_status,
    processed_at=clock_timestamp(),error_message=NULL,
    transaction_rule_version=20260917131000
  WHERE company_id=v_company AND id=v_event.id;
  UPDATE public.backoffice_sales_credit_notes SET status='POSTED',
    ar_reduction_amount=v_ar,refund_liability_amount=v_refund,
    financial_event_id=v_event.id,posted_by=v_actor,posted_at=clock_timestamp(),
    master_version=master_version+1,updated_by=v_actor,updated_at=clock_timestamp()
  WHERE company_id=v_company AND id=v_note.id;
  PERFORM private.reconcile_backoffice_invoice_receivable_schedule(v_company,v_invoice.id);
  UPDATE public.backoffice_sales_returns document SET
    status=CASE WHEN EXISTS(SELECT 1 FROM public.backoffice_sales_credit_notes note
          WHERE note.company_id=v_company AND note.return_id=document.id
            AND note.status='DRAFT') THEN 'CREDIT_PENDING'
      WHEN EXISTS(SELECT 1 FROM public.backoffice_sales_credit_notes note
          WHERE note.company_id=v_company AND note.return_id=document.id
            AND note.status='POSTED' AND note.refund_liability_amount>0)
        THEN 'REFUND_PENDING' ELSE 'COMPLETED' END,
    master_version=master_version+1,updated_at=clock_timestamp()
  WHERE document.company_id=v_company AND document.id=v_note.return_id;
  v_after:=private.backoffice_sales_credit_note_snapshot(v_company,v_note.id);
  v_response:=jsonb_build_object('companyId',v_company,'data',v_after,
    'finance',jsonb_build_object('financialEventId',v_event.id,'journalId',v_journal.id,
      'journalNo',v_journal.journal_no,'accountingDate',v_journal.accounting_date,
      'journalType',v_journal.journal_type),
    'exactRetry',false);
  INSERT INTO public.backoffice_sales_credit_note_operations(company_id,operation_id,
    operation_type,return_id,credit_note_id,expected_version,request_hash,
    response_snapshot,actor_id)
  VALUES(v_company,p_operation_id,'POST',v_note.return_id,v_note.id,p_expected_version,
    v_hash,v_response,v_actor);
  INSERT INTO public.backoffice_sales_credit_note_audit(company_id,return_id,
    credit_note_id,operation_id,action,actor_id,before_state,after_state)
  VALUES(v_company,v_note.return_id,v_note.id,p_operation_id,'POST',v_actor,v_before,v_after);
  RETURN v_response;
END
$$;

CREATE FUNCTION public.get_backoffice_sales_credit_note(p_credit_note_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_data jsonb;
BEGIN
  PERFORM private.acp_require_permission_capability(v_company,'finance.customer_credit_notes','VIEW');
  v_data:=private.backoffice_sales_credit_note_snapshot(v_company,p_credit_note_id);
  IF v_data IS NULL THEN RAISE EXCEPTION 'CREDIT_NOTE_NOT_FOUND: dokumen tidak ditemukan pada Company aktif'; END IF;
  RETURN jsonb_build_object('companyId',v_company,'data',v_data);
END
$$;

CREATE FUNCTION public.get_backoffice_sales_return_invoice_reconciliation(p_return_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(v_company,'finance.customer_credit_notes','VIEW');
  IF NOT EXISTS(SELECT 1 FROM public.backoffice_sales_returns document
    WHERE document.company_id=v_company AND document.id=p_return_id) THEN
    RAISE EXCEPTION 'RETURN_NOT_FOUND: dokumen Retur tidak ditemukan pada Company aktif';
  END IF;
  RETURN jsonb_build_object('companyId',v_company,'returnId',p_return_id,
    'receiptLines',COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'returnReceiptLineId',line.id,'returnLineId',line.return_line_id,
      'productId',line.product_id,'uomId',line.uom_id,
      'receivedQtyUom',line.received_qty_uom,'receivedBaseQty',line.received_base_qty,
      'allocatedBaseQty',COALESCE((SELECT sum(allocation.allocated_base_qty)
        FROM public.backoffice_sales_return_invoice_allocations allocation
        WHERE allocation.company_id=line.company_id
          AND allocation.return_receipt_line_id=line.id),0),
      'remainingBaseQty',line.received_base_qty-COALESCE((SELECT sum(allocation.allocated_base_qty)
        FROM public.backoffice_sales_return_invoice_allocations allocation
        WHERE allocation.company_id=line.company_id
          AND allocation.return_receipt_line_id=line.id),0)
    ) ORDER BY line.created_at,line.id)
    FROM public.backoffice_sales_return_receipt_lines line
    WHERE line.company_id=v_company AND line.return_id=p_return_id),'[]'::jsonb),
    'creditNotes',COALESCE((SELECT jsonb_agg(
      private.backoffice_sales_credit_note_snapshot(v_company,note.id)
      ORDER BY note.created_at,note.id)
      FROM public.backoffice_sales_credit_notes note
      WHERE note.company_id=v_company AND note.return_id=p_return_id),'[]'::jsonb));
END
$$;

REVOKE ALL ON FUNCTION
  private.backoffice_sales_invoice_snapshot_before_return_credit(uuid,uuid),
  private.provision_backoffice_credit_note_account_fallbacks(uuid,uuid),
  private.trg_provision_backoffice_credit_note_account_fallbacks(),
  private.backoffice_sales_credit_note_snapshot(uuid,uuid),
  private.backoffice_sales_credit_note_operation_retry(uuid,uuid,text,text),
  private.recalculate_backoffice_sales_credit_note(uuid,uuid,uuid),
  private.reconcile_backoffice_invoice_receivable_schedule(uuid,uuid),
  private.backoffice_invoice_receivable_before_receipts(uuid,uuid,date)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.backoffice_sales_invoice_snapshot_before_return_credit(uuid,uuid),
  private.provision_backoffice_credit_note_account_fallbacks(uuid,uuid),
  private.trg_provision_backoffice_credit_note_account_fallbacks(),
  private.backoffice_sales_credit_note_snapshot(uuid,uuid),
  private.backoffice_sales_credit_note_operation_retry(uuid,uuid,text,text),
  private.recalculate_backoffice_sales_credit_note(uuid,uuid,uuid),
  private.reconcile_backoffice_invoice_receivable_schedule(uuid,uuid),
  private.backoffice_invoice_receivable_before_receipts(uuid,uuid,date)
TO service_role;
REVOKE ALL ON FUNCTION
  public.allocate_backoffice_sales_return_invoices(uuid,bigint,uuid,jsonb),
  public.update_backoffice_sales_credit_note_draft(uuid,bigint,uuid,date,numeric,text),
  public.post_backoffice_sales_credit_note(uuid,bigint,uuid),
  public.get_backoffice_sales_credit_note(uuid),
  public.get_backoffice_sales_return_invoice_reconciliation(uuid)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION
  public.allocate_backoffice_sales_return_invoices(uuid,bigint,uuid,jsonb),
  public.update_backoffice_sales_credit_note_draft(uuid,bigint,uuid,date,numeric,text),
  public.post_backoffice_sales_credit_note(uuid,bigint,uuid),
  public.get_backoffice_sales_credit_note(uuid),
  public.get_backoffice_sales_return_invoice_reconciliation(uuid)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260917131000','backoffice_sales_return_credit_note_runtime',
  'Step 3/5 explicit Finance allocation, Draft Invoice adjustment, source-snapshot Customer Credit Note and atomic AR/refund-liability journal; no Refund settlement');
NOTIFY pgrst,'reload schema';
COMMIT;
