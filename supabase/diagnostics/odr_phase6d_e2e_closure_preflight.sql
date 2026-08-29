-- ODR-6D authenticated end-to-end closure preflight.
-- SAFETY: SELECT-only. This file intentionally blocks closure when an active
-- consumer still understands legacy POSTED Sale only.
WITH dependency_versions(version) AS (
  VALUES('20260828110000'::TEXT),('20260828130000'),('20260828140000'),
    ('20260828160000'),('20260828170000'),('20260828190000'),
    ('20260828200000'),('20260828210000'),('20260828220000'),
    ('20260828230000'),('20260828240000'),('20260828250000'),
    ('20260828260000'),('20260828270000'),('20260828280000'),
    ('20260829090000'),('20260829100000'),('20260829110000'),
    ('20260829120000')
), protected_relations(relation_name) AS (
  VALUES('sales_stock_reservations'::TEXT),('sales_stock_reservation_lines'),
    ('sales_stock_reservation_audit'),('sales_dispatch_allocations'),
    ('sales_order_procurement_demands'),('sales_order_procurement_demand_lines'),
    ('sales_order_procurement_demand_audit'),
    ('sales_order_procurement_amendments'),
    ('sales_order_procurement_amendment_audit'),
    ('sales_dispatch_financial_effects'),
    ('sales_dispatch_financial_effect_audit'),
    ('sales_payment_verification_requests'),
    ('sales_payment_verification_audit')
), return_contract AS (
  SELECT signature,to_regprocedure(signature) routine_oid
  FROM unnest(ARRAY[
    'public.get_pos_returnable_sales(text,integer)',
    'public.save_sales_return_draft(uuid,bigint,uuid,uuid,text,text,jsonb,jsonb)',
    'private.acp5h_post_sales_return_core(uuid,bigint,uuid)'
  ]) signature
), ar_contract AS (
  SELECT signature,to_regprocedure(signature) routine_oid
  FROM unnest(ARRAY[
    'public.get_finance_ar_aging(date,uuid,uuid)',
    'public.get_finance_customer_statement(uuid,date,date,uuid)'
  ]) signature
), checks AS (
  SELECT 'odr6d_migration_chain'::TEXT check_name,
    CASE WHEN count(*) FILTER(WHERE migration.version IS NULL)=0
      THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('expected',count(*),'missing',COALESCE(jsonb_agg(
      dependency.version ORDER BY dependency.version)
      FILTER(WHERE migration.version IS NULL),'[]'::JSONB)) details
  FROM dependency_versions dependency
  LEFT JOIN private.kgs_schema_migrations migration
    ON migration.version=dependency.version

  UNION ALL
  SELECT 'active_finance_posting_queue',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('runCount',count(*))
  FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')

  UNION ALL
  SELECT 'open_finance_posting_exception',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('exceptionRows',count(*))
  FROM public.finance_posting_exceptions WHERE status<>'RESOLVED'

  UNION ALL
  SELECT 'nonterminal_offline_submission',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('submissionCount',count(*))
  FROM public.pos_offline_sale_submissions
  WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')

  UNION ALL
  SELECT 'protected_odr_table_browser_write_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('writableRelations',COALESCE(jsonb_agg(DISTINCT
      privilege.table_name ORDER BY privilege.table_name),'[]'::JSONB))
  FROM information_schema.table_privileges privilege
  JOIN protected_relations protected ON protected.relation_name=privilege.table_name
  WHERE privilege.table_schema='public'
    AND privilege.grantee IN('anon','authenticated','PUBLIC')
    AND privilege.privilege_type IN('INSERT','UPDATE','DELETE','TRUNCATE')

  UNION ALL
  SELECT 'active_company_context_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('rowCount',count(*))
  FROM public.user_active_company_contexts context_row
  LEFT JOIN public.company_memberships membership
    ON membership.company_id=context_row.company_id
   AND membership.user_id=context_row.user_id AND membership.status='ACTIVE'
  LEFT JOIN public.profiles profile ON profile.id=context_row.user_id
  WHERE membership.user_id IS NULL AND COALESCE(profile.role::TEXT,'')<>'super_admin'

  UNION ALL
  SELECT 'reservation_header_line_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('reservationCount',count(*))
  FROM public.sales_stock_reservations reservation
  LEFT JOIN LATERAL (SELECT sum(line.reserved_base_qty) reserved,
      sum(line.released_base_qty) released,
      sum(line.dispatched_base_qty) dispatched
    FROM public.sales_stock_reservation_lines line
    WHERE line.company_id=reservation.company_id
      AND line.reservation_id=reservation.id) totals ON TRUE
  WHERE round(reservation.total_reserved_base_qty,6)<>
      round(COALESCE(totals.reserved,0),6)
    OR round(reservation.total_released_base_qty,6)<>
      round(COALESCE(totals.released,0),6)
    OR round(reservation.total_dispatched_base_qty,6)<>
      round(COALESCE(totals.dispatched,0),6)

  UNION ALL
  SELECT 'confirmed_order_document_coverage',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('rowCount',count(*))
  FROM public.sales_stock_reservations reservation
  JOIN public.sales_headers sale ON sale.company_id=reservation.company_id
    AND sale.id=reservation.sales_id
  LEFT JOIN public.sales_invoice_snapshots invoice
    ON invoice.company_id=sale.company_id AND invoice.sales_id=sale.id
  LEFT JOIN public.sales_delivery_documents delivery
    ON delivery.company_id=sale.company_id AND delivery.sales_id=sale.id
   AND delivery.reservation_id=reservation.id
  WHERE invoice.id IS NULL OR delivery.id IS NULL

  UNION ALL
  SELECT 'confirmed_order_final_invoice_identity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('rowCount',count(*))
  FROM public.sales_invoice_snapshots invoice
  JOIN public.sales_headers sale ON sale.company_id=invoice.company_id
    AND sale.id=invoice.sales_id
  WHERE invoice.snapshot_provenance='ORDER_CONFIRM'
    AND (invoice.invoice_no!~'^INV-[0-9]{8}-[0-9]{10}$'
      OR sale.invoice_no IS DISTINCT FROM invoice.invoice_no
      OR invoice.snapshot_payload->>'invoiceNo' IS DISTINCT FROM invoice.invoice_no)

  UNION ALL
  SELECT 'dispatch_allocation_movement_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('allocationRows',count(*))
  FROM public.sales_dispatch_allocations allocation
  LEFT JOIN public.stock_movements movement
    ON movement.company_id=allocation.company_id
   AND movement.id=allocation.stock_movement_id
  WHERE movement.id IS NULL OR round(abs(movement.qty_change),6)<>
    round(allocation.dispatched_base_qty,6)

  UNION ALL
  SELECT 'procurement_demand_header_line_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('demandCount',count(*))
  FROM public.sales_order_procurement_demands demand
  WHERE demand.total_demand_base_qty IS DISTINCT FROM COALESCE((
      SELECT sum(line.demand_base_qty)
      FROM public.sales_order_procurement_demand_lines line
      WHERE line.company_id=demand.company_id AND line.demand_id=demand.id),0)
    OR demand.total_released_base_qty IS DISTINCT FROM COALESCE((
      SELECT sum(line.released_base_qty)
      FROM public.sales_order_procurement_demand_lines line
      WHERE line.company_id=demand.company_id AND line.demand_id=demand.id),0)

  UNION ALL
  SELECT 'payment_request_maker_checker_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('rowCount',count(*))
  FROM public.sales_payment_verification_requests request_row
  WHERE request_row.status IN('VERIFIED','REJECTED') AND
    (request_row.reviewed_by IS NULL OR request_row.reviewed_at IS NULL
      OR request_row.requested_by=request_row.reviewed_by)

  UNION ALL
  SELECT 'odr_finance_event_journal_coverage',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('rowCount',count(*))
  FROM public.financial_events event_row
  LEFT JOIN public.finance_journals journal_row
    ON journal_row.company_id=event_row.company_id
   AND journal_row.financial_event_id=event_row.id
   AND journal_row.status='POSTED'
  WHERE event_row.system_event_key IN('SALE_DISPATCHED','SALE_PAYMENT_VERIFIED')
    AND ((event_row.status::TEXT='POSTED' AND journal_row.id IS NULL)
      OR (event_row.status::TEXT<>'POSTED' AND journal_row.id IS NOT NULL))

  UNION ALL
  SELECT 'posted_journal_balance',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('journalCount',count(*))
  FROM public.finance_journals journal_row
  WHERE journal_row.status='POSTED' AND (journal_row.total_debit<=0
    OR journal_row.total_debit<>journal_row.total_credit)

  UNION ALL
  SELECT 'odr_sales_return_consumer_contract',
    CASE WHEN count(*)=3 AND count(*) FILTER(WHERE routine_oid IS NOT NULL
      AND pg_get_functiondef(routine_oid) ILIKE '%sales_dispatch_allocations%')=3
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('expected',3,'odrAwareRows',count(*) FILTER(
      WHERE routine_oid IS NOT NULL
        AND pg_get_functiondef(routine_oid) ILIKE '%sales_dispatch_allocations%'),
      'missingOrLegacyOnly',COALESCE(jsonb_agg(signature ORDER BY signature)
        FILTER(WHERE routine_oid IS NULL OR
          pg_get_functiondef(routine_oid) NOT ILIKE '%sales_dispatch_allocations%'),
        '[]'::JSONB))
  FROM return_contract

  UNION ALL
  SELECT 'odr_ar_reporting_consumer_contract',
    CASE WHEN count(*)=2 AND count(*) FILTER(WHERE routine_oid IS NOT NULL
      AND pg_get_functiondef(routine_oid) ILIKE '%sales_dispatch_financial_effects%')=2
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('expected',2,'odrAwareRows',count(*) FILTER(
      WHERE routine_oid IS NOT NULL AND
        pg_get_functiondef(routine_oid) ILIKE '%sales_dispatch_financial_effects%'),
      'missingOrLegacyOnly',COALESCE(jsonb_agg(signature ORDER BY signature)
        FILTER(WHERE routine_oid IS NULL OR
          pg_get_functiondef(routine_oid) NOT ILIKE '%sales_dispatch_financial_effects%'),
        '[]'::JSONB))
  FROM ar_contract

  UNION ALL
  SELECT 'odr_tempo_collection_consumer_contract',
    CASE WHEN to_regprocedure(
      'public.save_customer_receipt_draft_with_disposition(uuid,bigint,uuid,date,uuid,text,text,text,numeric,text,jsonb)')
      IS NOT NULL AND pg_get_functiondef(to_regprocedure(
      'public.save_customer_receipt_draft_with_disposition(uuid,bigint,uuid,date,uuid,text,text,text,numeric,text,jsonb)'))
      ILIKE '%sales_dispatch_financial_effects%' THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('requiredDesign',jsonb_build_array(
      'ODR TEMPO collection may allocate only dispatched receivable',
      'payment before Dispatch remains Customer Advance',
      'legacy POSTED Sale collection remains compatible'))

  UNION ALL
  SELECT 'authenticated_odr6d_uat_matrix','SETUP',jsonb_build_object(
    'required',jsonb_build_array(
      'online non-TEMPO exact retry and stale version',
      'TEMPO scheduled and backorder',
      'negative-stock authorization and session demand',
      'partial then final Dispatch and Received',
      'payment verify reject maker-checker and controlled queue',
      'Sales Return after ODR Dispatch',
      'AR aging statement and collection after ODR TEMPO Dispatch',
      'two Company and role denial',
      'offline fail-closed hard refresh and rollback rehearsal'))
), inventory AS (
  SELECT 'odr6d_runtime_inventory'::TEXT check_name,'INFO'::TEXT status,
    jsonb_build_object(
      'reservations',(SELECT count(*) FROM public.sales_stock_reservations),
      'openReservations',(SELECT count(*) FROM public.sales_stock_reservations
        WHERE status IN('OPEN','PARTIALLY_DISPATCHED')),
      'linkedDeliveries',(SELECT count(*) FROM public.sales_delivery_documents
        WHERE reservation_id IS NOT NULL),
      'dispatchAllocations',(SELECT count(*) FROM public.sales_dispatch_allocations),
      'procurementDemands',(SELECT count(*) FROM public.sales_order_procurement_demands),
      'paymentRequests',(SELECT count(*) FROM public.sales_payment_verification_requests),
      'odrHoldEvents',(SELECT count(*) FROM public.financial_events
        WHERE system_event_key IN('SALE_DISPATCHED','SALE_PAYMENT_VERIFIED')
          AND status::TEXT='HOLD'),
      'odrPostedEvents',(SELECT count(*) FROM public.financial_events
        WHERE system_event_key IN('SALE_DISPATCHED','SALE_PAYMENT_VERIFIED')
          AND status::TEXT='POSTED'),
      'controlledCompanies',(SELECT count(*) FROM public.finance_company_policies
        WHERE posting_mode='CONTROLLED'),
      'automaticCompanies',(SELECT count(*) FROM public.finance_company_policies
        WHERE posting_mode='AUTOMATIC')) details
)
SELECT * FROM (SELECT * FROM checks UNION ALL SELECT * FROM inventory) result
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'SETUP' THEN 2
  WHEN 'PASS' THEN 3 ELSE 4 END,check_name;
