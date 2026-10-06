-- Uses four canonical taxed invoices created by the unmodified posting suite.
-- NO effective customer transfer or accounting relocation is claimed here.
DO $test$
DECLARE
  c uuid:='4eedbf12-3c60-40e0-b2b7-1a48ca62b6f8';actor uuid:=auth.uid();
  ids uuid[]; target public.backoffice_sales_invoices%rowtype;customer_new uuid:=gen_random_uuid();
  method uuid;allocations jsonb;receipt jsonb;posted jsonb;receipt_four uuid;receipt_two uuid;
  command jsonb;result jsonb;retry jsonb;operation uuid:=gen_random_uuid();snapshot jsonb;lines jsonb;
  revision bigint;before_data jsonb:='{}';after_data jsonb:='{}';t record;fingerprint text;part jsonb;
  bad jsonb;expected text;draft jsonb;
  phase text:='behavior_start';
BEGIN
  IF actor IS NULL THEN RAISE EXCEPTION 'TEST_PRECONDITION: auth context required'; END IF;
  phase:='load_fixture_ids';
  SELECT array_agg(invoice_id ORDER BY ordinal) INTO ids
  FROM staging_revision_invoice_fixture;
  IF cardinality(ids)<>4 THEN RAISE EXCEPTION 'TEST_PRECONDITION: exact four-invoice fixture required'; END IF;
  phase:='load_target_invoice';
  SELECT * INTO STRICT target FROM public.backoffice_sales_invoices WHERE company_id=c AND id=ids[1];
  IF NOT EXISTS(SELECT 1 FROM public.backoffice_sales_down_payment_applications a
      WHERE a.company_id=c AND a.regular_invoice_id=target.id AND a.status='POSTED') THEN
    RAISE EXCEPTION 'TEST_PRECONDITION: target nonzero applied DP required'; END IF;
  IF (SELECT count(DISTINCT customer_id) FROM public.backoffice_sales_invoices WHERE company_id=c AND id=ANY(ids))<>1 THEN
    RAISE EXCEPTION 'TEST_PRECONDITION: shared customer required'; END IF;
  phase:='load_payment_method';
  SELECT payment_method_id INTO STRICT method FROM public.customer_receipt_documents
    WHERE company_id=c AND status='POSTED' ORDER BY id LIMIT 1;
  INSERT INTO public.customers(id,company_id,code,name,customer_category_id,customer_type,is_active,
    is_system_customer,current_balance,credit_limit,created_by,updated_by)
    SELECT customer_new,c,'STAGING-REVISION-CUSTOMER','STAGING TEST Revised Billing',customer_category_id,
      customer_type,true,false,0,0,actor,actor FROM public.customers WHERE company_id=c AND id=target.customer_id;
  SELECT jsonb_agg(jsonb_build_object('sourceType','BACKOFFICE_SALES_INVOICE','sourceId',id,
    'clientAllocationKey',gen_random_uuid(),'allocatedAmount',1000) ORDER BY id) INTO allocations FROM unnest(ids) id;
  phase:='save_shared_four_receipt';
  receipt:=public.save_customer_receipt_allocated_draft(NULL,NULL,target.customer_id,current_date,
    method,'STAGING-SHARED-FOUR',NULL,'Shared four invoice fixture',4000,allocations);
  receipt_four:=(receipt->>'documentId')::uuid;
  phase:='post_shared_four_receipt';
  posted:=public.post_customer_receipt_unified(receipt_four,(receipt->>'masterVersion')::bigint,gen_random_uuid());
  IF posted->>'status' IS DISTINCT FROM 'POSTED' THEN RAISE EXCEPTION 'TEST_FAILED: shared receipt four not posted'; END IF;
  SELECT jsonb_agg(jsonb_build_object('sourceType','BACKOFFICE_SALES_INVOICE','sourceId',id,
    'clientAllocationKey',gen_random_uuid(),'allocatedAmount',100) ORDER BY id) INTO allocations FROM unnest(ids[1:2]) id;
  phase:='save_shared_two_receipt';
  receipt:=public.save_customer_receipt_allocated_draft(NULL,NULL,target.customer_id,current_date,
    method,'STAGING-SHARED-TWO',NULL,'Shared two invoice fixture',200,allocations);
  receipt_two:=(receipt->>'documentId')::uuid;
  phase:='post_shared_two_receipt';
  posted:=public.post_customer_receipt_unified(receipt_two,(receipt->>'masterVersion')::bigint,gen_random_uuid());
  IF posted->>'status' IS DISTINCT FROM 'POSTED' THEN RAISE EXCEPTION 'TEST_FAILED: shared receipt two not posted'; END IF;
  phase:='save_pending_receipt';
  draft:=public.save_customer_receipt_allocated_draft(NULL,NULL,target.customer_id,current_date,
    method,'STAGING-PENDING',NULL,'Pending dependency fixture',50,
    jsonb_build_array(jsonb_build_object('sourceType','BACKOFFICE_SALES_INVOICE','sourceId',target.id,
      'clientAllocationKey',gen_random_uuid(),'allocatedAmount',50)));
  -- Read again: existing payment writers may update the schedule/header version.
  SELECT * INTO STRICT target FROM public.backoffice_sales_invoices WHERE company_id=c AND id=ids[1];
  SELECT count(*) INTO revision FROM public.backoffice_sales_invoice_price_corrections
    WHERE company_id=c AND source_invoice_id=target.id AND status='POSTED';
  SELECT jsonb_agg(jsonb_build_object('invoiceLineId',l.id,
    'unitPrice',private.backoffice_invoice_effective_entered_unit_price(c,l.id)::text,
    'discountAmount',l.discount_amount::text) ORDER BY l.id) INTO lines
    FROM public.backoffice_sales_invoice_lines l WHERE l.company_id=c AND l.invoice_id=target.id
      AND l.line_type='PRODUCT' AND l.source_kind='SALES_ORDER';
  command:=jsonb_build_object('kind','INVOICE_REVISION','invoiceId',target.id,'operationId',operation,
    'masterVersion',target.master_version,'revision',revision,'customerId',customer_new,
    'invoiceDate',target.invoice_date,'dueDate',jsonb_build_object('mode','KEEP_TERM'),'lines',lines);
  FOR t IN SELECT n.nspname s,cl.relname r FROM pg_class cl JOIN pg_namespace n ON n.oid=cl.relnamespace
    WHERE cl.relkind='r' AND (n.nspname IN('public','private') OR (n.nspname='auth' AND cl.relname='users'))
      AND NOT(n.nspname='private' AND cl.relname='backoffice_invoice_revision_preparations') ORDER BY 1,2 LOOP
    EXECUTE format('SELECT md5(COALESCE(string_agg(h,'''' ORDER BY h),'''')) FROM (SELECT md5(to_jsonb(x)::text) h FROM %I.%I x) q',t.s,t.r) INTO fingerprint;
    before_data:=before_data||jsonb_build_object(t.s||'.'||t.r,fingerprint);
  END LOOP;
  phase:='prepare_revision';
  result:=private.prepare_backoffice_invoice_revision(command);
  retry:=private.prepare_backoffice_invoice_revision(command);
  IF result->>'status' IS DISTINCT FROM 'PREPARED_NOT_POSTED' OR retry->>'exactRetry' IS DISTINCT FROM 'true'
    OR result-'exactRetry' IS DISTINCT FROM retry-'exactRetry'
    OR (SELECT count(*) FROM private.backoffice_invoice_revision_preparations WHERE company_id=c AND operation_id=operation)<>1 THEN
    RAISE EXCEPTION 'TEST_FAILED: preparation exact retry'; END IF;
  SELECT source_snapshot INTO STRICT snapshot FROM private.backoffice_invoice_revision_preparations
    WHERE company_id=c AND operation_id=operation AND actor_id=actor AND created_at<=clock_timestamp();
  SELECT value INTO STRICT part FROM jsonb_array_elements(snapshot->'receipts')
    WHERE value->'document'->>'id'=receipt_four::text;
  IF jsonb_array_length(part->'targetAllocations')<>1 OR jsonb_array_length(part->'otherBackofficeAllocations')<>3
    OR (part->'targetAllocations'->0->>'allocated_amount')::numeric<>1000
    OR (SELECT sum((value->>'allocated_amount')::numeric) FROM jsonb_array_elements(part->'otherBackofficeAllocations'))<>3000 THEN
    RAISE EXCEPTION 'TEST_FAILED: four-way shared receipt ownership'; END IF;
  SELECT value INTO STRICT part FROM jsonb_array_elements(snapshot->'receipts')
    WHERE value->'document'->>'id'=receipt_two::text;
  IF jsonb_array_length(part->'targetAllocations')<>1 OR jsonb_array_length(part->'otherBackofficeAllocations')<>1
    OR (part->'targetAllocations'->0->>'allocated_amount')::numeric<>100 THEN
    RAISE EXCEPTION 'TEST_FAILED: two-way shared receipt ownership'; END IF;
  IF jsonb_array_length(snapshot->'downPayments')<1
    OR NOT EXISTS(SELECT 1 FROM jsonb_array_elements(snapshot->'downPayments') dp,
      jsonb_array_elements(dp->'applications') a WHERE a->>'regular_invoice_id'=target.id::text AND a->>'status'='POSTED')
    OR NOT EXISTS(SELECT 1 FROM jsonb_array_elements(snapshot->'receipts') r WHERE r->'document'->>'status'='DRAFT') THEN
    RAISE EXCEPTION 'TEST_FAILED: applied DP and pending Receipt must be retained'; END IF;
  PERFORM private.assert_backoffice_invoice_revision_preparation_fresh(operation);
  FOR bad,expected IN SELECT * FROM (VALUES
    (command||jsonb_build_object('notes','different payload'),'IDEMPOTENCY_PAYLOAD_CONFLICT'),
    (command||jsonb_build_object('companyId',c),'INVOICE_REVISION_COMMAND_INVALID'),
    (command||jsonb_build_object('operationId',gen_random_uuid(),'customerId',gen_random_uuid()),'INVOICE_REVISION_CUSTOMER_INVALID'),
    (command||jsonb_build_object('operationId',gen_random_uuid(),'masterVersion',target.master_version+1),'MASTER_VERSION_CONFLICT')
  ) cases(payload,error) LOOP
    BEGIN PERFORM private.prepare_backoffice_invoice_revision(bad);RAISE EXCEPTION 'TEST_FAILED: invalid preparation accepted';
    EXCEPTION WHEN raise_exception THEN IF SQLERRM<>expected THEN RAISE; END IF; END;
  END LOOP;
  BEGIN
    UPDATE public.customers SET name='STAGING TEST changed billing master',master_version=master_version+1 WHERE id=customer_new;
    PERFORM private.assert_backoffice_invoice_revision_preparation_fresh(operation);
    RAISE EXCEPTION 'TEST_FAILED: Customer drift accepted';
  EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'INVOICE_REVISION_DEPENDENCIES_CHANGED' THEN RAISE; END IF; END;
  BEGIN
    PERFORM public.save_customer_receipt_allocated_draft((draft->>'documentId')::uuid,(draft->>'masterVersion')::bigint,
      target.customer_id,current_date,method,'STAGING-PENDING-EDITED',NULL,'changed dependency',50,
      jsonb_build_array(jsonb_build_object('sourceType','BACKOFFICE_SALES_INVOICE','sourceId',target.id,
        'clientAllocationKey',gen_random_uuid(),'allocatedAmount',50)));
    PERFORM private.assert_backoffice_invoice_revision_preparation_fresh(operation);
    RAISE EXCEPTION 'TEST_FAILED: Receipt drift accepted';
  EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'INVOICE_REVISION_DEPENDENCIES_CHANGED' THEN RAISE; END IF; END;
  BEGIN
    UPDATE private.backoffice_invoice_revision_preparations SET request_snapshot='{}' WHERE company_id=c AND operation_id=operation;
    RAISE EXCEPTION 'TEST_FAILED: history update allowed';
  EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'INVOICE_REVISION_PREPARATION_IMMUTABLE' THEN RAISE; END IF; END;
  BEGIN
    DELETE FROM private.backoffice_invoice_revision_preparations WHERE company_id=c AND operation_id=operation;
    RAISE EXCEPTION 'TEST_FAILED: history delete allowed';
  EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'INVOICE_REVISION_PREPARATION_IMMUTABLE' THEN RAISE; END IF; END;
  BEGIN
    PERFORM set_config('request.jwt.claim.sub','',true);
    PERFORM set_config('request.jwt.claims','{}',true);
    PERFORM private.prepare_backoffice_invoice_revision(command);
    RAISE EXCEPTION 'TEST_FAILED: unauthenticated retry accepted';
  EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'AUTHENTICATION_REQUIRED' THEN RAISE; END IF; END;
  IF auth.uid() IS DISTINCT FROM actor THEN RAISE EXCEPTION 'TEST_FAILED: auth subtransaction restore'; END IF;
  FOR t IN SELECT n.nspname s,cl.relname r FROM pg_class cl JOIN pg_namespace n ON n.oid=cl.relnamespace
    WHERE cl.relkind='r' AND (n.nspname IN('public','private') OR (n.nspname='auth' AND cl.relname='users'))
      AND NOT(n.nspname='private' AND cl.relname='backoffice_invoice_revision_preparations') ORDER BY 1,2 LOOP
    EXECUTE format('SELECT md5(COALESCE(string_agg(h,'''' ORDER BY h),'''')) FROM (SELECT md5(to_jsonb(x)::text) h FROM %I.%I x) q',t.s,t.r) INTO fingerprint;
    after_data:=after_data||jsonb_build_object(t.s||'.'||t.r,fingerprint);
  END LOOP;
  IF before_data IS DISTINCT FROM after_data THEN RAISE EXCEPTION 'TEST_FAILED: preparation changed existing business rows'; END IF;
  IF has_function_privilege('authenticated','private.prepare_backoffice_invoice_revision(jsonb)','EXECUTE')
    OR has_table_privilege('authenticated','private.backoffice_invoice_revision_preparations','INSERT') THEN
    RAISE EXCEPTION 'TEST_FAILED: candidate publicly writable'; END IF;
EXCEPTION WHEN OTHERS THEN
  RAISE EXCEPTION 'REVISION_PREPARATION_BEHAVIOR_FAILED[%]: %',phase,SQLERRM
    USING ERRCODE=SQLSTATE;
END
$test$;
SELECT 'backoffice_invoice_revision_preparation_behavior' check_name,'PASS' status,0 violation_rows,
  jsonb_build_object('tested',ARRAY['immutable prepared operation, not posting','server-owned actor and Company',
    'posted shared Receipts with four and two invoices','only target allocation selected; all siblings retained',
    'nonzero applied DP and draft Receipt dependencies','exact retry and changed-payload conflict',
    'Customer and Receipt drift rejected','history update/delete rejected','unauthenticated retry rejected',
    'existing business-row fingerprints unchanged during preparation','outer transaction rolled back']) details;
