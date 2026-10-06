-- STAGING DEVELOPMENT CANDIDATE, not a migration or a posting endpoint.
-- Preparation has NO effective Invoice, settlement, revision-counter or GL effect.
CREATE TABLE private.backoffice_invoice_revision_preparations (
  company_id uuid NOT NULL REFERENCES public.companies(id),
  operation_id uuid NOT NULL,
  invoice_id uuid NOT NULL,
  actor_id uuid NOT NULL REFERENCES public.profiles(id),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  request_snapshot jsonb NOT NULL CHECK(jsonb_typeof(request_snapshot)='object'),
  source_snapshot jsonb NOT NULL CHECK(jsonb_typeof(source_snapshot)='object'),
  response_snapshot jsonb NOT NULL CHECK(jsonb_typeof(response_snapshot)='object'
    AND (response_snapshot->>'status') IS NOT DISTINCT FROM 'PREPARED_NOT_POSTED'),
  PRIMARY KEY(company_id,operation_id),
  FOREIGN KEY(company_id,invoice_id) REFERENCES public.backoffice_sales_invoices(company_id,id)
);
ALTER TABLE private.backoffice_invoice_revision_preparations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.backoffice_invoice_revision_preparations FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION private.guard_backoffice_invoice_revision_preparation()
RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $guard$
BEGIN RAISE EXCEPTION 'INVOICE_REVISION_PREPARATION_IMMUTABLE'; END
$guard$;
REVOKE ALL ON FUNCTION private.guard_backoffice_invoice_revision_preparation() FROM PUBLIC,anon,authenticated,service_role;
CREATE TRIGGER invoice_revision_preparation_immutable BEFORE UPDATE OR DELETE
  ON private.backoffice_invoice_revision_preparations FOR EACH ROW
  EXECUTE FUNCTION private.guard_backoffice_invoice_revision_preparation();
CREATE TRIGGER invoice_revision_preparation_no_truncate BEFORE TRUNCATE
  ON private.backoffice_invoice_revision_preparations FOR EACH STATEMENT
  EXECUTE FUNCTION private.guard_backoffice_invoice_revision_preparation();

