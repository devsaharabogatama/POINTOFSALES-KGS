-- Complete the retained Retail -> Backoffice Return compatibility path.
-- Original Retail Sale/Invoice/Payment rows remain immutable. This migration
-- adds truthful source lineage to the existing Backoffice Credit Note/Refund
-- documents and dispatches native Backoffice documents to the unchanged core.
BEGIN;

DO $guard$
BEGIN
  IF EXISTS(
    SELECT required.version
    FROM (VALUES('20260917131000'),('20260917150000'),('20260917151000'),
      ('20260918120000'),('20260918130000')) required(version)
    WHERE NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations migration
      WHERE migration.version=required.version)
  ) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: retained Retail financial dependencies required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260918150000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260918150000';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
    WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
  IF EXISTS(SELECT 1 FROM information_schema.columns
    WHERE table_schema='public'
      AND ((table_name='backoffice_sales_credit_notes' AND column_name='source_kind')
        OR (table_name='backoffice_sales_credit_note_lines' AND column_name='source_kind')
        OR (table_name='backoffice_sales_return_invoice_allocations' AND column_name='source_kind')
        OR (table_name='backoffice_sales_customer_refunds' AND column_name='source_kind')))
    OR to_regprocedure('private.allocate_retained_retail_return_credit_core(uuid,bigint,uuid,jsonb)') IS NOT NULL
    OR to_regprocedure('private.post_retained_retail_credit_note_core(uuid,bigint,uuid)') IS NOT NULL
    OR to_regprocedure('private.trg_assign_backoffice_customer_refund_source()') IS NOT NULL
    OR to_regprocedure('public.get_retained_retail_return_invoice_workspace(uuid)') IS NOT NULL
    OR to_regprocedure('public.get_backoffice_sales_credit_note_payment_context(uuid)') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: retained Retail Credit Note bridge collision';
  END IF;
END
$guard$;

ALTER TABLE public.backoffice_sales_credit_notes
  ADD COLUMN source_kind text NOT NULL DEFAULT 'BACKOFFICE',
  ADD COLUMN source_retail_sales_id uuid,
  ADD COLUMN source_retail_invoice_snapshot_id uuid;
ALTER TABLE public.backoffice_sales_credit_notes
  ALTER COLUMN source_invoice_id DROP NOT NULL;
ALTER TABLE public.backoffice_sales_credit_notes
  DROP CONSTRAINT backoffice_sales_credit_notes_invoice_fk;
ALTER TABLE public.backoffice_sales_credit_notes
  ADD CONSTRAINT backoffice_sales_credit_notes_invoice_fk
    FOREIGN KEY(company_id,source_invoice_id)
    REFERENCES public.backoffice_sales_invoices(company_id,id) ON DELETE RESTRICT,
  ADD CONSTRAINT backoffice_sales_credit_notes_retail_sale_fk
    FOREIGN KEY(company_id,source_retail_sales_id)
    REFERENCES public.sales_headers(company_id,id) ON DELETE RESTRICT,
  ADD CONSTRAINT backoffice_sales_credit_notes_retail_invoice_fk
    FOREIGN KEY(company_id,source_retail_invoice_snapshot_id)
    REFERENCES public.sales_invoice_snapshots(company_id,id) ON DELETE RESTRICT,
  ADD CONSTRAINT backoffice_sales_credit_notes_source_shape_check CHECK(
    (source_kind='BACKOFFICE' AND source_invoice_id IS NOT NULL
      AND source_retail_sales_id IS NULL AND source_retail_invoice_snapshot_id IS NULL)
    OR
    (source_kind='RETAINED_RETAIL' AND source_invoice_id IS NULL
      AND source_retail_sales_id IS NOT NULL
      AND source_retail_invoice_snapshot_id IS NOT NULL));
CREATE UNIQUE INDEX backoffice_sales_credit_note_active_retail_source
  ON public.backoffice_sales_credit_notes(company_id,return_id,source_retail_sales_id)
  WHERE source_kind='RETAINED_RETAIL' AND status='DRAFT';
CREATE INDEX backoffice_sales_credit_notes_retail_status
  ON public.backoffice_sales_credit_notes(
    company_id,source_retail_sales_id,status,created_at,id)
  WHERE source_retail_sales_id IS NOT NULL;

ALTER TABLE public.backoffice_sales_credit_note_lines
  ADD COLUMN source_kind text NOT NULL DEFAULT 'BACKOFFICE',
  ADD COLUMN source_retail_sales_detail_id uuid;
ALTER TABLE public.backoffice_sales_credit_note_lines
  ALTER COLUMN sales_order_line_id DROP NOT NULL,
  ALTER COLUMN source_invoice_line_id DROP NOT NULL;
ALTER TABLE public.backoffice_sales_credit_note_lines
  DROP CONSTRAINT backoffice_sales_credit_note_lines_order_line_fk,
  DROP CONSTRAINT backoffice_sales_credit_note_lines_invoice_line_fk;
ALTER TABLE public.backoffice_sales_credit_note_lines
  ADD CONSTRAINT backoffice_sales_credit_note_lines_order_line_fk
    FOREIGN KEY(company_id,sales_order_line_id)
    REFERENCES public.backoffice_sales_order_lines(company_id,id) ON DELETE RESTRICT,
  ADD CONSTRAINT backoffice_sales_credit_note_lines_invoice_line_fk
    FOREIGN KEY(company_id,source_invoice_line_id)
    REFERENCES public.backoffice_sales_invoice_lines(company_id,id) ON DELETE RESTRICT,
  ADD CONSTRAINT backoffice_sales_credit_note_lines_retail_detail_fk
    FOREIGN KEY(company_id,source_retail_sales_detail_id)
    REFERENCES public.sales_details(company_id,id) ON DELETE RESTRICT,
  ADD CONSTRAINT backoffice_sales_credit_note_lines_source_shape_check CHECK(
    (source_kind='BACKOFFICE' AND sales_order_line_id IS NOT NULL
      AND source_invoice_line_id IS NOT NULL
      AND source_retail_sales_detail_id IS NULL)
    OR
    (source_kind='RETAINED_RETAIL' AND sales_order_line_id IS NULL
      AND source_invoice_line_id IS NULL
      AND source_retail_sales_detail_id IS NOT NULL));
CREATE INDEX backoffice_sales_credit_note_lines_retail_source
  ON public.backoffice_sales_credit_note_lines(
    company_id,source_retail_sales_detail_id,credit_note_id)
  WHERE source_retail_sales_detail_id IS NOT NULL;

ALTER TABLE public.backoffice_sales_return_invoice_allocations
  ADD COLUMN source_kind text NOT NULL DEFAULT 'BACKOFFICE',
  ADD COLUMN source_retail_sales_id uuid,
  ADD COLUMN source_retail_sales_detail_id uuid;
ALTER TABLE public.backoffice_sales_return_invoice_allocations
  ALTER COLUMN sales_order_line_id DROP NOT NULL;
ALTER TABLE public.backoffice_sales_return_invoice_allocations
  DROP CONSTRAINT backoffice_sales_return_invoice_alloc_order_line_fk,
  DROP CONSTRAINT backoffice_sales_return_invoice_alloc_shape_check;
