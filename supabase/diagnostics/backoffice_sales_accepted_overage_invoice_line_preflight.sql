-- SELECT-only preflight for Step 4/6.5C2A accepted-overage Invoice line parity.
-- Run the entire file only on isolated Development fkywtxucmyjvpwdiqpix.
WITH required_routines(signature) AS (
  VALUES
    ('private.post_backoffice_sales_discrepancy_transfer(uuid,bigint,uuid,uuid)'),
    ('private.save_backoffice_sales_invoice_draft_core(uuid,bigint,uuid,uuid,jsonb)'),
    ('private.save_backoffice_sales_invoice_draft_core_before_delivery_fee(uuid,bigint,uuid,uuid,jsonb)'),
    ('public.post_backoffice_sales_invoice(uuid,bigint,uuid)'),
    ('private.backoffice_sales_invoice_snapshot(uuid,uuid)'),
    ('private.backoffice_sales_invoice_ui_snapshot(uuid,uuid)'),
    ('public.get_backoffice_sales_invoice_workspace(uuid,text,text,integer)')
), routine_state AS (
  SELECT signature,to_regprocedure(signature) oid FROM required_routines
), definitions AS (
  SELECT
    pg_get_functiondef(to_regprocedure(
      'private.save_backoffice_sales_invoice_draft_core(uuid,bigint,uuid,uuid,jsonb)')) save_wrapper_body,
    pg_get_functiondef(to_regprocedure(
      'private.save_backoffice_sales_invoice_draft_core_before_delivery_fee(uuid,bigint,uuid,uuid,jsonb)')) save_base_body,
    pg_get_functiondef(to_regprocedure(
      'public.post_backoffice_sales_invoice(uuid,bigint,uuid)')) post_body,
    pg_get_functiondef(to_regprocedure(
      'private.backoffice_sales_invoice_ui_snapshot(uuid,uuid)')) ui_body
), checks AS (
  SELECT 'c2a_dependency_ledger' check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END status,
    abs(1-count(*)) violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260912122000'
  UNION ALL
  SELECT 'c2a_required_routines',CASE WHEN count(*) FILTER(WHERE oid IS NOT NULL)=7
    THEN 'PASS' ELSE 'BLOCKER' END,
    7-count(*) FILTER(WHERE oid IS NOT NULL),jsonb_build_object(
      'expected',7,'present',count(*) FILTER(WHERE oid IS NOT NULL),
      'missing',COALESCE(jsonb_agg(signature) FILTER(WHERE oid IS NULL),'[]'::jsonb))
  FROM routine_state
  UNION ALL
  SELECT 'c2a_schema_collision',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*),jsonb_build_object('existingColumns',COALESCE(jsonb_agg(
      table_name||'.'||column_name ORDER BY table_name,column_name),'[]'::jsonb))
  FROM information_schema.columns WHERE table_schema='public' AND (
    (table_name='backoffice_sales_delivery_discrepancy_lines' AND column_name IN(
      'accepted_overage_base_qty','draft_overage_invoice_allocated_base_qty',
      'invoiced_overage_base_qty','overage_to_invoice_base_qty'))
    OR (table_name='backoffice_sales_invoice_lines' AND column_name IN(
      'source_kind','discrepancy_line_id'))
    OR (table_name='backoffice_sales_invoice_quantity_allocations' AND column_name IN(
      'source_kind','discrepancy_line_id')))
  UNION ALL
  SELECT 'c2a_invoice_call_chain_shape',CASE WHEN save_wrapper_body LIKE
      '%save_backoffice_sales_invoice_draft_core_before_delivery_fee%'
      AND save_base_body LIKE
      '%BACKOFFICE_SALES_INVOICE_LINE_DUPLICATE%'
      AND save_base_body LIKE '%draft_invoice_allocated_base_qty%'
      AND post_body LIKE '%invoiced_base_qty%'
      AND ui_body LIKE '%sourceSnapshot%' THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN save_wrapper_body LIKE
      '%save_backoffice_sales_invoice_draft_core_before_delivery_fee%'
      AND save_base_body LIKE '%BACKOFFICE_SALES_INVOICE_LINE_DUPLICATE%'
      AND save_base_body LIKE '%draft_invoice_allocated_base_qty%'
      AND post_body LIKE '%invoiced_base_qty%'
      AND ui_body LIKE '%sourceSnapshot%' THEN 0 ELSE 1 END,
    jsonb_build_object('wrapperDelegatesToBase',save_wrapper_body LIKE
      '%save_backoffice_sales_invoice_draft_core_before_delivery_fee%',
      'singleSourceLineDuplicateGuard',save_base_body LIKE
      '%BACKOFFICE_SALES_INVOICE_LINE_DUPLICATE%',
      'draftAllocationUpdate',save_base_body LIKE '%draft_invoice_allocated_base_qty%',
      'postedAllocationUpdate',post_body LIKE '%invoiced_base_qty%',
      'uiSourceSnapshot',ui_body LIKE '%sourceSnapshot%') FROM definitions
  UNION ALL
  SELECT 'c2a_active_finance_queue',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*),jsonb_build_object('runRows',count(*))
  FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'c2a_nonterminal_offline',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*),jsonb_build_object('submissionRows',count(*))
  FROM public.pos_offline_sale_submissions
  WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
  UNION ALL
  SELECT 'c2a_existing_overage_invoice_boundary',
    CASE WHEN count(*) FILTER(WHERE line.commercial_approval_status='APPROVED'
      AND line.warehouse_resolution_status='RESOLVED')=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*) FILTER(WHERE line.commercial_approval_status='APPROVED'
      AND line.warehouse_resolution_status='RESOLVED'),
    jsonb_build_object('approvedPendingWarehouse',count(*) FILTER(WHERE
      line.commercial_approval_status='APPROVED' AND line.warehouse_resolution_status='PENDING'),
      'approvedResolved',count(*) FILTER(WHERE line.commercial_approval_status='APPROVED'
        AND line.warehouse_resolution_status='RESOLVED'))
  FROM public.backoffice_sales_delivery_discrepancy_lines line
  WHERE line.discrepancy_type='OVERAGE' AND line.requested_resolution='ACCEPT_OVERAGE'
  UNION ALL
  SELECT 'c2a_runtime_inventory','INFO',0,jsonb_build_object(
    'draftInvoices',(SELECT count(*) FROM public.backoffice_sales_invoices WHERE status='DRAFT'),
    'heldQuantityAllocations',(SELECT count(*) FROM public.backoffice_sales_invoice_quantity_allocations
      WHERE status='HELD'),
    'pendingAcceptedOverage',(SELECT count(*)
      FROM public.backoffice_sales_delivery_discrepancy_lines line
      WHERE line.requested_resolution='ACCEPT_OVERAGE'
        AND line.warehouse_resolution_status='PENDING'))
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;
