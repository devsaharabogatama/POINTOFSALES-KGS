-- Transactional Backoffice Regular/Down Payment Invoice posting runtime.
-- Development rollout only. POS retail, Stock, FIFO and Customer receipt COGS stay unchanged.
BEGIN;

DO $guard$
DECLARE v_definition text;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260909160000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Invoice Finance mapping required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260909161000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260909161000';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
    WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
  IF to_regprocedure('private.post_financial_event_core(uuid,uuid,bigint,uuid)') IS NULL
    OR to_regprocedure('private.f4b_financial_event_supported(public.financial_events)') IS NULL
    OR to_regprocedure('private.resolve_financial_event_account(public.financial_events,text)') IS NULL
    OR to_regprocedure('private.backoffice_sales_invoice_snapshot(uuid,uuid)') IS NULL
    OR to_regprocedure('private.rebuild_backoffice_sales_invoice_schedules(uuid,uuid,uuid)') IS NULL
    OR to_regclass('private.pos_invoice_number_seq') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical runtime dependency missing';
  END IF;
  IF to_regprocedure('private.trg_g6_guard_posting_rule_set()') IS NULL
    OR to_regprocedure('private.trg_g6_guard_posting_rule_line()') IS NULL
    OR NOT EXISTS(SELECT 1 FROM pg_trigger trigger_state
      WHERE trigger_state.tgrelid='public.posting_rule_sets'::regclass
        AND trigger_state.tgname='g6_guard_posting_rule_set'
        AND NOT trigger_state.tgisinternal
        AND trigger_state.tgenabled<>'D')
    OR NOT EXISTS(SELECT 1 FROM pg_trigger trigger_state
      WHERE trigger_state.tgrelid='public.posting_rule_lines'::regclass
        AND trigger_state.tgname='g6_guard_posting_rule_line'
        AND NOT trigger_state.tgisinternal
        AND trigger_state.tgenabled<>'D')
    OR position('POSTING_RULE_SET_MUST_START_DRAFT' in pg_get_functiondef(
      'private.trg_g6_guard_posting_rule_set()'::regprocedure))=0
    OR position('APPROVED_POSTING_RULE_LINES_IMMUTABLE' in pg_get_functiondef(
      'private.trg_g6_guard_posting_rule_line()'::regprocedure))=0 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: posting rule lifecycle drift';
  END IF;
  IF to_regclass('public.backoffice_sales_down_payment_application_tax_breakdowns') IS NOT NULL
    OR to_regprocedure('public.post_backoffice_sales_invoice(uuid,bigint,uuid)') IS NOT NULL
    OR to_regprocedure('public.set_backoffice_sales_invoice_down_payments(uuid,bigint,uuid,jsonb)') IS NOT NULL
    OR to_regprocedure('private.rebuild_backoffice_sales_invoice_dp_applications(uuid,uuid,jsonb,text)') IS NOT NULL
    OR to_regprocedure('private.require_backoffice_sales_invoice_post_permission(uuid)') IS NOT NULL
    OR to_regprocedure('private.trg_auto_apply_backoffice_sales_invoice_dp()') IS NOT NULL
    OR to_regprocedure('private.post_backoffice_sales_invoice_financial_event_core(uuid,uuid,bigint,uuid)') IS NOT NULL
    OR to_regprocedure('private.post_financial_event_core_pre_backoffice_invoice(uuid,uuid,bigint,uuid)') IS NOT NULL
    OR to_regprocedure('private.f4b_financial_event_supported_pre_backoffice_invoice(public.financial_events)') IS NOT NULL
    OR to_regprocedure('private.trg_guard_backoffice_sales_dp_application_tax_history()') IS NOT NULL
    OR to_regprocedure('private.trg_delete_backoffice_sales_dp_application_children()') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Invoice posting identity collision';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.access_permission_catalog permission
    WHERE permission.permission_key='finance.journals_reports'
      AND permission.enforcement_status IN('SHADOW','ENFORCED')
      AND permission.is_customizable
      AND 'POST'=ANY(permission.supported_capabilities)) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Finance posting permission missing';
  END IF;
  IF EXISTS(SELECT 1 FROM public.backoffice_sales_invoices invoice
    WHERE invoice.status IN('POSTED','REVERSED') OR invoice.invoice_no IS NOT NULL
      OR invoice.financial_event_id IS NOT NULL OR invoice.posted_at IS NOT NULL
      OR invoice.posted_by IS NOT NULL) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: unexpected posted Invoice state';
  END IF;
  SELECT pg_get_functiondef(
    'private.post_financial_event_core(uuid,uuid,bigint,uuid)'::regprocedure)
  INTO v_definition;
  IF position('post_backoffice_receipt_financial_event_core' in v_definition)=0
    OR position('post_financial_event_core_pre_backoffice_receipt' in v_definition)=0 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance dispatcher drift';
  END IF;
  IF EXISTS(SELECT 1 FROM public.backoffice_sales_invoices invoice
    LEFT JOIN LATERAL(SELECT round(COALESCE(sum(line.line_amount),0),4) charge,
        round(COALESCE(sum(line.discount_amount),0),4) discount,
        round(COALESCE(sum(line.tax_amount),0),4) tax
      FROM public.backoffice_sales_invoice_lines line
      WHERE line.company_id=invoice.company_id AND line.invoice_id=invoice.id
        AND line.effect_type='CHARGE') amount ON true
    LEFT JOIN LATERAL(SELECT round(COALESCE(sum(schedule.amount_due),0),4) total
      FROM public.backoffice_sales_invoice_receivable_schedules schedule
      WHERE schedule.company_id=invoice.company_id AND schedule.invoice_id=invoice.id) schedule ON true
    WHERE invoice.status='DRAFT' AND (round(invoice.charge_total,4)<>amount.charge+amount.discount
      OR round(invoice.discount_total,4)<>amount.discount
      OR round(invoice.tax_total,4)<>amount.tax
      OR round(invoice.grand_total,4)<>schedule.total)) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Draft Invoice reconciliation failed';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.profiles profile
      JOIN auth.users auth_user ON auth_user.id=profile.id
      WHERE profile.role::text='super_admin') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: linked Super Admin required';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.posting_rule_sets rule_set
      WHERE rule_set.system_key='BACKOFFICE_SALES_INVOICE'
        AND rule_set.status='APPROVED')
    OR EXISTS(SELECT 1 FROM (
      SELECT rule_set.company_id,rule_set.transaction_category_id,
        rule_set.rule_set_version,count(line.id) line_count,
        count(*) OVER(PARTITION BY rule_set.company_id,
          rule_set.transaction_category_id) approved_count
      FROM public.posting_rule_sets rule_set
      JOIN public.posting_rule_lines line ON line.company_id=rule_set.company_id
        AND line.rule_set_id=rule_set.id
      WHERE rule_set.system_key='BACKOFFICE_SALES_INVOICE'
        AND rule_set.status='APPROVED'
      GROUP BY rule_set.id,rule_set.company_id,rule_set.transaction_category_id,
        rule_set.rule_set_version
    ) contract WHERE contract.rule_set_version<>1 OR contract.line_count<>4
        OR contract.approved_count<>1) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Regular posting rule v1 drift';
  END IF;
END
$guard$;

