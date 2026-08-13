-- G5 optional Supplier Invoice tolerance corrective postflight.
-- SAFETY: SELECT-only, aggregate metadata only.

WITH checks AS (
    SELECT
        'migration_ledger'::text AS check_name,
        CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'FAIL' END AS status,
        CASE WHEN count(*) = 1 THEN 0 ELSE 1 END AS violation_rows,
        jsonb_build_object('ledger_rows',count(*)) AS details
    FROM private.kgs_schema_migrations
    WHERE version = '20260810160000'

    UNION ALL

    SELECT
        'private_tolerance_resolver',
        CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN count(*) = 1 THEN 0 ELSE 1 END,
        jsonb_build_object('routine_rows',count(*))
    FROM pg_proc routine
    JOIN pg_namespace namespace ON namespace.oid = routine.pronamespace
    WHERE namespace.nspname = 'private'
      AND routine.proname = 'refresh_supplier_invoice_totals'
      AND pg_get_function_identity_arguments(routine.oid) =
          'p_company_id uuid, p_document_id uuid'
      AND routine.prosecdef

    UNION ALL

    SELECT
        'browser_tolerance_resolver_boundary',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),
        jsonb_build_object('browser_executable_rows',count(*))
    FROM pg_proc routine
    JOIN pg_namespace namespace ON namespace.oid = routine.pronamespace
    WHERE namespace.nspname = 'private'
      AND routine.proname = 'refresh_supplier_invoice_totals'
      AND (
          has_function_privilege('anon',routine.oid,'EXECUTE')
          OR has_function_privilege('authenticated',routine.oid,'EXECUTE')
      )

    UNION ALL

    SELECT
        'partial_quantity_marked_within_tolerance',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),
        jsonb_build_object('row_count',count(*))
    FROM public.supplier_invoice_tolerance_results result
    WHERE result.result_status = 'WITHIN_TOLERANCE'
      AND result.allocated_base_qty < result.invoice_base_qty

    UNION ALL

    SELECT
        'optional_tolerance_runtime_inventory',
        'INFO',
        0,
        jsonb_build_object(
            'documents',(SELECT count(*) FROM public.supplier_invoice_documents),
            'documents_without_policy',(
                SELECT count(*) FROM public.supplier_invoice_documents
                WHERE tolerance_policy_id IS NULL
            ),
            'within_tolerance_results',(
                SELECT count(*)
                FROM public.supplier_invoice_tolerance_results
                WHERE result_status = 'WITHIN_TOLERANCE'
            ),
            'exception_results',(
                SELECT count(*)
                FROM public.supplier_invoice_tolerance_results
                WHERE result_status = 'EXCEPTION'
            )
        )
)
SELECT check_name,status,violation_rows,details
FROM checks
ORDER BY
    CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,
    check_name;
