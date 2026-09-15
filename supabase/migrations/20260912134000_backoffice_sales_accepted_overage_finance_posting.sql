-- Step 5/6.1: controlled Finance posting for accepted-overage COGS.
-- Physical resolution only creates HOLD; the existing Finance queue posts it.
BEGIN;

DO $guard$
DECLARE v_post text;v_supported text;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260912133000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: C4 client activation required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260912134000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260912134000';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
    WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
  IF to_regprocedure('private.post_backoffice_accepted_overage_financial_event_core(uuid,uuid,bigint,uuid)') IS NOT NULL
    OR to_regprocedure('private.post_financial_event_core_pre_backoffice_accepted_overage(uuid,uuid,bigint,uuid)') IS NOT NULL
    OR to_regprocedure('private.f4b_financial_event_supported_pre_backoffice_accepted_overage(public.financial_events)') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: accepted-overage Finance wrapper collision';
  END IF;
  SELECT pg_get_functiondef('private.post_financial_event_core(uuid,uuid,bigint,uuid)'::regprocedure)
    INTO STRICT v_post;
  IF position('post_backoffice_sales_invoice_financial_event_core' in v_post)=0
    OR position('post_financial_event_core_pre_backoffice_invoice' in v_post)=0 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical Finance post chain drift';
  END IF;
  SELECT pg_get_functiondef('private.f4b_financial_event_supported(public.financial_events)'::regprocedure)
    INTO STRICT v_supported;
  IF position('BACKOFFICE_SALES_INVOICE' in v_supported)=0
    OR position('f4b_financial_event_supported_pre_backoffice_invoice' in v_supported)=0 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical Finance support chain drift';
  END IF;
  IF EXISTS(
    SELECT 1 FROM public.financial_events event
    LEFT JOIN public.backoffice_sales_discrepancy_stock_effects effect
      ON effect.company_id=event.company_id AND effect.id=event.source_id
      AND effect.financial_event_id=event.id
    WHERE event.system_event_key='BACKOFFICE_ACCEPTED_OVERAGE_COGS'
      AND (event.source_table<>'backoffice_sales_discrepancy_stock_effects'
        OR event.event_type::text<>'SALE_POSTED' OR effect.id IS NULL
        OR effect.effect_type<>'OVERAGE_ACCEPTED_SALE'
        OR jsonb_typeof(event.amounts) IS DISTINCT FROM 'object'
        OR jsonb_typeof(event.amounts->'fifoCostTotal') IS DISTINCT FROM 'number'
        OR jsonb_typeof(event.amounts->'acceptedDate') IS DISTINCT FROM 'string'
        OR event.transaction_category_id IS NULL
        OR event.transaction_rule_version IS NULL
        OR NOT EXISTS(SELECT 1 FROM public.posting_rule_sets rule_set
          WHERE rule_set.company_id=event.company_id
            AND rule_set.transaction_category_id=event.transaction_category_id
            AND rule_set.system_key=event.system_event_key
            AND rule_set.rule_set_version=event.transaction_rule_version
            AND rule_set.status='APPROVED'
            AND rule_set.effective_from<=event.event_date
            AND (rule_set.effective_to IS NULL OR rule_set.effective_to>event.event_date)))
  ) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: accepted-overage Event source drift';
  END IF;
  IF EXISTS(
    SELECT 1 FROM public.financial_events event
    JOIN public.backoffice_sales_discrepancy_stock_effects effect
      ON effect.company_id=event.company_id AND effect.id=event.source_id
      AND effect.financial_event_id=event.id
    WHERE event.system_event_key='BACKOFFICE_ACCEPTED_OVERAGE_COGS'
      AND jsonb_typeof(event.amounts->'fifoCostTotal')='number'
      AND (round((event.amounts->>'fifoCostTotal')::numeric,4)<>round(effect.total_cost,4)
        OR round(effect.quantity_base,6)<>(SELECT round(COALESCE(sum(allocation.quantity_base),0),6)
          FROM public.backoffice_sales_discrepancy_fifo_allocations allocation
          WHERE allocation.company_id=effect.company_id AND allocation.stock_effect_id=effect.id)
        OR round(effect.total_cost,4)<>(SELECT round(COALESCE(sum(allocation.total_cost),0),4)
          FROM public.backoffice_sales_discrepancy_fifo_allocations allocation
          WHERE allocation.company_id=effect.company_id AND allocation.stock_effect_id=effect.id)
        OR NOT EXISTS(SELECT 1 FROM public.stock_movements movement
          WHERE movement.company_id=effect.company_id
            AND movement.id=effect.source_stock_movement_id
            AND movement.reference_table='backoffice_sales_discrepancy_stock_effects'
            AND movement.reference_id=effect.id AND movement.product_id=effect.product_id
            AND movement.warehouse_id=effect.source_warehouse_id
            AND movement.movement_status='POSTED'
            AND round(movement.qty_change,6)=-round(effect.quantity_base,6)))
  ) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: accepted-overage cost lineage drift';
  END IF;
