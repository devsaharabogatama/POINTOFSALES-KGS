-- BRD phase 1 preflight: tenant-safe Company logo/branding readiness.
--
-- SAFETY:
-- - SELECT-only; no DDL, DML, TEMP table, function side effect, or grants.
-- - Returns aggregate counts and catalog metadata only; no Company names,
--   object names, user identities, or business rows.

WITH required_versions(version) AS (
    VALUES ('20260811100000')
), expected_relations(relation_name) AS (
    VALUES ('company_branding_profiles'), ('company_branding_audit')
), expected_profile_columns(column_name) AS (
    VALUES
        ('company_id'), ('logo_object_path'), ('logo_public_url'),
        ('logo_mime_type'), ('logo_size_bytes'), ('logo_checksum_sha256'),
        ('logo_version'), ('master_version'), ('uploaded_by'),
        ('uploaded_at'), ('updated_by'), ('updated_at')
), expected_audit_columns(column_name) AS (
    VALUES
        ('id'), ('company_id'), ('action'), ('actor_id'),
        ('before_state'), ('after_state'), ('created_at')
), target_bucket AS (
    SELECT
        bucket.id,
        bucket.public,
        bucket.file_size_limit,
        bucket.allowed_mime_types
    FROM storage.buckets bucket
    WHERE bucket.id = 'company-branding'
), checks AS (
    SELECT
        'brd_phase1_dependency'::TEXT AS check_name,
        CASE WHEN count(*) FILTER (WHERE migration.version IS NULL) = 0
            THEN 'PASS' ELSE 'BLOCKER' END AS status,
        jsonb_build_object(
            'expected',count(*),
            'missing',COALESCE(
                jsonb_agg(required.version ORDER BY required.version)
                    FILTER (WHERE migration.version IS NULL),
                '[]'::JSONB
            )
        ) AS details
    FROM required_versions required
    LEFT JOIN private.kgs_schema_migrations migration
      ON migration.version = required.version

    UNION ALL

    SELECT
        'supabase_storage_catalog_readiness',
        CASE WHEN to_regclass('storage.buckets') IS NOT NULL
                  AND to_regclass('storage.objects') IS NOT NULL
             THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'storage_schema_exists',EXISTS(
                SELECT 1 FROM information_schema.schemata
                WHERE schema_name='storage'
            ),
            'buckets_table_exists',
                to_regclass('storage.buckets') IS NOT NULL,
            'objects_table_exists',
                to_regclass('storage.objects') IS NOT NULL
        )

    UNION ALL

    SELECT
        'canonical_branding_schema_state','SETUP',
        jsonb_build_object(
            'missing_relations',COALESCE(
                jsonb_agg(expected.relation_name ORDER BY expected.relation_name)
                    FILTER (WHERE catalog.oid IS NULL),
                '[]'::JSONB
            )
        )
    FROM expected_relations expected
    LEFT JOIN pg_catalog.pg_class catalog
      ON catalog.oid=to_regclass('public.' || expected.relation_name)

    UNION ALL

    SELECT
        'canonical_branding_profile_column_state','SETUP',
        jsonb_build_object(
            'missing_columns',COALESCE(
                jsonb_agg(expected.column_name ORDER BY expected.column_name)
                    FILTER (WHERE column_state.column_name IS NULL),
                '[]'::JSONB
            )
        )
    FROM expected_profile_columns expected
    LEFT JOIN information_schema.columns column_state
      ON column_state.table_schema='public'
     AND column_state.table_name='company_branding_profiles'
     AND column_state.column_name=expected.column_name

    UNION ALL

    SELECT
        'canonical_branding_audit_column_state','SETUP',
        jsonb_build_object(
            'missing_columns',COALESCE(
                jsonb_agg(expected.column_name ORDER BY expected.column_name)
                    FILTER (WHERE column_state.column_name IS NULL),
                '[]'::JSONB
            )
        )
    FROM expected_audit_columns expected
    LEFT JOIN information_schema.columns column_state
      ON column_state.table_schema='public'
     AND column_state.table_name='company_branding_audit'
     AND column_state.column_name=expected.column_name

    UNION ALL

    SELECT
        'company_branding_bucket_state',
        CASE
            WHEN count(*)=0 THEN 'SETUP'
            WHEN bool_and(public)
             AND bool_and(file_size_limit=2097152)
             AND bool_and(allowed_mime_types @> ARRAY[
                    'image/png','image/jpeg','image/webp'
                 ]::TEXT[])
             AND bool_and(cardinality(allowed_mime_types)=3)
                THEN 'PASS'
            ELSE 'BLOCKER'
        END,
        jsonb_build_object(
            'bucket_rows',count(*),
            'public_rows',count(*) FILTER (WHERE public),
            'two_megabyte_limit_rows',count(*) FILTER (
                WHERE file_size_limit=2097152
            ),
            'exact_mime_contract_rows',count(*) FILTER (
                WHERE allowed_mime_types @> ARRAY[
                        'image/png','image/jpeg','image/webp'
                    ]::TEXT[]
                  AND cardinality(allowed_mime_types)=3
            )
        )
    FROM target_bucket

    UNION ALL

    SELECT
        'existing_branding_object_scope',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object('object_count',count(*))
    FROM storage.objects object_state
    WHERE object_state.bucket_id='company-branding'

    UNION ALL

    SELECT
        'unsafe_browser_branding_storage_policy',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('policy_count',count(*))
    FROM pg_catalog.pg_policies policy
    WHERE policy.schemaname='storage'
      AND policy.tablename='objects'
      AND policy.cmd IN ('ALL','INSERT','UPDATE','DELETE')
      AND 'authenticated'=ANY(policy.roles::TEXT[])
      AND concat_ws(' ',policy.qual,policy.with_check)
            ILIKE '%company-branding%'

    UNION ALL

    SELECT
        'active_company_branding_operator_readiness',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object('company_count',count(*))
    FROM public.companies company
    WHERE company.status='ACTIVE'
      AND NOT EXISTS (
          SELECT 1
          FROM public.company_memberships membership
          WHERE membership.company_id=company.id
            AND membership.status='ACTIVE'
            AND membership.role_code IN ('COMPANY_OWNER','COMPANY_ADMIN')
      )

    UNION ALL

    SELECT
        'company_identity_readiness',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.companies company
    WHERE btrim(company.company_code)=''
       OR btrim(company.company_name)=''
       OR btrim(company.company_slug)=''

    UNION ALL

    SELECT
        'legacy_company_branding_column_inventory','INFO',
        jsonb_build_object(
            'column_count',count(*),
            'column_names',COALESCE(
                jsonb_agg(column_state.column_name ORDER BY column_state.column_name),
                '[]'::JSONB
            )
        )
    FROM information_schema.columns column_state
    WHERE column_state.table_schema='public'
      AND column_state.table_name='companies'
      AND (
          column_state.column_name ILIKE '%logo%'
          OR column_state.column_name ILIKE '%brand%'
      )

    UNION ALL

    SELECT
        'browser_company_branding_write_boundary','INFO',
        jsonb_build_object(
            'companies_update',has_table_privilege(
                'authenticated','public.companies','UPDATE'
            ),
            'storage_objects_insert',has_table_privilege(
                'authenticated','storage.objects','INSERT'
            ),
            'storage_objects_update',has_table_privilege(
                'authenticated','storage.objects','UPDATE'
            ),
            'storage_objects_delete',has_table_privilege(
                'authenticated','storage.objects','DELETE'
            )
        )

    UNION ALL

    SELECT
        'company_branding_source_inventory','INFO',
        jsonb_build_object(
            'companies',count(*),
            'active_companies',count(*) FILTER (WHERE status='ACTIVE'),
            'companies_with_legal_name',count(*) FILTER (
                WHERE NULLIF(btrim(legal_name),'') IS NOT NULL
            ),
            'companies_with_tax_id',count(*) FILTER (
                WHERE NULLIF(btrim(tax_id),'') IS NOT NULL
            )
        )
    FROM public.companies
)
SELECT check_name,status,details
FROM checks
ORDER BY
    CASE status
        WHEN 'BLOCKER' THEN 1
        WHEN 'REVIEW' THEN 2
        WHEN 'SETUP' THEN 3
        WHEN 'BACKFILL' THEN 4
        WHEN 'PASS' THEN 5
        ELSE 6
    END,
    check_name;