CREATE FUNCTION private.backoffice_invoice_revision_source_snapshot(
  p_company_id uuid,p_invoice_id uuid,p_customer_id uuid
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY INVOKER
SET search_path=pg_catalog,public,pg_temp AS $snapshot$
DECLARE v_invoice public.backoffice_sales_invoices%rowtype;v_customer jsonb;v_revisions jsonb:='[]'::jsonb;
BEGIN
  SELECT * INTO v_invoice FROM public.backoffice_sales_invoices i
    WHERE i.company_id=p_company_id AND i.id=p_invoice_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_NOT_FOUND'; END IF;
  SELECT to_jsonb(c) INTO v_customer FROM public.customers c
    WHERE c.company_id=p_company_id AND c.id=p_customer_id AND c.is_active;
  IF NOT FOUND THEN RAISE EXCEPTION 'INVOICE_REVISION_CUSTOMER_INVALID'; END IF;
  IF to_regclass('private.backoffice_invoice_revisions') IS NOT NULL THEN
    EXECUTE 'SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.revision_no),''[]''::jsonb)
      FROM private.backoffice_invoice_revisions r WHERE r.company_id=$1 AND r.invoice_id=$2'
      INTO v_revisions USING p_company_id,p_invoice_id;
  END IF;
  RETURN jsonb_build_object('invoice',to_jsonb(v_invoice),'billingCustomer',v_customer,
    'unifiedRevisions',v_revisions,
    'lines',COALESCE((SELECT jsonb_agg(to_jsonb(l) ORDER BY l.id)
      FROM public.backoffice_sales_invoice_lines l WHERE l.company_id=p_company_id AND l.invoice_id=p_invoice_id),'[]'::jsonb),
    'schedules',COALESCE((SELECT jsonb_agg(to_jsonb(s) ORDER BY s.id)
      FROM public.backoffice_sales_invoice_receivable_schedules s WHERE s.company_id=p_company_id AND s.invoice_id=p_invoice_id),'[]'::jsonb),
    'priceCorrections',COALESCE((SELECT jsonb_agg(to_jsonb(c) ORDER BY c.id)
      FROM public.backoffice_sales_invoice_price_corrections c WHERE c.company_id=p_company_id AND c.source_invoice_id=p_invoice_id),'[]'::jsonb),
    'creditNotes',COALESCE((SELECT jsonb_agg(to_jsonb(c) ORDER BY c.id)
      FROM public.backoffice_sales_credit_notes c WHERE c.company_id=p_company_id AND c.source_invoice_id=p_invoice_id),'[]'::jsonb),
    'receipts',COALESCE((SELECT jsonb_agg(jsonb_build_object('document',to_jsonb(r),
      'targetAllocations',(SELECT jsonb_agg(to_jsonb(a) ORDER BY a.id)
        FROM public.customer_receipt_backoffice_invoice_allocations a
        WHERE a.company_id=p_company_id AND a.document_id=r.id AND a.invoice_id=p_invoice_id),
      'otherBackofficeAllocations',COALESCE((SELECT jsonb_agg(to_jsonb(a) ORDER BY a.id)
        FROM public.customer_receipt_backoffice_invoice_allocations a
        WHERE a.company_id=p_company_id AND a.document_id=r.id AND a.invoice_id<>p_invoice_id),'[]'::jsonb),
      'retailAllocations',COALESCE((SELECT jsonb_agg(to_jsonb(a) ORDER BY a.id)
        FROM public.customer_receipt_allocations a
        WHERE a.company_id=p_company_id AND a.document_id=r.id),'[]'::jsonb)) ORDER BY r.id)
      FROM public.customer_receipt_documents r WHERE r.company_id=p_company_id AND EXISTS(
        SELECT 1 FROM public.customer_receipt_backoffice_invoice_allocations a
        WHERE a.company_id=p_company_id AND a.document_id=r.id AND a.invoice_id=p_invoice_id)),'[]'::jsonb),
    'downPayments',COALESCE((SELECT jsonb_agg(jsonb_build_object('invoice',to_jsonb(dp),
      'applications',COALESCE((SELECT jsonb_agg(to_jsonb(a) ORDER BY a.id)
        FROM public.backoffice_sales_down_payment_applications a
        WHERE a.company_id=p_company_id AND a.down_payment_invoice_id=dp.id),'[]'::jsonb),
      'taxBreakdowns',COALESCE((SELECT jsonb_agg(to_jsonb(t) ORDER BY t.id)
        FROM public.backoffice_sales_down_payment_application_tax_breakdowns t
        WHERE t.company_id=p_company_id AND t.down_payment_invoice_id=dp.id),'[]'::jsonb)) ORDER BY dp.id)
      FROM public.backoffice_sales_invoices dp WHERE dp.company_id=p_company_id AND EXISTS(
        SELECT 1 FROM public.backoffice_sales_down_payment_applications a
        WHERE a.company_id=p_company_id AND a.regular_invoice_id=p_invoice_id AND a.down_payment_invoice_id=dp.id)),'[]'::jsonb));
END
$snapshot$;
REVOKE ALL ON FUNCTION private.backoffice_invoice_revision_source_snapshot(uuid,uuid,uuid)
  FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION private.prepare_backoffice_invoice_revision(p_command jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,public,pg_temp AS $prepare$
DECLARE
  v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
  v_invoice_id uuid;v_operation uuid;v_customer uuid;v_date date;v_version bigint;v_revision bigint;
  v_payload jsonb;v_source jsonb;v_response jsonb;v_amounts jsonb;v_dates jsonb;v_lines jsonb;
  v_existing private.backoffice_invoice_revision_preparations%rowtype;v_notes text;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF v_company IS NULL OR v_company NOT IN('4eedbf12-3c60-40e0-b2b7-1a48ca62b6f8'::uuid,
    '07bdffb9-8c56-444c-a49b-81ac86745674'::uuid,'809abdd9-d05f-4525-9726-1951a0ae1a81'::uuid) THEN
    RAISE EXCEPTION 'INVOICE_REVISION_COMPANY_NOT_ENABLED';
  END IF;
  PERFORM private.acp_require_permission_capability(v_company,'sales.backoffice_orders','EDIT_DRAFT');
  PERFORM private.require_backoffice_sales_invoice_post_permission(v_company);
  IF jsonb_typeof(p_command) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'INVOICE_REVISION_COMMAND_INVALID'; END IF;
  IF EXISTS(SELECT 1 FROM jsonb_object_keys(p_command) k WHERE k NOT IN(
      'kind','invoiceId','operationId','masterVersion','revision','notes','customerId','invoiceDate','dueDate','lines'))
    OR p_command->>'kind' IS DISTINCT FROM 'INVOICE_REVISION'
    OR jsonb_typeof(p_command->'invoiceId') IS DISTINCT FROM 'string'
    OR jsonb_typeof(p_command->'operationId') IS DISTINCT FROM 'string'
    OR jsonb_typeof(p_command->'customerId') IS DISTINCT FROM 'string'
    OR jsonb_typeof(p_command->'invoiceDate') IS DISTINCT FROM 'string'
    OR jsonb_typeof(p_command->'masterVersion') IS DISTINCT FROM 'number'
    OR jsonb_typeof(p_command->'revision') IS DISTINCT FROM 'number'
    OR p_command->>'invoiceId' !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    OR p_command->>'operationId' !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    OR p_command->>'customerId' !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    OR p_command->>'masterVersion' !~ '^[1-9][0-9]*$' OR p_command->>'revision' !~ '^(0|[1-9][0-9]*)$'
    OR p_command->>'invoiceDate' !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
    OR jsonb_typeof(p_command->'lines') IS DISTINCT FROM 'array'
    OR COALESCE(jsonb_typeof(p_command->'notes'),'null') NOT IN('string','null') THEN
    RAISE EXCEPTION 'INVOICE_REVISION_COMMAND_INVALID';
  END IF;
  -- Unsupported paths stay closed until the unified posting orchestrator exists.
  IF p_command->'dueDate' IS DISTINCT FROM '{"mode":"KEEP_TERM"}'::jsonb THEN
    RAISE EXCEPTION 'INVOICE_REVISION_PREPARATION_KEEP_TERM_REQUIRED';
  END IF;
  BEGIN
    v_invoice_id:=(p_command->>'invoiceId')::uuid;v_operation:=(p_command->>'operationId')::uuid;
    v_customer:=(p_command->>'customerId')::uuid;v_date:=(p_command->>'invoiceDate')::date;
    v_version:=(p_command->>'masterVersion')::bigint;v_revision:=(p_command->>'revision')::bigint;
  EXCEPTION WHEN invalid_text_representation OR datetime_field_overflow OR numeric_value_out_of_range THEN
    RAISE EXCEPTION 'INVOICE_REVISION_COMMAND_INVALID'; END;
  IF '00000000-0000-0000-0000-000000000000'::uuid IN(v_invoice_id,v_operation,v_customer)
    OR v_version>9007199254740991 OR v_revision>9007199254740991 THEN
    RAISE EXCEPTION 'INVOICE_REVISION_COMMAND_INVALID';
  END IF;
  IF length(p_command->>'notes')>1000 THEN RAISE EXCEPTION 'INVOICE_REVISION_COMMAND_INVALID'; END IF;
  v_notes:=NULLIF(btrim(p_command->>'notes'),'');
  -- Validate raw lines BEFORE normalizing so extra/immutable fields cannot disappear.
  -- The replay path below must reject malformed payloads too.
  IF jsonb_array_length(p_command->'lines') NOT BETWEEN 1 AND 500 THEN RAISE EXCEPTION 'INVOICE_REVISION_COMMAND_INVALID'; END IF;
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_command->'lines') l
      WHERE jsonb_typeof(l) IS DISTINCT FROM 'object') THEN RAISE EXCEPTION 'INVOICE_REVISION_LINE_INVALID'; END IF;
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_command->'lines') l
    WHERE EXISTS(SELECT 1 FROM jsonb_object_keys(l) k WHERE k NOT IN('invoiceLineId','unitPrice','discountAmount'))
      OR jsonb_typeof(l->'invoiceLineId') IS DISTINCT FROM 'string'
      OR l->>'invoiceLineId' !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      OR jsonb_typeof(l->'unitPrice') IS DISTINCT FROM 'string'
      OR jsonb_typeof(l->'discountAmount') IS DISTINCT FROM 'string'
      OR l->>'unitPrice' !~ '^(0|[1-9][0-9]{0,19})(\.[0-9]{1,4})?$'
      OR l->>'discountAmount' !~ '^(0|[1-9][0-9]{0,19})(\.[0-9]{1,4})?$') THEN
    RAISE EXCEPTION 'INVOICE_REVISION_LINE_INVALID'; END IF;
  SELECT jsonb_agg(jsonb_build_object('invoiceLineId',(l->>'invoiceLineId')::uuid,
    'unitPrice',((l->>'unitPrice')::numeric(24,4))::text,
    'discountAmount',((l->>'discountAmount')::numeric(24,4))::text) ORDER BY (l->>'invoiceLineId')::uuid)
    INTO v_lines FROM jsonb_array_elements(p_command->'lines') l;
  v_payload:=jsonb_build_object('kind','INVOICE_REVISION','invoiceId',v_invoice_id,
    'masterVersion',v_version,'revision',v_revision,'customerId',v_customer,
    'invoiceDate',v_date,'dueDate',p_command->'dueDate','notes',v_notes,'lines',v_lines);
  PERFORM pg_advisory_xact_lock(hashtextextended(v_company||':INVOICE_REVISION_PREPARE:'||v_operation,0));
  SELECT * INTO v_existing FROM private.backoffice_invoice_revision_preparations
    WHERE company_id=v_company AND operation_id=v_operation;
  IF FOUND THEN
    IF v_existing.request_snapshot IS DISTINCT FROM v_payload THEN RAISE EXCEPTION 'IDEMPOTENCY_PAYLOAD_CONFLICT'; END IF;
    RETURN v_existing.response_snapshot||jsonb_build_object('exactRetry',true);
  END IF;
  PERFORM 1 FROM public.backoffice_sales_invoices WHERE company_id=v_company AND id=v_invoice_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_NOT_FOUND'; END IF;
  v_source:=private.backoffice_invoice_revision_source_snapshot(v_company,v_invoice_id,v_customer);
  v_amounts:=private.backoffice_invoice_revision_amount_preview(v_company,v_invoice_id,v_version,v_revision,v_lines);
  v_dates:=private.backoffice_invoice_revision_date_preview(v_company,v_invoice_id,v_version,v_date);
  v_response:=jsonb_build_object('status','PREPARED_NOT_POSTED','operationId',v_operation,
    'invoiceId',v_invoice_id,'exactRetry',false,'amounts',v_amounts,'dates',v_dates,
    'sourceFingerprint',md5(v_source::text),'requiresPostingRecheck',true);
  INSERT INTO private.backoffice_invoice_revision_preparations(company_id,operation_id,invoice_id,
    actor_id,request_snapshot,source_snapshot,response_snapshot)
    VALUES(v_company,v_operation,v_invoice_id,v_actor,v_payload,v_source,v_response);
  RETURN v_response;