END
$guard$;

CREATE FUNCTION private.post_backoffice_accepted_overage_financial_event_core(
  p_company_id uuid,p_event_id uuid,p_expected_event_version bigint,p_actor_id uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
  v_event public.financial_events%rowtype;
  v_effect public.backoffice_sales_discrepancy_stock_effects%rowtype;
  v_case public.backoffice_sales_delivery_discrepancies%rowtype;
  v_line public.backoffice_sales_delivery_discrepancy_lines%rowtype;
  v_order public.backoffice_sales_orders%rowtype;
  v_period public.accounting_periods%rowtype;
  v_journal public.finance_journals%rowtype;
  v_account uuid;v_rule_count bigint;v_rule_version bigint;
  v_alloc_qty numeric(24,6);v_alloc_cost numeric(24,4);v_cost numeric(24,4);
  v_accepted_date date;v_accounting_date date;v_journal_type text:='AUTOMATIC';
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
    AND v_event.error_message='NO_FINANCIAL_EFFECT' THEN
    RETURN jsonb_build_object('financialEventId',v_event.id,'journalId',NULL,
      'journalNo',NULL,'status','CANCELED','reason','NO_FINANCIAL_EFFECT',
      'idempotentReplay',true);
  END IF;
  IF v_event.status::text<>'HOLD' OR v_event.event_type::text<>'SALE_POSTED'
    OR v_event.system_event_key<>'BACKOFFICE_ACCEPTED_OVERAGE_COGS'
    OR v_event.source_table<>'backoffice_sales_discrepancy_stock_effects' THEN
    RAISE EXCEPTION 'UNSUPPORTED_FINANCIAL_EVENT_CONTRACT';
  END IF;

  SELECT effect.* INTO v_effect
  FROM public.backoffice_sales_discrepancy_stock_effects effect
  WHERE effect.company_id=p_company_id AND effect.id=v_event.source_id
    AND effect.financial_event_id=v_event.id
    AND effect.effect_type='OVERAGE_ACCEPTED_SALE' FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'FINANCIAL_EVENT_SOURCE_NOT_FOUND'; END IF;
  SELECT discrepancy.* INTO STRICT v_case
  FROM public.backoffice_sales_delivery_discrepancies discrepancy
  WHERE discrepancy.company_id=p_company_id AND discrepancy.id=v_effect.discrepancy_id
  FOR SHARE;
  SELECT line.* INTO STRICT v_line
  FROM public.backoffice_sales_delivery_discrepancy_lines line
  WHERE line.company_id=p_company_id AND line.id=v_effect.discrepancy_line_id
    AND line.discrepancy_id=v_effect.discrepancy_id FOR SHARE;
  SELECT document.* INTO STRICT v_order FROM public.backoffice_sales_orders document
  WHERE document.company_id=p_company_id AND document.id=v_case.sales_order_id FOR SHARE;

  IF jsonb_typeof(v_event.amounts) IS DISTINCT FROM 'object'
    OR NOT (v_event.amounts ?& ARRAY['fifoCostTotal','acceptedDate','salesOrderId',
      'deliveryOrderId','discrepancyId','discrepancyLineId'])
    OR jsonb_typeof(v_event.amounts->'fifoCostTotal') IS DISTINCT FROM 'number'
    OR jsonb_typeof(v_event.amounts->'acceptedDate') IS DISTINCT FROM 'string'
    OR v_event.amounts->>'salesOrderId' IS DISTINCT FROM v_case.sales_order_id::text
    OR v_event.amounts->>'deliveryOrderId' IS DISTINCT FROM v_case.delivery_order_id::text
    OR v_event.amounts->>'discrepancyId' IS DISTINCT FROM v_case.id::text
    OR v_event.amounts->>'discrepancyLineId' IS DISTINCT FROM v_line.id::text
    OR v_line.requested_resolution<>'ACCEPT_OVERAGE'
    OR v_line.commercial_approval_status<>'APPROVED'
    OR v_line.warehouse_resolution_status<>'RESOLVED' THEN
    RAISE EXCEPTION 'FINANCIAL_EVENT_SOURCE_IDENTITY_MISMATCH';
  END IF;
  BEGIN
    v_cost:=round((v_event.amounts->>'fifoCostTotal')::numeric,4);
    v_accepted_date:=(v_event.amounts->>'acceptedDate')::date;
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'FINANCIAL_EVENT_AMOUNT_SOURCE_MISMATCH';
  END;
  SELECT round(COALESCE(sum(allocation.quantity_base),0),6),
    round(COALESCE(sum(allocation.total_cost),0),4)
  INTO v_alloc_qty,v_alloc_cost
  FROM public.backoffice_sales_discrepancy_fifo_allocations allocation
  WHERE allocation.company_id=p_company_id AND allocation.stock_effect_id=v_effect.id;
  IF v_cost<>round(v_effect.total_cost,4) OR v_cost<>v_alloc_cost
    OR round(v_effect.quantity_base,6)<>v_alloc_qty
    OR NOT EXISTS(SELECT 1 FROM public.stock_movements movement
      WHERE movement.company_id=p_company_id
        AND movement.id=v_effect.source_stock_movement_id
        AND movement.reference_table='backoffice_sales_discrepancy_stock_effects'
        AND movement.reference_id=v_effect.id AND movement.product_id=v_effect.product_id
        AND movement.warehouse_id=v_effect.source_warehouse_id
        AND movement.movement_status='POSTED'
        AND round(movement.qty_change,6)=-round(v_effect.quantity_base,6)) THEN
    RAISE EXCEPTION 'FINANCIAL_EVENT_AMOUNT_SOURCE_MISMATCH';
  END IF;

  IF v_cost=0 THEN
    UPDATE public.financial_events SET status='CANCELED'::public.event_status,
      processed_at=v_now,error_message='NO_FINANCIAL_EFFECT'
    WHERE company_id=p_company_id AND id=v_event.id;
    RETURN jsonb_build_object('financialEventId',v_event.id,'journalId',NULL,
      'journalNo',NULL,'status','CANCELED','reason','NO_FINANCIAL_EFFECT',
      'idempotentReplay',false);
  END IF;
  IF v_cost<0 THEN RAISE EXCEPTION 'FINANCIAL_EVENT_AMOUNT_SOURCE_MISMATCH'; END IF;

  SELECT period.* INTO v_period FROM public.accounting_periods period
  WHERE period.company_id=p_company_id
    AND v_accepted_date BETWEEN period.start_date AND period.end_date
    AND period.status IN('OPEN','REOPENED')
  ORDER BY period.start_date LIMIT 1 FOR SHARE;
  IF NOT FOUND THEN
    SELECT period.* INTO v_period FROM public.accounting_periods period
    WHERE period.company_id=p_company_id AND period.start_date>v_accepted_date
      AND period.status IN('OPEN','REOPENED')
    ORDER BY period.start_date LIMIT 1 FOR SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION 'POSTABLE_ACCOUNTING_PERIOD_NOT_FOUND'; END IF;
    v_journal_type:='PRIOR_PERIOD_ADJUSTMENT';v_accounting_date:=v_period.start_date;
  ELSE
    v_accounting_date:=v_accepted_date;
  END IF;
  SELECT count(*),max(rule_set.rule_set_version) INTO v_rule_count,v_rule_version
  FROM public.posting_rule_sets rule_set
  WHERE rule_set.company_id=p_company_id
    AND rule_set.transaction_category_id=v_event.transaction_category_id
    AND rule_set.system_key='BACKOFFICE_ACCEPTED_OVERAGE_COGS'
    AND rule_set.status='APPROVED' AND rule_set.effective_from<=v_event.event_date
    AND (rule_set.effective_to IS NULL OR rule_set.effective_to>v_event.event_date);
  IF v_rule_count<>1 OR v_rule_version IS NULL
    OR v_event.transaction_rule_version IS DISTINCT FROM v_rule_version THEN
    RAISE EXCEPTION 'POSTING_RULE_SET_MISSING_OR_AMBIGUOUS';
  END IF;

  INSERT INTO public.finance_journals(company_id,journal_no,journal_type,
    accounting_period_id,accounting_date,original_event_date,source_type,source_id,
    source_version,financial_event_id,idempotency_key,system_event_key,
    transaction_category_id,transaction_rule_version,store_id,warehouse_id,
    currency_code,description,status,created_by)
  VALUES(p_company_id,'BAO-'||replace(v_event.id::text,'-',''),v_journal_type,
    v_period.id,v_accounting_date,v_accepted_date,v_event.source_table,v_effect.id,
    1,v_event.id,'BACKOFFICE_ACCEPTED_OVERAGE_EVENT|'||p_company_id||'|'||v_event.id||'|'||v_event.event_version,
    v_event.system_event_key,v_event.transaction_category_id,v_rule_version,
    v_order.store_id,v_effect.source_warehouse_id,v_order.currency_code,
    'HPP kelebihan barang diterima · '||v_case.discrepancy_no,'DRAFT',p_actor_id)
  RETURNING * INTO v_journal;
  v_account:=private.resolve_financial_event_account(v_event,'COGS');
  INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,account_id,
    debit,credit,store_id,warehouse_id,customer_id,description)
  VALUES(p_company_id,v_journal.id,10,v_account,v_cost,0,v_order.store_id,
    v_effect.source_warehouse_id,v_order.customer_id,'COGS - Kelebihan barang diterima');
  v_account:=private.resolve_financial_event_account(v_event,'INVENTORY_ASSET');
  INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,account_id,
    debit,credit,store_id,warehouse_id,customer_id,description)
  VALUES(p_company_id,v_journal.id,20,v_account,0,v_cost,v_order.store_id,
    v_effect.source_warehouse_id,v_order.customer_id,
    'INVENTORY_ASSET - Kelebihan barang diterima');
  UPDATE public.finance_journals SET status='POSTED',posted_by=p_actor_id,posted_at=v_now
  WHERE company_id=p_company_id AND id=v_journal.id RETURNING * INTO v_journal;
  IF round(v_journal.total_debit,4)<>v_cost OR round(v_journal.total_credit,4)<>v_cost THEN
    RAISE EXCEPTION 'JOURNAL_UNBALANCED';
  END IF;
  UPDATE public.financial_events SET status='POSTED'::public.event_status,
    processed_at=v_now,error_message=NULL,transaction_rule_version=v_rule_version
  WHERE company_id=p_company_id AND id=v_event.id;
  RETURN jsonb_build_object('financialEventId',v_event.id,'journalId',v_journal.id,
    'journalNo',v_journal.journal_no,'status','POSTED','journalType',v_journal.journal_type,
    'accountingDate',v_journal.accounting_date,'originalEventDate',v_journal.original_event_date,
    'totalDebit',v_journal.total_debit,'totalCredit',v_journal.total_credit,
    'idempotentReplay',false);
