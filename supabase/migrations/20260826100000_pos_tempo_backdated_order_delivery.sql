-- POS TEMPO effective transaction date and past delivery schedule.
-- The selected business date is separate from immutable created/posted timestamps.
BEGIN;

DO $guard$
DECLARE
  v_definition TEXT;
BEGIN
  IF NOT EXISTS(
    SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260825110000'
  ) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: POS TEMPO transaction date';
  END IF;
  IF EXISTS(
    SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260826100000'
  ) THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260826100000';
  END IF;
  IF to_regclass('public.accounting_periods') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: accounting periods';
  END IF;
  SELECT pg_get_functiondef(
    'private.post_pos_sale_online_core(uuid,bigint,uuid)'::regprocedure
  ) INTO v_definition;
  IF v_definition IS NULL
     OR v_definition !~ 'IF v_is_tempo THEN'
     OR v_definition !~ 'SALE_POSTED' THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical POS online core';
  END IF;
END
$guard$;

ALTER TABLE public.sales_headers
  ADD COLUMN transaction_date_source TEXT NOT NULL DEFAULT 'SERVER_CREATED',
  ADD COLUMN transaction_date_selected_by UUID
    REFERENCES public.profiles(id) ON DELETE RESTRICT,
  ADD COLUMN transaction_date_selected_at TIMESTAMPTZ,
  ADD CONSTRAINT sales_headers_transaction_date_source_check CHECK(
    transaction_date_source IN('SERVER_CREATED','CASHIER_SELECTED')
  ),
  ADD CONSTRAINT sales_headers_transaction_date_selection_check CHECK(
    (transaction_date_source='SERVER_CREATED'
      AND transaction_date_selected_by IS NULL
      AND transaction_date_selected_at IS NULL)
    OR
    (transaction_date_source='CASHIER_SELECTED'
      AND is_tempo
      AND transaction_date_selected_by IS NOT NULL
      AND transaction_date_selected_at IS NOT NULL)
  );

