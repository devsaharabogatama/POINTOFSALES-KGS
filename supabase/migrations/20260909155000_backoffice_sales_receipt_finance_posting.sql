-- Canonical Finance posting for Backoffice Customer receipt FIFO cost.
-- Receipt/Stock/FIFO/Qty To Invoice are not changed by this migration.
-- Revenue, Tax, AR, Payment and Invoice remain outside this gate.

BEGIN;

DO $guard$
DECLARE v_post text;v_supported text;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260909154000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Customer receipt runtime required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260909155000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260909155000';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF to_regprocedure('private.post_financial_event_core(uuid,uuid,bigint,uuid)') IS NULL
    OR to_regprocedure('private.f4b_financial_event_supported(public.financial_events)') IS NULL
    OR to_regprocedure('private.resolve_financial_event_account(public.financial_events,text)') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical Finance dependency missing';
  END IF;
  IF to_regprocedure('private.post_financial_event_core_pre_backoffice_receipt(uuid,uuid,bigint,uuid)') IS NOT NULL
    OR to_regprocedure('private.f4b_financial_event_supported_pre_backoffice_receipt(public.financial_events)') IS NOT NULL
    OR to_regprocedure('private.post_backoffice_receipt_financial_event_core(uuid,uuid,bigint,uuid)') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Finance wrapper identity collision';
  END IF;
  SELECT pg_get_functiondef('private.post_financial_event_core(uuid,uuid,bigint,uuid)'::regprocedure)
    INTO v_post;
  IF position('post_odr_payment_financial_event_core' in v_post)=0
    OR position('post_financial_event_core_pre_odr5d' in v_post)=0
    OR position('PREDISPATCH_ADVANCE_EVENT_NOT_POSTED' in v_post)=0 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance dispatcher drift';
  END IF;
  SELECT pg_get_functiondef(
    'private.f4b_financial_event_supported(public.financial_events)'::regprocedure)
    INTO v_supported;
  IF position('SALE_PAYMENT_VERIFIED' in v_supported)=0
    OR position('sales_payment_verification_requests' in v_supported)=0 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: supported Event predicate drift';
  END IF;
END
$guard$;

