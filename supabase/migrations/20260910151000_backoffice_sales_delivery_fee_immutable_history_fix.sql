-- Forward-fix: compute delivery fee before canonical Invoice core writes immutable history.
-- Isolated Development rollout only. No production, POS, Stock, DO, FIFO, or COGS mutation.
BEGIN;

DO $guard$
DECLARE v_core text;v_history_guard text;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260910150000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: delivery-fee parity required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260910151000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260910151000';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
    WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
  IF to_regprocedure(
      'private.save_backoffice_sales_invoice_draft_core(uuid,bigint,uuid,uuid,jsonb)') IS NULL
    OR to_regprocedure(
      'private.save_backoffice_sales_invoice_draft_core_before_delivery_fee(uuid,bigint,uuid,uuid,jsonb)') IS NULL
    OR to_regprocedure('private.trg_backoffice_sales_invoice_delivery_fee()') IS NULL
    OR to_regprocedure(
      'private.trg_guard_backoffice_sales_invoice_foundation_history()') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: required Invoice chain missing';
  END IF;
  SELECT pg_get_functiondef(
    'private.save_backoffice_sales_invoice_draft_core(uuid,bigint,uuid,uuid,jsonb)'::regprocedure)
  INTO v_core;
  SELECT pg_get_functiondef(
    'private.trg_guard_backoffice_sales_invoice_foundation_history()'::regprocedure)
  INTO v_history_guard;
  IF position('UPDATE public.backoffice_sales_invoice_audit SET after_state=v_after'
      in v_core)=0
    OR position('BACKOFFICE_SALES_INVOICE_HISTORY_IMMUTABLE' in v_history_guard)=0 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: immutable-history failure signature drift';
  END IF;
END
$guard$;

CREATE OR REPLACE FUNCTION private.trg_backoffice_sales_invoice_delivery_fee()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_order_fee numeric;v_other_fee numeric;v_fee_setting text;
BEGIN
  v_fee_setting:=current_setting('kgs.backoffice_invoice_delivery_fee_amount',true);
  IF NULLIF(v_fee_setting,'') IS NOT NULL THEN
    BEGIN
      NEW.delivery_fee_amount:=round(v_fee_setting::numeric,4);
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'BACKOFFICE_INVOICE_DELIVERY_FEE_INVALID';
    END;
    NEW.commercial_snapshot:=COALESCE(NEW.commercial_snapshot,'{}'::jsonb)
      ||jsonb_build_object('deliveryFeeAuthority','BACKOFFICE_ORDER_ALLOCATION');
  END IF;
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

