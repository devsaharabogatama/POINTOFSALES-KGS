-- Identity foundation for Office-to-Retail cutover targets and canonical
-- pending-Revision blocker classification. No Apply or mode switch is opened.
BEGIN;

DO $guard$
BEGIN
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260910130000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260910130000';
  END IF;
  IF (SELECT count(*) FROM private.kgs_schema_migrations WHERE version IN(
      '20260908100000','20260909162000','20260909163000',
      '20260910110000','20260910120000'))<>5
    OR to_regclass('public.sales_headers') IS NULL
    OR to_regclass('public.sales_process_cutover_plans') IS NULL
    OR to_regprocedure(
      'private.classify_sales_process_conversion_candidate(text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean)'
    ) IS NULL
    OR to_regprocedure('private.trg_guard_sales_process_identity()') IS NULL
    OR to_regprocedure('private.trg_g4_prepare_sale_draft()') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: cutover identity dependency incomplete';
  END IF;
  IF to_regprocedure(
      'private.sales_process_retail_identity_is_valid(text,text,uuid,uuid,uuid)'
    ) IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: cutover identity helper collision';
  END IF;
  IF (SELECT count(*) FROM information_schema.columns
      WHERE table_schema='public' AND table_name='sales_headers'
        AND column_name IN('session_id','pos_id','created_session_id')
        AND is_nullable='NO')<>3 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: sales session identity nullability drift';
  END IF;
  IF (SELECT count(*) FROM information_schema.table_constraints
      WHERE table_schema='public' AND table_name='sales_headers'
        AND constraint_name IN('sales_headers_origin_check',
          'sales_headers_process_mode_check',
          'sales_headers_origin_process_pair_check'))<>3 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: sales process constraint drift';
  END IF;
  IF EXISTS(SELECT 1 FROM public.sales_headers
      WHERE sales_origin NOT IN('POS','BACKOFFICE_SALES')
        OR session_id IS NULL OR pos_id IS NULL OR created_session_id IS NULL) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: existing sales identity rows invalid';
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
END
$guard$;

CREATE FUNCTION private.sales_process_retail_identity_is_valid(
  p_sales_origin text,p_sales_process_mode text,p_session_id uuid,
  p_pos_id uuid,p_created_session_id uuid
) RETURNS boolean LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path=public,pg_temp AS $$
  SELECT
    CASE
      WHEN p_sales_origin='BACKOFFICE_CUTOVER'
        AND p_sales_process_mode='RETAIL_CONFIRM_INVOICE'
      THEN p_session_id IS NULL AND p_pos_id IS NULL
        AND p_created_session_id IS NULL
      WHEN p_sales_origin IN('POS','BACKOFFICE_SALES')
      THEN p_session_id IS NOT NULL AND p_pos_id IS NOT NULL
        AND p_created_session_id IS NOT NULL
      ELSE false
    END;
$$;

REVOKE ALL ON FUNCTION
  private.sales_process_retail_identity_is_valid(text,text,uuid,uuid,uuid)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.sales_process_retail_identity_is_valid(text,text,uuid,uuid,uuid)
TO service_role;

ALTER TABLE public.sales_headers
  DROP CONSTRAINT sales_headers_origin_check,
  DROP CONSTRAINT sales_headers_origin_process_pair_check,
  ALTER COLUMN session_id DROP NOT NULL,
  ALTER COLUMN pos_id DROP NOT NULL,
  ALTER COLUMN created_session_id DROP NOT NULL,
  ADD CONSTRAINT sales_headers_origin_check CHECK(
    sales_origin IN('POS','BACKOFFICE_SALES','BACKOFFICE_CUTOVER')),
  ADD CONSTRAINT sales_headers_origin_process_pair_check CHECK(
    (sales_origin='POS' AND sales_process_mode='RETAIL_CONFIRM_INVOICE')
    OR (sales_origin='BACKOFFICE_CUTOVER'
      AND sales_process_mode='RETAIL_CONFIRM_INVOICE')
    OR (sales_origin='BACKOFFICE_SALES'
      AND sales_process_mode='BACKOFFICE_DELIVERED_QTY_INVOICE')),
  ADD CONSTRAINT sales_headers_retail_identity_context_check CHECK(
    private.sales_process_retail_identity_is_valid(sales_origin,
      sales_process_mode,session_id,pos_id,created_session_id));

COMMENT ON COLUMN public.sales_headers.sales_origin IS
  'Immutable business source: POS, BACKOFFICE_SALES, or system-created BACKOFFICE_CUTOVER. BACKOFFICE_CUTOVER never fabricates Cashier Session/POS identity.';

CREATE OR REPLACE FUNCTION private.trg_g4_prepare_sale_draft()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.sales_origin<>'BACKOFFICE_CUTOVER' THEN
    NEW.created_session_id := COALESCE(NEW.created_session_id, NEW.session_id);
  END IF;
  IF NEW.document_status = 'DRAFT' AND NEW.draft_no IS NULL THEN
    NEW.draft_no := 'DRF-' || to_char(clock_timestamp(), 'YYYYMMDD') || '-'
      || lpad(nextval('private.pos_draft_number_seq')::TEXT, 6, '0');
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION private.trg_guard_sales_process_identity()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
BEGIN
  IF TG_OP='UPDATE' AND (
    NEW.sales_origin IS DISTINCT FROM OLD.sales_origin
    OR NEW.sales_process_mode IS DISTINCT FROM OLD.sales_process_mode
  ) THEN
    RAISE EXCEPTION 'SALES_PROCESS_IDENTITY_IMMUTABLE';
  END IF;

  IF TG_OP='INSERT' AND NEW.sales_origin='BACKOFFICE_CUTOVER'
    AND COALESCE(current_setting('kgs.sales_process_cutover_mutation',true),'')<>'1' THEN
    RAISE EXCEPTION 'BACKOFFICE_CUTOVER_RUNTIME_REQUIRED';
  END IF;

  IF NEW.sales_origin='BACKOFFICE_SALES' AND NOT EXISTS(
    SELECT 1 FROM public.company_features feature
    WHERE feature.company_id=NEW.company_id
      AND feature.feature_code='backoffice_delivered_qty_sales_enabled'
      AND feature.is_enabled
  ) THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_FEATURE_NOT_ENABLED';
  END IF;
  RETURN NEW;
END
$$;

REVOKE ALL ON FUNCTION private.trg_g4_prepare_sale_draft(),
  private.trg_guard_sales_process_identity()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.trg_g4_prepare_sale_draft(),
  private.trg_guard_sales_process_identity()
TO service_role;

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
    IF jsonb_array_length(v_blockers)>0 THEN
      v_decision:='BLOCKED';
    ELSE
      v_decision:='CONVERT';
      IF p_has_issued_invoice THEN
        v_requirements:=v_requirements||jsonb_build_array('FORMAL_CANCEL_SOURCE_INVOICE');
      END IF;
      IF p_has_open_procurement THEN
        v_requirements:=v_requirements||jsonb_build_array('TRANSFER_PROCUREMENT_LINEAGE');
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
VALUES('20260910130000','sales_process_cutover_retail_identity',
  'Add strict BACKOFFICE_CUTOVER Retail identity without fake Cashier Session/POS, preserve normal POS identity requirements, and classify pending Retail revisions as grandfathered blockers; no Apply, mode switch, operational conversion, Stock, Payment or Finance effect');

COMMIT;
