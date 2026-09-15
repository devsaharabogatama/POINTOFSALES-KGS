-- Backoffice Invoice integration into the existing Customer Receipt and AR reports.
-- No document backfill and no operational/financial effect is created by this migration.
BEGIN;

DO $guard$
DECLARE v_definition text;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260829120000')
    OR NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260911160000')
    OR NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260911162000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical Retail AR and Backoffice payment runtime required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260911163000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260911163000';
  END IF;
  IF to_regprocedure('public.post_customer_receipt_unified(uuid,bigint,uuid)') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: unified Receipt post collision';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
    WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
  SELECT pg_get_functiondef('public.get_finance_customer_receipts()'::regprocedure)
    INTO v_definition;
  IF v_definition NOT ILIKE '%customer_receipt_allocations%'
    OR v_definition NOT ILIKE '%odr6d_dispatched_receivable_before_receipts%' THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical Retail Receipt reader drift';
  END IF;
END
$guard$;

CREATE FUNCTION public.post_customer_receipt_unified(
  p_document_id uuid,p_master_version bigint,p_idempotency_key uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='15s' AS $$
DECLARE v_company uuid:=public.private_active_company_id();
  v_document public.customer_receipt_documents%rowtype;
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'finance.customer_receipts','POST');
  SELECT * INTO v_document FROM public.customer_receipt_documents document
  WHERE document.company_id=v_company AND document.id=p_document_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'CUSTOMER_RECEIPT_NOT_FOUND'; END IF;
  IF v_document.unapplied_disposition='CUSTOMER_BALANCE' THEN
    IF EXISTS(SELECT 1 FROM public.customer_receipt_backoffice_invoice_allocations allocation
      WHERE allocation.company_id=v_company AND allocation.document_id=v_document.id) THEN
      RAISE EXCEPTION 'CUSTOMER_RECEIPT_ADVANCE_MUST_BE_UNALLOCATED';
    END IF;
    RETURN public.post_customer_receipt_with_disposition(
      p_document_id,p_master_version,p_idempotency_key);
  END IF;
  RETURN public.post_customer_receipt_allocated(
    p_document_id,p_master_version,p_idempotency_key);
END
$$;

