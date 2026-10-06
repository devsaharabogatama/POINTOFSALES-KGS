-- STAGING DEVELOPMENT CANDIDATE. This routine locks and revalidates the exact
-- dependencies needed by a future writer, but deliberately performs no write.
CREATE FUNCTION private.plan_backoffice_invoice_revision_execution(p_operation_id uuid)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path=pg_catalog,public,pg_temp AS $plan$
DECLARE
  v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
  v_preparation private.backoffice_invoice_revision_preparations%rowtype;
  v_invoice public.backoffice_sales_invoices%rowtype;v_customer uuid;v_date date;
  v_old_period public.accounting_periods%rowtype;v_new_period public.accounting_periods%rowtype;
  v_receipts jsonb;v_dp jsonb;v_journal jsonb;v_receipt_id uuid;v_dp_id uuid;
  v_posted_receipt numeric(24,4);v_advance numeric(24,4);v_draft_receipt numeric(24,4);
  v_dp_total numeric(24,4);v_source_journal uuid;
  v_missing_receipt_period bigint;v_missing_receipt_accounts bigint;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF p_operation_id IS NULL THEN RAISE EXCEPTION 'INVOICE_REVISION_OPERATION_REQUIRED'; END IF;
  PERFORM private.acp_require_permission_capability(v_company,'sales.backoffice_orders','EDIT_DRAFT');
  PERFORM private.require_backoffice_sales_invoice_post_permission(v_company);
  SELECT * INTO v_preparation FROM private.backoffice_invoice_revision_preparations p
    WHERE p.company_id=v_company AND p.operation_id=p_operation_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'INVOICE_REVISION_PREPARATION_NOT_FOUND'; END IF;
  IF v_preparation.actor_id<>v_actor THEN RAISE EXCEPTION 'INVOICE_REVISION_PREPARATION_ACTOR_MISMATCH'; END IF;
  v_customer:=(v_preparation.request_snapshot->>'customerId')::uuid;
  v_date:=(v_preparation.request_snapshot->>'invoiceDate')::date;

  -- Canonical Receipt writers lock Receipt before Invoice. Match that order and
  -- sort IDs so multiple shared documents cannot invert each other.
  FOR v_receipt_id IN
    SELECT DISTINCT a.document_id
    FROM public.customer_receipt_backoffice_invoice_allocations a
    WHERE a.company_id=v_company AND a.invoice_id=v_preparation.invoice_id
    ORDER BY a.document_id
  LOOP
    PERFORM 1 FROM public.customer_receipt_documents r
      WHERE r.company_id=v_company AND r.id=v_receipt_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'INVOICE_REVISION_RECEIPT_DEPENDENCY_MISSING'; END IF;
  END LOOP;
  SELECT * INTO v_invoice FROM public.backoffice_sales_invoices i
    WHERE i.company_id=v_company AND i.id=v_preparation.invoice_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_NOT_FOUND'; END IF;
  FOR v_dp_id IN
    SELECT DISTINCT a.down_payment_invoice_id
    FROM public.backoffice_sales_down_payment_applications a
    WHERE a.company_id=v_company AND a.regular_invoice_id=v_invoice.id
    ORDER BY a.down_payment_invoice_id
  LOOP
    PERFORM 1 FROM public.backoffice_sales_invoices i
      WHERE i.company_id=v_company AND i.id=v_dp_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'INVOICE_REVISION_DP_DEPENDENCY_MISSING'; END IF;
  END LOOP;
  SELECT * INTO v_old_period FROM public.accounting_periods p
    WHERE p.company_id=v_company AND v_invoice.invoice_date BETWEEN p.start_date AND p.end_date
    ORDER BY p.start_date DESC,p.id LIMIT 1 FOR UPDATE;
  SELECT * INTO v_new_period FROM public.accounting_periods p
    WHERE p.company_id=v_company AND v_date BETWEEN p.start_date AND p.end_date
    ORDER BY p.start_date DESC,p.id LIMIT 1 FOR UPDATE;
  IF v_old_period.id IS NULL OR v_new_period.id IS NULL
    OR v_old_period.status NOT IN('OPEN','REOPENED') OR v_new_period.status NOT IN('OPEN','REOPENED') THEN
    RAISE EXCEPTION 'INVOICE_REVISION_ACCOUNTING_PERIOD_LOCKED';
  END IF;
  PERFORM private.assert_backoffice_invoice_revision_preparation_fresh(p_operation_id);

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'receiptId',r.id,'receiptNo',r.receipt_no,'status',r.status,
      'receiptCustomerId',r.customer_id,'receiptDate',r.receipt_date,
      'allocationId',a.id,'allocatedAmount',a.allocated_amount,
      'fromCustomerId',v_invoice.customer_id,'toCustomerId',v_customer,
      'action',CASE WHEN r.status='DRAFT' THEN 'REWRITE_DRAFT_TARGET_SHARE'
        WHEN r.status='POSTED' AND r.receipt_date<v_date THEN 'TRANSFER_TO_ADVANCE_THEN_APPLY'
        WHEN r.status='POSTED' THEN 'TRANSFER_POSTED_AR_ATTRIBUTION'
        ELSE 'NO_EFFECT_CANCELED' END,
      'otherBackofficeAllocationCount',(SELECT count(*) FROM public.customer_receipt_backoffice_invoice_allocations x
        WHERE x.company_id=v_company AND x.document_id=r.id AND x.invoice_id<>v_invoice.id),
      'retailAllocationCount',(SELECT count(*) FROM public.customer_receipt_allocations x
        WHERE x.company_id=v_company AND x.document_id=r.id)) ORDER BY r.id),'[]'::jsonb),
    round(COALESCE(sum(a.allocated_amount) FILTER(WHERE r.status='POSTED'),0),4),
    round(COALESCE(sum(a.allocated_amount) FILTER(WHERE r.status='POSTED' AND r.receipt_date<v_date),0),4),
    round(COALESCE(sum(a.allocated_amount) FILTER(WHERE r.status='DRAFT'),0),4)
  INTO v_receipts,v_posted_receipt,v_advance,v_draft_receipt
  FROM public.customer_receipt_backoffice_invoice_allocations a
  JOIN public.customer_receipt_documents r ON r.company_id=a.company_id AND r.id=a.document_id
  WHERE a.company_id=v_company AND a.invoice_id=v_invoice.id;

  SELECT count(*) FILTER(WHERE period.id IS NULL OR period.status NOT IN('OPEN','REOPENED')),
    count(*) FILTER(WHERE r.receivable_account_id_snapshot IS NULL
      OR private.resolve_financial_event_account(event,'CUSTOMER_ADVANCE_LIABILITY') IS NULL)
  INTO v_missing_receipt_period,v_missing_receipt_accounts
  FROM public.customer_receipt_backoffice_invoice_allocations a
  JOIN public.customer_receipt_documents r ON r.company_id=a.company_id AND r.id=a.document_id
    AND r.status='POSTED' AND r.receipt_date<v_date
  JOIN public.financial_events event ON event.company_id=v_invoice.company_id
    AND event.id=v_invoice.financial_event_id
  LEFT JOIN public.accounting_periods period ON period.company_id=r.company_id
    AND r.receipt_date BETWEEN period.start_date AND period.end_date
  WHERE a.company_id=v_company AND a.invoice_id=v_invoice.id;
  IF v_missing_receipt_period<>0 THEN
    RAISE EXCEPTION 'INVOICE_REVISION_RECEIPT_PERIOD_LOCKED';
  END IF;
  IF v_missing_receipt_accounts<>0 THEN
    RAISE EXCEPTION 'INVOICE_REVISION_RECEIPT_ADVANCE_MAPPING_REQUIRED';
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object('applicationId',a.id,
      'downPaymentInvoiceId',a.down_payment_invoice_id,'status',a.status,
      'appliedAmount',a.applied_amount,'fromCustomerId',dp.customer_id,
      'toCustomerId',v_customer,'action',CASE WHEN a.status='POSTED'
        THEN 'TRANSFER_POSTED_DP_ATTRIBUTION' ELSE 'RECHECK_NONPOSTED_DP' END) ORDER BY a.id),'[]'::jsonb),
    round(COALESCE(sum(a.applied_amount) FILTER(WHERE a.status='POSTED'),0),4)
  INTO v_dp,v_dp_total
  FROM public.backoffice_sales_down_payment_applications a
  JOIN public.backoffice_sales_invoices dp ON dp.company_id=a.company_id AND dp.id=a.down_payment_invoice_id
  WHERE a.company_id=v_company AND a.regular_invoice_id=v_invoice.id;

  SELECT j.id INTO v_source_journal FROM public.finance_journals j
    WHERE j.company_id=v_company AND j.financial_event_id=v_invoice.financial_event_id
      AND j.status='POSTED' ORDER BY j.id LIMIT 1;
  IF v_source_journal IS NULL THEN RAISE EXCEPTION 'INVOICE_REVISION_SOURCE_JOURNAL_REQUIRED'; END IF;
  SELECT jsonb_build_object('sourceJournalId',j.id,'sourceJournalNo',j.journal_no,
      'sourceAccountingDate',j.accounting_date,'sourcePeriodId',j.accounting_period_id,
      'replacementAccountingDate',v_date,'replacementPeriodId',v_new_period.id,
      'requiresRelocation',j.accounting_date<>v_date OR v_invoice.customer_id<>v_customer,
      'lineCount',(SELECT count(*) FROM public.finance_journal_lines l
        WHERE l.company_id=v_company AND l.journal_id=j.id),
      'totalDebit',j.total_debit,'totalCredit',j.total_credit)
    INTO v_journal FROM public.finance_journals j
    WHERE j.company_id=v_company AND j.id=v_source_journal;
  IF (v_journal->>'lineCount')::integer<2
    OR (v_journal->>'totalDebit')::numeric<>(v_journal->>'totalCredit')::numeric THEN
    RAISE EXCEPTION 'INVOICE_REVISION_SOURCE_JOURNAL_INVALID';
  END IF;
  RETURN jsonb_build_object('status','EXECUTION_PLAN_NOT_POSTED','operationId',p_operation_id,
    'invoiceId',v_invoice.id,'fromCustomerId',v_invoice.customer_id,'toCustomerId',v_customer,
    'fromInvoiceDate',v_invoice.invoice_date,'toInvoiceDate',v_date,
    'amounts',v_preparation.response_snapshot->'amounts','dates',v_preparation.response_snapshot->'dates',
    'receipts',v_receipts,'postedReceiptAmount',v_posted_receipt,
    'receiptAdvanceAmount',v_advance,'draftReceiptAmount',v_draft_receipt,
    'downPayments',v_dp,'postedDownPaymentAmount',v_dp_total,'journal',v_journal,
    'stockEffect',false,'fifoEffect',false,'salesOrderEffect',false,'deliveryEffect',false,
    'requiresAtomicWriter',true);
END
$plan$;
REVOKE ALL ON FUNCTION private.plan_backoffice_invoice_revision_execution(uuid)
  FROM PUBLIC,anon,authenticated,service_role;
