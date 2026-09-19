-- Align Customer Receipt candidates and allocation guards with posted Customer Credit Notes.
BEGIN;

DO $guard$
DECLARE v_workspace text;v_save text;v_post text;
BEGIN
  IF (SELECT count(*) FROM private.kgs_schema_migrations
    WHERE version IN('20260917131000','20260918150000','20260919100000'))<>3 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Return Credit Note and net-commercial chain required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260919110000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260919110000';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
    WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
  IF to_regprocedure('private.customer_receipt_retail_receivable_before_receipts(uuid,uuid,date)') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Customer Receipt Credit Note helper collision';
  END IF;
  SELECT pg_get_functiondef(to_regprocedure('public.get_finance_customer_receipts()')) INTO STRICT v_workspace;
  SELECT pg_get_functiondef(to_regprocedure(
    'public.save_customer_receipt_allocated_draft(uuid,bigint,uuid,date,uuid,text,text,text,numeric,jsonb)')) INTO STRICT v_save;
  SELECT pg_get_functiondef(to_regprocedure(
    'public.post_customer_receipt_allocated(uuid,bigint,uuid)')) INTO STRICT v_post;
  IF position('''remainingAmount'',row_data.original_receivable-row_data.allocated_amount' IN v_workspace)=0
    OR position('v_invoice.grand_total-v_paid' IN v_save)=0
    OR position('private.odr6d_dispatched_receivable_before_receipts(' IN v_save)=0
    OR position('customer_receipt_retail_receivable_before_receipts' IN v_post)>0 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Customer Receipt runtime anchor drift';
  END IF;
END
$guard$;

CREATE FUNCTION private.customer_receipt_retail_receivable_before_receipts(
  p_company_id uuid,p_sales_id uuid,p_as_of date
) RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
  SELECT greatest(0,round(
    private.odr6d_dispatched_receivable_before_receipts(p_company_id,p_sales_id,p_as_of)
    -COALESCE((SELECT sum(note.ar_reduction_amount)
      FROM public.backoffice_sales_credit_notes note
      WHERE note.company_id=p_company_id AND note.source_kind='RETAINED_RETAIL'
        AND note.source_retail_sales_id=p_sales_id AND note.status='POSTED'
        AND note.credit_note_date<=p_as_of),0),4))
$$;

DO $patch_workspace$
DECLARE v_definition text;v_old text;v_new text;v_count integer;
BEGIN
  SELECT pg_get_functiondef(to_regprocedure('public.get_finance_customer_receipts()'))
  INTO STRICT v_definition;

  v_old:='private.odr6d_dispatched_receivable_before_receipts(
          sale.company_id,sale.id,v_today) original_receivable,
        COALESCE(receipt.paid,0) allocated_amount
      FROM public.sales_headers sale';
  v_new:='private.odr6d_dispatched_receivable_before_receipts(
          sale.company_id,sale.id,v_today) original_receivable,
        COALESCE(receipt.paid,0) allocated_amount,
        COALESCE((SELECT sum(note.ar_reduction_amount)
          FROM public.backoffice_sales_credit_notes note
          WHERE note.company_id=sale.company_id AND note.source_kind=''RETAINED_RETAIL''
            AND note.source_retail_sales_id=sale.id AND note.status=''POSTED''
            AND note.credit_note_date<=v_today),0) credited_amount
      FROM public.sales_headers sale';
  v_count:=(length(v_definition)-length(replace(v_definition,v_old,'')))/length(v_old);
  IF v_count<>1 THEN RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Retail Receipt workspace anchor drift'; END IF;
  v_definition:=replace(v_definition,v_old,v_new);

  v_old:='store.store_name,invoice.grand_total,COALESCE(receipt.paid,0)
      FROM public.backoffice_sales_invoices invoice';
  v_new:='store.store_name,invoice.grand_total,COALESCE(receipt.paid,0),
        COALESCE((SELECT sum(note.ar_reduction_amount)
          FROM public.backoffice_sales_credit_notes note
          WHERE note.company_id=invoice.company_id AND note.source_kind=''BACKOFFICE''
            AND note.source_invoice_id=invoice.id AND note.status=''POSTED''
            AND note.credit_note_date<=v_today),0)
      FROM public.backoffice_sales_invoices invoice';
  v_count:=(length(v_definition)-length(replace(v_definition,v_old,'')))/length(v_old);
  IF v_count<>1 THEN RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Backoffice Receipt workspace anchor drift'; END IF;
  v_definition:=replace(v_definition,v_old,v_new);

  v_old:='''allocatedAmount'',row_data.allocated_amount,
      ''remainingAmount'',row_data.original_receivable-row_data.allocated_amount)';
  v_new:='''allocatedAmount'',row_data.allocated_amount,
      ''creditedAmount'',row_data.credited_amount,
      ''remainingAmount'',greatest(0,row_data.original_receivable
        -row_data.allocated_amount-row_data.credited_amount))';
  v_count:=(length(v_definition)-length(replace(v_definition,v_old,'')))/length(v_old);
  IF v_count<>1 THEN RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Receipt workspace output anchor drift'; END IF;
  v_definition:=replace(v_definition,v_old,v_new);

  v_old:='WHERE row_data.original_receivable-row_data.allocated_amount>0)';
  v_new:='WHERE row_data.original_receivable-row_data.allocated_amount-row_data.credited_amount>0)';
  v_count:=(length(v_definition)-length(replace(v_definition,v_old,'')))/length(v_old);
  IF v_count<>1 THEN RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Receipt workspace open-row anchor drift'; END IF;
  EXECUTE replace(v_definition,v_old,v_new);
END
$patch_workspace$;

DO $patch_save$
DECLARE v_definition text;v_old text;v_new text;v_count integer;
BEGIN
  SELECT pg_get_functiondef(to_regprocedure(
    'public.save_customer_receipt_allocated_draft(uuid,bigint,uuid,date,uuid,text,text,text,numeric,jsonb)'))
  INTO STRICT v_definition;

  v_old:='IF v_amount>private.odr6d_dispatched_receivable_before_receipts(
        v_company,v_sale.id,p_receipt_date)-v_paid THEN';
  v_new:='IF v_amount>private.customer_receipt_retail_receivable_before_receipts(
        v_company,v_sale.id,p_receipt_date)-v_paid THEN';
  v_count:=(length(v_definition)-length(replace(v_definition,v_old,'')))/length(v_old);
  IF v_count<>1 THEN RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Retail Receipt save anchor drift'; END IF;
  v_definition:=replace(v_definition,v_old,v_new);

  v_old:='IF v_amount>v_invoice.grand_total-v_paid THEN';
  v_new:='IF v_amount>private.backoffice_invoice_receivable_before_receipts(
        v_company,v_invoice.id,p_receipt_date)-v_paid THEN';
  v_count:=(length(v_definition)-length(replace(v_definition,v_old,'')))/length(v_old);
  IF v_count<>1 THEN RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Backoffice Receipt save anchor drift'; END IF;
  EXECUTE replace(v_definition,v_old,v_new);
END
$patch_save$;

DO $patch_post$
DECLARE v_definition text;v_old text;v_new text;v_count integer;
BEGIN
  SELECT pg_get_functiondef(to_regprocedure(
    'public.post_customer_receipt_allocated(uuid,bigint,uuid)')) INTO STRICT v_definition;
  v_old:='IF v_total<=0 OR v_total<>round(v_document.total_amount,4) THEN
    RAISE EXCEPTION ''CUSTOMER_RECEIPT_ALLOCATION_TOTAL_INVALID'';
  END IF;
  FOR v_allocation IN
    SELECT allocation.invoice_id,allocation.allocated_amount';
  v_new:='IF v_total<=0 OR v_total<>round(v_document.total_amount,4) THEN
    RAISE EXCEPTION ''CUSTOMER_RECEIPT_ALLOCATION_TOTAL_INVALID'';
  END IF;
  FOR v_allocation IN
    SELECT allocation.sales_id,allocation.allocated_amount
    FROM public.customer_receipt_allocations allocation
    WHERE allocation.company_id=v_company AND allocation.document_id=v_document.id
    ORDER BY allocation.sales_id
  LOOP
    PERFORM 1 FROM public.sales_headers sale
    WHERE sale.company_id=v_company AND sale.id=v_allocation.sales_id
      AND sale.is_tempo AND sale.customer_id=v_document.customer_id
      AND (sale.document_status=''POSTED'' OR EXISTS(SELECT 1
        FROM public.sales_dispatch_financial_effects effect
        WHERE effect.company_id=sale.company_id AND effect.sales_id=sale.id
          AND effect.effective_date<=v_document.receipt_date)) FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION ''CUSTOMER_RECEIPT_ALLOCATION_INVALID''; END IF;
    SELECT COALESCE(sum(allocation.allocated_amount),0) INTO v_paid
    FROM public.customer_receipt_allocations allocation
    JOIN public.customer_receipt_documents receipt
      ON receipt.company_id=allocation.company_id AND receipt.id=allocation.document_id
     AND receipt.status=''POSTED''
    WHERE allocation.company_id=v_company AND allocation.sales_id=v_allocation.sales_id;
    IF v_allocation.allocated_amount>
      private.customer_receipt_retail_receivable_before_receipts(
        v_company,v_allocation.sales_id,v_document.receipt_date)-v_paid THEN
      RAISE EXCEPTION ''CUSTOMER_RECEIPT_OUTSTANDING_CHANGED'';
    END IF;
  END LOOP;
  FOR v_allocation IN
    SELECT allocation.invoice_id,allocation.allocated_amount';
  v_count:=(length(v_definition)-length(replace(v_definition,v_old,'')))/length(v_old);
  IF v_count<>1 THEN RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Receipt post recheck anchor drift'; END IF;
  EXECUTE replace(v_definition,v_old,v_new);
END
$patch_post$;

REVOKE ALL ON FUNCTION
  private.customer_receipt_retail_receivable_before_receipts(uuid,uuid,date)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.customer_receipt_retail_receivable_before_receipts(uuid,uuid,date)
  TO service_role;

REVOKE ALL ON FUNCTION
  public.get_finance_customer_receipts(),
  public.save_customer_receipt_allocated_draft(uuid,bigint,uuid,date,uuid,text,text,text,numeric,jsonb),
  public.post_customer_receipt_allocated(uuid,bigint,uuid)
  FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION
  public.get_finance_customer_receipts(),
  public.save_customer_receipt_allocated_draft(uuid,bigint,uuid,date,uuid,text,text,text,numeric,jsonb),
  public.post_customer_receipt_allocated(uuid,bigint,uuid)
  TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260919110000','customer_receipt_credit_note_outstanding_alignment',
  'Align Finance Customer Receipt candidates plus Save/Post allocation guards with posted Backoffice and retained Retail Credit Note AR reductions');

NOTIFY pgrst,'reload schema';
COMMIT;
