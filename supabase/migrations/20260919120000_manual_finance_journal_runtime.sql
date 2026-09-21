-- Guarded Manual Finance Journal runtime. Approval is ON by default.
BEGIN;

DO $guard$
DECLARE v_line_definition text;v_line_normalized text;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260919110000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: customer receipt credit-note alignment required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260919120000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260919120000';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF to_regprocedure('private.acp_require_permission_capability(uuid,text,text)') IS NULL
     OR to_regprocedure('private.trg_g6_guard_finance_journal()') IS NULL
     OR to_regprocedure('private.trg_g6_guard_finance_journal_line()') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical Finance/permission runtime missing';
  END IF;
  SELECT pg_get_functiondef('private.trg_g6_guard_finance_journal_line()'::regprocedure)
  INTO v_line_definition;
  v_line_normalized:=regexp_replace(lower(v_line_definition),'\s+','','g');
  IF position('backoffice_customer_refund' IN v_line_normalized)=0
     OR position('original_journal.journal_typein(''manual'',''opening_balance'')'
       IN v_line_normalized)=0
     OR position('ifv_status<>''draft''' IN v_line_normalized)=0 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical Journal line guard drift';
  END IF;
  IF EXISTS(SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='finance_journals'
      AND column_name='manual_workflow_status')
     OR EXISTS(SELECT 1 FROM public.access_permission_catalog
       WHERE permission_key='finance.manual_journals') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Manual Journal object collision';
  END IF;
END
$guard$;

ALTER TABLE public.finance_company_policies
  ADD COLUMN manual_journal_approval_required BOOLEAN NOT NULL DEFAULT TRUE;

ALTER TABLE public.finance_journals
  ADD COLUMN manual_workflow_status TEXT,
  ADD COLUMN manual_approval_required_snapshot BOOLEAN,
  ADD COLUMN external_reference TEXT,
  ADD COLUMN evidence_url TEXT,
  ADD COLUMN submitted_by UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
  ADD COLUMN submitted_at TIMESTAMPTZ,
  ADD COLUMN approved_by UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
  ADD COLUMN approved_at TIMESTAMPTZ;

ALTER TABLE public.finance_journals DISABLE TRIGGER g6_guard_finance_journal;
UPDATE public.finance_journals SET
  manual_workflow_status=CASE status
    WHEN 'POSTED' THEN 'APPROVED' WHEN 'CANCELED' THEN 'CANCELED' ELSE 'DRAFT' END,
  manual_approval_required_snapshot=FALSE,
  submitted_by=CASE WHEN status='POSTED' THEN COALESCE(posted_by,created_by) END,
  submitted_at=CASE WHEN status='POSTED' THEN COALESCE(posted_at,created_at) END,
  approved_by=CASE WHEN status='POSTED' THEN posted_by END,
  approved_at=CASE WHEN status='POSTED' THEN posted_at END
WHERE journal_type='MANUAL';
ALTER TABLE public.finance_journals ENABLE TRIGGER g6_guard_finance_journal;

ALTER TABLE public.finance_journals
  ADD CONSTRAINT finance_journals_manual_workflow_check CHECK(
    (journal_type<>'MANUAL' AND manual_workflow_status IS NULL
      AND manual_approval_required_snapshot IS NULL
      AND submitted_by IS NULL AND submitted_at IS NULL
      AND approved_by IS NULL AND approved_at IS NULL)
    OR
    (journal_type='MANUAL'
      AND manual_workflow_status IN('DRAFT','PENDING_APPROVAL','APPROVED','CANCELED')
      AND manual_approval_required_snapshot IS NOT NULL
      AND (manual_workflow_status<>'PENDING_APPROVAL'
        OR (status='DRAFT' AND submitted_by IS NOT NULL AND submitted_at IS NOT NULL
          AND manual_approval_required_snapshot))
      AND (manual_workflow_status<>'APPROVED'
        OR (status='POSTED' AND submitted_by IS NOT NULL AND submitted_at IS NOT NULL
          AND approved_by IS NOT NULL AND approved_at IS NOT NULL))
      AND (manual_workflow_status<>'CANCELED' OR status='CANCELED'))
  ) NOT VALID,
  ADD CONSTRAINT finance_journals_manual_reference_check CHECK(
    external_reference IS NULL OR btrim(external_reference)<>''
  ) NOT VALID,
  ADD CONSTRAINT finance_journals_manual_evidence_check CHECK(
    evidence_url IS NULL OR evidence_url~'^https://'
  ) NOT VALID;
ALTER TABLE public.finance_journals
  VALIDATE CONSTRAINT finance_journals_manual_workflow_check;
ALTER TABLE public.finance_journals
  VALIDATE CONSTRAINT finance_journals_manual_reference_check;
ALTER TABLE public.finance_journals
  VALIDATE CONSTRAINT finance_journals_manual_evidence_check;

