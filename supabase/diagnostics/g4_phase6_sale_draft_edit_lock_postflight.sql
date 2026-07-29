-- G4 phase 6 postflight: Sale Draft lifecycle and edit-lock foundation.
-- SAFETY: SELECT-only.

WITH expected_columns(column_name) AS (
    VALUES
        ('draft_no'), ('draft_label'), ('draft_notes'),
        ('created_session_id'), ('edit_lock_owner_id'),
        ('edit_lock_session_id'), ('edit_lock_acquired_at'),
        ('edit_lock_heartbeat_at'), ('canceled_at'), ('canceled_by'),
        ('cancel_reason')
), expected_routines(signature) AS (
    VALUES
        ('public.list_pos_sale_drafts(uuid)'),
        ('public.acquire_pos_sale_draft_lock(uuid,uuid,boolean)'),
        ('public.heartbeat_pos_sale_draft_lock(uuid,uuid)'),
        ('public.release_pos_sale_draft_lock(uuid,uuid,boolean,text)'),
        ('public.cancel_pos_sale_draft(uuid,bigint,uuid,text)'),
        ('public.save_pos_sale_draft(jsonb)'),
        ('public.post_pos_sale(uuid,bigint,uuid)')
), checks AS (
    SELECT
        'migration_ledger'::text AS check_name,
        CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'FAIL' END AS status,
        count(*)::bigint AS violation_rows,
        jsonb_build_object('ledger_rows',count(*)) AS details
    FROM private.kgs_schema_migrations
    WHERE version = '20260729120000'

    UNION ALL

    SELECT
        'required_draft_columns',
        CASE WHEN count(*) FILTER (WHERE c.column_name IS NULL) = 0
             THEN 'PASS' ELSE 'FAIL' END,
        count(*) FILTER (WHERE c.column_name IS NULL),
        jsonb_build_object(
            'column_rows',count(*) FILTER (WHERE c.column_name IS NOT NULL),
            'expected',count(*)
        )
    FROM expected_columns e
    LEFT JOIN information_schema.columns c
      ON c.table_schema = 'public'
     AND c.table_name = 'sales_headers'
     AND c.column_name = e.column_name

    UNION ALL

    SELECT
        'required_guarded_routines',
        CASE WHEN count(*) FILTER (
            WHERE to_regprocedure(e.signature) IS NULL
        ) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*) FILTER (WHERE to_regprocedure(e.signature) IS NULL),
        jsonb_build_object('expected',count(*))
    FROM expected_routines e

    UNION ALL

    SELECT
        'private_core_routine_boundary',
        CASE WHEN count(*) = 2
                  AND bool_and(
                      NOT has_function_privilege(
                          'authenticated',p.oid,'EXECUTE'
                      )
                      AND NOT has_function_privilege('anon',p.oid,'EXECUTE')
                  )
             THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN count(*) = 2 THEN count(*) FILTER (
            WHERE has_function_privilege('authenticated',p.oid,'EXECUTE')
               OR has_function_privilege('anon',p.oid,'EXECUTE')
        ) ELSE 1 END,
        jsonb_build_object('routine_rows',count(*))
    FROM pg_proc p
    WHERE p.oid IN (
        to_regprocedure('private.save_pos_sale_draft_core(jsonb)'),
        to_regprocedure('private.post_pos_sale_core(uuid,bigint,uuid)')
    )

    UNION ALL

    SELECT
        'draft_number_trigger',
        CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'FAIL' END,
        abs(1-count(*)),
        jsonb_build_object('trigger_rows',count(*))
    FROM pg_trigger
    WHERE tgrelid = 'public.sales_headers'::regclass
      AND tgname = 'g4_prepare_sale_draft'
      AND NOT tgisinternal

    UNION ALL

    SELECT
        'draft_lock_constraints',
        CASE WHEN count(*) = 3 THEN 'PASS' ELSE 'FAIL' END,
        abs(3-count(*)),
        jsonb_build_object('constraint_rows',count(*))
    FROM pg_constraint
    WHERE conrelid = 'public.sales_headers'::regclass
      AND conname IN (
          'sales_headers_edit_lock_shape',
          'sales_headers_canceled_contract',
          'fk_sales_headers_company_edit_lock_session'
      )

    UNION ALL

    SELECT
        'draft_lock_indexes',
        CASE WHEN count(*) = 3 THEN 'PASS' ELSE 'FAIL' END,
        abs(3-count(*)),
        jsonb_build_object('index_rows',count(*))
    FROM pg_indexes
    WHERE schemaname = 'public'
      AND tablename = 'sales_headers'
      AND indexname IN (
          'uq_sales_headers_company_draft_no',
          'idx_sales_headers_store_draft_updated',
          'idx_sales_headers_draft_lock_heartbeat'
      )

    UNION ALL

    SELECT
        'same_store_cashier_visibility',
        CASE WHEN count(*) = 1
                  AND bool_or(pg_get_functiondef(p.oid) ~ 'CASHIER')
             THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN count(*) = 1
                  AND bool_or(pg_get_functiondef(p.oid) ~ 'CASHIER')
             THEN 0 ELSE 1 END,
        jsonb_build_object('helper_rows',count(*))
    FROM pg_proc p
    WHERE p.oid =
        to_regprocedure('public.private_sales_document_visible(uuid)')

    UNION ALL

    SELECT
        'draft_audit_action_contract',
        CASE WHEN count(*) = 1
                  AND bool_or(
                      pg_get_constraintdef(c.oid) ~ 'LOCK_TAKEOVER'
                      AND pg_get_constraintdef(c.oid) ~ 'LOCK_FORCE_RELEASE'
                      AND pg_get_constraintdef(c.oid) ~ 'CANCEL_DRAFT'
                  )
             THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN count(*) = 1
                  AND bool_or(
                      pg_get_constraintdef(c.oid) ~ 'LOCK_TAKEOVER'
                      AND pg_get_constraintdef(c.oid) ~ 'LOCK_FORCE_RELEASE'
                      AND pg_get_constraintdef(c.oid) ~ 'CANCEL_DRAFT'
                  )
             THEN 0 ELSE 1 END,
        jsonb_build_object('constraint_rows',count(*))
    FROM pg_constraint c
    WHERE c.conrelid = 'public.sale_master_audit'::regclass
      AND c.conname = 'sale_master_audit_action_check'

    UNION ALL

    SELECT
        'browser_draft_write_boundary',
        CASE WHEN NOT (
            has_table_privilege(
                'authenticated','public.sales_headers','INSERT,UPDATE,DELETE'
            )
            OR has_table_privilege(
                'authenticated','public.sale_master_audit','INSERT,UPDATE,DELETE'
            )
        ) THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN NOT (
            has_table_privilege(
                'authenticated','public.sales_headers','INSERT,UPDATE,DELETE'
            )
            OR has_table_privilege(
                'authenticated','public.sale_master_audit','INSERT,UPDATE,DELETE'
            )
        ) THEN 0 ELSE 1 END,
        jsonb_build_object(
            'sales_headers_write',has_table_privilege(
                'authenticated','public.sales_headers','INSERT,UPDATE,DELETE'
            ),
            'sale_audit_write',has_table_privilege(
                'authenticated','public.sale_master_audit','INSERT,UPDATE,DELETE'
            )
        )
)
SELECT check_name,status,violation_rows,details
FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 ELSE 2 END,check_name;
