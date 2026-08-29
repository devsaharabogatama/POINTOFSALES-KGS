-- ODR-6C.2 Finance payment-verification UI closing postflight.
-- SAFETY: SELECT-only. Run after authenticated Backoffice smoke.
WITH checks AS (
  SELECT 'active_finance_posting_queue'::TEXT check_name,
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END status,count(*) violation_rows,
    jsonb_build_object('runCount',count(*)) details
  FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'browser_payment_verification_table_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('privilegeRows',count(*))
  FROM information_schema.table_privileges privilege
  WHERE privilege.table_schema='public'
    AND privilege.table_name IN('sales_payment_verification_requests',
      'sales_payment_verification_audit','financial_events','finance_journals')
    AND privilege.grantee IN('anon','authenticated','PUBLIC')
    AND privilege.privilege_type IN('INSERT','UPDATE','DELETE')
  UNION ALL
  SELECT 'maker_checker_decision_contract',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('rowCount',count(*))
  FROM public.sales_payment_verification_requests req
  WHERE (req.status IN('VERIFIED','REJECTED') AND
      (req.reviewed_by IS NULL OR req.reviewed_at IS NULL
        OR req.requested_by=req.reviewed_by))
    OR (req.status='PENDING' AND (req.reviewed_by IS NOT NULL
      OR req.reviewed_at IS NOT NULL))
  UNION ALL
  SELECT 'payment_request_audit_coverage',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('requestCount',count(*))
  FROM public.sales_payment_verification_requests req
  WHERE req.status IN('VERIFIED','REJECTED') AND NOT EXISTS(
    SELECT 1 FROM public.sales_payment_verification_audit audit_row
    WHERE audit_row.company_id=req.company_id
      AND audit_row.verification_request_id=req.id
      AND audit_row.action=CASE req.status WHEN 'VERIFIED' THEN 'VERIFY'
        ELSE 'REJECT' END)
  UNION ALL
  SELECT 'payment_request_event_source_contract',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('rowCount',count(*))
  FROM public.sales_payment_verification_requests req
  LEFT JOIN public.financial_events evt ON evt.company_id=req.company_id
    AND evt.id=req.financial_event_id
  WHERE req.status='VERIFIED' AND (evt.id IS NULL
    OR evt.source_table<>'sales_payment_verification_requests'
    OR evt.source_id<>req.id OR evt.system_event_key<>'SALE_PAYMENT_VERIFIED'
    OR evt.status::TEXT NOT IN('HOLD','POSTED','CANCELED'))
  UNION ALL
  SELECT 'cash_payment_drawer_once_contract',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('rowCount',count(*))
  FROM public.sales_payment_verification_requests req
  LEFT JOIN public.cash_drawer_movements movement
    ON movement.company_id=req.company_id
   AND movement.id=req.cash_drawer_movement_id
  WHERE (req.settlement_route_snapshot='CASH_DRAWER' AND (
      movement.id IS NULL OR movement.direction<>'IN'
      OR movement.movement_type<>'SALE_PAYMENT_INTENT'
      OR movement.amount<>req.amount
      OR movement.source_table<>'sales_payment_verification_requests'
      OR movement.source_id<>req.id))
    OR (req.settlement_route_snapshot<>'CASH_DRAWER'
      AND req.cash_drawer_movement_id IS NOT NULL)
  UNION ALL
  SELECT 'rejected_cash_payment_reversal_contract',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('rowCount',count(*))
  FROM public.sales_payment_verification_requests req
  LEFT JOIN public.cash_drawer_movements movement
    ON movement.company_id=req.company_id
   AND movement.id=req.cash_drawer_reversal_movement_id
  WHERE req.settlement_route_snapshot='CASH_DRAWER'
    AND req.status='REJECTED' AND (movement.id IS NULL
      OR movement.direction<>'OUT' OR movement.movement_type<>'REVERSAL'
      OR movement.amount<>req.amount
      OR movement.source_table<>'sales_payment_verification_reversal'
      OR movement.source_id<>req.id)
  UNION ALL
  SELECT 'payment_event_journal_coverage',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('rowCount',count(*))
  FROM public.financial_events evt
  LEFT JOIN public.finance_journals journal_row
    ON journal_row.company_id=evt.company_id
    AND journal_row.financial_event_id=evt.id
    AND journal_row.status='POSTED'
  WHERE evt.system_event_key='SALE_PAYMENT_VERIFIED'
    AND ((evt.status::TEXT='POSTED' AND journal_row.id IS NULL)
      OR (evt.status::TEXT IN('HOLD','CANCELED') AND journal_row.id IS NOT NULL))
  UNION ALL
  SELECT 'posted_payment_journal_balance',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('journalCount',count(*))
  FROM public.finance_journals journal_row
  WHERE journal_row.system_event_key='SALE_PAYMENT_VERIFIED'
    AND journal_row.status='POSTED' AND (journal_row.total_debit<=0
      OR journal_row.total_debit<>journal_row.total_credit)
  UNION ALL
  SELECT 'open_finance_posting_exception',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('exceptionRows',count(*))
  FROM public.finance_posting_exceptions WHERE status='OPEN'
), inventory AS (
  SELECT 'finance_payment_verification_ui_inventory'::TEXT check_name,
    'INFO'::TEXT status,0::BIGINT violation_rows,jsonb_build_object(
      'requests',(SELECT count(*) FROM public.sales_payment_verification_requests),
      'pending',(SELECT count(*) FROM public.sales_payment_verification_requests
        WHERE status='PENDING'),
      'verified',(SELECT count(*) FROM public.sales_payment_verification_requests
        WHERE status='VERIFIED'),
      'rejected',(SELECT count(*) FROM public.sales_payment_verification_requests
        WHERE status='REJECTED'),
      'holdEvents',(SELECT count(*) FROM public.financial_events
        WHERE system_event_key='SALE_PAYMENT_VERIFIED' AND status::TEXT='HOLD'),
      'postedEvents',(SELECT count(*) FROM public.financial_events
        WHERE system_event_key='SALE_PAYMENT_VERIFIED' AND status::TEXT='POSTED'),
      'postedJournals',(SELECT count(*) FROM public.finance_journals
        WHERE system_event_key='SALE_PAYMENT_VERIFIED' AND status='POSTED')) details
)
SELECT * FROM (SELECT * FROM checks UNION ALL SELECT * FROM inventory) result
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,
  check_name;
