-- Effective-dated Retail/Backoffice cutover planning foundation.
-- This migration does not switch any Company or convert any operational document.
BEGIN;

DO $guard$
BEGIN
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260909162000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260909162000';
  END IF;
  IF (SELECT count(*) FROM private.kgs_schema_migrations WHERE version IN(
      '20260908100000','20260908110000','20260909145000',
      '20260909152000','20260909156000','20260909161000'))<>6 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: cutover dependency chain incomplete';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF to_regclass('public.company_sales_process_settings') IS NOT NULL
    OR to_regclass('public.company_sales_process_mode_history') IS NOT NULL
    OR to_regclass('public.sales_process_cutover_plans') IS NOT NULL
    OR to_regclass('public.sales_process_cutover_items') IS NOT NULL
    OR to_regclass('public.sales_process_cutover_audit') IS NOT NULL
    OR to_regprocedure('private.classify_sales_process_conversion_candidate(text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean)') IS NOT NULL
    OR to_regprocedure('private.trg_initialize_company_sales_process_setting()') IS NOT NULL
    OR to_regprocedure('private.trg_guard_company_sales_process_setting()') IS NOT NULL
    OR to_regprocedure('private.trg_guard_sales_process_history()') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: cutover foundation collision';
  END IF;
END
$guard$;

