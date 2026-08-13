-- PRD-1 phase 3 postflight: guarded existing-user Company assignment.
-- SAFETY: SELECT-only and aggregate metadata only.

WITH checks AS (
    SELECT 'migration_ledger'::TEXT check_name,
        CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
        count(*)::BIGINT violation_rows,
        jsonb_build_object('ledger_rows',count(*)) details
    FROM private.kgs_schema_migrations
    WHERE version='20260812100000'

    UNION ALL
    SELECT 'assignment_schema',
        CASE WHEN to_regclass('public.user_company_assignment_audit') IS NOT NULL
                  AND to_regprocedure(
                    'public.assign_existing_user_to_company(uuid,uuid,text,uuid)'
                  ) IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN to_regclass('public.user_company_assignment_audit') IS NOT NULL
                  AND to_regprocedure(
                    'public.assign_existing_user_to_company(uuid,uuid,text,uuid)'
                  ) IS NOT NULL
             THEN 0 ELSE 1 END,
        jsonb_build_object(
            'audit_table_exists',to_regclass(
                'public.user_company_assignment_audit'
            ) IS NOT NULL,
            'rpc_exists',to_regprocedure(
                'public.assign_existing_user_to_company(uuid,uuid,text,uuid)'
            ) IS NOT NULL
        )

    UNION ALL
    SELECT 'assignment_audit_rls',
        CASE WHEN count(*)=1 AND bool_and(class.relrowsecurity)
             THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN count(*)=1 AND bool_and(class.relrowsecurity)
             THEN 0 ELSE 1 END,
        jsonb_build_object('relation_rows',count(*))
    FROM pg_catalog.pg_class class
    JOIN pg_catalog.pg_namespace namespace ON namespace.oid=class.relnamespace
    WHERE namespace.nspname='public'
      AND class.relname='user_company_assignment_audit'

    UNION ALL
    SELECT 'assignment_audit_immutable_trigger',
        CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
        abs(1-count(*))::BIGINT,
        jsonb_build_object('trigger_rows',count(*))
    FROM pg_catalog.pg_trigger trigger
    JOIN pg_catalog.pg_class class ON class.oid=trigger.tgrelid
    JOIN pg_catalog.pg_namespace namespace ON namespace.oid=class.relnamespace
    WHERE namespace.nspname='public'
      AND class.relname='user_company_assignment_audit'
      AND trigger.tgname='trg_prd_guard_assignment_audit_history'
      AND trigger.tgenabled<>'D' AND NOT trigger.tgisinternal

    UNION ALL
    SELECT 'browser_assignment_boundary',
        CASE WHEN NOT has_table_privilege(
                'authenticated','public.company_memberships',
                'INSERT,UPDATE,DELETE'
             ) AND NOT has_table_privilege(
                'authenticated','public.store_memberships',
                'INSERT,UPDATE,DELETE'
             ) AND NOT has_table_privilege(
                'authenticated','public.user_company_assignment_audit',
                'INSERT,UPDATE,DELETE'
             ) AND has_function_privilege(
                'authenticated',
                'public.assign_existing_user_to_company(uuid,uuid,text,uuid)',
                'EXECUTE'
             ) THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN NOT has_table_privilege(
                'authenticated','public.company_memberships',
                'INSERT,UPDATE,DELETE'
             ) AND NOT has_table_privilege(
                'authenticated','public.store_memberships',
                'INSERT,UPDATE,DELETE'
             ) AND NOT has_table_privilege(
                'authenticated','public.user_company_assignment_audit',
                'INSERT,UPDATE,DELETE'
             ) AND has_function_privilege(
                'authenticated',
                'public.assign_existing_user_to_company(uuid,uuid,text,uuid)',
                'EXECUTE'
             ) THEN 0 ELSE 1 END,
        jsonb_build_object(
            'membership_direct_write',has_table_privilege(
                'authenticated','public.company_memberships',
                'INSERT,UPDATE,DELETE'
            ) OR has_table_privilege(
                'authenticated','public.store_memberships',
                'INSERT,UPDATE,DELETE'
            ),
            'audit_direct_write',has_table_privilege(
                'authenticated','public.user_company_assignment_audit',
                'INSERT,UPDATE,DELETE'
            ),
            'rpc_execute',has_function_privilege(
                'authenticated',
                'public.assign_existing_user_to_company(uuid,uuid,text,uuid)',
                'EXECUTE'
            )
        )

    UNION ALL
    SELECT 'membership_tenant_integrity',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),jsonb_build_object('row_count',count(*))
    FROM public.store_memberships membership
    LEFT JOIN public.stores store
      ON store.company_id=membership.company_id
     AND store.id=membership.store_id
    LEFT JOIN public.company_memberships company_membership
      ON company_membership.company_id=membership.company_id
     AND company_membership.user_id=membership.user_id
     AND company_membership.status='ACTIVE'
    WHERE membership.status='ACTIVE'
      AND (store.id IS NULL OR company_membership.id IS NULL)
)
SELECT check_name,status,violation_rows,details
FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 ELSE 2 END,check_name;
