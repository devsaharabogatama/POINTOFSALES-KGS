-- Sales Order revision closing gate. SAFETY: SELECT-only.
WITH routine_state AS (
  SELECT count(*) routine_rows FROM (VALUES
    (to_regprocedure('public.start_pos_sales_order_revision(uuid,bigint,uuid,uuid,text)')),
    (to_regprocedure('public.confirm_pos_sales_order(uuid,bigint,uuid,text)')),
    (to_regprocedure('public.cancel_pos_sale_draft(uuid,bigint,uuid,text)')),
    (to_regprocedure('public.get_sales_order_revision_links()')),
    (to_regprocedure('public.get_pos_sales_order_revision_eligibility(uuid)')),
    (to_regprocedure('private.sales_order_revision_child_idempotency_key(uuid,text)')),
    (to_regprocedure('private.confirm_pos_sales_order_before_revision_core(uuid,bigint,uuid,text)')),
    (to_regprocedure('private.cancel_pos_sale_draft_before_revision_core(uuid,bigint,uuid,text)')),
    (to_regprocedure('private.cancel_pos_sales_order_before_revision_core(uuid,bigint,uuid,text)'))
  ) routine(oid) WHERE oid IS NOT NULL
), checks AS (
  SELECT 'migration_ledger' check_name,
    CASE WHEN count(*)=3 THEN 'PASS' ELSE 'FAIL' END status,
    abs(3-count(*))::BIGINT violation_rows,
    jsonb_build_object('expected',3,'ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations
  WHERE version IN('20260903100000','20260903110000','20260903120000')
  UNION ALL
  SELECT 'required_revision_relations',
    CASE WHEN count(*)=2 THEN 'PASS' ELSE 'FAIL' END,
    abs(2-count(*))::BIGINT,
    jsonb_build_object('expected',2,'relationRows',count(*))
  FROM (VALUES(to_regclass('public.sales_order_revisions')),
    (to_regclass('public.sales_order_revision_audit'))) relation(oid)
  WHERE oid IS NOT NULL
  UNION ALL
  SELECT 'required_revision_routines',
    CASE WHEN routine_rows=9 THEN 'PASS' ELSE 'FAIL' END,
    abs(9-routine_rows)::BIGINT,
    jsonb_build_object('expected',9,'routineRows',routine_rows)
  FROM routine_state
  UNION ALL
  SELECT 'browser_revision_table_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::BIGINT,
    jsonb_build_object('privilegeRows',count(*))
  FROM information_schema.role_table_grants
  WHERE table_schema='public'
    AND table_name IN('sales_order_revisions','sales_order_revision_audit')
    AND grantee IN('anon','authenticated')
  UNION ALL
  SELECT 'revision_rls_state',
    CASE WHEN count(*)=2 THEN 'PASS' ELSE 'FAIL' END,
    abs(2-count(*))::BIGINT,jsonb_build_object('enabledRelations',count(*))
  FROM pg_class relation JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
  WHERE namespace.nspname='public'
    AND relation.relname IN('sales_order_revisions','sales_order_revision_audit')
    AND relation.relrowsecurity
  UNION ALL
  SELECT 'revision_lifecycle_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::BIGINT,
    jsonb_build_object('rowCount',count(*))
  FROM public.sales_order_revisions revision
  JOIN public.sales_headers source ON source.company_id=revision.company_id
    AND source.id=revision.source_sales_id
  JOIN public.sales_headers replacement
    ON replacement.company_id=revision.company_id
    AND replacement.id=revision.replacement_sales_id
  WHERE (revision.status='PENDING' AND (
      source.document_status<>'DRAFT'
      OR source.order_runtime_status NOT IN('CONFIRMED','RESERVED')
      OR replacement.document_status<>'DRAFT'
      OR replacement.order_runtime_status NOT IN('DRAFT_INPUT','SCHEDULED')))
    OR (revision.status='APPLIED' AND (
      source.document_status<>'CANCELED'
      OR source.order_runtime_status<>'CANCELED'
      OR replacement.document_status<>'DRAFT'
      OR replacement.order_runtime_status NOT IN('CONFIRMED','RESERVED')))
  UNION ALL
  SELECT 'pending_revision_zero_final_effect',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::BIGINT,
    jsonb_build_object('rowCount',count(*))
  FROM public.sales_order_revisions revision
  WHERE revision.status='PENDING' AND (
    EXISTS(SELECT 1 FROM public.sales_stock_reservations reservation
      WHERE reservation.company_id=revision.company_id
        AND reservation.sales_id=revision.replacement_sales_id)
    OR EXISTS(SELECT 1 FROM public.sales_invoice_snapshots invoice
      WHERE invoice.company_id=revision.company_id
        AND invoice.sales_id=revision.replacement_sales_id)
    OR EXISTS(SELECT 1 FROM public.sales_delivery_documents delivery
      WHERE delivery.company_id=revision.company_id
        AND delivery.sales_id=revision.replacement_sales_id)
    OR EXISTS(SELECT 1 FROM public.financial_events event
      WHERE event.company_id=revision.company_id
        AND event.root_sales_id=revision.replacement_sales_id))
  UNION ALL
  SELECT 'applied_revision_dispatch_payment_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::BIGINT,
    jsonb_build_object('rowCount',count(*))
  FROM public.sales_order_revisions revision
  JOIN public.sales_stock_reservations reservation
    ON reservation.company_id=revision.company_id
    AND reservation.sales_id=revision.source_sales_id
  WHERE revision.status='APPLIED'
    AND (reservation.total_dispatched_base_qty<>0
      OR EXISTS(SELECT 1 FROM public.sales_payment_verification_requests request
        WHERE request.company_id=revision.company_id
          AND request.sales_id=revision.source_sales_id
          AND request.status='VERIFIED'))
  UNION ALL
  SELECT 'applied_revision_invoice_identity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::BIGINT,
    jsonb_build_object('rowCount',count(*))
  FROM public.sales_order_revisions revision
  JOIN public.sales_headers source ON source.company_id=revision.company_id
    AND source.id=revision.source_sales_id
  JOIN public.sales_headers replacement
    ON replacement.company_id=revision.company_id
    AND replacement.id=revision.replacement_sales_id
  WHERE revision.status='APPLIED'
    AND (source.invoice_no=replacement.invoice_no
      OR replacement.original_invoice_no IS DISTINCT FROM source.invoice_no)
  UNION ALL
  SELECT 'revision_runtime_inventory','INFO',0::BIGINT,jsonb_build_object(
    'pending',count(*) FILTER(WHERE status='PENDING'),
    'applied',count(*) FILTER(WHERE status='APPLIED'),
    'abandoned',count(*) FILTER(WHERE status='ABANDONED'),
    'auditRows',(SELECT count(*) FROM public.sales_order_revision_audit))
  FROM public.sales_order_revisions
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
