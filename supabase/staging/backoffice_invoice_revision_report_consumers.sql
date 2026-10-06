-- Generated only from the captured active staging definitions and exact anchors.
CREATE OR REPLACE FUNCTION public.get_finance_ar_aging(p_as_of date DEFAULT NULL::date, p_customer_id uuid DEFAULT NULL::uuid, p_store_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
        WHERE allocation.company_id=v_company AND allocation.sales_id=sale.id),0) allocated_amount,
      COALESCE((SELECT sum(note.ar_reduction_amount)
        FROM public.backoffice_sales_credit_notes note
        WHERE note.company_id=v_company AND note.source_kind='RETAINED_RETAIL'
          AND note.source_retail_sales_id=sale.id AND note.status='POSTED'
          AND note.credit_note_date<=v_as_of),0) credited_amount
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
      invoice.invoice_no,(identity.value->>'customerId')::uuid,customer.code,customer.name,
      invoice.store_id,store.store_name,
      (identity.value->>'invoiceDate')::date,schedule.due_date,
      schedule.amount_due,
      GREATEST(LEAST(COALESCE(receipt.paid,0)+COALESCE(credit.credited,0)-COALESCE(sum(schedule.amount_due) OVER(
        PARTITION BY schedule.company_id,schedule.invoice_id ORDER BY schedule.installment_no
        ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING),0),schedule.amount_due),0),
      0::numeric credited_amount
    FROM public.backoffice_sales_invoices invoice
    JOIN public.backoffice_sales_invoice_receivable_schedules schedule
      ON schedule.company_id=invoice.company_id AND schedule.invoice_id=invoice.id
    JOIN LATERAL(SELECT private.backoffice_invoice_effective_identity(invoice.company_id,invoice.id,v_as_of) value) identity ON true
    JOIN public.customers customer ON customer.company_id=invoice.company_id
      AND customer.id=(identity.value->>'customerId')::uuid
    LEFT JOIN public.stores store ON store.company_id=invoice.company_id AND store.id=invoice.store_id
    LEFT JOIN LATERAL(SELECT sum(allocation.allocated_amount) paid
      FROM public.customer_receipt_backoffice_invoice_allocations allocation
      JOIN public.customer_receipt_documents document
        ON document.company_id=allocation.company_id AND document.id=allocation.document_id
       AND document.status='POSTED' AND document.receipt_date<=v_as_of
      WHERE allocation.company_id=invoice.company_id AND allocation.invoice_id=invoice.id) receipt ON true
    LEFT JOIN LATERAL(SELECT sum(note.ar_reduction_amount) credited
      FROM public.backoffice_sales_credit_notes note
      WHERE note.company_id=invoice.company_id AND note.source_invoice_id=invoice.id
        AND note.status='POSTED' AND note.credit_note_date<=v_as_of) credit ON true
    WHERE invoice.company_id=v_company AND invoice.status='POSTED'
      AND (identity.value->>'invoiceDate')::date<=v_as_of AND schedule.status IN('OPEN','PARTIALLY_PAID','PAID')
      AND (p_customer_id IS NULL OR (identity.value->>'customerId')::uuid=p_customer_id)
      AND (p_store_id IS NULL OR invoice.store_id=p_store_id)
  ),open_items AS (
    SELECT invoice.*,GREATEST(original_receivable-allocated_amount-credited_amount,0) outstanding,
      CASE WHEN due_date IS NULL THEN 'NO_DUE_DATE' WHEN due_date>=v_as_of THEN 'NOT_DUE'
        WHEN v_as_of-due_date<=30 THEN 'OVERDUE_1_30' WHEN v_as_of-due_date<=60 THEN 'OVERDUE_31_60'
        WHEN v_as_of-due_date<=90 THEN 'OVERDUE_61_90' ELSE 'OVERDUE_GT_90' END aging_bucket,
      CASE WHEN due_date IS NULL OR due_date>=v_as_of THEN 0 ELSE v_as_of-due_date END overdue_days
    FROM invoice_items invoice WHERE original_receivable-allocated_amount-credited_amount>0
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
      'originalReceivable',item.original_receivable,'allocatedAmount',item.allocated_amount,'creditedAmount',item.credited_amount,
      'outstanding',item.outstanding,'agingBucket',item.aging_bucket,'overdueDays',item.overdue_days)
      ORDER BY item.due_date NULLS LAST,item.transaction_date,item.invoice_no,item.installment_no),'[]'::jsonb)
      FROM open_items item)));
END
$function$;

