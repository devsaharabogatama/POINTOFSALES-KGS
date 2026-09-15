-- Additive client read-model plus explicit single due-date support.
-- Isolated development rollout only; no POS, Stock, DO, receipt, FIFO or historical mutation.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260910151000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: immutable Invoice Draft chain required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260911150000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260911150000';
  END IF;
  IF to_regprocedure('private.rebuild_backoffice_sales_invoice_schedules(uuid,uuid,uuid)') IS NULL
    OR to_regprocedure('private.save_backoffice_sales_invoice_draft_core(uuid,bigint,uuid,uuid,jsonb)') IS NULL
    OR to_regprocedure('public.save_backoffice_sales_invoice_draft(uuid,bigint,uuid,uuid,jsonb)') IS NULL
    OR to_regprocedure('public.post_backoffice_sales_invoice(uuid,bigint,uuid)') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical Invoice call chain missing';
  END IF;
  IF to_regprocedure('private.backoffice_sales_invoice_ui_snapshot(uuid,uuid)') IS NOT NULL
    OR to_regprocedure('public.get_backoffice_sales_invoice_workspace(uuid,text,text,integer)') IS NOT NULL
    OR to_regprocedure('public.get_backoffice_sales_invoice_ui(uuid)') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Invoice client routine collision';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
    WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
END
$guard$;

