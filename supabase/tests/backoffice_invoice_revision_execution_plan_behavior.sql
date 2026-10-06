DO $test$
DECLARE
  c uuid:='4eedbf12-3c60-40e0-b2b7-1a48ca62b6f8';target public.backoffice_sales_invoices%rowtype;
  ids uuid[];customer_new uuid;lines jsonb;revision bigint;operation uuid:=gen_random_uuid();
  command jsonb;prepared jsonb;plan jsonb;before_data jsonb:='{}';after_data jsonb:='{}';
  t record;fingerprint text;
BEGIN
  SELECT array_agg(invoice_id ORDER BY ordinal) INTO ids FROM staging_revision_invoice_fixture;
  SELECT * INTO STRICT target FROM public.backoffice_sales_invoices WHERE company_id=c AND id=ids[1];
  SELECT id INTO STRICT customer_new FROM public.customers
    WHERE company_id=c AND code='STAGING-REVISION-CUSTOMER';
  SELECT count(*) INTO revision FROM public.backoffice_sales_invoice_price_corrections
    WHERE company_id=c AND source_invoice_id=target.id AND status='POSTED';
  SELECT jsonb_agg(jsonb_build_object('invoiceLineId',l.id,
    'unitPrice',private.backoffice_invoice_effective_entered_unit_price(c,l.id)::text,
    'discountAmount',l.discount_amount::text) ORDER BY l.id) INTO lines
  FROM public.backoffice_sales_invoice_lines l WHERE l.company_id=c AND l.invoice_id=target.id
    AND l.line_type='PRODUCT' AND l.source_kind='SALES_ORDER';
  command:=jsonb_build_object('kind','INVOICE_REVISION','invoiceId',target.id,
    'operationId',operation,'masterVersion',target.master_version,'revision',revision,
    'customerId',customer_new,'invoiceDate',target.invoice_date+1,
    'dueDate',jsonb_build_object('mode','KEEP_TERM'),'lines',lines);
  FOR t IN SELECT n.nspname s,cl.relname r FROM pg_class cl JOIN pg_namespace n ON n.oid=cl.relnamespace
    WHERE cl.relkind='r' AND (n.nspname IN('public','private') OR (n.nspname='auth' AND cl.relname='users'))
      AND NOT(n.nspname='private' AND cl.relname='backoffice_invoice_revision_preparations') ORDER BY 1,2 LOOP
    EXECUTE format('SELECT md5(COALESCE(string_agg(h,'''' ORDER BY h),'''')) FROM (SELECT md5(to_jsonb(x)::text) h FROM %I.%I x) q',t.s,t.r) INTO fingerprint;
    before_data:=before_data||jsonb_build_object(t.s||'.'||t.r,fingerprint);
  END LOOP;
  prepared:=private.prepare_backoffice_invoice_revision(command);
  plan:=private.plan_backoffice_invoice_revision_execution(operation);
  IF plan->>'status' IS DISTINCT FROM 'EXECUTION_PLAN_NOT_POSTED'
    OR (plan->>'requiresAtomicWriter')::boolean IS DISTINCT FROM true
    OR (plan->>'stockEffect')::boolean IS DISTINCT FROM false
    OR jsonb_array_length(plan->'receipts')<>3
    OR (plan->>'postedReceiptAmount')::numeric<>1100
    OR (plan->>'receiptAdvanceAmount')::numeric<>1100
    OR (plan->>'draftReceiptAmount')::numeric<>50
    OR jsonb_array_length(plan->'downPayments')<1
    OR (plan->>'postedDownPaymentAmount')::numeric<=0
    OR (plan->'journal'->>'requiresRelocation')::boolean IS DISTINCT FROM true
    OR (plan->'journal'->>'lineCount')::integer<2 THEN
    RAISE EXCEPTION 'TEST_FAILED: exact execution plan mismatch: %',plan;
  END IF;
  IF (SELECT count(*) FROM jsonb_array_elements(plan->'receipts') r
      WHERE r->>'action'='TRANSFER_TO_ADVANCE_THEN_APPLY')<>2
    OR (SELECT count(*) FROM jsonb_array_elements(plan->'receipts') r
      WHERE r->>'action'='REWRITE_DRAFT_TARGET_SHARE')<>1
    OR NOT EXISTS(SELECT 1 FROM jsonb_array_elements(plan->'receipts') r
      WHERE (r->>'otherBackofficeAllocationCount')::integer=3) THEN
    RAISE EXCEPTION 'TEST_FAILED: selected Receipt share plan mismatch';
  END IF;
  FOR t IN SELECT n.nspname s,cl.relname r FROM pg_class cl JOIN pg_namespace n ON n.oid=cl.relnamespace
    WHERE cl.relkind='r' AND (n.nspname IN('public','private') OR (n.nspname='auth' AND cl.relname='users'))
      AND NOT(n.nspname='private' AND cl.relname='backoffice_invoice_revision_preparations') ORDER BY 1,2 LOOP
    EXECUTE format('SELECT md5(COALESCE(string_agg(h,'''' ORDER BY h),'''')) FROM (SELECT md5(to_jsonb(x)::text) h FROM %I.%I x) q',t.s,t.r) INTO fingerprint;
    after_data:=after_data||jsonb_build_object(t.s||'.'||t.r,fingerprint);
  END LOOP;
  IF before_data IS DISTINCT FROM after_data THEN RAISE EXCEPTION 'TEST_FAILED: execution plan changed business rows'; END IF;
END
$test$;
SELECT 'backoffice_invoice_revision_execution_plan_behavior' check_name,'PASS' status,0 violation_rows,
  jsonb_build_object('tested',ARRAY['Receipt to Invoice lock order','four/two shared Receipt selected shares',
    'posted Receipt before revised Invoice becomes advance','Draft Receipt rewrite plan','posted DP transfer plan',
    'source Journal and open-period relocation plan','no Stock FIFO SO DO or business-row mutation',
    'outer transaction rolled back']) details;