CREATE FUNCTION private.post_backoffice_receipt_financial_event_core(
  p_company_id uuid,p_event_id uuid,p_expected_event_version bigint,p_actor_id uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
  v_event public.financial_events%rowtype;
  v_receipt public.backoffice_sales_delivery_receipts%rowtype;
  v_order public.backoffice_sales_orders%rowtype;
  v_period public.accounting_periods%rowtype;
  v_journal public.finance_journals%rowtype;
  v_account uuid;v_rule_version bigint;v_rule_count bigint;
  v_accounting_date date;v_journal_type text:='AUTOMATIC';
  v_cost numeric(24,4);v_line_cost numeric(24,4);v_allocation_cost numeric(24,4);
  v_now timestamptz:=clock_timestamp();
BEGIN
  IF p_actor_id IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  SELECT event.* INTO v_event FROM public.financial_events event
  WHERE event.company_id=p_company_id AND event.id=p_event_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'FINANCIAL_EVENT_NOT_FOUND'; END IF;
  IF p_expected_event_version IS DISTINCT FROM v_event.event_version THEN
    RAISE EXCEPTION 'EVENT_VERSION_CONFLICT';
  END IF;
  IF v_event.status::text='POSTED' THEN
    SELECT journal.* INTO STRICT v_journal FROM public.finance_journals journal
    WHERE journal.company_id=p_company_id AND journal.financial_event_id=v_event.id
      AND journal.status='POSTED';
    RETURN jsonb_build_object('financialEventId',v_event.id,'journalId',v_journal.id,
      'journalNo',v_journal.journal_no,'status','POSTED','idempotentReplay',true);
  END IF;
  IF v_event.status::text='CANCELED'
    AND v_event.system_event_key='BACKOFFICE_CUSTOMER_RECEIPT'
    AND v_event.error_message='NO_FINANCIAL_EFFECT' THEN
    RETURN jsonb_build_object('financialEventId',v_event.id,'journalId',NULL,
      'journalNo',NULL,'status','CANCELED','reason','NO_FINANCIAL_EFFECT',
      'idempotentReplay',true);
  END IF;
  IF v_event.status::text<>'HOLD'
    OR v_event.system_event_key<>'BACKOFFICE_CUSTOMER_RECEIPT'
    OR v_event.event_type::text<>'SALE_POSTED'
    OR v_event.source_table<>'backoffice_sales_delivery_receipts' THEN
    RAISE EXCEPTION 'UNSUPPORTED_FINANCIAL_EVENT_CONTRACT';
  END IF;

  SELECT receipt.* INTO v_receipt
  FROM public.backoffice_sales_delivery_receipts receipt
  WHERE receipt.company_id=p_company_id AND receipt.id=v_event.source_id
    AND receipt.financial_event_id=v_event.id FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'FINANCIAL_EVENT_SOURCE_NOT_FOUND'; END IF;
  SELECT document.* INTO STRICT v_order FROM public.backoffice_sales_orders document
  WHERE document.company_id=p_company_id AND document.id=v_receipt.sales_order_id
  FOR SHARE;
  SELECT round(COALESCE(sum(line.fifo_cost_total),0),4)
    INTO v_line_cost FROM public.backoffice_sales_delivery_receipt_lines line
  WHERE line.company_id=p_company_id AND line.receipt_id=v_receipt.id;
  SELECT round(COALESCE(sum(allocation.total_cost),0),4)
    INTO v_allocation_cost FROM public.backoffice_sales_receipt_fifo_allocations allocation
  WHERE allocation.company_id=p_company_id AND allocation.receipt_id=v_receipt.id;
  IF jsonb_typeof(v_event.amounts->'fifoCostTotal') IS DISTINCT FROM 'number'
    OR jsonb_typeof(v_event.amounts->'acceptedDate') IS DISTINCT FROM 'string'
    OR (v_event.amounts->>'acceptedDate')::date IS DISTINCT FROM v_receipt.accepted_date
    OR v_event.amounts->>'deliveryOrderId' IS DISTINCT FROM v_receipt.delivery_order_id::text
    OR v_event.amounts->>'salesOrderId' IS DISTINCT FROM v_receipt.sales_order_id::text THEN
    RAISE EXCEPTION 'FINANCIAL_EVENT_SOURCE_IDENTITY_MISMATCH';
  END IF;
  v_cost:=round((v_event.amounts->>'fifoCostTotal')::numeric,4);
  IF v_cost<>round(v_receipt.total_fifo_cost,4)
    OR v_cost<>v_line_cost OR v_cost<>v_allocation_cost THEN
    RAISE EXCEPTION 'FINANCIAL_EVENT_AMOUNT_SOURCE_MISMATCH';
  END IF;

  IF v_cost=0 THEN
    UPDATE public.financial_events SET status='CANCELED'::public.event_status,
      processed_at=v_now,error_message='NO_FINANCIAL_EFFECT',
      transaction_rule_version=20260909155000
    WHERE company_id=p_company_id AND id=v_event.id;
    RETURN jsonb_build_object('financialEventId',v_event.id,'journalId',NULL,
      'journalNo',NULL,'status','CANCELED','reason','NO_FINANCIAL_EFFECT',
      'idempotentReplay',false);
  END IF;
  IF v_cost<0 THEN RAISE EXCEPTION 'FINANCIAL_EVENT_AMOUNT_SOURCE_MISMATCH'; END IF;

  SELECT period.* INTO v_period FROM public.accounting_periods period
  WHERE period.company_id=p_company_id
    AND v_receipt.accepted_date BETWEEN period.start_date AND period.end_date
    AND period.status IN('OPEN','REOPENED')
  ORDER BY period.start_date LIMIT 1 FOR SHARE;
  IF NOT FOUND THEN
    SELECT period.* INTO v_period FROM public.accounting_periods period
    WHERE period.company_id=p_company_id AND period.start_date>v_receipt.accepted_date
      AND period.status IN('OPEN','REOPENED')
    ORDER BY period.start_date LIMIT 1 FOR SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION 'POSTABLE_ACCOUNTING_PERIOD_NOT_FOUND'; END IF;
    v_journal_type:='PRIOR_PERIOD_ADJUSTMENT';v_accounting_date:=v_period.start_date;
  ELSE
    v_accounting_date:=v_receipt.accepted_date;
  END IF;

  SELECT count(*),max(rule_set.rule_set_version)
  INTO v_rule_count,v_rule_version FROM public.posting_rule_sets rule_set
  WHERE rule_set.company_id=p_company_id
    AND rule_set.transaction_category_id=v_event.transaction_category_id
    AND rule_set.system_key='BACKOFFICE_CUSTOMER_RECEIPT'
    AND rule_set.status='APPROVED' AND rule_set.effective_from<=v_event.event_date
    AND (rule_set.effective_to IS NULL OR rule_set.effective_to>v_event.event_date);
  IF v_rule_count<>1 OR v_rule_version IS NULL THEN
    RAISE EXCEPTION 'POSTING_RULE_SET_MISSING_OR_AMBIGUOUS';
  END IF;

  INSERT INTO public.finance_journals(company_id,journal_no,journal_type,
    accounting_period_id,accounting_date,original_event_date,source_type,source_id,
    source_version,financial_event_id,idempotency_key,system_event_key,
    transaction_category_id,transaction_rule_version,store_id,warehouse_id,
    description,status,created_by)
  VALUES(p_company_id,'BCR-'||replace(v_event.id::text,'-',''),v_journal_type,
    v_period.id,v_accounting_date,v_receipt.accepted_date,v_event.source_table,
    v_receipt.id,1,v_event.id,
    'BACKOFFICE_RECEIPT_EVENT|'||p_company_id||'|'||v_event.id||'|'||v_event.event_version,
    v_event.system_event_key,v_event.transaction_category_id,v_rule_version,
    v_order.store_id,v_receipt.transit_warehouse_id,
    'Backoffice Customer receipt: '||v_receipt.receipt_no,'DRAFT',p_actor_id)
  RETURNING * INTO v_journal;

  v_account:=private.resolve_financial_event_account(v_event,'COGS');
  INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,account_id,
    debit,credit,store_id,warehouse_id,customer_id,description)
  VALUES(p_company_id,v_journal.id,10,v_account,v_cost,0,v_order.store_id,
    v_receipt.transit_warehouse_id,v_order.customer_id,'COGS');
  v_account:=private.resolve_financial_event_account(v_event,'INVENTORY_ASSET');
  INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,account_id,
    debit,credit,store_id,warehouse_id,customer_id,description)
  VALUES(p_company_id,v_journal.id,20,v_account,0,v_cost,v_order.store_id,
    v_receipt.transit_warehouse_id,v_order.customer_id,'INVENTORY_ASSET');

  UPDATE public.finance_journals SET status='POSTED',posted_by=p_actor_id,
    posted_at=v_now WHERE company_id=p_company_id AND id=v_journal.id
  RETURNING * INTO v_journal;
  IF round(v_journal.total_debit,4)<>v_cost
    OR round(v_journal.total_credit,4)<>v_cost THEN
    RAISE EXCEPTION 'JOURNAL_UNBALANCED';
  END IF;
  UPDATE public.financial_events SET status='POSTED'::public.event_status,
    processed_at=v_now,error_message=NULL,transaction_rule_version=v_rule_version
  WHERE company_id=p_company_id AND id=v_event.id;
  RETURN jsonb_build_object('financialEventId',v_event.id,'journalId',v_journal.id,
    'journalNo',v_journal.journal_no,'status','POSTED',
    'journalType',v_journal.journal_type,'accountingDate',v_journal.accounting_date,
    'originalEventDate',v_journal.original_event_date,
    'totalDebit',v_journal.total_debit,'totalCredit',v_journal.total_credit,
    'idempotentReplay',false);
