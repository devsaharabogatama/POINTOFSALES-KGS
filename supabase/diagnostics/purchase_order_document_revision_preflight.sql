-- SELECT-only preflight for 20260914170000.
WITH checks AS (
  SELECT 'revision_dependency_ledger' check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END status,
    abs(1-count(*))::bigint violation_rows,
    jsonb_build_object('requiredVersion','20260914160000','ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260914160000'
  UNION ALL
  SELECT 'revision_schema_collision',
    CASE WHEN to_regclass('public.purchase_supplier_order_revision_operations') IS NULL
      AND to_regprocedure('public.revise_purchase_supplier_order(uuid,bigint,uuid,uuid,date,text,jsonb)') IS NULL
      AND to_regprocedure('private.revise_purchase_supplier_order_core(uuid,uuid,bigint,uuid,uuid,date,text,jsonb)') IS NULL
      THEN 'PASS' ELSE 'BLOCKER' END,
    (CASE WHEN to_regclass('public.purchase_supplier_order_revision_operations') IS NULL THEN 0 ELSE 1 END
      +CASE WHEN to_regprocedure('public.revise_purchase_supplier_order(uuid,bigint,uuid,uuid,date,text,jsonb)') IS NULL THEN 0 ELSE 1 END
      +CASE WHEN to_regprocedure('private.revise_purchase_supplier_order_core(uuid,uuid,bigint,uuid,uuid,date,text,jsonb)') IS NULL THEN 0 ELSE 1 END)::bigint,
    jsonb_build_object('migrationApplied',EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260914170000'))
  UNION ALL
  SELECT 'revision_active_finance_queue',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('runRows',count(*))
  FROM public.finance_posting_queue_runs WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'revision_nonterminal_offline',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('submissionRows',count(*))
  FROM public.pos_offline_sale_submissions WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
  UNION ALL
  SELECT 'revision_open_cutover',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('planRows',count(*))
  FROM public.sales_process_cutover_plans WHERE status IN('DRAFT','PREVIEWED','APPLYING')
  UNION ALL
  SELECT 'revision_line_guard_contract',
    CASE WHEN pg_get_functiondef('private.trg_g5_guard_order_line_mutation()'::regprocedure)
      ~ 'FINAL_SUPPLIER_ORDER_LINES_IMMUTABLE' THEN 'PASS' ELSE 'BLOCKER' END,0,
    jsonb_build_object('guardPresent',true)
  UNION ALL
  SELECT 'revision_development_fixture',CASE WHEN count(*)>=1 THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN count(*)>=1 THEN 0 ELSE 1 END,
    jsonb_build_object('eligibleConfirmedDailyPo',count(*),
      'orderNumbers',COALESCE(jsonb_agg(document.order_no ORDER BY document.order_no),'[]'))
  FROM public.supplier_order_documents document
  WHERE document.company_id='d290f1ee-6c54-4b01-90e6-d701748f0851'::uuid
    AND document.order_source='DAILY_REPLENISHMENT' AND document.status='CONFIRMED'
    AND NOT EXISTS(SELECT 1 FROM public.goods_receipt_documents receipt
      WHERE receipt.company_id=document.company_id AND receipt.supplier_order_id=document.id
        AND receipt.status<>'CANCELED')
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 0 ELSE 1 END,check_name;
