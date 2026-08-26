-- F4A Finance AR reporting runtime: outstanding, aging, statement and export.
-- Read-only reporting; no transaction, receipt, balance or journal mutation.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260827120000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Finance F3 required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260827130000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260827130000';
  END IF;
  IF EXISTS(SELECT 1 FROM pg_proc routine JOIN pg_namespace namespace
    ON namespace.oid=routine.pronamespace WHERE namespace.nspname='public'
      AND routine.proname IN('get_finance_ar_aging','get_finance_customer_statement',
        'export_finance_ar_report')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: AR reporting routine exists';
  END IF;
END
$guard$;

CREATE FUNCTION private.trg_customer_receipt_allocation_date_guard()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_receipt_date DATE;v_order_date DATE;
BEGIN
  SELECT receipt.receipt_date,
    (sale.transaction_date AT TIME ZONE company.timezone)::DATE
    INTO v_receipt_date,v_order_date
  FROM public.customer_receipt_documents receipt
  JOIN public.companies company ON company.id=receipt.company_id
  JOIN public.sales_headers sale ON sale.company_id=receipt.company_id
    AND sale.id=NEW.sales_id
  WHERE receipt.company_id=NEW.company_id AND receipt.id=NEW.document_id;
  IF v_receipt_date IS NULL OR v_order_date IS NULL THEN
    RAISE EXCEPTION 'CUSTOMER_RECEIPT_TEMPORAL_SOURCE_INVALID';
  END IF;
  IF v_receipt_date<v_order_date THEN
    RAISE EXCEPTION 'CUSTOMER_RECEIPT_BEFORE_ORDER_DATE';
  END IF;
  RETURN NEW;
END
$$;
CREATE TRIGGER customer_receipt_allocation_date_guard
BEFORE INSERT OR UPDATE OF company_id,document_id,sales_id
ON public.customer_receipt_allocations FOR EACH ROW
EXECUTE FUNCTION private.trg_customer_receipt_allocation_date_guard();

CREATE FUNCTION public.get_finance_ar_aging(
  p_as_of DATE DEFAULT NULL,p_customer_id UUID DEFAULT NULL,p_store_id UUID DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_timezone TEXT;
  v_company_today DATE;v_as_of DATE;v_permission JSONB;
BEGIN
  v_permission:=private.acp_require_permission_capability(
    v_company,'finance.customer_receipts','VIEW');
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
    WHERE store.company_id=v_company AND store.id=p_store_id) THEN
    RAISE EXCEPTION 'STORE_NOT_FOUND';
  END IF;

  RETURN (WITH invoices AS (
    SELECT sale.id sales_id,invoice.invoice_no,sale.customer_id,customer.code customer_code,
      customer.name customer_name,sale.store_id,store.store_name,
      (sale.transaction_date AT TIME ZONE v_timezone)::DATE transaction_date,
      CASE WHEN sale.due_date IS NULL THEN NULL
        ELSE (sale.due_date AT TIME ZONE v_timezone)::DATE END due_date,
      sale.sisa_piutang original_receivable,
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
    WHERE sale.company_id=v_company AND sale.document_status='POSTED' AND sale.is_tempo
      AND (sale.transaction_date AT TIME ZONE v_timezone)::DATE<=v_as_of
      AND (p_customer_id IS NULL OR sale.customer_id=p_customer_id)
      AND (p_store_id IS NULL OR sale.store_id=p_store_id)
  ),open_items AS (
    SELECT invoice.*,GREATEST(invoice.original_receivable-invoice.allocated_amount,0) outstanding,
      CASE WHEN invoice.due_date IS NULL THEN 'NO_DUE_DATE'
        WHEN invoice.due_date>=v_as_of THEN 'NOT_DUE'
        WHEN v_as_of-invoice.due_date<=30 THEN 'OVERDUE_1_30'
        WHEN v_as_of-invoice.due_date<=60 THEN 'OVERDUE_31_60'
        WHEN v_as_of-invoice.due_date<=90 THEN 'OVERDUE_61_90'
        ELSE 'OVERDUE_GT_90' END aging_bucket,
      CASE WHEN invoice.due_date IS NULL OR invoice.due_date>=v_as_of THEN 0
        ELSE v_as_of-invoice.due_date END overdue_days
    FROM invoices invoice
    WHERE invoice.original_receivable-invoice.allocated_amount>0
  ),bucket_order(bucket,sort_order) AS (VALUES
    ('NOT_DUE'::TEXT,1),('OVERDUE_1_30',2),('OVERDUE_31_60',3),
    ('OVERDUE_61_90',4),('OVERDUE_GT_90',5),('NO_DUE_DATE',6)
  )
  SELECT jsonb_build_object(
    'companyId',v_company,'asOf',v_as_of,
    'effectiveCapabilities',v_permission->'effectiveCapabilities',
    'summary',jsonb_build_object(
      'invoiceCount',(SELECT count(*) FROM open_items),
      'customerCount',(SELECT count(DISTINCT customer_id) FROM open_items),
      'originalReceivable',COALESCE((SELECT sum(original_receivable) FROM open_items),0),
      'allocatedAmount',COALESCE((SELECT sum(allocated_amount) FROM open_items),0),
      'outstanding',COALESCE((SELECT sum(outstanding) FROM open_items),0),
      'overdue',COALESCE((SELECT sum(outstanding) FROM open_items
        WHERE aging_bucket LIKE 'OVERDUE%'),0)),
    'buckets',(SELECT jsonb_agg(jsonb_build_object('bucket',bucket_order.bucket,
      'invoiceCount',COALESCE(bucket.invoice_count,0),
      'customerCount',COALESCE(bucket.customer_count,0),
      'outstanding',COALESCE(bucket.outstanding,0)) ORDER BY bucket_order.sort_order)
      FROM bucket_order LEFT JOIN (SELECT aging_bucket,count(*) invoice_count,
        count(DISTINCT customer_id) customer_count,sum(outstanding) outstanding
        FROM open_items GROUP BY aging_bucket) bucket ON bucket.aging_bucket=bucket_order.bucket),
    'invoices',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'salesId',item.sales_id,'invoiceNo',item.invoice_no,'customerId',item.customer_id,
      'customerCode',item.customer_code,'customerName',item.customer_name,
      'storeId',item.store_id,'storeName',item.store_name,
      'transactionDate',item.transaction_date,'dueDate',item.due_date,
      'originalReceivable',item.original_receivable,'allocatedAmount',item.allocated_amount,
      'outstanding',item.outstanding,'agingBucket',item.aging_bucket,
      'overdueDays',item.overdue_days) ORDER BY item.due_date NULLS LAST,
        item.transaction_date,item.invoice_no),'[]'::JSONB) FROM open_items item)
  ));