CREATE FUNCTION private.validate_pos_tempo_effective_dates(
  p_company_id UUID,
  p_transaction_at TIMESTAMPTZ,
  p_due_at TIMESTAMPTZ,
  p_fulfillment_mode TEXT,
  p_delivery_scheduled_at TIMESTAMPTZ
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE
  v_timezone TEXT;
  v_effective_date DATE;
  v_period_id UUID;
BEGIN
  SELECT company.timezone INTO v_timezone
  FROM public.companies company
  WHERE company.id=p_company_id AND company.status='ACTIVE';
  IF v_timezone IS NULL THEN
    RAISE EXCEPTION 'ACTIVE_COMPANY_NOT_FOUND';
  END IF;
  IF p_transaction_at IS NULL THEN
    RAISE EXCEPTION 'TEMPO_TRANSACTION_DATE_REQUIRED';
  END IF;
  IF p_transaction_at>clock_timestamp()+interval '1 minute' THEN
    RAISE EXCEPTION 'TEMPO_TRANSACTION_DATE_FUTURE';
  END IF;
  IF p_due_at IS NULL OR p_due_at<p_transaction_at THEN
    RAISE EXCEPTION 'TEMPO_DUE_DATE_BEFORE_TRANSACTION';
  END IF;
  IF p_fulfillment_mode='DELIVERY'
     AND p_delivery_scheduled_at IS NOT NULL
     AND p_delivery_scheduled_at<p_transaction_at THEN
    RAISE EXCEPTION 'DELIVERY_DATE_BEFORE_TRANSACTION';
  END IF;

  v_effective_date:=(p_transaction_at AT TIME ZONE v_timezone)::DATE;
  SELECT period.id INTO v_period_id
  FROM public.accounting_periods period
  WHERE period.company_id=p_company_id
    AND v_effective_date BETWEEN period.start_date AND period.end_date
    AND period.status IN('OPEN','REOPENED')
  ORDER BY period.start_date DESC,period.id
  LIMIT 1
  FOR SHARE;
  IF v_period_id IS NULL THEN
    RAISE EXCEPTION 'TEMPO_ACCOUNTING_PERIOD_NOT_OPEN';
  END IF;
END
$$;

REVOKE ALL ON FUNCTION private.validate_pos_tempo_effective_dates(
  UUID,TIMESTAMPTZ,TIMESTAMPTZ,TEXT,TIMESTAMPTZ
) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.validate_pos_tempo_effective_dates(
  UUID,TIMESTAMPTZ,TIMESTAMPTZ,TEXT,TIMESTAMPTZ
) TO service_role;

CREATE OR REPLACE FUNCTION public.save_pos_sale_draft_with_pricelist(
  p_payload JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE
  v_company UUID:=public.private_active_company_id();
  v_actor UUID:=auth.uid();
  v_result JSONB;
  v_sale public.sales_headers%ROWTYPE;
  v_requested_at TIMESTAMPTZ;
  v_has_requested_at BOOLEAN:=p_payload ? 'transactionAt'
    AND NULLIF(btrim(COALESCE(p_payload->>'transactionAt','')),'') IS NOT NULL;
BEGIN
  IF jsonb_typeof(p_payload)<>'object' THEN
    RAISE EXCEPTION 'INVALID_SALE_PAYLOAD';
  END IF;
  PERFORM set_config(
    'kgs.selected_pricelist_id',
    COALESCE(NULLIF(p_payload->>'selectedPricelistId',''),''),
    TRUE
  );
  v_result:=public.save_pos_sale_draft(p_payload);

  SELECT sale.* INTO v_sale
  FROM public.sales_headers sale
  WHERE sale.company_id=v_company
    AND sale.id=(v_result->>'salesId')::UUID
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'SALE_DRAFT_TRANSACTION_DATE_NOT_FOUND';
  END IF;

  IF v_sale.document_status='DRAFT' AND v_sale.is_tempo THEN
    BEGIN
      v_requested_at:=CASE WHEN v_has_requested_at
        THEN (p_payload->>'transactionAt')::TIMESTAMPTZ
        ELSE v_sale.transaction_date END;
    EXCEPTION WHEN invalid_datetime_format THEN
      RAISE EXCEPTION 'TEMPO_TRANSACTION_DATE_INVALID';
    END;
    PERFORM private.validate_pos_tempo_effective_dates(
      v_company,v_requested_at,v_sale.due_date,v_sale.fulfillment_mode,
      v_sale.delivery_scheduled_at
    );
    IF v_has_requested_at THEN
      UPDATE public.sales_headers sale SET
        transaction_date=v_requested_at,
        transaction_date_source='CASHIER_SELECTED',
        transaction_date_selected_by=v_actor,
        transaction_date_selected_at=clock_timestamp(),
        payload_snapshot=COALESCE(sale.payload_snapshot,'{}'::JSONB)
          || jsonb_build_object('transactionAt',v_requested_at)
      WHERE sale.company_id=v_company AND sale.id=v_sale.id;
      v_sale.transaction_date:=v_requested_at;
      v_sale.transaction_date_source:='CASHIER_SELECTED';
    END IF;
  ELSIF v_sale.document_status='DRAFT'
        AND v_sale.transaction_date_source='CASHIER_SELECTED' THEN
    UPDATE public.sales_headers sale SET
      transaction_date=sale.created_at,
      transaction_date_source='SERVER_CREATED',
      transaction_date_selected_by=NULL,
      transaction_date_selected_at=NULL,
      payload_snapshot=COALESCE(sale.payload_snapshot,'{}'::JSONB)
        - 'transactionAt'
    WHERE sale.company_id=v_company AND sale.id=v_sale.id;
    v_sale.transaction_date:=v_sale.created_at;
    v_sale.transaction_date_source:='SERVER_CREATED';
  END IF;

  RETURN v_result||jsonb_build_object(
    'transactionAt',v_sale.transaction_date,
    'transactionDateSource',v_sale.transaction_date_source
  );
END
$$;

DO $patch_sale$
DECLARE
  v_definition TEXT;
  v_patched TEXT;
BEGIN
  SELECT pg_get_functiondef(
    'private.post_pos_sale_online_core(uuid,bigint,uuid)'::regprocedure
  ) INTO v_definition;

  v_patched:=replace(
    v_definition,
    'IF v_is_tempo THEN',
    'IF v_is_tempo THEN
        PERFORM private.validate_pos_tempo_effective_dates(
            v_company,v_sale.transaction_date,v_sale.due_date,
            v_sale.fulfillment_mode,v_sale.delivery_scheduled_at
        );'
  );
  IF v_patched=v_definition THEN
    RAISE EXCEPTION 'SALE_PATCH_FAILED: TEMPO effective-date guard';
  END IF;

  v_definition:=v_patched;
  v_patched:=regexp_replace(
    v_definition,
    '(v_sale\.id[[:space:]]*,[[:space:]]*v_sale\.id[[:space:]]*,[[:space:]]*)v_now([[:space:]]*,[[:space:]]*1[[:space:]]*,)',
    E'\\1v_sale.transaction_date\\2'
  );
  IF v_patched=v_definition
     OR v_patched !~ 'v_sale\.transaction_date[[:space:]]*,[[:space:]]*1[[:space:]]*,' THEN
    RAISE EXCEPTION 'SALE_PATCH_FAILED: financial event effective date';
  END IF;
  EXECUTE v_patched;
END
$patch_sale$;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES(
  '20260826100000','pos_tempo_backdated_order_delivery',
  'Allows audited TEMPO effective order dates in open periods and past delivery schedules not earlier than the order; Sale Finance event follows the effective date while created/posted timestamps remain actual'
);

COMMIT;
