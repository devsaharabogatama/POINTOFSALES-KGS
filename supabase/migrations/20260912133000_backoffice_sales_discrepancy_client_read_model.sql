-- Step 4/6.5C4: tenant-scoped discrepancy read model for the existing SO and
-- Surat Jalan clients. Mutations remain delegated to the canonical RPC chain.
BEGIN;

DO $guard$
DECLARE v_definition text;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260912132000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: C3 Finance catalog fix required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260912133000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260912133000';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
    WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
  IF to_regprocedure('public.get_backoffice_sales_discrepancy_workspace(uuid,uuid)') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: discrepancy client read model collision';
  END IF;
  SELECT pg_get_functiondef(to_regprocedure(
    'public.approve_backoffice_sales_delivery_overage(uuid,bigint,uuid,jsonb,text)'))
  INTO STRICT v_definition;
  IF position('''SALES_ADMIN''' in v_definition)=0
    OR position('''SALES''' in v_definition)>0 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Sales approval role boundary drift';
  END IF;
END
$guard$;

CREATE FUNCTION public.get_backoffice_sales_discrepancy_workspace(
  p_sales_order_id uuid DEFAULT NULL,p_delivery_order_id uuid DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='15s' AS $$
DECLARE
  v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
  v_cases jsonb;v_lines jsonb;v_taxes jsonb;v_product_uoms jsonb;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
  IF p_sales_order_id IS NOT NULL AND p_delivery_order_id IS NOT NULL THEN
    RAISE EXCEPTION 'BACKOFFICE_DISCREPANCY_FILTER_INVALID';
  END IF;
  IF p_sales_order_id IS NOT NULL THEN
    PERFORM private.acp_require_permission_capability(
      v_company,'sales.backoffice_orders','VIEW');
    IF NOT EXISTS(SELECT 1 FROM public.backoffice_sales_orders document
      WHERE document.company_id=v_company AND document.id=p_sales_order_id) THEN
      RAISE EXCEPTION 'BACKOFFICE_SALES_ORDER_NOT_FOUND';
    END IF;
  ELSE
    PERFORM private.acp_require_permission_capability(
      v_company,'inventory.delivery_documents','VIEW');
    IF p_delivery_order_id IS NOT NULL AND NOT EXISTS(
      SELECT 1 FROM public.backoffice_sales_delivery_orders delivery
      WHERE delivery.company_id=v_company AND delivery.id=p_delivery_order_id) THEN
      RAISE EXCEPTION 'BACKOFFICE_DELIVERY_NOT_FOUND';
    END IF;
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',header.id,'discrepancyNo',header.discrepancy_no,
    'deliveryOrderId',header.delivery_order_id,'salesOrderId',header.sales_order_id,
    'receiptId',header.receipt_id,'status',header.status,
    'totalDiscrepancyBaseQty',header.total_discrepancy_base_qty,
    'requiresSalesApproval',header.requires_sales_approval,
    'requiresWarehouseResolution',header.requires_warehouse_resolution,
    'masterVersion',header.master_version,'createdAt',header.created_at,
    'updatedAt',header.updated_at,'resolvedAt',header.resolved_at
  ) ORDER BY header.created_at,header.id),'[]'::jsonb) INTO v_cases
  FROM public.backoffice_sales_delivery_discrepancies header
  WHERE header.company_id=v_company
    AND (p_sales_order_id IS NULL OR header.sales_order_id=p_sales_order_id)
    AND (p_delivery_order_id IS NULL OR header.delivery_order_id=p_delivery_order_id);

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',line.id,'discrepancyId',line.discrepancy_id,
    'deliveryOrderId',line.delivery_order_id,'salesOrderId',line.sales_order_id,
    'deliveryOrderLineId',line.delivery_order_line_id,
    'salesOrderLineId',line.sales_order_line_id,
    'discrepancyType',line.discrepancy_type,
    'requestedResolution',line.requested_resolution,
    'physicalState',line.physical_state,
    'quantityUom',line.quantity_uom,'quantityBase',line.quantity_base,
    'commercialApprovalStatus',line.commercial_approval_status,
    'warehouseResolutionStatus',line.warehouse_resolution_status,
    'reason',line.reason,
    'expectedProductId',line.expected_product_id,
    'expectedProductCode',delivery_line.product_code_snapshot,
    'expectedProductName',delivery_line.product_name_snapshot,
    'uomId',line.uom_id,'uomCode',delivery_line.uom_code_snapshot,
    'uomName',delivery_line.uom_name_snapshot,
    'actualProductId',line.actual_product_id,'actualProductCode',actual_product.sku,
    'actualProductName',actual_product.name,'actualUomId',line.actual_uom_id,
    'actualUomName',actual_uom.name,'actualQuantityUom',line.actual_quantity_uom,
    'actualQuantityBase',line.actual_quantity_base,
    'sourceUnitPrice',CASE WHEN p_sales_order_id IS NOT NULL THEN order_line.unit_price END,
    'sourceDiscountAmount',CASE WHEN p_sales_order_id IS NOT NULL
      AND order_line.ordered_base_qty>0
      THEN round(order_line.discount_amount*line.quantity_base/order_line.ordered_base_qty,4)
      WHEN p_sales_order_id IS NOT NULL THEN 0 END,
    'sourceTaxRuleId',CASE WHEN p_sales_order_id IS NOT NULL THEN order_line.tax_rule_id END,
    'sourceTaxName',CASE WHEN p_sales_order_id IS NOT NULL THEN order_line.tax_name_snapshot END,
    'sourceTaxRatePercent',CASE WHEN p_sales_order_id IS NOT NULL THEN order_line.tax_rate_percent_snapshot END,
    'approvedUnitPrice',CASE WHEN p_sales_order_id IS NOT NULL THEN line.approved_unit_price END,
    'approvedDiscountAmount',CASE WHEN p_sales_order_id IS NOT NULL THEN line.approved_discount_amount END,
    'approvedTaxAmount',CASE WHEN p_sales_order_id IS NOT NULL THEN line.approved_tax_amount END,
    'approvedLineTotal',CASE WHEN p_sales_order_id IS NOT NULL THEN line.approved_line_total END,
    'commercialSnapshot',CASE WHEN p_sales_order_id IS NOT NULL THEN line.commercial_snapshot END
  ) ORDER BY delivery_line.line_no,line.created_at,line.id),'[]'::jsonb) INTO v_lines
  FROM public.backoffice_sales_delivery_discrepancy_lines line
  JOIN public.backoffice_sales_delivery_discrepancies header
    ON header.company_id=line.company_id AND header.id=line.discrepancy_id
  JOIN public.backoffice_sales_delivery_order_lines delivery_line
    ON delivery_line.company_id=line.company_id AND delivery_line.id=line.delivery_order_line_id
  JOIN public.backoffice_sales_order_lines order_line
    ON order_line.company_id=line.company_id AND order_line.id=line.sales_order_line_id
  LEFT JOIN public.products actual_product
    ON actual_product.company_id=line.company_id AND actual_product.id=line.actual_product_id
  LEFT JOIN public.uoms actual_uom
    ON actual_uom.company_id=line.company_id AND actual_uom.id=line.actual_uom_id
  WHERE line.company_id=v_company
    AND (p_sales_order_id IS NULL OR line.sales_order_id=p_sales_order_id)
    AND (p_delivery_order_id IS NULL OR line.delivery_order_id=p_delivery_order_id);

  IF p_sales_order_id IS NOT NULL THEN
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',rule.id,'code',rule.tax_code,'name',rule.tax_name,
    'ratePercent',version.rate_percent,'priceMode',version.default_price_mode,
    'calculationScope',version.calculation_scope,'ruleVersion',version.rule_version
  ) ORDER BY rule.tax_name,rule.id),'[]'::jsonb) INTO v_taxes
  FROM public.tax_rules rule
  JOIN public.tax_rule_versions version
    ON version.company_id=rule.company_id AND version.tax_rule_id=rule.id
  WHERE rule.company_id=v_company AND rule.tax_scope='SALES' AND rule.is_active
    AND version.status='ACTIVE' AND version.effective_from<=statement_timestamp()
    AND (version.effective_to IS NULL OR version.effective_to>statement_timestamp())
    AND version.default_price_mode='INCLUSIVE'
    AND version.account_function_key='OUTPUT_TAX';
  ELSE
    v_taxes:='[]'::jsonb;
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'productUomId',product_uom.id,'productId',product.id,
    'productCode',product.sku,'productName',product.name,
    'uomId',uom.id,'uomCode',uom.code,'uomName',uom.name,
    'factorToBase',product_uom.factor_to_base
  ) ORDER BY product.name,uom.name,product_uom.id),'[]'::jsonb) INTO v_product_uoms
  FROM public.product_uoms product_uom
  JOIN public.products product
    ON product.company_id=product_uom.company_id AND product.id=product_uom.product_id
  JOIN public.uoms uom
    ON uom.company_id=product_uom.company_id AND uom.id=product_uom.uom_id
  WHERE product_uom.company_id=v_company AND product_uom.is_active
    AND product.is_active AND uom.is_active;

  RETURN jsonb_build_object('companyId',v_company,'workspaceVersion',1,
    'cases',v_cases,'lines',v_lines,'taxRules',v_taxes,
    'productUoms',v_product_uoms);
