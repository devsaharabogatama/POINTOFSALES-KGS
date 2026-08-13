-- PRD Company access lifecycle postflight. SELECT-only.
WITH checks AS (
  SELECT 'migration_ledger' AS check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END AS status,
    CASE WHEN count(*)=1 THEN 0 ELSE 1 END::BIGINT AS violation_rows,
    jsonb_build_object('ledger_rows',count(*)) AS details
  FROM private.kgs_schema_migrations WHERE version='20260813140000'
  UNION ALL
  SELECT 'required_company_access_routines',
    CASE WHEN count(*)=2 THEN 'PASS' ELSE 'FAIL' END,
    (2-count(*))::BIGINT,
    jsonb_build_object('routine_rows',count(*),'expected',2)
  FROM pg_proc procedure
  JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname='public' AND procedure.proname IN(
    'save_user_company_access','deactivate_user_company_access')
  UNION ALL
  SELECT 'browser_company_access_rpc_boundary',
    CASE WHEN count(*) FILTER(WHERE has_function_privilege(
      'anon',procedure.oid,'EXECUTE'))=0
      AND count(*) FILTER(WHERE has_function_privilege(
      'authenticated',procedure.oid,'EXECUTE'))=2 THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*) FILTER(WHERE has_function_privilege(
      'anon',procedure.oid,'EXECUTE'))=0
      AND count(*) FILTER(WHERE has_function_privilege(
      'authenticated',procedure.oid,'EXECUTE'))=2 THEN 0 ELSE 1 END::BIGINT,
    jsonb_build_object(
      'anon_rows',count(*) FILTER(WHERE has_function_privilege(
        'anon',procedure.oid,'EXECUTE')),
      'authenticated_rows',count(*) FILTER(WHERE has_function_privilege(
        'authenticated',procedure.oid,'EXECUTE')))
  FROM pg_proc procedure
  JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname='public' AND procedure.proname IN(
    'save_user_company_access','deactivate_user_company_access')
  UNION ALL
  SELECT 'inactive_company_default_membership',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('row_count',count(*))
  FROM public.company_memberships
  WHERE status='INACTIVE' AND is_default_company
  UNION ALL
  SELECT 'inactive_membership_active_store_assignment',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('row_count',count(*))
  FROM public.store_memberships store_membership
  JOIN public.company_memberships company_membership
    ON company_membership.company_id=store_membership.company_id
   AND company_membership.user_id=store_membership.user_id
  WHERE company_membership.status='INACTIVE'
    AND store_membership.status='ACTIVE'
  UNION ALL
  SELECT 'active_context_membership_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('row_count',count(*))
  FROM public.user_active_company_contexts context
  JOIN public.profiles profile ON profile.id=context.user_id
  WHERE profile.role<>'super_admin'::public.user_role
    AND NOT EXISTS(SELECT 1 FROM public.company_memberships membership
      WHERE membership.company_id=context.company_id
        AND membership.user_id=context.user_id AND membership.status='ACTIVE')
  UNION ALL
  SELECT 'assignment_audit_action_contract',
    CASE WHEN count(*)=1 AND bool_or(
      pg_get_constraintdef(constraint_row.oid) LIKE '%DEACTIVATE%'
      AND pg_get_constraintdef(constraint_row.oid) LIKE '%REACTIVATE%'
    ) THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1 AND bool_or(
      pg_get_constraintdef(constraint_row.oid) LIKE '%DEACTIVATE%'
      AND pg_get_constraintdef(constraint_row.oid) LIKE '%REACTIVATE%'
    ) THEN 0 ELSE 1 END::BIGINT,
    jsonb_build_object('constraint_rows',count(*))
  FROM pg_constraint constraint_row
  WHERE constraint_row.conrelid='public.user_company_assignment_audit'::regclass
    AND constraint_row.conname='user_company_assignment_audit_action_check'
  UNION ALL
  SELECT 'company_access_lifecycle_inventory','INFO',0,
    jsonb_build_object(
      'active_memberships',count(*) FILTER(WHERE status='ACTIVE'),
      'inactive_memberships',count(*) FILTER(WHERE status='INACTIVE'),
      'multi_company_users',count(DISTINCT user_id) FILTER(WHERE status='ACTIVE'
        AND user_id IN(SELECT user_id FROM public.company_memberships
          WHERE status='ACTIVE' GROUP BY user_id HAVING count(*)>1)))
  FROM public.company_memberships
)
SELECT check_name,status,violation_rows,details
FROM checks ORDER BY CASE status WHEN 'FAIL' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,
  check_name;
