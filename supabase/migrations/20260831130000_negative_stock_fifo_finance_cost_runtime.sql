-- NSC-2/3: source-linked negative replenishment settlement and Supplier
-- Invoice FIFO revaluation. Existing POSTED journals remain immutable.

BEGIN;

DO $guard$
BEGIN
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260831130000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260831130000';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260831120000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: NSC-1 required';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260814143000') THEN
    RAISE EXCEPTION
      'MIGRATION_PRECONDITION_FAILED: zero-value receipt runtime required';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs run
    WHERE run.status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active finance queue';
  END IF;
  IF EXISTS(
    SELECT 1
    FROM public.negative_stock_replenishment_allocations replenishment
    JOIN public.product_batches batch
      ON batch.company_id=replenishment.company_id
     AND batch.id=replenishment.product_batch_id
    JOIN public.goods_receipt_lines receipt_line
      ON receipt_line.company_id=batch.company_id
     AND receipt_line.id=batch.goods_receipt_line_id
    JOIN public.goods_receipt_documents receipt
      ON receipt.company_id=receipt_line.company_id
     AND receipt.id=receipt_line.document_id
    JOIN public.financial_events event
      ON event.company_id=receipt.company_id
     AND event.id=receipt.financial_event_id
    WHERE replenishment.cost_variance_total<>0
      AND event.status='POSTED'::public.event_status
  ) THEN
    RAISE EXCEPTION
      'MIGRATION_PRECONDITION_FAILED: posted replenishment backfill required';
  END IF;
  IF EXISTS(
    SELECT 1
    FROM public.supplier_invoice_documents invoice
    JOIN public.supplier_invoice_allocations allocation
      ON allocation.company_id=invoice.company_id
     AND allocation.document_id=invoice.id
    JOIN public.financial_events event
      ON event.company_id=invoice.company_id
     AND event.id=invoice.financial_event_id
    WHERE invoice.status='VALIDATED'
      AND allocation.price_variance<>0
      AND event.status='POSTED'::public.event_status
  ) THEN
    RAISE EXCEPTION
      'MIGRATION_PRECONDITION_FAILED: posted Invoice revaluation backfill required';
  END IF;
END
$guard$;

-- Preserve the existing Purchase/AP dispatcher behind an NSC wrapper. The
-- wrapper only intercepts a zero-value Goods Receipt that still carries a
-- non-zero negative-stock cost reclassification.
ALTER FUNCTION private.post_purchase_ap_financial_event_core(
  UUID,UUID,BIGINT,UUID)
RENAME TO nsc_previous_purchase_ap_financial_event_core;

