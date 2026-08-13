-- ACP-6D: enforce Customer Balance capabilities while preserving the proven
-- POS credit/tender paths and Finance HOLD boundary.

BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260813080000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: ACP-6C required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260813090000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED';
  END IF;
  IF (SELECT count(*) FROM public.access_permission_catalog
    WHERE permission_key='finance.customer_balances'
      AND enforcement_status='SHADOW')<>1 THEN
    RAISE EXCEPTION 'CUSTOMER_BALANCE_PERMISSION_NOT_SHADOW';
  END IF;
  IF EXISTS(SELECT 1 FROM public.customers customer
    WHERE customer.current_balance<>COALESCE((SELECT sum(CASE
      WHEN entry.direction='CREDIT' THEN entry.amount ELSE -entry.amount END)
      FROM public.customer_balance_ledger_entries entry
      WHERE entry.company_id=customer.company_id
        AND entry.customer_id=customer.id),0)) THEN
    RAISE EXCEPTION 'CUSTOMER_BALANCE_HISTORY_NOT_RECONCILED';
  END IF;
END
$guard$;

CREATE FUNCTION public.get_finance_customer_balances()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'finance.customer_balances','VIEW');
  RETURN jsonb_build_object(
    'companyId',v_company,'currentUserId',auth.uid(),
    'customers',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',customer.id,'name',customer.name,
      'current_balance',customer.current_balance,
      'is_active',customer.is_active)
      ORDER BY customer.name,customer.id),'[]'::JSONB)
    FROM public.customers customer WHERE customer.company_id=v_company
      AND NOT customer.is_system_customer),
    'requests',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',request.id,'customer_id',request.customer_id,
      'store_id',request.store_id,'request_no',request.request_no,
      'direction',request.direction,'amount',request.amount,
      'source_account_function',request.source_account_function,
      'reason',request.reason,'evidence_url',request.evidence_url,
      'status',request.status,'ledger_entry_id',request.ledger_entry_id,
      'created_by',request.created_by,'reviewed_by',request.reviewed_by,
      'created_at',request.created_at,'reviewed_at',request.reviewed_at,
      'rejection_reason',request.rejection_reason,
      'master_version',request.master_version)
      ORDER BY request.created_at DESC,request.id DESC),'[]'::JSONB)
    FROM (SELECT candidate.*
      FROM public.customer_balance_correction_requests candidate
      WHERE candidate.company_id=v_company
      ORDER BY candidate.created_at DESC,candidate.id DESC LIMIT 500) request),
    'policy',(SELECT CASE WHEN policy.id IS NULL THEN NULL ELSE
      jsonb_build_object('lifecycle_state',policy.lifecycle_state,
        'master_version',policy.master_version) END
      FROM (SELECT candidate.*
        FROM public.customer_balance_company_policies candidate
        WHERE candidate.company_id=v_company LIMIT 1) policy),
    'stores',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',store.id,'store_name',store.store_name)
      ORDER BY store.store_name,store.id),'[]'::JSONB)
      FROM public.stores store WHERE store.company_id=v_company
        AND store.status='ACTIVE'),
    'actors',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',profile.id,'name',profile.name,'email',profile.email)
      ORDER BY profile.name,profile.id),'[]'::JSONB)
      FROM public.profiles profile WHERE EXISTS(SELECT 1
        FROM public.customer_balance_correction_requests request
        WHERE request.company_id=v_company
          AND profile.id IN(request.created_by,request.reviewed_by)))
  );
END
$$;

CREATE FUNCTION public.export_finance_customer_balances(
  p_from TIMESTAMPTZ,p_to TIMESTAMPTZ
) RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'finance.customer_balances','EXPORT');
  IF p_from IS NULL OR p_to IS NULL OR p_from>p_to THEN
    RAISE EXCEPTION 'CUSTOMER_BALANCE_EXPORT_PERIOD_INVALID';
  END IF;
  RETURN jsonb_build_object(
    'periodFrom',p_from,'periodTo',p_to,
    'customerCount',(SELECT count(*) FROM public.customers customer
      WHERE customer.company_id=v_company AND NOT customer.is_system_customer),
    'currentBalanceTotal',(SELECT COALESCE(sum(customer.current_balance),0)
      FROM public.customers customer WHERE customer.company_id=v_company
        AND NOT customer.is_system_customer),
    'rows',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'customerName',customer.name,'customerCode',customer.code,
      'currentBalance',customer.current_balance,
      'entryNo',entry.entry_no,'transactionAt',entry.created_at,
      'direction',entry.direction,'amount',COALESCE(entry.amount,0),
      'balanceBefore',entry.balance_before,
      'balanceAfter',COALESCE(entry.balance_after,customer.current_balance),
      'sourceType',entry.source_type,
      'sourceReference',entry.source_reference,'reason',entry.reason)
      ORDER BY customer.name,entry.created_at,entry.entry_no),'[]'::JSONB)
      FROM public.customers customer
      LEFT JOIN public.customer_balance_ledger_entries entry
        ON entry.company_id=customer.company_id
       AND entry.customer_id=customer.id
       AND entry.created_at>=p_from
       AND entry.created_at<=p_to
      WHERE customer.company_id=v_company AND NOT customer.is_system_customer)
  );
