-- Purchase Daily Replenishment Step 6/6A: Supplier assignment to AP/Finance bridge.
-- This migration creates no Supplier Bill and posts no existing Event.

BEGIN;

DO $guard$
DECLARE v_assign text;v_purchase_post text;v_dispatch text;v_preview text;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260914100000')
    OR NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260914112000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Purchase Step 5/6B required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260914130000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260914130000';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs run
      WHERE run.status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue exists';
  END IF;
  IF to_regprocedure('public.assign_purchase_daily_receipt_suppliers_before_step6a(uuid,bigint,uuid,jsonb)') IS NOT NULL
    OR to_regprocedure('private.purchase_step6a_previous_purchase_ap_event_core(uuid,uuid,bigint,uuid)') IS NOT NULL
    OR to_regprocedure('private.post_financial_event_core_before_purchase_step6a(uuid,uuid,bigint,uuid)') IS NOT NULL
    OR to_regprocedure('private.f4b_financial_event_supported_before_purchase_step6a(public.financial_events)') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Step 6A routine collision';
  END IF;
  SELECT pg_get_functiondef('public.assign_purchase_daily_receipt_suppliers(uuid,bigint,uuid,jsonb)'::regprocedure)
    INTO v_assign;
  SELECT pg_get_functiondef('private.post_purchase_ap_financial_event_core(uuid,uuid,bigint,uuid)'::regprocedure)
    INTO v_purchase_post;
  SELECT pg_get_functiondef('private.post_financial_event_core(uuid,uuid,bigint,uuid)'::regprocedure)
    INTO v_dispatch;
  SELECT pg_get_functiondef('public.preview_purchase_ap_posting_queue(integer)'::regprocedure)
    INTO v_preview;
  IF v_assign IS NULL OR position('HOLD_FOR_STEP_6_RECLASSIFICATION' in v_assign)=0
    OR position('goods_receipt_supplier_assignments' in v_assign)=0 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Supplier assignment call chain drift';
  END IF;
  IF v_purchase_post IS NULL
    OR position('nsc_previous_purchase_ap_financial_event_core' in v_purchase_post)=0 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Purchase/AP posting call chain drift';
  END IF;
  IF v_dispatch IS NULL
    OR position('post_financial_event_core_pre_backoffice_discrepancy_stock_loss' in v_dispatch)=0 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Finance dispatcher call chain drift';
  END IF;
  IF v_preview IS NULL OR position('HOLD_FOR_STEP_6_RECLASSIFICATION' in v_preview)=0
    OR position('GOODS_RECEIPT_SUPPLIER_ASSIGNMENT' in v_preview)>0 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Purchase/AP preview call chain drift';
  END IF;
  IF EXISTS(
    SELECT 1 FROM public.goods_receipt_supplier_assignments assignment
    JOIN public.goods_receipt_unassigned_clearings clearing
      ON clearing.company_id=assignment.company_id AND clearing.id=assignment.clearing_id
    JOIN public.goods_receipt_supplier_assignment_operations operation
      ON operation.company_id=assignment.company_id AND operation.id=assignment.operation_id
    LEFT JOIN public.financial_events event
      ON event.company_id=operation.company_id AND event.id=operation.financial_event_id
    WHERE assignment.receipt_id<>clearing.receipt_id
      OR assignment.receipt_line_id<>clearing.receipt_line_id
      OR assignment.assigned_amount<>clearing.amount
      OR operation.receipt_id<>assignment.receipt_id
      OR event.id IS NULL
      OR event.system_event_key<>'GOODS_RECEIPT_SUPPLIER_ASSIGNMENT'
      OR event.source_table<>'goods_receipt_supplier_assignment_operations'
      OR event.source_id<>operation.id
      OR event.status<>'HOLD'::public.event_status
      OR event.amounts->>'financePostingState'<>'HOLD_FOR_STEP_6_RECLASSIFICATION'
      OR NULLIF(event.amounts->>'unassignedSupplierClearingAccountId','')::uuid
        IS DISTINCT FROM clearing.clearing_account_id
  ) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Supplier assignment lineage invalid';
  END IF;
  IF EXISTS(
    SELECT 1 FROM public.goods_receipt_supplier_assignments assignment
    JOIN public.goods_receipt_ap_provisionals provisional
      ON provisional.company_id=assignment.company_id
     AND provisional.receipt_line_id=assignment.receipt_line_id
    WHERE provisional.receipt_id<>assignment.receipt_id
      OR provisional.supplier_id<>assignment.supplier_id
      OR provisional.amount<>assignment.assigned_amount
  ) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: AP provisional assignment conflict';
  END IF;
  IF EXISTS(
    SELECT 1 FROM public.goods_receipt_documents receipt
    LEFT JOIN public.financial_events event
      ON event.company_id=receipt.company_id AND event.id=receipt.financial_event_id
    WHERE receipt.status='POSTED' AND receipt.receipt_scope='DAILY_WAREHOUSE'
      AND receipt.supplier_assignment_status='SUPPLIER_PENDING'
      AND (event.id IS NULL OR event.system_event_key<>'GOODS_RECEIPT'
        OR event.event_type::text<>'PURCHASE_POSTED'
        OR event.source_table<>'goods_receipt_documents' OR event.source_id<>receipt.id
        OR event.status<>'HOLD'::public.event_status
        OR event.amounts->>'financePostingState'<>'HOLD_FOR_SUPPLIER_ASSIGNMENT'
        OR round(COALESCE((event.amounts->>'inventoryDebit')::numeric,-1),4)
          <>round(receipt.provisional_ap_total,4)
        OR round(COALESCE((event.amounts->>'unassignedSupplierClearingCredit')::numeric,-1),4)
          <>round(receipt.provisional_ap_total,4)
        OR EXISTS(SELECT 1 FROM public.goods_receipt_unassigned_clearings clearing
          WHERE clearing.company_id=receipt.company_id AND clearing.receipt_id=receipt.id
            AND clearing.clearing_account_id IS DISTINCT FROM
              NULLIF(event.amounts->>'unassignedSupplierClearingAccountId','')::uuid))
  ) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: pending-Supplier Receipt lineage invalid';
  END IF;
