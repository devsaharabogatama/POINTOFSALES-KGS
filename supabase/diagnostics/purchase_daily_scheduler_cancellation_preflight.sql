-- SELECT-only preflight for Purchase Daily Replenishment Step 6/6B.
WITH dependency AS (
  SELECT count(*) present FROM private.kgs_schema_migrations
  WHERE version IN('20260913120000','20260913130000','20260914100000',
    '20260914110000','20260914111000','20260914112000','20260914130000')
), routine_contract AS (
  SELECT count(*) present FROM (VALUES
    (to_regprocedure('private.generate_purchase_daily_auto_ro_core(uuid,date,uuid,uuid,timestamptz)')),
    (to_regprocedure('private.generate_purchase_daily_auto_po_core(uuid,date,uuid,uuid,timestamptz)')),
    (to_regprocedure('private.purchase_daily_batch_snapshot(uuid,uuid)')),
    (to_regprocedure('private.g5_refresh_stock_request_order_status(uuid,uuid,uuid)')),
    (to_regprocedure('private.trg_g5_guard_supplier_order_history()')),
    (to_regprocedure('private.trg_guard_purchase_daily_batch()'))
  ) required(routine) WHERE routine IS NOT NULL
), relation_contract AS (
  SELECT count(*) present FROM (VALUES
    (to_regclass('public.company_purchase_replenishment_settings')),
    (to_regclass('public.purchase_daily_batches')),
    (to_regclass('public.purchase_daily_batch_lines')),
    (to_regclass('public.purchase_daily_batch_operations')),
    (to_regclass('public.purchase_daily_batch_audit')),
    (to_regclass('public.supplier_order_documents')),
    (to_regclass('public.goods_receipt_documents')),
    (to_regclass('public.purchase_return_documents'))
  ) required(relation) WHERE relation IS NOT NULL
), automatic_without_sponsor AS (
  SELECT count(*) rows FROM public.company_purchase_replenishment_settings setting
  JOIN public.companies company ON company.id=setting.company_id
  WHERE company.status='ACTIVE' AND setting.replenishment_mode<>'MANUAL'
    AND (setting.updated_by IS NULL OR NOT EXISTS(
      SELECT 1 FROM public.profiles profile WHERE profile.id=setting.updated_by))
), active_finance AS (
  SELECT count(*) rows FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
), guard_contract AS (
  SELECT
    (SELECT pg_get_constraintdef(oid) FROM pg_constraint
      WHERE conrelid=to_regclass('public.purchase_daily_batch_operations')
        AND conname='purchase_daily_batch_operations_operation_type_check') operation_check,
    (SELECT pg_get_constraintdef(oid) FROM pg_constraint
      WHERE conrelid=to_regclass('public.purchase_daily_batch_audit')
        AND conname='purchase_daily_batch_audit_action_check') audit_check,
    pg_get_functiondef(to_regprocedure(
      'private.trg_g5_guard_supplier_order_history()')) order_guard,
    pg_get_functiondef(to_regprocedure(
      'private.trg_guard_purchase_daily_batch()')) batch_guard
), date_identity AS (
  SELECT
    pg_get_functiondef(to_regprocedure(
      'private.generate_purchase_daily_auto_ro_core(uuid,date,uuid,uuid,timestamptz)')) ro_body,
    pg_get_functiondef(to_regprocedure(
      'private.generate_purchase_daily_auto_po_core(uuid,date,uuid,uuid,timestamptz)')) po_body
), historical_canceled_net_receipt AS (
  SELECT count(*) rows FROM public.supplier_order_documents document
  LEFT JOIN LATERAL(
    SELECT COALESCE(sum(line.accepted_good_base_qty+line.damaged_base_qty),0) quantity
    FROM public.goods_receipt_lines line
    JOIN public.goods_receipt_documents receipt
      ON receipt.company_id=line.company_id AND receipt.id=line.document_id
     AND receipt.status='POSTED'
    JOIN public.supplier_order_lines order_line
      ON order_line.company_id=line.company_id AND order_line.id=line.supplier_order_line_id
    WHERE order_line.company_id=document.company_id AND order_line.document_id=document.id
  ) received ON true
  LEFT JOIN LATERAL(
    SELECT COALESCE(sum(line.return_base_qty),0) quantity
    FROM public.purchase_return_lines line
    JOIN public.purchase_return_documents return_document
      ON return_document.company_id=line.company_id
     AND return_document.id=line.document_id AND return_document.status='POSTED'
    WHERE return_document.company_id=document.company_id
      AND return_document.supplier_order_id=document.id
  ) returned ON true
  WHERE document.status='CANCELED' AND received.quantity-returned.quantity<>0
), checks AS (
  SELECT 'scheduler_cancel_dependency_ledger' check_name,
    CASE WHEN dependency.present=7 THEN 'PASS' ELSE 'BLOCKER' END status,
    7-dependency.present violation_rows,
    jsonb_build_object('expected',7,'present',dependency.present) details FROM dependency
  UNION ALL
  SELECT 'scheduler_cancel_routine_contract',
    CASE WHEN present=6 THEN 'PASS' ELSE 'BLOCKER' END,6-present,
    jsonb_build_object('expected',6,'present',present) FROM routine_contract
  UNION ALL
  SELECT 'scheduler_cancel_relation_contract',
    CASE WHEN present=8 THEN 'PASS' ELSE 'BLOCKER' END,8-present,
    jsonb_build_object('expected',8,'present',present) FROM relation_contract
  UNION ALL
  SELECT 'scheduler_extension_availability',
    CASE WHEN EXISTS(SELECT 1 FROM pg_available_extensions WHERE name='pg_cron')
      THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN EXISTS(SELECT 1 FROM pg_available_extensions WHERE name='pg_cron')
      THEN 0 ELSE 1 END,
    jsonb_build_object('pgCronAvailable',EXISTS(
      SELECT 1 FROM pg_available_extensions WHERE name='pg_cron'))
  UNION ALL
  SELECT 'scheduler_cancel_object_collision',
    CASE WHEN to_regclass('public.purchase_daily_scheduler_runs') IS NULL
      AND to_regclass('public.purchase_daily_scheduler_attempts') IS NULL
      AND to_regclass('public.purchase_supplier_order_cancel_operations') IS NULL
      AND to_regprocedure('private.run_purchase_daily_replenishment_scheduler(timestamptz)') IS NULL
      AND to_regprocedure('public.cancel_purchase_daily_auto_ro(uuid,bigint,uuid,text)') IS NULL
      AND to_regprocedure('public.cancel_purchase_supplier_order(uuid,bigint,uuid,text)') IS NULL
      THEN 'PASS' ELSE 'BLOCKER' END,
    (CASE WHEN to_regclass('public.purchase_daily_scheduler_runs') IS NULL THEN 0 ELSE 1 END+
     CASE WHEN to_regclass('public.purchase_daily_scheduler_attempts') IS NULL THEN 0 ELSE 1 END+
     CASE WHEN to_regclass('public.purchase_supplier_order_cancel_operations') IS NULL THEN 0 ELSE 1 END+
     CASE WHEN to_regprocedure('private.run_purchase_daily_replenishment_scheduler(timestamptz)') IS NULL THEN 0 ELSE 1 END+
     CASE WHEN to_regprocedure('public.cancel_purchase_daily_auto_ro(uuid,bigint,uuid,text)') IS NULL THEN 0 ELSE 1 END+
     CASE WHEN to_regprocedure('public.cancel_purchase_supplier_order(uuid,bigint,uuid,text)') IS NULL THEN 0 ELSE 1 END),
    jsonb_build_object('migrationApplied',EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260914140000'))
  UNION ALL
  SELECT 'automatic_company_technical_sponsor',
    CASE WHEN rows=0 THEN 'PASS' ELSE 'BLOCKER' END,rows,
    jsonb_build_object('invalidCompanies',rows,
      'auditActor','SYSTEM_AUTOMATION','displayName','Sistem Otomatis')
  FROM automatic_without_sponsor
  UNION ALL
  SELECT 'active_finance_queue_boundary',
    CASE WHEN rows=0 THEN 'PASS' ELSE 'BLOCKER' END,rows,
    jsonb_build_object('activeRuns',rows) FROM active_finance
  UNION ALL
  SELECT 'historical_canceled_po_return_boundary',
    CASE WHEN rows=0 THEN 'PASS' ELSE 'BLOCKER' END,rows,
    jsonb_build_object('canceledPoWithUnreturnedPostedReceipt',rows)
  FROM historical_canceled_net_receipt
  UNION ALL
  SELECT 'canonical_cancellation_guard_contract',
    CASE WHEN operation_check ~ 'GENERATE_AUTO_RO'
      AND operation_check ~ 'CONFIRM_AUTO_RO'
      AND operation_check ~ 'GENERATE_AUTO_PO'
      AND operation_check !~ 'CANCEL_BATCH'
      AND audit_check ~ 'AUTO_PO_GENERATE' AND audit_check ~ 'AUTO_PO_REUSE'
      AND audit_check !~ '''CANCEL'''
      AND position('OLD.status IN' in order_guard)>0
      AND position('OLD.status IN' in batch_guard)>0
      THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN operation_check ~ 'GENERATE_AUTO_RO'
      AND operation_check ~ 'CONFIRM_AUTO_RO'
      AND operation_check ~ 'GENERATE_AUTO_PO'
      AND operation_check !~ 'CANCEL_BATCH'
      AND audit_check ~ 'AUTO_PO_GENERATE' AND audit_check ~ 'AUTO_PO_REUSE'
      AND audit_check !~ '''CANCEL'''
      AND position('OLD.status IN' in order_guard)>0
      AND position('OLD.status IN' in batch_guard)>0
      THEN 0 ELSE 1 END,
    jsonb_build_object('operationConstraintFound',operation_check IS NOT NULL,
      'auditConstraintFound',audit_check IS NOT NULL,'orderGuardFound',order_guard IS NOT NULL,
      'batchGuardFound',batch_guard IS NOT NULL) FROM guard_contract
  UNION ALL
  SELECT 'po_number_date_contract',
    CASE WHEN position('RO-''||to_char(p_business_date,''YYYYMMDD'')' in ro_body)>0
      AND position('POB-''||to_char(p_business_date,''YYYYMMDD'')' in po_body)>0
      AND position('PO-''||to_char(p_business_date,''YYYYMMDD'')' in po_body)>0
      THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN position('RO-''||to_char(p_business_date,''YYYYMMDD'')' in ro_body)>0
      AND position('POB-''||to_char(p_business_date,''YYYYMMDD'')' in po_body)>0
      AND position('PO-''||to_char(p_business_date,''YYYYMMDD'')' in po_body)>0
      THEN 0 ELSE 1 END,
    jsonb_build_object('batchFormats',jsonb_build_array('RO-YYYYMMDD-*','POB-YYYYMMDD-*'),
      'poFormat','PO-YYYYMMDD-*') FROM date_identity
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 0 WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,
  check_name;
