-- Backoffice Sales delivery-fee parity.
-- Isolated Development rollout only. No POS Retail, Stock, FIFO, DO, or COGS mutation.
BEGIN;

DO $guard$
DECLARE v_post text;v_finance text;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260910140000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: cutover procurement blocker required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260910150000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260910150000';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
    WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
  IF to_regprocedure('public.save_backoffice_sales_order_draft(uuid,bigint,uuid,jsonb)') IS NULL
    OR to_regprocedure('private.backoffice_sales_order_snapshot(uuid,uuid)') IS NULL
    OR to_regprocedure('private.save_backoffice_sales_invoice_draft_core(uuid,bigint,uuid,uuid,jsonb)') IS NULL
    OR to_regprocedure('private.backoffice_sales_invoice_snapshot(uuid,uuid)') IS NULL
    OR to_regprocedure('private.rebuild_backoffice_sales_invoice_schedules(uuid,uuid,uuid)') IS NULL
    OR to_regprocedure('private.post_backoffice_sales_invoice_financial_event_core(uuid,uuid,bigint,uuid)') IS NULL
    OR to_regprocedure('public.post_backoffice_sales_invoice(uuid,bigint,uuid)') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Backoffice Sales chain missing';
  END IF;
  IF to_regprocedure('public.save_backoffice_sales_order_draft_before_delivery_fee(uuid,bigint,uuid,jsonb)') IS NOT NULL
    OR to_regprocedure('private.save_backoffice_sales_invoice_draft_core_before_delivery_fee(uuid,bigint,uuid,uuid,jsonb)') IS NOT NULL
    OR to_regprocedure('private.backoffice_sales_order_snapshot_before_delivery_fee(uuid,uuid)') IS NOT NULL
    OR to_regprocedure('private.backoffice_sales_invoice_snapshot_before_delivery_fee(uuid,uuid)') IS NOT NULL
    OR to_regprocedure('private.trg_backoffice_sales_order_delivery_fee()') IS NOT NULL
    OR to_regprocedure('private.trg_backoffice_sales_invoice_delivery_fee()') IS NOT NULL
    OR EXISTS(SELECT 1 FROM information_schema.columns
      WHERE table_schema='public' AND column_name='delivery_fee_amount'
        AND table_name IN('backoffice_sales_orders','backoffice_sales_invoices')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: delivery-fee identity collision';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.account_functions function_state
    WHERE function_state.function_key='DELIVERY_FEE_REVENUE' AND function_state.is_active) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: DELIVERY_FEE_REVENUE catalog missing';
  END IF;
  IF EXISTS(SELECT 1 FROM public.posting_rule_sets rule_set
    LEFT JOIN LATERAL(SELECT count(*) line_count FROM public.posting_rule_lines line
      WHERE line.company_id=rule_set.company_id AND line.rule_set_id=rule_set.id) lines ON true
    WHERE rule_set.system_key='BACKOFFICE_SALES_INVOICE' AND rule_set.status='APPROVED'
      AND (rule_set.rule_set_version<>2 OR lines.line_count<>5)) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Regular Invoice posting rule v2 drift';
  END IF;
  IF EXISTS(SELECT 1 FROM public.transaction_categories category
    LEFT JOIN public.posting_rule_sets rule_set
      ON rule_set.company_id=category.company_id
      AND rule_set.transaction_category_id=category.id
      AND rule_set.system_key=category.system_key AND rule_set.status='APPROVED'
    WHERE category.system_key='BACKOFFICE_SALES_INVOICE' AND category.is_active
    GROUP BY category.company_id,category.id HAVING count(rule_set.id)<>1) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Regular Invoice approved posting rule ambiguous';
  END IF;
  IF EXISTS(SELECT 1 FROM public.transaction_categories category
    JOIN public.transaction_account_rules rule ON rule.company_id=category.company_id
      AND rule.transaction_category_id=category.id
    WHERE category.system_key='BACKOFFICE_SALES_INVOICE' AND category.is_active
      AND rule.system_key='BACKOFFICE_SALES_INVOICE'
      AND rule.account_function_key='DELIVERY_FEE_REVENUE')
    OR EXISTS(SELECT 1 FROM public.system_events event
      WHERE event.system_key='BACKOFFICE_SALES_INVOICE'
        AND 'DELIVERY_FEE_REVENUE'=ANY(event.conditional_account_functions)) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: delivery-fee Finance identity collision';
  END IF;
  IF EXISTS(SELECT 1 FROM public.transaction_categories category
    WHERE category.system_key='BACKOFFICE_SALES_INVOICE' AND category.is_active
      AND NOT EXISTS(SELECT 1 FROM (
        SELECT rule.account_id FROM public.transaction_account_rules rule
        JOIN public.transaction_categories source_category
          ON source_category.company_id=rule.company_id
          AND source_category.id=rule.transaction_category_id
          AND source_category.is_active
        JOIN public.chart_of_accounts account ON account.company_id=rule.company_id
          AND account.id=rule.account_id AND account.is_active AND account.is_postable
        WHERE rule.company_id=category.company_id
          AND rule.system_key IN('SALE_POSTED','SALE_DISPATCHED')
          AND source_category.system_key=rule.system_key
          AND rule.account_function_key='DELIVERY_FEE_REVENUE'
          AND rule.status='ACTIVE' AND rule.effective_from<=clock_timestamp()
          AND (rule.effective_to IS NULL OR rule.effective_to>clock_timestamp())
        UNION ALL
        SELECT fallback.account_id FROM public.company_account_function_fallbacks fallback
        JOIN public.chart_of_accounts account ON account.company_id=fallback.company_id
          AND account.id=fallback.account_id AND account.is_active AND account.is_postable
        WHERE fallback.company_id=category.company_id
          AND fallback.account_function_key='DELIVERY_FEE_REVENUE'
          AND fallback.status='ACTIVE' AND fallback.effective_from<=clock_timestamp()
          AND (fallback.effective_to IS NULL OR fallback.effective_to>clock_timestamp())
        UNION ALL
        SELECT account.id FROM public.chart_of_accounts account
        WHERE account.company_id=category.company_id AND account.is_active
          AND account.is_postable AND account.is_system_account
          AND account.system_function_key='DELIVERY_FEE_REVENUE') candidate)) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical delivery-fee account missing';
  END IF;
  SELECT pg_get_functiondef('public.post_backoffice_sales_invoice(uuid,bigint,uuid)'::regprocedure)
    INTO v_post;
  IF (length(v_post)-length(replace(v_post,
      '''taxTotal'',v_invoice.tax_total,','')))/length('''taxTotal'',v_invoice.tax_total,')<>1 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Invoice Post event anchor drift';
  END IF;
  SELECT pg_get_functiondef(
    'private.post_backoffice_sales_invoice_financial_event_core(uuid,uuid,bigint,uuid)'::regprocedure)
    INTO v_finance;
  IF position('v_expected_credit:=round(v_revenue+v_invoice.tax_total,4);' in v_finance)=0
    OR position('''SALES_REVENUE''' in v_finance)=0 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Invoice Finance runtime drift';
  END IF;
END
$guard$;

ALTER TABLE public.backoffice_sales_orders
  ADD COLUMN delivery_fee_amount numeric(20,4) NOT NULL DEFAULT 0,
  ADD COLUMN delivery_fee_invoice_display_mode text NOT NULL DEFAULT 'SHOW_SEPARATE';
ALTER TABLE public.backoffice_sales_orders
  ADD CONSTRAINT backoffice_sales_orders_delivery_fee_check CHECK(
    delivery_fee_amount>=0
    AND delivery_fee_invoice_display_mode IN('SHOW_SEPARATE','HIDE_BREAKDOWN'));
ALTER TABLE public.backoffice_sales_orders
  DROP CONSTRAINT backoffice_sales_orders_amount_check,
  ADD CONSTRAINT backoffice_sales_orders_amount_check CHECK(
    subtotal>=0 AND discount_total>=0 AND global_discount>=0
    AND discount_total<=subtotal AND tax_total>=0
    AND rounding_direction IN('NONE','DOWN','UP') AND rounding_increment>0
    AND grand_total_before_rounding=subtotal-discount_total
    AND rounding_adjustment=grand_total-delivery_fee_amount-grand_total_before_rounding
    AND grand_total>=0);

ALTER TABLE public.backoffice_sales_invoices
  ADD COLUMN delivery_fee_amount numeric(24,4) NOT NULL DEFAULT 0;
ALTER TABLE public.backoffice_sales_invoices
  DROP CONSTRAINT backoffice_sales_invoices_shape_check,
  ADD CONSTRAINT backoffice_sales_invoices_shape_check CHECK(
    invoice_sequence>0 AND currency_code~'^[A-Z]{3}$' AND master_version>0
    AND jsonb_typeof(customer_snapshot)='object'
    AND jsonb_typeof(payment_term_snapshot)='object'
    AND jsonb_typeof(commercial_snapshot)='object'
    AND ((invoice_type='REGULAR' AND down_payment_mode IS NULL AND down_payment_input IS NULL)
      OR (invoice_type='DOWN_PAYMENT' AND down_payment_mode IN('PERCENT','FIXED')
        AND down_payment_input>0
        AND (down_payment_mode<>'PERCENT' OR down_payment_input<=100)))
    AND down_payment_basis_total>=0 AND charge_total>=0 AND discount_total>=0
    AND tax_total>=0 AND delivery_fee_amount>=0 AND down_payment_deduction_total>=0
    AND (invoice_type='REGULAR' OR delivery_fee_amount=0)
    AND grand_total=charge_total-discount_total+tax_total+delivery_fee_amount
      -down_payment_deduction_total
    AND grand_total>=0
    AND ((status='DRAFT' AND invoice_no IS NULL AND posted_at IS NULL AND posted_by IS NULL
          AND canceled_at IS NULL AND canceled_by IS NULL)
      OR (status='POSTED' AND invoice_no IS NOT NULL AND posted_at IS NOT NULL AND posted_by IS NOT NULL
          AND canceled_at IS NULL AND canceled_by IS NULL)
      OR (status='CANCELED' AND posted_at IS NULL AND posted_by IS NULL
          AND canceled_at IS NOT NULL AND canceled_by IS NOT NULL
          AND nullif(btrim(cancel_reason),'') IS NOT NULL)
      OR (status='REVERSED' AND invoice_no IS NOT NULL AND posted_at IS NOT NULL AND posted_by IS NOT NULL
          AND canceled_at IS NOT NULL AND canceled_by IS NOT NULL
          AND nullif(btrim(cancel_reason),'') IS NOT NULL)));

CREATE FUNCTION private.trg_backoffice_sales_order_delivery_fee()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_fee_setting text;v_mode_setting text;v_allocated numeric;
BEGIN
  v_fee_setting:=current_setting('kgs.backoffice_delivery_fee_amount',true);
  v_mode_setting:=current_setting('kgs.backoffice_delivery_fee_display_mode',true);
  IF NULLIF(v_fee_setting,'') IS NOT NULL THEN
    BEGIN NEW.delivery_fee_amount:=round(v_fee_setting::numeric,4);
    EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'BACKOFFICE_DELIVERY_FEE_INVALID'; END;
  ELSIF TG_OP='INSERT' THEN NEW.delivery_fee_amount:=0;
  END IF;
  IF NULLIF(v_mode_setting,'') IS NOT NULL THEN
    NEW.delivery_fee_invoice_display_mode:=upper(btrim(v_mode_setting));
  ELSIF TG_OP='INSERT' THEN NEW.delivery_fee_invoice_display_mode:='SHOW_SEPARATE';
  END IF;
  IF NEW.delivery_fee_amount<0 OR NEW.delivery_fee_invoice_display_mode NOT IN(
      'SHOW_SEPARATE','HIDE_BREAKDOWN') THEN
    RAISE EXCEPTION 'BACKOFFICE_DELIVERY_FEE_INVALID';
  END IF;
  SELECT round(COALESCE(sum(invoice.delivery_fee_amount),0),4) INTO v_allocated
  FROM public.backoffice_sales_invoices invoice
  WHERE invoice.company_id=NEW.company_id AND invoice.sales_order_id=NEW.id
    AND invoice.invoice_type='REGULAR' AND invoice.status IN('DRAFT','POSTED');
  IF v_allocated>NEW.delivery_fee_amount THEN
    RAISE EXCEPTION 'BACKOFFICE_DELIVERY_FEE_BELOW_INVOICE_ALLOCATION';
  END IF;
  NEW.grand_total:=round(NEW.grand_total_before_rounding+NEW.rounding_adjustment
    +NEW.delivery_fee_amount,4);
  RETURN NEW;
END
$$;
CREATE TRIGGER backoffice_sales_order_delivery_fee_guard
BEFORE INSERT OR UPDATE
ON public.backoffice_sales_orders FOR EACH ROW
EXECUTE FUNCTION private.trg_backoffice_sales_order_delivery_fee();

CREATE FUNCTION private.trg_backoffice_sales_invoice_delivery_fee()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_order_fee numeric;v_other_fee numeric;
BEGIN
  IF NEW.delivery_fee_amount<0
    OR (NEW.invoice_type='DOWN_PAYMENT' AND NEW.delivery_fee_amount<>0) THEN
    RAISE EXCEPTION 'BACKOFFICE_INVOICE_DELIVERY_FEE_INVALID';
  END IF;
  SELECT document.delivery_fee_amount INTO v_order_fee
  FROM public.backoffice_sales_orders document
  WHERE document.company_id=NEW.company_id AND document.id=NEW.sales_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'BACKOFFICE_SALES_ORDER_NOT_FOUND'; END IF;
  SELECT round(COALESCE(sum(invoice.delivery_fee_amount),0),4) INTO v_other_fee
  FROM public.backoffice_sales_invoices invoice
  WHERE invoice.company_id=NEW.company_id AND invoice.sales_order_id=NEW.sales_order_id
    AND invoice.id<>NEW.id AND invoice.invoice_type='REGULAR'
    AND invoice.status IN('DRAFT','POSTED');
  IF NEW.status IN('DRAFT','POSTED')
    AND v_other_fee+NEW.delivery_fee_amount>v_order_fee THEN
    RAISE EXCEPTION 'BACKOFFICE_INVOICE_DELIVERY_FEE_EXCEEDS_ORDER';
  END IF;
  NEW.grand_total:=round(NEW.charge_total-NEW.discount_total+NEW.tax_total
    +NEW.delivery_fee_amount-NEW.down_payment_deduction_total,4);
  RETURN NEW;
END
$$;
CREATE TRIGGER backoffice_sales_invoice_delivery_fee_guard
BEFORE INSERT OR UPDATE
ON public.backoffice_sales_invoices FOR EACH ROW
EXECUTE FUNCTION private.trg_backoffice_sales_invoice_delivery_fee();

ALTER FUNCTION private.backoffice_sales_order_snapshot(uuid,uuid)
  RENAME TO backoffice_sales_order_snapshot_before_delivery_fee;
CREATE FUNCTION private.backoffice_sales_order_snapshot(p_company_id uuid,p_order_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
  SELECT private.backoffice_sales_order_snapshot_before_delivery_fee(p_company_id,p_order_id)
    ||jsonb_build_object('deliveryFeeAmount',document.delivery_fee_amount,
      'deliveryFeeInvoiceDisplayMode',document.delivery_fee_invoice_display_mode)
  FROM public.backoffice_sales_orders document
  WHERE document.company_id=p_company_id AND document.id=p_order_id
$$;

ALTER FUNCTION public.save_backoffice_sales_order_draft(uuid,bigint,uuid,jsonb)
  RENAME TO save_backoffice_sales_order_draft_before_delivery_fee;
CREATE FUNCTION public.save_backoffice_sales_order_draft(
  p_order_id uuid,p_expected_version bigint,p_operation_id uuid,p_payload jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='8s' AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_fee numeric:=0;
  v_mode text:='SHOW_SEPARATE';v_response jsonb;
BEGIN
  IF p_payload IS NULL OR jsonb_typeof(p_payload)<>'object' THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_ORDER_PAYLOAD_INVALID';
  END IF;
  BEGIN
    IF p_payload ? 'deliveryFeeAmount' THEN
      v_fee:=round((p_payload->>'deliveryFeeAmount')::numeric,4);
    ELSIF p_order_id IS NOT NULL THEN
      SELECT document.delivery_fee_amount INTO v_fee
      FROM public.backoffice_sales_orders document
      WHERE document.company_id=v_company AND document.id=p_order_id;
    END IF;
    v_mode:=upper(btrim(COALESCE(NULLIF(p_payload->>'deliveryFeeInvoiceDisplayMode',''),
      CASE WHEN p_order_id IS NULL THEN 'SHOW_SEPARATE' ELSE
        (SELECT document.delivery_fee_invoice_display_mode
         FROM public.backoffice_sales_orders document
         WHERE document.company_id=v_company AND document.id=p_order_id) END,
      'SHOW_SEPARATE')));
  EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'BACKOFFICE_DELIVERY_FEE_INVALID'; END;
  v_fee:=COALESCE(v_fee,0);
  IF v_fee<0 OR v_mode NOT IN('SHOW_SEPARATE','HIDE_BREAKDOWN') THEN
    RAISE EXCEPTION 'BACKOFFICE_DELIVERY_FEE_INVALID';
  END IF;
  PERFORM set_config('kgs.backoffice_delivery_fee_amount',v_fee::text,true);
  PERFORM set_config('kgs.backoffice_delivery_fee_display_mode',v_mode,true);
  v_response:=public.save_backoffice_sales_order_draft_before_delivery_fee(
    p_order_id,p_expected_version,p_operation_id,p_payload);
  RETURN v_response;
END
$$;

ALTER FUNCTION private.backoffice_sales_invoice_snapshot(uuid,uuid)
  RENAME TO backoffice_sales_invoice_snapshot_before_delivery_fee;
CREATE FUNCTION private.backoffice_sales_invoice_snapshot(p_company_id uuid,p_invoice_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
  SELECT private.backoffice_sales_invoice_snapshot_before_delivery_fee(p_company_id,p_invoice_id)
    ||jsonb_build_object('deliveryFeeAmount',invoice.delivery_fee_amount,
      'orderDeliveryFeeAmount',document.delivery_fee_amount,
      'deliveryFeeInvoiceDisplayMode',document.delivery_fee_invoice_display_mode,
      'deliveryFeeRemaining',greatest(0,document.delivery_fee_amount-COALESCE((
        SELECT sum(other_invoice.delivery_fee_amount)
        FROM public.backoffice_sales_invoices other_invoice
        WHERE other_invoice.company_id=invoice.company_id
          AND other_invoice.sales_order_id=invoice.sales_order_id
          AND other_invoice.id<>invoice.id AND other_invoice.invoice_type='REGULAR'
          AND other_invoice.status IN('DRAFT','POSTED')),0)))
  FROM public.backoffice_sales_invoices invoice
  JOIN public.backoffice_sales_orders document ON document.company_id=invoice.company_id
    AND document.id=invoice.sales_order_id
  WHERE invoice.company_id=p_company_id AND invoice.id=p_invoice_id
$$;

ALTER FUNCTION private.save_backoffice_sales_invoice_draft_core(uuid,bigint,uuid,uuid,jsonb)
  RENAME TO save_backoffice_sales_invoice_draft_core_before_delivery_fee;
CREATE FUNCTION private.save_backoffice_sales_invoice_draft_core(
  p_invoice_id uuid,p_expected_version bigint,p_operation_id uuid,
  p_sales_order_id uuid,p_payload jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
  v_response jsonb;v_invoice_id uuid;v_invoice public.backoffice_sales_invoices%rowtype;
  v_order public.backoffice_sales_orders%rowtype;v_fee numeric;v_other_fee numeric;
  v_after jsonb;
BEGIN
  v_response:=private.save_backoffice_sales_invoice_draft_core_before_delivery_fee(
    p_invoice_id,p_expected_version,p_operation_id,p_sales_order_id,p_payload);
  IF COALESCE((v_response->>'exactRetry')::boolean,false) THEN RETURN v_response; END IF;
  v_invoice_id:=(v_response->'data'->>'id')::uuid;
  SELECT * INTO STRICT v_invoice FROM public.backoffice_sales_invoices invoice
  WHERE invoice.company_id=v_company AND invoice.id=v_invoice_id FOR UPDATE;
  SELECT * INTO STRICT v_order FROM public.backoffice_sales_orders document
  WHERE document.company_id=v_company AND document.id=p_sales_order_id FOR UPDATE;
  IF v_invoice.invoice_type='DOWN_PAYMENT' THEN
    IF p_payload ? 'deliveryFeeAmount'
      AND round(COALESCE(NULLIF(p_payload->>'deliveryFeeAmount','')::numeric,0),4)<>0 THEN
      RAISE EXCEPTION 'BACKOFFICE_INVOICE_DELIVERY_FEE_NOT_ALLOWED_ON_DP';
    END IF;
    v_fee:=0;
  ELSIF p_payload ? 'deliveryFeeAmount' THEN
    BEGIN v_fee:=round((p_payload->>'deliveryFeeAmount')::numeric,4);
    EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'BACKOFFICE_INVOICE_DELIVERY_FEE_INVALID'; END;
  ELSIF p_invoice_id IS NULL THEN
    SELECT round(COALESCE(sum(other_invoice.delivery_fee_amount),0),4) INTO v_other_fee
    FROM public.backoffice_sales_invoices other_invoice
    WHERE other_invoice.company_id=v_company
      AND other_invoice.sales_order_id=p_sales_order_id
      AND other_invoice.id<>v_invoice_id AND other_invoice.invoice_type='REGULAR'
      AND other_invoice.status IN('DRAFT','POSTED');
    v_fee:=greatest(0,v_order.delivery_fee_amount-v_other_fee);
  ELSE
    v_fee:=v_invoice.delivery_fee_amount;
  END IF;
  IF v_fee<0 THEN RAISE EXCEPTION 'BACKOFFICE_INVOICE_DELIVERY_FEE_INVALID'; END IF;
  UPDATE public.backoffice_sales_invoices SET delivery_fee_amount=v_fee,
    commercial_snapshot=commercial_snapshot||jsonb_build_object(
      'deliveryFeeAuthority','BACKOFFICE_ORDER_ALLOCATION'),
    updated_by=v_actor,updated_at=clock_timestamp()
  WHERE company_id=v_company AND id=v_invoice_id;
  PERFORM private.rebuild_backoffice_sales_invoice_schedules(v_company,v_invoice_id,v_actor);
  v_after:=private.backoffice_sales_invoice_snapshot(v_company,v_invoice_id);
  v_response:=jsonb_build_object('companyId',v_company,'data',v_after,'exactRetry',false);
  UPDATE public.backoffice_sales_invoice_operations SET response_snapshot=v_response
  WHERE company_id=v_company AND operation_id=p_operation_id AND operation_type='SAVE_DRAFT';
  UPDATE public.backoffice_sales_invoice_audit SET after_state=v_after
  WHERE company_id=v_company AND operation_id=p_operation_id
    AND action IN('CREATE_DRAFT','UPDATE_DRAFT');
  RETURN v_response;
END
$$;

-- Reuse the canonical delivery-fee revenue account; never invent a COA mapping.
CREATE FUNCTION private.resolve_backoffice_delivery_fee_account(p_company_id uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_source text;v_count bigint;v_account uuid;
BEGIN
  FOREACH v_source IN ARRAY ARRAY['SALE_POSTED','SALE_DISPATCHED']::text[] LOOP
    SELECT count(DISTINCT rule.account_id),
      (array_agg(DISTINCT rule.account_id ORDER BY rule.account_id))[1]
    INTO v_count,v_account
    FROM public.transaction_account_rules rule
    JOIN public.transaction_categories category ON category.company_id=rule.company_id
      AND category.id=rule.transaction_category_id AND category.is_active
    JOIN public.chart_of_accounts account ON account.company_id=rule.company_id
      AND account.id=rule.account_id
    WHERE rule.company_id=p_company_id AND rule.system_key=v_source
      AND category.system_key=v_source
      AND rule.account_function_key='DELIVERY_FEE_REVENUE'
      AND rule.status='ACTIVE' AND rule.effective_from<=clock_timestamp()
      AND (rule.effective_to IS NULL OR rule.effective_to>clock_timestamp())
      AND account.is_active AND account.is_postable;
    IF v_count=1 THEN RETURN v_account; END IF;
    IF v_count>1 THEN RAISE EXCEPTION
      'MIGRATION_PRECONDITION_FAILED: ambiguous delivery-fee source %.%',p_company_id,v_source; END IF;
  END LOOP;
  SELECT count(DISTINCT fallback.account_id),
    (array_agg(DISTINCT fallback.account_id ORDER BY fallback.account_id))[1]
  INTO v_count,v_account FROM public.company_account_function_fallbacks fallback
  JOIN public.chart_of_accounts account ON account.company_id=fallback.company_id
    AND account.id=fallback.account_id
  WHERE fallback.company_id=p_company_id
    AND fallback.account_function_key='DELIVERY_FEE_REVENUE'
    AND fallback.status='ACTIVE' AND fallback.effective_from<=clock_timestamp()
    AND (fallback.effective_to IS NULL OR fallback.effective_to>clock_timestamp())
    AND account.is_active AND account.is_postable;
  IF v_count=1 THEN RETURN v_account; END IF;
  IF v_count>1 THEN RAISE EXCEPTION
    'MIGRATION_PRECONDITION_FAILED: ambiguous delivery-fee fallback %',p_company_id; END IF;
  SELECT count(*),(array_agg(account.id ORDER BY account.id))[1] INTO v_count,v_account
  FROM public.chart_of_accounts account
  WHERE account.company_id=p_company_id AND account.is_system_account
    AND account.system_function_key='DELIVERY_FEE_REVENUE'
    AND account.is_active AND account.is_postable;
  IF v_count=1 THEN RETURN v_account; END IF;
  RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: delivery-fee mapping missing %',p_company_id;
END
$$;

DO $finance_mapping$
DECLARE v_actor uuid;v_category record;v_account uuid;v_rule uuid;
  v_old record;v_new uuid;v_now timestamptz:=clock_timestamp();
BEGIN
  SELECT profile.id INTO v_actor FROM public.profiles profile
  JOIN auth.users auth_user ON auth_user.id=profile.id
  WHERE profile.role::text='super_admin' ORDER BY profile.id LIMIT 1;
  IF v_actor IS NULL THEN RAISE EXCEPTION
    'MIGRATION_PRECONDITION_FAILED: linked Super Admin required'; END IF;
  UPDATE public.system_events event SET
    conditional_account_functions=array_append(event.conditional_account_functions,
      'DELIVERY_FEE_REVENUE')
  WHERE event.system_key='BACKOFFICE_SALES_INVOICE'
    AND NOT ('DELIVERY_FEE_REVENUE'=ANY(event.conditional_account_functions));
  FOR v_category IN SELECT category.* FROM public.transaction_categories category
    WHERE category.system_key='BACKOFFICE_SALES_INVOICE' AND category.is_active
    ORDER BY category.company_id
  LOOP
    v_account:=private.resolve_backoffice_delivery_fee_account(v_category.company_id);
    INSERT INTO public.transaction_account_rules(company_id,transaction_category_id,
      system_key,account_function_key,account_id,effective_from,rule_version,status,
      approved_by,approved_at,created_by,updated_by)
    VALUES(v_category.company_id,v_category.id,'BACKOFFICE_SALES_INVOICE',
      'DELIVERY_FEE_REVENUE',v_account,'-infinity'::timestamptz,1,'ACTIVE',
      v_actor,v_now,v_actor,v_actor) RETURNING id INTO v_rule;
    INSERT INTO public.finance_master_audit(company_id,entity_type,entity_id,
      action,actor_id,after_state)
    SELECT rule.company_id,'RULE',rule.id,'CREATE',v_actor,to_jsonb(rule)
    FROM public.transaction_account_rules rule WHERE rule.id=v_rule;
  END LOOP;
  FOR v_old IN SELECT rule_set.* FROM public.posting_rule_sets rule_set
    WHERE rule_set.system_key='BACKOFFICE_SALES_INVOICE'
      AND rule_set.status='APPROVED' ORDER BY rule_set.company_id
  LOOP
    INSERT INTO public.posting_rule_set_audit(company_id,rule_set_id,action,
      actor_id,before_state,after_state,reason)
    VALUES(v_old.company_id,v_old.id,'RETIRE',v_actor,to_jsonb(v_old),
      to_jsonb(v_old)||jsonb_build_object('status','RETIRED'),
      'Add separate Backoffice delivery-fee revenue line');
    UPDATE public.posting_rule_sets SET status='RETIRED',master_version=master_version+1,
      updated_by=v_actor,updated_at=v_now
    WHERE company_id=v_old.company_id AND id=v_old.id;
    INSERT INTO public.posting_rule_sets(company_id,transaction_category_id,system_key,
      rule_set_version,effective_from,status,description,created_by,updated_by)
    VALUES(v_old.company_id,v_old.transaction_category_id,'BACKOFFICE_SALES_INVOICE',
      v_old.rule_set_version+1,'-infinity'::timestamptz,'DRAFT',
      'Regular Invoice: AR plus applied DP equals Product Revenue, tax, and delivery-fee revenue',
      v_actor,v_actor) RETURNING id INTO v_new;
    INSERT INTO public.posting_rule_lines(company_id,rule_set_id,line_no,
      account_function_key,entry_side,amount_expression_key,condition_key,
      is_required,created_by)
    SELECT line.company_id,v_new,line.line_no,line.account_function_key,line.entry_side,
      line.amount_expression_key,line.condition_key,line.is_required,v_actor
    FROM public.posting_rule_lines line
    WHERE line.company_id=v_old.company_id AND line.rule_set_id=v_old.id
    ORDER BY line.line_no;
    INSERT INTO public.posting_rule_lines(company_id,rule_set_id,line_no,
      account_function_key,entry_side,amount_expression_key,condition_key,is_required,created_by)
    VALUES(v_old.company_id,v_new,60,'DELIVERY_FEE_REVENUE','CREDIT',
      'BACKOFFICE_INVOICE_DELIVERY_FEE','BACKOFFICE_INVOICE_HAS_DELIVERY_FEE',false,v_actor);
    INSERT INTO public.posting_rule_set_audit(company_id,rule_set_id,action,
      actor_id,after_state,reason)
    SELECT rule_set.company_id,rule_set.id,'CREATE',v_actor,
      to_jsonb(rule_set)||jsonb_build_object('lines',(SELECT jsonb_agg(to_jsonb(line)
        ORDER BY line.line_no) FROM public.posting_rule_lines line
        WHERE line.company_id=rule_set.company_id AND line.rule_set_id=rule_set.id)),
      'Backoffice delivery-fee posting definition'
    FROM public.posting_rule_sets rule_set WHERE rule_set.id=v_new;
    UPDATE public.posting_rule_sets SET status='APPROVED',approved_by=v_actor,
      approved_at=v_now,updated_by=v_actor
    WHERE company_id=v_old.company_id AND id=v_new;
    INSERT INTO public.posting_rule_set_audit(company_id,rule_set_id,action,
      actor_id,after_state,reason)
    SELECT rule_set.company_id,rule_set.id,'APPROVE',v_actor,
      to_jsonb(rule_set)||jsonb_build_object('lines',(SELECT jsonb_agg(to_jsonb(line)
        ORDER BY line.line_no) FROM public.posting_rule_lines line
        WHERE line.company_id=rule_set.company_id AND line.rule_set_id=rule_set.id)),
      'Approve Backoffice delivery-fee posting definition'
    FROM public.posting_rule_sets rule_set WHERE rule_set.id=v_new;
  END LOOP;
END
$finance_mapping$;
DROP FUNCTION private.resolve_backoffice_delivery_fee_account(uuid);

DO $patch_post$
DECLARE v_definition text;v_needle text;v_replacement text;
BEGIN
  SELECT pg_get_functiondef('public.post_backoffice_sales_invoice(uuid,bigint,uuid)'::regprocedure)
    INTO v_definition;
  v_needle:='''taxTotal'',v_invoice.tax_total,';
  v_replacement:='''taxTotal'',v_invoice.tax_total,''deliveryFeeAmount'',v_invoice.delivery_fee_amount,';
  IF (length(v_definition)-length(replace(v_definition,v_needle,'')))/length(v_needle)<>1 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Invoice Post event anchor drift';
  END IF;
  EXECUTE replace(v_definition,v_needle,v_replacement);
END
$patch_post$;

DO $patch_finance$
DECLARE v_definition text;v_needle text;v_replacement text;
BEGIN
  SELECT pg_get_functiondef(
    'private.post_backoffice_sales_invoice_financial_event_core(uuid,uuid,bigint,uuid)'::regprocedure)
    INTO v_definition;
  v_needle:='v_tax numeric(24,4);v_expected_debit numeric(24,4);v_expected_credit numeric(24,4);';
  v_replacement:='v_tax numeric(24,4);v_delivery_fee numeric(24,4);v_expected_debit numeric(24,4);v_expected_credit numeric(24,4);';
  IF (length(v_definition)-length(replace(v_definition,v_needle,'')))/length(v_needle)<>1 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Finance declaration anchor drift'; END IF;
  v_definition:=replace(v_definition,v_needle,v_replacement);
  v_needle:='OR round((v_event.amounts->>''downPaymentDeductionTotal'')::numeric,4)';
  v_replacement:='OR round(COALESCE(
      NULLIF(v_event.amounts->>''deliveryFeeAmount'','''')::numeric,0),4)
      <>round(v_invoice.delivery_fee_amount,4)
    OR round((v_event.amounts->>''downPaymentDeductionTotal'')::numeric,4)';
  IF (length(v_definition)-length(replace(v_definition,v_needle,'')))/length(v_needle)<>1 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Finance amount anchor drift'; END IF;
  v_definition:=replace(v_definition,v_needle,v_replacement);
  v_needle:='v_revenue:=round(v_invoice.charge_total-v_invoice.discount_total,4);';
  v_replacement:='v_revenue:=round(v_invoice.charge_total-v_invoice.discount_total,4);
  v_delivery_fee:=round(v_invoice.delivery_fee_amount,4);';
  IF (length(v_definition)-length(replace(v_definition,v_needle,'')))/length(v_needle)<>1 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Finance revenue anchor drift'; END IF;
  v_definition:=replace(v_definition,v_needle,v_replacement);
  v_needle:='''Pendapatan penjualan'');';
  v_replacement:='''Pendapatan penjualan'');
    IF v_delivery_fee>0 THEN
      v_account:=private.resolve_financial_event_account(v_event,''DELIVERY_FEE_REVENUE'');
      v_line_no:=v_line_no+10;
      INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,account_id,
        debit,credit,store_id,warehouse_id,customer_id,description)
      VALUES(p_company_id,v_journal.id,v_line_no,v_account,0,v_delivery_fee,
        v_invoice.store_id,v_invoice.warehouse_id,v_invoice.customer_id,''Pendapatan ongkir'');
    END IF;';
  IF (length(v_definition)-length(replace(v_definition,v_needle,'')))/length(v_needle)<>1 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Finance journal anchor drift'; END IF;
  v_definition:=replace(v_definition,v_needle,v_replacement);
  v_needle:='v_expected_credit:=round(v_revenue+v_invoice.tax_total,4);';
  v_replacement:='v_expected_credit:=round(v_revenue+v_invoice.tax_total+v_delivery_fee,4);';
  IF (length(v_definition)-length(replace(v_definition,v_needle,'')))/length(v_needle)<>1 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Finance balance anchor drift'; END IF;
  EXECUTE replace(v_definition,v_needle,v_replacement);
  SELECT pg_get_functiondef(
    'private.post_backoffice_sales_invoice_financial_event_core(uuid,uuid,bigint,uuid)'::regprocedure)
    INTO v_definition;
  IF position('DELIVERY_FEE_REVENUE' in v_definition)=0
    OR position('deliveryFeeAmount' in v_definition)=0
    OR position('NULLIF(v_event.amounts->>''deliveryFeeAmount'','''')::numeric,0'
      in v_definition)=0
    OR position('v_expected_credit:=round(v_revenue+v_invoice.tax_total+v_delivery_fee,4);'
      in v_definition)=0 THEN
    RAISE EXCEPTION 'MIGRATION_POSTCONDITION_FAILED: Invoice Finance delivery-fee patch missing';
  END IF;
END
$patch_finance$;

REVOKE ALL ON FUNCTION
  private.trg_backoffice_sales_order_delivery_fee(),
  private.trg_backoffice_sales_invoice_delivery_fee(),
  private.backoffice_sales_order_snapshot_before_delivery_fee(uuid,uuid),
  private.backoffice_sales_order_snapshot(uuid,uuid),
  private.backoffice_sales_invoice_snapshot_before_delivery_fee(uuid,uuid),
  private.backoffice_sales_invoice_snapshot(uuid,uuid),
  private.save_backoffice_sales_invoice_draft_core_before_delivery_fee(uuid,bigint,uuid,uuid,jsonb),
  private.save_backoffice_sales_invoice_draft_core(uuid,bigint,uuid,uuid,jsonb)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.trg_backoffice_sales_order_delivery_fee(),
  private.trg_backoffice_sales_invoice_delivery_fee(),
  private.backoffice_sales_order_snapshot_before_delivery_fee(uuid,uuid),
  private.backoffice_sales_order_snapshot(uuid,uuid),
  private.backoffice_sales_invoice_snapshot_before_delivery_fee(uuid,uuid),
  private.backoffice_sales_invoice_snapshot(uuid,uuid),
  private.save_backoffice_sales_invoice_draft_core_before_delivery_fee(uuid,bigint,uuid,uuid,jsonb),
  private.save_backoffice_sales_invoice_draft_core(uuid,bigint,uuid,uuid,jsonb)
TO service_role;
REVOKE ALL ON FUNCTION
  public.save_backoffice_sales_order_draft_before_delivery_fee(uuid,bigint,uuid,jsonb),
  public.save_backoffice_sales_order_draft(uuid,bigint,uuid,jsonb)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  public.save_backoffice_sales_order_draft_before_delivery_fee(uuid,bigint,uuid,jsonb)
TO service_role;
GRANT EXECUTE ON FUNCTION
  public.save_backoffice_sales_order_draft(uuid,bigint,uuid,jsonb)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260910150000','backoffice_sales_delivery_fee_parity',
  'Backoffice SO delivery fee, first Regular Invoice auto-allocation with editable aggregate cap and cancel release, separate DELIVERY_FEE_REVENUE posting, exact-retry snapshots; no POS Retail, Stock, FIFO, DO, DP fee or COGS change');

NOTIFY pgrst,'reload schema';
COMMIT;
