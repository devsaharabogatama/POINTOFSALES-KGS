-- SELECT-only diagnosis for the rollback behavior authorization fixture.
-- It identifies whether any pending direct Retail Bank request has a maker
-- who can actually reach the maker-checker guard, and inventories independent
-- approvers without changing Auth, requests, permissions, or Company context.
WITH
pending_bank AS (
  SELECT request.id request_id,request.company_id,request.requested_by,
    request.requested_at,request.master_version,sale.invoice_no,sale.draft_no
  FROM public.sales_payment_verification_requests request
  JOIN public.sales_headers sale
    ON sale.company_id=request.company_id AND sale.id=request.sales_id
  WHERE request.status='PENDING'
    AND request.verification_mode='MANUAL_REVIEW'
    AND request.settlement_route_snapshot='DIRECT_BANK'
    AND sale.sales_origin='POS'
    AND sale.sales_process_mode='RETAIL_CONFIRM_INVOICE'
    AND sale.document_status='POSTED'
    AND sale.order_runtime_status='LEGACY_POSTED'
),
classified AS (
  SELECT request.*,
    (private.acp_resolve_permission(request.company_id,request.requested_by,
      'finance.sales_payment_verification')->'effectiveCapabilities') ? 'APPROVE'
      maker_has_approve,
    (SELECT count(*) FROM (
      SELECT profile.id actor_id
      FROM public.profiles profile
      WHERE profile.role::text='super_admin'
        AND profile.id<>request.requested_by
      UNION
      SELECT membership.user_id
      FROM public.company_memberships membership
      WHERE membership.company_id=request.company_id
        AND membership.status='ACTIVE'
        AND membership.user_id<>request.requested_by
    ) candidate
    WHERE (private.acp_resolve_permission(request.company_id,candidate.actor_id,
      'finance.sales_payment_verification')->'effectiveCapabilities') ? 'APPROVE')
      independent_approver_rows
  FROM pending_bank request
),
first_request AS (
  SELECT * FROM classified ORDER BY requested_at,request_id LIMIT 1
),
reviewers AS (
  SELECT candidate.actor_id,candidate.role_code,
    (private.acp_resolve_permission(first_request.company_id,candidate.actor_id,
      'finance.sales_payment_verification')->'effectiveCapabilities') capabilities
  FROM first_request
  CROSS JOIN LATERAL (
    SELECT profile.id actor_id,'SUPER_ADMIN'::text role_code
    FROM public.profiles profile
    WHERE profile.role::text='super_admin'
      AND profile.id<>first_request.requested_by
    UNION
    SELECT membership.user_id,membership.role_code
    FROM public.company_memberships membership
    WHERE membership.company_id=first_request.company_id
      AND membership.status='ACTIVE'
      AND membership.user_id<>first_request.requested_by
  ) candidate
),
checks AS (
  SELECT 10 seq,
    'pos_retail_non_cash_behavior_permission_fixture_partition'::text check_name,
    CASE WHEN count(*)>0
      AND count(*) FILTER (WHERE independent_approver_rows>0)>0
      THEN 'PASS' ELSE 'BLOCKER' END status,
    CASE WHEN count(*)>0
      AND count(*) FILTER (WHERE independent_approver_rows>0)>0
      THEN 0 ELSE 1 END violation_rows,
    jsonb_build_object('pendingBankRequests',count(*),
      'makerCanApprove',count(*) FILTER (WHERE maker_has_approve),
      'hasIndependentApprover',count(*) FILTER (WHERE independent_approver_rows>0))
      details
  FROM classified
  UNION ALL
  SELECT 20,'pos_retail_non_cash_behavior_permission_selected_request','INFO',0,
    coalesce((SELECT to_jsonb(first_request) FROM first_request),'{}'::jsonb)
  UNION ALL
  SELECT 30,'pos_retail_non_cash_behavior_permission_reviewer_inventory','INFO',0,
    jsonb_build_object('rows',coalesce(jsonb_agg(to_jsonb(reviewers)
      ORDER BY role_code,actor_id),'[]'::jsonb))
  FROM reviewers
)
SELECT check_name,status,violation_rows,details FROM checks ORDER BY seq;
