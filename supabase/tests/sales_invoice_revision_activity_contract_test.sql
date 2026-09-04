-- Sales Invoice revision activity read-model contract regression.
-- SAFETY: definition and privilege checks only; no business row is changed.
BEGIN;

DO $test$
DECLARE v_activity TEXT;v_revision TEXT;
BEGIN
  IF to_regprocedure('public.get_sales_document_activity()') IS NULL THEN
    RAISE EXCEPTION 'TEST_FAILED: Sales document activity RPC missing';
  END IF;
  SELECT lower(pg_get_functiondef(
    'public.get_sales_document_activity()'::regprocedure))
    INTO v_activity;
  SELECT lower(pg_get_functiondef(
    'public.get_sales_order_revision_links()'::regprocedure)) INTO v_revision;
  IF position('sales.sales_documents' IN v_activity)=0
    OR position('createdbyname' IN v_activity)=0
    OR position('updatedat' IN v_activity)=0
    OR position('confirmedbyname' IN v_activity)=0
    OR position('canceledbyname' IN v_activity)=0 THEN
    RAISE EXCEPTION 'TEST_FAILED: Sales document activity contract incomplete';
  END IF;
  IF position('sourceinvoiceno' IN v_revision)=0
    OR position('replacementinvoiceno' IN v_revision)=0
    OR position('startedbyname' IN v_revision)=0
    OR position('appliedbyname' IN v_revision)=0
    OR position('abandonedbyname' IN v_revision)=0 THEN
    RAISE EXCEPTION 'TEST_FAILED: revision human-readable linkage incomplete';
  END IF;
  IF has_function_privilege('anon','public.get_sales_document_activity()','EXECUTE')
    OR NOT has_function_privilege(
      'authenticated','public.get_sales_document_activity()','EXECUTE') THEN
    RAISE EXCEPTION 'TEST_FAILED: Sales document activity RPC boundary invalid';
  END IF;
END
$test$;

SELECT 'sales_invoice_revision_activity_contract_test' check_name,'PASS' status,
  jsonb_build_object('tested',ARRAY[
    'VIEW-guarded document activity','human-readable revision actors',
    'source and replacement Invoice numbers','browser RPC boundary']) details;

ROLLBACK;