CREATE TABLE public.backoffice_sales_down_payment_application_tax_breakdowns(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL,
  application_id uuid NOT NULL,
  down_payment_invoice_id uuid NOT NULL,
  source_tax_breakdown_id uuid NOT NULL,
  tax_group_no integer NOT NULL,
  tax_rule_id uuid NOT NULL,
  tax_rule_version bigint NOT NULL,
  tax_account_id uuid NOT NULL,
  tax_code_snapshot text NOT NULL,
  tax_name_snapshot text NOT NULL,
  applied_tax_amount numeric(24,4) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT backoffice_sales_dp_app_tax_company_id_unique UNIQUE(company_id,id),
  CONSTRAINT backoffice_sales_dp_app_tax_group_unique
    UNIQUE(company_id,application_id,tax_group_no),
  CONSTRAINT backoffice_sales_dp_app_tax_application_fk
    FOREIGN KEY(company_id,application_id)
    REFERENCES public.backoffice_sales_down_payment_applications(company_id,id)
    ON DELETE CASCADE,
  CONSTRAINT backoffice_sales_dp_app_tax_source_fk
    FOREIGN KEY(company_id,source_tax_breakdown_id)
    REFERENCES public.backoffice_sales_invoice_tax_breakdowns(company_id,id)
    ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_dp_app_tax_invoice_fk
    FOREIGN KEY(company_id,down_payment_invoice_id)
    REFERENCES public.backoffice_sales_invoices(company_id,id)
    ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_dp_app_tax_rule_version_fk
    FOREIGN KEY(company_id,tax_rule_id,tax_rule_version)
    REFERENCES public.tax_rule_versions(company_id,tax_rule_id,rule_version)
    ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_dp_app_tax_account_fk
    FOREIGN KEY(company_id,tax_account_id)
    REFERENCES public.chart_of_accounts(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_dp_app_tax_shape_check CHECK(
    tax_group_no>0 AND tax_rule_version>0 AND applied_tax_amount>0
    AND nullif(btrim(tax_code_snapshot),'') IS NOT NULL
    AND nullif(btrim(tax_name_snapshot),'') IS NOT NULL)
);
CREATE INDEX backoffice_sales_dp_app_tax_invoice
  ON public.backoffice_sales_down_payment_application_tax_breakdowns(
    company_id,down_payment_invoice_id,application_id,tax_group_no);
ALTER TABLE public.backoffice_sales_down_payment_application_tax_breakdowns
  ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.backoffice_sales_down_payment_application_tax_breakdowns
  FROM PUBLIC,anon,authenticated;
GRANT ALL ON TABLE public.backoffice_sales_down_payment_application_tax_breakdowns
  TO service_role;

ALTER TABLE public.backoffice_sales_invoice_operations
  DROP CONSTRAINT backoffice_sales_invoice_operations_shape_check,
  ADD CONSTRAINT backoffice_sales_invoice_operations_shape_check CHECK(
    operation_type IN('SAVE_DRAFT','CANCEL_DRAFT','SET_DOWN_PAYMENTS','POST')
    AND (expected_version IS NULL OR expected_version>0)
    AND request_hash~'^[0-9a-f]{64}$'
    AND jsonb_typeof(response_snapshot)='object');

-- The mapping in 160000 expressed tax as one net credit. The runtime keeps the
-- customer-facing total but follows the Odoo line model: current Invoice tax is
-- credited and tax carried by the negative DP line is debited by exact account.
DO $regular_rule_v2$
DECLARE v_actor uuid;v_old record;v_new uuid;v_now timestamptz:=clock_timestamp();
BEGIN
  SELECT profile.id INTO v_actor FROM public.profiles profile
  JOIN auth.users auth_user ON auth_user.id=profile.id
  WHERE profile.role::text='super_admin' ORDER BY profile.id LIMIT 1;
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: linked Super Admin required';
  END IF;
  FOR v_old IN SELECT rule_set.* FROM public.posting_rule_sets rule_set
    JOIN public.transaction_categories category
      ON category.company_id=rule_set.company_id
      AND category.id=rule_set.transaction_category_id
    WHERE rule_set.system_key='BACKOFFICE_SALES_INVOICE'
      AND rule_set.status='APPROVED' AND category.is_active
    ORDER BY rule_set.company_id,rule_set.rule_set_version
  LOOP
    INSERT INTO public.posting_rule_set_audit(company_id,rule_set_id,action,
      actor_id,before_state,after_state,reason)
    VALUES(v_old.company_id,v_old.id,'RETIRE',v_actor,to_jsonb(v_old),
      to_jsonb(v_old)||jsonb_build_object('status','RETIRED'),
      'Replace net tax expression with explicit Invoice tax credit and DP tax debit');
    UPDATE public.posting_rule_sets SET status='RETIRED',master_version=master_version+1,
      updated_by=v_actor,updated_at=v_now WHERE company_id=v_old.company_id AND id=v_old.id;
    -- Canonical G6 lifecycle is mandatory: a rule set starts as DRAFT, its
    -- lines are written while editable, CREATE is audited, then it is approved.
    -- Direct APPROVED insertion is rejected by g6_guard_posting_rule_set.
    INSERT INTO public.posting_rule_sets(company_id,transaction_category_id,system_key,
      rule_set_version,effective_from,status,description,approved_by,approved_at,
      created_by,updated_by)
    VALUES(v_old.company_id,v_old.transaction_category_id,'BACKOFFICE_SALES_INVOICE',
      v_old.rule_set_version+1,'-infinity'::timestamptz,'DRAFT',
      'Regular Invoice: AR plus applied DP basis and tax equals Revenue plus current Invoice tax',
      NULL,NULL,v_actor,v_actor) RETURNING id INTO v_new;
    INSERT INTO public.posting_rule_lines(company_id,rule_set_id,line_no,
      account_function_key,entry_side,amount_expression_key,condition_key,
      is_required,created_by) VALUES
      (v_old.company_id,v_new,10,'CUSTOMER_RECEIVABLE','DEBIT',
        'BACKOFFICE_INVOICE_RECEIVABLE',NULL,true,v_actor),
      (v_old.company_id,v_new,20,'CUSTOMER_ADVANCE_LIABILITY','DEBIT',
        'BACKOFFICE_INVOICE_DP_BASIS_APPLIED','BACKOFFICE_INVOICE_HAS_DP',false,v_actor),
      (v_old.company_id,v_new,30,'OUTPUT_TAX','DEBIT',
        'BACKOFFICE_INVOICE_DP_TAX_APPLIED','BACKOFFICE_INVOICE_HAS_DP_TAX',false,v_actor),
      (v_old.company_id,v_new,40,'SALES_REVENUE','CREDIT',
        'BACKOFFICE_INVOICE_REVENUE_DPP',NULL,true,v_actor),
      (v_old.company_id,v_new,50,'OUTPUT_TAX','CREDIT',
        'BACKOFFICE_INVOICE_CURRENT_OUTPUT_TAX','BACKOFFICE_INVOICE_HAS_TAX',false,v_actor);
    INSERT INTO public.posting_rule_set_audit(company_id,rule_set_id,action,actor_id,
      after_state,reason)
    SELECT rule_set.company_id,rule_set.id,'CREATE',v_actor,
      to_jsonb(rule_set)||jsonb_build_object('lines',(SELECT jsonb_agg(to_jsonb(line)
        ORDER BY line.line_no) FROM public.posting_rule_lines line
        WHERE line.company_id=rule_set.company_id AND line.rule_set_id=rule_set.id)),
      'Odoo-style explicit DP deduction tax mapping'
    FROM public.posting_rule_sets rule_set WHERE rule_set.id=v_new;
    UPDATE public.posting_rule_sets SET status='APPROVED',approved_by=v_actor,
      approved_at=v_now,updated_by=v_actor
    WHERE company_id=v_old.company_id AND id=v_new;
    INSERT INTO public.posting_rule_set_audit(company_id,rule_set_id,action,actor_id,
      after_state,reason)
    SELECT rule_set.company_id,rule_set.id,'APPROVE',v_actor,
      to_jsonb(rule_set)||jsonb_build_object('lines',(SELECT jsonb_agg(to_jsonb(line)
        ORDER BY line.line_no) FROM public.posting_rule_lines line
        WHERE line.company_id=rule_set.company_id AND line.rule_set_id=rule_set.id)),
      'Approve explicit Invoice and DP tax sides'
    FROM public.posting_rule_sets rule_set WHERE rule_set.id=v_new;
  END LOOP;
END
$regular_rule_v2$;

-- The canonical finance.journals_reports catalog can still be SHADOW. Do not
-- change its global lifecycle from this Sales-only gate. Reuse its role and
-- per-user override result, then enforce POST locally for this new RPC.
CREATE FUNCTION private.require_backoffice_sales_invoice_post_permission(
  p_company_id uuid
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_resolution jsonb;
BEGIN
  v_resolution:=private.acp_require_permission_capability(
    p_company_id,'finance.journals_reports','POST');
  IF NOT COALESCE((v_resolution->'effectiveCapabilities') ? 'POST',false) THEN
    RAISE EXCEPTION 'CUSTOM_PERMISSION_DENIED';
  END IF;
  RETURN v_resolution;
END
$$;

CREATE FUNCTION private.rebuild_backoffice_sales_invoice_dp_applications(
  p_company_id uuid,p_invoice_id uuid,p_applications jsonb,p_mode text
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE
  v_invoice public.backoffice_sales_invoices%rowtype;v_dp record;v_item jsonb;
  v_requested numeric(24,4);v_available numeric(24,4);v_remaining numeric(24,4);
  v_remaining_basis numeric(24,4);v_remaining_tax numeric(24,4);
  v_basis numeric(24,4);v_tax numeric(24,4);v_total numeric(24,4):=0;
  v_application_id uuid;v_line_no integer;v_group record;v_group_tax numeric(24,4);
  v_group_assigned numeric(24,4);v_group_count integer;v_group_index integer;
BEGIN
  SELECT invoice.* INTO STRICT v_invoice FROM public.backoffice_sales_invoices invoice
  WHERE invoice.company_id=p_company_id AND invoice.id=p_invoice_id FOR UPDATE;
  IF v_invoice.status<>'DRAFT' OR v_invoice.invoice_type<>'REGULAR' THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_DP_APPLICATION_NOT_EDITABLE';
  END IF;
  IF p_mode NOT IN('AUTO','MANUAL')
    OR (p_mode='MANUAL' AND jsonb_typeof(p_applications)<>'array') THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_DP_APPLICATION_INVALID';
  END IF;
  IF p_mode='MANUAL' AND EXISTS(SELECT 1
    FROM jsonb_array_elements(p_applications) item
    GROUP BY item->>'downPaymentInvoiceId' HAVING count(*)>1) THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_DP_APPLICATION_DUPLICATE';
  END IF;
  DELETE FROM public.backoffice_sales_down_payment_application_tax_breakdowns child
  USING public.backoffice_sales_down_payment_applications application
  WHERE child.company_id=p_company_id AND child.application_id=application.id
    AND application.company_id=p_company_id AND application.regular_invoice_id=p_invoice_id
    AND application.status='HELD';
  DELETE FROM public.backoffice_sales_down_payment_applications application
  WHERE application.company_id=p_company_id AND application.regular_invoice_id=p_invoice_id
    AND application.status='HELD';
  DELETE FROM public.backoffice_sales_invoice_lines line
  WHERE line.company_id=p_company_id AND line.invoice_id=p_invoice_id
    AND line.line_type='DOWN_PAYMENT_DEDUCTION' AND line.effect_type='DEDUCTION';
  v_remaining:=round(v_invoice.charge_total-v_invoice.discount_total+v_invoice.tax_total,4);
  IF v_remaining<0 THEN RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_AMOUNT_INVALID'; END IF;

  FOR v_dp IN
    SELECT dp.*,round(dp.grand_total-COALESCE(used.used_amount,0),4) available_amount,
      round(dp.charge_total-COALESCE(used.used_basis,0),4) available_basis,
      round(dp.tax_total-COALESCE(used.used_tax,0),4) available_tax
    FROM public.backoffice_sales_invoices dp
    LEFT JOIN LATERAL(SELECT sum(application.applied_amount) used_amount,
        sum(application.applied_basis_amount) used_basis,
        sum(application.applied_tax_amount) used_tax
      FROM public.backoffice_sales_down_payment_applications application
      WHERE application.company_id=dp.company_id
        AND application.down_payment_invoice_id=dp.id
        AND application.regular_invoice_id<>p_invoice_id
        AND application.status IN('HELD','POSTED')) used ON true
    WHERE dp.company_id=p_company_id AND dp.sales_order_id=v_invoice.sales_order_id
      AND dp.invoice_type='DOWN_PAYMENT' AND dp.status='POSTED'
      AND (p_mode='AUTO' OR EXISTS(SELECT 1 FROM jsonb_array_elements(p_applications) item
        WHERE item->>'downPaymentInvoiceId'=dp.id::text))
    ORDER BY CASE WHEN p_mode='MANUAL' THEN (SELECT ordinality FROM
        jsonb_array_elements(p_applications) WITH ORDINALITY selected(value,ordinality)
        WHERE selected.value->>'downPaymentInvoiceId'=dp.id::text LIMIT 1) END NULLS LAST,
      dp.posted_at,dp.invoice_sequence,dp.id
    FOR UPDATE OF dp
  LOOP
    EXIT WHEN v_remaining<=0;
    v_available:=v_dp.available_amount;v_remaining_basis:=v_dp.available_basis;
    v_remaining_tax:=v_dp.available_tax;
    IF v_available<=0 THEN CONTINUE; END IF;
    IF p_mode='AUTO' THEN
      v_requested:=least(v_available,v_remaining);
    ELSE
      SELECT round((selected.value->>'appliedAmount')::numeric,4) INTO v_requested
      FROM jsonb_array_elements(p_applications) selected(value)
      WHERE selected.value->>'downPaymentInvoiceId'=v_dp.id::text;
      IF v_requested IS NULL OR v_requested<=0 THEN
        RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_DP_APPLICATION_INVALID';
      END IF;
    END IF;
    IF v_requested>v_available THEN
      RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_DP_EXCEEDS_AVAILABLE';
    END IF;
    IF v_requested>v_remaining THEN
      RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_DP_EXCEEDS_INVOICE';
    END IF;
    IF v_requested=v_available THEN
      v_basis:=v_remaining_basis;v_tax:=v_remaining_tax;
    ELSE
      v_basis:=round(v_requested*v_remaining_basis/v_available,4);
      v_tax:=v_requested-v_basis;
    END IF;
    IF v_basis<0 OR v_tax<0 OR v_basis+v_tax<>v_requested THEN
      RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_DP_SPLIT_INVALID';
    END IF;
    INSERT INTO public.backoffice_sales_down_payment_applications(company_id,
      sales_order_id,down_payment_invoice_id,regular_invoice_id,applied_amount,
      applied_basis_amount,applied_tax_amount,status)
    VALUES(p_company_id,v_invoice.sales_order_id,v_dp.id,p_invoice_id,v_requested,
      v_basis,v_tax,'HELD') RETURNING id INTO v_application_id;
    IF v_tax>0 THEN
      SELECT count(*) INTO v_group_count
      FROM public.backoffice_sales_invoice_tax_breakdowns breakdown
      WHERE breakdown.company_id=p_company_id AND breakdown.invoice_id=v_dp.id
        AND breakdown.tax_amount-COALESCE((SELECT sum(prior.applied_tax_amount)
          FROM public.backoffice_sales_down_payment_application_tax_breakdowns prior
          JOIN public.backoffice_sales_down_payment_applications application
            ON application.company_id=prior.company_id AND application.id=prior.application_id
          WHERE prior.company_id=p_company_id
            AND prior.source_tax_breakdown_id=breakdown.id
            AND application.regular_invoice_id<>p_invoice_id
            AND application.status IN('HELD','POSTED')),0)>0;
      IF v_group_count=0 THEN
        RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_DP_TAX_LINEAGE_MISSING';
      END IF;
      v_group_assigned:=0;v_group_index:=0;
      FOR v_group IN
        SELECT breakdown.*,
          round(breakdown.tax_amount-COALESCE((SELECT sum(prior.applied_tax_amount)
            FROM public.backoffice_sales_down_payment_application_tax_breakdowns prior
            JOIN public.backoffice_sales_down_payment_applications application
              ON application.company_id=prior.company_id AND application.id=prior.application_id
            WHERE prior.company_id=p_company_id
              AND prior.source_tax_breakdown_id=breakdown.id
              AND application.regular_invoice_id<>p_invoice_id
              AND application.status IN('HELD','POSTED')),0),4) available_tax
        FROM public.backoffice_sales_invoice_tax_breakdowns breakdown
        WHERE breakdown.company_id=p_company_id AND breakdown.invoice_id=v_dp.id
          AND breakdown.tax_amount-COALESCE((SELECT sum(prior.applied_tax_amount)
            FROM public.backoffice_sales_down_payment_application_tax_breakdowns prior
            JOIN public.backoffice_sales_down_payment_applications application
              ON application.company_id=prior.company_id AND application.id=prior.application_id
            WHERE prior.company_id=p_company_id
              AND prior.source_tax_breakdown_id=breakdown.id
              AND application.regular_invoice_id<>p_invoice_id
              AND application.status IN('HELD','POSTED')),0)>0
        ORDER BY breakdown.tax_group_no
      LOOP
        v_group_index:=v_group_index+1;
        v_group_tax:=CASE WHEN v_group_index=v_group_count THEN v_tax-v_group_assigned
          ELSE round(v_tax*v_group.available_tax/v_remaining_tax,4) END;
        IF v_group_tax<0 OR v_group_tax>v_group.available_tax THEN
          RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_DP_TAX_ALLOCATION_INVALID';
        END IF;
        IF v_group_tax>0 THEN
          INSERT INTO public.backoffice_sales_down_payment_application_tax_breakdowns(
            company_id,application_id,down_payment_invoice_id,source_tax_breakdown_id,
            tax_group_no,tax_rule_id,tax_rule_version,tax_account_id,
            tax_code_snapshot,tax_name_snapshot,applied_tax_amount)
          VALUES(p_company_id,v_application_id,v_dp.id,v_group.id,v_group.tax_group_no,
            v_group.tax_rule_id,v_group.tax_rule_version,v_group.tax_account_id,
            v_group.tax_code_snapshot,v_group.tax_name_snapshot,v_group_tax);
          v_group_assigned:=v_group_assigned+v_group_tax;
        END IF;
      END LOOP;
      IF v_group_assigned<>v_tax THEN
        RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_DP_TAX_ALLOCATION_INVALID';
      END IF;
    END IF;
    SELECT COALESCE(max(line.line_no),0)+1 INTO v_line_no
    FROM public.backoffice_sales_invoice_lines line
    WHERE line.company_id=p_company_id AND line.invoice_id=p_invoice_id;
    INSERT INTO public.backoffice_sales_invoice_lines(company_id,invoice_id,sales_order_id,
      line_no,line_type,effect_type,unit_price,discount_amount,tax_amount,line_amount,
      description,source_snapshot)
    VALUES(p_company_id,p_invoice_id,v_invoice.sales_order_id,v_line_no,
      'DOWN_PAYMENT_DEDUCTION','DEDUCTION',v_requested,0,0,v_requested,
      'Potongan DP '||COALESCE(v_dp.invoice_no,v_dp.draft_no),
      jsonb_build_object('applicationId',v_application_id,
        'downPaymentInvoiceId',v_dp.id,'downPaymentInvoiceNo',v_dp.invoice_no,
        'appliedBasisAmount',v_basis,'appliedTaxAmount',v_tax));
    v_total:=v_total+v_requested;v_remaining:=v_remaining-v_requested;
  END LOOP;
  IF p_mode='MANUAL' AND EXISTS(SELECT 1 FROM jsonb_array_elements(p_applications) item
    WHERE NOT EXISTS(SELECT 1 FROM public.backoffice_sales_invoices dp
      WHERE dp.company_id=p_company_id AND dp.sales_order_id=v_invoice.sales_order_id
        AND dp.id=(item->>'downPaymentInvoiceId')::uuid
        AND dp.invoice_type='DOWN_PAYMENT' AND dp.status='POSTED')) THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_DP_NOT_AVAILABLE';
  END IF;
  UPDATE public.backoffice_sales_invoices SET down_payment_deduction_total=v_total,
    grand_total=charge_total-discount_total+tax_total-v_total,
    updated_at=clock_timestamp()
  WHERE company_id=p_company_id AND id=p_invoice_id;
END
$$;

CREATE FUNCTION private.trg_auto_apply_backoffice_sales_invoice_dp()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
  IF NEW.status='DRAFT' AND NEW.invoice_type='REGULAR' THEN
    PERFORM private.rebuild_backoffice_sales_invoice_dp_applications(
      NEW.company_id,NEW.id,NULL,'AUTO');
  END IF;
  RETURN NEW;
END
$$;
CREATE TRIGGER backoffice_sales_invoice_dp_auto_apply
AFTER UPDATE OF charge_total,discount_total,tax_total
ON public.backoffice_sales_invoices FOR EACH ROW
EXECUTE FUNCTION private.trg_auto_apply_backoffice_sales_invoice_dp();

CREATE FUNCTION public.set_backoffice_sales_invoice_down_payments(
  p_invoice_id uuid,p_expected_version bigint,p_operation_id uuid,p_applications jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='8s' AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
  v_invoice public.backoffice_sales_invoices%rowtype;v_hash text;v_retry jsonb;
  v_before jsonb;v_after jsonb;v_response jsonb;
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'sales.backoffice_orders','EDIT_DRAFT');
  IF p_invoice_id IS NULL OR p_expected_version IS NULL OR p_operation_id IS NULL
    OR jsonb_typeof(p_applications)<>'array' THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_DP_APPLICATION_INVALID';
  END IF;
  v_hash:=encode(extensions.digest(convert_to(jsonb_build_object('invoiceId',p_invoice_id,
    'expectedVersion',p_expected_version,'applications',p_applications)::text,'UTF8'),
    'sha256'),'hex');
  PERFORM pg_advisory_xact_lock(hashtextextended(
    v_company::text||':BACKOFFICE_INVOICE:'||p_operation_id::text,0));
  v_retry:=private.backoffice_sales_invoice_operation_retry(
    v_company,p_operation_id,'SET_DOWN_PAYMENTS',v_hash);
  IF v_retry IS NOT NULL THEN RETURN v_retry; END IF;
  SELECT invoice.* INTO v_invoice FROM public.backoffice_sales_invoices invoice
  WHERE invoice.company_id=v_company AND invoice.id=p_invoice_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_NOT_FOUND'; END IF;
  IF v_invoice.status<>'DRAFT' OR v_invoice.invoice_type<>'REGULAR' THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_DP_APPLICATION_NOT_EDITABLE';
  END IF;
  IF v_invoice.master_version<>p_expected_version THEN
    RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(
    v_company::text||':BACKOFFICE_INVOICE_ORDER:'||v_invoice.sales_order_id::text,0));
  v_before:=private.backoffice_sales_invoice_snapshot(v_company,p_invoice_id);
  PERFORM private.rebuild_backoffice_sales_invoice_dp_applications(
    v_company,p_invoice_id,p_applications,'MANUAL');
  UPDATE public.backoffice_sales_invoices SET master_version=master_version+1,
    updated_by=v_actor,updated_at=clock_timestamp()
  WHERE company_id=v_company AND id=p_invoice_id;
  PERFORM private.rebuild_backoffice_sales_invoice_schedules(v_company,p_invoice_id,v_actor);
  v_after:=private.backoffice_sales_invoice_snapshot(v_company,p_invoice_id);
  v_response:=jsonb_build_object('companyId',v_company,'data',v_after,'exactRetry',false);
  INSERT INTO public.backoffice_sales_invoice_operations(company_id,operation_id,
    operation_type,invoice_id,expected_version,request_hash,response_snapshot,actor_id)
  VALUES(v_company,p_operation_id,'SET_DOWN_PAYMENTS',p_invoice_id,p_expected_version,
    v_hash,v_response,v_actor);
  INSERT INTO public.backoffice_sales_invoice_audit(company_id,invoice_id,action,
    operation_id,actor_id,reason,before_state,after_state)
  VALUES(v_company,p_invoice_id,'UPDATE_DRAFT',p_operation_id,v_actor,
    'Ubah alokasi uang muka',v_before,v_after);
  RETURN v_response;
END
$$;

CREATE FUNCTION private.post_backoffice_sales_invoice_financial_event_core(
  p_company_id uuid,p_event_id uuid,p_expected_event_version bigint,p_actor_id uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
  v_event public.financial_events%rowtype;v_invoice public.backoffice_sales_invoices%rowtype;
  v_period public.accounting_periods%rowtype;v_journal public.finance_journals%rowtype;
  v_rule_count bigint;v_rule_version bigint;v_account uuid;v_line_no integer:=0;
  v_revenue numeric(24,4);v_applied_basis numeric(24,4);v_applied_tax numeric(24,4);
  v_tax numeric(24,4);v_expected_debit numeric(24,4);v_expected_credit numeric(24,4);
  v_breakdown record;v_now timestamptz:=clock_timestamp();
BEGIN
  IF p_actor_id IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  SELECT event.* INTO v_event FROM public.financial_events event
  WHERE event.company_id=p_company_id AND event.id=p_event_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'FINANCIAL_EVENT_NOT_FOUND'; END IF;
  IF p_expected_event_version IS DISTINCT FROM v_event.event_version THEN
    RAISE EXCEPTION 'EVENT_VERSION_CONFLICT';
  END IF;
  IF v_event.status::text='POSTED' THEN
    SELECT journal.* INTO STRICT v_journal FROM public.finance_journals journal
    WHERE journal.company_id=p_company_id AND journal.financial_event_id=v_event.id
      AND journal.status='POSTED';
    RETURN jsonb_build_object('financialEventId',v_event.id,'journalId',v_journal.id,
      'journalNo',v_journal.journal_no,'status','POSTED','idempotentReplay',true);
  END IF;
  IF v_event.status::text<>'HOLD' OR v_event.event_type::text<>'SALE_POSTED'
    OR v_event.source_table<>'backoffice_sales_invoices'
    OR v_event.system_event_key NOT IN(
      'BACKOFFICE_SALES_INVOICE','BACKOFFICE_SALES_DOWN_PAYMENT') THEN
    RAISE EXCEPTION 'UNSUPPORTED_FINANCIAL_EVENT_CONTRACT';
  END IF;
  SELECT invoice.* INTO v_invoice FROM public.backoffice_sales_invoices invoice
  WHERE invoice.company_id=p_company_id AND invoice.id=v_event.source_id
    AND invoice.financial_event_id=v_event.id AND invoice.status='POSTED' FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'FINANCIAL_EVENT_SOURCE_NOT_FOUND'; END IF;
  IF (v_invoice.invoice_type='REGULAR'
      AND v_event.system_event_key<>'BACKOFFICE_SALES_INVOICE')
    OR (v_invoice.invoice_type='DOWN_PAYMENT'
      AND v_event.system_event_key<>'BACKOFFICE_SALES_DOWN_PAYMENT')
    OR jsonb_typeof(v_event.amounts)<>'object'
    OR NOT (v_event.amounts ?& ARRAY['invoiceId','salesOrderId','grandTotal',
      'chargeTotal','discountTotal','taxTotal','downPaymentDeductionTotal'])
    OR NULLIF(v_event.amounts->>'invoiceId','') IS NULL
    OR NULLIF(v_event.amounts->>'salesOrderId','') IS NULL
    OR NULLIF(v_event.amounts->>'grandTotal','') IS NULL
    OR NULLIF(v_event.amounts->>'chargeTotal','') IS NULL
    OR NULLIF(v_event.amounts->>'discountTotal','') IS NULL
    OR NULLIF(v_event.amounts->>'taxTotal','') IS NULL
    OR NULLIF(v_event.amounts->>'downPaymentDeductionTotal','') IS NULL
    OR v_event.amounts->>'invoiceId' IS DISTINCT FROM v_invoice.id::text
    OR v_event.amounts->>'salesOrderId' IS DISTINCT FROM v_invoice.sales_order_id::text
    OR round((v_event.amounts->>'grandTotal')::numeric,4)<>round(v_invoice.grand_total,4)
    OR round((v_event.amounts->>'chargeTotal')::numeric,4)<>round(v_invoice.charge_total,4)
    OR round((v_event.amounts->>'discountTotal')::numeric,4)<>round(v_invoice.discount_total,4)
    OR round((v_event.amounts->>'taxTotal')::numeric,4)<>round(v_invoice.tax_total,4)
    OR round((v_event.amounts->>'downPaymentDeductionTotal')::numeric,4)
      <>round(v_invoice.down_payment_deduction_total,4) THEN
    RAISE EXCEPTION 'FINANCIAL_EVENT_AMOUNT_SOURCE_MISMATCH';
  END IF;
  SELECT period.* INTO v_period FROM public.accounting_periods period
  WHERE period.company_id=p_company_id
    AND v_invoice.invoice_date BETWEEN period.start_date AND period.end_date
    AND period.status IN('OPEN','REOPENED')
  ORDER BY period.start_date LIMIT 1 FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_PERIOD_NOT_OPEN'; END IF;
  SELECT count(*),max(rule_set.rule_set_version) INTO v_rule_count,v_rule_version
  FROM public.posting_rule_sets rule_set
  WHERE rule_set.company_id=p_company_id
    AND rule_set.transaction_category_id=v_event.transaction_category_id
    AND rule_set.system_key=v_event.system_event_key AND rule_set.status='APPROVED'
    AND rule_set.effective_from<=v_event.event_date
    AND (rule_set.effective_to IS NULL OR rule_set.effective_to>v_event.event_date);
  IF v_rule_count<>1 OR v_rule_version IS NULL THEN
    RAISE EXCEPTION 'POSTING_RULE_SET_MISSING_OR_AMBIGUOUS';
  END IF;

  SELECT round(COALESCE(sum(application.applied_basis_amount),0),4),
    round(COALESCE(sum(application.applied_tax_amount),0),4)
  INTO v_applied_basis,v_applied_tax
  FROM public.backoffice_sales_down_payment_applications application
  WHERE application.company_id=p_company_id
    AND application.regular_invoice_id=v_invoice.id AND application.status='POSTED';
  SELECT round(COALESCE(sum(breakdown.tax_amount),0),4) INTO v_tax
  FROM public.backoffice_sales_invoice_tax_breakdowns breakdown
  WHERE breakdown.company_id=p_company_id AND breakdown.invoice_id=v_invoice.id;
  v_revenue:=round(v_invoice.charge_total-v_invoice.discount_total,4);
  IF v_revenue<=0 THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_AMOUNT_NOT_POSITIVE';
  END IF;
  IF v_tax<>round(v_invoice.tax_total,4)
    OR v_applied_basis+v_applied_tax<>round(v_invoice.down_payment_deduction_total,4) THEN
    RAISE EXCEPTION 'FINANCIAL_EVENT_AMOUNT_SOURCE_MISMATCH';
  END IF;

  INSERT INTO public.finance_journals(company_id,journal_no,journal_type,
    accounting_period_id,accounting_date,original_event_date,source_type,source_id,
    source_version,financial_event_id,idempotency_key,system_event_key,
    transaction_category_id,transaction_rule_version,store_id,warehouse_id,
    currency_code,description,status,created_by)
  VALUES(p_company_id,'BOI-'||replace(v_event.id::text,'-',''),'AUTOMATIC',v_period.id,
    v_invoice.invoice_date,v_invoice.invoice_date,v_event.source_table,v_invoice.id,
    v_invoice.master_version,v_event.id,
    'BACKOFFICE_INVOICE_EVENT|'||p_company_id||'|'||v_event.id||'|'||v_event.event_version,
    v_event.system_event_key,v_event.transaction_category_id,v_rule_version,
    v_invoice.store_id,v_invoice.warehouse_id,v_invoice.currency_code,
    CASE v_invoice.invoice_type WHEN 'DOWN_PAYMENT' THEN 'Uang muka '
      ELSE 'Invoice penjualan ' END||v_invoice.invoice_no,'DRAFT',p_actor_id)
  RETURNING * INTO v_journal;

  IF v_invoice.grand_total>0 THEN
    v_account:=private.resolve_financial_event_account(v_event,'CUSTOMER_RECEIVABLE');
    v_line_no:=v_line_no+10;
    INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,account_id,
      debit,credit,store_id,warehouse_id,customer_id,description)
    VALUES(p_company_id,v_journal.id,v_line_no,v_account,v_invoice.grand_total,0,
      v_invoice.store_id,v_invoice.warehouse_id,v_invoice.customer_id,'Piutang Customer');
  END IF;
  IF v_invoice.invoice_type='DOWN_PAYMENT' THEN
    v_account:=private.resolve_financial_event_account(
      v_event,'CUSTOMER_ADVANCE_LIABILITY');
    v_line_no:=v_line_no+10;
    INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,account_id,
      debit,credit,store_id,warehouse_id,customer_id,description)
    VALUES(p_company_id,v_journal.id,v_line_no,v_account,0,v_revenue,
      v_invoice.store_id,v_invoice.warehouse_id,v_invoice.customer_id,
      'Liabilitas uang muka Customer');
    FOR v_breakdown IN SELECT breakdown.*
      FROM public.backoffice_sales_invoice_tax_breakdowns breakdown
      WHERE breakdown.company_id=p_company_id AND breakdown.invoice_id=v_invoice.id
      ORDER BY breakdown.tax_group_no
    LOOP
      IF NOT EXISTS(SELECT 1 FROM public.tax_rule_versions version
        JOIN public.chart_of_accounts account ON account.company_id=version.company_id
          AND account.id=version.account_id AND account.is_active AND account.is_postable
        WHERE version.company_id=p_company_id
          AND version.tax_rule_id=v_breakdown.tax_rule_id
          AND version.rule_version=v_breakdown.tax_rule_version
          AND version.account_function_key='OUTPUT_TAX'
          AND version.account_id=v_breakdown.tax_account_id) THEN
        RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_TAX_ACCOUNT_INVALID';
      END IF;
      v_line_no:=v_line_no+10;
      INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,account_id,
        debit,credit,store_id,warehouse_id,customer_id,description)
      VALUES(p_company_id,v_journal.id,v_line_no,v_breakdown.tax_account_id,0,
        v_breakdown.tax_amount,v_invoice.store_id,v_invoice.warehouse_id,
        v_invoice.customer_id,'Pajak keluaran DP '||v_breakdown.tax_code_snapshot);
    END LOOP;
  ELSE
    IF v_applied_basis>0 THEN
      v_account:=private.resolve_financial_event_account(
        v_event,'CUSTOMER_ADVANCE_LIABILITY');
      v_line_no:=v_line_no+10;
      INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,account_id,
        debit,credit,store_id,warehouse_id,customer_id,description)
      VALUES(p_company_id,v_journal.id,v_line_no,v_account,v_applied_basis,0,
        v_invoice.store_id,v_invoice.warehouse_id,v_invoice.customer_id,
        'Pemakaian basis uang muka Customer');
    END IF;
    FOR v_breakdown IN SELECT application_tax.*
      FROM public.backoffice_sales_down_payment_application_tax_breakdowns application_tax
      JOIN public.backoffice_sales_down_payment_applications application
        ON application.company_id=application_tax.company_id
        AND application.id=application_tax.application_id
        AND application.status='POSTED'
      WHERE application_tax.company_id=p_company_id
        AND application.regular_invoice_id=v_invoice.id
      ORDER BY application.down_payment_invoice_id,application_tax.tax_group_no
    LOOP
      IF NOT EXISTS(SELECT 1 FROM public.tax_rule_versions version
        WHERE version.company_id=p_company_id
          AND version.tax_rule_id=v_breakdown.tax_rule_id
          AND version.rule_version=v_breakdown.tax_rule_version
          AND version.account_function_key='OUTPUT_TAX'
          AND version.account_id=v_breakdown.tax_account_id) THEN
        RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_DP_TAX_ACCOUNT_INVALID';
      END IF;
      v_line_no:=v_line_no+10;
      INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,account_id,
        debit,credit,store_id,warehouse_id,customer_id,description)
      VALUES(p_company_id,v_journal.id,v_line_no,v_breakdown.tax_account_id,
        v_breakdown.applied_tax_amount,0,v_invoice.store_id,v_invoice.warehouse_id,
        v_invoice.customer_id,'Pengurang pajak DP '||v_breakdown.tax_code_snapshot);
    END LOOP;
    v_account:=private.resolve_financial_event_account(v_event,'SALES_REVENUE');
    v_line_no:=v_line_no+10;
    INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,account_id,
      debit,credit,store_id,warehouse_id,customer_id,description)
    VALUES(p_company_id,v_journal.id,v_line_no,v_account,0,v_revenue,
      v_invoice.store_id,v_invoice.warehouse_id,v_invoice.customer_id,'Pendapatan penjualan');
    FOR v_breakdown IN SELECT breakdown.*
      FROM public.backoffice_sales_invoice_tax_breakdowns breakdown
      WHERE breakdown.company_id=p_company_id AND breakdown.invoice_id=v_invoice.id
      ORDER BY breakdown.tax_group_no
    LOOP
      IF NOT EXISTS(SELECT 1 FROM public.tax_rule_versions version
        WHERE version.company_id=p_company_id
          AND version.tax_rule_id=v_breakdown.tax_rule_id
          AND version.rule_version=v_breakdown.tax_rule_version
          AND version.account_function_key='OUTPUT_TAX'
          AND version.account_id=v_breakdown.tax_account_id) THEN
        RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_TAX_ACCOUNT_INVALID';
      END IF;
      v_line_no:=v_line_no+10;
      INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,account_id,
        debit,credit,store_id,warehouse_id,customer_id,description)
      VALUES(p_company_id,v_journal.id,v_line_no,v_breakdown.tax_account_id,0,
        v_breakdown.tax_amount,v_invoice.store_id,v_invoice.warehouse_id,
        v_invoice.customer_id,'Pajak keluaran '||v_breakdown.tax_code_snapshot);
    END LOOP;
  END IF;

  v_expected_debit:=round(v_invoice.grand_total+v_applied_basis+v_applied_tax,4);
  v_expected_credit:=round(v_revenue+v_invoice.tax_total,4);
  IF v_expected_debit<>v_expected_credit THEN RAISE EXCEPTION 'JOURNAL_UNBALANCED'; END IF;
  UPDATE public.finance_journals SET status='POSTED',posted_by=p_actor_id,posted_at=v_now
  WHERE company_id=p_company_id AND id=v_journal.id RETURNING * INTO v_journal;
  IF round(v_journal.total_debit,4)<>v_expected_debit
    OR round(v_journal.total_credit,4)<>v_expected_credit THEN
    RAISE EXCEPTION 'JOURNAL_UNBALANCED';
  END IF;
  UPDATE public.financial_events SET status='POSTED'::public.event_status,
    processed_at=v_now,error_message=NULL,transaction_rule_version=v_rule_version
  WHERE company_id=p_company_id AND id=v_event.id;
  RETURN jsonb_build_object('financialEventId',v_event.id,'journalId',v_journal.id,
    'journalNo',v_journal.journal_no,'status','POSTED','journalType',v_journal.journal_type,
    'accountingDate',v_journal.accounting_date,'originalEventDate',v_journal.original_event_date,
    'totalDebit',v_journal.total_debit,'totalCredit',v_journal.total_credit,
    'idempotentReplay',false);
