-- Authenticated, representative and rollback-only regression for the exact UI defect.
BEGIN;
DO $test$
DECLARE v_actor uuid;v_company uuid;v_invoice uuid;v_customer uuid;v_method uuid;
  v_today date;v_amount numeric(20,4);v_balance_before numeric(20,4);
  v_evidence_url text;
  v_operation uuid:=gen_random_uuid();v_result jsonb;v_retry jsonb;v_receipt uuid;
  v_event uuid;v_journal uuid;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260912139000') THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: migration 20260912139000 required';
  END IF;
  SELECT profile.id INTO v_actor FROM public.profiles profile
  WHERE profile.role='super_admin'::public.user_role ORDER BY profile.id LIMIT 1;
  SELECT candidate.company_id,candidate.invoice_id,candidate.customer_id,candidate.method_id,
    candidate.company_today,least(candidate.outstanding,1),candidate.current_balance,
    candidate.evidence_url
  INTO v_company,v_invoice,v_customer,v_method,v_today,v_amount,v_balance_before,
    v_evidence_url
  FROM (
    SELECT invoice.company_id,invoice.id invoice_id,invoice.customer_id,method.id method_id,
      (clock_timestamp() AT TIME ZONE company.timezone)::date company_today,
      invoice.grand_total-COALESCE((SELECT sum(allocation.allocated_amount)
        FROM public.customer_receipt_backoffice_invoice_allocations allocation
        JOIN public.customer_receipt_documents receipt
          ON receipt.company_id=allocation.company_id AND receipt.id=allocation.document_id
         AND receipt.status='POSTED'
        WHERE allocation.company_id=invoice.company_id AND allocation.invoice_id=invoice.id),0) outstanding,
      customer.current_balance,
      CASE WHEN method.proof_mode='REQUIRED'
        THEN 'https://example.invalid/rollback-only-proof' ELSE NULL END evidence_url
    FROM public.backoffice_sales_invoices invoice
    JOIN public.companies company ON company.id=invoice.company_id AND company.status='ACTIVE'
    JOIN public.customers customer ON customer.company_id=invoice.company_id
      AND customer.id=invoice.customer_id AND customer.is_active AND customer.is_system_customer
    JOIN LATERAL(SELECT payment_method.id,payment_method.proof_mode
      FROM public.payment_methods payment_method
      WHERE payment_method.company_id=invoice.company_id AND payment_method.is_active
        AND payment_method.settlement_route IN('CASH_DRAWER','DIRECT_BANK')
      ORDER BY payment_method.is_default DESC,payment_method.id LIMIT 1) method ON true
    WHERE invoice.status='POSTED'
      AND invoice.invoice_date<=(clock_timestamp() AT TIME ZONE company.timezone)::date
      AND invoice.grand_total>COALESCE((SELECT sum(allocation.allocated_amount)
        FROM public.customer_receipt_backoffice_invoice_allocations allocation
        JOIN public.customer_receipt_documents receipt
          ON receipt.company_id=allocation.company_id AND receipt.id=allocation.document_id
         AND receipt.status='POSTED'
        WHERE allocation.company_id=invoice.company_id AND allocation.invoice_id=invoice.id),0)
      AND EXISTS(SELECT 1 FROM public.accounting_periods period
        WHERE period.company_id=invoice.company_id AND period.status IN('OPEN','REOPENED')
          AND (clock_timestamp() AT TIME ZONE company.timezone)::date
            BETWEEN period.start_date AND period.end_date)
    ORDER BY invoice.created_at DESC,invoice.id
  ) candidate LIMIT 1;
  IF v_actor IS NULL OR v_invoice IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: unpaid posted WALK-IN Backoffice Invoice, active Payment Method and current open period required';
  END IF;
  PERFORM set_config('request.jwt.claim.sub',v_actor::text,true);
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',v_actor,'role','authenticated')::text,true);
  INSERT INTO public.user_active_company_contexts(user_id,company_id)
  VALUES(v_actor,v_company) ON CONFLICT(user_id) DO UPDATE
    SET company_id=excluded.company_id,selected_at=clock_timestamp(),updated_at=clock_timestamp();

  v_result:=public.register_backoffice_sales_invoice_payment(v_invoice,v_operation,
    v_today,v_method,v_amount,'SYSTEM-CUSTOMER-ROLLBACK',v_evidence_url,
    'Rollback-only WALK-IN Invoice payment regression');
  v_receipt:=(v_result->'payment'->>'receiptId')::uuid;
  IF v_result->'payment'->>'status'<>'POSTED'
    OR v_result->'paymentContext'->'summary'->>'status' NOT IN('PARTIALLY_PAID','PAID')
    OR NOT EXISTS(SELECT 1 FROM public.customer_receipt_documents receipt
      WHERE receipt.company_id=v_company AND receipt.id=v_receipt
        AND receipt.customer_id=v_customer AND receipt.status='POSTED'
        AND receipt.unapplied_disposition='NONE')
    OR NOT EXISTS(SELECT 1 FROM public.customer_receipt_backoffice_invoice_allocations allocation
      WHERE allocation.company_id=v_company AND allocation.document_id=v_receipt
        AND allocation.invoice_id=v_invoice AND allocation.allocated_amount=v_amount)
    OR EXISTS(SELECT 1 FROM public.customer_receipt_allocations allocation
      WHERE allocation.company_id=v_company AND allocation.document_id=v_receipt)
    OR (SELECT current_balance FROM public.customers
      WHERE company_id=v_company AND id=v_customer) IS DISTINCT FROM v_balance_before THEN
    RAISE EXCEPTION 'TEST_FAILED: scoped WALK-IN Backoffice Invoice payment contract invalid';
  END IF;
  SELECT financial_event_id INTO STRICT v_event FROM public.customer_receipt_documents
  WHERE company_id=v_company AND id=v_receipt;
  SELECT id INTO STRICT v_journal FROM public.finance_journals
  WHERE company_id=v_company AND financial_event_id=v_event AND status='POSTED';
  IF NOT EXISTS(SELECT 1 FROM public.finance_journals journal
      WHERE journal.company_id=v_company AND journal.id=v_journal
        AND journal.total_debit=v_amount AND journal.total_credit=v_amount)
    OR (SELECT count(*) FROM public.finance_journal_lines line
      WHERE line.company_id=v_company AND line.journal_id=v_journal
        AND line.customer_id=v_customer)<>2 THEN
    RAISE EXCEPTION 'TEST_FAILED: WALK-IN receipt journal invalid';
  END IF;
  v_retry:=public.register_backoffice_sales_invoice_payment(v_invoice,v_operation,
    v_today,v_method,v_amount,'SYSTEM-CUSTOMER-ROLLBACK',v_evidence_url,
    'Rollback-only WALK-IN Invoice payment regression');
  IF COALESCE((v_retry->>'exactRetry')::boolean,false) IS NOT TRUE
    OR (SELECT count(*) FROM public.finance_journals
      WHERE company_id=v_company AND financial_event_id=v_event)<>1 THEN
    RAISE EXCEPTION 'TEST_FAILED: WALK-IN payment retry duplicated effect';
  END IF;
END
$test$;
ROLLBACK;

SELECT 'backoffice_sales_system_customer_payment_behavior' check_name,'PASS' status,
  0::bigint violation_rows,
  jsonb_build_object('tested',jsonb_build_array(
    'posted WALK-IN Backoffice Invoice payment',
    'Backoffice-only allocation',
    'zero Customer Balance effect',
    'balanced Customer Receipt journal',
    'exact retry')) details;
