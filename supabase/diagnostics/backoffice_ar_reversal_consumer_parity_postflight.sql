-- SELECT-only postflight for Backoffice AR reversal consumer parity.
WITH ledger AS (
  SELECT count(*)::bigint rows FROM private.kgs_schema_migrations
  WHERE version='20261110130000'
), runtime AS (
  SELECT md5(pg_get_functiondef(
      'private.ar4_backoffice_invoice_allocated_credit(uuid,uuid,date)'::regprocedure))
      helper_md5,
    pg_get_functiondef(
      'private.ar4_backoffice_invoice_allocated_credit(uuid,uuid,date)'::regprocedure)
      ILIKE '%reversal_of_allocation_id%' reversal_aware,
    has_function_privilege('authenticated',
      'private.ar4_backoffice_invoice_allocated_credit(uuid,uuid,date)','EXECUTE')
      authenticated_execute
), parity AS (
  SELECT count(*)::bigint invalid
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
), reversal_inventory AS (
  SELECT count(*)::bigint rows FROM public.ar_open_item_allocations
  WHERE reversal_of_allocation_id IS NOT NULL
), checks AS (
  SELECT 'backoffice_ar_reversal_parity_postflight_migration_ledger' check_name,
    CASE WHEN ledger.rows=1 THEN 'PASS' ELSE 'FAIL' END status,
    CASE WHEN ledger.rows=1 THEN 0 ELSE 1 END violation_rows,
    jsonb_build_object('ledgerRows',ledger.rows) details FROM ledger
  UNION ALL
  SELECT 'backoffice_ar_reversal_parity_postflight_runtime_contract',
    CASE WHEN runtime.reversal_aware AND NOT runtime.authenticated_execute
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN runtime.reversal_aware AND NOT runtime.authenticated_execute THEN 0 ELSE 1 END,
    to_jsonb(runtime) FROM runtime
  UNION ALL
  SELECT 'backoffice_ar_reversal_parity_postflight_data_contract',
    CASE WHEN parity.invalid=0 THEN 'PASS' ELSE 'FAIL' END,parity.invalid,
    jsonb_build_object('invalidInvoiceItems',parity.invalid,
      'reversalRows',reversal_inventory.rows)
  FROM parity CROSS JOIN reversal_inventory
  UNION ALL
  SELECT 'backoffice_ar_reversal_parity_postflight_business_boundary','INFO',0,
    jsonb_build_object('changed',jsonb_build_array(
      'reversal-aware Backoffice Credit Note allocation consumers'),
      'preserved',jsonb_build_array('Receipt allocations','Customer Balance',
      'Cash/Bank refund','Posted Journals','POS Retail','Stock/Reservation/FIFO/HPP'),
      'next','Run rollback-only Task 5 behavior and authenticated browser smoke')
)
SELECT check_name,status,violation_rows,details FROM checks ORDER BY check_name;
