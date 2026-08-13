-- ACP-5D postflight: Purchase Return permission enforcement.
-- SAFETY: SELECT-only; aggregate metadata and invariants only.

WITH expected_relations(relation_name) AS (VALUES
  ('purchase_return_documents'),('purchase_return_lines'),
  ('purchase_return_fifo_allocations'),('purchase_return_ap_adjustments'),
  ('purchase_return_audit')
), expected_routines(routine_name) AS (VALUES
  ('get_purchase_returns'),('get_pos_purchase_return_workspace'),
  ('save_purchase_return_draft'),('review_purchase_return'),
  ('post_purchase_return'),('cancel_purchase_return_draft')
), checks AS (
  SELECT 'migration_ledger'::TEXT check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    CASE WHEN count(*)=1 THEN 0 ELSE 1 END::BIGINT violation_rows,
    jsonb_build_object('ledger_rows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260813010000'

  UNION ALL
  SELECT 'purchase_return_permission_enforced',
    CASE WHEN count(*)=1 AND bool_and(enforcement_status='ENFORCED')
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1 AND bool_and(enforcement_status='ENFORCED')
      THEN 0 ELSE 1 END,
    jsonb_build_object('rows',count(*),'statuses',jsonb_agg(enforcement_status))
  FROM public.access_permission_catalog
  WHERE permission_key='purchase.purchase_returns'

  UNION ALL
  SELECT 'required_purchase_return_routines',
    CASE WHEN count(*) FILTER(WHERE procedure.oid IS NULL)=0
      THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE procedure.oid IS NULL),
    jsonb_build_object('expected',count(*),'missing',COALESCE(jsonb_agg(
      expected.routine_name ORDER BY expected.routine_name)
      FILTER(WHERE procedure.oid IS NULL),'[]'::JSONB))
  FROM expected_routines expected LEFT JOIN pg_proc procedure
    ON procedure.proname=expected.routine_name
   AND procedure.pronamespace='public'::regnamespace

  UNION ALL
  SELECT 'purchase_return_runtime_permission_hooks',
    CASE WHEN count(*)=3 THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=3 THEN 0 ELSE 1 END,
    jsonb_build_object('routine_rows',count(*))
  FROM pg_proc procedure WHERE procedure.pronamespace='public'::regnamespace
    AND procedure.proname IN('get_purchase_returns','review_purchase_return',
      'post_purchase_return')
    AND pg_get_functiondef(procedure.oid)
      ILIKE '%acp_require_permission_capability%'
    AND pg_get_functiondef(procedure.oid) ILIKE '%purchase.purchase_returns%'

  UNION ALL
  SELECT 'purchase_return_direct_table_boundary',
    CASE WHEN count(*) FILTER(WHERE readable OR writable)=0
      THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE readable OR writable),
    jsonb_build_object('exposed',COALESCE(jsonb_agg(relation_name)
      FILTER(WHERE readable OR writable),'[]'::JSONB))
  FROM (SELECT expected.relation_name,
    has_table_privilege('authenticated',format('public.%I',relation_name),
      'SELECT') readable,
    has_table_privilege('authenticated',format('public.%I',relation_name),
      'INSERT,UPDATE,DELETE') writable FROM expected_relations expected) state

  UNION ALL
  SELECT 'purchase_return_rpc_boundary',
    CASE WHEN count(*) FILTER(WHERE authenticated_execute)=6
      AND count(*) FILTER(WHERE anon_execute)=0 THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*) FILTER(WHERE authenticated_execute)=6
      AND count(*) FILTER(WHERE anon_execute)=0 THEN 0 ELSE 1 END,
    jsonb_build_object('authenticated_rows',count(*)
      FILTER(WHERE authenticated_execute),'anon_rows',count(*)
      FILTER(WHERE anon_execute))
  FROM (SELECT expected.routine_name,
    has_function_privilege('authenticated',procedure.oid,'EXECUTE')
      authenticated_execute,
    has_function_privilege('anon',procedure.oid,'EXECUTE') anon_execute
    FROM expected_routines expected JOIN pg_proc procedure
      ON procedure.proname=expected.routine_name
     AND procedure.pronamespace='public'::regnamespace) privilege_state

  UNION ALL
  SELECT 'private_purchase_return_core_boundary',
    CASE WHEN count(*)=4 AND count(*) FILTER(WHERE auth_execute)=0
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=4 AND count(*) FILTER(WHERE auth_execute)=0
      THEN 0 ELSE 1 END,
    jsonb_build_object('core_rows',count(*),'authenticated_executable_rows',
      count(*) FILTER(WHERE auth_execute))
  FROM (SELECT procedure.oid,has_function_privilege(
      'authenticated',procedure.oid,'EXECUTE') auth_execute
    FROM pg_proc procedure WHERE procedure.pronamespace='private'::regnamespace
      AND procedure.proname LIKE 'acp5d_%purchase_return%core') core

  UNION ALL
  SELECT 'nonfinal_purchase_return_with_final_effect',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('document_count',count(*))
  FROM public.purchase_return_documents document
  WHERE document.status<>'POSTED' AND (document.financial_event_id IS NOT NULL
    OR EXISTS(SELECT 1 FROM public.purchase_return_fifo_allocations allocation
      WHERE allocation.company_id=document.company_id
        AND allocation.document_id=document.id)
    OR EXISTS(SELECT 1 FROM public.purchase_return_ap_adjustments adjustment
      WHERE adjustment.company_id=document.company_id
        AND adjustment.document_id=document.id))

  UNION ALL
  SELECT 'purchase_return_runtime_inventory','INFO',0,
    jsonb_build_object('documents',count(*),
      'drafts',count(*) FILTER(WHERE status='DRAFT'),
      'posted',count(*) FILTER(WHERE status='POSTED'),
      'canceled',count(*) FILTER(WHERE status='CANCELED'))
  FROM public.purchase_return_documents
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
