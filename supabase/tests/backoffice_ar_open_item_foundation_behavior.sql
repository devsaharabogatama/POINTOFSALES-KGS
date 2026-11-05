-- Rollback-only behavior test. Requires migration 20261105100000 installed.
BEGIN;

DO $test$
DECLARE v_candidate record;v_actor uuid;v_company uuid;v_payload jsonb;
  v_customer uuid;v_filtered jsonb;v_item public.ar_open_item_registry%rowtype;
  v_allocation public.ar_open_item_allocations%rowtype;v_operation uuid;
  v_rejected boolean;v_source_counts jsonb;v_after_counts jsonb;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20261105100000')
    OR to_regprocedure('public.get_finance_ar_open_items(uuid,boolean)') IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: migration 20261105100000 must be installed';
  END IF;

  SELECT jsonb_build_object(
    'invoices',(SELECT count(*) FROM public.backoffice_sales_invoices),
    'receipts',(SELECT count(*) FROM public.customer_receipt_documents),
    'creditNotes',(SELECT count(*) FROM public.backoffice_sales_credit_notes),
    'corrections',(SELECT count(*) FROM public.backoffice_sales_invoice_price_corrections),
    'journals',(SELECT count(*) FROM public.finance_journals)) INTO v_source_counts;

  FOR v_candidate IN
    SELECT membership.user_id AS actor_id,membership.company_id
    FROM public.company_memberships membership
    JOIN auth.users auth_user ON auth_user.id=membership.user_id
    WHERE membership.status='ACTIVE'
      AND EXISTS(SELECT 1 FROM public.ar_open_item_registry item
        WHERE item.company_id=membership.company_id)
      AND EXISTS(SELECT 1 FROM public.ar_open_item_allocations allocation
        WHERE allocation.company_id=membership.company_id)
    ORDER BY membership.created_at,membership.user_id
  LOOP
    BEGIN
      PERFORM set_config('request.jwt.claims',jsonb_build_object(
        'sub',v_candidate.actor_id,'role','authenticated')::text,true);
      PERFORM set_config('request.jwt.claim.sub',v_candidate.actor_id::text,true);
      PERFORM set_config('request.jwt.claim.role','authenticated',true);
      PERFORM public.set_active_company_context(v_candidate.company_id,'BACKOFFICE');
      v_payload:=public.get_finance_ar_open_items(NULL,true);
      v_actor:=v_candidate.actor_id;v_company:=v_candidate.company_id;
      EXIT;
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM='CUSTOM_PERMISSION_DENIED' THEN CONTINUE; END IF;
      RAISE;
    END;
  END LOOP;
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: authenticated Finance VIEW actor with AR items required';
  END IF;

  IF (v_payload->>'companyId')::uuid<>v_company
    OR jsonb_typeof(v_payload->'items')<>'array' THEN
    RAISE EXCEPTION 'TEST_FAILED: authenticated AR read shape invalid';
  END IF;
  IF (SELECT count(DISTINCT audit.entity_kind)
      FROM public.ar_open_item_audit audit WHERE audit.company_id=v_company)<>3
    OR EXISTS(
      SELECT 1 FROM public.ar_open_item_audit audit
      LEFT JOIN public.ar_open_item_registry registry
        ON registry.company_id=audit.company_id AND registry.id=audit.entity_id
      WHERE audit.company_id=v_company AND audit.entity_kind='REGISTRY'
        AND (registry.id IS NULL OR audit.actor_id<>registry.created_by
          OR audit.state_snapshot IS DISTINCT FROM to_jsonb(registry)))
    OR EXISTS(
      SELECT 1 FROM public.ar_open_item_audit audit
      LEFT JOIN public.ar_open_item_operations operation
        ON operation.company_id=audit.company_id AND operation.id=audit.entity_id
      WHERE audit.company_id=v_company AND audit.entity_kind='OPERATION'
        AND (operation.id IS NULL OR audit.actor_id<>operation.actor_id
          OR audit.state_snapshot IS DISTINCT FROM to_jsonb(operation)))
    OR EXISTS(
      SELECT 1 FROM public.ar_open_item_audit audit
      LEFT JOIN public.ar_open_item_allocations allocation
        ON allocation.company_id=audit.company_id AND allocation.id=audit.entity_id
      WHERE audit.company_id=v_company AND audit.entity_kind='ALLOCATION'
        AND (allocation.id IS NULL OR audit.actor_id<>allocation.created_by
          OR audit.state_snapshot IS DISTINCT FROM to_jsonb(allocation))) THEN
    RAISE EXCEPTION 'TEST_FAILED: audit actor/snapshot lineage invalid';
  END IF;
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(v_payload->'items') item
      WHERE NOT EXISTS(SELECT 1 FROM public.ar_open_item_registry registry
        WHERE registry.company_id=v_company AND registry.id=(item->>'id')::uuid)) THEN
    RAISE EXCEPTION 'TEST_FAILED: cross-Company AR item leaked';
  END IF;

  SELECT item.customer_id INTO v_customer FROM public.ar_open_item_registry item
  WHERE item.company_id=v_company ORDER BY item.created_at,item.id LIMIT 1;
  v_filtered:=public.get_finance_ar_open_items(v_customer,true);
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(v_filtered->'items') item
      WHERE (item->>'customerId')::uuid<>v_customer) THEN
    RAISE EXCEPTION 'TEST_FAILED: Customer filter leaked another Customer';
  END IF;

  SELECT * INTO v_item FROM public.ar_open_item_registry item
  WHERE item.company_id=v_company ORDER BY item.created_at,item.id LIMIT 1;
  v_rejected:=false;
  BEGIN
    UPDATE public.ar_open_item_registry SET document_no=document_no WHERE id=v_item.id;
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='AR_OPEN_ITEM_HISTORY_IMMUTABLE' THEN v_rejected:=true; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'TEST_FAILED: registry history mutation accepted'; END IF;

  SELECT * INTO v_allocation FROM public.ar_open_item_allocations allocation
  WHERE allocation.company_id=v_company AND allocation.source_kind='RECEIPT_ALLOCATION'
  ORDER BY allocation.created_at,allocation.id LIMIT 1;
  IF v_allocation.id IS NOT NULL THEN
    v_operation:=gen_random_uuid();
    INSERT INTO public.ar_open_item_operations(id,company_id,operation_kind,idempotency_key,
      request_hash,actor_id,operation_snapshot)
    VALUES(v_operation,v_company,'BACKFILL_RECEIPT','TEST-OVERALLOC|'||v_operation,
      md5(v_operation::text),v_actor,jsonb_build_object('test',true));
    IF (SELECT count(*) FROM public.ar_open_item_audit audit
        WHERE audit.company_id=v_company AND audit.entity_kind='OPERATION'
          AND audit.entity_id=v_operation AND audit.actor_id=v_actor
          AND audit.state_snapshot->>'actor_id'=v_actor::text)<>1 THEN
      RAISE EXCEPTION 'TEST_FAILED: operation audit trigger actor lineage invalid';
    END IF;
    v_rejected:=false;
    BEGIN
      INSERT INTO public.ar_open_item_allocations(company_id,operation_id,debit_item_id,
        credit_item_id,allocated_amount,source_kind,source_id,created_by)
      VALUES(v_company,v_operation,v_allocation.debit_item_id,v_allocation.credit_item_id,
        0.0001,'RECEIPT_ALLOCATION',gen_random_uuid(),v_actor);
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM='AR_OPEN_ITEM_ALLOCATION_EXCEEDS_RESIDUAL'
        THEN v_rejected:=true; ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
      RAISE EXCEPTION 'TEST_FAILED: over-allocation accepted';
    END IF;
    v_rejected:=false;
    BEGIN
      INSERT INTO public.ar_open_item_operations(company_id,operation_kind,idempotency_key,
        request_hash,actor_id,operation_snapshot)
      VALUES(v_company,'BACKFILL_RECEIPT','TEST-OVERALLOC|'||v_operation,
        md5(v_operation::text),v_actor,jsonb_build_object('test',true));
    EXCEPTION WHEN unique_violation THEN v_rejected:=true;
    END;
    IF NOT v_rejected THEN RAISE EXCEPTION 'TEST_FAILED: duplicate operation key accepted'; END IF;
  END IF;

  IF has_table_privilege('authenticated','public.ar_open_item_registry','SELECT')
    OR has_table_privilege('authenticated','public.ar_open_item_operations','SELECT')
    OR has_table_privilege('authenticated','public.ar_open_item_allocations','SELECT')
    OR has_table_privilege('authenticated','public.ar_open_item_audit','SELECT') THEN
    RAISE EXCEPTION 'TEST_FAILED: authenticated direct table read is open';
  END IF;

  SELECT jsonb_build_object(
    'invoices',(SELECT count(*) FROM public.backoffice_sales_invoices),
    'receipts',(SELECT count(*) FROM public.customer_receipt_documents),
    'creditNotes',(SELECT count(*) FROM public.backoffice_sales_credit_notes),
    'corrections',(SELECT count(*) FROM public.backoffice_sales_invoice_price_corrections),
    'journals',(SELECT count(*) FROM public.finance_journals)) INTO v_after_counts;
  IF v_after_counts<>v_source_counts THEN
    RAISE EXCEPTION 'TEST_FAILED: read foundation changed canonical source rows';
  END IF;
END
$test$;

SELECT 'backoffice_ar_open_item_foundation_behavior' AS check_name,'PASS' AS status,
  0::bigint AS violation_rows,jsonb_build_object('tested',ARRAY[
    'installed exact forward migration','authenticated Finance VIEW read',
    'active Company isolation','Customer filter','append-only registry',
    'registry/operation/allocation audit actor and snapshot lineage',
    'shared operation audit trigger execution',
    'allocation residual guard when fixture exists','operation idempotency when fixture exists',
    'direct authenticated table denial','zero canonical source mutation',
    'all test writes rolled back']) AS details;
ROLLBACK;