ALTER TABLE public.finance_journal_audit
  DROP CONSTRAINT finance_journal_audit_action_check;
ALTER TABLE public.finance_journal_audit
  ADD CONSTRAINT finance_journal_audit_action_check CHECK(action IN(
    'CREATE','SAVE_DRAFT','SUBMIT','APPROVE','LOCK','REOPEN','POST','CANCEL','REVERSE'
  ));

CREATE TABLE private.manual_finance_journal_operations(
  company_id UUID NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
  operation_key UUID NOT NULL,
  action TEXT NOT NULL CHECK(action IN('SAVE','SUBMIT','APPROVE','CANCEL','SAVE_POLICY')),
  journal_id UUID,
  payload_hash TEXT NOT NULL,
  result JSONB NOT NULL,
  actor_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY(company_id,operation_key),
  CONSTRAINT manual_journal_operation_hash_check CHECK(payload_hash~'^[0-9a-f]{32}$'),
  CONSTRAINT fk_manual_journal_operation_journal FOREIGN KEY(company_id,journal_id)
    REFERENCES public.finance_journals(company_id,id) ON DELETE RESTRICT
);
REVOKE ALL ON private.manual_finance_journal_operations FROM PUBLIC,anon,authenticated;
GRANT ALL ON private.manual_finance_journal_operations TO service_role;

INSERT INTO public.access_permission_catalog(
  permission_key,module_key,permission_label,description,view_roles,
  operator_roles,approver_roles,supported_capabilities,required_any_features,
  is_customizable,enforcement_status
) VALUES(
  'finance.manual_journals','FINANCE','Jurnal Manual',
  'Draft, submit, approval, posting, pembatalan, dan reversal Jurnal Manual',
  ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE','ACCOUNTING'],
  ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE'],
  ARRAY['COMPANY_OWNER','COMPANY_ADMIN'],
  ARRAY['VIEW','CREATE_DRAFT','EDIT_DRAFT','APPROVE','POST','CANCEL_FINAL','REVERSE'],
  '{}',TRUE,'ENFORCED'
);

CREATE FUNCTION private.trg_manual_finance_journal_workflow_guard()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
  IF TG_OP='INSERT' AND NEW.journal_type='MANUAL' THEN
    IF NEW.status<>'DRAFT' OR NEW.manual_workflow_status<>'DRAFT'
       OR NEW.manual_approval_required_snapshot IS NULL THEN
      RAISE EXCEPTION 'MANUAL_JOURNAL_MUST_START_DRAFT';
    END IF;
  ELSIF TG_OP='UPDATE' AND OLD.journal_type='MANUAL' THEN
    IF NEW.journal_type IS DISTINCT FROM OLD.journal_type
       OR NEW.manual_approval_required_snapshot IS DISTINCT FROM OLD.manual_approval_required_snapshot THEN
      RAISE EXCEPTION 'MANUAL_JOURNAL_IDENTITY_IMMUTABLE';
    END IF;
    IF OLD.manual_workflow_status='PENDING_APPROVAL' THEN
      IF NEW.accounting_date IS DISTINCT FROM OLD.accounting_date
         OR NEW.accounting_period_id IS DISTINCT FROM OLD.accounting_period_id
         OR NEW.description IS DISTINCT FROM OLD.description
         OR NEW.external_reference IS DISTINCT FROM OLD.external_reference
         OR NEW.evidence_url IS DISTINCT FROM OLD.evidence_url
         OR NEW.total_debit IS DISTINCT FROM OLD.total_debit
         OR NEW.total_credit IS DISTINCT FROM OLD.total_credit THEN
        RAISE EXCEPTION 'PENDING_MANUAL_JOURNAL_IMMUTABLE';
      END IF;
      IF NOT (
        (NEW.status='POSTED' AND NEW.manual_workflow_status='APPROVED') OR
        (NEW.status='CANCELED' AND NEW.manual_workflow_status='CANCELED') OR
        (NEW.status='DRAFT' AND NEW.manual_workflow_status='PENDING_APPROVAL')
      ) THEN RAISE EXCEPTION 'MANUAL_JOURNAL_WORKFLOW_TRANSITION_INVALID'; END IF;
    END IF;
  END IF;
  RETURN NEW;
END
$$;
CREATE TRIGGER b_manual_finance_journal_workflow_guard
BEFORE INSERT OR UPDATE ON public.finance_journals
FOR EACH ROW EXECUTE FUNCTION private.trg_manual_finance_journal_workflow_guard();

CREATE OR REPLACE FUNCTION private.trg_g6_guard_finance_journal_line()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE
  v_company uuid;v_journal uuid;v_status text;v_journal_type text;
  v_manual_status text;v_reversal_of uuid;v_system_event_key text;
  v_account public.chart_of_accounts%rowtype;
  v_original_line public.finance_journal_lines%rowtype;
