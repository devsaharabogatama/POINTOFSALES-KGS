-- ACP-2 postflight: shadow-only custom permission foundation.
-- SAFETY: SELECT-only aggregate metadata.

WITH expected_relations(relation_name) AS (
    VALUES('access_permission_catalog'),('user_company_permission_overrides'),
          ('user_company_permission_audit')
), expected_routines(routine_signature) AS (
    VALUES
      ('public.resolve_user_permission(uuid,uuid,text)'),
      ('public.list_user_permission_profile(uuid,uuid)'),
      ('public.save_user_permission_override(uuid,uuid,text,text,bigint)'),
      ('private.acp_can_manage_target(uuid,uuid,uuid)'),
      ('private.acp_resolve_permission(uuid,uuid,text)')
), checks AS (
    SELECT 'migration_ledger'::TEXT check_name,
      CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
      abs(1-count(*))::BIGINT violation_rows,
      jsonb_build_object('ledger_rows',count(*)) details
    FROM private.kgs_schema_migrations WHERE version='20260812120000'

    UNION ALL
    SELECT 'required_permission_relations',
      CASE WHEN count(*) FILTER(WHERE relation.oid IS NULL)=0 THEN 'PASS' ELSE 'FAIL' END,
      count(*) FILTER(WHERE relation.oid IS NULL),
      jsonb_build_object('expected',count(*),'missing',COALESCE(
        jsonb_agg(expected.relation_name ORDER BY expected.relation_name)
          FILTER(WHERE relation.oid IS NULL),'[]'::JSONB))
    FROM expected_relations expected
    LEFT JOIN LATERAL(SELECT to_regclass('public.'||expected.relation_name) oid) relation ON TRUE

    UNION ALL
    SELECT 'required_permission_routines',
      CASE WHEN count(*) FILTER(WHERE routine.oid IS NULL)=0 THEN 'PASS' ELSE 'FAIL' END,
      count(*) FILTER(WHERE routine.oid IS NULL),
      jsonb_build_object('expected',count(*),'missing',COALESCE(
        jsonb_agg(expected.routine_signature ORDER BY expected.routine_signature)
          FILTER(WHERE routine.oid IS NULL),'[]'::JSONB))
    FROM expected_routines expected
    LEFT JOIN LATERAL(SELECT to_regprocedure(expected.routine_signature) oid) routine ON TRUE

    UNION ALL
    SELECT 'permission_relation_rls',
      CASE WHEN count(*)=3 AND bool_and(class.relrowsecurity) THEN 'PASS' ELSE 'FAIL' END,
      CASE WHEN count(*)=3 AND bool_and(class.relrowsecurity) THEN 0 ELSE 1 END,
      jsonb_build_object('relation_rows',count(*))
    FROM pg_catalog.pg_class class
    JOIN pg_catalog.pg_namespace namespace ON namespace.oid=class.relnamespace
    WHERE namespace.nspname='public' AND class.relname IN(
      'access_permission_catalog','user_company_permission_overrides',
      'user_company_permission_audit')

    UNION ALL
    SELECT 'permission_catalog_contract',
      CASE WHEN count(*)=32 AND count(*) FILTER(WHERE enforcement_status<>'SHADOW')=0
             AND count(*) FILTER(WHERE NOT is_customizable)=1
           THEN 'PASS' ELSE 'FAIL' END,
      CASE WHEN count(*)=32 AND count(*) FILTER(WHERE enforcement_status<>'SHADOW')=0
             AND count(*) FILTER(WHERE NOT is_customizable)=1
           THEN 0 ELSE 1 END,
      jsonb_build_object('catalog_rows',count(*),
        'non_shadow_rows',count(*) FILTER(WHERE enforcement_status<>'SHADOW'),
        'protected_rows',count(*) FILTER(WHERE NOT is_customizable))
    FROM public.access_permission_catalog

    UNION ALL
    SELECT 'shadow_runtime_contract',
      CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
      jsonb_build_object('enforced_rows',count(*))
    FROM public.access_permission_catalog WHERE enforcement_status='ENFORCED'

    UNION ALL
    SELECT 'browser_permission_write_boundary',
      CASE WHEN NOT has_table_privilege('authenticated','public.access_permission_catalog','INSERT,UPDATE,DELETE')
             AND NOT has_table_privilege('authenticated','public.user_company_permission_overrides','INSERT,UPDATE,DELETE')
             AND NOT has_table_privilege('authenticated','public.user_company_permission_audit','INSERT,UPDATE,DELETE')
             AND has_function_privilege('authenticated','public.resolve_user_permission(uuid,uuid,text)','EXECUTE')
             AND has_function_privilege('authenticated','public.list_user_permission_profile(uuid,uuid)','EXECUTE')
             AND has_function_privilege('authenticated','public.save_user_permission_override(uuid,uuid,text,text,bigint)','EXECUTE')
           THEN 'PASS' ELSE 'FAIL' END,
      CASE WHEN NOT has_table_privilege('authenticated','public.access_permission_catalog','INSERT,UPDATE,DELETE')
             AND NOT has_table_privilege('authenticated','public.user_company_permission_overrides','INSERT,UPDATE,DELETE')
             AND NOT has_table_privilege('authenticated','public.user_company_permission_audit','INSERT,UPDATE,DELETE')
             AND has_function_privilege('authenticated','public.resolve_user_permission(uuid,uuid,text)','EXECUTE')
             AND has_function_privilege('authenticated','public.list_user_permission_profile(uuid,uuid)','EXECUTE')
             AND has_function_privilege('authenticated','public.save_user_permission_override(uuid,uuid,text,text,bigint)','EXECUTE')
           THEN 0 ELSE 1 END,
      jsonb_build_object('direct_write',
        has_table_privilege('authenticated','public.access_permission_catalog','INSERT,UPDATE,DELETE')
        OR has_table_privilege('authenticated','public.user_company_permission_overrides','INSERT,UPDATE,DELETE')
        OR has_table_privilege('authenticated','public.user_company_permission_audit','INSERT,UPDATE,DELETE'))

    UNION ALL
    SELECT 'permission_audit_immutable_trigger',
      CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,abs(1-count(*))::BIGINT,
      jsonb_build_object('trigger_rows',count(*))
    FROM pg_catalog.pg_trigger trigger
    JOIN pg_catalog.pg_class class ON class.oid=trigger.tgrelid
    JOIN pg_catalog.pg_namespace namespace ON namespace.oid=class.relnamespace
    WHERE namespace.nspname='public' AND class.relname='user_company_permission_audit'
      AND trigger.tgname='trg_acp_guard_permission_history'
      AND trigger.tgenabled<>'D' AND NOT trigger.tgisinternal

    UNION ALL
    SELECT 'permission_override_tenant_integrity',
      CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
      jsonb_build_object('row_count',count(*))
    FROM public.user_company_permission_overrides override_row
    LEFT JOIN public.company_memberships membership
      ON membership.company_id=override_row.company_id
     AND membership.user_id=override_row.user_id AND membership.status='ACTIVE'
    WHERE membership.id IS NULL

    UNION ALL
    SELECT 'permission_runtime_inventory','INFO',0,
      jsonb_build_object('catalog_rows',(SELECT count(*) FROM public.access_permission_catalog),
        'override_rows',(SELECT count(*) FROM public.user_company_permission_overrides),
        'audit_rows',(SELECT count(*) FROM public.user_company_permission_audit),
        'enforced_rows',(SELECT count(*) FROM public.access_permission_catalog WHERE enforcement_status='ENFORCED'))
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
