-- Forward-fix: connect Backoffice Quotation/SO to the existing canonical
-- inclusive SALES tax resolver/calculator. Development pilot only at rollout.
DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260909100000')
    OR to_regprocedure('private.resolve_product_tax_rule(uuid,uuid,text,timestamptz)') IS NULL
    OR to_regprocedure('private.calculate_tax_group(jsonb,numeric,text,text,text)') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical tax dependency';
  END IF;
  IF EXISTS(SELECT 1 FROM public.backoffice_sales_orders) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Backoffice pilot documents require explicit tax backfill';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
END
$guard$;

ALTER TABLE public.backoffice_sales_order_lines
  ADD COLUMN tax_rule_id uuid,
  ADD COLUMN tax_rule_version bigint,
  ADD COLUMN tax_code_snapshot text,
  ADD COLUMN tax_name_snapshot text,
  ADD COLUMN tax_rate_percent_snapshot numeric(12,6),
  ADD COLUMN tax_price_mode_snapshot text,
  ADD COLUMN tax_calculation_scope_snapshot text,
  ADD COLUMN tax_base numeric(20,4) NOT NULL DEFAULT 0,
  ADD COLUMN tax_rounding numeric(20,4) NOT NULL DEFAULT 0,
  ADD COLUMN tax_account_id uuid,
  ADD COLUMN tax_account_code_snapshot text,
  ADD COLUMN tax_account_name_snapshot text;

ALTER TABLE public.backoffice_sales_order_lines
  ALTER COLUMN line_total DROP EXPRESSION,
  ALTER COLUMN line_total SET DEFAULT 0;

ALTER TABLE public.backoffice_sales_order_lines
  ADD CONSTRAINT backoffice_sales_order_lines_tax_rule_fk
    FOREIGN KEY(company_id,tax_rule_id)
    REFERENCES public.tax_rules(company_id,id) ON DELETE RESTRICT,
  ADD CONSTRAINT backoffice_sales_order_lines_tax_contract CHECK(
    tax_base>=0 AND tax_amount>=0
    AND ((tax_rule_id IS NULL AND tax_rule_version IS NULL
      AND tax_code_snapshot IS NULL AND tax_name_snapshot IS NULL
      AND tax_rate_percent_snapshot IS NULL AND tax_price_mode_snapshot IS NULL
      AND tax_calculation_scope_snapshot IS NULL AND tax_account_id IS NULL
      AND tax_account_code_snapshot IS NULL AND tax_account_name_snapshot IS NULL
      AND tax_amount=0)
    OR (tax_rule_id IS NOT NULL AND tax_rule_version IS NOT NULL
      AND nullif(btrim(tax_code_snapshot),'') IS NOT NULL
      AND nullif(btrim(tax_name_snapshot),'') IS NOT NULL
      AND tax_rate_percent_snapshot BETWEEN 0 AND 100
      AND tax_price_mode_snapshot='INCLUSIVE'
      AND tax_calculation_scope_snapshot IN('PER_LINE','PER_DOCUMENT')
      AND tax_account_id IS NOT NULL
      AND nullif(btrim(tax_account_code_snapshot),'') IS NOT NULL
      AND nullif(btrim(tax_account_name_snapshot),'') IS NOT NULL))
  );

ALTER TABLE public.backoffice_sales_orders
  DROP CONSTRAINT backoffice_sales_orders_amount_check,
  ADD CONSTRAINT backoffice_sales_orders_amount_check CHECK(
    subtotal>=0 AND discount_total>=0 AND tax_total>=0
    AND discount_total<=subtotal AND tax_total<=grand_total
    AND grand_total=subtotal-discount_total
  );

CREATE FUNCTION private.trg_backoffice_sales_line_total()
RETURNS trigger LANGUAGE plpgsql SET search_path=public,pg_temp AS $$
BEGIN
  NEW.line_total:=round(NEW.ordered_qty*NEW.unit_price-NEW.discount_amount,4);
  RETURN NEW;
END
$$;

