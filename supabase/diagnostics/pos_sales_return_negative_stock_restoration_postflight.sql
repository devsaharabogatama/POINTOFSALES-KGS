-- SELECT-only postflight for migration 20261102120000.
WITH core_state AS (
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
), exact_invoice AS (
  SELECT sale.id sales_id,detail.id sales_detail_id,
    negative.id negative_allocation_id,negative.shortage_base_qty,
    negative.replenished_base_qty,
    COALESCE((SELECT sum(restoration.quantity_base)
      FROM public.sales_return_negative_stock_restorations restoration
      WHERE restoration.company_id=negative.company_id
        AND restoration.source_negative_allocation_id=negative.id),0) restored_base
  FROM public.sales_headers sale
  JOIN public.sales_details detail ON detail.company_id=sale.company_id
    AND detail.sales_id=sale.id
  JOIN public.sale_stock_requirements requirement
    ON requirement.company_id=detail.company_id
   AND requirement.sales_detail_id=detail.id
  JOIN public.negative_stock_sale_allocations negative
    ON negative.company_id=requirement.company_id
   AND negative.stock_requirement_id=requirement.id
  WHERE sale.invoice_no='INV-20261101-0000000951'
)
SELECT 'pos_return_negative_stock_postflight_migration_ledger' check_name,
  CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
  abs(count(*)-1) violation_rows,
  jsonb_build_object('ledgerRows',count(*)) details
FROM private.kgs_schema_migrations WHERE version='20261102120000'
UNION ALL
SELECT 'pos_return_negative_stock_postflight_schema_contract',
  CASE WHEN to_regclass('public.sales_return_negative_stock_restorations') IS NOT NULL
      AND to_regprocedure(
        'private.restore_sales_return_negative_stock(uuid,uuid,uuid,uuid,uuid,timestamp with time zone,numeric)'
      ) IS NOT NULL
      AND EXISTS(SELECT 1 FROM information_schema.columns
        WHERE table_schema='public' AND table_name='product_batches'
          AND column_name='sales_return_negative_allocation_id')
    THEN 'PASS' ELSE 'FAIL' END,
  CASE WHEN to_regclass('public.sales_return_negative_stock_restorations') IS NOT NULL
      AND to_regprocedure(
        'private.restore_sales_return_negative_stock(uuid,uuid,uuid,uuid,uuid,timestamp with time zone,numeric)'
      ) IS NOT NULL
      AND EXISTS(SELECT 1 FROM information_schema.columns
        WHERE table_schema='public' AND table_name='product_batches'
          AND column_name='sales_return_negative_allocation_id')
    THEN 0 ELSE 1 END,
  jsonb_build_object('restorationTable',
      to_regclass('public.sales_return_negative_stock_restorations') IS NOT NULL,
    'helper',to_regprocedure(
      'private.restore_sales_return_negative_stock(uuid,uuid,uuid,uuid,uuid,timestamp with time zone,numeric)'
    ) IS NOT NULL,
    'batchLineage',EXISTS(SELECT 1 FROM information_schema.columns
      WHERE table_schema='public' AND table_name='product_batches'
        AND column_name='sales_return_negative_allocation_id'))
UNION ALL
SELECT 'pos_return_negative_stock_postflight_runtime_contract',
  CASE WHEN core.definition LIKE '%restore_sales_return_negative_stock%'
      AND core.definition NOT LIKE '%IF v_remaining<>0 THEN%SOURCE_SALE_FIFO_RESTORATION_EXHAUSTED%'
      AND trigger.definition LIKE '%RETURN_NEGATIVE_SOURCE_MISMATCH%'
      AND trigger.definition LIKE '%sales_return_negative_allocation_id%'
      AND constraint_state.definition LIKE '%sales_return_negative_allocation_id%'
    THEN 'PASS' ELSE 'FAIL' END,
  CASE WHEN core.definition LIKE '%restore_sales_return_negative_stock%'
      AND trigger.definition LIKE '%RETURN_NEGATIVE_SOURCE_MISMATCH%'
      AND constraint_state.definition LIKE '%sales_return_negative_allocation_id%'
    THEN 0 ELSE 1 END,
  jsonb_build_object('returnCoreNegativeAware',
      core.definition LIKE '%restore_sales_return_negative_stock%',
    'triggerExactTargetAware',trigger.definition LIKE '%RETURN_NEGATIVE_SOURCE_MISMATCH%',
    'lineageConstraint',constraint_state.definition)
FROM core_state core CROSS JOIN trigger_state trigger
CROSS JOIN lineage_constraint constraint_state
UNION ALL
SELECT 'pos_return_negative_stock_postflight_exact_invoice_unchanged',
  CASE WHEN count(*)=1 AND bool_and(shortage_base_qty=5
      AND replenished_base_qty=0 AND restored_base=0)
    THEN 'PASS' ELSE 'FAIL' END,
  CASE WHEN count(*)=1 AND bool_and(shortage_base_qty=5
      AND replenished_base_qty=0 AND restored_base=0)
    THEN 0 ELSE 1 END,
  jsonb_build_object('rows',count(*),'requirements',COALESCE(jsonb_agg(
    jsonb_build_object('salesId',sales_id,'salesDetailId',sales_detail_id,
      'negativeAllocationId',negative_allocation_id,'shortageBase',shortage_base_qty,
      'replenishedBase',replenished_base_qty,'restoredBase',restored_base)
  ),'[]'::jsonb))
FROM exact_invoice
UNION ALL
SELECT 'pos_return_negative_stock_postflight_business_boundary','INFO',0,
  jsonb_build_object('next','Run rollback-only authenticated behavior before real Return',
    'changed',jsonb_build_array('exact negative Sale source restoration',
      'negative Return batch lineage','combined positive/negative Return HPP'),
    'preserved',jsonb_build_array('positive FIFO Return','Backoffice approval',
      'refund methods','Finance posting','Goods Receipt','Purchase Return',
      'historical rows','other Companies'));
