-- Backoffice AR Task 6: atomic native Credit Note post, source residual
-- reconciliation, and editable replacement Invoice Draft.
-- Production rollout is separately gated; this migration is developed and
-- verified against the production-shaped local Supabase database first.
BEGIN;

DO $guard$
BEGIN
  IF (SELECT count(*) FROM private.kgs_schema_migrations
      WHERE version IN('20261105100000','20261105110000','20261105120000',
        '20261106100000'))<>4 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: AR Tasks 2-5 required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20261110100000')
    OR to_regprocedure(
      'public.post_backoffice_credit_note_create_replacement_invoice(uuid,bigint,uuid)')
      IS NOT NULL
    OR EXISTS(SELECT 1 FROM information_schema.columns
      WHERE table_schema='public' AND table_name='backoffice_sales_invoices'
        AND column_name IN('replacement_credit_note_id','replacement_source_invoice_id')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Task 6 already or partially installed';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
    WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
  IF md5(pg_get_functiondef(
      'public.save_backoffice_sales_invoice_draft(uuid,bigint,uuid,uuid,jsonb)'::regprocedure))
        <>'91a423d2fb08901b7596f3b048c84cd2'
    OR md5(pg_get_functiondef(
      'private.ar3_post_backoffice_sales_invoice_core(uuid,bigint,uuid)'::regprocedure))
        <>'c874b7d081b9781004eaf42522bda1d0'
    OR md5(pg_get_functiondef(
      'private.post_backoffice_sales_credit_note_before_retained(uuid,bigint,uuid)'::regprocedure))
        <>'3ce005460e7e50ec4b9d9134e5e4a928'
    OR md5(pg_get_functiondef(
      'public.post_backoffice_sales_credit_note(uuid,bigint,uuid)'::regprocedure))
        <>'93723ceab34fd6318088f314e976dd72'
    OR md5(pg_get_functiondef(
      'public.apply_backoffice_ar_open_credit(uuid,jsonb,date,numeric,uuid)'::regprocedure))
        <>'1f3eb44dda2997282789da828e31fa81' THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Task 6 runtime anchor changed';
  END IF;
END
$guard$;

ALTER TABLE public.backoffice_sales_invoices
  ADD COLUMN replacement_credit_note_id uuid,
  ADD COLUMN replacement_source_invoice_id uuid,
  ADD CONSTRAINT backoffice_sales_invoices_replacement_note_fk
    FOREIGN KEY(company_id,replacement_credit_note_id)
    REFERENCES public.backoffice_sales_credit_notes(company_id,id) ON DELETE RESTRICT,
  ADD CONSTRAINT backoffice_sales_invoices_replacement_source_fk
    FOREIGN KEY(company_id,replacement_source_invoice_id)
    REFERENCES public.backoffice_sales_invoices(company_id,id) ON DELETE RESTRICT,
  ADD CONSTRAINT backoffice_sales_invoices_replacement_shape CHECK(
    (replacement_credit_note_id IS NULL AND replacement_source_invoice_id IS NULL)
    OR (replacement_credit_note_id IS NOT NULL
      AND replacement_source_invoice_id IS NOT NULL
      AND invoice_type='REGULAR'));

CREATE UNIQUE INDEX backoffice_sales_invoices_replacement_note_unique
  ON public.backoffice_sales_invoices(company_id,replacement_credit_note_id)
  WHERE replacement_credit_note_id IS NOT NULL;

ALTER TABLE public.backoffice_sales_invoice_lines
  ADD COLUMN replacement_source_invoice_line_id uuid,
  ADD CONSTRAINT backoffice_sales_invoice_lines_replacement_source_fk
    FOREIGN KEY(company_id,replacement_source_invoice_line_id)
    REFERENCES public.backoffice_sales_invoice_lines(company_id,id) ON DELETE RESTRICT;

ALTER TABLE public.backoffice_sales_invoice_lines
  DROP CONSTRAINT bo_sales_invoice_lines_source_check,
  ADD CONSTRAINT bo_sales_invoice_lines_source_check CHECK(
    ((source_kind='SALES_ORDER' AND discrepancy_line_id IS NULL
        AND replacement_source_invoice_line_id IS NULL)
      OR (source_kind='ACCEPTED_OVERAGE' AND discrepancy_line_id IS NOT NULL
        AND replacement_source_invoice_line_id IS NULL
        AND line_type='PRODUCT' AND effect_type='CHARGE')
      OR (source_kind='CREDIT_NOTE_REPLACEMENT'
        AND discrepancy_line_id IS NULL
        AND replacement_source_invoice_line_id IS NOT NULL
        AND line_type='PRODUCT' AND effect_type='CHARGE')));

ALTER TABLE public.ar_open_item_operations
  DROP CONSTRAINT ar_open_item_operations_shape,
  ADD CONSTRAINT ar_open_item_operations_shape CHECK(
    operation_kind IN('BACKFILL_RECEIPT','BACKFILL_CREDIT_NOTE',
      'BACKFILL_PRICE_CORRECTION','POST_RECEIPT','APPLY_CREDIT','REFUND_CREDIT',
      'CONVERT_CREDIT_BALANCE','APPLY_CUSTOMER_BALANCE',
      'REVERSE_OPEN_CREDIT_ACTION','POST_CREDIT_CREATE_REPLACEMENT')
    AND nullif(btrim(idempotency_key),'') IS NOT NULL
    AND request_hash~'^[0-9a-f]{32}$'
    AND jsonb_typeof(operation_snapshot)='object');

CREATE FUNCTION private.create_backoffice_replacement_invoice_draft(
  p_company_id uuid,p_credit_note_id uuid,p_actor_id uuid,p_operation_id uuid
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_note public.backoffice_sales_credit_notes%rowtype;
  v_source public.backoffice_sales_invoices%rowtype;
  v_order public.backoffice_sales_orders%rowtype;v_source_line record;
  v_invoice_id uuid:=gen_random_uuid();v_line_id uuid;v_sequence integer;
  v_draft_no text;v_line_no integer:=0;v_charge numeric(24,4):=0;
  v_discount numeric(24,4):=0;v_tax numeric(24,4):=0;v_due date;
  v_invoice_date date;v_after jsonb;v_hash text;
BEGIN
  SELECT * INTO STRICT v_note FROM public.backoffice_sales_credit_notes note
  WHERE note.company_id=p_company_id AND note.id=p_credit_note_id
    AND note.source_kind='BACKOFFICE' AND note.status='POSTED' FOR SHARE;
  SELECT * INTO STRICT v_source FROM public.backoffice_sales_invoices invoice
  WHERE invoice.company_id=p_company_id AND invoice.id=v_note.source_invoice_id
    AND invoice.status='POSTED' AND invoice.invoice_type='REGULAR' FOR SHARE;
  SELECT * INTO STRICT v_order FROM public.backoffice_sales_orders document
  WHERE document.company_id=p_company_id AND document.id=v_source.sales_order_id
    AND document.sales_process_mode='BACKOFFICE_DELIVERED_QTY_INVOICE' FOR SHARE;
  IF v_note.customer_id<>v_source.customer_id THEN
    RAISE EXCEPTION 'BACKOFFICE_REPLACEMENT_CUSTOMER_INVALID';
  END IF;
  IF EXISTS(SELECT 1 FROM public.backoffice_sales_invoices invoice
    WHERE invoice.company_id=p_company_id
      AND invoice.replacement_credit_note_id=p_credit_note_id) THEN
    RAISE EXCEPTION 'BACKOFFICE_REPLACEMENT_ALREADY_EXISTS';
  END IF;
  v_invoice_date:=v_note.credit_note_date;
  SELECT COALESCE(max(invoice.invoice_sequence),0)+1 INTO v_sequence
  FROM public.backoffice_sales_invoices invoice
  WHERE invoice.company_id=p_company_id AND invoice.sales_order_id=v_source.sales_order_id;
  v_draft_no:='DINV-'||to_char(v_invoice_date,'YYYYMMDD')||'-'||
    lpad(nextval('private.backoffice_sales_invoice_draft_no_seq')::text,10,'0');
  INSERT INTO public.backoffice_sales_invoices(id,company_id,sales_order_id,customer_id,
    store_id,warehouse_id,payment_term_id,draft_no,invoice_sequence,invoice_type,
    invoice_date,currency_code,customer_snapshot,payment_term_snapshot,
    commercial_snapshot,delivery_fee_amount,notes,replacement_credit_note_id,
    replacement_source_invoice_id,created_by,updated_by)
  VALUES(v_invoice_id,p_company_id,v_source.sales_order_id,v_source.customer_id,
    v_source.store_id,v_source.warehouse_id,v_source.payment_term_id,v_draft_no,
    v_sequence,'REGULAR',v_invoice_date,v_source.currency_code,v_source.customer_snapshot,
    v_source.payment_term_snapshot,v_source.commercial_snapshot||jsonb_build_object(
      'replacementCreditNoteId',v_note.id,'replacementSourceInvoiceId',v_source.id,
      'settlementHistoryCopied',false,'calculationAuthority','CANONICAL_SERVER'),
    v_source.delivery_fee_amount,'Invoice pengganti untuk '||v_source.invoice_no,
    v_note.id,v_source.id,p_actor_id,p_actor_id);
  FOR v_source_line IN
    SELECT line.*,private.backoffice_invoice_effective_line_amounts(
      p_company_id,line.id) effective
    FROM public.backoffice_sales_invoice_lines line
    WHERE line.company_id=p_company_id AND line.invoice_id=v_source.id
      AND line.line_type='PRODUCT' AND line.effect_type='CHARGE'
    ORDER BY line.line_no
  LOOP
    v_line_no:=v_line_no+1;v_line_id:=gen_random_uuid();
    INSERT INTO public.backoffice_sales_invoice_lines(id,company_id,invoice_id,
      sales_order_id,sales_order_line_id,line_no,line_type,effect_type,product_id,uom_id,
      quantity_uom,base_qty_per_uom,quantity_base,unit_price,discount_amount,tax_amount,
      line_amount,description,source_snapshot,source_kind,replacement_source_invoice_line_id)
    VALUES(v_line_id,p_company_id,v_invoice_id,v_source.sales_order_id,
      v_source_line.sales_order_line_id,v_line_no,'PRODUCT','CHARGE',
      v_source_line.product_id,v_source_line.uom_id,v_source_line.quantity_uom,
      v_source_line.base_qty_per_uom,v_source_line.quantity_base,
      round(((v_source_line.effective->>'lineAmount')::numeric
        +(v_source_line.effective->>'discountAmount')::numeric)
        /v_source_line.quantity_uom,4),
      (v_source_line.effective->>'discountAmount')::numeric,
      (v_source_line.effective->>'taxAmount')::numeric,
      (v_source_line.effective->>'lineAmount')::numeric,v_source_line.description,
      v_source_line.source_snapshot||jsonb_build_object(
        'replacementCreditNoteId',v_note.id,'replacementSourceInvoiceId',v_source.id,
        'replacementSourceInvoiceLineId',v_source_line.id),
      'CREDIT_NOTE_REPLACEMENT',v_source_line.id);
    v_charge:=v_charge+(v_source_line.effective->>'lineAmount')::numeric
      +(v_source_line.effective->>'discountAmount')::numeric;
    v_discount:=v_discount+(v_source_line.effective->>'discountAmount')::numeric;
    v_tax:=v_tax+(v_source_line.effective->>'taxAmount')::numeric;
  END LOOP;
  IF v_line_no=0 THEN RAISE EXCEPTION 'BACKOFFICE_REPLACEMENT_LINES_REQUIRED'; END IF;
  UPDATE public.backoffice_sales_invoices SET charge_total=round(v_charge,4),
    discount_total=round(v_discount,4),tax_total=round(v_tax,4),
    down_payment_deduction_total=0,
    grand_total=round(v_charge-v_discount+v_tax+delivery_fee_amount,4),
    updated_at=clock_timestamp()
  WHERE company_id=p_company_id AND id=v_invoice_id;
  SELECT greatest(v_invoice_date,v_invoice_date+
    COALESCE(min(schedule.due_date)-v_source.invoice_date,0)) INTO v_due
  FROM public.backoffice_sales_invoice_receivable_schedules schedule
  WHERE schedule.company_id=p_company_id AND schedule.invoice_id=v_source.id;
  IF v_source.payment_term_id IS NULL THEN
    PERFORM set_config('kgs.backoffice_invoice_due_date',v_due::text,true);
  END IF;
  PERFORM private.rebuild_backoffice_sales_invoice_schedules(
    p_company_id,v_invoice_id,p_actor_id);
  PERFORM set_config('kgs.backoffice_invoice_due_date','',true);
  v_after:=private.backoffice_sales_invoice_snapshot(p_company_id,v_invoice_id);
  v_hash:=encode(extensions.digest(convert_to(jsonb_build_object(
    'creditNoteId',p_credit_note_id,'sourceInvoiceId',v_source.id)::text,
    'UTF8'),'sha256'),'hex');
  INSERT INTO public.backoffice_sales_invoice_operations(company_id,operation_id,
    operation_type,invoice_id,request_hash,response_snapshot,actor_id)
  VALUES(p_company_id,p_operation_id,'SAVE_DRAFT',v_invoice_id,v_hash,
    jsonb_build_object('data',v_after,'replacementCreditNoteId',p_credit_note_id),
    p_actor_id);
  INSERT INTO public.backoffice_sales_invoice_audit(company_id,invoice_id,action,
    operation_id,actor_id,reason,after_state)
  VALUES(p_company_id,v_invoice_id,'CREATE_DRAFT',p_operation_id,p_actor_id,
    'Invoice pengganti dari Credit Note '||v_note.credit_note_no,v_after);
  RETURN v_invoice_id;
EXCEPTION WHEN OTHERS THEN
  PERFORM set_config('kgs.backoffice_invoice_due_date','',true);
  RAISE;
END
$$;

CREATE FUNCTION private.save_backoffice_replacement_invoice_draft_core(
  p_invoice_id uuid,p_expected_version bigint,p_operation_id uuid,
  p_sales_order_id uuid,p_payload jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
  v_invoice public.backoffice_sales_invoices%rowtype;
  v_source public.backoffice_sales_invoices%rowtype;v_payload jsonb;v_source_line record;
  v_before jsonb;v_after jsonb;v_response jsonb;v_retry jsonb;v_hash text;
  v_invoice_date date;v_qty numeric;v_price numeric;v_discount numeric;
  v_gross numeric;v_tax_enabled boolean;v_tax_result jsonb;v_tax_line jsonb;
  v_tax numeric;v_dpp numeric;v_charge numeric:=0;v_discount_total numeric:=0;
  v_tax_total numeric:=0;v_fee numeric;v_line_no integer:=0;
BEGIN
  IF v_company IS NULL OR v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF p_invoice_id IS NULL OR p_expected_version IS NULL OR p_operation_id IS NULL
    OR p_sales_order_id IS NULL OR jsonb_typeof(p_payload)<>'object'
    OR jsonb_typeof(p_payload->'lines')<>'array'
    OR jsonb_array_length(p_payload->'lines')=0 THEN
    RAISE EXCEPTION 'BACKOFFICE_REPLACEMENT_PAYLOAD_INVALID';
  END IF;
  v_hash:=encode(extensions.digest(convert_to(jsonb_build_object('invoiceId',p_invoice_id,
    'expectedVersion',p_expected_version,'salesOrderId',p_sales_order_id,
    'payload',p_payload)::text,'UTF8'),'sha256'),'hex');
  PERFORM pg_advisory_xact_lock(hashtextextended(
    v_company::text||':BACKOFFICE_INVOICE:'||p_operation_id::text,0));
  v_retry:=private.backoffice_sales_invoice_operation_retry(
    v_company,p_operation_id,'SAVE_DRAFT',v_hash);
  IF v_retry IS NOT NULL THEN RETURN v_retry; END IF;
  SELECT * INTO v_invoice FROM public.backoffice_sales_invoices invoice
  WHERE invoice.company_id=v_company AND invoice.id=p_invoice_id FOR UPDATE;
  IF NOT FOUND OR v_invoice.status<>'DRAFT'
    OR v_invoice.replacement_credit_note_id IS NULL
    OR v_invoice.sales_order_id<>p_sales_order_id THEN
    RAISE EXCEPTION 'BACKOFFICE_REPLACEMENT_DRAFT_NOT_FOUND';
  END IF;
  IF v_invoice.master_version<>p_expected_version THEN RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
  SELECT * INTO STRICT v_source FROM public.backoffice_sales_invoices invoice
  WHERE invoice.company_id=v_company AND invoice.id=v_invoice.replacement_source_invoice_id
    AND invoice.status='POSTED' FOR SHARE;
  BEGIN
    v_invoice_date:=(p_payload->>'invoiceDate')::date;
    v_fee:=round(COALESCE(NULLIF(p_payload->>'deliveryFeeAmount','')::numeric,0),4);
  EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'BACKOFFICE_REPLACEMENT_PAYLOAD_INVALID'; END;
  IF v_invoice_date IS NULL OR v_fee<0 OR v_fee>v_source.delivery_fee_amount THEN
    RAISE EXCEPTION 'BACKOFFICE_REPLACEMENT_PAYLOAD_INVALID';
  END IF;
  v_before:=private.backoffice_sales_invoice_snapshot(v_company,v_invoice.id);
  DELETE FROM public.backoffice_sales_invoice_lines line
  WHERE line.company_id=v_company AND line.invoice_id=v_invoice.id;
  FOR v_payload IN SELECT value FROM jsonb_array_elements(p_payload->'lines') LOOP
    BEGIN
      SELECT line.*,source.tax_rule_id,source.tax_rule_version,
        source.tax_rate_percent_snapshot,source.tax_price_mode_snapshot,
        source.tax_calculation_scope_snapshot,source.tax_account_id
      INTO STRICT v_source_line
      FROM public.backoffice_sales_invoice_lines line
      JOIN public.backoffice_sales_order_lines source
        ON source.company_id=line.company_id AND source.id=line.sales_order_line_id
      WHERE line.company_id=v_company AND line.invoice_id=v_source.id
        AND line.id=(v_payload->>'replacementSourceInvoiceLineId')::uuid
        AND line.line_type='PRODUCT' AND line.effect_type='CHARGE';
      v_qty:=round((v_payload->>'quantityUom')::numeric,6);
      v_price:=round((v_payload->>'unitPrice')::numeric,4);
      v_discount:=round(COALESCE(NULLIF(v_payload->>'discountAmount','')::numeric,0),4);
      v_tax_enabled:=COALESCE(NULLIF(v_payload->>'taxApplied','')::boolean,
        v_source_line.tax_rule_id IS NOT NULL);
    EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'BACKOFFICE_REPLACEMENT_LINE_INVALID'; END;
    IF v_qty<=0 OR v_qty>v_source_line.quantity_uom OR v_price<0 OR v_discount<0 THEN
      RAISE EXCEPTION 'BACKOFFICE_REPLACEMENT_LINE_INVALID';
    END IF;
    IF EXISTS(SELECT 1 FROM public.backoffice_sales_invoice_lines line
      WHERE line.company_id=v_company AND line.invoice_id=v_invoice.id
        AND line.replacement_source_invoice_line_id=v_source_line.id) THEN
      RAISE EXCEPTION 'BACKOFFICE_REPLACEMENT_LINE_DUPLICATE';
    END IF;
    v_gross:=round(v_qty*v_price-v_discount,4);
    IF v_gross<0 THEN RAISE EXCEPTION 'INVOICE_DISCOUNT_EXCEEDS_LINE_TOTAL'; END IF;
    v_tax:=0;v_dpp:=v_gross;
    IF v_tax_enabled THEN
      IF v_source_line.tax_rule_id IS NULL OR v_source_line.tax_rate_percent_snapshot IS NULL
        OR v_source_line.tax_price_mode_snapshot<>'INCLUSIVE' THEN
        RAISE EXCEPTION 'BACKOFFICE_REPLACEMENT_TAX_SOURCE_INVALID';
      END IF;
      v_tax_result:=private.calculate_tax_group(jsonb_build_array(jsonb_build_object(
        'lineKey',v_source_line.id::text,'amount',v_gross)),
        v_source_line.tax_rate_percent_snapshot,'SALES',
        v_source_line.tax_price_mode_snapshot,v_source_line.tax_calculation_scope_snapshot);
      v_tax_line:=v_tax_result->'lines'->0;
      v_dpp:=round((v_tax_line->>'taxBase')::numeric,4);
      v_tax:=round((v_tax_line->>'taxAmount')::numeric,4);
    END IF;
    v_line_no:=v_line_no+1;
    INSERT INTO public.backoffice_sales_invoice_lines(company_id,invoice_id,sales_order_id,
      sales_order_line_id,line_no,line_type,effect_type,product_id,uom_id,quantity_uom,
      base_qty_per_uom,quantity_base,unit_price,discount_amount,tax_amount,line_amount,
      description,source_snapshot,source_kind,replacement_source_invoice_line_id)
    VALUES(v_company,v_invoice.id,v_invoice.sales_order_id,v_source_line.sales_order_line_id,
      v_line_no,'PRODUCT','CHARGE',v_source_line.product_id,v_source_line.uom_id,v_qty,
      v_source_line.base_qty_per_uom,round(v_qty*v_source_line.base_qty_per_uom,6),
      CASE WHEN v_qty=0 THEN 0 ELSE round((v_dpp+v_discount)/v_qty,4) END,
      v_discount,v_tax,v_dpp,v_source_line.description,
      v_source_line.source_snapshot||jsonb_build_object(
        'replacementCreditNoteId',v_invoice.replacement_credit_note_id,
        'replacementSourceInvoiceId',v_source.id,
        'replacementSourceInvoiceLineId',v_source_line.id,
        'enteredGrossUnitPrice',v_price,'taxApplied',v_tax_enabled),
      'CREDIT_NOTE_REPLACEMENT',v_source_line.id);
    v_charge:=v_charge+v_dpp+v_discount;v_discount_total:=v_discount_total+v_discount;
    v_tax_total:=v_tax_total+v_tax;
  END LOOP;
  UPDATE public.backoffice_sales_invoices SET invoice_date=v_invoice_date,
    delivery_fee_amount=v_fee,notes=NULLIF(btrim(p_payload->>'notes'),''),
    charge_total=round(v_charge,4),discount_total=round(v_discount_total,4),
    tax_total=round(v_tax_total,4),down_payment_deduction_total=0,
    grand_total=round(v_charge-v_discount_total+v_tax_total+v_fee,4),
    master_version=master_version+1,updated_by=v_actor,updated_at=clock_timestamp()
  WHERE company_id=v_company AND id=v_invoice.id;
  DELETE FROM public.backoffice_sales_invoice_receivable_schedules
  WHERE company_id=v_company AND invoice_id=v_invoice.id;
  PERFORM private.rebuild_backoffice_sales_invoice_schedules(v_company,v_invoice.id,v_actor);
  v_after:=private.backoffice_sales_invoice_snapshot(v_company,v_invoice.id);
  v_response:=jsonb_build_object('companyId',v_company,'data',v_after,
    'replacementCreditNoteId',v_invoice.replacement_credit_note_id,'exactRetry',false);
  INSERT INTO public.backoffice_sales_invoice_operations(company_id,operation_id,
    operation_type,invoice_id,expected_version,request_hash,response_snapshot,actor_id)
  VALUES(v_company,p_operation_id,'SAVE_DRAFT',v_invoice.id,p_expected_version,
    v_hash,v_response,v_actor);
  INSERT INTO public.backoffice_sales_invoice_audit(company_id,invoice_id,action,
    operation_id,actor_id,before_state,after_state)
  VALUES(v_company,v_invoice.id,'UPDATE_DRAFT',p_operation_id,v_actor,v_before,v_after);
  RETURN v_response;
END
$$;

ALTER FUNCTION public.save_backoffice_sales_invoice_draft(uuid,bigint,uuid,uuid,jsonb)
  SET SCHEMA private;
ALTER FUNCTION private.save_backoffice_sales_invoice_draft(uuid,bigint,uuid,uuid,jsonb)
  RENAME TO save_backoffice_sales_invoice_draft_before_replacement;

CREATE FUNCTION public.save_backoffice_sales_invoice_draft(
  p_invoice_id uuid,p_expected_version bigint,p_operation_id uuid,
  p_sales_order_id uuid,p_payload jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='12s' AS $$
DECLARE v_company uuid:=public.private_active_company_id();
BEGIN
  IF p_invoice_id IS NOT NULL AND EXISTS(SELECT 1
    FROM public.backoffice_sales_invoices invoice
    WHERE invoice.company_id=v_company AND invoice.id=p_invoice_id
      AND invoice.replacement_credit_note_id IS NOT NULL) THEN
    PERFORM private.acp_require_permission_capability(
      v_company,'sales.backoffice_orders','EDIT_DRAFT');
    RETURN private.save_backoffice_replacement_invoice_draft_core(
      p_invoice_id,p_expected_version,p_operation_id,p_sales_order_id,p_payload);
  END IF;
  RETURN private.save_backoffice_sales_invoice_draft_before_replacement(
    p_invoice_id,p_expected_version,p_operation_id,p_sales_order_id,p_payload);
END
$$;

DO $patch_post$
DECLARE v_definition text;v_old text:='IF v_invoice.invoice_type=''REGULAR'' THEN';
  v_new text:='IF v_invoice.invoice_type=''REGULAR'' AND v_invoice.replacement_credit_note_id IS NULL THEN';
  v_count integer;
BEGIN
  SELECT pg_get_functiondef(
    'private.ar3_post_backoffice_sales_invoice_core(uuid,bigint,uuid)'::regprocedure)
  INTO STRICT v_definition;
  v_count:=(length(v_definition)-length(replace(v_definition,v_old,'')))/length(v_old);
  IF v_count<>2 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Invoice post regular anchors %',v_count;
  END IF;
  EXECUTE replace(v_definition,v_old,v_new);
END
$patch_post$;

CREATE FUNCTION public.post_backoffice_credit_note_create_replacement_invoice(
  p_credit_note_id uuid,p_expected_version bigint,p_operation_id uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='30s' AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
  v_note public.backoffice_sales_credit_notes%rowtype;
  v_source public.backoffice_sales_invoices%rowtype;
  v_credit public.ar_open_item_registry%rowtype;v_debit public.ar_open_item_registry%rowtype;
  v_hash text;v_retry jsonb;v_post jsonb;v_apply jsonb;v_response jsonb;
  v_source_residual numeric(24,4);v_credit_residual numeric(24,4);v_amount numeric(24,4);
  v_child_post uuid:=gen_random_uuid();v_child_apply uuid:=gen_random_uuid();
  v_child_draft uuid:=gen_random_uuid();v_invoice_id uuid;
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'finance.customer_credit_notes','POST');
  PERFORM private.acp_require_permission_capability(
    v_company,'sales.backoffice_orders','CREATE_DRAFT');
  PERFORM private.ar5_assert_backoffice_company(v_company);
  IF p_credit_note_id IS NULL OR p_expected_version IS NULL OR p_operation_id IS NULL THEN
    RAISE EXCEPTION 'BACKOFFICE_REPLACEMENT_REQUIRED_FIELD_INVALID';
  END IF;
  v_hash:=md5(jsonb_build_object('creditNoteId',p_credit_note_id,
    'expectedVersion',p_expected_version)::text);
  PERFORM pg_advisory_xact_lock(hashtextextended(
    v_company||':AR6:'||p_operation_id,0));
  v_retry:=private.ar5_operation_retry(v_company,p_operation_id,
    'POST_CREDIT_CREATE_REPLACEMENT',v_hash);
  IF v_retry IS NOT NULL THEN RETURN v_retry; END IF;
  SELECT * INTO v_note FROM public.backoffice_sales_credit_notes note
  WHERE note.company_id=v_company AND note.id=p_credit_note_id FOR UPDATE;
  IF NOT FOUND OR v_note.source_kind<>'BACKOFFICE' OR v_note.status<>'DRAFT'
    OR v_note.source_invoice_id IS NULL THEN
    RAISE EXCEPTION 'BACKOFFICE_REPLACEMENT_CREDIT_NOTE_INVALID';
  END IF;
  IF v_note.master_version<>p_expected_version THEN RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
  IF public.private_company_feature_enabled(v_company,'tax_sales_enabled') THEN
    RAISE EXCEPTION 'AR_OPEN_ITEM_CREDIT_NOTE_TAX_TREATMENT_PENDING';
  END IF;
  SELECT * INTO STRICT v_source FROM public.backoffice_sales_invoices invoice
  WHERE invoice.company_id=v_company AND invoice.id=v_note.source_invoice_id
    AND invoice.status='POSTED' AND invoice.invoice_type='REGULAR' FOR UPDATE;
  PERFORM pg_advisory_xact_lock(hashtextextended(
    v_company::text||':BACKOFFICE_INVOICE_ORDER:'||v_source.sales_order_id::text,0));
  IF EXISTS(SELECT 1 FROM public.backoffice_sales_invoices invoice
    WHERE invoice.company_id=v_company AND invoice.replacement_credit_note_id=v_note.id) THEN
    RAISE EXCEPTION 'BACKOFFICE_REPLACEMENT_ALREADY_EXISTS';
  END IF;
  v_post:=public.post_backoffice_sales_credit_note(
    v_note.id,p_expected_version,v_child_post);
  SELECT * INTO STRICT v_credit FROM public.ar_open_item_registry item
  WHERE item.company_id=v_company AND item.item_kind='CREDIT_NOTE'
    AND item.direction='CREDIT' AND item.source_id=v_note.id FOR UPDATE;
  SELECT * INTO STRICT v_debit FROM public.ar_open_item_registry item
  WHERE item.company_id=v_company AND item.item_kind='INVOICE'
    AND item.direction='DEBIT' AND item.source_id=v_source.id FOR UPDATE;
  v_credit_residual:=v_credit.original_amount-private.ar5_item_allocated(
    v_company,v_credit.id,NULL);
  v_source_residual:=v_debit.original_amount-private.ar5_item_allocated(
    v_company,v_debit.id,NULL);
  v_amount:=least(v_credit_residual,v_source_residual);
  IF v_amount>0 THEN
    v_apply:=public.apply_backoffice_ar_open_credit(v_credit.id,
      jsonb_build_array(jsonb_build_object('debitItemId',v_debit.id,'amount',v_amount)),
      v_note.credit_note_date,v_credit_residual,v_child_apply);
  END IF;
  v_invoice_id:=private.create_backoffice_replacement_invoice_draft(
    v_company,v_note.id,v_actor,v_child_draft);
  v_response:=jsonb_build_object('operationKind','POST_CREDIT_CREATE_REPLACEMENT',
    'creditNoteId',v_note.id,'sourceInvoiceId',v_source.id,
    'replacementInvoiceId',v_invoice_id,'allocatedToSource',v_amount,
    'remainingCredit',v_credit_residual-v_amount,'creditNotePost',v_post,
    'sourceAllocation',v_apply,'exactRetry',false);
  INSERT INTO public.ar_open_item_operations(company_id,operation_kind,idempotency_key,
    request_hash,actor_id,operation_snapshot)
  VALUES(v_company,'POST_CREDIT_CREATE_REPLACEMENT',p_operation_id::text,
    v_hash,v_actor,v_response);
  RETURN v_response;
END
$$;

CREATE FUNCTION public.get_backoffice_credit_note_replacement(p_credit_note_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='8s' AS $$
DECLARE v_company uuid:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'finance.customer_credit_notes','VIEW');
  RETURN (SELECT jsonb_build_object('creditNoteId',note.id,
    'sourceInvoiceId',note.source_invoice_id,
    'replacementInvoice',CASE WHEN invoice.id IS NULL THEN NULL ELSE jsonb_build_object(
      'id',invoice.id,'draftNo',invoice.draft_no,'invoiceNo',invoice.invoice_no,
      'status',invoice.status,'masterVersion',invoice.master_version,
      'grandTotal',invoice.grand_total,'createdAt',invoice.created_at) END)
  FROM public.backoffice_sales_credit_notes note
  LEFT JOIN public.backoffice_sales_invoices invoice
    ON invoice.company_id=note.company_id AND invoice.replacement_credit_note_id=note.id
  WHERE note.company_id=v_company AND note.id=p_credit_note_id
    AND note.source_kind='BACKOFFICE');
END
$$;

REVOKE ALL ON FUNCTION private.create_backoffice_replacement_invoice_draft(uuid,uuid,uuid,uuid),
  private.save_backoffice_replacement_invoice_draft_core(uuid,bigint,uuid,uuid,jsonb),
  private.save_backoffice_sales_invoice_draft_before_replacement(uuid,bigint,uuid,uuid,jsonb)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.create_backoffice_replacement_invoice_draft(uuid,uuid,uuid,uuid),
  private.save_backoffice_replacement_invoice_draft_core(uuid,bigint,uuid,uuid,jsonb),
  private.save_backoffice_sales_invoice_draft_before_replacement(uuid,bigint,uuid,uuid,jsonb)
  TO service_role;
REVOKE ALL ON FUNCTION public.save_backoffice_sales_invoice_draft(uuid,bigint,uuid,uuid,jsonb),
  public.post_backoffice_credit_note_create_replacement_invoice(uuid,bigint,uuid),
  public.get_backoffice_credit_note_replacement(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.save_backoffice_sales_invoice_draft(uuid,bigint,uuid,uuid,jsonb),
  public.post_backoffice_credit_note_create_replacement_invoice(uuid,bigint,uuid),
  public.get_backoffice_credit_note_replacement(uuid) TO authenticated,service_role;

DO $postcondition$
DECLARE v_post text;
BEGIN
  SELECT pg_get_functiondef(
    'private.ar3_post_backoffice_sales_invoice_core(uuid,bigint,uuid)'::regprocedure)
  INTO STRICT v_post;
  IF (length(v_post)-length(replace(v_post,
      'IF v_invoice.invoice_type=''REGULAR'' AND v_invoice.replacement_credit_note_id IS NULL THEN','')))
      /length('IF v_invoice.invoice_type=''REGULAR'' AND v_invoice.replacement_credit_note_id IS NULL THEN')<>2
    OR to_regprocedure(
      'public.post_backoffice_credit_note_create_replacement_invoice(uuid,bigint,uuid)') IS NULL
    OR to_regprocedure(
      'private.save_backoffice_replacement_invoice_draft_core(uuid,bigint,uuid,uuid,jsonb)') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_POSTCONDITION_FAILED: Task 6 runtime incomplete';
  END IF;
END
$postcondition$;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20261110100000','backoffice_ar_credit_note_replacement_invoice',
  'Native Backoffice Credit Note atomic post plus source residual allocation and editable replacement Invoice Draft; settlement history not copied; ordinary Invoice quantity, POS, Stock/FIFO and historical Journals preserved');

NOTIFY pgrst,'reload schema';
COMMIT;
