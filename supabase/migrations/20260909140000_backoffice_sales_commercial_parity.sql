-- Backoffice Quotation/SO commercial parity with canonical POS pricing rules.
-- Draft-only commercial snapshot; zero fulfillment and Finance effect.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260909130000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Sales role authority required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260909140000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260909140000';
  END IF;
  IF to_regprocedure('private.resolve_product_tax_rule(uuid,uuid,text,timestamptz)') IS NULL
    OR to_regprocedure('private.calculate_tax_group(jsonb,numeric,text,text,text)') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical commercial calculator missing';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
END
$guard$;

ALTER TABLE public.backoffice_sales_orders
  ADD COLUMN global_discount numeric(20,4) NOT NULL DEFAULT 0,
  ADD COLUMN grand_total_before_rounding numeric(20,4) NOT NULL DEFAULT 0,
  ADD COLUMN rounding_direction text NOT NULL DEFAULT 'NONE',
  ADD COLUMN rounding_increment numeric(20,4) NOT NULL DEFAULT 100,
  ADD COLUMN rounding_adjustment numeric(20,4) NOT NULL DEFAULT 0;

UPDATE public.backoffice_sales_orders
SET grand_total_before_rounding=grand_total;

ALTER TABLE public.backoffice_sales_orders
  DROP CONSTRAINT backoffice_sales_orders_amount_check,
  ADD CONSTRAINT backoffice_sales_orders_amount_check CHECK(
    subtotal>=0 AND discount_total>=0 AND global_discount>=0
    AND discount_total<=subtotal AND tax_total>=0
    AND rounding_direction IN('NONE','DOWN','UP') AND rounding_increment>0
    AND grand_total_before_rounding=subtotal-discount_total
    AND rounding_adjustment=grand_total-grand_total_before_rounding
  ) NOT VALID;
ALTER TABLE public.backoffice_sales_orders
  VALIDATE CONSTRAINT backoffice_sales_orders_amount_check;

ALTER TABLE public.backoffice_sales_order_lines
  ADD COLUMN canonical_unit_price numeric(20,4),
  ADD COLUMN price_override_applied boolean NOT NULL DEFAULT false,
  ADD COLUMN price_override_unit_price numeric(20,4),
  ADD COLUMN line_discount_type text,
  ADD COLUMN line_discount_input numeric(20,6),
  ADD COLUMN line_discount_amount numeric(20,4) NOT NULL DEFAULT 0,
  ADD COLUMN allocated_order_discount_amount numeric(20,4) NOT NULL DEFAULT 0,
  ADD COLUMN allocated_document_rounding numeric(20,4) NOT NULL DEFAULT 0;

UPDATE public.backoffice_sales_order_lines SET canonical_unit_price=unit_price;
ALTER TABLE public.backoffice_sales_order_lines
  ALTER COLUMN canonical_unit_price SET NOT NULL,
  ADD CONSTRAINT backoffice_sales_order_lines_commercial_check CHECK(
    canonical_unit_price>=0
    AND ((NOT price_override_applied AND price_override_unit_price IS NULL)
      OR (price_override_applied AND price_override_unit_price=unit_price
        AND price_override_unit_price>=0))
    AND (line_discount_type IS NULL OR line_discount_type IN('AMOUNT','PERCENT'))
    AND (line_discount_input IS NULL OR line_discount_input>=0)
    AND (line_discount_type<>'PERCENT' OR line_discount_input<=100)
    AND line_discount_amount>=0 AND allocated_order_discount_amount>=0
    AND discount_amount=line_discount_amount+allocated_order_discount_amount
  ) NOT VALID;
ALTER TABLE public.backoffice_sales_order_lines
  VALIDATE CONSTRAINT backoffice_sales_order_lines_commercial_check;

ALTER FUNCTION private.resolve_pos_sale_price(uuid,uuid,uuid,uuid,numeric,timestamptz)
  RENAME TO resolve_pos_sale_price_before_backoffice_commercial;

