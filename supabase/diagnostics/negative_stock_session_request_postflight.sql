-- SELECT-only postflight for automatic negative-stock Session requests.

WITH checks AS (
  SELECT 'migration_ledger' check_name,
    count(*)=1 passed,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260819170000'
  UNION ALL
  SELECT 'required_schema',count(*)=2,
    jsonb_build_object('objectRows',count(*),'expected',2)
  FROM (VALUES
    (to_regclass('public.stock_request_negative_allocations')::OID),
    ((SELECT attrelid FROM pg_attribute WHERE attrelid=
      'public.stock_request_documents'::regclass AND attname='request_source'
      AND NOT attisdropped))
  ) object(object_oid) WHERE object_oid IS NOT NULL
  UNION ALL
  SELECT 'required_routines',count(*)=4,
    jsonb_build_object('routineRows',count(*),'expected',4)
  FROM unnest(ARRAY[
    to_regprocedure('private.ensure_negative_session_stock_request(uuid,uuid,uuid)'),
    to_regprocedure('private.prd_close_cashier_session_core(uuid,bigint,numeric)'),
    to_regprocedure('public.close_cashier_session(uuid,bigint,numeric)'),
    to_regprocedure('public.get_pos_negative_stock_readiness()')
  ]) routine_oid WHERE routine_oid IS NOT NULL
  UNION ALL
  SELECT 'close_session_request_contract',
    position('ensure_negative_session_stock_request' IN pg_get_functiondef(
      to_regprocedure('public.close_cashier_session(uuid,bigint,numeric)')))>0,
    jsonb_build_object('wrapperExists',to_regprocedure(
      'public.close_cashier_session(uuid,bigint,numeric)') IS NOT NULL)
  UNION ALL
  SELECT 'negative_snapshot_contract',
    NOT EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid=
      'public.cashier_session_stock_snapshots'::regclass
      AND conname='cashier_session_stock_snapshot_qty_nonnegative')
    AND EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid=
      'public.cashier_session_stock_snapshots'::regclass
      AND conname='cashier_session_stock_snapshot_qty_numeric'),
    jsonb_build_object('negativeSnapshotAllowed',TRUE)
  UNION ALL
  SELECT 'automatic_request_identity',count(*)=0,
    jsonb_build_object('duplicateGroups',count(*))
  FROM (SELECT company_id,requesting_session_id
    FROM public.stock_request_documents
    WHERE request_source='NEGATIVE_STOCK_SESSION_CLOSE'
    GROUP BY company_id,requesting_session_id HAVING count(*)>1) duplicate
  UNION ALL
  SELECT 'automatic_request_line_reconciliation',count(*)=0,
    jsonb_build_object('documentCount',count(*))
  FROM (SELECT document.id
    FROM public.stock_request_documents document
    LEFT JOIN public.stock_request_lines line
      ON line.company_id=document.company_id AND line.document_id=document.id
    WHERE document.request_source='NEGATIVE_STOCK_SESSION_CLOSE'
    GROUP BY document.id,document.line_count,document.requested_total_base_qty
    HAVING count(line.id)<>document.line_count
      OR COALESCE(sum(line.requested_base_qty),0)
        <>document.requested_total_base_qty) mismatch
  UNION ALL
  SELECT 'automatic_request_allocation_reconciliation',count(*)=0,
    jsonb_build_object('lineCount',count(*))
  FROM (SELECT line.id
    FROM public.stock_request_lines line
    JOIN public.stock_request_documents document
      ON document.company_id=line.company_id AND document.id=line.document_id
    LEFT JOIN public.stock_request_negative_allocations allocation
      ON allocation.company_id=line.company_id
     AND allocation.stock_request_line_id=line.id
    WHERE document.request_source='NEGATIVE_STOCK_SESSION_CLOSE'
    GROUP BY line.id,line.requested_base_qty
    HAVING COALESCE(sum(allocation.requested_base_qty),0)
      <>line.requested_base_qty) mismatch
  UNION ALL
  SELECT 'browser_write_boundary',
    NOT has_table_privilege('authenticated',
      'public.stock_request_negative_allocations','INSERT,UPDATE,DELETE'),
    jsonb_build_object('directWrite',has_table_privilege('authenticated',
      'public.stock_request_negative_allocations','INSERT,UPDATE,DELETE'))
  UNION ALL
  SELECT 'rpc_boundary',
    has_function_privilege('authenticated',
      'public.get_pos_negative_stock_readiness()','EXECUTE')
    AND has_function_privilege('authenticated',
      'public.close_cashier_session(uuid,bigint,numeric)','EXECUTE')
    AND NOT has_function_privilege('authenticated',
      'private.ensure_negative_session_stock_request(uuid,uuid,uuid)','EXECUTE'),
    jsonb_build_object('authenticatedReadiness',has_function_privilege(
      'authenticated','public.get_pos_negative_stock_readiness()','EXECUTE'))
  UNION ALL
  SELECT 'runtime_inventory',TRUE,jsonb_build_object(
    'automaticRequests',count(DISTINCT document.id),
    'requestLines',count(DISTINCT line.id),
    'lineageRows',count(DISTINCT allocation.id))
  FROM public.stock_request_documents document
  LEFT JOIN public.stock_request_lines line
    ON line.company_id=document.company_id AND line.document_id=document.id
  LEFT JOIN public.stock_request_negative_allocations allocation
    ON allocation.company_id=document.company_id
   AND allocation.stock_request_document_id=document.id
  WHERE document.request_source='NEGATIVE_STOCK_SESSION_CLOSE'
)
SELECT check_name,CASE WHEN check_name='runtime_inventory' THEN 'INFO'
  WHEN passed THEN 'PASS' ELSE 'FAIL' END status,
  CASE WHEN passed THEN 0 ELSE 1 END violation_rows,details
FROM checks ORDER BY CASE WHEN NOT passed THEN 0
  WHEN check_name='runtime_inventory' THEN 2 ELSE 1 END,check_name;
