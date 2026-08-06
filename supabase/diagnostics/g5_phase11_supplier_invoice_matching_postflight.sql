-- G5 phase 11 postflight: Supplier Invoice matching foundation.
-- SAFETY: SELECT-only; aggregate metadata and invariant counts only.
WITH expected_tables(table_name) AS (
    VALUES ('supplier_invoice_tolerance_policies'),
           ('supplier_invoice_documents'),('supplier_invoice_lines'),
           ('supplier_invoice_allocations'),
           ('supplier_invoice_tolerance_results'),
           ('supplier_invoice_audit')
), expected_routines(signature) AS (
    VALUES
      ('public.save_supplier_invoice_tolerance_policy(uuid,bigint,uuid,numeric,numeric,numeric,numeric,date,boolean)'),
      ('public.save_supplier_invoice_draft(uuid,bigint,uuid,text,date,date,text,text,text,jsonb)'),
      ('public.validate_supplier_invoice(uuid,bigint,uuid)'),
      ('public.cancel_supplier_invoice(uuid,bigint,text)'),
      ('public.private_supplier_invoice_finance_allowed(uuid)'),
      ('private.refresh_supplier_invoice_totals(uuid,uuid)')
), checks AS (
    SELECT 'migration_ledger'::TEXT AS check_name,
           CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END AS status,
           count(*)::BIGINT AS violation_rows,
           jsonb_build_object('ledger_rows',count(*)) AS details
    FROM private.kgs_schema_migrations
    WHERE version='20260806100000'
    UNION ALL
    SELECT 'required_supplier_invoice_tables',
           CASE WHEN count(*) FILTER(WHERE relation.oid IS NULL)=0
                THEN 'PASS' ELSE 'FAIL' END,
           count(*) FILTER(WHERE relation.oid IS NULL),
           jsonb_build_object(
               'expected',count(*),
               'missing',COALESCE(jsonb_agg(expected.table_name
                   ORDER BY expected.table_name)
                   FILTER(WHERE relation.oid IS NULL),'[]'::JSONB)
           )
    FROM expected_tables expected
    LEFT JOIN pg_catalog.pg_namespace namespace
      ON namespace.nspname='public'
    LEFT JOIN pg_catalog.pg_class relation
      ON relation.relnamespace=namespace.oid
     AND relation.relname=expected.table_name
     AND relation.relkind IN('r','p')
    UNION ALL
    SELECT 'required_supplier_invoice_routines',
           CASE WHEN count(*) FILTER(
                    WHERE to_regprocedure(expected.signature) IS NULL
                )=0 THEN 'PASS' ELSE 'FAIL' END,
           count(*) FILTER(
               WHERE to_regprocedure(expected.signature) IS NULL
           ),
           jsonb_build_object(
               'expected',count(*),
               'missing',COALESCE(jsonb_agg(expected.signature
                   ORDER BY expected.signature) FILTER(
                       WHERE to_regprocedure(expected.signature) IS NULL
                   ),'[]'::JSONB)
           )
    FROM expected_routines expected
    UNION ALL
    SELECT 'supplier_invoice_rls',
           CASE WHEN count(*)=6 AND bool_and(class.relrowsecurity)
                THEN 'PASS' ELSE 'FAIL' END,
           CASE WHEN count(*)=6 AND bool_and(class.relrowsecurity)
                THEN 0 ELSE 1 END,
           jsonb_build_object('table_rows',count(*))
    FROM pg_catalog.pg_class class
    JOIN pg_catalog.pg_namespace namespace ON namespace.oid=class.relnamespace
    WHERE namespace.nspname='public'
      AND class.relname IN(
          'supplier_invoice_tolerance_policies',
          'supplier_invoice_documents','supplier_invoice_lines',
          'supplier_invoice_allocations','supplier_invoice_tolerance_results',
          'supplier_invoice_audit'
      )
    UNION ALL
    SELECT 'browser_supplier_invoice_write_boundary',
           CASE WHEN NOT bool_or(has_table_privilege(
                    'authenticated','public.'||expected.table_name,
                    'INSERT,UPDATE,DELETE'
                )) THEN 'PASS' ELSE 'FAIL' END,
           CASE WHEN NOT bool_or(has_table_privilege(
                    'authenticated','public.'||expected.table_name,
                    'INSERT,UPDATE,DELETE'
                )) THEN 0 ELSE 1 END,
           jsonb_build_object('direct_write',bool_or(has_table_privilege(
               'authenticated','public.'||expected.table_name,
               'INSERT,UPDATE,DELETE'
           )))
    FROM expected_tables expected
    UNION ALL
    SELECT 'supplier_invoice_history_guards',
           CASE WHEN count(*)=5 THEN 'PASS' ELSE 'FAIL' END,
           CASE WHEN count(*)=5 THEN 0 ELSE 1 END,
           jsonb_build_object('trigger_rows',count(*))
    FROM pg_catalog.pg_trigger trigger
    JOIN pg_catalog.pg_class class ON class.oid=trigger.tgrelid
    JOIN pg_catalog.pg_namespace namespace ON namespace.oid=class.relnamespace
    WHERE namespace.nspname='public' AND NOT trigger.tgisinternal
      AND trigger.tgname IN(
          'g5_guard_supplier_invoice_documents',
          'g5_guard_supplier_invoice_lines',
          'g5_guard_supplier_invoice_allocations',
          'g5_guard_supplier_invoice_tolerance_results',
          'g5_guard_partial_invoice_purchase_return'
      )
    UNION ALL
    SELECT 'invalid_supplier_invoice_lifecycle',
           CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
           jsonb_build_object('row_count',count(*))
    FROM public.supplier_invoice_documents document
    WHERE (document.status='VALIDATED' AND (
               document.validation_idempotency_key IS NULL
               OR document.validated_by IS NULL
               OR document.validated_at IS NULL
               OR document.financial_event_id IS NULL
          ))
       OR (document.status IN('DRAFT','HOLD')
           AND document.financial_event_id IS NOT NULL)
       OR (document.status='CANCELED' AND (
               document.canceled_by IS NULL OR document.canceled_at IS NULL
               OR btrim(COALESCE(document.cancel_reason,''))=''
          ))
    UNION ALL
    SELECT 'invalid_supplier_invoice_allocation_reference',
           CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
           jsonb_build_object('row_count',count(*))
    FROM public.supplier_invoice_allocations allocation
    JOIN public.supplier_invoice_documents document
      ON document.company_id=allocation.company_id
     AND document.id=allocation.document_id
    JOIN public.supplier_invoice_lines invoice_line
      ON invoice_line.company_id=allocation.company_id
     AND invoice_line.id=allocation.invoice_line_id
     AND invoice_line.document_id=allocation.document_id
    JOIN public.goods_receipt_ap_provisionals provisional
      ON provisional.company_id=allocation.company_id
     AND provisional.id=allocation.source_ap_provisional_id
    JOIN public.goods_receipt_lines receipt_line
      ON receipt_line.company_id=allocation.company_id
     AND receipt_line.id=allocation.receipt_line_id
    WHERE document.supplier_id<>provisional.supplier_id
       OR invoice_line.product_id<>receipt_line.product_id
       OR allocation.supplier_order_line_id
          <>receipt_line.supplier_order_line_id
    UNION ALL
    SELECT 'validated_allocation_exceeds_receipt_residual',
           CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
           jsonb_build_object('provisional_count',count(*))
    FROM (
        SELECT provisional.id
        FROM public.goods_receipt_ap_provisionals provisional
        JOIN public.goods_receipt_lines receipt_line
          ON receipt_line.company_id=provisional.company_id
         AND receipt_line.id=provisional.receipt_line_id
        LEFT JOIN public.supplier_invoice_allocations allocation
          ON allocation.company_id=provisional.company_id
         AND allocation.source_ap_provisional_id=provisional.id
        LEFT JOIN public.supplier_invoice_documents invoice
          ON invoice.company_id=allocation.company_id
         AND invoice.id=allocation.document_id
         AND invoice.status='VALIDATED'
        GROUP BY provisional.id,provisional.company_id,
                 receipt_line.accepted_good_base_qty,
                 receipt_line.damaged_base_qty,receipt_line.id
        HAVING COALESCE(sum(allocation.allocated_base_qty)
                 FILTER(WHERE invoice.id IS NOT NULL),0)
            > receipt_line.accepted_good_base_qty
              +receipt_line.damaged_base_qty
              -COALESCE((
                  SELECT sum(return_line.return_base_qty)
                  FROM public.purchase_return_lines return_line
                  JOIN public.purchase_return_documents return_document
                    ON return_document.company_id=return_line.company_id
                   AND return_document.id=return_line.document_id
                   AND return_document.status='POSTED'
                  WHERE return_line.company_id=provisional.company_id
                    AND return_line.source_receipt_line_id=receipt_line.id
              ),0)
    ) invalid
    UNION ALL
    SELECT 'supplier_invoice_header_line_reconciliation',
           CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
           jsonb_build_object('document_count',count(*))
    FROM public.supplier_invoice_documents document
    WHERE document.line_count<>(
              SELECT count(*) FROM public.supplier_invoice_lines line
              WHERE line.company_id=document.company_id
                AND line.document_id=document.id
          )
       OR document.invoice_total_base_qty<>(
              SELECT COALESCE(sum(line.invoice_base_qty),0)
              FROM public.supplier_invoice_lines line
              WHERE line.company_id=document.company_id
                AND line.document_id=document.id
          )
       OR document.allocated_total_base_qty<>(
              SELECT COALESCE(sum(allocation.allocated_base_qty),0)
              FROM public.supplier_invoice_allocations allocation
              WHERE allocation.company_id=document.company_id
                AND allocation.document_id=document.id
          )
       OR document.grand_total<>(
              SELECT COALESCE(sum(line.line_total),0)
              FROM public.supplier_invoice_lines line
              WHERE line.company_id=document.company_id
                AND line.document_id=document.id
          )
    UNION ALL
    SELECT 'validated_supplier_invoice_financial_event_coverage',
           CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
           jsonb_build_object('document_count',count(*))
    FROM public.supplier_invoice_documents document
    LEFT JOIN public.financial_events event
      ON event.company_id=document.company_id
     AND event.id=document.financial_event_id
     AND event.source_table='supplier_invoice_documents'
     AND event.source_id=document.id
     AND event.system_event_key='SUPPLIER_INVOICE'
     AND event.status='HOLD'
    WHERE document.status='VALIDATED' AND event.id IS NULL
    UNION ALL
    SELECT 'supplier_invoice_zero_stock_effect',
           CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
           jsonb_build_object('movement_rows',count(*))
    FROM public.stock_movements movement
    WHERE movement.reference_table='supplier_invoice_documents'
    UNION ALL
    SELECT 'supplier_invoice_runtime_inventory','INFO',0,
           jsonb_build_object(
               'documents',(SELECT count(*)
                   FROM public.supplier_invoice_documents),
               'validated_documents',(SELECT count(*)
                   FROM public.supplier_invoice_documents
                   WHERE status='VALIDATED'),
               'allocation_rows',(SELECT count(*)
                   FROM public.supplier_invoice_allocations),
               'open_provisionals',(SELECT count(*)
                   FROM public.goods_receipt_ap_provisionals
                   WHERE status='OPEN'),
               'matched_provisionals',(SELECT count(*)
                   FROM public.goods_receipt_ap_provisionals
                   WHERE status='MATCHED')
           )
)
SELECT check_name,status,violation_rows,details
FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,
         check_name;
