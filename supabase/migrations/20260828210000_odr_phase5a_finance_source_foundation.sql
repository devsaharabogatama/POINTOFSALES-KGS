-- ODR-5A: additive Finance source foundation for Dispatch and Payment verification.
-- Zero backfill. No Financial Event, Journal, Stock, FIFO or Payment mutation.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260828140000')
    OR NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260828200000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: ODR-3C and ODR-4E required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260828210000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260828210000';
  END IF;
  IF to_regclass('public.sales_dispatch_financial_effects') IS NOT NULL
    OR to_regclass('public.sales_payment_verification_requests') IS NOT NULL
    OR to_regclass('public.sales_dispatch_financial_effect_audit') IS NOT NULL
    OR to_regclass('public.sales_payment_verification_audit') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: ODR-5A relation exists';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
    WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
END
$guard$;

INSERT INTO public.account_functions(function_key,function_name,
  compatible_account_types,default_normal_balance,allow_reconciliation)
VALUES('CUSTOMER_ADVANCE_LIABILITY','Uang Muka Customer',ARRAY['LIABILITY'],
  'CREDIT',TRUE)
ON CONFLICT(function_key) DO NOTHING;

DO $account_contract$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM public.account_functions account_function
    WHERE account_function.function_key='CUSTOMER_ADVANCE_LIABILITY'
      AND account_function.compatible_account_types=ARRAY['LIABILITY']::TEXT[]
      AND account_function.default_normal_balance='CREDIT'
      AND account_function.allow_reconciliation
      AND account_function.is_active) THEN
    RAISE EXCEPTION 'CUSTOMER_ADVANCE_ACCOUNT_FUNCTION_CONFLICT';
  END IF;
END
$account_contract$;

INSERT INTO public.system_events(system_key,event_group,event_name,
  required_account_functions,conditional_account_functions)
VALUES
  ('SALE_DISPATCHED','SALES','Penjualan Dikirim',
    ARRAY['SALES_REVENUE','INVENTORY_ASSET','COGS'],
    ARRAY['CUSTOMER_RECEIVABLE','PAYMENT_CLEARING','OUTPUT_TAX',
      'DELIVERY_FEE_REVENUE','PAYMENT_SURCHARGE_INCOME',
      'ROUNDING_GAIN','ROUNDING_LOSS']),
  ('SALE_PAYMENT_VERIFIED','SALES','Pembayaran Penjualan Diverifikasi',
    ARRAY[]::TEXT[],ARRAY['CASH_DRAWER','BANK','BANK_RECEIPT',
      'PAYMENT_CLEARING','CUSTOMER_RECEIVABLE','CUSTOMER_ADVANCE_LIABILITY'])
ON CONFLICT(system_key) DO NOTHING;

DO $event_contract$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM public.system_events system_event
      WHERE system_event.system_key='SALE_DISPATCHED'
        AND system_event.event_group='SALES'
        AND system_event.required_account_functions=
          ARRAY['SALES_REVENUE','INVENTORY_ASSET','COGS']::TEXT[]
        AND system_event.conditional_account_functions=
          ARRAY['CUSTOMER_RECEIVABLE','PAYMENT_CLEARING','OUTPUT_TAX',
            'DELIVERY_FEE_REVENUE','PAYMENT_SURCHARGE_INCOME',
            'ROUNDING_GAIN','ROUNDING_LOSS']::TEXT[]
        AND system_event.is_active)
    OR NOT EXISTS(SELECT 1 FROM public.system_events system_event
      WHERE system_event.system_key='SALE_PAYMENT_VERIFIED'
        AND system_event.event_group='SALES'
        AND system_event.required_account_functions=ARRAY[]::TEXT[]
        AND system_event.conditional_account_functions=
          ARRAY['CASH_DRAWER','BANK','BANK_RECEIPT','PAYMENT_CLEARING',
            'CUSTOMER_RECEIVABLE','CUSTOMER_ADVANCE_LIABILITY']::TEXT[]
        AND system_event.is_active) THEN
    RAISE EXCEPTION 'ODR5_SYSTEM_EVENT_CONFLICT';
  END IF;
END
$event_contract$;

