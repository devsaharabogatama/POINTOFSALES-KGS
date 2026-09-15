-- Step 4/6.4: Sales Admin commercial approval for accepted delivery overage.
-- Approval records commercial facts only. Stock/FIFO/Reservation/DO/Invoice and
-- Finance effects remain deferred to the Warehouse resolution migration.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260911166000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: mixed Customer receipt runtime required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260912100000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260912100000';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
    WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
  IF EXISTS(SELECT 1 FROM public.backoffice_sales_delivery_discrepancy_lines
    WHERE commercial_approval_status='APPROVED') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: approved overage requires explicit commercial reconciliation';
  END IF;
  IF EXISTS(SELECT 1 FROM information_schema.columns
    WHERE table_schema='public'
      AND ((table_name='backoffice_sales_delivery_discrepancies'
          AND column_name='master_version')
        OR (table_name='backoffice_sales_delivery_discrepancy_lines'
          AND column_name IN('approved_unit_price','approved_discount_amount',
            'approved_tax_amount','approved_line_total','commercial_snapshot',
            'commercial_approved_by','commercial_approved_at'))))
    OR to_regprocedure('public.approve_backoffice_sales_delivery_overage(uuid,bigint,uuid,jsonb,text)') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: overage approval contract collision';
  END IF;
END
$guard$;

ALTER TABLE public.backoffice_sales_delivery_discrepancies
  ADD COLUMN master_version bigint NOT NULL DEFAULT 1,
  ADD CONSTRAINT backoffice_sales_delivery_discrepancies_version_check
    CHECK(master_version>0);

ALTER TABLE public.backoffice_sales_delivery_discrepancy_lines
  ADD COLUMN approved_unit_price numeric(20,4),
  ADD COLUMN approved_discount_amount numeric(20,4),
  ADD COLUMN approved_tax_amount numeric(20,4),
  ADD COLUMN approved_line_total numeric(20,4),
  ADD COLUMN commercial_snapshot jsonb,
  ADD COLUMN commercial_approved_by uuid,
  ADD COLUMN commercial_approved_at timestamptz,
  ADD CONSTRAINT backoffice_sales_delivery_discrepancy_lines_approved_by_fk
    FOREIGN KEY(commercial_approved_by)
    REFERENCES public.profiles(id) ON DELETE RESTRICT,
  ADD CONSTRAINT backoffice_sales_delivery_discrepancy_lines_commercial_shape CHECK(
    (commercial_approval_status='APPROVED'
      AND requested_resolution='ACCEPT_OVERAGE'
      AND approved_unit_price IS NOT NULL AND approved_unit_price>=0
      AND approved_discount_amount IS NOT NULL AND approved_discount_amount>=0
      AND approved_tax_amount IS NOT NULL AND approved_tax_amount>=0
      AND approved_line_total IS NOT NULL AND approved_line_total>=0
      AND approved_tax_amount<=approved_line_total
      AND approved_discount_amount<=quantity_uom*approved_unit_price
      AND approved_line_total=round(quantity_uom*approved_unit_price-approved_discount_amount,4)
      AND jsonb_typeof(commercial_snapshot)='object'
      AND commercial_approved_by IS NOT NULL AND commercial_approved_at IS NOT NULL)
    OR (commercial_approval_status<>'APPROVED'
      AND approved_unit_price IS NULL AND approved_discount_amount IS NULL
      AND approved_tax_amount IS NULL AND approved_line_total IS NULL
      AND commercial_snapshot IS NULL AND commercial_approved_by IS NULL
      AND commercial_approved_at IS NULL));

