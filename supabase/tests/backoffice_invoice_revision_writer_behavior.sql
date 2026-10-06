DO $test$
DECLARE
  c uuid:='4eedbf12-3c60-40e0-b2b7-1a48ca62b6f8';operation uuid;target_invoice_id uuid;
  source_invoice jsonb;source_lines jsonb;source_receipts jsonb;source_dp jsonb;source_journal jsonb;
  result jsonb;retry jsonb;effective jsonb;plan jsonb;target_revision_id uuid;journal_count integer;
  schedule_due date;expected_due date;
  amount_operation uuid:=gen_random_uuid();amount_invoice public.backoffice_sales_invoices%rowtype;
  amount_line uuid;amount_lines jsonb;amount_command jsonb;amount_prepared jsonb;amount_result jsonb;
  amount_revision bigint;amount_effective jsonb;
  repeat_operation uuid:=gen_random_uuid();repeat_command jsonb;repeat_prepared jsonb;repeat_result jsonb;
  report_operation uuid:=gen_random_uuid();report_invoice public.backoffice_sales_invoices%rowtype;
  report_lines jsonb;report_command jsonb;report_result jsonb;report_customer uuid;report_revision bigint;
BEGIN
  SELECT p.operation_id,p.invoice_id INTO STRICT operation,target_invoice_id
  FROM private.backoffice_invoice_revision_preparations p
  WHERE (p.request_snapshot->>'invoiceDate')::date>
    (p.source_snapshot->'invoice'->>'invoice_date')::date
  ORDER BY p.created_at DESC LIMIT 1;
  plan:=private.plan_backoffice_invoice_revision_journals(operation);
  SELECT to_jsonb(i) INTO STRICT source_invoice FROM public.backoffice_sales_invoices i
    WHERE i.company_id=c AND i.id=target_invoice_id;
  SELECT jsonb_agg(to_jsonb(l) ORDER BY l.id) INTO source_lines
    FROM public.backoffice_sales_invoice_lines l WHERE l.company_id=c AND l.invoice_id=target_invoice_id;
  SELECT jsonb_agg(to_jsonb(x) ORDER BY x.kind,x.id) INTO source_receipts FROM (
    SELECT 'document' kind,d.id,to_jsonb(d) body FROM public.customer_receipt_documents d
      WHERE d.company_id=c AND EXISTS(SELECT 1 FROM public.customer_receipt_backoffice_invoice_allocations a
        WHERE a.company_id=c AND a.document_id=d.id AND a.invoice_id=target_invoice_id)
    UNION ALL
    SELECT 'allocation',a.id,to_jsonb(a) FROM public.customer_receipt_backoffice_invoice_allocations a
      WHERE a.company_id=c AND a.invoice_id=target_invoice_id) x;
  SELECT jsonb_agg(to_jsonb(a) ORDER BY a.id) INTO source_dp
    FROM public.backoffice_sales_down_payment_applications a
    WHERE a.company_id=c AND a.regular_invoice_id=target_invoice_id;
  SELECT to_jsonb(j) INTO STRICT source_journal FROM public.finance_journals j
    WHERE j.company_id=c AND j.id=(plan->'recognitionReversal'->>'sourceJournalId')::uuid;
  expected_due:=(plan->'dates'->'schedules'->0->>'dueDate')::date;

  result:=private.execute_backoffice_invoice_revision(operation);
  SET CONSTRAINTS ALL IMMEDIATE;
  SET CONSTRAINTS ALL DEFERRED;
  retry:=private.execute_backoffice_invoice_revision(operation);
  target_revision_id:=(result->>'revisionId')::uuid;
  IF result->>'status' IS DISTINCT FROM 'POSTED' OR result->>'exactRetry' IS DISTINCT FROM 'false'
    OR retry->>'exactRetry' IS DISTINCT FROM 'true'
    OR result-'exactRetry' IS DISTINCT FROM retry-'exactRetry' THEN
    RAISE EXCEPTION 'TEST_FAILED: writer response or exact retry mismatch';
  END IF;
  IF (SELECT count(*) FROM private.backoffice_invoice_revisions r
      WHERE r.company_id=c AND r.id=target_revision_id AND r.invoice_id=target_invoice_id)<>1
    OR (SELECT count(*) FROM private.backoffice_invoice_revision_lines l
      WHERE l.company_id=c AND l.revision_id=target_revision_id)<>jsonb_array_length(plan->'amounts'->'lines')
    OR (SELECT count(*) FROM private.backoffice_invoice_revision_settlement_attributions a
      WHERE a.company_id=c AND a.revision_id=target_revision_id)<4 THEN
    RAISE EXCEPTION 'TEST_FAILED: immutable revision lineage incomplete';
  END IF;
  SELECT count(*) INTO journal_count FROM public.finance_journals j
    WHERE j.company_id=c AND j.source_type='backoffice_invoice_revisions' AND j.source_id=target_revision_id;
  IF journal_count<>jsonb_array_length(result->'journalIds') OR journal_count<7
    OR EXISTS(SELECT 1 FROM public.finance_journals j WHERE j.company_id=c
      AND j.source_type='backoffice_invoice_revisions' AND j.source_id=target_revision_id
      AND (j.status<>'POSTED' OR j.total_debit<=0 OR j.total_debit<>j.total_credit)) THEN
    RAISE EXCEPTION 'TEST_FAILED: posted correction journal contract';
  END IF;
  effective:=private.backoffice_invoice_effective_identity(c,target_invoice_id,NULL);
  IF effective->>'customerId' IS DISTINCT FROM result->>'customerId'
    OR effective->>'invoiceDate' IS DISTINCT FROM result->>'invoiceDate'
    OR (effective->>'revision')::bigint<>1 THEN
    RAISE EXCEPTION 'TEST_FAILED: effective identity mismatch';
  END IF;
  SELECT due_date INTO STRICT schedule_due FROM public.backoffice_sales_invoice_receivable_schedules
    WHERE company_id=c AND invoice_id=target_invoice_id ORDER BY installment_no LIMIT 1;
  IF schedule_due IS DISTINCT FROM expected_due THEN RAISE EXCEPTION 'TEST_FAILED: schedule date not shifted'; END IF;
  IF (SELECT to_jsonb(i) FROM public.backoffice_sales_invoices i WHERE i.company_id=c AND i.id=target_invoice_id)
      IS DISTINCT FROM source_invoice
    OR (SELECT jsonb_agg(to_jsonb(l) ORDER BY l.id) FROM public.backoffice_sales_invoice_lines l
      WHERE l.company_id=c AND l.invoice_id=target_invoice_id) IS DISTINCT FROM source_lines
    OR (SELECT to_jsonb(j) FROM public.finance_journals j
      WHERE j.company_id=c AND j.id=(plan->'recognitionReversal'->>'sourceJournalId')::uuid)
      IS DISTINCT FROM source_journal THEN
    RAISE EXCEPTION 'TEST_FAILED: posted source Invoice, lines or Journal mutated';
  END IF;
  IF (SELECT jsonb_agg(to_jsonb(x) ORDER BY x.kind,x.id) FROM (
      SELECT 'document' kind,d.id,to_jsonb(d) body FROM public.customer_receipt_documents d
        WHERE d.company_id=c AND EXISTS(SELECT 1 FROM public.customer_receipt_backoffice_invoice_allocations a
          WHERE a.company_id=c AND a.document_id=d.id AND a.invoice_id=target_invoice_id)
      UNION ALL
      SELECT 'allocation',a.id,to_jsonb(a) FROM public.customer_receipt_backoffice_invoice_allocations a
        WHERE a.company_id=c AND a.invoice_id=target_invoice_id) x) IS DISTINCT FROM source_receipts
    OR (SELECT jsonb_agg(to_jsonb(a) ORDER BY a.id) FROM public.backoffice_sales_down_payment_applications a
      WHERE a.company_id=c AND a.regular_invoice_id=target_invoice_id) IS DISTINCT FROM source_dp THEN
    RAISE EXCEPTION 'TEST_FAILED: original Receipt or DP records mutated';
  END IF;
  BEGIN
    UPDATE private.backoffice_invoice_revisions SET payable_delta=1 WHERE company_id=c AND id=target_revision_id;
    RAISE EXCEPTION 'TEST_FAILED: revision mutation allowed';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM<>'INVOICE_REVISION_HISTORY_IMMUTABLE' THEN RAISE; END IF;
  END;
  IF has_function_privilege('authenticated','private.execute_backoffice_invoice_revision(uuid)','EXECUTE')
    OR has_table_privilege('authenticated','private.backoffice_invoice_revisions','SELECT') THEN
    RAISE EXCEPTION 'TEST_FAILED: private writer exposed';
  END IF;

  SELECT i.* INTO STRICT amount_invoice FROM public.backoffice_sales_invoices i
    JOIN staging_revision_invoice_fixture f ON f.invoice_id=i.id
    WHERE f.ordinal=2;
  SELECT min(l.id::text)::uuid INTO STRICT amount_line FROM public.backoffice_sales_invoice_lines l
    WHERE l.company_id=c AND l.invoice_id=amount_invoice.id AND l.line_type='PRODUCT'
      AND l.source_kind='SALES_ORDER';
  SELECT count(*) INTO amount_revision FROM public.backoffice_sales_invoice_price_corrections pc
    WHERE pc.company_id=c AND pc.source_invoice_id=amount_invoice.id AND pc.status='POSTED';
  SELECT jsonb_agg(jsonb_build_object('invoiceLineId',l.id,
    'unitPrice',(private.backoffice_invoice_effective_entered_unit_price(c,l.id)
      +CASE WHEN l.id=amount_line THEN 100 ELSE 0 END)::text,
    'discountAmount',(private.backoffice_invoice_effective_line_amounts(c,l.id)->>'discountAmount')) ORDER BY l.id)
  INTO amount_lines FROM public.backoffice_sales_invoice_lines l
  WHERE l.company_id=c AND l.invoice_id=amount_invoice.id AND l.line_type='PRODUCT'
    AND l.source_kind='SALES_ORDER';
  amount_command:=jsonb_build_object('kind','INVOICE_REVISION','invoiceId',amount_invoice.id,
    'operationId',amount_operation,'masterVersion',amount_invoice.master_version,
    'revision',amount_revision,'customerId',amount_invoice.customer_id,
    'invoiceDate',amount_invoice.invoice_date,'dueDate',jsonb_build_object('mode','KEEP_TERM'),
    'lines',amount_lines);
  amount_prepared:=private.prepare_backoffice_invoice_revision(amount_command);
  IF (amount_prepared->'amounts'->>'payableDelta')::numeric<=0 THEN
    RAISE EXCEPTION 'TEST_FAILED: nonzero amount fixture required'; END IF;
  amount_result:=private.execute_backoffice_invoice_revision(amount_operation);
  amount_effective:=private.backoffice_invoice_effective_line_amounts(c,amount_line);
  IF amount_result->>'status' IS DISTINCT FROM 'POSTED'
    OR (amount_result->>'effectiveTotal')::numeric<>(amount_prepared->'amounts'->>'afterTotal')::numeric
    OR (amount_effective->>'enteredUnitPrice')::numeric<>
      (SELECT (element.value->>'unitPrice')::numeric FROM jsonb_array_elements(amount_lines) element(value)
        WHERE element.value->>'invoiceLineId'=amount_line::text)
    OR private.backoffice_invoice_effective_total(c,amount_invoice.id,NULL)<>
      (amount_prepared->'amounts'->>'afterTotal')::numeric THEN
    RAISE EXCEPTION 'TEST_FAILED: amount-changing effective readers mismatch';
  END IF;
  SELECT jsonb_agg(jsonb_build_object('invoiceLineId',l.id,
    'unitPrice',(private.backoffice_invoice_effective_entered_unit_price(c,l.id)
      +CASE WHEN l.id=amount_line THEN 100 ELSE 0 END)::text,
    'discountAmount',(private.backoffice_invoice_effective_line_amounts(c,l.id)->>'discountAmount')) ORDER BY l.id)
  INTO amount_lines FROM public.backoffice_sales_invoice_lines l
  WHERE l.company_id=c AND l.invoice_id=amount_invoice.id AND l.line_type='PRODUCT'
    AND l.source_kind='SALES_ORDER';
  repeat_command:=amount_command||jsonb_build_object('operationId',repeat_operation,'revision',amount_revision+1,
    'lines',amount_lines);
  repeat_prepared:=private.prepare_backoffice_invoice_revision(repeat_command);
  repeat_result:=private.execute_backoffice_invoice_revision(repeat_operation);
  IF (repeat_result->>'revision')::bigint<>2 OR jsonb_array_length(repeat_result->'journalIds')<>1
    OR (repeat_result->>'effectiveTotal')::numeric<>(repeat_prepared->'amounts'->>'afterTotal')::numeric
    OR private.backoffice_invoice_effective_total(c,amount_invoice.id,NULL)<>
      (repeat_prepared->'amounts'->>'afterTotal')::numeric THEN
    RAISE EXCEPTION 'TEST_FAILED: repeat amount-only revision mismatch';
  END IF;
  BEGIN
    repeat_command:=repeat_command||jsonb_build_object('operationId',gen_random_uuid(),
      'customerId',(SELECT id FROM public.customers WHERE company_id=c AND id<>amount_invoice.customer_id
        AND is_active ORDER BY id LIMIT 1),'revision',amount_revision+2);
    PERFORM private.prepare_backoffice_invoice_revision(repeat_command);
    PERFORM private.execute_backoffice_invoice_revision((repeat_command->>'operationId')::uuid);
    RAISE EXCEPTION 'TEST_FAILED: unsupported repeat identity change accepted';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM<>'INVOICE_REVISION_REPEAT_IDENTITY_OR_DATE_NOT_YET_SUPPORTED' THEN RAISE; END IF;
  END;
  SELECT i.* INTO STRICT report_invoice FROM public.backoffice_sales_invoices i
    JOIN staging_revision_invoice_fixture f ON f.invoice_id=i.id
    WHERE f.ordinal=3;
  SELECT id INTO STRICT report_customer FROM public.customers
    WHERE company_id=c AND code='STAGING-REVISION-CUSTOMER' AND is_active;
  SELECT count(*) INTO report_revision FROM public.backoffice_sales_invoice_price_corrections pc
    WHERE pc.company_id=c AND pc.source_invoice_id=report_invoice.id AND pc.status='POSTED';
  SELECT jsonb_agg(jsonb_build_object('invoiceLineId',l.id,
    'unitPrice',(private.backoffice_invoice_effective_entered_unit_price(c,l.id)+100)::text,
    'discountAmount',(private.backoffice_invoice_effective_line_amounts(c,l.id)->>'discountAmount')) ORDER BY l.id)
  INTO report_lines FROM public.backoffice_sales_invoice_lines l
  WHERE l.company_id=c AND l.invoice_id=report_invoice.id AND l.line_type='PRODUCT'
    AND l.source_kind='SALES_ORDER';
  report_command:=jsonb_build_object('kind','INVOICE_REVISION','invoiceId',report_invoice.id,
    'operationId',report_operation,'masterVersion',report_invoice.master_version,
    'revision',report_revision,'customerId',report_customer,'invoiceDate',report_invoice.invoice_date,
    'dueDate',jsonb_build_object('mode','KEEP_TERM'),'lines',report_lines);
  PERFORM private.prepare_backoffice_invoice_revision(report_command);
  report_result:=private.execute_backoffice_invoice_revision(report_operation);
  SET CONSTRAINTS ALL IMMEDIATE;
  SET CONSTRAINTS ALL DEFERRED;
  IF report_result->>'status' IS DISTINCT FROM 'POSTED'
    OR report_result->>'customerId' IS DISTINCT FROM report_customer::text
    OR report_result->>'invoiceDate' IS DISTINCT FROM report_invoice.invoice_date::text THEN
    RAISE EXCEPTION 'TEST_FAILED: current-date customer-only report fixture';
  END IF;
