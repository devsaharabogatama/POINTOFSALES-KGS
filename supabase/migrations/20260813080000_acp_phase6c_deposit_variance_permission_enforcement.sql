-- ACP-6C: enforce Deposit Variance capabilities without releasing Finance
-- HOLD events or granting Cash Deposit authority.

BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260813070000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: ACP-6B required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260813080000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED';
  END IF;
  IF (SELECT count(*) FROM public.access_permission_catalog
    WHERE permission_key='finance.deposit_variances'
      AND enforcement_status='SHADOW')<>1 THEN
    RAISE EXCEPTION 'DEPOSIT_VARIANCE_PERMISSION_NOT_SHADOW';
  END IF;
  IF EXISTS(SELECT 1 FROM public.deposit_variance_resolution_requests request
    LEFT JOIN public.deposit_variance_allocations allocation
      ON allocation.company_id=request.company_id
     AND allocation.id=request.allocation_id
    WHERE request.status='APPROVED' AND (
      allocation.id IS NULL
      OR allocation.resolution_request_id<>request.id
      OR allocation.financial_event_id<>request.financial_event_id)) THEN
    RAISE EXCEPTION 'DEPOSIT_VARIANCE_HISTORY_NOT_RECONCILED';
  END IF;
END
$guard$;

CREATE FUNCTION public.get_finance_deposit_variances()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
  v_permission JSONB;v_can_manage BOOLEAN;
