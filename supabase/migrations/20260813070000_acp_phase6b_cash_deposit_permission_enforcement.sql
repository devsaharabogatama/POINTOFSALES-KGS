-- ACP-6B: enforce Cash Deposit Backoffice capabilities while preserving the
-- independent Cashier closed-session/Store channel and Deposit Variance scope.

BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260813060000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: ACP-6A required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260813070000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED';
  END IF;
  IF (SELECT count(*) FROM public.access_permission_catalog
    WHERE permission_key='finance.cash_deposits'
      AND enforcement_status='SHADOW')<>1 THEN
    RAISE EXCEPTION 'CASH_DEPOSIT_PERMISSION_NOT_SHADOW';
  END IF;
END
$guard$;

-- A custom override can narrow the existing Cashier Store/session authority,
-- but this helper never grants Store access or Cashier authority by itself.
CREATE FUNCTION private.acp_require_cash_deposit_channel_mutation(
  p_company UUID
) RETURNS VOID LANGUAGE plpgsql STABLE SECURITY DEFINER
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
    AND permission_key='finance.cash_deposits';
  IF v_preset IN('LIHAT_SAJA','TANPA_AKSES') THEN
    RAISE EXCEPTION
      'PERMISSION_CAPABILITY_REQUIRED: finance.cash_deposits channel mutation';
  END IF;
END
$$;

CREATE FUNCTION public.get_finance_cash_deposits(p_status TEXT DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
  v_status TEXT:=NULLIF(upper(btrim(p_status)),'');
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'finance.cash_deposits','VIEW');
  IF v_status IS NOT NULL AND v_status NOT IN(
    'DRAFT','SUBMITTED','APPROVED','REJECTED','CANCELED'
  ) THEN RAISE EXCEPTION 'CASH_DEPOSIT_STATUS_INVALID'; END IF;

  RETURN jsonb_build_object(
    'companyId',v_company,
    'data',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',document.id,'company_id',document.company_id,
      'store_id',document.store_id,'deposit_no',document.deposit_no,
      'destination_type',document.destination_type,
      'destination_name_snapshot',document.destination_name_snapshot,
      'actual_deposit_amount',document.actual_deposit_amount,
      'total_expected_deposit',document.total_expected_deposit,
      'deposit_variance',document.deposit_variance,
      'variance_type',document.variance_type,'deposit_at',document.deposit_at,
      'evidence_url',document.evidence_url,'notes',document.notes,
      'status',document.status,'proof_mode_snapshot',document.proof_mode_snapshot,
      'master_version',document.master_version,
      'created_by',document.created_by,'submitted_by',document.submitted_by,
      'approved_by',document.approved_by,'rejected_by',document.rejected_by,
      'canceled_by',document.canceled_by,'created_at',document.created_at,
      'updated_at',document.updated_at,'submitted_at',document.submitted_at,
      'approved_at',document.approved_at,'rejected_at',document.rejected_at,
      'canceled_at',document.canceled_at,
      'rejection_reason',document.rejection_reason,
      'cancel_reason',document.cancel_reason,
      'financial_event_id',document.financial_event_id
    ) ORDER BY document.created_at DESC,document.id DESC),'[]'::JSONB)
    FROM (SELECT candidate.* FROM public.cash_deposit_documents candidate
      WHERE candidate.company_id=v_company
        AND (v_status IS NULL OR candidate.status=v_status)
      ORDER BY candidate.created_at DESC,candidate.id DESC LIMIT 500) document),
    'lines',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',line.id,'deposit_document_id',line.deposit_document_id,
      'store_id',line.store_id,'cashier_session_id',line.cashier_session_id,
      'line_no',line.line_no,'session_code_snapshot',line.session_code_snapshot,
      'cashier_id',line.cashier_id,
      'cashier_name_snapshot',line.cashier_name_snapshot,
      'closing_cash_actual_snapshot',line.closing_cash_actual_snapshot,
      'next_session_float_reserved',line.next_session_float_reserved,
      'posted_deposit_allocations_snapshot',
        line.posted_deposit_allocations_snapshot,
      'expected_deposit_amount',line.expected_deposit_amount,
      'allocation_status',line.allocation_status
    ) ORDER BY document.created_at DESC,line.line_no,line.id),'[]'::JSONB)
    FROM public.cash_deposit_session_lines line
    JOIN public.cash_deposit_documents document
      ON document.company_id=line.company_id
     AND document.id=line.deposit_document_id
    WHERE line.company_id=v_company
      AND (v_status IS NULL OR document.status=v_status)),
    'stores',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',store.id,'store_name',store.store_name)
      ORDER BY store.store_name,store.id),'[]'::JSONB)
    FROM public.stores store WHERE store.company_id=v_company
      AND EXISTS(SELECT 1 FROM public.cash_deposit_documents document
        WHERE document.company_id=v_company AND document.store_id=store.id
          AND (v_status IS NULL OR document.status=v_status))),
    'actors',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',profile.id,'name',profile.name) ORDER BY profile.name,profile.id),
      '[]'::JSONB) FROM public.profiles profile WHERE EXISTS(SELECT 1
        FROM public.cash_deposit_documents document
        WHERE document.company_id=v_company
          AND profile.id IN(document.created_by,document.submitted_by,
            document.approved_by,document.rejected_by,document.canceled_by)
          AND (v_status IS NULL OR document.status=v_status)))
  );