CREATE FUNCTION private.resolve_pos_sale_price(
  p_company_id uuid,p_store_id uuid,p_customer_id uuid,p_product_uom_id uuid,
  p_quantity numeric,p_resolved_at timestamptz
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
  v_result jsonb;
  v_map_raw text:=NULLIF(current_setting('kgs.backoffice_price_override_map',true),'');
  v_map jsonb:='{}'::jsonb;
  v_override numeric(20,4);
BEGIN
  v_result:=private.resolve_pos_sale_price_before_backoffice_commercial(
    p_company_id,p_store_id,p_customer_id,p_product_uom_id,p_quantity,p_resolved_at);
  IF v_map_raw IS NULL THEN RETURN v_result; END IF;
  BEGIN v_map:=v_map_raw::jsonb;
  EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'BACKOFFICE_PRICE_OVERRIDE_CONTEXT_INVALID'; END;
  IF jsonb_typeof(v_map)<>'object' THEN
    RAISE EXCEPTION 'BACKOFFICE_PRICE_OVERRIDE_CONTEXT_INVALID';
  END IF;
  IF NOT v_map ? p_product_uom_id::text THEN RETURN v_result; END IF;
  BEGIN v_override:=round((v_map->>p_product_uom_id::text)::numeric,4);
  EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'BACKOFFICE_PRICE_OVERRIDE_INVALID'; END;
  IF v_override IS NULL OR v_override<0 OR v_override>999999999999999.9999 THEN
    RAISE EXCEPTION 'BACKOFFICE_PRICE_OVERRIDE_INVALID';
  END IF;
  RETURN v_result||jsonb_build_object(
    'canonicalResolvedUnitPrice',(v_result->>'resolvedUnitPrice')::numeric,
    'resolvedUnitPrice',v_override,'priceOverrideApplied',true,
    'priceOverrideSource','BACKOFFICE_SALES_INPUT');
END
$$;

CREATE OR REPLACE FUNCTION private.apply_backoffice_sales_order_tax(
  p_company_id uuid,p_order_id uuid,p_resolved_at timestamptz
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
  v_line record;v_tax jsonb;v_group record;v_input jsonb;v_result jsonb;v_result_line jsonb;
  v_tax_total numeric:=0;
BEGIN
  FOR v_line IN SELECT id,product_id,line_total FROM public.backoffice_sales_order_lines
    WHERE company_id=p_company_id AND sales_order_id=p_order_id ORDER BY line_no
  LOOP
    v_tax:=private.resolve_product_tax_rule(p_company_id,v_line.product_id,'SALES',p_resolved_at);
    UPDATE public.backoffice_sales_order_lines SET
      pricing_snapshot=pricing_snapshot||jsonb_build_object('tax',v_tax),
      tax_rule_id=CASE WHEN COALESCE((v_tax->>'taxApplied')::boolean,false) THEN (v_tax->>'taxRuleId')::uuid END,
      tax_rule_version=CASE WHEN COALESCE((v_tax->>'taxApplied')::boolean,false) THEN (v_tax->>'ruleVersion')::bigint END,
      tax_code_snapshot=CASE WHEN COALESCE((v_tax->>'taxApplied')::boolean,false) THEN v_tax->>'taxCode' END,
      tax_name_snapshot=CASE WHEN COALESCE((v_tax->>'taxApplied')::boolean,false) THEN v_tax->>'taxName' END,
      tax_rate_percent_snapshot=CASE WHEN COALESCE((v_tax->>'taxApplied')::boolean,false) THEN (v_tax->>'ratePercent')::numeric END,
      tax_price_mode_snapshot=CASE WHEN COALESCE((v_tax->>'taxApplied')::boolean,false) THEN v_tax->>'priceMode' END,
      tax_calculation_scope_snapshot=CASE WHEN COALESCE((v_tax->>'taxApplied')::boolean,false) THEN v_tax->>'calculationScope' END,
      tax_base=v_line.line_total,tax_amount=0,tax_rounding=0,
      tax_account_id=CASE WHEN COALESCE((v_tax->>'taxApplied')::boolean,false) THEN (v_tax->>'taxAccountId')::uuid END,
      tax_account_code_snapshot=CASE WHEN COALESCE((v_tax->>'taxApplied')::boolean,false) THEN v_tax->>'taxAccountCode' END,
      tax_account_name_snapshot=CASE WHEN COALESCE((v_tax->>'taxApplied')::boolean,false) THEN v_tax->>'taxAccountName' END
    WHERE company_id=p_company_id AND id=v_line.id;
  END LOOP;
  FOR v_group IN SELECT tax_rule_id,tax_rule_version,tax_rate_percent_snapshot,
      tax_price_mode_snapshot,tax_calculation_scope_snapshot
    FROM public.backoffice_sales_order_lines
    WHERE company_id=p_company_id AND sales_order_id=p_order_id AND tax_rule_id IS NOT NULL
    GROUP BY tax_rule_id,tax_rule_version,tax_rate_percent_snapshot,
      tax_price_mode_snapshot,tax_calculation_scope_snapshot
  LOOP
    SELECT jsonb_agg(jsonb_build_object('lineKey',id::text,'amount',line_total) ORDER BY line_no)
    INTO v_input FROM public.backoffice_sales_order_lines
    WHERE company_id=p_company_id AND sales_order_id=p_order_id
      AND tax_rule_id=v_group.tax_rule_id AND tax_rule_version=v_group.tax_rule_version;
    v_result:=private.calculate_tax_group(v_input,v_group.tax_rate_percent_snapshot,
      'SALES',v_group.tax_price_mode_snapshot,v_group.tax_calculation_scope_snapshot);
    FOR v_result_line IN SELECT value FROM jsonb_array_elements(v_result->'lines') LOOP
      UPDATE public.backoffice_sales_order_lines SET
        tax_base=(v_result_line->>'taxBase')::numeric,
        tax_amount=(v_result_line->>'taxAmount')::numeric,
        tax_rounding=(v_result_line->>'taxRounding')::numeric
      WHERE company_id=p_company_id AND id=(v_result_line->>'lineKey')::uuid;
    END LOOP;
  END LOOP;
  SELECT COALESCE(sum(tax_amount),0) INTO v_tax_total
  FROM public.backoffice_sales_order_lines
  WHERE company_id=p_company_id AND sales_order_id=p_order_id;
  UPDATE public.backoffice_sales_orders SET tax_total=v_tax_total,
    grand_total=subtotal-discount_total+rounding_adjustment,
    commercial_snapshot=commercial_snapshot||jsonb_build_object(
      'taxScope','CANONICAL_SALES_INCLUSIVE','taxResolvedAt',p_resolved_at)
  WHERE company_id=p_company_id AND id=p_order_id;
END
$$;

CREATE OR REPLACE FUNCTION private.backoffice_sales_order_snapshot(
  p_company_id uuid,p_order_id uuid
) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
  SELECT jsonb_build_object(
    'id',document.id,'quotationNo',document.quotation_no,'orderNo',document.order_no,
    'status',document.status,'salesOrigin',document.sales_origin,
    'salesProcessMode',document.sales_process_mode,'storeId',document.store_id,
    'warehouseId',document.warehouse_id,'customerId',document.customer_id,
    'pricelistId',document.pricelist_id,'orderDate',document.order_date,
    'plannedDeliveryDate',document.planned_delivery_date,'isTempo',document.is_tempo,
    'dueDate',document.due_date,'currencyCode',document.currency_code,
    'customerSnapshot',document.customer_snapshot,'commercialSnapshot',document.commercial_snapshot,
    'notes',document.notes,'subtotal',document.subtotal,'discountTotal',document.discount_total,
    'globalDiscount',document.global_discount,'taxTotal',document.tax_total,
    'grandTotalBeforeRounding',document.grand_total_before_rounding,
    'roundingDirection',document.rounding_direction,'roundingIncrement',document.rounding_increment,
    'roundingAdjustment',document.rounding_adjustment,'grandTotal',document.grand_total,
    'masterVersion',document.master_version,'createdAt',document.created_at,
    'updatedAt',document.updated_at,'sentAt',document.sent_at,
    'confirmedAt',document.confirmed_at,'canceledAt',document.canceled_at,
    'cancelReason',document.cancel_reason,
    'lines',COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'id',line.id,'lineNo',line.line_no,'productId',line.product_id,
      'uomId',line.uom_id,'orderedQty',line.ordered_qty,
      'baseQtyPerUom',line.base_qty_per_uom,'orderedBaseQty',line.ordered_base_qty,
      'canonicalUnitPrice',line.canonical_unit_price,'unitPrice',line.unit_price,
      'priceOverrideApplied',line.price_override_applied,
      'priceOverrideUnitPrice',line.price_override_unit_price,
      'lineSubtotal',line.line_subtotal,'lineDiscountType',line.line_discount_type,
      'lineDiscountInput',line.line_discount_input,'lineDiscountAmount',line.line_discount_amount,
      'allocatedOrderDiscountAmount',line.allocated_order_discount_amount,
      'discountAmount',line.discount_amount,'taxRuleId',line.tax_rule_id,
      'taxRuleVersion',line.tax_rule_version,'taxCode',line.tax_code_snapshot,
      'taxName',line.tax_name_snapshot,'taxRatePercent',line.tax_rate_percent_snapshot,
      'taxPriceMode',line.tax_price_mode_snapshot,'taxBase',line.tax_base,
      'taxAmount',line.tax_amount,'taxRounding',line.tax_rounding,
      'allocatedDocumentRounding',line.allocated_document_rounding,
      'lineTotal',line.line_total,'productCode',line.product_code_snapshot,
      'productName',line.product_name_snapshot,'uomCode',line.uom_code_snapshot,
      'uomName',line.uom_name_snapshot,'pricingSnapshot',line.pricing_snapshot,
      'masterVersion',line.master_version) ORDER BY line.line_no)
      FROM public.backoffice_sales_order_lines line
      WHERE line.company_id=document.company_id AND line.sales_order_id=document.id),'[]'::jsonb)
  ) FROM public.backoffice_sales_orders document
  WHERE document.company_id=p_company_id AND document.id=p_order_id
