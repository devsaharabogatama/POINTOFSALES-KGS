BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260829110000')
    OR NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260828250000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: ODR Return and Finance runtime required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260829120000') THEN RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED'; END IF;
END
$guard$;

CREATE FUNCTION private.odr6d_dispatched_receivable_before_receipts(
  p_company_id UUID,p_sales_id UUID,p_as_of DATE
) RETURNS NUMERIC LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
  SELECT CASE WHEN sale.document_status='POSTED' THEN sale.sisa_piutang
    ELSE GREATEST(COALESCE((SELECT sum(effect.receivable_amount)
      FROM public.sales_dispatch_financial_effects effect
      WHERE effect.company_id=sale.company_id AND effect.sales_id=sale.id
        AND effect.effective_date<=p_as_of),0)-COALESCE((
      SELECT sum(request.amount)
      FROM public.sales_payment_verification_requests request
      WHERE request.company_id=sale.company_id AND request.sales_id=sale.id
        AND request.status='VERIFIED' AND request.receipt_timing='POST_DISPATCH'
        AND request.settlement_target='CUSTOMER_RECEIVABLE'
        AND request.effective_date<=p_as_of),0),0) END
  FROM public.sales_headers sale
  WHERE sale.company_id=p_company_id AND sale.id=p_sales_id AND sale.is_tempo;
$$;

