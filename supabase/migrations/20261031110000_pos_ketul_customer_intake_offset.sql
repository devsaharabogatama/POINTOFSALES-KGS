BEGIN;

DO $guard$
DECLARE
  v_company constant uuid := 'a59c534b-909f-4b3f-aba0-ae9db6d90b76';
  v_dependencies integer;
  v_post_definition text;
BEGIN
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20261031110000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20261031110000';
  END IF;
  SELECT count(*) INTO v_dependencies FROM private.kgs_schema_migrations
  WHERE version IN('20260720090000','20260722120000','20260722150000',
    '20260722180000','20261008110000','20261008120000','20261008130000',
    '20261030120000','20261030130000','20261031100000');
  IF v_dependencies<>10 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: dependency ledger';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.companies company
      WHERE company.id=v_company AND company.company_code='KGFF'
        AND company.status='ACTIVE')
    OR NOT EXISTS(SELECT 1 FROM public.company_features feature
      WHERE feature.company_id=v_company AND feature.feature_code='ketul_enabled'
        AND feature.is_enabled) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: KGFF Ketul entitlement';
  END IF;
  IF (SELECT count(*) FROM public.product_categories category
      WHERE category.company_id=v_company AND upper(btrim(category.category_name))='KETUL'
        AND category.is_active)<>1
    OR (SELECT count(*) FROM public.products product
      JOIN public.product_categories category ON category.company_id=product.company_id
        AND category.id=product.category_id
      WHERE product.company_id=v_company AND category.is_active
        AND upper(btrim(category.category_name))='KETUL' AND product.is_active
        AND NOT product.is_bundle)<>4 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: exact KGFF Ketul catalog';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.chart_of_accounts account
      WHERE account.company_id=v_company AND account.account_code='1030100-4'
        AND account.account_name='PERSEDIAAN KETUL' AND account.account_type='ASSET'
        AND account.normal_balance='DEBIT' AND account.is_active
        AND account.is_postable AND NOT account.is_system_account)
    THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Finance account authority';
  END IF;
  IF EXISTS(SELECT 1 FROM public.chart_of_accounts account
      WHERE account.company_id=v_company AND (account.account_code='2010105-1'
        OR lower(btrim(account.account_name))=lower('HUTANG KETUL CUSTOMER')))
    OR EXISTS(SELECT 1 FROM public.account_functions function_state
      WHERE function_state.function_key='CUSTOMER_KETUL_PAYABLE')
    OR EXISTS(SELECT 1 FROM public.payment_methods method
      WHERE method.company_id=v_company AND method.method_type='KETUL_OFFSET')
    OR to_regclass('public.pos_ketul_customer_intakes') IS NOT NULL
    OR to_regprocedure('public.save_pos_sale_draft_with_ketul(jsonb)') IS NOT NULL
    OR to_regprocedure('public.post_pos_sale_with_ketul(uuid,bigint,uuid)') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Ketul runtime already present';
  END IF;
  SELECT pg_get_functiondef(
    'private.post_pos_sale_online_core(uuid,bigint,uuid)'::regprocedure)
    INTO v_post_definition;
  IF v_post_definition NOT LIKE '%v_payment_method.method_type = ''KETUL_OFFSET''%'
    OR v_post_definition NOT LIKE '%DEFERRED_PAYMENT_METHOD_NOT_ENABLED%'
    OR v_post_definition LIKE '%kgs.ketul_post_context%' THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: POS Ketul guard drift';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
      WHERE status IN('PREVIEWED','APPROVED','PROCESSING'))
    OR EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
      WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active runtime queue';
  END IF;
END
$guard$;

INSERT INTO public.account_functions(function_key,function_name,
  compatible_account_types,default_normal_balance,allow_reconciliation)
VALUES('CUSTOMER_KETUL_PAYABLE','Hutang Ketul Customer',
  ARRAY['LIABILITY']::text[],'CREDIT',true);

UPDATE public.system_events event SET
  required_account_functions=(
    SELECT array_agg(DISTINCT function_key ORDER BY function_key)
    FROM unnest(event.required_account_functions
      ||ARRAY['CUSTOMER_KETUL_PAYABLE']::text[]) function_key),
  updated_at=clock_timestamp()
WHERE event.system_key='KETUL_CUSTOMER_INTAKE';

DO $finance$
DECLARE
  v_company constant uuid := 'a59c534b-909f-4b3f-aba0-ae9db6d90b76';
  v_actor uuid;v_account uuid;v_category uuid;v_now timestamptz:=clock_timestamp();
  v_rule_version bigint;v_fallback_version bigint;
