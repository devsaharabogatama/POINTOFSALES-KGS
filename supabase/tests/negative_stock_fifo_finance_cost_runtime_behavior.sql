-- NSC runtime behavioral test.
-- All writes, including the temporary FIFO revaluation, are rolled back.

BEGIN;

DO $test$
DECLARE
  v_candidate RECORD;
  v_source UUID;
  v_plan UUID;
  v_inventory_account UUID;
  v_offset_account UUID;
  v_variance_account UUID;
  v_actor UUID;
  v_old_cogs NUMERIC;
  v_new_cogs NUMERIC;
  v_result JSONB;
  v_test_variance NUMERIC(20,4):=10;
  v_test_qty NUMERIC(24,6);
BEGIN
  SELECT invoice.company_id,invoice.id document_id,
    invoice.financial_event_id,invoice.validated_by,event.transaction_category_id,
    event.event_date,allocation.id allocation_id,allocation.receipt_line_id,
    batch.id batch_id,batch.qty_purchased,batch.cogs_unit
  INTO v_candidate
  FROM public.supplier_invoice_documents invoice
  JOIN public.financial_events event
    ON event.company_id=invoice.company_id
   AND event.id=invoice.financial_event_id
  JOIN public.supplier_invoice_allocations allocation
    ON allocation.company_id=invoice.company_id
   AND allocation.document_id=invoice.id
  JOIN public.product_batches batch
    ON batch.company_id=allocation.company_id
   AND batch.goods_receipt_line_id=allocation.receipt_line_id
  WHERE invoice.status='VALIDATED' AND batch.qty_purchased>0
    AND NOT EXISTS(SELECT 1
      FROM public.inventory_cost_adjustment_sources source
      WHERE source.company_id=invoice.company_id
        AND source.source_financial_event_id=invoice.financial_event_id)
  ORDER BY invoice.validated_at,invoice.id,allocation.id,batch.id
  LIMIT 1;
  IF v_candidate IS NULL THEN
    RAISE EXCEPTION
      'TEST_PRECONDITION_FAILED: validated Invoice receipt batch required';
  END IF;
  v_actor:=v_candidate.validated_by;
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: Invoice actor required';
  END IF;
  v_test_qty:=LEAST(1::NUMERIC,v_candidate.qty_purchased);
  v_inventory_account:=private.resolve_opening_stock_account(
    v_candidate.company_id,v_candidate.transaction_category_id,
    'INVENTORY_ASSET',v_candidate.event_date);
  v_offset_account:=private.resolve_opening_stock_account(
    v_candidate.company_id,v_candidate.transaction_category_id,
    'COGS',v_candidate.event_date);
  v_variance_account:=private.resolve_opening_stock_account(
    v_candidate.company_id,v_candidate.transaction_category_id,
    'PURCHASE_PRICE_VARIANCE',v_candidate.event_date);
  v_old_cogs:=v_candidate.cogs_unit;

  INSERT INTO public.inventory_cost_adjustment_sources(
    company_id,adjustment_type,source_document_table,source_document_id,
    source_financial_event_id,total_quantity_base,planned_cost_variance,
    inventory_account_id,offset_account_id,variance_account_id,status,
    idempotency_key,created_by
  ) VALUES(
    v_candidate.company_id,'SUPPLIER_INVOICE_REVALUATION',
    'supplier_invoice_documents',v_candidate.document_id,
    v_candidate.financial_event_id,v_test_qty,v_test_variance,
    v_inventory_account,v_offset_account,v_variance_account,'PLANNED',
    'NSC_BEHAVIOR|'||gen_random_uuid()::TEXT,v_actor
  ) RETURNING id INTO v_source;

  INSERT INTO public.supplier_invoice_batch_cost_allocations(
    company_id,document_id,supplier_invoice_allocation_id,receipt_line_id,
    product_batch_id,allocated_base_qty,price_variance_total
  ) VALUES(
    v_candidate.company_id,v_candidate.document_id,
    v_candidate.allocation_id,v_candidate.receipt_line_id,
    v_candidate.batch_id,v_test_qty,v_test_variance
  ) RETURNING id INTO v_plan;

  v_result:=private.nsc_apply_supplier_invoice_batch_cost(
    v_candidate.company_id,v_candidate.document_id,
    v_candidate.financial_event_id);
  SELECT batch.cogs_unit INTO v_new_cogs FROM public.product_batches batch
  WHERE batch.company_id=v_candidate.company_id AND batch.id=v_candidate.batch_id;

  IF v_new_cogs<=v_old_cogs
    OR round((v_result->>'inventoryVariance')::NUMERIC
      +(v_result->>'hppVariance')::NUMERIC,4)<>v_test_variance
    OR NOT EXISTS(SELECT 1
      FROM public.supplier_invoice_batch_cost_allocations plan
      WHERE plan.company_id=v_candidate.company_id AND plan.id=v_plan
        AND plan.application_status='APPLIED'
        AND plan.inventory_variance+plan.hpp_variance=v_test_variance
        AND plan.remaining_base_qty_snapshot+plan.sold_base_qty_snapshot
          =plan.allocated_base_qty)
    OR NOT EXISTS(SELECT 1
      FROM public.inventory_cost_adjustment_sources source
      WHERE source.company_id=v_candidate.company_id AND source.id=v_source
        AND source.status='APPLIED'
        AND source.inventory_variance+source.hpp_variance
          =source.planned_cost_variance)
  THEN
    RAISE EXCEPTION 'TEST_FAILED: NSC FIFO cost split invalid';
  END IF;

  -- Exact retry must return the applied result without changing FIFO again.
  v_result:=private.nsc_apply_supplier_invoice_batch_cost(
    v_candidate.company_id,v_candidate.document_id,
    v_candidate.financial_event_id);
  IF COALESCE((v_result->>'idempotentReplay')::BOOLEAN,FALSE) IS NOT TRUE
    OR (SELECT batch.cogs_unit FROM public.product_batches batch
      WHERE batch.company_id=v_candidate.company_id
        AND batch.id=v_candidate.batch_id)<>v_new_cogs THEN
    RAISE EXCEPTION 'TEST_FAILED: NSC exact retry invalid';
  END IF;

END
$test$;

SELECT 'supplier_invoice_fifo_cost_split_behavior' check_name,
  'PASS' status,
  jsonb_build_object('writesPersisted',FALSE,'exactRetry',TRUE,
    'transactionOutcome','ROLLBACK') details;

ROLLBACK;
