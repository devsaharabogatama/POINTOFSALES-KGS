-- SLD phase 1 preflight: canonical Sales Invoice and Surat Jalan readiness.
--
-- SAFETY:
-- - SELECT-only; no DDL, DML, TEMP table, function side effect, or grants.
-- - Returns aggregate counts and schema metadata only.
-- - Does not expose Customer, Company, Product, address, phone, or document rows.

WITH required_versions(version) AS (
    VALUES ('20260811110000')
), expected_document_tables(table_name) AS (
    VALUES
        ('sales_invoice_snapshots'),
        ('sales_delivery_documents'),
        ('sales_delivery_lines'),
        ('sales_document_audit')
), expected_delivery_columns(column_name) AS (
    VALUES
        ('fulfillment_mode'),
        ('delivery_recipient_name'),
        ('delivery_recipient_phone'),
        ('delivery_address'),
        ('delivery_scheduled_at'),
        ('delivery_notes')
), expected_invoice_snapshot_fields(field_name) AS (
    VALUES
        ('snapshotVersion'), ('snapshotProvenance'), ('invoiceNo'),
        ('company'), ('store'), ('warehouse'), ('cashier'), ('terminal'),
        ('customer'), ('postedAt'), ('sourceChannel'), ('isTempo'),
        ('dueDate'), ('lines'), ('payments'), ('totals'), ('branding')
), posted_sales AS (
    SELECT sh.*
    FROM public.sales_headers sh
    WHERE sh.document_status = 'POSTED'
), posted_sale_event_counts AS (
    SELECT
        ps.company_id,
        ps.id AS sales_id,
        count(fe.id) AS event_count
    FROM posted_sales ps
    LEFT JOIN public.financial_events fe
      ON fe.company_id = ps.company_id
     AND fe.source_table = 'sales_headers'
     AND fe.source_id = ps.id
     AND fe.event_type = 'SALE_POSTED'::public.event_type
    GROUP BY ps.company_id, ps.id
), checks AS (
    SELECT
        'sld_foundation_dependency'::TEXT AS check_name,
        CASE WHEN count(*) FILTER (WHERE m.version IS NULL) = 0
             THEN 'PASS' ELSE 'BLOCKER' END AS status,
        jsonb_build_object(
            'expected',count(*),
            'missing',COALESCE(
                jsonb_agg(r.version ORDER BY r.version)
                    FILTER (WHERE m.version IS NULL),
                '[]'::JSONB
            )
        ) AS details
    FROM required_versions r
    LEFT JOIN private.kgs_schema_migrations m ON m.version = r.version

    UNION ALL

    SELECT
        'canonical_sales_document_schema_state',
        CASE WHEN count(*) FILTER (WHERE c.table_name IS NULL) = 0
                  AND (
                      SELECT count(*)
                      FROM expected_delivery_columns expected_column
                      LEFT JOIN information_schema.columns actual_column
                        ON actual_column.table_schema = 'public'
                       AND actual_column.table_name = 'sales_headers'
                       AND actual_column.column_name = expected_column.column_name
                      WHERE actual_column.column_name IS NULL
                  ) = 0
             THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object(
            'missing_tables',COALESCE(
                jsonb_agg(t.table_name ORDER BY t.table_name)
                    FILTER (WHERE c.table_name IS NULL),
                '[]'::JSONB
            ),
            'missing_sales_header_columns',(
                SELECT COALESCE(
                    jsonb_agg(expected_column.column_name
                        ORDER BY expected_column.column_name)
                        FILTER (WHERE actual_column.column_name IS NULL),
                    '[]'::JSONB
                )
                FROM expected_delivery_columns expected_column
                LEFT JOIN information_schema.columns actual_column
                  ON actual_column.table_schema = 'public'
                 AND actual_column.table_name = 'sales_headers'
                 AND actual_column.column_name = expected_column.column_name
            )
        )
    FROM expected_document_tables t
    LEFT JOIN information_schema.tables c
      ON c.table_schema = 'public'
     AND c.table_name = t.table_name

    UNION ALL

    SELECT
        'posted_sale_core_document_contract',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM posted_sales ps
    WHERE ps.invoice_no IS NULL
       OR btrim(ps.invoice_no) = ''
       OR ps.posting_idempotency_key IS NULL
       OR ps.sales_warehouse_id IS NULL
       OR ps.posted_session_id IS NULL
       OR ps.posted_at IS NULL
       OR ps.posted_by IS NULL
       OR ps.receipt_snapshot IS NULL
       OR ps.invoice_status <> 'GENERATED'::public.invoice_status

    UNION ALL

    SELECT
        'duplicate_company_invoice_number',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('duplicate_groups',count(*))
    FROM (
        SELECT company_id,upper(btrim(invoice_no))
        FROM posted_sales
        GROUP BY company_id,upper(btrim(invoice_no))
        HAVING count(*) > 1
    ) duplicate_groups

    UNION ALL

    SELECT
        'posted_sale_tenant_reference_integrity',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('orphan_or_cross_tenant_rows',count(*))
    FROM posted_sales ps
    LEFT JOIN public.companies company
      ON company.id = ps.company_id
    LEFT JOIN public.stores store
      ON store.company_id = ps.company_id AND store.id = ps.store_id
    LEFT JOIN public.warehouses warehouse
      ON warehouse.company_id = ps.company_id
     AND warehouse.id = ps.sales_warehouse_id
    LEFT JOIN public.customers customer
      ON customer.company_id = ps.company_id AND customer.id = ps.customer_id
    WHERE company.id IS NULL
       OR store.id IS NULL
       OR warehouse.id IS NULL
       OR (ps.customer_id IS NOT NULL AND customer.id IS NULL)

    UNION ALL

    SELECT
        'posted_receipt_core_snapshot_contract',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM posted_sales ps
    WHERE NOT (
        ps.receipt_snapshot ? 'invoiceNo'
        AND ps.receipt_snapshot ? 'postedAt'
        AND ps.receipt_snapshot ? 'grandTotal'
        AND ps.receipt_snapshot ? 'lines'
        AND ps.receipt_snapshot ? 'payments'
        AND jsonb_typeof(ps.receipt_snapshot->'lines') = 'array'
        AND jsonb_typeof(ps.receipt_snapshot->'payments') = 'array'
    )

    UNION ALL

    SELECT
        'posted_sale_line_snapshot_contract',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.sales_details sd
    JOIN posted_sales ps
      ON ps.company_id = sd.company_id AND ps.id = sd.sales_id
    WHERE sd.client_line_key IS NULL
       OR btrim(sd.client_line_key) = ''
       OR sd.product_uom_id IS NULL
       OR sd.sale_uom_id IS NULL
       OR COALESCE(btrim(sd.sale_uom_name_snapshot),'') = ''
       OR COALESCE(btrim(sd.product_sku_snapshot),'') = ''
       OR COALESCE(btrim(sd.product_name_snapshot),'') = ''
       OR sd.qty <= 0
       OR sd.quantity_base <= 0
       OR sd.uom_factor_to_base_snapshot <= 0
       OR sd.resolved_unit_price IS NULL
       OR sd.line_total IS NULL
       OR sd.tax_amount IS NULL

    UNION ALL

    SELECT
        'posted_sale_payment_snapshot_contract',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.sales_payments payment
    JOIN posted_sales ps
      ON ps.company_id = payment.company_id AND ps.id = payment.sales_id
    WHERE payment.amount <= 0
       OR payment.payment_method_id IS NULL
       OR COALESCE(btrim(payment.payment_method_name_snapshot),'') = ''
       OR COALESCE(btrim(payment.payment_method_type_snapshot),'') = ''

    UNION ALL

    SELECT
        'posted_sale_single_financial_event',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('sale_count',count(*))
    FROM posted_sale_event_counts
    WHERE event_count <> 1

    UNION ALL

    SELECT
        'sales_return_invoice_reference_contract',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.sales_return_documents return_document
    LEFT JOIN public.sales_headers source_sale
      ON source_sale.company_id = return_document.company_id
     AND source_sale.id = return_document.source_sales_id
    WHERE source_sale.id IS NULL
       OR source_sale.document_status <> 'POSTED'
       OR return_document.source_invoice_no_snapshot
            IS DISTINCT FROM source_sale.invoice_no

    UNION ALL

    SELECT
        'posted_bundle_commercial_line_coverage',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('line_count',count(*))
    FROM public.sales_details sd
    JOIN posted_sales ps
      ON ps.company_id = sd.company_id AND ps.id = sd.sales_id
    JOIN public.products product
      ON product.company_id = sd.company_id AND product.id = sd.product_id
    WHERE product.is_bundle
      AND NOT EXISTS (
          SELECT 1
          FROM public.bundle_sale_allocations allocation
          WHERE allocation.company_id = sd.company_id
            AND allocation.sales_detail_id = sd.id
      )

    UNION ALL

    SELECT
        'offline_posted_receipt_snapshot_coverage',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM posted_sales ps
    WHERE ps.source_channel = 'OFFLINE'
      AND (
          ps.offline_submission_id IS NULL
          OR ps.offline_transaction_at IS NULL
          OR ps.receipt_snapshot IS NULL
          OR jsonb_typeof(ps.receipt_snapshot->'lines')
                IS DISTINCT FROM 'array'
      )

    UNION ALL

    SELECT
        'formal_invoice_snapshot_backfill_scope',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BACKFILL' END,
        jsonb_build_object(
            'posted_sales',count(*),
            'online_sales',count(*) FILTER (WHERE source_channel = 'ONLINE'),
            'offline_sales',count(*) FILTER (WHERE source_channel = 'OFFLINE')
        )
    FROM posted_sales
    WHERE receipt_snapshot IS NOT NULL
      AND EXISTS (
          SELECT 1
          FROM expected_invoice_snapshot_fields field
          WHERE NOT (receipt_snapshot ? field.field_name)
      )

    UNION ALL

    SELECT
        'active_customer_delivery_identity_readiness',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object('customer_count',count(*))
    FROM public.customers customer
    WHERE customer.is_active
      AND NOT customer.is_system_customer
      AND (
          COALESCE(btrim(customer.phone),'') = ''
          OR COALESCE(btrim(customer.address),'') = ''
      )

    UNION ALL

    SELECT
        'active_store_print_identity_readiness',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object('store_count',count(*))
    FROM public.stores store
    JOIN public.companies company ON company.id = store.company_id
    WHERE company.status = 'ACTIVE'
      AND store.status = 'ACTIVE'
      AND (
          COALESCE(btrim(store.store_name),'') = ''
          OR COALESCE(btrim(store.address),'') = ''
      )

    UNION ALL

    SELECT
        'active_company_print_identity_readiness',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('company_count',count(*))
    FROM public.companies company
    WHERE company.status = 'ACTIVE'
      AND COALESCE(btrim(company.company_name),'') = ''

    UNION ALL

    SELECT
        'company_branding_document_retention_contract',
        'SETUP',
        jsonb_build_object(
            'active_companies',count(*) FILTER (
                WHERE company.status = 'ACTIVE'
            ),
            'companies_with_logo',count(*) FILTER (
                WHERE company.status = 'ACTIVE'
                  AND branding.logo_object_path IS NOT NULL
            ),
            'requirement','referenced logo objects must survive branding replacement'
        )
    FROM public.companies company
    LEFT JOIN public.company_branding_profiles branding
      ON branding.company_id = company.id

    UNION ALL

    SELECT
        'browser_direct_sales_document_write_boundary',
        'INFO',
        jsonb_build_object(
            'sales_headers_write',has_table_privilege(
                'authenticated','public.sales_headers','INSERT,UPDATE,DELETE'
            ),
            'sales_details_write',has_table_privilege(
                'authenticated','public.sales_details','INSERT,UPDATE,DELETE'
            ),
            'sales_payments_write',has_table_privilege(
                'authenticated','public.sales_payments','INSERT,UPDATE,DELETE'
            )
        )

    UNION ALL

    SELECT
        'sales_document_runtime_inventory',
        'INFO',
        jsonb_build_object(
            'posted_sales',(SELECT count(*) FROM posted_sales),
            'online_posted_sales',(
                SELECT count(*) FROM posted_sales WHERE source_channel='ONLINE'
            ),
            'offline_posted_sales',(
                SELECT count(*) FROM posted_sales WHERE source_channel='OFFLINE'
            ),
            'posted_sale_lines',(
                SELECT count(*) FROM public.sales_details sd
                JOIN posted_sales ps
                  ON ps.company_id=sd.company_id AND ps.id=sd.sales_id
            ),
            'payment_legs',(
                SELECT count(*) FROM public.sales_payments payment
                JOIN posted_sales ps
                  ON ps.company_id=payment.company_id
                 AND ps.id=payment.sales_id
            ),
            'sales_returns',(SELECT count(*) FROM public.sales_return_documents),
            'bundle_sale_allocations',(
                SELECT count(*) FROM public.bundle_sale_allocations
            )
        )
)
SELECT check_name,status,details
FROM checks
ORDER BY
    CASE status
        WHEN 'BLOCKER' THEN 1
        WHEN 'REVIEW' THEN 2
        WHEN 'BACKFILL' THEN 3
        WHEN 'SETUP' THEN 4
        WHEN 'PASS' THEN 5
        ELSE 6
    END,
    check_name;