END
$$;

-- The approved Sales module policy gives SALES and SALES_ADMIN the same
-- operational capability. Keep the canonical core and only correct the public
-- role gate that previously omitted SALES.
CREATE OR REPLACE FUNCTION public.approve_backoffice_sales_delivery_overage(
  p_discrepancy_id uuid,p_expected_version bigint,p_operation_id uuid,
  p_payload jsonb,p_notes text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='30s' AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
BEGIN
  PERFORM private.acp_require_permission_capability(v_company,'sales.sales_orders','MANAGE');
  IF NOT public.private_is_super_admin(v_actor)
    AND NOT public.private_user_has_any_company_role(v_company,
      ARRAY['COMPANY_OWNER','COMPANY_ADMIN','SALES','SALES_ADMIN']::text[]) THEN
    RAISE EXCEPTION 'SALES_ROLE_REQUIRED';
  END IF;
  RETURN private.approve_backoffice_sales_delivery_overage_core(
    p_discrepancy_id,p_expected_version,p_operation_id,p_payload,p_notes);
END
$$;

REVOKE ALL ON FUNCTION public.get_backoffice_sales_discrepancy_workspace(uuid,uuid)
  FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_backoffice_sales_discrepancy_workspace(uuid,uuid)
  TO authenticated,service_role;
REVOKE ALL ON FUNCTION public.approve_backoffice_sales_delivery_overage(
  uuid,bigint,uuid,jsonb,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.approve_backoffice_sales_delivery_overage(
  uuid,bigint,uuid,jsonb,text) TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260912133000','backoffice_sales_discrepancy_client_read_model',
  'Step 4/6.5C4 exposes one tenant-scoped read model to existing SO/SJ clients and aligns Sales/Sales Admin approval role policy without changing canonical Stock or Finance mutation');

NOTIFY pgrst,'reload schema';
COMMIT;
