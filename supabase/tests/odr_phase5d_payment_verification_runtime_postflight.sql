-- ODR-5D payment verification runtime postflight. SELECT-only.
WITH checks AS (
  SELECT 'active_finance_posting_queue'::TEXT check_name,
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END status,count(*) violation_rows,
    jsonb_build_object('runCount',count(*)) details
  FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'automatic_posting_remains_closed',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('automaticCompanies',count(*))
  FROM public.finance_company_policies WHERE posting_mode='AUTOMATIC'
  UNION ALL
  SELECT 'migration_ledger',CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    abs(count(*)-1),jsonb_build_object('ledgerRows',count(*))
  FROM private.kgs_schema_migrations WHERE version='20260828240000'
  UNION ALL
  SELECT 'required_payment_verification_routines',
    CASE WHEN count(*)=11 THEN 'PASS' ELSE 'FAIL' END,abs(count(*)-11),
    jsonb_build_object('expected',11,'routineRows',count(*))
  FROM unnest(ARRAY[
    'private.odr5d_settlement_account_function(public.payment_methods)',
    'private.capture_sales_order_payment_requests(uuid,uuid,uuid)',
    'public.get_finance_sales_payment_verifications()',
    'public.review_sales_payment_verification(uuid,bigint,text,text,uuid)',
    'private.post_odr_payment_financial_event_core(uuid,uuid,bigint,uuid)',
    'private.post_financial_event_core_pre_odr5d(uuid,uuid,bigint,uuid)',
    'private.post_financial_event_core(uuid,uuid,bigint,uuid)',
    'private.f4b_financial_event_supported(public.financial_events)',
    'private.dispatch_sales_delivery_core_pre_odr5d(uuid,bigint,uuid,jsonb,text)',
    'private.dispatch_sales_delivery_core(uuid,bigint,uuid,jsonb,text)',
    'private.odr5d_close_cashier_session_legacy(uuid,bigint,numeric)'
  ]) signature WHERE to_regprocedure(signature) IS NOT NULL
  UNION ALL
  SELECT 'payment_verification_permission_enforced',
    CASE WHEN count(*)=1 AND min(enforcement_status)='ENFORCED'
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1 AND min(enforcement_status)='ENFORCED' THEN 0 ELSE 1 END,
    jsonb_build_object('rows',count(*),'statuses',COALESCE(jsonb_agg(
      enforcement_status ORDER BY enforcement_status),'[]'::JSONB))
  FROM public.access_permission_catalog
  WHERE permission_key='finance.sales_payment_verification'
  UNION ALL
  SELECT 'required_payment_verification_columns',
    CASE WHEN count(*)=6 THEN 'PASS' ELSE 'FAIL' END,abs(count(*)-6),
    jsonb_build_object('expected',6,'columnRows',count(*))
  FROM information_schema.columns column_state
  WHERE column_state.table_schema='public'
    AND column_state.table_name='sales_payment_verification_requests'
    AND column_state.column_name IN('cashier_session_id','store_id','pos_terminal_id',
      'effective_date','cash_drawer_movement_id','cash_drawer_reversal_movement_id')
  UNION ALL
  SELECT 'browser_payment_verification_table_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('privilegeRows',count(*))
  FROM information_schema.table_privileges privilege
  WHERE privilege.table_schema='public'
    AND privilege.table_name IN('sales_payment_verification_requests',
      'sales_payment_verification_audit')
    AND privilege.grantee IN('anon','authenticated','PUBLIC')
    AND privilege.privilege_type IN('INSERT','UPDATE','DELETE')
  UNION ALL
  SELECT 'private_payment_verification_runtime_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('authenticatedExecutableRows',count(*))
  FROM information_schema.routine_privileges privilege
  WHERE privilege.grantee IN('anon','authenticated','PUBLIC')
    AND privilege.privilege_type='EXECUTE' AND privilege.specific_schema='private'
    AND privilege.routine_name IN('capture_sales_order_payment_requests',
      'post_odr_payment_financial_event_core','post_financial_event_core_pre_odr5d',
      'dispatch_sales_delivery_core_pre_odr5d','odr5d_close_cashier_session_legacy')
  UNION ALL
  SELECT 'payment_request_event_source_contract',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('rowCount',count(*))
  FROM public.sales_payment_verification_requests request
  LEFT JOIN public.financial_events event ON event.company_id=request.company_id
    AND event.id=request.financial_event_id
  WHERE request.status='VERIFIED' AND (event.id IS NULL
    OR event.source_table<>'sales_payment_verification_requests'
    OR event.source_id<>request.id OR event.system_event_key<>'SALE_PAYMENT_VERIFIED'
    OR event.event_type::TEXT<>'PAYMENT_RECEIVED'
    OR event.status::TEXT NOT IN('HOLD','POSTED','CANCELED'))
  UNION ALL
  SELECT 'cash_payment_drawer_once_contract',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('rowCount',count(*))
  FROM public.sales_payment_verification_requests request
  LEFT JOIN public.cash_drawer_movements movement
    ON movement.company_id=request.company_id
   AND movement.id=request.cash_drawer_movement_id
  WHERE (request.settlement_route_snapshot='CASH_DRAWER' AND (
      movement.id IS NULL OR movement.direction<>'IN'
      OR movement.movement_type<>'SALE_PAYMENT_INTENT'
      OR movement.amount<>request.amount
      OR movement.source_table<>'sales_payment_verification_requests'
      OR movement.source_id<>request.id))
    OR (request.settlement_route_snapshot<>'CASH_DRAWER'
      AND request.cash_drawer_movement_id IS NOT NULL)
  UNION ALL
  SELECT 'rejected_cash_payment_reversal_contract',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('rowCount',count(*))
  FROM public.sales_payment_verification_requests request
  LEFT JOIN public.cash_drawer_movements movement
    ON movement.company_id=request.company_id
   AND movement.id=request.cash_drawer_reversal_movement_id
  WHERE request.settlement_route_snapshot='CASH_DRAWER'
    AND request.status='REJECTED' AND (movement.id IS NULL
      OR movement.direction<>'OUT' OR movement.movement_type<>'REVERSAL'
      OR movement.amount<>request.amount
      OR movement.source_table<>'sales_payment_verification_reversal'
      OR movement.source_id<>request.id)
  UNION ALL
  SELECT 'payment_event_journal_coverage',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('rowCount',count(*))
  FROM public.financial_events event
  LEFT JOIN public.finance_journals journal ON journal.company_id=event.company_id
    AND journal.financial_event_id=event.id AND journal.status='POSTED'
  WHERE event.system_event_key='SALE_PAYMENT_VERIFIED'
    AND ((event.status::TEXT='POSTED' AND journal.id IS NULL)
      OR (event.status::TEXT='HOLD' AND journal.id IS NOT NULL)
      OR (event.status::TEXT='CANCELED' AND journal.id IS NOT NULL))
  UNION ALL
  SELECT 'posted_payment_journal_balance',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('journalCount',count(*))
  FROM public.finance_journals journal
  WHERE journal.system_event_key='SALE_PAYMENT_VERIFIED'
    AND journal.status='POSTED' AND (journal.total_debit<=0
      OR journal.total_debit<>journal.total_credit)
),inventory AS (
  SELECT 'payment_verification_runtime_inventory'::TEXT check_name,
    'INFO'::TEXT status,0::BIGINT violation_rows,jsonb_build_object(
      'requests',(SELECT count(*) FROM public.sales_payment_verification_requests),
      'pending',(SELECT count(*) FROM public.sales_payment_verification_requests
        WHERE status='PENDING'),
      'verified',(SELECT count(*) FROM public.sales_payment_verification_requests
        WHERE status='VERIFIED'),
      'rejected',(SELECT count(*) FROM public.sales_payment_verification_requests
        WHERE status='REJECTED'),
      'cashIntents',(SELECT count(*) FROM public.cash_drawer_movements
        WHERE movement_type='SALE_PAYMENT_INTENT'),
      'holdEvents',(SELECT count(*) FROM public.financial_events
        WHERE system_event_key='SALE_PAYMENT_VERIFIED' AND status::TEXT='HOLD'),
      'postedEvents',(SELECT count(*) FROM public.financial_events
        WHERE system_event_key='SALE_PAYMENT_VERIFIED' AND status::TEXT='POSTED'),
      'postedJournals',(SELECT count(*) FROM public.finance_journals
        WHERE system_event_key='SALE_PAYMENT_VERIFIED' AND status='POSTED')
    ) details
)
SELECT * FROM (SELECT * FROM checks UNION ALL SELECT * FROM inventory) result
ORDER BY check_name;
