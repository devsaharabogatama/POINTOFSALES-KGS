-- Direct in-application Opening Balance document with aggregate party-level AR/AP balances.
-- Production execution is intentionally manual after preflight and review.

BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260919120000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: manual Finance runtime missing';
  END IF;
  IF EXISTS (SELECT 1 FROM private.kgs_schema_migrations WHERE version='20261029100000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20261029100000';
  END IF;
  IF to_regclass('public.finance_journals') IS NULL
     OR to_regclass('public.finance_journal_lines') IS NULL
     OR to_regclass('public.accounting_periods') IS NULL
     OR to_regclass('public.customers') IS NULL
     OR to_regclass('public.suppliers') IS NULL
     OR to_regprocedure('private.acp_require_permission_capability(uuid,text,text)') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical Finance dependency changed';
  END IF;
END
$guard$;

CREATE SEQUENCE private.opening_balance_no_seq AS bigint START 1;
REVOKE ALL ON SEQUENCE private.opening_balance_no_seq FROM PUBLIC,anon,authenticated;
GRANT USAGE,SELECT ON SEQUENCE private.opening_balance_no_seq TO service_role;

CREATE TABLE public.opening_balance_documents(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
  document_no text NOT NULL,
  effective_date date NOT NULL,
  external_reference text,
  description text NOT NULL,
  status text NOT NULL DEFAULT 'DRAFT',
  total_debit numeric(20,4) NOT NULL DEFAULT 0,
  total_credit numeric(20,4) NOT NULL DEFAULT 0,
  journal_id uuid,
  posting_idempotency_key uuid,
  master_version bigint NOT NULL DEFAULT 1,
  created_by uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  submitted_by uuid REFERENCES public.profiles(id) ON DELETE RESTRICT,
  posted_by uuid REFERENCES public.profiles(id) ON DELETE RESTRICT,
  canceled_by uuid REFERENCES public.profiles(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  submitted_at timestamptz,
  posted_at timestamptz,
  canceled_at timestamptz,
  cancel_reason text,
  CONSTRAINT opening_balance_document_company_id_id_unique UNIQUE(company_id,id),
  CONSTRAINT opening_balance_document_company_no_unique UNIQUE(company_id,document_no),
  CONSTRAINT opening_balance_document_posting_key_unique UNIQUE(company_id,posting_idempotency_key),
  CONSTRAINT opening_balance_document_status_check CHECK(status IN('DRAFT','SUBMITTED','POSTED','CANCELED')),
  CONSTRAINT opening_balance_document_amount_check CHECK(total_debit>=0 AND total_credit>=0),
  CONSTRAINT opening_balance_document_text_check CHECK(
    nullif(btrim(document_no),'') IS NOT NULL
    AND nullif(btrim(description),'') IS NOT NULL
    AND (external_reference IS NULL OR nullif(btrim(external_reference),'') IS NOT NULL)
  ),
  CONSTRAINT opening_balance_document_version_check CHECK(master_version>0),
  CONSTRAINT opening_balance_document_lifecycle_check CHECK(
    (status='DRAFT' AND submitted_at IS NULL AND posted_at IS NULL AND canceled_at IS NULL AND journal_id IS NULL)
    OR (status='SUBMITTED' AND submitted_by IS NOT NULL AND submitted_at IS NOT NULL
        AND posted_at IS NULL AND canceled_at IS NULL AND journal_id IS NULL)
    OR (status='POSTED' AND submitted_by IS NOT NULL AND submitted_at IS NOT NULL
        AND posted_by IS NOT NULL AND posted_at IS NOT NULL AND journal_id IS NOT NULL
        AND posting_idempotency_key IS NOT NULL AND total_debit>0 AND total_debit=total_credit)
    OR (status='CANCELED' AND canceled_by IS NOT NULL AND canceled_at IS NOT NULL
        AND nullif(btrim(cancel_reason),'') IS NOT NULL AND journal_id IS NULL)
  ),
  CONSTRAINT opening_balance_document_journal_fk FOREIGN KEY(company_id,journal_id)
    REFERENCES public.finance_journals(company_id,id) ON DELETE RESTRICT
);

CREATE TABLE public.opening_balance_lines(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL,
  document_id uuid NOT NULL,
  line_no integer NOT NULL,
  line_type text NOT NULL,
  account_id uuid NOT NULL,
  customer_id uuid,
  supplier_id uuid,
  source_document_no text,
  source_document_date date,
  due_date date,
  debit numeric(20,4) NOT NULL DEFAULT 0,
  credit numeric(20,4) NOT NULL DEFAULT 0,
  description text,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT opening_balance_line_company_id_id_unique UNIQUE(company_id,id),
  CONSTRAINT opening_balance_line_number_unique UNIQUE(company_id,document_id,line_no),
  CONSTRAINT opening_balance_line_document_fk FOREIGN KEY(company_id,document_id)
    REFERENCES public.opening_balance_documents(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT opening_balance_line_account_fk FOREIGN KEY(company_id,account_id)
    REFERENCES public.chart_of_accounts(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT opening_balance_line_customer_fk FOREIGN KEY(company_id,customer_id)
    REFERENCES public.customers(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT opening_balance_line_supplier_fk FOREIGN KEY(company_id,supplier_id)
    REFERENCES public.suppliers(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT opening_balance_line_type_check CHECK(line_type IN('GL','RECEIVABLE','PAYABLE')),
  CONSTRAINT opening_balance_line_number_check CHECK(line_no>0),
  CONSTRAINT opening_balance_line_amount_check CHECK(
    (debit>0 AND credit=0) OR (credit>0 AND debit=0)
  ),
  CONSTRAINT opening_balance_line_date_check CHECK(due_date IS NULL OR source_document_date IS NULL OR due_date>=source_document_date),
  CONSTRAINT opening_balance_line_shape_check CHECK(
    (line_type='GL' AND customer_id IS NULL AND supplier_id IS NULL
      AND source_document_no IS NULL AND source_document_date IS NULL AND due_date IS NULL)
    OR (line_type='RECEIVABLE' AND customer_id IS NOT NULL AND supplier_id IS NULL
      AND debit>0 AND credit=0)
    OR (line_type='PAYABLE' AND supplier_id IS NOT NULL AND customer_id IS NULL
      AND credit>0 AND debit=0)
  )
);

CREATE INDEX opening_balance_line_document_idx
  ON public.opening_balance_lines(company_id,document_id,line_no);
CREATE INDEX opening_balance_line_customer_idx
  ON public.opening_balance_lines(company_id,customer_id,due_date)
  WHERE line_type='RECEIVABLE';
CREATE INDEX opening_balance_line_supplier_idx
  ON public.opening_balance_lines(company_id,supplier_id,due_date)
  WHERE line_type='PAYABLE';

CREATE TABLE public.opening_balance_audit(
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
  document_id uuid NOT NULL,
  action text NOT NULL CHECK(action IN('CREATE','UPDATE','SUBMIT','POST','CANCEL')),
  actor_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  before_state jsonb,
  after_state jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT opening_balance_audit_document_fk FOREIGN KEY(company_id,document_id)
    REFERENCES public.opening_balance_documents(company_id,id) ON DELETE RESTRICT
);

CREATE TABLE private.opening_balance_operations(
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
  operation_key uuid NOT NULL,
  action text NOT NULL,
  payload_hash text NOT NULL,
  result jsonb NOT NULL,
  actor_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY(company_id,operation_key)
);

ALTER TABLE public.opening_balance_documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.opening_balance_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.opening_balance_audit ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.opening_balance_documents,public.opening_balance_lines,
  public.opening_balance_audit,private.opening_balance_operations FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.opening_balance_documents,public.opening_balance_lines,
  public.opening_balance_audit,private.opening_balance_operations TO service_role;

CREATE FUNCTION private.opening_balance_control_accounts(p_company uuid,p_function text)
RETURNS TABLE(account_id uuid) LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
  SELECT fallback.account_id
  FROM public.company_account_function_fallbacks fallback
  WHERE fallback.company_id=p_company AND fallback.account_function_key=p_function
    AND fallback.status='ACTIVE' AND fallback.effective_from<=clock_timestamp()
    AND (fallback.effective_to IS NULL OR fallback.effective_to>clock_timestamp())
  UNION
  SELECT rule.account_id
  FROM public.transaction_account_rules rule
  WHERE rule.company_id=p_company AND rule.account_function_key=p_function
    AND rule.status='ACTIVE' AND rule.effective_from<=clock_timestamp()
    AND (rule.effective_to IS NULL OR rule.effective_to>clock_timestamp());
$$;

CREATE FUNCTION private.opening_balance_result(p_document public.opening_balance_documents)
RETURNS jsonb LANGUAGE sql STABLE SET search_path=public,pg_temp AS $$
  SELECT jsonb_build_object('documentId',p_document.id,'documentNo',p_document.document_no,
    'status',p_document.status,'masterVersion',p_document.master_version,
    'totalDebit',p_document.total_debit,'totalCredit',p_document.total_credit,
    'journalId',p_document.journal_id);
$$;

CREATE FUNCTION public.get_opening_balance_workspace()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,private,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_permission jsonb;
BEGIN
  v_permission:=private.acp_require_permission_capability(v_company,'finance.manual_journals','VIEW');
  RETURN jsonb_build_object(
    'companyId',v_company,
    'currentUserId',auth.uid(),
    'capabilities',COALESCE(v_permission->'effectiveCapabilities','[]'::jsonb),
    'documents',(SELECT COALESCE(jsonb_agg(to_jsonb(document) ORDER BY document.created_at DESC),'[]'::jsonb)
      FROM (SELECT * FROM public.opening_balance_documents candidate
        WHERE candidate.company_id=v_company ORDER BY candidate.created_at DESC LIMIT 100) document),
    'lines',(SELECT COALESCE(jsonb_agg(to_jsonb(line) ORDER BY line.document_id,line.line_no),'[]'::jsonb)
      FROM public.opening_balance_lines line WHERE line.company_id=v_company
        AND EXISTS(SELECT 1 FROM public.opening_balance_documents document
          WHERE document.company_id=v_company AND document.id=line.document_id)),
    'accounts',(SELECT COALESCE(jsonb_agg(jsonb_build_object('id',account.id,
      'code',account.account_code,'name',account.account_name,'type',account.account_type)
      ORDER BY account.account_code),'[]'::jsonb) FROM public.chart_of_accounts account
      WHERE account.company_id=v_company AND account.is_active AND account.is_postable),
    'customers',(SELECT COALESCE(jsonb_agg(jsonb_build_object('id',customer.id,
      'code',customer.code,'name',customer.name) ORDER BY customer.name),'[]'::jsonb)
      FROM public.customers customer WHERE customer.company_id=v_company AND customer.is_active
        AND NOT customer.is_system_customer),
    'suppliers',(SELECT COALESCE(jsonb_agg(jsonb_build_object('id',supplier.id,
      'code',supplier.supplier_code,'name',supplier.supplier_name) ORDER BY supplier.supplier_name),'[]'::jsonb)
      FROM public.suppliers supplier WHERE supplier.company_id=v_company AND supplier.is_active),
    'periods',(SELECT COALESCE(jsonb_agg(jsonb_build_object('id',period.id,'startDate',period.start_date,
      'endDate',period.end_date,'status',period.status) ORDER BY period.start_date DESC),'[]'::jsonb)
      FROM public.accounting_periods period WHERE period.company_id=v_company)
  );
END
$$;

CREATE FUNCTION public.save_opening_balance_draft(
  p_document_id uuid,p_master_version bigint,p_operation_key uuid,
  p_effective_date date,p_external_reference text,p_description text,p_lines jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,private,pg_temp SET statement_timeout='20s' AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
  v_document public.opening_balance_documents%rowtype;v_before jsonb;v_line jsonb;
  v_line_no int:=0;v_type text;v_account uuid;v_customer uuid;v_supplier uuid;
  v_debit numeric(20,4);v_credit numeric(20,4);v_total_debit numeric(20,4):=0;
  v_total_credit numeric(20,4):=0;v_hash text;v_existing private.opening_balance_operations%rowtype;
  v_result jsonb;v_is_new boolean:=p_document_id IS NULL;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  PERFORM private.acp_require_permission_capability(v_company,'finance.manual_journals',
    CASE WHEN v_is_new THEN 'CREATE_DRAFT' ELSE 'EDIT_DRAFT' END);
  IF p_operation_key IS NULL THEN RAISE EXCEPTION 'OPERATION_KEY_REQUIRED'; END IF;
  IF p_effective_date IS NULL THEN RAISE EXCEPTION 'OPENING_BALANCE_DATE_REQUIRED'; END IF;
  IF nullif(btrim(p_description),'') IS NULL OR length(btrim(p_description))>1000 THEN
    RAISE EXCEPTION 'OPENING_BALANCE_DESCRIPTION_INVALID'; END IF;
  IF p_external_reference IS NOT NULL AND (nullif(btrim(p_external_reference),'') IS NULL
    OR length(btrim(p_external_reference))>200) THEN RAISE EXCEPTION 'EXTERNAL_REFERENCE_INVALID'; END IF;
  IF jsonb_typeof(p_lines)<>'array' OR jsonb_array_length(p_lines)<2 OR jsonb_array_length(p_lines)>500 THEN
    RAISE EXCEPTION 'OPENING_BALANCE_LINES_INVALID'; END IF;
  v_hash:=md5(jsonb_build_object('documentId',p_document_id,'version',p_master_version,
    'date',p_effective_date,'reference',p_external_reference,'description',btrim(p_description),
    'lines',p_lines)::text);
  PERFORM pg_advisory_xact_lock(hashtextextended('OPENING_BALANCE_OPERATION|'||v_company||'|'||p_operation_key,0));
  SELECT * INTO v_existing FROM private.opening_balance_operations operation
  WHERE operation.company_id=v_company AND operation.operation_key=p_operation_key;
  IF FOUND THEN
    IF v_existing.action<>'SAVE' OR v_existing.payload_hash<>v_hash THEN RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT'; END IF;
    RETURN v_existing.result;
  END IF;
  PERFORM 1 FROM public.accounting_periods period WHERE period.company_id=v_company
    AND p_effective_date BETWEEN period.start_date AND period.end_date
    AND period.status IN('OPEN','REOPENED') FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'OPENING_BALANCE_PERIOD_NOT_OPEN'; END IF;
  IF v_is_new THEN
    INSERT INTO public.opening_balance_documents(company_id,document_no,effective_date,
      external_reference,description,created_by)
    VALUES(v_company,'OB/'||to_char(p_effective_date,'YYYY/MM')||'/'||
      lpad(nextval('private.opening_balance_no_seq')::text,6,'0'),p_effective_date,
      nullif(btrim(p_external_reference),''),btrim(p_description),v_actor)
    RETURNING * INTO v_document;
  ELSE
    SELECT * INTO v_document FROM public.opening_balance_documents document
    WHERE document.company_id=v_company AND document.id=p_document_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'OPENING_BALANCE_NOT_FOUND'; END IF;
    IF v_document.status<>'DRAFT' THEN RAISE EXCEPTION 'OPENING_BALANCE_DRAFT_REQUIRED'; END IF;
    IF p_master_version IS DISTINCT FROM v_document.master_version THEN RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
    v_before:=to_jsonb(v_document);
    DELETE FROM public.opening_balance_lines WHERE company_id=v_company AND document_id=v_document.id;
    UPDATE public.opening_balance_documents SET effective_date=p_effective_date,
      external_reference=nullif(btrim(p_external_reference),''),description=btrim(p_description),
      master_version=master_version+1,updated_at=clock_timestamp()
    WHERE company_id=v_company AND id=v_document.id RETURNING * INTO v_document;
  END IF;
  FOR v_line IN SELECT value FROM jsonb_array_elements(p_lines) LOOP
    v_line_no:=v_line_no+1;v_type:=upper(nullif(btrim(v_line->>'lineType'),''));
    BEGIN
      v_account:=(v_line->>'accountId')::uuid;
      v_customer:=nullif(v_line->>'customerId','')::uuid;
      v_supplier:=nullif(v_line->>'supplierId','')::uuid;
      v_debit:=round(coalesce(nullif(v_line->>'debit','')::numeric,0),4);
      v_credit:=round(coalesce(nullif(v_line->>'credit','')::numeric,0),4);
    EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'OPENING_BALANCE_LINE_VALUE_INVALID'; END;
    IF v_type NOT IN('GL','RECEIVABLE','PAYABLE') OR v_account IS NULL
      OR NOT((v_debit>0 AND v_credit=0) OR (v_credit>0 AND v_debit=0)) THEN
      RAISE EXCEPTION 'OPENING_BALANCE_LINE_VALUE_INVALID'; END IF;
    PERFORM 1 FROM public.chart_of_accounts account WHERE account.company_id=v_company
      AND account.id=v_account AND account.is_active AND account.is_postable FOR SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION 'OPENING_BALANCE_ACCOUNT_INVALID'; END IF;
    IF v_type='GL' AND EXISTS(SELECT 1 FROM (
      SELECT account_id FROM private.opening_balance_control_accounts(v_company,'INVENTORY_ASSET')
      UNION SELECT account_id FROM private.opening_balance_control_accounts(v_company,'CUSTOMER_RECEIVABLE')
      UNION SELECT account_id FROM private.opening_balance_control_accounts(v_company,'SUPPLIER_AP_FINAL')) control
      WHERE control.account_id=v_account) THEN RAISE EXCEPTION 'OPENING_BALANCE_CONTROL_ACCOUNT_REQUIRES_DETAIL'; END IF;
    IF v_type='RECEIVABLE' AND NOT EXISTS(SELECT 1 FROM private.opening_balance_control_accounts(
      v_company,'CUSTOMER_RECEIVABLE') control WHERE control.account_id=v_account) THEN
      RAISE EXCEPTION 'OPENING_RECEIVABLE_ACCOUNT_INVALID'; END IF;
    IF v_type='PAYABLE' AND NOT EXISTS(SELECT 1 FROM private.opening_balance_control_accounts(
      v_company,'SUPPLIER_AP_FINAL') control WHERE control.account_id=v_account) THEN
      RAISE EXCEPTION 'OPENING_PAYABLE_ACCOUNT_INVALID'; END IF;
    INSERT INTO public.opening_balance_lines(company_id,document_id,line_no,line_type,
      account_id,customer_id,supplier_id,source_document_no,source_document_date,due_date,
      debit,credit,description)
    VALUES(v_company,v_document.id,v_line_no,v_type,v_account,v_customer,v_supplier,
      CASE WHEN v_type='GL' THEN NULL ELSE nullif(btrim(v_line->>'sourceDocumentNo'),'') END,
      CASE WHEN v_type='GL' THEN NULL ELSE nullif(v_line->>'sourceDocumentDate','')::date END,
      CASE WHEN v_type='GL' THEN NULL ELSE nullif(v_line->>'dueDate','')::date END,
      v_debit,v_credit,nullif(btrim(v_line->>'description'),''));
    v_total_debit:=v_total_debit+v_debit;v_total_credit:=v_total_credit+v_credit;
  END LOOP;
  IF EXISTS(
    SELECT 1 FROM public.opening_balance_lines line
    JOIN public.opening_balance_documents document
      ON document.company_id=line.company_id AND document.id=line.document_id
    WHERE line.company_id=v_company AND document.status<>'CANCELED'
      AND line.line_type IN('RECEIVABLE','PAYABLE')
    GROUP BY line.line_type,line.customer_id,line.supplier_id
    HAVING count(*)>1
  ) THEN RAISE EXCEPTION 'OPENING_BALANCE_PARTY_DUPLICATE'; END IF;
  IF v_total_debit<=0 OR v_total_debit<>v_total_credit THEN RAISE EXCEPTION 'JOURNAL_UNBALANCED'; END IF;
  UPDATE public.opening_balance_documents SET total_debit=v_total_debit,total_credit=v_total_credit,
    updated_at=clock_timestamp() WHERE company_id=v_company AND id=v_document.id RETURNING * INTO v_document;
  INSERT INTO public.opening_balance_audit(company_id,document_id,action,actor_id,before_state,after_state)
  VALUES(v_company,v_document.id,CASE WHEN v_is_new THEN 'CREATE' ELSE 'UPDATE' END,v_actor,v_before,to_jsonb(v_document));
  v_result:=private.opening_balance_result(v_document);
  INSERT INTO private.opening_balance_operations(company_id,operation_key,action,payload_hash,result,actor_id)
  VALUES(v_company,p_operation_key,'SAVE',v_hash,v_result,v_actor);
  RETURN v_result;
END
$$;

CREATE FUNCTION public.submit_opening_balance(p_document_id uuid,p_master_version bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,private,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
  v_document public.opening_balance_documents%rowtype;v_before jsonb;
BEGIN
  PERFORM private.acp_require_permission_capability(v_company,'finance.manual_journals','EDIT_DRAFT');
  SELECT * INTO v_document FROM public.opening_balance_documents document
  WHERE document.company_id=v_company AND document.id=p_document_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'OPENING_BALANCE_NOT_FOUND'; END IF;
  IF v_document.status<>'DRAFT' THEN RAISE EXCEPTION 'OPENING_BALANCE_DRAFT_REQUIRED'; END IF;
  IF p_master_version IS DISTINCT FROM v_document.master_version THEN RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
  IF v_document.total_debit<=0 OR v_document.total_debit<>v_document.total_credit THEN RAISE EXCEPTION 'JOURNAL_UNBALANCED'; END IF;
  v_before:=to_jsonb(v_document);
  UPDATE public.opening_balance_documents SET status='SUBMITTED',submitted_by=v_actor,
    submitted_at=clock_timestamp(),master_version=master_version+1,updated_at=clock_timestamp()
  WHERE company_id=v_company AND id=v_document.id RETURNING * INTO v_document;
  INSERT INTO public.opening_balance_audit(company_id,document_id,action,actor_id,before_state,after_state)
  VALUES(v_company,v_document.id,'SUBMIT',v_actor,v_before,to_jsonb(v_document));
  RETURN private.opening_balance_result(v_document);
END
$$;

CREATE FUNCTION public.post_opening_balance(
  p_document_id uuid,p_master_version bigint,p_idempotency_key uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,private,pg_temp SET statement_timeout='20s' AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
  v_document public.opening_balance_documents%rowtype;v_period public.accounting_periods%rowtype;
  v_journal public.finance_journals%rowtype;v_before jsonb;v_line public.opening_balance_lines%rowtype;
BEGIN
  IF p_idempotency_key IS NULL THEN RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED'; END IF;
  PERFORM private.acp_require_permission_capability(v_company,'finance.manual_journals','APPROVE');
  PERFORM pg_advisory_xact_lock(hashtextextended('OPENING_BALANCE_POST|'||v_company||'|'||p_document_id,0));
  SELECT * INTO v_document FROM public.opening_balance_documents document
  WHERE document.company_id=v_company AND document.id=p_document_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'OPENING_BALANCE_NOT_FOUND'; END IF;
  IF v_document.status='POSTED' THEN
    IF v_document.posting_idempotency_key=p_idempotency_key THEN RETURN private.opening_balance_result(v_document); END IF;
    RAISE EXCEPTION 'OPENING_BALANCE_ALREADY_POSTED';
  END IF;
  IF v_document.status<>'SUBMITTED' THEN RAISE EXCEPTION 'OPENING_BALANCE_SUBMITTED_REQUIRED'; END IF;
  IF p_master_version IS DISTINCT FROM v_document.master_version THEN RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
  IF v_document.created_by=v_actor THEN RAISE EXCEPTION 'OPENING_BALANCE_SELF_APPROVAL_FORBIDDEN'; END IF;
  SELECT * INTO v_period FROM public.accounting_periods period WHERE period.company_id=v_company
    AND v_document.effective_date BETWEEN period.start_date AND period.end_date
    AND period.status IN('OPEN','REOPENED') FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'OPENING_BALANCE_PERIOD_NOT_OPEN'; END IF;
  v_before:=to_jsonb(v_document);v_journal.id:=gen_random_uuid();
  INSERT INTO public.finance_journals(id,company_id,journal_no,journal_type,accounting_period_id,
    accounting_date,source_type,source_id,idempotency_key,description,status,total_debit,total_credit,created_by)
  VALUES(v_journal.id,v_company,'OB-'||replace(v_journal.id::text,'-',''),'OPENING_BALANCE',
    v_period.id,v_document.effective_date,'OPENING_BALANCE_DOCUMENT',v_document.id,
    'OPENING_BALANCE|'||v_company||'|'||p_idempotency_key,btrim(v_document.description),
    'DRAFT',v_document.total_debit,v_document.total_credit,v_document.created_by)
  RETURNING * INTO v_journal;
  FOR v_line IN SELECT * FROM public.opening_balance_lines line
    WHERE line.company_id=v_company AND line.document_id=v_document.id ORDER BY line.line_no
  LOOP
    INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,account_id,
      account_code_snapshot,account_name_snapshot,normal_balance_snapshot,debit,credit,
      customer_id,supplier_id,description)
    VALUES(v_company,v_journal.id,v_line.line_no,v_line.account_id,'PENDING','PENDING','DEBIT',
      v_line.debit,v_line.credit,v_line.customer_id,v_line.supplier_id,v_line.description);
  END LOOP;
  UPDATE public.finance_journals SET status='POSTED',posted_by=v_actor,posted_at=clock_timestamp()
  WHERE company_id=v_company AND id=v_journal.id RETURNING * INTO v_journal;
  UPDATE public.opening_balance_documents SET status='POSTED',journal_id=v_journal.id,
    posting_idempotency_key=p_idempotency_key,posted_by=v_actor,posted_at=clock_timestamp(),
    master_version=master_version+1,updated_at=clock_timestamp()
  WHERE company_id=v_company AND id=v_document.id RETURNING * INTO v_document;
  INSERT INTO public.opening_balance_audit(company_id,document_id,action,actor_id,before_state,after_state)
  VALUES(v_company,v_document.id,'POST',v_actor,v_before,to_jsonb(v_document));
  RETURN private.opening_balance_result(v_document);
END
$$;

CREATE FUNCTION public.cancel_opening_balance(
  p_document_id uuid,p_master_version bigint,p_reason text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,private,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
  v_document public.opening_balance_documents%rowtype;v_before jsonb;
BEGIN
  PERFORM private.acp_require_permission_capability(v_company,'finance.manual_journals','EDIT_DRAFT');
  IF nullif(btrim(p_reason),'') IS NULL THEN RAISE EXCEPTION 'CANCEL_REASON_REQUIRED'; END IF;
  SELECT * INTO v_document FROM public.opening_balance_documents document
  WHERE document.company_id=v_company AND document.id=p_document_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'OPENING_BALANCE_NOT_FOUND'; END IF;
  IF v_document.status NOT IN('DRAFT','SUBMITTED') THEN RAISE EXCEPTION 'OPENING_BALANCE_CANCEL_NOT_ALLOWED'; END IF;
  IF p_master_version IS DISTINCT FROM v_document.master_version THEN RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
  v_before:=to_jsonb(v_document);
  UPDATE public.opening_balance_documents SET status='CANCELED',canceled_by=v_actor,
    canceled_at=clock_timestamp(),cancel_reason=btrim(p_reason),master_version=master_version+1,
    updated_at=clock_timestamp() WHERE company_id=v_company AND id=v_document.id RETURNING * INTO v_document;
  INSERT INTO public.opening_balance_audit(company_id,document_id,action,actor_id,before_state,after_state)
  VALUES(v_company,v_document.id,'CANCEL',v_actor,v_before,to_jsonb(v_document));
  RETURN private.opening_balance_result(v_document);
END
$$;

GRANT EXECUTE ON FUNCTION public.get_opening_balance_workspace() TO authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.save_opening_balance_draft(uuid,bigint,uuid,date,text,text,jsonb) TO authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.submit_opening_balance(uuid,bigint) TO authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.post_opening_balance(uuid,bigint,uuid) TO authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.cancel_opening_balance(uuid,bigint,text) TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,description)
VALUES('20261029100000','Direct in-application Opening Balance with GL and aggregate party-level AR/AP balances');

COMMIT;