DO $patch$
DECLARE v_definition TEXT;v_before TEXT;
BEGIN
  SELECT pg_get_functiondef(
    'public.save_customer_receipt_draft(uuid,bigint,uuid,date,uuid,text,text,text,jsonb)'::regprocedure)
    INTO v_definition;
  v_before:=v_definition;
  v_definition:=replace(v_definition,
    'AND sale.id=(v_item->>''salesId'')::UUID AND sale.document_status=''POSTED''
      AND sale.is_tempo AND sale.customer_id=p_customer_id;',
    'AND sale.id=(v_item->>''salesId'')::UUID AND sale.is_tempo
      AND sale.customer_id=p_customer_id
      AND (sale.document_status=''POSTED'' OR EXISTS(SELECT 1
        FROM public.sales_dispatch_financial_effects dispatch_effect
        WHERE dispatch_effect.company_id=sale.company_id
          AND dispatch_effect.sales_id=sale.id
          AND dispatch_effect.effective_date<=p_receipt_date));');
  v_definition:=replace(v_definition,
    'IF v_amount>v_sale.sisa_piutang-v_paid THEN',
    'IF v_amount>private.odr6d_dispatched_receivable_before_receipts(
      v_company,v_sale.id,p_receipt_date)-v_paid THEN');
  IF v_definition=v_before OR v_definition NOT LIKE '%sales_dispatch_financial_effects%'
    OR v_definition NOT LIKE '%odr6d_dispatched_receivable_before_receipts%' THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Customer Receipt Draft definition changed';
  END IF;
  EXECUTE v_definition;

  SELECT pg_get_functiondef(
    'private.f2_post_customer_receipt_hold_core(uuid,bigint,uuid)'::regprocedure)
    INTO v_definition;
  v_before:=v_definition;
  v_definition:=replace(v_definition,
    'AND sale.id=v_allocation.sales_id AND sale.document_status=''POSTED''
      AND sale.is_tempo AND sale.customer_id=v_document.customer_id
      AND v_allocation.allocated_amount<=sale.sisa_piutang-COALESCE((',
    'AND sale.id=v_allocation.sales_id AND sale.is_tempo
      AND sale.customer_id=v_document.customer_id
      AND (sale.document_status=''POSTED'' OR EXISTS(SELECT 1
        FROM public.sales_dispatch_financial_effects dispatch_effect
        WHERE dispatch_effect.company_id=sale.company_id
          AND dispatch_effect.sales_id=sale.id
          AND dispatch_effect.effective_date<=v_document.receipt_date))
      AND v_allocation.allocated_amount<=private.odr6d_dispatched_receivable_before_receipts(
        v_company,sale.id,v_document.receipt_date)-COALESCE((');
  IF v_definition=v_before OR v_definition NOT LIKE '%sales_dispatch_financial_effects%'
    OR v_definition NOT LIKE '%odr6d_dispatched_receivable_before_receipts%' THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Customer Receipt Post core definition changed';
  END IF;
  EXECUTE v_definition;

  SELECT pg_get_functiondef(
    'public.save_customer_receipt_draft_with_disposition(uuid,bigint,uuid,date,uuid,text,text,text,numeric,text,jsonb)'::regprocedure)
    INTO v_definition;
  v_before:=v_definition;
  v_definition:=replace(v_definition,
    'BEGIN
  IF v_disposition=''NONE'' THEN',
    'BEGIN
  PERFORM 1 FROM public.sales_dispatch_financial_effects WHERE FALSE;
  IF v_disposition=''NONE'' THEN');
  IF v_definition=v_before OR v_definition NOT LIKE '%sales_dispatch_financial_effects%' THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Customer Receipt disposition wrapper changed';
  END IF;
  EXECUTE v_definition;
END
$patch$;

CREATE OR REPLACE FUNCTION public.get_finance_customer_receipts()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_permission JSONB;v_today DATE;
BEGIN
  v_permission:=private.acp_require_permission_capability(v_company,'finance.customer_receipts','VIEW');
  SELECT (current_timestamp AT TIME ZONE company.timezone)::DATE INTO v_today
  FROM public.companies company WHERE company.id=v_company AND company.status='ACTIVE';
  IF v_today IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_NOT_FOUND'; END IF;
  RETURN jsonb_build_object('companyId',v_company,'currentUserId',auth.uid(),
    'effectiveCapabilities',v_permission->'effectiveCapabilities',
    'documents',(SELECT COALESCE(jsonb_agg(to_jsonb(row_data)
      ORDER BY row_data.created_at DESC,row_data.id DESC),'[]'::JSONB)
      FROM (SELECT * FROM public.customer_receipt_documents document
        WHERE document.company_id=v_company ORDER BY document.created_at DESC LIMIT 500) row_data),
    'allocations',(SELECT COALESCE(jsonb_agg(to_jsonb(allocation)
      ORDER BY allocation.document_id,allocation.created_at),'[]'::JSONB)
      FROM public.customer_receipt_allocations allocation WHERE allocation.company_id=v_company),
    'openInvoices',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'salesId',sale.id,'invoiceNo',invoice.invoice_no,'customerId',sale.customer_id,
      'transactionDate',sale.transaction_date,'dueDate',sale.due_date,
      'originalReceivable',private.odr6d_dispatched_receivable_before_receipts(
        sale.company_id,sale.id,v_today),'allocatedAmount',COALESCE(receipt.paid,0),
      'remainingAmount',GREATEST(private.odr6d_dispatched_receivable_before_receipts(
        sale.company_id,sale.id,v_today)-COALESCE(receipt.paid,0),0))
      ORDER BY sale.due_date NULLS LAST,sale.transaction_date,sale.id),'[]'::JSONB)
      FROM public.sales_headers sale
      JOIN public.sales_invoice_snapshots invoice ON invoice.company_id=sale.company_id
        AND invoice.sales_id=sale.id
      LEFT JOIN LATERAL(SELECT sum(allocation.allocated_amount) paid
        FROM public.customer_receipt_allocations allocation
        JOIN public.customer_receipt_documents document
          ON document.company_id=allocation.company_id AND document.id=allocation.document_id
         AND document.status='POSTED'
        WHERE allocation.company_id=sale.company_id AND allocation.sales_id=sale.id) receipt ON TRUE
      WHERE sale.company_id=v_company AND sale.is_tempo
        AND (sale.document_status='POSTED' OR EXISTS(SELECT 1
          FROM public.sales_dispatch_financial_effects effect
          WHERE effect.company_id=sale.company_id AND effect.sales_id=sale.id
            AND effect.effective_date<=v_today))
        AND private.odr6d_dispatched_receivable_before_receipts(
          sale.company_id,sale.id,v_today)-COALESCE(receipt.paid,0)>0),
    'customers',(SELECT COALESCE(jsonb_agg(jsonb_build_object('id',customer.id,
      'code',customer.code,'name',customer.name) ORDER BY customer.name),'[]'::JSONB)
      FROM public.customers customer WHERE customer.company_id=v_company
        AND NOT customer.is_system_customer),
    'paymentMethods',(SELECT COALESCE(jsonb_agg(jsonb_build_object('id',method.id,
      'name',method.payment_method_name,'type',method.method_type,
      'settlementRoute',method.settlement_route) ORDER BY method.payment_method_name),'[]'::JSONB)
      FROM public.payment_methods method WHERE method.company_id=v_company AND method.is_active
        AND method.settlement_route IN('CASH_DRAWER','DIRECT_BANK')));
END
$$;

CREATE OR REPLACE FUNCTION public.get_finance_ar_aging(
  p_as_of DATE DEFAULT NULL,p_customer_id UUID DEFAULT NULL,p_store_id UUID DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_timezone TEXT;
  v_company_today DATE;v_as_of DATE;v_permission JSONB;
BEGIN
  v_permission:=private.acp_require_permission_capability(v_company,'finance.customer_receipts','VIEW');
  SELECT company.timezone,(current_timestamp AT TIME ZONE company.timezone)::DATE
    INTO v_timezone,v_company_today FROM public.companies company
    WHERE company.id=v_company AND company.status='ACTIVE';
  IF v_timezone IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_NOT_FOUND'; END IF;
  v_as_of:=COALESCE(p_as_of,v_company_today);
  IF v_as_of>v_company_today THEN RAISE EXCEPTION 'AR_AS_OF_DATE_FUTURE'; END IF;
  IF p_customer_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.customers customer
    WHERE customer.company_id=v_company AND customer.id=p_customer_id
      AND NOT customer.is_system_customer) THEN RAISE EXCEPTION 'CUSTOMER_NOT_FOUND'; END IF;
  IF p_store_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.stores store
    WHERE store.company_id=v_company AND store.id=p_store_id) THEN RAISE EXCEPTION 'STORE_NOT_FOUND'; END IF;
  RETURN (WITH invoices AS (
    SELECT sale.id sales_id,invoice.invoice_no,sale.customer_id,customer.code customer_code,
      customer.name customer_name,sale.store_id,store.store_name,
      CASE WHEN sale.document_status='POSTED' THEN
        (sale.transaction_date AT TIME ZONE v_timezone)::DATE ELSE
        (SELECT min(effect.effective_date) FROM public.sales_dispatch_financial_effects effect
          WHERE effect.company_id=sale.company_id AND effect.sales_id=sale.id
            AND effect.effective_date<=v_as_of) END transaction_date,
      CASE WHEN sale.due_date IS NULL THEN NULL ELSE
        (sale.due_date AT TIME ZONE v_timezone)::DATE END due_date,
      private.odr6d_dispatched_receivable_before_receipts(
        sale.company_id,sale.id,v_as_of) original_receivable,
      COALESCE((SELECT sum(allocation.allocated_amount)
        FROM public.customer_receipt_allocations allocation
        JOIN public.customer_receipt_documents receipt
          ON receipt.company_id=allocation.company_id AND receipt.id=allocation.document_id
         AND receipt.status='POSTED' AND receipt.receipt_date<=v_as_of
        WHERE allocation.company_id=v_company AND allocation.sales_id=sale.id),0) allocated_amount
    FROM public.sales_headers sale
    JOIN public.sales_invoice_snapshots invoice ON invoice.company_id=sale.company_id
      AND invoice.sales_id=sale.id
    JOIN public.customers customer ON customer.company_id=sale.company_id
      AND customer.id=sale.customer_id
    LEFT JOIN public.stores store ON store.company_id=sale.company_id AND store.id=sale.store_id
    WHERE sale.company_id=v_company AND sale.is_tempo
      AND (sale.document_status='POSTED' OR EXISTS(SELECT 1
        FROM public.sales_dispatch_financial_effects effect
        WHERE effect.company_id=sale.company_id AND effect.sales_id=sale.id
          AND effect.effective_date<=v_as_of))
      AND (p_customer_id IS NULL OR sale.customer_id=p_customer_id)
      AND (p_store_id IS NULL OR sale.store_id=p_store_id)
  ),open_items AS (
    SELECT invoice.*,GREATEST(original_receivable-allocated_amount,0) outstanding,
      CASE WHEN due_date IS NULL THEN 'NO_DUE_DATE' WHEN due_date>=v_as_of THEN 'NOT_DUE'
        WHEN v_as_of-due_date<=30 THEN 'OVERDUE_1_30' WHEN v_as_of-due_date<=60 THEN 'OVERDUE_31_60'
        WHEN v_as_of-due_date<=90 THEN 'OVERDUE_61_90' ELSE 'OVERDUE_GT_90' END aging_bucket,
      CASE WHEN due_date IS NULL OR due_date>=v_as_of THEN 0 ELSE v_as_of-due_date END overdue_days
    FROM invoices invoice WHERE original_receivable-allocated_amount>0
  ),bucket_order(bucket,sort_order) AS (VALUES ('NOT_DUE'::TEXT,1),('OVERDUE_1_30',2),
    ('OVERDUE_31_60',3),('OVERDUE_61_90',4),('OVERDUE_GT_90',5),('NO_DUE_DATE',6))
  SELECT jsonb_build_object('companyId',v_company,'asOf',v_as_of,
    'effectiveCapabilities',v_permission->'effectiveCapabilities','summary',jsonb_build_object(
      'invoiceCount',(SELECT count(*) FROM open_items),'customerCount',(SELECT count(DISTINCT customer_id) FROM open_items),
      'originalReceivable',COALESCE((SELECT sum(original_receivable) FROM open_items),0),
      'allocatedAmount',COALESCE((SELECT sum(allocated_amount) FROM open_items),0),
      'outstanding',COALESCE((SELECT sum(outstanding) FROM open_items),0),
      'overdue',COALESCE((SELECT sum(outstanding) FROM open_items WHERE aging_bucket LIKE 'OVERDUE%'),0)),
    'buckets',(SELECT jsonb_agg(jsonb_build_object('bucket',bucket_order.bucket,
      'invoiceCount',COALESCE(bucket.invoice_count,0),'customerCount',COALESCE(bucket.customer_count,0),
      'outstanding',COALESCE(bucket.outstanding,0)) ORDER BY bucket_order.sort_order)
      FROM bucket_order LEFT JOIN (SELECT aging_bucket,count(*) invoice_count,
        count(DISTINCT customer_id) customer_count,sum(outstanding) outstanding FROM open_items
        GROUP BY aging_bucket) bucket ON bucket.aging_bucket=bucket_order.bucket),
    'invoices',(SELECT COALESCE(jsonb_agg(jsonb_build_object('salesId',item.sales_id,
      'invoiceNo',item.invoice_no,'customerId',item.customer_id,'customerCode',item.customer_code,
      'customerName',item.customer_name,'storeId',item.store_id,'storeName',item.store_name,
      'transactionDate',item.transaction_date,'dueDate',item.due_date,
      'originalReceivable',item.original_receivable,'allocatedAmount',item.allocated_amount,
      'outstanding',item.outstanding,'agingBucket',item.aging_bucket,'overdueDays',item.overdue_days)
      ORDER BY item.due_date NULLS LAST,item.transaction_date,item.invoice_no),'[]'::JSONB)
      FROM open_items item)));
END
$$;

CREATE OR REPLACE FUNCTION public.get_finance_customer_statement(
  p_customer_id UUID,p_date_from DATE DEFAULT NULL,p_as_of DATE DEFAULT NULL,p_store_id UUID DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_timezone TEXT;v_company_today DATE;
  v_from DATE;v_as_of DATE;v_customer public.customers%ROWTYPE;v_permission JSONB;
BEGIN
  v_permission:=private.acp_require_permission_capability(v_company,'finance.customer_receipts','VIEW');
  SELECT company.timezone,(current_timestamp AT TIME ZONE company.timezone)::DATE
    INTO v_timezone,v_company_today FROM public.companies company
    WHERE company.id=v_company AND company.status='ACTIVE';
  IF v_timezone IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_NOT_FOUND'; END IF;
  v_as_of:=COALESCE(p_as_of,v_company_today);v_from:=COALESCE(p_date_from,(v_as_of-INTERVAL '90 days')::DATE);
  IF v_as_of>v_company_today THEN RAISE EXCEPTION 'AR_AS_OF_DATE_FUTURE'; END IF;
  IF v_from>v_as_of THEN RAISE EXCEPTION 'AR_DATE_RANGE_INVALID'; END IF;
  SELECT * INTO v_customer FROM public.customers customer WHERE customer.company_id=v_company
    AND customer.id=p_customer_id AND NOT customer.is_system_customer;
  IF NOT FOUND THEN RAISE EXCEPTION 'CUSTOMER_NOT_FOUND'; END IF;
  IF p_store_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.stores store
    WHERE store.company_id=v_company AND store.id=p_store_id) THEN
    RAISE EXCEPTION 'STORE_NOT_FOUND';
  END IF;
  RETURN (WITH invoice_rows AS (
    SELECT sale.id source_id,'INVOICE'::TEXT source_type,invoice.invoice_no document_no,
      (sale.transaction_date AT TIME ZONE v_timezone)::DATE business_date,
      CASE WHEN sale.due_date IS NULL THEN NULL ELSE (sale.due_date AT TIME ZONE v_timezone)::DATE END due_date,
      sale.store_id,store.store_name,sale.sisa_piutang debit,0::NUMERIC credit,
      'Invoice penjualan tempo'::TEXT description
    FROM public.sales_headers sale JOIN public.sales_invoice_snapshots invoice
      ON invoice.company_id=sale.company_id AND invoice.sales_id=sale.id
    LEFT JOIN public.stores store ON store.company_id=sale.company_id AND store.id=sale.store_id
    WHERE sale.company_id=v_company AND sale.customer_id=p_customer_id
      AND sale.document_status='POSTED' AND sale.is_tempo
      AND (sale.transaction_date AT TIME ZONE v_timezone)::DATE<=v_as_of
      AND (p_store_id IS NULL OR sale.store_id=p_store_id)
    UNION ALL
    SELECT effect.id,'INVOICE'::TEXT,invoice.invoice_no,effect.effective_date,
      CASE WHEN sale.due_date IS NULL THEN NULL ELSE (sale.due_date AT TIME ZONE v_timezone)::DATE END,
      sale.store_id,store.store_name,effect.receivable_amount,0::NUMERIC,
      'Piutang dari Dispatch '||delivery.delivery_no
    FROM public.sales_dispatch_financial_effects effect
    JOIN public.sales_headers sale ON sale.company_id=effect.company_id AND sale.id=effect.sales_id
      AND sale.is_tempo AND sale.customer_id=p_customer_id AND sale.document_status<>'POSTED'
    JOIN public.sales_invoice_snapshots invoice ON invoice.company_id=sale.company_id AND invoice.sales_id=sale.id
    JOIN public.sales_delivery_documents delivery ON delivery.company_id=effect.company_id
      AND delivery.id=effect.delivery_document_id
    LEFT JOIN public.stores store ON store.company_id=sale.company_id AND store.id=sale.store_id
    WHERE effect.company_id=v_company AND effect.effective_date<=v_as_of
      AND effect.receivable_amount>0 AND (p_store_id IS NULL OR sale.store_id=p_store_id)
  ),receipt_rows AS (
    SELECT allocation.id source_id,'RECEIPT'::TEXT source_type,receipt.receipt_no document_no,
      receipt.receipt_date business_date,CASE WHEN allocation.due_date_snapshot IS NULL THEN NULL
        ELSE (allocation.due_date_snapshot AT TIME ZONE v_timezone)::DATE END due_date,
      sale.store_id,store.store_name,0::NUMERIC debit,allocation.allocated_amount credit,
      ('Pembayaran '||allocation.invoice_no_snapshot)::TEXT description
    FROM public.customer_receipt_allocations allocation JOIN public.customer_receipt_documents receipt
      ON receipt.company_id=allocation.company_id AND receipt.id=allocation.document_id AND receipt.status='POSTED'
    JOIN public.sales_headers sale ON sale.company_id=allocation.company_id AND sale.id=allocation.sales_id
      AND sale.customer_id=p_customer_id LEFT JOIN public.stores store
      ON store.company_id=sale.company_id AND store.id=sale.store_id
    WHERE allocation.company_id=v_company AND receipt.customer_id=p_customer_id
      AND receipt.receipt_date<=v_as_of AND (p_store_id IS NULL OR sale.store_id=p_store_id)
    UNION ALL
    SELECT request.id,'ODR_PAYMENT'::TEXT,sale.invoice_no,request.effective_date,
      CASE WHEN sale.due_date IS NULL THEN NULL ELSE (sale.due_date AT TIME ZONE v_timezone)::DATE END,
      sale.store_id,store.store_name,0::NUMERIC,request.amount,'Pembayaran ODR terverifikasi'
    FROM public.sales_payment_verification_requests request JOIN public.sales_headers sale
      ON sale.company_id=request.company_id AND sale.id=request.sales_id AND sale.customer_id=p_customer_id
    LEFT JOIN public.stores store ON store.company_id=sale.company_id AND store.id=sale.store_id
    WHERE request.company_id=v_company AND request.status='VERIFIED'
      AND request.receipt_timing='POST_DISPATCH' AND request.settlement_target='CUSTOMER_RECEIVABLE'
      AND request.effective_date<=v_as_of AND (p_store_id IS NULL OR sale.store_id=p_store_id)
  ),all_rows AS (SELECT * FROM invoice_rows UNION ALL SELECT * FROM receipt_rows),
  opening AS (SELECT COALESCE(sum(debit-credit),0) amount FROM all_rows WHERE business_date<v_from),
  period_rows AS (SELECT row_data.*,row_number() OVER(ORDER BY business_date,
    CASE source_type WHEN 'INVOICE' THEN 1 ELSE 2 END,source_id) sequence_no
    FROM all_rows row_data WHERE business_date BETWEEN v_from AND v_as_of),
  running AS (SELECT period_rows.*,opening.amount+sum(debit-credit) OVER(ORDER BY sequence_no
    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) running_balance FROM period_rows CROSS JOIN opening)
  SELECT jsonb_build_object('companyId',v_company,'customer',jsonb_build_object('id',v_customer.id,
    'code',v_customer.code,'name',v_customer.name),'dateFrom',v_from,'asOf',v_as_of,
    'effectiveCapabilities',v_permission->'effectiveCapabilities','openingBalance',(SELECT amount FROM opening),
    'periodDebit',COALESCE((SELECT sum(debit) FROM period_rows),0),
    'periodCredit',COALESCE((SELECT sum(credit) FROM period_rows),0),
    'endingBalance',(SELECT amount FROM opening)+COALESCE((SELECT sum(debit-credit) FROM period_rows),0),
    'rows',(SELECT COALESCE(jsonb_agg(jsonb_build_object('sequence',row_data.sequence_no,
      'sourceId',row_data.source_id,'sourceType',row_data.source_type,'documentNo',row_data.document_no,
      'businessDate',row_data.business_date,'dueDate',row_data.due_date,'storeId',row_data.store_id,
      'storeName',row_data.store_name,'description',row_data.description,'debit',row_data.debit,
      'credit',row_data.credit,'runningBalance',row_data.running_balance)
      ORDER BY row_data.sequence_no),'[]'::JSONB) FROM running row_data)));
END
$$;

REVOKE ALL ON FUNCTION private.odr6d_dispatched_receivable_before_receipts(UUID,UUID,DATE)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.odr6d_dispatched_receivable_before_receipts(UUID,UUID,DATE)
  TO service_role;
REVOKE ALL ON FUNCTION public.get_finance_ar_aging(DATE,UUID,UUID),
  public.get_finance_customer_statement(UUID,DATE,DATE,UUID),
  public.get_finance_customer_receipts() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_finance_ar_aging(DATE,UUID,UUID),
  public.get_finance_customer_statement(UUID,DATE,DATE,UUID),
  public.get_finance_customer_receipts() TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260829120000','odr_phase6d_tempo_ar_collection_compatibility',
  'Make AR Aging, Customer Statement and Customer Receipt allocation recognize only immutable dispatched ODR TEMPO receivable; pre-Dispatch verified payment remains Customer Advance and legacy POSTED Sale remains compatible');

COMMIT;
