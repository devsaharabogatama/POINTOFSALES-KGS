-- SELECT-only preflight for Backoffice AR reversal consumer parity.
WITH required(version) AS (VALUES
  ('20261105100000'),('20261105110000'),('20261105120000'),
  ('20261106100000'),('20261110100000'),('20261110150000')
), dependency AS (
  SELECT array_agg(required.version ORDER BY required.version)
      FILTER (WHERE migration.version IS NULL) missing,
    array_agg(required.version ORDER BY required.version)
      FILTER (WHERE migration.version IS NOT NULL) installed
  FROM required LEFT JOIN private.kgs_schema_migrations migration USING(version)
), runtime AS (
  SELECT to_regprocedure(
      'private.ar4_backoffice_invoice_allocated_credit(uuid,uuid,date)') helper,
    to_regprocedure('private.ar5_item_allocated(uuid,uuid,date)') reversal_helper
), definitions AS (
  SELECT md5(pg_get_functiondef(helper)) helper_md5,
    md5(pg_get_functiondef(reversal_helper)) reversal_helper_md5,
    pg_get_functiondef(helper) ILIKE '%reversal_of_allocation_id%' reversal_aware
  FROM runtime
), consumers AS (
  SELECT count(*)::bigint rows,
    array_agg(routine.oid::regprocedure::text ORDER BY routine.oid::regprocedure::text)
      AS routines
  FROM pg_proc routine JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
  WHERE routine.prokind='f' AND namespace.nspname IN('public','private')
    AND pg_get_functiondef(routine.oid)
      ILIKE '%ar4_backoffice_invoice_allocated_credit%'
), allocation_inventory AS (
  SELECT count(*) FILTER(WHERE allocation.reversal_of_allocation_id IS NULL)::bigint
      active_rows,
    count(*) FILTER(WHERE allocation.reversal_of_allocation_id IS NOT NULL)::bigint
      reversal_rows
  FROM public.ar_open_item_allocations allocation
  JOIN public.ar_open_item_registry debit ON debit.company_id=allocation.company_id
    AND debit.id=allocation.debit_item_id AND debit.item_kind='INVOICE'
  JOIN public.ar_open_item_registry credit ON credit.company_id=allocation.company_id
    AND credit.id=allocation.credit_item_id AND credit.item_kind='CREDIT_NOTE'
), mismatch AS (
  SELECT count(*)::bigint rows
  FROM public.ar_open_item_registry debit
  WHERE debit.scope_kind='BACKOFFICE' AND debit.item_kind='INVOICE'
    AND debit.direction='DEBIT'
    AND private.ar4_backoffice_invoice_allocated_credit(
      debit.company_id,debit.source_id,NULL)<>(SELECT round(COALESCE(sum(CASE
        WHEN allocation.reversal_of_allocation_id IS NULL
          THEN allocation.allocated_amount ELSE -allocation.allocated_amount END),0),4)
      FROM public.ar_open_item_allocations allocation
      JOIN public.ar_open_item_registry credit ON credit.company_id=allocation.company_id
        AND credit.id=allocation.credit_item_id AND credit.scope_kind='BACKOFFICE'
        AND credit.item_kind='CREDIT_NOTE' AND credit.direction='CREDIT'
      WHERE allocation.company_id=debit.company_id
        AND allocation.debit_item_id=debit.id)
), boundary AS (
  SELECT (SELECT count(*) FROM public.finance_posting_queue_runs
      WHERE status IN('PREVIEWED','APPROVED','PROCESSING'))::bigint active_finance_queue,
    (SELECT count(*) FROM public.pos_offline_sale_submissions
      WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION'))::bigint nonterminal_offline
), checks AS (
  SELECT 'backoffice_ar_reversal_parity_preflight_dependency_ledger' check_name,
    CASE WHEN dependency.missing IS NULL THEN 'PASS' ELSE 'FAIL' END status,
    COALESCE(cardinality(dependency.missing),0) violation_rows,to_jsonb(dependency) details
  FROM dependency
  UNION ALL
  SELECT 'backoffice_ar_reversal_parity_preflight_installation_state',
    CASE WHEN NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20261110130000') THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20261110130000') THEN 1 ELSE 0 END,
    jsonb_build_object('classification',CASE WHEN EXISTS(SELECT 1
      FROM private.kgs_schema_migrations WHERE version='20261110130000')
      THEN 'INSTALLED' ELSE 'NOT_INSTALLED' END)
  UNION ALL
  SELECT 'backoffice_ar_reversal_parity_preflight_runtime_anchors',
    CASE WHEN definitions.helper_md5='97600ce6d46ae08b7df414c271fe46aa'
      AND definitions.reversal_helper_md5='3de3fd3ba6aa98e79db22ef32f1bd0da'
      AND NOT definitions.reversal_aware AND consumers.rows=7 THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN definitions.helper_md5='97600ce6d46ae08b7df414c271fe46aa'
      AND definitions.reversal_helper_md5='3de3fd3ba6aa98e79db22ef32f1bd0da'
      AND NOT definitions.reversal_aware AND consumers.rows=7 THEN 0 ELSE 1 END,
    to_jsonb(definitions)||to_jsonb(consumers) FROM definitions CROSS JOIN consumers
  UNION ALL
  SELECT 'backoffice_ar_reversal_parity_preflight_allocation_inventory','INFO',0,
    to_jsonb(allocation_inventory)||jsonb_build_object('mismatchedInvoiceItems',mismatch.rows)
  FROM allocation_inventory CROSS JOIN mismatch
  UNION ALL
  SELECT 'backoffice_ar_reversal_parity_preflight_runtime_boundary',
    CASE WHEN boundary.active_finance_queue=0 AND boundary.nonterminal_offline=0
      THEN 'PASS' ELSE 'FAIL' END,
    boundary.active_finance_queue+boundary.nonterminal_offline,to_jsonb(boundary) FROM boundary
  UNION ALL
  SELECT 'backoffice_ar_reversal_parity_preflight_business_boundary','INFO',0,
    jsonb_build_object('mutation','NONE','changed',jsonb_build_array(
      'Credit Note allocation reversal visibility in shared Backoffice AR consumers'),
      'preserved',jsonb_build_array('Receipt allocations','Customer Balance','Cash/Bank refund',
      'Posted Journals','POS Retail','Stock/Reservation/FIFO/HPP'))
)
SELECT check_name,status,violation_rows,details FROM checks ORDER BY check_name;
