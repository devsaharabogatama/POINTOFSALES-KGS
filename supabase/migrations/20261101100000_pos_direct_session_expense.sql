-- Point 4: POS Expense is paid atomically from the selected cashier session.
-- Cash uses the existing canonical disbursement core. Non-cash uses a
-- POS-session-only core with the same canonical Event/disbursement/audit shape.

BEGIN;

DO $guard$
BEGIN
  IF EXISTS (
    SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20261101100000'
  ) THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20261101100000';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260803040000'
  ) OR NOT EXISTS (
    SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260803070000'
  ) OR NOT EXISTS (
    SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260803100000'
  ) OR NOT EXISTS (
    SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260804100000'
  ) OR NOT EXISTS (
    SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260813060000'
  ) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Expense runtime chain incomplete';
  END IF;
  IF to_regprocedure('private.acp6a_save_expense_draft_core(uuid,bigint,uuid,uuid,uuid,text,uuid,text,numeric,uuid,text,text,text,date,uuid)') IS NULL
     OR to_regprocedure('private.acp6a_disburse_expense_core(uuid,bigint,uuid,text,uuid)') IS NULL
     OR to_regprocedure('private.resolve_expense_disbursement_account(uuid,uuid,text,timestamptz)') IS NULL
     OR to_regprocedure('public.get_pos_expense_workspace(uuid)') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Expense runtime object missing';
  END IF;
  IF to_regprocedure('public.post_pos_expense(uuid,uuid,uuid,text,uuid,text,numeric,uuid,text,text,text,date,uuid,uuid)') IS NOT NULL
     OR to_regprocedure('private.post_pos_noncash_expense_core(uuid,bigint,uuid,text,uuid)') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: partial POS direct Expense runtime found';
  END IF;
END
$guard$;

