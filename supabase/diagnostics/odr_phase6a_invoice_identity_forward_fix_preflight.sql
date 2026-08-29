-- ODR-6A.1 confirmed Order Invoice identity forward-fix preflight.
-- SAFETY: SELECT-only.
WITH checks AS (
  SELECT 'odr6a_dependency'::TEXT check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('ledgerRows',count(*),'requiredVersion','20260828270000') details
  FROM private.kgs_schema_migrations WHERE version='20260828270000'

  UNION ALL
  SELECT 'active_finance_posting_queue',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('runCount',count(*))
  FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')

  UNION ALL
  SELECT 'nonterminal_offline_submission',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('submissionCount',count(*))
  FROM public.pos_offline_sale_submissions
  WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')

  UNION ALL
  SELECT 'invoice_number_sequence_state',
    CASE WHEN to_regclass('private.pos_invoice_number_seq') IS NOT NULL
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('sequenceExists',
      to_regclass('private.pos_invoice_number_seq') IS NOT NULL)

  UNION ALL
  SELECT 'order_confirm_draft_invoice_repair_scope',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BACKFILL' END,
    jsonb_build_object('snapshotRows',count(*),
      'companyCount',count(DISTINCT invoice.company_id))
  FROM public.sales_invoice_snapshots invoice
  WHERE invoice.snapshot_provenance='ORDER_CONFIRM'
    AND (invoice.invoice_no LIKE 'DRAFT-%'
      OR invoice.snapshot_payload->>'invoiceNo' LIKE 'DRAFT-%')

  UNION ALL
  SELECT 'order_confirm_repair_source_contract',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('invalidRows',count(*))
  FROM public.sales_invoice_snapshots invoice
  JOIN public.sales_headers sale ON sale.company_id=invoice.company_id
    AND sale.id=invoice.sales_id
  LEFT JOIN public.sales_stock_reservations reservation
    ON reservation.company_id=sale.company_id AND reservation.sales_id=sale.id
  WHERE invoice.snapshot_provenance='ORDER_CONFIRM'
    AND (invoice.invoice_no LIKE 'DRAFT-%'
      OR invoice.snapshot_payload->>'invoiceNo' LIKE 'DRAFT-%')
    AND (sale.document_status<>'DRAFT'
      OR sale.order_runtime_status NOT IN('CONFIRMED','RESERVED','CANCELED')
      OR reservation.id IS NULL
      OR sale.confirmed_by IS NULL OR sale.confirmed_at IS NULL)

  UNION ALL
  SELECT 'historical_invoice_identity_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('nonOrderConfirmDraftRows',count(*))
  FROM public.sales_invoice_snapshots invoice
  WHERE invoice.snapshot_provenance<>'ORDER_CONFIRM'
    AND (invoice.invoice_no LIKE 'DRAFT-%'
      OR invoice.snapshot_payload->>'invoiceNo' LIKE 'DRAFT-%')

  UNION ALL
  SELECT 'canonical_confirm_invoice_identity_state','SETUP',
    jsonb_build_object('helperExists',to_regprocedure(
      'private.ensure_confirmed_order_invoice_identity(uuid,uuid)') IS NOT NULL,
      'requiredOrder',ARRAY[
        'confirm reservation','allocate final Invoice identity',
        'create immutable Invoice and Delivery snapshots'])
),inventory AS (
  SELECT 'invoice_identity_runtime_inventory'::TEXT check_name,'INFO'::TEXT status,
    jsonb_build_object(
      'orderConfirmInvoices',(SELECT count(*) FROM public.sales_invoice_snapshots
        WHERE snapshot_provenance='ORDER_CONFIRM'),
      'draftIdentityInvoices',(SELECT count(*) FROM public.sales_invoice_snapshots
        WHERE snapshot_provenance='ORDER_CONFIRM' AND invoice_no LIKE 'DRAFT-%'),
      'linkedDeliveries',(SELECT count(*) FROM public.sales_delivery_documents
        WHERE reservation_id IS NOT NULL),
      'openReservations',(SELECT count(*) FROM public.sales_stock_reservations
        WHERE status IN('OPEN','PARTIALLY_DISPATCHED')))
)
SELECT * FROM (SELECT * FROM checks UNION ALL SELECT * FROM inventory) result
ORDER BY check_name;
