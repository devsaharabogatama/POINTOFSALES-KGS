-- STAGING DEVELOPMENT CANDIDATE. Produces exact balanced journal legs only;
-- no Finance Event, Journal, revision, settlement or source document is written.
CREATE FUNCTION private.plan_backoffice_invoice_revision_journals(p_operation_id uuid)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path=pg_catalog,public,pg_temp AS $journal_plan$
DECLARE
  v_company uuid:=public.private_active_company_id();v_execution jsonb;
  v_preparation private.backoffice_invoice_revision_preparations%rowtype;
  v_invoice public.backoffice_sales_invoices%rowtype;v_event public.financial_events%rowtype;
  v_source_journal public.finance_journals%rowtype;v_new_customer uuid;v_new_date date;
  v_ar uuid;v_advance uuid;v_reversal jsonb;v_replacement jsonb;
  v_receipt_legs jsonb:='[]'::jsonb;v_dp_legs jsonb:='[]'::jsonb;
  v_amount_legs jsonb:='[]'::jsonb;v_item jsonb;v_amount numeric(24,4);
  v_debit numeric(24,4);v_credit numeric(24,4);v_group record;
  v_paid numeric(24,4);v_credited numeric(24,4);v_before_total numeric(24,4);
  v_after_total numeric(24,4);v_prior_net numeric(24,4);v_after_net numeric(24,4);
  v_ar_delta numeric(24,4);v_refund_delta numeric(24,4);v_refund uuid;
  v_current_customer uuid;v_current_date date;v_current_identity jsonb;