ALTER TABLE public.backoffice_sales_return_invoice_allocations
  ADD CONSTRAINT backoffice_sales_return_invoice_alloc_order_line_fk
    FOREIGN KEY(company_id,sales_order_line_id)
    REFERENCES public.backoffice_sales_order_lines(company_id,id) ON DELETE RESTRICT,
  ADD CONSTRAINT backoffice_sales_return_invoice_alloc_retail_sale_fk
    FOREIGN KEY(company_id,source_retail_sales_id)
    REFERENCES public.sales_headers(company_id,id) ON DELETE RESTRICT,
  ADD CONSTRAINT backoffice_sales_return_invoice_alloc_retail_detail_fk
    FOREIGN KEY(company_id,source_retail_sales_detail_id)
    REFERENCES public.sales_details(company_id,id) ON DELETE RESTRICT,
  ADD CONSTRAINT backoffice_sales_return_invoice_alloc_shape_check CHECK(
    (source_kind='BACKOFFICE' AND sales_order_line_id IS NOT NULL
      AND source_retail_sales_id IS NULL AND source_retail_sales_detail_id IS NULL
      AND allocation_type IN('UNINVOICED','DRAFT_INVOICE','POSTED_INVOICE')
      AND ((allocation_type='UNINVOICED' AND invoice_id IS NULL
            AND invoice_line_id IS NULL AND credit_note_id IS NULL
            AND invoice_line_snapshot IS NULL)
        OR (allocation_type='DRAFT_INVOICE' AND invoice_id IS NOT NULL
            AND invoice_line_id IS NOT NULL AND credit_note_id IS NULL
            AND jsonb_typeof(invoice_line_snapshot)='object')
        OR (allocation_type='POSTED_INVOICE' AND invoice_id IS NOT NULL
            AND invoice_line_id IS NOT NULL AND credit_note_id IS NOT NULL
            AND jsonb_typeof(invoice_line_snapshot)='object')))
    OR
    (source_kind='RETAINED_RETAIL' AND sales_order_line_id IS NULL
      AND source_retail_sales_id IS NOT NULL
      AND source_retail_sales_detail_id IS NOT NULL
      AND allocation_type='RETAIL_POSTED_INVOICE'
      AND invoice_id IS NULL AND invoice_line_id IS NULL
      AND credit_note_id IS NOT NULL
      AND jsonb_typeof(invoice_line_snapshot)='object'));
CREATE INDEX backoffice_sales_return_invoice_alloc_retail_source
  ON public.backoffice_sales_return_invoice_allocations(
    company_id,source_retail_sales_detail_id,created_at,id)
  WHERE source_retail_sales_detail_id IS NOT NULL;

ALTER TABLE public.backoffice_sales_customer_refunds
  ADD COLUMN source_kind text NOT NULL DEFAULT 'BACKOFFICE',
  ADD COLUMN source_retail_sales_id uuid;
ALTER TABLE public.backoffice_sales_customer_refunds
  ALTER COLUMN source_invoice_id DROP NOT NULL;
ALTER TABLE public.backoffice_sales_customer_refunds
  DROP CONSTRAINT backoffice_sales_customer_refunds_invoice_fk;
ALTER TABLE public.backoffice_sales_customer_refunds
  ADD CONSTRAINT backoffice_sales_customer_refunds_invoice_fk
    FOREIGN KEY(company_id,source_invoice_id)
    REFERENCES public.backoffice_sales_invoices(company_id,id) ON DELETE RESTRICT,
  ADD CONSTRAINT backoffice_sales_customer_refunds_retail_sale_fk
    FOREIGN KEY(company_id,source_retail_sales_id)
    REFERENCES public.sales_headers(company_id,id) ON DELETE RESTRICT,
  ADD CONSTRAINT backoffice_sales_customer_refunds_source_shape_check CHECK(
    (source_kind='BACKOFFICE' AND source_invoice_id IS NOT NULL
      AND source_retail_sales_id IS NULL)
    OR
    (source_kind='RETAINED_RETAIL' AND source_invoice_id IS NULL
      AND source_retail_sales_id IS NOT NULL));

CREATE OR REPLACE FUNCTION private.backoffice_sales_credit_note_snapshot(
  p_company_id uuid,p_credit_note_id uuid
) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
  SELECT jsonb_build_object(
    'id',note.id,'returnId',note.return_id,'sourceKind',note.source_kind,
    'sourceInvoiceId',note.source_invoice_id,
    'sourceRetailSalesId',note.source_retail_sales_id,
    'sourceRetailInvoiceSnapshotId',note.source_retail_invoice_snapshot_id,
    'creditNoteNo',note.credit_note_no,'status',note.status,
    'creditNoteDate',note.credit_note_date,'currencyCode',note.currency_code,
    'reason',note.reason,'chargeTotal',note.charge_total,
    'discountTotal',note.discount_total,'taxTotal',note.tax_total,
    'deliveryFeeAmount',note.delivery_fee_amount,'grandTotal',note.grand_total,
    'arReductionAmount',note.ar_reduction_amount,
    'refundLiabilityAmount',note.refund_liability_amount,
    'sourceInvoiceSnapshot',note.source_invoice_snapshot,
    'masterVersion',note.master_version,'createdAt',note.created_at,
    'updatedAt',note.updated_at,'postedAt',note.posted_at,
    'lines',COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'id',line.id,'lineNo',line.line_no,'sourceKind',line.source_kind,
      'returnReceiptLineId',line.return_receipt_line_id,
      'salesOrderLineId',line.sales_order_line_id,
      'sourceInvoiceLineId',line.source_invoice_line_id,
      'sourceRetailSalesDetailId',line.source_retail_sales_detail_id,
      'productId',line.product_id,'uomId',line.uom_id,
      'quantityUom',line.quantity_uom,'quantityBase',line.quantity_base,
      'unitPrice',line.unit_price,'discountAmount',line.discount_amount,
      'taxAmount',line.tax_amount,'lineAmount',line.line_amount,
      'sourceSnapshot',line.source_snapshot
    ) ORDER BY line.line_no)
    FROM public.backoffice_sales_credit_note_lines line
    WHERE line.company_id=note.company_id AND line.credit_note_id=note.id),'[]'::jsonb)
  ) FROM public.backoffice_sales_credit_notes note
  WHERE note.company_id=p_company_id AND note.id=p_credit_note_id
$$;

CREATE OR REPLACE FUNCTION private.backoffice_sales_customer_refund_snapshot(
  p_company_id uuid,p_refund_id uuid
) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
  SELECT jsonb_build_object('id',refund.id,'creditNoteId',refund.credit_note_id,
    'returnId',refund.return_id,'sourceKind',refund.source_kind,
    'sourceInvoiceId',refund.source_invoice_id,
    'sourceRetailSalesId',refund.source_retail_sales_id,
    'refundNo',refund.refund_no,'documentKind',refund.document_kind,
    'status',refund.status,'refundDate',refund.refund_date,'amount',refund.amount,
    'paymentMethodId',refund.payment_method_id,
    'paymentMethodName',refund.payment_method_name_snapshot,
    'paymentMethodType',refund.payment_method_type_snapshot,
    'settlementRoute',refund.settlement_route_snapshot,
    'settlementAccountFunction',refund.settlement_account_function_snapshot,
    'referenceNo',refund.reference_no,'evidenceUrl',refund.evidence_url,
    'notes',refund.notes,'reversalOfRefundId',refund.reversal_of_refund_id,
    'financialEventId',refund.financial_event_id,'masterVersion',refund.master_version,
    'postedAt',refund.posted_at)
  FROM public.backoffice_sales_customer_refunds refund
  WHERE refund.company_id=p_company_id AND refund.id=p_refund_id
$$;

CREATE FUNCTION private.trg_guard_retained_retail_credit_note_fee()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_other numeric(24,4);v_limit numeric(24,4);
BEGIN
  IF NEW.source_kind<>'RETAINED_RETAIL' OR NEW.status<>'DRAFT' THEN RETURN NEW; END IF;
  v_limit:=COALESCE((NEW.source_invoice_snapshot->>'deliveryFeeAmount')::numeric,0);
  SELECT round(COALESCE(sum(note.delivery_fee_amount),0),4) INTO v_other
  FROM public.backoffice_sales_credit_notes note
  WHERE note.company_id=NEW.company_id
    AND note.source_kind='RETAINED_RETAIL'
    AND note.source_retail_sales_id=NEW.source_retail_sales_id
    AND note.id<>NEW.id AND note.status IN('DRAFT','POSTED');
  IF v_other+NEW.delivery_fee_amount>v_limit THEN
    RAISE EXCEPTION 'CREDIT_NOTE_DELIVERY_FEE_EXCEEDS_SOURCE: ongkir Credit Note kumulatif melebihi ongkir Invoice sumber';
  END IF;
  RETURN NEW;
