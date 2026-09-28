-- Read-only Production preflight. Run before migration 20260928110000.
-- Safe to rerun; no business row is mutated.
DROP TABLE IF EXISTS pg_temp.backoffice_invoice_price_correction_preflight_result;
CREATE TEMP TABLE backoffice_invoice_price_correction_preflight_result(
  check_name text,status text,violation_rows bigint,details jsonb
);

DO $audit$
DECLARE v_missing text[]:=ARRAY[]::text[];v_collision text[]:=ARRAY[]::text[];
  v_company record;v_category uuid;v_function text;v_account uuid;v_invalid jsonb:='[]'::jsonb;
  v_resolved bigint:=0;v_target_count bigint:=0;
  v_return_definition text;v_statement_definition text;v_receipt_definition text;
  v_receipt_workspace_definition text;
  v_anchor_invalid text[]:=ARRAY[]::text[];v_signature text;v_relation text;
  v_anchor text;v_anchor_count integer;
BEGIN
  FOREACH v_relation IN ARRAY ARRAY[
    'private.kgs_schema_migrations','public.companies','public.profiles',
    'public.products','public.uoms','public.stores','public.chart_of_accounts',
    'public.system_events','public.transaction_categories','public.accounting_periods',
    'public.backoffice_sales_invoices','public.backoffice_sales_invoice_lines',
    'public.backoffice_sales_invoice_receivable_schedules','public.backoffice_sales_credit_notes',
    'public.backoffice_sales_customer_refunds','public.customer_receipt_documents',
    'public.customer_receipt_backoffice_invoice_allocations','public.financial_events',
    'public.finance_journals','public.finance_journal_lines','public.finance_posting_queue_runs',
    'public.pos_offline_sale_submissions'
  ]::text[] LOOP
    IF to_regclass(v_relation) IS NULL THEN v_missing:=array_append(v_missing,'relation:'||v_relation); END IF;
  END LOOP;
  FOREACH v_signature IN ARRAY ARRAY[
    'public.private_active_company_id()',
    'private.acp_require_permission_capability(uuid,text,text)',
    'private.require_backoffice_sales_invoice_post_permission(uuid)',
    'private.calculate_tax_group(jsonb,numeric,text,text,text)',
    'private.resolve_financial_event_account(public.financial_events,text)',
    'private.resolve_opening_stock_account(uuid,uuid,text,timestamp with time zone)',
    'private.reconcile_backoffice_invoice_receivable_schedule(uuid,uuid)',
    'private.allocate_backoffice_sales_return_invoices_before_retained(uuid,bigint,uuid,jsonb)',
    'private.backoffice_sales_invoice_snapshot(uuid,uuid)',
    'private.backoffice_sales_invoice_ui_snapshot(uuid,uuid)',
    'private.backoffice_sales_credit_note_refunded_amount(uuid,uuid)',
    'public.get_backoffice_sales_invoice_payment_context(uuid)',
    'public.get_finance_customer_receipts()',
    'public.get_finance_customer_statement(uuid,date,date,uuid)',
    'public.save_customer_receipt_allocated_draft(uuid,bigint,uuid,date,uuid,text,text,text,numeric,jsonb)'
  ]::text[] LOOP
    IF to_regprocedure(v_signature) IS NULL THEN v_missing:=array_append(v_missing,v_signature); END IF;
  END LOOP;
  INSERT INTO backoffice_invoice_price_correction_preflight_result VALUES(
    'posted_invoice_price_correction_required_runtime',CASE WHEN cardinality(v_missing)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    cardinality(v_missing),jsonb_build_object('missing',v_missing));
  IF cardinality(v_missing)>0 THEN RETURN; END IF;

  INSERT INTO backoffice_invoice_price_correction_preflight_result
  SELECT 'posted_invoice_price_correction_note_catalog',
    CASE WHEN count(*)=2 THEN 'PASS' ELSE 'BLOCKER' END,2-count(*),
    jsonb_build_object('present',COALESCE(jsonb_agg(system_key ORDER BY system_key),'[]'::jsonb),
      'expected',ARRAY['CUSTOMER_CREDIT_NOTE','CUSTOMER_DEBIT_NOTE'])
  FROM public.system_events WHERE system_key IN('CUSTOMER_DEBIT_NOTE','CUSTOMER_CREDIT_NOTE');

  INSERT INTO backoffice_invoice_price_correction_preflight_result
  SELECT 'posted_invoice_price_correction_dependency_ledger',CASE WHEN count(*)=6 THEN 'PASS' ELSE 'BLOCKER' END,
    6-count(*),jsonb_build_object('required',ARRAY['20260911163000','20260917131000','20260917150000','20260918150000','20260919110000','20260925100000'],
      'installed',COALESCE(jsonb_agg(version ORDER BY version),'[]'::jsonb))
  FROM private.kgs_schema_migrations WHERE version IN('20260911163000','20260917131000','20260917150000','20260918150000','20260919110000','20260925100000');

  IF to_regclass('public.backoffice_sales_invoice_price_corrections') IS NOT NULL THEN v_collision:=array_append(v_collision,'price correction table'); END IF;
  IF to_regclass('public.backoffice_sales_invoice_price_correction_lines') IS NOT NULL THEN v_collision:=array_append(v_collision,'price correction lines'); END IF;
  IF to_regclass('public.backoffice_sales_invoice_price_correction_operations') IS NOT NULL THEN v_collision:=array_append(v_collision,'price correction operations'); END IF;
  IF to_regclass('private.backoffice_sales_invoice_price_correction_no_seq') IS NOT NULL THEN v_collision:=array_append(v_collision,'price correction sequence'); END IF;
  IF to_regprocedure('public.post_backoffice_sales_invoice_price_correction(uuid,bigint,bigint,uuid,jsonb)') IS NOT NULL THEN v_collision:=array_append(v_collision,'price correction RPC'); END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260928110000') THEN v_collision:=array_append(v_collision,'migration ledger'); END IF;
  INSERT INTO backoffice_invoice_price_correction_preflight_result VALUES(
    'posted_invoice_price_correction_object_collision',CASE WHEN cardinality(v_collision)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    cardinality(v_collision),jsonb_build_object('existing',v_collision));

  SELECT pg_get_functiondef(
    'private.allocate_backoffice_sales_return_invoices_before_retained(uuid,bigint,uuid,jsonb)'::regprocedure)
  INTO STRICT v_return_definition;
  SELECT pg_get_functiondef('public.get_finance_customer_statement(uuid,date,date,uuid)'::regprocedure)
  INTO STRICT v_statement_definition;
  SELECT pg_get_functiondef(
    'public.save_customer_receipt_allocated_draft(uuid,bigint,uuid,date,uuid,text,text,text,numeric,jsonb)'::regprocedure)
  INTO STRICT v_receipt_definition;
  SELECT pg_get_functiondef('public.get_finance_customer_receipts()'::regprocedure)
  INTO STRICT v_receipt_workspace_definition;
  v_anchor:='v_before jsonb;v_after jsonb;v_all_received boolean;v_has_draft_notes boolean;';
  v_anchor_count:=(length(v_return_definition)-length(replace(v_return_definition,v_anchor,'')))/length(v_anchor);
  IF v_anchor_count<>1 THEN
    v_anchor_invalid:=array_append(v_anchor_invalid,'Return declaration anchor');
  END IF;
  v_anchor:='    v_ratio:=v_qty_base/v_invoice_line.quantity_base;
    SELECT round(COALESCE(sum(line.line_amount+line.discount_amount),0),4),';
  v_anchor_count:=(length(v_return_definition)-length(replace(v_return_definition,v_anchor,'')))/length(v_anchor);
  IF v_anchor_count<>1 THEN
    v_anchor_invalid:=array_append(v_anchor_invalid,'Return effective-price anchor');
  END IF;
  v_anchor:='    v_charge:=CASE WHEN v_used+v_qty_base=v_invoice_line.quantity_base
      THEN v_invoice_line.line_amount+v_invoice_line.discount_amount-v_prior
      ELSE round((v_invoice_line.line_amount+v_invoice_line.discount_amount)*v_ratio,4) END;
    v_discount:=CASE WHEN v_used+v_qty_base=v_invoice_line.quantity_base
      THEN v_invoice_line.discount_amount-v_discount
      ELSE round(v_invoice_line.discount_amount*v_ratio,4) END;
    v_tax:=CASE WHEN v_used+v_qty_base=v_invoice_line.quantity_base
      THEN v_invoice_line.tax_amount-v_tax
      ELSE round(v_invoice_line.tax_amount*v_ratio,4) END;';
  v_anchor_count:=(length(v_return_definition)-length(replace(v_return_definition,v_anchor,'')))/length(v_anchor);
  IF v_anchor_count<>1 THEN
    v_anchor_invalid:=array_append(v_anchor_invalid,'Return value anchor');
  END IF;
  v_anchor:='      v_qty_uom,v_invoice_line.base_qty_per_uom,v_qty_base,v_invoice_line.unit_price,
      v_discount,v_tax,v_line_amount,
      v_invoice_line.source_snapshot||jsonb_build_object(''sourceInvoiceId'',v_invoice.id,
        ''sourceInvoiceNo'',v_invoice.invoice_no,''sourceInvoiceLineId'',v_invoice_line.id));';
  v_anchor_count:=(length(v_return_definition)-length(replace(v_return_definition,v_anchor,'')))/length(v_anchor);
  IF v_anchor_count<>1 THEN
    v_anchor_invalid:=array_append(v_anchor_invalid,'Return insert anchor');
  END IF;
  v_anchor:='WHERE refund.company_id=v_company AND refund.status=''POSTED''
      AND refund.refund_date<=v_as_of
      AND (p_store_id IS NULL OR refund.store_id=p_store_id)
  ),all_rows AS (SELECT * FROM invoice_rows UNION ALL SELECT * FROM receipt_rows)';
  v_anchor_count:=(length(v_statement_definition)-length(replace(v_statement_definition,v_anchor,'')))/length(v_anchor);
  IF v_anchor_count<>1 THEN
    v_anchor_invalid:=array_append(v_anchor_invalid,'Customer Statement union anchor');
  END IF;
  IF v_receipt_definition NOT LIKE '%IF v_amount>private.backoffice_invoice_receivable_before_receipts(%'
    OR v_receipt_definition NOT LIKE '%v_company,v_invoice.id,p_receipt_date)-v_paid THEN%' THEN
    v_anchor_invalid:=array_append(v_anchor_invalid,'Customer Receipt canonical helper anchor');
  END IF;
  v_anchor:='store.store_name,invoice.grand_total,COALESCE(receipt.paid,0),';
  v_anchor_count:=(length(v_receipt_workspace_definition)-length(replace(v_receipt_workspace_definition,v_anchor,'')))/length(v_anchor);
  IF v_anchor_count<>1 THEN
    v_anchor_invalid:=array_append(v_anchor_invalid,'Customer Receipt workspace total anchor');
  END IF;
  INSERT INTO backoffice_invoice_price_correction_preflight_result VALUES(
    'posted_invoice_price_correction_runtime_patch_anchor',
    CASE WHEN cardinality(v_anchor_invalid)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    cardinality(v_anchor_invalid),jsonb_build_object('invalid',v_anchor_invalid,
      'rule','Every dynamic runtime patch anchor must match before migration'));

  INSERT INTO backoffice_invoice_price_correction_preflight_result
  SELECT 'posted_invoice_price_correction_active_finance_queue',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*),jsonb_build_object('rows',count(*)) FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING');
  INSERT INTO backoffice_invoice_price_correction_preflight_result
  SELECT 'posted_invoice_price_correction_nonterminal_offline',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*),jsonb_build_object('rows',count(*)) FROM public.pos_offline_sale_submissions
    WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION');

  FOR v_company IN SELECT id,company_name FROM public.companies WHERE status='ACTIVE' AND id IN(
      '4eedbf12-3c60-40e0-b2b7-1a48ca62b6f8'::uuid,'07bdffb9-8c56-444c-a49b-81ac86745674'::uuid,
      '809abdd9-d05f-4525-9726-1951a0ae1a81'::uuid) ORDER BY id
  LOOP
    v_target_count:=v_target_count+1;
    FOR v_category,v_function IN
      SELECT category.id,function_key FROM (VALUES
        ('CUSTOMER_DEBIT_NOTE','CUSTOMER_RECEIVABLE'),('CUSTOMER_DEBIT_NOTE','SALES_REVENUE'),
        ('CUSTOMER_DEBIT_NOTE','CUSTOMER_REFUND_LIABILITY'),
        ('CUSTOMER_CREDIT_NOTE','CUSTOMER_RECEIVABLE'),('CUSTOMER_CREDIT_NOTE','SALES_RETURN_DISCOUNT'),
        ('CUSTOMER_CREDIT_NOTE','CUSTOMER_REFUND_LIABILITY')) needed(system_key,function_key)
      LEFT JOIN LATERAL(SELECT category.id FROM public.transaction_categories category
        WHERE category.company_id=v_company.id AND category.system_key=needed.system_key AND category.is_active
        ORDER BY category.is_system_default DESC,category.id LIMIT 1) category ON true
    LOOP
      BEGIN
        IF v_category IS NULL THEN RAISE EXCEPTION 'CATEGORY_MISSING'; END IF;
        v_account:=private.resolve_opening_stock_account(v_company.id,v_category,v_function,clock_timestamp());
        IF v_account IS NULL THEN RAISE EXCEPTION 'ACCOUNT_MISSING'; END IF;
        v_resolved:=v_resolved+1;
      EXCEPTION WHEN OTHERS THEN
        v_invalid:=v_invalid||jsonb_build_array(jsonb_build_object('companyId',v_company.id,
          'companyName',v_company.company_name,'function',v_function,'error',SQLERRM));
      END;
    END LOOP;
  END LOOP;
  INSERT INTO backoffice_invoice_price_correction_preflight_result VALUES(
    'posted_invoice_price_correction_target_company_mapping',
    CASE WHEN v_target_count=3 AND v_resolved=18 AND jsonb_array_length(v_invalid)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_array_length(v_invalid)+CASE WHEN v_target_count=3 THEN 0 ELSE 3-v_target_count END,
    jsonb_build_object('companies',v_target_count,'resolvedRows',v_resolved,'expectedResolvedRows',18,'invalid',v_invalid,
      'taxNote','OUTPUT_TAX is resolved only when the source Invoice line is taxable'));

  INSERT INTO backoffice_invoice_price_correction_preflight_result
  SELECT 'posted_invoice_price_correction_runtime_inventory','INFO',0,
    jsonb_build_object('eligiblePostedRegularInvoices',count(*) FILTER(WHERE NOT has_credit_note),
      'blockedByExistingReturnCredit',count(*) FILTER(WHERE has_credit_note))
  FROM (SELECT invoice.id,EXISTS(SELECT 1 FROM public.backoffice_sales_credit_notes note
      WHERE note.company_id=invoice.company_id AND note.source_invoice_id=invoice.id
        AND note.status IN('DRAFT','POSTED')) has_credit_note
    FROM public.backoffice_sales_invoices invoice WHERE invoice.status='POSTED' AND invoice.invoice_type='REGULAR'
      AND invoice.company_id IN('4eedbf12-3c60-40e0-b2b7-1a48ca62b6f8'::uuid,
        '07bdffb9-8c56-444c-a49b-81ac86745674'::uuid,'809abdd9-d05f-4525-9726-1951a0ae1a81'::uuid)) inventory;
END
$audit$;

SELECT check_name,status,violation_rows,details
FROM backoffice_invoice_price_correction_preflight_result ORDER BY check_name;