END
$test$;

-- Exercise the canonical Return -> Credit Note path against a POSTED Invoice
-- whose customer and amount were both changed by the unified revision above.
-- Physical stock effects remain owned by the existing Return receipt runtime.
DO $return_credit$
DECLARE
  c constant uuid:='4eedbf12-3c60-40e0-b2b7-1a48ca62b6f8'::uuid;
  target_invoice public.backoffice_sales_invoices%rowtype;
  target_line public.backoffice_sales_invoice_lines%rowtype;
  effective_identity jsonb;effective_line jsonb;source_invoice jsonb;source_delivery jsonb;
  v_order_id uuid;v_order_line_id uuid;v_delivery_id uuid;v_return_id uuid;v_return_line_id uuid;
  v_receipt_id uuid;v_receipt_line_id uuid;v_note_id uuid;v_warehouse_id uuid;v_product_id uuid;
  v_version bigint;stock_before numeric;stock_after numeric;result jsonb;retry jsonb;
  allocate_operation uuid:=gen_random_uuid();post_operation uuid:=gen_random_uuid();
  expected_total numeric;note_total numeric;note_customer uuid;note_snapshot jsonb;
  return_status text;expected_return_status text;journal_customer_rows integer;
BEGIN
  SELECT invoice.* INTO STRICT target_invoice
  FROM public.backoffice_sales_invoices invoice
  JOIN staging_revision_invoice_fixture fixture ON fixture.invoice_id=invoice.id
  WHERE fixture.ordinal=3;
  SELECT line.* INTO STRICT target_line
  FROM public.backoffice_sales_invoice_lines line
  WHERE line.company_id=c AND line.invoice_id=target_invoice.id
    AND line.line_type='PRODUCT' AND line.source_kind='SALES_ORDER';
  v_order_id:=target_invoice.sales_order_id;
  v_order_line_id:=target_line.sales_order_line_id;
  v_warehouse_id:=target_invoice.warehouse_id;
  v_product_id:=target_line.product_id;
  effective_identity:=private.backoffice_invoice_effective_identity(c,target_invoice.id,NULL);
  effective_line:=private.backoffice_invoice_effective_line_amounts(c,target_line.id);
  expected_total:=(effective_line->>'lineAmount')::numeric+(effective_line->>'taxAmount')::numeric;
  IF effective_identity->>'customerId'=target_invoice.customer_id::text
    OR (effective_line->>'enteredUnitPrice')::numeric=target_line.unit_price THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: revised customer and amount Return fixture required';
  END IF;
  SELECT to_jsonb(invoice) INTO STRICT source_invoice
  FROM public.backoffice_sales_invoices invoice
  WHERE invoice.company_id=c AND invoice.id=target_invoice.id;
  SELECT delivery.id,to_jsonb(delivery) INTO STRICT v_delivery_id,source_delivery
  FROM public.backoffice_sales_delivery_orders delivery
  WHERE delivery.company_id=c AND delivery.sales_order_id=v_order_id;
  SELECT COALESCE(stock.stock_qty,0) INTO stock_before
  FROM public.product_stocks stock
  WHERE stock.company_id=c AND stock.warehouse_id=v_warehouse_id AND stock.product_id=v_product_id;

  result:=public.save_backoffice_sales_return_draft(NULL,NULL,gen_random_uuid(),v_order_id,
    jsonb_build_object('reason','Unified Invoice revision Return behavior',
      'lines',jsonb_build_array(jsonb_build_object('salesOrderLineId',v_order_line_id,
        'quantityUom',target_line.quantity_uom,'reason','Rollback-only revised Invoice Return'))));
  v_return_id:=(result->'data'->>'id')::uuid;
  result:=public.submit_backoffice_sales_return(v_return_id,
    (result->'data'->>'masterVersion')::bigint,gen_random_uuid());
  result:=public.approve_backoffice_sales_return(v_return_id,
    (result->'data'->>'masterVersion')::bigint,gen_random_uuid());
  SELECT line.id INTO STRICT v_return_line_id
  FROM public.backoffice_sales_return_lines line
  WHERE line.company_id=c AND line.return_id=v_return_id AND line.sales_order_line_id=v_order_line_id;
  result:=public.post_backoffice_sales_return_receipt(v_return_id,
    (result->'data'->>'masterVersion')::bigint,gen_random_uuid(),current_date,
    jsonb_build_array(jsonb_build_object('returnLineId',v_return_line_id,
      'quantityUom',target_line.quantity_uom,'warehouseId',v_warehouse_id,
      'disposition','RESTOCK','notes','Unified revision rollback fixture')),
    'Unified Invoice revision Return behavior');
  v_receipt_id:=(result->>'receiptId')::uuid;
  SELECT line.id INTO STRICT v_receipt_line_id
  FROM public.backoffice_sales_return_receipt_lines line
  WHERE line.company_id=c AND line.receipt_id=v_receipt_id AND line.return_line_id=v_return_line_id;
  SELECT document.master_version INTO STRICT v_version
  FROM public.backoffice_sales_returns document
  WHERE document.company_id=c AND document.id=v_return_id;
  result:=public.allocate_backoffice_sales_return_invoices(v_return_id,v_version,allocate_operation,
    jsonb_build_array(jsonb_build_object('returnReceiptLineId',v_receipt_line_id,
      'allocationType','POSTED_INVOICE','invoiceId',target_invoice.id,
      'invoiceLineId',target_line.id,'quantityUom',target_line.quantity_uom)));
  retry:=public.allocate_backoffice_sales_return_invoices(v_return_id,v_version,allocate_operation,
    jsonb_build_array(jsonb_build_object('returnReceiptLineId',v_receipt_line_id,
      'allocationType','POSTED_INVOICE','invoiceId',target_invoice.id,
      'invoiceLineId',target_line.id,'quantityUom',target_line.quantity_uom)));
  IF COALESCE((retry->>'exactRetry')::boolean,false) IS NOT TRUE THEN
    RAISE EXCEPTION 'TEST_FAILED: revised Invoice Return allocation exact retry';
  END IF;
  SELECT note.id,note.customer_id,note.grand_total,note.source_invoice_snapshot
  INTO STRICT v_note_id,note_customer,note_total,note_snapshot
  FROM public.backoffice_sales_credit_notes note
  WHERE note.company_id=c AND note.return_id=v_return_id
    AND note.source_invoice_id=target_invoice.id AND note.status='DRAFT';
  IF note_customer IS DISTINCT FROM (effective_identity->>'customerId')::uuid
    OR note_total IS DISTINCT FROM expected_total
    OR note_snapshot->'effectiveIdentity' IS DISTINCT FROM effective_identity
    OR NOT EXISTS(SELECT 1 FROM public.backoffice_sales_credit_note_lines line
      WHERE line.company_id=c AND line.credit_note_id=v_note_id
        AND line.source_invoice_line_id=target_line.id
        AND line.quantity_base=target_line.quantity_base
        AND line.unit_price=(effective_line->>'enteredUnitPrice')::numeric
        AND line.line_amount=(effective_line->>'lineAmount')::numeric
        AND line.discount_amount=(effective_line->>'discountAmount')::numeric
        AND line.tax_amount=(effective_line->>'taxAmount')::numeric) THEN
    RAISE EXCEPTION USING MESSAGE='TEST_FAILED: revised Invoice Credit Note identity/amount lineage: '||
      jsonb_build_object('noteCustomer',note_customer,'effectiveIdentity',effective_identity,
        'noteTotal',note_total,'expectedTotal',expected_total,'effectiveLine',effective_line)::text;
  END IF;
  SELECT note.master_version INTO STRICT v_version
  FROM public.backoffice_sales_credit_notes note
  WHERE note.company_id=c AND note.id=v_note_id;
  result:=public.post_backoffice_sales_credit_note(v_note_id,v_version,post_operation);
  retry:=public.post_backoffice_sales_credit_note(v_note_id,v_version,post_operation);
  expected_return_status:=CASE WHEN (result->'data'->>'refundLiabilityAmount')::numeric>0
    THEN 'REFUND_PENDING' ELSE 'COMPLETED' END;
  SELECT document.status INTO STRICT return_status
  FROM public.backoffice_sales_returns document
  WHERE document.company_id=c AND document.id=v_return_id;
  SELECT count(*) INTO journal_customer_rows
  FROM public.finance_journals journal
  JOIN public.finance_journal_lines line ON line.company_id=journal.company_id
    AND line.journal_id=journal.id
  WHERE journal.company_id=c AND journal.source_type='backoffice_sales_credit_notes'
    AND journal.source_id=v_note_id AND journal.status='POSTED'
    AND line.customer_id=(effective_identity->>'customerId')::uuid;
  SELECT stock.stock_qty INTO STRICT stock_after
  FROM public.product_stocks stock
  WHERE stock.company_id=c AND stock.warehouse_id=v_warehouse_id AND stock.product_id=v_product_id;
  IF result->'data'->>'status' IS DISTINCT FROM 'POSTED'
    OR COALESCE((retry->>'exactRetry')::boolean,false) IS NOT TRUE
    OR NOT EXISTS(SELECT 1 FROM public.backoffice_sales_credit_notes note
      WHERE note.company_id=c AND note.id=v_note_id AND note.status='POSTED'
        AND note.customer_id=(effective_identity->>'customerId')::uuid)
    OR (result->'data'->>'grandTotal')::numeric IS DISTINCT FROM expected_total
    OR (result->'data'->>'arReductionAmount')::numeric
      +(result->'data'->>'refundLiabilityAmount')::numeric IS DISTINCT FROM expected_total
    OR return_status IS DISTINCT FROM expected_return_status
    OR journal_customer_rows<1
    OR stock_after-stock_before IS DISTINCT FROM target_line.quantity_base
    OR (SELECT to_jsonb(invoice) FROM public.backoffice_sales_invoices invoice
      WHERE invoice.company_id=c AND invoice.id=target_invoice.id) IS DISTINCT FROM source_invoice
    OR (SELECT to_jsonb(delivery) FROM public.backoffice_sales_delivery_orders delivery
      WHERE delivery.company_id=c AND delivery.id=v_delivery_id) IS DISTINCT FROM source_delivery THEN
    RAISE EXCEPTION USING MESSAGE='TEST_FAILED: revised Invoice Return/Credit Note posting: '||
      jsonb_build_object('result',result,'retry',retry,'returnStatus',return_status,
        'journalCustomerRows',journal_customer_rows,'stockDelta',stock_after-stock_before)::text;
  END IF;
