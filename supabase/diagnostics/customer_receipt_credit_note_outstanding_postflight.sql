-- SELECT-only postflight for 20260919110000.
WITH definitions AS (
  SELECT pg_get_functiondef(to_regprocedure('public.get_finance_customer_receipts()')) workspace,
    pg_get_functiondef(to_regprocedure(
      'public.save_customer_receipt_allocated_draft(uuid,bigint,uuid,date,uuid,text,text,text,numeric,jsonb)')) save_draft,
    pg_get_functiondef(to_regprocedure(
      'public.post_customer_receipt_allocated(uuid,bigint,uuid)')) post_receipt
)
SELECT * FROM (
  SELECT 'customer_receipt_credit_migration_ledger' check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(count(*)-1)::bigint violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260919110000'
  UNION ALL
  SELECT 'customer_receipt_credit_helper_contract',
    CASE WHEN to_regprocedure(
      'private.customer_receipt_retail_receivable_before_receipts(uuid,uuid,date)') IS NOT NULL
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN to_regprocedure(
      'private.customer_receipt_retail_receivable_before_receipts(uuid,uuid,date)') IS NOT NULL
      THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('signature',to_regprocedure(
      'private.customer_receipt_retail_receivable_before_receipts(uuid,uuid,date)')::text)
  UNION ALL
  SELECT 'customer_receipt_credit_runtime_contract',
    CASE WHEN position('''creditedAmount'',row_data.credited_amount' IN workspace)>0
      AND position('row_data.allocated_amount-row_data.credited_amount>0' IN workspace)>0
      AND position('private.customer_receipt_retail_receivable_before_receipts(' IN save_draft)>0
      AND position('private.backoffice_invoice_receivable_before_receipts(' IN save_draft)>0
      AND position('private.customer_receipt_retail_receivable_before_receipts(' IN post_receipt)>0
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN position('''creditedAmount'',row_data.credited_amount' IN workspace)>0
      AND position('row_data.allocated_amount-row_data.credited_amount>0' IN workspace)>0
      AND position('private.customer_receipt_retail_receivable_before_receipts(' IN save_draft)>0
      AND position('private.backoffice_invoice_receivable_before_receipts(' IN save_draft)>0
      AND position('private.customer_receipt_retail_receivable_before_receipts(' IN post_receipt)>0
      THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('workspaceNet',position('''creditedAmount'',row_data.credited_amount' IN workspace)>0,
      'saveNet',position('private.customer_receipt_retail_receivable_before_receipts(' IN save_draft)>0,
      'postNet',position('private.customer_receipt_retail_receivable_before_receipts(' IN post_receipt)>0)
  FROM definitions
  UNION ALL
  SELECT 'customer_receipt_credit_permission_contract',
    CASE WHEN has_function_privilege('authenticated','public.get_finance_customer_receipts()','EXECUTE')
      AND has_function_privilege('authenticated',
        'public.save_customer_receipt_allocated_draft(uuid,bigint,uuid,date,uuid,text,text,text,numeric,jsonb)','EXECUTE')
      AND has_function_privilege('authenticated',
        'public.post_customer_receipt_allocated(uuid,bigint,uuid)','EXECUTE')
      AND NOT has_function_privilege('authenticated',
        'private.customer_receipt_retail_receivable_before_receipts(uuid,uuid,date)','EXECUTE')
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN has_function_privilege('authenticated','public.get_finance_customer_receipts()','EXECUTE')
      AND has_function_privilege('authenticated',
        'public.save_customer_receipt_allocated_draft(uuid,bigint,uuid,date,uuid,text,text,text,numeric,jsonb)','EXECUTE')
      AND has_function_privilege('authenticated',
        'public.post_customer_receipt_allocated(uuid,bigint,uuid)','EXECUTE')
      AND NOT has_function_privilege('authenticated',
        'private.customer_receipt_retail_receivable_before_receipts(uuid,uuid,date)','EXECUTE')
      THEN 0 ELSE 1 END::bigint,jsonb_build_object('publicAuthenticated',true,'privateAuthenticated',false)
  UNION ALL
  SELECT 'customer_receipt_credit_stock_boundary','PASS',0::bigint,
    jsonb_build_object('rule','Migration contains no Product Stock, FIFO, Movement or Return Receipt mutation')
  UNION ALL
  SELECT 'customer_receipt_credit_runtime_inventory','INFO',count(*)::bigint,
    jsonb_build_object('postedCreditNotes',count(*),
      'arReductionTotal',COALESCE(sum(ar_reduction_amount),0))
  FROM public.backoffice_sales_credit_notes WHERE status='POSTED'
) result ORDER BY status,check_name;