CREATE FUNCTION private.post_pos_noncash_expense_core(
  p_document_id UUID,
  p_master_version BIGINT,
  p_cashier_session_id UUID,
  p_evidence_url TEXT,
  p_idempotency_key UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE
  v_actor UUID:=auth.uid();
  v_company UUID:=public.private_active_company_id();
  v_now TIMESTAMPTZ:=clock_timestamp();
  v_document public.expense_documents%ROWTYPE;
  v_method public.payment_methods%ROWTYPE;
  v_session public.cashier_sessions%ROWTYPE;
  v_existing public.expense_disbursements%ROWTYPE;
  v_disbursement_id UUID:=gen_random_uuid();
  v_financial_event_id UUID;
  v_transaction_category_id UUID;
  v_outstanding_account_id UUID;
  v_payment_account_id UUID;
  v_payment_function TEXT;
  v_approval_snapshot JSONB;
  v_before JSONB;
  v_new_version BIGINT;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
  IF p_cashier_session_id IS NULL THEN
    RAISE EXCEPTION 'OPEN_EXPENSE_SESSION_REQUIRED';
  END IF;
  IF p_idempotency_key IS NULL THEN
    RAISE EXCEPTION 'EXPENSE_DISBURSEMENT_IDEMPOTENCY_KEY_REQUIRED';
  END IF;
  IF NOT public.private_company_feature_enabled(v_company,'expense_enabled') THEN
    RAISE EXCEPTION 'EXPENSE_FEATURE_DISABLED';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(
    'POS_DIRECT_EXPENSE_DISBURSEMENT|'||v_company::TEXT||'|'||p_idempotency_key::TEXT,0
  ));
  SELECT * INTO v_existing
  FROM public.expense_disbursements
  WHERE company_id=v_company AND idempotency_key=p_idempotency_key;
  IF FOUND THEN
    IF v_existing.document_id IS DISTINCT FROM p_document_id
       OR v_existing.cashier_session_id IS DISTINCT FROM p_cashier_session_id
       OR v_existing.evidence_url IS DISTINCT FROM p_evidence_url THEN
      RAISE EXCEPTION 'EXPENSE_DISBURSEMENT_IDEMPOTENCY_CONFLICT';
    END IF;
    SELECT * INTO v_document
    FROM public.expense_documents
    WHERE company_id=v_company AND id=v_existing.document_id;
    RETURN jsonb_build_object(
      'documentId',v_existing.document_id,
      'disbursementId',v_existing.id,
      'status',v_document.status,
      'masterVersion',v_document.master_version,
      'amount',v_existing.amount,
      'paymentMethodType',v_existing.payment_method_type_snapshot,
      'expectedCashAfter',NULL,
      'financialEventId',v_existing.financial_event_id,
      'idempotentReplay',TRUE
    );
  END IF;

  SELECT * INTO v_document
  FROM public.expense_documents
  WHERE company_id=v_company AND id=p_document_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'EXPENSE_DOCUMENT_NOT_FOUND'; END IF;
  IF v_document.status<>'APPROVED' THEN
    RAISE EXCEPTION 'ONLY_APPROVED_EXPENSE_DISBURSABLE';
  END IF;
  IF p_master_version IS NULL OR p_master_version<>v_document.master_version THEN
    RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
  END IF;
  IF v_document.cashier_session_id IS DISTINCT FROM p_cashier_session_id
     OR v_document.created_by IS DISTINCT FROM v_actor THEN
    RAISE EXCEPTION 'POS_DIRECT_EXPENSE_OWNERSHIP_REQUIRED';
  END IF;
  IF v_document.requested_amount<=0
     OR v_document.disbursed_amount<>0
     OR v_document.actual_expense_amount<>0
     OR v_document.returned_amount<>0
     OR v_document.outstanding_amount<>0 THEN
    RAISE EXCEPTION 'EXPENSE_INITIAL_DISBURSEMENT_STATE_INVALID';
  END IF;
  IF v_document.approved_by IS NULL OR v_document.approved_at IS NULL THEN
    RAISE EXCEPTION 'EXPENSE_APPROVAL_SNAPSHOT_INCOMPLETE';
  END IF;
  IF NOT public.private_user_has_store_access(v_document.store_id) THEN
    RAISE EXCEPTION 'EXPENSE_STORE_ACCESS_REQUIRED';
  END IF;

  SELECT * INTO v_session
  FROM public.cashier_sessions session
  WHERE session.company_id=v_company
    AND session.store_id=v_document.store_id
    AND session.id=p_cashier_session_id
    AND session.status='OPEN'::public.session_status
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'OPEN_EXPENSE_SESSION_REQUIRED'; END IF;
  IF v_session.cashier_id<>v_actor AND NOT (
    public.private_user_has_any_company_role(
      v_company,ARRAY['COMPANY_OWNER','COMPANY_ADMIN']::TEXT[]
    ) OR public.private_user_has_any_store_role(
      v_document.store_id,ARRAY['STORE_MANAGER']::TEXT[]
    )
  ) THEN
    RAISE EXCEPTION 'EXPENSE_SESSION_OPERATOR_REQUIRED';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.pos_terminals terminal
    WHERE terminal.company_id=v_company
      AND terminal.store_id=v_document.store_id
      AND terminal.id=v_session.pos_id
      AND terminal.status='ACTIVE'
  ) THEN RAISE EXCEPTION 'ACTIVE_EXPENSE_TERMINAL_REQUIRED'; END IF;

  SELECT * INTO v_method
  FROM public.payment_methods method
  WHERE method.company_id=v_company
    AND method.id=v_document.requested_payment_method_id
    AND method.is_active
    AND method.effective_from<=v_now
    AND (method.effective_to IS NULL OR method.effective_to>v_now)
    AND method.method_type IN ('TRANSFER','QRIS','CARD','E_WALLET')
    AND method.settlement_route IN ('DIRECT_BANK','CLEARING')
    AND (
      method.available_all_stores OR EXISTS (
        SELECT 1 FROM public.payment_method_store_assignments assignment
        WHERE assignment.company_id=v_company
          AND assignment.payment_method_id=method.id
          AND assignment.store_id=v_document.store_id
      )
    );
  IF NOT FOUND THEN RAISE EXCEPTION 'ACTIVE_EXPENSE_NONCASH_METHOD_NOT_FOUND'; END IF;
  IF v_method.method_type IS DISTINCT FROM v_document.requested_payment_method_type_snapshot THEN
    RAISE EXCEPTION 'EXPENSE_PAYMENT_METHOD_SNAPSHOT_CONFLICT';
  END IF;
  IF p_evidence_url IS NOT NULL AND p_evidence_url !~* '^https://' THEN
    RAISE EXCEPTION 'EXPENSE_DISBURSEMENT_EVIDENCE_HTTPS_REQUIRED';
  END IF;
  IF v_method.proof_mode='REQUIRED' AND p_evidence_url IS NULL THEN
    RAISE EXCEPTION 'EXPENSE_DISBURSEMENT_EVIDENCE_REQUIRED';
  END IF;

  v_payment_function:=CASE v_method.settlement_route
    WHEN 'DIRECT_BANK' THEN v_method.bank_account_function
    WHEN 'CLEARING' THEN v_method.clearing_account_function
  END;
  SELECT category.id INTO v_transaction_category_id
  FROM public.transaction_categories category
  WHERE category.company_id=v_company
    AND category.system_key='EXPENSE_DISBURSEMENT'
    AND category.is_active
  ORDER BY category.created_at,category.id
  LIMIT 1;
  IF v_transaction_category_id IS NULL THEN
    RAISE EXCEPTION 'EXPENSE_DISBURSEMENT_CATEGORY_NOT_FOUND';
  END IF;
  v_outstanding_account_id:=private.resolve_expense_disbursement_account(
    v_company,v_transaction_category_id,'OUTSTANDING_EXPENSE',v_now
  );
  v_payment_account_id:=private.resolve_expense_disbursement_account(
    v_company,v_transaction_category_id,v_payment_function,v_now
  );
  v_approval_snapshot:=jsonb_build_object(
    'approvalRequired',v_document.approval_required_snapshot,
    'directPosPaid',TRUE,
    'approvedBy',v_document.approved_by,
    'approvedAt',v_document.approved_at,
    'documentMasterVersion',v_document.master_version
  );
  v_before:=to_jsonb(v_document);

  INSERT INTO public.financial_events(
    event_code,event_type,source_table,source_id,root_sales_id,
    event_date,event_version,idempotency_key,payment_method,amounts,
    status,error_message,created_by,company_id,store_id,
    system_event_key,transaction_category_id
  ) VALUES (
    'EXP-DISB-'||replace(v_disbursement_id::TEXT,'-',''),
    'EXPENSE_DISBURSEMENT'::public.event_type,
    'expense_disbursements',v_disbursement_id,NULL,v_now,1,
    'EXPENSE_DISBURSEMENT|'||v_company::TEXT||'|'||p_idempotency_key::TEXT,
    v_method.payment_method_name,
    jsonb_build_object(
      'expenseDocumentId',v_document.id,
      'requestedAmount',v_document.requested_amount,
      'disbursedAmount',v_document.requested_amount,
      'outstandingAccountId',v_outstanding_account_id,
      'paymentAccountId',v_payment_account_id,
      'paymentAccountFunction',v_payment_function,
      'settlementRoute',v_method.settlement_route,
      'cashierSessionId',v_session.id,
      'approvalSnapshot',v_approval_snapshot,
      'financePostingState','HOLD_UNTIL_G6'
    ),
    'HOLD'::public.event_status,
    'CANONICAL_FINANCE_POSTING_NOT_ENABLED',v_actor,v_company,
    v_document.store_id,'EXPENSE_DISBURSEMENT',v_transaction_category_id
  ) RETURNING id INTO v_financial_event_id;

  INSERT INTO public.expense_disbursements(
    id,company_id,document_id,store_id,pos_terminal_id,amount,
    payment_method_id,payment_method_name_snapshot,
    payment_method_type_snapshot,payment_settlement_route_snapshot,
    payment_account_function_snapshot,cashier_session_id,evidence_url,
    idempotency_key,financial_event_id,transaction_category_id,
    outstanding_account_id_snapshot,payment_account_id_snapshot,
    document_master_version_snapshot,approval_snapshot,created_by,created_at
  ) VALUES (
    v_disbursement_id,v_company,v_document.id,v_document.store_id,
    v_session.pos_id,v_document.requested_amount,v_method.id,
    v_method.payment_method_name,v_method.method_type,
    v_method.settlement_route,v_payment_function,v_session.id,
    p_evidence_url,p_idempotency_key,v_financial_event_id,
    v_transaction_category_id,v_outstanding_account_id,
    v_payment_account_id,v_document.master_version,
    v_approval_snapshot,v_actor,v_now
  );

  UPDATE public.expense_documents
  SET status='DISBURSED',
      disbursed_amount=v_document.requested_amount,
      outstanding_amount=v_document.requested_amount,
      master_version=master_version+1,
      updated_by=v_actor,
      updated_at=v_now
  WHERE company_id=v_company AND id=v_document.id
  RETURNING master_version INTO v_new_version;

  INSERT INTO public.expense_audit(
    company_id,entity_type,entity_id,document_id,action,actor_id,
    before_state,after_state,created_at
  )
  SELECT v_company,'DISBURSEMENT',v_disbursement_id,v_document.id,
    'DISBURSE',v_actor,v_before,
    jsonb_build_object(
      'document',to_jsonb(document),
      'disbursement',to_jsonb(disbursement)
    ),v_now
  FROM public.expense_documents document
  JOIN public.expense_disbursements disbursement
    ON disbursement.company_id=document.company_id
   AND disbursement.document_id=document.id
   AND disbursement.id=v_disbursement_id
  WHERE document.company_id=v_company AND document.id=v_document.id;

  RETURN jsonb_build_object(
    'documentId',v_document.id,
    'disbursementId',v_disbursement_id,
    'status','DISBURSED',
    'masterVersion',v_new_version,
    'amount',v_document.requested_amount,
    'paymentMethodType',v_method.method_type,
    'expectedCashAfter',NULL,
    'financialEventId',v_financial_event_id,
    'idempotentReplay',FALSE
  );
