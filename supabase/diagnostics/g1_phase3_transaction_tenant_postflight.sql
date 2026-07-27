-- G1 phase 3 postflight. SELECT-only. Expected result: 30 PASS rows.

WITH expected_constraints(table_name, constraint_name, expected_type) AS (
    VALUES
        ('pos_terminals','uq_pos_terminals_company_id_id','u'),
        ('pos_terminals','uq_pos_terminals_company_store_id_id','u'),
        ('cashier_sessions','uq_cashier_sessions_company_id_id','u'),
        ('cashier_sessions','uq_cashier_sessions_company_store_pos_id','u'),
        ('customers','uq_customers_company_id_id','u'),
        ('sales_headers','uq_sales_headers_company_id_id','u'),
        ('sales_headers','uq_sales_headers_company_session_id','u'),
        ('sales_payments','uq_sales_payments_company_id_id','u'),
        ('purchases_headers','uq_purchases_headers_company_id_id','u'),
        ('cashier_sessions','fk_cashier_sessions_company_store','f'),
        ('cashier_sessions','fk_cashier_sessions_company_pos','f'),
        ('cashier_sessions','fk_cashier_sessions_company_store_pos','f'),
        ('sales_headers','fk_sales_headers_company_session','f'),
        ('sales_headers','fk_sales_headers_company_store','f'),
        ('sales_headers','fk_sales_headers_company_pos','f'),
        ('sales_headers','fk_sales_headers_company_customer','f'),
        ('sales_headers','fk_sales_headers_company_store_pos_session','f'),
        ('sales_details','fk_sales_details_company_sales','f'),
        ('sales_details','fk_sales_details_company_product','f'),
        ('sales_details','fk_sales_details_company_warehouse','f'),
        ('sales_payments','fk_sales_payments_company_sales','f'),
        ('sales_payments','fk_sales_payments_company_session','f'),
        ('sales_payments','fk_sales_payments_company_session_sales','f'),
        ('sales_payments','fk_sales_payments_company_reversal','f'),
        ('purchases_headers','fk_purchases_headers_company_store','f'),
        ('purchases_headers','fk_purchases_headers_company_warehouse','f'),
        ('purchases_details','fk_purchases_details_company_purchase','f'),
        ('purchases_details','fk_purchases_details_company_product','f')
), constraint_checks AS (
    SELECT
        'constraint:' || e.constraint_name AS check_name,
        CASE
            WHEN c.oid IS NULL OR c.contype::text <> e.expected_type OR NOT c.convalidated
            THEN 'FAIL' ELSE 'PASS'
        END AS status,
        jsonb_build_object(
            'table', e.table_name,
            'exists', c.oid IS NOT NULL,
            'type', c.contype,
            'validated', COALESCE(c.convalidated, FALSE)
        ) AS details
    FROM expected_constraints e
    LEFT JOIN pg_namespace n ON n.nspname = 'public'
    LEFT JOIN pg_class rel ON rel.relnamespace = n.oid AND rel.relname = e.table_name
    LEFT JOIN pg_constraint c ON c.conrelid = rel.oid AND c.conname = e.constraint_name
), other_checks AS (
    SELECT
        'migration_ledger'::text AS check_name,
        CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'FAIL' END AS status,
        jsonb_build_object('row_count', count(*)) AS details
    FROM private.kgs_schema_migrations
    WHERE version = '20260720150000'

    UNION ALL

    SELECT
        'all_phase3_foreign_keys_validated',
        CASE WHEN count(*) FILTER (WHERE status = 'PASS') = 19 THEN 'PASS' ELSE 'FAIL' END,
        jsonb_build_object('expected', 19, 'passed', count(*) FILTER (WHERE status = 'PASS'))
    FROM constraint_checks
    WHERE check_name LIKE 'constraint:fk_%'
)
SELECT check_name, status, details
FROM (
    SELECT * FROM constraint_checks
    UNION ALL
    SELECT * FROM other_checks
) checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 ELSE 2 END, check_name;