CREATE OR REPLACE FUNCTION public.get_finance_customer_receipts()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_permission jsonb;v_today date;
BEGIN
  v_permission:=private.acp_require_permission_capability(
    v_company,'finance.customer_receipts','VIEW');
  SELECT (current_timestamp AT TIME ZONE company.timezone)::date INTO v_today
  FROM public.companies company WHERE company.id=v_company AND company.status='ACTIVE';
  IF v_today IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_NOT_FOUND'; END IF;
  RETURN jsonb_build_object('companyId',v_company,'currentUserId',auth.uid(),
    'effectiveCapabilities',v_permission->'effectiveCapabilities',
    'documents',(SELECT COALESCE(jsonb_agg(to_jsonb(row_data)
      ORDER BY row_data.created_at DESC,row_data.id DESC),'[]'::jsonb)
      FROM (SELECT * FROM public.customer_receipt_documents document
        WHERE document.company_id=v_company ORDER BY document.created_at DESC LIMIT 500) row_data),
    'allocations',(SELECT COALESCE(jsonb_agg(allocation_row
      ORDER BY allocation_row->>'document_id',allocation_row->>'created_at'),'[]'::jsonb)
      FROM (
        SELECT jsonb_build_object('document_id',allocation.document_id,
          'source_type','RETAIL_SALE','source_id',allocation.sales_id,
          'sales_id',allocation.sales_id,'invoice_id',NULL,
          'client_allocation_key',allocation.client_allocation_key,
          'allocated_amount',allocation.allocated_amount,
          'invoice_no_snapshot',allocation.invoice_no_snapshot,
          'created_at',allocation.created_at) allocation_row
        FROM public.customer_receipt_allocations allocation
        WHERE allocation.company_id=v_company
        UNION ALL
        SELECT jsonb_build_object('document_id',allocation.document_id,
          'source_type','BACKOFFICE_SALES_INVOICE','source_id',allocation.invoice_id,
          'sales_id',NULL,'invoice_id',allocation.invoice_id,
          'client_allocation_key',allocation.client_allocation_key,
          'allocated_amount',allocation.allocated_amount,
          'invoice_no_snapshot',allocation.invoice_no_snapshot,
          'created_at',allocation.created_at)
        FROM public.customer_receipt_backoffice_invoice_allocations allocation
        WHERE allocation.company_id=v_company
      ) unioned),
    'openInvoices',(WITH invoice_rows AS (
      SELECT 'RETAIL_SALE'::text source_type,sale.id source_id,sale.id sales_id,
        invoice.invoice_no,sale.customer_id,
        (sale.transaction_date AT TIME ZONE company.timezone)::date transaction_date,
        CASE WHEN sale.due_date IS NULL THEN NULL
          ELSE (sale.due_date AT TIME ZONE company.timezone)::date END due_date,
        store.store_name,
        private.odr6d_dispatched_receivable_before_receipts(
          sale.company_id,sale.id,v_today) original_receivable,
        COALESCE(receipt.paid,0) allocated_amount
      FROM public.sales_headers sale
      JOIN public.companies company ON company.id=sale.company_id
      JOIN public.sales_invoice_snapshots invoice ON invoice.company_id=sale.company_id
        AND invoice.sales_id=sale.id
      LEFT JOIN public.stores store ON store.company_id=sale.company_id AND store.id=sale.store_id
      LEFT JOIN LATERAL(SELECT sum(allocation.allocated_amount) paid
        FROM public.customer_receipt_allocations allocation
        JOIN public.customer_receipt_documents document
          ON document.company_id=allocation.company_id AND document.id=allocation.document_id
         AND document.status='POSTED'
        WHERE allocation.company_id=sale.company_id AND allocation.sales_id=sale.id) receipt ON true
      WHERE sale.company_id=v_company AND sale.is_tempo
        AND (sale.document_status='POSTED' OR EXISTS(SELECT 1
          FROM public.sales_dispatch_financial_effects effect
          WHERE effect.company_id=sale.company_id AND effect.sales_id=sale.id
            AND effect.effective_date<=v_today))
      UNION ALL
      SELECT 'BACKOFFICE_SALES_INVOICE',invoice.id,NULL::uuid,invoice.invoice_no,
        invoice.customer_id,invoice.invoice_date,
        (SELECT min(schedule.due_date)
         FROM public.backoffice_sales_invoice_receivable_schedules schedule
         WHERE schedule.company_id=invoice.company_id AND schedule.invoice_id=invoice.id
           AND schedule.status IN('OPEN','PARTIALLY_PAID')),
        store.store_name,invoice.grand_total,COALESCE(receipt.paid,0)
      FROM public.backoffice_sales_invoices invoice
      LEFT JOIN public.stores store ON store.company_id=invoice.company_id AND store.id=invoice.store_id
      LEFT JOIN LATERAL(SELECT sum(allocation.allocated_amount) paid
        FROM public.customer_receipt_backoffice_invoice_allocations allocation
        JOIN public.customer_receipt_documents document
          ON document.company_id=allocation.company_id AND document.id=allocation.document_id
         AND document.status='POSTED'
        WHERE allocation.company_id=invoice.company_id AND allocation.invoice_id=invoice.id) receipt ON true
      WHERE invoice.company_id=v_company AND invoice.status='POSTED'
        AND invoice.invoice_date<=v_today
    ) SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'sourceType',row_data.source_type,'sourceId',row_data.source_id,
      'salesId',row_data.sales_id,'invoiceNo',row_data.invoice_no,
      'customerId',row_data.customer_id,'transactionDate',row_data.transaction_date,
      'dueDate',row_data.due_date,'storeName',row_data.store_name,
      'originalReceivable',row_data.original_receivable,
      'allocatedAmount',row_data.allocated_amount,
      'remainingAmount',row_data.original_receivable-row_data.allocated_amount)
      ORDER BY row_data.due_date NULLS LAST,row_data.transaction_date,row_data.invoice_no),'[]'::jsonb)
      FROM invoice_rows row_data
      WHERE row_data.original_receivable-row_data.allocated_amount>0),
    'customers',(SELECT COALESCE(jsonb_agg(jsonb_build_object('id',customer.id,
      'code',customer.code,'name',customer.name) ORDER BY customer.name),'[]'::jsonb)
      FROM public.customers customer WHERE customer.company_id=v_company
        AND NOT customer.is_system_customer),
    'paymentMethods',(SELECT COALESCE(jsonb_agg(jsonb_build_object('id',method.id,
      'name',method.payment_method_name,'type',method.method_type,
      'settlementRoute',method.settlement_route) ORDER BY method.payment_method_name),'[]'::jsonb)
      FROM public.payment_methods method WHERE method.company_id=v_company AND method.is_active
        AND method.settlement_route IN('CASH_DRAWER','DIRECT_BANK')));
