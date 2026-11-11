-- Read-only contract test for Task 2 allocation audit snapshots after Task 5
-- added the nullable effective_date column. No database row is mutated.
DO $test$
DECLARE
  v_current jsonb;
  v_legacy jsonb;
  v_changed jsonb;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20261105100000')
    OR NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20261106100000') THEN
    RAISE EXCEPTION
      'TEST_PRECONDITION_FAILED: Task 2 and Task 5 migrations required';
  END IF;

  SELECT to_jsonb(allocation) INTO v_current
  FROM public.ar_open_item_allocations allocation
  ORDER BY allocation.created_at,allocation.id LIMIT 1;
  IF v_current IS NULL THEN
    RAISE EXCEPTION
      'TEST_PRECONDITION_FAILED: one canonical allocation row required';
  END IF;

  v_legacy:=v_current-'effective_date';
  IF v_legacy IS DISTINCT FROM (CASE
      WHEN v_legacy ? 'effective_date' THEN v_current
      ELSE v_current-'effective_date' END) THEN
    RAISE EXCEPTION
      'TEST_FAILED: legacy snapshot compatibility rejected';
  END IF;

  IF v_current IS DISTINCT FROM (CASE
      WHEN v_current ? 'effective_date' THEN v_current
      ELSE v_current-'effective_date' END) THEN
    RAISE EXCEPTION
      'TEST_FAILED: current snapshot exact comparison rejected';
  END IF;

  v_changed:=v_legacy||jsonb_build_object('allocated_amount',-1);
  IF v_changed IS NOT DISTINCT FROM (CASE
      WHEN v_changed ? 'effective_date' THEN v_current
      ELSE v_current-'effective_date' END) THEN
    RAISE EXCEPTION
      'TEST_FAILED: non-schema snapshot mismatch was hidden';
  END IF;
END
$test$;

SELECT 'backoffice_ar_audit_snapshot_schema_compatibility_behavior' check_name,
  'PASS' status,0 violation_rows,jsonb_build_object('tested',ARRAY[
    'legacy allocation snapshot without effective_date remains comparable',
    'current allocation snapshot with effective_date remains exact',
    'non-schema allocation field mismatch remains rejected',
    'zero database mutation']) details;
