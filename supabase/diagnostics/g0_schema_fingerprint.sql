-- G0 catalog fingerprint for KGS POS.
--
-- SAFETY:
-- - SELECT-only: no TEMP table, DDL, DML, GRANT, REVOKE, or persistent changes.
-- - Returns schema metadata/definitions only, never business-row contents.
-- - Run the entire file in Supabase SQL Editor and export the final result.

WITH catalog_rows AS (
    -- Installed extensions.
    SELECT
        'extension'::text AS object_type,
        e.extname::text AS object_name,
        'definition'::text AS property,
        jsonb_build_object(
            'version', e.extversion,
            'schema', n.nspname
        ) AS value
    FROM pg_extension e
    JOIN pg_namespace n ON n.oid = e.extnamespace

    UNION ALL

    -- Enum labels and sort order.
    SELECT
        'enum',
        format('%I.%I', n.nspname, t.typname),
        'labels',
        jsonb_build_object(
            'labels', jsonb_agg(e.enumlabel ORDER BY e.enumsortorder)
        )
    FROM pg_type t
    JOIN pg_namespace n ON n.oid = t.typnamespace
    JOIN pg_enum e ON e.enumtypid = t.oid
    WHERE n.nspname = 'public'
    GROUP BY n.nspname, t.typname

    UNION ALL

    -- Public table columns.
    SELECT
        'column',
        format('%I.%I.%I', c.table_schema, c.table_name, c.column_name),
        'definition',
        jsonb_build_object(
            'ordinal_position', c.ordinal_position,
            'data_type', c.data_type,
            'udt_schema', c.udt_schema,
            'udt_name', c.udt_name,
            'nullable', c.is_nullable = 'YES',
            'default', c.column_default,
            'numeric_precision', c.numeric_precision,
            'numeric_scale', c.numeric_scale,
            'character_maximum_length', c.character_maximum_length
        )
    FROM information_schema.columns c
    WHERE c.table_schema = 'public'

    UNION ALL

    -- PK, FK, UNIQUE, CHECK, and exclusion constraints.
    SELECT
        'constraint',
        format('%I.%I.%I', n.nspname, rel.relname, con.conname),
        'definition',
        jsonb_build_object(
            'type', con.contype,
            'validated', con.convalidated,
            'deferrable', con.condeferrable,
            'initially_deferred', con.condeferred,
            'definition', pg_get_constraintdef(con.oid, true)
        )
    FROM pg_constraint con
    JOIN pg_class rel ON rel.oid = con.conrelid
    JOIN pg_namespace n ON n.oid = rel.relnamespace
    WHERE n.nspname = 'public'

    UNION ALL

    -- Index definitions, including unique indexes not backed by constraints.
    SELECT
        'index',
        format('%I.%I', i.schemaname, i.indexname),
        'definition',
        jsonb_build_object(
            'table', i.tablename,
            'definition', i.indexdef
        )
    FROM pg_indexes i
    WHERE i.schemaname = 'public'

    UNION ALL

    -- Exact RLS policy expressions and roles.
    SELECT
        'policy',
        format('%I.%I.%I', p.schemaname, p.tablename, p.policyname),
        'definition',
        jsonb_build_object(
            'permissive', p.permissive,
            'roles', p.roles,
            'command', p.cmd,
            'using', p.qual,
            'with_check', p.with_check
        )
    FROM pg_policies p
    WHERE p.schemaname = 'public'

    UNION ALL

    -- Key function definitions and ACL. Definition text is required because no
    -- migration registry exists to prove which local file was applied.
    SELECT
        'function',
        format(
            '%I.%I(%s)',
            n.nspname,
            p.proname,
            pg_get_function_identity_arguments(p.oid)
        ),
        'definition',
        jsonb_build_object(
            'owner', owner_role.rolname,
            'language', lang.lanname,
            'security_definer', p.prosecdef,
            'volatility', p.provolatile,
            'parallel', p.proparallel,
            'config', p.proconfig,
            'acl', p.proacl,
            'result', pg_get_function_result(p.oid),
            'definition_md5', md5(pg_get_functiondef(p.oid)),
            'definition', pg_get_functiondef(p.oid)
        )
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    JOIN pg_roles owner_role ON owner_role.oid = p.proowner
    JOIN pg_language lang ON lang.oid = p.prolang
    WHERE n.nspname = 'public'
      AND p.proname IN (
          'private_is_super_admin',
          'private_user_has_company_access',
          'private_user_has_store_access',
          'get_user_role_in_company',
          'handle_new_user',
          'import_products_for_company',
          'create_sales_transaction',
          'transfer_product_stock',
          'confirm_purchase_order',
          'process_financial_events_queue',
          'trg_cash_advances_to_financial_events',
          'trg_bank_deposits_to_financial_events'
      )

    UNION ALL

    -- Non-internal triggers with exact definition and enabled state.
    SELECT
        'trigger',
        format('%I.%I.%I', n.nspname, rel.relname, trg.tgname),
        'definition',
        jsonb_build_object(
            'enabled', trg.tgenabled,
            'definition', pg_get_triggerdef(trg.oid, true)
        )
    FROM pg_trigger trg
    JOIN pg_class rel ON rel.oid = trg.tgrelid
    JOIN pg_namespace n ON n.oid = rel.relnamespace
    WHERE n.nspname = 'public'
      AND NOT trg.tgisinternal

    UNION ALL

    -- Explicit table/view privileges for API roles.
    SELECT
        'table_privilege',
        format('%I.%I:%s', tp.table_schema, tp.table_name, tp.grantee),
        tp.privilege_type,
        jsonb_build_object(
            'grantor', tp.grantor,
            'grantable', tp.is_grantable = 'YES'
        )
    FROM information_schema.table_privileges tp
    WHERE tp.table_schema = 'public'
      AND tp.grantee IN ('anon', 'authenticated', 'service_role', 'PUBLIC')

    UNION ALL

    -- Explicit routine privileges for API roles.
    SELECT
        'routine_privilege',
        format('%I.%I:%s', rp.routine_schema, rp.routine_name, rp.grantee),
        rp.privilege_type,
        jsonb_build_object(
            'specific_name', rp.specific_name,
            'grantor', rp.grantor,
            'grantable', rp.is_grantable = 'YES'
        )
    FROM information_schema.routine_privileges rp
    WHERE rp.routine_schema = 'public'
      AND rp.grantee IN ('anon', 'authenticated', 'service_role', 'PUBLIC')

    UNION ALL

    -- Default privileges influence every future object and must be known before
    -- G1 creates new tables/functions.
    SELECT
        'default_privilege',
        format('%s:%s:%s', owner_role.rolname, COALESCE(n.nspname, '*'), d.defaclobjtype),
        'acl',
        jsonb_build_object('acl', d.defaclacl)
    FROM pg_default_acl d
    JOIN pg_roles owner_role ON owner_role.oid = d.defaclrole
    LEFT JOIN pg_namespace n ON n.oid = d.defaclnamespace
)
SELECT
    object_type,
    object_name,
    property,
    value
FROM catalog_rows
ORDER BY object_type, object_name, property;

