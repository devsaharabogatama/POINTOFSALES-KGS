-- ACP-1 preflight: role-baseline and custom-restriction access fingerprint.
--
-- SAFETY:
-- - exactly one SELECT statement;
-- - no DDL, DML, TEMP object, function execution with side effects, or grants;
-- - aggregate counts and metadata only; no user identity, email, or business data.

WITH required_versions(version) AS (
    VALUES ('20260720180000'),('20260720210000')
), expected_roles(role_code) AS (
    VALUES
        ('COMPANY_OWNER'),('COMPANY_ADMIN'),('FINANCE'),('ACCOUNTING'),
        ('STORE_MANAGER'),('WAREHOUSE_ADMIN'),('CASHIER')
), protected_relations(relation_name) AS (
    VALUES
        ('product_stocks'),('product_batches'),('stock_movements'),
        ('financial_events'),('finance_journals'),('finance_journal_lines'),
        ('journal_entries'),('journal_lines'),('sales_payments'),
        ('company_memberships'),('store_memberships')
), expected_role_helpers(routine_name) AS (
    VALUES
        ('private_user_company_role'),
        ('private_user_has_company_access'),
        ('private_user_has_any_company_role'),
        ('private_user_has_any_store_role'),
        ('private_user_has_store_access'),
        ('private_user_has_any_company_or_store_role'),
        ('private_active_company_id')
), expected_permission_relations(relation_name) AS (
    VALUES
        ('access_permission_catalog'),
        ('user_company_permission_overrides'),
        ('user_company_permission_audit')
), active_company_memberships AS (
    SELECT membership.*
    FROM public.company_memberships membership
    WHERE membership.status='ACTIVE'
), active_store_memberships AS (
    SELECT membership.*
    FROM public.store_memberships membership
    WHERE membership.status='ACTIVE'
), company_scoped_relations AS (
    SELECT class.oid,class.relname,class.relrowsecurity
    FROM pg_catalog.pg_class class
    JOIN pg_catalog.pg_namespace namespace ON namespace.oid=class.relnamespace
    JOIN pg_catalog.pg_attribute attribute
      ON attribute.attrelid=class.oid
     AND attribute.attname='company_id'
     AND NOT attribute.attisdropped
    WHERE namespace.nspname='public'
      AND class.relkind IN ('r','p')
), role_helper_inventory AS (
    SELECT procedure.proname,
        procedure.prosecdef,
        has_function_privilege(
            'authenticated',procedure.oid,'EXECUTE'
        ) authenticated_execute,
        pg_catalog.pg_get_functiondef(procedure.oid) definition
    FROM pg_catalog.pg_proc procedure
    JOIN pg_catalog.pg_namespace namespace
      ON namespace.oid=procedure.pronamespace
    WHERE namespace.nspname IN ('public','private')
), checks AS (
    SELECT 'acp_foundation_dependency'::TEXT check_name,
        CASE WHEN count(*) FILTER(WHERE migration.version IS NULL)=0
             THEN 'PASS' ELSE 'BLOCKER' END status,
        jsonb_build_object(
            'expected',count(*),
            'missing',COALESCE(
                jsonb_agg(required.version ORDER BY required.version)
                    FILTER(WHERE migration.version IS NULL),
                '[]'::JSONB
            )
        ) details
    FROM required_versions required
    LEFT JOIN private.kgs_schema_migrations migration
      ON migration.version=required.version

    UNION ALL
    SELECT 'company_membership_identity_integrity',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM active_company_memberships membership
    LEFT JOIN public.profiles profile ON profile.id=membership.user_id
    LEFT JOIN auth.users auth_user ON auth_user.id=membership.user_id
    LEFT JOIN public.companies company ON company.id=membership.company_id
    WHERE profile.id IS NULL OR auth_user.id IS NULL OR company.id IS NULL

    UNION ALL
    SELECT 'company_membership_role_vocabulary',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.company_memberships membership
    WHERE membership.role_code NOT IN (SELECT role_code FROM expected_roles)
       OR membership.status NOT IN ('ACTIVE','INACTIVE')

    UNION ALL
    SELECT 'duplicate_company_user_membership',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('duplicate_groups',count(*))
    FROM (
        SELECT company_id,user_id
        FROM public.company_memberships
        GROUP BY company_id,user_id
        HAVING count(*)>1
    ) duplicate_group

    UNION ALL
    SELECT 'multiple_default_company_membership',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('user_count',count(*))
    FROM (
        SELECT user_id
        FROM public.company_memberships
        WHERE is_default_company
        GROUP BY user_id
        HAVING count(*)>1
    ) duplicate_default

    UNION ALL
    SELECT 'active_company_context_integrity',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.user_active_company_contexts context
    LEFT JOIN public.profiles profile ON profile.id=context.user_id
    LEFT JOIN public.companies company ON company.id=context.company_id
    LEFT JOIN public.company_memberships membership
      ON membership.company_id=context.company_id
     AND membership.user_id=context.user_id
     AND membership.status='ACTIVE'
    WHERE profile.id IS NULL OR company.id IS NULL OR company.status<>'ACTIVE'
       OR (
            profile.role<>'super_admin'::public.user_role
            AND membership.id IS NULL
       )

    UNION ALL
    SELECT 'store_membership_tenant_integrity',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM active_store_memberships membership
    LEFT JOIN public.stores store
      ON store.id=membership.store_id
     AND store.company_id=membership.company_id
    LEFT JOIN active_company_memberships company_membership
      ON company_membership.company_id=membership.company_id
     AND company_membership.user_id=membership.user_id
    LEFT JOIN auth.users auth_user ON auth_user.id=membership.user_id
    WHERE store.id IS NULL OR company_membership.id IS NULL
       OR auth_user.id IS NULL

    UNION ALL
    SELECT 'store_membership_role_divergence',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object('row_count',count(*))
    FROM active_store_memberships store_membership
    JOIN active_company_memberships company_membership
      ON company_membership.company_id=store_membership.company_id
     AND company_membership.user_id=store_membership.user_id
    WHERE store_membership.role_code<>company_membership.role_code

    UNION ALL
    SELECT 'regular_multi_company_identity',
        CASE WHEN count(*)>0 THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object('eligible_users',count(*),'required',1)
    FROM (
        SELECT membership.user_id
        FROM active_company_memberships membership
        JOIN public.profiles profile ON profile.id=membership.user_id
        WHERE profile.role<>'super_admin'::public.user_role
        GROUP BY membership.user_id
        HAVING count(DISTINCT membership.company_id)>=2
    ) eligible

    UNION ALL
    SELECT 'role_baseline_uat_coverage',
        CASE WHEN count(*) FILTER(WHERE actual.role_code IS NULL)=0
             THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object(
            'expected',count(*),
            'missing',COALESCE(
                jsonb_agg(expected.role_code ORDER BY expected.role_code)
                    FILTER(WHERE actual.role_code IS NULL),
                '[]'::JSONB
            )
        )
    FROM expected_roles expected
    LEFT JOIN (
        SELECT DISTINCT role_code FROM active_company_memberships
        UNION
        SELECT DISTINCT role_code FROM active_store_memberships
    ) actual ON actual.role_code=expected.role_code

    UNION ALL
    SELECT 'company_scoped_relation_rls',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'company_scoped_relations',(SELECT count(*) FROM company_scoped_relations),
            'relations_without_rls',count(*)
        )
    FROM company_scoped_relations relation
    WHERE NOT relation.relrowsecurity

    UNION ALL
    SELECT 'protected_relation_browser_write_boundary',
        CASE WHEN count(*) FILTER(WHERE privilege.direct_write)=0
             THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'expected',count(*),
            'direct_write_relations',count(*) FILTER(WHERE privilege.direct_write),
            'missing_relations',count(*) FILTER(WHERE privilege.relation_oid IS NULL)
        )
    FROM protected_relations protected
    CROSS JOIN LATERAL (
        SELECT to_regclass('public.'||protected.relation_name) relation_oid,
            CASE WHEN to_regclass('public.'||protected.relation_name) IS NULL
                 THEN FALSE
                 ELSE has_table_privilege(
                     'authenticated','public.'||protected.relation_name,
                     'INSERT,UPDATE,DELETE'
                 ) END direct_write
    ) privilege

    UNION ALL
    SELECT 'company_scoped_authenticated_write_inventory',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object(
            'writable_relations',count(*),
            'company_scoped_relations',(SELECT count(*) FROM company_scoped_relations)
        )
    FROM company_scoped_relations relation
    WHERE has_table_privilege(
        'authenticated',relation.oid,'INSERT,UPDATE,DELETE'
    )

    UNION ALL
    SELECT 'canonical_role_helper_state',
        CASE WHEN count(*) FILTER(WHERE helper.oid IS NULL)=0
             THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'expected',count(*),
            'missing',COALESCE(
                jsonb_agg(expected.routine_name ORDER BY expected.routine_name)
                    FILTER(WHERE helper.oid IS NULL),
                '[]'::JSONB
            )
        )
    FROM expected_role_helpers expected
    LEFT JOIN LATERAL (
        SELECT procedure.oid
        FROM pg_catalog.pg_proc procedure
        JOIN pg_catalog.pg_namespace namespace
          ON namespace.oid=procedure.pronamespace
        WHERE namespace.nspname='public'
          AND procedure.proname=expected.routine_name
        LIMIT 1
    ) helper ON TRUE

    UNION ALL
    SELECT 'role_authority_implementation_inventory',
        'INFO',
        jsonb_build_object(
            'security_definer_routines',count(*) FILTER(WHERE prosecdef),
            'authenticated_executable_security_definer',count(*) FILTER(
                WHERE prosecdef AND authenticated_execute
            ),
            'company_role_helper_references',count(*) FILTER(
                WHERE definition LIKE '%private_user_has_any_company_role%'
            ),
            'store_role_helper_references',count(*) FILTER(
                WHERE definition LIKE '%private_user_has_any_store_role%'
                   OR definition LIKE '%private_user_has_store_access%'
            ),
            'active_company_helper_references',count(*) FILTER(
                WHERE definition LIKE '%private_active_company_id%'
            )
        )
    FROM role_helper_inventory

    UNION ALL
    SELECT 'custom_permission_schema_state',
        CASE WHEN count(*) FILTER(WHERE relation.relation_oid IS NULL)=0
             THEN 'INFO' ELSE 'SETUP' END,
        jsonb_build_object(
            'expected',count(*),
            'missing',COALESCE(
                jsonb_agg(expected.relation_name ORDER BY expected.relation_name)
                    FILTER(WHERE relation.relation_oid IS NULL),
                '[]'::JSONB
            ),
            'runtime_expected','ROLE_ONLY'
        )
    FROM expected_permission_relations expected
    CROSS JOIN LATERAL (
        SELECT to_regclass('public.'||expected.relation_name) relation_oid
    ) relation

    UNION ALL
    SELECT 'access_scope_inventory',
        'INFO',
        jsonb_build_object(
            'active_companies',(SELECT count(*) FROM public.companies WHERE status='ACTIVE'),
            'active_company_memberships',(SELECT count(*) FROM active_company_memberships),
            'active_store_memberships',(SELECT count(*) FROM active_store_memberships),
            'active_contexts',(SELECT count(*) FROM public.user_active_company_contexts),
            'active_stores',(SELECT count(*) FROM public.stores WHERE status='ACTIVE'),
            'active_terminals',(SELECT count(*) FROM public.pos_terminals WHERE status='ACTIVE'),
            'active_warehouses',(SELECT count(*) FROM public.warehouses WHERE is_active)
        )
)
SELECT check_name,status,details
FROM checks
ORDER BY
    CASE status
        WHEN 'BLOCKER' THEN 1
        WHEN 'REVIEW' THEN 2
        WHEN 'SETUP' THEN 3
        WHEN 'PASS' THEN 4
        ELSE 5
    END,
    check_name;