END
$$;
CREATE TRIGGER retained_retail_credit_note_fee_guard
BEFORE INSERT OR UPDATE OF delivery_fee_amount ON public.backoffice_sales_credit_notes
FOR EACH ROW EXECUTE FUNCTION private.trg_guard_retained_retail_credit_note_fee();

CREATE FUNCTION public.get_retained_retail_return_invoice_workspace(p_return_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='8s' AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_document public.backoffice_sales_returns%rowtype;
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'finance.customer_credit_notes','VIEW');
  SELECT * INTO v_document FROM public.backoffice_sales_returns document
  WHERE document.company_id=v_company AND document.id=p_return_id
    AND document.source_kind='RETAINED_RETAIL';
  IF NOT FOUND THEN RAISE EXCEPTION 'RETAINED_RETAIL_RETURN_NOT_FOUND'; END IF;
  RETURN jsonb_build_object('companyId',v_company,'invoices',jsonb_build_array(
    (SELECT jsonb_build_object('id',sale.id,'invoiceNo',invoice.invoice_no,
      'draftNo',COALESCE(sale.draft_no,''),'status','POSTED','sourceKind','RETAINED_RETAIL',
      'lines',COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'id',detail.id,'salesOrderLineId',NULL,
        'retailSalesDetailId',detail.id,'sourceKind','RETAINED_RETAIL') ORDER BY detail.id)
        FROM public.sales_details detail
        WHERE detail.company_id=sale.company_id AND detail.sales_id=sale.id),'[]'::jsonb))
     FROM public.sales_headers sale
     JOIN public.sales_invoice_snapshots invoice
       ON invoice.company_id=sale.company_id AND invoice.sales_id=sale.id
     WHERE sale.company_id=v_company AND sale.id=v_document.retail_sales_id)));
END
$$;