BEGIN
  IF TG_OP='DELETE' THEN v_company:=OLD.company_id;v_journal:=OLD.journal_id;
  ELSE v_company:=NEW.company_id;v_journal:=NEW.journal_id;END IF;
  IF TG_OP='UPDATE' AND (NEW.id IS DISTINCT FROM OLD.id
    OR NEW.company_id IS DISTINCT FROM OLD.company_id
    OR NEW.journal_id IS DISTINCT FROM OLD.journal_id) THEN
    RAISE EXCEPTION 'FINANCE_JOURNAL_LINE_IDENTITY_IMMUTABLE';
  END IF;
  SELECT journal.status,journal.journal_type,journal.manual_workflow_status,
    journal.reversal_of_journal_id,journal.system_event_key
  INTO v_status,v_journal_type,v_manual_status,v_reversal_of,v_system_event_key
  FROM public.finance_journals journal
  WHERE journal.company_id=v_company AND journal.id=v_journal FOR UPDATE;
  IF v_status IS NULL THEN RAISE EXCEPTION 'FINANCE_JOURNAL_NOT_FOUND'; END IF;
  IF v_status<>'DRAFT' THEN RAISE EXCEPTION 'POSTED_JOURNAL_IMMUTABLE'; END IF;
  IF v_journal_type='MANUAL' AND v_manual_status<>'DRAFT'
     AND NOT (TG_OP='UPDATE' AND NEW IS NOT DISTINCT FROM OLD) THEN
    RAISE EXCEPTION 'PENDING_MANUAL_JOURNAL_IMMUTABLE';
  END IF;
  IF TG_OP='DELETE' THEN RETURN OLD; END IF;
  IF v_journal_type='REVERSAL' THEN
    SELECT original_line.* INTO v_original_line
    FROM public.finance_journal_lines original_line
    JOIN public.finance_journals original_journal
      ON original_journal.company_id=original_line.company_id
     AND original_journal.id=original_line.journal_id
    WHERE original_line.company_id=NEW.company_id
      AND original_line.journal_id=v_reversal_of
      AND original_line.line_no=NEW.line_no
      AND original_line.account_id=NEW.account_id
      AND original_journal.status='POSTED'
      AND (original_journal.journal_type IN('MANUAL','OPENING_BALANCE')
        OR (v_system_event_key='BACKOFFICE_CUSTOMER_REFUND'
          AND original_journal.system_event_key='BACKOFFICE_CUSTOMER_REFUND'
          AND original_journal.journal_type IN('AUTOMATIC','PRIOR_PERIOD_ADJUSTMENT')));
    IF NOT FOUND THEN RAISE EXCEPTION 'REVERSAL_LINE_SOURCE_MISMATCH'; END IF;
    NEW.account_code_snapshot:=v_original_line.account_code_snapshot;
    NEW.account_name_snapshot:=v_original_line.account_name_snapshot;
    NEW.account_function_key_snapshot:=v_original_line.account_function_key_snapshot;
    NEW.normal_balance_snapshot:=v_original_line.normal_balance_snapshot;
    NEW.debit:=v_original_line.credit;NEW.credit:=v_original_line.debit;
    NEW.store_id:=v_original_line.store_id;NEW.warehouse_id:=v_original_line.warehouse_id;
    NEW.customer_id:=v_original_line.customer_id;NEW.supplier_id:=v_original_line.supplier_id;
    RETURN NEW;
  END IF;
  SELECT * INTO v_account FROM public.chart_of_accounts account
  WHERE account.company_id=NEW.company_id AND account.id=NEW.account_id;
  IF NOT FOUND OR NOT v_account.is_active OR NOT v_account.is_postable THEN
    RAISE EXCEPTION 'ACTIVE_POSTABLE_ACCOUNT_REQUIRED';
  END IF;
  IF v_journal_type='MANUAL' AND NOT v_account.allow_manual_posting THEN
    RAISE EXCEPTION 'MANUAL_POSTING_ACCOUNT_NOT_ALLOWED';
  END IF;
  NEW.account_code_snapshot:=v_account.account_code;
  NEW.account_name_snapshot:=v_account.account_name;
  NEW.account_function_key_snapshot:=v_account.system_function_key;
  NEW.normal_balance_snapshot:=v_account.normal_balance;
  RETURN NEW;
END
$$;

CREATE FUNCTION private.manual_journal_result(p_journal public.finance_journals)
RETURNS JSONB LANGUAGE sql STABLE SET search_path=public,pg_temp AS $$
  SELECT jsonb_build_object('journalId',p_journal.id,'displayNo',p_journal.display_no,
    'status',p_journal.status,'workflowStatus',p_journal.manual_workflow_status,
    'masterVersion',p_journal.master_version,
    'approvalRequired',p_journal.manual_approval_required_snapshot)