END
$$;

CREATE FUNCTION public.get_finance_customer_statement(
  p_customer_id UUID,p_date_from DATE DEFAULT NULL,p_as_of DATE DEFAULT NULL,
  p_store_id UUID DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_timezone TEXT;
  v_company_today DATE;v_from DATE;v_as_of DATE;v_customer public.customers%ROWTYPE;
  v_permission JSONB;
BEGIN
  v_permission:=private.acp_require_permission_capability(
    v_company,'finance.customer_receipts','VIEW');
  SELECT company.timezone,(current_timestamp AT TIME ZONE company.timezone)::DATE
    INTO v_timezone,v_company_today FROM public.companies company
  WHERE company.id=v_company AND company.status='ACTIVE';
  IF v_timezone IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_NOT_FOUND'; END IF;
  v_as_of:=COALESCE(p_as_of,v_company_today);
  v_from:=COALESCE(p_date_from,(v_as_of-INTERVAL '90 days')::DATE);
  IF v_as_of>v_company_today THEN RAISE EXCEPTION 'AR_AS_OF_DATE_FUTURE'; END IF;
  IF v_from>v_as_of THEN RAISE EXCEPTION 'AR_DATE_RANGE_INVALID'; END IF;
  SELECT * INTO v_customer FROM public.customers customer
  WHERE customer.company_id=v_company AND customer.id=p_customer_id
    AND NOT customer.is_system_customer;
  IF NOT FOUND THEN RAISE EXCEPTION 'CUSTOMER_NOT_FOUND'; END IF;
  IF p_store_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.stores store
    WHERE store.company_id=v_company AND store.id=p_store_id) THEN
    RAISE EXCEPTION 'STORE_NOT_FOUND';
  END IF;

  RETURN (WITH invoice_rows AS (
    SELECT sale.id source_id,'INVOICE'::TEXT source_type,invoice.invoice_no document_no,
      (sale.transaction_date AT TIME ZONE v_timezone)::DATE business_date,
      CASE WHEN sale.due_date IS NULL THEN NULL
        ELSE (sale.due_date AT TIME ZONE v_timezone)::DATE END due_date,
      sale.store_id,store.store_name,sale.sisa_piutang debit,0::NUMERIC credit,
      'Invoice penjualan tempo'::TEXT description
    FROM public.sales_headers sale
    JOIN public.sales_invoice_snapshots invoice ON invoice.company_id=sale.company_id
      AND invoice.sales_id=sale.id
    LEFT JOIN public.stores store ON store.company_id=sale.company_id AND store.id=sale.store_id
    WHERE sale.company_id=v_company AND sale.customer_id=p_customer_id
      AND sale.document_status='POSTED' AND sale.is_tempo
      AND (sale.transaction_date AT TIME ZONE v_timezone)::DATE<=v_as_of
      AND (p_store_id IS NULL OR sale.store_id=p_store_id)
  ),receipt_rows AS (
    SELECT allocation.id source_id,'RECEIPT'::TEXT source_type,
      receipt.receipt_no document_no,receipt.receipt_date business_date,
      CASE WHEN allocation.due_date_snapshot IS NULL THEN NULL
        ELSE (allocation.due_date_snapshot AT TIME ZONE v_timezone)::DATE END due_date,
      sale.store_id,store.store_name,
      0::NUMERIC debit,allocation.allocated_amount credit,
      ('Pembayaran '||allocation.invoice_no_snapshot)::TEXT description
    FROM public.customer_receipt_allocations allocation
    JOIN public.customer_receipt_documents receipt ON receipt.company_id=allocation.company_id
      AND receipt.id=allocation.document_id AND receipt.status='POSTED'
    JOIN public.sales_headers sale ON sale.company_id=allocation.company_id
      AND sale.id=allocation.sales_id AND sale.customer_id=p_customer_id
    LEFT JOIN public.stores store ON store.company_id=sale.company_id AND store.id=sale.store_id
    WHERE allocation.company_id=v_company AND receipt.customer_id=p_customer_id
      AND receipt.receipt_date<=v_as_of AND (p_store_id IS NULL OR sale.store_id=p_store_id)
  ),all_rows AS (SELECT * FROM invoice_rows UNION ALL SELECT * FROM receipt_rows),
  opening AS (SELECT COALESCE(sum(debit-credit),0) amount FROM all_rows
    WHERE business_date<v_from),period_rows AS (
    SELECT row_data.*,row_number() OVER(ORDER BY business_date,
      CASE source_type WHEN 'INVOICE' THEN 1 ELSE 2 END,source_id) sequence_no
    FROM all_rows row_data WHERE business_date BETWEEN v_from AND v_as_of
  ),running AS (
    SELECT period_rows.*,opening.amount+sum(debit-credit) OVER(ORDER BY sequence_no
      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) running_balance
    FROM period_rows CROSS JOIN opening
  )
  SELECT jsonb_build_object('companyId',v_company,'customer',jsonb_build_object(
      'id',v_customer.id,'code',v_customer.code,'name',v_customer.name),
    'dateFrom',v_from,'asOf',v_as_of,
    'effectiveCapabilities',v_permission->'effectiveCapabilities',
    'openingBalance',(SELECT amount FROM opening),
    'periodDebit',COALESCE((SELECT sum(debit) FROM period_rows),0),
    'periodCredit',COALESCE((SELECT sum(credit) FROM period_rows),0),
    'endingBalance',(SELECT amount FROM opening)+
      COALESCE((SELECT sum(debit-credit) FROM period_rows),0),
    'rows',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'sequence',row_data.sequence_no,'sourceId',row_data.source_id,
      'sourceType',row_data.source_type,'documentNo',row_data.document_no,
      'businessDate',row_data.business_date,'dueDate',row_data.due_date,
      'storeId',row_data.store_id,'storeName',row_data.store_name,
      'description',row_data.description,'debit',row_data.debit,
      'credit',row_data.credit,'runningBalance',row_data.running_balance)
      ORDER BY row_data.sequence_no),'[]'::JSONB) FROM running row_data)
  ));