CREATE FUNCTION private.allocate_retained_retail_return_credit_core(
  p_return_id uuid,p_expected_version bigint,p_operation_id uuid,p_allocations jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='15s' AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
  v_return public.backoffice_sales_returns%rowtype;v_sale public.sales_headers%rowtype;
  v_invoice public.sales_invoice_snapshots%rowtype;v_item jsonb;
  v_receipt_line public.backoffice_sales_return_receipt_lines%rowtype;
  v_return_line public.backoffice_sales_return_lines%rowtype;
  v_detail public.sales_details%rowtype;v_note public.backoffice_sales_credit_notes%rowtype;
  v_note_id uuid;v_line_no integer;v_qty_uom numeric(24,6);v_qty_base numeric(24,6);
  v_used numeric(24,6);v_prior_qty numeric(24,6);v_native_qty numeric(24,6);
  v_ratio numeric;v_refund numeric(24,4);v_tax numeric(24,4);v_net numeric(24,4);
  v_prior_refund numeric(24,4);v_prior_tax numeric(24,4);v_native_refund numeric(24,4);
  v_native_tax numeric(24,4);v_hash text;v_retry jsonb;v_response jsonb;
  v_all_received boolean;v_snapshot jsonb;v_created_note boolean:=false;
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'finance.customer_credit_notes','CREATE_DRAFT');
  IF p_return_id IS NULL OR p_expected_version IS NULL OR p_operation_id IS NULL
    OR jsonb_typeof(p_allocations)<>'array' OR jsonb_array_length(p_allocations)=0 THEN
    RAISE EXCEPTION 'RETURN_INVOICE_ALLOCATION_REQUIRED: pilih Invoice Retail sumber untuk setiap qty Retur yang sudah diterima';
  END IF;
  v_hash:=encode(extensions.digest(convert_to(jsonb_build_object(
    'returnId',p_return_id,'expectedVersion',p_expected_version,
    'allocations',p_allocations)::text,'UTF8'),'sha256'),'hex');
  PERFORM pg_advisory_xact_lock(hashtextextended(
    v_company::text||':RETURN_CREDIT:'||p_operation_id::text,0));
  v_retry:=private.backoffice_sales_credit_note_operation_retry(
    v_company,p_operation_id,'ALLOCATE_RETURN',v_hash);
  IF v_retry IS NOT NULL THEN RETURN v_retry; END IF;
  SELECT * INTO v_return FROM public.backoffice_sales_returns document
  WHERE document.company_id=v_company AND document.id=p_return_id FOR UPDATE;
  IF NOT FOUND OR v_return.source_kind<>'RETAINED_RETAIL' THEN
    RAISE EXCEPTION 'RETAINED_RETAIL_RETURN_NOT_FOUND';
  END IF;
  IF v_return.master_version<>p_expected_version THEN
    RAISE EXCEPTION 'MASTER_VERSION_CONFLICT: dokumen Retur sudah berubah, muat ulang sebelum melanjutkan';
  END IF;
  IF v_return.status NOT IN('APPROVED','PARTIALLY_RECEIVED','RECEIVED','CREDIT_PENDING')
    OR v_return.total_received_base_qty<=0 THEN
    RAISE EXCEPTION 'RETURN_NOT_READY_FOR_INVOICE_RECONCILIATION: Gudang harus mem-posting penerimaan Retur terlebih dahulu';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(
    v_company::text||':RETAINED_RETAIL_CREDIT:'||v_return.retail_sales_id::text,0));
  SELECT * INTO v_sale FROM public.sales_headers sale
  WHERE sale.company_id=v_company AND sale.id=v_return.retail_sales_id
    AND sale.document_status<>'CANCELED' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'RETAINED_RETAIL_RETURN_SOURCE_NOT_FOUND'; END IF;
  SELECT * INTO v_invoice FROM public.sales_invoice_snapshots invoice
  WHERE invoice.company_id=v_company AND invoice.sales_id=v_sale.id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'RETAINED_RETAIL_SOURCE_INVOICE_REQUIRED: Invoice Retail sumber tidak ditemukan';
  END IF;

  FOR v_item IN SELECT value FROM jsonb_array_elements(p_allocations) LOOP
    BEGIN
      IF upper(btrim(v_item->>'allocationType'))<>'RETAIL_POSTED_INVOICE'
        OR (v_item->>'retailSalesId')::uuid<>v_sale.id THEN
        RAISE EXCEPTION 'invalid retained target';
      END IF;
      v_qty_uom:=round((v_item->>'quantityUom')::numeric,6);
      SELECT * INTO STRICT v_receipt_line
      FROM public.backoffice_sales_return_receipt_lines line
      WHERE line.company_id=v_company
        AND line.id=(v_item->>'returnReceiptLineId')::uuid
        AND line.return_id=p_return_id;
      SELECT * INTO STRICT v_return_line
      FROM public.backoffice_sales_return_lines line
      WHERE line.company_id=v_company AND line.id=v_receipt_line.return_line_id
        AND line.return_id=p_return_id AND line.source_kind='RETAINED_RETAIL';
      IF (v_item->>'retailSalesDetailId')::uuid<>v_return_line.retail_sales_detail_id THEN
        RAISE EXCEPTION 'invalid retained line';
      END IF;
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'RETURN_SOURCE_RETAIL_INVOICE_LINE_INVALID: pilih Invoice dan baris Retail asli dari Retur ini';
    END;
    IF v_qty_uom<=0 THEN
      RAISE EXCEPTION 'RETURN_INVOICE_ALLOCATION_TYPE_INVALID: qty koreksi harus lebih dari nol';
    END IF;
    v_qty_base:=round(v_qty_uom*v_receipt_line.base_qty_per_uom,6);
    SELECT COALESCE(sum(allocation.allocated_base_qty),0) INTO v_used
    FROM public.backoffice_sales_return_invoice_allocations allocation
    WHERE allocation.company_id=v_company
      AND allocation.return_receipt_line_id=v_receipt_line.id;
    IF v_used+v_qty_base>v_receipt_line.received_base_qty THEN
      RAISE EXCEPTION 'RETURN_RECEIPT_QUANTITY_ALREADY_ALLOCATED: jumlah pembagian melebihi qty yang diterima Gudang';
    END IF;
    SELECT * INTO STRICT v_detail FROM public.sales_details detail
    WHERE detail.company_id=v_company AND detail.id=v_return_line.retail_sales_detail_id
      AND detail.sales_id=v_sale.id FOR SHARE;
    IF v_detail.quantity_base<=0 OR v_detail.qty<=0 THEN
      RAISE EXCEPTION 'RETAINED_RETAIL_SOURCE_QUANTITY_INVALID';
    END IF;
    SELECT COALESCE(sum(line.quantity_base),0),COALESCE(sum(line.refund_before_rounding),0),
      COALESCE(sum(line.tax_refund_amount),0)
    INTO v_native_qty,v_native_refund,v_native_tax
    FROM public.sales_return_lines line
    JOIN public.sales_return_documents document
      ON document.company_id=line.company_id AND document.id=line.document_id
      AND document.status='POSTED'
    WHERE line.company_id=v_company AND line.source_sales_detail_id=v_detail.id;
    SELECT COALESCE(sum(allocation.allocated_base_qty),0) INTO v_prior_qty
    FROM public.backoffice_sales_return_invoice_allocations allocation
    WHERE allocation.company_id=v_company
      AND allocation.source_kind='RETAINED_RETAIL'
      AND allocation.source_retail_sales_detail_id=v_detail.id;
    IF v_native_qty+v_prior_qty+v_qty_base>v_detail.quantity_base THEN
      RAISE EXCEPTION 'POSTED_INVOICE_RETURN_QUANTITY_EXCEEDS_LINE: koreksi kumulatif melebihi qty Invoice Retail';
    END IF;

    SELECT * INTO v_note FROM public.backoffice_sales_credit_notes note
    WHERE note.company_id=v_company AND note.return_id=p_return_id
      AND note.source_kind='RETAINED_RETAIL'
      AND note.source_retail_sales_id=v_sale.id AND note.status='DRAFT' FOR UPDATE;
    IF NOT FOUND THEN
      v_note_id:=gen_random_uuid();v_created_note:=true;
      v_snapshot:=v_invoice.snapshot_payload||jsonb_build_object(
        'sourceKind','RETAINED_RETAIL','retailSalesId',v_sale.id,
        'retailInvoiceSnapshotId',v_invoice.id,'invoiceNo',v_invoice.invoice_no,
        'deliveryFeeAmount',COALESCE(v_sale.delivery_fee_amount,0));
      INSERT INTO public.backoffice_sales_credit_notes(id,company_id,return_id,
        source_kind,source_retail_sales_id,source_retail_invoice_snapshot_id,
        customer_id,store_id,warehouse_id,credit_note_no,credit_note_date,
        currency_code,reason,source_invoice_snapshot,created_by,updated_by)
      SELECT v_note_id,v_company,p_return_id,'RETAINED_RETAIL',v_sale.id,v_invoice.id,
        v_sale.customer_id,v_sale.store_id,v_sale.sales_warehouse_id,
        'CN-'||to_char((clock_timestamp() AT TIME ZONE company.timezone)::date,'YYYYMMDD')||'-'||
          lpad(nextval('private.backoffice_sales_credit_note_no_seq')::text,10,'0'),
        (clock_timestamp() AT TIME ZONE company.timezone)::date,
        company.currency_code,'Retur Customer '||v_return.return_no,
        v_snapshot,v_actor,v_actor
      FROM public.companies company WHERE company.id=v_company;
      SELECT * INTO STRICT v_note FROM public.backoffice_sales_credit_notes note
      WHERE note.company_id=v_company AND note.id=v_note_id FOR UPDATE;
    ELSE
      v_note_id:=v_note.id;
      UPDATE public.backoffice_sales_credit_notes SET
        master_version=master_version+1,updated_by=v_actor,updated_at=clock_timestamp()
      WHERE company_id=v_company AND id=v_note_id RETURNING * INTO v_note;
    END IF;
    SELECT COALESCE(max(line_no),0)+1 INTO v_line_no
    FROM public.backoffice_sales_credit_note_lines
    WHERE company_id=v_company AND credit_note_id=v_note_id;
    SELECT COALESCE(sum(line.line_amount+line.tax_amount),0),COALESCE(sum(line.tax_amount),0)
    INTO v_prior_refund,v_prior_tax
    FROM public.backoffice_sales_credit_note_lines line
    WHERE line.company_id=v_company AND line.source_kind='RETAINED_RETAIL'
      AND line.source_retail_sales_detail_id=v_detail.id;
    v_ratio:=v_qty_base/v_detail.quantity_base;
    IF v_native_qty+v_prior_qty+v_qty_base=v_detail.quantity_base THEN
      v_refund:=round(v_detail.line_total+v_detail.allocated_document_rounding
        -v_native_refund-v_prior_refund,4);
      v_tax:=round(COALESCE(v_detail.tax_amount,0)-v_native_tax-v_prior_tax,4);
    ELSE
      v_refund:=round((v_detail.line_total+v_detail.allocated_document_rounding)*v_ratio,4);
      v_tax:=round(COALESCE(v_detail.tax_amount,0)*v_ratio,4);
    END IF;
    v_net:=round(v_refund-v_tax,4);
    IF v_refund<=0 OR v_tax<0 OR v_net<0 THEN
      RAISE EXCEPTION 'RETAINED_RETAIL_CREDIT_VALUE_INVALID: nilai koreksi Invoice Retail tidak valid';
    END IF;
    INSERT INTO public.backoffice_sales_credit_note_lines(company_id,credit_note_id,
      return_id,return_receipt_line_id,source_kind,source_retail_sales_detail_id,
      line_no,product_id,uom_id,quantity_uom,base_qty_per_uom,quantity_base,
      unit_price,discount_amount,tax_amount,line_amount,source_snapshot)
    VALUES(v_company,v_note_id,p_return_id,v_receipt_line.id,'RETAINED_RETAIL',
      v_detail.id,v_line_no,v_detail.product_id,v_detail.sale_uom_id,v_qty_uom,
      v_detail.uom_factor_to_base_snapshot,v_qty_base,
      round(v_net/v_qty_uom,4),0,v_tax,v_net,
      to_jsonb(v_detail)||jsonb_build_object('sourceKind','RETAINED_RETAIL',
        'sourceInvoiceNo',v_invoice.invoice_no,'sourceRetailSalesId',v_sale.id,
        'sourceRetailSalesDetailId',v_detail.id,'taxAccountId',v_detail.tax_account_id,
        'refundAmount',v_refund));
    PERFORM private.recalculate_backoffice_sales_credit_note(v_company,v_note_id,v_actor);
    INSERT INTO public.backoffice_sales_return_invoice_allocations(company_id,return_id,
      return_receipt_line_id,source_kind,source_retail_sales_id,
      source_retail_sales_detail_id,allocation_type,credit_note_id,
      allocated_base_qty,invoice_line_snapshot,operation_id,actor_id)
    VALUES(v_company,p_return_id,v_receipt_line.id,'RETAINED_RETAIL',v_sale.id,
      v_detail.id,'RETAIL_POSTED_INVOICE',v_note_id,v_qty_base,to_jsonb(v_detail),
      p_operation_id,v_actor);
  END LOOP;

  SELECT NOT EXISTS(SELECT 1 FROM public.backoffice_sales_return_receipt_lines line
    WHERE line.company_id=v_company AND line.return_id=p_return_id
      AND line.received_base_qty>COALESCE((SELECT sum(allocation.allocated_base_qty)
        FROM public.backoffice_sales_return_invoice_allocations allocation
        WHERE allocation.company_id=line.company_id
          AND allocation.return_receipt_line_id=line.id),0)) INTO v_all_received;
  UPDATE public.backoffice_sales_returns SET
    status=CASE WHEN v_all_received THEN 'CREDIT_PENDING' ELSE status END,
    master_version=master_version+1,updated_at=clock_timestamp()
  WHERE company_id=v_company AND id=p_return_id RETURNING * INTO v_return;
  v_response:=jsonb_build_object('companyId',v_company,'returnId',p_return_id,
    'returnStatus',v_return.status,'masterVersion',v_return.master_version,
    'allReceivedQuantityAllocated',v_all_received,
    'creditNotes',COALESCE((SELECT jsonb_agg(
      private.backoffice_sales_credit_note_snapshot(v_company,note.id)
      ORDER BY note.created_at,note.id) FROM public.backoffice_sales_credit_notes note
      WHERE note.company_id=v_company AND note.return_id=p_return_id),'[]'::jsonb),
    'exactRetry',false);
  INSERT INTO public.backoffice_sales_credit_note_operations(company_id,operation_id,
    operation_type,return_id,request_hash,response_snapshot,actor_id)
  VALUES(v_company,p_operation_id,'ALLOCATE_RETURN',p_return_id,v_hash,v_response,v_actor);
  INSERT INTO public.backoffice_sales_credit_note_audit(company_id,return_id,
    credit_note_id,operation_id,action,actor_id,after_state)
  VALUES(v_company,p_return_id,NULL,p_operation_id,'ALLOCATE_RETURN',v_actor,
    jsonb_build_object('returnId',p_return_id,'sourceKind','RETAINED_RETAIL',
      'returnStatus',v_return.status,'masterVersion',v_return.master_version,
      'allocationCount',jsonb_array_length(p_allocations),
      'createdCreditNote',v_created_note));
  RETURN v_response;
