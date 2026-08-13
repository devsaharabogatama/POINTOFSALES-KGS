-- SLD phase 2 postflight: canonical Sales Invoice and Surat Jalan verification.
-- SAFETY: SELECT-only; aggregate metadata and counts only.

WITH expected_relations(relation_name) AS (
    VALUES
        ('sales_invoice_snapshots'),('sales_delivery_documents'),
        ('sales_delivery_lines'),('sales_document_audit')
), expected_columns(column_name) AS (
    VALUES
        ('fulfillment_mode'),('delivery_recipient_name'),
        ('delivery_recipient_phone'),('delivery_address'),
        ('delivery_scheduled_at'),('delivery_notes')
), expected_routines(signature) AS (
    VALUES
        ('public.configure_pos_sale_fulfillment(uuid,bigint,text,text,text,text,timestamp with time zone,text)'),
        ('public.get_sales_invoice_document(uuid)'),
        ('public.get_sales_delivery_document(uuid)'),
        ('public.update_sales_delivery_status(uuid,bigint,text,text)'),
        ('public.record_sales_document_print(text,uuid)'),
        ('public.company_branding_logo_is_referenced(text)'),
        ('private.ensure_sales_documents(uuid,uuid,text)')
), posted_sales AS (
    SELECT sale.* FROM public.sales_headers sale
    WHERE sale.document_status='POSTED'
), event_counts AS (
    SELECT sale.company_id,sale.id,count(event.id) AS event_count
    FROM posted_sales sale
    LEFT JOIN public.financial_events event
      ON event.company_id=sale.company_id
     AND event.source_table='sales_headers'
     AND event.source_id=sale.id
     AND event.event_type='SALE_POSTED'::public.event_type
    GROUP BY sale.company_id,sale.id
), checks AS (
    SELECT
        'migration_ledger'::TEXT AS check_name,
        CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END AS status,
        count(*) FILTER (WHERE version<>'20260811130000') AS violation_rows,
        jsonb_build_object('ledger_rows',count(*)) AS details
    FROM private.kgs_schema_migrations
    WHERE version='20260811130000'

    UNION ALL

    SELECT
        'required_sales_document_relations',
        CASE WHEN count(*) FILTER (
            WHERE to_regclass('public.'||relation_name) IS NULL
        )=0 THEN 'PASS' ELSE 'FAIL' END,
        count(*) FILTER (WHERE to_regclass('public.'||relation_name) IS NULL),
        jsonb_build_object(
            'missing',COALESCE(jsonb_agg(relation_name ORDER BY relation_name)
                FILTER (WHERE to_regclass('public.'||relation_name) IS NULL),
                '[]'::JSONB),'expected',count(*)
        )
    FROM expected_relations

    UNION ALL

    SELECT
        'required_fulfillment_columns',
        CASE WHEN count(*) FILTER (WHERE actual.column_name IS NULL)=0
             THEN 'PASS' ELSE 'FAIL' END,
        count(*) FILTER (WHERE actual.column_name IS NULL),
        jsonb_build_object(
            'missing',COALESCE(jsonb_agg(expected.column_name
                ORDER BY expected.column_name)
                FILTER (WHERE actual.column_name IS NULL),'[]'::JSONB),
            'expected',count(*)
        )
    FROM expected_columns expected
    LEFT JOIN information_schema.columns actual
      ON actual.table_schema='public' AND actual.table_name='sales_headers'
     AND actual.column_name=expected.column_name

    UNION ALL

    SELECT
        'required_sales_document_routines',
        CASE WHEN count(*) FILTER (WHERE to_regprocedure(signature) IS NULL)=0
             THEN 'PASS' ELSE 'FAIL' END,
        count(*) FILTER (WHERE to_regprocedure(signature) IS NULL),
        jsonb_build_object(
            'missing',COALESCE(jsonb_agg(signature ORDER BY signature)
                FILTER (WHERE to_regprocedure(signature) IS NULL),'[]'::JSONB),
            'expected',count(*)
        )
    FROM expected_routines

    UNION ALL

    SELECT
        'required_sales_document_triggers',
        CASE WHEN count(*)=7 THEN 'PASS' ELSE 'FAIL' END,
        abs(7-count(*)),jsonb_build_object('trigger_rows',count(*))
    FROM pg_catalog.pg_trigger trigger_state
    WHERE NOT trigger_state.tgisinternal
      AND trigger_state.tgenabled<>'D'
      AND trigger_state.tgname IN (
          'sld_capture_fulfillment_payload','sld_finalize_posted_sale',
          'sld_invoice_history_immutable','sld_delivery_line_history_immutable',
          'sld_document_audit_immutable','sld_delivery_update_guard',
          'sld_document_audit_reference'
      )

    UNION ALL

    SELECT
        'posted_sale_invoice_snapshot_coverage',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),jsonb_build_object('sale_count',count(*))
    FROM posted_sales sale
    LEFT JOIN public.sales_invoice_snapshots invoice
      ON invoice.company_id=sale.company_id AND invoice.sales_id=sale.id
    WHERE invoice.id IS NULL

    UNION ALL

    SELECT
        'invoice_snapshot_source_identity',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),jsonb_build_object('row_count',count(*))
    FROM public.sales_invoice_snapshots invoice
    LEFT JOIN public.sales_headers sale
      ON sale.company_id=invoice.company_id AND sale.id=invoice.sales_id
    WHERE sale.id IS NULL OR sale.document_status<>'POSTED'
       OR invoice.invoice_no IS DISTINCT FROM sale.invoice_no
       OR NOT (
           invoice.snapshot_payload ? 'company'
           AND invoice.snapshot_payload ? 'branding'
           AND invoice.snapshot_payload ? 'store'
           AND invoice.snapshot_payload ? 'warehouse'
           AND invoice.snapshot_payload ? 'customer'
           AND invoice.snapshot_payload ? 'lines'
           AND invoice.snapshot_payload ? 'payments'
           AND invoice.snapshot_payload ? 'totals'
       )

    UNION ALL

    SELECT
        'legacy_invoice_backfill_provenance',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),jsonb_build_object('row_count',count(*))
    FROM public.sales_invoice_snapshots invoice
    WHERE invoice.created_at<=COALESCE((
        SELECT migration.applied_at
        FROM private.kgs_schema_migrations migration
        WHERE migration.version='20260811130000'
    ),'-infinity'::TIMESTAMPTZ)
      AND invoice.snapshot_provenance<>'LEGACY_CUTOVER'

    UNION ALL

    SELECT
        'pickup_sale_without_delivery_document',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),jsonb_build_object('sale_count',count(*))
    FROM posted_sales sale
    JOIN public.sales_delivery_documents delivery
      ON delivery.company_id=sale.company_id AND delivery.sales_id=sale.id
    WHERE sale.fulfillment_mode='PICKUP'

    UNION ALL

    SELECT
        'delivery_sale_document_coverage',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),jsonb_build_object('sale_count',count(*))
    FROM posted_sales sale
    LEFT JOIN public.sales_delivery_documents delivery
      ON delivery.company_id=sale.company_id AND delivery.sales_id=sale.id
    WHERE sale.fulfillment_mode='DELIVERY'
      AND (delivery.id IS NULL OR sale.sj_no IS DISTINCT FROM delivery.delivery_no)

    UNION ALL

    SELECT
        'delivery_line_source_coverage',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),jsonb_build_object('document_count',count(*))
    FROM public.sales_delivery_documents delivery
    WHERE (
        SELECT count(*) FROM public.sales_delivery_lines line
        WHERE line.company_id=delivery.company_id
          AND line.delivery_document_id=delivery.id
    )<>(
        SELECT count(*) FROM public.sales_details line
        WHERE line.company_id=delivery.company_id
          AND line.sales_id=delivery.sales_id
    )

    UNION ALL

    SELECT
        'posted_sale_single_financial_event_preserved',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),jsonb_build_object('sale_count',count(*))
    FROM event_counts WHERE event_count<>1

    UNION ALL

    SELECT
        'referenced_branding_snapshot_coverage',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),jsonb_build_object('row_count',count(*))
    FROM public.sales_invoice_snapshots invoice
    WHERE invoice.branding_logo_object_path IS NOT NULL
      AND (
          invoice.branding_logo_version IS NULL
          OR invoice.branding_logo_checksum_sha256 IS NULL
      )

    UNION ALL

    SELECT
        'sales_document_rls',
        CASE WHEN count(*) FILTER (WHERE NOT class.relrowsecurity)=0
             THEN 'PASS' ELSE 'FAIL' END,
        count(*) FILTER (WHERE NOT class.relrowsecurity),
        jsonb_build_object('relation_rows',count(*))
    FROM expected_relations expected
    JOIN pg_catalog.pg_class class
      ON class.oid=to_regclass('public.'||expected.relation_name)

    UNION ALL

    SELECT
        'browser_sales_document_write_boundary',
        CASE WHEN bool_or(has_table_privilege(
            'authenticated','public.'||relation_name,'INSERT,UPDATE,DELETE'
        )) THEN 'FAIL' ELSE 'PASS' END,
        count(*) FILTER (WHERE has_table_privilege(
            'authenticated','public.'||relation_name,'INSERT,UPDATE,DELETE'
        )),jsonb_build_object('relation_rows',count(*))
    FROM expected_relations

    UNION ALL

    SELECT
        'sales_document_runtime_inventory','INFO',0,
        jsonb_build_object(
            'posted_sales',(SELECT count(*) FROM posted_sales),
            'invoice_snapshots',(SELECT count(*) FROM public.sales_invoice_snapshots),
            'legacy_cutover_snapshots',(
                SELECT count(*) FROM public.sales_invoice_snapshots
                WHERE snapshot_provenance='LEGACY_CUTOVER'
            ),
            'delivery_documents',(SELECT count(*) FROM public.sales_delivery_documents),
            'delivery_lines',(SELECT count(*) FROM public.sales_delivery_lines),
            'document_audit_rows',(SELECT count(*) FROM public.sales_document_audit),
            'referenced_logo_snapshots',(
                SELECT count(*) FROM public.sales_invoice_snapshots
                WHERE branding_logo_object_path IS NOT NULL
            )
        )
)
SELECT check_name,status,violation_rows,details
FROM checks
ORDER BY
    CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,
    check_name;