CREATE TABLE public.sales_dispatch_financial_effects(
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id UUID NOT NULL,
  sales_id UUID NOT NULL,
  delivery_document_id UUID NOT NULL,
  reservation_id UUID NOT NULL,
  dispatch_idempotency_key UUID NOT NULL,
  dispatch_version BIGINT NOT NULL,
  effective_date DATE NOT NULL,
  dispatched_base_qty NUMERIC(24,6) NOT NULL,
  commercial_amount NUMERIC(24,4) NOT NULL,
  tax_amount NUMERIC(24,4) NOT NULL DEFAULT 0,
  delivery_fee_amount NUMERIC(24,4) NOT NULL DEFAULT 0,
  payment_surcharge_amount NUMERIC(24,4) NOT NULL DEFAULT 0,
  rounding_adjustment NUMERIC(24,4) NOT NULL DEFAULT 0,
  receivable_amount NUMERIC(24,4) NOT NULL DEFAULT 0,
  clearing_amount NUMERIC(24,4) NOT NULL DEFAULT 0,
  fifo_cost_total NUMERIC(24,4) NOT NULL,
  source_snapshot JSONB NOT NULL,
  financial_event_id UUID,
  created_by UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT sales_dispatch_financial_effects_company_id_id_unique
    UNIQUE(company_id,id),
  CONSTRAINT sales_dispatch_financial_effects_operation_unique UNIQUE(
    company_id,delivery_document_id,dispatch_idempotency_key),
  CONSTRAINT sales_dispatch_financial_effects_event_unique
    UNIQUE(company_id,financial_event_id),
  CONSTRAINT sales_dispatch_financial_effects_quantity_check CHECK(
    dispatch_version>0 AND dispatched_base_qty>0),
  CONSTRAINT sales_dispatch_financial_effects_amount_check CHECK(
    commercial_amount>=0 AND tax_amount>=0 AND delivery_fee_amount>=0
    AND payment_surcharge_amount>=0 AND receivable_amount>=0
    AND clearing_amount>=0 AND fifo_cost_total>=0),
  CONSTRAINT sales_dispatch_financial_effects_snapshot_check CHECK(
    jsonb_typeof(source_snapshot)='object'),
  CONSTRAINT fk_sales_dispatch_effect_company FOREIGN KEY(company_id)
    REFERENCES public.companies(id) ON DELETE RESTRICT,
  CONSTRAINT fk_sales_dispatch_effect_sale FOREIGN KEY(company_id,sales_id)
    REFERENCES public.sales_headers(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT fk_sales_dispatch_effect_delivery FOREIGN KEY(
    company_id,delivery_document_id)
    REFERENCES public.sales_delivery_documents(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT fk_sales_dispatch_effect_reservation FOREIGN KEY(
    company_id,reservation_id)
    REFERENCES public.sales_stock_reservations(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT fk_sales_dispatch_effect_event FOREIGN KEY(company_id,financial_event_id)
    REFERENCES public.financial_events(company_id,id) ON DELETE RESTRICT
);

CREATE INDEX idx_sales_dispatch_financial_effect_sale
  ON public.sales_dispatch_financial_effects(company_id,sales_id,created_at);

CREATE TABLE public.sales_payment_verification_requests(
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id UUID NOT NULL,
  sales_id UUID NOT NULL,
  client_payment_key UUID NOT NULL,
  payment_method_id UUID NOT NULL,
  amount NUMERIC(24,4) NOT NULL,
  proof_url TEXT,
  status TEXT NOT NULL DEFAULT 'PENDING',
  receipt_timing TEXT,
  settlement_target TEXT,
  payment_method_code_snapshot TEXT NOT NULL,
  payment_method_name_snapshot TEXT NOT NULL,
  payment_method_type_snapshot TEXT NOT NULL,
  settlement_route_snapshot TEXT NOT NULL,
  settlement_account_function_snapshot TEXT,
  intent_snapshot JSONB NOT NULL,
  financial_event_id UUID,
  requested_by UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  requested_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  reviewed_by UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
  reviewed_at TIMESTAMPTZ,
  review_note TEXT,
  master_version BIGINT NOT NULL DEFAULT 1,
  created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT sales_payment_verification_company_id_id_unique
    UNIQUE(company_id,id),
  CONSTRAINT sales_payment_verification_intent_unique
    UNIQUE(company_id,sales_id,client_payment_key),
  CONSTRAINT sales_payment_verification_event_unique
    UNIQUE(company_id,financial_event_id),
  CONSTRAINT sales_payment_verification_status_check CHECK(
    status IN('PENDING','VERIFIED','REJECTED','CANCELED')),
  CONSTRAINT sales_payment_verification_timing_check CHECK(
    receipt_timing IS NULL OR receipt_timing IN('PRE_DISPATCH','POST_DISPATCH')),
  CONSTRAINT sales_payment_verification_target_check CHECK(
    settlement_target IS NULL OR settlement_target IN(
      'CUSTOMER_ADVANCE','PAYMENT_CLEARING','CUSTOMER_RECEIVABLE')),
  CONSTRAINT sales_payment_verification_amount_check CHECK(amount>0),
  CONSTRAINT sales_payment_verification_version_check CHECK(master_version>0),
  CONSTRAINT sales_payment_verification_identity_check CHECK(
    btrim(payment_method_code_snapshot)<>''
    AND btrim(payment_method_name_snapshot)<>''
    AND btrim(payment_method_type_snapshot)<>''
    AND btrim(settlement_route_snapshot)<>''
    AND jsonb_typeof(intent_snapshot)='object'),
  CONSTRAINT sales_payment_verification_proof_check CHECK(
    proof_url IS NULL OR proof_url~*'^https://'),
  CONSTRAINT sales_payment_verification_review_check CHECK(
    (status='PENDING' AND reviewed_by IS NULL AND reviewed_at IS NULL
      AND receipt_timing IS NULL AND settlement_target IS NULL
      AND financial_event_id IS NULL)
    OR (status IN('VERIFIED','REJECTED','CANCELED')
      AND reviewed_by IS NOT NULL AND reviewed_at IS NOT NULL)
    ),
  CONSTRAINT sales_payment_verification_verified_check CHECK(
    status<>'VERIFIED' OR (receipt_timing IS NOT NULL
      AND settlement_target IS NOT NULL
      AND settlement_account_function_snapshot IS NOT NULL
      AND financial_event_id IS NOT NULL)),
  CONSTRAINT fk_sales_payment_verification_company FOREIGN KEY(company_id)
    REFERENCES public.companies(id) ON DELETE RESTRICT,
  CONSTRAINT fk_sales_payment_verification_sale FOREIGN KEY(company_id,sales_id)
    REFERENCES public.sales_headers(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT fk_sales_payment_verification_method FOREIGN KEY(
    company_id,payment_method_id)
    REFERENCES public.payment_methods(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT fk_sales_payment_verification_event FOREIGN KEY(
    company_id,financial_event_id)
    REFERENCES public.financial_events(company_id,id) ON DELETE RESTRICT
);

CREATE INDEX idx_sales_payment_verification_workspace
  ON public.sales_payment_verification_requests(
    company_id,status,requested_at,id);

CREATE TABLE public.sales_dispatch_financial_effect_audit(
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id UUID NOT NULL,
  dispatch_financial_effect_id UUID NOT NULL,
  action TEXT NOT NULL,
  actor_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  idempotency_key UUID NOT NULL,
  state JSONB NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT sales_dispatch_financial_effect_audit_action_check
    CHECK(action IN('CAPTURE','EVENT_CREATED','POSTED','ERROR')),
  CONSTRAINT sales_dispatch_financial_effect_audit_operation_unique UNIQUE(
    company_id,dispatch_financial_effect_id,action,idempotency_key),
  CONSTRAINT sales_dispatch_financial_effect_audit_state_check
    CHECK(jsonb_typeof(state)='object'),
  CONSTRAINT fk_sales_dispatch_financial_effect_audit_parent FOREIGN KEY(
    company_id,dispatch_financial_effect_id)
    REFERENCES public.sales_dispatch_financial_effects(company_id,id)
    ON DELETE RESTRICT
);

CREATE TABLE public.sales_payment_verification_audit(
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id UUID NOT NULL,
  verification_request_id UUID NOT NULL,
  action TEXT NOT NULL,
  actor_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  idempotency_key UUID NOT NULL,
  before_state JSONB,
  after_state JSONB NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT sales_payment_verification_audit_action_check CHECK(
    action IN('CREATE','VERIFY','REJECT','CANCEL','POST','ERROR')),
  CONSTRAINT sales_payment_verification_audit_operation_unique UNIQUE(
    company_id,verification_request_id,action,idempotency_key),
  CONSTRAINT sales_payment_verification_audit_state_check CHECK(
    (before_state IS NULL OR jsonb_typeof(before_state)='object')
    AND jsonb_typeof(after_state)='object'),
  CONSTRAINT fk_sales_payment_verification_audit_parent FOREIGN KEY(
    company_id,verification_request_id)
    REFERENCES public.sales_payment_verification_requests(company_id,id)
    ON DELETE RESTRICT
);

CREATE FUNCTION private.trg_odr5_guard_dispatch_financial_effect()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path=public,pg_temp AS $$
DECLARE v_sales UUID;v_reservation UUID;
BEGIN
  IF TG_OP<>'INSERT' THEN
    RAISE EXCEPTION 'DISPATCH_FINANCIAL_EFFECT_IMMUTABLE';
  END IF;
  SELECT delivery.sales_id,delivery.reservation_id INTO v_sales,v_reservation
  FROM public.sales_delivery_documents delivery
  WHERE delivery.company_id=NEW.company_id
    AND delivery.id=NEW.delivery_document_id;
  IF v_sales IS DISTINCT FROM NEW.sales_id
    OR v_reservation IS DISTINCT FROM NEW.reservation_id THEN
    RAISE EXCEPTION 'DISPATCH_FINANCIAL_EFFECT_SOURCE_MISMATCH';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.sales_dispatch_allocations allocation
    WHERE allocation.company_id=NEW.company_id
      AND allocation.delivery_document_id=NEW.delivery_document_id
      AND allocation.reservation_id=NEW.reservation_id
      AND allocation.dispatch_idempotency_key=NEW.dispatch_idempotency_key) THEN
    RAISE EXCEPTION 'DISPATCH_OPERATION_NOT_FOUND';
  END IF;
  RETURN NEW;
END
$$;

CREATE TRIGGER trg_odr5_guard_dispatch_financial_effect
BEFORE INSERT OR UPDATE OR DELETE ON public.sales_dispatch_financial_effects
FOR EACH ROW EXECUTE FUNCTION private.trg_odr5_guard_dispatch_financial_effect();

CREATE FUNCTION private.trg_odr5_guard_payment_verification()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path=public,pg_temp AS $$
BEGIN
  IF TG_OP='DELETE' THEN RAISE EXCEPTION 'PAYMENT_VERIFICATION_IMMUTABLE'; END IF;
  IF TG_OP='UPDATE' AND COALESCE(current_setting(
    'kgs.odr5_payment_verification_mutation',TRUE),'')<>'1' THEN
    RAISE EXCEPTION 'PAYMENT_VERIFICATION_GUARDED_MUTATION_REQUIRED';
  END IF;
  IF TG_OP='UPDATE' AND (NEW.company_id,NEW.sales_id,NEW.client_payment_key,
    NEW.payment_method_id,NEW.amount,NEW.intent_snapshot) IS DISTINCT FROM
    (OLD.company_id,OLD.sales_id,OLD.client_payment_key,OLD.payment_method_id,
      OLD.amount,OLD.intent_snapshot) THEN
    RAISE EXCEPTION 'PAYMENT_VERIFICATION_SOURCE_IMMUTABLE';
  END IF;
  RETURN NEW;
END
$$;

CREATE TRIGGER trg_odr5_guard_payment_verification
BEFORE UPDATE OR DELETE ON public.sales_payment_verification_requests
FOR EACH ROW EXECUTE FUNCTION private.trg_odr5_guard_payment_verification();

CREATE FUNCTION private.trg_odr5_guard_finance_source_audit()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path=public,pg_temp AS $$
BEGIN RAISE EXCEPTION 'ODR5_FINANCE_SOURCE_AUDIT_IMMUTABLE'; END
$$;

CREATE TRIGGER trg_odr5_guard_dispatch_effect_audit
BEFORE UPDATE OR DELETE ON public.sales_dispatch_financial_effect_audit
FOR EACH ROW EXECUTE FUNCTION private.trg_odr5_guard_finance_source_audit();
CREATE TRIGGER trg_odr5_guard_payment_verification_audit
BEFORE UPDATE OR DELETE ON public.sales_payment_verification_audit
FOR EACH ROW EXECUTE FUNCTION private.trg_odr5_guard_finance_source_audit();

INSERT INTO public.access_permission_catalog(permission_key,module_key,
  permission_label,description,view_roles,operator_roles,approver_roles,
  supported_capabilities,required_any_features,is_customizable,
  enforcement_status,catalog_version)
VALUES('finance.sales_payment_verification','FINANCE',
  'Verifikasi Pembayaran Penjualan','Review dan verifikasi payment intent POS',
  ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE','ACCOUNTING'],
  ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE'],
  ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE'],
  ARRAY['VIEW','REVIEW','APPROVE','POST'],'{}',TRUE,'SHADOW',1)
ON CONFLICT(permission_key) DO NOTHING;

ALTER TABLE public.sales_dispatch_financial_effects ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sales_payment_verification_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sales_dispatch_financial_effect_audit ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sales_payment_verification_audit ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.sales_dispatch_financial_effects,
  public.sales_payment_verification_requests,
  public.sales_dispatch_financial_effect_audit,
  public.sales_payment_verification_audit FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.sales_dispatch_financial_effects,
  public.sales_payment_verification_requests,
  public.sales_dispatch_financial_effect_audit,
  public.sales_payment_verification_audit TO service_role;

REVOKE ALL ON FUNCTION
  private.trg_odr5_guard_dispatch_financial_effect(),
  private.trg_odr5_guard_payment_verification(),
  private.trg_odr5_guard_finance_source_audit()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.trg_odr5_guard_dispatch_financial_effect(),
  private.trg_odr5_guard_payment_verification(),
  private.trg_odr5_guard_finance_source_audit()
TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260828210000','odr_phase5a_finance_source_foundation',
  'Additive zero-backfill Dispatch financial source and Sales payment verification foundation, dedicated event catalog, Customer Advance liability function, append-only audit, RLS and browser closure; no event, journal, stock, FIFO or payment mutation');

NOTIFY pgrst,'reload schema';
COMMIT;
