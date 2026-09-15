-- Immutable per-tax-group snapshot for Backoffice Regular/DP Invoice.
-- Additive preparation only: no Invoice posting, Event, Journal, Stock, or POS effect.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260909158000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Invoice digest fix required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260909159000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260909159000';
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
    WHERE status IN('POSTED','REVERSED') OR invoice_no IS NOT NULL
      OR financial_event_id IS NOT NULL OR posted_at IS NOT NULL) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: unexpected posted Invoice state';
  END IF;
  IF to_regprocedure('private.backoffice_sales_invoice_snapshot(uuid,uuid)') IS NULL
    OR to_regprocedure('private.save_backoffice_sales_invoice_draft_core(uuid,bigint,uuid,uuid,jsonb)') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Draft Invoice runtime missing';
  END IF;
  IF to_regclass('public.backoffice_sales_invoice_tax_breakdowns') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: tax breakdown relation collision';
  END IF;
  IF EXISTS(SELECT 1 FROM public.backoffice_sales_invoice_lines line
    JOIN public.backoffice_sales_invoices invoice ON invoice.company_id=line.company_id
      AND invoice.id=line.invoice_id
    WHERE line.tax_amount>0 AND invoice.invoice_type='REGULAR'
      AND (NULLIF(line.source_snapshot->>'taxRuleId','') IS NULL
        OR NULLIF(line.source_snapshot->>'taxRuleVersion','') IS NULL
        OR NULLIF(line.source_snapshot->>'taxAccountId','') IS NULL
        OR NULLIF(line.source_snapshot->>'taxCode','') IS NULL
        OR NULLIF(line.source_snapshot->>'taxName','') IS NULL
        OR NULLIF(line.source_snapshot->>'taxRatePercent','') IS NULL
        OR NULLIF(line.source_snapshot->>'taxPriceMode','') IS NULL
        OR NULLIF(line.source_snapshot->>'taxCalculationScope','') IS NULL)) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Regular tax snapshot incomplete';
  END IF;
  IF EXISTS(SELECT 1 FROM public.backoffice_sales_invoices invoice
    WHERE invoice.invoice_type='DOWN_PAYMENT' AND invoice.tax_total>0
      AND (invoice.down_payment_basis_total<=0 OR NOT EXISTS(SELECT 1
        FROM public.backoffice_sales_order_lines line
        WHERE line.company_id=invoice.company_id AND line.sales_order_id=invoice.sales_order_id
          AND line.tax_amount>0 AND line.tax_rule_id IS NOT NULL
          AND line.tax_rule_version IS NOT NULL AND line.tax_account_id IS NOT NULL))) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: DP tax snapshot incomplete';
  END IF;
  IF EXISTS(SELECT 1 FROM public.backoffice_sales_order_lines line
    LEFT JOIN public.tax_rule_versions version ON version.company_id=line.company_id
      AND version.tax_rule_id=line.tax_rule_id AND version.rule_version=line.tax_rule_version
    WHERE line.tax_amount>0 AND version.id IS NULL) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: tax version lineage missing';
  END IF;
END
$guard$;