END
$$;

ALTER FUNCTION public.allocate_backoffice_sales_return_invoices(uuid,bigint,uuid,jsonb)
  RENAME TO allocate_backoffice_sales_return_invoices_before_retained;
ALTER FUNCTION public.allocate_backoffice_sales_return_invoices_before_retained(uuid,bigint,uuid,jsonb)
  SET SCHEMA private;

CREATE FUNCTION public.allocate_backoffice_sales_return_invoices(
  p_return_id uuid,p_expected_version bigint,p_operation_id uuid,p_allocations jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='15s' AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_kind text;
BEGIN
  SELECT source_kind INTO v_kind FROM public.backoffice_sales_returns
  WHERE company_id=v_company AND id=p_return_id;
  IF v_kind IS NULL THEN RAISE EXCEPTION 'RETURN_NOT_FOUND: dokumen Retur tidak ditemukan pada Company aktif'; END IF;
  IF v_kind='RETAINED_RETAIL' THEN
    RETURN private.allocate_retained_retail_return_credit_core(
      p_return_id,p_expected_version,p_operation_id,p_allocations);
  END IF;
  RETURN private.allocate_backoffice_sales_return_invoices_before_retained(
    p_return_id,p_expected_version,p_operation_id,p_allocations);
END
$$;

CREATE FUNCTION private.post_retained_retail_credit_note_core(
  p_credit_note_id uuid,p_expected_version bigint,p_operation_id uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='15s' AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
  v_note public.backoffice_sales_credit_notes%rowtype;v_sale public.sales_headers%rowtype;
  v_event public.financial_events%rowtype;v_period public.accounting_periods%rowtype;
  v_journal public.finance_journals%rowtype;v_category uuid;v_hash text;v_retry jsonb;
  v_before jsonb;v_after jsonb;v_response jsonb;v_receipts numeric(24,4);
  v_prior_credit numeric(24,4);v_prior_ar numeric(24,4);v_native_return numeric(24,4);
  v_outstanding numeric(24,4);v_ar numeric(24,4);v_refund numeric(24,4);
  v_net numeric(24,4);v_account uuid;v_tax record;v_line_no integer:=0;
  v_journal_type text:='AUTOMATIC';v_accounting_date date;v_event_at timestamptz;
  v_timezone text;v_company_today date;v_latest_payment_date date;
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'finance.customer_credit_notes','POST');
  IF p_credit_note_id IS NULL OR p_expected_version IS NULL OR p_operation_id IS NULL THEN
    RAISE EXCEPTION 'CREDIT_NOTE_POST_INPUT_INVALID: pilih Draft Credit Note yang akan diposting';
  END IF;
  v_hash:=encode(extensions.digest(convert_to(jsonb_build_object(
    'creditNoteId',p_credit_note_id,'expectedVersion',p_expected_version)::text,
    'UTF8'),'sha256'),'hex');
  PERFORM pg_advisory_xact_lock(hashtextextended(
    v_company::text||':CREDIT_NOTE:'||p_operation_id::text,0));
  v_retry:=private.backoffice_sales_credit_note_operation_retry(
    v_company,p_operation_id,'POST',v_hash);
  IF v_retry IS NOT NULL THEN RETURN v_retry; END IF;
  SELECT * INTO v_note FROM public.backoffice_sales_credit_notes note
  WHERE note.company_id=v_company AND note.id=p_credit_note_id FOR UPDATE;
  IF NOT FOUND OR v_note.source_kind<>'RETAINED_RETAIL' THEN
    RAISE EXCEPTION 'RETAINED_RETAIL_CREDIT_NOTE_NOT_FOUND';
  END IF;
  IF v_note.status<>'DRAFT' THEN
    RAISE EXCEPTION 'CREDIT_NOTE_NOT_POSTABLE: hanya Draft Credit Note yang dapat diposting';
  END IF;
  IF v_note.master_version<>p_expected_version THEN
    RAISE EXCEPTION 'MASTER_VERSION_CONFLICT: Credit Note sudah berubah, muat ulang sebelum posting';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(
    v_company::text||':RETAINED_RETAIL_CREDIT:'||v_note.source_retail_sales_id::text,0));
  SELECT * INTO v_sale FROM public.sales_headers sale
  WHERE sale.company_id=v_company AND sale.id=v_note.source_retail_sales_id
    AND sale.document_status<>'CANCELED' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'RETAINED_RETAIL_RETURN_SOURCE_NOT_FOUND'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.backoffice_sales_credit_note_lines line
    WHERE line.company_id=v_company AND line.credit_note_id=v_note.id
      AND line.source_kind='RETAINED_RETAIL') THEN
    RAISE EXCEPTION 'CREDIT_NOTE_LINES_REQUIRED: Credit Note belum mempunyai alokasi Product';
  END IF;
  SELECT company.timezone,(clock_timestamp() AT TIME ZONE company.timezone)::date
  INTO v_timezone,v_company_today FROM public.companies company
  WHERE company.id=v_company AND company.status='ACTIVE';
  IF v_timezone IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_NOT_FOUND'; END IF;
  IF v_note.credit_note_date>v_company_today THEN
    RAISE EXCEPTION 'CREDIT_NOTE_DATE_FUTURE: tanggal Credit Note tidak boleh melewati tanggal Company';
  END IF;
  SELECT round(COALESCE(sum(allocation.allocated_amount),0),4),max(receipt.receipt_date)
  INTO v_receipts,v_latest_payment_date
  FROM public.customer_receipt_allocations allocation
  JOIN public.customer_receipt_documents receipt
    ON receipt.company_id=allocation.company_id AND receipt.id=allocation.document_id
   AND receipt.status='POSTED'
  WHERE allocation.company_id=v_company AND allocation.sales_id=v_sale.id;
  IF round(v_sale.grand_total_after_rounding-v_sale.sisa_piutang,4)>0 THEN
    v_latest_payment_date:=greatest(v_latest_payment_date,
      (v_sale.transaction_date AT TIME ZONE v_timezone)::date);
  END IF;
  IF v_latest_payment_date IS NOT NULL AND v_latest_payment_date>v_note.credit_note_date THEN
    RAISE EXCEPTION 'CREDIT_NOTE_DATE_BEFORE_PAYMENT: tanggal Credit Note harus sama atau setelah pembayaran terakhir Invoice';
  END IF;
  SELECT round(COALESCE(sum(other.grand_total),0),4),
    round(COALESCE(sum(other.ar_reduction_amount),0),4)
  INTO v_prior_credit,v_prior_ar
  FROM public.backoffice_sales_credit_notes other
  WHERE other.company_id=v_company AND other.source_kind='RETAINED_RETAIL'
    AND other.source_retail_sales_id=v_sale.id AND other.status='POSTED';
  SELECT round(COALESCE(sum(document.refund_total),0),4) INTO v_native_return
  FROM public.sales_return_documents document
  WHERE document.company_id=v_company AND document.source_sales_id=v_sale.id
    AND document.status='POSTED';
  IF v_native_return+v_prior_credit+v_note.grand_total>v_sale.grand_total_after_rounding THEN
    RAISE EXCEPTION 'CREDIT_NOTE_AMOUNT_EXCEEDS_INVOICE: koreksi kumulatif melebihi nilai Invoice Retail sumber';
  END IF;
  -- sisa_piutang is the source Retail receivable before Finance Customer
  -- Receipts.  Cap it again by the remaining commercial value so a prior
  -- native Retail Return can never be credited a second time.
  v_outstanding:=greatest(0,least(
    round(v_sale.sisa_piutang-v_receipts-v_prior_ar,4),
    round(v_sale.grand_total_after_rounding-v_native_return-v_prior_credit,4)));
  v_ar:=least(v_note.grand_total,v_outstanding);v_refund:=v_note.grand_total-v_ar;
  v_event_at:=(v_note.credit_note_date::text||' 12:00:00')::timestamp AT TIME ZONE v_timezone;
  SELECT * INTO v_period FROM public.accounting_periods period
  WHERE period.company_id=v_company AND v_note.credit_note_date
    BETWEEN period.start_date AND period.end_date
    AND period.status IN('OPEN','REOPENED') ORDER BY period.start_date LIMIT 1 FOR SHARE;
  IF NOT FOUND THEN
    SELECT * INTO v_period FROM public.accounting_periods period
    WHERE period.company_id=v_company AND period.start_date>v_note.credit_note_date
      AND period.status IN('OPEN','REOPENED') ORDER BY period.start_date LIMIT 1 FOR SHARE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'POSTABLE_ACCOUNTING_PERIOD_NOT_FOUND: buka periode Credit Note atau periode penyesuaian berikutnya';
    END IF;
    v_journal_type:='PRIOR_PERIOD_ADJUSTMENT';v_accounting_date:=v_period.start_date;
  ELSE v_accounting_date:=v_note.credit_note_date; END IF;
  SELECT category.id INTO v_category FROM public.transaction_categories category
  WHERE category.company_id=v_company AND category.system_key='CUSTOMER_CREDIT_NOTE'
    AND category.is_active ORDER BY category.is_system_default DESC,category.id LIMIT 1;
  IF v_category IS NULL THEN
    RAISE EXCEPTION 'CUSTOMER_CREDIT_NOTE_CATEGORY_REQUIRED: aktifkan kategori transaksi Credit Note Customer';
  END IF;
  v_before:=private.backoffice_sales_credit_note_snapshot(v_company,v_note.id);
  INSERT INTO public.financial_events(event_code,event_type,source_table,source_id,event_date,
    event_version,idempotency_key,amounts,status,error_message,created_by,company_id,
    store_id,system_event_key,transaction_category_id,transaction_rule_version)
  VALUES('BO-CN-'||replace(v_note.id::text,'-',''),'SALE_REVISED'::public.event_type,
    'backoffice_sales_credit_notes',v_note.id,v_event_at,1,
    'BACKOFFICE_CREDIT_NOTE|'||v_company||'|'||v_note.id||'|'||p_operation_id,
    jsonb_build_object('creditNoteId',v_note.id,'returnId',v_note.return_id,
      'sourceKind','RETAINED_RETAIL','sourceRetailSalesId',v_sale.id,
      'grandTotal',v_note.grand_total,'arReductionAmount',v_ar,
      'refundLiabilityAmount',v_refund,'financePostingState','HOLD'),
    'HOLD'::public.event_status,'CANONICAL_FINANCE_POSTING_PENDING',v_actor,
    v_company,v_note.store_id,'CUSTOMER_CREDIT_NOTE',v_category,20260918150000)
  RETURNING * INTO v_event;
  INSERT INTO public.finance_journals(company_id,journal_no,journal_type,
    accounting_period_id,accounting_date,original_event_date,source_type,source_id,
    source_version,financial_event_id,idempotency_key,system_event_key,
    transaction_category_id,transaction_rule_version,store_id,warehouse_id,
    description,status,created_by)
  VALUES(v_company,'CNJ-'||replace(v_note.id::text,'-',''),v_journal_type,
    v_period.id,v_accounting_date,v_note.credit_note_date,
    'backoffice_sales_credit_notes',v_note.id,v_note.master_version,v_event.id,
    'BACKOFFICE_CREDIT_NOTE_JOURNAL|'||v_company||'|'||v_note.id,
    'CUSTOMER_CREDIT_NOTE',v_category,20260918150000,v_note.store_id,
    v_note.warehouse_id,'Credit Note Customer '||v_note.credit_note_no,'DRAFT',v_actor)
  RETURNING * INTO v_journal;
  v_net:=round(v_note.charge_total-v_note.discount_total,4);
  IF v_net>0 THEN
    v_account:=private.resolve_financial_event_account(v_event,'SALES_RETURN_DISCOUNT');
    v_line_no:=v_line_no+10;
    INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,account_id,
      debit,credit,store_id,warehouse_id,customer_id,description)
    VALUES(v_company,v_journal.id,v_line_no,v_account,v_net,0,v_note.store_id,
      v_note.warehouse_id,v_note.customer_id,'Retur dan potongan penjualan');
  END IF;
  FOR v_tax IN SELECT (line.source_snapshot->>'taxAccountId')::uuid account_id,
      sum(line.tax_amount) amount
    FROM public.backoffice_sales_credit_note_lines line
    WHERE line.company_id=v_company AND line.credit_note_id=v_note.id
      AND line.tax_amount>0 GROUP BY (line.source_snapshot->>'taxAccountId')::uuid
  LOOP
    IF v_tax.account_id IS NULL OR NOT EXISTS(SELECT 1 FROM public.chart_of_accounts account
      WHERE account.company_id=v_company AND account.id=v_tax.account_id
        AND account.is_active AND account.is_postable) THEN
      RAISE EXCEPTION 'CREDIT_NOTE_SOURCE_TAX_ACCOUNT_INVALID: snapshot Pajak Invoice Retail tidak dapat diposting';
    END IF;
    v_line_no:=v_line_no+10;
    INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,account_id,
      debit,credit,store_id,warehouse_id,customer_id,description)
    VALUES(v_company,v_journal.id,v_line_no,v_tax.account_id,v_tax.amount,0,
      v_note.store_id,v_note.warehouse_id,v_note.customer_id,'Pembalik Pajak Keluaran');
  END LOOP;
  IF v_note.delivery_fee_amount>0 THEN
    v_account:=private.resolve_financial_event_account(v_event,'DELIVERY_FEE_REVENUE');
    v_line_no:=v_line_no+10;
    INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,account_id,
      debit,credit,store_id,warehouse_id,customer_id,description)
    VALUES(v_company,v_journal.id,v_line_no,v_account,v_note.delivery_fee_amount,0,
      v_note.store_id,v_note.warehouse_id,v_note.customer_id,'Koreksi ongkir');
  END IF;
  IF v_ar>0 THEN
    v_account:=private.resolve_financial_event_account(v_event,'CUSTOMER_RECEIVABLE');
    v_line_no:=v_line_no+10;
    INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,account_id,
      debit,credit,store_id,warehouse_id,customer_id,description)
    VALUES(v_company,v_journal.id,v_line_no,v_account,0,v_ar,v_note.store_id,
      v_note.warehouse_id,v_note.customer_id,'Pengurang Piutang Customer');
  END IF;
  IF v_refund>0 THEN
    v_account:=private.resolve_financial_event_account(v_event,'CUSTOMER_REFUND_LIABILITY');
    v_line_no:=v_line_no+10;
    INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,account_id,
      debit,credit,store_id,warehouse_id,customer_id,description)
    VALUES(v_company,v_journal.id,v_line_no,v_account,0,v_refund,v_note.store_id,
      v_note.warehouse_id,v_note.customer_id,'Utang Refund Customer');
  END IF;
  UPDATE public.finance_journals SET status='POSTED',posted_by=v_actor,
    posted_at=clock_timestamp() WHERE company_id=v_company AND id=v_journal.id
    RETURNING * INTO v_journal;
  IF round(v_journal.total_debit,4)<>round(v_note.grand_total,4)
    OR round(v_journal.total_credit,4)<>round(v_note.grand_total,4) THEN
    RAISE EXCEPTION 'JOURNAL_UNBALANCED: nilai debit dan kredit Credit Note tidak seimbang';
  END IF;
  UPDATE public.financial_events SET status='POSTED'::public.event_status,
    processed_at=clock_timestamp(),error_message=NULL,
    transaction_rule_version=20260918150000
  WHERE company_id=v_company AND id=v_event.id;
  UPDATE public.backoffice_sales_credit_notes SET status='POSTED',
    ar_reduction_amount=v_ar,refund_liability_amount=v_refund,
    financial_event_id=v_event.id,posted_by=v_actor,posted_at=clock_timestamp(),
    master_version=master_version+1,updated_by=v_actor,updated_at=clock_timestamp()
  WHERE company_id=v_company AND id=v_note.id;
  UPDATE public.backoffice_sales_returns document SET
    status=CASE WHEN EXISTS(SELECT 1 FROM public.backoffice_sales_credit_notes note
          WHERE note.company_id=v_company AND note.return_id=document.id
            AND note.status='DRAFT') THEN 'CREDIT_PENDING'
      WHEN EXISTS(SELECT 1 FROM public.backoffice_sales_credit_notes note
          WHERE note.company_id=v_company AND note.return_id=document.id
            AND note.status='POSTED' AND note.refund_liability_amount>0)
        THEN 'REFUND_PENDING' ELSE 'COMPLETED' END,
    master_version=master_version+1,updated_at=clock_timestamp()
  WHERE document.company_id=v_company AND document.id=v_note.return_id;
  v_after:=private.backoffice_sales_credit_note_snapshot(v_company,v_note.id);
  v_response:=jsonb_build_object('companyId',v_company,'data',v_after,
    'finance',jsonb_build_object('financialEventId',v_event.id,'journalId',v_journal.id,
      'journalNo',v_journal.journal_no,'accountingDate',v_journal.accounting_date,
      'journalType',v_journal.journal_type),'exactRetry',false);
  INSERT INTO public.backoffice_sales_credit_note_operations(company_id,operation_id,
    operation_type,return_id,credit_note_id,expected_version,request_hash,
    response_snapshot,actor_id)
  VALUES(v_company,p_operation_id,'POST',v_note.return_id,v_note.id,p_expected_version,
    v_hash,v_response,v_actor);
  INSERT INTO public.backoffice_sales_credit_note_audit(company_id,return_id,
    credit_note_id,operation_id,action,actor_id,before_state,after_state)
  VALUES(v_company,v_note.return_id,v_note.id,p_operation_id,'POST',v_actor,v_before,v_after);
  RETURN v_response;
