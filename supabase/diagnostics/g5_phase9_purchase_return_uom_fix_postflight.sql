-- G5 phase 9 postflight: return UOM may differ from purchase UOM.
-- SAFETY: SELECT-only.
WITH checks AS (
    SELECT 'migration_ledger'::TEXT AS check_name,
           CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END AS status,
           CASE WHEN count(*)=1 THEN 0 ELSE 1 END AS violation_rows,
           jsonb_build_object('ledger_rows',count(*)) AS details
    FROM private.kgs_schema_migrations
    WHERE version='20260806080000'
    UNION ALL
    SELECT 'return_uom_runtime_contract',
           CASE WHEN count(*)=1
                  AND count(*) FILTER (
                      WHERE position(
                          'product_uom.purchase_allowed' IN routine.prosrc
                      )=0
                      AND position('product_uom.is_active' IN routine.prosrc)>0
                      AND position('uom.is_active' IN routine.prosrc)>0
                      AND position('v_line."returnQty" * v_uom.factor_to_base' IN routine.prosrc)>0
                  )=1
                THEN 'PASS' ELSE 'FAIL' END,
           CASE WHEN count(*)=1
                  AND count(*) FILTER (
                      WHERE position(
                          'product_uom.purchase_allowed' IN routine.prosrc
                      )=0
                      AND position('product_uom.is_active' IN routine.prosrc)>0
                      AND position('uom.is_active' IN routine.prosrc)>0
                      AND position('v_line."returnQty" * v_uom.factor_to_base' IN routine.prosrc)>0
                  )=1
                THEN 0 ELSE 1 END,
           jsonb_build_object('routine_rows',count(*))
    FROM pg_catalog.pg_proc routine
    JOIN pg_catalog.pg_namespace namespace
      ON namespace.oid=routine.pronamespace
    WHERE namespace.nspname='public'
      AND routine.proname='save_purchase_return_draft'
      AND pg_get_function_identity_arguments(routine.oid)=
          'p_document_id uuid, p_master_version bigint, p_cashier_session_id uuid, p_source_receipt_id uuid, p_source_warehouse_id uuid, p_return_date date, p_return_reason text, p_supplier_document_no text, p_notes text, p_lines jsonb'
    UNION ALL
    SELECT 'browser_purchase_return_write_boundary',
           CASE WHEN NOT has_table_privilege(
                    'authenticated','public.purchase_return_documents',
                    'INSERT,UPDATE,DELETE'
                ) THEN 'PASS' ELSE 'FAIL' END,
           CASE WHEN NOT has_table_privilege(
                    'authenticated','public.purchase_return_documents',
                    'INSERT,UPDATE,DELETE'
                ) THEN 0 ELSE 1 END,
           jsonb_build_object(
               'direct_write',has_table_privilege(
                   'authenticated','public.purchase_return_documents',
                   'INSERT,UPDATE,DELETE'
               )
           )
)
SELECT check_name,status,violation_rows,details
FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 ELSE 2 END,check_name;