CREATE FUNCTION private.resolve_explicit_sales_tax_rule(
  p_company_id uuid,p_tax_rule_id uuid,p_resolved_at timestamptz
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_count bigint;v_rule record;
BEGIN
  IF p_company_id IS NULL OR p_tax_rule_id IS NULL OR p_resolved_at IS NULL THEN
    RAISE EXCEPTION 'OVERAGE_TAX_RULE_INPUT_REQUIRED';
  END IF;
  IF NOT public.private_company_feature_enabled(p_company_id,'tax_sales_enabled') THEN
    RAISE EXCEPTION 'SALES_TAX_FEATURE_DISABLED';
  END IF;
  SELECT count(*) INTO v_count
  FROM public.tax_rules rule
  JOIN public.tax_rule_versions version
    ON version.company_id=rule.company_id AND version.tax_rule_id=rule.id
  JOIN public.chart_of_accounts account
    ON account.company_id=version.company_id AND account.id=version.account_id
  WHERE rule.company_id=p_company_id AND rule.id=p_tax_rule_id
    AND rule.tax_scope='SALES' AND rule.is_active
    AND version.status='ACTIVE' AND version.effective_from<=p_resolved_at
    AND (version.effective_to IS NULL OR version.effective_to>p_resolved_at)
    AND version.default_price_mode='INCLUSIVE'
    AND version.account_function_key='OUTPUT_TAX'
    AND account.is_active AND account.is_postable;
  IF v_count<>1 THEN RAISE EXCEPTION 'CURRENT_SALES_TAX_RULE_REQUIRED'; END IF;
  SELECT rule.tax_code,rule.tax_name,version.rule_version,version.rate_percent,
    version.calculation_scope,version.default_price_mode,version.account_id,
    account.account_code,account.account_name
  INTO STRICT v_rule
  FROM public.tax_rules rule
  JOIN public.tax_rule_versions version
    ON version.company_id=rule.company_id AND version.tax_rule_id=rule.id
  JOIN public.chart_of_accounts account
    ON account.company_id=version.company_id AND account.id=version.account_id
  WHERE rule.company_id=p_company_id AND rule.id=p_tax_rule_id
    AND rule.tax_scope='SALES' AND rule.is_active
    AND version.status='ACTIVE' AND version.effective_from<=p_resolved_at
    AND (version.effective_to IS NULL OR version.effective_to>p_resolved_at)
    AND version.default_price_mode='INCLUSIVE'
    AND version.account_function_key='OUTPUT_TAX'
    AND account.is_active AND account.is_postable;
  RETURN jsonb_build_object('taxApplied',true,'taxRuleId',p_tax_rule_id,
    'ruleVersion',v_rule.rule_version,'taxCode',v_rule.tax_code,
    'taxName',v_rule.tax_name,'ratePercent',v_rule.rate_percent,
    'calculationScope',v_rule.calculation_scope,'priceMode',v_rule.default_price_mode,
    'taxAccountId',v_rule.account_id,'taxAccountCode',v_rule.account_code,
    'taxAccountName',v_rule.account_name,'resolvedAt',p_resolved_at);
END
$$;

CREATE FUNCTION private.approve_backoffice_sales_delivery_overage_core(
  p_discrepancy_id uuid,p_expected_version bigint,p_operation_id uuid,
  p_payload jsonb,p_notes text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='30s' AS $$
DECLARE
  v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
  v_header public.backoffice_sales_delivery_discrepancies%rowtype;
  v_existing public.backoffice_sales_discrepancy_operations%rowtype;
  v_item jsonb;v_line record;v_source record;v_tax jsonb;v_tax_result jsonb;
  v_tax_line jsonb;v_request jsonb;v_result jsonb;v_now timestamptz:=clock_timestamp();
  v_line_id uuid;v_unit numeric;v_discount numeric;v_gross numeric;v_net numeric;
  v_tax_amount numeric;v_tax_applied boolean;v_tax_rule_id uuid;
  v_pending_count bigint;v_payload_count bigint;v_updated bigint:=0;
  v_seen uuid[]:='{}'::uuid[];v_snapshot jsonb;v_status text;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
  IF p_discrepancy_id IS NULL OR p_operation_id IS NULL THEN
    RAISE EXCEPTION 'OVERAGE_APPROVAL_ID_REQUIRED';
  END IF;
  IF p_payload IS NULL OR jsonb_typeof(p_payload)<>'object'
    OR jsonb_typeof(p_payload->'lines')<>'array'
    OR jsonb_array_length(p_payload->'lines')=0
    OR jsonb_array_length(p_payload->'lines')>500
    OR length(COALESCE(p_notes,''))>500 THEN
    RAISE EXCEPTION 'OVERAGE_APPROVAL_PAYLOAD_INVALID';
  END IF;
  v_request:=jsonb_build_object('discrepancyId',p_discrepancy_id,
    'expectedVersion',p_expected_version,'payload',p_payload,
    'notes',NULLIF(btrim(p_notes),''));

  -- Serialize operation identity before reading immutable replay history. This
  -- makes concurrent identical calls converge to the same stored response.
  PERFORM pg_advisory_xact_lock(hashtextextended(
    v_company::text||':BACKOFFICE_OVERAGE_APPROVAL:'||p_operation_id::text,0));

  SELECT * INTO v_existing FROM public.backoffice_sales_discrepancy_operations operation
  WHERE operation.company_id=v_company AND operation.id=p_operation_id;
  IF FOUND THEN
    IF v_existing.operation_type='SALES_APPROVE_OVERAGE'
      AND v_existing.discrepancy_id=p_discrepancy_id
      AND v_existing.request_payload=v_request AND v_existing.completed_at IS NOT NULL THEN
      RETURN v_existing.result_payload||jsonb_build_object('exactRetry',true);
    END IF;
    RAISE EXCEPTION 'IDEMPOTENCY_PAYLOAD_CONFLICT';
  END IF;

  SELECT * INTO v_header FROM public.backoffice_sales_delivery_discrepancies discrepancy
  WHERE discrepancy.company_id=v_company AND discrepancy.id=p_discrepancy_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'BACKOFFICE_DISCREPANCY_NOT_FOUND'; END IF;
  IF v_header.status<>'PENDING_SALES_APPROVAL' THEN
    RAISE EXCEPTION 'BACKOFFICE_DISCREPANCY_SALES_APPROVAL_NOT_PENDING';
  END IF;
  IF p_expected_version IS NULL OR p_expected_version<>v_header.master_version THEN
    RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
  END IF;

  SELECT count(*) INTO v_pending_count
  FROM public.backoffice_sales_delivery_discrepancy_lines line
  WHERE line.company_id=v_company AND line.discrepancy_id=p_discrepancy_id
    AND line.requested_resolution='ACCEPT_OVERAGE'
    AND line.commercial_approval_status='PENDING';
  v_payload_count:=jsonb_array_length(p_payload->'lines');
  IF v_pending_count=0 OR v_payload_count<>v_pending_count THEN
    RAISE EXCEPTION 'OVERAGE_APPROVAL_LINE_SET_INVALID';
  END IF;

  FOR v_item IN SELECT value FROM jsonb_array_elements(p_payload->'lines') LOOP
    IF jsonb_typeof(v_item)<>'object' THEN RAISE EXCEPTION 'OVERAGE_APPROVAL_PAYLOAD_INVALID'; END IF;
    BEGIN v_line_id:=(v_item->>'discrepancyLineId')::uuid;
    EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'OVERAGE_APPROVAL_LINE_ID_INVALID'; END;
    IF v_line_id IS NULL OR v_line_id=ANY(v_seen) THEN
      RAISE EXCEPTION 'OVERAGE_APPROVAL_LINE_ID_INVALID';
    END IF;
    v_seen:=array_append(v_seen,v_line_id);
    SELECT line.*,order_line.unit_price source_unit_price,
      order_line.discount_amount source_discount_amount,
      order_line.ordered_base_qty source_ordered_base_qty,
      order_line.tax_rule_id source_tax_rule_id,
      order_line.tax_rule_version source_tax_rule_version,
      order_line.tax_code_snapshot source_tax_code,
      order_line.tax_name_snapshot source_tax_name,
      order_line.tax_rate_percent_snapshot source_tax_rate,
      order_line.tax_price_mode_snapshot source_tax_price_mode,
      order_line.tax_calculation_scope_snapshot source_tax_scope,
      order_line.tax_account_id source_tax_account_id,
      order_line.tax_account_code_snapshot source_tax_account_code,
      order_line.tax_account_name_snapshot source_tax_account_name,
      order_line.pricing_snapshot source_pricing_snapshot
    INTO STRICT v_line
    FROM public.backoffice_sales_delivery_discrepancy_lines line
    JOIN public.backoffice_sales_order_lines order_line
      ON order_line.company_id=line.company_id AND order_line.id=line.sales_order_line_id
    WHERE line.company_id=v_company AND line.discrepancy_id=p_discrepancy_id
      AND line.id=v_line_id AND line.requested_resolution='ACCEPT_OVERAGE'
      AND line.commercial_approval_status='PENDING' FOR UPDATE OF line;

    BEGIN
      v_unit:=round(CASE WHEN v_item ? 'unitPrice' THEN (v_item->>'unitPrice')::numeric
        ELSE v_line.source_unit_price END,4);
      v_discount:=round(CASE WHEN v_item ? 'discountAmount'
        THEN (v_item->>'discountAmount')::numeric
        ELSE v_line.source_discount_amount*v_line.quantity_base
          /v_line.source_ordered_base_qty END,4);
      v_tax_applied:=CASE WHEN v_item ? 'taxApplied'
        THEN (v_item->>'taxApplied')::boolean
        WHEN NULLIF(v_item->>'taxRuleId','') IS NOT NULL THEN true
        ELSE v_line.source_tax_rule_id IS NOT NULL END;
      v_tax_rule_id:=CASE WHEN v_tax_applied
        THEN COALESCE(NULLIF(v_item->>'taxRuleId','')::uuid,v_line.source_tax_rule_id) END;
    EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'OVERAGE_COMMERCIAL_INPUT_INVALID'; END;
    v_gross:=round(v_line.quantity_uom*v_unit,4);
    IF v_unit<0 OR v_discount<0 OR v_discount>v_gross THEN
      RAISE EXCEPTION 'OVERAGE_COMMERCIAL_INPUT_INVALID';
    END IF;
    IF NOT v_tax_applied AND NULLIF(v_item->>'taxRuleId','') IS NOT NULL THEN
      RAISE EXCEPTION 'OVERAGE_TAX_INPUT_CONFLICT';
    END IF;
    v_net:=round(v_gross-v_discount,4);v_tax_amount:=0;
    IF v_tax_applied THEN
      IF v_tax_rule_id IS NULL THEN RAISE EXCEPTION 'OVERAGE_TAX_RULE_REQUIRED'; END IF;
      IF v_tax_rule_id=v_line.source_tax_rule_id THEN
        v_tax:=jsonb_build_object('taxApplied',true,'taxRuleId',v_line.source_tax_rule_id,
          'ruleVersion',v_line.source_tax_rule_version,'taxCode',v_line.source_tax_code,
          'taxName',v_line.source_tax_name,'ratePercent',v_line.source_tax_rate,
          'priceMode',v_line.source_tax_price_mode,'calculationScope',v_line.source_tax_scope,
          'taxAccountId',v_line.source_tax_account_id,
          'taxAccountCode',v_line.source_tax_account_code,
          'taxAccountName',v_line.source_tax_account_name,'source','SALES_ORDER');
      ELSE
        v_tax:=private.resolve_explicit_sales_tax_rule(v_company,v_tax_rule_id,v_now)
          ||jsonb_build_object('source','SALES_ADMIN_OVERRIDE');
      END IF;
      IF NULLIF(v_tax->>'ratePercent','') IS NULL
        OR NULLIF(v_tax->>'priceMode','') IS NULL
        OR NULLIF(v_tax->>'calculationScope','') IS NULL THEN
        RAISE EXCEPTION 'OVERAGE_TAX_SNAPSHOT_INVALID';
      END IF;
      v_tax_result:=private.calculate_tax_group(
        jsonb_build_array(jsonb_build_object('lineKey',v_line.id::text,'amount',v_net)),
        (v_tax->>'ratePercent')::numeric,'SALES',v_tax->>'priceMode',
        v_tax->>'calculationScope');
      v_tax_line:=v_tax_result->'lines'->0;
      v_tax_amount:=round((v_tax_line->>'taxAmount')::numeric,4);
    ELSE
      v_tax:=jsonb_build_object('taxApplied',false,'source',
        CASE WHEN v_item ? 'taxApplied' THEN 'SALES_ADMIN_OVERRIDE' ELSE 'SALES_ORDER' END);
    END IF;
    v_snapshot:=jsonb_build_object('quantityUom',v_line.quantity_uom,
      'quantityBase',v_line.quantity_base,'unitPrice',v_unit,
      'grossAmount',v_gross,'discountAmount',v_discount,
      'tax',v_tax,'taxAmount',v_tax_amount,'lineTotal',v_net,
      'defaultAuthority','SALES_ORDER','adjustedBySalesAdmin',
        (v_item ? 'unitPrice') OR (v_item ? 'discountAmount')
          OR (v_item ? 'taxApplied') OR (v_item ? 'taxRuleId'),
      'sourcePricingSnapshot',v_line.source_pricing_snapshot);
    UPDATE public.backoffice_sales_delivery_discrepancy_lines SET
      commercial_approval_status='APPROVED',approved_unit_price=v_unit,
      approved_discount_amount=v_discount,approved_tax_amount=v_tax_amount,
      approved_line_total=v_net,commercial_snapshot=v_snapshot,
      commercial_approved_by=v_actor,commercial_approved_at=v_now,updated_at=v_now
    WHERE company_id=v_company AND id=v_line.id;
    v_updated:=v_updated+1;
  END LOOP;

  IF EXISTS(SELECT 1 FROM public.backoffice_sales_delivery_discrepancy_lines line
    WHERE line.company_id=v_company AND line.discrepancy_id=p_discrepancy_id
      AND line.commercial_approval_status='PENDING') THEN
    RAISE EXCEPTION 'OVERAGE_APPROVAL_LINE_SET_INVALID';
  END IF;
  v_status:=CASE WHEN v_header.requires_warehouse_resolution
    THEN 'PENDING_WAREHOUSE_RESOLUTION' ELSE 'OPEN' END;
  UPDATE public.backoffice_sales_delivery_discrepancies SET status=v_status,
    master_version=master_version+1,updated_by=v_actor,updated_at=v_now
  WHERE company_id=v_company AND id=p_discrepancy_id;
  v_result:=jsonb_build_object('discrepancyId',p_discrepancy_id,
    'discrepancyNo',v_header.discrepancy_no,'status',v_status,
    'masterVersion',v_header.master_version+1,'approvedLineCount',v_updated,
    'exactRetry',false);
  INSERT INTO public.backoffice_sales_discrepancy_operations(id,company_id,
    discrepancy_id,operation_type,request_payload,result_payload,actor_id,completed_at)
  VALUES(p_operation_id,v_company,p_discrepancy_id,'SALES_APPROVE_OVERAGE',
    v_request,v_result,v_actor,v_now);
  INSERT INTO public.backoffice_sales_discrepancy_audit(company_id,discrepancy_id,
    operation_id,action,actor_id,before_state,after_state)
  VALUES(v_company,p_discrepancy_id,p_operation_id,'SALES_APPROVE_OVERAGE',v_actor,
    jsonb_build_object('status',v_header.status,'masterVersion',v_header.master_version),
    v_result);
  RETURN v_result;
END
$$;

CREATE FUNCTION public.approve_backoffice_sales_delivery_overage(
  p_discrepancy_id uuid,p_expected_version bigint,p_operation_id uuid,
  p_payload jsonb,p_notes text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='30s' AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
BEGIN
  PERFORM private.acp_require_permission_capability(v_company,'sales.sales_orders','MANAGE');
  IF NOT public.private_is_super_admin(v_actor)
    AND NOT public.private_user_has_any_company_role(v_company,
      ARRAY['COMPANY_OWNER','COMPANY_ADMIN','SALES_ADMIN']::text[]) THEN
    RAISE EXCEPTION 'SALES_ADMIN_REQUIRED';
  END IF;
  RETURN private.approve_backoffice_sales_delivery_overage_core(
    p_discrepancy_id,p_expected_version,p_operation_id,p_payload,p_notes);
END
$$;

ALTER TABLE public.backoffice_sales_delivery_discrepancies ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.backoffice_sales_delivery_discrepancy_lines ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON FUNCTION private.resolve_explicit_sales_tax_rule(uuid,uuid,timestamptz),
  private.approve_backoffice_sales_delivery_overage_core(uuid,bigint,uuid,jsonb,text)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.resolve_explicit_sales_tax_rule(uuid,uuid,timestamptz),
  private.approve_backoffice_sales_delivery_overage_core(uuid,bigint,uuid,jsonb,text)
TO service_role;
REVOKE ALL ON FUNCTION public.approve_backoffice_sales_delivery_overage(uuid,bigint,uuid,jsonb,text)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.approve_backoffice_sales_delivery_overage(uuid,bigint,uuid,jsonb,text)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260912100000','backoffice_sales_overage_commercial_approval',
  'Step 4/6.4 Sales Admin approval defaults overage price/discount/tax from original SO, permits explicit adjustment, uses optimistic version/exact retry/immutable audit, and creates zero physical or Finance effect');
NOTIFY pgrst,'reload schema';
COMMIT;
