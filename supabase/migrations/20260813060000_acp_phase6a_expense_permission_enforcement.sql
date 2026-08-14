-- ACP-6A: enforce Expense Backoffice capabilities while preserving the
-- independent Cashier open-session channel.

BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260813050000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: ACP-5H required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260813060000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED';
  END IF;
  IF (SELECT count(*) FROM public.access_permission_catalog
    WHERE permission_key='finance.expenses'
      AND enforcement_status='SHADOW')<>1 THEN
    RAISE EXCEPTION 'EXPENSE_PERMISSION_NOT_SHADOW';
  END IF;
END
$guard$;

-- Cashier authority is still decided by the existing Store/session guards.
-- An explicit custom restriction may narrow that authority, never widen it.
CREATE FUNCTION private.acp_require_expense_channel_mutation(p_company UUID)
RETURNS VOID LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_preset TEXT;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF p_company IS DISTINCT FROM public.private_active_company_id() THEN
    RAISE EXCEPTION 'ACTIVE_COMPANY_CONTEXT_MISMATCH';
  END IF;
  SELECT restriction_preset INTO v_preset
  FROM public.user_company_permission_overrides
  WHERE company_id=p_company AND user_id=auth.uid()
    AND permission_key='finance.expenses';
  IF v_preset IN('LIHAT_SAJA','TIDAK_ADA_AKSES') THEN
    RAISE EXCEPTION 'PERMISSION_CAPABILITY_REQUIRED: finance.expenses channel mutation';
  END IF;
END
$$;

CREATE FUNCTION public.get_finance_expenses(p_status TEXT DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
  v_status TEXT:=NULLIF(upper(btrim(p_status)),'');
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'finance.expenses','VIEW');
  IF v_status IS NOT NULL AND v_status NOT IN(
    'DRAFT','SUBMITTED','APPROVED','REJECTED','CANCELED','PAYMENT_PENDING',
    'DISBURSED','PARTIALLY_SETTLED','SETTLED','SETTLED_NO_EXPENSE','REVERSED'
  ) THEN RAISE EXCEPTION 'EXPENSE_STATUS_INVALID'; END IF;

  RETURN jsonb_build_object(
    'companyId',v_company,
    'data',(SELECT COALESCE(jsonb_agg(to_jsonb(document)
      ORDER BY document.created_at DESC,document.id DESC),'[]'::JSONB)
      FROM (SELECT candidate.* FROM public.expense_documents candidate
        WHERE candidate.company_id=v_company
          AND (v_status IS NULL OR candidate.status=v_status)
        ORDER BY candidate.created_at DESC,candidate.id DESC LIMIT 500) document),
    'settlementRequests',(SELECT COALESCE(jsonb_agg(to_jsonb(request)
      ORDER BY request.submitted_at DESC,request.id DESC),'[]'::JSONB)
      FROM public.expense_settlement_requests request
      JOIN public.expense_documents document
        ON document.company_id=request.company_id AND document.id=request.document_id
      WHERE request.company_id=v_company
        AND (v_status IS NULL OR document.status=v_status)),
    'additionalRequests',(SELECT COALESCE(jsonb_agg(to_jsonb(request)
      ORDER BY request.requested_at DESC,request.id DESC),'[]'::JSONB)
      FROM public.expense_additional_disbursement_requests request
      JOIN public.expense_documents document
        ON document.company_id=request.company_id AND document.id=request.document_id
      WHERE request.company_id=v_company
        AND (v_status IS NULL OR document.status=v_status)),
    'stores',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',store.id,'store_name',store.store_name)
      ORDER BY store.store_name,store.id),'[]'::JSONB)
      FROM public.stores store WHERE store.company_id=v_company
        AND EXISTS(SELECT 1 FROM public.expense_documents document
          WHERE document.company_id=v_company AND document.store_id=store.id
            AND (v_status IS NULL OR document.status=v_status))),
    'sessions',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',session.id,'session_code',session.session_code,'status',session.status)
      ORDER BY session.session_code,session.id),'[]'::JSONB)
      FROM public.cashier_sessions session WHERE session.company_id=v_company
        AND EXISTS(SELECT 1 FROM public.expense_documents document
          WHERE document.company_id=v_company
            AND document.cashier_session_id=session.id
            AND (v_status IS NULL OR document.status=v_status))),
    'actors',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',profile.id,'name',profile.name) ORDER BY profile.name,profile.id),
      '[]'::JSONB) FROM public.profiles profile WHERE EXISTS(SELECT 1
        FROM public.expense_documents document WHERE document.company_id=v_company
          AND profile.id IN(document.created_by,document.submitted_by,
            document.approved_by,document.rejected_by,document.canceled_by,
            document.disbursed_by,document.settled_by)
          AND (v_status IS NULL OR document.status=v_status))
      OR EXISTS(SELECT 1 FROM public.expense_settlement_requests request
        JOIN public.expense_documents document
          ON document.company_id=request.company_id AND document.id=request.document_id
        WHERE request.company_id=v_company
          AND profile.id IN(request.submitted_by,request.reviewed_by)
          AND (v_status IS NULL OR document.status=v_status))
      OR EXISTS(SELECT 1 FROM public.expense_additional_disbursement_requests request
        JOIN public.expense_documents document
          ON document.company_id=request.company_id AND document.id=request.document_id
        WHERE request.company_id=v_company
          AND profile.id IN(request.requested_by,request.approved_by,
            request.rejected_by,request.disbursed_by)
          AND (v_status IS NULL OR document.status=v_status))),
    'paymentMethods',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',method.id,'payment_method_name',method.payment_method_name,
      'method_type',method.method_type,'proof_mode',method.proof_mode,
      'settlement_route',method.settlement_route,'is_active',method.is_active)
      ORDER BY method.payment_method_name,method.id),'[]'::JSONB)
      FROM public.payment_methods method WHERE method.company_id=v_company
        AND (EXISTS(SELECT 1 FROM public.expense_documents document
          WHERE document.company_id=v_company
            AND document.requested_payment_method_id=method.id
            AND (v_status IS NULL OR document.status=v_status))
          OR EXISTS(SELECT 1
            FROM public.expense_additional_disbursement_requests request
            JOIN public.expense_documents document
              ON document.company_id=request.company_id
             AND document.id=request.document_id
            WHERE request.company_id=v_company
              AND request.payment_method_id=method.id
              AND (v_status IS NULL OR document.status=v_status)))));