END
$prepare$;
REVOKE ALL ON FUNCTION private.prepare_backoffice_invoice_revision(jsonb) FROM PUBLIC,anon,authenticated,service_role;

-- Full snapshot equality, not a checksum-based permission or concurrency token.
CREATE FUNCTION private.assert_backoffice_invoice_revision_preparation_fresh(p_operation_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $fresh$
DECLARE v_company uuid:=public.private_active_company_id();v_row private.backoffice_invoice_revision_preparations%rowtype;v_dates jsonb;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  PERFORM private.acp_require_permission_capability(v_company,'sales.backoffice_orders','EDIT_DRAFT');
  PERFORM private.require_backoffice_sales_invoice_post_permission(v_company);
  SELECT * INTO v_row FROM private.backoffice_invoice_revision_preparations
    WHERE company_id=v_company AND operation_id=p_operation_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'INVOICE_REVISION_PREPARATION_NOT_FOUND'; END IF;
  IF private.backoffice_invoice_revision_source_snapshot(v_company,v_row.invoice_id,
      (v_row.request_snapshot->>'customerId')::uuid) IS DISTINCT FROM v_row.source_snapshot THEN
    RAISE EXCEPTION 'INVOICE_REVISION_DEPENDENCIES_CHANGED';
  END IF;
  v_dates:=private.backoffice_invoice_revision_date_preview(v_company,v_row.invoice_id,
    (v_row.request_snapshot->>'masterVersion')::bigint,(v_row.request_snapshot->>'invoiceDate')::date);
  IF v_dates IS DISTINCT FROM v_row.response_snapshot->'dates' THEN
    RAISE EXCEPTION 'INVOICE_REVISION_DEPENDENCIES_CHANGED';
  END IF;
END
$fresh$;
REVOKE ALL ON FUNCTION private.assert_backoffice_invoice_revision_preparation_fresh(uuid)
  FROM PUBLIC,anon,authenticated,service_role;