$$;

CREATE FUNCTION private.manual_journal_operation_retry(
  p_company UUID,p_key UUID,p_action TEXT,p_hash TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,private,pg_temp AS $$
DECLARE v_operation private.manual_finance_journal_operations%ROWTYPE;
BEGIN
  SELECT * INTO v_operation FROM private.manual_finance_journal_operations
  WHERE company_id=p_company AND operation_key=p_key;
  IF NOT FOUND THEN RETURN NULL; END IF;
  IF v_operation.action<>p_action OR v_operation.payload_hash<>p_hash THEN
    RAISE EXCEPTION 'MANUAL_JOURNAL_IDEMPOTENCY_CONFLICT';
  END IF;
  RETURN v_operation.result;
END
$$;

CREATE FUNCTION public.get_manual_finance_journal_context()
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,private,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
  v_permission jsonb;v_policy public.finance_company_policies%rowtype;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
  v_permission:=private.acp_resolve_permission(
    v_company,v_actor,'finance.manual_journals');
  INSERT INTO public.finance_company_policies(company_id,created_by,updated_by)
  VALUES(v_company,v_actor,v_actor) ON CONFLICT(company_id) DO NOTHING;
  SELECT * INTO v_policy FROM public.finance_company_policies
  WHERE company_id=v_company FOR SHARE;
  RETURN jsonb_build_object('approvalRequired',v_policy.manual_journal_approval_required,
    'policyMasterVersion',v_policy.master_version,
    'capabilities',v_permission->'effectiveCapabilities');
END
$$;

CREATE FUNCTION public.save_manual_finance_journal_draft(
  p_journal_id UUID,p_expected_master_version BIGINT,p_operation_key UUID,
  p_accounting_date DATE,p_external_reference TEXT,p_description TEXT,
  p_evidence_url TEXT,p_lines JSONB
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,private,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
  v_policy public.finance_company_policies%rowtype;v_period public.accounting_periods%rowtype;
  v_journal public.finance_journals%rowtype;v_line jsonb;v_account uuid;
  v_debit numeric(20,4);v_credit numeric(20,4);v_line_no int:=0;
  v_total_debit numeric(20,4):=0;v_total_credit numeric(20,4):=0;
  v_payload_hash text;v_retry jsonb;v_result jsonb;v_timezone text;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
  PERFORM private.acp_require_permission_capability(v_company,'finance.manual_journals',
    CASE WHEN p_journal_id IS NULL THEN 'CREATE_DRAFT' ELSE 'EDIT_DRAFT' END);
  IF p_operation_key IS NULL THEN RAISE EXCEPTION 'OPERATION_KEY_REQUIRED'; END IF;
  IF p_accounting_date IS NULL THEN RAISE EXCEPTION 'ACCOUNTING_DATE_REQUIRED'; END IF;
  IF btrim(coalesce(p_description,''))='' THEN RAISE EXCEPTION 'JOURNAL_DESCRIPTION_REQUIRED'; END IF;
  IF length(btrim(p_description))>1000 THEN RAISE EXCEPTION 'JOURNAL_DESCRIPTION_TOO_LONG'; END IF;
  IF p_external_reference IS NOT NULL AND (btrim(p_external_reference)=''
    OR length(btrim(p_external_reference))>200) THEN RAISE EXCEPTION 'EXTERNAL_REFERENCE_INVALID'; END IF;
  IF p_evidence_url IS NOT NULL AND (p_evidence_url!~'^https://' OR length(p_evidence_url)>2000)
    THEN RAISE EXCEPTION 'EVIDENCE_URL_INVALID'; END IF;
  IF jsonb_typeof(p_lines)<>'array' OR jsonb_array_length(p_lines)<2
    OR jsonb_array_length(p_lines)>100 THEN RAISE EXCEPTION 'JOURNAL_LINES_INVALID'; END IF;
  v_payload_hash:=md5(jsonb_build_object('journalId',p_journal_id,'version',p_expected_master_version,
    'date',p_accounting_date,'reference',p_external_reference,'description',btrim(p_description),
    'evidence',p_evidence_url,'lines',p_lines)::text);
  PERFORM pg_advisory_xact_lock(hashtextextended(
    'MANUAL_JOURNAL_OPERATION|'||v_company::text||'|'||p_operation_key::text,0));
  v_retry:=private.manual_journal_operation_retry(v_company,p_operation_key,'SAVE',v_payload_hash);
  IF v_retry IS NOT NULL THEN RETURN v_retry; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('MANUAL_JOURNAL|'||v_company::text,0));
  INSERT INTO public.finance_company_policies(company_id,created_by,updated_by)
  VALUES(v_company,v_actor,v_actor) ON CONFLICT(company_id) DO NOTHING;
  SELECT * INTO v_policy FROM public.finance_company_policies
  WHERE company_id=v_company FOR SHARE;
  SELECT timezone INTO v_timezone FROM public.companies WHERE id=v_company AND status='ACTIVE';
  IF v_timezone IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_NOT_FOUND'; END IF;
  PERFORM private.ensure_company_accounting_periods(v_company,p_accounting_date,v_actor);
  SELECT * INTO v_period FROM public.accounting_periods period
  WHERE period.company_id=v_company AND p_accounting_date BETWEEN period.start_date AND period.end_date
    AND period.status IN('OPEN','REOPENED') FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'ACCOUNTING_PERIOD_NOT_OPEN_FOR_MANUAL_JOURNAL'; END IF;
  IF p_journal_id IS NULL THEN
    v_journal.id:=gen_random_uuid();
    INSERT INTO public.finance_journals(id,company_id,journal_no,journal_type,
      accounting_period_id,accounting_date,source_type,source_id,idempotency_key,
      description,status,created_by,manual_workflow_status,
      manual_approval_required_snapshot,external_reference,evidence_url)
    VALUES(v_journal.id,v_company,'MAN-'||replace(v_journal.id::text,'-',''),'MANUAL',
      v_period.id,p_accounting_date,'MANUAL_JOURNAL',v_journal.id,
      'MANUAL_JOURNAL|'||p_operation_key::text,btrim(p_description),'DRAFT',v_actor,
      'DRAFT',v_policy.manual_journal_approval_required,
      nullif(btrim(p_external_reference),''),p_evidence_url)
    RETURNING * INTO v_journal;
  ELSE
    SELECT * INTO v_journal FROM public.finance_journals journal
    WHERE journal.company_id=v_company AND journal.id=p_journal_id FOR UPDATE;
    IF NOT FOUND OR v_journal.journal_type<>'MANUAL' THEN RAISE EXCEPTION 'MANUAL_JOURNAL_NOT_FOUND'; END IF;
    IF v_journal.status<>'DRAFT' OR v_journal.manual_workflow_status<>'DRAFT' THEN
      RAISE EXCEPTION 'MANUAL_JOURNAL_EDIT_NOT_ALLOWED'; END IF;
    IF p_expected_master_version IS NULL OR p_expected_master_version<>v_journal.master_version THEN
      RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
    DELETE FROM public.finance_journal_lines WHERE company_id=v_company AND journal_id=v_journal.id;
    UPDATE public.finance_journals SET accounting_period_id=v_period.id,
      accounting_date=p_accounting_date,description=btrim(p_description),
      external_reference=nullif(btrim(p_external_reference),''),evidence_url=p_evidence_url
    WHERE company_id=v_company AND id=v_journal.id RETURNING * INTO v_journal;
  END IF;
  FOR v_line IN SELECT value FROM jsonb_array_elements(p_lines) LOOP
    v_line_no:=v_line_no+1;
    BEGIN
      v_account:=(v_line->>'accountId')::uuid;
      v_debit:=coalesce(nullif(v_line->>'debit','')::numeric,0);
      v_credit:=coalesce(nullif(v_line->>'credit','')::numeric,0);
    EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN
      RAISE EXCEPTION 'JOURNAL_LINE_VALUE_INVALID';
    END;
    IF v_account IS NULL OR v_debit<0 OR v_credit<0
       OR NOT((v_debit>0 AND v_credit=0) OR (v_credit>0 AND v_debit=0)) THEN
      RAISE EXCEPTION 'JOURNAL_LINE_VALUE_INVALID'; END IF;
    IF length(coalesce(v_line->>'description',''))>500 THEN
      RAISE EXCEPTION 'JOURNAL_LINE_DESCRIPTION_TOO_LONG'; END IF;
    INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,account_id,
      account_code_snapshot,account_name_snapshot,normal_balance_snapshot,debit,credit,description)
    VALUES(v_company,v_journal.id,v_line_no,v_account,'PENDING','PENDING','DEBIT',
      round(v_debit,4),round(v_credit,4),nullif(btrim(v_line->>'description'),''));
    v_total_debit:=v_total_debit+round(v_debit,4);v_total_credit:=v_total_credit+round(v_credit,4);
  END LOOP;
  IF v_total_debit<=0 OR v_total_debit<>v_total_credit THEN RAISE EXCEPTION 'JOURNAL_UNBALANCED'; END IF;
  UPDATE public.finance_journals SET total_debit=v_total_debit,total_credit=v_total_credit
  WHERE company_id=v_company AND id=v_journal.id RETURNING * INTO v_journal;
  INSERT INTO public.finance_journal_audit(company_id,entity_type,entity_id,action,
    actor_id,after_state) VALUES(v_company,'JOURNAL',v_journal.id,'SAVE_DRAFT',v_actor,to_jsonb(v_journal));
  v_result:=private.manual_journal_result(v_journal);
  INSERT INTO private.manual_finance_journal_operations(company_id,operation_key,action,
    journal_id,payload_hash,result,actor_id)
  VALUES(v_company,p_operation_key,'SAVE',v_journal.id,v_payload_hash,v_result,v_actor);
  RETURN v_result;
