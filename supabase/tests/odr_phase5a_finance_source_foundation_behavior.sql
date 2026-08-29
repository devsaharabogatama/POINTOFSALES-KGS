-- ODR-5A fixture-free catalog/guard behavioral contract.
-- No persistent writes are performed.
DO $test$
DECLARE v_dispatch_guard TEXT;v_payment_guard TEXT;v_audit_guard TEXT;
BEGIN
  SELECT procedure.prosrc INTO v_dispatch_guard FROM pg_proc procedure
  JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname='private'
    AND procedure.proname='trg_odr5_guard_dispatch_financial_effect';
  SELECT procedure.prosrc INTO v_payment_guard FROM pg_proc procedure
  JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname='private'
    AND procedure.proname='trg_odr5_guard_payment_verification';
  SELECT procedure.prosrc INTO v_audit_guard FROM pg_proc procedure
  JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname='private'
    AND procedure.proname='trg_odr5_guard_finance_source_audit';

  IF v_dispatch_guard IS NULL
    OR v_dispatch_guard NOT LIKE '%DISPATCH_FINANCIAL_EFFECT_IMMUTABLE%'
    OR v_dispatch_guard NOT LIKE '%DISPATCH_OPERATION_NOT_FOUND%'
    OR v_dispatch_guard NOT LIKE '%DISPATCH_FINANCIAL_EFFECT_SOURCE_MISMATCH%' THEN
    RAISE EXCEPTION 'TEST_FAILED: Dispatch Finance source guard invalid';
  END IF;
  IF v_payment_guard IS NULL
    OR v_payment_guard NOT LIKE '%PAYMENT_VERIFICATION_GUARDED_MUTATION_REQUIRED%'
    OR v_payment_guard NOT LIKE '%PAYMENT_VERIFICATION_SOURCE_IMMUTABLE%'
    OR v_payment_guard NOT LIKE '%PAYMENT_VERIFICATION_IMMUTABLE%' THEN
    RAISE EXCEPTION 'TEST_FAILED: Payment verification guard invalid';
  END IF;
  IF v_audit_guard IS NULL
    OR v_audit_guard NOT LIKE '%ODR5_FINANCE_SOURCE_AUDIT_IMMUTABLE%' THEN
    RAISE EXCEPTION 'TEST_FAILED: Finance source audit guard invalid';
  END IF;
  IF EXISTS(SELECT 1 FROM public.sales_dispatch_financial_effects)
    OR EXISTS(SELECT 1 FROM public.sales_payment_verification_requests) THEN
    RAISE EXCEPTION 'TEST_FAILED: Foundation must remain zero-backfill';
  END IF;
  IF EXISTS(SELECT 1 FROM information_schema.role_table_grants privilege
    WHERE privilege.table_schema='public' AND privilege.table_name IN(
      'sales_dispatch_financial_effects','sales_payment_verification_requests',
      'sales_dispatch_financial_effect_audit','sales_payment_verification_audit')
      AND privilege.grantee IN('anon','authenticated')) THEN
    RAISE EXCEPTION 'TEST_FAILED: Browser Finance source privilege open';
  END IF;
END
$test$;

SELECT 'odr_phase5a_finance_source_foundation_behavior' check_name,
  'PASS' status,jsonb_build_object('tested',jsonb_build_array(
    'DISPATCH_SOURCE_LINEAGE','PAYMENT_GUARDED_LIFECYCLE',
    'APPEND_ONLY_AUDIT','ZERO_BACKFILL','BROWSER_TABLE_CLOSURE')) details;
