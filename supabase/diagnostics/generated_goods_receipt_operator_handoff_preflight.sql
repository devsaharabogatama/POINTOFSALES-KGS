-- SELECT-only preflight for generated Goods Receipt operator handoff.
WITH checks AS (
  SELECT 'operator_handoff_dependency_ledger'::text check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END status,
    abs(count(*)-1)::bigint violation_rows,
    jsonb_build_object('requiredVersion','20260914180000','ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260914180000'
  UNION ALL
  SELECT 'operator_handoff_migration_collision',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'SETUP' END,count(*)::bigint,
    jsonb_build_object('installed',count(*)=1)
  FROM private.kgs_schema_migrations WHERE version='20260917141000'
  UNION ALL
  SELECT 'operator_handoff_routine_contract',
    CASE WHEN count(*)=2 THEN 'PASS' ELSE 'BLOCKER' END,
    abs(count(*)-2)::bigint,jsonb_build_object('present',count(*),'expected',2)
  FROM pg_proc procedure JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname='public' AND procedure.oid IN(
    to_regprocedure('public.save_generated_backoffice_goods_receipt(uuid,bigint,uuid,text,text,jsonb)'),
    to_regprocedure('public.post_generated_backoffice_goods_receipt(uuid,bigint,uuid)'))
  UNION ALL
  SELECT 'operator_handoff_active_finance_queue',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('activeRuns',count(*))
  FROM public.finance_posting_queue_runs run
  WHERE run.status IN('PREVIEWED','APPROVED','PROCESSING')
), inventory AS (
  SELECT 'operator_handoff_runtime_inventory'::text check_name,'INFO'::text status,
    0::bigint violation_rows,jsonb_build_object(
      'generatedDrafts',(SELECT count(*) FROM public.goods_receipt_documents receipt
        WHERE receipt.source_channel='BACKOFFICE' AND receipt.status='DRAFT'),
      'startedGeneratedDrafts',(SELECT count(*) FROM public.goods_receipt_documents receipt
        WHERE receipt.source_channel='BACKOFFICE' AND receipt.status='DRAFT'
          AND (receipt.line_count>0 OR EXISTS(SELECT 1 FROM public.goods_receipt_lines line
            WHERE line.company_id=receipt.company_id AND line.document_id=receipt.id)))) details
)
SELECT * FROM (SELECT * FROM checks UNION ALL SELECT * FROM inventory) result
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'FAIL' THEN 2 WHEN 'PASS' THEN 3
  WHEN 'SETUP' THEN 4 ELSE 5 END,check_name;
