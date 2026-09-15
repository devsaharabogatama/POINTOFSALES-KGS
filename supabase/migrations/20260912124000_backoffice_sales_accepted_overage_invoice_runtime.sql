-- Step 4/6.5C2B: accepted-overage partial Invoice Draft/Edit/Cancel/Post runtime.
BEGIN;

DO $guard$
DECLARE v_base text;v_post text;v_cancel text;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260912123000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: accepted-overage Invoice foundation required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260912124000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260912124000';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
    WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
  IF to_regprocedure('private.save_backoffice_sales_invoice_draft_core_before_delivery_fee(uuid,bigint,uuid,uuid,jsonb)') IS NULL
    OR to_regprocedure('private.save_backoffice_sales_invoice_draft_core(uuid,bigint,uuid,uuid,jsonb)') IS NULL
    OR to_regprocedure('public.cancel_backoffice_sales_invoice_draft(uuid,bigint,uuid,text)') IS NULL
    OR to_regprocedure('public.post_backoffice_sales_invoice(uuid,bigint,uuid)') IS NULL
    OR to_regprocedure('private.validate_backoffice_sales_invoice_overage_source()') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical Invoice call chain missing';
  END IF;
  IF to_regprocedure('private.trg_backoffice_sales_invoice_overage_counter()') IS NOT NULL
    OR to_regprocedure('private.trg_backoffice_sales_invoice_accepted_overage_lines()') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: C2B routine collision';
  END IF;
  SELECT pg_get_functiondef('private.save_backoffice_sales_invoice_draft_core_before_delivery_fee(uuid,bigint,uuid,uuid,jsonb)'::regprocedure) INTO v_base;
  SELECT pg_get_functiondef('public.post_backoffice_sales_invoice(uuid,bigint,uuid)'::regprocedure) INTO v_post;
  SELECT pg_get_functiondef('public.cancel_backoffice_sales_invoice_draft(uuid,bigint,uuid,text)'::regprocedure) INTO v_cancel;
  IF (length(v_base)-length(replace(v_base,$n$IF jsonb_typeof(p_payload->'lines')<>'array' OR jsonb_array_length(p_payload->'lines')=0 THEN$n$,'')))/length($n$IF jsonb_typeof(p_payload->'lines')<>'array' OR jsonb_array_length(p_payload->'lines')=0 THEN$n$)<>1
    OR (length(v_base)-length(replace(v_base,$n$AND allocation.status='HELD' AND source.company_id=allocation.company_id$n$,'')))/length($n$AND allocation.status='HELD' AND source.company_id=allocation.company_id$n$)<>1
    OR (length(v_post)-length(replace(v_post,$n$AND allocation.status='HELD' AND source.company_id=allocation.company_id$n$,'')))/length($n$AND allocation.status='HELD' AND source.company_id=allocation.company_id$n$)<>1
    OR (length(v_cancel)-length(replace(v_cancel,$n$AND allocation.status='HELD' AND source.company_id=allocation.company_id$n$,'')))/length($n$AND allocation.status='HELD' AND source.company_id=allocation.company_id$n$)<>1 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical Invoice definition drift';
  END IF;
END
$guard$;

