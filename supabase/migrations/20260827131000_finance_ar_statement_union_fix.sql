-- Forward-fix F4A Customer Statement UNION shape after 20260827130000.
BEGIN;
DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260827130000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Finance F4A runtime required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260827131000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260827131000';
  END IF;
  IF to_regprocedure('public.get_finance_customer_statement(uuid,date,date,uuid)') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Customer Statement routine missing';
  END IF;
END
$guard$;

CREATE OR REPLACE FUNCTION public.get_finance_customer_statement(
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
      sale.store_id,store.store_name,0::NUMERIC debit,allocation.allocated_amount credit,
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

REVOKE ALL ON FUNCTION public.get_finance_customer_statement(UUID,DATE,DATE,UUID)
  FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_finance_customer_statement(UUID,DATE,DATE,UUID)
  TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260827131000','finance_ar_statement_union_fix',
  'Align Invoice and Receipt statement rows to the same Store-aware ten-column UNION shape');
COMMIT;
