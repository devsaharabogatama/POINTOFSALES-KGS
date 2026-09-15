-- Transactional Draft Regular/Down Payment Invoice runtime.
-- Development rollout only. No posting, AR, Revenue, Tax payable, Payment,
-- Financial Event, Journal, Stock Movement, FIFO, or POS mutation.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260909156000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Invoice accounting foundation required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260909157000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260909157000';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
    WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
  IF EXISTS(SELECT 1 FROM public.backoffice_sales_invoices
    UNION ALL SELECT 1 FROM public.backoffice_sales_invoice_lines
    UNION ALL SELECT 1 FROM public.backoffice_sales_invoice_quantity_allocations
    UNION ALL SELECT 1 FROM public.backoffice_sales_down_payment_applications
    UNION ALL SELECT 1 FROM public.backoffice_sales_invoice_receivable_schedules
    UNION ALL SELECT 1 FROM public.backoffice_sales_invoice_audit) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Invoice foundation is no longer empty';
  END IF;
  IF to_regprocedure('private.acp_require_permission_capability(uuid,text,text)') IS NULL
    OR to_regprocedure('private.calculate_tax_group(jsonb,numeric,text,text,text)') IS NULL
    OR to_regprocedure('extensions.digest(bytea,text)') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical authorization/tax dependency missing';
  END IF;
END
$guard$;

-- Preserve the accounting split selected by the user: DP percentage applies
-- to DPP, while tax follows the same proportion. The total remains available
-- for customer-facing display and later AR posting.
ALTER TABLE public.backoffice_sales_down_payment_applications
  ADD COLUMN applied_basis_amount numeric(24,4) NOT NULL DEFAULT 0,
  ADD COLUMN applied_tax_amount numeric(24,4) NOT NULL DEFAULT 0,
  ADD CONSTRAINT backoffice_sales_dp_application_split_check CHECK(
    applied_basis_amount>=0 AND applied_tax_amount>=0
    AND applied_amount=applied_basis_amount+applied_tax_amount
  ) NOT VALID;
ALTER TABLE public.backoffice_sales_down_payment_applications
  VALIDATE CONSTRAINT backoffice_sales_dp_application_split_check;

-- All three quantities are stored at six decimals. Compare against the same
-- persisted precision so valid non-integer UOM factors cannot fail after cast.
ALTER TABLE public.backoffice_sales_invoice_lines
  DROP CONSTRAINT backoffice_sales_invoice_lines_shape_check,
  ADD CONSTRAINT backoffice_sales_invoice_lines_shape_check CHECK(
    line_no>0 AND line_type IN('PRODUCT','DOWN_PAYMENT','DOWN_PAYMENT_DEDUCTION')
    AND effect_type IN('CHARGE','DEDUCTION') AND unit_price>=0
    AND discount_amount>=0 AND tax_amount>=0 AND line_amount>=0
    AND nullif(btrim(description),'') IS NOT NULL AND jsonb_typeof(source_snapshot)='object'
    AND ((line_type='PRODUCT' AND effect_type='CHARGE' AND sales_order_line_id IS NOT NULL
      AND product_id IS NOT NULL AND uom_id IS NOT NULL AND quantity_uom>0
      AND base_qty_per_uom>0 AND quantity_base=round(quantity_uom*base_qty_per_uom,6))
      OR (line_type='DOWN_PAYMENT' AND effect_type='CHARGE' AND sales_order_line_id IS NULL
        AND product_id IS NULL AND uom_id IS NULL AND quantity_uom IS NULL
        AND base_qty_per_uom IS NULL AND quantity_base IS NULL)
      OR (line_type='DOWN_PAYMENT_DEDUCTION' AND effect_type='DEDUCTION'
        AND sales_order_line_id IS NULL AND product_id IS NULL AND uom_id IS NULL
        AND quantity_uom IS NULL AND base_qty_per_uom IS NULL AND quantity_base IS NULL)));