END
$return_credit$;
CREATE TEMP TABLE staging_revision_auth_command AS
SELECT p.invoice_id,p.request_snapshot||jsonb_build_object('operationId',p.operation_id) command
FROM private.backoffice_invoice_revision_preparations p
JOIN staging_revision_invoice_fixture f ON f.invoice_id=p.invoice_id AND f.ordinal=2
ORDER BY p.created_at DESC LIMIT 1;
GRANT SELECT ON staging_revision_auth_command TO authenticated;
CREATE TEMP TABLE staging_revision_report_target AS
SELECT r.invoice_id,r.prior_customer_id,r.new_customer_id,
  private.backoffice_invoice_effective_identity(r.company_id,r.invoice_id,current_date) report_identity,
  to_jsonb(invoice) report_source,customer.name report_customer_name,
  private.backoffice_invoice_effective_total(r.company_id,r.invoice_id,current_date) report_effective_total
FROM private.backoffice_invoice_revisions r
JOIN public.backoffice_sales_invoices invoice ON invoice.company_id=r.company_id AND invoice.id=r.invoice_id
JOIN public.customers customer ON customer.company_id=r.company_id AND customer.id=r.new_customer_id
WHERE r.company_id='4eedbf12-3c60-40e0-b2b7-1a48ca62b6f8'::uuid
  AND r.prior_customer_id<>r.new_customer_id AND r.new_invoice_date<=current_date
