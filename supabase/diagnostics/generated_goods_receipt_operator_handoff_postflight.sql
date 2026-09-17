-- SELECT-only verification for 20260917141000.
WITH definitions AS (
  SELECT pg_get_functiondef(
    'private.claim_generated_backoffice_goods_receipt(uuid,bigint,text)'::regprocedure) claim_definition,
    pg_get_functiondef(
    'public.save_generated_backoffice_goods_receipt(uuid,bigint,uuid,text,text,jsonb)'::regprocedure) save_definition,
    pg_get_functiondef(
    'public.post_generated_backoffice_goods_receipt(uuid,bigint,uuid)'::regprocedure) post_definition
), checks AS (
  SELECT 'operator_handoff_migration_ledger'::text check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(count(*)-1)::bigint violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260917141000'
  UNION ALL
  SELECT 'operator_handoff_runtime_contract',
    CASE WHEN claim_definition~'received_by IS DISTINCT FROM v_actor'
      AND claim_definition~'acp_require_permission_capability'
      AND claim_definition~'MASTER_VERSION_CONFLICT'
      AND save_definition~'claim_generated_backoffice_goods_receipt'
      AND post_definition~'claim_generated_backoffice_goods_receipt'
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN claim_definition~'received_by IS DISTINCT FROM v_actor'
      AND claim_definition~'acp_require_permission_capability'
      AND claim_definition~'MASTER_VERSION_CONFLICT'
      AND save_definition~'claim_generated_backoffice_goods_receipt'
      AND post_definition~'claim_generated_backoffice_goods_receipt'
      THEN 0 ELSE 1 END,
    jsonb_build_object('auditedOperatorHandoff',claim_definition~'received_by IS DISTINCT FROM v_actor',
      'permissionPreserved',claim_definition~'acp_require_permission_capability',
      'versionGuardPreserved',claim_definition~'MASTER_VERSION_CONFLICT',
      'saveDelegates',save_definition~'claim_generated_backoffice_goods_receipt',
      'postDelegates',post_definition~'claim_generated_backoffice_goods_receipt')
  FROM definitions
  UNION ALL
  SELECT 'operator_handoff_private_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('authenticatedExecutableRows',count(*))
  FROM information_schema.routine_privileges privilege
  WHERE privilege.routine_schema='private'
    AND privilege.routine_name='claim_generated_backoffice_goods_receipt'
    AND privilege.grantee IN('anon','authenticated') AND privilege.privilege_type='EXECUTE'
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
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