END
$guard$;

CREATE OR REPLACE FUNCTION private.trg_g5_guard_ap_provisional_lifecycle()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_receipt public.goods_receipt_documents%rowtype;
BEGIN
  SELECT * INTO v_receipt FROM public.goods_receipt_documents document
  WHERE document.company_id=COALESCE(NEW.company_id,OLD.company_id)
    AND document.id=COALESCE(NEW.receipt_id,OLD.receipt_id);
  IF NOT FOUND THEN RAISE EXCEPTION 'GOODS_RECEIPT_NOT_FOUND'; END IF;
  IF TG_OP='INSERT' THEN
    IF v_receipt.status='DRAFT' THEN RETURN NEW; END IF;
    IF v_receipt.status='POSTED' AND v_receipt.receipt_scope='DAILY_WAREHOUSE'
      AND v_receipt.supplier_assignment_status='SUPPLIER_PENDING'
      AND NEW.status='OPEN'
      AND EXISTS(
        SELECT 1 FROM public.goods_receipt_supplier_assignments assignment
        JOIN public.goods_receipt_supplier_assignment_operations operation
          ON operation.company_id=assignment.company_id
         AND operation.id=assignment.operation_id
         AND operation.receipt_id=assignment.receipt_id
        JOIN public.financial_events event
          ON event.company_id=operation.company_id
         AND event.id=operation.financial_event_id
         AND event.system_event_key='GOODS_RECEIPT_SUPPLIER_ASSIGNMENT'
         AND event.source_table='goods_receipt_supplier_assignment_operations'
         AND event.source_id=operation.id
        WHERE assignment.company_id=NEW.company_id
          AND assignment.receipt_id=NEW.receipt_id
          AND assignment.receipt_line_id=NEW.receipt_line_id
          AND assignment.supplier_id=NEW.supplier_id
          AND assignment.assigned_amount=NEW.amount
      ) THEN RETURN NEW; END IF;
    RAISE EXCEPTION 'FINAL_GOODS_RECEIPT_IMMUTABLE';
  END IF;
  IF TG_OP='DELETE' THEN
    IF v_receipt.status<>'DRAFT' THEN RAISE EXCEPTION 'FINAL_GOODS_RECEIPT_IMMUTABLE'; END IF;
    RETURN OLD;
  END IF;
  IF v_receipt.status<>'POSTED'
    OR NEW.company_id IS DISTINCT FROM OLD.company_id
    OR NEW.receipt_id IS DISTINCT FROM OLD.receipt_id
    OR NEW.receipt_line_id IS DISTINCT FROM OLD.receipt_line_id
    OR NEW.supplier_id IS DISTINCT FROM OLD.supplier_id
    OR NEW.amount IS DISTINCT FROM OLD.amount
    OR NEW.created_at IS DISTINCT FROM OLD.created_at
    OR NOT (NEW.status=OLD.status
      OR (OLD.status='OPEN' AND NEW.status IN('MATCHED','REVERSED'))) THEN
    RAISE EXCEPTION 'AP_PROVISIONAL_HISTORY_IMMUTABLE';
  END IF;
  RETURN NEW;
END
$$;

ALTER FUNCTION public.assign_purchase_daily_receipt_suppliers(uuid,bigint,uuid,jsonb)
  RENAME TO assign_purchase_daily_receipt_suppliers_before_step6a;