CREATE FUNCTION private.post_purchase_ap_financial_event_core(
  p_company_id UUID,p_event_id UUID,p_expected_event_version BIGINT,p_actor_id UUID
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
  v_event public.financial_events%ROWTYPE;
  v_receipt public.goods_receipt_documents%ROWTYPE;
  v_source public.inventory_cost_adjustment_sources%ROWTYPE;
  v_period public.accounting_periods%ROWTYPE;
  v_journal public.finance_journals%ROWTYPE;
  v_supplier UUID;
  v_accounting_date DATE;
  v_journal_type TEXT:='AUTOMATIC';
  v_now TIMESTAMPTZ:=clock_timestamp();
BEGIN
  IF p_actor_id IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  SELECT * INTO v_event FROM public.financial_events event
  WHERE event.company_id=p_company_id AND event.id=p_event_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'FINANCIAL_EVENT_NOT_FOUND'; END IF;
  IF p_expected_event_version IS DISTINCT FROM v_event.event_version THEN
    RAISE EXCEPTION 'EVENT_VERSION_CONFLICT';
  END IF;

  IF v_event.status='HOLD'::public.event_status
    AND v_event.system_event_key='GOODS_RECEIPT'
    AND v_event.source_table='goods_receipt_documents' THEN
    SELECT * INTO v_source
    FROM public.inventory_cost_adjustment_sources source
    WHERE source.company_id=p_company_id
      AND source.source_financial_event_id=v_event.id
      AND source.adjustment_type='NEGATIVE_REPLENISHMENT'
      AND source.status='APPLIED';
    IF FOUND AND v_source.planned_cost_variance<>0
      AND round(COALESCE((v_event.amounts->>'inventoryDebit')::NUMERIC,0),4)=0
      AND round(COALESCE((v_event.amounts
        ->>'supplierApProvisionalCredit')::NUMERIC,0),4)=0 THEN
      SELECT * INTO v_receipt FROM public.goods_receipt_documents document
      WHERE document.company_id=p_company_id AND document.id=v_event.source_id
        AND document.status='POSTED'
        AND document.financial_event_id=v_event.id FOR SHARE;
      IF NOT FOUND OR round(v_receipt.provisional_ap_total,4)<>0 THEN
        RAISE EXCEPTION 'NSC_ZERO_RECEIPT_SOURCE_INVALID';
      END IF;
      SELECT order_document.supplier_id INTO v_supplier
      FROM public.supplier_order_documents order_document
      WHERE order_document.company_id=p_company_id
        AND order_document.id=v_receipt.supplier_order_id;

      SELECT * INTO v_period FROM public.accounting_periods period
      WHERE period.company_id=p_company_id
        AND v_event.event_date::DATE BETWEEN period.start_date AND period.end_date
        AND period.status IN('OPEN','REOPENED')
      ORDER BY period.start_date LIMIT 1 FOR SHARE;
      IF NOT FOUND THEN
        SELECT * INTO v_period FROM public.accounting_periods period
        WHERE period.company_id=p_company_id
          AND period.start_date>v_event.event_date::DATE
          AND period.status IN('OPEN','REOPENED')
        ORDER BY period.start_date LIMIT 1 FOR SHARE;
        IF NOT FOUND THEN
          RAISE EXCEPTION 'POSTABLE_ACCOUNTING_PERIOD_NOT_FOUND';
        END IF;
        v_journal_type:='PRIOR_PERIOD_ADJUSTMENT';
        v_accounting_date:=v_period.start_date;
      ELSE
        v_accounting_date:=v_event.event_date::DATE;
      END IF;

      INSERT INTO public.finance_journals(company_id,journal_no,journal_type,
        accounting_period_id,accounting_date,original_event_date,source_type,
        source_id,source_version,financial_event_id,idempotency_key,
        system_event_key,transaction_category_id,transaction_rule_version,
        store_id,warehouse_id,description,status,created_by)
      VALUES(p_company_id,'G6-'||replace(v_event.id::TEXT,'-',''),
        v_journal_type,v_period.id,v_accounting_date,v_event.event_date::DATE,
        v_event.source_table,v_event.source_id,v_event.event_version,v_event.id,
        'G6_EVENT|'||p_company_id||'|'||v_event.id||'|'
          ||v_event.event_version,v_event.system_event_key,
        v_event.transaction_category_id,20260831130000,v_receipt.store_id,
        v_receipt.warehouse_id,
        'Negative-stock cost settlement: '||v_event.event_code,
        'DRAFT',p_actor_id)
      RETURNING * INTO v_journal;

      INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,
        account_id,debit,credit,store_id,warehouse_id,supplier_id,description)
      VALUES
        (p_company_id,v_journal.id,1,v_source.inventory_account_id,
          CASE WHEN v_source.inventory_variance>0
            THEN v_source.inventory_variance ELSE 0 END,
          CASE WHEN v_source.inventory_variance<0
            THEN abs(v_source.inventory_variance) ELSE 0 END,
          v_receipt.store_id,v_receipt.warehouse_id,v_supplier,
          'NEGATIVE_REPLENISHMENT_INVENTORY_VARIANCE'),
        (p_company_id,v_journal.id,2,v_source.offset_account_id,
          CASE WHEN v_source.hpp_variance>0
            THEN v_source.hpp_variance ELSE 0 END,
          CASE WHEN v_source.hpp_variance<0
            THEN abs(v_source.hpp_variance) ELSE 0 END,
          v_receipt.store_id,v_receipt.warehouse_id,v_supplier,
          'NEGATIVE_REPLENISHMENT_COGS_VARIANCE');
      UPDATE public.finance_journals journal SET status='POSTED',
        posted_by=p_actor_id,posted_at=v_now
      WHERE journal.company_id=p_company_id AND journal.id=v_journal.id
      RETURNING * INTO v_journal;
      UPDATE public.financial_events event SET
        status='POSTED'::public.event_status,processed_at=v_now,
        error_message=NULL,transaction_rule_version=20260831130000
      WHERE event.company_id=p_company_id AND event.id=v_event.id;
      RETURN jsonb_build_object('financialEventId',v_event.id,
        'journalId',v_journal.id,'journalNo',v_journal.journal_no,
        'status','POSTED','journalType',v_journal.journal_type,
        'accountingDate',v_journal.accounting_date,
        'totalDebit',v_journal.total_debit,
        'totalCredit',v_journal.total_credit,'idempotentReplay',FALSE,
        'negativeStockCostSettlement',TRUE);
    END IF;
  END IF;

  RETURN private.nsc_previous_purchase_ap_financial_event_core(
    p_company_id,p_event_id,p_expected_event_version,p_actor_id);
