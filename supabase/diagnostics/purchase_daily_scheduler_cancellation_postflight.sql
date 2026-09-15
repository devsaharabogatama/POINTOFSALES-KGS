-- SELECT-only postflight for Purchase Daily Replenishment Step 6/6B.
WITH ledger AS (
  SELECT count(*) rows FROM private.kgs_schema_migrations
  WHERE version='20260914140000'
), routines AS (
  SELECT count(*) present FROM (VALUES
    (to_regprocedure('private.purchase_supplier_order_net_received_base_qty(uuid,uuid)')),
    (to_regprocedure('private.cancel_purchase_daily_batch_core(uuid,uuid,bigint,uuid,uuid,text)')),
    (to_regprocedure('public.cancel_purchase_daily_auto_ro(uuid,bigint,uuid,text)')),
    (to_regprocedure('private.cancel_purchase_supplier_order_core(uuid,uuid,bigint,uuid,uuid,text)')),
    (to_regprocedure('public.cancel_purchase_supplier_order(uuid,bigint,uuid,text)')),
    (to_regprocedure('private.run_purchase_daily_replenishment_scheduler(timestamptz)'))
  ) required(routine) WHERE routine IS NOT NULL
), scheduler_definition AS (
  SELECT pg_get_functiondef(to_regprocedure(
    'private.run_purchase_daily_replenishment_scheduler(timestamptz)')) body
), cancel_definition AS (
  SELECT pg_get_functiondef(to_regprocedure(
    'private.cancel_purchase_supplier_order_core(uuid,uuid,bigint,uuid,uuid,text)')) body
), net_definition AS (
  SELECT pg_get_functiondef(to_regprocedure(
    'private.purchase_supplier_order_net_received_base_qty(uuid,uuid)')) body
), date_identity AS (
  SELECT
    pg_get_functiondef(to_regprocedure(
      'private.generate_purchase_daily_auto_ro_core(uuid,date,uuid,uuid,timestamptz)')) ro_body,
    pg_get_functiondef(to_regprocedure(
      'private.generate_purchase_daily_auto_po_core(uuid,date,uuid,uuid,timestamptz)')) po_body
), invalid_canceled_orders AS (
  SELECT count(*) rows FROM public.supplier_order_documents document
  WHERE document.status='CANCELED'
    AND private.purchase_supplier_order_net_received_base_qty(
      document.company_id,document.id)<>0
), invalid_scheduler_rows AS (
  SELECT count(*) rows FROM public.purchase_daily_scheduler_runs run
  WHERE run.execution_actor<>'SYSTEM_AUTOMATION'
    OR run.actor_display_name<>'Sistem Otomatis'
    OR run.technical_sponsor_id IS NULL
    OR (run.status IN('GENERATED','NO_DEMAND')
      AND (run.result_snapshot IS NULL OR run.error_code IS NOT NULL))
    OR (run.status='FAILED' AND run.error_code IS NULL)
), invalid_scheduler_attempts AS (
  SELECT count(*) rows FROM public.purchase_daily_scheduler_attempts attempt
  WHERE attempt.execution_actor<>'SYSTEM_AUTOMATION'
    OR attempt.actor_display_name<>'Sistem Otomatis'
    OR attempt.technical_sponsor_id IS NULL
    OR (attempt.status IN('GENERATED','NO_DEMAND','REUSED')
      AND (attempt.result_snapshot IS NULL OR attempt.error_code IS NOT NULL))
    OR (attempt.status='FAILED' AND attempt.error_code IS NULL)
), attempt_history_trigger AS (
  SELECT count(*) rows FROM pg_trigger catalog_trigger
  WHERE catalog_trigger.tgrelid='public.purchase_daily_scheduler_attempts'::regclass
    AND catalog_trigger.tgname='guard_purchase_daily_scheduler_attempts'
    AND NOT catalog_trigger.tgisinternal
), checks AS (
  SELECT 'migration_ledger' check_name,CASE WHEN rows=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(1-rows) violation_rows,jsonb_build_object('ledgerRows',rows) details FROM ledger
  UNION ALL
  SELECT 'scheduler_cancel_required_routines',CASE WHEN present=6 THEN 'PASS' ELSE 'FAIL' END,
    6-present,jsonb_build_object('expected',6,'present',present) FROM routines
  UNION ALL
  SELECT 'scheduler_cron_registration',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,abs(1-count(*)),
    jsonb_build_object('jobs',count(*),'schedule',max(schedule),'active',bool_and(active))
  FROM cron.job WHERE jobname='kgs-purchase-daily-replenishment'
  UNION ALL
  SELECT 'scheduler_system_identity_contract',
    CASE WHEN body ~ 'SYSTEM_AUTOMATION' AND body ~ 'Sistem Otomatis'
      AND body ~ 'generate_purchase_daily_auto_ro_core'
      AND body ~ 'generate_purchase_daily_auto_po_core'
      AND body ~ 'cutoff_local_time' THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN body ~ 'SYSTEM_AUTOMATION' AND body ~ 'Sistem Otomatis'
      AND body ~ 'generate_purchase_daily_auto_ro_core'
      AND body ~ 'generate_purchase_daily_auto_po_core'
      AND body ~ 'cutoff_local_time' THEN 0 ELSE 1 END,
    jsonb_build_object('systemActor',body ~ 'SYSTEM_AUTOMATION',
      'autoRo',body ~ 'generate_purchase_daily_auto_ro_core',
      'autoPo',body ~ 'generate_purchase_daily_auto_po_core',
      'cutoff',body ~ 'cutoff_local_time') FROM scheduler_definition
  UNION ALL
  SELECT 'supplier_order_return_before_cancel_contract',
    CASE WHEN cancel_definition.body ~ 'SUPPLIER_ORDER_RETURN_REQUIRED_BEFORE_CANCEL'
      AND net_definition.body ~ 'accepted_good_base_qty'
      AND net_definition.body ~ 'damaged_base_qty'
      AND net_definition.body ~ 'purchase_return_documents'
      AND net_definition.body ~ 'status[[:space:]]*=[[:space:]]*''POSTED''' THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN cancel_definition.body ~ 'SUPPLIER_ORDER_RETURN_REQUIRED_BEFORE_CANCEL'
      AND net_definition.body ~ 'accepted_good_base_qty'
      AND net_definition.body ~ 'damaged_base_qty'
      AND net_definition.body ~ 'purchase_return_documents'
      AND net_definition.body ~ 'status[[:space:]]*=[[:space:]]*''POSTED''' THEN 0 ELSE 1 END,
    jsonb_build_object('postedReceiptMinusPostedReturn',true,
      'stockBearingReceiptOnly',true) FROM cancel_definition CROSS JOIN net_definition
  UNION ALL
  SELECT 'canceled_supplier_order_net_receipt_reconciliation',
    CASE WHEN rows=0 THEN 'PASS' ELSE 'FAIL' END,rows,
    jsonb_build_object('invalidOrders',rows) FROM invalid_canceled_orders
  UNION ALL
  SELECT 'scheduler_run_shape',CASE WHEN rows=0 THEN 'PASS' ELSE 'FAIL' END,rows,
    jsonb_build_object('invalidRows',rows) FROM invalid_scheduler_rows
  UNION ALL
  SELECT 'scheduler_attempt_append_only_shape',
    CASE WHEN invalid.rows=0 AND guard.rows=1 THEN 'PASS' ELSE 'FAIL' END,
    invalid.rows+abs(1-guard.rows),
    jsonb_build_object('invalidRows',invalid.rows,'immutableTriggers',guard.rows)
  FROM invalid_scheduler_attempts invalid CROSS JOIN attempt_history_trigger guard
  UNION ALL
  SELECT 'scheduler_document_date_identity',
    CASE WHEN position('RO-''||to_char(p_business_date,''YYYYMMDD'')' in ro_body)>0
      AND position('POB-''||to_char(p_business_date,''YYYYMMDD'')' in po_body)>0
      AND position('PO-''||to_char(p_business_date,''YYYYMMDD'')' in po_body)>0
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN position('RO-''||to_char(p_business_date,''YYYYMMDD'')' in ro_body)>0
      AND position('POB-''||to_char(p_business_date,''YYYYMMDD'')' in po_body)>0
      AND position('PO-''||to_char(p_business_date,''YYYYMMDD'')' in po_body)>0
      THEN 0 ELSE 1 END,
    jsonb_build_object('roFormat','RO-YYYYMMDD-*','autoPoBatchFormat','POB-YYYYMMDD-*',
      'poFormat','PO-YYYYMMDD-*') FROM date_identity
  UNION ALL
  SELECT 'scheduler_cancel_private_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('authenticatedExecutableRows',count(*))
  FROM information_schema.routine_privileges privilege
  WHERE privilege.grantee IN('anon','authenticated') AND privilege.privilege_type='EXECUTE'
    AND privilege.specific_schema='private'
    AND privilege.routine_name IN('run_purchase_daily_replenishment_scheduler',
      'cancel_purchase_daily_batch_core','cancel_purchase_supplier_order_core',
      'purchase_supplier_order_net_received_base_qty')
  UNION ALL
  SELECT 'scheduler_cancel_public_boundary',
    CASE WHEN has_function_privilege('authenticated',
      'public.cancel_purchase_daily_auto_ro(uuid,bigint,uuid,text)','EXECUTE')
      AND has_function_privilege('authenticated',
      'public.cancel_purchase_supplier_order(uuid,bigint,uuid,text)','EXECUTE')
      AND NOT has_function_privilege('anon',
      'public.cancel_purchase_daily_auto_ro(uuid,bigint,uuid,text)','EXECUTE')
      AND NOT has_function_privilege('anon',
      'public.cancel_purchase_supplier_order(uuid,bigint,uuid,text)','EXECUTE')
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN has_function_privilege('authenticated',
      'public.cancel_purchase_daily_auto_ro(uuid,bigint,uuid,text)','EXECUTE')
      AND has_function_privilege('authenticated',
      'public.cancel_purchase_supplier_order(uuid,bigint,uuid,text)','EXECUTE')
      AND NOT has_function_privilege('anon',
      'public.cancel_purchase_daily_auto_ro(uuid,bigint,uuid,text)','EXECUTE')
      AND NOT has_function_privilege('anon',
      'public.cancel_purchase_supplier_order(uuid,bigint,uuid,text)','EXECUTE')
      THEN 0 ELSE 1 END,jsonb_build_object('authenticated',true,'anon',false)
  UNION ALL
  SELECT 'scheduler_runtime_inventory','INFO',0,jsonb_build_object(
    'runs',(SELECT count(*) FROM public.purchase_daily_scheduler_runs),
    'attempts',(SELECT count(*) FROM public.purchase_daily_scheduler_attempts),
    'generated',(SELECT count(*) FROM public.purchase_daily_scheduler_runs
      WHERE status='GENERATED'),
    'failed',(SELECT count(*) FROM public.purchase_daily_scheduler_runs
      WHERE status='FAILED'),
    'cancelOperations',(SELECT count(*) FROM public.purchase_supplier_order_cancel_operations))
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;
