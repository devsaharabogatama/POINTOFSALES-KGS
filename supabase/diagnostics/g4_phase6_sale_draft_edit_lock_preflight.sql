-- G4 phase 6 preflight: Sale Draft list, lifecycle, and single-editor lock.
--
-- SAFETY:
-- - SELECT-only; no DDL, DML, TEMP table, side-effect function, or grants.
-- - Returns aggregate counts and schema/routine state only.
-- - Run the entire file in Supabase SQL Editor and export the final result.

WITH required_versions(version) AS (
    VALUES ('20260729070000'), ('20260729100000')
), expected_columns(column_name) AS (
    VALUES
        ('draft_no'), ('draft_label'), ('draft_notes'),
        ('created_session_id'), ('edit_lock_owner_id'),
        ('edit_lock_session_id'), ('edit_lock_acquired_at'),
        ('edit_lock_heartbeat_at'), ('canceled_at'), ('canceled_by'),
        ('cancel_reason')
), expected_routines(routine_name) AS (
    VALUES
        ('list_pos_sale_drafts'),
        ('acquire_pos_sale_draft_lock'),
        ('heartbeat_pos_sale_draft_lock'),
        ('release_pos_sale_draft_lock'),
        ('cancel_pos_sale_draft')
), draft_inventory AS (
    SELECT
        sh.*,
        clock_timestamp() - sh.created_at AS draft_age
    FROM public.sales_headers sh
    WHERE sh.document_status = 'DRAFT'
), checks AS (
    SELECT
        'g4_phase6_dependencies'::text AS check_name,
        CASE WHEN count(*) FILTER (WHERE m.version IS NULL) = 0
             THEN 'PASS' ELSE 'BLOCKER' END AS status,
        jsonb_build_object(
            'expected', count(*),
            'missing', COALESCE(
                jsonb_agg(r.version ORDER BY r.version)
                    FILTER (WHERE m.version IS NULL),
                '[]'::jsonb
            )
        ) AS details
    FROM required_versions r
    LEFT JOIN private.kgs_schema_migrations m ON m.version = r.version

    UNION ALL

    SELECT
        'sale_draft_inventory',
        'INFO',
        jsonb_build_object(
            'draft_rows', count(*),
            'companies', count(DISTINCT company_id),
            'stores', count(DISTINCT store_id),
            'creators', count(DISTINCT created_by),
            'drafts_older_than_7_days',
                count(*) FILTER (WHERE draft_age > interval '7 days'),
            'drafts_with_blocker',
                count(*) FILTER (WHERE blocker_snapshot IS NOT NULL)
        )
    FROM draft_inventory

    UNION ALL

    SELECT
        'invalid_sale_draft_identity',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count', count(*))
    FROM draft_inventory
    WHERE NULLIF(btrim(invoice_no), '') IS NULL
       OR company_id IS NULL
       OR store_id IS NULL
       OR pos_id IS NULL
       OR session_id IS NULL
       OR created_by IS NULL
       OR client_transaction_id IS NULL
       OR master_version <= 0

    UNION ALL

    SELECT
        'sale_draft_created_session_scope',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count', count(*))
    FROM draft_inventory sh
    LEFT JOIN public.cashier_sessions cs
      ON cs.company_id = sh.company_id
     AND cs.id = sh.session_id
    WHERE cs.id IS NULL
       OR cs.store_id IS DISTINCT FROM sh.store_id

    UNION ALL

    SELECT
        'sale_draft_with_final_payment',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count', count(*))
    FROM draft_inventory sh
    WHERE EXISTS (
        SELECT 1
        FROM public.sales_payments sp
        WHERE sp.company_id = sh.company_id
          AND sp.sales_id = sh.id
    )

    UNION ALL

    SELECT
        'sale_draft_with_stock_movement',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count', count(*))
    FROM draft_inventory sh
    WHERE EXISTS (
        SELECT 1
        FROM public.stock_movements sm
        WHERE sm.company_id = sh.company_id
          AND sm.reference_table = 'sales_headers'
          AND sm.reference_id = sh.id
    )

    UNION ALL

    SELECT
        'sale_draft_with_financial_event',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count', count(*))
    FROM draft_inventory sh
    WHERE EXISTS (
        SELECT 1
        FROM public.financial_events fe
        WHERE fe.company_id = sh.company_id
          AND fe.source_table = 'sales_headers'
          AND fe.source_id = sh.id
    )

    UNION ALL

    SELECT
        'sale_draft_without_payload_snapshot',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object('row_count', count(*))
    FROM draft_inventory
    WHERE payload_snapshot IS NULL
       OR jsonb_typeof(payload_snapshot) IS DISTINCT FROM 'object'

    UNION ALL

    SELECT
        'canonical_sale_draft_lock_schema_state',
        CASE WHEN count(*) FILTER (WHERE c.column_name IS NULL) = 0
             THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object(
            'missing_columns', COALESCE(
                jsonb_agg(e.column_name ORDER BY e.column_name)
                    FILTER (WHERE c.column_name IS NULL),
                '[]'::jsonb
            ),
            'expected_columns', count(*)
        )
    FROM expected_columns e
    LEFT JOIN information_schema.columns c
      ON c.table_schema = 'public'
     AND c.table_name = 'sales_headers'
     AND c.column_name = e.column_name

    UNION ALL

    SELECT
        'canonical_sale_draft_lock_routine_state',
        CASE WHEN count(*) FILTER (WHERE p.proname IS NULL) = 0
             THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object(
            'missing_routines', COALESCE(
                jsonb_agg(e.routine_name ORDER BY e.routine_name)
                    FILTER (WHERE p.proname IS NULL),
                '[]'::jsonb
            ),
            'expected_routines', count(*)
        )
    FROM expected_routines e
    LEFT JOIN (
        SELECT DISTINCT proname
        FROM pg_proc
        WHERE pronamespace = 'public'::regnamespace
    ) p ON p.proname = e.routine_name

    UNION ALL

    SELECT
        'same_store_cashier_draft_visibility_contract',
        CASE WHEN count(*) = 1
                  AND bool_or(
                      pg_get_functiondef(p.oid) ~
                      'CASHIER|private_user_has_company_access'
                  )
             THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object(
            'helper_rows', count(*),
            'same_store_cashier_path_present', COALESCE(
                bool_or(
                    pg_get_functiondef(p.oid) ~
                    'CASHIER|private_user_has_company_access'
                ),
                FALSE
            )
        )
    FROM pg_proc p
    WHERE p.oid =
        to_regprocedure('public.private_sales_document_visible(uuid)')

    UNION ALL

    SELECT
        'sale_draft_audit_action_contract',
        CASE WHEN count(*) = 1
                  AND bool_or(
                      pg_get_constraintdef(c.oid) ~ 'LOCK_ACQUIRE'
                      AND pg_get_constraintdef(c.oid) ~ 'LOCK_TAKEOVER'
                      AND pg_get_constraintdef(c.oid) ~ 'LOCK_RELEASE'
                      AND pg_get_constraintdef(c.oid) ~ 'CANCEL_DRAFT'
                  )
             THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object(
            'constraint_rows', count(*),
            'lock_and_cancel_actions_present', COALESCE(
                bool_or(
                    pg_get_constraintdef(c.oid) ~ 'LOCK_ACQUIRE'
                    AND pg_get_constraintdef(c.oid) ~ 'LOCK_TAKEOVER'
                    AND pg_get_constraintdef(c.oid) ~ 'LOCK_RELEASE'
                    AND pg_get_constraintdef(c.oid) ~ 'CANCEL_DRAFT'
                ),
                FALSE
            )
        )
    FROM pg_constraint c
    WHERE c.conrelid = 'public.sale_master_audit'::regclass
      AND c.conname = 'sale_master_audit_action_check'

    UNION ALL

    SELECT
        'direct_sale_draft_write_privilege',
        'INFO',
        jsonb_build_object(
            'sales_headers_insert', has_table_privilege(
                'authenticated','public.sales_headers','INSERT'
            ),
            'sales_headers_update', has_table_privilege(
                'authenticated','public.sales_headers','UPDATE'
            ),
            'sales_headers_delete', has_table_privilege(
                'authenticated','public.sales_headers','DELETE'
            ),
            'sale_audit_insert', has_table_privilege(
                'authenticated','public.sale_master_audit','INSERT'
            )
        )
)
SELECT check_name, status, details
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