END
$$;

ALTER FUNCTION private.post_financial_event_core(uuid,uuid,bigint,uuid)
  RENAME TO post_financial_event_core_pre_backoffice_invoice;
CREATE FUNCTION private.post_financial_event_core(
  p_company_id uuid,p_event_id uuid,p_expected_event_version bigint,p_actor_id uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_key text;v_source text;
BEGIN
  SELECT event.system_event_key,event.source_table INTO v_key,v_source
  FROM public.financial_events event
  WHERE event.company_id=p_company_id AND event.id=p_event_id;
  IF v_key IN('BACKOFFICE_SALES_INVOICE','BACKOFFICE_SALES_DOWN_PAYMENT')
    AND v_source='backoffice_sales_invoices' THEN
    RETURN private.post_backoffice_sales_invoice_financial_event_core(
      p_company_id,p_event_id,p_expected_event_version,p_actor_id);
  END IF;
  RETURN private.post_financial_event_core_pre_backoffice_invoice(
    p_company_id,p_event_id,p_expected_event_version,p_actor_id);
END
$$;

ALTER FUNCTION private.f4b_financial_event_supported(public.financial_events)
  RENAME TO f4b_financial_event_supported_pre_backoffice_invoice;
CREATE FUNCTION private.f4b_financial_event_supported(
  p_event public.financial_events
) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
  SELECT CASE WHEN p_event.status::text='HOLD'
    AND p_event.system_event_key IN(
      'BACKOFFICE_SALES_INVOICE','BACKOFFICE_SALES_DOWN_PAYMENT')
    AND p_event.source_table='backoffice_sales_invoices' THEN true
    ELSE private.f4b_financial_event_supported_pre_backoffice_invoice(p_event) END
$$;

CREATE FUNCTION public.post_backoffice_sales_invoice(
  p_invoice_id uuid,p_expected_version bigint,p_operation_id uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='8s' AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
  v_invoice public.backoffice_sales_invoices%rowtype;v_hash text;v_retry jsonb;
  v_before jsonb;v_after jsonb;v_response jsonb;v_category uuid;v_rule_version bigint;
  v_event public.financial_events%rowtype;v_finance jsonb;v_timezone text;v_event_at timestamptz;
  v_invoice_no text;v_dp_total numeric(24,4);v_dp_tax numeric(24,4);
BEGIN
  PERFORM private.require_backoffice_sales_invoice_post_permission(v_company);
  IF p_invoice_id IS NULL OR p_expected_version IS NULL OR p_operation_id IS NULL THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_POST_PAYLOAD_INVALID';
  END IF;
  v_hash:=encode(extensions.digest(convert_to(jsonb_build_object('invoiceId',p_invoice_id,
    'expectedVersion',p_expected_version)::text,'UTF8'),'sha256'),'hex');
  PERFORM pg_advisory_xact_lock(hashtextextended(
    v_company::text||':BACKOFFICE_INVOICE:'||p_operation_id::text,0));
  v_retry:=private.backoffice_sales_invoice_operation_retry(
    v_company,p_operation_id,'POST',v_hash);
  IF v_retry IS NOT NULL THEN RETURN v_retry; END IF;
  SELECT invoice.* INTO v_invoice FROM public.backoffice_sales_invoices invoice
  WHERE invoice.company_id=v_company AND invoice.id=p_invoice_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_NOT_FOUND'; END IF;
  IF v_invoice.status<>'DRAFT' THEN RAISE EXCEPTION 'FINAL_BACKOFFICE_SALES_INVOICE_IMMUTABLE'; END IF;
  IF v_invoice.master_version<>p_expected_version THEN RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(
    v_company::text||':BACKOFFICE_INVOICE_ORDER:'||v_invoice.sales_order_id::text,0));
  PERFORM 1 FROM public.backoffice_sales_order_lines line
  WHERE line.company_id=v_company AND line.sales_order_id=v_invoice.sales_order_id
  ORDER BY line.line_no FOR UPDATE;
  PERFORM 1 FROM public.backoffice_sales_invoices invoice
  WHERE invoice.company_id=v_company AND invoice.sales_order_id=v_invoice.sales_order_id
  ORDER BY invoice.invoice_sequence FOR UPDATE;
  IF NOT EXISTS(SELECT 1 FROM public.accounting_periods period
    WHERE period.company_id=v_company
      AND v_invoice.invoice_date BETWEEN period.start_date AND period.end_date
      AND period.status IN('OPEN','REOPENED')) THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_PERIOD_NOT_OPEN';
  END IF;
  IF round(v_invoice.charge_total,4)<>round(COALESCE((SELECT
      sum(line.line_amount+line.discount_amount)
      FROM public.backoffice_sales_invoice_lines line
      WHERE line.company_id=v_company AND line.invoice_id=v_invoice.id
        AND line.effect_type='CHARGE'),0),4)
    OR round(v_invoice.discount_total,4)<>round(COALESCE((SELECT
      sum(line.discount_amount) FROM public.backoffice_sales_invoice_lines line
      WHERE line.company_id=v_company AND line.invoice_id=v_invoice.id
        AND line.effect_type='CHARGE'),0),4)
    OR round(v_invoice.tax_total,4)<>round(COALESCE((SELECT sum(line.tax_amount)
      FROM public.backoffice_sales_invoice_lines line
      WHERE line.company_id=v_company AND line.invoice_id=v_invoice.id
        AND line.effect_type='CHARGE'),0),4)
    OR round(v_invoice.down_payment_deduction_total,4)<>round(COALESCE((SELECT
      sum(line.line_amount) FROM public.backoffice_sales_invoice_lines line
      WHERE line.company_id=v_company AND line.invoice_id=v_invoice.id
        AND line.effect_type='DEDUCTION'),0),4) THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_AMOUNT_RECONCILIATION_FAILED';
  END IF;
  IF v_invoice.invoice_type='REGULAR' THEN
    IF NOT EXISTS(SELECT 1 FROM public.backoffice_sales_invoice_quantity_allocations allocation
      WHERE allocation.company_id=v_company AND allocation.invoice_id=v_invoice.id
        AND allocation.status='HELD')
      OR EXISTS(SELECT 1 FROM public.backoffice_sales_invoice_lines line
        LEFT JOIN public.backoffice_sales_invoice_quantity_allocations allocation
          ON allocation.company_id=line.company_id
          AND allocation.invoice_line_id=line.id
        WHERE line.company_id=v_company AND line.invoice_id=v_invoice.id
          AND line.line_type='PRODUCT'
          AND (allocation.id IS NULL OR allocation.status<>'HELD'
            OR round(allocation.allocated_base_qty,6)<>round(line.quantity_base,6)))
      OR EXISTS(SELECT 1 FROM public.backoffice_sales_invoice_quantity_allocations allocation
        JOIN public.backoffice_sales_invoice_lines line
          ON line.company_id=allocation.company_id AND line.id=allocation.invoice_line_id
        WHERE allocation.company_id=v_company AND allocation.invoice_id=v_invoice.id
          AND (allocation.status<>'HELD'
            OR round(allocation.allocated_base_qty,6)<>round(line.quantity_base,6))) THEN
      RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_QUANTITY_HOLD_INVALID';
    END IF;
    IF EXISTS(SELECT 1 FROM public.backoffice_sales_down_payment_applications application
      JOIN public.backoffice_sales_invoices dp ON dp.company_id=application.company_id
        AND dp.id=application.down_payment_invoice_id
      WHERE application.company_id=v_company AND application.regular_invoice_id=v_invoice.id
        AND (application.status<>'HELD' OR dp.status<>'POSTED'
          OR dp.sales_order_id<>v_invoice.sales_order_id)) THEN
      RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_DP_APPLICATION_INVALID';
    END IF;
  ELSIF EXISTS(SELECT 1 FROM public.backoffice_sales_invoice_quantity_allocations allocation
      WHERE allocation.company_id=v_company AND allocation.invoice_id=v_invoice.id)
    OR EXISTS(SELECT 1 FROM public.backoffice_sales_down_payment_applications application
      WHERE application.company_id=v_company
        AND application.regular_invoice_id=v_invoice.id) THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_DOWN_PAYMENT_LINEAGE_INVALID';
  END IF;
  SELECT round(COALESCE(sum(application.applied_amount),0),4),
    round(COALESCE(sum(application.applied_tax_amount),0),4)
  INTO v_dp_total,v_dp_tax FROM public.backoffice_sales_down_payment_applications application
  WHERE application.company_id=v_company AND application.regular_invoice_id=v_invoice.id
    AND application.status='HELD';
  IF v_dp_total<>round(v_invoice.down_payment_deduction_total,4)
    OR v_dp_tax<>round(COALESCE((SELECT sum(tax.applied_tax_amount)
      FROM public.backoffice_sales_down_payment_application_tax_breakdowns tax
      JOIN public.backoffice_sales_down_payment_applications application
        ON application.company_id=tax.company_id AND application.id=tax.application_id
      WHERE tax.company_id=v_company AND application.regular_invoice_id=v_invoice.id
        AND application.status='HELD'),0),4) THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_DP_APPLICATION_INVALID';
  END IF;
  IF EXISTS(SELECT 1 FROM public.backoffice_sales_down_payment_applications application
      WHERE application.company_id=v_company AND application.regular_invoice_id=v_invoice.id
        AND application.status='HELD'
        AND round(application.applied_tax_amount,4)<>round(COALESCE((SELECT sum(tax.applied_tax_amount)
          FROM public.backoffice_sales_down_payment_application_tax_breakdowns tax
          WHERE tax.company_id=application.company_id
            AND tax.application_id=application.id),0),4)) THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_DP_TAX_ALLOCATION_INVALID';
  END IF;
  IF EXISTS(SELECT 1 FROM public.backoffice_sales_invoice_receivable_schedules schedule
      WHERE schedule.company_id=v_company AND schedule.invoice_id=v_invoice.id
        AND schedule.status<>'DRAFT')
    OR (v_invoice.grand_total=0 AND EXISTS(SELECT 1
      FROM public.backoffice_sales_invoice_receivable_schedules schedule
      WHERE schedule.company_id=v_company AND schedule.invoice_id=v_invoice.id))
    OR (round(COALESCE((SELECT sum(schedule.amount_due)
      FROM public.backoffice_sales_invoice_receivable_schedules schedule
      WHERE schedule.company_id=v_company AND schedule.invoice_id=v_invoice.id
        AND schedule.status='DRAFT'),0),4)<>round(v_invoice.grand_total,4)
      AND v_invoice.grand_total>0) THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_SCHEDULE_INVALID';
  END IF;
  SELECT company.timezone INTO v_timezone FROM public.companies company
  WHERE company.id=v_company AND company.status='ACTIVE';
  IF v_timezone IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_NOT_FOUND'; END IF;
  v_event_at:=(v_invoice.invoice_date::text||' 12:00:00')::timestamp AT TIME ZONE v_timezone;
  SELECT category.id INTO v_category FROM public.transaction_categories category
  WHERE category.company_id=v_company AND category.is_active
    AND category.system_key=CASE v_invoice.invoice_type WHEN 'REGULAR'
      THEN 'BACKOFFICE_SALES_INVOICE' ELSE 'BACKOFFICE_SALES_DOWN_PAYMENT' END;
  IF v_category IS NULL THEN RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_CATEGORY_REQUIRED'; END IF;
  SELECT max(rule.rule_version) INTO v_rule_version FROM public.transaction_account_rules rule
  WHERE rule.company_id=v_company AND rule.transaction_category_id=v_category
    AND rule.status='ACTIVE' AND rule.effective_from<=v_event_at
    AND (rule.effective_to IS NULL OR rule.effective_to>v_event_at);
  IF v_rule_version IS NULL THEN RAISE EXCEPTION 'ACCOUNT_MAPPING_MISSING_OR_AMBIGUOUS'; END IF;
  v_invoice_no:='INV-'||to_char(v_invoice.invoice_date,'YYYYMMDD')||'-'||
    lpad(nextval('private.pos_invoice_number_seq')::text,10,'0');
  v_before:=private.backoffice_sales_invoice_snapshot(v_company,v_invoice.id);
  INSERT INTO public.financial_events(event_code,event_type,source_table,source_id,
    event_date,event_version,idempotency_key,amounts,status,error_message,created_by,
    company_id,store_id,system_event_key,transaction_category_id,transaction_rule_version)
  VALUES('BO-INV-'||replace(v_invoice.id::text,'-',''),'SALE_POSTED'::public.event_type,
    'backoffice_sales_invoices',v_invoice.id,v_event_at,1,
    'BACKOFFICE_INVOICE|'||v_company||'|'||v_invoice.id||'|'||p_operation_id,
    jsonb_build_object('invoiceId',v_invoice.id,'salesOrderId',v_invoice.sales_order_id,
      'invoiceType',v_invoice.invoice_type,'invoiceDate',v_invoice.invoice_date,
      'chargeTotal',v_invoice.charge_total,'discountTotal',v_invoice.discount_total,
      'taxTotal',v_invoice.tax_total,
      'downPaymentDeductionTotal',v_invoice.down_payment_deduction_total,
      'grandTotal',v_invoice.grand_total,'financePostingState','HOLD'),
    'HOLD'::public.event_status,'CANONICAL_FINANCE_POSTING_PENDING',v_actor,
    v_company,v_invoice.store_id,CASE v_invoice.invoice_type WHEN 'REGULAR'
      THEN 'BACKOFFICE_SALES_INVOICE' ELSE 'BACKOFFICE_SALES_DOWN_PAYMENT' END,
    v_category,v_rule_version) RETURNING * INTO v_event;
  UPDATE public.backoffice_sales_invoices SET status='POSTED',invoice_no=v_invoice_no,
    financial_event_id=v_event.id,posted_by=v_actor,posted_at=clock_timestamp(),
    master_version=master_version+1,updated_by=v_actor,updated_at=clock_timestamp()
  WHERE company_id=v_company AND id=v_invoice.id RETURNING * INTO v_invoice;
  IF v_invoice.invoice_type='REGULAR' THEN
    UPDATE public.backoffice_sales_order_lines source SET
      draft_invoice_allocated_base_qty=source.draft_invoice_allocated_base_qty
        -allocation.allocated_base_qty,
      invoiced_base_qty=source.invoiced_base_qty+allocation.allocated_base_qty
    FROM public.backoffice_sales_invoice_quantity_allocations allocation
    WHERE allocation.company_id=v_company AND allocation.invoice_id=v_invoice.id
      AND allocation.status='HELD' AND source.company_id=allocation.company_id
      AND source.id=allocation.sales_order_line_id;
    UPDATE public.backoffice_sales_invoice_quantity_allocations SET status='POSTED',
      updated_at=clock_timestamp()
    WHERE company_id=v_company AND invoice_id=v_invoice.id AND status='HELD';
    UPDATE public.backoffice_sales_down_payment_applications SET status='POSTED',
      updated_at=clock_timestamp()
    WHERE company_id=v_company AND regular_invoice_id=v_invoice.id AND status='HELD';
  END IF;
  UPDATE public.backoffice_sales_invoice_receivable_schedules SET status='OPEN',
    updated_at=clock_timestamp()
  WHERE company_id=v_company AND invoice_id=v_invoice.id AND status='DRAFT';
  v_finance:=private.post_backoffice_sales_invoice_financial_event_core(
    v_company,v_event.id,v_event.event_version,v_actor);
  v_after:=private.backoffice_sales_invoice_snapshot(v_company,v_invoice.id);
  v_response:=jsonb_build_object('companyId',v_company,'data',v_after,
    'finance',v_finance,'exactRetry',false);
  INSERT INTO public.backoffice_sales_invoice_operations(company_id,operation_id,
    operation_type,invoice_id,expected_version,request_hash,response_snapshot,actor_id)
  VALUES(v_company,p_operation_id,'POST',v_invoice.id,p_expected_version,v_hash,
    v_response,v_actor);
  INSERT INTO public.backoffice_sales_invoice_audit(company_id,invoice_id,action,
    operation_id,actor_id,before_state,after_state)
  VALUES(v_company,v_invoice.id,'POST',p_operation_id,v_actor,v_before,v_after);
  RETURN v_response;
END
$$;

CREATE FUNCTION private.trg_guard_backoffice_sales_dp_application_tax_history()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_status text;
BEGIN
  SELECT invoice.status INTO v_status
  FROM public.backoffice_sales_down_payment_applications application
  JOIN public.backoffice_sales_invoices invoice
    ON invoice.company_id=application.company_id
    AND invoice.id=application.regular_invoice_id
  WHERE application.company_id=COALESCE(NEW.company_id,OLD.company_id)
    AND application.id=COALESCE(NEW.application_id,OLD.application_id);
  IF v_status IS NULL THEN RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_DP_APPLICATION_NOT_FOUND'; END IF;
  IF v_status<>'DRAFT' THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_DP_APPLICATION_IMMUTABLE';
  END IF;
  RETURN COALESCE(NEW,OLD);
END
$$;
CREATE TRIGGER backoffice_sales_dp_application_tax_history_guard
BEFORE UPDATE OR DELETE
ON public.backoffice_sales_down_payment_application_tax_breakdowns
FOR EACH ROW EXECUTE FUNCTION private.trg_guard_backoffice_sales_dp_application_tax_history();

CREATE FUNCTION private.trg_delete_backoffice_sales_dp_application_children()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_status text;
BEGIN
  SELECT invoice.status INTO v_status FROM public.backoffice_sales_invoices invoice
  WHERE invoice.company_id=OLD.company_id AND invoice.id=OLD.regular_invoice_id;
  IF v_status<>'DRAFT' THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_DP_APPLICATION_IMMUTABLE';
  END IF;
  DELETE FROM public.backoffice_sales_down_payment_application_tax_breakdowns child
  WHERE child.company_id=OLD.company_id AND child.application_id=OLD.id;
  RETURN OLD;
END
$$;
CREATE TRIGGER backoffice_sales_dp_application_delete_children
BEFORE DELETE ON public.backoffice_sales_down_payment_applications
FOR EACH ROW EXECUTE FUNCTION private.trg_delete_backoffice_sales_dp_application_children();

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
    'grandTotal',invoice.grand_total,'financialEventId',invoice.financial_event_id,
    'notes',invoice.notes,'masterVersion',invoice.master_version,
    'createdAt',invoice.created_at,'updatedAt',invoice.updated_at,
    'postedAt',invoice.posted_at,'postedBy',invoice.posted_by,
    'canceledAt',invoice.canceled_at,'cancelReason',invoice.cancel_reason,
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
    'downPaymentApplications',COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'id',application.id,'downPaymentInvoiceId',application.down_payment_invoice_id,
      'downPaymentInvoiceNo',dp.invoice_no,'downPaymentDraftNo',dp.draft_no,
      'appliedAmount',application.applied_amount,
      'appliedBasisAmount',application.applied_basis_amount,
      'appliedTaxAmount',application.applied_tax_amount,'status',application.status,
      'taxBreakdowns',COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'taxGroupNo',tax.tax_group_no,'taxRuleId',tax.tax_rule_id,
        'taxRuleVersion',tax.tax_rule_version,'taxAccountId',tax.tax_account_id,
        'taxCode',tax.tax_code_snapshot,'taxName',tax.tax_name_snapshot,
        'appliedTaxAmount',tax.applied_tax_amount) ORDER BY tax.tax_group_no)
        FROM public.backoffice_sales_down_payment_application_tax_breakdowns tax
        WHERE tax.company_id=application.company_id
          AND tax.application_id=application.id),'[]'::jsonb))
      ORDER BY dp.posted_at,dp.invoice_sequence,dp.id)
      FROM public.backoffice_sales_down_payment_applications application
      JOIN public.backoffice_sales_invoices dp ON dp.company_id=application.company_id
        AND dp.id=application.down_payment_invoice_id
      WHERE application.company_id=invoice.company_id
        AND application.regular_invoice_id=invoice.id
        AND application.status IN('HELD','POSTED')),'[]'::jsonb),
    'availableDownPayments',CASE WHEN invoice.status='DRAFT' AND invoice.invoice_type='REGULAR'
      THEN COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'invoiceId',available.id,'invoiceNo',available.invoice_no,
        'invoiceSequence',available.invoice_sequence,'postedAt',available.posted_at,
        'availableAmount',available.available_amount)
        ORDER BY available.posted_at,available.invoice_sequence,available.id)
      FROM (SELECT dp.id,dp.invoice_no,dp.invoice_sequence,dp.posted_at,
          round(dp.grand_total-COALESCE(sum(application.applied_amount)
            FILTER(WHERE application.status IN('HELD','POSTED')
              AND application.regular_invoice_id<>invoice.id),0),4) available_amount
        FROM public.backoffice_sales_invoices dp
        LEFT JOIN public.backoffice_sales_down_payment_applications application
          ON application.company_id=dp.company_id
          AND application.down_payment_invoice_id=dp.id
        WHERE dp.company_id=invoice.company_id
          AND dp.sales_order_id=invoice.sales_order_id
          AND dp.invoice_type='DOWN_PAYMENT' AND dp.status='POSTED'
        GROUP BY dp.id,dp.invoice_no,dp.invoice_sequence,dp.posted_at,dp.grand_total
        HAVING round(dp.grand_total-COALESCE(sum(application.applied_amount)
          FILTER(WHERE application.status IN('HELD','POSTED')
            AND application.regular_invoice_id<>invoice.id),0),4)>0) available),'[]'::jsonb)
      ELSE '[]'::jsonb END,
    'schedules',COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'installmentNo',schedule.installment_no,'dueDate',schedule.due_date,
      'amountDue',schedule.amount_due,'allocatedPaymentAmount',schedule.allocated_payment_amount,
      'status',schedule.status) ORDER BY schedule.installment_no)
      FROM public.backoffice_sales_invoice_receivable_schedules schedule
      WHERE schedule.company_id=invoice.company_id AND schedule.invoice_id=invoice.id),'[]'::jsonb)
  ) FROM public.backoffice_sales_invoices invoice
  WHERE invoice.company_id=p_company_id AND invoice.id=p_invoice_id