END
$$;

CREATE FUNCTION public.get_pos_expense_categories(p_store_id UUID)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF NOT public.private_company_feature_enabled(v_company,'expense_enabled') THEN
    RETURN jsonb_build_object('categories','[]'::JSONB);
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.store_memberships membership
    WHERE membership.company_id=v_company AND membership.store_id=p_store_id
      AND membership.user_id=auth.uid() AND membership.status='ACTIVE') THEN
    RAISE EXCEPTION 'ACTIVE_STORE_MEMBERSHIP_REQUIRED';
  END IF;
  RETURN jsonb_build_object('categories',(SELECT COALESCE(jsonb_agg(
    jsonb_build_object('id',category.id,'category_name',category.category_name,
      'evidence_policy',category.evidence_policy,
      'default_payment_method_id',category.default_payment_method_id)
    ORDER BY category.category_name,category.id),'[]'::JSONB)
    FROM public.expense_categories category
    WHERE category.company_id=v_company AND category.is_active));
END
$$;

CREATE FUNCTION public.get_pos_expense_workspace(p_cashier_session_id UUID)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_store UUID;
BEGIN
  SELECT session.store_id INTO v_store FROM public.cashier_sessions session
  WHERE session.company_id=v_company AND session.id=p_cashier_session_id
    AND session.cashier_id=auth.uid() AND session.status='OPEN';
  IF v_store IS NULL THEN RAISE EXCEPTION 'OPEN_CASHIER_SESSION_REQUIRED'; END IF;
  RETURN jsonb_build_object(
    'approvedCashExpenses',(SELECT COALESCE(jsonb_agg(to_jsonb(document)
      ORDER BY document.approved_at,document.id),'[]'::JSONB)
      FROM public.expense_documents document WHERE document.company_id=v_company
        AND document.store_id=v_store AND document.status='APPROVED'
        AND document.requested_payment_method_type_snapshot='CASH'),
    'outstandingExpenses',(SELECT COALESCE(jsonb_agg(to_jsonb(document)||
      jsonb_build_object('settlement_pending',EXISTS(SELECT 1
        FROM public.expense_settlement_requests request
        WHERE request.company_id=v_company AND request.document_id=document.id
          AND request.status='SUBMITTED')) ORDER BY document.updated_at,document.id),
      '[]'::JSONB) FROM public.expense_documents document
      WHERE document.company_id=v_company AND document.store_id=v_store
        AND document.status IN('DISBURSED','PARTIALLY_SETTLED')
        AND document.outstanding_amount>0),
    'approvedAdditionalCashExpenses',(SELECT COALESCE(jsonb_agg(
      to_jsonb(request)||jsonb_build_object(
        'document_no',document.document_no,
        'document_master_version',document.master_version,
        'category_name_snapshot',document.category_name_snapshot,
        'responsible_party_name_snapshot',document.responsible_party_name_snapshot)
      ORDER BY request.approved_at,request.id),'[]'::JSONB)
      FROM public.expense_additional_disbursement_requests request
      JOIN public.expense_documents document ON document.company_id=request.company_id
        AND document.id=request.document_id
      WHERE request.company_id=v_company AND request.store_id=v_store
        AND request.status='APPROVED'
        AND request.payment_method_type_snapshot='CASH'
        AND document.status IN('DISBURSED','PARTIALLY_SETTLED')));