$$;

CREATE FUNCTION private.apply_backoffice_sales_commercials(
  p_company_id uuid,p_order_id uuid,p_actor_id uuid,p_payload jsonb,
  p_resolved_at timestamptz
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
  v_line jsonb;v_product_uom uuid;v_type text;v_input numeric;
  v_global numeric:=COALESCE((p_payload->>'globalDiscount')::numeric,0);
  v_rounding text:=upper(btrim(COALESCE(p_payload->>'roundingDirection','NONE')));
  v_increment numeric:=COALESCE((p_payload->>'roundingIncrement')::numeric,100);
  v_pre_global numeric;v_residual numeric;v_subtotal numeric;v_item_discount numeric;
  v_before numeric;v_after numeric;
BEGIN
  FOR v_line IN SELECT value FROM jsonb_array_elements(p_payload->'lines') LOOP
    v_product_uom:=(v_line->>'productUomId')::uuid;
    v_type:=upper(NULLIF(btrim(COALESCE(v_line->>'lineDiscountType','')),''));
    v_input:=COALESCE((v_line->>'lineDiscountInput')::numeric,0);
    UPDATE public.backoffice_sales_order_lines target SET
      canonical_unit_price=COALESCE(
        NULLIF(target.pricing_snapshot->>'canonicalResolvedUnitPrice','')::numeric,
        target.unit_price),
      price_override_applied=COALESCE(
        (target.pricing_snapshot->>'priceOverrideApplied')::boolean,false),
      price_override_unit_price=CASE WHEN COALESCE(
        (target.pricing_snapshot->>'priceOverrideApplied')::boolean,false)
        THEN target.unit_price END,
      line_discount_type=v_type,
      line_discount_input=CASE WHEN v_type IS NULL THEN NULL ELSE v_input END,
      line_discount_amount=CASE v_type
        WHEN 'AMOUNT' THEN round(v_input,4)
        WHEN 'PERCENT' THEN round(target.line_subtotal*v_input/100,4)
        ELSE 0 END,
      allocated_order_discount_amount=0,
      discount_amount=CASE v_type
        WHEN 'AMOUNT' THEN round(v_input,4)
        WHEN 'PERCENT' THEN round(target.line_subtotal*v_input/100,4)
        ELSE 0 END,
      updated_by=p_actor_id,updated_at=clock_timestamp()
    WHERE target.company_id=p_company_id AND target.sales_order_id=p_order_id
      AND target.pricing_snapshot->>'productUomId'=v_product_uom::text;
    IF NOT FOUND THEN RAISE EXCEPTION 'BACKOFFICE_SALES_ORDER_LINE_INVALID'; END IF;
    IF EXISTS(SELECT 1 FROM public.backoffice_sales_order_lines target
      WHERE target.company_id=p_company_id AND target.sales_order_id=p_order_id
        AND target.pricing_snapshot->>'productUomId'=v_product_uom::text
        AND target.line_discount_amount>target.line_subtotal) THEN
      RAISE EXCEPTION 'LINE_DISCOUNT_EXCEEDS_LINE_TOTAL';
    END IF;
  END LOOP;

  SELECT COALESCE(sum(line_total),0) INTO v_pre_global
  FROM public.backoffice_sales_order_lines
  WHERE company_id=p_company_id AND sales_order_id=p_order_id;
  IF v_global>v_pre_global THEN RAISE EXCEPTION 'GLOBAL_DISCOUNT_EXCEEDS_SALE_TOTAL'; END IF;
  IF v_global>0 AND v_pre_global>0 THEN
    UPDATE public.backoffice_sales_order_lines SET
      allocated_order_discount_amount=round(v_global*line_total/v_pre_global,4),
      discount_amount=line_discount_amount+round(v_global*line_total/v_pre_global,4)
    WHERE company_id=p_company_id AND sales_order_id=p_order_id;
    SELECT v_global-COALESCE(sum(allocated_order_discount_amount),0) INTO v_residual
    FROM public.backoffice_sales_order_lines
    WHERE company_id=p_company_id AND sales_order_id=p_order_id;
    UPDATE public.backoffice_sales_order_lines SET
      allocated_order_discount_amount=allocated_order_discount_amount+v_residual,
      discount_amount=discount_amount+v_residual
    WHERE id=(SELECT id FROM public.backoffice_sales_order_lines
      WHERE company_id=p_company_id AND sales_order_id=p_order_id
      ORDER BY line_total DESC,id LIMIT 1);
  END IF;

  PERFORM private.apply_backoffice_sales_order_tax(
    p_company_id,p_order_id,p_resolved_at);
  SELECT COALESCE(sum(line_subtotal),0),COALESCE(sum(line_discount_amount),0),
    COALESCE(sum(line_total),0)
  INTO v_subtotal,v_item_discount,v_before
  FROM public.backoffice_sales_order_lines
  WHERE company_id=p_company_id AND sales_order_id=p_order_id;
  v_after:=round(CASE v_rounding
    WHEN 'DOWN' THEN floor(v_before/v_increment)*v_increment
    WHEN 'UP' THEN ceil(v_before/v_increment)*v_increment
    ELSE v_before END,4);
  IF v_before>0 AND v_after<>v_before THEN
    UPDATE public.backoffice_sales_order_lines SET
      allocated_document_rounding=round((v_after-v_before)*line_total/v_before,4)
    WHERE company_id=p_company_id AND sales_order_id=p_order_id;
    SELECT (v_after-v_before)-COALESCE(sum(allocated_document_rounding),0)
    INTO v_residual FROM public.backoffice_sales_order_lines
    WHERE company_id=p_company_id AND sales_order_id=p_order_id;
    UPDATE public.backoffice_sales_order_lines SET
      allocated_document_rounding=allocated_document_rounding+v_residual
    WHERE id=(SELECT id FROM public.backoffice_sales_order_lines
      WHERE company_id=p_company_id AND sales_order_id=p_order_id
      ORDER BY line_total DESC,id LIMIT 1);
  END IF;
  UPDATE public.backoffice_sales_orders SET subtotal=v_subtotal,
    discount_total=v_item_discount+v_global,global_discount=v_global,
    grand_total_before_rounding=v_before,rounding_direction=v_rounding,
    rounding_increment=v_increment,rounding_adjustment=v_after-v_before,
    grand_total=v_after,
    commercial_snapshot=commercial_snapshot||jsonb_build_object(
      'pricingAuthority','CANONICAL_SERVER_WITH_BACKOFFICE_OVERRIDE',
      'discountAuthority','CANONICAL_SERVER',
      'roundingAuthority','CANONICAL_SERVER'),
    updated_by=p_actor_id,updated_at=clock_timestamp()
  WHERE company_id=p_company_id AND id=p_order_id;
END
$$;

-- Put the commercial calculator inside the existing atomic Save before its
-- immutable response/audit snapshots. Abort if the proven core drifted.
DO $patch_atomic_save$
DECLARE v_definition text;v_patched text;
  v_needle text:='v_after:=private.backoffice_sales_order_snapshot(v_company,v_document.id);';
  v_total_needle text:='subtotal=v_subtotal,discount_total=0,tax_total=0,grand_total=v_subtotal,';
BEGIN
  SELECT pg_get_functiondef(
    'public.save_backoffice_sales_order_draft_before_pricelist_header(uuid,bigint,uuid,jsonb)'::regprocedure
  ) INTO v_definition;
  IF (length(v_definition)-length(replace(v_definition,v_needle,'')))
       / nullif(length(v_needle),0)<>1 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: atomic Save snapshot boundary drift';
  END IF;
  v_patched:=replace(v_definition,v_needle,
    'PERFORM private.apply_backoffice_sales_commercials(v_company,v_document.id,v_actor,p_payload,v_resolved_at); '||v_needle);
  IF (length(v_patched)-length(replace(v_patched,v_total_needle,'')))
       / nullif(length(v_total_needle),0)<>1 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: atomic Save total boundary drift';
  END IF;
  v_patched:=replace(v_patched,v_total_needle,
    'subtotal=v_subtotal,discount_total=0,tax_total=0,grand_total_before_rounding=v_subtotal,grand_total=v_subtotal,');
  EXECUTE v_patched;
END
$patch_atomic_save$;

ALTER FUNCTION public.save_backoffice_sales_order_draft(uuid,bigint,uuid,jsonb)
  RENAME TO save_backoffice_sales_order_draft_before_commercial_parity;
REVOKE ALL ON FUNCTION public.save_backoffice_sales_order_draft_before_commercial_parity(uuid,bigint,uuid,jsonb)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.save_backoffice_sales_order_draft_before_commercial_parity(uuid,bigint,uuid,jsonb)
TO service_role;

CREATE FUNCTION public.save_backoffice_sales_order_draft(
  p_order_id uuid,p_expected_version bigint,p_operation_id uuid,p_payload jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
  v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
  v_line jsonb;v_product_uom uuid;v_override numeric;v_type text;v_input numeric;
  v_override_map jsonb:='{}'::jsonb;v_response jsonb;v_order_id uuid;
  v_pre_global numeric;v_global numeric;v_residual numeric;v_subtotal numeric;
  v_item_discount numeric;v_before numeric;v_after numeric;v_rounding text;v_increment numeric;
  v_resolved_at timestamptz;v_timezone text;v_final jsonb;
BEGIN
  IF p_payload IS NULL OR jsonb_typeof(p_payload)<>'object'
    OR jsonb_typeof(p_payload->'lines')<>'array' THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_ORDER_PAYLOAD_INVALID';
  END IF;
  BEGIN
    v_global:=COALESCE((p_payload->>'globalDiscount')::numeric,0);
    v_rounding:=upper(btrim(COALESCE(p_payload->>'roundingDirection','NONE')));
    v_increment:=COALESCE((p_payload->>'roundingIncrement')::numeric,100);
  EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'BACKOFFICE_SALES_COMMERCIAL_INPUT_INVALID'; END;
  IF v_global<0 OR v_rounding NOT IN('NONE','DOWN','UP') OR v_increment<=0 THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_COMMERCIAL_INPUT_INVALID';
  END IF;
  FOR v_line IN SELECT value FROM jsonb_array_elements(p_payload->'lines') LOOP
    BEGIN
      v_product_uom:=(v_line->>'productUomId')::uuid;
      v_type:=upper(NULLIF(btrim(COALESCE(v_line->>'lineDiscountType','')),''));
      v_input:=COALESCE((v_line->>'lineDiscountInput')::numeric,0);
      IF v_line ? 'overrideUnitPrice' AND jsonb_typeof(v_line->'overrideUnitPrice')<>'null' THEN
        v_override:=round((v_line->>'overrideUnitPrice')::numeric,4);
        IF v_override<0 OR v_override>999999999999999.9999 THEN
          RAISE EXCEPTION 'BACKOFFICE_PRICE_OVERRIDE_INVALID';
        END IF;
        IF v_override_map ? v_product_uom::text THEN
          RAISE EXCEPTION 'BACKOFFICE_SALES_ORDER_PRODUCT_UOM_DUPLICATE';
        END IF;
        v_override_map:=v_override_map||jsonb_build_object(v_product_uom::text,v_override);
      END IF;
    EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN
      RAISE EXCEPTION 'BACKOFFICE_SALES_COMMERCIAL_INPUT_INVALID';
    END;
    IF v_type IS NOT NULL AND v_type NOT IN('AMOUNT','PERCENT') THEN
      RAISE EXCEPTION 'LINE_DISCOUNT_TYPE_INVALID';
    END IF;
    IF v_input<0 OR (v_type='PERCENT' AND v_input>100) THEN
      RAISE EXCEPTION 'LINE_DISCOUNT_INVALID';
    END IF;
  END LOOP;
  PERFORM set_config('kgs.backoffice_price_override_map',v_override_map::text,true);
  v_response:=public.save_backoffice_sales_order_draft_before_commercial_parity(
    p_order_id,p_expected_version,p_operation_id,p_payload);
  -- The proven atomic core now calculates commercial values before writing its
  -- immutable operation/audit snapshots. Its response is already final.
  RETURN v_response;
  IF COALESCE((v_response->>'exactRetry')::boolean,false) THEN RETURN v_response; END IF;
  v_order_id:=(v_response->'data'->>'id')::uuid;

  FOR v_line IN SELECT value FROM jsonb_array_elements(p_payload->'lines') LOOP
    v_product_uom:=(v_line->>'productUomId')::uuid;
    v_type:=upper(NULLIF(btrim(COALESCE(v_line->>'lineDiscountType','')),''));
    v_input:=COALESCE((v_line->>'lineDiscountInput')::numeric,0);
    UPDATE public.backoffice_sales_order_lines target SET
      canonical_unit_price=COALESCE(NULLIF(target.pricing_snapshot->>'canonicalResolvedUnitPrice','')::numeric,target.unit_price),
      price_override_applied=COALESCE((target.pricing_snapshot->>'priceOverrideApplied')::boolean,false),
      price_override_unit_price=CASE WHEN COALESCE((target.pricing_snapshot->>'priceOverrideApplied')::boolean,false) THEN target.unit_price END,
      line_discount_type=v_type,line_discount_input=CASE WHEN v_type IS NULL THEN NULL ELSE v_input END,
      line_discount_amount=CASE v_type WHEN 'AMOUNT' THEN round(v_input,4)
        WHEN 'PERCENT' THEN round(target.line_subtotal*v_input/100,4) ELSE 0 END,
      allocated_order_discount_amount=0,
      discount_amount=CASE v_type WHEN 'AMOUNT' THEN round(v_input,4)
        WHEN 'PERCENT' THEN round(target.line_subtotal*v_input/100,4) ELSE 0 END,
      updated_by=v_actor,updated_at=clock_timestamp()
    WHERE target.company_id=v_company AND target.sales_order_id=v_order_id
      AND target.pricing_snapshot->>'productUomId'=v_product_uom::text;
    IF NOT FOUND THEN RAISE EXCEPTION 'BACKOFFICE_SALES_ORDER_LINE_INVALID'; END IF;
    IF EXISTS(SELECT 1 FROM public.backoffice_sales_order_lines target
      WHERE target.company_id=v_company AND target.sales_order_id=v_order_id
        AND target.pricing_snapshot->>'productUomId'=v_product_uom::text
        AND target.line_discount_amount>target.line_subtotal) THEN
      RAISE EXCEPTION 'LINE_DISCOUNT_EXCEEDS_LINE_TOTAL';
    END IF;
  END LOOP;

  SELECT COALESCE(sum(line_total),0) INTO v_pre_global
  FROM public.backoffice_sales_order_lines WHERE company_id=v_company AND sales_order_id=v_order_id;
  IF v_global>v_pre_global THEN RAISE EXCEPTION 'GLOBAL_DISCOUNT_EXCEEDS_SALE_TOTAL'; END IF;
  IF v_global>0 AND v_pre_global>0 THEN
    UPDATE public.backoffice_sales_order_lines SET
      allocated_order_discount_amount=round(v_global*line_total/v_pre_global,4),
      discount_amount=line_discount_amount+round(v_global*line_total/v_pre_global,4)
    WHERE company_id=v_company AND sales_order_id=v_order_id;
    SELECT v_global-COALESCE(sum(allocated_order_discount_amount),0) INTO v_residual
    FROM public.backoffice_sales_order_lines WHERE company_id=v_company AND sales_order_id=v_order_id;
    UPDATE public.backoffice_sales_order_lines SET
      allocated_order_discount_amount=allocated_order_discount_amount+v_residual,
      discount_amount=discount_amount+v_residual
    WHERE id=(SELECT id FROM public.backoffice_sales_order_lines
      WHERE company_id=v_company AND sales_order_id=v_order_id ORDER BY line_total DESC,id LIMIT 1);
  END IF;

  SELECT timezone INTO v_timezone FROM public.companies WHERE id=v_company;
  v_resolved_at:=((p_payload->>'orderDate')||' 12:00:00')::timestamp AT TIME ZONE v_timezone;
  PERFORM private.apply_backoffice_sales_order_tax(v_company,v_order_id,v_resolved_at);
  SELECT COALESCE(sum(line_subtotal),0),COALESCE(sum(line_discount_amount),0),
    COALESCE(sum(line_total),0) INTO v_subtotal,v_item_discount,v_before
  FROM public.backoffice_sales_order_lines WHERE company_id=v_company AND sales_order_id=v_order_id;
  v_after:=round(CASE v_rounding WHEN 'DOWN' THEN floor(v_before/v_increment)*v_increment
    WHEN 'UP' THEN ceil(v_before/v_increment)*v_increment ELSE v_before END,4);
  IF v_before>0 AND v_after<>v_before THEN
    UPDATE public.backoffice_sales_order_lines SET
      allocated_document_rounding=round((v_after-v_before)*line_total/v_before,4)
    WHERE company_id=v_company AND sales_order_id=v_order_id;
    SELECT (v_after-v_before)-COALESCE(sum(allocated_document_rounding),0) INTO v_residual
    FROM public.backoffice_sales_order_lines WHERE company_id=v_company AND sales_order_id=v_order_id;
    UPDATE public.backoffice_sales_order_lines SET allocated_document_rounding=allocated_document_rounding+v_residual
    WHERE id=(SELECT id FROM public.backoffice_sales_order_lines
      WHERE company_id=v_company AND sales_order_id=v_order_id ORDER BY line_total DESC,id LIMIT 1);
  END IF;
  UPDATE public.backoffice_sales_orders SET subtotal=v_subtotal,
    discount_total=v_item_discount+v_global,global_discount=v_global,
    grand_total_before_rounding=v_before,rounding_direction=v_rounding,
    rounding_increment=v_increment,rounding_adjustment=v_after-v_before,grand_total=v_after,
    commercial_snapshot=commercial_snapshot||jsonb_build_object(
      'pricingAuthority','CANONICAL_SERVER_WITH_BACKOFFICE_OVERRIDE',
      'discountAuthority','CANONICAL_SERVER','roundingAuthority','CANONICAL_SERVER'),
    updated_by=v_actor,updated_at=clock_timestamp()
  WHERE company_id=v_company AND id=v_order_id;
  v_final:=private.backoffice_sales_order_snapshot(v_company,v_order_id);
  v_response:=jsonb_build_object('companyId',v_company,'data',v_final,'exactRetry',false);
  UPDATE public.backoffice_sales_order_operations SET response_snapshot=v_response
  WHERE company_id=v_company AND operation_id=p_operation_id;
  UPDATE public.backoffice_sales_order_audit SET after_state=v_final
  WHERE company_id=v_company AND operation_id=p_operation_id;
  RETURN v_response;
END
$$;

CREATE FUNCTION public.preview_backoffice_sales_order_lines(
  p_store_id uuid,p_customer_id uuid,p_pricelist_id uuid,p_order_date date,
  p_lines jsonb
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
  v_company uuid:=public.private_active_company_id();v_timezone text;
  v_resolved_at timestamptz;v_line jsonb;v_product_uom uuid;v_qty numeric;
  v_price jsonb;v_tax jsonb;v_rows jsonb:='[]'::jsonb;
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'sales.backoffice_orders','VIEW');
  IF p_order_date IS NULL OR jsonb_typeof(p_lines)<>'array' THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_ORDER_PAYLOAD_INVALID';
  END IF;
  SELECT timezone INTO v_timezone FROM public.companies
  WHERE id=v_company AND status='ACTIVE';
  IF v_timezone IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_NOT_FOUND'; END IF;
  v_resolved_at:=(p_order_date::text||' 12:00:00')::timestamp AT TIME ZONE v_timezone;
  PERFORM set_config('kgs.selected_pricelist_id',COALESCE(p_pricelist_id::text,''),true);
  PERFORM set_config('kgs.backoffice_pricelist_id',COALESCE(p_pricelist_id::text,''),true);
  FOR v_line IN SELECT value FROM jsonb_array_elements(p_lines) LOOP
    BEGIN
      v_product_uom:=(v_line->>'productUomId')::uuid;
      v_qty:=(v_line->>'quantity')::numeric;
    EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'BACKOFFICE_SALES_ORDER_LINE_INVALID'; END;
    IF v_product_uom IS NULL OR v_qty IS NULL OR v_qty<=0 THEN
      RAISE EXCEPTION 'BACKOFFICE_SALES_ORDER_LINE_INVALID';
    END IF;
    v_price:=private.resolve_pos_sale_price_before_backoffice_commercial(
      v_company,p_store_id,p_customer_id,v_product_uom,v_qty,v_resolved_at);
    v_tax:=private.resolve_product_tax_rule(
      v_company,(v_price->>'productId')::uuid,'SALES',v_resolved_at);
    v_rows:=v_rows||jsonb_build_array(jsonb_build_object(
      'productUomId',v_product_uom,
      'canonicalUnitPrice',(v_price->>'resolvedUnitPrice')::numeric,
      'pricelistId',NULLIF(v_price->>'pricelistId','')::uuid,
      'pricelistName',v_price->>'pricelistName',
      'taxApplied',COALESCE((v_tax->>'taxApplied')::boolean,false),
      'taxName',v_tax->>'taxName','taxRatePercent',v_tax->>'ratePercent',
      'taxPriceMode',v_tax->>'priceMode'));
  END LOOP;
  RETURN jsonb_build_object('companyId',v_company,'resolvedAt',v_resolved_at,'lines',v_rows);
END
$$;

REVOKE ALL ON FUNCTION private.resolve_pos_sale_price_before_backoffice_commercial(uuid,uuid,uuid,uuid,numeric,timestamptz),
  private.resolve_pos_sale_price(uuid,uuid,uuid,uuid,numeric,timestamptz),
  private.apply_backoffice_sales_commercials(uuid,uuid,uuid,jsonb,timestamptz),
  public.save_backoffice_sales_order_draft(uuid,bigint,uuid,jsonb),
  public.preview_backoffice_sales_order_lines(uuid,uuid,uuid,date,jsonb)
FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION private.resolve_pos_sale_price_before_backoffice_commercial(uuid,uuid,uuid,uuid,numeric,timestamptz),
  private.resolve_pos_sale_price(uuid,uuid,uuid,uuid,numeric,timestamptz),
  private.apply_backoffice_sales_commercials(uuid,uuid,uuid,jsonb,timestamptz)
FROM authenticated;
GRANT EXECUTE ON FUNCTION private.resolve_pos_sale_price_before_backoffice_commercial(uuid,uuid,uuid,uuid,numeric,timestamptz),
  private.resolve_pos_sale_price(uuid,uuid,uuid,uuid,numeric,timestamptz),
  private.apply_backoffice_sales_commercials(uuid,uuid,uuid,jsonb,timestamptz)
TO service_role;
GRANT EXECUTE ON FUNCTION public.save_backoffice_sales_order_draft(uuid,bigint,uuid,jsonb),
  public.preview_backoffice_sales_order_lines(uuid,uuid,uuid,date,jsonb)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260909140000','backoffice_sales_commercial_parity',
  'Draft-only Backoffice canonical price override, line/global discount, inclusive tax snapshot and rounding; zero Reservation, Stock, Delivery, Invoice, Payment or Finance effect');
NOTIFY pgrst,'reload schema';
COMMIT;