END
$$;

ALTER FUNCTION private.post_financial_event_core(uuid,uuid,bigint,uuid)
  RENAME TO post_financial_event_core_pre_backoffice_accepted_overage;
CREATE FUNCTION private.post_financial_event_core(
  p_company_id uuid,p_event_id uuid,p_expected_event_version bigint,p_actor_id uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_key text;v_source text;
BEGIN
  SELECT event.system_event_key,event.source_table INTO v_key,v_source
  FROM public.financial_events event
  WHERE event.company_id=p_company_id AND event.id=p_event_id;
  IF v_key='BACKOFFICE_ACCEPTED_OVERAGE_COGS'
    AND v_source='backoffice_sales_discrepancy_stock_effects' THEN
    RETURN private.post_backoffice_accepted_overage_financial_event_core(
      p_company_id,p_event_id,p_expected_event_version,p_actor_id);
  END IF;
  RETURN private.post_financial_event_core_pre_backoffice_accepted_overage(
    p_company_id,p_event_id,p_expected_event_version,p_actor_id);
END
$$;

ALTER FUNCTION private.f4b_financial_event_supported(public.financial_events)
  RENAME TO f4b_financial_event_supported_pre_backoffice_accepted_overage;
CREATE FUNCTION private.f4b_financial_event_supported(
  p_event public.financial_events
) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
  SELECT CASE WHEN p_event.status::text='HOLD'
    AND p_event.system_event_key='BACKOFFICE_ACCEPTED_OVERAGE_COGS'
    AND p_event.source_table='backoffice_sales_discrepancy_stock_effects' THEN true
    ELSE private.f4b_financial_event_supported_pre_backoffice_accepted_overage(p_event) END
$$;

REVOKE ALL ON FUNCTION
  private.post_backoffice_accepted_overage_financial_event_core(uuid,uuid,bigint,uuid),
  private.post_financial_event_core_pre_backoffice_accepted_overage(uuid,uuid,bigint,uuid),
  private.post_financial_event_core(uuid,uuid,bigint,uuid),
  private.f4b_financial_event_supported_pre_backoffice_accepted_overage(public.financial_events),
  private.f4b_financial_event_supported(public.financial_events)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.post_backoffice_accepted_overage_financial_event_core(uuid,uuid,bigint,uuid),
  private.post_financial_event_core_pre_backoffice_accepted_overage(uuid,uuid,bigint,uuid),
  private.post_financial_event_core(uuid,uuid,bigint,uuid),
  private.f4b_financial_event_supported_pre_backoffice_accepted_overage(public.financial_events),
  private.f4b_financial_event_supported(public.financial_events)
TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260912134000','backoffice_sales_accepted_overage_finance_posting',
  'Step 5/6.1 routes accepted-overage COGS HOLD through the canonical Finance queue to balanced Dr COGS / Cr Transit Inventory without synchronous Warehouse Journal');
NOTIFY pgrst,'reload schema';
COMMIT;