BEGIN
  SELECT profile.id INTO STRICT v_actor FROM public.profiles profile
  WHERE public.private_is_super_admin(profile.id) ORDER BY profile.id LIMIT 1;
  INSERT INTO public.chart_of_accounts(company_id,account_code,account_name,
    account_type,normal_balance,parent_account_id,system_function_key,
    is_system_account,is_postable,allow_manual_posting,allow_reconciliation,
    is_active,created_by,updated_by)
  VALUES(v_company,'2010105-1','HUTANG KETUL CUSTOMER','LIABILITY','CREDIT',
    NULL,NULL,false,true,false,true,true,v_actor,v_actor)
  RETURNING id INTO v_account;
  INSERT INTO public.finance_master_audit(company_id,entity_type,entity_id,
    action,actor_id,after_state)
  SELECT v_company,'ACCOUNT',account.id,'CREATE',v_actor,to_jsonb(account)
  FROM public.chart_of_accounts account WHERE account.id=v_account;

  SELECT category.id INTO STRICT v_category FROM public.transaction_categories category
  WHERE category.company_id=v_company
    AND category.system_key='KETUL_CUSTOMER_INTAKE' AND category.is_active;
  SELECT coalesce(max(rule.rule_version),0)+1 INTO v_rule_version
  FROM public.transaction_account_rules rule
  WHERE rule.company_id=v_company AND rule.transaction_category_id=v_category
    AND rule.account_function_key='CUSTOMER_KETUL_PAYABLE';
  INSERT INTO public.transaction_account_rules(company_id,transaction_category_id,
    system_key,account_function_key,account_id,effective_from,rule_version,status,
    approved_by,approved_at,created_by,updated_by)
  VALUES(v_company,v_category,'KETUL_CUSTOMER_INTAKE','CUSTOMER_KETUL_PAYABLE',
    v_account,v_now,v_rule_version,'ACTIVE',v_actor,v_now,v_actor,v_actor);

  SELECT coalesce(max(fallback.fallback_version),0)+1 INTO v_fallback_version
  FROM public.company_account_function_fallbacks fallback
  WHERE fallback.company_id=v_company
    AND fallback.account_function_key='CUSTOMER_KETUL_PAYABLE';
  INSERT INTO public.company_account_function_fallbacks(company_id,
    account_function_key,account_id,effective_from,fallback_version,status,
    approved_by,approved_at,created_by,updated_by)
  VALUES(v_company,'CUSTOMER_KETUL_PAYABLE',v_account,v_now,v_fallback_version,
    'ACTIVE',v_actor,v_now,v_actor,v_actor);

  INSERT INTO public.payment_methods(company_id,payment_method_code,
    payment_method_name,method_type,settlement_route,is_default,
    available_all_stores,proof_mode,fee_enabled,is_active,is_system_method,
    created_by,updated_by)
  VALUES(v_company,'','Potongan Ketul','KETUL_OFFSET','INTERNAL_LIABILITY',
    false,true,'OPTIONAL',false,true,true,v_actor,v_actor);
END
$finance$;

