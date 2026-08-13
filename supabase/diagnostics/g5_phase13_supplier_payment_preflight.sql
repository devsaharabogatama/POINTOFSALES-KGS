-- G5 Phase 13 Preflight: Supplier Payment / AP Settlement readiness.
-- SAFETY: SELECT-only; aggregate metadata only. Strictly read-only; no DDL or DML mutations.

WITH required_versions(version) AS (
    VALUES ('20260806100000')
), expected_tables(table_name) AS (
    VALUES ('supplier_payment_documents'),('supplier_payment_allocations'),
           ('supplier_payment_audit')
), validated_invoices AS (
    SELECT doc.*,
           doc.grand_total AS ap_final_value
    FROM public.supplier_invoice_documents doc
    WHERE doc.status = 'VALIDATED'
), checks AS (
    SELECT 'g5_supplier_payment_dependencies'::TEXT AS check_name,
           CASE WHEN count(*) FILTER(WHERE migration.version IS NULL) = 0
                THEN 'PASS' ELSE 'BLOCKER' END AS status,
           jsonb_build_object(
               'expected', count(*),
               'missing', COALESCE(jsonb_agg(required.version ORDER BY required.version)
                   FILTER(WHERE migration.version IS NULL), '[]'::JSONB)
           ) AS details
    FROM required_versions required
    LEFT JOIN private.kgs_schema_migrations migration
      ON migration.version = required.version
    UNION ALL
    SELECT 'canonical_supplier_payment_schema_state', 'INFO',
           jsonb_build_object('missing_tables', COALESCE(jsonb_agg(expected.table_name ORDER BY expected.table_name)
               FILTER(WHERE relation.oid IS NULL), '[]'::JSONB))
    FROM expected_tables expected
    LEFT JOIN pg_catalog.pg_namespace namespace ON namespace.nspname = 'public'
    LEFT JOIN pg_catalog.pg_class relation
      ON relation.relnamespace = namespace.oid
     AND relation.relname = expected.table_name
     AND relation.relkind IN ('r','p')
    UNION ALL
    SELECT 'legacy_purchase_payment_inventory', 'INFO', jsonb_build_object(
        'headers', (SELECT count(*) FROM public.purchases_headers),
        'paid_headers', (SELECT count(*) FROM public.purchases_headers WHERE paid_amount > 0),
        'fully_paid_headers', (SELECT count(*) FROM public.purchases_headers WHERE paid_amount >= grand_total AND grand_total > 0),
        'total_paid_amount', (SELECT COALESCE(sum(paid_amount), 0) FROM public.purchases_headers)
    )
    UNION ALL
    SELECT 'validated_supplier_invoices_scope',
           CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'SETTLEMENT_CANDIDATE' END,
           jsonb_build_object(
               'validated_invoices', count(*),
               'total_ap_final_value', COALESCE(sum(ap_final_value), 0),
               'suppliers', count(DISTINCT supplier_id),
               'companies', count(DISTINCT company_id)
           )
    FROM validated_invoices
    UNION ALL
    SELECT 'supplier_invoice_validation_event_integrity',
           CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
           jsonb_build_object('orphan_validated_invoices', count(*))
    FROM validated_invoices doc
    LEFT JOIN public.financial_events event
      ON event.company_id = doc.company_id
     AND event.source_table = 'supplier_invoice_documents'
     AND event.source_id = doc.id
     AND event.event_type = 'SUPPLIER_INVOICE_VALIDATED'
    WHERE doc.validated_by IS NULL OR doc.validated_at IS NULL
       OR doc.validation_idempotency_key IS NULL OR doc.financial_event_id IS NULL
       OR event.id IS NULL
    UNION ALL
    SELECT 'invalid_validated_supplier_invoice_reference',
           CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
           jsonb_build_object('invalid_rows', count(*))
    FROM validated_invoices doc
    LEFT JOIN public.suppliers supplier
      ON supplier.company_id = doc.company_id
     AND supplier.id = doc.supplier_id
    WHERE supplier.id IS NULL OR doc.grand_total < 0 OR doc.line_count <= 0
    UNION ALL
    SELECT 'supplier_payment_transaction_category_readiness',
           CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'REVIEW' END,
           jsonb_build_object('missing_company_count', count(*))
    FROM (
        SELECT DISTINCT doc.company_id
        FROM validated_invoices doc
        WHERE NOT EXISTS (
            SELECT 1 FROM public.transaction_categories category
            WHERE category.company_id = doc.company_id
              AND category.system_key = 'SUPPLIER_PAYMENT'
              AND category.is_active
        )
    ) missing
    UNION ALL
    SELECT 'supplier_payment_account_function_catalog',
           CASE WHEN count(account_function.function_key) >= 3
                THEN 'PASS' ELSE 'BLOCKER' END,
           jsonb_build_object(
               'expected', 3, 'rows', count(account_function.function_key),
               'missing', COALESCE(jsonb_agg(required.function_key ORDER BY required.function_key)
                   FILTER(WHERE account_function.function_key IS NULL), '[]'::JSONB)
           )
    FROM (VALUES ('SUPPLIER_AP_FINAL'), ('MAIN_CASH'), ('BANK')) required(function_key)
    LEFT JOIN public.account_functions account_function
      ON account_function.function_key = required.function_key
)
SELECT check_name, status, details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'REVIEW' THEN 2
                     WHEN 'SETTLEMENT_CANDIDATE' THEN 3 WHEN 'PASS' THEN 4 ELSE 5 END,
         check_name;