END
$$;

CREATE FUNCTION public.export_finance_ar_report(
  p_report_type TEXT,p_customer_id UUID DEFAULT NULL,p_date_from DATE DEFAULT NULL,
  p_as_of DATE DEFAULT NULL,p_store_id UUID DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_type TEXT:=upper(btrim(COALESCE(p_report_type,'')));
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'finance.customer_receipts','EXPORT');
  IF v_type='AGING' THEN
    RETURN public.get_finance_ar_aging(p_as_of,p_customer_id,p_store_id);
  ELSIF v_type='STATEMENT' THEN
    IF p_customer_id IS NULL THEN RAISE EXCEPTION 'CUSTOMER_REQUIRED_FOR_STATEMENT'; END IF;
    RETURN public.get_finance_customer_statement(p_customer_id,p_date_from,p_as_of,p_store_id);
  END IF;
  RAISE EXCEPTION 'AR_REPORT_TYPE_INVALID';
END
$$;

REVOKE ALL ON FUNCTION public.get_finance_ar_aging(DATE,UUID,UUID),
  public.get_finance_customer_statement(UUID,DATE,DATE,UUID),
  public.export_finance_ar_report(TEXT,UUID,DATE,DATE,UUID) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_finance_ar_aging(DATE,UUID,UUID),
  public.get_finance_customer_statement(UUID,DATE,DATE,UUID),
  public.export_finance_ar_report(TEXT,UUID,DATE,DATE,UUID) TO authenticated,service_role;
REVOKE ALL ON FUNCTION private.trg_customer_receipt_allocation_date_guard()
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.trg_customer_receipt_allocation_date_guard() TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260827130000','finance_ar_reporting_runtime',
  'Tenant-scoped AR outstanding, aging, Customer statement and explicit EXPORT runtime from final sources, plus payment business-date guard');
COMMIT;