CREATE OR REPLACE FUNCTION private.validate_backoffice_sales_invoice_overage_source()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_line record;v_source record;v_available numeric;
BEGIN
  IF NEW.source_kind='SALES_ORDER' THEN RETURN NEW; END IF;
  IF TG_OP='UPDATE' AND (OLD.company_id,OLD.invoice_id,OLD.invoice_line_id,
      OLD.sales_order_id,OLD.sales_order_line_id,OLD.source_kind,OLD.discrepancy_line_id,
      OLD.allocated_base_qty) IS DISTINCT FROM
      (NEW.company_id,NEW.invoice_id,NEW.invoice_line_id,NEW.sales_order_id,
       NEW.sales_order_line_id,NEW.source_kind,NEW.discrepancy_line_id,NEW.allocated_base_qty) THEN
    RAISE EXCEPTION 'BACKOFFICE_ACCEPTED_OVERAGE_INVOICE_ALLOCATION_IMMUTABLE';
  END IF;
  SELECT line.source_kind,line.discrepancy_line_id,line.sales_order_id,
    line.sales_order_line_id,line.product_id,line.uom_id,line.quantity_base
  INTO STRICT v_line FROM public.backoffice_sales_invoice_lines line
  WHERE line.company_id=NEW.company_id AND line.id=NEW.invoice_line_id;
  SELECT discrepancy.sales_order_id,discrepancy.sales_order_line_id,
    discrepancy.expected_product_id,discrepancy.uom_id,
    discrepancy.overage_to_invoice_base_qty
  INTO STRICT v_source FROM public.backoffice_sales_delivery_discrepancy_lines discrepancy
  WHERE discrepancy.company_id=NEW.company_id AND discrepancy.id=NEW.discrepancy_line_id
    AND discrepancy.requested_resolution='ACCEPT_OVERAGE'
    AND discrepancy.commercial_approval_status='APPROVED'
    AND discrepancy.warehouse_resolution_status='RESOLVED' FOR UPDATE;
  v_available:=v_source.overage_to_invoice_base_qty
    +CASE WHEN TG_OP='UPDATE' AND OLD.source_kind='ACCEPTED_OVERAGE'
      AND OLD.discrepancy_line_id=NEW.discrepancy_line_id AND OLD.status='HELD'
      THEN OLD.allocated_base_qty ELSE 0 END;
  IF v_line.source_kind<>'ACCEPTED_OVERAGE'
    OR v_line.discrepancy_line_id<>NEW.discrepancy_line_id
    OR v_line.sales_order_id<>v_source.sales_order_id
    OR v_line.sales_order_line_id<>v_source.sales_order_line_id
    OR v_line.product_id<>v_source.expected_product_id OR v_line.uom_id<>v_source.uom_id
    OR NEW.allocated_base_qty<>v_line.quantity_base
    OR (NEW.status='HELD' AND NEW.allocated_base_qty>v_available) THEN
    RAISE EXCEPTION 'BACKOFFICE_ACCEPTED_OVERAGE_INVOICE_SOURCE_INVALID';
  END IF;
  RETURN NEW;
END
$$;

CREATE FUNCTION private.trg_backoffice_sales_invoice_overage_counter()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
  IF TG_OP='INSERT' AND NEW.source_kind='ACCEPTED_OVERAGE' AND NEW.status='HELD' THEN
    UPDATE public.backoffice_sales_delivery_discrepancy_lines SET
      draft_overage_invoice_allocated_base_qty=draft_overage_invoice_allocated_base_qty+NEW.allocated_base_qty,
      updated_at=clock_timestamp()
    WHERE company_id=NEW.company_id AND id=NEW.discrepancy_line_id;
  ELSIF TG_OP='DELETE' AND OLD.source_kind='ACCEPTED_OVERAGE' AND OLD.status='HELD' THEN
    UPDATE public.backoffice_sales_delivery_discrepancy_lines SET
      draft_overage_invoice_allocated_base_qty=draft_overage_invoice_allocated_base_qty-OLD.allocated_base_qty,
      updated_at=clock_timestamp()
    WHERE company_id=OLD.company_id AND id=OLD.discrepancy_line_id;
  ELSIF TG_OP='UPDATE' AND NEW.source_kind='ACCEPTED_OVERAGE' AND OLD.status='HELD'
      AND NEW.status='POSTED' THEN
    UPDATE public.backoffice_sales_delivery_discrepancy_lines SET
      draft_overage_invoice_allocated_base_qty=draft_overage_invoice_allocated_base_qty-NEW.allocated_base_qty,
      invoiced_overage_base_qty=invoiced_overage_base_qty+NEW.allocated_base_qty,
      updated_at=clock_timestamp()
    WHERE company_id=NEW.company_id AND id=NEW.discrepancy_line_id;
  ELSIF TG_OP='UPDATE' AND NEW.source_kind='ACCEPTED_OVERAGE' AND OLD.status='HELD'
      AND NEW.status='RELEASED' THEN
    UPDATE public.backoffice_sales_delivery_discrepancy_lines SET
      draft_overage_invoice_allocated_base_qty=draft_overage_invoice_allocated_base_qty-NEW.allocated_base_qty,
      updated_at=clock_timestamp()
    WHERE company_id=NEW.company_id AND id=NEW.discrepancy_line_id;
  END IF;
  IF TG_OP='DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END
$$;
CREATE TRIGGER backoffice_sales_invoice_overage_counter
AFTER INSERT OR UPDATE OR DELETE ON public.backoffice_sales_invoice_quantity_allocations
FOR EACH ROW EXECUTE FUNCTION private.trg_backoffice_sales_invoice_overage_counter();

