-- Sales Order revision preflight. SAFETY: SELECT-only.
WITH checks AS (
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
  SELECT 'revision_migration_dependencies',
    CASE WHEN count(*)=6 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('expected',6,'ledgerRows',count(*))
  FROM private.kgs_schema_migrations
  WHERE version IN('20260828100000','20260828110000','20260828280000',
    '20260830100000','20260830110000','20260830120000')
  UNION ALL
  SELECT 'canonical_revision_dependencies',
    CASE WHEN count(*)=4 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('expected',4,'routineRows',count(*))
  FROM (VALUES
    (to_regprocedure('public.save_pos_sale_draft_with_pricelist(jsonb)')),
    (to_regprocedure('public.cancel_pos_sale_draft(uuid,bigint,uuid,text)')),
    (to_regprocedure('public.confirm_pos_sales_order(uuid,bigint,uuid,text)')),
    (to_regprocedure('public.cancel_pos_sales_order(uuid,bigint,uuid,text)'))
  ) routine(oid) WHERE oid IS NOT NULL
  UNION ALL
  SELECT 'eligible_revision_source_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('invalidRows',count(*))
  FROM public.sales_headers sale
  LEFT JOIN public.sales_stock_reservations reservation
    ON reservation.company_id=sale.company_id AND reservation.sales_id=sale.id
  WHERE sale.document_status='DRAFT'
    AND sale.order_runtime_status IN('CONFIRMED','RESERVED')
    AND (reservation.id IS NULL OR reservation.status<>'OPEN'
      OR reservation.total_dispatched_base_qty<>0)
  UNION ALL
  SELECT 'revision_foundation_state',
    CASE WHEN to_regclass('public.sales_order_revisions') IS NULL
      AND to_regclass('public.sales_order_revision_audit') IS NULL
      THEN 'SETUP' ELSE 'REVIEW' END,
    jsonb_build_object('revisionExists',
      to_regclass('public.sales_order_revisions') IS NOT NULL,
      'auditExists',to_regclass('public.sales_order_revision_audit') IS NOT NULL)
  UNION ALL
  SELECT 'revision_runtime_inventory','INFO',jsonb_build_object(
    'eligibleOrders',count(*),
    'withPendingPayment',count(*) FILTER(WHERE EXISTS(
      SELECT 1 FROM public.sales_payment_verification_requests request
      WHERE request.company_id=sale.company_id AND request.sales_id=sale.id
        AND request.status='PENDING')),
    'withVerifiedPayment',count(*) FILTER(WHERE EXISTS(
      SELECT 1 FROM public.sales_payment_verification_requests request
      WHERE request.company_id=sale.company_id AND request.sales_id=sale.id
        AND request.status='VERIFIED')))
  FROM public.sales_headers sale
  JOIN public.sales_stock_reservations reservation
    ON reservation.company_id=sale.company_id AND reservation.sales_id=sale.id
  WHERE sale.document_status='DRAFT'
    AND sale.order_runtime_status IN('CONFIRMED','RESERVED')
    AND reservation.status='OPEN'
    AND reservation.total_dispatched_base_qty=0
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'REVIEW' THEN 2
  WHEN 'SETUP' THEN 3 WHEN 'PASS' THEN 4 ELSE 5 END,check_name;