END
$$;

ALTER FUNCTION public.post_backoffice_sales_credit_note(uuid,bigint,uuid)
  RENAME TO post_backoffice_sales_credit_note_before_retained;
ALTER FUNCTION public.post_backoffice_sales_credit_note_before_retained(uuid,bigint,uuid)
  SET SCHEMA private;

CREATE FUNCTION public.post_backoffice_sales_credit_note(
  p_credit_note_id uuid,p_expected_version bigint,p_operation_id uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='15s' AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_kind text;
BEGIN
  SELECT source_kind INTO v_kind FROM public.backoffice_sales_credit_notes
  WHERE company_id=v_company AND id=p_credit_note_id;
  IF v_kind IS NULL THEN RAISE EXCEPTION 'CREDIT_NOTE_NOT_FOUND: dokumen tidak ditemukan pada Company aktif'; END IF;
  IF v_kind='RETAINED_RETAIL' THEN
    RETURN private.post_retained_retail_credit_note_core(
      p_credit_note_id,p_expected_version,p_operation_id);
  END IF;
  RETURN private.post_backoffice_sales_credit_note_before_retained(
    p_credit_note_id,p_expected_version,p_operation_id);
END
$$;

-- Preserve the canonical Refund posting/reversal functions byte-for-byte.
-- Both functions already lock and validate the Credit Note.  This BEFORE
-- trigger copies the immutable source identity from that locked parent, so the
-- existing INSERT statements remain compatible for native and retained notes.
CREATE FUNCTION private.trg_assign_backoffice_customer_refund_source()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_note public.backoffice_sales_credit_notes%rowtype;
BEGIN
  SELECT * INTO v_note FROM public.backoffice_sales_credit_notes note
  WHERE note.company_id=NEW.company_id AND note.id=NEW.credit_note_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'CUSTOMER_REFUND_CREDIT_NOTE_NOT_FOUND: Credit Note sumber tidak ditemukan';
  END IF;
  IF NEW.return_id<>v_note.return_id THEN
    RAISE EXCEPTION 'CUSTOMER_REFUND_SOURCE_MISMATCH: Retur Refund tidak sama dengan Credit Note';
  END IF;
  NEW.source_kind:=v_note.source_kind;
  NEW.source_invoice_id:=v_note.source_invoice_id;
  NEW.source_retail_sales_id:=v_note.source_retail_sales_id;
  RETURN NEW;
END
$$;
CREATE TRIGGER assign_backoffice_customer_refund_source
BEFORE INSERT ON public.backoffice_sales_customer_refunds
FOR EACH ROW EXECUTE FUNCTION private.trg_assign_backoffice_customer_refund_source();

CREATE FUNCTION public.get_backoffice_sales_credit_note_payment_context(
  p_credit_note_id uuid
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='8s' AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_note public.backoffice_sales_credit_notes%rowtype;
  v_permission jsonb;
BEGIN
  v_permission:=private.acp_require_permission_capability(
    v_company,'finance.customer_refunds','VIEW');
  SELECT * INTO v_note FROM public.backoffice_sales_credit_notes note
  WHERE note.company_id=v_company AND note.id=p_credit_note_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'CREDIT_NOTE_NOT_FOUND: dokumen tidak ditemukan pada Company aktif'; END IF;
  RETURN (SELECT jsonb_build_object(
    'companyDate',(clock_timestamp() AT TIME ZONE company.timezone)::date,
    'sourceKind',v_note.source_kind,
    'sourceInvoiceId',v_note.source_invoice_id,
    'sourceRetailSalesId',v_note.source_retail_sales_id,
    'effectiveCapabilities',v_permission->'effectiveCapabilities',
    'paymentMethods',COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'id',method.id,'name',method.payment_method_name,'type',method.method_type,
      'settlementRoute',method.settlement_route,'proofMode',method.proof_mode)
      ORDER BY method.is_default DESC,method.payment_method_name,method.id)
      FROM public.payment_methods method
      WHERE method.company_id=v_company AND method.is_active
        AND method.settlement_route IN('CASH_DRAWER','DIRECT_BANK')
        AND (method.available_all_stores OR EXISTS(SELECT 1
          FROM public.payment_method_store_assignments assignment
          WHERE assignment.company_id=v_company
            AND assignment.payment_method_id=method.id
            AND assignment.store_id=v_note.store_id))),'[]'::jsonb))
    FROM public.companies company WHERE company.id=v_company AND company.status='ACTIVE');