END
$$;

CREATE FUNCTION private.nsc_plan_supplier_invoice_batch_cost(
  p_company_id UUID,p_document_id UUID,p_financial_event_id UUID,p_actor_id UUID
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE
  v_document public.supplier_invoice_documents%ROWTYPE;
  v_event public.financial_events%ROWTYPE;
  v_allocation public.supplier_invoice_allocations%ROWTYPE;
  v_batch RECORD;
  v_source_id UUID;
  v_inventory_account UUID;
  v_offset_account UUID;
  v_variance_account UUID;
  v_remaining_qty NUMERIC(24,6);
  v_take NUMERIC(24,6);
  v_remaining_variance NUMERIC(20,4);
  v_batch_variance NUMERIC(20,4);
  v_total_qty NUMERIC(24,6):=0;
  v_total_variance NUMERIC(20,4):=0;
  v_plan_rows BIGINT:=0;
BEGIN
  IF p_actor_id IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  SELECT * INTO v_document FROM public.supplier_invoice_documents document
  WHERE document.company_id=p_company_id AND document.id=p_document_id
    AND document.status='VALIDATED' FOR SHARE;
  IF NOT FOUND OR v_document.financial_event_id<>p_financial_event_id THEN
    RAISE EXCEPTION 'NSC_SUPPLIER_INVOICE_SOURCE_INVALID';
  END IF;
  SELECT * INTO v_event FROM public.financial_events event
  WHERE event.company_id=p_company_id AND event.id=p_financial_event_id
    AND event.system_event_key='SUPPLIER_INVOICE'
    AND event.source_table='supplier_invoice_documents'
    AND event.source_id=p_document_id AND event.status='HOLD'::public.event_status
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'NSC_SUPPLIER_INVOICE_EVENT_INVALID'; END IF;

  SELECT source.id INTO v_source_id
  FROM public.inventory_cost_adjustment_sources source
  WHERE source.company_id=p_company_id
    AND source.adjustment_type='SUPPLIER_INVOICE_REVALUATION'
    AND source.source_document_id=p_document_id;
  IF v_source_id IS NOT NULL THEN RETURN v_source_id; END IF;

  v_inventory_account:=private.resolve_opening_stock_account(
    p_company_id,v_event.transaction_category_id,'INVENTORY_ASSET',
    v_event.event_date);
  v_variance_account:=NULLIF(
    v_event.amounts->>'purchasePriceVarianceAccountId','')::UUID;
  IF v_variance_account IS NULL THEN
    v_variance_account:=private.resolve_opening_stock_account(
      p_company_id,v_event.transaction_category_id,
      'PURCHASE_PRICE_VARIANCE',v_event.event_date);
  END IF;
  v_offset_account:=private.resolve_opening_stock_account(
    p_company_id,v_event.transaction_category_id,'COGS',v_event.event_date);

  FOR v_allocation IN
    SELECT allocation.*
    FROM public.supplier_invoice_allocations allocation
    WHERE allocation.company_id=p_company_id
      AND allocation.document_id=p_document_id
      AND allocation.price_variance<>0
    ORDER BY allocation.created_at,allocation.id
  LOOP
    PERFORM pg_advisory_xact_lock(hashtextextended(
      'NSC_INVOICE_RECEIPT|'||p_company_id::TEXT||'|'||
      v_allocation.receipt_line_id::TEXT,0));
    v_remaining_qty:=v_allocation.allocated_base_qty;
    v_remaining_variance:=v_allocation.price_variance;
    FOR v_batch IN
      SELECT batch.*,
        batch.qty_purchased-COALESCE((
          SELECT sum(cost.allocated_base_qty)
          FROM public.supplier_invoice_batch_cost_allocations cost
          WHERE cost.company_id=batch.company_id
            AND cost.product_batch_id=batch.id),0) unplanned_base_qty
      FROM public.product_batches batch
      WHERE batch.company_id=p_company_id
        AND batch.goods_receipt_line_id=v_allocation.receipt_line_id
        AND batch.qty_purchased>COALESCE((
          SELECT sum(cost.allocated_base_qty)
          FROM public.supplier_invoice_batch_cost_allocations cost
          WHERE cost.company_id=batch.company_id
            AND cost.product_batch_id=batch.id),0)
      ORDER BY batch.created_at,batch.id
      FOR UPDATE OF batch
    LOOP
      EXIT WHEN v_remaining_qty<=0;
      v_take:=LEAST(v_remaining_qty,v_batch.unplanned_base_qty);
      v_batch_variance:=CASE WHEN v_take=v_remaining_qty
        THEN v_remaining_variance
        ELSE round(v_allocation.price_variance*v_take
          /v_allocation.allocated_base_qty,4) END;
      INSERT INTO public.supplier_invoice_batch_cost_allocations(
        company_id,document_id,supplier_invoice_allocation_id,
        receipt_line_id,product_batch_id,allocated_base_qty,
        price_variance_total
      ) VALUES(
        p_company_id,p_document_id,v_allocation.id,
        v_allocation.receipt_line_id,v_batch.id,v_take,v_batch_variance
      );
      v_plan_rows:=v_plan_rows+1;
      v_total_qty:=v_total_qty+v_take;
      v_total_variance:=v_total_variance+v_batch_variance;
      v_remaining_qty:=v_remaining_qty-v_take;
      v_remaining_variance:=v_remaining_variance-v_batch_variance;
    END LOOP;
    IF v_remaining_qty<>0 OR v_remaining_variance<>0 THEN
      RAISE EXCEPTION 'NSC_RECEIPT_BATCH_ALLOCATION_INCOMPLETE';
    END IF;
  END LOOP;

  IF v_plan_rows=0 THEN RETURN NULL; END IF;
  INSERT INTO public.inventory_cost_adjustment_sources(
    company_id,adjustment_type,source_document_table,source_document_id,
    source_financial_event_id,total_quantity_base,planned_cost_variance,
    inventory_account_id,offset_account_id,variance_account_id,status,
    idempotency_key,created_by
  ) VALUES(
    p_company_id,'SUPPLIER_INVOICE_REVALUATION',
    'supplier_invoice_documents',p_document_id,p_financial_event_id,
    v_total_qty,round(v_total_variance,4),v_inventory_account,v_offset_account,
    v_variance_account,
    'PLANNED','NSC_SUPPLIER_INVOICE|'||p_company_id::TEXT||'|'
      ||p_document_id::TEXT,p_actor_id
  ) RETURNING id INTO v_source_id;

  UPDATE public.financial_events event SET amounts=event.amounts
    ||jsonb_build_object('costSplitVersion',1,
      'inventoryCostAdjustmentSourceId',v_source_id,
      'plannedInventoryCostVariance',round(v_total_variance,4),
      'inventoryVarianceAccountId',v_inventory_account)
  WHERE event.company_id=p_company_id AND event.id=p_financial_event_id
    AND event.status='HOLD'::public.event_status;
  RETURN v_source_id;
END
$$;

CREATE FUNCTION private.nsc_apply_supplier_invoice_batch_cost(
  p_company_id UUID,p_document_id UUID,p_financial_event_id UUID
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE
  v_source public.inventory_cost_adjustment_sources%ROWTYPE;
  v_plan public.supplier_invoice_batch_cost_allocations%ROWTYPE;
  v_batch public.product_batches%ROWTYPE;
  v_remaining_qty NUMERIC(24,6);
  v_sold_qty NUMERIC(24,6);
  v_inventory_variance NUMERIC(20,4);
  v_hpp_variance NUMERIC(20,4);
  v_total_inventory NUMERIC(20,4):=0;
  v_total_hpp NUMERIC(20,4):=0;
  v_new_cogs NUMERIC(24,10);
  v_now TIMESTAMPTZ:=clock_timestamp();
BEGIN
  SELECT * INTO v_source FROM public.inventory_cost_adjustment_sources source
  WHERE source.company_id=p_company_id
    AND source.adjustment_type='SUPPLIER_INVOICE_REVALUATION'
    AND source.source_document_id=p_document_id
    AND source.source_financial_event_id=p_financial_event_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'NSC_COST_ADJUSTMENT_SOURCE_NOT_FOUND'; END IF;
  IF v_source.status IN('APPLIED','POSTED') THEN
    RETURN jsonb_build_object('sourceId',v_source.id,
      'inventoryVariance',v_source.inventory_variance,
      'hppVariance',v_source.hpp_variance,'idempotentReplay',TRUE);
  END IF;
  IF v_source.status<>'PLANNED' THEN
    RAISE EXCEPTION 'NSC_COST_ADJUSTMENT_STATUS_INVALID';
  END IF;

  FOR v_plan IN
    SELECT * FROM public.supplier_invoice_batch_cost_allocations plan
    WHERE plan.company_id=p_company_id AND plan.document_id=p_document_id
      AND plan.application_status='PLANNED'
    ORDER BY plan.created_at,plan.id FOR UPDATE
  LOOP
    SELECT * INTO v_batch FROM public.product_batches batch
    WHERE batch.company_id=p_company_id AND batch.id=v_plan.product_batch_id
    FOR UPDATE;
    IF NOT FOUND OR v_batch.qty_purchased<=0 OR v_batch.qty_remaining<0
      OR v_batch.qty_remaining>v_batch.qty_purchased THEN
      RAISE EXCEPTION 'NSC_PRODUCT_BATCH_STATE_INVALID';
    END IF;
    v_remaining_qty:=round(v_plan.allocated_base_qty
      *v_batch.qty_remaining/v_batch.qty_purchased,6);
    v_sold_qty:=v_plan.allocated_base_qty-v_remaining_qty;
    v_inventory_variance:=round(v_plan.price_variance_total
      *v_batch.qty_remaining/v_batch.qty_purchased,4);
    v_hpp_variance:=v_plan.price_variance_total-v_inventory_variance;
    v_new_cogs:=round(v_batch.cogs_unit
      +v_plan.price_variance_total/v_batch.qty_purchased,10);

    UPDATE public.product_batches batch SET cogs_unit=v_new_cogs
    WHERE batch.company_id=p_company_id AND batch.id=v_batch.id;
    UPDATE public.supplier_invoice_batch_cost_allocations plan SET
      remaining_base_qty_snapshot=v_remaining_qty,
      sold_base_qty_snapshot=v_sold_qty,
      inventory_variance=v_inventory_variance,
      hpp_variance=v_hpp_variance,
      previous_cogs_unit=round(v_batch.cogs_unit,10),
      revalued_cogs_unit=v_new_cogs,
      application_status='APPLIED',
      applied_financial_event_id=p_financial_event_id,applied_at=v_now
    WHERE plan.company_id=p_company_id AND plan.id=v_plan.id;
    v_total_inventory:=v_total_inventory+v_inventory_variance;
    v_total_hpp:=v_total_hpp+v_hpp_variance;
  END LOOP;

  IF round(v_total_inventory+v_total_hpp,4)
    <>round(v_source.planned_cost_variance,4) THEN
    RAISE EXCEPTION 'NSC_COST_VARIANCE_SPLIT_MISMATCH';
  END IF;
  UPDATE public.inventory_cost_adjustment_sources source SET
    inventory_variance=round(v_total_inventory,4),
    hpp_variance=round(v_total_hpp,4),status='APPLIED',applied_at=v_now,
    master_version=source.master_version+1,updated_at=v_now
  WHERE source.company_id=p_company_id AND source.id=v_source.id;
  UPDATE public.financial_events event SET amounts=event.amounts
    ||jsonb_build_object(
      'inventoryPurchasePriceVariance',round(v_total_inventory,4),
      'hppPurchasePriceVariance',round(v_total_hpp,4))
  WHERE event.company_id=p_company_id AND event.id=p_financial_event_id
    AND event.status='HOLD'::public.event_status;
  RETURN jsonb_build_object('sourceId',v_source.id,
    'inventoryVariance',round(v_total_inventory,4),
    'hppVariance',round(v_total_hpp,4),'idempotentReplay',FALSE);
END
$$;

CREATE FUNCTION private.trg_nsc_supplier_invoice_cost_plan()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
BEGIN
  IF OLD.status IN('DRAFT','HOLD') AND NEW.status='VALIDATED' THEN
    PERFORM private.nsc_plan_supplier_invoice_batch_cost(
      NEW.company_id,NEW.id,NEW.financial_event_id,NEW.validated_by);
  END IF;
  RETURN NEW;
END
$$;

CREATE TRIGGER nsc_supplier_invoice_cost_plan
AFTER UPDATE OF status ON public.supplier_invoice_documents
FOR EACH ROW EXECUTE FUNCTION private.trg_nsc_supplier_invoice_cost_plan();

CREATE FUNCTION private.trg_nsc_goods_receipt_cost_source()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
  v_quantity NUMERIC(24,6);
  v_variance NUMERIC(20,4);
  v_inventory_account UUID;
  v_cogs_account UUID;
  v_source_id UUID;
BEGIN
  IF NEW.system_event_key<>'GOODS_RECEIPT'
    OR NEW.source_table<>'goods_receipt_documents'
    OR NEW.status<>'HOLD'::public.event_status THEN RETURN NEW; END IF;
  SELECT COALESCE(sum(replenishment.replenished_base_qty),0),
    round(COALESCE(sum(replenishment.cost_variance_total),0),4)
    INTO v_quantity,v_variance
  FROM public.negative_stock_replenishment_allocations replenishment
  JOIN public.product_batches batch
    ON batch.company_id=replenishment.company_id
   AND batch.id=replenishment.product_batch_id
  JOIN public.goods_receipt_lines receipt_line
    ON receipt_line.company_id=batch.company_id
   AND receipt_line.id=batch.goods_receipt_line_id
  WHERE receipt_line.company_id=NEW.company_id
    AND receipt_line.document_id=NEW.source_id
    AND replenishment.cost_variance_total<>0;
  IF v_quantity=0 THEN RETURN NEW; END IF;
  v_inventory_account:=NULLIF(NEW.amounts->>'inventoryAccountId','')::UUID;
  v_cogs_account:=private.resolve_opening_stock_account(
    NEW.company_id,NEW.transaction_category_id,'COGS',NEW.event_date);
  INSERT INTO public.inventory_cost_adjustment_sources(
    company_id,adjustment_type,source_document_table,source_document_id,
    source_financial_event_id,total_quantity_base,planned_cost_variance,
    inventory_variance,hpp_variance,inventory_account_id,offset_account_id,
    status,idempotency_key,created_by,applied_at
  ) VALUES(
    NEW.company_id,'NEGATIVE_REPLENISHMENT','goods_receipt_documents',
    NEW.source_id,NEW.id,v_quantity,v_variance,-v_variance,v_variance,
    v_inventory_account,v_cogs_account,'APPLIED',
    'NSC_NEGATIVE_REPLENISHMENT|'||NEW.company_id::TEXT||'|'
      ||NEW.source_id::TEXT,NEW.created_by,clock_timestamp()
  ) RETURNING id INTO v_source_id;
  UPDATE public.financial_events event SET amounts=event.amounts
    ||jsonb_build_object('negativeStockCostSettlementVersion',1,
      'inventoryCostAdjustmentSourceId',v_source_id,
      'negativeStockCostVariance',v_variance,
      'negativeStockCogsAccountId',v_cogs_account)
  WHERE event.company_id=NEW.company_id AND event.id=NEW.id;
  RETURN NEW;
END
$$;

CREATE TRIGGER nsc_goods_receipt_cost_source
AFTER INSERT ON public.financial_events
FOR EACH ROW EXECUTE FUNCTION private.trg_nsc_goods_receipt_cost_source();

CREATE FUNCTION private.trg_nsc_replace_supplier_invoice_variance_line()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
BEGIN
  IF NEW.description='PURCHASE_PRICE_VARIANCE_AND_NONRECOVERABLE_TAX'
    AND EXISTS(
      SELECT 1 FROM public.finance_journals journal
      JOIN public.inventory_cost_adjustment_sources source
        ON source.company_id=journal.company_id
       AND source.source_financial_event_id=journal.financial_event_id
       AND source.adjustment_type='SUPPLIER_INVOICE_REVALUATION'
      WHERE journal.company_id=NEW.company_id AND journal.id=NEW.journal_id
    ) THEN RETURN NULL; END IF;
  RETURN NEW;
END
$$;

CREATE TRIGGER nsc_replace_supplier_invoice_variance_line
BEFORE INSERT ON public.finance_journal_lines
FOR EACH ROW EXECUTE FUNCTION
  private.trg_nsc_replace_supplier_invoice_variance_line();

CREATE FUNCTION private.nsc_insert_signed_journal_line(
  p_company_id UUID,p_journal_id UUID,p_line_no INTEGER,p_account_id UUID,
  p_amount NUMERIC,p_store_id UUID,p_warehouse_id UUID,p_supplier_id UUID,
  p_description TEXT
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
BEGIN
  IF round(COALESCE(p_amount,0),4)=0 THEN RETURN; END IF;
  INSERT INTO public.finance_journal_lines(
    company_id,journal_id,line_no,account_id,debit,credit,store_id,
    warehouse_id,supplier_id,description
  ) VALUES(
    p_company_id,p_journal_id,p_line_no,p_account_id,
    CASE WHEN p_amount>0 THEN round(p_amount,4) ELSE 0 END,
    CASE WHEN p_amount<0 THEN abs(round(p_amount,4)) ELSE 0 END,
    p_store_id,p_warehouse_id,p_supplier_id,p_description
  );
END
$$;

CREATE FUNCTION private.trg_nsc_cost_adjustment_journal_lines()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
  v_journal public.finance_journals%ROWTYPE;
  v_source public.inventory_cost_adjustment_sources%ROWTYPE;
  v_result JSONB;
  v_inventory NUMERIC(20,4);
  v_hpp NUMERIC(20,4);
  v_nonrecoverable NUMERIC(20,4):=0;
  v_supplier UUID;
BEGIN
  SELECT * INTO v_journal FROM public.finance_journals journal
  WHERE journal.company_id=NEW.company_id AND journal.id=NEW.journal_id;
  IF NOT FOUND OR v_journal.financial_event_id IS NULL THEN RETURN NEW; END IF;
  SELECT * INTO v_source FROM public.inventory_cost_adjustment_sources source
  WHERE source.company_id=NEW.company_id
    AND source.source_financial_event_id=v_journal.financial_event_id;
  IF NOT FOUND THEN RETURN NEW; END IF;

  IF v_source.adjustment_type='NEGATIVE_REPLENISHMENT'
    AND NEW.description='SUPPLIER_AP_PROVISIONAL'
    AND NOT EXISTS(SELECT 1 FROM public.finance_journal_lines line
      WHERE line.company_id=NEW.company_id AND line.journal_id=NEW.journal_id
        AND line.line_no IN(900001,900002,900003)) THEN
    SELECT order_document.supplier_id INTO v_supplier
    FROM public.goods_receipt_documents receipt
    JOIN public.supplier_order_documents order_document
      ON order_document.company_id=receipt.company_id
     AND order_document.id=receipt.supplier_order_id
    WHERE receipt.company_id=NEW.company_id
      AND receipt.id=v_source.source_document_id;
    PERFORM private.nsc_insert_signed_journal_line(NEW.company_id,
      NEW.journal_id,900001,v_source.inventory_account_id,
      v_source.inventory_variance,v_journal.store_id,v_journal.warehouse_id,
      v_supplier,'NEGATIVE_REPLENISHMENT_INVENTORY_VARIANCE');
    PERFORM private.nsc_insert_signed_journal_line(NEW.company_id,
      NEW.journal_id,900002,v_source.offset_account_id,
      v_source.hpp_variance,v_journal.store_id,v_journal.warehouse_id,
      v_supplier,'NEGATIVE_REPLENISHMENT_COGS_VARIANCE');

  ELSIF v_source.adjustment_type='SUPPLIER_INVOICE_REVALUATION'
    AND NEW.description='SUPPLIER_AP_FINAL'
    AND NOT EXISTS(SELECT 1 FROM public.finance_journal_lines line
      WHERE line.company_id=NEW.company_id AND line.journal_id=NEW.journal_id
        AND line.line_no IN(900001,900002,900003)) THEN
    v_result:=private.nsc_apply_supplier_invoice_batch_cost(
      NEW.company_id,v_source.source_document_id,v_journal.financial_event_id);
    v_inventory:=(v_result->>'inventoryVariance')::NUMERIC;
    v_hpp:=(v_result->>'hppVariance')::NUMERIC;
    SELECT document.supplier_id INTO v_supplier
    FROM public.supplier_invoice_documents document
    WHERE document.company_id=NEW.company_id
      AND document.id=v_source.source_document_id;
    SELECT COALESCE((event.amounts->>'nonrecoverablePurchaseTax')::NUMERIC,0)
      INTO v_nonrecoverable
    FROM public.financial_events event
    WHERE event.company_id=NEW.company_id
      AND event.id=v_journal.financial_event_id;
    PERFORM private.nsc_insert_signed_journal_line(NEW.company_id,
      NEW.journal_id,900001,v_source.inventory_account_id,v_inventory,
      v_journal.store_id,v_journal.warehouse_id,v_supplier,
      'SUPPLIER_INVOICE_INVENTORY_REVALUATION');
    PERFORM private.nsc_insert_signed_journal_line(NEW.company_id,
      NEW.journal_id,900002,v_source.offset_account_id,v_hpp,
      v_journal.store_id,v_journal.warehouse_id,v_supplier,
      'SUPPLIER_INVOICE_HPP_VARIANCE');
    PERFORM private.nsc_insert_signed_journal_line(NEW.company_id,
      NEW.journal_id,900003,v_source.variance_account_id,v_nonrecoverable,
      v_journal.store_id,v_journal.warehouse_id,v_supplier,
      'SUPPLIER_INVOICE_NONRECOVERABLE_TAX');
  END IF;
  RETURN NEW;
END
$$;

CREATE TRIGGER nsc_cost_adjustment_journal_lines
AFTER INSERT ON public.finance_journal_lines
FOR EACH ROW EXECUTE FUNCTION private.trg_nsc_cost_adjustment_journal_lines();

CREATE FUNCTION private.trg_nsc_cost_source_posted()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
BEGIN
  IF OLD.status='HOLD'::public.event_status
    AND NEW.status='POSTED'::public.event_status THEN
    UPDATE public.inventory_cost_adjustment_sources source SET
      status='POSTED',posted_at=COALESCE(NEW.processed_at,clock_timestamp()),
      master_version=source.master_version+1,updated_at=clock_timestamp()
    WHERE source.company_id=NEW.company_id
      AND source.source_financial_event_id=NEW.id
      AND source.status='APPLIED';
  END IF;
  RETURN NEW;
END
$$;

CREATE TRIGGER nsc_cost_source_posted
AFTER UPDATE OF status ON public.financial_events
FOR EACH ROW EXECUTE FUNCTION private.trg_nsc_cost_source_posted();

-- Plan existing HOLD invoices only. The NSC-0 preflight guarantees that
-- POSTED invoices with non-zero variance do not exist on this rollout.
DO $plan_existing$
DECLARE v_invoice RECORD;
BEGIN
  FOR v_invoice IN
    SELECT invoice.company_id,invoice.id,invoice.financial_event_id,
      invoice.validated_by
    FROM public.supplier_invoice_documents invoice
    JOIN public.financial_events event
      ON event.company_id=invoice.company_id
     AND event.id=invoice.financial_event_id
    WHERE invoice.status='VALIDATED'
      AND event.status='HOLD'::public.event_status
      AND EXISTS(SELECT 1 FROM public.supplier_invoice_allocations allocation
        WHERE allocation.company_id=invoice.company_id
          AND allocation.document_id=invoice.id
          AND allocation.price_variance<>0)
    ORDER BY invoice.company_id,invoice.id
  LOOP
    PERFORM private.nsc_plan_supplier_invoice_batch_cost(
      v_invoice.company_id,v_invoice.id,v_invoice.financial_event_id,
      v_invoice.validated_by);
  END LOOP;
END
$plan_existing$;

REVOKE ALL ON FUNCTION
  private.nsc_previous_purchase_ap_financial_event_core(UUID,UUID,BIGINT,UUID),
  private.post_purchase_ap_financial_event_core(UUID,UUID,BIGINT,UUID),
  private.nsc_plan_supplier_invoice_batch_cost(UUID,UUID,UUID,UUID),
  private.nsc_apply_supplier_invoice_batch_cost(UUID,UUID,UUID),
  private.trg_nsc_supplier_invoice_cost_plan(),
  private.trg_nsc_goods_receipt_cost_source(),
  private.trg_nsc_replace_supplier_invoice_variance_line(),
  private.nsc_insert_signed_journal_line(UUID,UUID,INTEGER,UUID,NUMERIC,
    UUID,UUID,UUID,TEXT),
  private.trg_nsc_cost_adjustment_journal_lines(),
  private.trg_nsc_cost_source_posted()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.nsc_previous_purchase_ap_financial_event_core(UUID,UUID,BIGINT,UUID),
  private.post_purchase_ap_financial_event_core(UUID,UUID,BIGINT,UUID),
  private.nsc_plan_supplier_invoice_batch_cost(UUID,UUID,UUID,UUID),
  private.nsc_apply_supplier_invoice_batch_cost(UUID,UUID,UUID),
  private.trg_nsc_supplier_invoice_cost_plan(),
  private.trg_nsc_goods_receipt_cost_source(),
  private.trg_nsc_replace_supplier_invoice_variance_line(),
  private.nsc_insert_signed_journal_line(UUID,UUID,INTEGER,UUID,NUMERIC,
    UUID,UUID,UUID,TEXT),
  private.trg_nsc_cost_adjustment_journal_lines(),
  private.trg_nsc_cost_source_posted()
TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260831130000','negative_stock_fifo_finance_cost_runtime',
  'Atomic Goods Receipt negative-cost settlement and Supplier Invoice FIFO Inventory/HPP variance split integrated with canonical Finance posting');

COMMIT;
