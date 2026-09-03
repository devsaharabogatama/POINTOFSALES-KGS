-- Sales Order revision idempotency namespace forward-fix preflight.
-- SAFETY: SELECT-only. No operational row is changed.
WITH definition AS (
  SELECT COALESCE(pg_get_functiondef(
    'public.confirm_pos_sales_order(uuid,bigint,uuid,text)'::regprocedure),'') body
), checks AS (
  SELECT 'active_finance_posting_queue' check_name,
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('runCount',count(*)) details
  FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'nonterminal_offline_submission',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('submissionCount',count(*))
  FROM public.pos_offline_sale_submissions
  WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
  UNION ALL
  SELECT 'revision_runtime_dependency',
    CASE WHEN count(*)=2 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('expected',2,'ledgerRows',count(*))
  FROM private.kgs_schema_migrations
  WHERE version IN('20260903100000','20260903110000')
  UNION ALL
  SELECT 'failed_attempt_atomic_rollback',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('invalidRows',count(*))
  FROM public.sales_order_revisions revision
  JOIN public.sales_headers source ON source.company_id=revision.company_id
    AND source.id=revision.source_sales_id
  JOIN public.sales_headers replacement
    ON replacement.company_id=revision.company_id
    AND replacement.id=revision.replacement_sales_id
  WHERE revision.status='PENDING' AND (
    source.document_status<>'DRAFT'
    OR source.order_runtime_status NOT IN('CONFIRMED','RESERVED')
    OR replacement.document_status<>'DRAFT'
    OR replacement.order_runtime_status NOT IN('DRAFT_INPUT','SCHEDULED')
    OR EXISTS(SELECT 1 FROM public.sales_stock_reservations reservation
      WHERE reservation.company_id=revision.company_id
        AND reservation.sales_id=revision.replacement_sales_id)
    OR EXISTS(SELECT 1 FROM public.sales_invoice_snapshots invoice
      WHERE invoice.company_id=revision.company_id
        AND invoice.sales_id=revision.replacement_sales_id)
    OR EXISTS(SELECT 1 FROM public.sales_delivery_documents delivery
      WHERE delivery.company_id=revision.company_id
        AND delivery.sales_id=revision.replacement_sales_id))
  UNION ALL
  SELECT 'revision_suboperation_idempotency_namespace',
    CASE WHEN body~'sales_order_revision_child_idempotency_key'
      THEN 'PASS' ELSE 'SETUP' END,
    jsonb_build_object(
      'currentWrapperReusesRootKey',
        body~'cancel_pos_sales_order\(v_source.id,v_source.master_version,[[:space:]]*p_idempotency_key'
        AND body~'confirm_pos_sales_order_before_revision_core\([[:space:]]*p_sales_id,p_master_version,p_idempotency_key',
      'forwardFixApplied',EXISTS(SELECT 1 FROM private.kgs_schema_migrations
        WHERE version='20260903120000'))
  FROM definition
  UNION ALL
  SELECT 'pending_revision_inventory','INFO',jsonb_build_object(
    'pending',count(*) FILTER(WHERE status='PENDING'),
    'applied',count(*) FILTER(WHERE status='APPLIED'),
    'abandoned',count(*) FILTER(WHERE status='ABANDONED'))
  FROM public.sales_order_revisions
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'SETUP' THEN 2
  WHEN 'PASS' THEN 3 ELSE 4 END,check_name;
