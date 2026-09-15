-- Same-number SO revision, document tabs/filter read model, and fulfillment status foundation.
-- This migration does not create Reservation, Delivery, Stock, Invoice, Payment or Finance effects.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260909141000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical insert fix required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260909142000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260909142000';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
END
$guard$;

ALTER TABLE public.backoffice_sales_orders
  ADD COLUMN fulfillment_status text NOT NULL DEFAULT 'QUOTATION',
  ADD COLUMN fulfillment_status_updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  ADD COLUMN revision_count bigint NOT NULL DEFAULT 0,
  ADD COLUMN last_revised_at timestamptz,
  ADD COLUMN last_revised_by uuid REFERENCES public.profiles(id) ON DELETE RESTRICT;

UPDATE public.backoffice_sales_orders SET
  fulfillment_status=CASE status
    WHEN 'CONFIRMED' THEN 'CONFIRMED'
    WHEN 'CANCELED' THEN 'CANCELED'
    ELSE 'QUOTATION' END,
  fulfillment_status_updated_at=COALESCE(updated_at,created_at);

ALTER TABLE public.backoffice_sales_orders
  ADD CONSTRAINT backoffice_sales_orders_fulfillment_status_check CHECK(
    fulfillment_status IN('QUOTATION','CONFIRMED','PREPARING',
      'PARTIALLY_SHIPPED','IN_TRANSIT','COMPLETED','CANCELED')),
  ADD CONSTRAINT backoffice_sales_orders_revision_state_check CHECK(
    revision_count>=0
    AND ((last_revised_at IS NULL AND last_revised_by IS NULL)
      OR (last_revised_at IS NOT NULL AND last_revised_by IS NOT NULL))
    AND (revision_count=0 OR last_revised_at IS NOT NULL)),
  ADD CONSTRAINT backoffice_sales_orders_fulfillment_lifecycle_check CHECK(
    (status IN('DRAFT','SENT') AND fulfillment_status='QUOTATION')
    OR (status='CONFIRMED' AND fulfillment_status IN('CONFIRMED','PREPARING',
      'PARTIALLY_SHIPPED','IN_TRANSIT','COMPLETED'))
    OR (status='CANCELED' AND fulfillment_status='CANCELED'));

CREATE INDEX backoffice_sales_orders_company_fulfillment_date
  ON public.backoffice_sales_orders(company_id,fulfillment_status,order_date DESC,id);
CREATE INDEX backoffice_sales_orders_company_planned_delivery
  ON public.backoffice_sales_orders(company_id,planned_delivery_date DESC,id);
CREATE INDEX backoffice_sales_orders_company_due_date
  ON public.backoffice_sales_orders(company_id,due_date DESC,id) WHERE due_date IS NOT NULL;

CREATE FUNCTION private.trg_sync_backoffice_sales_fulfillment_status()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
BEGIN
  IF NEW.status IN('DRAFT','SENT') THEN
    NEW.fulfillment_status:='QUOTATION';
  ELSIF NEW.status='CANCELED' THEN
    NEW.fulfillment_status:='CANCELED';
  ELSIF NEW.status='CONFIRMED'
    AND (OLD.status IS DISTINCT FROM 'CONFIRMED'
      OR NEW.fulfillment_status='QUOTATION') THEN
    NEW.fulfillment_status:='CONFIRMED';
  END IF;
  IF NEW.fulfillment_status IS DISTINCT FROM OLD.fulfillment_status THEN
    NEW.fulfillment_status_updated_at:=clock_timestamp();
  END IF;
  RETURN NEW;
END
$$;

CREATE TRIGGER backoffice_sales_fulfillment_status_sync
BEFORE UPDATE OF status,fulfillment_status ON public.backoffice_sales_orders
FOR EACH ROW EXECUTE FUNCTION private.trg_sync_backoffice_sales_fulfillment_status();

ALTER TABLE public.backoffice_sales_order_audit
  DROP CONSTRAINT backoffice_sales_order_audit_action_check,
  ADD CONSTRAINT backoffice_sales_order_audit_action_check CHECK(
    action IN('CREATE','UPDATE','SEND','CONFIRM','REVISE','CANCEL'));

