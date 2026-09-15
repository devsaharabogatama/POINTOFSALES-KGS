-- SELECT-only preflight for 20260912100000. Run the entire file.
WITH checks AS (
  SELECT 'active_finance_queue' check_name,
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END status,count(*) violation_rows,
    jsonb_build_object('runRows',count(*)) details
  FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'nonterminal_offline_submission',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*),
    jsonb_build_object('submissionRows',count(*))
  FROM public.pos_offline_sale_submissions
  WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
  UNION ALL
  SELECT 'approved_overage_before_runtime',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*),
    jsonb_build_object('approvedLines',count(*),
      'required','Existing approved rows require explicit commercial reconciliation')
  FROM public.backoffice_sales_delivery_discrepancy_lines
  WHERE commercial_approval_status='APPROVED'
  UNION ALL
  SELECT 'overage_approval_dependency_ledger',
    CASE WHEN count(*)=3 THEN 'PASS' ELSE 'BLOCKER' END,3-count(*),
    jsonb_build_object('expected',3,'present',count(*))
  FROM private.kgs_schema_migrations
  WHERE version IN('20260911164000','20260911165000','20260911166000')
  UNION ALL
  SELECT 'overage_approval_relation_contract',
    CASE WHEN count(*)=4 THEN 'PASS' ELSE 'BLOCKER' END,4-count(*),
    jsonb_build_object('expected',4,'present',count(*))
  FROM information_schema.tables
  WHERE table_schema='public' AND table_name IN(
    'backoffice_sales_delivery_discrepancies',
    'backoffice_sales_delivery_discrepancy_lines',
    'backoffice_sales_discrepancy_operations',
    'backoffice_sales_discrepancy_audit')
  UNION ALL
  SELECT 'overage_approval_column_collision',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*),
    jsonb_build_object('existing',COALESCE(jsonb_agg(table_name||'.'||column_name),'[]'::jsonb))
  FROM information_schema.columns
  WHERE table_schema='public'
    AND ((table_name='backoffice_sales_delivery_discrepancies' AND column_name='master_version')
      OR (table_name='backoffice_sales_delivery_discrepancy_lines'
        AND column_name IN('approved_unit_price','approved_discount_amount',
          'approved_tax_amount','approved_line_total','commercial_snapshot',
          'commercial_approved_by','commercial_approved_at')))
  UNION ALL
  SELECT 'overage_approval_routine_collision',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*),
    jsonb_build_object('existing',COALESCE(jsonb_agg(p.oid::regprocedure::text),'[]'::jsonb))
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE (n.nspname='public' AND p.proname='approve_backoffice_sales_delivery_overage')
     OR (n.nspname='private' AND p.proname IN(
       'approve_backoffice_sales_delivery_overage_core','resolve_explicit_sales_tax_rule'))
  UNION ALL
  SELECT 'pending_overage_runtime_inventory','INFO',0,
    jsonb_build_object('pendingLines',count(*),'discrepancies',count(DISTINCT discrepancy_id))
  FROM public.backoffice_sales_delivery_discrepancy_lines
  WHERE requested_resolution='ACCEPT_OVERAGE' AND commercial_approval_status='PENDING'
  UNION ALL
  SELECT 'preflight_revision','INFO',0,
    jsonb_build_object('revision','STEP_4_6_4_OVERAGE_COMMERCIAL_V1',
      'writes',false,'executionRule','Run the entire file; do not run selected text')
)
SELECT check_name,status,GREATEST(violation_rows,0)::bigint violation_rows,details
FROM checks ORDER BY CASE status WHEN 'BLOCKER' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;