CREATE TABLE public.backoffice_sales_invoice_operations(
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
  operation_id uuid NOT NULL,
  operation_type text NOT NULL,
  invoice_id uuid NOT NULL,
  expected_version bigint,
  request_hash text NOT NULL,
  response_snapshot jsonb NOT NULL,
  actor_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT backoffice_sales_invoice_operations_identity_unique
    UNIQUE(company_id,operation_id),
  CONSTRAINT backoffice_sales_invoice_operations_invoice_fk
    FOREIGN KEY(company_id,invoice_id)
    REFERENCES public.backoffice_sales_invoices(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_invoice_operations_shape_check CHECK(
    operation_type IN('SAVE_DRAFT','CANCEL_DRAFT')
    AND (expected_version IS NULL OR expected_version>0)
    AND request_hash~'^[0-9a-f]{64}$'
    AND jsonb_typeof(response_snapshot)='object')
);
ALTER TABLE public.backoffice_sales_invoice_operations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.backoffice_sales_invoice_operations FROM PUBLIC,anon,authenticated;

CREATE SEQUENCE private.backoffice_sales_invoice_draft_no_seq AS bigint START WITH 1;
REVOKE ALL ON SEQUENCE private.backoffice_sales_invoice_draft_no_seq
  FROM PUBLIC,anon,authenticated;
GRANT USAGE,SELECT ON SEQUENCE private.backoffice_sales_invoice_draft_no_seq TO service_role;

CREATE FUNCTION private.backoffice_sales_invoice_snapshot(
  p_company_id uuid,p_invoice_id uuid
) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
  SELECT jsonb_build_object(
    'id',invoice.id,'salesOrderId',invoice.sales_order_id,
    'draftNo',invoice.draft_no,'invoiceNo',invoice.invoice_no,
    'invoiceSequence',invoice.invoice_sequence,'invoiceType',invoice.invoice_type,
    'status',invoice.status,'invoiceDate',invoice.invoice_date,
    'currencyCode',invoice.currency_code,'customerId',invoice.customer_id,
    'storeId',invoice.store_id,'warehouseId',invoice.warehouse_id,
    'paymentTermId',invoice.payment_term_id,
    'paymentTermSnapshot',invoice.payment_term_snapshot,
    'customerSnapshot',invoice.customer_snapshot,
    'commercialSnapshot',invoice.commercial_snapshot,
    'downPaymentMode',invoice.down_payment_mode,
    'downPaymentInput',invoice.down_payment_input,
    'downPaymentBasisTotal',invoice.down_payment_basis_total,
    'chargeTotal',invoice.charge_total,'discountTotal',invoice.discount_total,
    'taxTotal',invoice.tax_total,
    'downPaymentDeductionTotal',invoice.down_payment_deduction_total,
    'grandTotal',invoice.grand_total,'notes',invoice.notes,
    'masterVersion',invoice.master_version,'createdAt',invoice.created_at,
    'updatedAt',invoice.updated_at,'canceledAt',invoice.canceled_at,
    'cancelReason',invoice.cancel_reason,
    'lines',COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'id',line.id,'lineNo',line.line_no,'lineType',line.line_type,
      'effectType',line.effect_type,'salesOrderLineId',line.sales_order_line_id,
      'productId',line.product_id,'uomId',line.uom_id,
      'quantityUom',line.quantity_uom,'baseQtyPerUom',line.base_qty_per_uom,
      'quantityBase',line.quantity_base,'unitPrice',line.unit_price,
      'discountAmount',line.discount_amount,'taxAmount',line.tax_amount,
      'lineAmount',line.line_amount,'description',line.description,
      'sourceSnapshot',line.source_snapshot) ORDER BY line.line_no)
      FROM public.backoffice_sales_invoice_lines line
      WHERE line.company_id=invoice.company_id AND line.invoice_id=invoice.id),'[]'::jsonb),
    'schedules',COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'installmentNo',schedule.installment_no,'dueDate',schedule.due_date,
      'amountDue',schedule.amount_due,'status',schedule.status)
      ORDER BY schedule.installment_no)
      FROM public.backoffice_sales_invoice_receivable_schedules schedule
      WHERE schedule.company_id=invoice.company_id AND schedule.invoice_id=invoice.id),'[]'::jsonb)
  ) FROM public.backoffice_sales_invoices invoice
  WHERE invoice.company_id=p_company_id AND invoice.id=p_invoice_id
$$;