CREATE OR REPLACE FUNCTION private.rebuild_backoffice_sales_invoice_schedules(
  p_company_id uuid,p_invoice_id uuid,p_actor_id uuid
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_invoice public.backoffice_sales_invoices%rowtype;v_term_line record;
  v_amount numeric(24,4);v_assigned numeric(24,4):=0;v_count integer:=0;
  v_has_balance boolean:=false;v_last_id uuid;v_explicit_due text;v_due_date date;
BEGIN
  SELECT * INTO STRICT v_invoice FROM public.backoffice_sales_invoices
  WHERE company_id=p_company_id AND id=p_invoice_id FOR UPDATE;
  DELETE FROM public.backoffice_sales_invoice_receivable_schedules
  WHERE company_id=p_company_id AND invoice_id=p_invoice_id;
  IF v_invoice.grand_total<=0 THEN RETURN; END IF;
  IF v_invoice.payment_term_id IS NULL THEN
    v_explicit_due:=current_setting('kgs.backoffice_invoice_due_date',true);
    BEGIN v_due_date:=COALESCE(NULLIF(v_explicit_due,'')::date,v_invoice.invoice_date);
    EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_DUE_DATE_INVALID'; END;
    INSERT INTO public.backoffice_sales_invoice_receivable_schedules(
      company_id,invoice_id,installment_no,due_date,amount_due)
    VALUES(p_company_id,p_invoice_id,1,v_due_date,v_invoice.grand_total);
    RETURN;
  END IF;
  FOR v_term_line IN SELECT * FROM public.backoffice_sales_payment_term_lines
    WHERE company_id=p_company_id AND payment_term_id=v_invoice.payment_term_id
    ORDER BY line_no FOR SHARE
  LOOP
    v_count:=v_count+1;
    IF v_term_line.amount_type='BALANCE' THEN
      IF v_has_balance THEN RAISE EXCEPTION 'PAYMENT_TERM_MULTIPLE_BALANCE_LINES'; END IF;
      v_has_balance:=true;v_amount:=v_invoice.grand_total-v_assigned;
    ELSIF v_term_line.amount_type='PERCENT' THEN
      v_amount:=round(v_invoice.grand_total*v_term_line.amount_value/100,4);
    ELSE
      v_amount:=least(round(v_term_line.amount_value,4),v_invoice.grand_total-v_assigned);
    END IF;
    IF v_amount<=0 OR v_assigned+v_amount>v_invoice.grand_total THEN
      RAISE EXCEPTION 'PAYMENT_TERM_AMOUNT_INVALID';
    END IF;
    INSERT INTO public.backoffice_sales_invoice_receivable_schedules(
      company_id,invoice_id,installment_no,due_date,amount_due)
    VALUES(p_company_id,p_invoice_id,v_count,
      private.backoffice_sales_invoice_due_date(v_invoice.invoice_date,
        v_term_line.due_rule,v_term_line.days_offset,v_term_line.day_of_month),v_amount)
    RETURNING id INTO v_last_id;
    v_assigned:=v_assigned+v_amount;
  END LOOP;
  IF v_count=0 THEN RAISE EXCEPTION 'PAYMENT_TERM_HAS_NO_LINES'; END IF;
  IF v_assigned<v_invoice.grand_total AND NOT v_has_balance THEN
    UPDATE public.backoffice_sales_invoice_receivable_schedules
    SET amount_due=amount_due+(v_invoice.grand_total-v_assigned)
    WHERE company_id=p_company_id AND id=v_last_id;
    v_assigned:=v_invoice.grand_total;
  END IF;
  IF v_assigned<>v_invoice.grand_total THEN RAISE EXCEPTION 'PAYMENT_TERM_TOTAL_MISMATCH'; END IF;
END
$$;

CREATE OR REPLACE FUNCTION public.save_backoffice_sales_invoice_draft(
  p_invoice_id uuid,p_expected_version bigint,p_operation_id uuid,
  p_sales_order_id uuid,p_payload jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='8s' AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_response jsonb;v_due text;
BEGIN
  PERFORM private.acp_require_permission_capability(v_company,'sales.backoffice_orders',
    CASE WHEN p_invoice_id IS NULL THEN 'CREATE_DRAFT' ELSE 'EDIT_DRAFT' END);
  IF NOT EXISTS(SELECT 1 FROM public.backoffice_sales_orders document
    WHERE document.company_id=v_company AND document.id=p_sales_order_id
      AND document.status='CONFIRMED' AND document.fulfillment_status='COMPLETED'
      AND document.sales_process_mode='BACKOFFICE_DELIVERED_QTY_INVOICE') THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_ORDER_NOT_INVOICEABLE';
  END IF;
  IF p_payload ? 'dueDate' THEN
    IF NULLIF(p_payload->>'paymentTermId','') IS NOT NULL THEN
      RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_DUE_DATE_CONFLICT';
    END IF;
    BEGIN v_due:=(p_payload->>'dueDate')::date::text;
    EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_DUE_DATE_INVALID'; END;
    IF NULLIF(v_due,'') IS NULL THEN RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_DUE_DATE_INVALID'; END IF;
    PERFORM set_config('kgs.backoffice_invoice_due_date',v_due,true);
  END IF;
  BEGIN
    v_response:=private.save_backoffice_sales_invoice_draft_core(p_invoice_id,p_expected_version,
      p_operation_id,p_sales_order_id,p_payload);
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('kgs.backoffice_invoice_due_date','',true);
    RAISE;
  END;
  PERFORM set_config('kgs.backoffice_invoice_due_date','',true);
  RETURN v_response;
END
$$;

CREATE FUNCTION private.backoffice_sales_invoice_ui_snapshot(p_company_id uuid,p_invoice_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
  SELECT private.backoffice_sales_invoice_snapshot(p_company_id,p_invoice_id)
    ||jsonb_build_object(
      'salesOrderNo',document.order_no,'quotationNo',document.quotation_no,
      'orderDate',document.order_date,'salesOrderDueDate',document.due_date,
      'fulfillmentStatus',document.fulfillment_status,
      'storeName',store.store_name,'warehouseName',warehouse.name,
      'dueDate',(SELECT min(schedule.due_date) FROM public.backoffice_sales_invoice_receivable_schedules schedule
        WHERE schedule.company_id=invoice.company_id AND schedule.invoice_id=invoice.id),
      'lines',COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'id',line.id,'lineNo',line.line_no,'lineType',line.line_type,'effectType',line.effect_type,
        'salesOrderLineId',line.sales_order_line_id,'productId',line.product_id,'uomId',line.uom_id,
        'productCode',source.product_code_snapshot,'productName',source.product_name_snapshot,
        'uomCode',source.uom_code_snapshot,'uomName',source.uom_name_snapshot,
        'orderedQty',source.ordered_qty,
        'acceptedQty',round(source.accepted_base_qty/source.base_qty_per_uom,6),
        'invoicedBeforeQty',round(greatest(0,source.invoiced_base_qty-line.quantity_base)/source.base_qty_per_uom,6),
        'quantityUom',line.quantity_uom,'baseQtyPerUom',line.base_qty_per_uom,
        'quantityBase',line.quantity_base,'unitPrice',line.unit_price,
        'discountAmount',line.discount_amount,'taxAmount',line.tax_amount,
        'lineAmount',line.line_amount,'description',line.description,
        'sourceSnapshot',line.source_snapshot) ORDER BY line.line_no)
        FROM public.backoffice_sales_invoice_lines line
        LEFT JOIN public.backoffice_sales_order_lines source ON source.company_id=line.company_id
          AND source.id=line.sales_order_line_id
        WHERE line.company_id=invoice.company_id AND line.invoice_id=invoice.id),'[]'::jsonb),
      'activity',COALESCE((SELECT jsonb_agg(jsonb_build_object('action',audit.action,
        'reason',audit.reason,'actorId',audit.actor_id,'createdAt',audit.created_at)
        ORDER BY audit.created_at,audit.id)
        FROM public.backoffice_sales_invoice_audit audit
        WHERE audit.company_id=invoice.company_id AND audit.invoice_id=invoice.id),'[]'::jsonb))
  FROM public.backoffice_sales_invoices invoice
  JOIN public.backoffice_sales_orders document ON document.company_id=invoice.company_id
    AND document.id=invoice.sales_order_id
  JOIN public.stores store ON store.company_id=invoice.company_id AND store.id=invoice.store_id
  JOIN public.warehouses warehouse ON warehouse.company_id=invoice.company_id AND warehouse.id=invoice.warehouse_id
  WHERE invoice.company_id=p_company_id AND invoice.id=p_invoice_id
