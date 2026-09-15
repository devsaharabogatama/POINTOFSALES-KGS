-- SELECT-only verification for 20260914170000.
WITH checks AS (
  SELECT 'revision_migration_ledger' check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,abs(1-count(*))::bigint violation_rows,
    jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260914170000'
  UNION ALL
  SELECT 'revision_required_runtime',CASE WHEN count(*)=4 THEN 'PASS' ELSE 'FAIL' END,
    abs(4-count(*))::bigint,jsonb_build_object('present',count(*),'expected',4)
  FROM pg_proc procedure JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
  WHERE (namespace.nspname,procedure.proname) IN(
    ('public','revise_purchase_supplier_order'),
    ('private','revise_purchase_supplier_order_core'),
    ('private','purchase_supplier_order_document_snapshot'),
    ('public','get_purchase_supplier_orders'))
  UNION ALL
  SELECT 'revision_operation_history_boundary',
    CASE WHEN to_regclass('public.purchase_supplier_order_revision_operations') IS NOT NULL
      AND EXISTS(SELECT 1 FROM pg_trigger trigger
        WHERE trigger.tgrelid='public.purchase_supplier_order_revision_operations'::regclass
          AND trigger.tgname='guard_purchase_supplier_order_revision_operations')
      THEN 'PASS' ELSE 'FAIL' END,0,jsonb_build_object('immutableTrigger',true)
  UNION ALL
  SELECT 'revision_public_security_boundary',CASE WHEN procedure.prosecdef
      AND COALESCE(array_to_string(procedure.proconfig,','),'') LIKE '%search_path=public, pg_temp%'
      THEN 'PASS' ELSE 'FAIL' END,0,
    jsonb_build_object('securityDefiner',procedure.prosecdef,'config',procedure.proconfig)
  FROM pg_proc procedure WHERE procedure.oid=
    'public.revise_purchase_supplier_order(uuid,bigint,uuid,uuid,date,text,jsonb)'::regprocedure
  UNION ALL
  SELECT 'revision_reader_contract',CASE WHEN pg_get_functiondef(
      'public.get_purchase_supplier_orders()'::regprocedure) ~ 'supplierOrderListVersion'',3'
      AND pg_get_functiondef('public.get_purchase_supplier_orders()'::regprocedure)
        ~ 'supplierOrderActivity' THEN 'PASS' ELSE 'FAIL' END,0,
    jsonb_build_object('requiredVersion',3)
  UNION ALL
  SELECT 'revision_runtime_inventory','INFO',0,
    jsonb_build_object('eligibleUnreceivedConfirmedDailyPo',count(*),
      'orderNumbers',COALESCE(jsonb_agg(document.order_no ORDER BY document.order_no),'[]'))
  FROM public.supplier_order_documents document
  WHERE document.order_source='DAILY_REPLENISHMENT' AND document.status='CONFIRMED'
    AND NOT EXISTS(SELECT 1 FROM public.goods_receipt_documents receipt
      WHERE receipt.company_id=document.company_id AND receipt.supplier_order_id=document.id
        AND receipt.status<>'CANCELED')
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 0 ELSE 1 END,check_name;