END
$$;

-- Add retained-Retail Credit Notes to AR Aging without rewriting the immutable
-- Retail Sale or Customer Receipt rows.
DO $patch_ar$
DECLARE v_definition text;v_old text;v_new text;v_count integer;
BEGIN
  SELECT pg_get_functiondef(to_regprocedure('public.get_finance_ar_aging(date,uuid,uuid)'))
    INTO STRICT v_definition;
  v_old:='WHERE allocation.company_id=v_company AND allocation.sales_id=sale.id),0) allocated_amount
    FROM public.sales_headers sale';
  v_new:='WHERE allocation.company_id=v_company AND allocation.sales_id=sale.id),0) allocated_amount,
      COALESCE((SELECT sum(note.ar_reduction_amount)
        FROM public.backoffice_sales_credit_notes note
        WHERE note.company_id=v_company AND note.source_kind=''RETAINED_RETAIL''
          AND note.source_retail_sales_id=sale.id AND note.status=''POSTED''
          AND note.credit_note_date<=v_as_of),0) credited_amount
    FROM public.sales_headers sale';
  v_count:=(length(v_definition)-length(replace(v_definition,v_old,'')))/length(v_old);
  IF v_count<>1 THEN RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Retail AR credit-column anchor drift'; END IF;
  v_definition:=replace(v_definition,v_old,v_new);
  v_old:='ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING),0),schedule.amount_due),0)
    FROM public.backoffice_sales_invoices invoice';
  v_new:='ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING),0),schedule.amount_due),0),
      0::numeric credited_amount
    FROM public.backoffice_sales_invoices invoice';
  v_count:=(length(v_definition)-length(replace(v_definition,v_old,'')))/length(v_old);
  IF v_count<>1 THEN RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Backoffice AR credit-column anchor drift'; END IF;
  v_definition:=replace(v_definition,v_old,v_new);
  v_old:='GREATEST(original_receivable-allocated_amount,0) outstanding';
  v_new:='GREATEST(original_receivable-allocated_amount-credited_amount,0) outstanding';
  v_count:=(length(v_definition)-length(replace(v_definition,v_old,'')))/length(v_old);
  IF v_count<>1 THEN RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Retail AR outstanding anchor drift'; END IF;
  v_definition:=replace(v_definition,v_old,v_new);
  v_old:='WHERE original_receivable-allocated_amount>0';
  v_new:='WHERE original_receivable-allocated_amount-credited_amount>0';
  v_count:=(length(v_definition)-length(replace(v_definition,v_old,'')))/length(v_old);
  IF v_count<>1 THEN RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Retail AR open-item anchor drift'; END IF;
  v_definition:=replace(v_definition,v_old,v_new);
  v_old:='''allocatedAmount'',item.allocated_amount,
      ''outstanding'',item.outstanding';
  v_new:='''allocatedAmount'',item.allocated_amount,''creditedAmount'',item.credited_amount,
      ''outstanding'',item.outstanding';
  v_count:=(length(v_definition)-length(replace(v_definition,v_old,'')))/length(v_old);
  IF v_count<>1 THEN RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Retail AR output anchor drift'; END IF;
  EXECUTE replace(v_definition,v_old,v_new);