CREATE OR REPLACE FUNCTION public.get_finance_customer_statement(p_customer_id uuid, p_date_from date DEFAULT NULL::date, p_as_of date DEFAULT NULL::date, p_store_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
    SELECT invoice.id,'INVOICE','BACKOFFICE',invoice.invoice_no,(identity.value->>'invoiceDate')::date,
      (SELECT min(schedule.due_date) FROM public.backoffice_sales_invoice_receivable_schedules schedule
       WHERE schedule.company_id=invoice.company_id AND schedule.invoice_id=invoice.id),
      invoice.store_id,store.store_name,invoice.grand_total,0::numeric,
      CASE invoice.invoice_type WHEN 'DOWN_PAYMENT' THEN 'Invoice DP Backoffice'
        ELSE 'Invoice penjualan Backoffice' END
    FROM public.backoffice_sales_invoices invoice
    JOIN LATERAL(SELECT private.backoffice_invoice_effective_identity(invoice.company_id,invoice.id,v_as_of) value) identity ON true
    LEFT JOIN public.stores store ON store.company_id=invoice.company_id AND store.id=invoice.store_id
    WHERE invoice.company_id=v_company AND (identity.value->>'customerId')::uuid=p_customer_id
      AND invoice.status='POSTED' AND (identity.value->>'invoiceDate')::date<=v_as_of
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
    JOIN LATERAL(SELECT private.backoffice_invoice_effective_identity(invoice.company_id,invoice.id,v_as_of) value) identity ON true
    LEFT JOIN public.stores store ON store.company_id=invoice.company_id AND store.id=invoice.store_id
    WHERE allocation.company_id=v_company AND (identity.value->>'customerId')::uuid=p_customer_id
      AND receipt.receipt_date<=v_as_of AND (p_store_id IS NULL OR invoice.store_id=p_store_id)
    UNION ALL
    SELECT note.id,'CREDIT_NOTE',CASE note.source_kind
        WHEN 'RETAINED_RETAIL' THEN 'RETAIL' ELSE 'BACKOFFICE' END,note.credit_note_no,note.credit_note_date,
      NULL::date,note.store_id,store.store_name,0::numeric,note.grand_total,
      ('Credit Note Retur Customer untuk '||COALESCE(source.invoice_no,
        note.source_invoice_snapshot->>'invoiceNo'))::text
    FROM public.backoffice_sales_credit_notes note
    LEFT JOIN public.backoffice_sales_invoices source
      ON source.company_id=note.company_id AND source.id=note.source_invoice_id
    LEFT JOIN public.stores store ON store.company_id=note.company_id AND store.id=note.store_id
    WHERE note.company_id=v_company AND note.customer_id=p_customer_id
      AND note.status='POSTED' AND note.credit_note_date<=v_as_of
      AND (p_store_id IS NULL OR note.store_id=p_store_id)
    UNION ALL
    SELECT refund.id,'CUSTOMER_REFUND','BACKOFFICE',refund.refund_no,refund.refund_date,
      NULL::date,refund.store_id,store.store_name,
      CASE WHEN refund.document_kind='REFUND' THEN refund.amount ELSE 0::numeric END,
      CASE WHEN refund.document_kind='REVERSAL' THEN refund.amount ELSE 0::numeric END,
      (CASE WHEN refund.document_kind='REFUND' THEN 'Refund Customer untuk '
        ELSE 'Reversal Refund Customer untuk ' END||note.credit_note_no)::text
    FROM public.backoffice_sales_customer_refunds refund
    JOIN public.backoffice_sales_credit_notes note
      ON note.company_id=refund.company_id AND note.id=refund.credit_note_id
      AND note.customer_id=p_customer_id
    LEFT JOIN public.stores store
      ON store.company_id=refund.company_id AND store.id=refund.store_id
    WHERE refund.company_id=v_company AND refund.status='POSTED'
      AND refund.refund_date<=v_as_of
      AND (p_store_id IS NULL OR refund.store_id=p_store_id)
    UNION ALL
    SELECT correction.id,'PRICE_CORRECTION','BACKOFFICE',correction.correction_no,
      correction.correction_date,NULL::date,invoice.store_id,store.store_name,
      CASE WHEN correction.total_delta>0 THEN correction.total_delta ELSE 0::numeric END,
      CASE WHEN correction.total_delta<0 THEN -correction.total_delta ELSE 0::numeric END,
      (CASE correction.correction_kind WHEN 'DEBIT_NOTE' THEN 'Debit Note koreksi harga untuk '
        ELSE 'Credit Note koreksi harga untuk ' END||invoice.invoice_no)::text
    FROM public.backoffice_sales_invoice_price_corrections correction
    JOIN public.backoffice_sales_invoices invoice
      ON invoice.company_id=correction.company_id AND invoice.id=correction.source_invoice_id
    JOIN LATERAL(SELECT private.backoffice_invoice_effective_identity(invoice.company_id,invoice.id,v_as_of) value) identity ON true
    LEFT JOIN public.stores store ON store.company_id=invoice.company_id AND store.id=invoice.store_id
    WHERE correction.company_id=v_company AND correction.status='POSTED'
      AND correction.correction_date<=v_as_of
      AND (p_store_id IS NULL OR invoice.store_id=p_store_id)
    UNION ALL
    SELECT revision.id,'INVOICE_REVISION','BACKOFFICE',
      invoice.invoice_no||'-R'||revision.revision_no,revision.revision_date,NULL::date,
      invoice.store_id,store.store_name,greatest(revision.payable_delta,0),
      greatest(-revision.payable_delta,0),'Koreksi Invoice posted'
    FROM private.backoffice_invoice_revisions revision
    JOIN public.backoffice_sales_invoices invoice ON invoice.company_id=revision.company_id
      AND invoice.id=revision.invoice_id
    LEFT JOIN public.stores store ON store.company_id=invoice.company_id AND store.id=invoice.store_id
    WHERE revision.company_id=v_company AND revision.new_customer_id=p_customer_id
      AND revision.revision_date<=v_as_of AND revision.payable_delta<>0
      AND (p_store_id IS NULL OR invoice.store_id=p_store_id)
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
$function$;
