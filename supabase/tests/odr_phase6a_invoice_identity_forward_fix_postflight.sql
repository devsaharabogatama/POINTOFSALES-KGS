-- ODR-6A.1 Invoice identity forward-fix postflight. SELECT-only.
WITH checks AS (
  SELECT 'migration_ledger'::TEXT check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(count(*)-1)::BIGINT violation_rows,
    jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260828280000'

  UNION ALL
  SELECT 'canonical_confirm_invoice_identity_order',
    CASE WHEN allocate_pos>0 AND document_pos>allocate_pos THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN allocate_pos>0 AND document_pos>allocate_pos THEN 0 ELSE 1 END,
    jsonb_build_object('allocationPosition',allocate_pos,
      'documentPosition',document_pos)
  FROM (SELECT strpos(definition,'ensure_confirmed_order_invoice_identity') allocate_pos,
      strpos(definition,'ensure_confirmed_order_documents') document_pos
    FROM (SELECT pg_get_functiondef(
      'public.confirm_pos_sales_order(uuid,bigint,uuid,text)'::regprocedure
    ) definition) source) runtime

  UNION ALL
  SELECT 'private_invoice_identity_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('authenticatedExecutableRows',count(*))
  FROM information_schema.routine_privileges privilege
  WHERE privilege.specific_schema='private'
    AND privilege.routine_name='ensure_confirmed_order_invoice_identity'
    AND privilege.grantee IN('anon','authenticated','PUBLIC')
    AND privilege.privilege_type='EXECUTE'

  UNION ALL
  SELECT 'order_confirm_final_invoice_identity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('invalidRows',count(*))
  FROM public.sales_invoice_snapshots invoice
  JOIN public.sales_headers sale ON sale.company_id=invoice.company_id
    AND sale.id=invoice.sales_id
  WHERE invoice.snapshot_provenance='ORDER_CONFIRM'
    AND (invoice.invoice_no!~'^INV-[0-9]{8}-[0-9]{10}$'
      OR sale.invoice_no IS DISTINCT FROM invoice.invoice_no
      OR invoice.snapshot_payload->>'invoiceNo' IS DISTINCT FROM invoice.invoice_no)

  UNION ALL
  SELECT 'linked_delivery_invoice_identity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('invalidRows',count(*))
  FROM public.sales_delivery_documents delivery
  JOIN public.sales_invoice_snapshots invoice
    ON invoice.company_id=delivery.company_id
   AND invoice.id=delivery.invoice_snapshot_id
  WHERE delivery.reservation_id IS NOT NULL
    AND delivery.snapshot_payload->>'invoiceNo' IS DISTINCT FROM invoice.invoice_no

  UNION ALL
  SELECT 'duplicate_invoice_identity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('duplicateGroups',count(*))
  FROM (SELECT company_id,invoice_no FROM public.sales_invoice_snapshots
    GROUP BY company_id,invoice_no HAVING count(*)>1) duplicate_row

  UNION ALL
  SELECT 'identity_repair_audit_coverage',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('snapshotRows',count(*))
  FROM public.sales_invoice_snapshots invoice
  WHERE invoice.snapshot_provenance='ORDER_CONFIRM'
    AND invoice.snapshot_version>1
    AND NOT EXISTS(SELECT 1 FROM public.sales_document_audit audit
      WHERE audit.company_id=invoice.company_id
        AND audit.document_type='SALES_INVOICE'
        AND audit.document_id=invoice.id AND audit.sales_id=invoice.sales_id
        AND audit.action='REPAIR_IDENTITY')

  UNION ALL
  SELECT 'invoice_immutable_trigger_state',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    abs(count(*)-1)::BIGINT,jsonb_build_object('enabledTriggerRows',count(*))
  FROM pg_trigger trigger_row
  WHERE trigger_row.tgrelid='public.sales_invoice_snapshots'::regclass
    AND trigger_row.tgname='sld_invoice_history_immutable'
    AND trigger_row.tgenabled='O'

  UNION ALL
  SELECT 'delivery_guard_trigger_state',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    abs(count(*)-1)::BIGINT,jsonb_build_object('enabledTriggerRows',count(*))
  FROM pg_trigger trigger_row
  WHERE trigger_row.tgrelid='public.sales_delivery_documents'::regclass
    AND trigger_row.tgname='sld_delivery_update_guard'
    AND trigger_row.tgenabled='O'

  UNION ALL
  SELECT 'active_finance_posting_queue',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('runCount',count(*))
  FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
),inventory AS (
  SELECT 'invoice_identity_runtime_inventory'::TEXT check_name,'INFO'::TEXT status,
    0::BIGINT violation_rows,jsonb_build_object(
      'orderConfirmInvoices',(SELECT count(*) FROM public.sales_invoice_snapshots
        WHERE snapshot_provenance='ORDER_CONFIRM'),
      'repairedInvoices',(SELECT count(*) FROM public.sales_invoice_snapshots
        WHERE snapshot_provenance='ORDER_CONFIRM' AND snapshot_version>1),
      'linkedDeliveries',(SELECT count(*) FROM public.sales_delivery_documents
        WHERE reservation_id IS NOT NULL),
      'openReservations',(SELECT count(*) FROM public.sales_stock_reservations
        WHERE status IN('OPEN','PARTIALLY_DISPATCHED')),
      'odrFinancialEvents',(SELECT count(*) FROM public.financial_events
        WHERE system_event_key IN('SALE_DISPATCHED','SALE_PAYMENT_VERIFIED')))
)
SELECT * FROM (SELECT * FROM checks UNION ALL SELECT * FROM inventory) result
ORDER BY check_name;