END
$$;

CREATE FUNCTION public.post_pos_expense(
  p_store_id UUID,
  p_cashier_session_id UUID,
  p_category_id UUID,
  p_responsible_party_type TEXT,
  p_responsible_party_id UUID,
  p_responsible_party_name TEXT,
  p_requested_amount NUMERIC,
  p_payment_method_id UUID,
  p_recipient TEXT,
  p_description TEXT,
  p_evidence_url TEXT,
  p_expected_settlement_date DATE,
  p_client_expense_id UUID,
  p_idempotency_key UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE
  v_actor UUID:=auth.uid();
  v_company UUID:=public.private_active_company_id();
  v_draft JSONB;
  v_result JSONB;
  v_document public.expense_documents%ROWTYPE;
  v_before JSONB;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
  IF p_client_expense_id IS NULL THEN RAISE EXCEPTION 'CLIENT_EXPENSE_ID_REQUIRED'; END IF;
  IF p_idempotency_key IS NULL THEN RAISE EXCEPTION 'EXPENSE_DISBURSEMENT_IDEMPOTENCY_KEY_REQUIRED'; END IF;
  PERFORM private.acp_require_expense_channel_mutation(v_company);

  v_draft:=private.acp6a_save_expense_draft_core(
    NULL,NULL,p_store_id,p_cashier_session_id,p_category_id,
    p_responsible_party_type,p_responsible_party_id,p_responsible_party_name,
    p_requested_amount,p_payment_method_id,p_recipient,p_description,
    p_evidence_url,p_expected_settlement_date,p_client_expense_id
  );

  SELECT * INTO v_document
  FROM public.expense_documents
  WHERE company_id=v_company
    AND id=(v_draft->>'documentId')::UUID
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'EXPENSE_DOCUMENT_NOT_FOUND'; END IF;
  IF v_document.created_by IS DISTINCT FROM v_actor
     OR v_document.store_id IS DISTINCT FROM p_store_id
     OR v_document.cashier_session_id IS DISTINCT FROM p_cashier_session_id THEN
    RAISE EXCEPTION 'POS_DIRECT_EXPENSE_OWNERSHIP_REQUIRED';
  END IF;

  IF v_document.status='DRAFT' THEN
    v_before:=to_jsonb(v_document);
    UPDATE public.expense_documents
    SET status='APPROVED',
        submitted_by=v_actor,
        submitted_at=clock_timestamp(),
        approved_by=v_actor,
        approved_at=clock_timestamp(),
        master_version=master_version+1,
        updated_by=v_actor,
        updated_at=clock_timestamp()
    WHERE company_id=v_company AND id=v_document.id
    RETURNING * INTO v_document;
    INSERT INTO public.expense_audit(
      company_id,entity_type,entity_id,document_id,action,actor_id,
      before_state,after_state
    ) VALUES (
      v_company,'DOCUMENT',v_document.id,v_document.id,'AUTO_APPROVE',v_actor,
      v_before,to_jsonb(v_document)
    );
  ELSIF v_document.status<>'DISBURSED' THEN
    RAISE EXCEPTION 'POS_DIRECT_EXPENSE_STATE_INVALID';
  END IF;

  IF v_document.requested_payment_method_type_snapshot='CASH' THEN
    v_result:=private.acp6a_disburse_expense_core(
      v_document.id,v_document.master_version,p_cashier_session_id,
      p_evidence_url,p_idempotency_key
    );
  ELSE
    v_result:=private.post_pos_noncash_expense_core(
      v_document.id,v_document.master_version,p_cashier_session_id,
      p_evidence_url,p_idempotency_key
    );
  END IF;
  RETURN v_result||jsonb_build_object('documentNo',v_document.document_no);
END
$$;

CREATE OR REPLACE FUNCTION public.get_pos_expense_workspace(
  p_cashier_session_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE
  v_company UUID:=public.private_active_company_id();
  v_store UUID;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  SELECT session.store_id INTO v_store
  FROM public.cashier_sessions session
  WHERE session.company_id=v_company
    AND session.id=p_cashier_session_id
    AND session.cashier_id=auth.uid()
    AND session.status='OPEN';
  IF v_store IS NULL THEN RAISE EXCEPTION 'OPEN_CASHIER_SESSION_REQUIRED'; END IF;

  RETURN jsonb_build_object(
    'approvedCashExpenses',(
      SELECT COALESCE(jsonb_agg(to_jsonb(document)
        ORDER BY document.approved_at,document.id),'[]'::JSONB)
      FROM public.expense_documents document
      WHERE document.company_id=v_company
        AND document.store_id=v_store
        AND document.cashier_session_id=p_cashier_session_id
        AND document.status='APPROVED'
        AND document.requested_payment_method_type_snapshot='CASH'
    ),
    'outstandingExpenses',(
      SELECT COALESCE(jsonb_agg(to_jsonb(document)||jsonb_build_object(
        'settlement_pending',EXISTS(
          SELECT 1 FROM public.expense_settlement_requests request
          WHERE request.company_id=v_company
            AND request.document_id=document.id
            AND request.status='SUBMITTED'
        )) ORDER BY document.updated_at,document.id),'[]'::JSONB)
      FROM public.expense_documents document
      WHERE document.company_id=v_company
        AND document.store_id=v_store
        AND document.cashier_session_id=p_cashier_session_id
        AND document.status IN('DISBURSED','PARTIALLY_SETTLED')
        AND document.outstanding_amount>0
    ),
    'approvedAdditionalCashExpenses',(
      SELECT COALESCE(jsonb_agg(to_jsonb(request)||jsonb_build_object(
        'document_no',document.document_no,
        'document_master_version',document.master_version,
        'category_name_snapshot',document.category_name_snapshot,
        'responsible_party_name_snapshot',document.responsible_party_name_snapshot
      ) ORDER BY request.approved_at,request.id),'[]'::JSONB)
      FROM public.expense_additional_disbursement_requests request
      JOIN public.expense_documents document
        ON document.company_id=request.company_id
       AND document.id=request.document_id
      WHERE request.company_id=v_company
        AND request.store_id=v_store
        AND document.cashier_session_id=p_cashier_session_id
        AND request.status='APPROVED'
        AND request.payment_method_type_snapshot='CASH'
        AND document.status IN('DISBURSED','PARTIALLY_SETTLED')
    ),
    'sessionExpenseSummary',(
      SELECT jsonb_build_object(
        'documentCount',count(DISTINCT disbursement.document_id),
        'totalAmount',COALESCE(sum(disbursement.amount),0),
        'cashAmount',COALESCE(sum(disbursement.amount) FILTER (
          WHERE disbursement.payment_method_type_snapshot='CASH'
        ),0),
        'nonCashAmount',COALESCE(sum(disbursement.amount) FILTER (
          WHERE disbursement.payment_method_type_snapshot<>'CASH'
        ),0)
      )
      FROM public.expense_disbursements disbursement
      WHERE disbursement.company_id=v_company
        AND disbursement.cashier_session_id=p_cashier_session_id
    )
  );
END
$$;

REVOKE ALL ON FUNCTION private.post_pos_noncash_expense_core(UUID,BIGINT,UUID,TEXT,UUID)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.post_pos_noncash_expense_core(UUID,BIGINT,UUID,TEXT,UUID)
TO service_role;
REVOKE ALL ON FUNCTION public.post_pos_expense(UUID,UUID,UUID,TEXT,UUID,TEXT,NUMERIC,UUID,TEXT,TEXT,TEXT,DATE,UUID,UUID)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.post_pos_expense(UUID,UUID,UUID,TEXT,UUID,TEXT,NUMERIC,UUID,TEXT,TEXT,TEXT,DATE,UUID,UUID)
TO authenticated,service_role;

COMMENT ON FUNCTION public.post_pos_expense(UUID,UUID,UUID,TEXT,UUID,TEXT,NUMERIC,UUID,TEXT,TEXT,TEXT,DATE,UUID,UUID)
IS 'Atomically records and pays one initial POS Expense from the selected open Cashier Session; no approval or second initial disbursement step.';

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES(
  '20261101100000',
  'pos_direct_session_expense',
  'Atomic direct POS Expense payment, session-scoped POS workspace and immutable per-session Expense summary; Backoffice approval and historical flows preserved'
);

COMMIT;