CREATE TABLE public.pos_ketul_customer_intakes(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL,
  sales_id uuid NOT NULL,
  store_id uuid NOT NULL,
  warehouse_id uuid NOT NULL,
  cashier_session_id uuid NOT NULL,
  customer_id uuid,
  status text NOT NULL DEFAULT 'DRAFT',
  total_amount numeric(20,4) NOT NULL,
  payload_hash text NOT NULL,
  master_version bigint NOT NULL DEFAULT 1,
  posting_idempotency_key uuid,
  financial_event_id uuid,
  finance_journal_id uuid,
  posted_by uuid REFERENCES public.profiles(id),
  posted_at timestamptz,
  created_by uuid NOT NULL REFERENCES public.profiles(id),
  updated_by uuid NOT NULL REFERENCES public.profiles(id),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT pos_ketul_intakes_company_id_id_unique UNIQUE(company_id,id),
  CONSTRAINT pos_ketul_intakes_company_sale_unique UNIQUE(company_id,sales_id),
  CONSTRAINT pos_ketul_intakes_sale_fk FOREIGN KEY(company_id,sales_id)
    REFERENCES public.sales_headers(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT pos_ketul_intakes_store_fk FOREIGN KEY(company_id,store_id)
    REFERENCES public.stores(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT pos_ketul_intakes_warehouse_fk FOREIGN KEY(company_id,warehouse_id)
    REFERENCES public.warehouses(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT pos_ketul_intakes_session_fk FOREIGN KEY(company_id,cashier_session_id)
    REFERENCES public.cashier_sessions(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT pos_ketul_intakes_customer_fk FOREIGN KEY(company_id,customer_id)
    REFERENCES public.customers(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT pos_ketul_intakes_status_check CHECK(status IN('DRAFT','POSTED')),
  CONSTRAINT pos_ketul_intakes_amount_positive CHECK(total_amount>0),
  CONSTRAINT pos_ketul_intakes_version_positive CHECK(master_version>0),
  CONSTRAINT pos_ketul_intakes_posted_shape CHECK(
    (status='DRAFT' AND posting_idempotency_key IS NULL
      AND financial_event_id IS NULL AND finance_journal_id IS NULL
      AND posted_by IS NULL AND posted_at IS NULL)
    OR
    (status='POSTED' AND posting_idempotency_key IS NOT NULL
      AND financial_event_id IS NOT NULL AND finance_journal_id IS NOT NULL
      AND posted_by IS NOT NULL AND posted_at IS NOT NULL))
);

CREATE TABLE public.pos_ketul_customer_intake_lines(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL,
  intake_id uuid NOT NULL,
  line_no integer NOT NULL,
  product_id uuid NOT NULL,
  base_uom_id uuid NOT NULL,
  quantity_base numeric(24,6) NOT NULL,
  unit_price numeric(20,4) NOT NULL,
  line_total numeric(20,4) NOT NULL,
  product_sku_snapshot text NOT NULL,
  product_name_snapshot text NOT NULL,
  base_uom_name_snapshot text NOT NULL,
  product_batch_id uuid,
  stock_movement_id uuid,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT pos_ketul_lines_company_id_id_unique UNIQUE(company_id,id),
  CONSTRAINT pos_ketul_lines_intake_line_unique UNIQUE(company_id,intake_id,line_no),
  CONSTRAINT pos_ketul_lines_intake_product_unique UNIQUE(company_id,intake_id,product_id),
  CONSTRAINT pos_ketul_lines_intake_fk FOREIGN KEY(company_id,intake_id)
    REFERENCES public.pos_ketul_customer_intakes(company_id,id) ON DELETE CASCADE,
  CONSTRAINT pos_ketul_lines_product_fk FOREIGN KEY(company_id,product_id)
    REFERENCES public.products(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT pos_ketul_lines_uom_fk FOREIGN KEY(company_id,base_uom_id)
    REFERENCES public.uoms(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT pos_ketul_lines_quantity_positive CHECK(quantity_base>0),
  CONSTRAINT pos_ketul_lines_price_positive CHECK(unit_price>0),
  CONSTRAINT pos_ketul_lines_total_exact CHECK(
    line_total=round(quantity_base*unit_price,4))
);

CREATE TABLE public.pos_ketul_customer_intake_audit(
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id uuid NOT NULL,
  intake_id uuid NOT NULL,
  action text NOT NULL,
  actor_id uuid NOT NULL REFERENCES public.profiles(id),
  before_state jsonb,
  after_state jsonb,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT pos_ketul_audit_intake_fk FOREIGN KEY(company_id,intake_id)
    REFERENCES public.pos_ketul_customer_intakes(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT pos_ketul_audit_action_check CHECK(action IN('CREATE','UPDATE','POST'))
);

CREATE INDEX idx_pos_ketul_intakes_company_status
  ON public.pos_ketul_customer_intakes(company_id,status,created_at);
CREATE INDEX idx_pos_ketul_lines_product
  ON public.pos_ketul_customer_intake_lines(company_id,product_id);

ALTER TABLE public.pos_ketul_customer_intakes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pos_ketul_customer_intake_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pos_ketul_customer_intake_audit ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.pos_ketul_customer_intakes,
  public.pos_ketul_customer_intake_lines,public.pos_ketul_customer_intake_audit
FROM PUBLIC,anon,authenticated;
GRANT SELECT,INSERT,UPDATE,DELETE ON TABLE public.pos_ketul_customer_intakes,
  public.pos_ketul_customer_intake_lines,public.pos_ketul_customer_intake_audit
TO service_role;
GRANT USAGE,SELECT ON SEQUENCE public.pos_ketul_customer_intake_audit_id_seq
TO service_role;

CREATE FUNCTION private.trg_pos_ketul_intake_immutable()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
BEGIN
  IF TG_OP='DELETE' AND OLD.status='POSTED' THEN
    RAISE EXCEPTION 'POSTED_KETUL_INTAKE_IMMUTABLE';
  END IF;
  IF TG_OP='UPDATE' AND OLD.status='POSTED' THEN
    RAISE EXCEPTION 'POSTED_KETUL_INTAKE_IMMUTABLE';
  END IF;
  NEW.updated_at:=clock_timestamp();
  RETURN NEW;
END
$$;
CREATE TRIGGER pos_ketul_intake_immutable
BEFORE UPDATE OR DELETE ON public.pos_ketul_customer_intakes
FOR EACH ROW EXECUTE FUNCTION private.trg_pos_ketul_intake_immutable();

CREATE OR REPLACE FUNCTION private.trg_g6_set_settlement_function_snapshot()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_expected text;
BEGIN
  IF TG_OP='UPDATE' THEN
    IF NEW.settlement_account_function_snapshot IS DISTINCT FROM
       OLD.settlement_account_function_snapshot THEN
      RAISE EXCEPTION 'SETTLEMENT_ACCOUNT_FUNCTION_SNAPSHOT_IMMUTABLE';
    END IF;
    RETURN NEW;
  END IF;
  SELECT CASE NEW.settlement_route_snapshot
    WHEN 'CASH_DRAWER' THEN 'CASH_DRAWER'
    WHEN 'DIRECT_BANK' THEN method.bank_account_function
    WHEN 'CLEARING' THEN method.clearing_account_function
    WHEN 'RECEIVABLE' THEN 'CUSTOMER_RECEIVABLE'
    WHEN 'INTERNAL_LIABILITY' THEN CASE method.method_type
      WHEN 'KETUL_OFFSET' THEN 'CUSTOMER_KETUL_PAYABLE'
      ELSE 'CUSTOMER_BALANCE_LIABILITY' END
  END INTO v_expected
  FROM public.payment_methods method
  WHERE method.company_id=NEW.company_id AND method.id=NEW.payment_method_id;
  IF v_expected IS NULL THEN RAISE EXCEPTION 'SETTLEMENT_ACCOUNT_FUNCTION_REQUIRED'; END IF;
  IF NEW.settlement_account_function_snapshot IS NOT NULL
     AND NEW.settlement_account_function_snapshot<>v_expected THEN
    RAISE EXCEPTION 'SETTLEMENT_ACCOUNT_FUNCTION_SNAPSHOT_MISMATCH';
  END IF;
  NEW.settlement_account_function_snapshot:=v_expected;
  RETURN NEW;
END
$$;

DO $patch_post$
DECLARE v_definition text;v_patched text;v_old text;v_new text;
BEGIN
  SELECT pg_get_functiondef(
    'private.post_pos_sale_online_core(uuid,bigint,uuid)'::regprocedure)
    INTO v_definition;
  v_old:='IF v_payment_method.method_type = ''KETUL_OFFSET'' THEN
                RAISE EXCEPTION ''DEFERRED_PAYMENT_METHOD_NOT_ENABLED'';
            END IF;';
  v_new:='IF v_payment_method.method_type = ''KETUL_OFFSET'' AND NOT (
                current_setting(''kgs.ketul_post_context'',TRUE)=v_sale.id::TEXT
                AND EXISTS(SELECT 1
                  FROM public.pos_ketul_customer_intakes intake
                  WHERE intake.company_id=v_company AND intake.sales_id=v_sale.id
                    AND intake.status=''DRAFT''
                    AND intake.total_amount=v_payment_base)
            ) THEN
                RAISE EXCEPTION ''DEFERRED_PAYMENT_METHOD_NOT_ENABLED'';
            END IF;';
  v_patched:=replace(replace(v_definition,chr(13),''),replace(v_old,chr(13),''),
    replace(v_new,chr(13),''));
  IF v_patched=replace(v_definition,chr(13),'')
    OR v_patched NOT LIKE '%kgs.ketul_post_context%' THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: POS Ketul guard patch';
  END IF;
  EXECUTE v_patched;
END
$patch_post$;

CREATE FUNCTION public.save_pos_sale_draft_with_ketul(p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
  v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
  v_method uuid;v_payload jsonb:=p_payload;v_payments jsonb;v_lines jsonb;
  v_total numeric(20,4):=0;v_result jsonb;v_sale public.sales_headers%rowtype;
  v_intake public.pos_ketul_customer_intakes%rowtype;v_before jsonb;
  v_hash text;v_client_key uuid;v_row record;v_line_no integer:=0;
  v_intake_found boolean:=false;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
  IF jsonb_typeof(p_payload)<>'object' THEN RAISE EXCEPTION 'INVALID_SALE_PAYLOAD'; END IF;
  v_lines:=COALESCE(p_payload->'ketulIntakeLines','[]'::jsonb);
  IF jsonb_typeof(v_lines)<>'array' THEN RAISE EXCEPTION 'KETUL_LINES_ARRAY_REQUIRED'; END IF;
  IF jsonb_array_length(v_lines)>0 THEN
    IF COALESCE((p_payload->>'isTempo')::boolean,false) THEN
      RAISE EXCEPTION 'KETUL_OFFSET_TEMPO_NOT_SUPPORTED';
    END IF;
    IF NOT EXISTS(SELECT 1 FROM public.company_features feature
      WHERE feature.company_id=v_company AND feature.feature_code='ketul_enabled'
        AND feature.is_enabled) THEN RAISE EXCEPTION 'KETUL_FEATURE_DISABLED'; END IF;
  END IF;
  SELECT method.id INTO v_method FROM public.payment_methods method
  WHERE method.company_id=v_company AND method.method_type='KETUL_OFFSET'
    AND method.settlement_route='INTERNAL_LIABILITY' AND method.is_system_method
    AND method.is_active;
  IF jsonb_array_length(v_lines)>0 AND v_method IS NULL THEN
    RAISE EXCEPTION 'KETUL_OFFSET_METHOD_REQUIRED';
  END IF;

  CREATE TEMP TABLE IF NOT EXISTS pg_temp.ketul_input(
    product_id uuid PRIMARY KEY,quantity_base numeric(24,6),unit_price numeric(20,4)
  ) ON COMMIT DROP;
  TRUNCATE pg_temp.ketul_input;
  IF jsonb_array_length(v_lines)>0 THEN
    BEGIN
      INSERT INTO pg_temp.ketul_input(product_id,quantity_base,unit_price)
      SELECT (line->>'productId')::uuid,sum((line->>'quantity')::numeric),
        CASE WHEN min((line->>'unitPrice')::numeric)=max((line->>'unitPrice')::numeric)
          THEN min((line->>'unitPrice')::numeric)
          ELSE NULL END
      FROM jsonb_array_elements(v_lines) line GROUP BY (line->>'productId')::uuid;
    EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'INVALID_KETUL_LINE'; END;
    IF EXISTS(SELECT 1 FROM pg_temp.ketul_input input
        WHERE input.quantity_base<=0 OR input.unit_price IS NULL OR input.unit_price<=0)
      OR EXISTS(SELECT 1 FROM pg_temp.ketul_input input
        LEFT JOIN public.products product ON product.company_id=v_company
          AND product.id=input.product_id AND product.is_active AND NOT product.is_bundle
        LEFT JOIN public.product_categories category ON category.company_id=product.company_id
          AND category.id=product.category_id AND category.is_active
          AND upper(btrim(category.category_name))='KETUL'
        LEFT JOIN public.uoms uom ON uom.company_id=product.company_id
          AND uom.id=product.uom_id
        WHERE product.id IS NULL OR category.id IS NULL OR uom.id IS NULL) THEN
      RAISE EXCEPTION 'ACTIVE_KETUL_PRODUCT_REQUIRED';
    END IF;
    SELECT round(sum(input.quantity_base*input.unit_price),4) INTO v_total
    FROM pg_temp.ketul_input input;
  END IF;

  SELECT COALESCE(jsonb_agg(payment),'[]'::jsonb) INTO v_payments
  FROM jsonb_array_elements(COALESCE(p_payload->'payments','[]'::jsonb)) payment
  WHERE NOT EXISTS(SELECT 1 FROM public.payment_methods method
    WHERE method.company_id=v_company AND method.id=(payment->>'paymentMethodId')::uuid
      AND method.method_type='KETUL_OFFSET');
  IF v_total>0 THEN
    v_client_key:=(substr(md5(v_company::text||'|'||COALESCE(p_payload->>'clientTransactionId','')
      ||'|KETUL'),1,8)||'-'||substr(md5(v_company::text||'|'||COALESCE(p_payload->>'clientTransactionId','')
      ||'|KETUL'),9,4)||'-4'||substr(md5(v_company::text||'|'||COALESCE(p_payload->>'clientTransactionId','')
      ||'|KETUL'),14,3)||'-a'||substr(md5(v_company::text||'|'||COALESCE(p_payload->>'clientTransactionId','')
      ||'|KETUL'),18,3)||'-'||substr(md5(v_company::text||'|'||COALESCE(p_payload->>'clientTransactionId','')
      ||'|KETUL'),21,12))::uuid;
    v_payments:=v_payments||jsonb_build_array(jsonb_build_object(
      'clientPaymentKey',v_client_key,'paymentMethodId',v_method,
      'amount',v_total,'tenderedAmount',v_total));
  END IF;
  v_payload:=(p_payload-'ketulIntakeLines')||jsonb_build_object('payments',v_payments,
    'ketulIntakeLines',v_lines,'ketulOffsetTotal',v_total);
  v_result:=public.save_pos_sale_draft_with_pricelist(v_payload);
  SELECT sale.* INTO STRICT v_sale FROM public.sales_headers sale
  WHERE sale.company_id=v_company AND sale.id=(v_result->>'salesId')::uuid FOR UPDATE;
  IF v_sale.sales_origin<>'POS' OR v_sale.sales_process_mode<>'RETAIL_CONFIRM_INVOICE'
    OR v_sale.document_status<>'DRAFT' THEN RAISE EXCEPTION 'DIRECT_RETAIL_POS_DRAFT_REQUIRED'; END IF;
  IF v_total>v_sale.grand_total_after_rounding THEN
    RAISE EXCEPTION 'KETUL_OFFSET_EXCEEDS_SALE_TOTAL';
  END IF;
  SELECT * INTO v_intake FROM public.pos_ketul_customer_intakes intake
  WHERE intake.company_id=v_company AND intake.sales_id=v_sale.id FOR UPDATE;
  v_intake_found:=FOUND;
  IF v_intake_found AND v_intake.status<>'DRAFT' THEN
    RAISE EXCEPTION 'POSTED_KETUL_INTAKE_IMMUTABLE';
  END IF;
  IF v_total=0 THEN
    IF v_intake_found THEN
      DELETE FROM public.pos_ketul_customer_intakes
      WHERE company_id=v_company AND id=v_intake.id;
    END IF;
    RETURN v_result||jsonb_build_object('ketulOffsetTotal',0,'ketulLineCount',0);
  END IF;
  v_hash:=encode(extensions.digest(convert_to((SELECT string_agg(
    input.product_id::text||':'||input.quantity_base::text||':'||input.unit_price::text,
    '|' ORDER BY input.product_id) FROM pg_temp.ketul_input input),'UTF8'),'sha256'),'hex');
  IF NOT v_intake_found THEN
    INSERT INTO public.pos_ketul_customer_intakes(company_id,sales_id,store_id,
      warehouse_id,cashier_session_id,customer_id,total_amount,payload_hash,
      created_by,updated_by)
    VALUES(v_company,v_sale.id,v_sale.store_id,v_sale.sales_warehouse_id,
      v_sale.session_id,v_sale.customer_id,v_total,v_hash,v_actor,v_actor)
    RETURNING * INTO v_intake;
    INSERT INTO public.pos_ketul_customer_intake_audit(company_id,intake_id,
      action,actor_id,after_state)
    VALUES(v_company,v_intake.id,'CREATE',v_actor,to_jsonb(v_intake));
  ELSE
    v_before:=to_jsonb(v_intake);
    DELETE FROM public.pos_ketul_customer_intake_lines
    WHERE company_id=v_company AND intake_id=v_intake.id;
    UPDATE public.pos_ketul_customer_intakes SET total_amount=v_total,
      payload_hash=v_hash,customer_id=v_sale.customer_id,
      master_version=master_version+1,updated_by=v_actor
    WHERE company_id=v_company AND id=v_intake.id RETURNING * INTO v_intake;
    INSERT INTO public.pos_ketul_customer_intake_audit(company_id,intake_id,
      action,actor_id,before_state,after_state)
    VALUES(v_company,v_intake.id,'UPDATE',v_actor,v_before,to_jsonb(v_intake));
  END IF;
  FOR v_row IN SELECT input.*,product.sku,product.name,product.uom_id,uom.name uom_name
    FROM pg_temp.ketul_input input JOIN public.products product
      ON product.company_id=v_company AND product.id=input.product_id
    JOIN public.uoms uom ON uom.company_id=product.company_id AND uom.id=product.uom_id
    ORDER BY product.sku,product.id
  LOOP
    v_line_no:=v_line_no+1;
    INSERT INTO public.pos_ketul_customer_intake_lines(company_id,intake_id,
      line_no,product_id,base_uom_id,quantity_base,unit_price,line_total,
      product_sku_snapshot,product_name_snapshot,base_uom_name_snapshot)
    VALUES(v_company,v_intake.id,v_line_no,v_row.product_id,v_row.uom_id,
      v_row.quantity_base,v_row.unit_price,round(v_row.quantity_base*v_row.unit_price,4),
      v_row.sku,v_row.name,v_row.uom_name);
  END LOOP;
  RETURN v_result||jsonb_build_object('ketulIntakeId',v_intake.id,
    'ketulOffsetTotal',v_total,'ketulLineCount',v_line_no);
END
$$;

CREATE FUNCTION private.post_pos_ketul_intake(
  p_company_id uuid,p_sales_id uuid,p_posting_key uuid,p_actor_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
  v_intake public.pos_ketul_customer_intakes%rowtype;v_sale public.sales_headers%rowtype;
  v_line public.pos_ketul_customer_intake_lines%rowtype;v_stock numeric(24,6);
  v_batch uuid;v_movement uuid;v_event uuid;v_journal uuid;v_period uuid;
  v_category uuid;v_inventory uuid;v_payable uuid;v_now timestamptz:=clock_timestamp();
  v_receipt jsonb;
BEGIN
  SELECT * INTO STRICT v_intake FROM public.pos_ketul_customer_intakes intake
  WHERE intake.company_id=p_company_id AND intake.sales_id=p_sales_id FOR UPDATE;
  IF v_intake.status='POSTED' THEN
    IF v_intake.posting_idempotency_key=p_posting_key THEN
      RETURN jsonb_build_object('ketulIntakeId',v_intake.id,'status','POSTED',
        'ketulOffsetTotal',v_intake.total_amount,'idempotentReplay',true);
    END IF;
    RAISE EXCEPTION 'KETUL_POST_IDEMPOTENCY_CONFLICT';
  END IF;
  SELECT * INTO STRICT v_sale FROM public.sales_headers sale
  WHERE sale.company_id=p_company_id AND sale.id=p_sales_id
    AND sale.document_status='POSTED' AND sale.sales_origin='POS'
    AND sale.sales_process_mode='RETAIL_CONFIRM_INVOICE' FOR SHARE;
  IF (SELECT count(*) FROM public.sales_payments payment
      WHERE payment.company_id=p_company_id AND payment.sales_id=p_sales_id
        AND payment.payment_method_type_snapshot='KETUL_OFFSET'
        AND payment.amount=v_intake.total_amount)<>1 THEN
    RAISE EXCEPTION 'KETUL_OFFSET_PAYMENT_CONTRACT_INVALID';
  END IF;
  SELECT category.id INTO STRICT v_category FROM public.transaction_categories category
  WHERE category.company_id=p_company_id
    AND category.system_key='KETUL_CUSTOMER_INTAKE' AND category.is_active;

  FOR v_line IN SELECT * FROM public.pos_ketul_customer_intake_lines line
    WHERE line.company_id=p_company_id AND line.intake_id=v_intake.id
    ORDER BY line.line_no FOR UPDATE
  LOOP
    PERFORM pg_advisory_xact_lock(hashtextextended(p_company_id::text||':STOCK:'||
      v_line.product_id::text||':'||v_intake.warehouse_id::text,0));
    INSERT INTO public.product_stocks(product_id,warehouse_id,stock_qty,company_id)
    VALUES(v_line.product_id,v_intake.warehouse_id,v_line.quantity_base,p_company_id)
    ON CONFLICT(product_id,warehouse_id) DO UPDATE SET
      stock_qty=public.product_stocks.stock_qty+excluded.stock_qty,updated_at=v_now
    RETURNING stock_qty INTO v_stock;
    INSERT INTO public.product_batches(product_id,warehouse_id,purchase_detail_id,
      qty_purchased,qty_remaining,cogs_unit,company_id)
    VALUES(v_line.product_id,v_intake.warehouse_id,NULL,v_line.quantity_base,
      v_line.quantity_base,v_line.unit_price,p_company_id) RETURNING id INTO v_batch;
    v_movement:=gen_random_uuid();
    INSERT INTO public.stock_movements(id,product_id,warehouse_id,qty_change,
      movement_type,reference_table,reference_id,company_id,base_uom_id,
      base_uom_name_snapshot,balance_after_base_qty,actor_id,posted_at,
      movement_status,source_line_id,notes)
    VALUES(v_movement,v_line.product_id,v_intake.warehouse_id,v_line.quantity_base,
      'PURCHASE'::public.stock_movement_type,'pos_ketul_customer_intakes',v_intake.id,
      p_company_id,v_line.base_uom_id,v_line.base_uom_name_snapshot,v_stock,
      p_actor_id,v_now,'POSTED',v_line.id,'Penerimaan Ketul Customer via POS');
    UPDATE public.pos_ketul_customer_intake_lines SET product_batch_id=v_batch,
      stock_movement_id=v_movement WHERE company_id=p_company_id AND id=v_line.id;
  END LOOP;

  INSERT INTO public.financial_events(event_code,event_type,source_table,source_id,
    root_sales_id,event_date,event_version,idempotency_key,payment_method,amounts,
    status,error_message,created_by,company_id,store_id,system_event_key,
    transaction_category_id)
  VALUES('KETUL-'||replace(v_intake.id::text,'-',''),
    'PURCHASE_POSTED'::public.event_type,'pos_ketul_customer_intakes',v_intake.id,
    p_sales_id,v_now,1,'KETUL_CUSTOMER_INTAKE|'||p_company_id||'|'||p_posting_key,
    'Potongan Ketul',jsonb_build_object('inventoryDebit',v_intake.total_amount,
      'payableCredit',v_intake.total_amount,'saleId',p_sales_id,
      'ketulIntakeId',v_intake.id),'HOLD'::public.event_status,
    'KETUL_POSTING_IN_TRANSACTION',p_actor_id,p_company_id,v_intake.store_id,
    'KETUL_CUSTOMER_INTAKE',v_category) RETURNING id INTO v_event;
  SELECT private.resolve_financial_event_account(event,'INVENTORY_ASSET'),
    private.resolve_financial_event_account(event,'CUSTOMER_KETUL_PAYABLE')
  INTO v_inventory,v_payable FROM public.financial_events event
  WHERE event.company_id=p_company_id AND event.id=v_event;
  PERFORM private.ensure_company_accounting_periods(p_company_id,v_now::date,p_actor_id);
  SELECT period.id INTO v_period FROM public.accounting_periods period
  WHERE period.company_id=p_company_id AND v_now::date BETWEEN period.start_date AND period.end_date
    AND period.status IN('OPEN','REOPENED') ORDER BY period.start_date DESC LIMIT 1 FOR SHARE;
  IF v_period IS NULL THEN RAISE EXCEPTION 'POSTABLE_ACCOUNTING_PERIOD_NOT_FOUND'; END IF;
  INSERT INTO public.finance_journals(company_id,journal_no,journal_type,
    accounting_period_id,accounting_date,original_event_date,source_type,source_id,
    source_version,financial_event_id,idempotency_key,system_event_key,
    transaction_category_id,transaction_rule_version,store_id,warehouse_id,
    description,status,created_by,posted_by,posted_at)
  VALUES(p_company_id,'KETUL-'||replace(v_intake.id::text,'-',''),'AUTOMATIC',
    v_period,v_now::date,v_now::date,'pos_ketul_customer_intakes',v_intake.id,1,
    v_event,'KETUL_EVENT|'||p_company_id||'|'||v_intake.id,
    'KETUL_CUSTOMER_INTAKE',v_category,20261031110000,v_intake.store_id,
    v_intake.warehouse_id,'Penerimaan Ketul Customer via POS','DRAFT',p_actor_id,
    NULL,NULL) RETURNING id INTO v_journal;
  INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,account_id,
    debit,credit,store_id,warehouse_id,customer_id,description)
  VALUES
    (p_company_id,v_journal,1,v_inventory,v_intake.total_amount,0,
      v_intake.store_id,v_intake.warehouse_id,v_intake.customer_id,'PERSEDIAAN KETUL'),
    (p_company_id,v_journal,2,v_payable,0,v_intake.total_amount,
      v_intake.store_id,v_intake.warehouse_id,v_intake.customer_id,'HUTANG KETUL CUSTOMER');
  UPDATE public.finance_journals SET status='POSTED',posted_by=p_actor_id,
    posted_at=v_now WHERE company_id=p_company_id AND id=v_journal;
  UPDATE public.financial_events SET status='POSTED'::public.event_status,
    processed_at=v_now,error_message=NULL,transaction_rule_version=20261031110000
  WHERE company_id=p_company_id AND id=v_event;
  UPDATE public.pos_ketul_customer_intakes SET status='POSTED',
    posting_idempotency_key=p_posting_key,financial_event_id=v_event,
    finance_journal_id=v_journal,posted_by=p_actor_id,posted_at=v_now,
    master_version=master_version+1,updated_by=p_actor_id
  WHERE company_id=p_company_id AND id=v_intake.id RETURNING * INTO v_intake;
  INSERT INTO public.pos_ketul_customer_intake_audit(company_id,intake_id,
    action,actor_id,after_state)
  VALUES(p_company_id,v_intake.id,'POST',p_actor_id,to_jsonb(v_intake));
  SELECT COALESCE(sale.receipt_snapshot,'{}'::jsonb)||jsonb_build_object(
    'ketulIntake',jsonb_build_object('intakeId',v_intake.id,
      'offsetTotal',v_intake.total_amount,'lines',(SELECT jsonb_agg(jsonb_build_object(
        'productId',line.product_id,'sku',line.product_sku_snapshot,
        'productName',line.product_name_snapshot,'uomName',line.base_uom_name_snapshot,
        'quantity',line.quantity_base,'unitPrice',line.unit_price,
        'lineTotal',line.line_total) ORDER BY line.line_no)
        FROM public.pos_ketul_customer_intake_lines line
        WHERE line.company_id=p_company_id AND line.intake_id=v_intake.id)),
    'ketulOffsetTotal',v_intake.total_amount,
    'externalPaymentTotal',sale.paid_amount-v_intake.total_amount)
  INTO v_receipt FROM public.sales_headers sale
  WHERE sale.company_id=p_company_id AND sale.id=p_sales_id;
  UPDATE public.sales_headers SET receipt_snapshot=v_receipt
  WHERE company_id=p_company_id AND id=p_sales_id;
  RETURN jsonb_build_object('ketulIntakeId',v_intake.id,'status','POSTED',
    'ketulOffsetTotal',v_intake.total_amount,'financialEventId',v_event,
    'financeJournalId',v_journal,'idempotentReplay',false);
END
$$;

CREATE FUNCTION public.post_pos_sale_with_ketul(p_sales_id uuid,
  p_master_version bigint,p_posting_idempotency_key uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
  v_intake public.pos_ketul_customer_intakes%rowtype;v_result jsonb;v_ketul jsonb;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  SELECT * INTO v_intake FROM public.pos_ketul_customer_intakes intake
  WHERE intake.company_id=v_company AND intake.sales_id=p_sales_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN public.post_pos_sale_with_pricelist(p_sales_id,p_master_version,
      p_posting_idempotency_key);
  END IF;
  IF v_intake.status='POSTED' THEN
    IF v_intake.posting_idempotency_key=p_posting_idempotency_key THEN
      SELECT sale.receipt_snapshot INTO v_result FROM public.sales_headers sale
      WHERE sale.company_id=v_company AND sale.id=p_sales_id;
      RETURN jsonb_build_object('salesId',p_sales_id,'documentStatus','POSTED',
        'masterVersion',(SELECT master_version FROM public.sales_headers
          WHERE company_id=v_company AND id=p_sales_id),
        'ketulOffsetTotal',v_intake.total_amount,'receipt',v_result,
        'idempotentReplay',true);
    END IF;
    RAISE EXCEPTION 'KETUL_POST_IDEMPOTENCY_CONFLICT';
  END IF;
  PERFORM set_config('kgs.ketul_post_context',p_sales_id::text,true);
  v_result:=public.post_pos_sale_with_pricelist(p_sales_id,p_master_version,
    p_posting_idempotency_key);
  IF v_result->>'documentStatus'<>'POSTED' THEN RETURN v_result; END IF;
  v_ketul:=private.post_pos_ketul_intake(v_company,p_sales_id,
    p_posting_idempotency_key,v_actor);
  RETURN v_result||v_ketul||jsonb_build_object('receipt',(
    SELECT sale.receipt_snapshot FROM public.sales_headers sale
    WHERE sale.company_id=v_company AND sale.id=p_sales_id));
END
$$;

REVOKE ALL ON FUNCTION private.trg_pos_ketul_intake_immutable(),
  private.post_pos_ketul_intake(uuid,uuid,uuid,uuid)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.trg_pos_ketul_intake_immutable(),
  private.post_pos_ketul_intake(uuid,uuid,uuid,uuid) TO service_role;
REVOKE ALL ON FUNCTION public.save_pos_sale_draft_with_ketul(jsonb),
  public.post_pos_sale_with_ketul(uuid,bigint,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.save_pos_sale_draft_with_ketul(jsonb),
  public.post_pos_sale_with_ketul(uuid,bigint,uuid) TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20261031110000','pos_ketul_customer_intake_offset',
  'KGFF direct Retail POS Ketul customer intake with server-derived hidden offset, atomic Stock/FIFO, dedicated payable and Finance journal; preserves Backoffice, Tempo, Offline and existing Return');

COMMIT;
