-- SELECT-only fixture inventory for Transit usage foundation rollback behavior.
WITH checks AS (
  SELECT 'canonical_super_admin_fixture'::text check_name,
    CASE WHEN count(*)>0 THEN 'PASS' ELSE 'BLOCKER' END::text status,
    CASE WHEN count(*)>0 THEN 0 ELSE 1 END::bigint violation_rows,
    jsonb_build_object('rows',count(*)) details
  FROM auth.users user_row
  JOIN public.profiles profile ON profile.id=user_row.id
    AND profile.role='super_admin'::public.user_role
  UNION ALL
  SELECT 'active_company_fixture',
    CASE WHEN count(*)>0 THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN count(*)>0 THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('rows',count(*))
  FROM public.companies company WHERE company.status='ACTIVE'
  UNION ALL
  SELECT 'active_company_context_default_contract',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END,
    abs(count(*)-1)::bigint,
    jsonb_build_object('rows',count(*),'columnDefault',max(column_default))
  FROM information_schema.columns
  WHERE table_schema='public' AND table_name='user_active_company_contexts'
    AND column_name='selection_source' AND is_nullable='NO'
    AND column_default IS NOT NULL
)
SELECT check_name,status,violation_rows,details
FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,
  check_name;