CREATE FUNCTION private.trg_backoffice_sales_invoice_accepted_overage_lines()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_setting text;v_items jsonb;v_item jsonb;v_source record;v_tax jsonb;
  v_tax_result jsonb;v_tax_line jsonb;v_seen uuid[]:='{}'::uuid[];v_id uuid;
  v_qty_uom numeric;v_qty_base numeric;v_used_discount numeric;v_used_tax numeric;
  v_discount numeric;v_tax_amount numeric;v_net numeric;v_dpp numeric;v_line_id uuid;
  v_line_no integer;v_remaining_discount numeric;v_remaining_tax numeric;
BEGIN
  v_setting:=current_setting('kgs.backoffice_invoice_accepted_overage_lines',true);
  IF NULLIF(v_setting,'') IS NULL THEN RETURN NEW; END IF;
  BEGIN v_items:=v_setting::jsonb;
  EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'BACKOFFICE_ACCEPTED_OVERAGE_INVOICE_PAYLOAD_INVALID'; END;
  IF jsonb_typeof(v_items)<>'array' OR NEW.invoice_type<>'REGULAR' OR NEW.status<>'DRAFT' THEN
    RAISE EXCEPTION 'BACKOFFICE_ACCEPTED_OVERAGE_INVOICE_PAYLOAD_INVALID';
  END IF;
  -- Consume the transaction-local input once. AFTER UPDATE routines rebuild
  -- DP/tax/schedules and may update this header again before the outer wrapper
  -- returns; those nested updates must never recreate the overage lines.
  PERFORM set_config('kgs.backoffice_invoice_accepted_overage_lines','',true);
  SELECT COALESCE(max(line_no),0) INTO v_line_no
  FROM public.backoffice_sales_invoice_lines
  WHERE company_id=NEW.company_id AND invoice_id=NEW.id;
  FOR v_item IN SELECT value FROM jsonb_array_elements(v_items) LOOP
    BEGIN
      v_id:=(v_item->>'discrepancyLineId')::uuid;
      v_qty_uom:=round((v_item->>'quantityUom')::numeric,6);
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'BACKOFFICE_ACCEPTED_OVERAGE_INVOICE_PAYLOAD_INVALID';
    END;
    IF v_id IS NULL OR v_id=ANY(v_seen) OR v_qty_uom<=0
      OR (v_item-'discrepancyLineId'-'quantityUom')<>'{}'::jsonb THEN
      RAISE EXCEPTION 'BACKOFFICE_ACCEPTED_OVERAGE_INVOICE_PAYLOAD_INVALID';
    END IF;
    v_seen:=array_append(v_seen,v_id);
    SELECT discrepancy.*,source.product_code_snapshot,source.product_name_snapshot,
      source.uom_code_snapshot,source.uom_name_snapshot,source.base_qty_per_uom
    INTO STRICT v_source
    FROM public.backoffice_sales_delivery_discrepancy_lines discrepancy
    JOIN public.backoffice_sales_order_lines source
      ON source.company_id=discrepancy.company_id AND source.id=discrepancy.sales_order_line_id
    WHERE discrepancy.company_id=NEW.company_id AND discrepancy.id=v_id
      AND discrepancy.sales_order_id=NEW.sales_order_id
      AND discrepancy.requested_resolution='ACCEPT_OVERAGE'
      AND discrepancy.commercial_approval_status='APPROVED'
      AND discrepancy.warehouse_resolution_status='RESOLVED'
      AND discrepancy.accepted_overage_base_qty>0 FOR UPDATE OF discrepancy;
    v_qty_base:=round(v_qty_uom*v_source.base_qty_per_uom,6);
    IF v_qty_base<=0 OR v_qty_base>v_source.overage_to_invoice_base_qty THEN
      RAISE EXCEPTION 'BACKOFFICE_ACCEPTED_OVERAGE_INVOICE_QUANTITY_EXCEEDS_AVAILABLE';
    END IF;
    SELECT round(COALESCE(sum(line.discount_amount),0),4),
      round(COALESCE(sum(line.tax_amount),0),4)
    INTO v_used_discount,v_used_tax
    FROM public.backoffice_sales_invoice_lines line
    JOIN public.backoffice_sales_invoice_quantity_allocations allocation
      ON allocation.company_id=line.company_id AND allocation.invoice_line_id=line.id
    WHERE line.company_id=NEW.company_id AND line.discrepancy_line_id=v_id
      AND allocation.status IN('HELD','POSTED');
    v_remaining_discount:=round(v_source.approved_discount_amount-v_used_discount,4);
    v_remaining_tax:=round(v_source.approved_tax_amount-v_used_tax,4);
    IF v_remaining_discount<0 OR v_remaining_tax<0 THEN
      RAISE EXCEPTION 'BACKOFFICE_ACCEPTED_OVERAGE_INVOICE_RECONCILIATION_FAILED';
    END IF;
    v_discount:=CASE WHEN v_qty_base=v_source.overage_to_invoice_base_qty
      THEN v_remaining_discount ELSE round(v_source.approved_discount_amount
        *v_qty_base/v_source.accepted_overage_base_qty,4) END;
    v_discount:=least(v_discount,v_remaining_discount);
    v_net:=round(v_qty_uom*v_source.approved_unit_price-v_discount,4);
    IF v_net<0 THEN RAISE EXCEPTION 'BACKOFFICE_ACCEPTED_OVERAGE_INVOICE_DISCOUNT_INVALID'; END IF;
    v_tax:=COALESCE(v_source.commercial_snapshot->'tax','{}'::jsonb);
    IF COALESCE((v_tax->>'taxApplied')::boolean,false) THEN
      IF v_qty_base=v_source.overage_to_invoice_base_qty THEN
        v_tax_amount:=v_remaining_tax;
      ELSE
        v_tax_result:=private.calculate_tax_group(
          jsonb_build_array(jsonb_build_object('lineKey',v_id::text,'amount',v_net)),
          (v_tax->>'ratePercent')::numeric,'SALES',v_tax->>'priceMode',
          v_tax->>'calculationScope');
        v_tax_line:=v_tax_result->'lines'->0;
        v_tax_amount:=least(round((v_tax_line->>'taxAmount')::numeric,4),v_remaining_tax);
      END IF;
    ELSE v_tax_amount:=0;
    END IF;
    v_dpp:=round(v_net-v_tax_amount,4);
    IF v_dpp<0 THEN RAISE EXCEPTION 'BACKOFFICE_ACCEPTED_OVERAGE_INVOICE_TAX_INVALID'; END IF;
    v_line_no:=v_line_no+1;v_line_id:=gen_random_uuid();
    INSERT INTO public.backoffice_sales_invoice_lines(id,company_id,invoice_id,
      sales_order_id,sales_order_line_id,line_no,line_type,effect_type,product_id,uom_id,
      quantity_uom,base_qty_per_uom,quantity_base,unit_price,discount_amount,tax_amount,
      line_amount,description,source_snapshot,source_kind,discrepancy_line_id)
    VALUES(v_line_id,NEW.company_id,NEW.id,NEW.sales_order_id,v_source.sales_order_line_id,
      v_line_no,'PRODUCT','CHARGE',v_source.expected_product_id,v_source.uom_id,
      v_qty_uom,v_source.base_qty_per_uom,v_qty_base,
      CASE WHEN v_qty_uom=0 THEN 0 ELSE round((v_dpp+v_discount)/v_qty_uom,4) END,
      v_discount,v_tax_amount,v_dpp,'Kelebihan barang',
      v_source.commercial_snapshot||jsonb_build_object(
        'enteredGrossUnitPrice',v_source.approved_unit_price,
        'taxApplied',COALESCE((v_tax->>'taxApplied')::boolean,false),
        'taxRuleId',v_tax->>'taxRuleId','taxRuleVersion',v_tax->>'ruleVersion',
        'taxCode',v_tax->>'taxCode','taxName',v_tax->>'taxName',
        'taxRatePercent',v_tax->>'ratePercent','taxPriceMode',v_tax->>'priceMode',
        'taxCalculationScope',v_tax->>'calculationScope','taxAccountId',v_tax->>'taxAccountId',
        'sourceKind','ACCEPTED_OVERAGE','discrepancyLineId',v_id,
        'discountAllocationPolicy','PROPORTIONAL_LAST_REMAINDER',
        'taxAllocationPolicy','PER_INVOICE_LAST_REMAINDER'),
      'ACCEPTED_OVERAGE',v_id);
    INSERT INTO public.backoffice_sales_invoice_quantity_allocations(company_id,invoice_id,
      invoice_line_id,sales_order_id,sales_order_line_id,allocated_base_qty,
      source_kind,discrepancy_line_id)
    VALUES(NEW.company_id,NEW.id,v_line_id,NEW.sales_order_id,v_source.sales_order_line_id,
      v_qty_base,'ACCEPTED_OVERAGE',v_id);
    NEW.charge_total:=round(NEW.charge_total+v_dpp+v_discount,4);
    NEW.discount_total:=round(NEW.discount_total+v_discount,4);
    NEW.tax_total:=round(NEW.tax_total+v_tax_amount,4);
  END LOOP;
  NEW.commercial_snapshot:=COALESCE(NEW.commercial_snapshot,'{}'::jsonb)
    ||jsonb_build_object('acceptedOverageAllocation','PROPORTIONAL_LAST_REMAINDER');
  RETURN NEW;
