-- Sales Invoice revision activity closing gate.
-- SAFETY: SELECT-only.
WITH checks AS (
  SELECT 'migration_ledger'::TEXT check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(1-count(*))::BIGINT violation_rows,
    jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260904120000'
  UNION ALL
  SELECT 'required_activity_routines',
    CASE WHEN count(*)=2 THEN 'PASS' ELSE 'FAIL' END,
    abs(2-count(*))::BIGINT,jsonb_build_object('expected',2,'routineRows',count(*))
  FROM unnest(ARRAY['public.get_sales_document_activity()',
    'public.get_sales_order_revision_links()']) signature
  WHERE to_regprocedure(signature) IS NOT NULL
  UNION ALL
  SELECT 'sales_document_activity_rpc_boundary',
    CASE WHEN NOT has_function_privilege('anon',
        'public.get_sales_document_activity()','EXECUTE')
      AND has_function_privilege('authenticated',
        'public.get_sales_document_activity()','EXECUTE')
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN NOT has_function_privilege('anon',
        'public.get_sales_document_activity()','EXECUTE')
      AND has_function_privilege('authenticated',
        'public.get_sales_document_activity()','EXECUTE')
      THEN 0 ELSE 1 END::BIGINT,
    jsonb_build_object('anonExecute',has_function_privilege('anon',
      'public.get_sales_document_activity()','EXECUTE'),
      'authenticatedExecute',has_function_privilege('authenticated',
      'public.get_sales_document_activity()','EXECUTE'))
  UNION ALL
  SELECT 'revision_invoice_identity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::BIGINT,
    jsonb_build_object('rowCount',count(*))
  FROM public.sales_order_revisions revision
  JOIN public.sales_headers source ON source.company_id=revision.company_id
    AND source.id=revision.source_sales_id
  JOIN public.sales_headers replacement ON replacement.company_id=revision.company_id
    AND replacement.id=revision.replacement_sales_id
  WHERE revision.status='APPLIED' AND
    (COALESCE(btrim(source.invoice_no),'')=''
      OR COALESCE(btrim(replacement.invoice_no),'')='')
  UNION ALL
  SELECT 'revision_activity_runtime_inventory','INFO',0::BIGINT,
    jsonb_build_object('revisionRows',count(*),
      'appliedRows',count(*) FILTER(WHERE status='APPLIED'),
      'pendingRows',count(*) FILTER(WHERE status='PENDING'),
      'abandonedRows',count(*) FILTER(WHERE status='ABANDONED'))
  FROM public.sales_order_revisions
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