END
$$;

-- Deposit Variance obtains only its linked Deposit labels through its own key.
CREATE FUNCTION public.get_deposit_variance_cash_deposit_references()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'finance.deposit_variances','VIEW');
  RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object(
    'id',document.id,'deposit_no',document.deposit_no,
    'destination_type',document.destination_type,
    'destination_name_snapshot',document.destination_name_snapshot,
    'total_expected_deposit',document.total_expected_deposit,
    'actual_deposit_amount',document.actual_deposit_amount,
    'deposit_variance',document.deposit_variance,
    'deposit_at',document.deposit_at,'evidence_url',document.evidence_url,
    'approved_at',document.approved_at,'store_id',document.store_id,
    'status',document.status
  ) ORDER BY document.deposit_at DESC,document.id DESC)
  FROM public.cash_deposit_documents document
  WHERE document.company_id=v_company AND EXISTS(
    SELECT 1 FROM public.deposit_variance_exceptions exception
    WHERE exception.company_id=v_company
      AND exception.cash_deposit_document_id=document.id
  )),'[]'::JSONB);
END
$$;

-- Preserve the reviewed transaction implementations as private trusted cores.
ALTER FUNCTION public.list_cash_deposit_eligible_sessions(UUID)
  SET SCHEMA private;
ALTER FUNCTION private.list_cash_deposit_eligible_sessions(UUID)
  RENAME TO acp6b_list_cash_deposit_eligible_sessions_core;
ALTER FUNCTION public.save_cash_deposit_draft(
  UUID,BIGINT,UUID,TEXT,TEXT,NUMERIC,TIMESTAMPTZ,TEXT,TEXT,UUID,JSONB)
  SET SCHEMA private;
ALTER FUNCTION private.save_cash_deposit_draft(
  UUID,BIGINT,UUID,TEXT,TEXT,NUMERIC,TIMESTAMPTZ,TEXT,TEXT,UUID,JSONB)
  RENAME TO acp6b_save_cash_deposit_draft_core;
ALTER FUNCTION public.submit_cash_deposit(UUID,BIGINT,UUID)
  SET SCHEMA private;
ALTER FUNCTION private.submit_cash_deposit(UUID,BIGINT,UUID)
  RENAME TO acp6b_submit_cash_deposit_core;
ALTER FUNCTION public.review_cash_deposit(UUID,BIGINT,TEXT,TEXT,UUID)
  SET SCHEMA private;
ALTER FUNCTION private.review_cash_deposit(UUID,BIGINT,TEXT,TEXT,UUID)
  RENAME TO acp6b_review_cash_deposit_core;
ALTER FUNCTION public.cancel_cash_deposit(UUID,BIGINT,TEXT)
  SET SCHEMA private;
ALTER FUNCTION private.cancel_cash_deposit(UUID,BIGINT,TEXT)
  RENAME TO acp6b_cancel_cash_deposit_core;

CREATE FUNCTION public.list_cash_deposit_eligible_sessions(p_store_id UUID)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_cash_deposit_channel_mutation(v_company);
  RETURN private.acp6b_list_cash_deposit_eligible_sessions_core(p_store_id);
END
$$;

