-- Harness supplies canonical posted taxed/untaxed invoices and final ROLLBACK.
DO $test$
DECLARE
  v_invoice public.backoffice_sales_invoices%rowtype;
  v_lines jsonb; v_bad jsonb; v_preview jsonb; v_retry jsonb;
  v_revision bigint; v_count integer:=0; v_taxed integer:=0; v_untaxed integer:=0;
  v_prior_corrections integer:=0; v_error text; v_before jsonb; v_discount numeric;
  v_date date; v_dates jsonb; v_period_id uuid; v_old_period_id uuid; v_schedule jsonb;
BEGIN
  IF has_function_privilege('authenticated',
    'private.backoffice_invoice_revision_amount_preview(uuid,uuid,bigint,bigint,jsonb)','EXECUTE')
    OR has_function_privilege('anon',
    'private.backoffice_invoice_revision_amount_preview(uuid,uuid,bigint,bigint,jsonb)','EXECUTE')
    OR has_function_privilege('service_role',
    'private.backoffice_invoice_revision_amount_preview(uuid,uuid,bigint,bigint,jsonb)','EXECUTE') THEN
    RAISE EXCEPTION 'TEST_FAILED: private candidate exposed';
  END IF;
  FOR v_invoice IN SELECT * FROM public.backoffice_sales_invoices
    WHERE company_id='4eedbf12-3c60-40e0-b2b7-1a48ca62b6f8'
      AND status='POSTED' AND invoice_type='REGULAR' ORDER BY id LOOP
    SELECT count(*) INTO v_revision FROM public.backoffice_sales_invoice_price_corrections
      WHERE company_id=v_invoice.company_id AND source_invoice_id=v_invoice.id AND status='POSTED';
    IF v_revision>0 THEN v_prior_corrections:=v_prior_corrections+1; END IF;
    SELECT jsonb_agg(jsonb_build_object('invoiceLineId',l.id,
      'unitPrice',private.backoffice_invoice_effective_entered_unit_price(l.company_id,l.id)::text,
      'discountAmount',l.discount_amount::text) ORDER BY l.id) INTO v_lines
      FROM public.backoffice_sales_invoice_lines l WHERE l.company_id=v_invoice.company_id
      AND l.invoice_id=v_invoice.id AND l.line_type='PRODUCT' AND l.source_kind='SALES_ORDER';
    IF jsonb_array_length(v_lines)<>1 THEN RAISE EXCEPTION 'TEST_PRECONDITION: one-line canonical fixture required'; END IF;
    v_preview:=private.backoffice_invoice_revision_amount_preview(v_invoice.company_id,v_invoice.id,
      v_invoice.master_version,v_revision,v_lines);
    IF (v_preview->>'changedLines')::integer<>0 OR (v_preview->>'payableDelta')::numeric<>0
      OR (v_preview->>'beforeTotal')::numeric<>(v_preview->>'afterTotal')::numeric THEN
      RAISE EXCEPTION 'TEST_FAILED: unchanged effective amount parity';
    END IF;
    v_before:=v_preview->'lines'->0->'before';
    IF (v_before->>'taxAmount')::numeric>0 THEN v_taxed:=v_taxed+1; ELSE v_untaxed:=v_untaxed+1; END IF;
    -- A late discount reduces the payable by the exact entered inclusive amount.
    v_discount:=(v_lines->0->>'discountAmount')::numeric+1000;
    v_bad:=jsonb_set(v_lines,'{0,discountAmount}',to_jsonb(v_discount::text));
    v_preview:=private.backoffice_invoice_revision_amount_preview(v_invoice.company_id,v_invoice.id,
      v_invoice.master_version,v_revision,v_bad);
    v_retry:=private.backoffice_invoice_revision_amount_preview(v_invoice.company_id,v_invoice.id,
      v_invoice.master_version,v_revision,v_bad);
    IF v_preview IS DISTINCT FROM v_retry OR (v_preview->>'payableDelta')::numeric<>-1000
      OR (v_preview->>'salesDiscountDelta')::numeric<>1000 OR (v_preview->>'changedLines')::integer<>1
      OR (v_preview->>'grossRevenueDelta')::numeric-(v_preview->>'salesDiscountDelta')::numeric
         +(v_preview->>'taxDelta')::numeric<>(v_preview->>'payableDelta')::numeric THEN
      RAISE EXCEPTION 'TEST_FAILED: late discount arithmetic / deterministic preview';
    END IF;
    -- Increase price and discount together; neither change may be lost.
    v_bad:=jsonb_set(v_bad,'{0,unitPrice}',to_jsonb(((v_lines->0->>'unitPrice')::numeric+2000)::text));
    v_preview:=private.backoffice_invoice_revision_amount_preview(v_invoice.company_id,v_invoice.id,
      v_invoice.master_version,v_revision,v_bad);
    IF (v_preview->>'payableDelta')::numeric<>
      (v_preview->'lines'->0->>'quantityUom')::numeric*2000-1000 THEN
      RAISE EXCEPTION 'TEST_FAILED: joint price discount change';
    END IF;
    -- Zero net delta is legitimate for metadata-only correction planning.
    v_bad:=jsonb_set(v_bad,'{0,discountAmount}',to_jsonb(round((v_lines->0->>'discountAmount')::numeric+
      (v_preview->'lines'->0->>'quantityUom')::numeric*2000,4)::text));
    v_preview:=private.backoffice_invoice_revision_amount_preview(v_invoice.company_id,v_invoice.id,
      v_invoice.master_version,v_revision,v_bad);
    IF (v_preview->>'payableDelta')::numeric<>0 OR (v_preview->>'changedLines')::integer<>1 THEN
      RAISE EXCEPTION 'TEST_FAILED: zero net change must preserve changed line';
    END IF;
    FOR v_bad,v_error IN SELECT * FROM (VALUES
      (jsonb_set(v_lines,'{0,unitPrice}','null'::jsonb),'INVOICE_REVISION_LINE_INVALID'),
      (jsonb_set(v_lines,'{0,unitPrice}','"NaN"'::jsonb),'INVOICE_REVISION_LINE_INVALID'),
      (jsonb_set(v_lines,'{0,unitPrice}','"-1"'::jsonb),'INVOICE_REVISION_LINE_INVALID'),
      (jsonb_set(v_lines,'{0,unitPrice}','"1.00001"'::jsonb),'INVOICE_REVISION_LINE_INVALID'),
      (jsonb_set(v_lines,'{0,quantity}','"9"'::jsonb),'INVOICE_REVISION_LINE_INVALID'),
      (jsonb_set(v_lines,'{0,invoiceLineId}',to_jsonb(gen_random_uuid()::text)),'INVOICE_REVISION_LINE_OWNERSHIP_INVALID'),
      (jsonb_set(v_lines,'{0,discountAmount}','"999999999"'::jsonb),'INVOICE_DISCOUNT_EXCEEDS_CORRECTED_LINE_TOTAL'),
      (v_lines||v_lines,'INVOICE_REVISION_LINE_SET_MISMATCH'),
      ('[]'::jsonb,'INVOICE_REVISION_PREVIEW_PAYLOAD_INVALID'),
      ('null'::jsonb,'INVOICE_REVISION_PREVIEW_PAYLOAD_INVALID')
    ) t(payload,expected) LOOP
      BEGIN
        PERFORM private.backoffice_invoice_revision_amount_preview(v_invoice.company_id,v_invoice.id,
          v_invoice.master_version,v_revision,v_bad);
        RAISE EXCEPTION 'TEST_FAILED: invalid preview accepted';
      EXCEPTION WHEN raise_exception THEN IF SQLERRM<>v_error THEN RAISE; END IF; END;
    END LOOP;
    BEGIN
      PERFORM private.backoffice_invoice_revision_amount_preview(v_invoice.company_id,v_invoice.id,
        v_invoice.master_version+1,v_revision,v_lines);
      RAISE EXCEPTION 'TEST_FAILED: stale master accepted';
    EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'MASTER_VERSION_CONFLICT' THEN RAISE; END IF; END;
    BEGIN
      PERFORM private.backoffice_invoice_revision_amount_preview(v_invoice.company_id,v_invoice.id,
        v_invoice.master_version,v_revision+1,v_lines);
      RAISE EXCEPTION 'TEST_FAILED: stale revision accepted';
    EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'INVOICE_PRICE_REVISION_CONFLICT' THEN RAISE; END IF; END;
    BEGIN
      PERFORM private.backoffice_invoice_revision_amount_preview('07bdffb9-8c56-444c-a49b-81ac86745674',
        v_invoice.id,v_invoice.master_version,v_revision,v_lines);
      RAISE EXCEPTION 'TEST_FAILED: foreign tenant source accepted';
    EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'BACKOFFICE_SALES_INVOICE_NOT_FOUND' THEN RAISE; END IF; END;
    v_date:=(date_trunc('month',v_invoice.invoice_date)+interval '1 month')::date;
    -- Each synthetic invoice uses this month's newly-created open period.
    SELECT id INTO STRICT v_old_period_id FROM public.accounting_periods
      WHERE company_id=v_invoice.company_id AND v_invoice.invoice_date BETWEEN start_date AND end_date;
    SELECT id INTO v_period_id FROM public.accounting_periods
      WHERE company_id=v_invoice.company_id AND v_date BETWEEN start_date AND end_date;
    IF v_period_id IS NULL THEN
      BEGIN
        PERFORM private.backoffice_invoice_revision_date_preview(v_invoice.company_id,v_invoice.id,
          v_invoice.master_version,v_date);
        RAISE EXCEPTION 'TEST_FAILED: missing period accepted';
      EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'INVOICE_REVISION_ACCOUNTING_PERIOD_MISSING' THEN RAISE; END IF; END;
      INSERT INTO public.accounting_periods(company_id,period_year,period_month,start_date,end_date,
        status,created_by,updated_by) VALUES(v_invoice.company_id,extract(year FROM v_date)::integer,
        extract(month FROM v_date)::integer,v_date,(v_date+interval '1 month -1 day')::date,
        'OPEN',v_invoice.created_by,v_invoice.created_by) RETURNING id INTO v_period_id;
    END IF;
    v_dates:=private.backoffice_invoice_revision_date_preview(v_invoice.company_id,v_invoice.id,
      v_invoice.master_version,v_date);
    IF (v_dates->>'dateChanged')::boolean IS DISTINCT FROM true
      OR v_dates->>'previousPeriodId'=v_dates->>'periodId'
      OR jsonb_array_length(v_dates->'schedules')=0 THEN
      RAISE EXCEPTION 'TEST_FAILED: cross-month nonzero schedules required';
    END IF;
    FOR v_schedule IN SELECT value FROM jsonb_array_elements(v_dates->'schedules') LOOP
      IF (v_schedule->>'dueDate')::date-v_date<>
        (v_schedule->>'previousDueDate')::date-v_invoice.invoice_date THEN
        RAISE EXCEPTION 'TEST_FAILED: installment term changed';
      END IF;
    END LOOP;
    BEGIN
      UPDATE public.accounting_periods SET status='LOCKED',closed_by=v_invoice.created_by,
        closed_at=clock_timestamp() WHERE id=v_period_id;
      PERFORM private.backoffice_invoice_revision_date_preview(v_invoice.company_id,v_invoice.id,
        v_invoice.master_version,v_date);
      RAISE EXCEPTION 'TEST_FAILED: locked destination period accepted';
    EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'INVOICE_REVISION_ACCOUNTING_PERIOD_LOCKED' THEN RAISE; END IF; END;
    BEGIN
      UPDATE public.accounting_periods SET status='LOCKED',closed_by=v_invoice.created_by,
        closed_at=clock_timestamp() WHERE id=v_old_period_id;
      PERFORM private.backoffice_invoice_revision_date_preview(v_invoice.company_id,v_invoice.id,
        v_invoice.master_version,v_date);
      RAISE EXCEPTION 'TEST_FAILED: locked source period accepted';
    EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'INVOICE_REVISION_ACCOUNTING_PERIOD_LOCKED' THEN RAISE; END IF; END;
    v_count:=v_count+1;
  END LOOP;
  IF v_count<2 OR v_taxed<1 OR v_untaxed<1 OR v_prior_corrections<1 THEN
    RAISE EXCEPTION 'TEST_PRECONDITION: nonzero taxed untaxed previously-corrected sources required';
  END IF;
END
$test$;
SELECT 'backoffice_invoice_revision_amount_preview_behavior' check_name,'PASS' status,0 violation_rows,
  jsonb_build_object('tested',ARRAY['canonical taxed and untaxed posted fixtures',
    'existing effective price correction parity','late discount exact payable delta',
    'joint price and discount changes','zero-net financial change',
    'invalid NULL NaN precision quantity foreign-line payloads rejected',
    'stale master and price revisions rejected','cross-tenant ownership rejected',
    'deterministic read-only preview','no browser or service-role execute grant',
    'cross-month KEEP_TERM schedule date preview','missing or locked source/destination period rejected']) details;
