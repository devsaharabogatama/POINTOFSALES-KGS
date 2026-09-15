-- SELECT-only verification for the exact non-Finance master fixture used by
-- the rollback-only Invoice Finance Mapping behavior test.
WITH checks AS (
  SELECT 'invoice_mapping_behavior_linked_actor'::text check_name,
    CASE WHEN count(*)>0 THEN 'PASS' ELSE 'BLOCKER' END status,
    CASE WHEN count(*)>0 THEN 0 ELSE 1 END::bigint violation_rows,
    jsonb_build_object('linkedSuperAdminRows',count(*)) details
  FROM public.profiles profile
  JOIN auth.users auth_user ON auth_user.id=profile.id
  WHERE profile.role='super_admin'::public.user_role
  UNION ALL
  SELECT 'invoice_mapping_behavior_company_store',
    CASE WHEN count(*)>0 THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN count(*)>0 THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('eligibleCompanyStorePairs',count(*))
  FROM public.companies company
  JOIN public.stores store ON store.company_id=company.id AND store.status='ACTIVE'
  WHERE company.status='ACTIVE'
)
SELECT * FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 ELSE 2 END,check_name;