END
$$;

ALTER FUNCTION private.post_financial_event_core(uuid,uuid,bigint,uuid)
  RENAME TO post_financial_event_core_pre_backoffice_receipt;
CREATE FUNCTION private.post_financial_event_core(
  p_company_id uuid,p_event_id uuid,p_expected_event_version bigint,p_actor_id uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_key text;v_source text;
BEGIN
  SELECT event.system_event_key,event.source_table INTO v_key,v_source
  FROM public.financial_events event
  WHERE event.company_id=p_company_id AND event.id=p_event_id;
  IF v_key='BACKOFFICE_CUSTOMER_RECEIPT'
    AND v_source='backoffice_sales_delivery_receipts' THEN
    RETURN private.post_backoffice_receipt_financial_event_core(
      p_company_id,p_event_id,p_expected_event_version,p_actor_id);
  END IF;
  RETURN private.post_financial_event_core_pre_backoffice_receipt(
    p_company_id,p_event_id,p_expected_event_version,p_actor_id);
END
$$;

CREATE FUNCTION private.f4b_financial_event_supported_pre_backoffice_receipt(
  p_event public.financial_events
) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
  SELECT p_event.status::text='HOLD' AND CASE p_event.system_event_key
    WHEN 'STOCK_OPENING' THEN p_event.source_table='opening_stock_documents'
    WHEN 'SALE_POSTED' THEN p_event.source_table='sales_headers'
    WHEN 'SALES_RETURN' THEN p_event.source_table='sales_return_documents'
    WHEN 'GOODS_RECEIPT' THEN p_event.source_table='goods_receipt_documents'
    WHEN 'SUPPLIER_INVOICE' THEN p_event.source_table='supplier_invoice_documents'
    WHEN 'SUPPLIER_PAYMENT' THEN p_event.source_table='supplier_payment_documents'
    WHEN 'STOCK_GAIN' THEN p_event.source_table='stock_adjustment_documents'
    WHEN 'EXPENSE_DISBURSEMENT' THEN p_event.source_table='expense_disbursements'
    WHEN 'CASH_DEPOSIT' THEN p_event.source_table='cash_deposit_documents'
    WHEN 'CASH_VARIANCE' THEN p_event.source_table='deposit_variance_resolution_requests'
    WHEN 'SALE_PAYMENT' THEN p_event.source_table='customer_receipt_documents'
    WHEN 'CUSTOMER_BALANCE_RECEIPT' THEN p_event.source_table='customer_receipt_documents'
    WHEN 'SALE_DISPATCHED' THEN p_event.source_table='sales_dispatch_financial_effects'
    WHEN 'SALE_PAYMENT_VERIFIED' THEN
      p_event.source_table='sales_payment_verification_requests'
    ELSE false END
$$;
CREATE OR REPLACE FUNCTION private.f4b_financial_event_supported(
  p_event public.financial_events
) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
  SELECT CASE
    WHEN p_event.status::text='HOLD'
      AND p_event.system_event_key='BACKOFFICE_CUSTOMER_RECEIPT'
      AND p_event.source_table='backoffice_sales_delivery_receipts' THEN true
    ELSE private.f4b_financial_event_supported_pre_backoffice_receipt(p_event)
  END
$$;

REVOKE ALL ON FUNCTION
  private.post_backoffice_receipt_financial_event_core(uuid,uuid,bigint,uuid),
  private.post_financial_event_core_pre_backoffice_receipt(uuid,uuid,bigint,uuid),
  private.post_financial_event_core(uuid,uuid,bigint,uuid),
  private.f4b_financial_event_supported_pre_backoffice_receipt(public.financial_events),
  private.f4b_financial_event_supported(public.financial_events)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.post_backoffice_receipt_financial_event_core(uuid,uuid,bigint,uuid),
  private.post_financial_event_core_pre_backoffice_receipt(uuid,uuid,bigint,uuid),
  private.post_financial_event_core(uuid,uuid,bigint,uuid),
  private.f4b_financial_event_supported_pre_backoffice_receipt(public.financial_events),
  private.f4b_financial_event_supported(public.financial_events)
TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260909155000','backoffice_sales_receipt_finance_posting',
  'Canonical controlled/automatic Finance posting for Backoffice Customer receipt FIFO COGS: Dr COGS, Cr Transit Inventory; period-aware, source-reconciled and idempotent; no Invoice, Revenue, AR, Payment or Stock mutation');

NOTIFY pgrst,'reload schema';
COMMIT;