$$;

CREATE FUNCTION public.get_backoffice_sales_invoice_workspace(
  p_sales_order_id uuid DEFAULT NULL,p_status text DEFAULT NULL,p_search text DEFAULT NULL,
  p_limit integer DEFAULT 100
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='8s' AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_status text:=upper(NULLIF(btrim(p_status),''));
  v_search text:=NULLIF(btrim(p_search),'');v_source jsonb;
BEGIN
  PERFORM private.acp_require_permission_capability(v_company,'sales.backoffice_orders','VIEW');
  IF v_status IS NOT NULL AND v_status NOT IN('DRAFT','POSTED','CANCELED','REVERSED') THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_STATUS_INVALID';
  END IF;
  IF p_limit IS NULL OR p_limit<1 OR p_limit>200 THEN RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_FILTER_INVALID'; END IF;
  IF p_sales_order_id IS NOT NULL THEN
    SELECT jsonb_build_object('id',document.id,'salesOrderNo',document.order_no,
      'quotationNo',document.quotation_no,'status',document.status,
      'fulfillmentStatus',document.fulfillment_status,'orderDate',document.order_date,
      'plannedDeliveryDate',document.planned_delivery_date,'isTempo',document.is_tempo,
      'dueDate',document.due_date,'customerId',document.customer_id,
      'customerSnapshot',document.customer_snapshot,'storeId',document.store_id,
      'warehouseId',document.warehouse_id,'currencyCode',document.currency_code,
      'deliveryFeeAmount',document.delivery_fee_amount,
      'deliveryFeeRemaining',greatest(0,document.delivery_fee_amount-COALESCE((SELECT sum(invoice.delivery_fee_amount)
        FROM public.backoffice_sales_invoices invoice WHERE invoice.company_id=document.company_id
          AND invoice.sales_order_id=document.id AND invoice.invoice_type='REGULAR'
          AND invoice.status IN('DRAFT','POSTED')),0)),
      'totalToInvoiceBaseQty',COALESCE((SELECT sum(line.to_invoice_base_qty)
        FROM public.backoffice_sales_order_lines line WHERE line.company_id=document.company_id
          AND line.sales_order_id=document.id),0),
      'lines',COALESCE((SELECT jsonb_agg(jsonb_build_object('id',line.id,'lineNo',line.line_no,
        'productId',line.product_id,'uomId',line.uom_id,'productCode',line.product_code_snapshot,
        'productName',line.product_name_snapshot,'uomCode',line.uom_code_snapshot,
        'uomName',line.uom_name_snapshot,'orderedQty',line.ordered_qty,
        'acceptedQty',round(line.accepted_base_qty/line.base_qty_per_uom,6),
        'invoicedQty',round(line.invoiced_base_qty/line.base_qty_per_uom,6),
        'draftAllocatedQty',round(line.draft_invoice_allocated_base_qty/line.base_qty_per_uom,6),
        'toInvoiceQty',round(line.to_invoice_base_qty/line.base_qty_per_uom,6),
        'baseQtyPerUom',line.base_qty_per_uom,'unitPrice',line.unit_price,
        'discountAmount',line.discount_amount,'taxApplied',line.tax_rule_id IS NOT NULL,
        'taxName',line.tax_name_snapshot,'taxRatePercent',line.tax_rate_percent_snapshot)
        ORDER BY line.line_no) FROM public.backoffice_sales_order_lines line
        WHERE line.company_id=document.company_id AND line.sales_order_id=document.id),'[]'::jsonb))
      INTO v_source FROM public.backoffice_sales_orders document
      WHERE document.company_id=v_company AND document.id=p_sales_order_id;
    IF v_source IS NULL THEN RAISE EXCEPTION 'BACKOFFICE_SALES_ORDER_NOT_FOUND'; END IF;
  END IF;
  RETURN jsonb_build_object('companyId',v_company,
    'companyDate',current_timestamp AT TIME ZONE company.timezone::text,
    'sourceOrder',v_source,
    'paymentTerms',COALESCE((SELECT jsonb_agg(jsonb_build_object('id',term.id,'code',term.term_code,
      'name',term.term_name,'showInstallmentDates',term.show_installment_dates) ORDER BY term.term_name)
      FROM public.backoffice_sales_payment_terms term WHERE term.company_id=v_company AND term.is_active),'[]'::jsonb),
    'invoices',COALESCE((SELECT jsonb_agg(private.backoffice_sales_invoice_ui_snapshot(v_company,invoice.id)
      ORDER BY invoice.created_at DESC,invoice.id DESC)
      FROM (SELECT item.id,item.created_at FROM public.backoffice_sales_invoices item
        WHERE item.company_id=v_company AND (p_sales_order_id IS NULL OR item.sales_order_id=p_sales_order_id)
          AND (v_status IS NULL OR item.status=v_status)
          AND (v_search IS NULL OR item.draft_no ILIKE '%'||v_search||'%'
            OR item.invoice_no ILIKE '%'||v_search||'%'
            OR item.customer_snapshot->>'name' ILIKE '%'||v_search||'%')
        ORDER BY item.created_at DESC,item.id DESC LIMIT p_limit) invoice),'[]'::jsonb))
  FROM public.companies company WHERE company.id=v_company;
END
$$;

CREATE FUNCTION public.get_backoffice_sales_invoice_ui(p_invoice_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='8s' AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_data jsonb;
BEGIN
  PERFORM private.acp_require_permission_capability(v_company,'sales.backoffice_orders','VIEW');
  v_data:=private.backoffice_sales_invoice_ui_snapshot(v_company,p_invoice_id);
  IF v_data IS NULL THEN RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_NOT_FOUND'; END IF;
  RETURN jsonb_build_object('companyId',v_company,'data',v_data);
END
$$;

REVOKE ALL ON FUNCTION private.backoffice_sales_invoice_ui_snapshot(uuid,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.backoffice_sales_invoice_ui_snapshot(uuid,uuid) TO service_role;
REVOKE ALL ON FUNCTION public.get_backoffice_sales_invoice_workspace(uuid,text,text,integer),
  public.get_backoffice_sales_invoice_ui(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_backoffice_sales_invoice_workspace(uuid,text,text,integer),
  public.get_backoffice_sales_invoice_ui(uuid) TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260911150000','backoffice_sales_invoice_client_activation',
  'Additive Invoice UI read-model and explicit single due-date scheduling through canonical Draft call chain; no automatic Invoice, POS, Stock, DO, receipt, FIFO, historical row or production effect');
NOTIFY pgrst,'reload schema';
COMMIT;
