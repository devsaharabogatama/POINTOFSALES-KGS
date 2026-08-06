-- G5 phase 10 preflight: Supplier Invoice / three-way matching readiness.
-- SAFETY: SELECT-only; aggregate metadata only.
WITH required_versions(version) AS (
    VALUES ('20260806070000'),('20260806080000')
), expected_tables(table_name) AS (
    VALUES ('supplier_invoice_documents'),('supplier_invoice_lines'),
           ('supplier_invoice_allocations'),('supplier_invoice_tolerance_results'),
           ('supplier_invoice_audit')
), open_provisionals AS (
    SELECT provisional.*,
           provisional.amount-COALESCE((
               SELECT sum(adjustment.amount)
               FROM public.purchase_return_ap_adjustments adjustment
               JOIN public.purchase_return_documents return_document
                 ON return_document.company_id=adjustment.company_id
                AND return_document.id=adjustment.document_id
                AND return_document.status='POSTED'
               WHERE adjustment.company_id=provisional.company_id
                 AND adjustment.source_ap_provisional_id=provisional.id
                 AND adjustment.adjustment_route='AP_PROVISIONAL'
           ),0) AS net_uninvoiced_value
    FROM public.goods_receipt_ap_provisionals provisional
    WHERE provisional.status='OPEN'
), checks AS (
    SELECT 'g5_supplier_invoice_dependencies'::TEXT AS check_name,
           CASE WHEN count(*) FILTER(WHERE migration.version IS NULL)=0
                THEN 'PASS' ELSE 'BLOCKER' END AS status,
           jsonb_build_object(
               'expected',count(*),
               'missing',COALESCE(jsonb_agg(required.version ORDER BY required.version)
                   FILTER(WHERE migration.version IS NULL),'[]'::JSONB)
           ) AS details
    FROM required_versions required
    LEFT JOIN private.kgs_schema_migrations migration
      ON migration.version=required.version
    UNION ALL
    SELECT 'canonical_supplier_invoice_schema_state','INFO',
           jsonb_build_object('missing_tables',COALESCE(jsonb_agg(expected.table_name ORDER BY expected.table_name)
               FILTER(WHERE relation.oid IS NULL),'[]'::JSONB))
    FROM expected_tables expected
    LEFT JOIN pg_catalog.pg_namespace namespace ON namespace.nspname='public'
    LEFT JOIN pg_catalog.pg_class relation
      ON relation.relnamespace=namespace.oid
     AND relation.relname=expected.table_name
     AND relation.relkind IN('r','p')
    UNION ALL
    SELECT 'legacy_purchase_inventory','INFO',jsonb_build_object(
        'headers',(SELECT count(*) FROM public.purchases_headers),
        'details',(SELECT count(*) FROM public.purchases_details),
        -- Legacy purchases_headers has payment_status, not an operational
        -- document status. Supplier Invoice readiness must not infer a
        -- CONFIRMED lifecycle that does not exist on this table.
        'headers_with_financial_value',(SELECT count(*)
            FROM public.purchases_headers
            WHERE grand_total<>0 OR paid_amount<>0),
        'paid_headers',(SELECT count(*) FROM public.purchases_headers WHERE paid_amount>0)
    )
    UNION ALL
    SELECT 'legacy_purchase_financial_backfill_scope',
           CASE WHEN count(*)=0 THEN 'PASS' ELSE 'REVIEW' END,
           jsonb_build_object('header_rows',count(*))
    FROM public.purchases_headers
    WHERE paid_amount<>0 OR grand_total<>0
    UNION ALL
    SELECT 'invalid_goods_receipt_ap_reference',
           CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
           jsonb_build_object('row_count',count(*))
    FROM public.goods_receipt_ap_provisionals provisional
    LEFT JOIN public.goods_receipt_documents receipt
      ON receipt.company_id=provisional.company_id
     AND receipt.id=provisional.receipt_id
    LEFT JOIN public.goods_receipt_lines line
      ON line.company_id=provisional.company_id
     AND line.id=provisional.receipt_line_id
     AND line.document_id=provisional.receipt_id
    LEFT JOIN public.suppliers supplier
      ON supplier.company_id=provisional.company_id
     AND supplier.id=provisional.supplier_id
    WHERE receipt.id IS NULL OR receipt.status<>'POSTED'
       OR line.id IS NULL OR supplier.id IS NULL OR provisional.amount<0
    UNION ALL
    SELECT 'purchase_return_ap_adjustment_exceeds_source',
           CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
           jsonb_build_object('provisional_count',count(*))
    FROM (
        SELECT provisional.id
        FROM public.goods_receipt_ap_provisionals provisional
        LEFT JOIN public.purchase_return_ap_adjustments adjustment
          ON adjustment.company_id=provisional.company_id
         AND adjustment.source_ap_provisional_id=provisional.id
        LEFT JOIN public.purchase_return_documents return_document
          ON return_document.company_id=adjustment.company_id
         AND return_document.id=adjustment.document_id
         AND return_document.status='POSTED'
        GROUP BY provisional.id,provisional.amount
        HAVING COALESCE(sum(adjustment.amount)
            FILTER(WHERE return_document.id IS NOT NULL),0)>provisional.amount
    ) invalid
    UNION ALL
    SELECT 'negative_net_uninvoiced_provisional',
           CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
           jsonb_build_object('row_count',count(*))
    FROM open_provisionals WHERE net_uninvoiced_value<0
    UNION ALL
    SELECT 'supplier_invoice_matching_scope',
           CASE WHEN count(*) FILTER(WHERE net_uninvoiced_value>0)=0
                THEN 'PASS' ELSE 'BACKFILL' END,
           jsonb_build_object(
               'open_provisionals',count(*),
               'allocatable_rows',count(*) FILTER(WHERE net_uninvoiced_value>0),
               'net_uninvoiced_value',COALESCE(sum(GREATEST(net_uninvoiced_value,0)),0),
               'companies',count(DISTINCT company_id) FILTER(WHERE net_uninvoiced_value>0)
           )
    FROM open_provisionals
    UNION ALL
    SELECT 'supplier_invoice_transaction_category_readiness',
           CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
           jsonb_build_object('company_count',count(*))
    FROM (
        SELECT DISTINCT provisional.company_id
        FROM open_provisionals provisional
        WHERE provisional.net_uninvoiced_value>0
          AND NOT EXISTS (
              SELECT 1 FROM public.transaction_categories category
              WHERE category.company_id=provisional.company_id
                AND category.system_key='SUPPLIER_INVOICE'
                AND category.is_active
          )
    ) missing
    UNION ALL
    SELECT 'supplier_invoice_account_function_catalog',
           CASE WHEN count(account_function.function_key)=4
                THEN 'PASS' ELSE 'BLOCKER' END,
           jsonb_build_object(
               'expected',4,'rows',count(account_function.function_key),
               'missing',COALESCE(jsonb_agg(required.function_key ORDER BY required.function_key)
                   FILTER(WHERE account_function.function_key IS NULL),'[]'::JSONB)
           )
    FROM (VALUES ('SUPPLIER_AP_PROVISIONAL'),('SUPPLIER_AP_FINAL'),
                 ('PURCHASE_PRICE_VARIANCE'),('INPUT_TAX')) required(function_key)
    LEFT JOIN public.account_functions account_function
      ON account_function.function_key=required.function_key
    UNION ALL
    SELECT 'active_purchase_tax_rule_inventory','INFO',jsonb_build_object(
        'rules',count(DISTINCT rule.id),
        'current_versions',count(version.id),
        'recoverable_versions',count(version.id) FILTER(WHERE version.is_recoverable)
    )
    FROM public.tax_rules rule
    LEFT JOIN public.tax_rule_versions version
      ON version.company_id=rule.company_id
     AND version.tax_rule_id=rule.id
     AND version.status='ACTIVE'
     AND version.effective_from<=clock_timestamp()
     AND (version.effective_to IS NULL OR version.effective_to>clock_timestamp())
    WHERE rule.tax_scope='PURCHASE' AND rule.is_active
    UNION ALL
    SELECT 'direct_supplier_invoice_write_boundary','INFO',jsonb_build_object(
        'legacy_header_insert',has_table_privilege('authenticated','public.purchases_headers','INSERT'),
        'legacy_header_update',has_table_privilege('authenticated','public.purchases_headers','UPDATE'),
        'legacy_detail_insert',has_table_privilege('authenticated','public.purchases_details','INSERT')
    )
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'REVIEW' THEN 2
                     WHEN 'BACKFILL' THEN 3 WHEN 'PASS' THEN 4 ELSE 5 END,
         check_name;