ORDER BY r.posted_at DESC,r.id LIMIT 1;
GRANT SELECT ON staging_revision_report_target TO authenticated;
SET LOCAL ROLE authenticated;
DO $authenticated$
DECLARE c uuid:='4eedbf12-3c60-40e0-b2b7-1a48ca62b6f8';target_invoice uuid;command jsonb;
 operation uuid;result jsonb;context jsonb;ui jsonb;payment jsonb;
 report_invoice uuid;old_customer uuid;new_customer uuid;new_statement jsonb;old_statement jsonb;aging jsonb;
 report_identity jsonb;report_source jsonb;
 report_customer_name text;report_effective_total numeric;export_payload jsonb;export_invoice jsonb;
 new_statement_hits integer;old_statement_hits integer;
BEGIN
 SELECT row.invoice_id,(row.command->>'operationId')::uuid,row.command
 INTO STRICT target_invoice,operation,command FROM staging_revision_auth_command row;
 result:=public.post_backoffice_invoice_revision(command);
 context:=public.get_backoffice_invoice_revision_context(target_invoice);
 ui:=public.get_backoffice_sales_invoice_ui(target_invoice);
 payment:=public.get_backoffice_sales_invoice_payment_context(target_invoice);
 SELECT invoice_id,prior_customer_id,new_customer_id,row.report_identity,row.report_source,
   row.report_customer_name,row.report_effective_total
 INTO STRICT report_invoice,old_customer,new_customer,report_identity,report_source,
   report_customer_name,report_effective_total
 FROM staging_revision_report_target row;
 new_statement:=public.get_finance_customer_statement(new_customer,DATE '2000-01-01',current_date,NULL);
 old_statement:=public.get_finance_customer_statement(old_customer,DATE '2000-01-01',current_date,NULL);
 aging:=public.get_finance_ar_aging(current_date,new_customer,NULL);
 export_payload:=public.export_sales_documents(DATE '2000-01-01',current_date);
 SELECT element.value INTO STRICT export_invoice FROM jsonb_array_elements(export_payload->'invoices') element(value)
   WHERE element.value->>'invoiceId'=report_invoice::text;
 SELECT count(*) INTO new_statement_hits FROM jsonb_array_elements(new_statement->'rows') row(value)
   WHERE row.value->>'sourceId'=report_invoice::text;
 SELECT count(*) INTO old_statement_hits FROM jsonb_array_elements(old_statement->'rows') row(value)
   WHERE row.value->>'sourceId'=report_invoice::text;
 IF result->>'exactRetry' IS DISTINCT FROM 'true' OR (context->>'revision')::bigint<2
   OR jsonb_array_length(context->'history')<>2
   OR jsonb_array_length(context->'lines')<1
   OR context->>'effectiveTotal' IS DISTINCT FROM result->>'effectiveTotal'
   OR ui->'data'->>'customerId' IS DISTINCT FROM context->'effectiveIdentity'->>'customerId'
   OR ui->'data'->>'invoiceDate' IS DISTINCT FROM context->'effectiveIdentity'->>'invoiceDate'
   OR ui->'data'->>'effectiveGrandTotal' IS DISTINCT FROM context->>'effectiveTotal'
   OR payment->'effectiveIdentity' IS DISTINCT FROM context->'effectiveIdentity'
   OR payment->>'invoiceRevision' IS DISTINCT FROM context->>'revision'
   OR new_statement_hits<>1
   OR old_statement_hits<>0
   OR aging->>'companyId' IS NULL
   OR export_invoice->>'customerName' IS DISTINCT FROM report_customer_name
   OR export_invoice->>'invoiceDate' IS DISTINCT FROM report_identity->>'invoiceDate'
   OR (export_invoice->>'grandTotal')::numeric IS DISTINCT FROM report_effective_total
   OR NOT has_function_privilege('authenticated','public.post_backoffice_invoice_revision(jsonb)','EXECUTE')
   OR NOT has_function_privilege('authenticated','public.get_backoffice_invoice_revision_context(uuid)','EXECUTE') THEN
  RAISE EXCEPTION USING MESSAGE='TEST_FAILED: authenticated unified RPC/context contract: '||
    jsonb_build_object('exactRetry',result->>'exactRetry','contextRevision',context->>'revision',
      'historyRows',jsonb_array_length(context->'history'),'lineRows',jsonb_array_length(context->'lines'),
      'contextTotal',context->>'effectiveTotal','resultTotal',result->>'effectiveTotal',
      'uiCustomer',ui->'data'->>'customerId','contextCustomer',context->'effectiveIdentity'->>'customerId',
      'uiDate',ui->'data'->>'invoiceDate','contextDate',context->'effectiveIdentity'->>'invoiceDate',
      'uiTotal',ui->'data'->>'effectiveGrandTotal','paymentRevision',payment->>'invoiceRevision',
      'paymentIdentity',payment->'effectiveIdentity','newStatementHits',new_statement_hits,
      'oldStatementHits',old_statement_hits,'agingCompany',aging->>'companyId',
      'reportInvoice',report_invoice,'reportIdentity',report_identity,
      'reportSourceStatus',report_source->>'status','reportSourceDate',report_source->>'invoice_date',
      'exportInvoice',export_invoice,'reportCustomerName',report_customer_name,
      'reportEffectiveTotal',report_effective_total,
      'newStatementRows',new_statement->'rows')::text; END IF;
END
$authenticated$;
SET LOCAL ROLE postgres;
SELECT 'backoffice_invoice_revision_writer_behavior' check_name,'PASS' status,0 violation_rows,
  jsonb_build_object('tested',ARRAY['atomic immutable revision write','posted balanced source-linked correction journals',
    'deferred Finance trigger settlement','exact retry without duplicate Journal','effective Customer and Invoice date',
    'receivable due-date shift','source Invoice lines Journal Receipt and DP immutable',
    'nonzero and repeat amount-only revisions with effective line/total readers',
    'repeat identity/date revision fail-closed','authenticated atomic RPC and UI/payment context',
    'effective Customer statement, AR and Sales export reader execution',
    'private permission boundary',
    'outer transaction rolled back']) details;