END
$$;

CREATE OR REPLACE FUNCTION public.get_finance_ar_aging(
  p_as_of date DEFAULT NULL,p_customer_id uuid DEFAULT NULL,p_store_id uuid DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_timezone text;
  v_company_today date;v_as_of date;v_permission jsonb;
BEGIN
  v_permission:=private.acp_require_permission_capability(v_company,'finance.customer_receipts','VIEW');
  SELECT company.timezone,(current_timestamp AT TIME ZONE company.timezone)::date
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
  RETURN (WITH invoice_items AS (
    SELECT 'RETAIL_SALE'::text source_process,sale.id source_id,sale.id sales_id,
      NULL::uuid schedule_id,NULL::integer installment_no,NULL::integer installment_count,
      invoice.invoice_no,sale.customer_id,customer.code customer_code,
      customer.name customer_name,sale.store_id,store.store_name,
      CASE WHEN sale.document_status='POSTED' THEN
        (sale.transaction_date AT TIME ZONE v_timezone)::date ELSE
        (SELECT min(effect.effective_date) FROM public.sales_dispatch_financial_effects effect
          WHERE effect.company_id=sale.company_id AND effect.sales_id=sale.id
            AND effect.effective_date<=v_as_of) END transaction_date,
      CASE WHEN sale.due_date IS NULL THEN NULL ELSE
        (sale.due_date AT TIME ZONE v_timezone)::date END due_date,
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
    JOIN public.customers customer ON customer.company_id=sale.company_id AND customer.id=sale.customer_id
    LEFT JOIN public.stores store ON store.company_id=sale.company_id AND store.id=sale.store_id
    WHERE sale.company_id=v_company AND sale.is_tempo
      AND (sale.document_status='POSTED' OR EXISTS(SELECT 1
        FROM public.sales_dispatch_financial_effects effect
        WHERE effect.company_id=sale.company_id AND effect.sales_id=sale.id
          AND effect.effective_date<=v_as_of))
      AND (p_customer_id IS NULL OR sale.customer_id=p_customer_id)
      AND (p_store_id IS NULL OR sale.store_id=p_store_id)
    UNION ALL
    SELECT 'BACKOFFICE',invoice.id,NULL::uuid,schedule.id,schedule.installment_no,
      (SELECT count(*)::integer FROM public.backoffice_sales_invoice_receivable_schedules all_schedule
       WHERE all_schedule.company_id=invoice.company_id AND all_schedule.invoice_id=invoice.id),
      invoice.invoice_no,invoice.customer_id,customer.code,customer.name,
      invoice.store_id,store.store_name,invoice.invoice_date,schedule.due_date,
      schedule.amount_due,
      GREATEST(LEAST(COALESCE(receipt.paid,0)-COALESCE(sum(schedule.amount_due) OVER(
        PARTITION BY schedule.company_id,schedule.invoice_id ORDER BY schedule.installment_no
        ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING),0),schedule.amount_due),0)
    FROM public.backoffice_sales_invoices invoice
    JOIN public.backoffice_sales_invoice_receivable_schedules schedule
      ON schedule.company_id=invoice.company_id AND schedule.invoice_id=invoice.id
    JOIN public.customers customer ON customer.company_id=invoice.company_id
      AND customer.id=invoice.customer_id
    LEFT JOIN public.stores store ON store.company_id=invoice.company_id AND store.id=invoice.store_id
    LEFT JOIN LATERAL(SELECT sum(allocation.allocated_amount) paid
      FROM public.customer_receipt_backoffice_invoice_allocations allocation
      JOIN public.customer_receipt_documents document
        ON document.company_id=allocation.company_id AND document.id=allocation.document_id
       AND document.status='POSTED' AND document.receipt_date<=v_as_of
      WHERE allocation.company_id=invoice.company_id AND allocation.invoice_id=invoice.id) receipt ON true
    WHERE invoice.company_id=v_company AND invoice.status='POSTED'
      AND invoice.invoice_date<=v_as_of AND schedule.status IN('OPEN','PARTIALLY_PAID','PAID')
      AND (p_customer_id IS NULL OR invoice.customer_id=p_customer_id)
      AND (p_store_id IS NULL OR invoice.store_id=p_store_id)
  ),open_items AS (
    SELECT invoice.*,GREATEST(original_receivable-allocated_amount,0) outstanding,
      CASE WHEN due_date IS NULL THEN 'NO_DUE_DATE' WHEN due_date>=v_as_of THEN 'NOT_DUE'
        WHEN v_as_of-due_date<=30 THEN 'OVERDUE_1_30' WHEN v_as_of-due_date<=60 THEN 'OVERDUE_31_60'
        WHEN v_as_of-due_date<=90 THEN 'OVERDUE_61_90' ELSE 'OVERDUE_GT_90' END aging_bucket,
      CASE WHEN due_date IS NULL OR due_date>=v_as_of THEN 0 ELSE v_as_of-due_date END overdue_days
    FROM invoice_items invoice WHERE original_receivable-allocated_amount>0
  ),bucket_order(bucket,sort_order) AS (VALUES ('NOT_DUE'::text,1),('OVERDUE_1_30',2),
    ('OVERDUE_31_60',3),('OVERDUE_61_90',4),('OVERDUE_GT_90',5),('NO_DUE_DATE',6))
  SELECT jsonb_build_object('companyId',v_company,'asOf',v_as_of,
    'effectiveCapabilities',v_permission->'effectiveCapabilities','summary',jsonb_build_object(
      'invoiceCount',(SELECT count(DISTINCT source_process||'|'||source_id::text) FROM open_items),
      'itemCount',(SELECT count(*) FROM open_items),
      'customerCount',(SELECT count(DISTINCT customer_id) FROM open_items),
      'originalReceivable',COALESCE((SELECT sum(original_receivable) FROM open_items),0),
      'allocatedAmount',COALESCE((SELECT sum(allocated_amount) FROM open_items),0),
      'outstanding',COALESCE((SELECT sum(outstanding) FROM open_items),0),
      'overdue',COALESCE((SELECT sum(outstanding) FROM open_items WHERE aging_bucket LIKE 'OVERDUE%'),0)),
    'buckets',(SELECT jsonb_agg(jsonb_build_object('bucket',bucket_order.bucket,
      'invoiceCount',COALESCE(bucket.invoice_count,0),'customerCount',COALESCE(bucket.customer_count,0),
      'outstanding',COALESCE(bucket.outstanding,0)) ORDER BY bucket_order.sort_order)
      FROM bucket_order LEFT JOIN (SELECT aging_bucket,
        count(DISTINCT source_process||'|'||source_id::text) invoice_count,
        count(DISTINCT customer_id) customer_count,sum(outstanding) outstanding
        FROM open_items GROUP BY aging_bucket) bucket ON bucket.aging_bucket=bucket_order.bucket),
    'invoices',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'sourceProcess',item.source_process,'sourceId',item.source_id,'salesId',item.sales_id,
      'scheduleId',item.schedule_id,'installmentNo',item.installment_no,
      'installmentCount',item.installment_count,'invoiceNo',item.invoice_no,
      'customerId',item.customer_id,'customerCode',item.customer_code,
      'customerName',item.customer_name,'storeId',item.store_id,'storeName',item.store_name,
      'transactionDate',item.transaction_date,'dueDate',item.due_date,
      'originalReceivable',item.original_receivable,'allocatedAmount',item.allocated_amount,
      'outstanding',item.outstanding,'agingBucket',item.aging_bucket,'overdueDays',item.overdue_days)
      ORDER BY item.due_date NULLS LAST,item.transaction_date,item.invoice_no,item.installment_no),'[]'::jsonb)
      FROM open_items item)));
