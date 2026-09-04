-- Sales Order revision Order-date preservation closing gate.
-- SAFETY: SELECT-only.
WITH migration AS (
  SELECT applied_at FROM private.kgs_schema_migrations
  WHERE version='20260904130000'
), revision_runtime AS (
  SELECT lower(regexp_replace(COALESCE(pg_get_functiondef(to_regprocedure(
    'public.start_pos_sales_order_revision(uuid,bigint,uuid,uuid,text)')),''),
    '[[:space:]]+','','g')) definition
), checks AS (
  SELECT 'migration_ledger'::TEXT check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(1-count(*))::BIGINT violation_rows,
    jsonb_build_object('ledgerRows',count(*)) details
  FROM migration
  UNION ALL
  SELECT 'revision_order_date_runtime_contract',
    CASE WHEN position('sales_order_revision_date_payload' IN definition)>0
      AND position('transaction_date=v_source.transaction_date' IN definition)>0
      AND position('transaction_date_source=v_source.transaction_date_source'
        IN definition)>0
      AND position('transaction_date_selected_by=v_source.transaction_date_selected_by'
        IN definition)>0
      AND position('transaction_date_selected_at=v_source.transaction_date_selected_at'
        IN definition)>0
      AND position('created_at=v_source.created_at' IN definition)=0
      AND position('posted_at=v_source.posted_at' IN definition)=0
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN position('sales_order_revision_date_payload' IN definition)>0
      AND position('transaction_date=v_source.transaction_date' IN definition)>0
      AND position('transaction_date_source=v_source.transaction_date_source'
        IN definition)>0
      AND position('transaction_date_selected_by=v_source.transaction_date_selected_by'
        IN definition)>0
      AND position('transaction_date_selected_at=v_source.transaction_date_selected_at'
        IN definition)>0
      AND position('created_at=v_source.created_at' IN definition)=0
      AND position('posted_at=v_source.posted_at' IN definition)=0
      THEN 0 ELSE 1 END::BIGINT,
    jsonb_build_object('routineRows',CASE WHEN definition='' THEN 0 ELSE 1 END)
  FROM revision_runtime
  UNION ALL
  SELECT 'private_revision_date_helper_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::BIGINT,
    jsonb_build_object('browserExecutableRows',count(*))
  FROM (VALUES('anon'),('authenticated')) role_name(name)
  WHERE has_function_privilege(role_name.name,
    'private.sales_order_revision_date_payload(jsonb,timestamptz,text)',
    'EXECUTE')
  UNION ALL
  SELECT 'new_revision_start_date_audit_identity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::BIGINT,
    jsonb_build_object('rowCount',count(*))
  FROM public.sales_order_revisions revision
  JOIN migration ON TRUE
  JOIN public.sales_headers source ON source.company_id=revision.company_id
    AND source.id=revision.source_sales_id
  LEFT JOIN public.sales_order_revision_audit audit
    ON audit.company_id=revision.company_id AND audit.revision_id=revision.id
   AND audit.action='START'
  WHERE revision.started_at>=migration.applied_at
    AND (audit.id IS NULL
      OR (audit.after_state->>'transactionDate')::TIMESTAMPTZ
        IS DISTINCT FROM source.transaction_date
      OR audit.after_state->>'transactionDateSource'
        IS DISTINCT FROM source.transaction_date_source
      OR NULLIF(audit.after_state->>'transactionDateSelectedBy','')::UUID
        IS DISTINCT FROM source.transaction_date_selected_by
      OR NULLIF(audit.after_state->>'transactionDateSelectedAt','')::TIMESTAMPTZ
        IS DISTINCT FROM source.transaction_date_selected_at)
  UNION ALL
  SELECT 'new_revision_lifecycle_timestamp_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::BIGINT,
    jsonb_build_object('rowCount',count(*))
  FROM public.sales_order_revisions revision
  JOIN migration ON TRUE
  JOIN public.sales_headers source ON source.company_id=revision.company_id
    AND source.id=revision.source_sales_id
  JOIN public.sales_headers replacement
    ON replacement.company_id=revision.company_id
   AND replacement.id=revision.replacement_sales_id
  WHERE revision.started_at>=migration.applied_at
    AND (replacement.created_at<revision.started_at-interval '5 seconds'
      OR (replacement.posted_at IS NOT NULL
        AND replacement.posted_at<revision.started_at-interval '5 seconds'))
  UNION ALL
  SELECT 'revision_order_date_runtime_inventory','INFO',0::BIGINT,
    jsonb_build_object('newRevisions',count(*),
      'pendingNew',count(*) FILTER(WHERE revision.status='PENDING'),
      'appliedNew',count(*) FILTER(WHERE revision.status='APPLIED'))
  FROM public.sales_order_revisions revision JOIN migration ON TRUE
  WHERE revision.started_at>=migration.applied_at
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,
  check_name;