END
$patch_ar$;

-- The existing Statement union already emits Backoffice Credit Notes. Make the
-- source label work for either a Backoffice Invoice or retained Retail Invoice.
DO $patch_statement$
DECLARE v_definition text;v_old text;v_new text;v_count integer;
BEGIN
  SELECT pg_get_functiondef(to_regprocedure(
    'public.get_finance_customer_statement(uuid,date,date,uuid)')) INTO STRICT v_definition;
  v_old:='SELECT note.id,''CREDIT_NOTE'',''BACKOFFICE'',note.credit_note_no';
  v_new:='SELECT note.id,''CREDIT_NOTE'',CASE note.source_kind
        WHEN ''RETAINED_RETAIL'' THEN ''RETAIL'' ELSE ''BACKOFFICE'' END,note.credit_note_no';
  v_count:=(length(v_definition)-length(replace(v_definition,v_old,'')))/length(v_old);
  IF v_count<>1 THEN RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Customer Statement source-process anchor drift'; END IF;
  v_definition:=replace(v_definition,v_old,v_new);
  v_old:='(''Credit Note Retur Customer untuk ''||source.invoice_no)::text
    FROM public.backoffice_sales_credit_notes note
    JOIN public.backoffice_sales_invoices source
      ON source.company_id=note.company_id AND source.id=note.source_invoice_id
      AND source.customer_id=p_customer_id';
  v_new:='(''Credit Note Retur Customer untuk ''||COALESCE(source.invoice_no,
        note.source_invoice_snapshot->>''invoiceNo''))::text
    FROM public.backoffice_sales_credit_notes note
    LEFT JOIN public.backoffice_sales_invoices source
      ON source.company_id=note.company_id AND source.id=note.source_invoice_id';
  v_count:=(length(v_definition)-length(replace(v_definition,v_old,'')))/length(v_old);
  IF v_count<>1 THEN RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Customer Statement retained source anchor drift'; END IF;
  EXECUTE replace(v_definition,v_old,v_new);
END
$patch_statement$;

REVOKE ALL ON FUNCTION
  private.allocate_backoffice_sales_return_invoices_before_retained(uuid,bigint,uuid,jsonb),
  private.allocate_retained_retail_return_credit_core(uuid,bigint,uuid,jsonb),
  private.post_backoffice_sales_credit_note_before_retained(uuid,bigint,uuid),
  private.post_retained_retail_credit_note_core(uuid,bigint,uuid),
  private.trg_guard_retained_retail_credit_note_fee(),
  private.trg_assign_backoffice_customer_refund_source()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.allocate_backoffice_sales_return_invoices_before_retained(uuid,bigint,uuid,jsonb),
  private.allocate_retained_retail_return_credit_core(uuid,bigint,uuid,jsonb),
  private.post_backoffice_sales_credit_note_before_retained(uuid,bigint,uuid),
  private.post_retained_retail_credit_note_core(uuid,bigint,uuid),
  private.trg_guard_retained_retail_credit_note_fee(),
  private.trg_assign_backoffice_customer_refund_source()
TO service_role;
REVOKE ALL ON FUNCTION
  public.get_retained_retail_return_invoice_workspace(uuid),
  public.allocate_backoffice_sales_return_invoices(uuid,bigint,uuid,jsonb),
  public.post_backoffice_sales_credit_note(uuid,bigint,uuid),
  public.get_backoffice_sales_credit_note_payment_context(uuid)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION
  public.get_retained_retail_return_invoice_workspace(uuid),
  public.allocate_backoffice_sales_return_invoices(uuid,bigint,uuid,jsonb),
  public.post_backoffice_sales_credit_note(uuid,bigint,uuid),
  public.get_backoffice_sales_credit_note_payment_context(uuid)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260918150000','retained_retail_credit_note_refund_bridge',
  'Complete retained Retail Return financial correction with exact Retail Invoice lineage, AR-first Credit Note and canonical Refund compatibility; native Backoffice path delegates unchanged');
NOTIFY pgrst,'reload schema';
COMMIT;