END
$$;

CREATE OR REPLACE FUNCTION public.get_finance_customer_statement(
  p_customer_id uuid,p_date_from date DEFAULT NULL,p_as_of date DEFAULT NULL,p_store_id uuid DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_timezone text;v_company_today date;
  v_from date;v_as_of date;v_customer public.customers%rowtype;v_permission jsonb;
BEGIN
  v_permission:=private.acp_require_permission_capability(v_company,'finance.customer_receipts','VIEW');
  SELECT company.timezone,(current_timestamp AT TIME ZONE company.timezone)::date
    INTO v_timezone,v_company_today FROM public.companies company
    WHERE company.id=v_company AND company.status='ACTIVE';
  IF v_timezone IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_NOT_FOUND'; END IF;
  v_as_of:=COALESCE(p_as_of,v_company_today);v_from:=COALESCE(p_date_from,(v_as_of-INTERVAL '90 days')::date);
  IF v_as_of>v_company_today THEN RAISE EXCEPTION 'AR_AS_OF_DATE_FUTURE'; END IF;
  IF v_from>v_as_of THEN RAISE EXCEPTION 'AR_DATE_RANGE_INVALID'; END IF;
  SELECT * INTO v_customer FROM public.customers customer WHERE customer.company_id=v_company
    AND customer.id=p_customer_id AND NOT customer.is_system_customer;
  IF NOT FOUND THEN RAISE EXCEPTION 'CUSTOMER_NOT_FOUND'; END IF;
  IF p_store_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.stores store
    WHERE store.company_id=v_company AND store.id=p_store_id) THEN RAISE EXCEPTION 'STORE_NOT_FOUND'; END IF;
  RETURN (WITH invoice_rows AS (
    SELECT sale.id source_id,'INVOICE'::text source_type,'RETAIL'::text source_process,
      invoice.invoice_no document_no,(sale.transaction_date AT TIME ZONE v_timezone)::date business_date,
      CASE WHEN sale.due_date IS NULL THEN NULL ELSE (sale.due_date AT TIME ZONE v_timezone)::date END due_date,
      sale.store_id,store.store_name,sale.sisa_piutang debit,0::numeric credit,
      'Invoice penjualan Retail tempo'::text description
    FROM public.sales_headers sale JOIN public.sales_invoice_snapshots invoice
      ON invoice.company_id=sale.company_id AND invoice.sales_id=sale.id
    LEFT JOIN public.stores store ON store.company_id=sale.company_id AND store.id=sale.store_id
    WHERE sale.company_id=v_company AND sale.customer_id=p_customer_id
      AND sale.document_status='POSTED' AND sale.is_tempo
      AND (sale.transaction_date AT TIME ZONE v_timezone)::date<=v_as_of
      AND (p_store_id IS NULL OR sale.store_id=p_store_id)
    UNION ALL
    SELECT effect.id,'INVOICE','RETAIL',invoice.invoice_no,effect.effective_date,
      CASE WHEN sale.due_date IS NULL THEN NULL ELSE (sale.due_date AT TIME ZONE v_timezone)::date END,
      sale.store_id,store.store_name,effect.receivable_amount,0::numeric,
      'Piutang Retail dari Dispatch '||delivery.delivery_no
    FROM public.sales_dispatch_financial_effects effect
    JOIN public.sales_headers sale ON sale.company_id=effect.company_id AND sale.id=effect.sales_id
      AND sale.is_tempo AND sale.customer_id=p_customer_id AND sale.document_status<>'POSTED'
    JOIN public.sales_invoice_snapshots invoice ON invoice.company_id=sale.company_id AND invoice.sales_id=sale.id
    JOIN public.sales_delivery_documents delivery ON delivery.company_id=effect.company_id
      AND delivery.id=effect.delivery_document_id
    LEFT JOIN public.stores store ON store.company_id=sale.company_id AND store.id=sale.store_id
    WHERE effect.company_id=v_company AND effect.effective_date<=v_as_of
      AND effect.receivable_amount>0 AND (p_store_id IS NULL OR sale.store_id=p_store_id)
    UNION ALL
    SELECT invoice.id,'INVOICE','BACKOFFICE',invoice.invoice_no,invoice.invoice_date,
      (SELECT min(schedule.due_date) FROM public.backoffice_sales_invoice_receivable_schedules schedule
       WHERE schedule.company_id=invoice.company_id AND schedule.invoice_id=invoice.id),
      invoice.store_id,store.store_name,invoice.grand_total,0::numeric,
      CASE invoice.invoice_type WHEN 'DOWN_PAYMENT' THEN 'Invoice DP Backoffice'
        ELSE 'Invoice penjualan Backoffice' END
    FROM public.backoffice_sales_invoices invoice
    LEFT JOIN public.stores store ON store.company_id=invoice.company_id AND store.id=invoice.store_id
    WHERE invoice.company_id=v_company AND invoice.customer_id=p_customer_id
      AND invoice.status='POSTED' AND invoice.invoice_date<=v_as_of
      AND (p_store_id IS NULL OR invoice.store_id=p_store_id)
  ),receipt_rows AS (
    SELECT allocation.id source_id,'RECEIPT'::text source_type,'RETAIL'::text source_process,
      receipt.receipt_no document_no,receipt.receipt_date business_date,
      CASE WHEN allocation.due_date_snapshot IS NULL THEN NULL
        ELSE (allocation.due_date_snapshot AT TIME ZONE v_timezone)::date END due_date,
      sale.store_id,store.store_name,0::numeric debit,allocation.allocated_amount credit,
      ('Pembayaran Retail '||allocation.invoice_no_snapshot)::text description
    FROM public.customer_receipt_allocations allocation JOIN public.customer_receipt_documents receipt
      ON receipt.company_id=allocation.company_id AND receipt.id=allocation.document_id AND receipt.status='POSTED'
    JOIN public.sales_headers sale ON sale.company_id=allocation.company_id AND sale.id=allocation.sales_id
      AND sale.customer_id=p_customer_id LEFT JOIN public.stores store
      ON store.company_id=sale.company_id AND store.id=sale.store_id
    WHERE allocation.company_id=v_company AND receipt.customer_id=p_customer_id
      AND receipt.receipt_date<=v_as_of AND (p_store_id IS NULL OR sale.store_id=p_store_id)
    UNION ALL
    SELECT request.id,'ODR_PAYMENT','RETAIL',sale.invoice_no,request.effective_date,
      CASE WHEN sale.due_date IS NULL THEN NULL ELSE (sale.due_date AT TIME ZONE v_timezone)::date END,
      sale.store_id,store.store_name,0::numeric,request.amount,'Pembayaran ODR terverifikasi'
    FROM public.sales_payment_verification_requests request JOIN public.sales_headers sale
      ON sale.company_id=request.company_id AND sale.id=request.sales_id AND sale.customer_id=p_customer_id
    LEFT JOIN public.stores store ON store.company_id=sale.company_id AND store.id=sale.store_id
    WHERE request.company_id=v_company AND request.status='VERIFIED'
      AND request.receipt_timing='POST_DISPATCH' AND request.settlement_target='CUSTOMER_RECEIVABLE'
      AND request.effective_date<=v_as_of AND (p_store_id IS NULL OR sale.store_id=p_store_id)
    UNION ALL
    SELECT allocation.id,'RECEIPT','BACKOFFICE',receipt.receipt_no,receipt.receipt_date,
      allocation.due_date_snapshot,invoice.store_id,store.store_name,0::numeric,
      allocation.allocated_amount,('Pembayaran Backoffice '||allocation.invoice_no_snapshot)::text
    FROM public.customer_receipt_backoffice_invoice_allocations allocation
    JOIN public.customer_receipt_documents receipt
      ON receipt.company_id=allocation.company_id AND receipt.id=allocation.document_id AND receipt.status='POSTED'
    JOIN public.backoffice_sales_invoices invoice
      ON invoice.company_id=allocation.company_id AND invoice.id=allocation.invoice_id
      AND invoice.customer_id=p_customer_id
    LEFT JOIN public.stores store ON store.company_id=invoice.company_id AND store.id=invoice.store_id
    WHERE allocation.company_id=v_company AND receipt.customer_id=p_customer_id
      AND receipt.receipt_date<=v_as_of AND (p_store_id IS NULL OR invoice.store_id=p_store_id)
  ),all_rows AS (SELECT * FROM invoice_rows UNION ALL SELECT * FROM receipt_rows),
  opening AS (SELECT COALESCE(sum(debit-credit),0) amount FROM all_rows WHERE business_date<v_from),
  period_rows AS (SELECT row_data.*,row_number() OVER(ORDER BY business_date,
    CASE source_type WHEN 'INVOICE' THEN 1 ELSE 2 END,source_process,source_id) sequence_no
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
      'sourceId',row_data.source_id,'sourceType',row_data.source_type,
      'sourceProcess',row_data.source_process,'documentNo',row_data.document_no,
      'businessDate',row_data.business_date,'dueDate',row_data.due_date,'storeId',row_data.store_id,
      'storeName',row_data.store_name,'description',row_data.description,'debit',row_data.debit,
      'credit',row_data.credit,'runningBalance',row_data.running_balance)
      ORDER BY row_data.sequence_no),'[]'::jsonb) FROM running row_data)));
END
$$;

REVOKE ALL ON FUNCTION public.post_customer_receipt_unified(uuid,bigint,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.post_customer_receipt_unified(uuid,bigint,uuid) TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260911163000','backoffice_sales_ar_reporting_integration',
  'Integrate typed Retail and Backoffice Invoice sources into existing Customer Receipt workspace, AR Aging, Customer Statement, export reader and unified posting dispatch; no data backfill or Stock/DO/POS/Invoice mutation');

NOTIFY pgrst,'reload schema';
COMMIT;
