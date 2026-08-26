-- Company Finance period policy and POS TEMPO resume/date correction.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(
    SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260826100000'
  ) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: POS TEMPO backdated runtime';
  END IF;
  IF EXISTS(
    SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260827090000'
  ) THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260827090000';
  END IF;
END
$guard$;

CREATE TABLE public.finance_company_policies(
  company_id UUID PRIMARY KEY REFERENCES public.companies(id) ON DELETE RESTRICT,
  period_creation_mode TEXT NOT NULL DEFAULT 'MANUAL',
  posting_mode TEXT NOT NULL DEFAULT 'CONTROLLED',
  master_version BIGINT NOT NULL DEFAULT 1,
  created_by UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
  updated_by UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT finance_company_policies_period_mode_check
    CHECK(period_creation_mode IN('MANUAL','AUTOMATIC')),
  CONSTRAINT finance_company_policies_posting_mode_check
    CHECK(posting_mode IN('CONTROLLED','AUTOMATIC')),
  CONSTRAINT finance_company_policies_version_check CHECK(master_version>0)
);

CREATE TABLE public.finance_company_policy_audit(
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id UUID NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
  action TEXT NOT NULL CHECK(action IN('CREATE','UPDATE','AUTO_PERIOD_CREATE')),
  actor_id UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
  before_state JSONB,
  after_state JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

INSERT INTO public.finance_company_policies(company_id)
SELECT company.id FROM public.companies company
ON CONFLICT(company_id) DO NOTHING;

ALTER TABLE public.finance_company_policies ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.finance_company_policy_audit ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.finance_company_policies FROM PUBLIC,anon,authenticated;
REVOKE ALL ON public.finance_company_policy_audit FROM PUBLIC,anon,authenticated;

CREATE FUNCTION private.trg_finance_company_policy_audit_immutable()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
  RAISE EXCEPTION 'FINANCE_COMPANY_POLICY_AUDIT_IMMUTABLE';
END
$$;
CREATE TRIGGER finance_company_policy_audit_immutable
BEFORE UPDATE OR DELETE ON public.finance_company_policy_audit
FOR EACH ROW EXECUTE FUNCTION private.trg_finance_company_policy_audit_immutable();

CREATE FUNCTION private.ensure_company_accounting_periods(
  p_company_id UUID,p_reference_date DATE,p_actor UUID
) RETURNS INTEGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE
  v_month DATE;
  v_candidate DATE;
  v_created INTEGER:=0;
  v_period public.accounting_periods%ROWTYPE;
BEGIN
  IF p_company_id IS NULL OR p_reference_date IS NULL THEN
    RAISE EXCEPTION 'ACCOUNTING_PERIOD_CONTEXT_REQUIRED';
  END IF;
  IF NOT EXISTS(
    SELECT 1 FROM public.finance_company_policies policy
    WHERE policy.company_id=p_company_id
      AND policy.period_creation_mode='AUTOMATIC'
  ) THEN
    RETURN 0;
  END IF;
  PERFORM pg_advisory_xact_lock(
    hashtextextended('FINANCE_AUTO_PERIOD|'||p_company_id::TEXT,0)
  );
  v_month:=date_trunc('month',p_reference_date)::DATE;
  FOREACH v_candidate IN ARRAY ARRAY[
    v_month,(v_month+interval '1 month')::DATE
  ] LOOP
    INSERT INTO public.accounting_periods(
      company_id,period_year,period_month,start_date,end_date,status,
      created_by,updated_by
    ) VALUES(
      p_company_id,extract(year FROM v_candidate)::INTEGER,
      extract(month FROM v_candidate)::INTEGER,v_candidate,
      (v_candidate+interval '1 month'-interval '1 day')::DATE,
      'OPEN',p_actor,p_actor
    ) ON CONFLICT(company_id,period_year,period_month) DO NOTHING
    RETURNING * INTO v_period;
    IF FOUND THEN
      v_created:=v_created+1;
      INSERT INTO public.finance_company_policy_audit(
        company_id,action,actor_id,after_state
      ) VALUES(
        p_company_id,'AUTO_PERIOD_CREATE',p_actor,
        jsonb_build_object('accountingPeriodId',v_period.id,
          'periodStart',v_period.start_date,'periodEnd',v_period.end_date)
      );
    END IF;
  END LOOP;
  RETURN v_created;
END
$$;

REVOKE ALL ON FUNCTION private.ensure_company_accounting_periods(
  UUID,DATE,UUID
) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.ensure_company_accounting_periods(
  UUID,DATE,UUID
) TO service_role;

CREATE FUNCTION public.get_finance_company_policy()
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE
  v_company UUID:=public.private_active_company_id();
  v_actor UUID:=auth.uid();
  v_timezone TEXT;
  v_policy public.finance_company_policies%ROWTYPE;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
  PERFORM private.acp_require_permission_capability(
    v_company,'finance.journals_reports','VIEW'
  );
  INSERT INTO public.finance_company_policies(company_id,created_by,updated_by)
  VALUES(v_company,v_actor,v_actor) ON CONFLICT(company_id) DO NOTHING;
  SELECT company.timezone INTO v_timezone FROM public.companies company
  WHERE company.id=v_company AND company.status='ACTIVE';
  PERFORM private.ensure_company_accounting_periods(
    v_company,(clock_timestamp() AT TIME ZONE v_timezone)::DATE,v_actor
  );
  SELECT * INTO v_policy FROM public.finance_company_policies policy
  WHERE policy.company_id=v_company;
  RETURN jsonb_build_object(
    'periodCreationMode',v_policy.period_creation_mode,
    'postingMode',v_policy.posting_mode,
    'masterVersion',v_policy.master_version
  );
END
$$;

CREATE FUNCTION public.save_finance_company_policy(
  p_master_version BIGINT,p_period_creation_mode TEXT
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE
  v_company UUID:=public.private_active_company_id();
  v_actor UUID:=auth.uid();
  v_timezone TEXT;
  v_before JSONB;
  v_policy public.finance_company_policies%ROWTYPE;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
  PERFORM private.acp_require_permission_capability(
    v_company,'finance.journals_reports','CLOSE_PERIOD'
  );
  IF upper(COALESCE(p_period_creation_mode,'')) NOT IN('MANUAL','AUTOMATIC') THEN
    RAISE EXCEPTION 'PERIOD_CREATION_MODE_INVALID';
  END IF;
  INSERT INTO public.finance_company_policies(company_id,created_by,updated_by)
  VALUES(v_company,v_actor,v_actor) ON CONFLICT(company_id) DO NOTHING;
  SELECT policy.* INTO v_policy
  FROM public.finance_company_policies policy
  WHERE policy.company_id=v_company FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'FINANCE_COMPANY_POLICY_NOT_FOUND'; END IF;
  v_before:=to_jsonb(v_policy);
  IF p_master_version IS NULL OR p_master_version<>v_policy.master_version THEN
    RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
  END IF;
  UPDATE public.finance_company_policies SET
    period_creation_mode=upper(p_period_creation_mode),
    master_version=master_version+1,updated_by=v_actor,
    updated_at=clock_timestamp()
  WHERE company_id=v_company RETURNING * INTO v_policy;
  INSERT INTO public.finance_company_policy_audit(
    company_id,action,actor_id,before_state,after_state
  ) VALUES(v_company,'UPDATE',v_actor,v_before,to_jsonb(v_policy));
  SELECT company.timezone INTO v_timezone FROM public.companies company
  WHERE company.id=v_company;
  PERFORM private.ensure_company_accounting_periods(
    v_company,(clock_timestamp() AT TIME ZONE v_timezone)::DATE,v_actor
  );
  RETURN jsonb_build_object(
    'periodCreationMode',v_policy.period_creation_mode,
    'postingMode',v_policy.posting_mode,
    'masterVersion',v_policy.master_version
  );
END
$$;

REVOKE ALL ON FUNCTION public.get_finance_company_policy() FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.save_finance_company_policy(BIGINT,TEXT)
  FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_finance_company_policy() TO authenticated;
GRANT EXECUTE ON FUNCTION public.save_finance_company_policy(BIGINT,TEXT)
  TO authenticated;

CREATE OR REPLACE FUNCTION private.validate_pos_tempo_effective_dates(
  p_company_id UUID,p_transaction_at TIMESTAMPTZ,p_due_at TIMESTAMPTZ,
  p_fulfillment_mode TEXT,p_delivery_scheduled_at TIMESTAMPTZ
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE
  v_timezone TEXT;
  v_effective_date DATE;
  v_due_date DATE;
  v_delivery_date DATE;
  v_period_id UUID;
BEGIN
  SELECT company.timezone INTO v_timezone FROM public.companies company
  WHERE company.id=p_company_id AND company.status='ACTIVE';
  IF v_timezone IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_NOT_FOUND'; END IF;
  IF p_transaction_at IS NULL THEN RAISE EXCEPTION 'TEMPO_TRANSACTION_DATE_REQUIRED'; END IF;
  IF p_transaction_at>clock_timestamp()+interval '1 minute' THEN
    RAISE EXCEPTION 'TEMPO_TRANSACTION_DATE_FUTURE';
  END IF;
  v_effective_date:=(p_transaction_at AT TIME ZONE v_timezone)::DATE;
  v_due_date:=CASE WHEN p_due_at IS NULL THEN NULL
    ELSE (p_due_at AT TIME ZONE v_timezone)::DATE END;
  v_delivery_date:=CASE WHEN p_delivery_scheduled_at IS NULL THEN NULL
    ELSE (p_delivery_scheduled_at AT TIME ZONE v_timezone)::DATE END;
  IF v_due_date IS NULL OR v_due_date<v_effective_date THEN
    RAISE EXCEPTION 'TEMPO_DUE_DATE_BEFORE_TRANSACTION';
  END IF;
  IF p_fulfillment_mode='DELIVERY' AND v_delivery_date IS NOT NULL
     AND v_delivery_date<v_effective_date THEN
    RAISE EXCEPTION 'DELIVERY_DATE_BEFORE_TRANSACTION';
  END IF;
  PERFORM private.ensure_company_accounting_periods(
    p_company_id,v_effective_date,auth.uid()
  );
  SELECT period.id INTO v_period_id FROM public.accounting_periods period
  WHERE period.company_id=p_company_id
    AND v_effective_date BETWEEN period.start_date AND period.end_date
    AND period.status IN('OPEN','REOPENED')
  ORDER BY period.start_date DESC,period.id LIMIT 1 FOR SHARE;
  IF v_period_id IS NULL THEN RAISE EXCEPTION 'TEMPO_ACCOUNTING_PERIOD_NOT_OPEN'; END IF;
END
$$;

CREATE OR REPLACE FUNCTION public.save_pos_sale_draft_with_pricelist(
  p_payload JSONB
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE
  v_company UUID:=public.private_active_company_id();
  v_actor UUID:=auth.uid();
  v_result JSONB;
  v_sale public.sales_headers%ROWTYPE;
  v_requested_at TIMESTAMPTZ;
  v_intent TEXT:=upper(COALESCE(NULLIF(p_payload->>'transactionDateIntent',''),
    CASE WHEN p_payload ? 'transactionAt' THEN 'CASHIER_SELECTED' ELSE 'PRESERVE' END));
BEGIN
  IF jsonb_typeof(p_payload)<>'object' THEN RAISE EXCEPTION 'INVALID_SALE_PAYLOAD'; END IF;
  IF v_intent NOT IN('PRESERVE','CASHIER_SELECTED') THEN
    RAISE EXCEPTION 'TEMPO_TRANSACTION_DATE_INTENT_INVALID';
  END IF;
  PERFORM set_config('kgs.selected_pricelist_id',
    COALESCE(NULLIF(p_payload->>'selectedPricelistId',''),''),TRUE);
  v_result:=public.save_pos_sale_draft(p_payload);
  SELECT sale.* INTO v_sale FROM public.sales_headers sale
  WHERE sale.company_id=v_company AND sale.id=(v_result->>'salesId')::UUID
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'SALE_DRAFT_TRANSACTION_DATE_NOT_FOUND'; END IF;

  IF v_sale.document_status='DRAFT' AND v_sale.is_tempo THEN
    BEGIN
      v_requested_at:=CASE WHEN v_intent='CASHIER_SELECTED'
        THEN (p_payload->>'transactionAt')::TIMESTAMPTZ
        ELSE v_sale.transaction_date END;
    EXCEPTION WHEN invalid_datetime_format THEN
      RAISE EXCEPTION 'TEMPO_TRANSACTION_DATE_INVALID';
    END;
    IF v_requested_at IS NULL THEN RAISE EXCEPTION 'TEMPO_TRANSACTION_DATE_REQUIRED'; END IF;
    PERFORM private.validate_pos_tempo_effective_dates(
      v_company,v_requested_at,v_sale.due_date,v_sale.fulfillment_mode,
      v_sale.delivery_scheduled_at);
    IF v_intent='CASHIER_SELECTED' THEN
      UPDATE public.sales_headers sale SET
        transaction_date=v_requested_at,
        transaction_date_source='CASHIER_SELECTED',
        transaction_date_selected_by=v_actor,
        transaction_date_selected_at=clock_timestamp(),
        payload_snapshot=COALESCE(sale.payload_snapshot,'{}'::JSONB)
          ||jsonb_build_object('transactionAt',v_requested_at,
            'transactionDateIntent','CASHIER_SELECTED')
      WHERE sale.company_id=v_company AND sale.id=v_sale.id;
      v_sale.transaction_date:=v_requested_at;
      v_sale.transaction_date_source:='CASHIER_SELECTED';
    END IF;
  ELSIF v_sale.document_status='DRAFT'
        AND v_sale.transaction_date_source='CASHIER_SELECTED' THEN
    UPDATE public.sales_headers sale SET
      transaction_date=sale.created_at,transaction_date_source='SERVER_CREATED',
      transaction_date_selected_by=NULL,transaction_date_selected_at=NULL,
      payload_snapshot=COALESCE(sale.payload_snapshot,'{}'::JSONB)
        -'transactionAt'-'transactionDateIntent'
    WHERE sale.company_id=v_company AND sale.id=v_sale.id;
    v_sale.transaction_date:=v_sale.created_at;
    v_sale.transaction_date_source:='SERVER_CREATED';
  END IF;
  RETURN v_result||jsonb_build_object('transactionAt',v_sale.transaction_date,
    'transactionDateSource',v_sale.transaction_date_source);
END
$$;

CREATE OR REPLACE FUNCTION public.list_pos_sale_drafts(p_store_id UUID DEFAULT NULL)
RETURNS JSONB LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
  SELECT COALESCE(jsonb_agg(item ORDER BY updated_at DESC),'[]'::JSONB)
  FROM (
    SELECT sale.updated_at,jsonb_build_object(
      'salesId',sale.id,'draftNo',sale.draft_no,'draftLabel',sale.draft_label,
      'draftNotes',sale.draft_notes,'draftReason',sale.draft_reason,
      'customerId',sale.customer_id,'customerName',customer.name,
      'storeId',sale.store_id,'storeName',store.store_name,
      'createdBy',sale.created_by,'createdByName',creator.name,
      'createdAt',sale.created_at,'transactionAt',sale.transaction_date,
      'transactionDateSource',sale.transaction_date_source,
      'updatedAt',sale.updated_at,'masterVersion',sale.master_version,
      'grandTotal',sale.grand_total_after_rounding,
      'lineCount',(SELECT count(*) FROM public.sales_details detail
        WHERE detail.company_id=sale.company_id AND detail.sales_id=sale.id),
      'isStale',sale.created_at<clock_timestamp()-interval '7 days',
      'lockOwnerId',sale.edit_lock_owner_id,'lockOwnerName',lock_owner.name,
      'lockSessionId',sale.edit_lock_session_id,
      'lockHeartbeatAt',sale.edit_lock_heartbeat_at,
      'lockExpired',sale.edit_lock_heartbeat_at IS NOT NULL
        AND sale.edit_lock_heartbeat_at<clock_timestamp()-interval '5 minutes',
      'payloadSnapshot',sale.payload_snapshot) item
    FROM public.sales_headers sale
    JOIN public.customers customer ON customer.company_id=sale.company_id
      AND customer.id=sale.customer_id
    JOIN public.stores store ON store.company_id=sale.company_id
      AND store.id=sale.store_id
    JOIN public.profiles creator ON creator.id=sale.created_by
    LEFT JOIN public.profiles lock_owner ON lock_owner.id=sale.edit_lock_owner_id
    WHERE sale.company_id=public.private_active_company_id()
      AND sale.document_status='DRAFT'
      AND (p_store_id IS NULL OR sale.store_id=p_store_id)
      AND (public.private_user_has_any_company_role(sale.company_id,
          ARRAY['COMPANY_OWNER','COMPANY_ADMIN']::TEXT[])
        OR public.private_user_has_any_store_role(sale.store_id,
          ARRAY['CASHIER','STORE_MANAGER']::TEXT[]))
  ) visible;
$$;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260827090000','finance_period_policy_tempo_resume_fix',
  'Adds Company-controlled automatic monthly periods and preserves TEMPO transaction-date intent while comparing due/delivery dates in Company business timezone');

COMMIT;