END
$$;
CREATE TRIGGER backoffice_sales_invoice_accepted_overage_lines
BEFORE UPDATE ON public.backoffice_sales_invoices
FOR EACH ROW EXECUTE FUNCTION private.trg_backoffice_sales_invoice_accepted_overage_lines();

DO $patch_chain$
DECLARE v_definition text;
BEGIN
  SELECT pg_get_functiondef('private.save_backoffice_sales_invoice_draft_core_before_delivery_fee(uuid,bigint,uuid,uuid,jsonb)'::regprocedure) INTO v_definition;
  v_definition:=replace(v_definition,
    $n$IF jsonb_typeof(p_payload->'lines')<>'array' OR jsonb_array_length(p_payload->'lines')=0 THEN$n$,
    $n$IF (jsonb_typeof(p_payload->'lines')<>'array' OR jsonb_array_length(p_payload->'lines')=0)
      AND (jsonb_typeof(p_payload->'acceptedOverageLines')<>'array'
        OR jsonb_array_length(p_payload->'acceptedOverageLines')=0) THEN$n$);
  v_definition:=replace(v_definition,
    $n$AND allocation.status='HELD' AND source.company_id=allocation.company_id$n$,
    $n$AND allocation.status='HELD' AND allocation.source_kind='SALES_ORDER'
      AND source.company_id=allocation.company_id$n$);
  EXECUTE v_definition;

  SELECT pg_get_functiondef('public.cancel_backoffice_sales_invoice_draft(uuid,bigint,uuid,text)'::regprocedure) INTO v_definition;
  v_definition:=replace(v_definition,
    $n$AND allocation.status='HELD' AND source.company_id=allocation.company_id$n$,
    $n$AND allocation.status='HELD' AND allocation.source_kind='SALES_ORDER'
    AND source.company_id=allocation.company_id$n$);
  EXECUTE v_definition;

  SELECT pg_get_functiondef('public.post_backoffice_sales_invoice(uuid,bigint,uuid)'::regprocedure) INTO v_definition;
  v_definition:=replace(v_definition,
    $n$AND allocation.status='HELD' AND source.company_id=allocation.company_id$n$,
    $n$AND allocation.status='HELD' AND allocation.source_kind='SALES_ORDER'
      AND source.company_id=allocation.company_id$n$);
  EXECUTE v_definition;
