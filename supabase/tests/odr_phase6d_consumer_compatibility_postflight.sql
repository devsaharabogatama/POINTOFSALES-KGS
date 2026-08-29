-- ODR-6D Return, AR and TEMPO collection compatibility postflight.
-- SAFETY: SELECT-only.
WITH routine_contract(signature,routine_oid,marker) AS (VALUES
  ('private.acp5h_post_sales_return_core(uuid,bigint,uuid)',
    to_regprocedure('private.acp5h_post_sales_return_core(uuid,bigint,uuid)'),
    'sales_dispatch_allocations'),
  ('public.get_pos_returnable_sales(text,integer)',
    to_regprocedure('public.get_pos_returnable_sales(text,integer)'),
    'sales_dispatch_allocations'),
  ('public.save_sales_return_draft(uuid,bigint,uuid,uuid,text,text,jsonb,jsonb)',
    to_regprocedure('public.save_sales_return_draft(uuid,bigint,uuid,uuid,text,text,jsonb,jsonb)'),
    'sales_dispatch_allocations'),
  ('public.get_finance_ar_aging(date,uuid,uuid)',
    to_regprocedure('public.get_finance_ar_aging(date,uuid,uuid)'),
    'sales_dispatch_financial_effects'),
  ('public.get_finance_customer_statement(uuid,date,date,uuid)',
    to_regprocedure('public.get_finance_customer_statement(uuid,date,date,uuid)'),
    'sales_dispatch_financial_effects'),
  ('public.save_customer_receipt_draft_with_disposition(uuid,bigint,uuid,date,uuid,text,text,text,numeric,text,jsonb)',
    to_regprocedure('public.save_customer_receipt_draft_with_disposition(uuid,bigint,uuid,date,uuid,text,text,text,numeric,text,jsonb)'),
    'sales_dispatch_financial_effects'),
  ('public.get_finance_customer_receipts()',
    to_regprocedure('public.get_finance_customer_receipts()'),
    'sales_dispatch_financial_effects')
), checks AS (
  SELECT 'migration_ledger'::TEXT check_name,
    CASE WHEN count(*)=2 THEN 'PASS' ELSE 'FAIL' END status,
    CASE WHEN count(*)=2 THEN 0 ELSE abs(2-count(*)) END::BIGINT violation_rows,
    jsonb_build_object('expected',2,'ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version IN('20260829110000','20260829120000')
  UNION ALL
  SELECT 'odr_consumer_routine_contract',CASE WHEN count(*)=7 AND bool_and(
    routine_oid IS NOT NULL AND pg_get_functiondef(routine_oid) ILIKE '%'||marker||'%')
    THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE routine_oid IS NULL OR
      pg_get_functiondef(routine_oid) NOT ILIKE '%'||marker||'%'),
    jsonb_build_object('expected',7,'routineRows',count(*),'invalid',COALESCE(jsonb_agg(signature)
      FILTER(WHERE routine_oid IS NULL OR pg_get_functiondef(routine_oid)
        NOT ILIKE '%'||marker||'%'),'[]'::JSONB)) FROM routine_contract
  UNION ALL
  SELECT 'return_quantity_dispatch_boundary',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*),jsonb_build_object('rowCount',count(*)) FROM (
    SELECT detail.company_id,detail.id
    FROM public.sales_return_lines return_line
    JOIN public.sales_return_documents return_document ON return_document.company_id=return_line.company_id
      AND return_document.id=return_line.document_id AND return_document.status='POSTED'
    JOIN public.sales_details detail ON detail.company_id=return_line.company_id
      AND detail.id=return_line.source_sales_detail_id
    GROUP BY detail.company_id,detail.id
    HAVING sum(return_line.quantity_uom)>
      private.odr6d_returnable_sales_detail_quantity(detail.company_id,detail.id)) violation
  UNION ALL
  SELECT 'receipt_dispatched_receivable_boundary',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*),jsonb_build_object('rowCount',count(*)) FROM (
    SELECT allocation.company_id,allocation.sales_id
    FROM public.customer_receipt_allocations allocation
    JOIN public.customer_receipt_documents receipt ON receipt.company_id=allocation.company_id
      AND receipt.id=allocation.document_id AND receipt.status='POSTED'
    GROUP BY allocation.company_id,allocation.sales_id
    HAVING sum(allocation.allocated_amount)>private.odr6d_dispatched_receivable_before_receipts(
      allocation.company_id,allocation.sales_id,current_date)) violation
  UNION ALL
  SELECT 'predispatch_payment_advance_boundary',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*),jsonb_build_object('rowCount',count(*))
  FROM public.sales_payment_verification_requests request
  WHERE request.status='VERIFIED' AND request.receipt_timing='PRE_DISPATCH'
    AND request.settlement_target<>'CUSTOMER_ADVANCE'
  UNION ALL
  SELECT 'browser_consumer_write_boundary',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*),jsonb_build_object('writableRelations',COALESCE(jsonb_agg(table_name),'[]'::JSONB))
  FROM information_schema.role_table_grants
  WHERE grantee='authenticated' AND table_schema='public'
    AND table_name IN('sales_dispatch_allocations','sales_dispatch_financial_effects',
      'customer_receipt_allocations','sales_return_lines')
    AND privilege_type IN('INSERT','UPDATE','DELETE')
), inventory AS (
  SELECT 'odr6d_consumer_runtime_inventory'::TEXT check_name,'INFO'::TEXT status,
    0::BIGINT violation_rows,jsonb_build_object(
      'dispatchedSales',(SELECT count(DISTINCT reservation_line.sales_id)
        FROM public.sales_dispatch_allocations allocation
        JOIN public.sales_stock_reservation_lines reservation_line
          ON reservation_line.company_id=allocation.company_id
         AND reservation_line.id=allocation.reservation_line_id),
      'odrTempoReceivable',(SELECT COALESCE(sum(receivable_amount),0)
        FROM public.sales_dispatch_financial_effects),
      'postedReturns',(SELECT count(*) FROM public.sales_return_documents WHERE status='POSTED'),
      'postedReceipts',(SELECT count(*) FROM public.customer_receipt_documents WHERE status='POSTED')) details
)
SELECT * FROM (SELECT * FROM checks UNION ALL SELECT * FROM inventory) result
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
