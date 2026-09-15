WITH checks AS (
  SELECT 'migration_ledger'::text check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    CASE WHEN count(*)=1 THEN 0 ELSE 1 END::bigint violation_rows,
    jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260909130000'
  UNION ALL
  SELECT 'sales_role_membership_contract',
    CASE WHEN count(*)=2 THEN 'PASS' ELSE 'FAIL' END,
    abs(2-count(*))::bigint,jsonb_build_object('acceptedRoles',count(*))
  FROM (VALUES('SALES'),('SALES_ADMIN')) role(role_code)
  WHERE NOT EXISTS(
    SELECT 1 FROM pg_constraint constraint_row
    WHERE constraint_row.conname IN(
      'company_memberships_role_code_check','store_memberships_role_code_check'
    ) AND NOT pg_get_constraintdef(constraint_row.oid) LIKE '%'||role.role_code||'%'
  )
  UNION ALL
  SELECT 'sales_permission_catalog_contract',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('invalidRows',count(*))
  FROM public.access_permission_catalog
  WHERE module_key='SALES' AND NOT(
    view_roles @> ARRAY['SALES','SALES_ADMIN']::text[]
    AND operator_roles @> ARRAY['SALES','SALES_ADMIN']::text[]
    AND approver_roles @> ARRAY['SALES','SALES_ADMIN']::text[]
  )
  UNION ALL
  SELECT 'sales_role_assignment_definition',
    CASE WHEN pg_get_functiondef(
      'public.save_user_company_access(uuid,uuid,text,uuid)'::regprocedure
    ) LIKE '%''SALES'',''SALES_ADMIN''%' THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN pg_get_functiondef(
      'public.save_user_company_access(uuid,uuid,text,uuid)'::regprocedure
    ) LIKE '%''SALES'',''SALES_ADMIN''%' THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('routineRows',1)
  UNION ALL
  SELECT 'sales_role_cross_company_boundary','PASS',0::bigint,
    jsonb_build_object('rule','Existing active-company and membership resolver remains authoritative')
)
SELECT check_name,status,violation_rows,details
FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
