-- Fail-closed classification for cutover candidates with open procurement/PO.
-- No plan, operational document, Reservation, Stock, Payment, Finance or mode mutation.
BEGIN;

DO $guard$
DECLARE v_result jsonb;
BEGIN
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260910140000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260910140000';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260910130000')
    OR to_regprocedure(
      'private.classify_sales_process_conversion_candidate(text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean)'
    ) IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: cutover classifier dependency incomplete';
  END IF;
  IF EXISTS(SELECT 1 FROM public.sales_process_cutover_plans
      WHERE status IN('DRAFT','PREVIEWED','APPLYING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: cancel open cutover plan and recreate after classifier upgrade';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
      WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
      WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
  v_result:=private.classify_sales_process_conversion_candidate(
    'RETAIL_CONFIRM_INVOICE','BACKOFFICE_DELIVERED_QTY_INVOICE',false,
    false,false,false,false,false,false,true);
  IF v_result->>'decision'<>'CONVERT'
    OR NOT (v_result->'requirementCodes' ? 'TRANSFER_PROCUREMENT_LINEAGE') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: legacy procurement classifier drift';
  END IF;
END
$guard$;

CREATE OR REPLACE FUNCTION private.classify_sales_process_conversion_candidate(
  p_source_mode text,p_target_mode text,p_is_final boolean,
  p_has_dispatch boolean,p_has_final_stock_effect boolean,
  p_has_posted_finance boolean,p_has_nonterminal_payment boolean,
  p_has_issued_invoice boolean,p_has_pending_revision boolean,
  p_has_open_procurement boolean
) RETURNS jsonb LANGUAGE plpgsql IMMUTABLE SET search_path=public,pg_temp AS $$
DECLARE v_blockers jsonb:='[]'::jsonb;v_requirements jsonb:='[]'::jsonb;
  v_decision text;
BEGIN
  IF p_source_mode NOT IN('RETAIL_CONFIRM_INVOICE','BACKOFFICE_DELIVERED_QTY_INVOICE')
    OR p_target_mode NOT IN('RETAIL_CONFIRM_INVOICE','BACKOFFICE_DELIVERED_QTY_INVOICE')
    OR p_source_mode=p_target_mode THEN
    RAISE EXCEPTION 'SALES_PROCESS_CONVERSION_MODE_INVALID';
  END IF;
  IF p_is_final THEN
    v_decision:='KEEP_SOURCE';
  ELSE
    IF p_has_dispatch THEN v_blockers:=v_blockers||jsonb_build_array('DISPATCH_STARTED'); END IF;
    IF p_has_final_stock_effect THEN v_blockers:=v_blockers||jsonb_build_array('FINAL_STOCK_EFFECT'); END IF;
    IF p_has_posted_finance THEN v_blockers:=v_blockers||jsonb_build_array('POSTED_FINANCE_EFFECT'); END IF;
    IF p_has_nonterminal_payment THEN v_blockers:=v_blockers||jsonb_build_array('PAYMENT_REQUIRES_RESOLUTION'); END IF;
    IF p_has_pending_revision THEN v_blockers:=v_blockers||jsonb_build_array('PENDING_REVISION_MUST_RESOLVE'); END IF;
    IF p_has_open_procurement THEN v_blockers:=v_blockers||jsonb_build_array('OPEN_PROCUREMENT_MUST_FINISH'); END IF;
    IF jsonb_array_length(v_blockers)>0 THEN
      v_decision:='BLOCKED';
    ELSE
      v_decision:='CONVERT';
      IF p_has_issued_invoice THEN
        v_requirements:=v_requirements||jsonb_build_array('FORMAL_CANCEL_SOURCE_INVOICE');
      END IF;
    END IF;
  END IF;
  RETURN jsonb_build_object('decision',v_decision,'blockerCodes',v_blockers,
    'requirementCodes',v_requirements);
END
$$;

REVOKE ALL ON FUNCTION
  private.classify_sales_process_conversion_candidate(text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.classify_sales_process_conversion_candidate(text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean)
TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260910140000','sales_process_cutover_procurement_blocker',
  'Classify nonfinal cutover candidates with open procurement or PO as BLOCKED grandfathered sources using OPEN_PROCUREMENT_MUST_FINISH; no Apply, conversion, mode switch, Stock, Payment or Finance effect');

COMMIT;