END
$$;

CREATE FUNCTION private.validate_manual_finance_journal_for_posting(
  p_company uuid,p_journal uuid
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_invalid bigint;v_count bigint;v_debit numeric;v_credit numeric;
BEGIN
  SELECT count(*),coalesce(sum(line.debit),0),coalesce(sum(line.credit),0),
    count(*) FILTER(WHERE NOT account.is_active OR NOT account.is_postable
      OR NOT account.allow_manual_posting)
  INTO v_count,v_debit,v_credit,v_invalid
  FROM public.finance_journal_lines line
  JOIN public.chart_of_accounts account ON account.company_id=line.company_id AND account.id=line.account_id
  WHERE line.company_id=p_company AND line.journal_id=p_journal;
  IF v_count<2 THEN RAISE EXCEPTION 'JOURNAL_MINIMUM_TWO_LINES_REQUIRED'; END IF;
  IF v_debit<=0 OR round(v_debit,4)<>round(v_credit,4) THEN RAISE EXCEPTION 'JOURNAL_UNBALANCED'; END IF;
  IF v_invalid>0 THEN RAISE EXCEPTION 'MANUAL_POSTING_ACCOUNT_NOT_ALLOWED'; END IF;
END
$$;

CREATE FUNCTION public.submit_manual_finance_journal(
  p_journal_id UUID,p_expected_master_version BIGINT,p_operation_key UUID
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,private,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
  v_journal public.finance_journals%rowtype;v_hash text;v_retry jsonb;v_result jsonb;
BEGIN
  IF v_actor IS NULL OR v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_AUTH_CONTEXT_REQUIRED'; END IF;
  PERFORM private.acp_require_permission_capability(v_company,'finance.manual_journals','EDIT_DRAFT');
  IF p_operation_key IS NULL THEN RAISE EXCEPTION 'OPERATION_KEY_REQUIRED'; END IF;
  v_hash:=md5(jsonb_build_object('journalId',p_journal_id,'version',p_expected_master_version)::text);
  PERFORM pg_advisory_xact_lock(hashtextextended(
    'MANUAL_JOURNAL_OPERATION|'||v_company::text||'|'||p_operation_key::text,0));
  v_retry:=private.manual_journal_operation_retry(v_company,p_operation_key,'SUBMIT',v_hash);
  IF v_retry IS NOT NULL THEN RETURN v_retry; END IF;
  SELECT * INTO v_journal FROM public.finance_journals WHERE company_id=v_company AND id=p_journal_id FOR UPDATE;
  IF NOT FOUND OR v_journal.journal_type<>'MANUAL' THEN RAISE EXCEPTION 'MANUAL_JOURNAL_NOT_FOUND'; END IF;
  IF v_journal.master_version<>p_expected_master_version THEN RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
  IF v_journal.status<>'DRAFT' OR v_journal.manual_workflow_status<>'DRAFT' THEN RAISE EXCEPTION 'MANUAL_JOURNAL_SUBMIT_NOT_ALLOWED'; END IF;
  PERFORM private.validate_manual_finance_journal_for_posting(v_company,v_journal.id);
  IF v_journal.manual_approval_required_snapshot THEN
    UPDATE public.finance_journals SET manual_workflow_status='PENDING_APPROVAL',
      submitted_by=v_actor,submitted_at=clock_timestamp()
    WHERE company_id=v_company AND id=v_journal.id RETURNING * INTO v_journal;
  ELSE
    UPDATE public.finance_journals SET manual_workflow_status='APPROVED',
      submitted_by=v_actor,submitted_at=clock_timestamp(),approved_by=v_actor,
      approved_at=clock_timestamp(),posted_by=v_actor,status='POSTED'
    WHERE company_id=v_company AND id=v_journal.id RETURNING * INTO v_journal;
  END IF;
  INSERT INTO public.finance_journal_audit(company_id,entity_type,entity_id,action,actor_id,
    after_state) VALUES(v_company,'JOURNAL',v_journal.id,'SUBMIT',v_actor,to_jsonb(v_journal));
  v_result:=private.manual_journal_result(v_journal);
  INSERT INTO private.manual_finance_journal_operations VALUES(
    v_company,p_operation_key,'SUBMIT',v_journal.id,v_hash,v_result,v_actor,clock_timestamp());
  RETURN v_result;
END
$$;

CREATE FUNCTION public.approve_manual_finance_journal(
  p_journal_id UUID,p_expected_master_version BIGINT,p_operation_key UUID
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,private,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
  v_journal public.finance_journals%rowtype;v_hash text;v_retry jsonb;v_result jsonb;
BEGIN
  IF v_actor IS NULL OR v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_AUTH_CONTEXT_REQUIRED'; END IF;
  PERFORM private.acp_require_permission_capability(v_company,'finance.manual_journals','APPROVE');
  IF p_operation_key IS NULL THEN RAISE EXCEPTION 'OPERATION_KEY_REQUIRED'; END IF;
  v_hash:=md5(jsonb_build_object('journalId',p_journal_id,'version',p_expected_master_version)::text);
  PERFORM pg_advisory_xact_lock(hashtextextended(
    'MANUAL_JOURNAL_OPERATION|'||v_company::text||'|'||p_operation_key::text,0));
  v_retry:=private.manual_journal_operation_retry(v_company,p_operation_key,'APPROVE',v_hash);
  IF v_retry IS NOT NULL THEN RETURN v_retry; END IF;
  SELECT * INTO v_journal FROM public.finance_journals WHERE company_id=v_company AND id=p_journal_id FOR UPDATE;
  IF NOT FOUND OR v_journal.journal_type<>'MANUAL' THEN RAISE EXCEPTION 'MANUAL_JOURNAL_NOT_FOUND'; END IF;
  IF v_journal.master_version<>p_expected_master_version THEN RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
  IF v_journal.status<>'DRAFT' OR v_journal.manual_workflow_status<>'PENDING_APPROVAL' THEN RAISE EXCEPTION 'MANUAL_JOURNAL_APPROVAL_NOT_ALLOWED'; END IF;
  IF v_journal.submitted_by=v_actor THEN RAISE EXCEPTION 'MANUAL_JOURNAL_SELF_APPROVAL_FORBIDDEN'; END IF;
  PERFORM private.validate_manual_finance_journal_for_posting(v_company,v_journal.id);
  UPDATE public.finance_journals SET manual_workflow_status='APPROVED',approved_by=v_actor,
    approved_at=clock_timestamp(),posted_by=v_actor,status='POSTED'
  WHERE company_id=v_company AND id=v_journal.id RETURNING * INTO v_journal;
  INSERT INTO public.finance_journal_audit(company_id,entity_type,entity_id,action,actor_id,
    after_state) VALUES(v_company,'JOURNAL',v_journal.id,'APPROVE',v_actor,to_jsonb(v_journal));
  v_result:=private.manual_journal_result(v_journal);
  INSERT INTO private.manual_finance_journal_operations VALUES(
    v_company,p_operation_key,'APPROVE',v_journal.id,v_hash,v_result,v_actor,clock_timestamp());
  RETURN v_result;
END
$$;

CREATE FUNCTION public.cancel_manual_finance_journal(
  p_journal_id UUID,p_expected_master_version BIGINT,p_reason TEXT,p_operation_key UUID
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,private,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
  v_journal public.finance_journals%rowtype;v_hash text;v_retry jsonb;v_result jsonb;
BEGIN
  IF v_actor IS NULL OR v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_AUTH_CONTEXT_REQUIRED'; END IF;
  PERFORM private.acp_require_permission_capability(v_company,'finance.manual_journals','CANCEL_FINAL');
  IF p_operation_key IS NULL THEN RAISE EXCEPTION 'OPERATION_KEY_REQUIRED'; END IF;
  IF btrim(coalesce(p_reason,''))='' THEN RAISE EXCEPTION 'CANCEL_REASON_REQUIRED'; END IF;
  v_hash:=md5(jsonb_build_object('journalId',p_journal_id,'version',p_expected_master_version,'reason',btrim(p_reason))::text);
  PERFORM pg_advisory_xact_lock(hashtextextended(
    'MANUAL_JOURNAL_OPERATION|'||v_company::text||'|'||p_operation_key::text,0));
  v_retry:=private.manual_journal_operation_retry(v_company,p_operation_key,'CANCEL',v_hash);
  IF v_retry IS NOT NULL THEN RETURN v_retry; END IF;
  SELECT * INTO v_journal FROM public.finance_journals WHERE company_id=v_company AND id=p_journal_id FOR UPDATE;
  IF NOT FOUND OR v_journal.journal_type<>'MANUAL' THEN RAISE EXCEPTION 'MANUAL_JOURNAL_NOT_FOUND'; END IF;
  IF v_journal.master_version<>p_expected_master_version THEN RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
  IF v_journal.status<>'DRAFT' OR v_journal.manual_workflow_status NOT IN('DRAFT','PENDING_APPROVAL') THEN RAISE EXCEPTION 'MANUAL_JOURNAL_CANCEL_NOT_ALLOWED'; END IF;
  UPDATE public.finance_journals SET manual_workflow_status='CANCELED',status='CANCELED',
    canceled_by=v_actor,canceled_at=clock_timestamp(),cancel_reason=btrim(p_reason)
  WHERE company_id=v_company AND id=v_journal.id RETURNING * INTO v_journal;
  v_result:=private.manual_journal_result(v_journal);
  INSERT INTO private.manual_finance_journal_operations VALUES(
    v_company,p_operation_key,'CANCEL',v_journal.id,v_hash,v_result,v_actor,clock_timestamp());
  RETURN v_result;
END
$$;

CREATE FUNCTION public.save_manual_journal_approval_policy(
  p_expected_master_version BIGINT,p_approval_required BOOLEAN,p_operation_key UUID
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,private,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
  v_policy public.finance_company_policies%rowtype;v_before jsonb;v_hash text;v_retry jsonb;v_result jsonb;
BEGIN
  IF v_actor IS NULL OR v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_AUTH_CONTEXT_REQUIRED'; END IF;
  PERFORM private.acp_require_permission_capability(v_company,'finance.manual_journals','APPROVE');
  IF p_approval_required IS NULL OR p_operation_key IS NULL THEN RAISE EXCEPTION 'MANUAL_JOURNAL_POLICY_INPUT_REQUIRED'; END IF;
  v_hash:=md5(jsonb_build_object('version',p_expected_master_version,'approvalRequired',p_approval_required)::text);
  PERFORM pg_advisory_xact_lock(hashtextextended(
    'MANUAL_JOURNAL_OPERATION|'||v_company::text||'|'||p_operation_key::text,0));
  v_retry:=private.manual_journal_operation_retry(v_company,p_operation_key,'SAVE_POLICY',v_hash);
  IF v_retry IS NOT NULL THEN RETURN v_retry; END IF;
  SELECT * INTO v_policy FROM public.finance_company_policies WHERE company_id=v_company FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'FINANCE_COMPANY_POLICY_NOT_FOUND'; END IF;
  IF v_policy.master_version<>p_expected_master_version THEN RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
  v_before:=to_jsonb(v_policy);
  UPDATE public.finance_company_policies SET manual_journal_approval_required=p_approval_required,
    master_version=master_version+1,updated_by=v_actor,updated_at=clock_timestamp()
  WHERE company_id=v_company RETURNING * INTO v_policy;
  INSERT INTO public.finance_company_policy_audit(company_id,action,actor_id,before_state,after_state)
  VALUES(v_company,'UPDATE',v_actor,v_before,to_jsonb(v_policy));
  v_result:=jsonb_build_object('approvalRequired',v_policy.manual_journal_approval_required,
    'masterVersion',v_policy.master_version);
  INSERT INTO private.manual_finance_journal_operations(company_id,operation_key,action,
    payload_hash,result,actor_id) VALUES(v_company,p_operation_key,'SAVE_POLICY',v_hash,v_result,v_actor);
  RETURN v_result;
END
$$;

REVOKE ALL ON FUNCTION private.trg_manual_finance_journal_workflow_guard(),
  private.manual_journal_result(public.finance_journals),
  private.manual_journal_operation_retry(UUID,UUID,TEXT,TEXT),
  private.validate_manual_finance_journal_for_posting(UUID,UUID)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.trg_manual_finance_journal_workflow_guard(),
  private.manual_journal_result(public.finance_journals),
  private.manual_journal_operation_retry(UUID,UUID,TEXT,TEXT),
  private.validate_manual_finance_journal_for_posting(UUID,UUID)
TO service_role;

REVOKE ALL ON FUNCTION public.get_manual_finance_journal_context(),
  public.save_manual_finance_journal_draft(UUID,BIGINT,UUID,DATE,TEXT,TEXT,TEXT,JSONB),
  public.submit_manual_finance_journal(UUID,BIGINT,UUID),
  public.approve_manual_finance_journal(UUID,BIGINT,UUID),
  public.cancel_manual_finance_journal(UUID,BIGINT,TEXT,UUID),
  public.save_manual_journal_approval_policy(BIGINT,BOOLEAN,UUID)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_manual_finance_journal_context(),
  public.save_manual_finance_journal_draft(UUID,BIGINT,UUID,DATE,TEXT,TEXT,TEXT,JSONB),
  public.submit_manual_finance_journal(UUID,BIGINT,UUID),
  public.approve_manual_finance_journal(UUID,BIGINT,UUID),
  public.cancel_manual_finance_journal(UUID,BIGINT,TEXT,UUID),
  public.save_manual_journal_approval_policy(BIGINT,BOOLEAN,UUID)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260919120000','manual_finance_journal_runtime',
  'Manual Journal draft, default-on maker-checker approval, guarded posting/cancel, immutable audit, idempotent mutations and tenant permissions; automatic Finance/POS/Stock runtime unchanged');

NOTIFY pgrst,'reload schema';
COMMIT;