CREATE FUNCTION public.save_cash_deposit_draft(
  p_document_id UUID,p_master_version BIGINT,p_store_id UUID,
  p_destination_type TEXT,p_destination_name TEXT,
  p_actual_deposit_amount NUMERIC,p_deposit_at TIMESTAMPTZ,
  p_evidence_url TEXT,p_notes TEXT,p_client_deposit_id UUID,p_sessions JSONB
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_cash_deposit_channel_mutation(v_company);
  RETURN private.acp6b_save_cash_deposit_draft_core(
    p_document_id,p_master_version,p_store_id,p_destination_type,
    p_destination_name,p_actual_deposit_amount,p_deposit_at,p_evidence_url,
    p_notes,p_client_deposit_id,p_sessions);
END
$$;

CREATE FUNCTION public.submit_cash_deposit(
  p_document_id UUID,p_master_version BIGINT,p_idempotency_key UUID
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_cash_deposit_channel_mutation(v_company);
  RETURN private.acp6b_submit_cash_deposit_core(
    p_document_id,p_master_version,p_idempotency_key);
END
$$;

CREATE FUNCTION public.review_cash_deposit(
  p_document_id UUID,p_master_version BIGINT,p_action TEXT,
  p_reason TEXT,p_idempotency_key UUID
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
  v_action TEXT:=upper(btrim(COALESCE(p_action,'')));
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'finance.cash_deposits',
    CASE WHEN v_action='APPROVE' THEN 'APPROVE' ELSE 'REVIEW' END);
  RETURN private.acp6b_review_cash_deposit_core(
    p_document_id,p_master_version,p_action,p_reason,p_idempotency_key);
END
$$;

CREATE FUNCTION public.cancel_cash_deposit(
  p_document_id UUID,p_master_version BIGINT,p_reason TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_cash_deposit_channel_mutation(v_company);
  RETURN private.acp6b_cancel_cash_deposit_core(
    p_document_id,p_master_version,p_reason);
END
$$;

UPDATE public.access_permission_catalog SET
  enforcement_status='ENFORCED',catalog_version=catalog_version+1,
  updated_at=clock_timestamp()
WHERE permission_key='finance.cash_deposits' AND enforcement_status='SHADOW';

REVOKE SELECT ON public.cash_deposit_policies,public.cash_deposit_documents,
  public.cash_deposit_session_lines,public.cash_deposit_audit
FROM authenticated;

REVOKE ALL ON FUNCTION
  private.acp_require_cash_deposit_channel_mutation(UUID),
  private.acp6b_list_cash_deposit_eligible_sessions_core(UUID),
  private.acp6b_save_cash_deposit_draft_core(
    UUID,BIGINT,UUID,TEXT,TEXT,NUMERIC,TIMESTAMPTZ,TEXT,TEXT,UUID,JSONB),
  private.acp6b_submit_cash_deposit_core(UUID,BIGINT,UUID),
  private.acp6b_review_cash_deposit_core(UUID,BIGINT,TEXT,TEXT,UUID),
  private.acp6b_cancel_cash_deposit_core(UUID,BIGINT,TEXT)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.acp_require_cash_deposit_channel_mutation(UUID),
  private.acp6b_list_cash_deposit_eligible_sessions_core(UUID),
  private.acp6b_save_cash_deposit_draft_core(
    UUID,BIGINT,UUID,TEXT,TEXT,NUMERIC,TIMESTAMPTZ,TEXT,TEXT,UUID,JSONB),
  private.acp6b_submit_cash_deposit_core(UUID,BIGINT,UUID),
  private.acp6b_review_cash_deposit_core(UUID,BIGINT,TEXT,TEXT,UUID),
  private.acp6b_cancel_cash_deposit_core(UUID,BIGINT,TEXT)
TO service_role;

REVOKE ALL ON FUNCTION
  public.get_finance_cash_deposits(TEXT),
  public.get_deposit_variance_cash_deposit_references(),
  public.list_cash_deposit_eligible_sessions(UUID),
  public.save_cash_deposit_draft(
    UUID,BIGINT,UUID,TEXT,TEXT,NUMERIC,TIMESTAMPTZ,TEXT,TEXT,UUID,JSONB),
  public.submit_cash_deposit(UUID,BIGINT,UUID),
  public.review_cash_deposit(UUID,BIGINT,TEXT,TEXT,UUID),
  public.cancel_cash_deposit(UUID,BIGINT,TEXT)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION
  public.get_finance_cash_deposits(TEXT),
  public.get_deposit_variance_cash_deposit_references(),
  public.list_cash_deposit_eligible_sessions(UUID),
  public.save_cash_deposit_draft(
    UUID,BIGINT,UUID,TEXT,TEXT,NUMERIC,TIMESTAMPTZ,TEXT,TEXT,UUID,JSONB),
  public.submit_cash_deposit(UUID,BIGINT,UUID),
  public.review_cash_deposit(UUID,BIGINT,TEXT,TEXT,UUID),
  public.cancel_cash_deposit(UUID,BIGINT,TEXT)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260813070000','acp_phase6b_cash_deposit_permission_enforcement',
  'Cash Deposit capability enforcement with separate Cashier and Deposit Variance channels');

COMMIT;
