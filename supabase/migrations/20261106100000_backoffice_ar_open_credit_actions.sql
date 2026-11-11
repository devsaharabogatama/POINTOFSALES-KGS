BEGIN;

DO $precondition$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20261105100000')
    OR NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20261105110000')
    OR NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20261105120000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Task 2/3/4 AR chain required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20261106100000')
    OR to_regprocedure('public.apply_backoffice_ar_open_credit(uuid,jsonb,date,numeric,uuid)') IS NOT NULL
    OR to_regprocedure('public.refund_backoffice_ar_open_credit(uuid,numeric,date,uuid,text,text,text,numeric,uuid)') IS NOT NULL
    OR to_regprocedure('public.convert_backoffice_ar_open_credit_to_customer_balance(uuid,numeric,date,text,numeric,uuid)') IS NOT NULL
    OR to_regprocedure('public.apply_customer_balance_to_backoffice_invoice(uuid,numeric,date,text,numeric,numeric,uuid)') IS NOT NULL
    OR to_regprocedure('public.reverse_backoffice_ar_open_credit_action(uuid,date,text,uuid)') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Task 5 already or partially installed';
  END IF;
END
$precondition$;

ALTER TABLE public.ar_open_item_allocations
  ADD COLUMN effective_date date;

ALTER TABLE public.ar_open_item_registry
  DROP CONSTRAINT ar_open_item_registry_shape,
  ADD CONSTRAINT ar_open_item_registry_shape CHECK(
    scope_kind='BACKOFFICE'
    AND item_kind IN('INVOICE','RECEIPT','CREDIT_NOTE','PRICE_CORRECTION',
      'AR_REFUND','AR_BALANCE_CONVERSION','AR_BALANCE_USAGE','AR_ACTION_REVERSAL')
    AND direction IN('DEBIT','CREDIT')
    AND ((item_kind='INVOICE' AND direction='DEBIT')
      OR (item_kind IN('RECEIPT','CREDIT_NOTE','AR_BALANCE_USAGE') AND direction='CREDIT')
      OR (item_kind IN('AR_REFUND','AR_BALANCE_CONVERSION') AND direction='DEBIT')
      OR item_kind='AR_ACTION_REVERSAL'
      OR item_kind='PRICE_CORRECTION')
    AND nullif(btrim(document_no),'') IS NOT NULL
    AND original_amount>0 AND jsonb_typeof(source_snapshot)='object');

ALTER TABLE public.ar_open_item_operations
  DROP CONSTRAINT ar_open_item_operations_shape,
  ADD CONSTRAINT ar_open_item_operations_shape CHECK(
    operation_kind IN('BACKFILL_RECEIPT','BACKFILL_CREDIT_NOTE',
      'BACKFILL_PRICE_CORRECTION','POST_RECEIPT','APPLY_CREDIT','REFUND_CREDIT',
      'CONVERT_CREDIT_BALANCE','APPLY_CUSTOMER_BALANCE','REVERSE_OPEN_CREDIT_ACTION')
    AND nullif(btrim(idempotency_key),'') IS NOT NULL
    AND request_hash~'^[0-9a-f]{32}$'
    AND jsonb_typeof(operation_snapshot)='object');

ALTER TABLE public.ar_open_item_allocations
  DROP CONSTRAINT ar_open_item_allocations_shape,
  ADD CONSTRAINT ar_open_item_allocations_shape CHECK(
    allocated_amount>0
    AND source_kind IN('RECEIPT_ALLOCATION','CREDIT_NOTE','PRICE_CORRECTION',
      'OPEN_CREDIT_APPLY','OPEN_CREDIT_REFUND','OPEN_CREDIT_CONVERSION',
      'CUSTOMER_BALANCE_USAGE','ACTION_REVERSAL_SETTLEMENT','ALLOCATION_REVERSAL')
    AND ((source_kind='ALLOCATION_REVERSAL' AND reversal_of_allocation_id IS NOT NULL)
      OR (source_kind<>'ALLOCATION_REVERSAL' AND reversal_of_allocation_id IS NULL))
    AND ((source_kind IN('RECEIPT_ALLOCATION','CREDIT_NOTE','PRICE_CORRECTION')
        AND effective_date IS NULL)
      OR (source_kind NOT IN('RECEIPT_ALLOCATION','CREDIT_NOTE','PRICE_CORRECTION')
        AND effective_date IS NOT NULL)));

CREATE INDEX ar_open_item_allocations_effective_idx
  ON public.ar_open_item_allocations(company_id,effective_date,id);

CREATE OR REPLACE FUNCTION private.ar5_item_allocated(
  p_company_id uuid,p_item_id uuid,p_as_of date DEFAULT NULL)
RETURNS numeric LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
BEGIN
  RETURN (SELECT round(COALESCE(sum(CASE WHEN allocation.reversal_of_allocation_id IS NULL
      THEN allocation.allocated_amount ELSE -allocation.allocated_amount END),0),4)
  FROM public.ar_open_item_allocations allocation
  WHERE allocation.company_id=p_company_id
    AND (allocation.debit_item_id=p_item_id OR allocation.credit_item_id=p_item_id)
    AND (p_as_of IS NULL OR COALESCE(allocation.effective_date,
      allocation.created_at::date)<=p_as_of));
END
$$;

CREATE OR REPLACE FUNCTION private.trg_ar_open_item_validate_allocation()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_debit public.ar_open_item_registry%rowtype;
  v_credit public.ar_open_item_registry%rowtype;v_debit_used numeric;v_credit_used numeric;
  v_operation_kind text;v_original public.ar_open_item_allocations%rowtype;
BEGIN
  SELECT * INTO STRICT v_debit FROM public.ar_open_item_registry item
  WHERE item.company_id=NEW.company_id AND item.id=NEW.debit_item_id FOR UPDATE;
  SELECT * INTO STRICT v_credit FROM public.ar_open_item_registry item
  WHERE item.company_id=NEW.company_id AND item.id=NEW.credit_item_id FOR UPDATE;
  IF v_debit.direction<>'DEBIT' OR v_credit.direction<>'CREDIT'
    OR v_debit.customer_id<>v_credit.customer_id THEN
    RAISE EXCEPTION 'AR_OPEN_ITEM_ALLOCATION_IDENTITY_INVALID';
  END IF;
  IF NEW.effective_date IS NOT NULL
    AND NEW.effective_date<GREATEST(v_debit.document_date,v_credit.document_date) THEN
    RAISE EXCEPTION 'AR_OPEN_ITEM_ALLOCATION_DATE_INVALID';
  END IF;
  SELECT operation.operation_kind INTO STRICT v_operation_kind
  FROM public.ar_open_item_operations operation
  WHERE operation.company_id=NEW.company_id AND operation.id=NEW.operation_id;
  IF NEW.source_kind='ALLOCATION_REVERSAL' THEN
    IF v_operation_kind<>'REVERSE_OPEN_CREDIT_ACTION' THEN
      RAISE EXCEPTION 'AR_OPEN_ITEM_ALLOCATION_OPERATION_INVALID';
    END IF;
    SELECT * INTO STRICT v_original FROM public.ar_open_item_allocations allocation
    WHERE allocation.company_id=NEW.company_id AND allocation.id=NEW.reversal_of_allocation_id
      AND allocation.reversal_of_allocation_id IS NULL FOR UPDATE;
    IF v_original.debit_item_id<>NEW.debit_item_id
      OR v_original.credit_item_id<>NEW.credit_item_id
      OR v_original.allocated_amount<>NEW.allocated_amount
      OR NEW.effective_date<v_original.effective_date
      OR EXISTS(SELECT 1 FROM public.ar_open_item_allocations reversal
        WHERE reversal.company_id=NEW.company_id
          AND reversal.reversal_of_allocation_id=v_original.id) THEN
      RAISE EXCEPTION 'AR_OPEN_ITEM_ALLOCATION_REVERSAL_INVALID';
    END IF;
    RETURN NEW;
  END IF;
  IF (NEW.source_kind='RECEIPT_ALLOCATION'
      AND v_operation_kind NOT IN('BACKFILL_RECEIPT','POST_RECEIPT'))
    OR (NEW.source_kind='CREDIT_NOTE' AND v_operation_kind<>'BACKFILL_CREDIT_NOTE')
    OR (NEW.source_kind='PRICE_CORRECTION'
      AND v_operation_kind<>'BACKFILL_PRICE_CORRECTION')
    OR (NEW.source_kind='OPEN_CREDIT_APPLY' AND v_operation_kind<>'APPLY_CREDIT')
    OR (NEW.source_kind='OPEN_CREDIT_REFUND' AND v_operation_kind<>'REFUND_CREDIT')
    OR (NEW.source_kind='OPEN_CREDIT_CONVERSION'
      AND v_operation_kind<>'CONVERT_CREDIT_BALANCE')
    OR (NEW.source_kind='CUSTOMER_BALANCE_USAGE'
      AND v_operation_kind<>'APPLY_CUSTOMER_BALANCE')
    OR (NEW.source_kind='ACTION_REVERSAL_SETTLEMENT'
      AND v_operation_kind<>'REVERSE_OPEN_CREDIT_ACTION') THEN
    RAISE EXCEPTION 'AR_OPEN_ITEM_ALLOCATION_OPERATION_INVALID';
  END IF;
  v_debit_used:=private.ar5_item_allocated(NEW.company_id,NEW.debit_item_id,NULL);
  v_credit_used:=private.ar5_item_allocated(NEW.company_id,NEW.credit_item_id,NULL);
  IF v_debit_used+NEW.allocated_amount>v_debit.original_amount
    OR v_credit_used+NEW.allocated_amount>v_credit.original_amount THEN
    RAISE EXCEPTION 'AR_OPEN_ITEM_ALLOCATION_EXCEEDS_RESIDUAL';
  END IF;
  RETURN NEW;
END
$$;