CREATE OR REPLACE FUNCTION private.save_backoffice_sales_invoice_draft_core(
  p_invoice_id uuid,p_expected_version bigint,p_operation_id uuid,
  p_sales_order_id uuid,p_payload jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_type text;v_fee numeric:=0;
  v_order_fee numeric;v_other_fee numeric;v_existing_fee numeric;v_response jsonb;
BEGIN
  IF p_operation_id IS NULL OR p_sales_order_id IS NULL OR p_payload IS NULL
    OR jsonb_typeof(p_payload)<>'object' THEN
    RETURN private.save_backoffice_sales_invoice_draft_core_before_delivery_fee(
      p_invoice_id,p_expected_version,p_operation_id,p_sales_order_id,p_payload);
  END IF;
  v_type:=upper(btrim(p_payload->>'invoiceType'));
  IF v_type NOT IN('REGULAR','DOWN_PAYMENT') THEN
    RETURN private.save_backoffice_sales_invoice_draft_core_before_delivery_fee(
      p_invoice_id,p_expected_version,p_operation_id,p_sales_order_id,p_payload);
  END IF;

  -- Same lock key and ordering as the canonical core; reentrant in this transaction.
  PERFORM pg_advisory_xact_lock(hashtextextended(
    v_company::text||':BACKOFFICE_INVOICE_ORDER:'||p_sales_order_id::text,0));
  SELECT document.delivery_fee_amount INTO v_order_fee
  FROM public.backoffice_sales_orders document
  WHERE document.company_id=v_company AND document.id=p_sales_order_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN private.save_backoffice_sales_invoice_draft_core_before_delivery_fee(
      p_invoice_id,p_expected_version,p_operation_id,p_sales_order_id,p_payload);
  END IF;

  IF v_type='DOWN_PAYMENT' THEN
    IF p_payload ? 'deliveryFeeAmount' THEN
      BEGIN v_fee:=round(COALESCE(NULLIF(p_payload->>'deliveryFeeAmount','')::numeric,0),4);
      EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'BACKOFFICE_INVOICE_DELIVERY_FEE_INVALID';
      END;
      IF v_fee<>0 THEN
        RAISE EXCEPTION 'BACKOFFICE_INVOICE_DELIVERY_FEE_NOT_ALLOWED_ON_DP';
      END IF;
    END IF;
    v_fee:=0;
  ELSIF p_payload ? 'deliveryFeeAmount' THEN
    BEGIN v_fee:=round((p_payload->>'deliveryFeeAmount')::numeric,4);
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'BACKOFFICE_INVOICE_DELIVERY_FEE_INVALID';
    END;
  ELSIF p_invoice_id IS NOT NULL THEN
    SELECT invoice.delivery_fee_amount INTO v_existing_fee
    FROM public.backoffice_sales_invoices invoice
    WHERE invoice.company_id=v_company AND invoice.id=p_invoice_id
      AND invoice.sales_order_id=p_sales_order_id;
    v_fee:=COALESCE(v_existing_fee,0);
  ELSE
    SELECT round(COALESCE(sum(invoice.delivery_fee_amount),0),4) INTO v_other_fee
    FROM public.backoffice_sales_invoices invoice
    WHERE invoice.company_id=v_company AND invoice.sales_order_id=p_sales_order_id
      AND invoice.invoice_type='REGULAR' AND invoice.status IN('DRAFT','POSTED');
    v_fee:=greatest(0,v_order_fee-v_other_fee);
  END IF;
  IF v_fee<0 THEN RAISE EXCEPTION 'BACKOFFICE_INVOICE_DELIVERY_FEE_INVALID'; END IF;
  PERFORM set_config('kgs.backoffice_invoice_delivery_fee_amount',v_fee::text,true);
  BEGIN
    v_response:=private.save_backoffice_sales_invoice_draft_core_before_delivery_fee(
      p_invoice_id,p_expected_version,p_operation_id,p_sales_order_id,p_payload);
  EXCEPTION WHEN OTHERS THEN
    -- The setting is transaction-local, so clear it explicitly when a caller
    -- catches the canonical error and continues inside the same transaction.
    PERFORM set_config('kgs.backoffice_invoice_delivery_fee_amount','',true);
    RAISE;
  END;
  -- Do not leak this Invoice's fee into POST/CANCEL or another Invoice call
  -- executed later in the same transaction (including behavioral tests).
  PERFORM set_config('kgs.backoffice_invoice_delivery_fee_amount','',true);
  RETURN v_response;
END
$$;

REVOKE ALL ON FUNCTION
  private.trg_backoffice_sales_invoice_delivery_fee(),
  private.save_backoffice_sales_invoice_draft_core(uuid,bigint,uuid,uuid,jsonb)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.trg_backoffice_sales_invoice_delivery_fee(),
  private.save_backoffice_sales_invoice_draft_core(uuid,bigint,uuid,uuid,jsonb)
TO service_role;

DO $postcondition$
DECLARE v_core text;v_trigger text;
BEGIN
  SELECT pg_get_functiondef(
    'private.save_backoffice_sales_invoice_draft_core(uuid,bigint,uuid,uuid,jsonb)'::regprocedure)
  INTO v_core;
  SELECT pg_get_functiondef(
    'private.trg_backoffice_sales_invoice_delivery_fee()'::regprocedure)
  INTO v_trigger;
  IF position('UPDATE public.backoffice_sales_invoice_audit' in v_core)>0
    OR position('UPDATE public.backoffice_sales_invoice_operations' in v_core)>0
    OR position('kgs.backoffice_invoice_delivery_fee_amount' in v_core)=0
    OR position($needle$set_config('kgs.backoffice_invoice_delivery_fee_amount','',true)$needle$
      in v_core)=0
    OR position('kgs.backoffice_invoice_delivery_fee_amount' in v_trigger)=0 THEN
    RAISE EXCEPTION 'MIGRATION_POSTCONDITION_FAILED: immutable-history forward-fix invalid';
  END IF;
END
$postcondition$;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260910151000','backoffice_sales_delivery_fee_immutable_history_fix',
  'Computes Invoice delivery fee before canonical core snapshot/audit insert through transaction-local trigger input; removes all wrapper updates to immutable operation/audit history; preserves serialized allocation, exact retry, schedules, Finance and POS boundary');

NOTIFY pgrst,'reload schema';
COMMIT;