END
$$;

-- Preserve proven G4 implementations behind capability wrappers.
ALTER FUNCTION public.request_customer_balance_correction(
  UUID,UUID,TEXT,NUMERIC,TEXT,TEXT,TEXT,UUID) SET SCHEMA private;
ALTER FUNCTION private.request_customer_balance_correction(
  UUID,UUID,TEXT,NUMERIC,TEXT,TEXT,TEXT,UUID)
  RENAME TO acp6d_request_customer_balance_core;
ALTER FUNCTION public.review_customer_balance_correction(
  UUID,BIGINT,TEXT,TEXT,UUID) SET SCHEMA private;
ALTER FUNCTION private.review_customer_balance_correction(
  UUID,BIGINT,TEXT,TEXT,UUID) RENAME TO acp6d_review_customer_balance_core;
ALTER FUNCTION public.get_customer_balance_statement(
  UUID,TIMESTAMPTZ,TIMESTAMPTZ) SET SCHEMA private;
ALTER FUNCTION private.get_customer_balance_statement(
  UUID,TIMESTAMPTZ,TIMESTAMPTZ) RENAME TO acp6d_customer_balance_statement_core;

CREATE FUNCTION public.request_customer_balance_correction(
  p_customer_id UUID,p_store_id UUID,p_direction TEXT,p_amount NUMERIC,
  p_source_account_function TEXT,p_reason TEXT,p_evidence_url TEXT,
  p_idempotency_key UUID
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'finance.customer_balances','MANAGE');
  RETURN private.acp6d_request_customer_balance_core(
    p_customer_id,p_store_id,p_direction,p_amount,p_source_account_function,
    p_reason,p_evidence_url,p_idempotency_key);
END
$$;

CREATE FUNCTION public.review_customer_balance_correction(
  p_request_id UUID,p_master_version BIGINT,p_action TEXT,
  p_reason TEXT,p_idempotency_key UUID
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
  v_action TEXT:=upper(btrim(COALESCE(p_action,'')));
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'finance.customer_balances',
    CASE WHEN v_action='APPROVE' THEN 'APPROVE' ELSE 'REVIEW' END);
  RETURN private.acp6d_review_customer_balance_core(
    p_request_id,p_master_version,p_action,p_reason,p_idempotency_key);
END
$$;

CREATE FUNCTION public.get_customer_balance_statement(
  p_customer_id UUID,p_from TIMESTAMPTZ DEFAULT NULL,
  p_to TIMESTAMPTZ DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'finance.customer_balances','VIEW');
  RETURN private.acp6d_customer_balance_statement_core(
    p_customer_id,p_from,p_to);
END
$$;

UPDATE public.access_permission_catalog SET
  enforcement_status='ENFORCED',catalog_version=catalog_version+1,
  updated_at=clock_timestamp()
WHERE permission_key='finance.customer_balances'
  AND enforcement_status='SHADOW';

REVOKE SELECT ON public.customer_balance_company_policies,
  public.customer_balance_correction_requests,
  public.customer_balance_ledger_entries,public.customer_balance_audit
FROM authenticated;

REVOKE ALL ON FUNCTION
  private.acp6d_request_customer_balance_core(
    UUID,UUID,TEXT,NUMERIC,TEXT,TEXT,TEXT,UUID),
  private.acp6d_review_customer_balance_core(UUID,BIGINT,TEXT,TEXT,UUID),
  private.acp6d_customer_balance_statement_core(
    UUID,TIMESTAMPTZ,TIMESTAMPTZ)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.acp6d_request_customer_balance_core(
    UUID,UUID,TEXT,NUMERIC,TEXT,TEXT,TEXT,UUID),
  private.acp6d_review_customer_balance_core(UUID,BIGINT,TEXT,TEXT,UUID),
  private.acp6d_customer_balance_statement_core(
    UUID,TIMESTAMPTZ,TIMESTAMPTZ)
TO service_role;

REVOKE ALL ON FUNCTION public.get_finance_customer_balances(),
  public.export_finance_customer_balances(TIMESTAMPTZ,TIMESTAMPTZ),
  public.request_customer_balance_correction(
    UUID,UUID,TEXT,NUMERIC,TEXT,TEXT,TEXT,UUID),
  public.review_customer_balance_correction(UUID,BIGINT,TEXT,TEXT,UUID),
  public.get_customer_balance_statement(UUID,TIMESTAMPTZ,TIMESTAMPTZ)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_finance_customer_balances(),
  public.export_finance_customer_balances(TIMESTAMPTZ,TIMESTAMPTZ),
  public.request_customer_balance_correction(
    UUID,UUID,TEXT,NUMERIC,TEXT,TEXT,TEXT,UUID),
  public.review_customer_balance_correction(UUID,BIGINT,TEXT,TEXT,UUID),
  public.get_customer_balance_statement(UUID,TIMESTAMPTZ,TIMESTAMPTZ)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260813090000','acp_phase6d_customer_balance_permission_enforcement',
  'Customer Balance composed read/export and correction maker-checker capability enforcement while POS and Finance boundaries remain independent');

COMMIT;