CREATE FUNCTION public.assign_purchase_daily_receipt_suppliers(
  p_receipt_id uuid,p_expected_master_version bigint,p_operation_id uuid,p_assignments jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_result jsonb;v_count integer;
BEGIN
  v_result:=public.assign_purchase_daily_receipt_suppliers_before_step6a(
    p_receipt_id,p_expected_master_version,p_operation_id,p_assignments);
  IF EXISTS(
    SELECT 1 FROM public.goods_receipt_supplier_assignments assignment
    JOIN public.goods_receipt_unassigned_clearings clearing
      ON clearing.company_id=assignment.company_id AND clearing.id=assignment.clearing_id
    JOIN public.goods_receipt_supplier_assignment_operations operation
      ON operation.company_id=assignment.company_id AND operation.id=assignment.operation_id
    JOIN public.financial_events event
      ON event.company_id=operation.company_id AND event.id=operation.financial_event_id
    WHERE assignment.company_id=v_company AND assignment.receipt_id=p_receipt_id
      AND assignment.operation_id=p_operation_id
      AND NULLIF(event.amounts->>'unassignedSupplierClearingAccountId','')::uuid
        IS DISTINCT FROM clearing.clearing_account_id
  ) THEN RAISE EXCEPTION 'SUPPLIER_ASSIGNMENT_CLEARING_ACCOUNT_MISMATCH'; END IF;
  INSERT INTO public.goods_receipt_ap_provisionals(company_id,receipt_id,
    receipt_line_id,supplier_id,amount)
  SELECT assignment.company_id,assignment.receipt_id,assignment.receipt_line_id,
    assignment.supplier_id,assignment.assigned_amount
  FROM public.goods_receipt_supplier_assignments assignment
  WHERE assignment.company_id=v_company AND assignment.receipt_id=p_receipt_id
    AND assignment.operation_id=p_operation_id
  ON CONFLICT(company_id,receipt_line_id) DO NOTHING;
  IF EXISTS(
    SELECT 1 FROM public.goods_receipt_supplier_assignments assignment
    LEFT JOIN public.goods_receipt_ap_provisionals provisional
      ON provisional.company_id=assignment.company_id
     AND provisional.receipt_line_id=assignment.receipt_line_id
    WHERE assignment.company_id=v_company AND assignment.receipt_id=p_receipt_id
      AND assignment.operation_id=p_operation_id
      AND (provisional.id IS NULL OR provisional.receipt_id<>assignment.receipt_id
        OR provisional.supplier_id<>assignment.supplier_id
        OR provisional.amount<>assignment.assigned_amount)
  ) THEN RAISE EXCEPTION 'AP_PROVISIONAL_ASSIGNMENT_MISMATCH'; END IF;
  SELECT count(*) INTO v_count FROM public.goods_receipt_ap_provisionals provisional
  JOIN public.goods_receipt_supplier_assignments assignment
    ON assignment.company_id=provisional.company_id
   AND assignment.receipt_line_id=provisional.receipt_line_id
  WHERE assignment.company_id=v_company AND assignment.receipt_id=p_receipt_id
    AND assignment.operation_id=p_operation_id;
  RETURN v_result||jsonb_build_object('apProvisionalCount',v_count);
END
$$;

-- Backfill only exact append-only assignments created before this bridge.
INSERT INTO public.goods_receipt_ap_provisionals(company_id,receipt_id,
  receipt_line_id,supplier_id,amount)
SELECT assignment.company_id,assignment.receipt_id,assignment.receipt_line_id,
  assignment.supplier_id,assignment.assigned_amount
FROM public.goods_receipt_supplier_assignments assignment
LEFT JOIN public.goods_receipt_ap_provisionals provisional
  ON provisional.company_id=assignment.company_id
 AND provisional.receipt_line_id=assignment.receipt_line_id
WHERE provisional.id IS NULL;

ALTER FUNCTION private.post_purchase_ap_financial_event_core(uuid,uuid,bigint,uuid)
  RENAME TO purchase_step6a_previous_purchase_ap_event_core;

CREATE FUNCTION private.post_purchase_ap_financial_event_core(
  p_company_id uuid,p_event_id uuid,p_expected_event_version bigint,p_actor_id uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_event public.financial_events%rowtype;v_operation record;v_receipt record;
  v_period public.accounting_periods%rowtype;v_journal public.finance_journals%rowtype;
  v_inventory_account uuid;v_clearing_account uuid;v_ap_account uuid;
  v_total numeric(20,4);v_source_total numeric(20,4);v_line_total numeric(20,4);
  v_batch_total numeric(20,4);v_clearing_total numeric(20,4);
  v_count integer;v_line integer:=0;v_row record;v_date date;v_type text:='AUTOMATIC';
  v_now timestamptz:=clock_timestamp();v_pending_receipt boolean;
BEGIN
  SELECT * INTO v_event FROM public.financial_events event
  WHERE event.company_id=p_company_id AND event.id=p_event_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'FINANCIAL_EVENT_NOT_FOUND'; END IF;
  v_pending_receipt:=v_event.system_event_key='GOODS_RECEIPT'
    AND v_event.source_table='goods_receipt_documents'
    AND v_event.amounts->>'financePostingState'='HOLD_FOR_SUPPLIER_ASSIGNMENT';
  IF NOT v_pending_receipt AND (v_event.system_event_key<>'GOODS_RECEIPT_SUPPLIER_ASSIGNMENT'
    OR v_event.source_table<>'goods_receipt_supplier_assignment_operations') THEN
    RETURN private.purchase_step6a_previous_purchase_ap_event_core(
      p_company_id,p_event_id,p_expected_event_version,p_actor_id);
  END IF;
  IF p_actor_id IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF p_expected_event_version IS DISTINCT FROM v_event.event_version THEN
    RAISE EXCEPTION 'EVENT_VERSION_CONFLICT'; END IF;
  IF v_event.status='POSTED'::public.event_status THEN
    SELECT * INTO STRICT v_journal FROM public.finance_journals journal
    WHERE journal.company_id=p_company_id AND journal.financial_event_id=v_event.id
      AND journal.status='POSTED';
    RETURN jsonb_build_object('financialEventId',v_event.id,'journalId',v_journal.id,
      'journalNo',v_journal.journal_no,'status','POSTED','idempotentReplay',true);
  END IF;
  IF v_event.status='CANCELED'::public.event_status
    AND v_event.error_message='NO_FINANCIAL_EFFECT' THEN
    RETURN jsonb_build_object('financialEventId',v_event.id,'journalId',NULL,
      'journalNo',NULL,'status','CANCELED','reason','NO_FINANCIAL_EFFECT',
      'idempotentReplay',true);
  END IF;
  IF v_event.status<>'HOLD'::public.event_status
    OR v_event.event_type::text<>'PURCHASE_POSTED' THEN
    RAISE EXCEPTION 'UNSUPPORTED_FINANCIAL_EVENT_CONTRACT'; END IF;
  IF v_pending_receipt THEN
    SELECT receipt.* INTO v_receipt FROM public.goods_receipt_documents receipt
    WHERE receipt.company_id=p_company_id AND receipt.id=v_event.source_id
      AND receipt.status='POSTED' AND receipt.receipt_scope='DAILY_WAREHOUSE'
      AND receipt.supplier_assignment_status='SUPPLIER_PENDING'
      AND receipt.financial_event_id=v_event.id FOR SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION 'FINANCIAL_EVENT_SOURCE_NOT_FOUND'; END IF;
    SELECT round(COALESCE(sum(line.provisional_ap_amount),0),4)
      INTO v_line_total FROM public.goods_receipt_lines line
    WHERE line.company_id=p_company_id AND line.document_id=v_receipt.id;
    SELECT round(COALESCE(sum(batch.qty_purchased*batch.cogs_unit),0),4)
      INTO v_batch_total FROM public.product_batches batch
    JOIN public.goods_receipt_condition_allocations allocation
      ON allocation.company_id=batch.company_id
     AND allocation.id=batch.goods_receipt_condition_allocation_id
    JOIN public.goods_receipt_lines line ON line.company_id=allocation.company_id
     AND line.id=allocation.receipt_line_id
    WHERE line.company_id=p_company_id AND line.document_id=v_receipt.id;
    SELECT round(COALESCE(sum(clearing.amount),0),4)
      INTO v_clearing_total FROM public.goods_receipt_unassigned_clearings clearing
    WHERE clearing.company_id=p_company_id AND clearing.receipt_id=v_receipt.id;
    v_total:=round(v_receipt.provisional_ap_total,4);
    IF v_total<>v_line_total OR v_total<>v_batch_total OR v_total<>v_clearing_total
      OR v_total<>round(COALESCE((v_event.amounts->>'inventoryDebit')::numeric,-1),4)
      OR v_total<>round(COALESCE((v_event.amounts->>'unassignedSupplierClearingCredit')::numeric,-1),4)
      OR round(COALESCE((v_event.amounts->>'supplierApProvisionalCredit')::numeric,-1),4)<>0 THEN
      RAISE EXCEPTION 'FINANCIAL_EVENT_AMOUNT_SOURCE_MISMATCH'; END IF;
    IF EXISTS(SELECT 1 FROM public.goods_receipt_unassigned_clearings clearing
        WHERE clearing.company_id=p_company_id AND clearing.receipt_id=v_receipt.id
          AND clearing.clearing_account_id IS DISTINCT FROM
            NULLIF(v_event.amounts->>'unassignedSupplierClearingAccountId','')::uuid) THEN
      RAISE EXCEPTION 'FINANCIAL_EVENT_ACCOUNT_SOURCE_MISMATCH'; END IF;
    IF v_total=0 THEN
      UPDATE public.financial_events SET status='CANCELED'::public.event_status,
        processed_at=v_now,error_message='NO_FINANCIAL_EFFECT',
        transaction_rule_version=20260914130000
      WHERE company_id=p_company_id AND id=v_event.id;
      RETURN jsonb_build_object('financialEventId',v_event.id,'journalId',NULL,
        'journalNo',NULL,'status','CANCELED','reason','NO_FINANCIAL_EFFECT',
        'idempotentReplay',false);
    END IF;
    v_inventory_account:=private.g6_require_event_snapshot_account(v_event,
      NULLIF(v_event.amounts->>'inventoryAccountId','')::uuid,'INVENTORY_ASSET');
    v_clearing_account:=private.g6_require_event_snapshot_account(v_event,
      NULLIF(v_event.amounts->>'unassignedSupplierClearingAccountId','')::uuid,
      'PURCHASE_UNASSIGNED_CLEARING');
    SELECT * INTO v_period FROM public.accounting_periods period
    WHERE period.company_id=p_company_id
      AND v_event.event_date::date BETWEEN period.start_date AND period.end_date
      AND period.status IN('OPEN','REOPENED')
    ORDER BY period.start_date LIMIT 1 FOR SHARE;
    IF NOT FOUND THEN
      SELECT * INTO v_period FROM public.accounting_periods period
      WHERE period.company_id=p_company_id AND period.start_date>v_event.event_date::date
        AND period.status IN('OPEN','REOPENED')
      ORDER BY period.start_date LIMIT 1 FOR SHARE;
      IF NOT FOUND THEN RAISE EXCEPTION 'POSTABLE_ACCOUNTING_PERIOD_NOT_FOUND'; END IF;
      v_type:='PRIOR_PERIOD_ADJUSTMENT';v_date:=v_period.start_date;
    ELSE v_date:=v_event.event_date::date; END IF;
    INSERT INTO public.finance_journals(company_id,journal_no,journal_type,
      accounting_period_id,accounting_date,original_event_date,source_type,source_id,
      source_version,financial_event_id,idempotency_key,system_event_key,
      transaction_category_id,transaction_rule_version,store_id,warehouse_id,
      description,status,created_by)
    VALUES(p_company_id,'G6-'||replace(v_event.id::text,'-',''),v_type,v_period.id,v_date,
      v_event.event_date::date,v_event.source_table,v_event.source_id,v_event.event_version,
      v_event.id,'G6_EVENT|'||p_company_id||'|'||v_event.id||'|'||v_event.event_version,
      v_event.system_event_key,v_event.transaction_category_id,20260914130000,
      v_receipt.store_id,v_receipt.warehouse_id,
      'Pending-Supplier Goods Receipt: '||v_event.event_code,'DRAFT',p_actor_id)
    RETURNING * INTO v_journal;
    INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,account_id,
      debit,credit,store_id,warehouse_id,description)
    VALUES(p_company_id,v_journal.id,1,v_inventory_account,v_total,0,
        v_receipt.store_id,v_receipt.warehouse_id,'INVENTORY_ASSET'),
      (p_company_id,v_journal.id,2,v_clearing_account,0,v_total,
        v_receipt.store_id,v_receipt.warehouse_id,'PURCHASE_UNASSIGNED_CLEARING');
    UPDATE public.finance_journals SET status='POSTED',posted_by=p_actor_id,posted_at=v_now
    WHERE company_id=p_company_id AND id=v_journal.id RETURNING * INTO v_journal;
    IF round(v_journal.total_debit,4)<>v_total
      OR round(v_journal.total_credit,4)<>v_total THEN RAISE EXCEPTION 'JOURNAL_UNBALANCED'; END IF;
    UPDATE public.financial_events SET status='POSTED'::public.event_status,
      processed_at=v_now,error_message=NULL,transaction_rule_version=20260914130000
    WHERE company_id=p_company_id AND id=v_event.id;
    RETURN jsonb_build_object('financialEventId',v_event.id,'journalId',v_journal.id,
      'journalNo',v_journal.journal_no,'status','POSTED','journalType',v_journal.journal_type,
      'accountingDate',v_journal.accounting_date,'totalDebit',v_journal.total_debit,
      'totalCredit',v_journal.total_credit,'idempotentReplay',false,
      'pendingSupplierReceipt',true);
  END IF;
  SELECT operation.*,receipt.warehouse_id,receipt.store_id,receipt.status receipt_status,
    receipt.receipt_scope,receipt.financial_event_id receipt_financial_event_id,
    receipt_event.status receipt_financial_status INTO v_operation
  FROM public.goods_receipt_supplier_assignment_operations operation
  JOIN public.goods_receipt_documents receipt
    ON receipt.company_id=operation.company_id AND receipt.id=operation.receipt_id
  JOIN public.financial_events receipt_event
    ON receipt_event.company_id=receipt.company_id
   AND receipt_event.id=receipt.financial_event_id
  WHERE operation.company_id=p_company_id AND operation.id=v_event.source_id
    AND operation.financial_event_id=v_event.id FOR SHARE OF operation,receipt;
  IF NOT FOUND OR v_operation.receipt_status<>'POSTED'
    OR v_operation.receipt_scope<>'DAILY_WAREHOUSE' THEN
    RAISE EXCEPTION 'FINANCIAL_EVENT_SOURCE_NOT_FOUND'; END IF;
  IF v_operation.receipt_financial_status NOT IN(
      'POSTED'::public.event_status,'CANCELED'::public.event_status) THEN
    RAISE EXCEPTION 'GOODS_RECEIPT_FINANCE_MUST_POST_FIRST'; END IF;
  SELECT count(*),round(COALESCE(sum(assignment.assigned_amount),0),4),
    round(COALESCE(sum(clearing.amount),0),4) INTO v_count,v_total,v_source_total
  FROM public.goods_receipt_supplier_assignments assignment
  JOIN public.goods_receipt_unassigned_clearings clearing
    ON clearing.company_id=assignment.company_id AND clearing.id=assignment.clearing_id
   AND clearing.receipt_id=assignment.receipt_id
   AND clearing.receipt_line_id=assignment.receipt_line_id
  JOIN public.goods_receipt_ap_provisionals provisional
    ON provisional.company_id=assignment.company_id
   AND provisional.receipt_id=assignment.receipt_id
   AND provisional.receipt_line_id=assignment.receipt_line_id
   AND provisional.supplier_id=assignment.supplier_id
   AND provisional.amount=assignment.assigned_amount AND provisional.status='OPEN'
  WHERE assignment.company_id=p_company_id
    AND assignment.operation_id=v_operation.id;
  IF v_count<=0 OR v_total<>v_source_total
    OR v_count<>COALESCE((v_operation.result_snapshot->>'assignmentCount')::integer,-1)
    OR v_total<>round(COALESCE((v_operation.result_snapshot->>'assignedAmount')::numeric,-1),4)
    OR v_total<>round(COALESCE((v_event.amounts->>'unassignedSupplierClearingDebit')::numeric,-1),4)
    OR v_total<>round(COALESCE((v_event.amounts->>'supplierApProvisionalCredit')::numeric,-1),4)
    OR v_count<>COALESCE((v_event.amounts->>'assignmentCount')::integer,-1) THEN
    RAISE EXCEPTION 'FINANCIAL_EVENT_AMOUNT_SOURCE_MISMATCH'; END IF;
  IF EXISTS(SELECT 1 FROM public.goods_receipt_supplier_assignments assignment
      JOIN public.goods_receipt_unassigned_clearings clearing
        ON clearing.company_id=assignment.company_id AND clearing.id=assignment.clearing_id
      WHERE assignment.company_id=p_company_id AND assignment.operation_id=v_operation.id
        AND clearing.clearing_account_id IS DISTINCT FROM
          NULLIF(v_event.amounts->>'unassignedSupplierClearingAccountId','')::uuid) THEN
    RAISE EXCEPTION 'FINANCIAL_EVENT_ACCOUNT_SOURCE_MISMATCH'; END IF;
  IF v_total=0 THEN
    UPDATE public.financial_events SET status='CANCELED'::public.event_status,
      processed_at=v_now,error_message='NO_FINANCIAL_EFFECT',
      transaction_rule_version=20260914130000
    WHERE company_id=p_company_id AND id=v_event.id;
    RETURN jsonb_build_object('financialEventId',v_event.id,'journalId',NULL,
      'journalNo',NULL,'status','CANCELED','reason','NO_FINANCIAL_EFFECT',
      'idempotentReplay',false);
  END IF;
  v_clearing_account:=private.g6_require_event_snapshot_account(v_event,
    NULLIF(v_event.amounts->>'unassignedSupplierClearingAccountId','')::uuid,
    'PURCHASE_UNASSIGNED_CLEARING');
  v_ap_account:=private.g6_require_event_snapshot_account(v_event,
    NULLIF(v_event.amounts->>'supplierApProvisionalAccountId','')::uuid,
    'SUPPLIER_AP_PROVISIONAL');
  SELECT * INTO v_period FROM public.accounting_periods period
  WHERE period.company_id=p_company_id
    AND v_event.event_date::date BETWEEN period.start_date AND period.end_date
    AND period.status IN('OPEN','REOPENED')
  ORDER BY period.start_date LIMIT 1 FOR SHARE;
  IF NOT FOUND THEN
    SELECT * INTO v_period FROM public.accounting_periods period
    WHERE period.company_id=p_company_id AND period.start_date>v_event.event_date::date
      AND period.status IN('OPEN','REOPENED')
    ORDER BY period.start_date LIMIT 1 FOR SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION 'POSTABLE_ACCOUNTING_PERIOD_NOT_FOUND'; END IF;
    v_type:='PRIOR_PERIOD_ADJUSTMENT';v_date:=v_period.start_date;
  ELSE v_date:=v_event.event_date::date; END IF;
  INSERT INTO public.finance_journals(company_id,journal_no,journal_type,
    accounting_period_id,accounting_date,original_event_date,source_type,source_id,
    source_version,financial_event_id,idempotency_key,system_event_key,
    transaction_category_id,transaction_rule_version,store_id,warehouse_id,
    description,status,created_by)
  VALUES(p_company_id,'G6-'||replace(v_event.id::text,'-',''),v_type,v_period.id,v_date,
    v_event.event_date::date,v_event.source_table,v_event.source_id,v_event.event_version,
    v_event.id,'G6_EVENT|'||p_company_id||'|'||v_event.id||'|'||v_event.event_version,
    v_event.system_event_key,v_event.transaction_category_id,20260914130000,
    v_operation.store_id,v_operation.warehouse_id,
    'Supplier assignment clearing reclassification: '||v_event.event_code,
    'DRAFT',p_actor_id) RETURNING * INTO v_journal;
  FOR v_row IN
    SELECT assignment.supplier_id,round(sum(assignment.assigned_amount),4) amount
    FROM public.goods_receipt_supplier_assignments assignment
    WHERE assignment.company_id=p_company_id AND assignment.operation_id=v_operation.id
    GROUP BY assignment.supplier_id ORDER BY assignment.supplier_id
  LOOP
    v_line:=v_line+1;
    INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,account_id,
      debit,credit,store_id,warehouse_id,supplier_id,description)
    VALUES(p_company_id,v_journal.id,v_line,v_clearing_account,v_row.amount,0,
      v_operation.store_id,v_operation.warehouse_id,v_row.supplier_id,
      'PURCHASE_UNASSIGNED_CLEARING');
    v_line:=v_line+1;
    INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,account_id,
      debit,credit,store_id,warehouse_id,supplier_id,description)
    VALUES(p_company_id,v_journal.id,v_line,v_ap_account,0,v_row.amount,
      v_operation.store_id,v_operation.warehouse_id,v_row.supplier_id,
      'SUPPLIER_AP_PROVISIONAL');
  END LOOP;
  UPDATE public.finance_journals SET status='POSTED',posted_by=p_actor_id,posted_at=v_now
  WHERE company_id=p_company_id AND id=v_journal.id RETURNING * INTO v_journal;
  IF round(v_journal.total_debit,4)<>v_total
    OR round(v_journal.total_credit,4)<>v_total THEN RAISE EXCEPTION 'JOURNAL_UNBALANCED'; END IF;
  UPDATE public.financial_events SET status='POSTED'::public.event_status,
    processed_at=v_now,error_message=NULL,transaction_rule_version=20260914130000
  WHERE company_id=p_company_id AND id=v_event.id;
  RETURN jsonb_build_object('financialEventId',v_event.id,'journalId',v_journal.id,
    'journalNo',v_journal.journal_no,'status','POSTED','journalType',v_journal.journal_type,
    'accountingDate',v_journal.accounting_date,'totalDebit',v_journal.total_debit,
    'totalCredit',v_journal.total_credit,'idempotentReplay',false);