BEGIN
  v_permission:=private.acp_require_permission_capability(
    v_company,'finance.deposit_variances','VIEW');
  v_can_manage:=COALESCE(
    (v_permission->'effectiveCapabilities') ? 'MANAGE',FALSE);

  RETURN jsonb_build_object(
    'companyId',v_company,
    'data',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',exception.id,'store_id',exception.store_id,
      'cash_deposit_document_id',exception.cash_deposit_document_id,
      'variance_type',exception.variance_type,
      'original_amount',exception.original_amount,
      'resolved_amount',exception.resolved_amount,
      'remaining_amount',exception.remaining_amount,'status',exception.status,
      'responsible_party_type',exception.responsible_party_type,
      'responsible_party_id',exception.responsible_party_id,
      'responsible_party_reason',exception.responsible_party_reason,
      'responsible_party_assigned_by',exception.responsible_party_assigned_by,
      'responsible_party_assigned_at',exception.responsible_party_assigned_at,
      'opened_at',exception.opened_at,
      'master_version',exception.master_version,
      'created_by',exception.created_by,'updated_by',exception.updated_by,
      'created_at',exception.created_at,'updated_at',exception.updated_at,
      'resolved_by',exception.resolved_by,'resolved_at',exception.resolved_at,
      'written_off_by',exception.written_off_by,
      'written_off_at',exception.written_off_at
    ) ORDER BY exception.opened_at DESC,exception.id DESC),'[]'::JSONB)
    FROM (SELECT candidate.* FROM public.deposit_variance_exceptions candidate
      WHERE candidate.company_id=v_company
      ORDER BY candidate.opened_at DESC,candidate.id DESC LIMIT 500) exception),
    'requests',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',request.id,'variance_exception_id',request.variance_exception_id,
      'request_no',request.request_no,
      'allocation_amount',request.allocation_amount,
      'resolution_type',request.resolution_type,
      'settlement_account_function',request.settlement_account_function,
      'reason',request.reason,'evidence_url',request.evidence_url,
      'resolution_reference',request.resolution_reference,
      'status',request.status,'requires_review',request.requires_review,
      'allocation_id',request.allocation_id,
      'financial_event_id',request.financial_event_id,
      'created_by',request.created_by,'reviewed_by',request.reviewed_by,
      'created_at',request.created_at,'reviewed_at',request.reviewed_at,
      'rejection_reason',request.rejection_reason,
      'master_version',request.master_version
    ) ORDER BY request.created_at DESC,request.id DESC),'[]'::JSONB)
    FROM public.deposit_variance_resolution_requests request
    WHERE request.company_id=v_company AND EXISTS(SELECT 1
      FROM public.deposit_variance_exceptions exception
      WHERE exception.company_id=v_company
        AND exception.id=request.variance_exception_id)),
    'allocations',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',allocation.id,
      'variance_exception_id',allocation.variance_exception_id,
      'allocation_amount',allocation.allocation_amount,
      'resolution_type',allocation.resolution_type,
      'reason',allocation.reason,'evidence_url',allocation.evidence_url,
      'resolution_reference',allocation.resolution_reference,
      'account_function_snapshot',allocation.account_function_snapshot,
      'submitted_by',allocation.submitted_by,
      'submitted_at',allocation.submitted_at,
      'reviewed_by',allocation.reviewed_by,
      'reviewed_at',allocation.reviewed_at,
      'created_at',allocation.created_at
    ) ORDER BY allocation.created_at DESC,allocation.id DESC),'[]'::JSONB)
    FROM public.deposit_variance_allocations allocation
    WHERE allocation.company_id=v_company AND EXISTS(SELECT 1
      FROM public.deposit_variance_exceptions exception
      WHERE exception.company_id=v_company
        AND exception.id=allocation.variance_exception_id)),
    'documents',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',deposit.id,'deposit_no',deposit.deposit_no,
      'destination_type',deposit.destination_type,
      'destination_name_snapshot',deposit.destination_name_snapshot,
      'total_expected_deposit',deposit.total_expected_deposit,
      'actual_deposit_amount',deposit.actual_deposit_amount,
      'deposit_variance',deposit.deposit_variance,
      'deposit_at',deposit.deposit_at,'evidence_url',deposit.evidence_url,
      'approved_at',deposit.approved_at,'store_id',deposit.store_id,
      'status',deposit.status
    ) ORDER BY deposit.deposit_at DESC,deposit.id DESC),'[]'::JSONB)
    FROM public.cash_deposit_documents deposit
    WHERE deposit.company_id=v_company AND EXISTS(SELECT 1
      FROM public.deposit_variance_exceptions exception
      WHERE exception.company_id=v_company
        AND exception.cash_deposit_document_id=deposit.id)),
    'stores',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',store.id,'store_name',store.store_name)
      ORDER BY store.store_name,store.id),'[]'::JSONB)
    FROM public.stores store WHERE store.company_id=v_company
      AND EXISTS(SELECT 1 FROM public.deposit_variance_exceptions exception
        WHERE exception.company_id=v_company AND exception.store_id=store.id)),
    'actors',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',profile.id,'name',profile.name,
      'email',CASE WHEN v_can_manage THEN profile.email ELSE NULL END)
      ORDER BY profile.name,profile.id),'[]'::JSONB)
    FROM public.profiles profile WHERE EXISTS(SELECT 1
      FROM public.deposit_variance_exceptions exception
      WHERE exception.company_id=v_company AND profile.id IN(
        exception.created_by,exception.updated_by,
        exception.responsible_party_id,
        exception.responsible_party_assigned_by,
        exception.resolved_by,exception.written_off_by))
      OR EXISTS(SELECT 1 FROM public.deposit_variance_resolution_requests request
        WHERE request.company_id=v_company
          AND profile.id IN(request.created_by,request.reviewed_by))
      OR EXISTS(SELECT 1 FROM public.deposit_variance_allocations allocation
        WHERE allocation.company_id=v_company
          AND profile.id IN(allocation.submitted_by,allocation.reviewed_by))
      OR (v_can_manage AND EXISTS(SELECT 1 FROM public.company_memberships membership
        WHERE membership.company_id=v_company AND membership.user_id=profile.id
          AND membership.status='ACTIVE'))),
    'members',(SELECT CASE WHEN v_can_manage THEN COALESCE(jsonb_agg(
      jsonb_build_object('user_id',membership.user_id,
        'role_code',membership.role_code,'profile',jsonb_build_object(
          'id',profile.id,'name',profile.name,'email',profile.email))
      ORDER BY membership.role_code,profile.name,membership.user_id),
      '[]'::JSONB) ELSE '[]'::JSONB END
    FROM public.company_memberships membership
    JOIN public.profiles profile ON profile.id=membership.user_id
    WHERE membership.company_id=v_company AND membership.status='ACTIVE')
  );
END
$$;

-- Preserve the proven G4 transaction implementations as private cores.
ALTER FUNCTION public.assign_deposit_variance_responsible_party(
  UUID,BIGINT,UUID,TEXT) SET SCHEMA private;
ALTER FUNCTION private.assign_deposit_variance_responsible_party(
  UUID,BIGINT,UUID,TEXT) RENAME TO acp6c_assign_responsible_party_core;
ALTER FUNCTION public.resolve_deposit_variance(
  UUID,BIGINT,NUMERIC,TEXT,TEXT,TEXT,TEXT,TEXT,UUID) SET SCHEMA private;