$$;

REVOKE ALL ON FUNCTION
  private.require_backoffice_sales_invoice_post_permission(uuid),
  private.rebuild_backoffice_sales_invoice_dp_applications(uuid,uuid,jsonb,text),
  private.trg_auto_apply_backoffice_sales_invoice_dp(),
  private.post_backoffice_sales_invoice_financial_event_core(uuid,uuid,bigint,uuid),
  private.post_financial_event_core_pre_backoffice_invoice(uuid,uuid,bigint,uuid),
  private.post_financial_event_core(uuid,uuid,bigint,uuid),
  private.f4b_financial_event_supported_pre_backoffice_invoice(public.financial_events),
  private.f4b_financial_event_supported(public.financial_events),
  private.trg_guard_backoffice_sales_dp_application_tax_history(),
  private.trg_delete_backoffice_sales_dp_application_children()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.require_backoffice_sales_invoice_post_permission(uuid),
  private.rebuild_backoffice_sales_invoice_dp_applications(uuid,uuid,jsonb,text),
  private.trg_auto_apply_backoffice_sales_invoice_dp(),
  private.post_backoffice_sales_invoice_financial_event_core(uuid,uuid,bigint,uuid),
  private.post_financial_event_core_pre_backoffice_invoice(uuid,uuid,bigint,uuid),
  private.post_financial_event_core(uuid,uuid,bigint,uuid),
  private.f4b_financial_event_supported_pre_backoffice_invoice(public.financial_events),
  private.f4b_financial_event_supported(public.financial_events),
  private.trg_guard_backoffice_sales_dp_application_tax_history(),
  private.trg_delete_backoffice_sales_dp_application_children()
TO service_role;
REVOKE ALL ON FUNCTION
  public.set_backoffice_sales_invoice_down_payments(uuid,bigint,uuid,jsonb),
  public.post_backoffice_sales_invoice(uuid,bigint,uuid)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION
  public.set_backoffice_sales_invoice_down_payments(uuid,bigint,uuid,jsonb),
  public.post_backoffice_sales_invoice(uuid,bigint,uuid)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260909161000','backoffice_sales_invoice_posting_runtime',
  'Transactional Finance-authorized Regular/DP Invoice posting; canonical shared Invoice number, exact retry, open invoice-date period, posted quantity holds, auto/editable DP applications, per-tax-account DP deduction, AR/Advance/Revenue/Output Tax Journal and immutable snapshots; no POS, Stock, FIFO or receipt COGS mutation');

NOTIFY pgrst,'reload schema';
COMMIT;
