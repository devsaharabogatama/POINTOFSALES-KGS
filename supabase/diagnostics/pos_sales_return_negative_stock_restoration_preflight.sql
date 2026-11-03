-- SELECT-only preflight for negative-stock Sales Return restoration.
WITH dependency(version) AS (VALUES
  ('20260805190000'),('20260805220000'),('20260831130000'),
  ('20260911140000'),('20260919143000'),('20261102100000'),('20261102110000')
), installed AS (
  SELECT dependency.version,
    EXISTS(SELECT 1 FROM private.kgs_schema_migrations ledger
      WHERE ledger.version=dependency.version) installed
  FROM dependency
), core_state AS (
  SELECT pg_get_functiondef(
    'private.acp5h_post_sales_return_core(uuid,bigint,uuid)'::regprocedure
  ) definition
), trigger_state AS (
  SELECT pg_get_functiondef(
    'private.reconcile_negative_stock_replenishment()'::regprocedure
  ) definition
), lineage_constraint AS (
  SELECT pg_get_constraintdef(constraint_row.oid,true) definition
  FROM pg_constraint constraint_row
  JOIN pg_class relation ON relation.oid=constraint_row.conrelid
  JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
  WHERE namespace.nspname='public' AND relation.relname='product_batches'
    AND constraint_row.conname='product_batches_source_lineage_check'
), returnable AS (
  SELECT sale.company_id,sale.id sales_id,sale.invoice_no,
    detail.id sales_detail_id,detail.product_id,
    private.odr6d_returnable_sales_detail_quantity(
      detail.company_id,detail.id) returnable_quantity,
    COALESCE((SELECT sum(line.quantity_uom)
      FROM public.sales_return_lines line
      JOIN public.sales_return_documents document
        ON document.company_id=line.company_id AND document.id=line.document_id
       AND document.status='POSTED'
      WHERE line.company_id=detail.company_id
        AND line.source_sales_detail_id=detail.id),0) posted_return_quantity
  FROM public.sales_headers sale
  JOIN public.sales_details detail ON detail.company_id=sale.company_id
    AND detail.sales_id=sale.id
  WHERE sale.sales_origin='POS'
    AND sale.sales_process_mode='RETAIL_CONFIRM_INVOICE'
    AND (sale.document_status='POSTED' OR EXISTS(
      SELECT 1 FROM public.sales_dispatch_allocations dispatch
      JOIN public.sales_stock_reservation_lines reservation
        ON reservation.company_id=dispatch.company_id
       AND reservation.id=dispatch.reservation_line_id
      WHERE dispatch.company_id=sale.company_id
        AND reservation.sales_id=sale.id))
), negative_candidates AS (
  SELECT returnable.*,requirement.id requirement_id,
    requirement.stock_product_id,negative.id negative_allocation_id,
    negative.warehouse_id,negative.shortage_base_qty,
    negative.replenished_base_qty,
    negative.provisional_unit_cost,
    COALESCE((SELECT sum(fifo.quantity_base)
      FROM public.sale_fifo_allocations fifo
      WHERE fifo.company_id=requirement.company_id
        AND fifo.stock_requirement_id=requirement.id),0) positive_fifo_base,
    greatest(returnable.returnable_quantity-
      returnable.posted_return_quantity,0) visible_remaining_quantity,
    EXISTS(SELECT 1 FROM public.negative_stock_sale_allocations other
      WHERE other.company_id=negative.company_id
        AND other.stock_product_id=negative.stock_product_id
        AND other.warehouse_id=negative.warehouse_id
        AND other.id<>negative.id AND other.reconciled_at IS NULL) collision
  FROM returnable
  JOIN public.sale_stock_requirements requirement
    ON requirement.company_id=returnable.company_id
   AND requirement.sales_id=returnable.sales_id
   AND requirement.sales_detail_id=returnable.sales_detail_id
  JOIN public.negative_stock_sale_allocations negative
    ON negative.company_id=requirement.company_id
   AND negative.stock_requirement_id=requirement.id
  WHERE returnable.returnable_quantity>returnable.posted_return_quantity
), exact_invoice AS (
  SELECT * FROM negative_candidates
  WHERE invoice_no='INV-20261101-0000000951'
)
SELECT 'pos_return_negative_stock_preflight_dependency_ledger' check_name,
  CASE WHEN bool_and(installed) THEN 'PASS' ELSE 'BLOCKER' END status,
  count(*) FILTER(WHERE NOT installed) violation_rows,
  jsonb_build_object('required',jsonb_agg(version ORDER BY version),
    'missing',COALESCE(jsonb_agg(version ORDER BY version)
      FILTER(WHERE NOT installed),'[]'::jsonb)) details
FROM installed
UNION ALL
SELECT 'pos_return_negative_stock_preflight_installation_state',
  CASE WHEN NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20261102120000')
      AND NOT EXISTS(SELECT 1 FROM information_schema.columns
        WHERE table_schema='public' AND table_name='product_batches'
          AND column_name='sales_return_negative_allocation_id')
    THEN 'PASS' ELSE 'BLOCKER' END,
  (CASE WHEN EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20261102120000') THEN 1 ELSE 0 END
   +CASE WHEN EXISTS(SELECT 1 FROM information_schema.columns
      WHERE table_schema='public' AND table_name='product_batches'
        AND column_name='sales_return_negative_allocation_id') THEN 1 ELSE 0 END),
  jsonb_build_object(
    'classification',CASE
      WHEN EXISTS(SELECT 1 FROM private.kgs_schema_migrations
        WHERE version='20261102120000') THEN 'INSTALLED_OR_PARTIAL'
      WHEN EXISTS(SELECT 1 FROM information_schema.columns
        WHERE table_schema='public' AND table_name='product_batches'
          AND column_name='sales_return_negative_allocation_id') THEN 'PARTIAL_INCONSISTENT'
      ELSE 'NOT_INSTALLED' END)
