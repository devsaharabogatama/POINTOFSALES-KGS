-- BRD phase 1 postflight: Company branding foundation verification.
-- SAFETY: SELECT-only; aggregate metadata only.

WITH expected_routines(signature) AS (
    VALUES
        ('public.get_company_branding()'),
        ('public.save_company_branding_logo(bigint,text,text,text,bigint,text)'),
        ('public.remove_company_branding_logo(bigint)')
), checks AS (
    SELECT
        'migration_ledger'::TEXT AS check_name,
        CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END AS status,
        jsonb_build_object('ledger_rows',count(*)) AS details
    FROM private.kgs_schema_migrations migration
    WHERE migration.version='20260811110000'

    UNION ALL

    SELECT
        'required_branding_relations',
        CASE WHEN count(*) FILTER (WHERE relation_oid IS NULL)=0
             THEN 'PASS' ELSE 'FAIL' END,
        jsonb_build_object(
            'missing',COALESCE(
                jsonb_agg(relation_name ORDER BY relation_name)
                    FILTER (WHERE relation_oid IS NULL),'[]'::JSONB
            ),
            'expected',count(*)
        )
    FROM (
        VALUES
            ('company_branding_profiles',
             to_regclass('public.company_branding_profiles')),
            ('company_branding_audit',
             to_regclass('public.company_branding_audit'))
    ) expected_relation(relation_name,relation_oid)

    UNION ALL

    SELECT
        'required_branding_routines',
        CASE WHEN count(*) FILTER (
            WHERE to_regprocedure(signature) IS NULL
        )=0 THEN 'PASS' ELSE 'FAIL' END,
        jsonb_build_object(
            'missing',COALESCE(
                jsonb_agg(signature ORDER BY signature) FILTER (
                    WHERE to_regprocedure(signature) IS NULL
                ),'[]'::JSONB
            ),
            'expected',count(*)
        )
    FROM expected_routines

    UNION ALL

    SELECT
        'branding_bucket_contract',
        CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
        jsonb_build_object('matching_rows',count(*))
    FROM storage.buckets bucket
    WHERE bucket.id='company-branding'
      AND bucket.name='company-branding'
      AND bucket.public
      AND bucket.file_size_limit=2097152
      AND bucket.allowed_mime_types @> ARRAY[
            'image/png','image/jpeg','image/webp'
          ]::TEXT[]
      AND cardinality(bucket.allowed_mime_types)=3

    UNION ALL

    SELECT
        'branding_rls_contract',
        CASE WHEN count(*) FILTER (WHERE NOT class.relrowsecurity)=0
                  AND count(*)=2 THEN 'PASS' ELSE 'FAIL' END,
        jsonb_build_object(
            'rls_enabled',count(*) FILTER (WHERE class.relrowsecurity),
            'relation_rows',count(*)
        )
    FROM pg_catalog.pg_class class
    JOIN pg_catalog.pg_namespace namespace
      ON namespace.oid=class.relnamespace
    WHERE namespace.nspname='public'
      AND class.relname IN (
          'company_branding_profiles','company_branding_audit'
      )

    UNION ALL

    SELECT
        'branding_policy_contract',
        CASE WHEN count(*)=2
                  AND count(*) FILTER (WHERE policy.cmd='SELECT')=2
             THEN 'PASS' ELSE 'FAIL' END,
        jsonb_build_object(
            'policy_rows',count(*),
            'select_policy_rows',count(*) FILTER (WHERE policy.cmd='SELECT')
        )
    FROM pg_catalog.pg_policies policy
    WHERE policy.schemaname='public'
      AND policy.tablename IN (
          'company_branding_profiles','company_branding_audit'
      )

    UNION ALL

    SELECT
        'branding_history_triggers',
        CASE WHEN count(*)=2 THEN 'PASS' ELSE 'FAIL' END,
        jsonb_build_object('trigger_rows',count(*))
    FROM pg_catalog.pg_trigger trigger_row
    JOIN pg_catalog.pg_class class ON class.oid=trigger_row.tgrelid
    JOIN pg_catalog.pg_namespace namespace
      ON namespace.oid=class.relnamespace
    WHERE namespace.nspname='public'
      AND class.relname IN (
          'company_branding_profiles','company_branding_audit'
      )
      AND trigger_row.tgenabled<>'D'
      AND NOT trigger_row.tgisinternal

    UNION ALL

    SELECT
        'browser_branding_write_boundary',
        CASE WHEN NOT has_table_privilege(
                       'authenticated','public.company_branding_profiles',
                       'INSERT,UPDATE,DELETE'
                   )
                  AND NOT has_table_privilege(
                       'authenticated','public.company_branding_audit',
                       'INSERT,UPDATE,DELETE'
                   )
             THEN 'PASS' ELSE 'FAIL' END,
        jsonb_build_object(
            'profile_write',has_table_privilege(
                'authenticated','public.company_branding_profiles',
                'INSERT,UPDATE,DELETE'
            ),
            'audit_write',has_table_privilege(
                'authenticated','public.company_branding_audit',
                'INSERT,UPDATE,DELETE'
            )
        )

    UNION ALL

    SELECT
        'browser_branding_rpc_boundary',
        CASE WHEN count(*) FILTER (
                    WHERE has_function_privilege(
                        'authenticated',to_regprocedure(signature),'EXECUTE'
                    )
                )=3
                  AND count(*) FILTER (
                    WHERE has_function_privilege(
                        'anon',to_regprocedure(signature),'EXECUTE'
                    )
                )=0
             THEN 'PASS' ELSE 'FAIL' END,
        jsonb_build_object(
            'authenticated_execute',count(*) FILTER (
                WHERE has_function_privilege(
                    'authenticated',to_regprocedure(signature),'EXECUTE'
                )
            ),
            'anon_execute',count(*) FILTER (
                WHERE has_function_privilege(
                    'anon',to_regprocedure(signature),'EXECUTE'
                )
            ),
            'expected',count(*)
        )
    FROM expected_routines

    UNION ALL

    SELECT
        'unsafe_branding_storage_policy',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
        jsonb_build_object('writable_policy_rows',count(*))
    FROM pg_catalog.pg_policies policy
    WHERE policy.schemaname='storage'
      AND policy.tablename='objects'
      AND policy.cmd IN ('ALL','INSERT','UPDATE','DELETE')
      AND 'authenticated'=ANY(policy.roles::TEXT[])
      AND concat_ws(' ',policy.qual,policy.with_check)
            ILIKE '%company-branding%'

    UNION ALL

    SELECT
        'branding_profile_tenant_path_integrity',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
        jsonb_build_object('row_count',count(*))
    FROM public.company_branding_profiles profile
    WHERE profile.logo_object_path IS NOT NULL
      AND profile.logo_object_path NOT LIKE
            profile.company_id::TEXT || '/logo/%'

    UNION ALL

    SELECT
        'active_branding_storage_object_coverage',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
        jsonb_build_object('missing_object_rows',count(*))
    FROM public.company_branding_profiles profile
    LEFT JOIN storage.objects object_state
      ON object_state.bucket_id='company-branding'
     AND object_state.name=profile.logo_object_path
    WHERE profile.logo_object_path IS NOT NULL
      AND object_state.id IS NULL

    UNION ALL

    SELECT
        'branding_audit_reference_integrity',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
        jsonb_build_object('orphan_or_cross_tenant_rows',count(*))
    FROM public.company_branding_audit audit
    LEFT JOIN public.companies company ON company.id=audit.company_id
    LEFT JOIN public.profiles actor ON actor.id=audit.actor_id
    WHERE company.id IS NULL OR actor.id IS NULL

    UNION ALL

    SELECT
        'branding_runtime_inventory',
        'INFO',
        jsonb_build_object(
            'profiles',(SELECT count(*)
                        FROM public.company_branding_profiles),
            'active_logos',(SELECT count(*)
                            FROM public.company_branding_profiles
                            WHERE logo_object_path IS NOT NULL),
            'audit_rows',(SELECT count(*)
                          FROM public.company_branding_audit),
            'bucket_objects',(SELECT count(*) FROM storage.objects
                              WHERE bucket_id='company-branding')
        )
)
SELECT check_name,status,details
FROM checks
ORDER BY
    CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,
    check_name;