CREATE TRIGGER backoffice_sales_line_total
BEFORE INSERT OR UPDATE OF ordered_qty,unit_price,discount_amount
ON public.backoffice_sales_order_lines FOR EACH ROW
EXECUTE FUNCTION private.trg_backoffice_sales_line_total();

CREATE FUNCTION private.apply_backoffice_sales_order_tax(
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
    grand_total=subtotal-discount_total,
    commercial_snapshot=commercial_snapshot||jsonb_build_object(
      'taxScope','CANONICAL_SALES_INCLUSIVE','taxResolvedAt',p_resolved_at)
  WHERE company_id=p_company_id AND id=p_order_id;
END
$$;

CREATE FUNCTION private.trg_backoffice_sales_order_tax()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_timezone text;v_resolved_at timestamptz;
BEGIN
  IF NEW.status='DRAFT' AND NEW.commercial_snapshot->>'taxScope'='DEFERRED_ZERO' THEN
    SELECT timezone INTO v_timezone FROM public.companies WHERE id=NEW.company_id;
    v_resolved_at:=(NEW.order_date::text||' 12:00:00')::timestamp AT TIME ZONE v_timezone;
    PERFORM private.apply_backoffice_sales_order_tax(NEW.company_id,NEW.id,v_resolved_at);
  END IF;
  RETURN NEW;
END
$$;

CREATE TRIGGER backoffice_sales_order_tax
AFTER UPDATE OF commercial_snapshot ON public.backoffice_sales_orders
FOR EACH ROW EXECUTE FUNCTION private.trg_backoffice_sales_order_tax();

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
    'taxTotal',document.tax_total,'grandTotal',document.grand_total,
    'masterVersion',document.master_version,'createdAt',document.created_at,
    'updatedAt',document.updated_at,'sentAt',document.sent_at,
    'confirmedAt',document.confirmed_at,'canceledAt',document.canceled_at,
    'cancelReason',document.cancel_reason,
    'lines',COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'id',line.id,'lineNo',line.line_no,'productId',line.product_id,
      'uomId',line.uom_id,'orderedQty',line.ordered_qty,
      'baseQtyPerUom',line.base_qty_per_uom,'orderedBaseQty',line.ordered_base_qty,
      'unitPrice',line.unit_price,'lineSubtotal',line.line_subtotal,
      'discountAmount',line.discount_amount,'taxRuleId',line.tax_rule_id,
      'taxRuleVersion',line.tax_rule_version,'taxCode',line.tax_code_snapshot,
      'taxName',line.tax_name_snapshot,'taxRatePercent',line.tax_rate_percent_snapshot,
      'taxPriceMode',line.tax_price_mode_snapshot,
      'taxCalculationScope',line.tax_calculation_scope_snapshot,
      'taxBase',line.tax_base,'taxAmount',line.tax_amount,'taxRounding',line.tax_rounding,
      'lineTotal',line.line_total,'productCode',line.product_code_snapshot,
      'productName',line.product_name_snapshot,'uomCode',line.uom_code_snapshot,
      'uomName',line.uom_name_snapshot,'pricingSnapshot',line.pricing_snapshot,
      'masterVersion',line.master_version) ORDER BY line.line_no)
      FROM public.backoffice_sales_order_lines line
      WHERE line.company_id=document.company_id AND line.sales_order_id=document.id),'[]'::jsonb)
  ) FROM public.backoffice_sales_orders document
  WHERE document.company_id=p_company_id AND document.id=p_order_id
$$;

REVOKE ALL ON FUNCTION private.trg_backoffice_sales_line_total(),
  private.apply_backoffice_sales_order_tax(uuid,uuid,timestamptz),
  private.trg_backoffice_sales_order_tax() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.trg_backoffice_sales_line_total(),
  private.apply_backoffice_sales_order_tax(uuid,uuid,timestamptz),
  private.trg_backoffice_sales_order_tax() TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260909110000','backoffice_sales_canonical_tax_runtime',
  'Connect Backoffice Quotation/SO to canonical inclusive SALES tax resolver and snapshot; zero downstream fulfillment effect');
