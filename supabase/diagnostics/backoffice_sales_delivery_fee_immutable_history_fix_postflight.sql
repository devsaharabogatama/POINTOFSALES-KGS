-- SELECT-only verification for 20260910151000.
WITH definitions AS (
  SELECT pg_get_functiondef(to_regprocedure(
      'private.save_backoffice_sales_invoice_draft_core(uuid,bigint,uuid,uuid,jsonb)')) core_definition,
    pg_get_functiondef(to_regprocedure(
      'private.trg_backoffice_sales_invoice_delivery_fee()')) trigger_definition
), checks AS (
  SELECT 'migration_ledger'::text check_name,CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(1-count(*))::bigint violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260910151000'
  UNION ALL
  SELECT 'immutable_history_write_boundary',
    CASE WHEN position('UPDATE public.backoffice_sales_invoice_audit' in core_definition)=0
      AND position('UPDATE public.backoffice_sales_invoice_operations' in core_definition)=0
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN position('UPDATE public.backoffice_sales_invoice_audit' in core_definition)=0
      AND position('UPDATE public.backoffice_sales_invoice_operations' in core_definition)=0
      THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('auditUpdatePresent',
      position('UPDATE public.backoffice_sales_invoice_audit' in core_definition)>0,
      'operationUpdatePresent',
      position('UPDATE public.backoffice_sales_invoice_operations' in core_definition)>0)
  FROM definitions
  UNION ALL
  SELECT 'pre_core_delivery_fee_contract',
    CASE WHEN position('kgs.backoffice_invoice_delivery_fee_amount' in core_definition)>0
      AND position('kgs.backoffice_invoice_delivery_fee_amount' in trigger_definition)>0
      AND position($needle$set_config('kgs.backoffice_invoice_delivery_fee_amount','',true)$needle$
        in core_definition)>0
      AND position('BACKOFFICE_INVOICE_DELIVERY_FEE_NOT_ALLOWED_ON_DP' in core_definition)>0
      AND position('BACKOFFICE_INVOICE_DELIVERY_FEE_EXCEEDS_ORDER' in trigger_definition)>0
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN position('kgs.backoffice_invoice_delivery_fee_amount' in core_definition)>0
      AND position('kgs.backoffice_invoice_delivery_fee_amount' in trigger_definition)>0
      AND position($needle$set_config('kgs.backoffice_invoice_delivery_fee_amount','',true)$needle$
        in core_definition)>0
      AND position('BACKOFFICE_INVOICE_DELIVERY_FEE_NOT_ALLOWED_ON_DP' in core_definition)>0
      AND position('BACKOFFICE_INVOICE_DELIVERY_FEE_EXCEEDS_ORDER' in trigger_definition)>0
      THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('coreUsesTransactionLocalFee',
      position('kgs.backoffice_invoice_delivery_fee_amount' in core_definition)>0,
      'triggerUsesTransactionLocalFee',
      position('kgs.backoffice_invoice_delivery_fee_amount' in trigger_definition)>0,
      'coreClearsTransactionLocalFee',
      position($needle$set_config('kgs.backoffice_invoice_delivery_fee_amount','',true)$needle$
        in core_definition)>0)
  FROM definitions
  UNION ALL
  SELECT 'immutable_audit_trigger_contract',CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    abs(1-count(*))::bigint,jsonb_build_object('triggerRows',count(*))
  FROM pg_trigger trigger_state
  WHERE trigger_state.tgrelid='public.backoffice_sales_invoice_audit'::regclass
    AND trigger_state.tgname='backoffice_sales_invoice_audit_immutable'
    AND NOT trigger_state.tgisinternal AND trigger_state.tgenabled<>'D'
  UNION ALL
  SELECT 'private_runtime_boundary',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('browserExecutableRows',count(*))
  FROM information_schema.routine_privileges privilege
  WHERE privilege.specific_schema='private' AND privilege.grantee IN('anon','authenticated')
    AND privilege.routine_name IN('save_backoffice_sales_invoice_draft_core',
      'trg_backoffice_sales_invoice_delivery_fee')
  UNION ALL
  SELECT 'invoice_operation_audit_reconciliation',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('invalidRows',count(*))
  FROM public.backoffice_sales_invoice_operations operation
  LEFT JOIN public.backoffice_sales_invoice_audit audit
    ON audit.company_id=operation.company_id AND audit.operation_id=operation.operation_id
  WHERE operation.operation_type='SAVE_DRAFT'
    AND (audit.id IS NULL OR audit.after_state IS DISTINCT FROM operation.response_snapshot->'data')
  UNION ALL
  SELECT 'delivery_fee_runtime_inventory','INFO',0::bigint,jsonb_build_object(
    'ordersWithFee',(SELECT count(*) FROM public.backoffice_sales_orders
      WHERE delivery_fee_amount>0),
    'invoicesWithFee',(SELECT count(*) FROM public.backoffice_sales_invoices
      WHERE delivery_fee_amount>0),
    'saveAudits',(SELECT count(*) FROM public.backoffice_sales_invoice_audit
      WHERE action IN('CREATE_DRAFT','UPDATE_DRAFT')))
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;
