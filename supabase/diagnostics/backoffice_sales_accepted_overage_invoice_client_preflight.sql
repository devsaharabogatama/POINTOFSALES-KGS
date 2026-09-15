-- SELECT-only preflight for Step 4/6.5C2C. Run the entire file.
WITH checks AS (
  SELECT 'c2c_dependency_ledger' check_name,
    CASE WHEN count(*)=2 THEN 'PASS' ELSE 'BLOCKER' END status,
    2-count(*) violation_rows,
    jsonb_build_object('expected',2,'present',count(*)) details
  FROM private.kgs_schema_migrations WHERE version IN('20260912123000','20260912124000')
  UNION ALL
  SELECT 'c2c_read_routine_contract',CASE WHEN count(*)=2 THEN 'PASS' ELSE 'BLOCKER' END,
    2-count(*),jsonb_build_object('expected',2,'present',count(*))
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE (n.nspname,p.proname,pg_get_function_identity_arguments(p.oid)) IN(
    ('private','backoffice_sales_invoice_ui_snapshot','p_company_id uuid, p_invoice_id uuid'),
    ('public','get_backoffice_sales_invoice_workspace','p_sales_order_id uuid, p_status text, p_search text, p_limit integer'))
  UNION ALL
  SELECT 'c2c_read_model_collision',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*),
    jsonb_build_object('alreadyPatched',count(*)>0)
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE (n.nspname='private' AND p.proname='backoffice_sales_invoice_ui_snapshot'
      AND position('''sourceKind''' in pg_get_functiondef(p.oid))>0)
     OR (n.nspname='public' AND p.proname='get_backoffice_sales_invoice_workspace'
      AND position('''acceptedOverageLines''' in pg_get_functiondef(p.oid))>0)
  UNION ALL
  SELECT 'c2c_active_finance_queue',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*),jsonb_build_object('runRows',count(*))
  FROM public.finance_posting_queue_runs WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'c2c_nonterminal_offline',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*),jsonb_build_object('submissionRows',count(*))
  FROM public.pos_offline_sale_submissions WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
  UNION ALL
  SELECT 'c2c_runtime_inventory','INFO',0,
    jsonb_build_object('resolvedAcceptedOverage',count(*),'invoiceable',count(*) FILTER(WHERE overage_to_invoice_base_qty>0))
  FROM public.backoffice_sales_delivery_discrepancy_lines
  WHERE requested_resolution='ACCEPT_OVERAGE' AND commercial_approval_status='APPROVED'
    AND warehouse_resolution_status='RESOLVED'
)
SELECT * FROM checks ORDER BY CASE status WHEN 'BLOCKER' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;
