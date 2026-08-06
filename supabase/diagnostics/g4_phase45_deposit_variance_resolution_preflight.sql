-- G4 phase 45 preflight: Deposit variance investigation/resolution readiness.
--
-- SAFETY:
-- - SELECT-only; no DDL, DML, TEMP table, function side effect, or grants.
-- - Returns aggregate counts only; no Cashier, destination, or evidence values.
-- - Does not resolve, write off, refund, reclassify, or journal a variance.

WITH required_versions(version) AS (
    VALUES ('20260804130000')
), expected_exception_columns(column_name) AS (
    VALUES
        ('master_version'),
        ('responsible_party_reason'),
        ('responsible_party_assigned_by'),
        ('responsible_party_assigned_at'),
        ('resolved_by'),
        ('resolved_at'),
        ('written_off_by'),
        ('written_off_at')
), expected_allocation_columns(column_name) AS (
    VALUES
        ('status'),
        ('submitted_by'),
        ('submitted_at'),
        ('reviewed_by'),
        ('reviewed_at'),
        ('rejection_reason'),
        ('resolution_reference')
), expected_runtime_routines(routine_name) AS (
    VALUES
        ('assign_deposit_variance_responsible_party'),
        ('resolve_deposit_variance'),
        ('review_deposit_variance_resolution')
), required_resolution_functions(variance_type,function_key) AS (
    VALUES
        ('UNDER_DEPOSIT','CASH_SHORTAGE_CONTROL'),
        ('UNDER_DEPOSIT','CASH_DRAWER'),
        ('UNDER_DEPOSIT','BANK'),
        ('UNDER_DEPOSIT','EXPENSE'),
        ('OVER_DEPOSIT','CASH_DRAWER'),
        ('OVER_DEPOSIT','BANK'),
        ('OVER_DEPOSIT','OTHER_INCOME')
), exception_inventory AS (
    SELECT exception.*
    FROM public.deposit_variance_exceptions exception
), allocation_summary AS (
    SELECT
        exception.id AS exception_id,
        COALESCE(sum(allocation.allocation_amount),0) AS allocation_total,
        count(allocation.id) AS allocation_count
    FROM exception_inventory exception
    LEFT JOIN public.deposit_variance_allocations allocation
      ON allocation.company_id=exception.company_id
     AND allocation.variance_exception_id=exception.id
    GROUP BY exception.id
), affected_company_function AS (
    SELECT DISTINCT
        exception.company_id,
        required.function_key
    FROM exception_inventory exception
    JOIN required_resolution_functions required
      ON required.variance_type=exception.variance_type
    WHERE exception.status NOT IN ('RESOLVED','WRITTEN_OFF','CANCELED')
), company_function_readiness AS (
    SELECT
        affected.company_id,
        affected.function_key,
        EXISTS (
            SELECT 1
            FROM public.transaction_categories category
            JOIN public.transaction_account_rules rule
              ON rule.company_id=category.company_id
             AND rule.transaction_category_id=category.id
             AND rule.account_function_key=affected.function_key
            JOIN public.chart_of_accounts account
              ON account.company_id=rule.company_id
             AND account.id=rule.account_id
            WHERE category.company_id=affected.company_id
              AND category.system_key='CASH_VARIANCE'
              AND category.is_active
              AND rule.status='ACTIVE'
              AND rule.effective_from<=clock_timestamp()
              AND (
                  rule.effective_to IS NULL
                  OR rule.effective_to>clock_timestamp()
              )
              AND account.is_active
              AND account.is_postable
        ) OR EXISTS (
            SELECT 1
            FROM public.company_account_function_fallbacks fallback
            JOIN public.chart_of_accounts account
              ON account.company_id=fallback.company_id
             AND account.id=fallback.account_id
            WHERE fallback.company_id=affected.company_id
              AND fallback.account_function_key=affected.function_key
              AND fallback.status='ACTIVE'
              AND fallback.effective_from<=clock_timestamp()
              AND (
                  fallback.effective_to IS NULL
                  OR fallback.effective_to>clock_timestamp()
              )
              AND account.is_active
              AND account.is_postable
        ) AS is_ready
    FROM affected_company_function affected
), checks AS (
    SELECT
        'g4_phase45_dependencies'::text AS check_name,
        CASE WHEN count(*) FILTER (WHERE migration.version IS NULL)=0
             THEN 'PASS' ELSE 'BLOCKER' END AS status,
        jsonb_build_object(
            'expected',count(*),
            'missing',COALESCE(
                jsonb_agg(required.version ORDER BY required.version)
                    FILTER (WHERE migration.version IS NULL),
                '[]'::jsonb
            )
        ) AS details
    FROM required_versions required
    LEFT JOIN private.kgs_schema_migrations migration
      ON migration.version=required.version

    UNION ALL

    SELECT
        'canonical_variance_exception_schema_state',
        CASE WHEN count(*) FILTER (WHERE column_state.column_name IS NULL)=0
             THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object(
            'expected_columns',count(*),
            'missing_columns',COALESCE(
                jsonb_agg(expected.column_name ORDER BY expected.column_name)
                    FILTER (WHERE column_state.column_name IS NULL),
                '[]'::jsonb
            )
        )
    FROM expected_exception_columns expected
    LEFT JOIN information_schema.columns column_state
      ON column_state.table_schema='public'
     AND column_state.table_name='deposit_variance_exceptions'
     AND column_state.column_name=expected.column_name

    UNION ALL

    SELECT
        'canonical_variance_allocation_schema_state',
        CASE WHEN count(*) FILTER (WHERE column_state.column_name IS NULL)=0
             THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object(
            'expected_columns',count(*),
            'missing_columns',COALESCE(
                jsonb_agg(expected.column_name ORDER BY expected.column_name)
                    FILTER (WHERE column_state.column_name IS NULL),
                '[]'::jsonb
            )
        )
    FROM expected_allocation_columns expected
    LEFT JOIN information_schema.columns column_state
      ON column_state.table_schema='public'
     AND column_state.table_name='deposit_variance_allocations'
     AND column_state.column_name=expected.column_name

    UNION ALL

    SELECT
        'canonical_variance_runtime_state',
        CASE WHEN count(*) FILTER (WHERE routine_state.routine_name IS NULL)=0
             THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object(
            'expected_routines',count(*),
            'missing_routines',COALESCE(
                jsonb_agg(expected.routine_name ORDER BY expected.routine_name)
                    FILTER (WHERE routine_state.routine_name IS NULL),
                '[]'::jsonb
            )
        )
    FROM expected_runtime_routines expected
    LEFT JOIN LATERAL (
        SELECT procedure.proname AS routine_name
        FROM pg_proc procedure
        JOIN pg_namespace namespace
          ON namespace.oid=procedure.pronamespace
        WHERE namespace.nspname='public'
          AND procedure.proname=expected.routine_name
        LIMIT 1
    ) routine_state ON TRUE

    UNION ALL

    SELECT
        'variance_investigation_status_contract',
        CASE WHEN count(*)=1 AND bool_or(
            pg_get_constraintdef(constraint_state.oid)
                LIKE '%UNDER_INVESTIGATION%'
        ) THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object(
            'constraint_rows',count(*),
            'under_investigation_supported',COALESCE(bool_or(
                pg_get_constraintdef(constraint_state.oid)
                    LIKE '%UNDER_INVESTIGATION%'
            ),FALSE)
        )
    FROM pg_constraint constraint_state
    JOIN pg_class relation ON relation.oid=constraint_state.conrelid
    JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
    WHERE namespace.nspname='public'
      AND relation.relname='deposit_variance_exceptions'
      AND constraint_state.conname='deposit_variance_exception_status_check'

    UNION ALL

    SELECT
        'variance_resolution_type_contract',
        CASE WHEN count(*)=1 AND bool_or(
            pg_get_constraintdef(constraint_state.oid)
                LIKE '%SOURCE_CORRECTION%'
        ) AND bool_or(
            pg_get_constraintdef(constraint_state.oid)
                LIKE '%RECOVERED_FUNDS%'
        ) THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object(
            'constraint_rows',count(*),
            'source_correction_supported',COALESCE(bool_or(
                pg_get_constraintdef(constraint_state.oid)
                    LIKE '%SOURCE_CORRECTION%'
            ),FALSE),
            'recovered_funds_supported',COALESCE(bool_or(
                pg_get_constraintdef(constraint_state.oid)
                    LIKE '%RECOVERED_FUNDS%'
            ),FALSE)
        )
    FROM pg_constraint constraint_state
    JOIN pg_class relation ON relation.oid=constraint_state.conrelid
    JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
    WHERE namespace.nspname='public'
      AND relation.relname='deposit_variance_allocations'
      AND constraint_state.conname=
          'deposit_variance_allocation_resolution_check'

    UNION ALL

    SELECT
        'approved_deposit_variance_exception_coverage',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('deposit_count',count(*))
    FROM public.cash_deposit_documents document
    LEFT JOIN exception_inventory exception
      ON exception.company_id=document.company_id
     AND exception.cash_deposit_document_id=document.id
    WHERE document.status='APPROVED'
      AND document.deposit_variance<>0
      AND exception.id IS NULL

    UNION ALL

    SELECT
        'matched_deposit_with_variance_exception',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('deposit_count',count(*))
    FROM public.cash_deposit_documents document
    JOIN exception_inventory exception
      ON exception.company_id=document.company_id
     AND exception.cash_deposit_document_id=document.id
    WHERE document.deposit_variance=0
       OR document.variance_type='MATCHED'

    UNION ALL

    SELECT
        'invalid_variance_exception_source',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM exception_inventory exception
    LEFT JOIN public.cash_deposit_documents document
      ON document.company_id=exception.company_id
     AND document.id=exception.cash_deposit_document_id
    WHERE document.id IS NULL
       OR document.status<>'APPROVED'
       OR document.store_id<>exception.store_id
       OR document.variance_type<>exception.variance_type
       OR abs(document.deposit_variance)<>exception.original_amount
       OR document.variance_account_id<>exception.control_account_id

    UNION ALL

    SELECT
        'variance_exception_amount_reconciliation',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('exception_count',count(*))
    FROM exception_inventory exception
    JOIN allocation_summary allocation
      ON allocation.exception_id=exception.id
    WHERE exception.original_amount<=0
       OR exception.resolved_amount<0
       OR exception.remaining_amount<0
       OR exception.resolved_amount>exception.original_amount
       OR exception.remaining_amount<>
            exception.original_amount-exception.resolved_amount
       OR allocation.allocation_total<>exception.resolved_amount

    UNION ALL

    SELECT
        'invalid_variance_exception_lifecycle',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM exception_inventory exception
    WHERE (
        exception.status='OPEN'
        AND exception.resolved_amount<>0
    ) OR (
        exception.status='PARTIALLY_RESOLVED'
        AND (
            exception.resolved_amount<=0
            OR exception.remaining_amount<=0
        )
    ) OR (
        exception.status IN ('RESOLVED','WRITTEN_OFF')
        AND exception.remaining_amount<>0
    )

    UNION ALL

    SELECT
        'invalid_variance_responsible_party',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM exception_inventory exception
    WHERE (
        exception.responsible_party_type IS NULL
        AND exception.responsible_party_id IS NOT NULL
    ) OR (
        exception.responsible_party_type IS NOT NULL
        AND exception.responsible_party_type<>'INTERNAL_USER'
    ) OR (
        exception.responsible_party_type='INTERNAL_USER'
        AND NOT EXISTS (
            SELECT 1
            FROM public.company_memberships membership
            WHERE membership.company_id=exception.company_id
              AND membership.user_id=exception.responsible_party_id
              AND membership.status='ACTIVE'
        )
    )

    UNION ALL

    SELECT
        'invalid_variance_allocation_reference',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.deposit_variance_allocations allocation
    LEFT JOIN exception_inventory exception
      ON exception.company_id=allocation.company_id
     AND exception.id=allocation.variance_exception_id
    LEFT JOIN public.chart_of_accounts account
      ON account.company_id=allocation.company_id
     AND account.id=allocation.account_id
    LEFT JOIN public.transaction_categories category
      ON category.company_id=allocation.company_id
     AND category.id=allocation.transaction_category_id
    WHERE exception.id IS NULL
       OR allocation.allocation_amount<=0
       OR btrim(allocation.reason)=''
       OR (
           allocation.evidence_url IS NOT NULL
           AND allocation.evidence_url!~*'^https://'
       )
       OR (
           allocation.account_id IS NOT NULL
           AND (
               account.id IS NULL
               OR NOT account.is_active
               OR NOT account.is_postable
           )
       )
       OR (
           allocation.transaction_category_id IS NOT NULL
           AND (
               category.id IS NULL
               OR NOT category.is_active
           )
       )

    UNION ALL

    SELECT
        'resolution_account_function_catalog',
        CASE WHEN count(*) FILTER (WHERE function_state.function_key IS NULL)=0
             THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'expected',count(*),
            'missing',COALESCE(
                jsonb_agg(DISTINCT required.function_key)
                    FILTER (WHERE function_state.function_key IS NULL),
                '[]'::jsonb
            )
        )
    FROM (
        SELECT DISTINCT function_key
        FROM required_resolution_functions
    ) required
    LEFT JOIN public.account_functions function_state
      ON function_state.function_key=required.function_key

    UNION ALL

    SELECT
        'open_variance_account_resolution_scope',
        CASE WHEN count(*) FILTER (WHERE NOT readiness.is_ready)=0
             THEN 'PASS' ELSE 'BACKFILL' END,
        jsonb_build_object(
            'company_function_rows',count(*),
            'missing_company_function_rows',count(*) FILTER (
                WHERE NOT readiness.is_ready
            ),
            'companies_affected',count(DISTINCT readiness.company_id)
        )
    FROM company_function_readiness readiness

    UNION ALL

    SELECT
        'open_variance_transaction_category_scope',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BACKFILL' END,
        jsonb_build_object('company_count',count(*))
    FROM (
        SELECT DISTINCT exception.company_id
        FROM exception_inventory exception
        WHERE exception.status NOT IN (
            'RESOLVED','WRITTEN_OFF','CANCELED'
        )
          AND NOT EXISTS (
              SELECT 1
              FROM public.transaction_categories category
              WHERE category.company_id=exception.company_id
                AND category.system_key='CASH_VARIANCE'
                AND category.is_active
          )
    ) missing_company

    UNION ALL

    SELECT
        'deposit_variance_resolution_event_state',
        CASE WHEN count(*)=1 THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object('event_rows',count(*))
    FROM pg_enum enum_value
    JOIN pg_type enum_type ON enum_type.oid=enum_value.enumtypid
    JOIN pg_namespace namespace ON namespace.oid=enum_type.typnamespace
    WHERE namespace.nspname='public'
      AND enum_type.typname='event_type'
      AND enum_value.enumlabel='DEPOSIT_VARIANCE_RESOLUTION'

    UNION ALL

    SELECT
        'browser_direct_variance_write_privilege',
        'INFO',
        jsonb_build_object(
            'exception_insert',has_table_privilege(
                'authenticated','public.deposit_variance_exceptions','INSERT'
            ),
            'exception_update',has_table_privilege(
                'authenticated','public.deposit_variance_exceptions','UPDATE'
            ),
            'allocation_insert',has_table_privilege(
                'authenticated','public.deposit_variance_allocations','INSERT'
            ),
            'allocation_update',has_table_privilege(
                'authenticated','public.deposit_variance_allocations','UPDATE'
            )
        )

    UNION ALL

    SELECT
        'deposit_variance_inventory',
        'INFO',
        jsonb_build_object(
            'approved_deposits',(
                SELECT count(*)
                FROM public.cash_deposit_documents
                WHERE status='APPROVED'
            ),
            'approved_under_deposits',(
                SELECT count(*)
                FROM public.cash_deposit_documents
                WHERE status='APPROVED'
                  AND variance_type='UNDER_DEPOSIT'
            ),
            'approved_over_deposits',(
                SELECT count(*)
                FROM public.cash_deposit_documents
                WHERE status='APPROVED'
                  AND variance_type='OVER_DEPOSIT'
            ),
            'exceptions',count(*),
            'open_exceptions',count(*) FILTER (
                WHERE status NOT IN (
                    'RESOLVED','WRITTEN_OFF','CANCELED'
                )
            ),
            'original_amount_total',COALESCE(sum(original_amount),0),
            'resolved_amount_total',COALESCE(sum(resolved_amount),0),
            'remaining_amount_total',COALESCE(sum(remaining_amount),0),
            'allocation_rows',(
                SELECT count(*)
                FROM public.deposit_variance_allocations
            )
        )
    FROM exception_inventory
)
SELECT check_name,status,details
FROM checks
ORDER BY
    CASE status
        WHEN 'BLOCKER' THEN 1
        WHEN 'BACKFILL' THEN 2
        WHEN 'SETUP' THEN 3
        WHEN 'PASS' THEN 4
        ELSE 5
    END,
    check_name;