CREATE TABLE public.backoffice_sales_invoice_tax_breakdowns(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL,
  invoice_id uuid NOT NULL,
  sales_order_id uuid NOT NULL,
  tax_group_no integer NOT NULL,
  tax_rule_id uuid NOT NULL,
  tax_rule_version bigint NOT NULL,
  tax_account_id uuid NOT NULL,
  tax_code_snapshot text NOT NULL,
  tax_name_snapshot text NOT NULL,
  tax_rate_percent numeric(20,6) NOT NULL,
  tax_price_mode text NOT NULL,
  tax_calculation_scope text NOT NULL,
  tax_base_amount numeric(24,4) NOT NULL,
  tax_amount numeric(24,4) NOT NULL,
  source_snapshot jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT backoffice_sales_invoice_tax_breakdowns_company_id_unique UNIQUE(company_id,id),
  CONSTRAINT backoffice_sales_invoice_tax_breakdowns_group_unique
    UNIQUE(company_id,invoice_id,tax_group_no),
  CONSTRAINT backoffice_sales_invoice_tax_breakdowns_invoice_fk
    FOREIGN KEY(company_id,invoice_id,sales_order_id)
    REFERENCES public.backoffice_sales_invoices(company_id,id,sales_order_id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_invoice_tax_breakdowns_rule_version_fk
    FOREIGN KEY(company_id,tax_rule_id,tax_rule_version)
    REFERENCES public.tax_rule_versions(company_id,tax_rule_id,rule_version) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_invoice_tax_breakdowns_account_fk
    FOREIGN KEY(company_id,tax_account_id)
    REFERENCES public.chart_of_accounts(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_invoice_tax_breakdowns_shape_check CHECK(
    tax_group_no>0 AND tax_rule_version>0
    AND nullif(btrim(tax_code_snapshot),'') IS NOT NULL
    AND nullif(btrim(tax_name_snapshot),'') IS NOT NULL
    AND tax_rate_percent>=0 AND tax_rate_percent<=100
    AND tax_price_mode IN('INCLUSIVE','EXCLUSIVE')
    AND tax_calculation_scope IN('PER_LINE','PER_DOCUMENT')
    AND tax_base_amount>=0 AND tax_amount>=0
    AND jsonb_typeof(source_snapshot)='object')
);

CREATE INDEX backoffice_sales_invoice_tax_breakdowns_invoice
  ON public.backoffice_sales_invoice_tax_breakdowns(company_id,invoice_id,tax_group_no);

ALTER TABLE public.backoffice_sales_invoice_tax_breakdowns ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.backoffice_sales_invoice_tax_breakdowns
  FROM PUBLIC,anon,authenticated;
GRANT ALL ON TABLE public.backoffice_sales_invoice_tax_breakdowns TO service_role;

CREATE FUNCTION private.rebuild_backoffice_sales_invoice_tax_breakdown(
  p_company_id uuid,p_invoice_id uuid
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_invoice public.backoffice_sales_invoices%rowtype;
  v_breakdown_tax numeric(24,4);
BEGIN
  SELECT * INTO STRICT v_invoice FROM public.backoffice_sales_invoices invoice
  WHERE invoice.company_id=p_company_id AND invoice.id=p_invoice_id;
  IF v_invoice.status NOT IN('DRAFT','CANCELED') THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_TAX_BREAKDOWN_NOT_EDITABLE';
  END IF;

  DELETE FROM public.backoffice_sales_invoice_tax_breakdowns breakdown
  WHERE breakdown.company_id=p_company_id AND breakdown.invoice_id=p_invoice_id;
  IF v_invoice.tax_total=0 THEN RETURN; END IF;

  IF v_invoice.invoice_type='REGULAR' THEN
    IF EXISTS(SELECT 1 FROM public.backoffice_sales_invoice_lines line
      WHERE line.company_id=p_company_id AND line.invoice_id=p_invoice_id
        AND line.tax_amount>0 AND (NULLIF(line.source_snapshot->>'taxRuleId','') IS NULL
          OR NULLIF(line.source_snapshot->>'taxRuleVersion','') IS NULL
          OR NULLIF(line.source_snapshot->>'taxAccountId','') IS NULL
          OR NULLIF(line.source_snapshot->>'taxCode','') IS NULL
          OR NULLIF(line.source_snapshot->>'taxName','') IS NULL
          OR NULLIF(line.source_snapshot->>'taxRatePercent','') IS NULL
          OR NULLIF(line.source_snapshot->>'taxPriceMode','') IS NULL
          OR NULLIF(line.source_snapshot->>'taxCalculationScope','') IS NULL)) THEN
      RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_TAX_SOURCE_INVALID';
    END IF;
    INSERT INTO public.backoffice_sales_invoice_tax_breakdowns(company_id,invoice_id,
      sales_order_id,tax_group_no,tax_rule_id,tax_rule_version,tax_account_id,
      tax_code_snapshot,tax_name_snapshot,tax_rate_percent,tax_price_mode,
      tax_calculation_scope,tax_base_amount,tax_amount,source_snapshot)
    SELECT p_company_id,p_invoice_id,v_invoice.sales_order_id,
      row_number() OVER(ORDER BY grouped.tax_account_id,grouped.tax_rule_id,
        grouped.tax_rule_version,grouped.tax_rate_percent),grouped.tax_rule_id,
      grouped.tax_rule_version,grouped.tax_account_id,grouped.tax_code,
      grouped.tax_name,grouped.tax_rate_percent,grouped.tax_price_mode,
      grouped.tax_scope,grouped.tax_base,grouped.tax_amount,
      jsonb_build_object('source','REGULAR_INVOICE_LINES','lineCount',grouped.line_count)
    FROM (SELECT (line.source_snapshot->>'taxRuleId')::uuid tax_rule_id,
        (line.source_snapshot->>'taxRuleVersion')::bigint tax_rule_version,
        (line.source_snapshot->>'taxAccountId')::uuid tax_account_id,
        line.source_snapshot->>'taxCode' tax_code,line.source_snapshot->>'taxName' tax_name,
        (line.source_snapshot->>'taxRatePercent')::numeric tax_rate_percent,
        line.source_snapshot->>'taxPriceMode' tax_price_mode,
        line.source_snapshot->>'taxCalculationScope' tax_scope,
        round(sum(line.line_amount),4) tax_base,round(sum(line.tax_amount),4) tax_amount,
        count(*) line_count
      FROM public.backoffice_sales_invoice_lines line
      WHERE line.company_id=p_company_id AND line.invoice_id=p_invoice_id
        AND line.tax_amount>0
      GROUP BY (line.source_snapshot->>'taxRuleId')::uuid,
        (line.source_snapshot->>'taxRuleVersion')::bigint,
        (line.source_snapshot->>'taxAccountId')::uuid,
        line.source_snapshot->>'taxCode',line.source_snapshot->>'taxName',
        (line.source_snapshot->>'taxRatePercent')::numeric,
        line.source_snapshot->>'taxPriceMode',
        line.source_snapshot->>'taxCalculationScope') grouped;
  ELSE
    IF v_invoice.down_payment_basis_total<=0 OR EXISTS(
      SELECT 1 FROM public.backoffice_sales_order_lines line
      WHERE line.company_id=p_company_id AND line.sales_order_id=v_invoice.sales_order_id
        AND line.tax_amount>0 AND (line.tax_rule_id IS NULL OR line.tax_rule_version IS NULL
          OR line.tax_account_id IS NULL OR nullif(btrim(line.tax_code_snapshot),'') IS NULL
          OR nullif(btrim(line.tax_name_snapshot),'') IS NULL
          OR line.tax_rate_percent_snapshot IS NULL OR line.tax_price_mode_snapshot IS NULL
          OR line.tax_calculation_scope_snapshot IS NULL)) THEN
      RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_TAX_SOURCE_INVALID';
    END IF;
    INSERT INTO public.backoffice_sales_invoice_tax_breakdowns(company_id,invoice_id,
      sales_order_id,tax_group_no,tax_rule_id,tax_rule_version,tax_account_id,
      tax_code_snapshot,tax_name_snapshot,tax_rate_percent,tax_price_mode,
      tax_calculation_scope,tax_base_amount,tax_amount,source_snapshot)
    WITH grouped AS (
      SELECT line.tax_rule_id,line.tax_rule_version,line.tax_account_id,
        line.tax_code_snapshot tax_code,line.tax_name_snapshot tax_name,
        line.tax_rate_percent_snapshot tax_rate_percent,
        line.tax_price_mode_snapshot tax_price_mode,
        line.tax_calculation_scope_snapshot tax_scope,
        round(sum(line.tax_base),4) source_tax_base,
        round(sum(line.tax_amount),4) source_tax_amount,count(*) line_count
      FROM public.backoffice_sales_order_lines line
      WHERE line.company_id=p_company_id AND line.sales_order_id=v_invoice.sales_order_id
        AND line.tax_amount>0
      GROUP BY line.tax_rule_id,line.tax_rule_version,line.tax_account_id,
        line.tax_code_snapshot,line.tax_name_snapshot,line.tax_rate_percent_snapshot,
        line.tax_price_mode_snapshot,line.tax_calculation_scope_snapshot
    ), rounded AS (
      SELECT grouped.*,
        row_number() OVER(ORDER BY tax_account_id,tax_rule_id,tax_rule_version,tax_rate_percent) group_no,
        count(*) OVER() group_count,
        round(source_tax_base*v_invoice.charge_total/v_invoice.down_payment_basis_total,4) allocated_base,
        round(source_tax_amount*v_invoice.charge_total/v_invoice.down_payment_basis_total,4) allocated_tax
      FROM grouped
    ), finalized AS (
      SELECT rounded.*,CASE WHEN group_no=group_count THEN allocated_tax+
          (v_invoice.tax_total-sum(allocated_tax) OVER()) ELSE allocated_tax END final_tax
      FROM rounded
    )
    SELECT p_company_id,p_invoice_id,v_invoice.sales_order_id,group_no,tax_rule_id,
      tax_rule_version,tax_account_id,tax_code,tax_name,tax_rate_percent,
      tax_price_mode,tax_scope,allocated_base,final_tax,
      jsonb_build_object('source','SALES_ORDER_TAX_GROUP','sourceTaxBase',source_tax_base,
        'sourceTaxAmount',source_tax_amount,'allocationBasis',v_invoice.charge_total,
        'orderDpp',v_invoice.down_payment_basis_total,'lineCount',line_count)
    FROM finalized;
  END IF;

  SELECT round(COALESCE(sum(breakdown.tax_amount),0),4) INTO v_breakdown_tax
  FROM public.backoffice_sales_invoice_tax_breakdowns breakdown
  WHERE breakdown.company_id=p_company_id AND breakdown.invoice_id=p_invoice_id;
  IF v_breakdown_tax<>round(v_invoice.tax_total,4) THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_TAX_BREAKDOWN_MISMATCH';
  END IF;
END
$$;

CREATE FUNCTION private.trg_rebuild_backoffice_sales_invoice_tax_breakdown()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
  IF NEW.status='DRAFT' THEN
    PERFORM private.rebuild_backoffice_sales_invoice_tax_breakdown(NEW.company_id,NEW.id);
  END IF;
  RETURN NEW;
END
$$;

CREATE TRIGGER backoffice_sales_invoice_tax_breakdown_rebuild
AFTER INSERT OR UPDATE OF charge_total,tax_total,down_payment_basis_total
ON public.backoffice_sales_invoices FOR EACH ROW
EXECUTE FUNCTION private.trg_rebuild_backoffice_sales_invoice_tax_breakdown();

-- Existing Development Draft/Canceled rows, if any, receive deterministic
-- breakdowns from their persisted Invoice/SO tax snapshots. No posted row is allowed.
DO $backfill$
DECLARE v_invoice record;
BEGIN
  FOR v_invoice IN SELECT invoice.company_id,invoice.id
    FROM public.backoffice_sales_invoices invoice
    WHERE invoice.status IN('DRAFT','CANCELED') ORDER BY invoice.company_id,invoice.id
  LOOP
    PERFORM private.rebuild_backoffice_sales_invoice_tax_breakdown(
      v_invoice.company_id,v_invoice.id);
  END LOOP;
END
$backfill$;

CREATE FUNCTION private.trg_guard_backoffice_sales_invoice_tax_breakdown_history()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_status text;
BEGIN
  SELECT invoice.status INTO STRICT v_status FROM public.backoffice_sales_invoices invoice
  WHERE invoice.company_id=OLD.company_id AND invoice.id=OLD.invoice_id;
  IF v_status<>'DRAFT' THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_TAX_BREAKDOWN_IMMUTABLE';
  END IF;
  IF TG_OP='DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END
$$;

CREATE TRIGGER backoffice_sales_invoice_tax_breakdown_history_guard
BEFORE UPDATE OR DELETE ON public.backoffice_sales_invoice_tax_breakdowns
FOR EACH ROW EXECUTE FUNCTION private.trg_guard_backoffice_sales_invoice_tax_breakdown_history();

CREATE OR REPLACE FUNCTION private.backoffice_sales_invoice_snapshot(
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
    'paymentTermId',invoice.payment_term_id,'paymentTermSnapshot',invoice.payment_term_snapshot,
    'customerSnapshot',invoice.customer_snapshot,'commercialSnapshot',invoice.commercial_snapshot,
    'downPaymentMode',invoice.down_payment_mode,'downPaymentInput',invoice.down_payment_input,
    'downPaymentBasisTotal',invoice.down_payment_basis_total,
    'chargeTotal',invoice.charge_total,'discountTotal',invoice.discount_total,
    'taxTotal',invoice.tax_total,'downPaymentDeductionTotal',invoice.down_payment_deduction_total,
    'grandTotal',invoice.grand_total,'notes',invoice.notes,
    'masterVersion',invoice.master_version,'createdAt',invoice.created_at,
    'updatedAt',invoice.updated_at,'canceledAt',invoice.canceled_at,'cancelReason',invoice.cancel_reason,
    'lines',COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'id',line.id,'lineNo',line.line_no,'lineType',line.line_type,
      'effectType',line.effect_type,'salesOrderLineId',line.sales_order_line_id,
      'productId',line.product_id,'uomId',line.uom_id,'quantityUom',line.quantity_uom,
      'baseQtyPerUom',line.base_qty_per_uom,'quantityBase',line.quantity_base,
      'unitPrice',line.unit_price,'discountAmount',line.discount_amount,
      'taxAmount',line.tax_amount,'lineAmount',line.line_amount,
      'description',line.description,'sourceSnapshot',line.source_snapshot) ORDER BY line.line_no)
      FROM public.backoffice_sales_invoice_lines line
      WHERE line.company_id=invoice.company_id AND line.invoice_id=invoice.id),'[]'::jsonb),
    'taxBreakdowns',COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'taxGroupNo',breakdown.tax_group_no,'taxRuleId',breakdown.tax_rule_id,
      'taxRuleVersion',breakdown.tax_rule_version,'taxAccountId',breakdown.tax_account_id,
      'taxCode',breakdown.tax_code_snapshot,'taxName',breakdown.tax_name_snapshot,
      'taxRatePercent',breakdown.tax_rate_percent,'taxPriceMode',breakdown.tax_price_mode,
      'taxCalculationScope',breakdown.tax_calculation_scope,
      'taxBaseAmount',breakdown.tax_base_amount,'taxAmount',breakdown.tax_amount,
      'sourceSnapshot',breakdown.source_snapshot) ORDER BY breakdown.tax_group_no)
      FROM public.backoffice_sales_invoice_tax_breakdowns breakdown
      WHERE breakdown.company_id=invoice.company_id AND breakdown.invoice_id=invoice.id),'[]'::jsonb),
    'schedules',COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'installmentNo',schedule.installment_no,'dueDate',schedule.due_date,
      'amountDue',schedule.amount_due,'status',schedule.status) ORDER BY schedule.installment_no)
      FROM public.backoffice_sales_invoice_receivable_schedules schedule
      WHERE schedule.company_id=invoice.company_id AND schedule.invoice_id=invoice.id),'[]'::jsonb)
  ) FROM public.backoffice_sales_invoices invoice
  WHERE invoice.company_id=p_company_id AND invoice.id=p_invoice_id
$$;

REVOKE ALL ON FUNCTION private.rebuild_backoffice_sales_invoice_tax_breakdown(uuid,uuid),
  private.trg_rebuild_backoffice_sales_invoice_tax_breakdown(),
  private.trg_guard_backoffice_sales_invoice_tax_breakdown_history()
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.rebuild_backoffice_sales_invoice_tax_breakdown(uuid,uuid),
  private.trg_rebuild_backoffice_sales_invoice_tax_breakdown(),
  private.trg_guard_backoffice_sales_invoice_tax_breakdown_history()
  TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260909159000','backoffice_sales_invoice_tax_breakdown',
  'Add immutable Regular/DP per-tax-group snapshots with proportional DP allocation; no posting, Event, Journal, Stock or POS effect');

NOTIFY pgrst,'reload schema';
COMMIT;
