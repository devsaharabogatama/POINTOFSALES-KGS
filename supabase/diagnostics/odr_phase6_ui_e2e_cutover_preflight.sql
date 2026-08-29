-- ODR-6 UI and authenticated E2E cutover preflight.
-- SAFETY: SELECT-only. No Order, Reservation, Dispatch, Procurement, Payment,
-- Finance policy, Event, Journal, permission, or business data mutation.
WITH dependency_versions(version) AS (
  VALUES('20260828110000'::TEXT),('20260828130000'),('20260828140000'),
    ('20260828160000'),('20260828170000'),('20260828190000'),
    ('20260828200000'),('20260828210000'),('20260828220000'),
    ('20260828230000'),('20260828240000'),('20260828250000'),
    ('20260828260000'),('20260828270000'),('20260828280000'),
    ('20260829090000')
),required_routines(routine_name,channel) AS (
  VALUES
    ('confirm_pos_sales_order'::TEXT,'POS'),
    ('cancel_pos_sales_order','POS'),
    ('get_pos_sales_orders','POS'),
    ('dispatch_sales_delivery','INVENTORY'),
    ('confirm_sales_delivery_received','INVENTORY'),
    ('get_inventory_delivery_dispatch_workspace','INVENTORY'),
    ('get_purchase_procurement_demands','PURCHASE'),
    ('get_finance_sales_payment_verifications','FINANCE'),
    ('review_sales_payment_verification','FINANCE')
),routine_state AS (
  SELECT required.routine_name,required.channel,
    EXISTS(SELECT 1 FROM pg_proc routine
      JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
      WHERE namespace.nspname='public' AND routine.proname=required.routine_name)
      routine_exists,
    EXISTS(SELECT 1 FROM information_schema.routine_privileges privilege
      WHERE privilege.specific_schema='public'
        AND privilege.routine_name=required.routine_name
        AND privilege.grantee='authenticated'
        AND privilege.privilege_type='EXECUTE') authenticated_execute,
    EXISTS(SELECT 1 FROM information_schema.routine_privileges privilege
      WHERE privilege.specific_schema='public'
        AND privilege.routine_name=required.routine_name
        AND privilege.grantee='anon'
        AND privilege.privilege_type='EXECUTE') anon_execute
  FROM required_routines required
),protected_relations(relation_name) AS (
  VALUES
    ('sales_stock_reservations'::TEXT),
    ('sales_stock_reservation_lines'),
    ('sales_stock_reservation_audit'),
    ('sales_dispatch_allocations'),
    ('sales_order_procurement_demands'),
    ('sales_order_procurement_demand_lines'),
    ('sales_order_procurement_demand_audit'),
    ('sales_order_procurement_amendments'),
    ('sales_order_procurement_amendment_audit'),
    ('sales_dispatch_financial_effects'),
    ('sales_dispatch_financial_effect_audit'),
    ('sales_payment_verification_requests'),
    ('sales_payment_verification_audit')
),checks AS (
  SELECT 'odr6_migration_dependencies'::TEXT check_name,
    CASE WHEN count(*) FILTER(WHERE migration.version IS NULL)=0
      THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('expected',count(*),'missing',COALESCE(jsonb_agg(
      dependency.version ORDER BY dependency.version)
      FILTER(WHERE migration.version IS NULL),'[]'::JSONB)) details
  FROM dependency_versions dependency
  LEFT JOIN private.kgs_schema_migrations migration
    ON migration.version=dependency.version

  UNION ALL
  SELECT 'canonical_odr_browser_routines',
    CASE WHEN count(*) FILTER(WHERE NOT routine_exists
      OR NOT authenticated_execute OR anon_execute)=0
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('expected',count(*),'invalid',COALESCE(jsonb_agg(
      jsonb_build_object('name',routine_name,'channel',channel,
        'exists',routine_exists,'authenticatedExecute',authenticated_execute,
        'anonExecute',anon_execute) ORDER BY channel,routine_name)
      FILTER(WHERE NOT routine_exists OR NOT authenticated_execute OR anon_execute),
      '[]'::JSONB))
  FROM routine_state

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
  SELECT 'posted_journal_balance',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('journalCount',count(*))
  FROM public.finance_journals journal
  WHERE journal.status='POSTED'
    AND (journal.total_debit<=0 OR journal.total_debit<>journal.total_credit)

  UNION ALL
  SELECT 'reservation_header_line_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('reservationCount',count(*))
  FROM (SELECT reservation.id
    FROM public.sales_stock_reservations reservation
    LEFT JOIN public.sales_stock_reservation_lines line
      ON line.company_id=reservation.company_id
     AND line.reservation_id=reservation.id
    GROUP BY reservation.id,reservation.total_reserved_base_qty,
      reservation.total_released_base_qty,reservation.total_dispatched_base_qty
    HAVING round(COALESCE(sum(line.reserved_base_qty),0),6)<>
        round(reservation.total_reserved_base_qty,6)
      OR round(COALESCE(sum(line.released_base_qty),0),6)<>
        round(reservation.total_released_base_qty,6)
      OR round(COALESCE(sum(line.dispatched_base_qty),0),6)<>
        round(reservation.total_dispatched_base_qty,6)) invalid

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
  SELECT 'odr_finance_event_journal_coverage',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('rowCount',count(*))
  FROM public.financial_events event
  LEFT JOIN public.finance_journals journal
    ON journal.company_id=event.company_id
   AND journal.financial_event_id=event.id AND journal.status='POSTED'
  WHERE event.system_event_key IN('SALE_DISPATCHED','SALE_PAYMENT_VERIFIED')
    AND ((event.status::TEXT='POSTED' AND journal.id IS NULL)
      OR (event.status::TEXT<>'POSTED' AND journal.id IS NOT NULL))

  UNION ALL
  SELECT 'odr_permission_runtime_state',
    CASE WHEN count(*)=4 AND count(*) FILTER(WHERE permission_key IN(
        'inventory.delivery_documents','purchase.supplier_orders',
        'finance.sales_payment_verification')
      AND enforcement_status<>'ENFORCED')=0
      AND count(*) FILTER(WHERE permission_key='sales.sales_orders')=1
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('permissions',COALESCE(jsonb_object_agg(
      permission_key,enforcement_status),'{}'::JSONB))
  FROM public.access_permission_catalog
  WHERE permission_key IN('sales.sales_orders','inventory.delivery_documents',
    'purchase.supplier_orders','finance.sales_payment_verification')

  UNION ALL
  SELECT 'legacy_pos_final_post_cutover','REVIEW',
    jsonb_build_object('requiredDesign',jsonb_build_array(
      'online POS confirmation must call confirm_pos_sales_order',
      'confirmed and scheduled Orders must be separate from Draft',
      'post_pos_sale_with_pricelist remains historical/offline compatibility only',
      'no client fallback from canonical confirm to legacy final Post'))

  UNION ALL
  SELECT 'legacy_delivery_status_cutover','REVIEW',
    jsonb_build_object('requiredDesign',jsonb_build_array(
      'linked READY Delivery dispatches only through dispatch_sales_delivery',
      'linked DISPATCHED Delivery completes only through confirm_sales_delivery_received',
      'legacy update_sales_delivery_status remains historical-only',
      'Inventory UI must show reservation remaining quantity'))

  UNION ALL
  SELECT 'offline_order_cutover_scope','REVIEW',
    jsonb_build_object('rule','Offline final Sale must remain fail-closed until reservation replay parity is implemented',
      'nonterminalSubmissions',(SELECT count(*)
        FROM public.pos_offline_sale_submissions
        WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')))

  UNION ALL
  SELECT 'authenticated_odr6_uat_scope','SETUP',
    jsonb_build_object('requiredChannels',jsonb_build_array(
      'POS confirm/cancel/order list','Inventory partial/full dispatch and received',
      'Purchasing demand/amendment visibility','Finance verify/reject and controlled queue'),
      'requiredBoundaries',jsonb_build_array(
      'negative stock','TEMPO and non-TEMPO','two Company','role denial',
      'exact retry','stale version','Return compatibility','hard refresh'))
),inventory AS (
  SELECT 'odr6_cutover_inventory'::TEXT check_name,'INFO'::TEXT status,
    jsonb_build_object(
      'draftSales',(SELECT count(*) FROM public.sales_headers
        WHERE document_status='DRAFT'),
      'reservedOrders',(SELECT count(*) FROM public.sales_stock_reservations
        WHERE status='OPEN'),
      'linkedDeliveries',(SELECT count(*) FROM public.sales_delivery_documents
        WHERE reservation_id IS NOT NULL),
      'dispatchAllocations',(SELECT count(*) FROM public.sales_dispatch_allocations),
      'procurementDemands',(SELECT count(*)
        FROM public.sales_order_procurement_demands),
      'paymentVerificationRequests',(SELECT count(*)
        FROM public.sales_payment_verification_requests),
      'odrHoldEvents',(SELECT count(*) FROM public.financial_events
        WHERE system_event_key IN('SALE_DISPATCHED','SALE_PAYMENT_VERIFIED')
          AND status::TEXT='HOLD'),
      'controlledCompanies',(SELECT count(*) FROM public.finance_company_policies
        WHERE posting_mode='CONTROLLED'),
      'automaticCompanies',(SELECT count(*) FROM public.finance_company_policies
        WHERE posting_mode='AUTOMATIC'),
      'openCashierSessions',(SELECT count(*) FROM public.cashier_sessions
        WHERE status='OPEN'::public.session_status)) details
)
SELECT * FROM (SELECT * FROM checks UNION ALL SELECT * FROM inventory) result
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'REVIEW' THEN 2
  WHEN 'SETUP' THEN 3 WHEN 'PASS' THEN 4 ELSE 5 END,check_name;