UNION ALL
SELECT 'pos_return_negative_stock_preflight_runtime_anchors',
  CASE WHEN core.definition LIKE '%SOURCE_SALE_FIFO_RESTORATION_EXHAUSTED%'
      AND core.definition LIKE '%odr6d_returnable_sales_detail_quantity%'
      AND trigger.definition LIKE '%negative_stock_sale_allocations%'
      AND trigger.definition LIKE '%backoffice_negative_stock_allocations%'
      AND trigger.definition LIKE '%purchase_return_stock_shortages%'
      AND constraint_state.definition LIKE '%sales_return_line_id IS NOT NULL%'
    THEN 'PASS' ELSE 'BLOCKER' END,
  CASE WHEN core.definition LIKE '%SOURCE_SALE_FIFO_RESTORATION_EXHAUSTED%'
      AND core.definition LIKE '%odr6d_returnable_sales_detail_quantity%'
      AND trigger.definition LIKE '%negative_stock_sale_allocations%'
      AND trigger.definition LIKE '%backoffice_negative_stock_allocations%'
      AND trigger.definition LIKE '%purchase_return_stock_shortages%'
      AND constraint_state.definition LIKE '%sales_return_line_id IS NOT NULL%'
    THEN 0 ELSE 1 END,
  jsonb_build_object('returnCoreMd5',md5(core.definition),
    'replenishmentTriggerMd5',md5(trigger.definition),
    'lineageConstraint',constraint_state.definition,
    'returnCoreNegativeAware',core.definition LIKE
      '%sales_return_negative_allocation_id%',
    'triggerReturnTargetAware',trigger.definition LIKE
      '%sales_return_negative_allocation_id%')
FROM core_state core CROSS JOIN trigger_state trigger
CROSS JOIN lineage_constraint constraint_state
UNION ALL
SELECT 'pos_return_negative_stock_preflight_exact_invoice',
  CASE WHEN count(*)=1
      AND bool_and(shortage_base_qty=5 AND replenished_base_qty=0
        AND positive_fifo_base=0 AND visible_remaining_quantity=5)
    THEN 'PASS' ELSE 'BLOCKER' END,
  CASE WHEN count(*)=1
      AND bool_and(shortage_base_qty=5 AND replenished_base_qty=0
        AND positive_fifo_base=0 AND visible_remaining_quantity=5)
    THEN 0 ELSE 1 END,
  jsonb_build_object('rows',count(*),'requirements',COALESCE(jsonb_agg(
    jsonb_build_object('companyId',company_id,'salesId',sales_id,
      'salesDetailId',sales_detail_id,'requirementId',requirement_id,
      'negativeAllocationId',negative_allocation_id,
      'visibleRemainingQuantity',visible_remaining_quantity,
      'positiveFifoBase',positive_fifo_base,'shortageBase',shortage_base_qty,
      'replenishedBase',replenished_base_qty,'collision',collision)
  ),'[]'::jsonb))
FROM exact_invoice
UNION ALL
SELECT 'pos_return_negative_stock_preflight_candidate_inventory','INFO',0,
  jsonb_build_object('rows',count(*),
    'unreplenished',count(*) FILTER(WHERE replenished_base_qty=0),
    'partiallyReplenished',count(*) FILTER(WHERE replenished_base_qty>0
      AND replenished_base_qty<shortage_base_qty),
    'fullyReplenished',count(*) FILTER(WHERE replenished_base_qty=shortage_base_qty),
    'mixedPositiveAndNegative',count(*) FILTER(WHERE positive_fifo_base>0),
    'collisionRows',count(*) FILTER(WHERE collision),
    'companies',COALESCE(jsonb_agg(DISTINCT company_id),'[]'::jsonb))
FROM negative_candidates
UNION ALL
SELECT 'pos_return_negative_stock_preflight_runtime_boundary',
  CASE WHEN NOT EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
      WHERE status IN('PREVIEWED','APPROVED','PROCESSING'))
      AND NOT EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
        WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION'))
    THEN 'PASS' ELSE 'BLOCKER' END,
  ((SELECT count(*) FROM public.finance_posting_queue_runs
      WHERE status IN('PREVIEWED','APPROVED','PROCESSING'))
   +(SELECT count(*) FROM public.pos_offline_sale_submissions
      WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION'))),
  jsonb_build_object(
    'activeFinanceQueue',(SELECT count(*) FROM public.finance_posting_queue_runs
      WHERE status IN('PREVIEWED','APPROVED','PROCESSING')),
    'nonterminalOffline',(SELECT count(*) FROM public.pos_offline_sale_submissions
      WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')))
UNION ALL
SELECT 'pos_return_negative_stock_preflight_business_boundary','INFO',0,
  jsonb_build_object('mutation','NONE','next',
    'Classify exact runtime digests and candidate/collision population before Phase B',
    'preserved',jsonb_build_array('positive FIFO Return','Backoffice approval',
      'refund methods','Finance posting','Goods Receipt','Purchase Return',
      'historical rows','other Companies'));