END
$patch_chain$;

CREATE OR REPLACE FUNCTION private.save_backoffice_sales_invoice_draft_core(
  p_invoice_id uuid,p_expected_version bigint,p_operation_id uuid,
  p_sales_order_id uuid,p_payload jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_type text;v_fee numeric:=0;
  v_order_fee numeric;v_other_fee numeric;v_existing_fee numeric;v_response jsonb;
  v_overage jsonb:=COALESCE(p_payload->'acceptedOverageLines','[]'::jsonb);
BEGIN
  IF p_operation_id IS NULL OR p_sales_order_id IS NULL OR p_payload IS NULL
    OR jsonb_typeof(p_payload)<>'object' THEN
    RETURN private.save_backoffice_sales_invoice_draft_core_before_delivery_fee(
      p_invoice_id,p_expected_version,p_operation_id,p_sales_order_id,p_payload);
  END IF;
  v_type:=upper(btrim(p_payload->>'invoiceType'));
  IF v_type NOT IN('REGULAR','DOWN_PAYMENT') THEN
    RETURN private.save_backoffice_sales_invoice_draft_core_before_delivery_fee(
      p_invoice_id,p_expected_version,p_operation_id,p_sales_order_id,p_payload);
  END IF;
  IF jsonb_typeof(v_overage)<>'array' OR jsonb_array_length(v_overage)>500
    OR (v_type='DOWN_PAYMENT' AND jsonb_array_length(v_overage)>0) THEN
    RAISE EXCEPTION 'BACKOFFICE_ACCEPTED_OVERAGE_INVOICE_PAYLOAD_INVALID';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(
    v_company::text||':BACKOFFICE_INVOICE_ORDER:'||p_sales_order_id::text,0));
  SELECT document.delivery_fee_amount INTO v_order_fee
  FROM public.backoffice_sales_orders document
  WHERE document.company_id=v_company AND document.id=p_sales_order_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN private.save_backoffice_sales_invoice_draft_core_before_delivery_fee(
      p_invoice_id,p_expected_version,p_operation_id,p_sales_order_id,p_payload);
  END IF;
  IF v_type='DOWN_PAYMENT' THEN
    IF p_payload ? 'deliveryFeeAmount' THEN
      BEGIN v_fee:=round(COALESCE(NULLIF(p_payload->>'deliveryFeeAmount','')::numeric,0),4);
      EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'BACKOFFICE_INVOICE_DELIVERY_FEE_INVALID'; END;
      IF v_fee<>0 THEN RAISE EXCEPTION 'BACKOFFICE_INVOICE_DELIVERY_FEE_NOT_ALLOWED_ON_DP'; END IF;
    END IF;
    v_fee:=0;
  ELSIF p_payload ? 'deliveryFeeAmount' THEN
    BEGIN v_fee:=round((p_payload->>'deliveryFeeAmount')::numeric,4);
    EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'BACKOFFICE_INVOICE_DELIVERY_FEE_INVALID'; END;
  ELSIF p_invoice_id IS NOT NULL THEN
    SELECT invoice.delivery_fee_amount INTO v_existing_fee
    FROM public.backoffice_sales_invoices invoice
    WHERE invoice.company_id=v_company AND invoice.id=p_invoice_id
      AND invoice.sales_order_id=p_sales_order_id;
    v_fee:=COALESCE(v_existing_fee,0);
  ELSE
    SELECT round(COALESCE(sum(invoice.delivery_fee_amount),0),4) INTO v_other_fee
    FROM public.backoffice_sales_invoices invoice
    WHERE invoice.company_id=v_company AND invoice.sales_order_id=p_sales_order_id
      AND invoice.invoice_type='REGULAR' AND invoice.status IN('DRAFT','POSTED');
    v_fee:=greatest(0,v_order_fee-v_other_fee);
  END IF;
  IF v_fee<0 THEN RAISE EXCEPTION 'BACKOFFICE_INVOICE_DELIVERY_FEE_INVALID'; END IF;
  PERFORM set_config('kgs.backoffice_invoice_delivery_fee_amount',v_fee::text,true);
  PERFORM set_config('kgs.backoffice_invoice_accepted_overage_lines',v_overage::text,true);
  BEGIN
    v_response:=private.save_backoffice_sales_invoice_draft_core_before_delivery_fee(
      p_invoice_id,p_expected_version,p_operation_id,p_sales_order_id,p_payload);
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('kgs.backoffice_invoice_delivery_fee_amount','',true);
    PERFORM set_config('kgs.backoffice_invoice_accepted_overage_lines','',true);
    RAISE;
  END;
  PERFORM set_config('kgs.backoffice_invoice_delivery_fee_amount','',true);
  PERFORM set_config('kgs.backoffice_invoice_accepted_overage_lines','',true);
  RETURN v_response;
END
$$;

REVOKE ALL ON FUNCTION private.validate_backoffice_sales_invoice_overage_source(),
  private.trg_backoffice_sales_invoice_overage_counter(),
  private.trg_backoffice_sales_invoice_accepted_overage_lines(),
  private.save_backoffice_sales_invoice_draft_core(uuid,bigint,uuid,uuid,jsonb)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.validate_backoffice_sales_invoice_overage_source(),
  private.trg_backoffice_sales_invoice_overage_counter(),
  private.trg_backoffice_sales_invoice_accepted_overage_lines(),
  private.save_backoffice_sales_invoice_draft_core(uuid,bigint,uuid,uuid,jsonb)
TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260912124000','backoffice_sales_accepted_overage_invoice_runtime',
  'Step 4/6.5C2B enables partial accepted-overage Invoice Draft/Edit/Cancel/Post with proportional discount, per-Invoice approved tax snapshot, last-Invoice rounding remainder, separate counters and immutable source lineage; no UI, Stock, POS or payment mutation');
NOTIFY pgrst,'reload schema';
COMMIT;