CREATE TABLE public.company_sales_process_settings(
  company_id uuid PRIMARY KEY REFERENCES public.companies(id) ON DELETE RESTRICT,
  active_mode text NOT NULL DEFAULT 'RETAIL_CONFIRM_INVOICE',
  mode_effective_at timestamptz NOT NULL DEFAULT '-infinity'::timestamptz,
  master_version bigint NOT NULL DEFAULT 1,
  updated_by uuid REFERENCES public.profiles(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT company_sales_process_settings_mode_check CHECK(active_mode IN(
    'RETAIL_CONFIRM_INVOICE','BACKOFFICE_DELIVERED_QTY_INVOICE')),
  CONSTRAINT company_sales_process_settings_version_check CHECK(master_version>0)
);

CREATE TABLE public.company_sales_process_mode_history(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
  change_type text NOT NULL,
  source_mode text,
  target_mode text NOT NULL,
  effective_at timestamptz NOT NULL,
  reason text NOT NULL,
  cutover_plan_id uuid,
  actor_id uuid REFERENCES public.profiles(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT company_sales_process_mode_history_company_id_unique UNIQUE(company_id,id),
  CONSTRAINT company_sales_process_mode_history_change_check CHECK(
    change_type IN('INITIALIZE','SWITCH','ROLLBACK')),
  CONSTRAINT company_sales_process_mode_history_source_check CHECK(
    source_mode IS NULL OR source_mode IN(
      'RETAIL_CONFIRM_INVOICE','BACKOFFICE_DELIVERED_QTY_INVOICE')),
  CONSTRAINT company_sales_process_mode_history_target_check CHECK(target_mode IN(
    'RETAIL_CONFIRM_INVOICE','BACKOFFICE_DELIVERED_QTY_INVOICE')),
  CONSTRAINT company_sales_process_mode_history_shape_check CHECK(
    (change_type='INITIALIZE' AND source_mode IS NULL AND cutover_plan_id IS NULL
      AND actor_id IS NULL)
    OR (change_type IN('SWITCH','ROLLBACK') AND source_mode IS NOT NULL
      AND source_mode<>target_mode AND cutover_plan_id IS NOT NULL
      AND actor_id IS NOT NULL)),
  CONSTRAINT company_sales_process_mode_history_reason_check CHECK(
    nullif(btrim(reason),'') IS NOT NULL AND length(reason)<=500)
);

CREATE TABLE public.sales_process_cutover_plans(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
  source_mode text NOT NULL,
  target_mode text NOT NULL,
  effective_at timestamptz NOT NULL,
  selection_policy text NOT NULL DEFAULT 'CONVERT_ELIGIBLE_KEEP_BLOCKED',
  status text NOT NULL DEFAULT 'DRAFT',
  reason text NOT NULL,
  expected_settings_version bigint NOT NULL,
  operation_id uuid NOT NULL,
  request_hash text NOT NULL,
  preview_snapshot jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_by uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  applied_by uuid REFERENCES public.profiles(id) ON DELETE RESTRICT,
  applied_at timestamptz,
  canceled_by uuid REFERENCES public.profiles(id) ON DELETE RESTRICT,
  canceled_at timestamptz,
  cancel_reason text,
  CONSTRAINT sales_process_cutover_plans_company_id_unique UNIQUE(company_id,id),
  CONSTRAINT sales_process_cutover_plans_operation_unique UNIQUE(company_id,operation_id),
  CONSTRAINT sales_process_cutover_plans_mode_check CHECK(
    source_mode IN('RETAIL_CONFIRM_INVOICE','BACKOFFICE_DELIVERED_QTY_INVOICE')
    AND target_mode IN('RETAIL_CONFIRM_INVOICE','BACKOFFICE_DELIVERED_QTY_INVOICE')
    AND source_mode<>target_mode),
  CONSTRAINT sales_process_cutover_plans_policy_check CHECK(
    selection_policy='CONVERT_ELIGIBLE_KEEP_BLOCKED'),
  CONSTRAINT sales_process_cutover_plans_status_check CHECK(
    status IN('DRAFT','PREVIEWED','APPLYING','APPLIED','CANCELED','FAILED')),
  CONSTRAINT sales_process_cutover_plans_shape_check CHECK(
    expected_settings_version>0 AND request_hash~'^[0-9a-f]{64}$'
    AND jsonb_typeof(preview_snapshot)='object'
    AND nullif(btrim(reason),'') IS NOT NULL AND length(reason)<=500
    AND ((status IN('DRAFT','PREVIEWED','APPLYING','FAILED')
          AND applied_by IS NULL AND applied_at IS NULL
          AND canceled_by IS NULL AND canceled_at IS NULL AND cancel_reason IS NULL)
      OR (status='APPLIED' AND applied_by IS NOT NULL AND applied_at IS NOT NULL
          AND canceled_by IS NULL AND canceled_at IS NULL AND cancel_reason IS NULL)
      OR (status='CANCELED' AND applied_by IS NULL AND applied_at IS NULL
          AND canceled_by IS NOT NULL AND canceled_at IS NOT NULL
          AND nullif(btrim(cancel_reason),'') IS NOT NULL))
  )
);

CREATE UNIQUE INDEX sales_process_cutover_one_open_plan
  ON public.sales_process_cutover_plans(company_id)
  WHERE status IN('DRAFT','PREVIEWED','APPLYING');

ALTER TABLE public.company_sales_process_mode_history
  ADD CONSTRAINT company_sales_process_mode_history_plan_fk
  FOREIGN KEY(company_id,cutover_plan_id)
  REFERENCES public.sales_process_cutover_plans(company_id,id) ON DELETE RESTRICT;

CREATE TABLE public.sales_process_cutover_items(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL,
  cutover_plan_id uuid NOT NULL,
  source_mode text NOT NULL,
  target_mode text NOT NULL,
  source_document_type text NOT NULL,
  source_document_id uuid NOT NULL,
  source_document_no text NOT NULL,
  source_status text NOT NULL,
  source_master_version bigint NOT NULL,
  decision text NOT NULL,
  item_status text NOT NULL DEFAULT 'PLANNED',
  blocker_codes jsonb NOT NULL DEFAULT '[]'::jsonb,
  requirement_codes jsonb NOT NULL DEFAULT '[]'::jsonb,
  source_snapshot jsonb NOT NULL DEFAULT '{}'::jsonb,
  target_document_type text,
  target_document_id uuid,
  target_document_no text,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT sales_process_cutover_items_company_id_unique UNIQUE(company_id,id),
  CONSTRAINT sales_process_cutover_items_source_unique UNIQUE(
    company_id,cutover_plan_id,source_mode,source_document_id),
  CONSTRAINT sales_process_cutover_items_plan_fk FOREIGN KEY(company_id,cutover_plan_id)
    REFERENCES public.sales_process_cutover_plans(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT sales_process_cutover_items_mode_check CHECK(
    source_mode IN('RETAIL_CONFIRM_INVOICE','BACKOFFICE_DELIVERED_QTY_INVOICE')
    AND target_mode IN('RETAIL_CONFIRM_INVOICE','BACKOFFICE_DELIVERED_QTY_INVOICE')
    AND source_mode<>target_mode),
  CONSTRAINT sales_process_cutover_items_source_type_check CHECK(
    source_document_type IN('RETAIL_SALE','BACKOFFICE_SALES_ORDER')),
  CONSTRAINT sales_process_cutover_items_decision_check CHECK(
    decision IN('CONVERT','KEEP_SOURCE','BLOCKED')),
  CONSTRAINT sales_process_cutover_items_status_check CHECK(
    item_status IN('PLANNED','APPLIED','KEPT','FAILED')),
  CONSTRAINT sales_process_cutover_items_shape_check CHECK(
    source_master_version>0 AND nullif(btrim(source_document_no),'') IS NOT NULL
    AND nullif(btrim(source_status),'') IS NOT NULL
    AND jsonb_typeof(blocker_codes)='array'
    AND jsonb_typeof(requirement_codes)='array'
    AND jsonb_typeof(source_snapshot)='object'
    AND ((target_document_id IS NULL AND target_document_type IS NULL
          AND target_document_no IS NULL)
      OR (target_document_id IS NOT NULL
          AND nullif(btrim(target_document_type),'') IS NOT NULL
          AND nullif(btrim(target_document_no),'') IS NOT NULL))
  )
);

CREATE TABLE public.sales_process_cutover_audit(
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id uuid NOT NULL,
  cutover_plan_id uuid NOT NULL,
  cutover_item_id uuid,
  action text NOT NULL,
  actor_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  operation_id uuid NOT NULL,
  before_state jsonb,
  after_state jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT sales_process_cutover_audit_operation_unique UNIQUE(
    company_id,cutover_plan_id,action,operation_id),
  CONSTRAINT sales_process_cutover_audit_plan_fk FOREIGN KEY(company_id,cutover_plan_id)
    REFERENCES public.sales_process_cutover_plans(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT sales_process_cutover_audit_item_fk FOREIGN KEY(company_id,cutover_item_id)
    REFERENCES public.sales_process_cutover_items(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT sales_process_cutover_audit_action_check CHECK(action IN(
    'CREATE_PLAN','REFRESH_PREVIEW','APPLY_ITEM','KEEP_ITEM','FAIL_ITEM',
    'APPLY_MODE','CANCEL_PLAN','ROLLBACK_MODE')),
  CONSTRAINT sales_process_cutover_audit_state_check CHECK(
    jsonb_typeof(after_state)='object')
);

CREATE FUNCTION private.classify_sales_process_conversion_candidate(
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
    IF jsonb_array_length(v_blockers)>0 THEN
      v_decision:='BLOCKED';
    ELSE
      v_decision:='CONVERT';
      IF p_has_issued_invoice THEN
        v_requirements:=v_requirements||jsonb_build_array('FORMAL_CANCEL_SOURCE_INVOICE');
      END IF;
      IF p_has_pending_revision THEN
        v_requirements:=v_requirements||jsonb_build_array('CONVERT_REVISION_PAIR');
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

CREATE FUNCTION private.trg_guard_company_sales_process_setting()
RETURNS trigger LANGUAGE plpgsql SET search_path=public,pg_temp AS $$
BEGIN
  IF TG_OP='DELETE' THEN RAISE EXCEPTION 'SALES_PROCESS_SETTING_DELETE_FORBIDDEN'; END IF;
  IF TG_OP='UPDATE' AND COALESCE(current_setting(
      'kgs.sales_process_cutover_mutation',true),'')<>'1' THEN
    RAISE EXCEPTION 'SALES_PROCESS_SETTING_RUNTIME_REQUIRED';
  END IF;
  RETURN NEW;
END
$$;

CREATE FUNCTION private.trg_initialize_company_sales_process_setting()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
  INSERT INTO public.company_sales_process_settings(company_id) VALUES(NEW.id);
  INSERT INTO public.company_sales_process_mode_history(
    company_id,change_type,source_mode,target_mode,effective_at,reason)
  VALUES(NEW.id,'INITIALIZE',NULL,'RETAIL_CONFIRM_INVOICE','-infinity'::timestamptz,
    'Initial compatibility mode; no operational cutover performed');
  RETURN NEW;
END
$$;

CREATE FUNCTION private.trg_guard_sales_process_history()
RETURNS trigger LANGUAGE plpgsql SET search_path=public,pg_temp AS $$
BEGIN
  RAISE EXCEPTION 'SALES_PROCESS_HISTORY_IMMUTABLE';
END
$$;

CREATE TRIGGER company_sales_process_settings_guard
BEFORE UPDATE OR DELETE ON public.company_sales_process_settings
FOR EACH ROW EXECUTE FUNCTION private.trg_guard_company_sales_process_setting();
CREATE TRIGGER company_sales_process_mode_history_immutable
BEFORE UPDATE OR DELETE ON public.company_sales_process_mode_history
FOR EACH ROW EXECUTE FUNCTION private.trg_guard_sales_process_history();
CREATE TRIGGER sales_process_cutover_audit_immutable
BEFORE UPDATE OR DELETE ON public.sales_process_cutover_audit
FOR EACH ROW EXECUTE FUNCTION private.trg_guard_sales_process_history();

INSERT INTO public.company_sales_process_settings(company_id)
SELECT company.id FROM public.companies company;
INSERT INTO public.company_sales_process_mode_history(
  company_id,change_type,source_mode,target_mode,effective_at,reason)
SELECT company.id,'INITIALIZE',NULL,'RETAIL_CONFIRM_INVOICE','-infinity'::timestamptz,
  'Initial compatibility mode; no operational cutover performed'
FROM public.companies company;

CREATE TRIGGER companies_sales_process_setting_initialize
AFTER INSERT ON public.companies
FOR EACH ROW EXECUTE FUNCTION private.trg_initialize_company_sales_process_setting();

ALTER TABLE public.company_sales_process_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.company_sales_process_mode_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sales_process_cutover_plans ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sales_process_cutover_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sales_process_cutover_audit ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.company_sales_process_settings,
  public.company_sales_process_mode_history,public.sales_process_cutover_plans,
  public.sales_process_cutover_items,public.sales_process_cutover_audit
FROM PUBLIC,anon,authenticated;
GRANT SELECT,INSERT,UPDATE,DELETE ON TABLE public.company_sales_process_settings,
  public.company_sales_process_mode_history,public.sales_process_cutover_plans,
  public.sales_process_cutover_items,public.sales_process_cutover_audit TO service_role;
GRANT USAGE,SELECT ON SEQUENCE public.sales_process_cutover_audit_id_seq TO service_role;
REVOKE ALL ON FUNCTION
  private.classify_sales_process_conversion_candidate(text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean),
  private.trg_initialize_company_sales_process_setting(),
  private.trg_guard_company_sales_process_setting(),
  private.trg_guard_sales_process_history()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.classify_sales_process_conversion_candidate(text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean),
  private.trg_initialize_company_sales_process_setting(),
  private.trg_guard_company_sales_process_setting(),
  private.trg_guard_sales_process_history()
TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260909162000','sales_process_cutover_foundation',
  'Add default-Retail effective mode state, immutable history, cutover plan/item/audit lineage and pure eligibility classifier; no Company switch or operational document, Stock, PO, Payment or Finance mutation');

COMMIT;