END
$$;

-- Move the trusted implementations out of the browser namespace.
ALTER FUNCTION public.save_expense_category(UUID,BIGINT,TEXT,TEXT,UUID,UUID,TEXT,TEXT,UUID,BOOLEAN)
  RENAME TO acp6a_save_expense_category_core;
ALTER FUNCTION public.acp6a_save_expense_category_core(UUID,BIGINT,TEXT,TEXT,UUID,UUID,TEXT,TEXT,UUID,BOOLEAN) SET SCHEMA private;
ALTER FUNCTION public.save_expense_approval_policy(UUID,BIGINT,BOOLEAN,BOOLEAN)
  RENAME TO acp6a_save_expense_approval_policy_core;
ALTER FUNCTION public.acp6a_save_expense_approval_policy_core(UUID,BIGINT,BOOLEAN,BOOLEAN) SET SCHEMA private;
ALTER FUNCTION public.save_expense_draft(UUID,BIGINT,UUID,UUID,UUID,TEXT,UUID,TEXT,NUMERIC,UUID,TEXT,TEXT,TEXT,DATE,UUID)
  RENAME TO acp6a_save_expense_draft_core;
ALTER FUNCTION public.acp6a_save_expense_draft_core(UUID,BIGINT,UUID,UUID,UUID,TEXT,UUID,TEXT,NUMERIC,UUID,TEXT,TEXT,TEXT,DATE,UUID) SET SCHEMA private;
ALTER FUNCTION public.submit_expense_request(UUID,BIGINT) RENAME TO acp6a_submit_expense_request_core;
ALTER FUNCTION public.acp6a_submit_expense_request_core(UUID,BIGINT) SET SCHEMA private;
ALTER FUNCTION public.review_expense_request(UUID,BIGINT,BOOLEAN,TEXT) RENAME TO acp6a_review_expense_request_core;
ALTER FUNCTION public.acp6a_review_expense_request_core(UUID,BIGINT,BOOLEAN,TEXT) SET SCHEMA private;
ALTER FUNCTION public.cancel_expense_request(UUID,BIGINT,TEXT) RENAME TO acp6a_cancel_expense_request_core;
ALTER FUNCTION public.acp6a_cancel_expense_request_core(UUID,BIGINT,TEXT) SET SCHEMA private;
ALTER FUNCTION public.disburse_expense(UUID,BIGINT,UUID,TEXT,UUID) RENAME TO acp6a_disburse_expense_core;
ALTER FUNCTION public.acp6a_disburse_expense_core(UUID,BIGINT,UUID,TEXT,UUID) SET SCHEMA private;
ALTER FUNCTION public.save_expense_settlement(UUID,BIGINT,NUMERIC,TEXT,UUID) RENAME TO acp6a_save_expense_settlement_core;
ALTER FUNCTION public.acp6a_save_expense_settlement_core(UUID,BIGINT,NUMERIC,TEXT,UUID) SET SCHEMA private;
ALTER FUNCTION public.review_expense_settlement(UUID,BIGINT,TEXT,TEXT) RENAME TO acp6a_review_expense_settlement_core;
ALTER FUNCTION public.acp6a_review_expense_settlement_core(UUID,BIGINT,TEXT,TEXT) SET SCHEMA private;
ALTER FUNCTION public.return_expense_funds(UUID,BIGINT,NUMERIC,UUID,UUID,TEXT,UUID) RENAME TO acp6a_return_expense_funds_core;
ALTER FUNCTION public.acp6a_return_expense_funds_core(UUID,BIGINT,NUMERIC,UUID,UUID,TEXT,UUID) SET SCHEMA private;
ALTER FUNCTION public.request_additional_expense_disbursement(UUID,BIGINT,NUMERIC,UUID,TEXT,UUID) RENAME TO acp6a_request_additional_core;
ALTER FUNCTION public.acp6a_request_additional_core(UUID,BIGINT,NUMERIC,UUID,TEXT,UUID) SET SCHEMA private;
ALTER FUNCTION public.review_additional_expense_disbursement(UUID,BIGINT,TEXT,TEXT) RENAME TO acp6a_review_additional_core;
ALTER FUNCTION public.acp6a_review_additional_core(UUID,BIGINT,TEXT,TEXT) SET SCHEMA private;
ALTER FUNCTION public.disburse_additional_expense(UUID,BIGINT,BIGINT,UUID,TEXT,UUID) RENAME TO acp6a_disburse_additional_core;
ALTER FUNCTION public.acp6a_disburse_additional_core(UUID,BIGINT,BIGINT,UUID,TEXT,UUID) SET SCHEMA private;

