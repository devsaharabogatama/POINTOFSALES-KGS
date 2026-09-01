-- NSC-2/3 runtime postflight. SAFETY: SELECT-only.

WITH required_routines(signature) AS (
  VALUES
    ('private.nsc_previous_purchase_ap_financial_event_core(uuid,uuid,bigint,uuid)'::TEXT),
    ('private.post_purchase_ap_financial_event_core(uuid,uuid,bigint,uuid)'::TEXT),
    ('private.nsc_plan_supplier_invoice_batch_cost(uuid,uuid,uuid,uuid)'::TEXT),
    ('private.nsc_apply_supplier_invoice_batch_cost(uuid,uuid,uuid)'::TEXT),
    ('private.trg_nsc_supplier_invoice_cost_plan()'::TEXT),
    ('private.trg_nsc_goods_receipt_cost_source()'::TEXT),
    ('private.trg_nsc_replace_supplier_invoice_variance_line()'::TEXT),
    ('private.nsc_insert_signed_journal_line(uuid,uuid,integer,uuid,numeric,uuid,uuid,uuid,text)'::TEXT),
    ('private.trg_nsc_cost_adjustment_journal_lines()'::TEXT),
    ('private.trg_nsc_cost_source_posted()'::TEXT)
), routine_state AS (
  SELECT count(*)::BIGINT routine_rows
  FROM required_routines required
  WHERE to_regprocedure(required.signature) IS NOT NULL
), trigger_state AS (
  SELECT count(*)::BIGINT trigger_rows
  FROM pg_trigger trigger_state
  WHERE NOT trigger_state.tgisinternal
    AND trigger_state.tgname IN(
      'nsc_supplier_invoice_cost_plan','nsc_goods_receipt_cost_source',
      'nsc_replace_supplier_invoice_variance_line',
      'nsc_cost_adjustment_journal_lines','nsc_cost_source_posted')
), checks AS (
  SELECT 'migration_ledger' check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    CASE WHEN count(*)=1 THEN 0 ELSE 1 END::BIGINT violation_rows,
    jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations
  WHERE version='20260831130000'

  UNION ALL
  SELECT 'required_nsc_runtime_routines',
    CASE WHEN routine_state.routine_rows=10 THEN 'PASS' ELSE 'FAIL' END,
    10-routine_state.routine_rows,
    jsonb_build_object('expected',10,'routineRows',routine_state.routine_rows)
  FROM routine_state

  UNION ALL
  SELECT 'required_nsc_runtime_triggers',
    CASE WHEN trigger_state.trigger_rows=5 THEN 'PASS' ELSE 'FAIL' END,
    5-trigger_state.trigger_rows,
    jsonb_build_object('expected',5,'triggerRows',trigger_state.trigger_rows)
  FROM trigger_state

  UNION ALL
  SELECT 'private_nsc_runtime_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('authenticatedExecutableRows',count(*))
  FROM information_schema.routine_privileges privilege
  WHERE privilege.specific_schema='private'
    AND privilege.grantee IN('anon','authenticated')
    AND (privilege.routine_name LIKE 'nsc_%'
      OR privilege.routine_name='post_purchase_ap_financial_event_core')
    AND privilege.privilege_type='EXECUTE'

  UNION ALL
  SELECT 'zero_value_negative_receipt_runtime_contract',
    CASE WHEN pg_get_functiondef(
      'private.post_purchase_ap_financial_event_core(uuid,uuid,bigint,uuid)'
        ::regprocedure) LIKE '%negativeStockCostSettlement%'
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN pg_get_functiondef(
      'private.post_purchase_ap_financial_event_core(uuid,uuid,bigint,uuid)'
        ::regprocedure) LIKE '%negativeStockCostSettlement%'
      THEN 0 ELSE 1 END,
    jsonb_build_object('routineRows',1)

  UNION ALL
  SELECT 'supplier_invoice_batch_plan_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('allocationRows',count(*))
  FROM (
    SELECT allocation.company_id,allocation.id
    FROM public.supplier_invoice_allocations allocation
    JOIN public.supplier_invoice_documents document
      ON document.company_id=allocation.company_id
     AND document.id=allocation.document_id AND document.status='VALIDATED'
    JOIN public.financial_events event
      ON event.company_id=document.company_id
     AND event.id=document.financial_event_id
    WHERE allocation.price_variance<>0 AND event.status='HOLD'::public.event_status
    GROUP BY allocation.company_id,allocation.id,allocation.allocated_base_qty
    HAVING COALESCE((SELECT sum(plan.allocated_base_qty)
      FROM public.supplier_invoice_batch_cost_allocations plan
      WHERE plan.company_id=allocation.company_id
        AND plan.supplier_invoice_allocation_id=allocation.id),0)
      <>allocation.allocated_base_qty
  ) invalid

  UNION ALL
  SELECT 'applied_batch_cost_split_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('planRows',count(*))
  FROM public.supplier_invoice_batch_cost_allocations plan
  WHERE plan.application_status='APPLIED'
    AND (plan.inventory_variance+plan.hpp_variance<>plan.price_variance_total
      OR plan.remaining_base_qty_snapshot+plan.sold_base_qty_snapshot
        <>plan.allocated_base_qty)

  UNION ALL
  SELECT 'cost_adjustment_source_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('sourceRows',count(*))
  FROM public.inventory_cost_adjustment_sources source
  WHERE source.status IN('APPLIED','POSTED') AND (
    (source.adjustment_type='NEGATIVE_REPLENISHMENT'
      AND (source.inventory_variance+source.hpp_variance<>0
        OR source.hpp_variance<>source.planned_cost_variance))
    OR (source.adjustment_type='SUPPLIER_INVOICE_REVALUATION'
      AND source.inventory_variance+source.hpp_variance
        <>source.planned_cost_variance))

  UNION ALL
  SELECT 'posted_cost_adjustment_journal_coverage',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('sourceRows',count(*))
  FROM public.inventory_cost_adjustment_sources source
  WHERE source.status='POSTED' AND NOT EXISTS(
    SELECT 1 FROM public.finance_journals journal
    JOIN public.finance_journal_lines line
      ON line.company_id=journal.company_id AND line.journal_id=journal.id
    WHERE journal.company_id=source.company_id
      AND journal.financial_event_id=source.source_financial_event_id
      AND journal.status='POSTED'
      AND line.description IN(
        'NEGATIVE_REPLENISHMENT_INVENTORY_VARIANCE',
        'NEGATIVE_REPLENISHMENT_COGS_VARIANCE',
        'SUPPLIER_INVOICE_INVENTORY_REVALUATION',
        'SUPPLIER_INVOICE_HPP_VARIANCE',
        'SUPPLIER_INVOICE_NONRECOVERABLE_TAX'))

  UNION ALL
  SELECT 'posted_cost_adjustment_journal_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('sourceRows',count(*))
  FROM public.inventory_cost_adjustment_sources source
  JOIN public.financial_events event
    ON event.company_id=source.company_id
   AND event.id=source.source_financial_event_id
  JOIN public.finance_journals journal
    ON journal.company_id=source.company_id
   AND journal.financial_event_id=source.source_financial_event_id
   AND journal.status='POSTED'
  WHERE source.status='POSTED' AND (
    COALESCE((SELECT sum(line.debit-line.credit)
      FROM public.finance_journal_lines line
      WHERE line.company_id=journal.company_id
        AND line.journal_id=journal.id
        AND line.account_id=source.inventory_account_id
        AND line.description IN(
          'NEGATIVE_REPLENISHMENT_INVENTORY_VARIANCE',
          'SUPPLIER_INVOICE_INVENTORY_REVALUATION')),0)
      <>source.inventory_variance
    OR COALESCE((SELECT sum(line.debit-line.credit)
      FROM public.finance_journal_lines line
      WHERE line.company_id=journal.company_id
        AND line.journal_id=journal.id
        AND line.account_id=source.offset_account_id
        AND line.description IN(
          'NEGATIVE_REPLENISHMENT_COGS_VARIANCE',
          'SUPPLIER_INVOICE_HPP_VARIANCE')),0)<>source.hpp_variance
    OR (source.adjustment_type='SUPPLIER_INVOICE_REVALUATION'
      AND COALESCE((SELECT sum(line.debit-line.credit)
        FROM public.finance_journal_lines line
        WHERE line.company_id=journal.company_id
          AND line.journal_id=journal.id
          AND line.account_id=source.variance_account_id
          AND line.description='SUPPLIER_INVOICE_NONRECOVERABLE_TAX'),0)
        <>COALESCE((event.amounts->>'nonrecoverablePurchaseTax')::NUMERIC,0)))

  UNION ALL
  SELECT 'open_negative_replenishment_source_coverage',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('receiptRows',count(*))
  FROM (
    SELECT receipt.company_id,receipt.id
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
    WHERE replenishment.cost_variance_total<>0
    GROUP BY receipt.company_id,receipt.id
    HAVING NOT EXISTS(SELECT 1
      FROM public.inventory_cost_adjustment_sources source
      WHERE source.company_id=receipt.company_id
        AND source.adjustment_type='NEGATIVE_REPLENISHMENT'
        AND source.source_document_id=receipt.id)
  ) invalid

  UNION ALL
  SELECT 'nsc_runtime_inventory','INFO',0,
    jsonb_build_object(
      'openNegativeAllocations',(SELECT count(*)
        FROM public.negative_stock_sale_allocations allocation
        WHERE allocation.reconciled_at IS NULL),
      'costSources',(SELECT count(*)
        FROM public.inventory_cost_adjustment_sources),
      'plannedBatchCosts',(SELECT count(*)
        FROM public.supplier_invoice_batch_cost_allocations plan
        WHERE plan.application_status='PLANNED'),
      'appliedBatchCosts',(SELECT count(*)
        FROM public.supplier_invoice_batch_cost_allocations plan
        WHERE plan.application_status='APPLIED'))
)
SELECT check_name,status,violation_rows,details
FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,
  check_name;