CREATE FUNCTION private.backoffice_sales_invoice_operation_retry(
  p_company_id uuid,p_operation_id uuid,p_operation_type text,p_request_hash text
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_operation public.backoffice_sales_invoice_operations%rowtype;
BEGIN
  SELECT * INTO v_operation FROM public.backoffice_sales_invoice_operations
  WHERE company_id=p_company_id AND operation_id=p_operation_id;
  IF NOT FOUND THEN RETURN NULL; END IF;
  IF v_operation.operation_type<>p_operation_type
    OR v_operation.request_hash<>p_request_hash THEN
    RAISE EXCEPTION 'IDEMPOTENCY_PAYLOAD_CONFLICT';
  END IF;
  RETURN v_operation.response_snapshot||jsonb_build_object('exactRetry',true);
END
$$;

CREATE FUNCTION private.backoffice_sales_invoice_due_date(
  p_invoice_date date,p_due_rule text,p_days_offset integer,p_day_of_month integer
) RETURNS date LANGUAGE plpgsql IMMUTABLE SET search_path=public,pg_temp AS $$
DECLARE v_month date;v_last_day integer;
BEGIN
  IF p_due_rule='DAYS_AFTER_INVOICE' THEN RETURN p_invoice_date+p_days_offset; END IF;
  IF p_due_rule='END_OF_MONTH' THEN
    RETURN ((date_trunc('month',p_invoice_date)::date+interval '1 month - 1 day')::date
      +p_days_offset);
  END IF;
  IF p_due_rule='DAY_OF_FOLLOWING_MONTH' THEN
    v_month:=(date_trunc('month',p_invoice_date)::date+interval '1 month')::date;
    v_last_day:=extract(day FROM (v_month+interval '1 month - 1 day'))::integer;
    RETURN v_month+least(p_day_of_month,v_last_day)-1+p_days_offset;
  END IF;
  RAISE EXCEPTION 'PAYMENT_TERM_DUE_RULE_INVALID';
END
$$;

CREATE FUNCTION private.rebuild_backoffice_sales_invoice_schedules(
  p_company_id uuid,p_invoice_id uuid,p_actor_id uuid
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_invoice public.backoffice_sales_invoices%rowtype;v_term_line record;
  v_amount numeric(24,4);v_assigned numeric(24,4):=0;v_count integer:=0;
  v_has_balance boolean:=false;v_last_id uuid;
BEGIN
  SELECT * INTO STRICT v_invoice FROM public.backoffice_sales_invoices
  WHERE company_id=p_company_id AND id=p_invoice_id FOR UPDATE;
  DELETE FROM public.backoffice_sales_invoice_receivable_schedules
  WHERE company_id=p_company_id AND invoice_id=p_invoice_id;
  IF v_invoice.grand_total<=0 THEN RETURN; END IF;
  IF v_invoice.payment_term_id IS NULL THEN
    INSERT INTO public.backoffice_sales_invoice_receivable_schedules(
      company_id,invoice_id,installment_no,due_date,amount_due)
    VALUES(p_company_id,p_invoice_id,1,v_invoice.invoice_date,v_invoice.grand_total);
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

CREATE FUNCTION private.save_backoffice_sales_invoice_draft_core(
  p_invoice_id uuid,p_expected_version bigint,p_operation_id uuid,
  p_sales_order_id uuid,p_payload jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE
  v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
  v_order public.backoffice_sales_orders%rowtype;v_invoice public.backoffice_sales_invoices%rowtype;
  v_existing boolean:=false;v_before jsonb;v_after jsonb;v_response jsonb;
  v_hash text;v_retry jsonb;v_type text;v_invoice_date date;v_term uuid;
  v_dp_mode text;v_dp_input numeric;v_invoice_id uuid;v_sequence integer;v_draft_no text;
  v_line_payload jsonb;v_source public.backoffice_sales_order_lines%rowtype;
  v_qty_uom numeric;v_qty_base numeric;v_gross_unit numeric;v_discount numeric;
  v_gross_net numeric;v_tax_enabled boolean;v_tax_result jsonb;v_tax_line jsonb;
  v_tax numeric;v_dpp numeric;v_line_id uuid;v_line_no integer:=0;
  v_charge numeric(24,4):=0;v_discount_total numeric(24,4):=0;
  v_tax_total numeric(24,4):=0;v_dp_basis numeric(24,4):=0;
  v_order_dpp numeric(24,4);v_order_tax numeric(24,4);v_used_dp numeric(24,4);
  v_request_type text:='SAVE_DRAFT';
BEGIN
  IF v_actor IS NULL OR v_company IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF p_operation_id IS NULL OR p_sales_order_id IS NULL OR p_payload IS NULL
    OR jsonb_typeof(p_payload)<>'object' THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_PAYLOAD_INVALID';
  END IF;
  v_hash:=encode(extensions.digest(convert_to(jsonb_build_object('invoiceId',p_invoice_id,
    'expectedVersion',p_expected_version,'salesOrderId',p_sales_order_id,
    'payload',p_payload)::text,'UTF8'),'sha256'),'hex');
  PERFORM pg_advisory_xact_lock(hashtextextended(
    v_company::text||':BACKOFFICE_INVOICE:'||p_operation_id::text,0));
  v_retry:=private.backoffice_sales_invoice_operation_retry(
    v_company,p_operation_id,v_request_type,v_hash);
  IF v_retry IS NOT NULL THEN RETURN v_retry; END IF;

  -- Different operation IDs for the same SO must still serialize sequence,
  -- DP-capacity, and quantity-hold decisions.
  PERFORM pg_advisory_xact_lock(hashtextextended(
    v_company::text||':BACKOFFICE_INVOICE_ORDER:'||p_sales_order_id::text,0));

  SELECT * INTO v_order FROM public.backoffice_sales_orders document
  WHERE document.company_id=v_company AND document.id=p_sales_order_id FOR UPDATE;
  IF NOT FOUND OR v_order.status<>'CONFIRMED'
    OR v_order.sales_process_mode<>'BACKOFFICE_DELIVERED_QTY_INVOICE' THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_ORDER_NOT_INVOICEABLE';
  END IF;
  PERFORM 1 FROM public.backoffice_sales_order_lines line
  WHERE line.company_id=v_company AND line.sales_order_id=p_sales_order_id
  ORDER BY line.line_no FOR UPDATE;
  PERFORM 1 FROM public.backoffice_sales_invoices invoice
  WHERE invoice.company_id=v_company AND invoice.sales_order_id=p_sales_order_id
  ORDER BY invoice.invoice_sequence FOR UPDATE;

  BEGIN
    v_type:=upper(btrim(p_payload->>'invoiceType'));
    v_invoice_date:=(p_payload->>'invoiceDate')::date;
    v_term:=NULLIF(p_payload->>'paymentTermId','')::uuid;
  EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_PAYLOAD_INVALID'; END;
  IF v_type NOT IN('REGULAR','DOWN_PAYMENT') OR v_invoice_date IS NULL THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_PAYLOAD_INVALID';
  END IF;
  IF v_type='DOWN_PAYMENT' THEN
    BEGIN
      v_dp_mode:=upper(btrim(p_payload->>'downPaymentMode'));
      v_dp_input:=round((p_payload->>'downPaymentInput')::numeric,6);
    EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'DOWN_PAYMENT_INPUT_INVALID'; END;
    IF v_dp_mode NOT IN('PERCENT','FIXED') OR v_dp_input<=0
      OR (v_dp_mode='PERCENT' AND v_dp_input>100) THEN
      RAISE EXCEPTION 'DOWN_PAYMENT_INPUT_INVALID';
    END IF;
  END IF;
  IF v_term IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.backoffice_sales_payment_terms term
    WHERE term.company_id=v_company AND term.id=v_term AND term.is_active) THEN
    RAISE EXCEPTION 'PAYMENT_TERM_NOT_FOUND';
  END IF;

  IF p_invoice_id IS NOT NULL THEN
    SELECT * INTO v_invoice FROM public.backoffice_sales_invoices invoice
    WHERE invoice.company_id=v_company AND invoice.id=p_invoice_id FOR UPDATE;
    IF NOT FOUND OR v_invoice.sales_order_id<>p_sales_order_id THEN
      RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_NOT_FOUND';
    END IF;
    IF v_invoice.status<>'DRAFT' OR v_invoice.invoice_type<>v_type THEN
      RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_NOT_EDITABLE';
    END IF;
    IF p_expected_version IS NULL OR p_expected_version<>v_invoice.master_version THEN
      RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
    END IF;
    v_existing:=true;v_invoice_id:=v_invoice.id;v_sequence:=v_invoice.invoice_sequence;
    v_draft_no:=v_invoice.draft_no;
    v_before:=private.backoffice_sales_invoice_snapshot(v_company,v_invoice_id);
    UPDATE public.backoffice_sales_order_lines source SET
      draft_invoice_allocated_base_qty=source.draft_invoice_allocated_base_qty-allocation.allocated_base_qty
    FROM public.backoffice_sales_invoice_quantity_allocations allocation
    WHERE allocation.company_id=v_company AND allocation.invoice_id=v_invoice_id
      AND allocation.status='HELD' AND source.company_id=allocation.company_id
      AND source.id=allocation.sales_order_line_id;
    DELETE FROM public.backoffice_sales_invoice_receivable_schedules
      WHERE company_id=v_company AND invoice_id=v_invoice_id;
    DELETE FROM public.backoffice_sales_down_payment_applications
      WHERE company_id=v_company AND regular_invoice_id=v_invoice_id AND status='HELD';
    DELETE FROM public.backoffice_sales_invoice_quantity_allocations
      WHERE company_id=v_company AND invoice_id=v_invoice_id AND status='HELD';
    DELETE FROM public.backoffice_sales_invoice_lines
      WHERE company_id=v_company AND invoice_id=v_invoice_id;
  ELSE
    IF p_expected_version IS NOT NULL THEN RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
    v_invoice_id:=gen_random_uuid();
    SELECT COALESCE(max(invoice_sequence),0)+1 INTO v_sequence
    FROM public.backoffice_sales_invoices WHERE company_id=v_company
      AND sales_order_id=p_sales_order_id;
    v_draft_no:='DINV-'||to_char(v_invoice_date,'YYYYMMDD')||'-'||
      lpad(nextval('private.backoffice_sales_invoice_draft_no_seq')::text,10,'0');
    INSERT INTO public.backoffice_sales_invoices(id,company_id,sales_order_id,customer_id,
      store_id,warehouse_id,payment_term_id,draft_no,invoice_sequence,invoice_type,
      invoice_date,currency_code,customer_snapshot,payment_term_snapshot,commercial_snapshot,
      down_payment_mode,down_payment_input,created_by,updated_by)
    VALUES(v_invoice_id,v_company,p_sales_order_id,v_order.customer_id,v_order.store_id,
      v_order.warehouse_id,v_term,v_draft_no,v_sequence,v_type,v_invoice_date,
      v_order.currency_code,v_order.customer_snapshot,
      COALESCE((SELECT jsonb_build_object('id',term.id,'code',term.term_code,
        'name',term.term_name,'masterVersion',term.master_version)
        FROM public.backoffice_sales_payment_terms term
        WHERE term.company_id=v_company AND term.id=v_term),'{}'::jsonb),
      jsonb_build_object('calculationAuthority','CANONICAL_SERVER'),
      CASE WHEN v_type='DOWN_PAYMENT' THEN v_dp_mode END,
      CASE WHEN v_type='DOWN_PAYMENT' THEN v_dp_input END,v_actor,v_actor);
  END IF;

  IF v_type='REGULAR' THEN
    IF jsonb_typeof(p_payload->'lines')<>'array' OR jsonb_array_length(p_payload->'lines')=0 THEN
      RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_LINES_REQUIRED';
    END IF;
    FOR v_line_payload IN SELECT value FROM jsonb_array_elements(p_payload->'lines') LOOP
      BEGIN
        SELECT * INTO v_source FROM public.backoffice_sales_order_lines source
        WHERE source.company_id=v_company AND source.sales_order_id=p_sales_order_id
          AND source.id=(v_line_payload->>'salesOrderLineId')::uuid FOR UPDATE;
        v_qty_uom:=round((v_line_payload->>'quantityUom')::numeric,6);
        v_gross_unit:=round(COALESCE(NULLIF(v_line_payload->>'unitPrice','')::numeric,
          v_source.unit_price),4);
        v_discount:=round(COALESCE(NULLIF(v_line_payload->>'discountAmount','')::numeric,0),4);
        v_tax_enabled:=COALESCE(NULLIF(v_line_payload->>'taxApplied','')::boolean,
          v_source.tax_rule_id IS NOT NULL);
      EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_LINE_INVALID'; END;
      IF NOT FOUND OR v_qty_uom<=0 OR v_gross_unit<0 OR v_discount<0 THEN
        RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_LINE_INVALID';
      END IF;
      IF EXISTS(SELECT 1 FROM public.backoffice_sales_invoice_lines line
        WHERE line.company_id=v_company AND line.invoice_id=v_invoice_id
          AND line.sales_order_line_id=v_source.id) THEN
        RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_LINE_DUPLICATE';
      END IF;
      v_qty_base:=round(v_qty_uom*v_source.base_qty_per_uom,6);
      IF v_qty_base>v_source.to_invoice_base_qty THEN
        RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_QUANTITY_EXCEEDS_AVAILABLE';
      END IF;
      v_gross_net:=round(v_qty_uom*v_gross_unit-v_discount,4);
      IF v_gross_net<0 THEN RAISE EXCEPTION 'INVOICE_DISCOUNT_EXCEEDS_LINE_TOTAL'; END IF;
      v_tax:=0;v_dpp:=v_gross_net;
      IF v_tax_enabled THEN
        IF v_source.tax_rule_id IS NULL OR v_source.tax_rate_percent_snapshot IS NULL
          OR v_source.tax_price_mode_snapshot<>'INCLUSIVE' THEN
          RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_TAX_SOURCE_INVALID';
        END IF;
        v_tax_result:=private.calculate_tax_group(jsonb_build_array(
          jsonb_build_object('lineKey',v_source.id::text,'amount',v_gross_net)),
          v_source.tax_rate_percent_snapshot,'SALES',v_source.tax_price_mode_snapshot,
          v_source.tax_calculation_scope_snapshot);
        v_tax_line:=v_tax_result->'lines'->0;
        v_dpp:=round((v_tax_line->>'taxBase')::numeric,4);
        v_tax:=round((v_tax_line->>'taxAmount')::numeric,4);
      END IF;
      v_line_no:=v_line_no+1;v_line_id:=gen_random_uuid();
      INSERT INTO public.backoffice_sales_invoice_lines(id,company_id,invoice_id,
        sales_order_id,sales_order_line_id,line_no,line_type,effect_type,product_id,uom_id,
        quantity_uom,base_qty_per_uom,quantity_base,unit_price,discount_amount,tax_amount,
        line_amount,description,source_snapshot)
      VALUES(v_line_id,v_company,v_invoice_id,p_sales_order_id,v_source.id,v_line_no,
        'PRODUCT','CHARGE',v_source.product_id,v_source.uom_id,v_qty_uom,
        v_source.base_qty_per_uom,v_qty_base,
        CASE WHEN v_qty_uom=0 THEN 0 ELSE round((v_dpp+v_discount)/v_qty_uom,4) END,
        v_discount,v_tax,v_dpp,v_source.product_name_snapshot,
        jsonb_build_object('enteredGrossUnitPrice',v_gross_unit,'taxApplied',v_tax_enabled,
          'taxRuleId',v_source.tax_rule_id,'taxRuleVersion',v_source.tax_rule_version,
          'taxCode',v_source.tax_code_snapshot,'taxName',v_source.tax_name_snapshot,
          'taxRatePercent',v_source.tax_rate_percent_snapshot,
          'taxPriceMode',v_source.tax_price_mode_snapshot,
          'taxCalculationScope',v_source.tax_calculation_scope_snapshot,
          'taxAccountId',v_source.tax_account_id,'sourceOrderLineVersion',v_source.master_version));
      INSERT INTO public.backoffice_sales_invoice_quantity_allocations(company_id,invoice_id,
        invoice_line_id,sales_order_id,sales_order_line_id,allocated_base_qty)
      VALUES(v_company,v_invoice_id,v_line_id,p_sales_order_id,v_source.id,v_qty_base);
      UPDATE public.backoffice_sales_order_lines SET
        draft_invoice_allocated_base_qty=draft_invoice_allocated_base_qty+v_qty_base
      WHERE company_id=v_company AND id=v_source.id;
      v_charge:=v_charge+v_dpp+v_discount;
      v_discount_total:=v_discount_total+v_discount;v_tax_total:=v_tax_total+v_tax;
    END LOOP;
  ELSE
    SELECT round(COALESCE(sum(tax_base),0),4),round(COALESCE(sum(tax_amount),0),4)
    INTO v_order_dpp,v_order_tax FROM public.backoffice_sales_order_lines
    WHERE company_id=v_company AND sales_order_id=p_sales_order_id;
    IF v_order_dpp<=0 THEN RAISE EXCEPTION 'DOWN_PAYMENT_BASIS_NOT_POSITIVE'; END IF;
    SELECT round(COALESCE(sum(charge_total),0),4) INTO v_used_dp
    FROM public.backoffice_sales_invoices
    WHERE company_id=v_company AND sales_order_id=p_sales_order_id
      AND invoice_type='DOWN_PAYMENT' AND status IN('DRAFT','POSTED')
      AND id<>v_invoice_id;
    v_dp_basis:=CASE v_dp_mode WHEN 'PERCENT' THEN round(v_order_dpp*v_dp_input/100,4)
      ELSE round(v_dp_input,4) END;
    IF v_dp_basis<=0 OR v_used_dp+v_dp_basis>v_order_dpp THEN
      RAISE EXCEPTION 'DOWN_PAYMENT_EXCEEDS_ORDER_DPP';
    END IF;
    v_tax_total:=round(v_order_tax*v_dp_basis/v_order_dpp,4);
    v_charge:=v_dp_basis;
    v_line_no:=1;
    INSERT INTO public.backoffice_sales_invoice_lines(company_id,invoice_id,sales_order_id,
      line_no,line_type,effect_type,unit_price,tax_amount,line_amount,description,source_snapshot)
    VALUES(v_company,v_invoice_id,p_sales_order_id,1,'DOWN_PAYMENT','CHARGE',v_dp_basis,
      v_tax_total,v_dp_basis,'Uang muka '||v_dp_input||CASE WHEN v_dp_mode='PERCENT' THEN '%' ELSE '' END,
      jsonb_build_object('calculation','DPP_PLUS_PROPORTIONAL_TAX','orderDpp',v_order_dpp,
        'orderTax',v_order_tax,'basisAmount',v_dp_basis,'taxAmount',v_tax_total));
  END IF;

  UPDATE public.backoffice_sales_invoices SET payment_term_id=v_term,
      payment_term_snapshot=COALESCE((SELECT jsonb_build_object('id',term.id,
        'code',term.term_code,'name',term.term_name,'masterVersion',term.master_version)
        FROM public.backoffice_sales_payment_terms term
        WHERE term.company_id=v_company AND term.id=v_term),'{}'::jsonb),
      invoice_date=v_invoice_date,notes=NULLIF(btrim(p_payload->>'notes'),''),
      down_payment_mode=CASE WHEN v_type='DOWN_PAYMENT' THEN v_dp_mode END,
      down_payment_input=CASE WHEN v_type='DOWN_PAYMENT' THEN v_dp_input END,
      down_payment_basis_total=CASE WHEN v_type='DOWN_PAYMENT' THEN v_order_dpp ELSE 0 END,
      charge_total=v_charge,discount_total=v_discount_total,tax_total=v_tax_total,
      down_payment_deduction_total=0,
      grand_total=v_charge-v_discount_total+v_tax_total,
      commercial_snapshot=jsonb_build_object('calculationAuthority','CANONICAL_SERVER',
        'taxMode','INCLUSIVE_SNAPSHOT','dpCalculation','DPP_PLUS_PROPORTIONAL_TAX'),
      master_version=master_version+CASE WHEN v_existing THEN 1 ELSE 0 END,
      updated_by=v_actor,updated_at=clock_timestamp()
    WHERE company_id=v_company AND id=v_invoice_id;
  PERFORM private.rebuild_backoffice_sales_invoice_schedules(v_company,v_invoice_id,v_actor);
  v_after:=private.backoffice_sales_invoice_snapshot(v_company,v_invoice_id);
  v_response:=jsonb_build_object('companyId',v_company,'data',v_after,'exactRetry',false);
  INSERT INTO public.backoffice_sales_invoice_operations(company_id,operation_id,
    operation_type,invoice_id,expected_version,request_hash,response_snapshot,actor_id)
  VALUES(v_company,p_operation_id,v_request_type,v_invoice_id,p_expected_version,v_hash,v_response,v_actor);
  INSERT INTO public.backoffice_sales_invoice_audit(company_id,invoice_id,action,
    operation_id,actor_id,before_state,after_state)
  VALUES(v_company,v_invoice_id,CASE WHEN v_existing THEN 'UPDATE_DRAFT' ELSE 'CREATE_DRAFT' END,
    p_operation_id,v_actor,v_before,v_after);
  RETURN v_response;
END
$$;

CREATE FUNCTION public.save_backoffice_sales_invoice_draft(
  p_invoice_id uuid,p_expected_version bigint,p_operation_id uuid,
  p_sales_order_id uuid,p_payload jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='8s' AS $$
DECLARE v_company uuid:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(v_company,'sales.backoffice_orders',
    CASE WHEN p_invoice_id IS NULL THEN 'CREATE_DRAFT' ELSE 'EDIT_DRAFT' END);
  RETURN private.save_backoffice_sales_invoice_draft_core(p_invoice_id,p_expected_version,
    p_operation_id,p_sales_order_id,p_payload);
END
$$;

CREATE FUNCTION public.cancel_backoffice_sales_invoice_draft(
  p_invoice_id uuid,p_expected_version bigint,p_operation_id uuid,p_reason text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='8s' AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
  v_invoice public.backoffice_sales_invoices%rowtype;v_hash text;v_retry jsonb;
  v_before jsonb;v_after jsonb;v_response jsonb;
BEGIN
  PERFORM private.acp_require_permission_capability(v_company,'sales.backoffice_orders','MANAGE');
  IF p_invoice_id IS NULL OR p_expected_version IS NULL OR p_operation_id IS NULL
    OR NULLIF(btrim(p_reason),'') IS NULL THEN RAISE EXCEPTION 'CANCEL_REASON_REQUIRED'; END IF;
  v_hash:=encode(extensions.digest(convert_to(jsonb_build_object('invoiceId',p_invoice_id,
    'expectedVersion',p_expected_version,'reason',btrim(p_reason))::text,'UTF8'),'sha256'),'hex');
  PERFORM pg_advisory_xact_lock(hashtextextended(
    v_company::text||':BACKOFFICE_INVOICE:'||p_operation_id::text,0));
  v_retry:=private.backoffice_sales_invoice_operation_retry(
    v_company,p_operation_id,'CANCEL_DRAFT',v_hash);
  IF v_retry IS NOT NULL THEN RETURN v_retry; END IF;
  SELECT * INTO v_invoice FROM public.backoffice_sales_invoices invoice
  WHERE invoice.company_id=v_company AND invoice.id=p_invoice_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_NOT_FOUND'; END IF;
  IF v_invoice.status<>'DRAFT' THEN RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_NOT_CANCELABLE'; END IF;
  IF v_invoice.master_version<>p_expected_version THEN RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
  PERFORM 1 FROM public.backoffice_sales_order_lines line
  WHERE line.company_id=v_company AND line.sales_order_id=v_invoice.sales_order_id
  ORDER BY line.line_no FOR UPDATE;
  v_before:=private.backoffice_sales_invoice_snapshot(v_company,p_invoice_id);
  UPDATE public.backoffice_sales_order_lines source SET
    draft_invoice_allocated_base_qty=source.draft_invoice_allocated_base_qty-allocation.allocated_base_qty
  FROM public.backoffice_sales_invoice_quantity_allocations allocation
  WHERE allocation.company_id=v_company AND allocation.invoice_id=p_invoice_id
    AND allocation.status='HELD' AND source.company_id=allocation.company_id
    AND source.id=allocation.sales_order_line_id;
  UPDATE public.backoffice_sales_invoice_quantity_allocations SET status='RELEASED',
    released_reason='DRAFT_CANCELED',updated_at=clock_timestamp()
  WHERE company_id=v_company AND invoice_id=p_invoice_id AND status='HELD';
  UPDATE public.backoffice_sales_down_payment_applications SET status='RELEASED',
    released_reason='DRAFT_CANCELED',updated_at=clock_timestamp()
  WHERE company_id=v_company AND regular_invoice_id=p_invoice_id AND status='HELD';
  UPDATE public.backoffice_sales_invoice_receivable_schedules SET status='CANCELED',
    updated_at=clock_timestamp()
  WHERE company_id=v_company AND invoice_id=p_invoice_id AND status='DRAFT';
  UPDATE public.backoffice_sales_invoices SET status='CANCELED',canceled_by=v_actor,
    canceled_at=clock_timestamp(),cancel_reason=btrim(p_reason),master_version=master_version+1,
    updated_by=v_actor,updated_at=clock_timestamp()
  WHERE company_id=v_company AND id=p_invoice_id;
  v_after:=private.backoffice_sales_invoice_snapshot(v_company,p_invoice_id);
  v_response:=jsonb_build_object('companyId',v_company,'data',v_after,'exactRetry',false);
  INSERT INTO public.backoffice_sales_invoice_operations(company_id,operation_id,operation_type,
    invoice_id,expected_version,request_hash,response_snapshot,actor_id)
  VALUES(v_company,p_operation_id,'CANCEL_DRAFT',p_invoice_id,p_expected_version,v_hash,v_response,v_actor);
  INSERT INTO public.backoffice_sales_invoice_audit(company_id,invoice_id,action,operation_id,
    actor_id,reason,before_state,after_state)
  VALUES(v_company,p_invoice_id,'CANCEL_DRAFT',p_operation_id,v_actor,btrim(p_reason),v_before,v_after);
  RETURN v_response;
END
$$;

CREATE FUNCTION public.get_backoffice_sales_invoice(p_invoice_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='8s' AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_data jsonb;
BEGIN
  PERFORM private.acp_require_permission_capability(v_company,'sales.backoffice_orders','VIEW');
  v_data:=private.backoffice_sales_invoice_snapshot(v_company,p_invoice_id);
  IF v_data IS NULL THEN RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_NOT_FOUND'; END IF;
  RETURN jsonb_build_object('companyId',v_company,'data',v_data);
END
$$;

REVOKE ALL ON FUNCTION private.backoffice_sales_invoice_snapshot(uuid,uuid),
  private.backoffice_sales_invoice_operation_retry(uuid,uuid,text,text),
  private.backoffice_sales_invoice_due_date(date,text,integer,integer),
  private.rebuild_backoffice_sales_invoice_schedules(uuid,uuid,uuid),
  private.save_backoffice_sales_invoice_draft_core(uuid,bigint,uuid,uuid,jsonb)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.backoffice_sales_invoice_snapshot(uuid,uuid),
  private.backoffice_sales_invoice_operation_retry(uuid,uuid,text,text),
  private.backoffice_sales_invoice_due_date(date,text,integer,integer),
  private.rebuild_backoffice_sales_invoice_schedules(uuid,uuid,uuid),
  private.save_backoffice_sales_invoice_draft_core(uuid,bigint,uuid,uuid,jsonb)
  TO service_role;
REVOKE ALL ON FUNCTION public.save_backoffice_sales_invoice_draft(uuid,bigint,uuid,uuid,jsonb),
  public.cancel_backoffice_sales_invoice_draft(uuid,bigint,uuid,text),
  public.get_backoffice_sales_invoice(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.save_backoffice_sales_invoice_draft(uuid,bigint,uuid,uuid,jsonb),
  public.cancel_backoffice_sales_invoice_draft(uuid,bigint,uuid,text),
  public.get_backoffice_sales_invoice(uuid) TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260909157000','backoffice_sales_invoice_draft_runtime',
  'Transactional exact-retry Draft Regular/DP Invoice runtime; regular quantity holds, DPP plus proportional DP tax, Draft receivable schedules, stale-version/cross-tenant guards and cancel release; no Finance posting, AR, Payment, Stock, FIFO or POS effect');

NOTIFY pgrst,'reload schema';
COMMIT;