ALTER FUNCTION private.resolve_deposit_variance(
  UUID,BIGINT,NUMERIC,TEXT,TEXT,TEXT,TEXT,TEXT,UUID)
  RENAME TO acp6c_resolve_deposit_variance_core;
ALTER FUNCTION public.review_deposit_variance_resolution(
  UUID,BIGINT,TEXT,TEXT,UUID) SET SCHEMA private;
ALTER FUNCTION private.review_deposit_variance_resolution(
  UUID,BIGINT,TEXT,TEXT,UUID) RENAME TO acp6c_review_resolution_core;

CREATE FUNCTION public.assign_deposit_variance_responsible_party(
  p_exception_id UUID,p_master_version BIGINT,
  p_responsible_user_id UUID,p_reason TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'finance.deposit_variances','MANAGE');
  RETURN private.acp6c_assign_responsible_party_core(
    p_exception_id,p_master_version,p_responsible_user_id,p_reason);
END
$$;

CREATE FUNCTION public.resolve_deposit_variance(
  p_exception_id UUID,p_master_version BIGINT,p_allocation_amount NUMERIC,
  p_resolution_type TEXT,p_settlement_account_function TEXT,p_reason TEXT,
  p_evidence_url TEXT,p_resolution_reference TEXT,p_idempotency_key UUID
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'finance.deposit_variances','MANAGE');
  RETURN private.acp6c_resolve_deposit_variance_core(
    p_exception_id,p_master_version,p_allocation_amount,p_resolution_type,
    p_settlement_account_function,p_reason,p_evidence_url,
    p_resolution_reference,p_idempotency_key);
END
$$;

CREATE FUNCTION public.review_deposit_variance_resolution(
  p_request_id UUID,p_master_version BIGINT,p_action TEXT,
  p_reason TEXT,p_idempotency_key UUID
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
  v_action TEXT:=upper(btrim(COALESCE(p_action,'')));
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'finance.deposit_variances',
    CASE WHEN v_action='APPROVE' THEN 'APPROVE' ELSE 'REVIEW' END);
  RETURN private.acp6c_review_resolution_core(
    p_request_id,p_master_version,p_action,p_reason,p_idempotency_key);
END
$$;

UPDATE public.access_permission_catalog SET
  enforcement_status='ENFORCED',catalog_version=catalog_version+1,
  updated_at=clock_timestamp()
WHERE permission_key='finance.deposit_variances'
  AND enforcement_status='SHADOW';

REVOKE SELECT ON public.deposit_variance_exceptions,
  public.deposit_variance_allocations,
  public.deposit_variance_resolution_requests,
  public.deposit_variance_resolution_audit
FROM authenticated;

REVOKE ALL ON FUNCTION
  private.acp6c_assign_responsible_party_core(UUID,BIGINT,UUID,TEXT),
  private.acp6c_resolve_deposit_variance_core(
    UUID,BIGINT,NUMERIC,TEXT,TEXT,TEXT,TEXT,TEXT,UUID),
  private.acp6c_review_resolution_core(UUID,BIGINT,TEXT,TEXT,UUID)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.acp6c_assign_responsible_party_core(UUID,BIGINT,UUID,TEXT),
  private.acp6c_resolve_deposit_variance_core(
    UUID,BIGINT,NUMERIC,TEXT,TEXT,TEXT,TEXT,TEXT,UUID),
  private.acp6c_review_resolution_core(UUID,BIGINT,TEXT,TEXT,UUID)
TO service_role;

REVOKE ALL ON FUNCTION
  public.get_finance_deposit_variances(),
  public.assign_deposit_variance_responsible_party(UUID,BIGINT,UUID,TEXT),
  public.resolve_deposit_variance(
    UUID,BIGINT,NUMERIC,TEXT,TEXT,TEXT,TEXT,TEXT,UUID),
  public.review_deposit_variance_resolution(UUID,BIGINT,TEXT,TEXT,UUID)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION
  public.get_finance_deposit_variances(),
  public.assign_deposit_variance_responsible_party(UUID,BIGINT,UUID,TEXT),
  public.resolve_deposit_variance(
    UUID,BIGINT,NUMERIC,TEXT,TEXT,TEXT,TEXT,TEXT,UUID),
  public.review_deposit_variance_resolution(UUID,BIGINT,TEXT,TEXT,UUID)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260813080000','acp_phase6c_deposit_variance_permission_enforcement',
  'Deposit Variance composed read and maker-checker capability enforcement while Finance events remain HOLD');

COMMIT;
