-- SELECT-only postflight for Backoffice AR Task 5.
WITH
ledger AS (
  SELECT count(*)::bigint rows FROM private.kgs_schema_migrations
  WHERE version='20261106100000'
),
runtime AS (
  SELECT
    to_regprocedure('public.apply_backoffice_ar_open_credit(uuid,jsonb,date,numeric,uuid)') IS NOT NULL apply_rpc,
    to_regprocedure('public.refund_backoffice_ar_open_credit(uuid,numeric,date,uuid,text,text,text,numeric,uuid)') IS NOT NULL refund_rpc,
    to_regprocedure('public.convert_backoffice_ar_open_credit_to_customer_balance(uuid,numeric,date,text,numeric,uuid)') IS NOT NULL convert_rpc,
    to_regprocedure('public.apply_customer_balance_to_backoffice_invoice(uuid,numeric,date,text,numeric,numeric,uuid)') IS NOT NULL balance_use_rpc,
    to_regprocedure('public.reverse_backoffice_ar_open_credit_action(uuid,date,text,uuid)') IS NOT NULL reverse_rpc,
    to_regprocedure('private.ar5_item_allocated(uuid,uuid,date)') IS NOT NULL residual_helper
),
schema_contract AS (
  SELECT
    EXISTS(SELECT 1 FROM information_schema.columns col
      WHERE col.table_schema='public' AND col.table_name='ar_open_item_allocations'
        AND col.column_name='effective_date' AND col.data_type='date') effective_date,
    COALESCE((SELECT pg_get_constraintdef(con.oid)
      FROM pg_constraint con JOIN pg_class relation ON relation.oid=con.conrelid
      JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
      WHERE namespace.nspname='public' AND relation.relname='ar_open_item_allocations'
        AND con.conname='ar_open_item_allocations_shape'),'') allocation_shape,
    COALESCE((SELECT pg_get_constraintdef(con.oid)
      FROM pg_constraint con JOIN pg_class relation ON relation.oid=con.conrelid
      JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
      WHERE namespace.nspname='public' AND relation.relname='customer_balance_ledger_entries'
        AND con.conname='customer_balance_ledger_source_check'),'') balance_source_shape
),
integrity AS (
  SELECT count(*)::bigint invalid_rows
  FROM public.ar_open_item_registry item
  WHERE item.original_amount-private.ar5_item_allocated(item.company_id,item.id,NULL)<0
     OR item.original_amount-private.ar5_item_allocated(item.company_id,item.id,NULL)>item.original_amount
),
privilege_contract AS (
  SELECT
    has_function_privilege('authenticated',
      'public.apply_backoffice_ar_open_credit(uuid,jsonb,date,numeric,uuid)','EXECUTE') apply_execute,
    has_function_privilege('authenticated',
      'public.reverse_backoffice_ar_open_credit_action(uuid,date,text,uuid)','EXECUTE') reverse_execute,
    has_table_privilege('authenticated','public.ar_open_item_operations','SELECT') direct_operation_select
),
checks AS (
  SELECT 'backoffice_ar_open_credit_actions_postflight_migration_ledger' check_name,
    CASE WHEN ledger.rows=1 THEN 'PASS' ELSE 'FAIL' END status,
    CASE WHEN ledger.rows=1 THEN 0 ELSE 1 END violation_rows,
    jsonb_build_object('ledgerRows',ledger.rows) details FROM ledger
  UNION ALL
  SELECT 'backoffice_ar_open_credit_actions_postflight_runtime_contract',
    CASE WHEN runtime.apply_rpc AND runtime.refund_rpc AND runtime.convert_rpc
      AND runtime.balance_use_rpc AND runtime.reverse_rpc AND runtime.residual_helper
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN runtime.apply_rpc AND runtime.refund_rpc AND runtime.convert_rpc
      AND runtime.balance_use_rpc AND runtime.reverse_rpc AND runtime.residual_helper
      THEN 0 ELSE 1 END,to_jsonb(runtime) FROM runtime
  UNION ALL
  SELECT 'backoffice_ar_open_credit_actions_postflight_schema_contract',
    CASE WHEN schema_contract.effective_date
      AND schema_contract.allocation_shape LIKE '%ALLOCATION_REVERSAL%'
      AND schema_contract.balance_source_shape LIKE '%OPEN_CREDIT_CONVERSION%'
      AND schema_contract.balance_source_shape LIKE '%BACKOFFICE_INVOICE_PAYMENT%'
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN schema_contract.effective_date
      AND schema_contract.allocation_shape LIKE '%ALLOCATION_REVERSAL%'
      AND schema_contract.balance_source_shape LIKE '%OPEN_CREDIT_CONVERSION%'
      AND schema_contract.balance_source_shape LIKE '%BACKOFFICE_INVOICE_PAYMENT%'
      THEN 0 ELSE 1 END,to_jsonb(schema_contract) FROM schema_contract
  UNION ALL
  SELECT 'backoffice_ar_open_credit_actions_postflight_residual_integrity',
    CASE WHEN integrity.invalid_rows=0 THEN 'PASS' ELSE 'FAIL' END,
    integrity.invalid_rows,jsonb_build_object('invalidRows',integrity.invalid_rows) FROM integrity
  UNION ALL
  SELECT 'backoffice_ar_open_credit_actions_postflight_privilege_contract',
    CASE WHEN privilege_contract.apply_execute AND privilege_contract.reverse_execute
      AND NOT privilege_contract.direct_operation_select THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN privilege_contract.apply_execute AND privilege_contract.reverse_execute
      AND NOT privilege_contract.direct_operation_select THEN 0 ELSE 1 END,
    to_jsonb(privilege_contract) FROM privilege_contract
  UNION ALL
  SELECT 'backoffice_ar_open_credit_actions_postflight_business_boundary','INFO',0,
    jsonb_build_object('changed',jsonb_build_array('Backoffice AR open-credit direct allocation',
      'AR-native Cash/Bank refund','explicit Customer Balance conversion',
      'Customer Balance settlement after Invoice Posted','append-only reversal'),
      'preserved',jsonb_build_array('POS Retail','Backoffice SO/dispatch/initial Invoice posting',
      'legacy Refund Liability','Stock/Reservation/FIFO/HPP','historical Posted rows'),
      'next','Run rollback-only behavior before client deployment')
)
SELECT check_name,status,violation_rows,details FROM checks ORDER BY check_name;
