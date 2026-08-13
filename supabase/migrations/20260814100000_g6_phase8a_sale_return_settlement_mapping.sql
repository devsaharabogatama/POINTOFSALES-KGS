-- G6 phase 8A: explicit Sale/Return settlement account-function mapping.
-- This migration does not post Financial Events or create Journals.

BEGIN;

DO $migration_guard$
BEGIN
  IF NOT EXISTS(
    SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260813150000'
  ) THEN
    RAISE EXCEPTION
      'MIGRATION_PRECONDITION_FAILED: Inventory Delivery authority required';
  END IF;
  IF EXISTS(
    SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260814100000'
  ) THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260814100000';
  END IF;
END
$migration_guard$;

CREATE OR REPLACE FUNCTION private.provision_g6_sale_settlement_fallbacks(
  p_company_id UUID,p_actor_id UUID DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE
  v_actor UUID:=p_actor_id;
  v_mapping RECORD;
  v_account_id UUID;
  v_candidate_count BIGINT;
  v_fallback_id UUID;
BEGIN
  IF NOT EXISTS(
    SELECT 1 FROM public.companies company
    WHERE company.id=p_company_id AND company.status='ACTIVE'
  ) THEN
    RETURN;
  END IF;

  IF v_actor IS NULL OR NOT EXISTS(
    SELECT 1 FROM public.profiles profile WHERE profile.id=v_actor
  ) THEN
    SELECT profile.id INTO v_actor
    FROM public.profiles profile
    WHERE profile.role::TEXT='super_admin'
    ORDER BY profile.id LIMIT 1;
  END IF;
  IF v_actor IS NULL THEN
    RAISE EXCEPTION
      'MIGRATION_PRECONDITION_FAILED: linked Super Admin profile required';
  END IF;

  FOR v_mapping IN
    SELECT * FROM (VALUES
      ('CASH_DRAWER'::TEXT,'CASH_DRAWER'::TEXT),
      ('BANK_RECEIPT'::TEXT,'BANK'::TEXT)
    ) mapping(function_key,canonical_account_function_key)
  LOOP
    IF EXISTS(
      SELECT 1 FROM public.company_account_function_fallbacks fallback
      WHERE fallback.company_id=p_company_id
        AND fallback.account_function_key=v_mapping.function_key
        AND fallback.status='ACTIVE'
        AND fallback.effective_from<=TIMESTAMPTZ '2000-01-01 00:00:00+00'
        AND (fallback.effective_to IS NULL
             OR fallback.effective_to>TIMESTAMPTZ '2099-12-31 23:59:59+00')
    ) THEN
      CONTINUE;
    END IF;

    IF EXISTS(
      SELECT 1 FROM public.company_account_function_fallbacks fallback
      WHERE fallback.company_id=p_company_id
        AND fallback.account_function_key=v_mapping.function_key
        AND fallback.status='ACTIVE'
    ) THEN
      RAISE EXCEPTION
        'MIGRATION_PRECONDITION_FAILED: partial active fallback for %',
        v_mapping.function_key;
    END IF;

    SELECT count(*),(array_agg(account.id ORDER BY account.id))[1]
      INTO v_candidate_count,v_account_id
    FROM public.chart_of_accounts account
    WHERE account.company_id=p_company_id
      AND account.system_function_key=
        v_mapping.canonical_account_function_key
      AND account.is_system_account
      AND account.is_active
      AND account.is_postable
      AND account.account_type='ASSET';

    IF v_candidate_count<>1 OR v_account_id IS NULL THEN
      RAISE EXCEPTION
        'MIGRATION_PRECONDITION_FAILED: % requires exactly one canonical % account; found %',
        v_mapping.function_key,
        v_mapping.canonical_account_function_key,
        v_candidate_count;
    END IF;

    INSERT INTO public.company_account_function_fallbacks(
      company_id,account_function_key,account_id,effective_from,
      fallback_version,status,approved_by,approved_at,created_by,updated_by
    ) VALUES(
      p_company_id,v_mapping.function_key,v_account_id,
      TIMESTAMPTZ '2000-01-01 00:00:00+00',
      COALESCE((SELECT max(existing.fallback_version)+1
        FROM public.company_account_function_fallbacks existing
        WHERE existing.company_id=p_company_id
          AND existing.account_function_key=v_mapping.function_key),1),
      'ACTIVE',v_actor,clock_timestamp(),v_actor,v_actor
    ) RETURNING id INTO v_fallback_id;

    INSERT INTO public.finance_master_audit(
      company_id,entity_type,entity_id,action,actor_id,after_state
    )
    SELECT fallback.company_id,'FALLBACK',fallback.id,'CREATE',v_actor,
      to_jsonb(fallback)
    FROM public.company_account_function_fallbacks fallback
    WHERE fallback.id=v_fallback_id;
  END LOOP;
END
$$;

REVOKE ALL ON FUNCTION
  private.provision_g6_sale_settlement_fallbacks(UUID,UUID)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.provision_g6_sale_settlement_fallbacks(UUID,UUID)
TO service_role;

DO $backfill$
DECLARE
  v_actor UUID;
  v_company RECORD;
BEGIN
  SELECT profile.id INTO v_actor
  FROM public.profiles profile
  WHERE profile.role::TEXT='super_admin'
  ORDER BY profile.id LIMIT 1;
  IF v_actor IS NULL THEN
    RAISE EXCEPTION
      'MIGRATION_PRECONDITION_FAILED: linked Super Admin profile required';
  END IF;

  FOR v_company IN
    SELECT company.id FROM public.companies company
    WHERE company.status='ACTIVE' ORDER BY company.id
  LOOP
    PERFORM private.provision_g6_sale_settlement_fallbacks(
      v_company.id,v_actor);
  END LOOP;
END
$backfill$;

CREATE OR REPLACE FUNCTION private.trg_g6_provision_sale_settlement_fallbacks()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
BEGIN
  IF NEW.status='ACTIVE' AND (
    TG_OP='INSERT' OR OLD.status IS DISTINCT FROM NEW.status
  ) THEN
    PERFORM private.provision_g6_sale_settlement_fallbacks(NEW.id,auth.uid());
  END IF;
  RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS g6_provision_sale_settlement_fallbacks
ON public.companies;
CREATE TRIGGER g6_provision_sale_settlement_fallbacks
AFTER INSERT OR UPDATE OF status ON public.companies
FOR EACH ROW EXECUTE FUNCTION
  private.trg_g6_provision_sale_settlement_fallbacks();

DO $postcondition$
DECLARE
  v_unresolved BIGINT;
BEGIN
  WITH event_functions AS (
    SELECT event.company_id,event.transaction_category_id,
      event.system_event_key,event.event_date,
      CASE payment.settlement_route_snapshot
        WHEN 'CASH_DRAWER' THEN 'CASH_DRAWER'
        WHEN 'DIRECT_BANK' THEN method.bank_account_function
        WHEN 'CLEARING' THEN method.clearing_account_function
        WHEN 'RECEIVABLE' THEN 'CUSTOMER_RECEIVABLE'
        WHEN 'INTERNAL_LIABILITY' THEN 'CUSTOMER_BALANCE_LIABILITY'
      END function_key
    FROM public.financial_events event
    JOIN public.sales_payments payment
      ON payment.company_id=event.company_id
     AND payment.sales_id=event.source_id
    JOIN public.payment_methods method
      ON method.company_id=payment.company_id
     AND method.id=payment.payment_method_id
    WHERE event.status='HOLD'::public.event_status
      AND event.system_event_key='SALE_POSTED'
    UNION ALL
    SELECT event.company_id,event.transaction_category_id,
      event.system_event_key,event.event_date,
      CASE refund.settlement_route_snapshot
        WHEN 'CASH_DRAWER' THEN 'CASH_DRAWER'
        WHEN 'DIRECT_BANK' THEN method.bank_account_function
        WHEN 'CLEARING' THEN method.clearing_account_function
        WHEN 'RECEIVABLE' THEN 'CUSTOMER_RECEIVABLE'
        WHEN 'INTERNAL_LIABILITY' THEN 'CUSTOMER_BALANCE_LIABILITY'
      END function_key
    FROM public.financial_events event
    JOIN public.sales_return_refunds refund
      ON refund.company_id=event.company_id
     AND refund.document_id=event.source_id
    JOIN public.payment_methods method
      ON method.company_id=refund.company_id
     AND method.id=refund.payment_method_id
    WHERE event.status='HOLD'::public.event_status
      AND event.system_event_key='SALES_RETURN'
  )
  SELECT count(*) INTO v_unresolved
  FROM event_functions scope
  WHERE scope.function_key IS NULL OR NOT(
    (SELECT count(*) FROM public.transaction_account_rules rule
      WHERE rule.company_id=scope.company_id
        AND rule.transaction_category_id=scope.transaction_category_id
        AND rule.system_key=scope.system_event_key
        AND rule.account_function_key=scope.function_key
        AND rule.status='ACTIVE'
        AND rule.effective_from<=scope.event_date
        AND (rule.effective_to IS NULL OR rule.effective_to>scope.event_date))=1
    OR (
      (SELECT count(*) FROM public.transaction_account_rules rule
        WHERE rule.company_id=scope.company_id
          AND rule.transaction_category_id=scope.transaction_category_id
          AND rule.system_key=scope.system_event_key
          AND rule.account_function_key=scope.function_key
          AND rule.status='ACTIVE'
          AND rule.effective_from<=scope.event_date
          AND (rule.effective_to IS NULL OR rule.effective_to>scope.event_date))=0
      AND
      (SELECT count(*) FROM public.company_account_function_fallbacks fallback
        WHERE fallback.company_id=scope.company_id
          AND fallback.account_function_key=scope.function_key
          AND fallback.status='ACTIVE'
          AND fallback.effective_from<=scope.event_date
          AND (fallback.effective_to IS NULL
               OR fallback.effective_to>scope.event_date))=1
    )
  );
  IF v_unresolved<>0 THEN
    RAISE EXCEPTION
      'PHASE8A_SETTLEMENT_MAPPING_UNRESOLVED: % rows',v_unresolved;
  END IF;
END
$postcondition$;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES(
  '20260814100000','g6_phase8a_sale_return_settlement_mapping',
  'Explicit audited CASH_DRAWER and BANK_RECEIPT-to-BANK settlement fallbacks for deterministic Sale and Sales Return posting; no Event or Journal mutation'
);

COMMIT;
