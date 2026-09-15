-- SELECT-only postflight for Purchase RO/PO list parity read model.
WITH checks AS (
  SELECT 'migration_ledger' AS check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END AS status,
    abs(1-count(*))::bigint AS violation_rows,
    jsonb_build_object('ledgerRows',count(*)) AS details
  FROM private.kgs_schema_migrations WHERE version='20260914160000'
  UNION ALL
  SELECT 'purchase_order_list_required_routines',
    CASE WHEN count(*)=3 THEN 'PASS' ELSE 'FAIL' END,
    abs(3-count(*))::bigint,
    jsonb_build_object('present',count(*),'expected',3)
  FROM (VALUES
    ('public.get_purchase_supplier_orders()'),
    ('private.purchase_order_list_v1_base()'),
    ('private.classify_purchase_order_bill_status(numeric,numeric,integer,integer,boolean)')
  ) expected(signature)
  WHERE to_regprocedure(expected.signature) IS NOT NULL
  UNION ALL
  SELECT 'purchase_order_list_public_contract',
    CASE WHEN definition ~ 'supplierOrderListVersion'
      AND definition ~ 'supplierOrderBillSummaries'
      AND definition ~ 'purchase\.supplier_orders'
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN definition ~ 'supplierOrderListVersion'
      AND definition ~ 'supplierOrderBillSummaries'
      AND definition ~ 'purchase\.supplier_orders' THEN 0 ELSE 1 END,
    jsonb_build_object('versioned',definition ~ 'supplierOrderListVersion',
      'billSummary',definition ~ 'supplierOrderBillSummaries',
      'permissionGuard',definition ~ 'purchase\.supplier_orders')
  FROM (SELECT pg_get_functiondef(
    'public.get_purchase_supplier_orders()'::regprocedure) definition) source
  UNION ALL
  SELECT 'purchase_order_list_private_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('authenticatedExecutableRows',count(*))
  FROM information_schema.routine_privileges privilege
  WHERE privilege.specific_schema='private'
    AND privilege.grantee='authenticated'
    AND privilege.privilege_type='EXECUTE'
    AND privilege.routine_name IN(
      'purchase_order_list_v1_base','classify_purchase_order_bill_status')
  UNION ALL
  SELECT 'purchase_order_bill_link_tenant_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('crossCompanyLinks',count(*))
  FROM public.supplier_invoice_allocations allocation
  JOIN public.supplier_order_lines order_line
    ON order_line.id=allocation.supplier_order_line_id
  JOIN public.supplier_invoice_documents invoice
    ON invoice.id=allocation.document_id
  WHERE allocation.company_id<>order_line.company_id
     OR allocation.company_id<>invoice.company_id
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 0 WHEN 'BLOCKER' THEN 1 ELSE 2 END,check_name;