CREATE OR REPLACE FUNCTION private.ar5_operation_retry(
  p_company_id uuid,p_operation_id uuid,p_operation_kind text,p_request_hash text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_operation public.ar_open_item_operations%rowtype;
BEGIN
  SELECT * INTO v_operation FROM public.ar_open_item_operations operation
  WHERE operation.company_id=p_company_id
    AND operation.idempotency_key=p_operation_id::text;
  IF NOT FOUND THEN RETURN NULL; END IF;
  IF v_operation.operation_kind<>p_operation_kind
    OR v_operation.request_hash<>p_request_hash THEN
    RAISE EXCEPTION 'IDEMPOTENCY_PAYLOAD_CONFLICT';
  END IF;
  RETURN v_operation.operation_snapshot||jsonb_build_object('exactRetry',true);
END
$$;

CREATE OR REPLACE FUNCTION private.ar5_assert_backoffice_company(p_company_id uuid)
RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM public.company_sales_process_settings setting
    WHERE setting.company_id=p_company_id
      AND setting.active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE') THEN
    RAISE EXCEPTION 'BACKOFFICE_AR_ACTION_PROCESS_MODE_INVALID';
  END IF;
END
$$;

CREATE OR REPLACE FUNCTION public.get_finance_ar_open_items(
  p_customer_id uuid DEFAULT NULL,p_include_settled boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='8s' AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_permission jsonb;
BEGIN
  v_permission:=private.acp_require_permission_capability(
    v_company,'finance.customer_receipts','VIEW');
  RETURN (
    WITH allocated AS (
      SELECT item.id,private.ar5_item_allocated(v_company,item.id,NULL) amount
      FROM public.ar_open_item_registry item WHERE item.company_id=v_company
    ),rows AS (
      SELECT item.*,round(item.original_amount-allocated.amount,4) residual_amount
      FROM public.ar_open_item_registry item JOIN allocated ON allocated.id=item.id
      WHERE item.company_id=v_company
        AND (p_customer_id IS NULL OR item.customer_id=p_customer_id)
        AND (p_include_settled OR round(item.original_amount-allocated.amount,4)>0)
    )
    SELECT jsonb_build_object('companyId',v_company,'customerId',p_customer_id,
      'includeSettled',p_include_settled,
      'debitResidual',COALESCE(sum(residual_amount) FILTER(WHERE direction='DEBIT'),0),
      'creditResidual',COALESCE(sum(residual_amount) FILTER(WHERE direction='CREDIT'),0),
      'items',COALESCE(jsonb_agg(jsonb_build_object(
        'id',id,'itemKind',item_kind,'sourceId',source_id,'direction',direction,
        'documentNo',document_no,'documentDate',document_date,'customerId',customer_id,
        'accountId',account_id,'originalAmount',original_amount,
        'allocatedAmount',original_amount-residual_amount,'residualAmount',residual_amount,
        'sourceSnapshot',source_snapshot)
        ORDER BY document_date,document_no,id),'[]'::jsonb),
      'operations',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'id',operation.id,'operationKind',operation.operation_kind,
        'actorId',operation.actor_id,'createdAt',operation.created_at,
        'snapshot',operation.operation_snapshot)
        ORDER BY operation.created_at DESC,operation.id DESC),'[]'::jsonb)
      FROM (SELECT candidate.* FROM public.ar_open_item_operations candidate
        WHERE candidate.company_id=v_company AND candidate.operation_kind IN(
          'APPLY_CREDIT','REFUND_CREDIT','CONVERT_CREDIT_BALANCE',
          'APPLY_CUSTOMER_BALANCE','REVERSE_OPEN_CREDIT_ACTION')
        ORDER BY candidate.created_at DESC,candidate.id DESC LIMIT 200) operation))
    FROM rows);
END
$$;