END
$$;

ALTER FUNCTION private.post_financial_event_core(uuid,uuid,bigint,uuid)
  RENAME TO post_financial_event_core_before_purchase_step6a;
CREATE FUNCTION private.post_financial_event_core(
  p_company_id uuid,p_event_id uuid,p_expected_event_version bigint,p_actor_id uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_key text;v_source text;
BEGIN
  SELECT event.system_event_key,event.source_table INTO v_key,v_source
  FROM public.financial_events event
  WHERE event.company_id=p_company_id AND event.id=p_event_id;
  IF (v_key='GOODS_RECEIPT_SUPPLIER_ASSIGNMENT'
      AND v_source='goods_receipt_supplier_assignment_operations')
    OR (v_key='GOODS_RECEIPT' AND v_source='goods_receipt_documents') THEN
    RETURN private.post_purchase_ap_financial_event_core(
      p_company_id,p_event_id,p_expected_event_version,p_actor_id);
  END IF;
  RETURN private.post_financial_event_core_before_purchase_step6a(
    p_company_id,p_event_id,p_expected_event_version,p_actor_id);
END
$$;

ALTER FUNCTION private.f4b_financial_event_supported(public.financial_events)
  RENAME TO f4b_financial_event_supported_before_purchase_step6a;
CREATE FUNCTION private.f4b_financial_event_supported(
  p_event public.financial_events
) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
  SELECT CASE
    WHEN p_event.status='HOLD'::public.event_status
      AND p_event.system_event_key='SUPPLIER_INVOICE'
      AND p_event.source_table='supplier_invoice_documents'
      AND EXISTS(
        SELECT 1 FROM public.supplier_invoice_allocations invoice_allocation
        JOIN public.goods_receipt_supplier_assignments assignment
          ON assignment.company_id=invoice_allocation.company_id
         AND assignment.receipt_line_id=invoice_allocation.receipt_line_id
        JOIN public.goods_receipt_supplier_assignment_operations operation
          ON operation.company_id=assignment.company_id
         AND operation.id=assignment.operation_id
        JOIN public.financial_events assignment_event
          ON assignment_event.company_id=operation.company_id
         AND assignment_event.id=operation.financial_event_id
        WHERE invoice_allocation.company_id=p_event.company_id
          AND invoice_allocation.document_id=p_event.source_id
          AND assignment_event.status NOT IN(
            'POSTED'::public.event_status,'CANCELED'::public.event_status)
      ) THEN false
    WHEN p_event.status='HOLD'::public.event_status
      AND p_event.system_event_key='GOODS_RECEIPT'
      AND p_event.event_type::text='PURCHASE_POSTED'
      AND p_event.source_table='goods_receipt_documents'
      AND p_event.amounts->>'financePostingState'='HOLD_FOR_SUPPLIER_ASSIGNMENT'
      AND EXISTS(SELECT 1 FROM public.goods_receipt_documents receipt
        WHERE receipt.company_id=p_event.company_id AND receipt.id=p_event.source_id
          AND receipt.status='POSTED' AND receipt.receipt_scope='DAILY_WAREHOUSE'
          AND receipt.supplier_assignment_status='SUPPLIER_PENDING'
          AND receipt.financial_event_id=p_event.id)
    THEN true
    WHEN p_event.status='HOLD'::public.event_status
    AND p_event.system_event_key='GOODS_RECEIPT_SUPPLIER_ASSIGNMENT'
    AND p_event.event_type::text='PURCHASE_POSTED'
    AND p_event.source_table='goods_receipt_supplier_assignment_operations'
    AND EXISTS(SELECT 1 FROM public.goods_receipt_supplier_assignment_operations operation
      JOIN public.goods_receipt_documents receipt
        ON receipt.company_id=operation.company_id AND receipt.id=operation.receipt_id
      JOIN public.financial_events receipt_event
        ON receipt_event.company_id=receipt.company_id
       AND receipt_event.id=receipt.financial_event_id
      WHERE operation.company_id=p_event.company_id AND operation.id=p_event.source_id
        AND operation.financial_event_id=p_event.id
        AND receipt_event.status IN(
          'POSTED'::public.event_status,'CANCELED'::public.event_status))
    THEN true ELSE private.f4b_financial_event_supported_before_purchase_step6a(p_event) END
$$;

CREATE OR REPLACE FUNCTION public.preview_purchase_ap_posting_queue(
  p_limit integer DEFAULT 100
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_actor uuid:=auth.uid();v_company uuid:=public.private_active_company_id();
  v_run_id uuid:=gen_random_uuid();v_run public.finance_posting_queue_runs%rowtype;
  v_count integer;v_hash text;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
  IF p_limit IS NULL OR p_limit<1 OR p_limit>500 THEN RAISE EXCEPTION 'QUEUE_PREVIEW_LIMIT_INVALID'; END IF;
  IF NOT private.g6_finance_queue_role_allowed(v_company) THEN RAISE EXCEPTION 'FINANCE_QUEUE_ROLE_REQUIRED'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('G6_FINANCE_QUEUE|'||v_company,0));
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs run
      WHERE run.company_id=v_company AND run.status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'ACTIVE_FINANCE_POSTING_QUEUE_ALREADY_EXISTS'; END IF;
  INSERT INTO public.finance_posting_queue_runs(id,company_id,queue_no,scope_system_key,
    status,preview_limit,preview_hash,created_by)
  VALUES(v_run_id,v_company,'FQ-'||to_char(clock_timestamp(),'YYYYMMDD')||'-'||
    upper(substr(replace(v_run_id::text,'-',''),1,8)),'PURCHASE_AP','PREVIEWED',p_limit,
    md5('EMPTY|'||v_company||'|'||v_run_id),v_actor);
  INSERT INTO public.finance_posting_queue_items(company_id,queue_run_id,line_no,
    financial_event_id,event_version_snapshot,event_code_snapshot,system_event_key_snapshot,
    source_table_snapshot,source_id_snapshot,transaction_category_id_snapshot,event_date_snapshot)
  SELECT event.company_id,v_run_id,row_number() OVER(ORDER BY event.event_date,
      CASE WHEN event.system_event_key='GOODS_RECEIPT'
        AND event.amounts->>'financePostingState'='HOLD_FOR_SUPPLIER_ASSIGNMENT' THEN 0
        WHEN event.system_event_key='GOODS_RECEIPT_SUPPLIER_ASSIGNMENT' THEN 1 ELSE 2 END,
      event.id)::integer,event.id,event.event_version,event.event_code,event.system_event_key,
    event.source_table,event.source_id,event.transaction_category_id,event.event_date
  FROM public.financial_events event
  WHERE event.company_id=v_company AND event.status='HOLD'::public.event_status
    AND ((event.system_event_key='GOODS_RECEIPT_SUPPLIER_ASSIGNMENT'
        AND event.event_type::text='PURCHASE_POSTED'
        AND event.source_table='goods_receipt_supplier_assignment_operations'
        AND EXISTS(SELECT 1 FROM public.goods_receipt_supplier_assignment_operations operation
          JOIN public.goods_receipt_documents receipt
            ON receipt.company_id=operation.company_id AND receipt.id=operation.receipt_id
          JOIN public.financial_events receipt_event
            ON receipt_event.company_id=receipt.company_id
           AND receipt_event.id=receipt.financial_event_id
          WHERE operation.company_id=event.company_id AND operation.id=event.source_id
            AND operation.financial_event_id=event.id
            AND receipt_event.status IN(
              'POSTED'::public.event_status,'CANCELED'::public.event_status)))
      OR (event.system_event_key='GOODS_RECEIPT' AND event.event_type::text='PURCHASE_POSTED'
        AND event.source_table='goods_receipt_documents'
        AND EXISTS(SELECT 1 FROM public.goods_receipt_documents receipt
          WHERE receipt.company_id=event.company_id AND receipt.id=event.source_id
            AND receipt.status='POSTED' AND receipt.financial_event_id=event.id
            AND (receipt.supplier_assignment_status<>'SUPPLIER_PENDING'
              OR (receipt.receipt_scope='DAILY_WAREHOUSE'
                AND event.amounts->>'financePostingState'='HOLD_FOR_SUPPLIER_ASSIGNMENT'))))
      OR (event.system_event_key='SUPPLIER_INVOICE'
        AND event.event_type::text='SUPPLIER_INVOICE_VALIDATED'
        AND event.source_table='supplier_invoice_documents'
        AND EXISTS(SELECT 1 FROM public.supplier_invoice_documents invoice
          WHERE invoice.company_id=event.company_id AND invoice.id=event.source_id
            AND invoice.status='VALIDATED' AND invoice.financial_event_id=event.id)
        AND NOT EXISTS(
          SELECT 1 FROM public.supplier_invoice_allocations invoice_allocation
          JOIN public.goods_receipt_supplier_assignments assignment
            ON assignment.company_id=invoice_allocation.company_id
           AND assignment.receipt_line_id=invoice_allocation.receipt_line_id
          JOIN public.goods_receipt_supplier_assignment_operations operation
            ON operation.company_id=assignment.company_id
           AND operation.id=assignment.operation_id
          JOIN public.financial_events assignment_event
            ON assignment_event.company_id=operation.company_id
           AND assignment_event.id=operation.financial_event_id
          WHERE invoice_allocation.company_id=event.company_id
            AND invoice_allocation.document_id=event.source_id
            AND assignment_event.status NOT IN(
              'POSTED'::public.event_status,'CANCELED'::public.event_status)))
      OR (event.system_event_key='SUPPLIER_PAYMENT'
        AND event.event_type::text='SUPPLIER_PAYMENT_VALIDATED'
        AND event.source_table='supplier_payment_documents'
        AND EXISTS(SELECT 1 FROM public.supplier_payment_documents payment
          WHERE payment.company_id=event.company_id AND payment.id=event.source_id
            AND payment.status='VALIDATED' AND payment.financial_event_id=event.id)))
    AND NOT EXISTS(SELECT 1 FROM public.finance_journals journal
      WHERE journal.company_id=event.company_id AND journal.financial_event_id=event.id)
  ORDER BY event.event_date,
    CASE WHEN event.system_event_key='GOODS_RECEIPT'
      AND event.amounts->>'financePostingState'='HOLD_FOR_SUPPLIER_ASSIGNMENT' THEN 0
      WHEN event.system_event_key='GOODS_RECEIPT_SUPPLIER_ASSIGNMENT' THEN 1 ELSE 2 END,
    event.id LIMIT p_limit;
  GET DIAGNOSTICS v_count=ROW_COUNT;
  IF v_count=0 THEN RAISE EXCEPTION 'NO_SUPPORTED_HOLD_EVENTS'; END IF;
  SELECT md5(string_agg(item.financial_event_id||':'||item.event_version_snapshot,
    '|' ORDER BY item.line_no)) INTO v_hash FROM public.finance_posting_queue_items item
  WHERE item.company_id=v_company AND item.queue_run_id=v_run_id;
  UPDATE public.finance_posting_queue_runs SET previewed_event_count=v_count,
    preview_hash=v_hash WHERE company_id=v_company AND id=v_run_id RETURNING * INTO v_run;
  INSERT INTO public.finance_posting_queue_audit(company_id,queue_run_id,action,actor_id,after_state)
  VALUES(v_company,v_run_id,'PREVIEW',v_actor,jsonb_build_object('status',v_run.status,
    'masterVersion',v_run.master_version,'eventCount',v_count,'previewHash',v_hash,
    'scopeSystemKey','PURCHASE_AP'));
  RETURN jsonb_build_object('queueRunId',v_run.id,'queueNo',v_run.queue_no,
    'status',v_run.status,'masterVersion',v_run.master_version,'eventCount',v_count,
    'previewHash',v_hash,'scopeSystemKey','PURCHASE_AP');
END
$$;

REVOKE ALL ON FUNCTION
  public.assign_purchase_daily_receipt_suppliers_before_step6a(uuid,bigint,uuid,jsonb),
  private.purchase_step6a_previous_purchase_ap_event_core(uuid,uuid,bigint,uuid),
  private.post_purchase_ap_financial_event_core(uuid,uuid,bigint,uuid),
  private.post_financial_event_core_before_purchase_step6a(uuid,uuid,bigint,uuid),
  private.post_financial_event_core(uuid,uuid,bigint,uuid),
  private.f4b_financial_event_supported_before_purchase_step6a(public.financial_events),
  private.f4b_financial_event_supported(public.financial_events)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  public.assign_purchase_daily_receipt_suppliers_before_step6a(uuid,bigint,uuid,jsonb),
  private.purchase_step6a_previous_purchase_ap_event_core(uuid,uuid,bigint,uuid),
  private.post_purchase_ap_financial_event_core(uuid,uuid,bigint,uuid),
  private.post_financial_event_core_before_purchase_step6a(uuid,uuid,bigint,uuid),
  private.post_financial_event_core(uuid,uuid,bigint,uuid),
  private.f4b_financial_event_supported_before_purchase_step6a(public.financial_events),
  private.f4b_financial_event_supported(public.financial_events)
TO service_role;
REVOKE ALL ON FUNCTION public.assign_purchase_daily_receipt_suppliers(uuid,bigint,uuid,jsonb),
  public.preview_purchase_ap_posting_queue(integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.assign_purchase_daily_receipt_suppliers(uuid,bigint,uuid,jsonb),
  public.preview_purchase_ap_posting_queue(integer) TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260914130000','purchase_supplier_assignment_ap_bridge',
  'Step 6/6A posts pending-Supplier Receipt Inventory to Clearing, then bridges append-only Supplier assignments to canonical AP provisionals and Clearing-to-AP posting without creating Supplier Bills or repeating Stock/FIFO');

NOTIFY pgrst,'reload schema';
COMMIT;