-- Extend the proven atomic save. A confirmed SO may only be revised while no
-- fulfillment has started. Later fulfillment phases must replace this guard
-- with an atomic Reservation/DO delta reconciler before opening more states.
DO $patch_atomic_revision$
DECLARE
  v_definition text;
  v_patched text;
  v_state_needle text:='IF v_document.status<>''DRAFT'' THEN RAISE EXCEPTION ''BACKOFFICE_SALES_ORDER_NOT_DRAFT''; END IF;';
  v_state_replacement text:='IF v_document.status NOT IN(''DRAFT'',''CONFIRMED'') THEN RAISE EXCEPTION ''BACKOFFICE_SALES_ORDER_EDIT_STATE_INVALID''; END IF; IF v_document.status=''CONFIRMED'' AND v_document.fulfillment_status<>''CONFIRMED'' THEN RAISE EXCEPTION ''BACKOFFICE_SALES_ORDER_REVISION_REQUIRES_RETURN_OR_FULFILLMENT_SYNC''; END IF; IF v_document.status=''CONFIRMED'' AND nullif(btrim(COALESCE(p_payload->>''revisionReason'','''')) ,'''') IS NULL THEN RAISE EXCEPTION ''BACKOFFICE_SALES_ORDER_REVISION_REASON_REQUIRED''; END IF;';
  v_update_needle text:='master_version=master_version+1,updated_by=v_actor,updated_at=clock_timestamp()';
  v_update_replacement text:='revision_count=revision_count+CASE WHEN v_document.status=''CONFIRMED'' THEN 1 ELSE 0 END,last_revised_at=CASE WHEN v_document.status=''CONFIRMED'' THEN clock_timestamp() ELSE last_revised_at END,last_revised_by=CASE WHEN v_document.status=''CONFIRMED'' THEN v_actor ELSE last_revised_by END,master_version=master_version+1,updated_by=v_actor,updated_at=clock_timestamp()';
  v_audit_columns text:='operation_id,action,actor_id,before_state,after_state)';
  v_audit_columns_new text:='operation_id,action,actor_id,reason,before_state,after_state)';
  v_audit_action text:='CASE WHEN v_before IS NULL THEN ''CREATE'' ELSE ''UPDATE'' END,';
  v_audit_action_new text:='CASE WHEN v_before IS NULL THEN ''CREATE'' WHEN v_before->>''status''=''CONFIRMED'' THEN ''REVISE'' ELSE ''UPDATE'' END,';
  v_audit_values text:='v_actor,v_before,v_after);';
  v_audit_values_new text:='v_actor,CASE WHEN v_before->>''status''=''CONFIRMED'' THEN nullif(btrim(p_payload->>''revisionReason''),'''') END,v_before,v_after);';
BEGIN
  SELECT pg_get_functiondef(
    'public.save_backoffice_sales_order_draft_before_pricelist_header(uuid,bigint,uuid,jsonb)'::regprocedure
  ) INTO v_definition;
  IF (length(v_definition)-length(replace(v_definition,v_state_needle,'')))
       / nullif(length(v_state_needle),0)<>1 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: edit state boundary drift';
  END IF;
  IF (length(v_definition)-length(replace(v_definition,v_update_needle,'')))
       / nullif(length(v_update_needle),0)<>1 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: revision metadata boundary drift';
  END IF;
  IF (length(v_definition)-length(replace(v_definition,v_audit_columns,'')))
       / nullif(length(v_audit_columns),0)<>1
    OR (length(v_definition)-length(replace(v_definition,v_audit_action,'')))
       / nullif(length(v_audit_action),0)<>1
    OR (length(v_definition)-length(replace(v_definition,v_audit_values,'')))
       / nullif(length(v_audit_values),0)<>1 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: revision audit boundary drift';
  END IF;
  v_patched:=replace(v_definition,v_state_needle,v_state_replacement);
  v_patched:=replace(v_patched,v_update_needle,v_update_replacement);
  v_patched:=replace(v_patched,v_audit_columns,v_audit_columns_new);
  v_patched:=replace(v_patched,v_audit_action,v_audit_action_new);
  v_patched:=replace(v_patched,v_audit_values,v_audit_values_new);
  EXECUTE v_patched;
END
$patch_atomic_revision$;

CREATE OR REPLACE FUNCTION private.backoffice_sales_order_snapshot(
  p_company_id uuid,p_order_id uuid
) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
  SELECT jsonb_build_object(
    'id',document.id,'quotationNo',document.quotation_no,'orderNo',document.order_no,
    'status',document.status,'fulfillmentStatus',document.fulfillment_status,
    'fulfillmentStatusUpdatedAt',document.fulfillment_status_updated_at,
    'salesOrigin',document.sales_origin,'salesProcessMode',document.sales_process_mode,
    'storeId',document.store_id,'warehouseId',document.warehouse_id,
    'customerId',document.customer_id,'pricelistId',document.pricelist_id,
    'orderDate',document.order_date,'plannedDeliveryDate',document.planned_delivery_date,
    'isTempo',document.is_tempo,'dueDate',document.due_date,
    'currencyCode',document.currency_code,'customerSnapshot',document.customer_snapshot,
    'commercialSnapshot',document.commercial_snapshot,'notes',document.notes,
    'subtotal',document.subtotal,'discountTotal',document.discount_total,
    'globalDiscount',document.global_discount,'taxTotal',document.tax_total,
    'grandTotalBeforeRounding',document.grand_total_before_rounding,
    'roundingDirection',document.rounding_direction,'roundingIncrement',document.rounding_increment,
    'roundingAdjustment',document.rounding_adjustment,'grandTotal',document.grand_total,
    'revisionCount',document.revision_count,'lastRevisedAt',document.last_revised_at,
    'lastRevisedBy',document.last_revised_by,
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

CREATE FUNCTION public.get_backoffice_sales_orders_v2(
  p_document_kind text DEFAULT NULL,p_fulfillment_status text DEFAULT NULL,
  p_date_basis text DEFAULT 'ORDER_DATE',p_date_from date DEFAULT NULL,
  p_date_to date DEFAULT NULL,p_search text DEFAULT NULL,p_limit integer DEFAULT 100
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
  v_company uuid:=public.private_active_company_id();
  v_kind text:=nullif(upper(btrim(COALESCE(p_document_kind,''))), '');
  v_fulfillment text:=nullif(upper(btrim(COALESCE(p_fulfillment_status,''))), '');
  v_basis text:=upper(btrim(COALESCE(p_date_basis,'ORDER_DATE')));
BEGIN
  PERFORM private.acp_require_permission_capability(v_company,'sales.backoffice_orders','VIEW');
  IF v_kind IS NOT NULL AND v_kind NOT IN('QUOTATION','SALES_ORDER') THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_DOCUMENT_KIND_INVALID';
  END IF;
  IF v_fulfillment IS NOT NULL AND v_fulfillment NOT IN('QUOTATION','CONFIRMED',
    'PREPARING','PARTIALLY_SHIPPED','IN_TRANSIT','COMPLETED','CANCELED') THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_FULFILLMENT_STATUS_INVALID';
  END IF;
  IF v_basis NOT IN('ORDER_DATE','DELIVERY_DATE','DUE_DATE')
    OR (p_date_from IS NOT NULL AND p_date_to IS NOT NULL AND p_date_to<p_date_from)
    OR p_limit IS NULL OR p_limit<1 OR p_limit>500 THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_FILTER_INVALID';
  END IF;
  RETURN jsonb_build_object('companyId',v_company,'data',COALESCE((
    SELECT jsonb_agg(private.backoffice_sales_order_snapshot(v_company,row_data.id)
      ORDER BY row_data.sort_date DESC,row_data.updated_at DESC,row_data.id)
    FROM (SELECT document.id,document.updated_at,
        CASE v_basis WHEN 'DELIVERY_DATE' THEN document.planned_delivery_date
          WHEN 'DUE_DATE' THEN document.due_date ELSE document.order_date END sort_date
      FROM public.backoffice_sales_orders document
      WHERE document.company_id=v_company
        AND (v_kind IS NULL OR (v_kind='QUOTATION' AND document.order_no IS NULL)
          OR (v_kind='SALES_ORDER' AND document.order_no IS NOT NULL))
        AND (v_fulfillment IS NULL OR document.fulfillment_status=v_fulfillment)
        AND (p_date_from IS NULL OR CASE v_basis
          WHEN 'DELIVERY_DATE' THEN document.planned_delivery_date
          WHEN 'DUE_DATE' THEN document.due_date ELSE document.order_date END>=p_date_from)
        AND (p_date_to IS NULL OR CASE v_basis
          WHEN 'DELIVERY_DATE' THEN document.planned_delivery_date
          WHEN 'DUE_DATE' THEN document.due_date ELSE document.order_date END<=p_date_to)
        AND (nullif(btrim(COALESCE(p_search,'')),'') IS NULL
          OR document.quotation_no ILIKE '%'||btrim(p_search)||'%'
          OR COALESCE(document.order_no,'') ILIKE '%'||btrim(p_search)||'%'
          OR document.customer_snapshot->>'name' ILIKE '%'||btrim(p_search)||'%'
          OR document.customer_snapshot->>'code' ILIKE '%'||btrim(p_search)||'%')
      ORDER BY sort_date DESC NULLS LAST,document.updated_at DESC,document.id
      LIMIT p_limit) row_data),'[]'::jsonb));
END
$$;

REVOKE ALL ON FUNCTION private.trg_sync_backoffice_sales_fulfillment_status(),
  public.get_backoffice_sales_orders_v2(text,text,text,date,date,text,integer)
FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION private.trg_sync_backoffice_sales_fulfillment_status()
FROM authenticated;
GRANT EXECUTE ON FUNCTION private.trg_sync_backoffice_sales_fulfillment_status()
TO service_role;
GRANT EXECUTE ON FUNCTION public.get_backoffice_sales_orders_v2(text,text,text,date,date,text,integer)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260909142000','backoffice_sales_revision_status_runtime',
  'Same-number audited SO revision while fulfillment has not started, server-derived fulfillment status foundation, and document/date filters; no operational downstream effect');

NOTIFY pgrst,'reload schema';
COMMIT;