CREATE FUNCTION public.apply_backoffice_ar_open_credit(
  p_credit_item_id uuid,p_allocations jsonb,p_effective_date date,
  p_expected_credit_residual numeric,p_operation_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='15s' AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
  v_credit public.ar_open_item_registry%rowtype;v_row record;v_operation_id uuid;
  v_hash text;v_retry jsonb;v_total numeric(24,4):=0;v_residual numeric(24,4);
  v_today date;v_response jsonb;v_results jsonb:='[]'::jsonb;v_allocation_id uuid;
BEGIN
  PERFORM private.acp_require_permission_capability(v_company,'finance.customer_receipts','POST');
  PERFORM private.ar5_assert_backoffice_company(v_company);
  IF p_credit_item_id IS NULL OR p_operation_id IS NULL OR p_effective_date IS NULL
    OR p_expected_credit_residual IS NULL OR jsonb_typeof(p_allocations)<>'array'
    OR jsonb_array_length(p_allocations)=0 THEN
    RAISE EXCEPTION 'AR_OPEN_CREDIT_APPLY_REQUIRED_FIELD_INVALID';
  END IF;
  v_hash:=md5(jsonb_build_object('creditItemId',p_credit_item_id,
    'allocations',p_allocations,'effectiveDate',p_effective_date,
    'expectedCreditResidual',round(p_expected_credit_residual,4))::text);
  PERFORM pg_advisory_xact_lock(hashtextextended(
    v_company||':AR5:'||p_operation_id,0));
  v_retry:=private.ar5_operation_retry(v_company,p_operation_id,'APPLY_CREDIT',v_hash);
  IF v_retry IS NOT NULL THEN RETURN v_retry; END IF;
  SELECT (clock_timestamp() AT TIME ZONE company.timezone)::date INTO STRICT v_today
  FROM public.companies company WHERE company.id=v_company AND company.status='ACTIVE';
  IF p_effective_date>v_today THEN RAISE EXCEPTION 'AR_OPEN_CREDIT_DATE_INVALID'; END IF;
  SELECT * INTO v_credit FROM public.ar_open_item_registry item
  WHERE item.company_id=v_company AND item.id=p_credit_item_id
    AND item.item_kind='CREDIT_NOTE' AND item.direction='CREDIT' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'AR_OPEN_CREDIT_NOT_FOUND'; END IF;
  v_residual:=v_credit.original_amount-private.ar5_item_allocated(v_company,v_credit.id,NULL);
  IF round(v_residual,4)<>round(p_expected_credit_residual,4) THEN
    RAISE EXCEPTION 'AR_OPEN_CREDIT_STALE_RESIDUAL';
  END IF;
  v_operation_id:=gen_random_uuid();
  FOR v_row IN SELECT value FROM jsonb_array_elements(p_allocations) value LOOP
    IF NULLIF(v_row.value->>'debitItemId','') IS NULL
      OR COALESCE((v_row.value->>'amount')::numeric,0)<=0 THEN
      RAISE EXCEPTION 'AR_OPEN_CREDIT_ALLOCATION_INVALID';
    END IF;
    v_allocation_id:=gen_random_uuid();
    PERFORM 1 FROM public.ar_open_item_registry debit
    WHERE debit.company_id=v_company AND debit.id=(v_row.value->>'debitItemId')::uuid
      AND debit.item_kind='INVOICE' AND debit.direction='DEBIT'
      AND debit.customer_id=v_credit.customer_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'AR_OPEN_CREDIT_TARGET_INVOICE_INVALID'; END IF;
    v_total:=v_total+round((v_row.value->>'amount')::numeric,4);
    v_results:=v_results||jsonb_build_array(jsonb_build_object(
      'allocationId',v_allocation_id,'debitItemId',v_row.value->>'debitItemId',
      'amount',round((v_row.value->>'amount')::numeric,4)));
  END LOOP;
  IF v_total<=0 OR v_total>v_residual THEN
    RAISE EXCEPTION 'AR_OPEN_CREDIT_ALLOCATION_EXCEEDS_RESIDUAL';
  END IF;
  v_response:=jsonb_build_object('operationId',v_operation_id,'operationKind','APPLY_CREDIT',
    'creditItemId',v_credit.id,'effectiveDate',p_effective_date,'amount',v_total,
    'allocations',v_results,'remainingCredit',v_residual-v_total,'exactRetry',false);
  INSERT INTO public.ar_open_item_operations(id,company_id,operation_kind,idempotency_key,
    request_hash,actor_id,operation_snapshot)
  VALUES(v_operation_id,v_company,'APPLY_CREDIT',p_operation_id::text,v_hash,v_actor,v_response);
  FOR v_row IN SELECT value FROM jsonb_array_elements(v_results) value LOOP
    INSERT INTO public.ar_open_item_allocations(id,company_id,operation_id,debit_item_id,
      credit_item_id,allocated_amount,source_kind,source_id,effective_date,created_by)
    VALUES((v_row.value->>'allocationId')::uuid,v_company,v_operation_id,
      (v_row.value->>'debitItemId')::uuid,v_credit.id,(v_row.value->>'amount')::numeric,
      'OPEN_CREDIT_APPLY',(v_row.value->>'allocationId')::uuid,p_effective_date,v_actor);
  END LOOP;
  RETURN v_response;
END
$$;

-- Remaining journal-producing actions and their append-only reversal are
-- installed below in the same transaction.

CREATE FUNCTION public.refund_backoffice_ar_open_credit(
  p_credit_item_id uuid,p_amount numeric,p_effective_date date,
  p_payment_method_id uuid,p_reference_no text,p_evidence_url text,p_notes text,
  p_expected_credit_residual numeric,p_operation_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='20s' AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
  v_credit public.ar_open_item_registry%rowtype;v_note public.backoffice_sales_credit_notes%rowtype;
  v_method public.payment_methods%rowtype;v_event public.financial_events%rowtype;
  v_journal public.finance_journals%rowtype;v_period public.accounting_periods%rowtype;
  v_operation_id uuid:=gen_random_uuid();v_allocation_id uuid:=gen_random_uuid();
  v_registry_id uuid:=gen_random_uuid();v_source_id uuid:=gen_random_uuid();
  v_hash text;v_retry jsonb;v_response jsonb;v_residual numeric(24,4);
  v_amount numeric(24,4):=round(COALESCE(p_amount,0),4);v_timezone text;v_today date;
  v_event_at timestamptz;v_accounting_date date;v_journal_type text:='AUTOMATIC';
  v_category uuid;v_ar_account uuid;v_settlement_account uuid;v_settlement_function text;
BEGIN
  PERFORM private.acp_require_permission_capability(v_company,'finance.customer_refunds','POST');
  PERFORM private.ar5_assert_backoffice_company(v_company);
  IF p_credit_item_id IS NULL OR p_operation_id IS NULL OR p_effective_date IS NULL
    OR p_payment_method_id IS NULL OR v_amount<=0 OR v_amount<>p_amount
    OR p_expected_credit_residual IS NULL THEN
    RAISE EXCEPTION 'AR_OPEN_CREDIT_REFUND_REQUIRED_FIELD_INVALID';
  END IF;
  IF p_evidence_url IS NOT NULL AND p_evidence_url!~*'^https://' THEN
    RAISE EXCEPTION 'AR_OPEN_CREDIT_REFUND_EVIDENCE_INVALID';
  END IF;
  v_hash:=md5(jsonb_build_object('creditItemId',p_credit_item_id,'amount',v_amount,
    'effectiveDate',p_effective_date,'paymentMethodId',p_payment_method_id,
    'referenceNo',NULLIF(btrim(p_reference_no),''),'evidenceUrl',NULLIF(btrim(p_evidence_url),''),
    'notes',NULLIF(btrim(p_notes),''),'expectedCreditResidual',round(p_expected_credit_residual,4))::text);
  PERFORM pg_advisory_xact_lock(hashtextextended(v_company||':AR5:'||p_operation_id,0));
  v_retry:=private.ar5_operation_retry(v_company,p_operation_id,'REFUND_CREDIT',v_hash);
  IF v_retry IS NOT NULL THEN RETURN v_retry; END IF;
  SELECT company.timezone,(clock_timestamp() AT TIME ZONE company.timezone)::date
  INTO STRICT v_timezone,v_today FROM public.companies company
  WHERE company.id=v_company AND company.status='ACTIVE';
  SELECT * INTO v_credit FROM public.ar_open_item_registry item
  WHERE item.company_id=v_company AND item.id=p_credit_item_id
    AND item.item_kind='CREDIT_NOTE' AND item.direction='CREDIT' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'AR_OPEN_CREDIT_NOT_FOUND'; END IF;
  SELECT * INTO STRICT v_note FROM public.backoffice_sales_credit_notes note
  WHERE note.company_id=v_company AND note.id=v_credit.source_id
    AND note.status='POSTED' AND note.source_kind='BACKOFFICE' FOR SHARE;
  IF p_effective_date<v_credit.document_date OR p_effective_date>v_today THEN
    RAISE EXCEPTION 'AR_OPEN_CREDIT_DATE_INVALID';
  END IF;
  v_residual:=v_credit.original_amount-private.ar5_item_allocated(v_company,v_credit.id,NULL);
  IF round(v_residual,4)<>round(p_expected_credit_residual,4) OR v_amount>v_residual THEN
    RAISE EXCEPTION 'AR_OPEN_CREDIT_STALE_OR_INSUFFICIENT_RESIDUAL';
  END IF;
  SELECT * INTO v_method FROM public.payment_methods method
  WHERE method.company_id=v_company AND method.id=p_payment_method_id AND method.is_active
    AND method.settlement_route IN('CASH_DRAWER','DIRECT_BANK')
    AND (method.available_all_stores OR EXISTS(SELECT 1
      FROM public.payment_method_store_assignments assignment
      WHERE assignment.company_id=v_company AND assignment.payment_method_id=method.id
        AND assignment.store_id=v_note.store_id));
  IF NOT FOUND THEN RAISE EXCEPTION 'AR_OPEN_CREDIT_REFUND_METHOD_INVALID'; END IF;
  IF v_method.proof_mode='REQUIRED' AND NULLIF(btrim(p_evidence_url),'') IS NULL THEN
    RAISE EXCEPTION 'AR_OPEN_CREDIT_REFUND_EVIDENCE_REQUIRED';
  END IF;
  v_settlement_function:=CASE v_method.settlement_route WHEN 'CASH_DRAWER' THEN 'CASH_DRAWER'
    ELSE NULLIF(btrim(v_method.bank_account_function),'') END;
  IF v_settlement_function IS NULL THEN RAISE EXCEPTION 'AR_OPEN_CREDIT_REFUND_ACCOUNT_INVALID'; END IF;
  SELECT * INTO v_period FROM public.accounting_periods period
  WHERE period.company_id=v_company AND p_effective_date BETWEEN period.start_date AND period.end_date
    AND period.status IN('OPEN','REOPENED') ORDER BY period.start_date LIMIT 1 FOR SHARE;
  IF NOT FOUND THEN
    SELECT * INTO v_period FROM public.accounting_periods period
    WHERE period.company_id=v_company AND period.start_date>p_effective_date
      AND period.status IN('OPEN','REOPENED') ORDER BY period.start_date LIMIT 1 FOR SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION 'POSTABLE_ACCOUNTING_PERIOD_NOT_FOUND'; END IF;
    v_accounting_date:=v_period.start_date;v_journal_type:='PRIOR_PERIOD_ADJUSTMENT';
  ELSE v_accounting_date:=p_effective_date; END IF;
  SELECT category.id INTO STRICT v_category FROM public.transaction_categories category
  WHERE category.company_id=v_company AND category.system_key='BACKOFFICE_CUSTOMER_REFUND'
    AND category.is_active ORDER BY category.is_system_default DESC,category.id LIMIT 1;
  v_event_at:=(p_effective_date::text||' 12:00:00')::timestamp AT TIME ZONE v_timezone;
  INSERT INTO public.financial_events(id,event_code,event_type,source_table,source_id,
    event_date,event_version,idempotency_key,payment_method,amounts,status,error_message,
    created_by,company_id,store_id,system_event_key,transaction_category_id,transaction_rule_version)
  VALUES(gen_random_uuid(),'AR5-RF-'||replace(v_source_id::text,'-',''),'SALES_REFUND'::public.event_type,
    'ar_open_item_operations',v_operation_id,v_event_at,1,
    'AR5_REFUND|'||v_company||'|'||v_operation_id,v_method.payment_method_name,
    jsonb_build_object('operationId',v_operation_id,'creditItemId',v_credit.id,
      'amount',v_amount,'settlementAccountFunction',v_settlement_function),
    'HOLD'::public.event_status,'CANONICAL_FINANCE_POSTING_PENDING',v_actor,v_company,
    v_note.store_id,'BACKOFFICE_CUSTOMER_REFUND',v_category,20261106100000)
  RETURNING * INTO v_event;
  v_ar_account:=private.resolve_financial_event_account(v_event,'CUSTOMER_RECEIVABLE');
  v_settlement_account:=private.resolve_financial_event_account(v_event,v_settlement_function);
  INSERT INTO public.finance_journals(company_id,journal_no,journal_type,accounting_period_id,
    accounting_date,original_event_date,source_type,source_id,source_version,financial_event_id,
    idempotency_key,system_event_key,transaction_category_id,transaction_rule_version,
    store_id,warehouse_id,description,status,created_by)
  VALUES(v_company,'AR5-RF-'||replace(v_source_id::text,'-',''),v_journal_type,v_period.id,
    v_accounting_date,p_effective_date,'ar_open_item_operations',v_operation_id,1,v_event.id,
    'AR5_REFUND_JOURNAL|'||v_company||'|'||v_operation_id,'BACKOFFICE_CUSTOMER_REFUND',
    v_category,20261106100000,v_note.store_id,v_note.warehouse_id,
    'Refund open credit '||v_credit.document_no,'DRAFT',v_actor) RETURNING * INTO v_journal;
  INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,account_id,debit,credit,
    store_id,warehouse_id,customer_id,description) VALUES
    (v_company,v_journal.id,10,v_ar_account,v_amount,0,v_note.store_id,v_note.warehouse_id,
      v_credit.customer_id,'AR refund open credit'),
    (v_company,v_journal.id,20,v_settlement_account,0,v_amount,v_note.store_id,v_note.warehouse_id,
      v_credit.customer_id,'Pengeluaran '||v_method.payment_method_name);
  UPDATE public.finance_journals SET status='POSTED',posted_by=v_actor,posted_at=clock_timestamp()
  WHERE company_id=v_company AND id=v_journal.id RETURNING * INTO v_journal;
  IF round(v_journal.total_debit,4)<>v_amount OR round(v_journal.total_credit,4)<>v_amount THEN
    RAISE EXCEPTION 'JOURNAL_UNBALANCED';
  END IF;
  UPDATE public.financial_events SET status='POSTED'::public.event_status,
    processed_at=clock_timestamp(),error_message=NULL,transaction_rule_version=20261106100000
  WHERE company_id=v_company AND id=v_event.id;
  INSERT INTO public.ar_open_item_registry(id,company_id,item_kind,source_id,financial_event_id,
    journal_id,journal_line_id,customer_id,account_id,direction,document_no,document_date,
    original_amount,source_snapshot,created_by)
  SELECT v_registry_id,v_company,'AR_REFUND',v_source_id,v_event.id,v_journal.id,line.id,
    v_credit.customer_id,v_ar_account,'DEBIT','AR5-RF-'||replace(v_source_id::text,'-',''),
    p_effective_date,v_amount,jsonb_build_object('operationId',v_operation_id,
      'creditItemId',v_credit.id,'paymentMethodId',v_method.id),v_actor
  FROM public.finance_journal_lines line WHERE line.company_id=v_company
    AND line.journal_id=v_journal.id AND line.account_id=v_ar_account AND line.debit=v_amount;
  v_response:=jsonb_build_object('operationId',v_operation_id,'operationKind','REFUND_CREDIT',
    'creditItemId',v_credit.id,'debitItemId',v_registry_id,'allocationId',v_allocation_id,
    'effectiveDate',p_effective_date,'amount',v_amount,'remainingCredit',v_residual-v_amount,
    'financialEventId',v_event.id,'journalId',v_journal.id,'journalNo',v_journal.journal_no,
    'settlementMethod',v_method.payment_method_name,'exactRetry',false);
  INSERT INTO public.ar_open_item_operations(id,company_id,operation_kind,idempotency_key,
    request_hash,actor_id,operation_snapshot)
  VALUES(v_operation_id,v_company,'REFUND_CREDIT',p_operation_id::text,v_hash,v_actor,v_response);
  INSERT INTO public.ar_open_item_allocations(id,company_id,operation_id,debit_item_id,
    credit_item_id,allocated_amount,source_kind,source_id,effective_date,created_by)
  VALUES(v_allocation_id,v_company,v_operation_id,v_registry_id,v_credit.id,v_amount,
    'OPEN_CREDIT_REFUND',v_allocation_id,p_effective_date,v_actor);
  RETURN v_response;
END
$$;

ALTER TABLE public.customer_balance_ledger_entries
  DROP CONSTRAINT customer_balance_ledger_source_check,
  ADD CONSTRAINT customer_balance_ledger_source_check CHECK(source_type IN(
    'MANUAL_CORRECTION','SALE_OVERPAYMENT','SALE_PAYMENT','CUSTOMER_RECEIPT',
    'OPEN_CREDIT_CONVERSION','BACKOFFICE_INVOICE_PAYMENT','OPEN_CREDIT_ACTION_REVERSAL'));

ALTER TABLE public.customer_balance_audit
  DROP CONSTRAINT customer_balance_audit_action_check,
  ADD CONSTRAINT customer_balance_audit_action_check CHECK(action IN(
    'POLICY_PROVISION','POLICY_SYNC','REQUEST_CORRECTION','APPROVE_CORRECTION',
    'REJECT_CORRECTION','AUTO_DISABLE','SALE_OVERPAYMENT_CREDIT',
    'SALE_PAYMENT_DEBIT','CUSTOMER_RECEIPT_CREDIT','OPEN_CREDIT_CONVERSION_CREDIT',
    'BACKOFFICE_INVOICE_PAYMENT_DEBIT','OPEN_CREDIT_ACTION_REVERSAL'));

CREATE OR REPLACE FUNCTION private.trg_g4_customer_balance_source_integrity()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
  IF NEW.source_type='MANUAL_CORRECTION' THEN
    IF NOT EXISTS(SELECT 1 FROM public.customer_balance_correction_requests request
      WHERE request.company_id=NEW.company_id AND request.id=NEW.source_id) THEN
      RAISE EXCEPTION 'CUSTOMER_BALANCE_CORRECTION_SOURCE_NOT_FOUND'; END IF;
  ELSIF NEW.source_type IN('SALE_OVERPAYMENT','SALE_PAYMENT') THEN
    IF NOT EXISTS(SELECT 1 FROM public.sales_payments payment
      WHERE payment.company_id=NEW.company_id AND payment.id=NEW.source_id
        AND NOT payment.is_reversal) THEN
      RAISE EXCEPTION 'CUSTOMER_BALANCE_SALE_PAYMENT_SOURCE_NOT_FOUND'; END IF;
  ELSIF NEW.source_type='CUSTOMER_RECEIPT' THEN
    IF NOT EXISTS(SELECT 1 FROM public.customer_receipt_documents document
      WHERE document.company_id=NEW.company_id AND document.id=NEW.source_id
        AND document.unapplied_disposition='CUSTOMER_BALANCE') THEN
      RAISE EXCEPTION 'CUSTOMER_BALANCE_RECEIPT_SOURCE_NOT_FOUND'; END IF;
  ELSIF NEW.source_type IN('OPEN_CREDIT_CONVERSION','BACKOFFICE_INVOICE_PAYMENT',
      'OPEN_CREDIT_ACTION_REVERSAL') THEN
    IF NOT EXISTS(SELECT 1 FROM public.ar_open_item_operations operation
      WHERE operation.company_id=NEW.company_id AND operation.id=NEW.source_id
        AND operation.operation_kind=CASE WHEN NEW.source_type='OPEN_CREDIT_ACTION_REVERSAL'
          THEN 'REVERSE_OPEN_CREDIT_ACTION' ELSE CASE NEW.source_type
          WHEN 'OPEN_CREDIT_CONVERSION' THEN 'CONVERT_CREDIT_BALANCE'
          ELSE 'APPLY_CUSTOMER_BALANCE' END END) THEN
      RAISE EXCEPTION 'CUSTOMER_BALANCE_AR_OPERATION_SOURCE_NOT_FOUND'; END IF;
  ELSE RAISE EXCEPTION 'CUSTOMER_BALANCE_SOURCE_NOT_SUPPORTED'; END IF;
  RETURN NEW;
END
$$;

CREATE FUNCTION public.convert_backoffice_ar_open_credit_to_customer_balance(
  p_credit_item_id uuid,p_amount numeric,p_effective_date date,p_reason text,
  p_expected_credit_residual numeric,p_operation_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='20s' AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
  v_credit public.ar_open_item_registry%rowtype;v_note public.backoffice_sales_credit_notes%rowtype;
  v_customer public.customers%rowtype;v_event public.financial_events%rowtype;
  v_journal public.finance_journals%rowtype;v_period public.accounting_periods%rowtype;
  v_operation_id uuid:=gen_random_uuid();v_allocation_id uuid:=gen_random_uuid();
  v_registry_id uuid:=gen_random_uuid();v_source_id uuid:=gen_random_uuid();v_ledger_id uuid;
  v_hash text;v_retry jsonb;v_response jsonb;v_residual numeric(24,4);
  v_amount numeric(24,4):=round(COALESCE(p_amount,0),4);v_timezone text;v_today date;
  v_event_at timestamptz;v_accounting_date date;v_journal_type text:='AUTOMATIC';
  v_category uuid;v_ar_account uuid;v_liability_account uuid;v_policy text;
  v_before numeric(20,4);v_after numeric(20,4);v_entry_no bigint;
BEGIN
  PERFORM private.acp_require_permission_capability(v_company,'finance.customer_balances','MANAGE');
  PERFORM private.ar5_assert_backoffice_company(v_company);
  IF p_credit_item_id IS NULL OR p_operation_id IS NULL OR p_effective_date IS NULL
    OR v_amount<=0 OR v_amount<>p_amount OR NULLIF(btrim(p_reason),'') IS NULL
    OR p_expected_credit_residual IS NULL THEN
    RAISE EXCEPTION 'AR_OPEN_CREDIT_CONVERSION_REQUIRED_FIELD_INVALID';
  END IF;
  v_hash:=md5(jsonb_build_object('creditItemId',p_credit_item_id,'amount',v_amount,
    'effectiveDate',p_effective_date,'reason',btrim(p_reason),
    'expectedCreditResidual',round(p_expected_credit_residual,4))::text);
  PERFORM pg_advisory_xact_lock(hashtextextended(v_company||':AR5:'||p_operation_id,0));
  v_retry:=private.ar5_operation_retry(v_company,p_operation_id,'CONVERT_CREDIT_BALANCE',v_hash);
  IF v_retry IS NOT NULL THEN RETURN v_retry; END IF;
  SELECT company.timezone,(clock_timestamp() AT TIME ZONE company.timezone)::date
  INTO STRICT v_timezone,v_today FROM public.companies company
  WHERE company.id=v_company AND company.status='ACTIVE';
  IF NOT EXISTS(SELECT 1 FROM public.company_features feature
      WHERE feature.company_id=v_company AND feature.feature_code='customer_balance_enabled'
        AND feature.is_enabled) THEN RAISE EXCEPTION 'CUSTOMER_BALANCE_FEATURE_DISABLED'; END IF;
  SELECT policy.lifecycle_state INTO STRICT v_policy
  FROM public.customer_balance_company_policies policy
  WHERE policy.company_id=v_company FOR UPDATE;
  IF v_policy<>'ACTIVE' THEN RAISE EXCEPTION 'CUSTOMER_BALANCE_CREDIT_DISABLED'; END IF;
  SELECT * INTO v_credit FROM public.ar_open_item_registry item
  WHERE item.company_id=v_company AND item.id=p_credit_item_id
    AND item.item_kind='CREDIT_NOTE' AND item.direction='CREDIT' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'AR_OPEN_CREDIT_NOT_FOUND'; END IF;
  SELECT * INTO STRICT v_note FROM public.backoffice_sales_credit_notes note
  WHERE note.company_id=v_company AND note.id=v_credit.source_id
    AND note.status='POSTED' AND note.source_kind='BACKOFFICE' FOR SHARE;
  SELECT * INTO v_customer FROM public.customers customer
  WHERE customer.company_id=v_company AND customer.id=v_credit.customer_id
    AND customer.is_active AND NOT customer.is_system_customer FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'CUSTOMER_BALANCE_CUSTOMER_NOT_FOUND'; END IF;
  IF p_effective_date<v_credit.document_date OR p_effective_date>v_today THEN
    RAISE EXCEPTION 'AR_OPEN_CREDIT_DATE_INVALID'; END IF;
  v_residual:=v_credit.original_amount-private.ar5_item_allocated(v_company,v_credit.id,NULL);
  IF round(v_residual,4)<>round(p_expected_credit_residual,4) OR v_amount>v_residual THEN
    RAISE EXCEPTION 'AR_OPEN_CREDIT_STALE_OR_INSUFFICIENT_RESIDUAL'; END IF;
  SELECT * INTO v_period FROM public.accounting_periods period
  WHERE period.company_id=v_company AND p_effective_date BETWEEN period.start_date AND period.end_date
    AND period.status IN('OPEN','REOPENED') ORDER BY period.start_date LIMIT 1 FOR SHARE;
  IF NOT FOUND THEN
    SELECT * INTO v_period FROM public.accounting_periods period
    WHERE period.company_id=v_company AND period.start_date>p_effective_date
      AND period.status IN('OPEN','REOPENED') ORDER BY period.start_date LIMIT 1 FOR SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION 'POSTABLE_ACCOUNTING_PERIOD_NOT_FOUND'; END IF;
    v_accounting_date:=v_period.start_date;v_journal_type:='PRIOR_PERIOD_ADJUSTMENT';
  ELSE v_accounting_date:=p_effective_date; END IF;
  SELECT category.id INTO STRICT v_category FROM public.transaction_categories category
  WHERE category.company_id=v_company AND category.system_key='CUSTOMER_BALANCE_RECEIPT'
    AND category.is_active ORDER BY category.is_system_default DESC,category.id LIMIT 1;
  v_ar_account:=private.resolve_customer_balance_account(v_company,v_category,'CUSTOMER_RECEIVABLE',
    (p_effective_date::text||' 12:00:00')::timestamp AT TIME ZONE v_timezone);
  v_liability_account:=private.resolve_customer_balance_account(v_company,v_category,
    'CUSTOMER_BALANCE_LIABILITY',(p_effective_date::text||' 12:00:00')::timestamp AT TIME ZONE v_timezone);
  v_event_at:=(p_effective_date::text||' 12:00:00')::timestamp AT TIME ZONE v_timezone;
  INSERT INTO public.financial_events(id,event_code,event_type,source_table,source_id,event_date,
    event_version,idempotency_key,payment_method,amounts,status,error_message,created_by,
    company_id,store_id,system_event_key,transaction_category_id,transaction_rule_version)
  VALUES(gen_random_uuid(),'AR5-CB-'||replace(v_source_id::text,'-',''),
    'CUSTOMER_BALANCE_ADJUSTMENT'::public.event_type,'ar_open_item_operations',v_operation_id,
    v_event_at,1,'AR5_CONVERT|'||v_company||'|'||v_operation_id,'CUSTOMER_BALANCE',
    jsonb_build_object('operationId',v_operation_id,'creditItemId',v_credit.id,'amount',v_amount),
    'HOLD'::public.event_status,'CANONICAL_FINANCE_POSTING_PENDING',v_actor,v_company,
    v_note.store_id,'CUSTOMER_BALANCE_RECEIPT',v_category,20261106100000)
  RETURNING * INTO v_event;
  INSERT INTO public.finance_journals(company_id,journal_no,journal_type,accounting_period_id,
    accounting_date,original_event_date,source_type,source_id,source_version,financial_event_id,
    idempotency_key,system_event_key,transaction_category_id,transaction_rule_version,
    store_id,warehouse_id,description,status,created_by)
  VALUES(v_company,'AR5-CB-'||replace(v_source_id::text,'-',''),v_journal_type,v_period.id,
    v_accounting_date,p_effective_date,'ar_open_item_operations',v_operation_id,1,v_event.id,
    'AR5_CONVERT_JOURNAL|'||v_company||'|'||v_operation_id,'CUSTOMER_BALANCE_RECEIPT',
    v_category,20261106100000,v_note.store_id,v_note.warehouse_id,
    'Konversi open credit '||v_credit.document_no,'DRAFT',v_actor) RETURNING * INTO v_journal;
  INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,account_id,debit,credit,
    store_id,warehouse_id,customer_id,description) VALUES
    (v_company,v_journal.id,10,v_ar_account,v_amount,0,v_note.store_id,v_note.warehouse_id,
      v_credit.customer_id,'AR konversi open credit'),
    (v_company,v_journal.id,20,v_liability_account,0,v_amount,v_note.store_id,v_note.warehouse_id,
      v_credit.customer_id,'Customer Balance liability');
  UPDATE public.finance_journals SET status='POSTED',posted_by=v_actor,posted_at=clock_timestamp()
  WHERE company_id=v_company AND id=v_journal.id RETURNING * INTO v_journal;
  IF round(v_journal.total_debit,4)<>v_amount OR round(v_journal.total_credit,4)<>v_amount THEN
    RAISE EXCEPTION 'JOURNAL_UNBALANCED'; END IF;
  UPDATE public.financial_events SET status='POSTED'::public.event_status,
    processed_at=clock_timestamp(),error_message=NULL,transaction_rule_version=20261106100000
  WHERE company_id=v_company AND id=v_event.id;
  INSERT INTO public.ar_open_item_registry(id,company_id,item_kind,source_id,financial_event_id,
    journal_id,journal_line_id,customer_id,account_id,direction,document_no,document_date,
    original_amount,source_snapshot,created_by)
  SELECT v_registry_id,v_company,'AR_BALANCE_CONVERSION',v_source_id,v_event.id,v_journal.id,line.id,
    v_credit.customer_id,v_ar_account,'DEBIT','AR5-CB-'||replace(v_source_id::text,'-',''),
    p_effective_date,v_amount,jsonb_build_object('operationId',v_operation_id,
      'creditItemId',v_credit.id),v_actor
  FROM public.finance_journal_lines line WHERE line.company_id=v_company
    AND line.journal_id=v_journal.id AND line.account_id=v_ar_account AND line.debit=v_amount;
  v_before:=v_customer.current_balance;v_after:=v_before+v_amount;
  v_entry_no:=nextval('private.customer_balance_request_no_seq');
  v_response:=jsonb_build_object('operationId',v_operation_id,
    'operationKind','CONVERT_CREDIT_BALANCE','creditItemId',v_credit.id,
    'debitItemId',v_registry_id,'allocationId',v_allocation_id,'effectiveDate',p_effective_date,
    'amount',v_amount,'remainingCredit',v_residual-v_amount,'balanceBefore',v_before,
    'balanceAfter',v_after,'financialEventId',v_event.id,'journalId',v_journal.id,
    'journalNo',v_journal.journal_no,'exactRetry',false);
  INSERT INTO public.ar_open_item_operations(id,company_id,operation_kind,idempotency_key,
    request_hash,actor_id,operation_snapshot)
  VALUES(v_operation_id,v_company,'CONVERT_CREDIT_BALANCE',p_operation_id::text,v_hash,v_actor,v_response);
  INSERT INTO public.customer_balance_ledger_entries(company_id,customer_id,store_id,entry_no,
    direction,amount,source_type,source_id,source_reference,reason,balance_before,balance_after,
    transaction_category_id,liability_account_id,source_account_id,source_account_function,
    financial_event_id,idempotency_key,payload_hash,created_by)
  VALUES(v_company,v_credit.customer_id,v_note.store_id,v_entry_no,'CREDIT',v_amount,
    'OPEN_CREDIT_CONVERSION',v_operation_id,v_credit.document_no,btrim(p_reason),v_before,v_after,
    v_category,v_liability_account,v_ar_account,'CUSTOMER_RECEIVABLE',v_event.id,p_operation_id,
    v_hash,v_actor) RETURNING id INTO v_ledger_id;
  UPDATE public.customers SET current_balance=v_after,updated_by=v_actor
  WHERE company_id=v_company AND id=v_credit.customer_id;
  INSERT INTO public.customer_balance_audit(company_id,customer_id,action,actor_id,before_state,after_state)
  VALUES(v_company,v_credit.customer_id,'OPEN_CREDIT_CONVERSION_CREDIT',v_actor,
    jsonb_build_object('balance',v_before),jsonb_build_object('balance',v_after,
      'ledgerEntryId',v_ledger_id,'operationId',v_operation_id));
  INSERT INTO public.ar_open_item_allocations(id,company_id,operation_id,debit_item_id,
    credit_item_id,allocated_amount,source_kind,source_id,effective_date,created_by)
  VALUES(v_allocation_id,v_company,v_operation_id,v_registry_id,v_credit.id,v_amount,
    'OPEN_CREDIT_CONVERSION',v_allocation_id,p_effective_date,v_actor);
  RETURN v_response||jsonb_build_object('customerBalanceLedgerEntryId',v_ledger_id);
END
$$;

CREATE FUNCTION public.apply_customer_balance_to_backoffice_invoice(
  p_invoice_item_id uuid,p_amount numeric,p_effective_date date,p_reason text,
  p_expected_invoice_residual numeric,p_expected_customer_balance numeric,
  p_operation_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='20s' AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
  v_invoice_item public.ar_open_item_registry%rowtype;v_invoice public.backoffice_sales_invoices%rowtype;
  v_customer public.customers%rowtype;v_event public.financial_events%rowtype;
  v_journal public.finance_journals%rowtype;v_period public.accounting_periods%rowtype;
  v_operation_id uuid:=gen_random_uuid();v_allocation_id uuid:=gen_random_uuid();
  v_registry_id uuid:=gen_random_uuid();v_source_id uuid:=gen_random_uuid();v_ledger_id uuid;
  v_hash text;v_retry jsonb;v_response jsonb;v_residual numeric(24,4);
  v_amount numeric(24,4):=round(COALESCE(p_amount,0),4);v_timezone text;v_today date;
  v_event_at timestamptz;v_accounting_date date;v_journal_type text:='AUTOMATIC';
  v_category uuid;v_ar_account uuid;v_liability_account uuid;v_policy text;
  v_before numeric(20,4);v_after numeric(20,4);v_entry_no bigint;
BEGIN
  PERFORM private.acp_require_permission_capability(v_company,'finance.customer_balances','MANAGE');
  PERFORM private.ar5_assert_backoffice_company(v_company);
  IF p_invoice_item_id IS NULL OR p_operation_id IS NULL OR p_effective_date IS NULL
    OR v_amount<=0 OR v_amount<>p_amount OR NULLIF(btrim(p_reason),'') IS NULL
    OR p_expected_invoice_residual IS NULL OR p_expected_customer_balance IS NULL THEN
    RAISE EXCEPTION 'CUSTOMER_BALANCE_INVOICE_PAYMENT_REQUIRED_FIELD_INVALID'; END IF;
  v_hash:=md5(jsonb_build_object('invoiceItemId',p_invoice_item_id,'amount',v_amount,
    'effectiveDate',p_effective_date,'reason',btrim(p_reason),
    'expectedInvoiceResidual',round(p_expected_invoice_residual,4),
    'expectedCustomerBalance',round(p_expected_customer_balance,4))::text);
  PERFORM pg_advisory_xact_lock(hashtextextended(v_company||':AR5:'||p_operation_id,0));
  v_retry:=private.ar5_operation_retry(v_company,p_operation_id,'APPLY_CUSTOMER_BALANCE',v_hash);
  IF v_retry IS NOT NULL THEN RETURN v_retry; END IF;
  SELECT company.timezone,(clock_timestamp() AT TIME ZONE company.timezone)::date
  INTO STRICT v_timezone,v_today FROM public.companies company
  WHERE company.id=v_company AND company.status='ACTIVE';
  IF NOT EXISTS(SELECT 1 FROM public.company_features feature
      WHERE feature.company_id=v_company AND feature.feature_code='customer_balance_enabled'
        AND feature.is_enabled) THEN RAISE EXCEPTION 'CUSTOMER_BALANCE_FEATURE_DISABLED'; END IF;
  SELECT policy.lifecycle_state INTO STRICT v_policy
  FROM public.customer_balance_company_policies policy
  WHERE policy.company_id=v_company FOR UPDATE;
  IF v_policy NOT IN('ACTIVE','WIND_DOWN') THEN RAISE EXCEPTION 'CUSTOMER_BALANCE_DEBIT_DISABLED'; END IF;
  SELECT * INTO v_invoice_item FROM public.ar_open_item_registry item
  WHERE item.company_id=v_company AND item.id=p_invoice_item_id
    AND item.item_kind='INVOICE' AND item.direction='DEBIT' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'BACKOFFICE_INVOICE_OPEN_ITEM_NOT_FOUND'; END IF;
  SELECT * INTO STRICT v_invoice FROM public.backoffice_sales_invoices invoice
  WHERE invoice.company_id=v_company AND invoice.id=v_invoice_item.source_id
    AND invoice.status='POSTED' FOR SHARE;
  SELECT * INTO v_customer FROM public.customers customer
  WHERE customer.company_id=v_company AND customer.id=v_invoice_item.customer_id
    AND NOT customer.is_system_customer FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'CUSTOMER_BALANCE_CUSTOMER_NOT_FOUND'; END IF;
  IF p_effective_date<v_invoice_item.document_date OR p_effective_date>v_today THEN
    RAISE EXCEPTION 'CUSTOMER_BALANCE_INVOICE_PAYMENT_DATE_INVALID'; END IF;
  v_residual:=v_invoice_item.original_amount-private.ar5_item_allocated(v_company,v_invoice_item.id,NULL);
  v_before:=v_customer.current_balance;
  IF round(v_residual,4)<>round(p_expected_invoice_residual,4)
    OR round(v_before,4)<>round(p_expected_customer_balance,4)
    OR v_amount>v_residual OR v_amount>v_before THEN
    RAISE EXCEPTION 'CUSTOMER_BALANCE_INVOICE_PAYMENT_STALE_OR_INSUFFICIENT'; END IF;
  SELECT * INTO v_period FROM public.accounting_periods period
  WHERE period.company_id=v_company AND p_effective_date BETWEEN period.start_date AND period.end_date
    AND period.status IN('OPEN','REOPENED') ORDER BY period.start_date LIMIT 1 FOR SHARE;
  IF NOT FOUND THEN
    SELECT * INTO v_period FROM public.accounting_periods period
    WHERE period.company_id=v_company AND period.start_date>p_effective_date
      AND period.status IN('OPEN','REOPENED') ORDER BY period.start_date LIMIT 1 FOR SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION 'POSTABLE_ACCOUNTING_PERIOD_NOT_FOUND'; END IF;
    v_accounting_date:=v_period.start_date;v_journal_type:='PRIOR_PERIOD_ADJUSTMENT';
  ELSE v_accounting_date:=p_effective_date; END IF;
  SELECT category.id INTO STRICT v_category FROM public.transaction_categories category
  WHERE category.company_id=v_company AND category.system_key='CUSTOMER_BALANCE_USAGE'
    AND category.is_active ORDER BY category.is_system_default DESC,category.id LIMIT 1;
  v_ar_account:=private.resolve_customer_balance_account(v_company,v_category,'CUSTOMER_RECEIVABLE',
    (p_effective_date::text||' 12:00:00')::timestamp AT TIME ZONE v_timezone);
  v_liability_account:=private.resolve_customer_balance_account(v_company,v_category,
    'CUSTOMER_BALANCE_LIABILITY',(p_effective_date::text||' 12:00:00')::timestamp AT TIME ZONE v_timezone);
  v_event_at:=(p_effective_date::text||' 12:00:00')::timestamp AT TIME ZONE v_timezone;
  INSERT INTO public.financial_events(id,event_code,event_type,source_table,source_id,event_date,
    event_version,idempotency_key,payment_method,amounts,status,error_message,created_by,
    company_id,store_id,system_event_key,transaction_category_id,transaction_rule_version)
  VALUES(gen_random_uuid(),'AR5-BU-'||replace(v_source_id::text,'-',''),
    'CUSTOMER_BALANCE_ADJUSTMENT'::public.event_type,'ar_open_item_operations',v_operation_id,
    v_event_at,1,'AR5_BALANCE_USE|'||v_company||'|'||v_operation_id,'CUSTOMER_BALANCE',
    jsonb_build_object('operationId',v_operation_id,'invoiceItemId',v_invoice_item.id,'amount',v_amount),
    'HOLD'::public.event_status,'CANONICAL_FINANCE_POSTING_PENDING',v_actor,v_company,
    v_invoice.store_id,'CUSTOMER_BALANCE_USAGE',v_category,20261106100000)
  RETURNING * INTO v_event;
  INSERT INTO public.finance_journals(company_id,journal_no,journal_type,accounting_period_id,
    accounting_date,original_event_date,source_type,source_id,source_version,financial_event_id,
    idempotency_key,system_event_key,transaction_category_id,transaction_rule_version,
    store_id,warehouse_id,description,status,created_by)
  VALUES(v_company,'AR5-BU-'||replace(v_source_id::text,'-',''),v_journal_type,v_period.id,
    v_accounting_date,p_effective_date,'ar_open_item_operations',v_operation_id,1,v_event.id,
    'AR5_BALANCE_USE_JOURNAL|'||v_company||'|'||v_operation_id,'CUSTOMER_BALANCE_USAGE',
    v_category,20261106100000,v_invoice.store_id,NULL,
    'Customer Balance untuk '||v_invoice_item.document_no,'DRAFT',v_actor) RETURNING * INTO v_journal;
  INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,account_id,debit,credit,
    store_id,customer_id,description) VALUES
    (v_company,v_journal.id,10,v_liability_account,v_amount,0,v_invoice.store_id,
      v_invoice_item.customer_id,'Pemakaian Customer Balance'),
    (v_company,v_journal.id,20,v_ar_account,0,v_amount,v_invoice.store_id,
      v_invoice_item.customer_id,'Pelunasan AR '||v_invoice_item.document_no);
  UPDATE public.finance_journals SET status='POSTED',posted_by=v_actor,posted_at=clock_timestamp()
  WHERE company_id=v_company AND id=v_journal.id RETURNING * INTO v_journal;
  IF round(v_journal.total_debit,4)<>v_amount OR round(v_journal.total_credit,4)<>v_amount THEN
    RAISE EXCEPTION 'JOURNAL_UNBALANCED'; END IF;
  UPDATE public.financial_events SET status='POSTED'::public.event_status,
    processed_at=clock_timestamp(),error_message=NULL,transaction_rule_version=20261106100000
  WHERE company_id=v_company AND id=v_event.id;
  INSERT INTO public.ar_open_item_registry(id,company_id,item_kind,source_id,financial_event_id,
    journal_id,journal_line_id,customer_id,account_id,direction,document_no,document_date,
    original_amount,source_snapshot,created_by)
  SELECT v_registry_id,v_company,'AR_BALANCE_USAGE',v_source_id,v_event.id,v_journal.id,line.id,
    v_invoice_item.customer_id,v_ar_account,'CREDIT','AR5-BU-'||replace(v_source_id::text,'-',''),
    p_effective_date,v_amount,jsonb_build_object('operationId',v_operation_id,
      'invoiceItemId',v_invoice_item.id),v_actor
  FROM public.finance_journal_lines line WHERE line.company_id=v_company
    AND line.journal_id=v_journal.id AND line.account_id=v_ar_account AND line.credit=v_amount;
  v_after:=v_before-v_amount;v_entry_no:=nextval('private.customer_balance_request_no_seq');
  v_response:=jsonb_build_object('operationId',v_operation_id,
    'operationKind','APPLY_CUSTOMER_BALANCE','invoiceItemId',v_invoice_item.id,
    'creditItemId',v_registry_id,'allocationId',v_allocation_id,'effectiveDate',p_effective_date,
    'amount',v_amount,'remainingInvoice',v_residual-v_amount,'balanceBefore',v_before,
    'balanceAfter',v_after,'financialEventId',v_event.id,'journalId',v_journal.id,
    'journalNo',v_journal.journal_no,'exactRetry',false);
  INSERT INTO public.ar_open_item_operations(id,company_id,operation_kind,idempotency_key,
    request_hash,actor_id,operation_snapshot)
  VALUES(v_operation_id,v_company,'APPLY_CUSTOMER_BALANCE',p_operation_id::text,v_hash,v_actor,v_response);
  INSERT INTO public.customer_balance_ledger_entries(company_id,customer_id,store_id,entry_no,
    direction,amount,source_type,source_id,source_reference,reason,balance_before,balance_after,
    transaction_category_id,liability_account_id,source_account_id,source_account_function,
    financial_event_id,idempotency_key,payload_hash,created_by)
  VALUES(v_company,v_invoice_item.customer_id,v_invoice.store_id,v_entry_no,'DEBIT',v_amount,
    'BACKOFFICE_INVOICE_PAYMENT',v_operation_id,v_invoice_item.document_no,btrim(p_reason),
    v_before,v_after,v_category,v_liability_account,v_ar_account,'CUSTOMER_RECEIVABLE',
    v_event.id,p_operation_id,v_hash,v_actor) RETURNING id INTO v_ledger_id;
  UPDATE public.customers SET current_balance=v_after,updated_by=v_actor
  WHERE company_id=v_company AND id=v_invoice_item.customer_id;
  INSERT INTO public.customer_balance_audit(company_id,customer_id,action,actor_id,before_state,after_state)
  VALUES(v_company,v_invoice_item.customer_id,'BACKOFFICE_INVOICE_PAYMENT_DEBIT',v_actor,
    jsonb_build_object('balance',v_before),jsonb_build_object('balance',v_after,
      'ledgerEntryId',v_ledger_id,'operationId',v_operation_id));
  INSERT INTO public.ar_open_item_allocations(id,company_id,operation_id,debit_item_id,
    credit_item_id,allocated_amount,source_kind,source_id,effective_date,created_by)
  VALUES(v_allocation_id,v_company,v_operation_id,v_invoice_item.id,v_registry_id,v_amount,
    'CUSTOMER_BALANCE_USAGE',v_allocation_id,p_effective_date,v_actor);
  RETURN v_response||jsonb_build_object('customerBalanceLedgerEntryId',v_ledger_id);
END
$$;

CREATE FUNCTION public.reverse_backoffice_ar_open_credit_action(
  p_original_operation_id uuid,p_effective_date date,p_reason text,p_operation_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='20s' AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
  v_original public.ar_open_item_operations%rowtype;v_original_allocation record;
  v_original_item public.ar_open_item_registry%rowtype;v_reverse_item_id uuid:=gen_random_uuid();
  v_reverse_source_id uuid:=gen_random_uuid();v_reverse_operation_id uuid:=gen_random_uuid();
  v_event public.financial_events%rowtype;v_original_event public.financial_events%rowtype;
  v_journal public.finance_journals%rowtype;v_original_journal public.finance_journals%rowtype;
  v_period public.accounting_periods%rowtype;v_customer public.customers%rowtype;
  v_ledger public.customer_balance_ledger_entries%rowtype;v_new_ledger_id uuid;
  v_hash text;v_retry jsonb;v_response jsonb;v_today date;v_timezone text;
  v_accounting_date date;v_journal_type text:='AUTOMATIC';v_line record;v_ar_line_id uuid;
  v_amount numeric(24,4);v_before numeric(20,4);v_after numeric(20,4);v_entry_no bigint;
  v_reversal_ids jsonb:='[]'::jsonb;v_reversal_id uuid;v_settlement_id uuid;
BEGIN
  IF p_original_operation_id IS NULL OR p_operation_id IS NULL OR p_effective_date IS NULL
    OR NULLIF(btrim(p_reason),'') IS NULL THEN
    RAISE EXCEPTION 'AR_OPEN_CREDIT_REVERSAL_REQUIRED_FIELD_INVALID'; END IF;
  SELECT * INTO v_original FROM public.ar_open_item_operations operation
  WHERE operation.company_id=v_company AND operation.id=p_original_operation_id FOR UPDATE;
  IF NOT FOUND OR v_original.operation_kind NOT IN('APPLY_CREDIT','REFUND_CREDIT',
      'CONVERT_CREDIT_BALANCE','APPLY_CUSTOMER_BALANCE') THEN
    RAISE EXCEPTION 'AR_OPEN_CREDIT_REVERSAL_SOURCE_INVALID'; END IF;
  IF v_original.operation_kind='REFUND_CREDIT' THEN
    PERFORM private.acp_require_permission_capability(v_company,'finance.customer_refunds','REVERSE');
  ELSIF v_original.operation_kind IN('CONVERT_CREDIT_BALANCE','APPLY_CUSTOMER_BALANCE') THEN
    PERFORM private.acp_require_permission_capability(v_company,'finance.customer_balances','MANAGE');
  ELSE
    PERFORM private.acp_require_permission_capability(v_company,'finance.customer_receipts','POST');
  END IF;
  PERFORM private.ar5_assert_backoffice_company(v_company);
  v_hash:=md5(jsonb_build_object('originalOperationId',p_original_operation_id,
    'effectiveDate',p_effective_date,'reason',btrim(p_reason))::text);
  PERFORM pg_advisory_xact_lock(hashtextextended(v_company||':AR5:'||p_operation_id,0));
  v_retry:=private.ar5_operation_retry(v_company,p_operation_id,
    'REVERSE_OPEN_CREDIT_ACTION',v_hash);
  IF v_retry IS NOT NULL THEN RETURN v_retry; END IF;
  IF EXISTS(SELECT 1 FROM public.ar_open_item_operations operation
    WHERE operation.company_id=v_company
      AND operation.operation_kind='REVERSE_OPEN_CREDIT_ACTION'
      AND operation.operation_snapshot->>'originalOperationId'=p_original_operation_id::text) THEN
    RAISE EXCEPTION 'AR_OPEN_CREDIT_ACTION_ALREADY_REVERSED'; END IF;
  SELECT company.timezone,(clock_timestamp() AT TIME ZONE company.timezone)::date
  INTO STRICT v_timezone,v_today FROM public.companies company
  WHERE company.id=v_company AND company.status='ACTIVE';
  IF p_effective_date>v_today OR EXISTS(SELECT 1 FROM public.ar_open_item_allocations allocation
    WHERE allocation.company_id=v_company AND allocation.operation_id=v_original.id
      AND p_effective_date<allocation.effective_date) THEN
    RAISE EXCEPTION 'AR_OPEN_CREDIT_REVERSAL_DATE_INVALID'; END IF;
  SELECT round(COALESCE(sum(allocation.allocated_amount),0),4) INTO v_amount
  FROM public.ar_open_item_allocations allocation
  WHERE allocation.company_id=v_company AND allocation.operation_id=v_original.id
    AND allocation.reversal_of_allocation_id IS NULL;
  IF v_amount<=0 THEN RAISE EXCEPTION 'AR_OPEN_CREDIT_REVERSAL_ALLOCATION_NOT_FOUND'; END IF;
  IF v_original.operation_kind='APPLY_CREDIT' THEN
    FOR v_original_allocation IN SELECT * FROM public.ar_open_item_allocations allocation
      WHERE allocation.company_id=v_company AND allocation.operation_id=v_original.id
        AND allocation.reversal_of_allocation_id IS NULL ORDER BY allocation.id
    LOOP
      v_reversal_id:=gen_random_uuid();
      v_reversal_ids:=v_reversal_ids||jsonb_build_array(jsonb_build_object(
        'id',v_reversal_id,'originalId',v_original_allocation.id,
        'debitItemId',v_original_allocation.debit_item_id,
        'creditItemId',v_original_allocation.credit_item_id,
        'amount',v_original_allocation.allocated_amount));
    END LOOP;
    v_response:=jsonb_build_object('operationId',v_reverse_operation_id,
      'operationKind','REVERSE_OPEN_CREDIT_ACTION','originalOperationId',v_original.id,
      'effectiveDate',p_effective_date,'amount',v_amount,'allocationReversals',v_reversal_ids,
      'exactRetry',false);
    INSERT INTO public.ar_open_item_operations(id,company_id,operation_kind,idempotency_key,
      request_hash,actor_id,operation_snapshot)
    VALUES(v_reverse_operation_id,v_company,'REVERSE_OPEN_CREDIT_ACTION',p_operation_id::text,
      v_hash,v_actor,v_response);
    FOR v_original_allocation IN SELECT value FROM jsonb_array_elements(v_reversal_ids) value LOOP
      INSERT INTO public.ar_open_item_allocations(id,company_id,operation_id,debit_item_id,
        credit_item_id,allocated_amount,source_kind,source_id,reversal_of_allocation_id,
        effective_date,created_by)
      VALUES((v_original_allocation.value->>'id')::uuid,v_company,v_reverse_operation_id,
        (v_original_allocation.value->>'debitItemId')::uuid,
        (v_original_allocation.value->>'creditItemId')::uuid,
        (v_original_allocation.value->>'amount')::numeric,'ALLOCATION_REVERSAL',
        (v_original_allocation.value->>'id')::uuid,
        (v_original_allocation.value->>'originalId')::uuid,p_effective_date,v_actor);
    END LOOP;
    RETURN v_response;
  END IF;

  SELECT * INTO STRICT v_original_item FROM public.ar_open_item_registry item
  WHERE item.company_id=v_company AND item.id=COALESCE(
    NULLIF(v_original.operation_snapshot->>'debitItemId','')::uuid,
    NULLIF(v_original.operation_snapshot->>'creditItemId','')::uuid) FOR UPDATE;
  SELECT * INTO STRICT v_original_event FROM public.financial_events event
  WHERE event.company_id=v_company
    AND event.id=(v_original.operation_snapshot->>'financialEventId')::uuid FOR SHARE;
  SELECT * INTO STRICT v_original_journal FROM public.finance_journals journal
  WHERE journal.company_id=v_company
    AND journal.id=(v_original.operation_snapshot->>'journalId')::uuid
    AND journal.status='POSTED' FOR SHARE;
  SELECT * INTO v_period FROM public.accounting_periods period
  WHERE period.company_id=v_company AND p_effective_date BETWEEN period.start_date AND period.end_date
    AND period.status IN('OPEN','REOPENED') ORDER BY period.start_date LIMIT 1 FOR SHARE;
  IF NOT FOUND THEN
    SELECT * INTO v_period FROM public.accounting_periods period
    WHERE period.company_id=v_company AND period.start_date>p_effective_date
      AND period.status IN('OPEN','REOPENED') ORDER BY period.start_date LIMIT 1 FOR SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION 'POSTABLE_ACCOUNTING_PERIOD_NOT_FOUND'; END IF;
    v_accounting_date:=v_period.start_date;v_journal_type:='PRIOR_PERIOD_ADJUSTMENT';
  ELSE v_accounting_date:=p_effective_date; END IF;
  INSERT INTO public.financial_events(id,event_code,event_type,source_table,source_id,event_date,
    event_version,idempotency_key,payment_method,amounts,status,error_message,created_by,
    company_id,store_id,system_event_key,transaction_category_id,transaction_rule_version)
  VALUES(gen_random_uuid(),'AR5-RV-'||replace(v_reverse_source_id::text,'-',''),
    v_original_event.event_type,'ar_open_item_operations',v_reverse_operation_id,
    (p_effective_date::text||' 12:00:00')::timestamp AT TIME ZONE v_timezone,1,
    'AR5_REVERSAL|'||v_company||'|'||v_reverse_operation_id,v_original_event.payment_method,
    jsonb_build_object('originalOperationId',v_original.id,'amount',v_amount,'reason',btrim(p_reason)),
    'HOLD'::public.event_status,'CANONICAL_FINANCE_POSTING_PENDING',v_actor,v_company,
    v_original_event.store_id,v_original_event.system_event_key,
    v_original_event.transaction_category_id,20261106100000) RETURNING * INTO v_event;
  INSERT INTO public.finance_journals(company_id,journal_no,journal_type,accounting_period_id,
    accounting_date,original_event_date,source_type,source_id,source_version,financial_event_id,
    idempotency_key,system_event_key,transaction_category_id,transaction_rule_version,
    store_id,warehouse_id,description,status,created_by)
  VALUES(v_company,'AR5-RV-'||replace(v_reverse_source_id::text,'-',''),v_journal_type,v_period.id,
    v_accounting_date,p_effective_date,'ar_open_item_operations',v_reverse_operation_id,1,v_event.id,
    'AR5_REVERSAL_JOURNAL|'||v_company||'|'||v_reverse_operation_id,
    v_original_journal.system_event_key,v_original_journal.transaction_category_id,
    20261106100000,v_original_journal.store_id,v_original_journal.warehouse_id,
    'Reversal '||v_original_journal.journal_no||': '||btrim(p_reason),'DRAFT',v_actor)
  RETURNING * INTO v_journal;
  FOR v_line IN SELECT * FROM public.finance_journal_lines line
    WHERE line.company_id=v_company AND line.journal_id=v_original_journal.id ORDER BY line.line_no
  LOOP
    INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,account_id,debit,credit,
      store_id,warehouse_id,customer_id,supplier_id,description)
    VALUES(v_company,v_journal.id,v_line.line_no,v_line.account_id,v_line.credit,v_line.debit,
      v_line.store_id,v_line.warehouse_id,v_line.customer_id,v_line.supplier_id,
      'Reversal: '||v_line.description);
  END LOOP;
  UPDATE public.finance_journals SET status='POSTED',posted_by=v_actor,posted_at=clock_timestamp()
  WHERE company_id=v_company AND id=v_journal.id RETURNING * INTO v_journal;
  IF round(v_journal.total_debit,4)<>v_amount OR round(v_journal.total_credit,4)<>v_amount THEN
    RAISE EXCEPTION 'JOURNAL_UNBALANCED'; END IF;
  UPDATE public.financial_events SET status='POSTED'::public.event_status,
    processed_at=clock_timestamp(),error_message=NULL,transaction_rule_version=20261106100000
  WHERE company_id=v_company AND id=v_event.id;
  SELECT line.id INTO STRICT v_ar_line_id FROM public.finance_journal_lines line
  WHERE line.company_id=v_company AND line.journal_id=v_journal.id
    AND line.account_id=v_original_item.account_id
    AND ((v_original_item.direction='DEBIT' AND line.credit=v_original_item.original_amount)
      OR (v_original_item.direction='CREDIT' AND line.debit=v_original_item.original_amount));
  INSERT INTO public.ar_open_item_registry(id,company_id,item_kind,source_id,financial_event_id,
    journal_id,journal_line_id,customer_id,account_id,direction,document_no,document_date,
    original_amount,source_snapshot,created_by)
  VALUES(v_reverse_item_id,v_company,'AR_ACTION_REVERSAL',v_reverse_source_id,v_event.id,
    v_journal.id,v_ar_line_id,v_original_item.customer_id,v_original_item.account_id,
    CASE v_original_item.direction WHEN 'DEBIT' THEN 'CREDIT' ELSE 'DEBIT' END,
    'AR5-RV-'||replace(v_reverse_source_id::text,'-',''),p_effective_date,
    v_original_item.original_amount,jsonb_build_object('originalOperationId',v_original.id,
      'originalItemId',v_original_item.id),v_actor);
  v_response:=jsonb_build_object('operationId',v_reverse_operation_id,
    'operationKind','REVERSE_OPEN_CREDIT_ACTION','originalOperationId',v_original.id,
    'effectiveDate',p_effective_date,'amount',v_amount,'reversalItemId',v_reverse_item_id,
    'financialEventId',v_event.id,'journalId',v_journal.id,'journalNo',v_journal.journal_no,
    'exactRetry',false);
  INSERT INTO public.ar_open_item_operations(id,company_id,operation_kind,idempotency_key,
    request_hash,actor_id,operation_snapshot)
  VALUES(v_reverse_operation_id,v_company,'REVERSE_OPEN_CREDIT_ACTION',p_operation_id::text,
    v_hash,v_actor,v_response);
  FOR v_original_allocation IN SELECT * FROM public.ar_open_item_allocations allocation
    WHERE allocation.company_id=v_company AND allocation.operation_id=v_original.id
      AND allocation.reversal_of_allocation_id IS NULL ORDER BY allocation.id
  LOOP
    v_reversal_id:=gen_random_uuid();
    INSERT INTO public.ar_open_item_allocations(id,company_id,operation_id,debit_item_id,
      credit_item_id,allocated_amount,source_kind,source_id,reversal_of_allocation_id,
      effective_date,created_by)
    VALUES(v_reversal_id,v_company,v_reverse_operation_id,v_original_allocation.debit_item_id,
      v_original_allocation.credit_item_id,v_original_allocation.allocated_amount,
      'ALLOCATION_REVERSAL',v_reversal_id,v_original_allocation.id,p_effective_date,v_actor);
  END LOOP;
  v_settlement_id:=gen_random_uuid();
  INSERT INTO public.ar_open_item_allocations(id,company_id,operation_id,debit_item_id,
    credit_item_id,allocated_amount,source_kind,source_id,effective_date,created_by)
  VALUES(v_settlement_id,v_company,v_reverse_operation_id,
    CASE WHEN v_original_item.direction='DEBIT' THEN v_original_item.id ELSE v_reverse_item_id END,
    CASE WHEN v_original_item.direction='CREDIT' THEN v_original_item.id ELSE v_reverse_item_id END,
    v_original_item.original_amount,'ACTION_REVERSAL_SETTLEMENT',v_settlement_id,
    p_effective_date,v_actor);
  IF v_original.operation_kind IN('CONVERT_CREDIT_BALANCE','APPLY_CUSTOMER_BALANCE') THEN
    SELECT * INTO STRICT v_ledger FROM public.customer_balance_ledger_entries entry
    WHERE entry.company_id=v_company AND entry.source_id=v_original.id FOR SHARE;
    SELECT * INTO STRICT v_customer FROM public.customers customer
    WHERE customer.company_id=v_company AND customer.id=v_original_item.customer_id FOR UPDATE;
    v_before:=v_customer.current_balance;
    IF v_original.operation_kind='CONVERT_CREDIT_BALANCE' THEN
      IF v_before<v_amount THEN RAISE EXCEPTION 'CUSTOMER_BALANCE_REVERSAL_INSUFFICIENT'; END IF;
      v_after:=v_before-v_amount;
    ELSE v_after:=v_before+v_amount; END IF;
    v_entry_no:=nextval('private.customer_balance_request_no_seq');
    INSERT INTO public.customer_balance_ledger_entries(company_id,customer_id,store_id,entry_no,
      direction,amount,source_type,source_id,source_reference,reason,balance_before,balance_after,
      transaction_category_id,liability_account_id,source_account_id,source_account_function,
      financial_event_id,idempotency_key,payload_hash,created_by)
    VALUES(v_company,v_ledger.customer_id,v_ledger.store_id,v_entry_no,
      CASE v_ledger.direction WHEN 'CREDIT' THEN 'DEBIT' ELSE 'CREDIT' END,v_amount,
      'OPEN_CREDIT_ACTION_REVERSAL',v_reverse_operation_id,v_ledger.source_reference,
      btrim(p_reason),v_before,v_after,v_ledger.transaction_category_id,
      v_ledger.liability_account_id,v_ledger.source_account_id,v_ledger.source_account_function,
      v_event.id,p_operation_id,v_hash,v_actor) RETURNING id INTO v_new_ledger_id;
    UPDATE public.customers SET current_balance=v_after,updated_by=v_actor
    WHERE company_id=v_company AND id=v_ledger.customer_id;
    INSERT INTO public.customer_balance_audit(company_id,customer_id,action,actor_id,
      before_state,after_state)
    VALUES(v_company,v_ledger.customer_id,'OPEN_CREDIT_ACTION_REVERSAL',v_actor,
      jsonb_build_object('balance',v_before,'originalOperationId',v_original.id),
      jsonb_build_object('balance',v_after,'ledgerEntryId',v_new_ledger_id,
        'operationId',v_reverse_operation_id));
  END IF;
  RETURN v_response||jsonb_build_object('customerBalanceLedgerEntryId',v_new_ledger_id);
END
$$;

REVOKE ALL ON FUNCTION private.ar5_item_allocated(uuid,uuid,date),
  private.ar5_operation_retry(uuid,uuid,text,text),private.ar5_assert_backoffice_company(uuid)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.ar5_item_allocated(uuid,uuid,date),
  private.ar5_operation_retry(uuid,uuid,text,text),private.ar5_assert_backoffice_company(uuid)
  TO service_role;
REVOKE ALL ON FUNCTION public.apply_backoffice_ar_open_credit(uuid,jsonb,date,numeric,uuid),
  public.refund_backoffice_ar_open_credit(uuid,numeric,date,uuid,text,text,text,numeric,uuid),
  public.convert_backoffice_ar_open_credit_to_customer_balance(uuid,numeric,date,text,numeric,uuid),
  public.apply_customer_balance_to_backoffice_invoice(uuid,numeric,date,text,numeric,numeric,uuid),
  public.reverse_backoffice_ar_open_credit_action(uuid,date,text,uuid)
  FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.apply_backoffice_ar_open_credit(uuid,jsonb,date,numeric,uuid),
  public.refund_backoffice_ar_open_credit(uuid,numeric,date,uuid,text,text,text,numeric,uuid),
  public.convert_backoffice_ar_open_credit_to_customer_balance(uuid,numeric,date,text,numeric,uuid),
  public.apply_customer_balance_to_backoffice_invoice(uuid,numeric,date,text,numeric,numeric,uuid),
  public.reverse_backoffice_ar_open_credit_action(uuid,date,text,uuid)
  TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20261106100000','backoffice_ar_open_credit_actions',
  'Backoffice AR open-credit apply, Cash/Bank refund, Customer Balance conversion and Posted Invoice settlement with append-only reversal; Retail/POS, legacy Refund Liability, Stock/FIFO and historical Journals preserved');

COMMIT;