BEGIN
  v_execution:=private.plan_backoffice_invoice_revision_execution(p_operation_id);
  SELECT * INTO STRICT v_preparation FROM private.backoffice_invoice_revision_preparations p
    WHERE p.company_id=v_company AND p.operation_id=p_operation_id;
  SELECT * INTO STRICT v_invoice FROM public.backoffice_sales_invoices i
    WHERE i.company_id=v_company AND i.id=v_preparation.invoice_id;
  SELECT * INTO STRICT v_event FROM public.financial_events e
    WHERE e.company_id=v_company AND e.id=v_invoice.financial_event_id;
  SELECT * INTO STRICT v_source_journal FROM public.finance_journals j
    WHERE j.company_id=v_company AND j.id=(v_execution->'journal'->>'sourceJournalId')::uuid;
  v_new_customer:=(v_execution->>'toCustomerId')::uuid;
  v_new_date:=(v_execution->>'toInvoiceDate')::date;
  v_current_customer:=v_invoice.customer_id;v_current_date:=v_invoice.invoice_date;
  IF to_regprocedure('private.backoffice_invoice_effective_identity(uuid,uuid,date)') IS NOT NULL THEN
    EXECUTE 'SELECT private.backoffice_invoice_effective_identity($1,$2,NULL)'
      INTO v_current_identity USING v_company,v_invoice.id;
    v_current_customer:=(v_current_identity->>'customerId')::uuid;
    v_current_date:=(v_current_identity->>'invoiceDate')::date;
  END IF;
  v_ar:=private.resolve_financial_event_account(v_event,'CUSTOMER_RECEIVABLE');
  v_advance:=private.resolve_financial_event_account(v_event,'CUSTOMER_ADVANCE_LIABILITY');
  SELECT round(COALESCE(sum(a.allocated_amount),0),4) INTO v_paid
  FROM public.customer_receipt_backoffice_invoice_allocations a
  JOIN public.customer_receipt_documents r ON r.company_id=a.company_id AND r.id=a.document_id
    AND r.status='POSTED'
  WHERE a.company_id=v_company AND a.invoice_id=v_invoice.id;
  SELECT round(COALESCE(sum(n.ar_reduction_amount),0),4) INTO v_credited
  FROM public.backoffice_sales_credit_notes n
  WHERE n.company_id=v_company AND n.source_invoice_id=v_invoice.id AND n.status='POSTED';
  v_before_total:=(v_execution->'amounts'->>'beforeTotal')::numeric;
  v_after_total:=(v_execution->'amounts'->>'afterTotal')::numeric;
  v_prior_net:=v_before_total-v_paid-v_credited;v_after_net:=v_after_total-v_paid-v_credited;
  v_ar_delta:=greatest(v_after_net,0)-greatest(v_prior_net,0);
  v_refund_delta:=greatest(-v_after_net,0)-greatest(-v_prior_net,0);
  IF round(v_ar_delta-v_refund_delta,4)<>(v_execution->'amounts'->>'payableDelta')::numeric THEN
    RAISE EXCEPTION 'INVOICE_REVISION_SETTLEMENT_SPLIT_INVALID';
  END IF;

  IF v_current_customer<>v_new_customer OR v_current_date<>v_new_date THEN
   SELECT COALESCE(jsonb_agg(jsonb_build_object('lineNo',l.line_no,'accountId',l.account_id,
      'debit',l.credit,'credit',l.debit,'customerId',l.customer_id,
      'storeId',l.store_id,'warehouseId',l.warehouse_id,
      'description',COALESCE(l.description,'')||' [INVOICE REVISION REVERSAL]') ORDER BY l.line_no),'[]'::jsonb)
  INTO v_reversal FROM public.finance_journal_lines l
  WHERE l.company_id=v_company AND l.journal_id=v_source_journal.id;
  SELECT COALESCE(jsonb_agg(jsonb_build_object('lineNo',l.line_no,'accountId',l.account_id,
      'debit',l.debit,'credit',l.credit,
      'customerId',CASE WHEN l.customer_id IS NULL THEN NULL ELSE v_new_customer END,
      'storeId',l.store_id,'warehouseId',l.warehouse_id,
      'description',COALESCE(l.description,'')||' [INVOICE REVISION REPLACEMENT]') ORDER BY l.line_no),'[]'::jsonb)
  INTO v_replacement FROM public.finance_journal_lines l
  WHERE l.company_id=v_company AND l.journal_id=v_source_journal.id;
  ELSE
   v_reversal:='[]'::jsonb;v_replacement:='[]'::jsonb;
  END IF;

  FOR v_item IN SELECT value FROM jsonb_array_elements(v_execution->'receipts') ORDER BY value->>'receiptId' LOOP
    IF v_item->>'action'='TRANSFER_TO_ADVANCE_THEN_APPLY'
      AND (v_current_customer<>v_new_customer OR v_current_date<>v_new_date) THEN
      v_amount:=(v_item->>'allocatedAmount')::numeric;
      v_receipt_legs:=v_receipt_legs||jsonb_build_array(
        jsonb_build_object('leg','RECEIPT_TO_ADVANCE','accountingDate',v_item->>'receiptDate',
          'sourceId',v_item->>'allocationId','lines',jsonb_build_array(
            jsonb_build_object('accountId',v_ar,'debit',v_amount,'credit',0,
              'customerId',v_current_customer,'description','Batalkan pelunasan Piutang sebelum tanggal Invoice revisi'),
            jsonb_build_object('accountId',v_advance,'debit',0,'credit',v_amount,
              'customerId',v_new_customer,'description','Pembayaran menjadi Uang Muka Customer'))),
        jsonb_build_object('leg','ADVANCE_TO_REVISED_INVOICE','accountingDate',v_new_date,
          'sourceId',v_item->>'allocationId','lines',jsonb_build_array(
            jsonb_build_object('accountId',v_advance,'debit',v_amount,'credit',0,
              'customerId',v_new_customer,'description','Aplikasi Uang Muka pada Invoice revisi'),
            jsonb_build_object('accountId',v_ar,'debit',0,'credit',v_amount,
              'customerId',v_new_customer,'description','Pelunasan Piutang Invoice revisi'))));
    ELSIF v_item->>'action'='TRANSFER_POSTED_AR_ATTRIBUTION' AND v_current_customer<>v_new_customer THEN
      v_amount:=(v_item->>'allocatedAmount')::numeric;
      v_receipt_legs:=v_receipt_legs||jsonb_build_array(jsonb_build_object(
        'leg','TRANSFER_POSTED_AR_ATTRIBUTION','accountingDate',v_item->>'receiptDate',
        'sourceId',v_item->>'allocationId','lines',jsonb_build_array(
          jsonb_build_object('accountId',v_ar,'debit',v_amount,'credit',0,
            'customerId',v_current_customer,'description','Pindahkan pelunasan dari customer lama'),
          jsonb_build_object('accountId',v_ar,'debit',0,'credit',v_amount,
            'customerId',v_new_customer,'description','Pindahkan pelunasan ke customer Invoice'))));
    END IF;
  END LOOP;
  FOR v_item IN SELECT value FROM jsonb_array_elements(v_execution->'downPayments') ORDER BY value->>'applicationId' LOOP
    IF v_item->>'action'='TRANSFER_POSTED_DP_ATTRIBUTION' AND v_current_customer<>v_new_customer THEN
      v_amount:=(v_item->>'appliedAmount')::numeric;
      v_dp_legs:=v_dp_legs||jsonb_build_array(jsonb_build_object('leg','TRANSFER_DP_ATTRIBUTION',
        'accountingDate',v_new_date,'sourceId',v_item->>'applicationId','lines',jsonb_build_array(
          jsonb_build_object('accountId',v_advance,'debit',v_amount,'credit',0,
            'customerId',(v_item->>'fromCustomerId')::uuid,'description','Pindahkan DP dari customer lama'),
          jsonb_build_object('accountId',v_advance,'debit',0,'credit',v_amount,
            'customerId',v_new_customer,'description','Pindahkan DP ke customer Invoice'))));
    END IF;
  END LOOP;

  -- Amount leg uses exact preview deltas. Tax stays on the original per-line
  -- account; gross revenue and discount use canonical Invoice-event mappings.
  IF (v_execution->'amounts'->>'grossRevenueDelta')::numeric<>0 THEN
    v_amount:=(v_execution->'amounts'->>'grossRevenueDelta')::numeric;
    v_amount_legs:=v_amount_legs||jsonb_build_array(jsonb_build_object('accountId',
      private.resolve_financial_event_account(v_event,'SALES_REVENUE'),
      'debit',greatest(-v_amount,0),'credit',greatest(v_amount,0),'customerId',v_new_customer,
      'description','Delta Pendapatan koreksi Invoice'));
  END IF;
  IF (v_execution->'amounts'->>'salesDiscountDelta')::numeric<>0 THEN
    v_amount:=(v_execution->'amounts'->>'salesDiscountDelta')::numeric;
    v_amount_legs:=v_amount_legs||jsonb_build_array(jsonb_build_object('accountId',
      private.resolve_financial_event_account(v_event,'SALES_DISCOUNT'),
      'debit',greatest(v_amount,0),'credit',greatest(-v_amount,0),'customerId',v_new_customer,
      'description','Delta Potongan Penjualan koreksi Invoice'));
  END IF;
  FOR v_group IN
    SELECT NULLIF(line->>'taxAccountId','')::uuid account_id,
      round(sum((line->'after'->>'taxAmount')::numeric-(line->'before'->>'taxAmount')::numeric),4) amount
    FROM jsonb_array_elements(v_execution->'amounts'->'lines') line
    GROUP BY NULLIF(line->>'taxAccountId','')::uuid
  LOOP
    IF v_group.amount<>0 THEN
      IF v_group.account_id IS NULL THEN RAISE EXCEPTION 'INVOICE_REVISION_TAX_ACCOUNT_REQUIRED'; END IF;
      v_amount_legs:=v_amount_legs||jsonb_build_array(jsonb_build_object('accountId',v_group.account_id,
        'debit',greatest(-v_group.amount,0),'credit',greatest(v_group.amount,0),
        'customerId',v_new_customer,'description','Delta Pajak Keluaran koreksi Invoice'));
    END IF;
  END LOOP;
  IF v_ar_delta<>0 THEN
    v_amount:=v_ar_delta;
    v_amount_legs:=v_amount_legs||jsonb_build_array(jsonb_build_object('accountId',v_ar,
      'debit',greatest(v_amount,0),'credit',greatest(-v_amount,0),'customerId',v_new_customer,
      'description','Delta Piutang koreksi Invoice'));
  END IF;
  IF v_refund_delta<>0 THEN
    v_refund:=private.resolve_financial_event_account(v_event,'CUSTOMER_REFUND_LIABILITY');
    v_amount:=v_refund_delta;
    v_amount_legs:=v_amount_legs||jsonb_build_array(jsonb_build_object('accountId',v_refund,
      'debit',greatest(-v_amount,0),'credit',greatest(v_amount,0),'customerId',v_new_customer,
      'description','Delta Utang Refund koreksi Invoice'));
  END IF;

  FOR v_item IN SELECT value FROM jsonb_array_elements(jsonb_build_array(
      jsonb_build_object('lines',v_reversal),jsonb_build_object('lines',v_replacement))
      ||v_receipt_legs||v_dp_legs||jsonb_build_array(jsonb_build_object('lines',v_amount_legs))) LOOP
    SELECT round(COALESCE(sum((line->>'debit')::numeric),0),4),
      round(COALESCE(sum((line->>'credit')::numeric),0),4)
    INTO v_debit,v_credit FROM jsonb_array_elements(v_item->'lines') line;
    IF v_debit<>v_credit THEN RAISE EXCEPTION 'INVOICE_REVISION_JOURNAL_PLAN_UNBALANCED'; END IF;
  END LOOP;
  RETURN v_execution||jsonb_build_object('status','JOURNAL_PLAN_NOT_POSTED',
    'recognitionReversal',jsonb_build_object('accountingDate',v_source_journal.accounting_date,
      'periodId',v_source_journal.accounting_period_id,'sourceJournalId',v_source_journal.id,'lines',v_reversal),
    'recognitionReplacement',jsonb_build_object('accountingDate',v_new_date,
      'periodId',v_execution->'dates'->>'periodId','lines',v_replacement),
    'receiptJournalLegs',v_receipt_legs,'downPaymentJournalLegs',v_dp_legs,
    'amountJournal',jsonb_build_object('accountingDate',v_new_date,'lines',v_amount_legs,
      'paidAmount',v_paid,'creditedAmount',v_credited,'arDelta',v_ar_delta,
      'refundLiabilityDelta',v_refund_delta),
    'writerEffect',false);
END
$journal_plan$;
REVOKE ALL ON FUNCTION private.plan_backoffice_invoice_revision_journals(uuid)
  FROM PUBLIC,anon,authenticated,service_role;