CREATE FUNCTION public.save_expense_category(p_category_id UUID,p_master_version BIGINT,p_category_name TEXT,p_description TEXT,p_transaction_category_id UUID,p_expense_account_id UUID,p_evidence_policy TEXT,p_approval_policy TEXT,p_default_payment_method_id UUID,p_is_active BOOLEAN)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$ DECLARE v_company UUID:=public.private_active_company_id(); BEGIN PERFORM private.acp_require_permission_capability(v_company,'finance.expenses','MANAGE'); RETURN private.acp6a_save_expense_category_core(p_category_id,p_master_version,p_category_name,p_description,p_transaction_category_id,p_expense_account_id,p_evidence_policy,p_approval_policy,p_default_payment_method_id,p_is_active); END $$;
CREATE FUNCTION public.save_expense_approval_policy(p_store_id UUID,p_master_version BIGINT,p_approval_required BOOLEAN,p_is_active BOOLEAN)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$ DECLARE v_company UUID:=public.private_active_company_id(); BEGIN PERFORM private.acp_require_permission_capability(v_company,'finance.expenses','MANAGE'); RETURN private.acp6a_save_expense_approval_policy_core(p_store_id,p_master_version,p_approval_required,p_is_active); END $$;
CREATE FUNCTION public.save_expense_draft(p_document_id UUID,p_master_version BIGINT,p_store_id UUID,p_cashier_session_id UUID,p_category_id UUID,p_responsible_party_type TEXT,p_responsible_party_id UUID,p_responsible_party_name TEXT,p_requested_amount NUMERIC,p_payment_method_id UUID,p_recipient TEXT,p_description TEXT,p_evidence_url TEXT,p_expected_settlement_date DATE,p_client_expense_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$ DECLARE v_company UUID:=public.private_active_company_id(); BEGIN PERFORM private.acp_require_expense_channel_mutation(v_company); RETURN private.acp6a_save_expense_draft_core(p_document_id,p_master_version,p_store_id,p_cashier_session_id,p_category_id,p_responsible_party_type,p_responsible_party_id,p_responsible_party_name,p_requested_amount,p_payment_method_id,p_recipient,p_description,p_evidence_url,p_expected_settlement_date,p_client_expense_id); END $$;
CREATE FUNCTION public.submit_expense_request(p_document_id UUID,p_master_version BIGINT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$ DECLARE v_company UUID:=public.private_active_company_id(); BEGIN PERFORM private.acp_require_expense_channel_mutation(v_company); RETURN private.acp6a_submit_expense_request_core(p_document_id,p_master_version); END $$;
CREATE FUNCTION public.review_expense_request(p_document_id UUID,p_master_version BIGINT,p_approve BOOLEAN,p_reason TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$ DECLARE v_company UUID:=public.private_active_company_id(); BEGIN PERFORM private.acp_require_permission_capability(v_company,'finance.expenses','APPROVE'); RETURN private.acp6a_review_expense_request_core(p_document_id,p_master_version,p_approve,p_reason); END $$;
CREATE FUNCTION public.cancel_expense_request(p_document_id UUID,p_master_version BIGINT,p_reason TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$ DECLARE v_company UUID:=public.private_active_company_id();v_creator UUID; BEGIN SELECT created_by INTO v_creator FROM public.expense_documents WHERE company_id=v_company AND id=p_document_id; IF v_creator=auth.uid() THEN PERFORM private.acp_require_expense_channel_mutation(v_company); ELSE PERFORM private.acp_require_permission_capability(v_company,'finance.expenses','CANCEL_FINAL'); END IF; RETURN private.acp6a_cancel_expense_request_core(p_document_id,p_master_version,p_reason); END $$;
CREATE FUNCTION public.disburse_expense(p_document_id UUID,p_master_version BIGINT,p_cashier_session_id UUID,p_evidence_url TEXT,p_idempotency_key UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$ DECLARE v_company UUID:=public.private_active_company_id(); BEGIN IF p_cashier_session_id IS NULL THEN PERFORM private.acp_require_permission_capability(v_company,'finance.expenses','POST'); ELSE PERFORM private.acp_require_expense_channel_mutation(v_company); END IF; RETURN private.acp6a_disburse_expense_core(p_document_id,p_master_version,p_cashier_session_id,p_evidence_url,p_idempotency_key); END $$;
CREATE FUNCTION public.save_expense_settlement(p_document_id UUID,p_master_version BIGINT,p_actual_expense_amount NUMERIC,p_evidence_url TEXT,p_idempotency_key UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$ DECLARE v_company UUID:=public.private_active_company_id(); BEGIN PERFORM private.acp_require_expense_channel_mutation(v_company); RETURN private.acp6a_save_expense_settlement_core(p_document_id,p_master_version,p_actual_expense_amount,p_evidence_url,p_idempotency_key); END $$;
CREATE FUNCTION public.review_expense_settlement(p_settlement_request_id UUID,p_master_version BIGINT,p_action TEXT,p_reason TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$ DECLARE v_company UUID:=public.private_active_company_id(); BEGIN PERFORM private.acp_require_permission_capability(v_company,'finance.expenses','APPROVE'); RETURN private.acp6a_review_expense_settlement_core(p_settlement_request_id,p_master_version,p_action,p_reason); END $$;
CREATE FUNCTION public.return_expense_funds(p_document_id UUID,p_master_version BIGINT,p_amount NUMERIC,p_payment_method_id UUID,p_receiving_session_id UUID,p_evidence_url TEXT,p_idempotency_key UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$ DECLARE v_company UUID:=public.private_active_company_id(); BEGIN IF p_receiving_session_id IS NULL THEN PERFORM private.acp_require_permission_capability(v_company,'finance.expenses','POST'); ELSE PERFORM private.acp_require_expense_channel_mutation(v_company); END IF; RETURN private.acp6a_return_expense_funds_core(p_document_id,p_master_version,p_amount,p_payment_method_id,p_receiving_session_id,p_evidence_url,p_idempotency_key); END $$;
CREATE FUNCTION public.request_additional_expense_disbursement(p_document_id UUID,p_master_version BIGINT,p_amount NUMERIC,p_payment_method_id UUID,p_evidence_url TEXT,p_idempotency_key UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$ DECLARE v_company UUID:=public.private_active_company_id(); BEGIN PERFORM private.acp_require_expense_channel_mutation(v_company); RETURN private.acp6a_request_additional_core(p_document_id,p_master_version,p_amount,p_payment_method_id,p_evidence_url,p_idempotency_key); END $$;
CREATE FUNCTION public.review_additional_expense_disbursement(p_request_id UUID,p_master_version BIGINT,p_action TEXT,p_reason TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$ DECLARE v_company UUID:=public.private_active_company_id(); BEGIN PERFORM private.acp_require_permission_capability(v_company,'finance.expenses','APPROVE'); RETURN private.acp6a_review_additional_core(p_request_id,p_master_version,p_action,p_reason); END $$;
CREATE FUNCTION public.disburse_additional_expense(p_request_id UUID,p_request_master_version BIGINT,p_document_master_version BIGINT,p_cashier_session_id UUID,p_evidence_url TEXT,p_idempotency_key UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$ DECLARE v_company UUID:=public.private_active_company_id(); BEGIN IF p_cashier_session_id IS NULL THEN PERFORM private.acp_require_permission_capability(v_company,'finance.expenses','POST'); ELSE PERFORM private.acp_require_expense_channel_mutation(v_company); END IF; RETURN private.acp6a_disburse_additional_core(p_request_id,p_request_master_version,p_document_master_version,p_cashier_session_id,p_evidence_url,p_idempotency_key); END $$;

UPDATE public.access_permission_catalog SET
  supported_capabilities=ARRAY['VIEW','CREATE_DRAFT','EDIT_DRAFT','MANAGE',
    'REVIEW','APPROVE','POST','CANCEL_FINAL']::TEXT[],
  enforcement_status='ENFORCED',catalog_version=catalog_version+1,
  updated_at=clock_timestamp()
WHERE permission_key='finance.expenses' AND enforcement_status='SHADOW';

REVOKE SELECT ON public.expense_categories,public.expense_approval_policies,
  public.expense_documents,public.expense_disbursements,public.expense_returns,
  public.expense_settlement_requests,public.expense_settlements,
  public.expense_additional_disbursement_requests,public.expense_audit
FROM authenticated;

REVOKE ALL ON FUNCTION private.acp_require_expense_channel_mutation(UUID) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.acp_require_expense_channel_mutation(UUID) TO service_role;
REVOKE ALL ON FUNCTION
  private.acp6a_save_expense_category_core(UUID,BIGINT,TEXT,TEXT,UUID,UUID,TEXT,TEXT,UUID,BOOLEAN),
  private.acp6a_save_expense_approval_policy_core(UUID,BIGINT,BOOLEAN,BOOLEAN),
  private.acp6a_save_expense_draft_core(UUID,BIGINT,UUID,UUID,UUID,TEXT,UUID,TEXT,NUMERIC,UUID,TEXT,TEXT,TEXT,DATE,UUID),
  private.acp6a_submit_expense_request_core(UUID,BIGINT),
  private.acp6a_review_expense_request_core(UUID,BIGINT,BOOLEAN,TEXT),
  private.acp6a_cancel_expense_request_core(UUID,BIGINT,TEXT),
  private.acp6a_disburse_expense_core(UUID,BIGINT,UUID,TEXT,UUID),
  private.acp6a_save_expense_settlement_core(UUID,BIGINT,NUMERIC,TEXT,UUID),
  private.acp6a_review_expense_settlement_core(UUID,BIGINT,TEXT,TEXT),
  private.acp6a_return_expense_funds_core(UUID,BIGINT,NUMERIC,UUID,UUID,TEXT,UUID),
  private.acp6a_request_additional_core(UUID,BIGINT,NUMERIC,UUID,TEXT,UUID),
  private.acp6a_review_additional_core(UUID,BIGINT,TEXT,TEXT),
  private.acp6a_disburse_additional_core(UUID,BIGINT,BIGINT,UUID,TEXT,UUID)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.acp6a_save_expense_category_core(UUID,BIGINT,TEXT,TEXT,UUID,UUID,TEXT,TEXT,UUID,BOOLEAN),
  private.acp6a_save_expense_approval_policy_core(UUID,BIGINT,BOOLEAN,BOOLEAN),
  private.acp6a_save_expense_draft_core(UUID,BIGINT,UUID,UUID,UUID,TEXT,UUID,TEXT,NUMERIC,UUID,TEXT,TEXT,TEXT,DATE,UUID),
  private.acp6a_submit_expense_request_core(UUID,BIGINT),
  private.acp6a_review_expense_request_core(UUID,BIGINT,BOOLEAN,TEXT),
  private.acp6a_cancel_expense_request_core(UUID,BIGINT,TEXT),
  private.acp6a_disburse_expense_core(UUID,BIGINT,UUID,TEXT,UUID),
  private.acp6a_save_expense_settlement_core(UUID,BIGINT,NUMERIC,TEXT,UUID),
  private.acp6a_review_expense_settlement_core(UUID,BIGINT,TEXT,TEXT),
  private.acp6a_return_expense_funds_core(UUID,BIGINT,NUMERIC,UUID,UUID,TEXT,UUID),
  private.acp6a_request_additional_core(UUID,BIGINT,NUMERIC,UUID,TEXT,UUID),
  private.acp6a_review_additional_core(UUID,BIGINT,TEXT,TEXT),
  private.acp6a_disburse_additional_core(UUID,BIGINT,BIGINT,UUID,TEXT,UUID)
TO service_role;
REVOKE ALL ON FUNCTION public.get_finance_expenses(TEXT),public.get_pos_expense_categories(UUID),public.get_pos_expense_workspace(UUID) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_finance_expenses(TEXT),public.get_pos_expense_categories(UUID),public.get_pos_expense_workspace(UUID) TO authenticated,service_role;
REVOKE ALL ON FUNCTION
  public.save_expense_category(UUID,BIGINT,TEXT,TEXT,UUID,UUID,TEXT,TEXT,UUID,BOOLEAN),
  public.save_expense_approval_policy(UUID,BIGINT,BOOLEAN,BOOLEAN),
  public.save_expense_draft(UUID,BIGINT,UUID,UUID,UUID,TEXT,UUID,TEXT,NUMERIC,UUID,TEXT,TEXT,TEXT,DATE,UUID),
  public.submit_expense_request(UUID,BIGINT),
  public.review_expense_request(UUID,BIGINT,BOOLEAN,TEXT),
  public.cancel_expense_request(UUID,BIGINT,TEXT),
  public.disburse_expense(UUID,BIGINT,UUID,TEXT,UUID),
  public.save_expense_settlement(UUID,BIGINT,NUMERIC,TEXT,UUID),
  public.review_expense_settlement(UUID,BIGINT,TEXT,TEXT),
  public.return_expense_funds(UUID,BIGINT,NUMERIC,UUID,UUID,TEXT,UUID),
  public.request_additional_expense_disbursement(UUID,BIGINT,NUMERIC,UUID,TEXT,UUID),
  public.review_additional_expense_disbursement(UUID,BIGINT,TEXT,TEXT),
  public.disburse_additional_expense(UUID,BIGINT,BIGINT,UUID,TEXT,UUID)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION
  public.save_expense_category(UUID,BIGINT,TEXT,TEXT,UUID,UUID,TEXT,TEXT,UUID,BOOLEAN),
  public.save_expense_approval_policy(UUID,BIGINT,BOOLEAN,BOOLEAN),
  public.save_expense_draft(UUID,BIGINT,UUID,UUID,UUID,TEXT,UUID,TEXT,NUMERIC,UUID,TEXT,TEXT,TEXT,DATE,UUID),
  public.submit_expense_request(UUID,BIGINT),
  public.review_expense_request(UUID,BIGINT,BOOLEAN,TEXT),
  public.cancel_expense_request(UUID,BIGINT,TEXT),
  public.disburse_expense(UUID,BIGINT,UUID,TEXT,UUID),
  public.save_expense_settlement(UUID,BIGINT,NUMERIC,TEXT,UUID),
  public.review_expense_settlement(UUID,BIGINT,TEXT,TEXT),
  public.return_expense_funds(UUID,BIGINT,NUMERIC,UUID,UUID,TEXT,UUID),
  public.request_additional_expense_disbursement(UUID,BIGINT,NUMERIC,UUID,TEXT,UUID),
  public.review_additional_expense_disbursement(UUID,BIGINT,TEXT,TEXT),
  public.disburse_additional_expense(UUID,BIGINT,BIGINT,UUID,TEXT,UUID)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260813060000','acp_phase6a_expense_permission_enforcement',
  'Expense capability enforcement with guarded Backoffice reads and independent Cashier session channel');

COMMIT;
